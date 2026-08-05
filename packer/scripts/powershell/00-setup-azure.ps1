# 00-setup-azure.ps1
# Creates the Azure prerequisites for a Packer build:
#   - Resource group
#   - Storage account + containers (installers, vhd-output)
#   - Service principal with Contributor on the resource group (Packer VM/gallery operations)
#   - User-assigned managed identity attached to the Packer build VM at runtime
#     so it can download installers from blob storage without SAS tokens or account keys
#
# Why managed identity instead of SAS?
#   SAS tokens embed credentials in URLs, expire on a fixed schedule, and cause
#   PowerShell ParserError (AmpersandNotAllowed) because the & characters in the
#   query string are misinterpreted by the shell. Managed identity + IMDS token
#   eliminates all three problems: no credentials in config, no expiry to manage,
#   no URL special-character issues.
#
# Prerequisites: az CLI logged in (az login), correct subscription set.
# Usage: .\00-setup-azure.ps1 -SubscriptionId <id> -Location eastus -Prefix flex-packer

param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$Location  = "eastus",
    [string]$Prefix    = "flex-packer",
    [string]$SpName    = "sp-$Prefix-build",
    [string]$MsiName   = "id-$Prefix-build"
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
az storage container create --name "installers" --account-name $sa --auth-mode login | Out-Null
az storage container create --name "vhd-output" --account-name $sa --auth-mode login | Out-Null

# Service principal — Packer uses this to create/manage VMs, disks, and gallery versions.
# It does NOT need blob access; installer downloads go through the managed identity.
Write-Host "`nCreating service principal: $SpName..."
$rgId = (az group show --name $rg --query id -o tsv)
$sp   = (az ad sp create-for-rbac `
            --name $SpName `
            --role Contributor `
            --scopes $rgId `
            --output json) | ConvertFrom-Json

$objectId = (az ad sp show --id $sp.appId --query id -o tsv)

# User-assigned managed identity — attached to the Packer build VM so provisioners
# can authenticate to blob storage via IMDS without any secrets or SAS tokens.
Write-Host "`nCreating user-assigned managed identity: $MsiName..."
$msi = (az identity create `
    --name $MsiName `
    --resource-group $rg `
    --location $Location `
    --output json) | ConvertFrom-Json

# Scope to the installers container only — principle of least privilege.
$containerScope = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa/blobServices/default/containers/installers"
Write-Host "Assigning Storage Blob Data Reader to managed identity on installers container..."
az role assignment create `
    --assignee $msi.principalId `
    --role "Storage Blob Data Reader" `
    --scope $containerScope | Out-Null

Write-Host "`n--- Copy these values into your vars file ---"
Write-Host "client_id              = `"$($sp.appId)`""
Write-Host "client_secret          = `"$($sp.password)`""
Write-Host "client_object_id       = `"$objectId`""
Write-Host "client_tenant_id       = `"$($sp.tenant)`""
Write-Host "client_subscription_id = `"$SubscriptionId`""
Write-Host "image_resource_group   = `"$rg`""
Write-Host "managed_identity_id    = `"$($msi.id)`""
Write-Host ""
Write-Host "vda_blob_url       = `"https://$sa.blob.core.windows.net/installers/VDASetup.exe`""
Write-Host "optimizer_blob_url = `"https://$sa.blob.core.windows.net/installers/CitrixOptimizer.zip`""
Write-Host ""
Write-Host "Storage account: $sa"
Write-Host "Run 01-upload-installers.ps1 next."
