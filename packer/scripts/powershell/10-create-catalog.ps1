# 10-create-catalog.ps1
# TEST SCRIPT: not yet validated for production. Use it on a test catalog.
# Creates a Citrix DaaS Flex (Quick Deploy) catalog through the API (POST catalogs/$manageddeploy)
# with accelerated networking ON, and fails unless the catalog reads back with it on.
#
# Why: accelerated networking is a per-catalog setting that can only be chosen at creation. The field
# (addCatalog.enableAcceleratedNetworking) is in Citrix's API but not in the published API reference, and a
# create call without it gives a catalog with it OFF (as did the Terraform provider before v1.0.43). The API also
# ignores fields it doesn't know without an error, so this script reads the catalog back instead of trusting the 2xx.
# See docs/accelerated-networking.md.
#
# Terraform is the way this repo creates catalogs: with citrix/citrix >= 1.0.43 the catalog modules turn
# accelerated networking on themselves. This script is for testing the API path. Importing its catalog into
# Terraform plans a replacement unless you work around it (docs/accelerated-networking.md, "Importing").
#
# Usage:
#   $env:CITRIX_CUSTOMER_ID / CITRIX_CLIENT_ID / CITRIX_CLIENT_SECRET as for 06-import-to-citrix.ps1
#   $env:TF_VAR_domain_service_account_password = "<join account password>"   # domain-joined catalogs only
#   .\10-create-catalog.ps1 -Name "Task Worker" -ImageName "<image>" -SessionType MultiSession `
#       -Region <azure-region> -VnetPeeringName "<peering>" -Domain corp.example -DomainOu "OU=VDAs,DC=corp,DC=example" `
#       -ServiceAccount svc-join -WhatIf          # print the request (password hidden), send nothing
#   Optional: -NamingScheme "vda-tw-##" (machine names, # = digit), -SessionTimeoutMinutes 1440 (idle timeout; default 15)
#
# The password is read only from the environment variable named by -PasswordVariable, and never printed.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$ImageName,
    [ValidateSet("MultiSession", "SingleSessionStatic", "SingleSessionRandom")] [string]$SessionType = "MultiSession",
    [Parameter(Mandatory)] [string]$Region,          # Azure region for the catalog, e.g. eastus2
    [string]$SubscriptionName = "Citrix Managed",
    [string]$VmSize = "Standard_D2as_v5",
    [string]$StorageType = "StandardSSD_LRS",
    [int]$MaxUsersPerVm = 2,
    [int]$NumberOfUsers = 2,          # the service sizes the catalog from this: machines = users / MaxUsersPerVm
    [string]$PeakTimeZoneId = "Eastern Standard Time",
    # Machine names, e.g. "vda-tw-##" (each # is a digit). Without it the service picks the names.
    [ValidatePattern('^[A-Za-z0-9-]*#+[A-Za-z0-9-]*$')] [ValidateLength(1, 15)] [string]$NamingScheme,
    # Idle-session timeout in minutes. Never 0: that disconnects an idle session at once. 1440 = a day.
    [ValidateRange(1, 525600)] [int]$SessionTimeoutMinutes = 15,
    [string]$VnetPeeringName,
    [string]$Domain,
    [string]$DomainOu,
    [string]$ServiceAccount,
    [string]$PasswordVariable = "TF_VAR_domain_service_account_password",
    [bool]$EnableAcceleratedNetworking = $true,
    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    [string]$SiteId
)
$ErrorActionPreference = "Stop"
Write-Warning "Test script: not yet validated for production. Use it on a test catalog."
. (Join-Path $PSScriptRoot "citrix-api.ps1")

Write-Host "`nConnecting to Citrix Cloud..."
Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId

$image = @((Invoke-CitrixApi GET "images").items | Where-Object name -eq $ImageName)
if ($image.Count -ne 1) { Write-Error "Expected one image named '$ImageName', found $($image.Count)." }
if ($image[0].state -ne "Ready") { Write-Error "Image '$ImageName' is $($image[0].state), not Ready." }

$subs = @((Invoke-CitrixApi GET "subscriptions").subscriptions)
$sub = $subs | Where-Object name -eq $SubscriptionName | Select-Object -First 1
if (-not $sub) { Write-Error "No Flex subscription named '$SubscriptionName'. Found: $(($subs | ForEach-Object name) -join ', ')" }

$addCatalog = [ordered]@{
    name                        = $Name
    region                      = $Region
    type                        = $SessionType
    isDomainJoined              = [bool]$Domain
    isAzureAdJoined             = $false
    enableAcceleratedNetworking = $EnableAcceleratedNetworking
}
if ($NamingScheme) {
    # isSchemeTypeNumeric, not namingSchemeType: the API drops the latter without an error, and the
    # machines then get letters (vda-tw-AA) instead of digits.
    $addCatalog.machineNamingScheme = [ordered]@{ namingScheme = $NamingScheme; isSchemeTypeNumeric = $true }
}
if ($SessionType -ne "MultiSession") { $MaxUsersPerVm = 1 }

$instanceType = ($VmSize -replace '^(?i)standard_', '' -replace '_', '').ToLowerInvariant()   # Standard_D2as_v5 -> d2asv5, the form the API accepts
$multi = $SessionType -eq "MultiSession"
$addCatalog.minUniqueUsers = $NumberOfUsers
$addCatalog.persistStaticAllocatedVmDisks = $true
# Same scale settings the Terraform provider sends with its default power_schedule. A bare
# { maxInstances, minInstances } is accepted, then the deployment fails with "Object validation failed".
$disconnectAction = if ($multi) { "Nothing" } else { "Shutdown" }
$scale = [ordered]@{
    peakStartTime = 8; peakEndTime = 16; peakTimeZoneId = $PeakTimeZoneId; weekdays = @{}
    peakMinInstances = 0; minInstances = 0
    peakDisconnectedSessionTimeout = 0; offPeakDisconnectedSessionTimeout = 0
    peakExtendedDisconnectTimeoutMinutes = 0; offPeakExtendedDisconnectTimeoutMinutes = 0
    peakDisconnectedSessionAction = $disconnectAction; offPeakDisconnectedSessionAction = $disconnectAction
}
$body = [ordered]@{
    managedSubscriptionId = $sub.subscriptionId
    addCatalog            = $addCatalog
    addCatalogImage       = [ordered]@{ templateId = $image[0].id; citrixPrepared = [bool]$image[0].citrixPrepared }   # the image list's own flag
    addCatalogCapacity    = [ordered]@{
        computeWorker = [ordered]@{ instanceTypeId = $instanceType; storageType = $StorageType; maxUsersPerVM = $MaxUsersPerVm; useManagedDisks = $true; useAzureHUB = $true }
        scaleSettings = $scale
        sessionTimeout = $SessionTimeoutMinutes
        multiSessionDisconnectedSessionTimeout = 0
    }
}
if ($VnetPeeringName) {
    $peer = @((Invoke-CitrixApi GET "managedCapacity/onPremConnections").items) | Where-Object name -eq $VnetPeeringName | Select-Object -First 1
    if (-not $peer) { Write-Error "No network connection named '$VnetPeeringName'." }
    $body.addCatalogOnPremConnectivity = @{ vnetPeeringId = $peer.id }
}
if ($Domain) {
    if (-not $VnetPeeringName) { Write-Error "A domain-joined catalog needs -VnetPeeringName." }
    if (-not $ServiceAccount) { Write-Error "A domain-joined catalog needs -ServiceAccount." }
    $password = [Environment]::GetEnvironmentVariable($PasswordVariable)
    if (-not $password -and -not $WhatIfPreference) { Write-Error "Set `$env:$PasswordVariable to the password of $ServiceAccount." }
    $body.addCatalogDomain = [ordered]@{ domainName = $Domain; domainOu = $DomainOu; serviceAccountName = $ServiceAccount }
    $body.deploySecrets = @{ serviceAccountPassword = $password }
}

Write-Host "`nRequest:"
Write-Host (($body | ConvertTo-Json -Depth 6) -replace '("serviceAccountPassword":\s*)"[^"]*"', '$1"<hidden>"')
if (-not $PSCmdlet.ShouldProcess("$Name ($SessionType, $VmSize, $NumberOfUsers users, accelerated networking $EnableAcceleratedNetworking)", "Create catalog")) { return }

$resp = Invoke-CitrixApi POST 'catalogs/$manageddeploy' $body
$catalogId = if ($resp -is [string]) { $resp.Trim('"') } elseif ($resp.id) { $resp.id } else { Find-CitrixCatalogId $Name }
Write-Host "`nCatalog id: $catalogId"

$c = Get-CitrixCatalog $catalogId
Write-Host "Read back: state $($c.state), enableAcceleratedNetworking $($c.enableAcceleratedNetworking), size $($c.vmTypeInstanceType)"
if ([bool]$c.enableAcceleratedNetworking -ne $EnableAcceleratedNetworking) {
    Write-Error ("enableAcceleratedNetworking reads back as '$($c.enableAcceleratedNetworking)', not $EnableAcceleratedNetworking. " +
        "The API ignored the field. Delete this catalog with 08-delete-catalog.ps1; it can't be changed in place.")
}
Write-Host "`nCatalog-level setting confirmed. The catalog deploys its machines next (about 45 minutes)."
Write-Host "The flag is what was asked for, not proof the NIC is accelerated: check in the guest (docs/accelerated-networking.md)."
Write-Host "`nTo manage this catalog with Terraform, write it as a citrix_quickdeploy_catalog resource (same name, region,"
Write-Host "size, image and network, enable_accelerated_networking = true) with lifecycle { ignore_changes = [persona, on_prem_connectivity] }."
Write-Host "Import doesn't read those two back, so without it the first plan replaces the catalog. Then:"
Write-Host "  terraform import citrix_quickdeploy_catalog.this $catalogId"
Write-Host "  terraform plan    # must say No changes; never apply a plan that says 'must be replaced'"
