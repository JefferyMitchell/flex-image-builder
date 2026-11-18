# install-extra-installers.ps1 — runs on the build VM (02-build.ps1 adds it when you pass -InstallersFile).
# Installs the installers listed in c:\setup\installers.json: agents such as Citrix Session Recording or
# Workspace Environment Management, or any other MSI or EXE you stage in your storage account.
#
# Each one is checked the way the VDA installer is, before anything runs, and any failure stops the build:
#  - it's downloaded from your storage account with the build VM's managed identity;
#  - its SHA-256 must match "sha256" (01-upload-installers.ps1 prints it);
#  - its Authenticode signature must be Valid, from the organization in "signer".
# Then the Windows features it needs ("windows_features") are turned on, and it's installed silently:
#  - .msi: msiexec /i <file> /qn /norestart /l*v <log>, plus "arguments" (MSI properties);
#  - .exe: <file> "arguments" (put the installer's own quiet switch there, e.g. /quiet).
# Exit codes 0, 1641 and 3010 pass.
#
# "msmq_new_id_at_startup": true adds a startup task that gives every machine made from the image its own
# MSMQ machine ID (QMId). Machines cloned from one image (MCS, PVS) otherwise share the image's ID, and
# MSMQ-based agents such as Session Recording then lose messages: sessions stay "Live" after logoff.
#
# The "build-input: extra=" and "installed-extra:" lines it prints go into the build record (02-build.ps1).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail([string]$Message) { $host.UI.WriteErrorLine("ERROR: $Message"); exit 1 }

$manifest = 'c:\setup\installers.json'
if (-not (Test-Path $manifest)) { Fail "Installer list not found: $manifest" }
# Windows PowerShell 5.1 (what the build VM runs) emits a JSON array from ConvertFrom-Json as ONE object, so
# @(... | ConvertFrom-Json) would be a one-item list holding the array. Assign first, then enumerate.
$parsed = Get-Content $manifest -Raw | ConvertFrom-Json
$entries = @($parsed | ForEach-Object { $_ })
if (-not $entries) { Fail "Installer list is empty: $manifest" }

$token = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/' -Headers @{ Metadata = 'true' }).access_token
$workDir = 'C:\Windows\Temp\extra-installers'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1   # 1 = workstation
$okExit = @(0, 1641, 3010)   # success, reboot initiated, reboot required

function Get-Blob([string]$Url, [string]$Path) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & curl.exe --fail --silent --show-error --location --retry 3 -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08" -o $Path $Url
    if ($LASTEXITCODE -ne 0) { Fail "Download failed (curl exit $LASTEXITCODE): $Url" }
    $sw.Stop()
    $mb = (Get-Item $Path).Length / 1MB
    Write-Host ("download: {0} {1:N0} MB in {2:N0} s ({3:N1} MB/s)" -f (Split-Path $Path -Leaf), $mb, $sw.Elapsed.TotalSeconds, ($mb / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)))
}

function Get-InstallerVersion([string]$Path) {
    # AppLocker reads an MSI's ProductVersion and an EXE's file version without opening an MSI session.
    try {
        $v = "$((Get-AppLockerFileInformation -Path $Path).Publisher.BinaryVersion)"
        if ($v -and $v -ne '0.0.0.0') { return $v }
    } catch { }
    $v = "$((Get-Item $Path).VersionInfo.ProductVersion)".Trim()
    if ($v) { $v -replace '\s', '' } else { 'unknown' }
}

$resetScript = @'
# Reset-MsmqId.ps1 — added by flex-image-builder; runs at startup as SYSTEM.
# Gives this machine its own MSMQ machine ID (QMId). Machines cloned from one image (MCS, PVS) otherwise
# share the image's ID, and MSMQ-based agents such as Citrix Session Recording then lose messages.
# Steps: stop MSMQ (and the services that depend on it), remove the stored QMId, set SysPrep=1 so MSMQ
# makes a new one, then start MSMQ and the dependent services that were set to start automatically.
#
# Once per machine: after a reset it writes this VM's Azure ID (vmId) to Reset-MsmqId.done and skips later
# starts on the same VM. A pooled machine's disk goes back to the image at restart, which removes the marker,
# so it resets at every start; a dedicated machine resets once and keeps its ID, so recordings queued before
# a restart aren't lost. If the VM ID can't be read, it resets anyway.
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'Reset-MsmqId.log'
$marker = Join-Path $PSScriptRoot 'Reset-MsmqId.done'
function Log([string]$m) { Add-Content -Path $log -Value ("{0:yyyy-MM-ddTHH:mm:ssZ} {1}" -f (Get-Date).ToUniversalTime(), $m) }
function Get-QmId {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\MSMQ\Parameters\MachineCache' -Name QMId -ErrorAction SilentlyContinue).QMId
    if ($v) { [guid]::new([byte[]]$v) } else { 'none' }
}
function Get-VmId {
    # The network can come up a little after the task starts: try for about a minute.
    for ($i = 0; $i -lt 12; $i++) {
        try {
            $id = Invoke-RestMethod -Headers @{ Metadata = 'true' } -TimeoutSec 5 -Uri 'http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text'
            if ("$id" -match '^[0-9a-fA-F-]{36}$') { return "$id".ToLowerInvariant() }
        } catch { }
        Start-Sleep -Seconds 5
    }
    $null
}
try {
    $vmId = Get-VmId
    if ($vmId -and (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $vmId)) {
        Log "QMId $(Get-QmId) kept: already reset on this VM ($vmId)"
        exit 0
    }
    $before = Get-QmId
    $msmq = Get-Service MSMQ
    $restart = @($msmq.DependentServices | Where-Object { $_.Status -eq 'Running' -or $_.StartType -like 'Automatic*' } | ForEach-Object Name)
    Stop-Service MSMQ -Force
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\MSMQ\Parameters\MachineCache' -Name QMId -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\MSMQ\Parameters' -Name SysPrep -Value 1 -Type DWord
    Start-Service MSMQ
    foreach ($s in $restart) { Start-Service $s }
    if ($vmId) { Set-Content -Path $marker -Value $vmId -Encoding ASCII }
    Log "QMId $before -> $(Get-QmId) on VM $(if ($vmId) { $vmId } else { 'unknown (reset anyway)' }); restarted: $($restart -join ', ')"
} catch {
    Log "failed: $($_.Exception.Message)"
    exit 1
}
'@

$n = 0
foreach ($e in $entries) {
    $n++
    $name = "$($e.name)"
    $url = "$($e.blob_url)"
    $leaf = [uri]::UnescapeDataString((Split-Path ([uri]$url).AbsolutePath -Leaf))
    $ext = [IO.Path]::GetExtension($leaf).ToLowerInvariant()
    if (@('.msi', '.exe') -notcontains $ext) { Fail "Entry $n ($name): only .msi and .exe installers are supported, not '$leaf'." }
    $path = Join-Path $workDir $leaf
    Write-Host "== [$n/$($entries.Count)] $name ($leaf)"

    # Download and verify before anything is installed.
    Get-Blob $url $path
    $expected = "$($e.sha256)"
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') { Fail "Entry $n ($name): sha256 isn't a SHA-256 hash. 01-upload-installers.ps1 prints it." }
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($hash -ne $expected.ToUpperInvariant()) { Fail "SHA-256 mismatch for ${leaf}: expected $expected, got $hash. Re-upload it and update sha256." }
    $sig = Get-AuthenticodeSignature $path
    $subject = "$($sig.SignerCertificate.Subject)"
    if ($sig.Status -ne 'Valid') { Fail "${leaf}'s signature isn't valid ($($sig.Status)): $($sig.StatusMessage)" }
    # Windows quotes values that contain commas: O="Citrix Systems, Inc."
    if ($subject -notmatch ('(^|, )O="?' + [regex]::Escape("$($e.signer)") + '"?(,|$)')) {
        Fail "$leaf is signed by '$subject', not by O=$($e.signer) (signer)."
    }
    $version = Get-InstallerVersion $path
    # signer goes last: the subject contains spaces, commas and quotes.
    Write-Host "build-input: extra=$leaf sha256=$hash thumbprint=$($sig.SignerCertificate.Thumbprint) version=$version signer=$subject"

    # Windows features first (e.g. MSMQ-Server for the Session Recording agent).
    foreach ($f in @($e.windows_features | Where-Object { $_ })) {
        if ($isServer) {
            $r = Install-WindowsFeature -Name $f
            if (-not $r.Success) { Fail "Couldn't add Windows feature $f (exit code $($r.ExitCode))." }
            Write-Host "feature: $f (Install-WindowsFeature, restart needed: $($r.RestartNeeded))"
        } else {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
            Write-Host "feature: $f (Enable-WindowsOptionalFeature, restart needed: $($r.RestartNeeded))"
        }
    }

    # Install silently.
    $installArgs = "$($e.arguments)".Trim()
    if ($ext -eq '.msi') {
        $log = Join-Path $workDir "$leaf.log"
        $argList = @('/i', "`"$path`"", '/qn', '/norestart', '/l*v', "`"$log`"")
        if ($installArgs) { $argList += $installArgs }
        Write-Host "msiexec $($argList -join ' ')"
        $p = Start-Process msiexec.exe -ArgumentList $argList -Wait -PassThru
    } else {
        $log = $null
        Write-Host "$leaf $installArgs"
        $p = if ($installArgs) { Start-Process $path -ArgumentList $installArgs -Wait -PassThru } else { Start-Process $path -Wait -PassThru }
    }
    if ($okExit -notcontains $p.ExitCode) {
        if ($log -and (Test-Path $log)) {
            Write-Host "--- last lines of $log ---"
            Get-Content $log -Tail 40 | ForEach-Object { Write-Host $_ }
        }
        Fail "$name failed to install (exit $($p.ExitCode))."
    }
    Write-Host "installed-extra: $name|$version|exit=$($p.ExitCode)"

    if ($e.msmq_new_id_at_startup) {
        if (-not (Get-Service MSMQ -ErrorAction SilentlyContinue)) { Fail "Entry $n ($name): msmq_new_id_at_startup is set, but MSMQ isn't installed. Add MSMQ-Server to windows_features." }
        $dir = Join-Path $env:ProgramData 'FlexImageBuilder'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # SYSTEM runs this script and writes its log here: only SYSTEM and Administrators may change the folder.
        # ProgramData's inherited rights would let any signed-in user create files in it.
        & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "Couldn't restrict $dir to SYSTEM and Administrators (icacls exit $LASTEXITCODE)." }
        $script = Join-Path $dir 'Reset-MsmqId.ps1'
        Set-Content -Path $script -Value $resetScript -Encoding UTF8
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskPath '\FlexImageBuilder\' -TaskName 'Reset MSMQ ID at startup' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-Host "msmq-id-reset: startup task \FlexImageBuilder\Reset MSMQ ID at startup -> $script"
    }
}

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Extra installers complete: $($entries.Count)."
