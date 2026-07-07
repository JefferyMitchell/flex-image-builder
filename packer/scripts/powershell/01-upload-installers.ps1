# 01-upload-installers.ps1
# Uploads VDA installer and Citrix Optimizer to Azure Blob Storage,
# then prints SAS URLs to paste into your .pkrvars.hcl file.
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
    [string]$ResourceGroup = "rg-flex-packer-build",
    [string]$Container     = "installers",
    [int]$SasHours         = 4
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $VdaPath))       { Write-Error "VDA installer not found: $VdaPath" }
if (-not (Test-Path $OptimizerPath)) { Write-Error "Citrix Optimizer not found: $OptimizerPath" }

$saKey  = (az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv)
$expiry = (Get-Date).AddHours($SasHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mmZ")

Write-Host "`nUploading VDA installer..."
az storage blob upload `
    --account-name $StorageAccount --account-key $saKey `
    --container-name $Container `
    --file $VdaPath --name "VDASetup.exe" `
    --overwrite | Out-Null

Write-Host "Uploading Citrix Optimizer..."
az storage blob upload `
    --account-name $StorageAccount --account-key $saKey `
    --container-name $Container `
    --file $OptimizerPath --name "CitrixOptimizer.zip" `
    --overwrite | Out-Null

Write-Host "Generating SAS URLs (valid $SasHours hours)..."
$vdaSas = (az storage blob generate-sas `
    --account-name $StorageAccount --account-key $saKey `
    --container-name $Container --name "VDASetup.exe" `
    --permissions r --expiry $expiry --full-uri -o tsv)

$optSas = (az storage blob generate-sas `
    --account-name $StorageAccount --account-key $saKey `
    --container-name $Container --name "CitrixOptimizer.zip" `
    --permissions r --expiry $expiry --full-uri -o tsv)

Write-Host "`n--- Paste these into your .pkrvars.hcl file ---"
Write-Host "vda_location       = `"$vdaSas`""
Write-Host "optimizer_location = `"$optSas`""
Write-Host ""
Write-Host "SAS URLs expire at $expiry UTC — start your Packer build before then."
Write-Host "Re-run this script to generate fresh URLs if needed."
