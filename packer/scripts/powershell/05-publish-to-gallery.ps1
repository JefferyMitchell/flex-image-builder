# 05-publish-to-gallery.ps1
#
# LEGACY: only for a managed image built elsewhere (managed images cannot be Trusted
# Launch). The templates in packer/templates/ publish straight into the gallery, so a
# normal build goes 02-build.ps1 -> 04-export-from-gallery.ps1 and skips this script.
#
# Publishes a Packer-built managed image to an Azure Compute Gallery so that
# 04-export-from-gallery.ps1 can export the OS VHD and VMGS SAS URIs.
#
# Packer outputs a managed image (e.g. win_desktop_11_23h2_202607171045).
# This script creates a gallery image version from that managed image.
#
# Usage:
#   .\05-publish-to-gallery.ps1 `
#     -ManagedImageName      win_desktop_11_23h2_202607171045 `
#     -ManagedImageRG        rg-flex-packer-build `
#     -GalleryResourceGroup  rg-flex-packer-build `
#     -GalleryName           FlexPackerGallery `
#     -ImageDefinition       WinDesktop11Enterprise23H2 `
#     -ImageVersion          1.0.0 `
#     -SubscriptionId        bf8e9af8-7c74-405f-a685-c15b15cb128f
#
# After this completes, run 04-export-from-gallery.ps1 to export the SAS URIs.

param(
    [Parameter(Mandatory)] [string]$ManagedImageName,
    [Parameter(Mandatory)] [string]$ManagedImageRG,
    [Parameter(Mandatory)] [string]$GalleryResourceGroup,
    [Parameter(Mandatory)] [string]$GalleryName,
    [Parameter(Mandatory)] [string]$ImageDefinition,
    [Parameter(Mandatory)] [string]$ImageVersion,
    [Parameter(Mandatory)] [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"

az account set --subscription $SubscriptionId 2>$null

# Get managed image ID
Write-Host "Looking up managed image: $ManagedImageName..."
$imageId = (az image show --resource-group $ManagedImageRG --name $ManagedImageName --query id --output tsv 2>&1)
if ($LASTEXITCODE -ne 0) {
    Write-Error "Managed image '$ManagedImageName' not found in $ManagedImageRG.`nAvailable images:`n$(az image list --resource-group $ManagedImageRG --query '[].name' --output tsv)"
}
Write-Host "  Image ID: $imageId"

# Get gallery location (image version must be published to the same region as the gallery)
$galleryLocation = (az sig show --resource-group $GalleryResourceGroup --gallery-name $GalleryName --query location --output tsv 2>$null).Trim()
Write-Host "  Gallery location: $galleryLocation"

Write-Host "`nPublishing gallery image version $ImageVersion..."
Write-Host "  $GalleryName/$ImageDefinition/$ImageVersion"
Write-Host "  (this takes 5-20 minutes depending on image size)"

az sig image-version create `
    --resource-group $GalleryResourceGroup `
    --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition `
    --gallery-image-version $ImageVersion `
    --managed-image $imageId `
    --target-regions $galleryLocation `
    --output json 2>&1 | Select-String -Pattern '"provisioningState"|"replicationState"|error'

if ($LASTEXITCODE -ne 0) {
    Write-Error "az sig image-version create failed (exit $LASTEXITCODE)"
}

Write-Host "`nGallery version published. Run 04-export-from-gallery.ps1 next:"
Write-Host ""
Write-Host "  .\04-export-from-gallery.ps1 ``"
Write-Host "    -GallerySubscriptionId $SubscriptionId ``"
Write-Host "    -GalleryResourceGroup  $GalleryResourceGroup ``"
Write-Host "    -GalleryName           $GalleryName ``"
Write-Host "    -ImageDefinition       $ImageDefinition ``"
Write-Host "    -ImageVersion          $ImageVersion ``"
Write-Host "    -DestStorageAccount    flexpackerbuild ``"
Write-Host "    -DestResourceGroup     rg-flex-packer-build ``"
Write-Host "    -DestSubscriptionId    $SubscriptionId"
