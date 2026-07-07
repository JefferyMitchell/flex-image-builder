# 02-build.ps1
# Clones citrix-packer-tools (if needed) and runs a Packer build.
#
# Usage:
#   .\02-build.ps1 -VarsFile win_server_2025.pkrvars.hcl -Os win_server_2025_dc -VdaVersion v2507
#
# OS options (match citrix-packer-tools template names):
#   win_desktop_11_23h2, win_office_11_23h2, win_server_11_23h2,
#   win_server_2019_dc,  win_server_2022_dc,  win_server_2025_dc
#
# VDA version options: v2407, v2411, v2503, v2507

param(
    [Parameter(Mandatory)]
    [string]$VarsFile,

    [Parameter(Mandatory)]
    [ValidateSet("win_desktop_11_23h2","win_office_11_23h2","win_server_11_23h2",
                 "win_server_2019_dc","win_server_2022_dc","win_server_2025_dc")]
    [string]$Os,

    [ValidateSet("v2407","v2411","v2503","v2507")]
    [string]$VdaVersion = "v2507"
)

$ErrorActionPreference = "Stop"

# Resolve vars file path
$scriptDir = $PSScriptRoot
$varsFilePath = $VarsFile
if (-not [System.IO.Path]::IsPathRooted($VarsFile)) {
    $varsFilePath = Join-Path (Join-Path $scriptDir "..\..\variables") $VarsFile
}
if (-not (Test-Path $varsFilePath)) {
    Write-Error "Vars file not found: $varsFilePath"
}

# Clone citrix-packer-tools if not present
$packerToolsDir = Join-Path $scriptDir "..\..\..\citrix-packer-tools"
if (-not (Test-Path $packerToolsDir)) {
    Write-Host "Cloning citrix-packer-tools..."
    git clone https://github.com/citrix/citrix-packer-tools.git $packerToolsDir
} else {
    Write-Host "citrix-packer-tools already present, pulling latest..."
    git -C $packerToolsDir pull
}

$templateDir  = Join-Path $packerToolsDir "azure\$VdaVersion"
$templateFile = Join-Path $templateDir "${Os}_packer_template.json"

if (-not (Test-Path $templateFile)) {
    Write-Error "Template not found: $templateFile`nCheck -Os and -VdaVersion values."
}

Write-Host "`nRunning Packer build..."
Write-Host "  Template : $templateFile"
Write-Host "  Vars     : $varsFilePath"
Write-Host ""

packer build -var-file="$varsFilePath" "$templateFile"

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`nBuild complete. Run 03-export-image.ps1 to get the VHD URI for Terraform."
