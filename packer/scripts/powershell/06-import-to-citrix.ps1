# 06-import-to-citrix.ps1
# Imports an exported VHD (and, for Trusted Launch, its VMGS guest-state blob) into the Citrix DaaS
# image library through the Quick Deploy API, waits for it to be Ready, and reads back the generation
# and Trusted Launch flags. The API alternative to citrix_quickdeploy_template_image in Terraform.
#
# Why the read-back: the API ignores request fields it doesn't recognize and still returns success.
# Sending "machineGeneration" instead of "hyperVGen" imports a Gen1 image, and a catalog update with it
# later reverts silently. So the script fails unless hyperVGen, vtpmEnabled and secureBootEnabled on the
# imported image are exactly what was asked for.
#
# Usage (after 04-export-from-gallery.ps1, with its vhd_uri and guest_disk_uri):
#   $env:CITRIX_CUSTOMER_ID   = "<customer id>"
#   $env:CITRIX_CLIENT_ID     = "<api client id>"
#   $env:CITRIX_CLIENT_SECRET = "<api client secret>"   # from your secret manager, never a parameter
#   .\06-import-to-citrix.ps1 `
#     -Name         WinServer2025DC-1.1.0 `
#     -VhdUri       "https://<account>.blob.core.windows.net/vhd-output/WinServer2025DC-1-1-0.vhd?<sas>" `
#     -GuestDiskUri "https://<account>.blob.core.windows.net/vhd-output/WinServer2025DC-1-1-0-vmgs.vhd?<sas>" `
#     -Region       eastus
#
# Check an image that's already imported (or resume after a timeout) without importing again:
#   .\06-import-to-citrix.ps1 -ImageId <image id>
#
# Trusted Launch (Gen2, vTPM, Secure Boot) is the default and needs -GuestDiskUri. For a Gen2 image
# without guest state, pass -NoSecureBoot (vTPM alone works from a plain Gen2 VHD).
#
# The route is POST /catalogservice/{customerId}/{siteId}/images/$import. The look-alike
# POST /catalogservice/{customerId}/images (no site ID) is the bring-your-own-subscription route:
# without a linked subscription its images stay Pending forever. See docs/troubleshooting.md.

[CmdletBinding(DefaultParameterSetName = "Import")]
param(
    # Image name in the Citrix library. Include the version, e.g. WinServer2025DC-1.1.0.
    [Parameter(Mandatory, ParameterSetName = "Import")] [string]$Name,

    # vhd_uri from the export script: the OS VHD blob with a read SAS.
    [Parameter(Mandatory, ParameterSetName = "Import")] [string]$VhdUri,

    # guest_disk_uri from the export script: the VMGS blob with a read SAS. Sent as vhdEncryptionUri.
    [Parameter(ParameterSetName = "Import")] [string]$GuestDiskUri,

    # Azure region for the image; use the region your catalogs deploy to.
    [Parameter(Mandatory, ParameterSetName = "Import")] [string]$Region,

    [Parameter(ParameterSetName = "Import")] [ValidateSet("Windows", "Linux")] [string]$OsPlatform = "Windows",

    [Parameter(ParameterSetName = "Import")] [string]$Notes = "Imported by flex-image-builder 06-import-to-citrix.ps1",
    [Parameter(ParameterSetName = "Import")] [string]$SubscriptionName = "Citrix Managed",

    # Skip the import and check an existing image: wait for Ready, then read back its flags.
    [Parameter(Mandatory, ParameterSetName = "Check")] [string]$ImageId,

    # Expected flags (sent on import, checked on read-back). Trusted Launch by default.
    [ValidateSet("V1", "V2")] [string]$HyperVGen = "V2",
    [switch]$NoVtpm,
    [switch]$NoSecureBoot,

    # Import usually takes 15-25 minutes.
    [int]$TimeoutMinutes = 60,
    [int]$PollSeconds = 30,

    # Citrix Cloud API host: api.cloud.com (US), api-eu.cloud.com, api-ap-s.cloud.com, api.citrixcloud.jp.
    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    # Optional; looked up from GET /cvad/manage/me when not given.
    [string]$SiteId
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "citrix-api.ps1")

$expected = [pscustomobject]@{
    hyperVGen         = $HyperVGen
    vtpmEnabled       = -not $NoVtpm
    secureBootEnabled = -not $NoSecureBoot
}

# ── Check the inputs before calling Citrix ────────────────────────────────────
if ($HyperVGen -eq "V1" -and ($expected.vtpmEnabled -or $expected.secureBootEnabled)) {
    Write-Error "vTPM and Secure Boot need a Gen2 (V2) image. For V1, add -NoVtpm -NoSecureBoot."
}

if ($PSCmdlet.ParameterSetName -eq "Import") {
    if ($expected.secureBootEnabled -and -not $GuestDiskUri) {
        Write-Error "Secure Boot needs the VMGS blob: pass -GuestDiskUri (guest_disk_uri from the export), or -NoSecureBoot."
    }
    if ($GuestDiskUri -and -not $expected.secureBootEnabled) {
        Write-Error "-GuestDiskUri is only used with Secure Boot. Drop -NoSecureBoot, or drop -GuestDiskUri."
    }

    # Citrix reads the blobs from its own backend, so each URI needs a read SAS; a plain blob URL is
    # rejected with "The specified VHD URL is invalid". The import also needs the SAS to stay valid
    # while Citrix copies the VHD.
    foreach ($u in @(@{ n = "VhdUri"; v = $VhdUri }, @{ n = "GuestDiskUri"; v = $GuestDiskUri })) {
        if (-not $u.v) { continue }
        if ($u.v -notmatch '^https://[^?]+\?.*sig=') {
            Write-Error "-$($u.n) must be an https blob URL with a read SAS (…?sv=…&sig=…), as printed by the export script."
        }
        $se = [regex]::Match($u.v, '[?&]se=([^&]+)').Groups[1].Value
        if ($se) {
            $expiry = [DateTime]::Parse([Uri]::UnescapeDataString($se), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
            $left = $expiry - [DateTime]::UtcNow
            if ($left.TotalMinutes -le 0) {
                Write-Error "The -$($u.n) SAS expired at $($expiry.ToString('u')). Re-run the export script for a fresh one."
            }
            if ($left.TotalHours -lt 2) {
                Write-Warning "The -$($u.n) SAS expires in $([int]$left.TotalMinutes) minutes; the import can take 25. Consider a fresh export."
            }
        }
    }
}

Write-Host "`nConnecting to Citrix Cloud..."
Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId

# ── Import ─────────────────────────────────────────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq "Import") {
    $existing = @((Invoke-CitrixApi GET "images").items | Where-Object { $_.name -eq $Name })
    if ($existing) {
        Write-Error "An image named '$Name' already exists (id $($existing[0].id), state $($existing[0].state)). Use a new name, or check it with -ImageId $($existing[0].id)."
    }

    # Field names are the API's, not Terraform's: hyperVGen (machine_generation),
    # vhdEncryptionUri (guest_disk_uri). Unknown names are dropped without an error.
    # Like the Terraform provider: without azureSubscriptionId the API refuses the import with
    # "this account does not have Citrix managed capacity enabled" (HTTP 422).
    $subs = @((Invoke-CitrixApi GET "subscriptions").subscriptions)
    $sub = $subs | Where-Object { $_.name -eq $SubscriptionName } | Select-Object -First 1
    if (-not $sub) { Write-Error "No Flex subscription named '$SubscriptionName'. Found: $(($subs | ForEach-Object name) -join ', ')" }
    $body = [ordered]@{
        azureSubscriptionId = $sub.subscriptionId
        name              = $Name
        vhdUri            = $VhdUri
        osPlatform        = $OsPlatform
        region            = $Region
        hyperVGen         = $expected.hyperVGen
        vtpmEnabled       = $expected.vtpmEnabled
        secureBootEnabled = $expected.secureBootEnabled
        notes             = $Notes
    }
    if ($GuestDiskUri) { $body.vhdEncryptionUri = $GuestDiskUri }

    Write-Host "`nImporting image '$Name'..."
    Write-Host "  vhdUri           : $(Format-SafeUri $VhdUri)"
    if ($GuestDiskUri) { Write-Host "  vhdEncryptionUri : $(Format-SafeUri $GuestDiskUri)" }
    Write-Host "  region $Region, $OsPlatform, $($expected.hyperVGen), vTPM $($expected.vtpmEnabled), Secure Boot $($expected.secureBootEnabled)"

    $resp = Invoke-CitrixApi POST 'images/$import' $body
    $ImageId = if ($resp -is [string]) { $resp.Trim('"') } else { $resp.id }
    if (-not $ImageId) { Write-Error "The import call returned no image id. Response: $($resp | ConvertTo-Json -Compress)" }
    Write-Host "  Image id: $ImageId"
}

# ── Wait for Ready ─────────────────────────────────────────────────────────────
Write-Host "`nWaiting for the image to be Ready (Pending → Importing → Ready, usually 15-25 minutes)..."
$start = [DateTime]::UtcNow
$deadline = $start.AddMinutes($TimeoutMinutes)
$last = ""
$seen = $false
$serverErrors = 0
while ($true) {
    try {
        $image = Get-CitrixImage $ImageId
        $seen = $true
        $serverErrors = 0
    } catch {
        # Right after $import, GET on the new image can return 404 ("Authority was not found") for a few
        # seconds, and the API occasionally returns a 5xx. Retry those instead of abandoning an import
        # that is actually running.
        $code = $_.Exception.Data["StatusCode"]
        $early404 = $code -eq 404 -and -not $seen -and ([DateTime]::UtcNow - $start).TotalMinutes -lt 5
        $transient = $code -ge 500 -and (++$serverErrors) -le 5
        if (-not ($early404 -or $transient)) { throw }
        Write-Host "  $([DateTime]::UtcNow.ToString('HH:mm:ss'))Z  HTTP $code from the API, retrying"
        Start-Sleep -Seconds $PollSeconds
        continue
    }
    $now = "$($image.state)/$($image.subState)"
    if ($now -ne $last) {
        Write-Host "  $([DateTime]::UtcNow.ToString('HH:mm:ss'))Z  $($image.state)$(if ($image.subState) { " ($($image.subState))" })$(if ($image.status) { " - $($image.status)" })"
        $last = $now
    }
    if ($image.state -eq "Ready") { break }
    if ($image.state -in @("Failed", "AzureResourcesNotFound")) {
        Write-Error "Import failed: state $($image.state). $($image.status) $($image.extraInfo)"
    }
    if ([DateTime]::UtcNow -gt $deadline) {
        Write-Error "Image still $($image.state) after $TimeoutMinutes minutes. Check again later with: .\06-import-to-citrix.ps1 -ImageId $ImageId"
    }
    Start-Sleep -Seconds $PollSeconds
}

# ── Read back the flags ────────────────────────────────────────────────────────
$actual = Get-ImageFlags $image
Write-Host "`nRead back from the API:"
Write-Host ("  {0,-18} {1,-10} {2}" -f "field", "expected", "actual")
foreach ($f in "hyperVGen", "vtpmEnabled", "secureBootEnabled") {
    Write-Host ("  {0,-18} {1,-10} {2}" -f $f, $expected.$f, $actual.$f)
}
Write-Host "  OS $($image.osName) $($image.osVersion), $($image.sessionSupport), VDA $($image.vdaVersion), region $($image.region)"

$diff = @(Compare-ImageFlags $expected $actual)
if ($diff) {
    Write-Error ("The image doesn't have the flags that were asked for ($($diff -join ', ')). Don't use it for a catalog: " +
        "an image update with mismatched flags reverts silently. Delete it and import again.")
}

Write-Host "`nImage $ImageId is Ready with the expected generation and Trusted Launch flags."
Write-Host "To put it on a catalog:"
Write-Host "  .\07-update-catalog-image.ps1 -CatalogName '<catalog>' -ImageId $ImageId -CheckOnly"
