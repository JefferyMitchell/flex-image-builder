# 01-plan.ps1
# Run terraform plan against the chosen example.
# Usage: .\01-plan.ps1 -Example singlesession-domain-joined

param(
    [Parameter(Mandatory)]
    [ValidateSet("singlesession-domain-joined", "multisession-no-domain-join")]
    [string]$Example
)

$examplePath = Join-Path $PSScriptRoot "..\..\infra\examples\$Example"

if (-not (Test-Path $examplePath)) {
    Write-Error "Example not found: $examplePath"
    exit 1
}

Write-Host "`nRunning terraform plan for: $Example`n"

Push-Location $examplePath
try {
    terraform init -upgrade
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    terraform plan
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
