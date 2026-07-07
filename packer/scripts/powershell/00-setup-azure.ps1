# 00-setup-azure.ps1
# Creates the Azure prerequisites for a Packer build:
#   - Resource group
#   - Storage account + containers (installers, vhd-output)
#   - Service principal with scoped Contributor role
#
# Prerequisites: az CLI logged in (az login), correct subscription set.
# Usage: .\00-setup-azure.ps1 -SubscriptionId <id> -Location eastus -Prefix flex-packer

param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$Location  = "eastus",
    [string]$Prefix    = "flex-packer",
    [string]$SpName    = "sp-$Prefix-build"
)

$ErrorActionPreference = "Stop"

$rg      = "rg-$Prefix-build"
$sa      = ($Prefix -replace "-","") + "build"   # storage accounts: lowercase, no hyphens
$sa      = $sa.Substring(0, [Math]::Min($sa.Length, 24))

Write-Host "`nSetting subscription to $SubscriptionId..."
az account set --subscription $SubscriptionId

Write-Host "`nCreating resource group: $rg..."
az group create --name $rg --location $Location | Out-Null

Write-Host "Creating storage account: $sa..."
az storage account create `
    --name $sa `
    --resource-group $rg `
    --location $Location `
    --sku Standard_LRS `
    --allow-blob-public-access false | Out-Null

Write-Host "Creating storage containers..."
$saKey = (az storage account keys list --account-name $sa --resource-group $rg --query "[0].value" -o tsv)
az storage container create --name "installers"  --account-name $sa --account-key $saKey | Out-Null
az storage container create --name "vhd-output"  --account-name $sa --account-key $saKey | Out-Null

Write-Host "Creating service principal: $SpName..."
$rgId = (az group show --name $rg --query id -o tsv)
$sp   = (az ad sp create-for-rbac `
            --name $SpName `
            --role Contributor `
            --scopes $rgId `
            --output json) | ConvertFrom-Json

$saId = (az storage account show --name $sa --resource-group $rg --query id -o tsv)
az role assignment create `
    --assignee $sp.appId `
    --role "Storage Blob Data Reader" `
    --scope $saId | Out-Null

$objectId = (az ad sp show --id $sp.appId --query id -o tsv)

Write-Host "`n--- Copy these values into your .pkrvars.hcl file ---"
Write-Host "client_id              = `"$($sp.appId)`""
Write-Host "client_secret          = `"$($sp.password)`""
Write-Host "client_object_id       = `"$objectId`""
Write-Host "client_tenant_id       = `"$($sp.tenant)`""
Write-Host "client_subscription_id = `"$SubscriptionId`""
Write-Host "image_resource_group   = `"$rg`""
Write-Host ""
Write-Host "Storage account for uploading installers: $sa"
Write-Host "Run 01-upload-installers.ps1 next."
