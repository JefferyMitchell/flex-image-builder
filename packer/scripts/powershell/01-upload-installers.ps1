# 01-upload-installers.ps1
# Uploads VDA installer and Citrix Optimizer to Azure Blob Storage.
# Prints plain blob URLs (no SAS) to paste into your vars file.
#
# Authentication: uses your active az login session (--auth-mode login).
# No account keys or SAS tokens are generated — the Packer build VM downloads
# installers at runtime using its managed identity (see 00-setup-azure.ps1).
#
# Usage:
#   .\01-upload-installers.ps1 `
#     -StorageAccount flexpackerbuild `
#     -VdaPath C:\Downloads\VDASetup.exe `
#     -OptimizerPath C:\Downloads\CitrixOptimizer.zip

param(
    [Parameter(Mandatory)] [string]$StorageAccount,
    [Parameter(Mandatory)] [string]$VdaPath,
    [Parameter(Mandatory)] [string]$OptimizerPath,
    [string]$Container = "installers"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $VdaPath))       { Write-Error "VDA installer not found: $VdaPath" }
if (-not (Test-Path $OptimizerPath)) { Write-Error "Citrix Optimizer not found: $OptimizerPath" }

Write-Host "`nUploading VDA installer..."
az storage blob upload `
    --account-name $StorageAccount --auth-mode login `
    --container-name $Container `
    --file $VdaPath --name "VDASetup.exe" `
    --overwrite | Out-Null

Write-Host "Uploading Citrix Optimizer..."
az storage blob upload `
    --account-name $StorageAccount --auth-mode login `
    --container-name $Container `
    --file $OptimizerPath --name "CitrixOptimizer.zip" `
    --overwrite | Out-Null

$vdaUrl = "https://$StorageAccount.blob.core.windows.net/$Container/VDASetup.exe"
$optUrl = "https://$StorageAccount.blob.core.windows.net/$Container/CitrixOptimizer.zip"

Write-Host "`n--- Paste these into your vars file ---"
Write-Host "vda_blob_url       = `"$vdaUrl`""
Write-Host "optimizer_blob_url = `"$optUrl`""
Write-Host ""
Write-Host "No expiry — the Packer build VM authenticates via managed identity at runtime."
