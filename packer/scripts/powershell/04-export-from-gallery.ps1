# 04-export-from-gallery.ps1
# Exports the OS VHD and VMGS (VM Guest State) disk from an Azure Compute Gallery
# image version to a storage account blob, and outputs the SAS URIs for use in
# citrix_quickdeploy_template_image (Citrix Platform Flex).
#
# Use this script when images are already published to an Azure Compute Gallery
# (e.g. by Azure Image Builder or a customer's existing Packer pipeline).
# For images built from Packer snapshots that are NOT in a gallery, use 03-export-image.ps1.
#
# How it works:
#   1. Creates a temporary managed disk from the gallery image version.
#   2. Calls az disk grant-access --secure-vm-guest-state-sas to obtain both the
#      OS disk SAS and the VMGS SAS (for TrustedLaunch images).
#   3. Copies OS VHD and VMGS to destination blob storage using AzCopy.
#   4. Deletes the temporary disk (you are billed for it only during this window).
#   5. Generates read-only SAS tokens for the destination blobs and prints the
#      terraform variable values ready to paste into terraform.tfvars.
#
# Note: az disk grant-access --secure-vm-guest-state-sas is available in az CLI
# and works for TrustedLaunch managed disks. This is different from the snapshot
# path (az snapshot grant-access) which does NOT expose a VMGS flag in az CLI.
# The REST API beginGetAccess endpoint is not available on gallery image versions
# directly — only on managed disks and snapshots.
#
# Usage:
#   .\04-export-from-gallery.ps1 `
#     -GallerySubscriptionId <subscription-id> `
#     -GalleryResourceGroup  rg-images `
#     -GalleryName           MyImageGallery `
#     -ImageDefinition       WinServer2025DC `
#     -ImageVersion          1.0.0 `
#     -DestStorageAccount    mystorageaccount `
#     -DestResourceGroup     rg-dest `
#     -DestSubscriptionId    <subscription-id>
#
# Notes:
# - GallerySubscriptionId and DestSubscriptionId can be the same or different.
#   Use different values when the gallery and destination storage are in different
#   Azure subscriptions (e.g. customer image gallery + Citrix managed storage).
# - A temporary managed disk is created in GalleryResourceGroup and deleted at the
#   end of the script. Disk billing applies while it exists (~10-30 min).
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

# ── Verify gallery image version ──────────────────────────────────────────────
Write-Host "`nVerifying gallery image version..."
az account set --subscription $GallerySubscriptionId 2>$null

$galleryVersionId = "/subscriptions/$GallerySubscriptionId/resourceGroups/$GalleryResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/images/$ImageDefinition/versions/$ImageVersion"

$versionJson = az sig image-version show `
    --resource-group $GalleryResourceGroup `
    --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition `
    --gallery-image-version $ImageVersion `
    -o json 2>$null | ConvertFrom-Json

if (-not $versionJson -or $versionJson.provisioningState -ne "Succeeded") {
    Write-Error "Gallery image version not found or not in Succeeded state. Got: $($versionJson.provisioningState)"
}
Write-Host "  Provisioning state : $($versionJson.provisioningState)"

# Detect gallery location (temp disk must be in same region)
$galleryLocation = (az sig show `
    --resource-group $GalleryResourceGroup `
    --gallery-name $GalleryName `
    --query "location" -o tsv 2>$null).Trim()
Write-Host "  Gallery location   : $galleryLocation"

# Detect security type from image definition — required for az disk create
$securityType = (az sig image-definition show `
    --resource-group $GalleryResourceGroup `
    --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition `
    --query "features[?name=='SecurityType'].value | [0]" -o tsv 2>$null).Trim()
Write-Host "  Security type      : $(if ($securityType) { $securityType } else { 'Standard (Gen2)' })"
$isTrustedLaunch = ($securityType -eq "TrustedLaunch" -or $securityType -eq "TrustedLaunchSupported")

# ── Create temporary managed disk from gallery image version ──────────────────
# az disk create --gallery-image-reference is the correct way to export a gallery
# image version. For TrustedLaunch images, --security-type TrustedLaunch is required.
# The temporary disk provides access to the VMGS via:
#   az disk grant-access --secure-vm-guest-state-sas
$diskName = "export-temp-$($ImageDefinition.ToLower())-$($ImageVersion.Replace('.', '-'))"
if ($diskName.Length -gt 80) { $diskName = $diskName.Substring(0, 80) }

Write-Host "`nCreating temporary managed disk from gallery image version..."
Write-Host "  Disk name: $diskName  (will be deleted after copy)"

if ($isTrustedLaunch) {
    Write-Host "  Passing --security-type TrustedLaunch (required for TrustedLaunch gallery images)"
    az disk create `
        --resource-group $GalleryResourceGroup `
        --name $diskName `
        --gallery-image-reference $galleryVersionId `
        --location $galleryLocation `
        --sku Standard_LRS `
        --security-type TrustedLaunch 2>&1 | Select-String -Pattern "provisioningState|error" | Select-Object -First 5
} else {
    az disk create `
        --resource-group $GalleryResourceGroup `
        --name $diskName `
        --gallery-image-reference $galleryVersionId `
        --location $galleryLocation `
        --sku Standard_LRS 2>&1 | Select-String -Pattern "provisioningState|error" | Select-Object -First 5
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "az disk create failed (exit $LASTEXITCODE)"
}
Write-Host "  Disk created."

# ── Grant access (OS SAS + VMGS SAS if TrustedLaunch) ────────────────────────
Write-Host "`nGranting access to temporary disk..."
Write-Host "  (az disk grant-access --secure-vm-guest-state-sas returns VMGS for TrustedLaunch disks)"
$sasJson = az disk grant-access `
    --resource-group $GalleryResourceGroup `
    --name $diskName `
    --duration-in-seconds 86400 `
    --secure-vm-guest-state-sas `
    -o json 2>$null

$sasResult = $sasJson | ConvertFrom-Json
$sourceSas = $sasResult.accessSAS
$vmgsSas   = $sasResult.securityDataAccessSAS

if (-not $sourceSas) {
    Write-Error "OS disk SAS not returned by az disk grant-access. Response: $sasJson"
}
Write-Host "  OS SAS obtained  (length $($sourceSas.Length))."
if ($vmgsSas) {
    Write-Host "  VMGS SAS obtained (length $($vmgsSas.Length)) — TrustedLaunch disk confirmed."
} else {
    Write-Host "  VMGS SAS not returned — disk does not have VM guest state (not TrustedLaunch)."
    Write-Host "  Proceeding with OS disk only. Set secure_boot_enabled = false in Terraform."
}

# ── Destination setup ──────────────────────────────────────────────────────────
az account set --subscription $DestSubscriptionId 2>$null
$saKey           = (az storage account keys list --account-name $DestStorageAccount --resource-group $DestResourceGroup --query "[0].value" -o tsv 2>$null)
$containerExpiry = [System.DateTime]::UtcNow.AddHours(6).ToString("yyyy-MM-ddTHH:mmZ")
$destContainerSas = (az storage container generate-sas `
    --account-name $DestStorageAccount --account-key $saKey `
    --name $OutputContainer --permissions rcw --expiry $containerExpiry -o tsv 2>$null)

$safeName    = "$ImageDefinition-$($ImageVersion.Replace('.', '-'))"
$osBlobName  = "$safeName.vhd"
$osDestUrl   = "https://$DestStorageAccount.blob.core.windows.net/$OutputContainer/$osBlobName`?$destContainerSas"

# ── OS disk copy ───────────────────────────────────────────────────────────────
Write-Host "`nCopying OS disk from temporary disk to blob storage (~10-30 minutes)..."
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

# ── Delete temporary disk ──────────────────────────────────────────────────────
Write-Host "`nDeleting temporary managed disk..."
az account set --subscription $GallerySubscriptionId 2>$null
az disk revoke-access --resource-group $GalleryResourceGroup --name $diskName 2>$null
az disk delete --resource-group $GalleryResourceGroup --name $diskName --yes 2>$null
Write-Host "  Temporary disk deleted."

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
    Write-Host "  # guest_disk_uri not available — image does not have VM guest state."
    Write-Host "  secure_boot_enabled = false"
    Write-Host "  vtpm_enabled        = false"
}
Write-Host ""
Write-Host "SAS expires: $blobExpiry UTC  (re-run this script with -SasDays N to renew)"
