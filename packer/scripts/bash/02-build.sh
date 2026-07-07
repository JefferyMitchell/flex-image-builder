#!/usr/bin/env bash
# 02-build.sh
# Clones citrix-packer-tools and runs a Packer build.
# Usage: ./02-build.sh --vars-file win_server_2025.pkrvars.hcl --os win_server_2025_dc [--vda-version v2507]

set -euo pipefail

VARS_FILE=""
OS_TEMPLATE=""
VDA_VERSION="v2507"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vars-file)    VARS_FILE="$2";    shift 2 ;;
        --os)           OS_TEMPLATE="$2";  shift 2 ;;
        --vda-version)  VDA_VERSION="$2";  shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$VARS_FILE" || -z "$OS_TEMPLATE" ]]; then
    cat <<EOF
Usage: $0 --vars-file <file> --os <os> [--vda-version v2507]

OS options:
  win_desktop_11_23h2  win_office_11_23h2   win_server_11_23h2
  win_server_2019_dc   win_server_2022_dc   win_server_2025_dc

VDA versions: v2407, v2411, v2503, v2507
EOF
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve vars file path
if [[ ! "$VARS_FILE" = /* ]]; then
    VARS_FILE="$SCRIPT_DIR/../../variables/$VARS_FILE"
fi
[[ -f "$VARS_FILE" ]] || { echo "Vars file not found: $VARS_FILE"; exit 1; }

# Clone or update citrix-packer-tools
PACKER_TOOLS_DIR="$SCRIPT_DIR/../../../citrix-packer-tools"
if [[ ! -d "$PACKER_TOOLS_DIR" ]]; then
    echo "Cloning citrix-packer-tools..."
    git clone https://github.com/citrix/citrix-packer-tools.git "$PACKER_TOOLS_DIR"
else
    echo "citrix-packer-tools present, pulling latest..."
    git -C "$PACKER_TOOLS_DIR" pull
fi

TEMPLATE_FILE="$PACKER_TOOLS_DIR/azure/$VDA_VERSION/${OS_TEMPLATE}_packer_template.json"
[[ -f "$TEMPLATE_FILE" ]] || { echo "Template not found: $TEMPLATE_FILE"; exit 1; }

echo ""
echo "Running Packer build..."
echo "  Template : $TEMPLATE_FILE"
echo "  Vars     : $VARS_FILE"
echo ""

packer build -var-file="$VARS_FILE" "$TEMPLATE_FILE"

echo ""
echo "Build complete. Run 03-export-image.sh to get the VHD URI for Terraform."
