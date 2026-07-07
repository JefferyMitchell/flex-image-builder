#!/usr/bin/env bash
# 01-upload-installers.sh
# Uploads VDA installer and Citrix Optimizer, prints SAS URLs for pkrvars.
# Usage: ./01-upload-installers.sh --storage-account <name> --vda-path /path/to/VDASetup.exe --optimizer-path /path/to/CitrixOptimizer.zip

set -euo pipefail

STORAGE_ACCOUNT=""
RESOURCE_GROUP="rg-flex-packer-build"
CONTAINER="installers"
VDA_PATH=""
OPTIMIZER_PATH=""
SAS_HOURS=4

while [[ $# -gt 0 ]]; do
    case $1 in
        --storage-account)  STORAGE_ACCOUNT="$2";  shift 2 ;;
        --resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
        --vda-path)         VDA_PATH="$2";         shift 2 ;;
        --optimizer-path)   OPTIMIZER_PATH="$2";   shift 2 ;;
        --sas-hours)        SAS_HOURS="$2";        shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$STORAGE_ACCOUNT" || -z "$VDA_PATH" || -z "$OPTIMIZER_PATH" ]]; then
    echo "Usage: $0 --storage-account <name> --vda-path <path> --optimizer-path <path>"
    exit 1
fi

[[ -f "$VDA_PATH" ]]       || { echo "VDA installer not found: $VDA_PATH"; exit 1; }
[[ -f "$OPTIMIZER_PATH" ]] || { echo "Citrix Optimizer not found: $OPTIMIZER_PATH"; exit 1; }

SA_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query "[0].value" -o tsv)
EXPIRY=$(date -u -d "+${SAS_HOURS} hours" +"%Y-%m-%dT%H:%MZ" 2>/dev/null || date -u -v+${SAS_HOURS}H +"%Y-%m-%dT%H:%MZ")

echo ""
echo "Uploading VDA installer..."
az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" --account-key "$SA_KEY" \
    --container-name "$CONTAINER" \
    --file "$VDA_PATH" --name "VDASetup.exe" \
    --overwrite --output none

echo "Uploading Citrix Optimizer..."
az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" --account-key "$SA_KEY" \
    --container-name "$CONTAINER" \
    --file "$OPTIMIZER_PATH" --name "CitrixOptimizer.zip" \
    --overwrite --output none

echo "Generating SAS URLs (valid ${SAS_HOURS}h)..."
VDA_SAS=$(az storage blob generate-sas \
    --account-name "$STORAGE_ACCOUNT" --account-key "$SA_KEY" \
    --container-name "$CONTAINER" --name "VDASetup.exe" \
    --permissions r --expiry "$EXPIRY" --full-uri -o tsv)

OPT_SAS=$(az storage blob generate-sas \
    --account-name "$STORAGE_ACCOUNT" --account-key "$SA_KEY" \
    --container-name "$CONTAINER" --name "CitrixOptimizer.zip" \
    --permissions r --expiry "$EXPIRY" --full-uri -o tsv)

echo ""
echo "--- Paste these into your .pkrvars.hcl file ---"
echo "vda_location       = \"$VDA_SAS\""
echo "optimizer_location = \"$OPT_SAS\""
echo ""
echo "SAS URLs expire at $EXPIRY UTC — start your Packer build before then."
