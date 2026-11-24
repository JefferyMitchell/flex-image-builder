# 11-check-catalog.ps1
# Reads a DaaS Flex (Quick Deploy) catalog back from both Citrix APIs and checks it, read-only:
#  - Quick Deploy: state, size and enableAcceleratedNetworking (what was requested);
#  - its image, from the site's image list: generation, vTPM and Secure Boot;
#  - the broker's provisioning scheme, the machine profile MCS builds machines from: SecurityType,
#    EnableSecureBoot, EnableVTPM, AcceleratedNetwork and size;
#  - its machines: power, registration, maintenance mode and VDA version.
# Run it after the catalog has deployed: the broker has no provisioning scheme before that.
# Exits 1 when the machine profile doesn't match the image's Trusted Launch flags, or accelerated
# networking isn't what -ExpectAcceleratedNetworking says.
#
# Why both APIs: Quick Deploy reports the request, and it ignores fields it doesn't know without an
# error. The provisioning scheme is what MCS uses. Neither proves the NIC is accelerated: on sizes where
# Azure requires accelerated networking it's on whatever the flag says, so check in the guest too
# (a Mellanox or Microsoft Azure Network Adapter whose byte counters move under load; on Server 2025 builds before
# 26100.33828 Get-NetAdapter shows it Not Present while it carries the traffic: docs/accelerated-networking.md).
#
# Accelerated networking can only be chosen when a catalog is created. This repo's catalog modules turn it on
# (citrix/citrix >= 1.0.43), so -ExpectAcceleratedNetworking defaults to $true. Pass $false for a catalog
# created with it off (provider v1.0.42 or earlier, or a resource that doesn't set it).
#
# Usage (credentials as for 06-import-to-citrix.ps1):
#   .\11-check-catalog.ps1 -CatalogName "Task Worker"
#   .\11-check-catalog.ps1 -CatalogName "Old Catalog" -ExpectAcceleratedNetworking $false
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$CatalogName,
    [bool]$ExpectAcceleratedNetworking = $true,
    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    [string]$SiteId
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "citrix-api.ps1")

# The broker returns some flags as the strings "True"/"False", and [bool]"False" is $true in PowerShell.
function ConvertTo-Flag($Value) { "$Value" -eq "True" }

Write-Host "`nConnecting to Citrix Cloud..."
Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId
$problems = [System.Collections.Generic.List[string]]::new()

# Quick Deploy: what was requested.
$c = Get-CitrixCatalog (Find-CitrixCatalogId $CatalogName)
$an = ConvertTo-Flag $c.enableAcceleratedNetworking
Write-Host "`nQuick Deploy : state $($c.state), size $($c.vmTypeInstanceType), enableAcceleratedNetworking $an, image '$($c.templateImageName)'"
if ($an -ne $ExpectAcceleratedNetworking) { $problems.Add("Quick Deploy: enableAcceleratedNetworking is $an, expected $ExpectAcceleratedNetworking. It can only be set at creation.") }

# The image's Trusted Launch flags (the list has the right values; see Find-CitrixImageInList).
$img = Find-CitrixImageInList $c.imageId
if ($img) {
    $flags = Get-ImageFlags $img
    Write-Host "Image        : $($img.name): $($flags.hyperVGen), vTPM $($flags.vtpmEnabled), Secure Boot $($flags.secureBootEnabled), VDA $($img.vdaVersion)"
} else {
    $flags = $null
    $problems.Add("Image $($c.imageId) isn't in the site's image list, so its flags can't be compared.")
}

# Broker: what MCS builds machines with.
$bc = @((Invoke-CitrixBroker GET "MachineCatalogs").Items) | Where-Object Name -eq $CatalogName | Select-Object -First 1
if (-not $bc) {
    $problems.Add("The broker has no catalog named '$CatalogName' yet. Run again once it has deployed.")
} else {
    $detail = Invoke-CitrixBroker GET "MachineCatalogs/$($bc.Id)"
    $md = $detail.ProvisioningScheme.VMMetadata
    if (-not $md) {
        $problems.Add("The broker catalog has no provisioning scheme yet. Run again once it has deployed.")
    } else {
        $sb = ConvertTo-Flag $md.EnableSecureBoot
        $tpm = ConvertTo-Flag $md.EnableVTPM
        $mdAn = ConvertTo-Flag $md.AcceleratedNetwork
        Write-Host "Machines get : SecurityType $($md.SecurityType), Secure Boot $sb, vTPM $tpm, accelerated networking $mdAn, size $($md.MachineSize)"
        $rules = $detail.ProvisioningScheme.MachineAccountCreationRules
        if ($rules) { Write-Host "Naming       : $($rules.NamingScheme) ($($rules.NamingSchemeType)), OU $($rules.OU)" }
        if ($flags) {
            if ($sb -ne $flags.secureBootEnabled) { $problems.Add("Secure Boot: the machine profile has $sb, the image has $($flags.secureBootEnabled).") }
            if ($tpm -ne $flags.vtpmEnabled) { $problems.Add("vTPM: the machine profile has $tpm, the image has $($flags.vtpmEnabled).") }
            if (($flags.secureBootEnabled -or $flags.vtpmEnabled) -and "$($md.SecurityType)" -ne "TrustedLaunch") {
                $problems.Add("SecurityType is '$($md.SecurityType)', but the image is Trusted Launch.")
            }
        }
        if ($mdAn -ne $ExpectAcceleratedNetworking) { $problems.Add("The machine profile's AcceleratedNetwork is $mdAn, expected $ExpectAcceleratedNetworking.") }
    }

    # Machines.
    $machines = @((Invoke-CitrixBroker GET "MachineCatalogs/$($bc.Id)/Machines").Items)
    Write-Host "`nMachines ($($machines.Count)):"
    foreach ($m in $machines) {
        Write-Host ("  {0}: power {1}, {2}, maintenance {3}, VDA {4}" -f ($m.Name -split '\\')[-1], $m.PowerState, $m.RegistrationState, $m.InMaintenanceMode, $m.AgentVersion)
    }
}

if ($problems.Count) {
    Write-Host "`nProblems:"
    $problems | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host "`nAll checks passed. The accelerated networking flag is what was requested: the adapters' byte counters in the guest show the NIC."
