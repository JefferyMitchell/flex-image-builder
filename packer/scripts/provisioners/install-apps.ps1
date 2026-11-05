# install-apps.ps1 — runs on the build VM (02-build.ps1 adds it when you pass -AppsFile).
# Installs the Chocolatey packages listed in c:\setup\apps.txt: one package ID per line, '#' starts a
# comment, and "id version" pins a version (e.g. "7zip 24.9.0").
#
# Why Chocolatey, not winget: winget's community source fails to initialize in unattended WinRM
# sessions (0x8a15000f "Data required by the source is missing"), even after an App Installer bootstrap.
#
# Environment (set by 02-build.ps1): CHOCO_VERSION, CHOCO_MSI_URL and CHOCO_MSI_SHA256 identify the
# Chocolatey release MSI to install; CHOCO_SOURCE is an optional internal feed, used instead of the
# community source.
$ErrorActionPreference = 'Stop'
$manifest = 'c:\setup\apps.txt'
if (-not (Test-Path $manifest)) { throw "App list not found: $manifest" }

# The Chocolatey MSI must match its pinned SHA-256 and carry a valid Chocolatey Software signature.
function Assert-ChocoMsi([string]$Path, [string]$ExpectedSha256) {
    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "CHOCO_MSI_SHA256 isn't a SHA-256 hash." }
    $actual = (Get-FileHash $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for the Chocolatey MSI: expected $ExpectedSha256, got $actual. Not installing it."
    }
    $sig = Get-AuthenticodeSignature $Path
    if ($sig.Status -ne 'Valid') { throw "The Chocolatey MSI's signature isn't valid ($($sig.Status)). Not installing it." }
    # Windows quotes values that contain commas: O="Chocolatey Software, Inc"
    if ($sig.SignerCertificate.Subject -notmatch '(^|, )O="?Chocolatey Software, Inc"?(,|$)') {
        throw "The Chocolatey MSI is signed by '$($sig.SignerCertificate.Subject)', not Chocolatey Software. Not installing it."
    }
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Downloading Chocolatey $env:CHOCO_VERSION from $env:CHOCO_MSI_URL..."
    $ProgressPreference = 'SilentlyContinue'
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    $msi = Join-Path $env:TEMP "chocolatey-$env:CHOCO_VERSION.msi"
    Invoke-WebRequest -Uri $env:CHOCO_MSI_URL -OutFile $msi -UseBasicParsing
    Assert-ChocoMsi $msi $env:CHOCO_MSI_SHA256
    Write-Host "Chocolatey MSI verified (SHA-256 and signature). Installing..."
    $install = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
    if (@(0, 3010) -notcontains $install.ExitCode) { throw "Chocolatey MSI install failed (exit $($install.ExitCode))" }
    Remove-Item $msi
    $env:Path = "$env:Path;$env:ProgramData\chocolatey\bin"
}
if ($env:CHOCO_SOURCE) {
    & choco source add --name internal --source $env:CHOCO_SOURCE --priority 1 --limit-output
    & choco source disable --name chocolatey --limit-output
    Write-Host "Package source: $env:CHOCO_SOURCE (community source disabled)"
}

$ok = @(0, 1641, 3010)   # success, reboot initiated, reboot required
foreach ($line in Get-Content $manifest) {
    $entry = ($line -split '#')[0].Trim()
    if (-not $entry) { continue }
    $id, $version = $entry -split '\s+', 2
    $chocoArgs = @('install', $id, '-y', '--no-progress', '--limit-output')
    if ($version) { $chocoArgs += @('--version', $version) }
    Write-Host "choco install $entry"
    & choco @chocoArgs
    if ($ok -notcontains $LASTEXITCODE) { throw "choco install failed for $id (exit $LASTEXITCODE)" }
}

# One line per installed package ("id|version"), for the build log.
& choco list --limit-output | ForEach-Object { Write-Host "installed-app: $_" }
Write-Host 'App stage complete.'
