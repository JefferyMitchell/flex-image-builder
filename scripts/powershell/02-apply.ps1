# 02-apply.ps1
# Run terraform apply against the chosen example.
# Usage: .\02-apply.ps1 -Example singlesession-domain-joined

param(
    [Parameter(Mandatory)]
    [ValidateSet("singlesession-domain-joined", "multisession-no-domain-join")]
    [string]$Example,

    [switch]$AutoApprove
)

$examplePath = Join-Path $PSScriptRoot "..\..\infra\examples\$Example"

if (-not (Test-Path $examplePath)) {
    Write-Error "Example not found: $examplePath"
    exit 1
}

# Domain join pre-flight reminder
if ($Example -eq "singlesession-domain-joined") {
    Write-Host "`n--- Domain Join Pre-flight Checklist ---"
    Write-Host "Before applying, confirm:"
    Write-Host "  [ ] Service account is NOT locked in AD"
    Write-Host "  [ ] Service account password is NOT expired (set to never expire)"
    Write-Host "  [ ] Cloud Connector (not Connector Appliance) is registered in Citrix Cloud"
    Write-Host "  [ ] TF_VAR_domain_service_account_password is set`n"

    if (-not $AutoApprove) {
        $confirm = Read-Host "Pre-flight checks complete? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Host "Aborted."
            exit 0
        }
    }
}

Write-Host "`nRunning terraform apply for: $Example`n"

Push-Location $examplePath
try {
    $applyArgs = @()
    if ($AutoApprove) { $applyArgs += "-auto-approve" }

    terraform apply @applyArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
