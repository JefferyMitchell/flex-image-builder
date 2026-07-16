# 03-export-image.ps1
# Exports the Packer snapshot (pre-generalization) to a VHD blob in Azure Storage
# and prints the SAS URI to use as vhd_uri in citrix_quickdeploy_template_image.
#
# Packer's Azure ARM builder takes a snapshot of the OS disk BEFORE generalizing the VM.
# That snapshot is the correct source for Citrix Platform Flex — it is non-generalized
# and contains the installed VDA, ready for MCS cloning.
#
# Usage:
#   .\03-export-image.ps1 `
#     -ResourceGroup rg-flex-packer-build `
#     -SnapshotName win_server_2025_dc_202507141200 `
#     -StorageAccount flexpackerbuild `
#     -SubscriptionId <subscription-id>
#
# SnapshotName is the ManagedImageOSDiskSnapshotName from the packer build output
# (same as ManagedImageName — Packer uses the same timestamp for both).

param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$SnapshotName,
    [Parameter(Mandatory)] [string]$StorageAccount,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$OutputContainer = "vhd-output",
    [int]$SasDays = 7
)

$ErrorActionPreference = "Stop"

# Locate AzCopy — required for snapshot-to-blob copies
$azCopy = Get-Command azcopy -ErrorAction SilentlyContinue
if (-not $azCopy) {
    $azCopy = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter azcopy.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $azCopy) { Write-Error "azcopy not found. Install with: winget install Microsoft.Azure.AzCopy.10" }
    $azCopyExe = $azCopy.FullName
} else {
    $azCopyExe = $azCopy.Source
}

Write-Host "`nSetting subscription $SubscriptionId..."
az account set --subscription $SubscriptionId

$snapshotId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/snapshots/$SnapshotName"

Write-Host "Verifying snapshot exists: $SnapshotName..."
$snapshotState = (az snapshot show --ids $snapshotId --query diskState -o tsv 2>&1)
if (-not $snapshotState -or $snapshotState -match "not found|error") {
    Write-Error "Snapshot '$SnapshotName' not found in '$ResourceGroup'. Check the name from the packer build output."
}
Write-Host "  Snapshot state: $snapshotState"

if ($snapshotState -eq "ActiveSAS") {
    Write-Host "Revoking existing SAS before re-granting..."
    az snapshot revoke-access --ids $snapshotId | Out-Null
    Start-Sleep -Seconds 3
}

Write-Host "Granting 24h read SAS on snapshot..."
$sasJson  = (az snapshot grant-access --ids $snapshotId --duration-in-seconds 86400 2>&1) -join "`n"
$sourceSas = ($sasJson | ConvertFrom-Json).accessSAS
if (-not $sourceSas) { Write-Error "Failed to get SAS from snapshot. Raw output:`n$sasJson" }
Write-Host "  Source SAS obtained (length $($sourceSas.Length))."

# Destination: generate container SAS for AzCopy to write into
$saKey     = (az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv)
$expiry    = (Get-Date).AddHours(25).ToString("yyyy-MM-ddTHH:mmZ")
$destContainerSas = (az storage container generate-sas `
    --account-name $StorageAccount --account-key $saKey `
    --name $OutputContainer --permissions rcw --expiry $expiry -o tsv)
$blobName  = "$SnapshotName.vhd"
$destUrl   = "https://$StorageAccount.blob.core.windows.net/$OutputContainer/$blobName`?$destContainerSas"

Write-Host "`nCopying snapshot VHD via AzCopy (typically 3-10 minutes for a 30-130 GB disk)..."
& $azCopyExe copy $sourceSas $destUrl --blob-type PageBlob
if ($LASTEXITCODE -ne 0) { Write-Error "AzCopy failed with exit code $LASTEXITCODE" }

Write-Host "`nRevoking snapshot SAS..."
az snapshot revoke-access --ids $snapshotId | Out-Null

# Generate a read-only SAS on the output blob for Terraform to use
$blobExpiry = (Get-Date).AddDays($SasDays).ToString("yyyy-MM-ddTHH:mmZ")
$blobSas = (az storage blob generate-sas `
    --account-name $StorageAccount --account-key $saKey `
    --container-name $OutputContainer --name $blobName `
    --permissions r --expiry $blobExpiry --https-only -o tsv)
$vhdUri = "https://$StorageAccount.blob.core.windows.net/$OutputContainer/$blobName`?$blobSas"

Write-Host "`n=== VHD export complete ==="
Write-Host ""
Write-Host "Add this to infra/examples/singlesession-custom-image/terraform.tfvars:"
Write-Host ""
Write-Host "  vhd_uri            = `"$vhdUri`""
Write-Host ""
Write-Host "SAS expires: $blobExpiry UTC  (regenerate before expiry with -SasDays)"
Write-Host "Blob: https://$StorageAccount.blob.core.windows.net/$OutputContainer/$blobName"
