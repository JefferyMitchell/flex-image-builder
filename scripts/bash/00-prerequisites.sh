#!/usr/bin/env bash
# 00-prerequisites.sh
# Verify required tools and environment variables are in place before deploying.

set -euo pipefail

errors=0

echo ""
echo "Checking prerequisites..."
echo ""

# Terraform
if command -v terraform &>/dev/null; then
    tf_version=$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])")
    echo "  [OK] Terraform $tf_version"
else
    echo "  [MISSING] Terraform not found. Install: https://developer.hashicorp.com/terraform/install"
    errors=$((errors + 1))
fi

# Git
if command -v git &>/dev/null; then
    echo "  [OK] $(git --version)"
else
    echo "  [MISSING] git not found."
    errors=$((errors + 1))
fi

# Environment variables
for var in CITRIX_CLIENT_SECRET TF_VAR_citrix_client_secret; do
    if [[ -n "${!var:-}" ]]; then
        echo "  [OK] $var is set"
    else
        echo "  [MISSING] $var is not set"
        errors=$((errors + 1))
    fi
done

# Domain join password (optional)
if [[ -n "${TF_VAR_domain_service_account_password:-}" ]]; then
    echo "  [OK] TF_VAR_domain_service_account_password is set"
else
    echo "  [WARN] TF_VAR_domain_service_account_password is not set (required for domain-joined catalogs)"
fi

echo ""
if [[ $errors -gt 0 ]]; then
    echo "$errors prerequisite(s) missing. Resolve before continuing."
    echo ""
    exit 1
else
    echo "All prerequisites met."
    echo ""
fi
