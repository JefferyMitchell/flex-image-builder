# 00-prerequisites.ps1
# Verify required tools and environment variables are in place before deploying.

$errors = 0

Write-Host "`nChecking prerequisites...`n"

# Terraform
if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $tfVersion = (terraform version -json | ConvertFrom-Json).terraform_version
    Write-Host "  [OK] Terraform $tfVersion"
} else {
    Write-Host "  [MISSING] Terraform not found. Install: winget install HashiCorp.Terraform"
    $errors++
}

# Git
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "  [OK] git $(git --version)"
} else {
    Write-Host "  [MISSING] git not found."
    $errors++
}

# Environment variables
$required = @(
    "CITRIX_CLIENT_SECRET",
    "TF_VAR_citrix_client_secret"
)
foreach ($var in $required) {
    if ([System.Environment]::GetEnvironmentVariable($var)) {
        Write-Host "  [OK] $var is set"
    } else {
        Write-Host "  [MISSING] $var is not set"
        $errors++
    }
}

# Domain join password (optional — only required for domain-joined catalogs)
if ([System.Environment]::GetEnvironmentVariable("TF_VAR_domain_service_account_password")) {
    Write-Host "  [OK] TF_VAR_domain_service_account_password is set"
} else {
    Write-Host "  [WARN] TF_VAR_domain_service_account_password is not set (required for domain-joined catalogs)"
}

Write-Host ""
if ($errors -gt 0) {
    Write-Host "$errors prerequisite(s) missing. Resolve before continuing.`n"
    exit 1
} else {
    Write-Host "All prerequisites met.`n"
}
