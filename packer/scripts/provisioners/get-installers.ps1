# get-installers.ps1 — runs on the build VM, before the VDA install.
# Downloads the VDA installer and the Citrix Optimizer from your storage account with the build VM's
# managed identity, then verifies them. Any failure stops the build before anything is installed:
#  - both files' SHA-256 must match the vars file (vda_sha256, optimizer_sha256; 01-upload-installers.ps1 prints them);
#  - the VDA installer's Authenticode signature must be Valid, from the organization in vda_signer;
#  - optimizer_template must exist in the Optimizer zip (otherwise the Optimizer step silently does nothing).
# The "build-input:" and "build-vm:" lines it prints go into the build record (02-build.ps1).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail([string]$Message) { $host.UI.WriteErrorLine("ERROR: $Message"); exit 1 }

$token = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/' -Headers @{ Metadata = 'true' }).access_token

function Get-Blob([string]$Url, [string]$Path) {
    # curl.exe (built into Windows) instead of Invoke-WebRequest, which was slow for the 1.4 GB VDA installer.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & curl.exe --fail --silent --show-error --location --retry 3 -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08" -o $Path $Url
    if ($LASTEXITCODE -ne 0) { Fail "Download failed (curl exit $LASTEXITCODE): $Url" }
    $sw.Stop()
    $mb = (Get-Item $Path).Length / 1MB
    Write-Host ("download: {0} {1:N0} MB in {2:N0} s ({3:N1} MB/s)" -f (Split-Path $Url -Leaf), $mb, $sw.Elapsed.TotalSeconds, ($mb / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)))
}

function Assert-Sha256([string]$Path, [string]$Expected, [string]$VarName) {
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { Fail "$VarName isn't set to a SHA-256 hash. 01-upload-installers.ps1 prints it." }
    $actual = (Get-FileHash $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) {
        Fail "SHA-256 mismatch for $(Split-Path $Path -Leaf): expected $Expected, got $actual. Re-upload with 01-upload-installers.ps1 and update $VarName."
    }
    $actual
}

Write-Host "Downloading installers via managed identity..."
Get-Blob $env:VDA_URL $env:VDA_PATH
Get-Blob $env:OPTIMIZER_URL $env:OPTIMIZER_PATH

$vdaHash = Assert-Sha256 $env:VDA_PATH $env:VDA_SHA256 'vda_sha256'
$optHash = Assert-Sha256 $env:OPTIMIZER_PATH $env:OPTIMIZER_SHA256 'optimizer_sha256'

$sig = Get-AuthenticodeSignature $env:VDA_PATH
$subject = "$($sig.SignerCertificate.Subject)"
if ($sig.Status -ne 'Valid') { Fail "The VDA installer's signature isn't valid ($($sig.Status)): $($sig.StatusMessage)" }
# Windows quotes values that contain commas: O="Citrix Systems, Inc."
if ($subject -notmatch ('(^|, )O="?' + [regex]::Escape($env:VDA_SIGNER) + '"?(,|$)')) {
    Fail "The VDA installer is signed by '$subject', not by O=$env:VDA_SIGNER (vda_signer)."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($env:OPTIMIZER_PATH)
$templates = @($zip.Entries | Where-Object { $_.FullName -match '^Templates[\\/][^\\/]+\.xml$' } | ForEach-Object { $_.Name })
$zip.Dispose()
if ($templates -notcontains $env:OPTIMIZER_TEMPLATE) {
    Fail "optimizer_template '$env:OPTIMIZER_TEMPLATE' is not in the Citrix Optimizer zip, so the image would not be optimized. Templates in this zip: $($templates -join ', ')"
}

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$secureBoot = 'unsupported'
try { $secureBoot = Confirm-SecureBootUEFI } catch { }
$tpm = 'unknown'
try { $t = Get-Tpm; $tpm = "$($t.TpmPresent)/$($t.TpmReady)" } catch { }
# signer goes last: the subject contains spaces, commas and (on Windows) quotes.
Write-Host "build-input: vda=$(Split-Path $env:VDA_URL -Leaf) sha256=$vdaHash thumbprint=$($sig.SignerCertificate.Thumbprint) signer=$subject"
Write-Host "build-input: optimizer=$(Split-Path $env:OPTIMIZER_URL -Leaf) sha256=$optHash template=$env:OPTIMIZER_TEMPLATE"
Write-Host "build-vm: os=`"$($cv.ProductName)`" build=$($cv.CurrentBuildNumber).$($cv.UBR) secureboot=$secureBoot tpm=$tpm"
Write-Host "Installers verified."
