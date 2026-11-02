# 00-setup-azure.ps1
# Creates the Azure prerequisites for a Packer build:
#   - Resource group
#   - Storage account + containers (installers, vhd-output)
#   - Storage Blob Data Contributor for YOU on that storage account (uploads and
#     exports sign in with your az session; no account keys)
#   - Packer auth, by -AuthMode:
#       Cli (default)     Packer uses your az CLI sign-in. No service principal, no secret.
#       ServicePrincipal  Creates a service principal with Contributor on the resource
#                         group (for unattended builds; prefer workload identity
#                         federation in CI so no secret is stored).
#     Either way Packer builds INSIDE this resource group (build_resource_group_name),
#     so resource-group scope is enough: it never creates a temporary resource group.
#   - User-assigned managed identity attached to the Packer build VM at runtime
#     so it can download installers from blob storage without SAS tokens or account keys
#   - Azure Compute Gallery + one Trusted Launch image definition per template
#     (Packer publishes into these but does not create them)
#
# Why managed identity instead of SAS?
#   SAS tokens embed credentials in URLs, expire on a fixed schedule, and cause
#   PowerShell ParserError (AmpersandNotAllowed) because the & characters in the
#   query string are misinterpreted by the shell. Managed identity + IMDS token
#   eliminates all three problems: no credentials in config, no expiry to manage,
#   no URL special-character issues.
#
# Prerequisites: az CLI logged in (az login), correct subscription set. The role
# assignments below need Owner or User Access Administrator on the subscription.
# Usage: .\00-setup-azure.ps1 -SubscriptionId <id> -Location eastus -Prefix flex-packer

param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [ValidateSet("Cli","ServicePrincipal")] [string]$AuthMode = "Cli",
    [string]$Location  = "eastus",
    [string]$Prefix    = "flex-packer",
    [string]$SpName    = "sp-$Prefix-build",
    [string]$MsiName   = "id-$Prefix-build",
    [string]$GalleryName = "FlexPackerGallery",
    [string]$Publisher   = "FlexImageBuilder"
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

# Containers via the management plane (container-rm): works before any data-plane role exists.
Write-Host "Creating storage containers..."
az storage container-rm create --storage-account $sa --resource-group $rg --name "installers" | Out-Null
az storage container-rm create --storage-account $sa --resource-group $rg --name "vhd-output" | Out-Null

# Data-plane role for the operator: 01-upload and the export scripts use --auth-mode login
# and user-delegation SAS, so no account keys are needed. Owner/Contributor alone do not
# grant blob data access.
$saId = (az storage account show --name $sa --resource-group $rg --query id -o tsv)
$me   = (az ad signed-in-user show --query id -o tsv)
Write-Host "Assigning Storage Blob Data Contributor to you on $sa..."
az role assignment create `
    --assignee-object-id $me `
    --assignee-principal-type User `
    --role "Storage Blob Data Contributor" `
    --scope $saId | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not assign Storage Blob Data Contributor (needs Owner or User Access Administrator). Ask an admin to assign it on $sa before running 01-upload-installers.ps1."
}

# Service principal (only with -AuthMode ServicePrincipal) — Packer uses it to create/manage
# the build VM and gallery versions inside this resource group. It does NOT need blob access;
# installer downloads go through the managed identity. Creating one needs rights to register
# applications in Entra ID.
if ($AuthMode -eq "ServicePrincipal") {
    Write-Host "`nCreating service principal: $SpName..."
    $rgId = (az group show --name $rg --query id -o tsv)
    $sp   = (az ad sp create-for-rbac `
                --name $SpName `
                --role Contributor `
                --scopes $rgId `
                --output json) | ConvertFrom-Json

    $objectId = (az ad sp show --id $sp.appId --query id -o tsv)
}

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

# Azure Compute Gallery — the templates publish straight into it.
# Definitions: Gen2 + SecurityType=TrustedLaunch (required for the VMGS export) and
# Specialized, because the templates capture without generalizing ("specialized": true):
# Citrix MCS needs the pre-generalization disk.
Write-Host "`nCreating Azure Compute Gallery: $GalleryName..."
az sig create --resource-group $rg --gallery-name $GalleryName --location $Location | Out-Null
foreach ($def in @("WinServer2025DC", "WinDesktop11Enterprise23H2")) {
    Write-Host "Creating image definition: $def (Gen2, Trusted Launch, Specialized)..."
    az sig image-definition create `
        --resource-group $rg `
        --gallery-name $GalleryName `
        --gallery-image-definition $def `
        --publisher $Publisher --offer FlexImages --sku $def `
        --os-type Windows --os-state Specialized `
        --hyper-v-generation V2 `
        --features SecurityType=TrustedLaunch | Out-Null
}

Write-Host "`n--- Copy these values into your vars file ---"
if ($AuthMode -eq "ServicePrincipal") {
    Write-Host "use_azure_cli_auth     = `"false`""
    Write-Host "client_id              = `"$($sp.appId)`""
    Write-Host "client_secret          = `"$($sp.password)`"   # shown once: keep it in a secret manager, never in git"
    Write-Host "client_object_id       = `"$objectId`""
    Write-Host "client_tenant_id       = `"$($sp.tenant)`""
} else {
    Write-Host "use_azure_cli_auth     = `"true`"    # Packer runs as your az login; no secret"
}
Write-Host "client_subscription_id = `"$SubscriptionId`""
Write-Host "image_resource_group   = `"$rg`""
Write-Host "managed_identity_id    = `"$($msi.id)`""
Write-Host "gallery_name           = `"$GalleryName`""
Write-Host "location               = `"$Location`""
Write-Host ""
Write-Host "vda_blob_url       = `"https://$sa.blob.core.windows.net/installers/VDASetup.exe`""
Write-Host "optimizer_blob_url = `"https://$sa.blob.core.windows.net/installers/CitrixOptimizer.zip`""
Write-Host ""
Write-Host "Storage account: $sa"
Write-Host "Run 01-upload-installers.ps1 next."
