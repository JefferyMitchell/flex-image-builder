# 03-export-image.ps1
# Exports the Packer-built Managed Image to a VHD blob in Azure Storage
# and prints the URI to use as vhd_uri in citrix_quickdeploy_template_image.
#
# Usage:
#   .\03-export-image.ps1 `
#     -ResourceGroup rg-flex-packer-build `
#     -ImageName win_server_2025_dc_202506261200 `
#     -StorageAccount flexpackerbuild `
#     -SubscriptionId <id>

param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$ImageName,
    [Parameter(Mandatory)] [string]$StorageAccount,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$OutputContainer = "vhd-output"
)

$ErrorActionPreference = "Stop"

Write-Host "`nSetting subscription..."
az account set --subscription $SubscriptionId

Write-Host "Looking up managed image: $ImageName..."
$diskId = (az image show `
    --resource-group $ResourceGroup `
    --name $ImageName `
    --query "storageProfile.osDisk.managedDisk.id" -o tsv)

if (-not $diskId) {
    Write-Error "Could not find managed disk for image '$ImageName'. Verify the image name in the resource group."
}

$diskName = $diskId.Split("/")[-1]
Write-Host "OS disk: $diskName"

Write-Host "Granting SAS access to disk (24h)..."
$sas = (az disk grant-access `
    --ids $diskId `
    --duration-in-seconds 86400 `
    --query accessSas -o tsv)

$saKey     = (az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv)
$blobName  = "$ImageName.vhd"

Write-Host "Copying VHD to storage account (this takes 5-15 minutes)..."
az storage blob copy start `
    --source-uri $sas `
    --destination-container $OutputContainer `
    --destination-blob $blobName `
    --account-name $StorageAccount `
    --account-key $saKey | Out-Null

Write-Host "Waiting for copy to complete..."
do {
    Start-Sleep -Seconds 30
    $status = (az storage blob show `
        --container-name $OutputContainer `
        --name $blobName `
        --account-name $StorageAccount `
        --account-key $saKey `
        --query "properties.copy.status" -o tsv)
    Write-Host "  Copy status: $status"
} while ($status -eq "pending")

if ($status -ne "success") {
    Write-Error "VHD copy failed with status: $status"
}

Write-Host "Revoking disk SAS access..."
az disk revoke-access --ids $diskId | Out-Null

$vhdUri = (az storage blob url `
    --container-name $OutputContainer `
    --name $blobName `
    --account-name $StorageAccount `
    --account-key $saKey -o tsv)

Write-Host "`n--- Use this URI in your Terraform vars ---"
Write-Host "vhd_uri = `"$vhdUri`""
Write-Host ""
Write-Host "Add this to infra/examples/singlesession-custom-image/terraform.tfvars"
