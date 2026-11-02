# 03-export-image.ps1
# Exports the Packer snapshot (pre-generalization) to a VHD blob in Azure Storage
# and prints the SAS URIs to use in citrix_quickdeploy_template_image.
#
# Packer's Azure ARM builder takes a snapshot of the OS disk BEFORE generalizing the VM.
# That snapshot is the correct source for Citrix Platform Flex — it is non-generalized
# and contains the installed VDA, ready for MCS cloning.
#
# When the Packer template includes security_type = "TrustedLaunch", the snapshot also
# carries VM Guest State (VMGS) data. This script captures both the OS VHD and the VMGS
# blob and outputs both URIs for use as vhd_uri and guest_disk_uri in Terraform.
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
    if (-not $azCopy) { Write-Error "azcopy not found on PATH. Install with: winget install Microsoft.Azure.AzCopy.10 (Windows) or brew install azcopy (macOS)" }
    $azCopyExe = $azCopy.FullName
} else {
    $azCopyExe = $azCopy.Source
}

Write-Host "`nSetting subscription $SubscriptionId..."
az account set --subscription $SubscriptionId

$snapshotId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/snapshots/$SnapshotName"

Write-Host "Verifying snapshot exists: $SnapshotName..."
$snapshotJson = az snapshot show --ids $snapshotId 2>&1 | ConvertFrom-Json
if (-not $snapshotJson) {
    Write-Error "Snapshot '$SnapshotName' not found in '$ResourceGroup'. Check the name from the packer build output."
}
$snapshotState = $snapshotJson.diskState
$snapshotSecurityType = $snapshotJson.securityProfile.securityType
Write-Host "  Snapshot state        : $snapshotState"
Write-Host "  Snapshot security type: $(if ($snapshotSecurityType) { $snapshotSecurityType } else { '(none — not a Trusted Launch snapshot)' })"

# Revoke any active SAS before re-granting (REST — works regardless of snapshot state).
# az snapshot grant-access does not support --security-data-access-level in az CLI ≤2.88;
# use the Compute REST API directly with getSecureVMGuestStateSAS to get the VMGS SAS.
Write-Host "`nRevoking any active SAS (REST)..."
$azToken   = (az account get-access-token --subscription $SubscriptionId --query accessToken -o tsv 2>$null)
$authHdr   = @{ Authorization = "Bearer $azToken"; "Content-Type" = "application/json" }
$baseUrl   = "https://management.azure.com$snapshotId"
try { Invoke-RestMethod -Method POST -Uri "$baseUrl/endGetAccess?api-version=2024-03-02" -Headers $authHdr -Body "{}" | Out-Null } catch {}
Start-Sleep -Seconds 3

Write-Host "Granting 24h read SAS on snapshot (including VMGS data if TrustedLaunch)..."
$grantResp = Invoke-WebRequest -Method POST -Uri "$baseUrl/beginGetAccess?api-version=2024-03-02" `
    -Headers $authHdr -Body '{"access":"Read","durationInSeconds":86400,"getSecureVMGuestStateSAS":true}' -UseBasicParsing
if ($grantResp.StatusCode -ne 202) { Write-Error "beginGetAccess returned $($grantResp.StatusCode)" }

$asyncUrl = ([string[]]($grantResp.Headers["Azure-AsyncOperation"]))[0]
$sasOut   = $null
for ($i = 1; $i -le 24; $i++) {
    $poll = Invoke-RestMethod -Method GET -Uri $asyncUrl -Headers $authHdr
    if ($poll.status -eq "Succeeded") { $sasOut = $poll.properties.output; break }
    if ($poll.status -eq "Failed")    { Write-Error "Grant-access operation failed: $($poll | ConvertTo-Json -Depth 4)" }
    Write-Host "  Waiting for SAS grant ($i/24)..."
    Start-Sleep -Seconds 5
}
if (-not $sasOut) { Write-Error "Timed out waiting for SAS grant operation" }

$sourceSas = $sasOut.accessSAS
$vmgsSas   = $sasOut.securityDataAccessSAS

if (-not $sourceSas) { Write-Error "accessSAS not returned by grant-access operation" }
Write-Host "  OS SAS obtained  (length $($sourceSas.Length))."
if ($vmgsSas) {
    Write-Host "  VMGS SAS obtained (length $($vmgsSas.Length)) — Trusted Launch snapshot confirmed."
} else {
    Write-Host "  VMGS SAS not returned — snapshot was not built with security_type = TrustedLaunch."
    Write-Host "  Proceeding with OS disk only. Secure Boot will not be available."
}

# Storage account key for destination SAS generation
# !! Use UtcNow — (Get-Date) returns LOCAL time. Appending "Z" tells Azure it's UTC, which is
# !! wrong on machines not in UTC. Azure rejects the SAS if expiry is before signed-start time.
$saKey   = (az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv)
$expiry  = [System.DateTime]::UtcNow.AddHours(25).ToString("yyyy-MM-ddTHH:mmZ")

# ── OS disk copy ──────────────────────────────────────────────────────────────
$destContainerSas = (az storage container generate-sas `
    --account-name $StorageAccount --account-key $saKey `
    --name $OutputContainer --permissions rcw --expiry $expiry -o tsv)
$osBlobName = "$SnapshotName.vhd"
$osDestUrl  = "https://$StorageAccount.blob.core.windows.net/$OutputContainer/$osBlobName`?$destContainerSas"

Write-Host "`nCopying OS disk snapshot via AzCopy (~10-15 minutes for a 130 GB disk)..."
& $azCopyExe copy $sourceSas $osDestUrl --blob-type PageBlob
if ($LASTEXITCODE -ne 0) { Write-Error "AzCopy (OS disk) failed with exit code $LASTEXITCODE" }

# ── VMGS disk copy (Trusted Launch only) ─────────────────────────────────────
$vmgsUri = $null
if ($vmgsSas) {
    $vmgsBlobName = "$SnapshotName-vmgs.vhd"
    $vmgsDestUrl  = "https://$StorageAccount.blob.core.windows.net/$OutputContainer/$vmgsBlobName`?$destContainerSas"

    Write-Host "`nCopying VMGS (VM Guest State) disk via AzCopy..."
    & $azCopyExe copy $vmgsSas $vmgsDestUrl --blob-type PageBlob
    if ($LASTEXITCODE -ne 0) { Write-Error "AzCopy (VMGS) failed with exit code $LASTEXITCODE" }

    $blobExpiry = [System.DateTime]::UtcNow.AddDays($SasDays).ToString("yyyy-MM-ddTHH:mmZ")
    $vmgsBlobSas = (az storage blob generate-sas `
        --account-name $StorageAccount --account-key $saKey `
        --container-name $OutputContainer --name $vmgsBlobName `
        --permissions r --expiry $blobExpiry --https-only -o tsv)
    $vmgsUri = "https://$StorageAccount.blob.core.windows.net/$OutputContainer/$vmgsBlobName`?$vmgsBlobSas"
}

Write-Host "`nRevoking snapshot SAS..."
try { Invoke-RestMethod -Method POST -Uri "$baseUrl/endGetAccess?api-version=2024-03-02" -Headers $authHdr -Body "{}" | Out-Null } catch {}
Start-Sleep -Seconds 2

# ── Output blob SAS for the OS VHD ───────────────────────────────────────────
$blobExpiry = [System.DateTime]::UtcNow.AddDays($SasDays).ToString("yyyy-MM-ddTHH:mmZ")
$osBlobSas  = (az storage blob generate-sas `
    --account-name $StorageAccount --account-key $saKey `
    --container-name $OutputContainer --name $osBlobName `
    --permissions r --expiry $blobExpiry --https-only -o tsv)
$vhdUri = "https://$StorageAccount.blob.core.windows.net/$OutputContainer/$osBlobName`?$osBlobSas"

# ── Final output ──────────────────────────────────────────────────────────────
Write-Host "`n=== Export complete ==="
Write-Host ""
Write-Host "Add these to infra/examples/singlesession-custom-image/terraform.tfvars:"
Write-Host ""
Write-Host "  vhd_uri            = `"$vhdUri`""
if ($vmgsUri) {
    Write-Host "  guest_disk_uri     = `"$vmgsUri`""
    Write-Host "  secure_boot_enabled = true"
    Write-Host "  vtpm_enabled        = true"
} else {
    Write-Host ""
    Write-Host "  # guest_disk_uri not available — rebuild Packer with security_type = TrustedLaunch"
    Write-Host "  # to enable Secure Boot support."
    Write-Host "  secure_boot_enabled = false"
    Write-Host "  vtpm_enabled        = false"
}
Write-Host ""
Write-Host "SAS expires: $blobExpiry UTC  (regenerate before expiry by re-running this script)"
