# install-apps.ps1 — runs on the build VM (02-build.ps1 adds it when you pass -AppsFile).
# Installs the Chocolatey packages listed in c:\setup\apps.txt: one package ID per line, '#' starts a
# comment, and "id version" pins a version (e.g. "7zip 24.9.0").
#
# Why Chocolatey, not winget: winget's community source fails to initialize in unattended WinRM
# sessions (0x8a15000f "Data required by the source is missing"), even after an App Installer bootstrap.
#
# Environment (set by 02-build.ps1): CHOCO_VERSION is the Chocolatey CLI version to bootstrap;
# CHOCO_SOURCE is an optional internal feed, used instead of the community source.
$ErrorActionPreference = 'Stop'
$manifest = 'c:\setup\apps.txt'
if (-not (Test-Path $manifest)) { throw "App list not found: $manifest" }

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Bootstrapping Chocolatey $env:CHOCO_VERSION..."
    $env:chocolateyVersion = $env:CHOCO_VERSION
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
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
