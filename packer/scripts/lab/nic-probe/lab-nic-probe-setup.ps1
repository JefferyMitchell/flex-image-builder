# lab-nic-probe-setup.ps1 — run on a domain controller (or with RSAT) as a Domain Admin.
# Sets up an outbound in-guest check for Flex VDAs: a GPO startup script, linked to the VDA OU,
# that writes each VDA's network adapters to a share on the DC at every boot.
#
# Why: Citrix-managed VDAs only accept ICA/CGP (1494, 2598) and port 80 from the peered VNet, so
# WinRM, RDP and SMB to the VDA are blocked. Outbound SMB from the VDA to its DC always works.
# New catalog machines boot after domain join, so they report without anyone signing in.
#
# Output: \\<dc>\NicProbe$\<COMPUTER>-probe.json (adapters, VF devices, accelNetActive, vmSize, Secure Boot)
#         \\<dc>\NicProbe$\<COMPUTER>-adapters.txt (plain Get-NetAdapter, as a fallback)
# To see results for a machine already running, reboot it (Studio, or POST cvad/manage/Machines/{id}/$reboot).
#
# Lab only. Remove with -Remove when you're done.
param(
    [Parameter(Mandatory)] [string]$VdaOu,                 # e.g. OU=MCS,OU=VDAs,DC=citrix,DC=lab
    [string]$ProbeScript = (Join-Path $PSScriptRoot "nicprobe.ps1"),
    [string]$ShareDir = "C:\NicProbe",
    [string]$GpoName = "LAB - NIC probe (accelnet validation)",
    [switch]$Remove
)
$ErrorActionPreference = "Stop"
Import-Module GroupPolicy, ActiveDirectory
$domain = (Get-ADDomain).DNSRoot
$dc = "$env:COMPUTERNAME.$domain"

if ($Remove) {
    Remove-GPO -Name $GpoName -ErrorAction SilentlyContinue
    Remove-SmbShare -Name 'NicProbe$' -Force -ErrorAction SilentlyContinue
    Remove-Item "\\$domain\NETLOGON\nicprobe.ps1" -ErrorAction SilentlyContinue
    "Removed GPO, share and script. $ShareDir is left in place with any results."
    return
}

New-Item -ItemType Directory -Force -Path $ShareDir | Out-Null
if (-not (Get-SmbShare -Name 'NicProbe$' -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name 'NicProbe$' -Path $ShareDir -ChangeAccess "$((Get-ADDomain).NetBIOSName)\Domain Computers" | Out-Null
}
icacls $ShareDir /grant "$((Get-ADDomain).NetBIOSName)\Domain Computers:(OI)(CI)M" | Out-Null

# The probe writes to this DC's share.
(Get-Content $ProbeScript -Raw) -replace '\\\\AD1\.citrix\.lab\\NicProbe\$', "\\$dc\NicProbe$" |
    Set-Content "\\$domain\NETLOGON\nicprobe.ps1" -Encoding UTF8

$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }
$scripts = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\Machine\Scripts"
New-Item -ItemType Directory -Force -Path "$scripts\Startup" | Out-Null
# cmd.exe wrappers: a PowerShell script run straight from a UNC path didn't run on the Flex VDAs,
# and the redirect captures any PowerShell error on the share.
$share = "\\$dc\NicProbe$"
$ini = @"

[Startup]
0CmdLine=cmd.exe
0Parameters=/c powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-NetAdapter | Format-List Name,InterfaceDescription,Status,LinkSpeed,MacAddress" > $share\%COMPUTERNAME%-adapters.txt 2>&1
1CmdLine=cmd.exe
1Parameters=/c copy /y \\$domain\NETLOGON\nicprobe.ps1 C:\Windows\Temp\nicprobe.ps1 && powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\nicprobe.ps1 > $share\%COMPUTERNAME%-ps.txt 2>&1
"@
[IO.File]::WriteAllText("$scripts\scripts.ini", ($ini -replace "`r?`n", "`r`n"), [Text.Encoding]::Unicode)

$dn = "CN={$($gpo.Id)},CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)"
Set-ADObject $dn -Replace @{ gPCMachineExtensionNames = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]' }
$ver = [int](Get-ADObject $dn -Properties versionNumber).versionNumber + 1
Set-ADObject $dn -Replace @{ versionNumber = $ver }
Set-Content "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id)}\GPT.INI" "[General]`r`nVersion=$ver`r`n" -Encoding ASCII
if ((Get-GPInheritance -Target $VdaOu).GpoLinks.DisplayName -notcontains $GpoName) { New-GPLink -Name $GpoName -Target $VdaOu | Out-Null }
"GPO '$GpoName' ($($gpo.Id)) linked to $VdaOu. Results: $ShareDir"
