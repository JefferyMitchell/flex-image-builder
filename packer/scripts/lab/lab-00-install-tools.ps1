# lab-00-install-tools.ps1
# Installs the tools the image pipeline needs, skips any already present, and reports their versions.
# See docs/lab-environment.md.
#
# Runs in Windows PowerShell 5.1 as well as PowerShell 7, because PowerShell 7 may be what's missing.
# On macOS and Linux it installs nothing: it reports what's missing and how to install it.
#
# Usage:
#   .\lab-00-install-tools.ps1 -WhatIf     # show what would be installed
#   .\lab-00-install-tools.ps1

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Continue"

$tools = @(
    @{ Name = "PowerShell 7"; Command = "pwsh";      VersionArgs = @("--version"); Winget = "Microsoft.PowerShell";       Brew = "brew install powershell/tap/powershell" }
    @{ Name = "Azure CLI";    Command = "az";        VersionArgs = @("--version"); Winget = "Microsoft.AzureCLI";         Brew = "brew install azure-cli" }
    @{ Name = "Packer";       Command = "packer";    VersionArgs = @("version");   Winget = "Hashicorp.Packer";           Brew = "brew install hashicorp/tap/packer" }
    @{ Name = "Git";          Command = "git";       VersionArgs = @("--version"); Winget = "Git.Git";                    Brew = "brew install git" }
    @{ Name = "AzCopy v10";   Command = "azcopy";    VersionArgs = @("--version"); Winget = "Microsoft.Azure.AZCopy.10";  Brew = "brew install azcopy" }
    @{ Name = "Terraform";    Command = "terraform"; VersionArgs = @("version");   Winget = "Hashicorp.Terraform";        Brew = "brew install terraform" }
)

function Test-Tool([string]$Command) { [bool](Get-Command $Command -ErrorAction SilentlyContinue) }

$isWindowsHost = $env:OS -eq "Windows_NT"
$missing = @($tools | Where-Object { -not (Test-Tool $_.Command) })

if ($missing.Count -and -not $isWindowsHost) {
    Write-Host "Missing tools. Install them with:"
    $missing | ForEach-Object { Write-Host "  $($_.Brew)" }
} elseif ($missing.Count) {
    if (-not (Test-Tool "winget")) {
        throw "winget isn't available. Install App Installer from the Microsoft Store, or install the tools by hand (see docs/lab-environment.md)."
    }
    foreach ($tool in $missing) {
        if ($PSCmdlet.ShouldProcess($tool.Name, "Install with winget ($($tool.Winget))")) {
            Write-Host "Installing $($tool.Name)..."
            & winget install --id $tool.Winget --exact --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { Write-Warning "winget returned $LASTEXITCODE for $($tool.Name)." }
        }
    }
    # Pick up PATH changes from the installers, without needing a new terminal.
    $env:Path = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine")
        [Environment]::GetEnvironmentVariable("Path", "User")
    ) -join ";"
}

Write-Host "`nTools:"
$stillMissing = 0
foreach ($tool in $tools) {
    if (Test-Tool $tool.Command) {
        $version = "$(& $tool.Command @($tool.VersionArgs) 2>$null | Select-Object -First 1)".Trim()
        Write-Host ("  {0,-14} {1}" -f $tool.Name, $version)
    } else {
        Write-Host ("  {0,-14} MISSING" -f $tool.Name)
        $stillMissing++
    }
}

if ($stillMissing -and -not $WhatIfPreference) {
    Write-Host "`n$stillMissing tool(s) still missing. If you just installed them, open a new terminal and run this again."
    exit 1
}
Write-Host "`nNext: run lab-01-check-prereqs.ps1 under PowerShell 7."
exit 0
