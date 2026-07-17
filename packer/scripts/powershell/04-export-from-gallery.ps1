# 04-export-from-gallery.ps1
# Exports the OS VHD and VMGS (VM Guest State) disk from an Azure Compute Gallery
# image version to a storage account blob, and outputs the SAS URIs for use in
# citrix_quickdeploy_template_image (Citrix Platform Flex).
#
# Use this script when images are already published to an Azure Compute Gallery
# (e.g. by Azure Image Builder or a customer's existing Packer pipeline).
# For images built with Packer snapshots, use 03-export-image.ps1 instead.
#
# Both the OS VHD and VMGS SAS URIs are required when secure_boot_enabled = true.
# If the gallery image was not published with security_type = TrustedLaunch,
# this script will output a VHD URI only and recommend secure_boot_enabled = false.
#
# Usage:
#   .\04-export-from-gallery.ps1 `
#     -GallerySubscriptionId bf8e9af8-7c74-405f-a685-c15b15cb128f `
#     -GalleryResourceGroup  rg-images `
#     -GalleryName           MyImageGallery `
#     -ImageDefinition       WinServer2025DC `
#     -ImageVersion          1.0.0 `
#     -DestStorageAccount    mystorageaccount `
#     -DestResourceGroup     rg-dest `
#     -DestSubscriptionId    bf8e9af8-7c74-405f-a685-c15b15cb128f
#
# Notes:
# - GallerySubscriptionId and DestSubscriptionId can be the same or different.
#   Use different values when the gallery and destination storage are in different
#   Azure subscriptions (e.g. customer image gallery + Citrix managed storage).
# - The destination storage account must already exist with a container named
#   OutputContainer (default: vhd-output). Create one with:
#     az storage account create --name <name> --resource-group <rg> --sku Standard_LRS --kind StorageV2
#     az storage container create --name vhd-output --account-name <name>
# - AzCopy v10 is required. Install with: winget install Microsoft.Azure.AzCopy.10
# - The blob names written are: <definition>-<version>.vhd and <definition>-<version>-vmgs.vhd
# - SAS tokens expire after SasDays (default 14). Re-run to regenerate without re-copying.

param(
    [Parameter(Mandatory)] [string]$GallerySubscriptionId,
    [Parameter(Mandatory)] [string]$GalleryResourceGroup,
    [Parameter(Mandatory)] [string]$GalleryName,
    [Parameter(Mandatory)] [string]$ImageDefinition,
    [Parameter(Mandatory)] [string]$ImageVersion,
    [Parameter(Mandatory)] [string]$DestStorageAccount,
    [Parameter(Mandatory)] [string]$DestResourceGroup,
    [Parameter(Mandatory)] [string]$DestSubscriptionId,
    [string]$OutputContainer = "vhd-output",
    [int]$SasDays = 14
)

$ErrorActionPreference = "Stop"

# Locate AzCopy
$azCopy = Get-Command azcopy -ErrorAction SilentlyContinue
if (-not $azCopy) {
    $azCopy = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter azcopy.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $azCopy) { Write-Error "azcopy not found. Install with: winget install Microsoft.Azure.AzCopy.10" }
    $azCopyExe = $azCopy.FullName
} else {
    $azCopyExe = $azCopy.Source
}

# Verify gallery image version exists and note its security type
Write-Host "`nVerifying gallery image version..."
az account set --subscription $GallerySubscriptionId 2>$null
$versionJson = az sig image-version show `
    --resource-group $GalleryResourceGroup `
    --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition `
    --gallery-image-version $ImageVersion `
    --query "{state:provisioningState, securityType:securityProfile.uefiSettings.secureBootEnabled, replicationState:replicationStatus.summary[0].state}" `
    -o json 2>$null | ConvertFrom-Json

$secureBootEnabled = $versionJson.securityType
Write-Host "  Provisioning state : $($versionJson.state)"
Write-Host "  Secure Boot        : $(if ($secureBootEnabled) { 'Enabled (TrustedLaunch)' } else { 'Not enabled' })"

# ── Grant SAS via REST API ─────────────────────────────────────────────────────
# The Azure CLI does not expose getSecureVMGuestStateSAS on gallery versions via
# a named parameter, so we use the Compute REST API directly.
# !! Use UtcNow — (Get-Date) returns LOCAL time. Appending "Z" would misrepresent
# !! the timezone, causing SAS expiry to be in the past on non-UTC machines.
Write-Host "`nObtaining bearer token for REST API..."
az account set --subscription $GallerySubscriptionId 2>$null
$azToken = (az account get-access-token --subscription $GallerySubscriptionId --query accessToken -o tsv 2>$null)
$authHdr = @{ Authorization = "Bearer $azToken"; "Content-Type" = "application/json" }

$galleryVersionId = "/subscriptions/$GallerySubscriptionId/resourceGroups/$GalleryResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/images/$ImageDefinition/versions/$ImageVersion"
$baseUrl = "https://management.azure.com$galleryVersionId"

# Revoke any active SAS
Write-Host "Revoking any active SAS on the gallery image version..."
try { Invoke-RestMethod -Method POST -Uri "$baseUrl/endGetAccess?api-version=2024-03-02" -Headers $authHdr -Body "{}" | Out-Null } catch {}
Start-Sleep -Seconds 3

# Grant access with VMGS flag
Write-Host "Granting read SAS on gallery image version (including VMGS if TrustedLaunch)..."
$grantResp = Invoke-WebRequest -Method POST -Uri "$baseUrl/beginGetAccess?api-version=2024-03-02" `
    -Headers $authHdr -Body '{"access":"Read","durationInSeconds":86400,"getSecureVMGuestStateSAS":true}' -UseBasicParsing
if ($grantResp.StatusCode -ne 202) { Write-Error "beginGetAccess returned $($grantResp.StatusCode)" }

$asyncUrl = ([string[]]($grantResp.Headers["Azure-AsyncOperation"]))[0]
$sasOut   = $null
for ($i = 1; $i -le 24; $i++) {
    $poll = Invoke-RestMethod -Method GET -Uri $asyncUrl -Headers $authHdr
    if ($poll.status -eq "Succeeded") { $sasOut = $poll.properties.output; break }
    if ($poll.status -eq "Failed")    { Write-Error "Grant-access operation failed: $($poll | ConvertTo-Json -Depth 4)" }
    Write-Host "  Waiting for SAS grant ($i/24)..."
    Start-Sleep -Seconds 5
}
if (-not $sasOut) { Write-Error "Timed out waiting for SAS grant operation" }

# Gallery grant-access returns the OS disk SAS at the top level, not in .accessSAS
# The response shape depends on whether it's a single-disk or multi-disk image.
# Try both shapes.
$sourceSas = if ($sasOut.accessSAS) { $sasOut.accessSAS } elseif ($sasOut.osDiskImage.accessUri) { $sasOut.osDiskImage.accessUri } else { $null }
$vmgsSas   = $sasOut.securityDataAccessSAS

if (-not $sourceSas) { Write-Error "OS disk SAS not returned. Response: $($sasOut | ConvertTo-Json -Depth 4)" }
Write-Host "  OS SAS obtained  (length $($sourceSas.Length))."
if ($vmgsSas) {
    Write-Host "  VMGS SAS obtained (length $($vmgsSas.Length)) — TrustedLaunch image confirmed."
} else {
    Write-Host "  VMGS SAS not returned — image was not published with security_type = TrustedLaunch."
    Write-Host "  Proceeding with OS disk only. Set secure_boot_enabled = false in Terraform."
}

# ── Destination setup ──────────────────────────────────────────────────────────
az account set --subscription $DestSubscriptionId 2>$null
$saKey          = (az storage account keys list --account-name $DestStorageAccount --resource-group $DestResourceGroup --query "[0].value" -o tsv 2>$null)
$containerExpiry = [System.DateTime]::UtcNow.AddHours(6).ToString("yyyy-MM-ddTHH:mmZ")
$destContainerSas = (az storage container generate-sas `
    --account-name $DestStorageAccount --account-key $saKey `
    --name $OutputContainer --permissions rcw --expiry $containerExpiry -o tsv 2>$null)

# Blob name: <ImageDefinition>-<ImageVersion>.vhd (dots replaced with dashes in version)
$safeName    = "$ImageDefinition-$($ImageVersion.Replace('.', '-'))"
$osBlobName  = "$safeName.vhd"
$osDestUrl   = "https://$DestStorageAccount.blob.core.windows.net/$OutputContainer/$osBlobName`?$destContainerSas"

# ── OS disk copy ───────────────────────────────────────────────────────────────
Write-Host "`nCopying OS disk from gallery to blob storage (~10-30 minutes)..."
& $azCopyExe copy $sourceSas $osDestUrl --blob-type PageBlob
if ($LASTEXITCODE -ne 0) { Write-Error "AzCopy (OS disk) failed with exit code $LASTEXITCODE" }

# ── VMGS disk copy (TrustedLaunch only) ───────────────────────────────────────
$vmgsUri = $null
if ($vmgsSas) {
    $vmgsBlobName = "$safeName-vmgs.vhd"
    $vmgsDestUrl  = "https://$DestStorageAccount.blob.core.windows.net/$OutputContainer/$vmgsBlobName`?$destContainerSas"

    Write-Host "`nCopying VMGS (VM Guest State) disk..."
    & $azCopyExe copy $vmgsSas $vmgsDestUrl --blob-type PageBlob
    if ($LASTEXITCODE -ne 0) { Write-Error "AzCopy (VMGS) failed with exit code $LASTEXITCODE" }

    $blobExpiry  = [System.DateTime]::UtcNow.AddDays($SasDays).ToString("yyyy-MM-ddTHH:mmZ")
    $vmgsBlobSas = (az storage blob generate-sas `
        --account-name $DestStorageAccount --account-key $saKey `
        --container-name $OutputContainer --name $vmgsBlobName `
        --permissions r --expiry $blobExpiry --https-only -o tsv 2>$null)
    $vmgsUri = "https://$DestStorageAccount.blob.core.windows.net/$OutputContainer/$vmgsBlobName`?$vmgsBlobSas"
}

# ── Revoke source SAS ──────────────────────────────────────────────────────────
Write-Host "`nRevoking SAS on gallery image version..."
az account set --subscription $GallerySubscriptionId 2>$null
$azToken = (az account get-access-token --subscription $GallerySubscriptionId --query accessToken -o tsv 2>$null)
$authHdr = @{ Authorization = "Bearer $azToken"; "Content-Type" = "application/json" }
try { Invoke-RestMethod -Method POST -Uri "$baseUrl/endGetAccess?api-version=2024-03-02" -Headers $authHdr -Body "{}" | Out-Null } catch {}

# ── Output blob SAS for OS VHD ────────────────────────────────────────────────
az account set --subscription $DestSubscriptionId 2>$null
$blobExpiry  = [System.DateTime]::UtcNow.AddDays($SasDays).ToString("yyyy-MM-ddTHH:mmZ")
$osBlobSas   = (az storage blob generate-sas `
    --account-name $DestStorageAccount --account-key $saKey `
    --container-name $OutputContainer --name $osBlobName `
    --permissions r --expiry $blobExpiry --https-only -o tsv 2>$null)
$vhdUri = "https://$DestStorageAccount.blob.core.windows.net/$OutputContainer/$osBlobName`?$osBlobSas"

# ── Final output ───────────────────────────────────────────────────────────────
Write-Host "`n=== Export complete ==="
Write-Host ""
Write-Host "Add these to your Terraform configuration:"
Write-Host ""
Write-Host "  vhd_uri            = `"$vhdUri`""
if ($vmgsUri) {
    Write-Host "  guest_disk_uri     = `"$vmgsUri`""
    Write-Host "  secure_boot_enabled = true"
    Write-Host "  vtpm_enabled        = true"
} else {
    Write-Host ""
    Write-Host "  # guest_disk_uri not available — image was not published with security_type = TrustedLaunch."
    Write-Host "  secure_boot_enabled = false"
    Write-Host "  vtpm_enabled        = false"
}
Write-Host ""
Write-Host "SAS expires: $blobExpiry UTC  (re-run this script with -SasDays N to renew)"
