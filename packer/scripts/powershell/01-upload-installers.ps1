# 01-upload-installers.ps1
# Uploads VDA installer and Citrix Optimizer to Azure Blob Storage, keeping their file names
# (e.g. VDAServerSetup_2507.exe), so you can always tell which VDA a build used.
# Prints plain blob URLs (no SAS) and each file's SHA-256 to paste into your vars file: the build VM
# checks both hashes, and the VDA installer's signature, before it installs anything.
#
# -ExtraPaths uploads extra installers (agents such as Session Recording or WEM) the same way and prints
# installers-file entries for them (see packer/installers/example.installers.json). Give them versioned
# file names without spaces before uploading (e.g. SessionRecordingAgentx64_2609.msi).
# Each of -VdaPath, -OptimizerPath and -ExtraPaths is optional, so you can upload just a new agent.
#
# Authentication: uses your active az login session (--auth-mode login).
# No account keys or SAS tokens are generated — the Packer build VM downloads
# installers at runtime using its managed identity (see 00-setup-azure.ps1).
#
# Usage:
#   .\01-upload-installers.ps1 `
#     -StorageAccount flexpackerbuild `
#     -VdaPath C:\Downloads\VDAServerSetup_2507.exe `
#     -OptimizerPath C:\Downloads\CitrixOptimizer.zip `
#     -ExtraPaths C:\Downloads\SessionRecordingAgentx64_2609.msi

param(
    [Parameter(Mandatory)] [string]$StorageAccount,
    [string]$VdaPath,
    [string]$OptimizerPath,
    [string[]]$ExtraPaths = @(),
    [string]$Container = "installers"
)

$ErrorActionPreference = "Stop"

# "pwsh -File" (macOS, Linux, CI) passes "-ExtraPaths a,b" as one string: split it, unless it's a real file name.
$ExtraPaths = @($ExtraPaths | ForEach-Object { if ($_ -match ',' -and -not (Test-Path -LiteralPath $_)) { $_ -split ',' } else { $_ } } | Where-Object { $_ })

if (-not $VdaPath -and -not $OptimizerPath -and -not $ExtraPaths) { Write-Error "Nothing to upload: give -VdaPath, -OptimizerPath and/or -ExtraPaths." }
if ($VdaPath -and -not (Test-Path $VdaPath))             { Write-Error "VDA installer not found: $VdaPath" }
if ($OptimizerPath -and -not (Test-Path $OptimizerPath)) { Write-Error "Citrix Optimizer not found: $OptimizerPath" }
foreach ($x in $ExtraPaths) {
    if (-not (Test-Path $x)) { Write-Error "Extra installer not found: $x" }
    $leaf = Split-Path $x -Leaf
    if ([IO.Path]::GetExtension($leaf) -notin '.msi', '.exe') { Write-Error "Extra installers must be .msi or .exe: $leaf" }
    if ($leaf -match '\s') { Write-Error "Rename '$leaf' without spaces (and with its version, e.g. CitrixWEMAgent_2607.exe) before uploading." }
}

function Send-Blob([string]$Path) {
    $name = Split-Path $Path -Leaf
    $hash = (Get-FileHash $Path -Algorithm SHA256).Hash
    Write-Host "Uploading $name..."
    az storage blob upload `
        --account-name $StorageAccount --auth-mode login `
        --container-name $Container `
        --file $Path --name $name --metadata "sha256=$hash" `
        --overwrite --no-progress | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Upload failed for $name (az exit $LASTEXITCODE)." }
    [pscustomobject]@{ Name = $name; Path = $Path; Hash = $hash; Url = "https://$StorageAccount.blob.core.windows.net/$Container/$name" }
}

if ($OptimizerPath) {
    # optimizer_template in the vars file must be one of these exact names; the build stops otherwise.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $OptimizerPath).Path)
    $optimizerTemplates = @($zip.Entries | Where-Object { $_.FullName -match '^Templates[\\/][^\\/]+\.xml$' } | ForEach-Object { $_.Name } | Sort-Object)
    $zip.Dispose()
    if (-not $optimizerTemplates) { Write-Error "No Templates\*.xml found in $OptimizerPath. Is it the Citrix Optimizer zip?" }
}

$vda = if ($VdaPath) { Send-Blob $VdaPath }
$opt = if ($OptimizerPath) { Send-Blob $OptimizerPath }
$extras = @(foreach ($x in $ExtraPaths) { Send-Blob $x })

if ($vda -or $opt) {
    Write-Host "`n--- Paste these into your vars file ---"
    if ($vda) {
        Write-Host "vda_blob_url       = `"$($vda.Url)`""
        Write-Host "vda_sha256         = `"$($vda.Hash)`""
    }
    if ($opt) {
        Write-Host "optimizer_blob_url = `"$($opt.Url)`""
        Write-Host "optimizer_sha256   = `"$($opt.Hash)`""
        Write-Host "optimizer_template = one of these, exactly as written:"
        $optimizerTemplates | ForEach-Object { Write-Host "  $_" }
    }
}
if ($extras) {
    Write-Host "`n--- Installers-file entries (02-build.ps1 -InstallersFile); add name, and windows_features/arguments as needed ---"
    foreach ($x in $extras) {
        # The signer's organization, where this machine can read Authenticode (Windows). Elsewhere, fill it in.
        $signer = '<organization the signature must come from>'
        if (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue) {
            $s = "$((Get-AuthenticodeSignature $x.Path).SignerCertificate.Subject)"
            # Windows quotes values that contain commas: O="Citrix Systems, Inc."
            if ($s -match '(^|, )O=("([^"]+)"|([^,]+))') { $signer = "$($Matches[3])$($Matches[4])" }
        }
        $entry = [ordered]@{ name = "<name>"; blob_url = $x.Url; sha256 = $x.Hash; signer = $signer }
        Write-Host ($entry | ConvertTo-Json)
    }
}
Write-Host ""
Write-Host "No expiry — the Packer build VM authenticates via managed identity at runtime."
