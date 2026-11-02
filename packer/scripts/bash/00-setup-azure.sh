#!/usr/bin/env bash
# DEPRECATED: use the PowerShell scripts in packer/scripts/powershell (run with pwsh 7 on macOS/Linux).
# These bash scripts predate the Trusted Launch, gallery and managed-identity changes.
# 00-setup-azure.sh
# Creates Azure prerequisites for a Packer build.
# Usage: ./00-setup-azure.sh --subscription <id> [--location eastus] [--prefix flex-packer]

set -euo pipefail

SUBSCRIPTION=""
LOCATION="eastus"
PREFIX="flex-packer"

while [[ $# -gt 0 ]]; do
    case $1 in
        --subscription) SUBSCRIPTION="$2"; shift 2 ;;
        --location)     LOCATION="$2";     shift 2 ;;
        --prefix)       PREFIX="$2";       shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$SUBSCRIPTION" ]]; then
    echo "Usage: $0 --subscription <id> [--location eastus] [--prefix flex-packer]"
    exit 1
fi

RG="rg-${PREFIX}-build"
SA=$(echo "${PREFIX}build" | tr -d '-' | cut -c1-24)
SP_NAME="sp-${PREFIX}-build"

echo ""
echo "Setting subscription to $SUBSCRIPTION..."
az account set --subscription "$SUBSCRIPTION"

echo "Creating resource group: $RG..."
az group create --name "$RG" --location "$LOCATION" --output none

echo "Creating storage account: $SA..."
az storage account create \
    --name "$SA" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --allow-blob-public-access false \
    --output none

SA_KEY=$(az storage account keys list --account-name "$SA" --resource-group "$RG" --query "[0].value" -o tsv)

echo "Creating storage containers..."
az storage container create --name "installers" --account-name "$SA" --account-key "$SA_KEY" --output none
az storage container create --name "vhd-output" --account-name "$SA" --account-key "$SA_KEY" --output none

echo "Creating service principal: $SP_NAME..."
RG_ID=$(az group show --name "$RG" --query id -o tsv)
SP=$(az ad sp create-for-rbac --name "$SP_NAME" --role Contributor --scopes "$RG_ID" --output json)

APP_ID=$(echo "$SP" | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")
SECRET=$(echo "$SP"  | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
TENANT=$(echo "$SP"  | python3 -c "import sys,json; print(json.load(sys.stdin)['tenant'])")

SA_ID=$(az storage account show --name "$SA" --resource-group "$RG" --query id -o tsv)
az role assignment create \
    --assignee "$APP_ID" \
    --role "Storage Blob Data Reader" \
    --scope "$SA_ID" \
    --output none

OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

echo ""
echo "--- Copy these values into your .pkrvars.hcl file ---"
echo "client_id              = \"$APP_ID\""
echo "client_secret          = \"$SECRET\""
echo "client_object_id       = \"$OBJECT_ID\""
echo "client_tenant_id       = \"$TENANT\""
echo "client_subscription_id = \"$SUBSCRIPTION\""
echo "image_resource_group   = \"$RG\""
echo ""
echo "Storage account: $SA"
echo "Run 01-upload-installers.sh next."
