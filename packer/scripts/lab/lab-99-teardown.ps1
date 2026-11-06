# lab-99-teardown.ps1
# Removes a lab: closes the ports you name, then deletes the resource groups marked as belonging to it.
# See docs/lab-environment.md.
#
# It can only delete a resource group that carries the tag flex-image-builder-lab=<LabName>, in the
# subscription you name. Nothing is deleted by name, so other resource groups in that subscription are
# out of reach. It stops if a marked group has a lock. Marking is a separate, deliberate step:
#
#   # After 00-setup-azure.ps1 and any other lab deployments:
#   .\lab-99-teardown.ps1 -SubscriptionId <id> -LabName image-lab -MarkResourceGroup rg-flex-packer-build
#
#   # When you're done. List first, then remove (it lists everything and asks before each delete):
#   .\lab-99-teardown.ps1 -SubscriptionId <id> -LabName image-lab -WhatIf
#   .\lab-99-teardown.ps1 -SubscriptionId <id> -LabName image-lab -Connection <connection name> -ClosePort 5985
#
# It doesn't remove Citrix catalogs or images, API clients, or role assignments outside the marked
# groups. It reminds you to check those. Use 08-delete-catalog.ps1 for catalogs.

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High", DefaultParameterSetName = "Remove")]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,

    # The lab's name, used as the tag's value.
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{2,39}$')] [string]$LabName,

    # Mark these resource groups as part of the lab, then stop.
    [Parameter(Mandatory, ParameterSetName = "Mark")] [string[]]$MarkResourceGroup,

    # Ports to close on this network connection, with 09-network-rule.ps1, before anything is deleted.
    [Parameter(ParameterSetName = "Remove")] [string]$Connection,
    [Parameter(ParameterSetName = "Remove")] [ValidateRange(1, 49151)] [int[]]$ClosePort = @(),

    [Parameter(ParameterSetName = "Remove")] [string]$ApiHost = "api.cloud.com"
)

$ErrorActionPreference = "Continue"
$tagKey = "flex-image-builder-lab"

function Invoke-AzJson {
    $output = & az @args -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0]) $($args[1]) failed. Check your az login and the subscription." }
    if (-not $output) { return $null }
    # Assign first: Windows PowerShell 5.1 otherwise passes a JSON array down the pipeline as one item.
    $parsed = ($output | Out-String) | ConvertFrom-Json
    $parsed
}

$account = Invoke-AzJson account show --subscription $SubscriptionId
Write-Host "Subscription: $($account.name)"

# -- Mark -----------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq "Mark") {
    foreach ($name in $MarkResourceGroup) {
        $group = Invoke-AzJson group show --name $name --subscription $SubscriptionId
        $resources = @(Invoke-AzJson resource list --resource-group $name --subscription $SubscriptionId --query "[].name")
        Write-Host "`n${name}: $($resources.Count) resource(s)"
        $resources | ForEach-Object { Write-Host "  $_" }
        if ($PSCmdlet.ShouldProcess($name, "Mark for deletion with lab '$LabName'. Teardown will delete this group and everything in it")) {
            & az tag update --resource-id $group.id --operation Merge --tags "$tagKey=$LabName" -o none --subscription $SubscriptionId
            if ($LASTEXITCODE -ne 0) { throw "Couldn't tag $name." }
            Write-Host "  Marked."
        }
    }
    exit 0
}

# -- Find what's marked ---------------------------------------------------------
$groups = @(Invoke-AzJson group list --subscription $SubscriptionId --tag "$tagKey=$LabName")
# Check the tag again here, so a change in how az filters can't widen what gets deleted.
$groups = @($groups | Where-Object { $_ -and $_.name -is [string] -and $_.tags.$tagKey -ceq $LabName })

if (-not $groups.Count) { Write-Host "No resource groups are marked for lab '$LabName'." }

$locked = @()
foreach ($group in $groups) {
    $resources = @(Invoke-AzJson resource list --resource-group $group.name --subscription $SubscriptionId --query "[].{name:name,type:type}" | Where-Object { $_ })
    Write-Host "`n$($group.name) ($($group.location)): $($resources.Count) resource(s)"
    $resources | ForEach-Object { Write-Host ("  {0,-40} {1}" -f $_.name, $_.type) }
    if (@(Invoke-AzJson lock list --resource-group $group.name --subscription $SubscriptionId | Where-Object { $_ }).Count) {
        Write-Warning "$($group.name) has a lock. Not deleting anything until you've checked why."
        $locked += $group.name
    }
}
if ($locked.Count) { throw "Locked: $($locked -join ', '). Nothing was closed or deleted." }

$failures = 0

# -- Close ports first ----------------------------------------------------------
if ($ClosePort.Count -and -not $Connection) { throw "-ClosePort needs -Connection." }
foreach ($port in $ClosePort) {
    if ($PSCmdlet.ShouldProcess("$Connection port $port", "Close")) {
        try {
            & (Join-Path $PSScriptRoot "..\powershell\09-network-rule.ps1") -Connection $Connection -Close $port -ApiHost $ApiHost -ErrorAction Stop
        } catch {
            Write-Warning "Couldn't close port ${port}: $($_.Exception.Message) The port may still be open: close it in the console's Security rules tab."
            $failures++
        }
    }
}

# -- Delete ---------------------------------------------------------------------
foreach ($group in $groups) {
    if ($PSCmdlet.ShouldProcess($group.name, "Delete this resource group and everything in it")) {
        # Read the tag again right before deleting, in case it changed after the listing above.
        $current = Invoke-AzJson group show --name $group.name --subscription $SubscriptionId
        if ($current.tags.$tagKey -cne $LabName) {
            Write-Warning "$($group.name) is no longer marked for lab '$LabName'. Not deleting it."
            $failures++
            continue
        }
        Write-Host "Deleting $($group.name)..."
        & az group delete --name $group.name --subscription $SubscriptionId --yes
        $exists = "$(& az group exists --name $group.name --subscription $SubscriptionId 2>$null)".Trim()
        if ($exists -eq "false") {
            Write-Host "  Gone."
        } else {
            Write-Warning "$($group.name) still exists."
            $failures++
        }
    }
}

Write-Host "`nCheck these yourself. This script doesn't remove them:"
Write-Host "  - Security rules you didn't name: 09-network-rule.ps1 -Connection <name>"
Write-Host "  - Citrix catalogs and imported images, and API clients made for the lab"
Write-Host "  - Role assignments outside the marked groups, shown in Azure as 'Identity not found'"
Write-Host "  - Lab resources in groups you didn't mark"
if ($failures) { Write-Host "`n$failures step(s) failed. See the warnings above."; exit 1 }
