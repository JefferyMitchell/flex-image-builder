# 02-build.ps1
# Runs a Packer build using our patched templates (SAS URL quoting fix applied).
# Clones citrix-packer-tools for the provisioner scripts; uses our template copy.
#
# Usage:
#   .\02-build.ps1 -VarsFile win_server_2025.json -Os win_server_2025_dc -VdaVersion v2507
#
# OS options: win_server_2025_dc, win_server_2022_dc, win_server_2019_dc,
#             win_desktop_11_23h2, win_office_11_23h2
# VDA version options: v2407, v2411, v2503, v2507

param(
    [Parameter(Mandatory)]
    [string]$VarsFile,

    [Parameter(Mandatory)]
    [ValidateSet("win_desktop_11_23h2","win_office_11_23h2","win_server_11_23h2",
                 "win_server_2019_dc","win_server_2022_dc","win_server_2025_dc")]
    [string]$Os,

    [ValidateSet("v2407","v2411","v2503","v2507")]
    [string]$VdaVersion = "v2507",

    # CIDR allowed to reach the build VM's WinRM port (e.g. your egress IP as x.x.x.x/32).
    # Overrides allowed_inbound_ip in the vars file. Without either, the build stops:
    # Packer would otherwise open WinRM on the build VM to the whole internet.
    [string]$AllowedInboundIp,

    # Leave the build VM and its resources in place if the build fails (packer -on-error=abort),
    # so you can troubleshoot it. See "A build fails or hangs" in docs/troubleshooting.md.
    [switch]$KeepOnError
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..\..\..")

# Resolve vars file path
$varsFilePath = $VarsFile
if (-not [System.IO.Path]::IsPathRooted($VarsFile)) {
    $varsFilePath = Join-Path $repoRoot "packer\variables\$VarsFile"
}
if (-not (Test-Path $varsFilePath)) {
    Write-Error "Vars file not found: $varsFilePath"
}

# Auth: with use_azure_cli_auth (the default) Packer runs as your az CLI sign-in.
$vars = Get-Content $varsFilePath -Raw | ConvertFrom-Json
if ("$($vars.use_azure_cli_auth)" -ne "false") {
    $account = (az account show --query "{user:user.name, sub:name}" -o json 2>$null) | ConvertFrom-Json
    if (-not $account) { Write-Error "use_azure_cli_auth is on but az is not signed in. Run 'az login' first." }
    Write-Host "Packer will authenticate as $($account.user) (subscription: $($account.sub))."
}

# Network: the build VM has a public IP for WinRM. Restrict who can reach it.
if (-not $AllowedInboundIp) { $AllowedInboundIp = "$($vars.allowed_inbound_ip)" }
if (-not $AllowedInboundIp -or $AllowedInboundIp -like "<*") {
    Write-Error ("Set -AllowedInboundIp (or allowed_inbound_ip in the vars file) to the CIDR your traffic leaves from, " +
                 "e.g. 203.0.113.10/32. Find it with: Invoke-RestMethod https://api.ipify.org (or ask your network team). " +
                 "Use 0.0.0.0/0 only if you accept WinRM being reachable from anywhere during the build.")
}
Write-Host "WinRM on the build VM will accept connections only from $AllowedInboundIp."

# Clone citrix-packer-tools if not present (needed for provisioner scripts)
$packerToolsDir = Join-Path $repoRoot "citrix-packer-tools"
if (-not (Test-Path $packerToolsDir)) {
    Write-Host "Cloning citrix-packer-tools..."
    git clone https://github.com/citrix/citrix-packer-tools.git $packerToolsDir
} else {
    Write-Host "citrix-packer-tools already present, pulling latest..."
    git -C $packerToolsDir pull
}

# Use our patched template (fixes SAS URL quoting for PowerShell inline provisioners)
$patchedTemplate = Join-Path $repoRoot "packer\templates\${Os}_packer_template.json"
if (-not (Test-Path $patchedTemplate)) {
    Write-Error "Patched template not found: $patchedTemplate`nAvailable patched templates: win_server_2025_dc, win_desktop_11_23h2"
}

# The template references OS-version-specific scripts via relative paths (./ and ../scripts/)
# so we must run packer from the citrix-packer-tools version directory, with our template file
$versionDir = Join-Path $packerToolsDir "azure\$VdaVersion"

Write-Host "`nEnsuring Packer Azure plugin is installed..."
packer plugins install github.com/hashicorp/azure

Write-Host "`nRunning Packer build..."
Write-Host "  Template : $patchedTemplate"
Write-Host "  Scripts  : $versionDir"
Write-Host "  Vars     : $varsFilePath"
Write-Host ""

Push-Location $versionDir
try {
    $onError = if ($KeepOnError) { "-on-error=abort" } else { "-on-error=cleanup" }
    if ($KeepOnError) {
        Write-Host "KeepOnError: on failure the build VM (pkrvm*) and its resources stay in the build resource group."
        Write-Host "Troubleshoot, then clean up: see 'A build fails or hangs' in docs/troubleshooting.md."
    }
    packer build $onError -var-file="$varsFilePath" -var "allowed_inbound_ip=$AllowedInboundIp" "$patchedTemplate"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

Write-Host "`nBuild complete. Run 04-export-from-gallery.ps1 to export the OS VHD (+ VMGS) and get the SAS URIs for Terraform."
