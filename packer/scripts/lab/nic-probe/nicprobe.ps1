$ErrorActionPreference = 'Continue'
$dest = '\\AD1.citrix.lab\NicProbe$'
Start-Sleep -Seconds 30

$vmSize = 'unknown'
try {
    $imds = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' -TimeoutSec 5
    $vmSize = $imds.vmSize
} catch { $vmSize = 'imds-error' }

$secureBoot = 'unsupported'
try { $secureBoot = Confirm-SecureBootUEFI } catch { }

$adapters = @(Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress)
$vf = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^PCI\\VEN_1414&DEV_00BA' -or $_.InstanceId -match '^PCI\\VEN_15B3' -or $_.FriendlyName -match 'Mellanox|Azure Network Adapter' } | Select-Object FriendlyName, InstanceId, Status)
$active = [bool]($adapters | Where-Object { $_.InterfaceDescription -match 'Mellanox|Azure Network Adapter' -and $_.Status -eq 'Up' })

$result = [ordered]@{}
$result.computer = $env:COMPUTERNAME
$result.utc = (Get-Date).ToUniversalTime().ToString('o')
$result.os = (Get-CimInstance Win32_OperatingSystem).Caption
$result.build = [Environment]::OSVersion.Version.ToString()
$result.vmSize = $vmSize
$result.secureBoot = $secureBoot
$result.accelNetActive = $active
$result.adapters = $adapters
$result.vfDevices = $vf

$result | ConvertTo-Json -Depth 4 | Out-File -FilePath "$dest\$($env:COMPUTERNAME)-probe.json" -Encoding utf8 -Force
