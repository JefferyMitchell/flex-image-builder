#!/usr/bin/env bash
# 01-plan.sh
# Run terraform plan against the chosen example.
# Usage: ./01-plan.sh singlesession-domain-joined

set -euo pipefail

EXAMPLE="${1:-}"

if [[ -z "$EXAMPLE" ]]; then
    echo "Usage: $0 <example>"
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

echo ""
echo "Running terraform plan for: $EXAMPLE"
echo ""

cd "$EXAMPLE_PATH"
terraform init -upgrade
terraform plan
