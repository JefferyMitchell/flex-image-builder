# 07-update-catalog-image.ps1
# TEST SCRIPT: not yet validated for production. Use it on a test catalog.
# Moves a Citrix DaaS (Quick Deploy) catalog to a new image, with the checks the API doesn't do:
#
# Before the update (all read-only; -CheckOnly stops here):
#   - the new image is Ready, and has the same session type as the catalog;
#   - its generation and Trusted Launch flags (hyperVGen, vtpmEnabled, secureBootEnabled) match the
#     catalog's current image. If they don't, the update goes Processing → Active, reports success, and
#     then the catalog quietly goes back to the old image. No error appears anywhere;
#   - the catalog isn't static (dedicated) single-session, unless -Force. The update re-provisions those
#     machines, and the users' disks don't survive.
# After it: waits for the catalog to finish, waits -SettleMinutes more, and confirms the catalog's
# imageId is the new image (the revert shows up only after the update reports success).
#
# Usage:
#   $env:CITRIX_CUSTOMER_ID / CITRIX_CLIENT_ID / CITRIX_CLIENT_SECRET as for 06-import-to-citrix.ps1
#   .\07-update-catalog-image.ps1 -CatalogName "Task Worker Desktop" -ImageId <image id> -CheckOnly
#   .\07-update-catalog-image.ps1 -CatalogName "Task Worker Desktop" -ImageId <image id> -VdaUpdateDelay 60
#
# -VdaUpdateDelay (minutes) sets when machines restart onto the new image. It has no default, because
# the update can end users' sessions; only -CheckOnly can leave it out:
#   0 = restart all machines now (sessions on them end), -1 = at each machine's next shutdown,
#   N = spread the restarts over N minutes, warning users first.

[CmdletBinding(DefaultParameterSetName = "ByName")]
param(
    [Parameter(Mandatory, ParameterSetName = "ByName")] [string]$CatalogName,
    [Parameter(Mandatory, ParameterSetName = "ById")]   [string]$CatalogId,

    # The image to move the catalog to (from 06-import-to-citrix.ps1).
    [Parameter(Mandatory)] [string]$ImageId,

    [ValidateRange(-1, 10080)] [int]$VdaUpdateDelay,

    # Run the checks and stop. Makes no changes.
    [switch]$CheckOnly,

    # Allow the update on a static (dedicated) single-session catalog, whose machines are
    # re-provisioned. Users lose anything on their machine's disk.
    [switch]$Force,

    # Extra wait after the catalog reports Active before the final check (a revert shows up late).
    [int]$SettleMinutes = 5,
    [int]$TimeoutMinutes = 120,
    [int]$PollSeconds = 30,

    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    [string]$SiteId
)

$ErrorActionPreference = "Stop"
Write-Warning "Test script: not yet validated for production. Use it on a test catalog."
if (-not $CheckOnly -and -not $PSBoundParameters.ContainsKey("VdaUpdateDelay")) {
    throw "Choose when machines restart: -VdaUpdateDelay 0 (all now; sessions end), -1 (each machine's next shutdown) or N (spread over N minutes, warning users first). Nothing was changed."
}
. (Join-Path $PSScriptRoot "citrix-api.ps1")

Write-Host "`nConnecting to Citrix Cloud..."
Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId

if ($CatalogName) { $CatalogId = Find-CitrixCatalogId $CatalogName }
$catalog = Get-CitrixCatalog $CatalogId
$newImage = Get-CitrixImage $ImageId

Write-Host "`nCatalog : $($catalog.name) ($CatalogId)"
Write-Host "  state $($catalog.state), $($catalog.sessionSupport), allocation $($catalog.allocationType), region $($catalog.region)"
Write-Host "  current image: $($catalog.templateImageName) ($($catalog.imageId))"
Write-Host "New image: $($newImage.name) ($ImageId)"
Write-Host "  state $($newImage.state), $($newImage.sessionSupport), region $($newImage.region), VDA $($newImage.vdaVersion)"

if ($catalog.imageId -eq $ImageId) {
    Write-Host "`nThe catalog already uses this image. Nothing to do."
    exit 0
}

# ── Pre-checks (read-only) ─────────────────────────────────────────────────────
Write-Host "`nPre-checks:"
$problems = [System.Collections.Generic.List[string]]::new()

if ($newImage.state -ne "Ready") {
    $problems.Add("The new image is $($newImage.state), not Ready.")
}
if ($catalog.state -notin @("Active", "InputRequired")) {
    $problems.Add("The catalog is $($catalog.state). Wait until it's Active.")
}
if ($newImage.sessionSupport -and $catalog.sessionSupport -and
    $newImage.sessionSupport -ne "Unknown" -and $newImage.sessionSupport -ne $catalog.sessionSupport) {
    $problems.Add("The new image is $($newImage.sessionSupport) but the catalog is $($catalog.sessionSupport).")
}
if ($newImage.region -and $catalog.region -and $newImage.region -ne $catalog.region) {
    Write-Warning "The new image is in $($newImage.region) but the catalog deploys to $($catalog.region)."
}

# Flags for comparison, preferring the image list: for Citrix-prepared images the detail GET
# reports hyperVGen V1 even when the image is Gen2.
function Get-ComparableFlags([string]$Id, $Detail) {
    $listed = Find-CitrixImageInList $Id
    if (-not $listed) { return Get-ImageFlags $Detail }
    $flags = Get-ImageFlags $listed
    $d = @(Compare-ImageFlags (Get-ImageFlags $Detail) $flags)
    if ($d) { Write-Host "  note: for $($listed.name) the image detail and the image list disagree on $($d -join ', '); using the list" }
    $flags
}

# Generation and Trusted Launch flags must match the catalog's current image, or the update reverts.
$currentImage = $null
try { $currentImage = Get-CitrixImage $catalog.imageId } catch { }
$newFlags = Get-ComparableFlags $ImageId $newImage
if (-not $currentImage) {
    $problems.Add("Can't read the catalog's current image ($($catalog.imageId)), so the flags can't be compared.")
} else {
    $curFlags = Get-ComparableFlags $catalog.imageId $currentImage
    Write-Host ("  {0,-18} {1,-14} {2}" -f "flag", "current image", "new image")
    foreach ($f in "hyperVGen", "vtpmEnabled", "secureBootEnabled") {
        Write-Host ("  {0,-18} {1,-14} {2}" -f $f, $curFlags.$f, $newFlags.$f)
    }
    $diff = @(Compare-ImageFlags $curFlags $newFlags)
    if ($diff) {
        $problems.Add("Flags differ from the catalog's current image ($($diff -join ', ')). The update would report success and then revert. " +
            "Import the image with matching flags, or create a new catalog from it.")
    }
}

# Static (dedicated) single-session machines are re-provisioned by an image update.
$isStatic = $catalog.sessionSupport -eq "SingleSession" -and $catalog.allocationType -in @("Permanent", "Static")
if ($isStatic) {
    $persist = if ($null -ne $catalog.persistStaticAllocatedVmDisks) { $catalog.persistStaticAllocatedVmDisks } else { "not set" }
    $msg = "This is a static (dedicated) single-session catalog (persistStaticAllocatedVmDisks: $persist). " +
           "The update re-provisions its machines, and users' disks don't survive."
    if ($Force) { Write-Warning "$msg Continuing because of -Force." }
    else { $problems.Add("$msg Pass -Force to update it anyway.") }
}

if ($problems.Count) {
    $problems | ForEach-Object { Write-Host "  FAIL  $_" -ForegroundColor Red }
    Write-Error "Pre-checks failed; the catalog was not changed."
}
Write-Host "  OK    image Ready, session type, flags$(if (-not $isStatic) { ', not a static catalog' })"

if ($CheckOnly) {
    Write-Host "`n-CheckOnly: no changes made. Run again with -VdaUpdateDelay instead of -CheckOnly to update the catalog."
    exit 0
}

# ── Update ─────────────────────────────────────────────────────────────────────
$previousImageId = $catalog.imageId
# Exact casing, as the API documents it. CitrixPrepared is false for images you imported.
$body = [ordered]@{
    TemplateId     = $ImageId
    CitrixPrepared = [bool]$newImage.citrixPrepared
    VdaUpdateDelay = $VdaUpdateDelay
}
Write-Host "`nUpdating the catalog image (VdaUpdateDelay $VdaUpdateDelay)..."
$resp = Invoke-CitrixApi POST ('catalogs/{0}/$updateImage' -f $CatalogId) $body
if ($resp) { Write-Host "  Accepted: $($resp | ConvertTo-Json -Compress)" } else { Write-Host "  Accepted." }

# ── Wait for it to finish ──────────────────────────────────────────────────────
Write-Host "`nWaiting for the catalog to finish (Processing → Active)..."
$start = [DateTime]::UtcNow
$deadline = $start.AddMinutes($TimeoutMinutes)
$sawProcessing = $false
$last = ""
while ($true) {
    $catalog = Get-CitrixCatalog $CatalogId
    $now = "$($catalog.state)/$($catalog.subState)"
    if ($now -ne $last) {
        Write-Host "  $([DateTime]::UtcNow.ToString('HH:mm:ss'))Z  $($catalog.state)$(if ($catalog.subState) { " ($($catalog.subState))" })$(if ($null -ne $catalog.taskCompletionPercentage) { " $($catalog.taskCompletionPercentage)%" })"
        $last = $now
    }
    if ($catalog.state -eq "Processing") { $sawProcessing = $true }
    if ($catalog.state -eq "Error") {
        Write-Error "The catalog went to Error during the update: $($catalog.statusMessage) $($catalog.extraInfo)"
    }
    # Done once it's out of Processing (allow a few minutes for Processing to show up at all).
    if ($catalog.state -in @("Active", "InputRequired") -and
        ($sawProcessing -or ([DateTime]::UtcNow - $start).TotalMinutes -ge 5)) { break }
    if ([DateTime]::UtcNow -gt $deadline) {
        Write-Error "The catalog is still $($catalog.state) after $TimeoutMinutes minutes. Check it in the console before running again."
    }
    Start-Sleep -Seconds $PollSeconds
}

# ── Read back ──────────────────────────────────────────────────────────────────
Write-Host "`nCatalog is $($catalog.state). Waiting $SettleMinutes minutes, then confirming the image (a revert shows up late)..."
Start-Sleep -Seconds ($SettleMinutes * 60)
$catalog = Get-CitrixCatalog $CatalogId
if ($catalog.imageId -ne $ImageId) {
    $what = if ($catalog.imageId -eq $previousImageId) { "went back to the previous image" } else { "uses image $($catalog.imageId)" }
    Write-Error "The update reported success, but the catalog $what ($($catalog.templateImageName)). See 'A catalog image update reverts' in docs/troubleshooting.md."
}
Write-Host "`nDone: $($catalog.name) now uses $($catalog.templateImageName) ($ImageId), state $($catalog.state)."
