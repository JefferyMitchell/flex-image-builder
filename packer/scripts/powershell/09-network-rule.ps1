# 09-network-rule.ps1
# Lists, opens or closes an inbound port on a Citrix DaaS (Quick Deploy) network connection: the
# "Security rules" of a VNet peering or Virtual WAN connection to Citrix-managed capacity. Catalog
# machines there accept nothing from your network by default; open a port to reach them, for example
# WinRM (5985) for in-guest checks or a monitoring agent's port, and close it again when you're done.
#
# What a rule is (read back from the API):
#   - Inbound, Allow, TCP / UDP / Any, one destination port from 1 to 49151. Citrix doesn't allow
#     20-21, 22, 23 or 3389.
#   - Source and destination are always the "VirtualNetwork" service tag: the Citrix-managed VNet and
#     every network peered with it. A rule can't be limited to one address.
#   - It applies to every machine on the connection, in every catalog that uses it.
#   - It takes about 3 minutes to reach the machines.
# So open only what you need, for as long as you need it.
#
# The API is the one the Web Studio console uses (Quick Deploy > Microsoft Azure > Network connections >
# your connection > Security rules); it isn't in the published API reference:
#   GET    {customerId}/{siteId}/managedCapacity/onPremConnections/{connectionId}/openPorts
#   POST   .../onPremConnections/{connectionId}/port/{port}/openPort   {"port","name","description","protocol"}
#   DELETE .../onPremConnections/{connectionId}/port/{port}
#
# Usage:
#   $env:CITRIX_CUSTOMER_ID / CITRIX_CLIENT_ID / CITRIX_CLIENT_SECRET as for 06-import-to-citrix.ps1
#   .\09-network-rule.ps1 -Connection my-peering
#   .\09-network-rule.ps1 -Connection my-peering -Open 5985 -Name winrm-check -Description "In-guest checks; remove after"
#   .\09-network-rule.ps1 -Connection my-peering -Close 5985
#
# Before testing a port, make sure the machine is powered on: autoscale powers catalog machines off
# outside peak hours, and a machine that's off looks exactly like a closed port.

[CmdletBinding(DefaultParameterSetName = "List")]
param(
    # The network connection's name or ID (Quick Deploy > Microsoft Azure > Network connections).
    [Parameter(Mandatory)] [string]$Connection,

    [Parameter(Mandatory, ParameterSetName = "Open")] [ValidateRange(1, 49151)] [int]$Open,
    [Parameter(ParameterSetName = "Open")] [string]$Name,
    [Parameter(ParameterSetName = "Open")] [ValidateLength(0, 140)] [string]$Description = "",
    [Parameter(ParameterSetName = "Open")] [ValidateSet("TCP", "UDP", "Any")] [string]$Protocol = "TCP",

    [Parameter(Mandatory, ParameterSetName = "Close")] [ValidateRange(1, 49151)] [int]$Close,

    [int]$TimeoutSeconds = 120,
    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    [string]$SiteId
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "citrix-api.ps1")

Write-Host "Connecting to Citrix Cloud..."
Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId

$connections = @((Invoke-CitrixApi GET "managedCapacity/onPremConnections").items)
$conn = $connections | Where-Object { $_.id -eq $Connection -or $_.name -eq $Connection } | Select-Object -First 1
if (-not $conn) {
    Write-Error "No network connection named or with ID '$Connection'. Connections: $(($connections | ForEach-Object name) -join ', ')"
}
$base = "managedCapacity/onPremConnections/$($conn.id)"
Write-Host "Connection: $($conn.name) ($($conn.id)), $(@($conn.catalogs).Count) catalog(s)"

function Get-Rules { @((Invoke-CitrixApi GET "$base/openPorts").ports | Where-Object { $_ }) }

function Wait-Rule([int]$Port, [bool]$Present) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $listed = [bool](Get-Rules | Where-Object { [int]$_.portNumber -eq $Port })
        if ($listed -eq $Present) { return }
        if ([DateTime]::UtcNow -gt $deadline) {
            Write-Error "Port $Port is $(if ($Present) { 'still not listed' } else { 'still listed' }) after $TimeoutSeconds seconds. Check the Security rules tab in the console."
        }
        Start-Sleep -Seconds 5
    }
}

switch ($PSCmdlet.ParameterSetName) {
    "Open" {
        if (@(20, 21, 22, 23, 3389) -contains $Open) { Write-Error "Citrix doesn't allow port $Open to be opened on Citrix-managed networks." }
        if (Get-Rules | Where-Object { [int]$_.portNumber -eq $Open }) {
            Write-Host "Port $Open is already open on $($conn.name)."
        } else {
            if (-not $Name) { $Name = "port-$Open" }
            Write-Host "Opening $Protocol port $Open ('$Name')..."
            Invoke-CitrixApi POST "$base/port/$Open/openPort" @{ port = "$Open"; name = $Name; description = $Description; protocol = $Protocol.ToUpperInvariant() } | Out-Null
            Wait-Rule $Open $true
            Write-Warning ("Port $Open is now open to every machine on '$($conn.name)', from that VNet and every network peered with it. " +
                           "It reaches the machines in about 3 minutes. Close it when you're done: .\09-network-rule.ps1 -Connection '$($conn.name)' -Close $Open")
        }
    }
    "Close" {
        if (-not (Get-Rules | Where-Object { [int]$_.portNumber -eq $Close })) {
            Write-Host "Port $Close isn't open on $($conn.name)."
        } else {
            Write-Host "Closing port $Close..."
            Invoke-CitrixApi DELETE "$base/port/$Close" @{} | Out-Null
            Wait-Rule $Close $false
            Write-Host "Port $Close is closed."
        }
    }
}

$rules = Get-Rules
if ($rules) {
    Write-Host "`nSecurity rules on $($conn.name):"
    $rules | Sort-Object { [int]$_.portNumber } |
        Format-Table @{ n = "Port"; e = { $_.portNumber } }, @{ n = "Protocol"; e = { $_.protocol } }, @{ n = "Name"; e = { $_.name } },
                     @{ n = "Source"; e = { $_.source } }, @{ n = "Action"; e = { $_.action } }, @{ n = "Priority"; e = { $_.priority } },
                     @{ n = "Description"; e = { $_.description } } -AutoSize | Out-String -Width 200 | Write-Host
} else {
    Write-Host "`nNo security rules on $($conn.name)."
}
