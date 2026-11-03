# 01-upload-installers.ps1
# Uploads VDA installer and Citrix Optimizer to Azure Blob Storage, keeping their file names
# (e.g. VDAServerSetup_2507.exe), so you can always tell which VDA a build used.
# Prints plain blob URLs (no SAS) and each file's SHA-256 to paste into your vars file: the build VM
# checks both hashes, and the VDA installer's signature, before it installs anything.
#
# Authentication: uses your active az login session (--auth-mode login).
# No account keys or SAS tokens are generated — the Packer build VM downloads
# installers at runtime using its managed identity (see 00-setup-azure.ps1).
#
# Usage:
#   .\01-upload-installers.ps1 `
#     -StorageAccount flexpackerbuild `
#     -VdaPath C:\Downloads\VDAServerSetup_2507.exe `
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

# optimizer_template in the vars file must be one of these exact names; the build stops otherwise.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $OptimizerPath).Path)
$optimizerTemplates = @($zip.Entries | Where-Object { $_.FullName -match '^Templates[\\/][^\\/]+\.xml$' } | ForEach-Object { $_.Name } | Sort-Object)
$zip.Dispose()
if (-not $optimizerTemplates) { Write-Error "No Templates\*.xml found in $OptimizerPath. Is it the Citrix Optimizer zip?" }

$vdaName = Split-Path $VdaPath -Leaf
$optName = Split-Path $OptimizerPath -Leaf
$vdaHash = (Get-FileHash $VdaPath -Algorithm SHA256).Hash
$optHash = (Get-FileHash $OptimizerPath -Algorithm SHA256).Hash

Write-Host "`nUploading VDA installer ($vdaName)..."
az storage blob upload `
    --account-name $StorageAccount --auth-mode login `
    --container-name $Container `
    --file $VdaPath --name $vdaName --metadata "sha256=$vdaHash" `
    --overwrite --no-progress | Out-Null

Write-Host "Uploading Citrix Optimizer ($optName)..."
az storage blob upload `
    --account-name $StorageAccount --auth-mode login `
    --container-name $Container `
    --file $OptimizerPath --name $optName --metadata "sha256=$optHash" `
    --overwrite --no-progress | Out-Null

$vdaUrl = "https://$StorageAccount.blob.core.windows.net/$Container/$vdaName"
$optUrl = "https://$StorageAccount.blob.core.windows.net/$Container/$optName"

Write-Host "`n--- Paste these into your vars file ---"
Write-Host "vda_blob_url       = `"$vdaUrl`""
Write-Host "vda_sha256         = `"$vdaHash`""
Write-Host "optimizer_blob_url = `"$optUrl`""
Write-Host "optimizer_sha256   = `"$optHash`""
Write-Host "optimizer_template = one of these, exactly as written:"
$optimizerTemplates | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "No expiry — the Packer build VM authenticates via managed identity at runtime."
