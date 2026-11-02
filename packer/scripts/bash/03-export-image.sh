#!/usr/bin/env bash
# DEPRECATED: use the PowerShell scripts in packer/scripts/powershell (run with pwsh 7 on macOS/Linux).
# These bash scripts predate the Trusted Launch, gallery and managed-identity changes.
# 03-export-image.sh
# Exports a Packer-built Managed Image to a VHD blob and prints the URI
# for use as vhd_uri in citrix_quickdeploy_template_image.
#
# Usage:
#   ./03-export-image.sh \
#     --resource-group rg-flex-packer-build \
#     --image-name win_server_2025_dc_202506261200 \
#     --storage-account flexpackerbuild \
#     --subscription <id>

set -euo pipefail

RESOURCE_GROUP=""
IMAGE_NAME=""
STORAGE_ACCOUNT=""
SUBSCRIPTION=""
OUTPUT_CONTAINER="vhd-output"

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
        --image-name)       IMAGE_NAME="$2";        shift 2 ;;
        --storage-account)  STORAGE_ACCOUNT="$2";  shift 2 ;;
        --subscription)     SUBSCRIPTION="$2";     shift 2 ;;
        --output-container) OUTPUT_CONTAINER="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$IMAGE_NAME" || -z "$STORAGE_ACCOUNT" || -z "$SUBSCRIPTION" ]]; then
    echo "Usage: $0 --resource-group <rg> --image-name <name> --storage-account <sa> --subscription <id>"
    exit 1
fi

echo ""
echo "Setting subscription..."
az account set --subscription "$SUBSCRIPTION"

echo "Looking up managed image: $IMAGE_NAME..."
DISK_ID=$(az image show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$IMAGE_NAME" \
    --query "storageProfile.osDisk.managedDisk.id" -o tsv)

[[ -n "$DISK_ID" ]] || { echo "Could not find managed disk for image '$IMAGE_NAME'."; exit 1; }

echo "Granting SAS access to disk (24h)..."
SAS=$(az disk grant-access \
    --ids "$DISK_ID" \
    --duration-in-seconds 86400 \
    --query accessSas -o tsv)

SA_KEY=$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].value" -o tsv)

BLOB_NAME="${IMAGE_NAME}.vhd"

echo "Copying VHD to storage account (this takes 5-15 minutes)..."
az storage blob copy start \
    --source-uri "$SAS" \
    --destination-container "$OUTPUT_CONTAINER" \
    --destination-blob "$BLOB_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$SA_KEY" \
    --output none

echo "Waiting for copy to complete..."
while true; do
    STATUS=$(az storage blob show \
        --container-name "$OUTPUT_CONTAINER" \
        --name "$BLOB_NAME" \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$SA_KEY" \
        --query "properties.copy.status" -o tsv)
    echo "  Copy status: $STATUS"
    [[ "$STATUS" == "success" ]] && break
    [[ "$STATUS" == "failed" || "$STATUS" == "aborted" ]] && { echo "Copy failed: $STATUS"; exit 1; }
    sleep 30
done

echo "Revoking disk SAS access..."
az disk revoke-access --ids "$DISK_ID" --output none

VHD_URI=$(az storage blob url \
    --container-name "$OUTPUT_CONTAINER" \
    --name "$BLOB_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$SA_KEY" -o tsv)

echo ""
echo "--- Use this URI in your Terraform vars ---"
echo "vhd_uri = \"$VHD_URI\""
echo ""
echo "Add this to infra/examples/singlesession-custom-image/terraform.tfvars"
