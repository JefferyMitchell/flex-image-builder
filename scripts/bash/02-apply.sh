#!/usr/bin/env bash
# 02-apply.sh
# Run terraform apply against the chosen example.
# Usage: ./02-apply.sh singlesession-domain-joined
#        ./02-apply.sh singlesession-domain-joined --auto-approve

set -euo pipefail

EXAMPLE="${1:-}"
AUTO_APPROVE="${2:-}"

if [[ -z "$EXAMPLE" ]]; then
    echo "Usage: $0 <example> [--auto-approve]"
    echo "Available examples:"
    echo "  singlesession-domain-joined"
    echo "  multisession-no-domain-join"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_PATH="$SCRIPT_DIR/../../infra/examples/$EXAMPLE"

if [[ ! -d "$EXAMPLE_PATH" ]]; then
    echo "Example not found: $EXAMPLE_PATH"
    exit 1
fi

# Domain join pre-flight reminder
if [[ "$EXAMPLE" == "singlesession-domain-joined" ]]; then
    echo ""
    echo "--- Domain Join Pre-flight Checklist ---"
    echo "Before applying, confirm:"
    echo "  [ ] Service account is NOT locked in AD"
    echo "  [ ] Service account password is NOT expired (set to never expire)"
    echo "  [ ] Cloud Connector (not Connector Appliance) is registered in Citrix Cloud"
    echo "  [ ] TF_VAR_domain_service_account_password is set"
    echo ""

    if [[ "$AUTO_APPROVE" != "--auto-approve" ]]; then
        read -r -p "Pre-flight checks complete? (y/N) " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

echo ""
echo "Running terraform apply for: $EXAMPLE"
echo ""

cd "$EXAMPLE_PATH"

if [[ "$AUTO_APPROVE" == "--auto-approve" ]]; then
    terraform apply -auto-approve
else
    terraform apply
fi
