# 02-build.ps1
# Runs a Packer build using our patched templates (SAS URL quoting fix applied).
# Clones citrix-packer-tools for the provisioner scripts, then renders a temporary copy of the
# template with this build's steps (Windows Update first, network mode) and builds from that.
#
# Usage:
#   .\02-build.ps1 -VarsFile win_server_2025.json -Os win_server_2025_dc -VdaVersion v2507
#
# OS options: win_server_2025_dc, win_server_2022_dc, win_server_2019_dc,
#             win_desktop_11_23h2, win_office_11_23h2
# VDA version options: v2407, v2411, v2503, v2507

param(
    [Parameter(Mandatory)]
    [string]$VarsFile,

    [Parameter(Mandatory)]
    [ValidateSet("win_desktop_11_23h2","win_office_11_23h2","win_server_11_23h2",
                 "win_server_2019_dc","win_server_2022_dc","win_server_2025_dc")]
    [string]$Os,

    [ValidateSet("v2407","v2411","v2503","v2507")]
    [string]$VdaVersion = "v2507",

    # CIDR allowed to reach the build VM's WinRM port (e.g. your egress IP as x.x.x.x/32).
    # Public-network builds only. Overrides allowed_inbound_ip in the vars file. Without either,
    # the build stops: Packer would otherwise open WinRM on the build VM to the whole internet.
    [string]$AllowedInboundIp,

    # Leave the build VM and its resources in place if the build fails (packer -on-error=abort),
    # so you can troubleshoot it. See "A build fails or hangs" in docs/troubleshooting.md.
    [switch]$KeepOnError,

    # Skip the Windows Update stage. For quick test builds only: images for users should be patched.
    [switch]$SkipWindowsUpdate,

    # More updates to exclude, by KB number or title pattern (e.g. KB5012170), if one loops or breaks the build.
    [string[]]$WindowsUpdateExclude = @(),

    # Optional app list: Chocolatey package IDs, one per line ('#' comments, "id version" pins a version).
    # Installed after the template's own steps, just before cleanup. See packer/apps/example.apps.txt.
    [string]$AppsFile,

    # Optional internal Chocolatey feed for the app installs; the community source is then disabled.
    [string]$ChocoSource,

    # Optional mirror of the pinned Chocolatey MSI, for builds that can't reach GitHub. Its hash and signature are still checked.
    [string]$ChocoMsiUrl,

    # citrix-packer-tools commit or tag to build with (its VDA, Optimizer and cleanup scripts), instead of
    # whatever is on main the day you build. The default is the commit this repo was last validated with.
    [string]$PackerToolsRef = "2d3a906959c3693ff7edbe51928b446f607eac44"
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..\..\..")

# Resolve vars file path
$varsFilePath = $VarsFile
if (-not [System.IO.Path]::IsPathRooted($VarsFile)) {
    $varsFilePath = Join-Path $repoRoot "packer\variables\$VarsFile"
}
if (-not (Test-Path $varsFilePath)) {
    Write-Error "Vars file not found: $varsFilePath"
}

# Auth: with use_azure_cli_auth (the default) Packer runs as your az CLI sign-in.
$vars = Get-Content $varsFilePath -Raw | ConvertFrom-Json
if ("$($vars.use_azure_cli_auth)" -ne "false") {
    $account = (az account show --query "{user:user.name, sub:name}" -o json 2>$null) | ConvertFrom-Json
    if (-not $account) { Write-Error "use_azure_cli_auth is on but az is not signed in. Run 'az login' first." }
    Write-Host "Packer will authenticate as $($account.user) (subscription: $($account.sub))."
}

# Network. The vars file picks the mode:
#  - private: virtual_network_name is set. The build VM joins that existing subnet with a private IP
#    only, so this script must run on a machine that can reach the subnet on WinRM (5986).
#    Use it where policy forbids public IPs, as most enterprise landing zones do.
#  - public (default): Packer creates a temporary VNet and gives the build VM a public IP.
$vnetName = "$($vars.virtual_network_name)"
$privateNetwork = [bool]$vnetName
if ($privateNetwork) {
    if (-not $vars.virtual_network_subnet_name -or -not $vars.virtual_network_resource_group_name) {
        Write-Error "virtual_network_name is set: also set virtual_network_subnet_name and virtual_network_resource_group_name in the vars file."
    }
    if ($AllowedInboundIp) { Write-Warning "-AllowedInboundIp is ignored: private-network builds create no public IP." }
    Write-Host ("Network: private. The build VM gets a private IP in $vnetName/$($vars.virtual_network_subnet_name) " +
                "and no public IP. This machine must reach that subnet on port 5986.")
} else {
    # The build VM has a public IP for WinRM. Restrict who can reach it.
    if (-not $AllowedInboundIp) { $AllowedInboundIp = "$($vars.allowed_inbound_ip)" }
    if (-not $AllowedInboundIp -or $AllowedInboundIp -like "<*") {
        Write-Error ("Set -AllowedInboundIp (or allowed_inbound_ip in the vars file) to the CIDR your traffic leaves from, " +
                     "e.g. 203.0.113.10/32. Find it with: Invoke-RestMethod https://api.ipify.org (or ask your network team). " +
                     "Use 0.0.0.0/0 only if you accept WinRM being reachable from anywhere during the build. " +
                     "If policy forbids public IPs, use a private-network build instead (set virtual_network_name).")
    }
    Write-Host "Network: public. WinRM on the build VM will accept connections only from $AllowedInboundIp."
}

# Installers: the build VM checks both downloads against these hashes, and the VDA installer's signature,
# before it installs anything. 01-upload-installers.ps1 prints them.
foreach ($k in 'vda_sha256', 'optimizer_sha256') {
    if ("$($vars.$k)" -notmatch '^[0-9a-fA-F]{64}$') {
        Write-Error "Set $k in the vars file to the installer's SHA-256. 01-upload-installers.ps1 prints it."
    }
}

# Apps (optional)
$chocoVersion = "2.7.4"   # Chocolatey CLI installed on the build VM. Change the version and the hash together.
$chocoMsiSha256 = "f39efebdc012525a7057f573f136f63af91a496efddd1db4c7910d657a5ac407"   # asset digest on the chocolatey/choco GitHub release
if (-not $ChocoMsiUrl) { $ChocoMsiUrl = "https://github.com/chocolatey/choco/releases/download/$chocoVersion/chocolatey-$chocoVersion.0.msi" }
if ($AppsFile) {
    $appsFilePath = $AppsFile
    if (-not (Test-Path $appsFilePath)) { $appsFilePath = Join-Path $repoRoot "packer\apps\$AppsFile" }
    if (-not (Test-Path $appsFilePath)) { Write-Error "Apps file not found: $AppsFile" }
    $appsFilePath = (Resolve-Path $appsFilePath).Path
    $appEntries = @(Get-Content $appsFilePath | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ })
    if (-not $appEntries) { Write-Error "Apps file has no package IDs: $appsFilePath" }
    Write-Host "Apps: $($appEntries.Count) Chocolatey packages from $appsFilePath (Chocolatey $chocoVersion$(if ($ChocoSource) { ", feed $ChocoSource" }))."
} elseif ($ChocoSource) {
    Write-Warning "-ChocoSource is ignored without -AppsFile."
}

# citrix-packer-tools provides the VDA, Optimizer and cleanup scripts. Pin it to -PackerToolsRef.
$packerToolsDir = Join-Path $repoRoot "citrix-packer-tools"
if (-not (Test-Path $packerToolsDir)) {
    Write-Host "Cloning citrix-packer-tools..."
    git clone --quiet https://github.com/citrix/citrix-packer-tools.git $packerToolsDir
} else {
    git -C $packerToolsDir fetch --quiet origin
}
git -C $packerToolsDir checkout --quiet --detach $PackerToolsRef
if ($LASTEXITCODE -ne 0) { Write-Error "Couldn't check out citrix-packer-tools at '$PackerToolsRef'." }
$packerToolsCommit = "$(git -C $packerToolsDir rev-parse HEAD)".Trim()
Write-Host "citrix-packer-tools: $packerToolsCommit"


# Use our patched template (fixes SAS URL quoting for PowerShell inline provisioners)
$patchedTemplate = Join-Path $repoRoot "packer\templates\${Os}_packer_template.json"
if (-not (Test-Path $patchedTemplate)) {
    Write-Error "Patched template not found: $patchedTemplate`nAvailable patched templates: win_server_2025_dc, win_desktop_11_23h2"
}

# The template references OS-version-specific scripts via relative paths (./ and ../scripts/)
# so we must run packer from the citrix-packer-tools version directory, with our template file
$versionDir = Join-Path $packerToolsDir "azure\$VdaVersion"

Write-Host "`nEnsuring Packer plugins are installed..."
packer plugins install github.com/hashicorp/azure v2.6.5
if (-not $SkipWindowsUpdate) {
    packer plugins install github.com/rgl/windows-update v0.18.5
    if ($LASTEXITCODE -ne 0) { Write-Error "Couldn't install the windows-update plugin (github.com/rgl/windows-update v0.18.5)." }
}
# Legacy JSON templates use the newest installed version of each plugin, so say if that isn't the pinned one.
$plugins = @(packer plugins installed | ForEach-Object { Split-Path $_ -Leaf } |
    ForEach-Object { if ($_ -match '^packer-plugin-([a-z-]+)_v([0-9.]+)_') { "$($Matches[1]) $($Matches[2])" } } | Sort-Object -Unique)
$newestAzure = @($plugins | Where-Object { $_ -like 'azure *' } | ForEach-Object { [version]($_ -split ' ')[1] } | Sort-Object)[-1]
if ($newestAzure -and $newestAzure -ne [version]"2.6.5") {
    Write-Warning "azure plugin $newestAzure is installed, and legacy JSON templates use the newest installed version. Remove it to build with the pinned v2.6.5."
}

Write-Host "`nRunning Packer build..."
Write-Host "  Template : $patchedTemplate"
Write-Host "  Scripts  : $versionDir"
Write-Host "  Vars     : $varsFilePath"
Write-Host ""

# Render: build from a temporary copy of the template with this build's changes. Legacy JSON
# templates can't include a provisioner conditionally, so optional steps are added here.
$t = Get-Content $patchedTemplate -Raw | ConvertFrom-Json
$packerArgs = @()
if ($privateNetwork) {
    # Packer refuses allowed_inbound_ip_addresses together with virtual_network_name.
    foreach ($b in $t.builders) { $b.PSObject.Properties.Remove("allowed_inbound_ip_addresses") }
} else {
    $packerArgs += "-var", "allowed_inbound_ip=$AllowedInboundIp"
}

$provisioners = [System.Collections.Generic.List[object]]::new()
if (-not $SkipWindowsUpdate) {
    # First, patch the marketplace image to current. Preview updates are excluded, and so is KB5007651
    # (the Defender "Windows Security platform" update): it's offered again after every install and
    # loops the provisioner indefinitely.
    $filters = @('exclude:$_.Title -like "*Preview*"', 'exclude:$_.Title -like "*KB5007651*"')
    foreach ($x in $WindowsUpdateExclude) { $filters += "exclude:`$_.Title -like `"*$x*`"" }
    $filters += 'include:$true'
    $provisioners.Add([pscustomobject][ordered]@{
        type            = "windows-update"
        search_criteria = "IsInstalled=0"
        filters         = $filters
    })
}
foreach ($p in $t.provisioners) { $provisioners.Add($p) }
if ($AppsFile) {
    # Apps go in just before the template's last step: cleanup, which wipes c:\setup.
    if ("$($provisioners[$provisioners.Count - 1].inline)" -notmatch 'script_cleanup') {
        Write-Error "Unexpected template shape: the last provisioner isn't the cleanup step."
    }
    $appEnv = @("CHOCO_VERSION=$chocoVersion", "CHOCO_MSI_URL=$ChocoMsiUrl", "CHOCO_MSI_SHA256=$chocoMsiSha256")
    if ($ChocoSource) { $appEnv += "CHOCO_SOURCE=$ChocoSource" }
    $appSteps = @(
        [pscustomobject][ordered]@{ type = "file"; source = $appsFilePath; destination = '{{user `location_setup`}}\apps.txt' }
        [pscustomobject][ordered]@{ type = "powershell"; script = (Join-Path $repoRoot "packer/scripts/provisioners/install-apps.ps1"); environment_vars = $appEnv }
        # Some installers return 3010 (reboot required): finish that before cleanup and capture.
        [pscustomobject][ordered]@{ type = "windows-restart"; restart_timeout = "30m" }
    )
    $provisioners.InsertRange($provisioners.Count - 1, [object[]]$appSteps)
}
$t.provisioners = $provisioners.ToArray()

# Base image: resolve "latest" to the exact marketplace version, so the build is repeatable and recorded.
$b0 = $t.builders[0]
$baseImage = "$($b0.image_publisher):$($b0.image_offer):$($b0.image_sku)"
$baseVersion = "$($vars.image_version)"
if (-not $baseVersion -or $baseVersion -eq "latest") {
    $baseVersion = @(az vm image list --location "$($vars.location)" --publisher $b0.image_publisher --offer $b0.image_offer --sku $b0.image_sku --all --query "[].version" -o tsv 2>$null) |
        Sort-Object { [version]$_ } | Select-Object -Last 1
}
if (-not $baseVersion) { Write-Error "Couldn't resolve the marketplace version of $baseImage in $($vars.location). Set image_version in the vars file." }
$packerArgs += "-var", "image_version=$baseVersion"
Write-Host "Base image: ${baseImage}:$baseVersion"

$template = Join-Path ([System.IO.Path]::GetTempPath()) "${Os}_build_$PID.json"
[System.IO.File]::WriteAllText($template, ($t | ConvertTo-Json -Depth 32))
$steps = if ($SkipWindowsUpdate) { "Windows Update skipped" } else { "Windows Update first" }
if ($AppsFile) { $steps += ", apps before cleanup" }
Write-Host "Rendered template: $($t.provisioners.Count) provisioners ($steps)."

$recordDir = Join-Path $repoRoot "build-records"
New-Item -ItemType Directory -Force -Path $recordDir | Out-Null
$buildLog = Join-Path $recordDir ("$($vars.gallery_image_name)-$($vars.gallery_image_version)-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + ".log")

Push-Location $versionDir
try {
    $onError = if ($KeepOnError) { "-on-error=abort" } else { "-on-error=cleanup" }
    if ($KeepOnError) {
        Write-Host "KeepOnError: on failure the build VM (pkrvm*) and its resources stay in the build resource group."
        Write-Host "Troubleshoot, then clean up: see 'A build fails or hangs' in docs/troubleshooting.md."
    }
    packer build $onError -var-file="$varsFilePath" @packerArgs "$template" 2>&1 | Tee-Object -FilePath $buildLog
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
    Remove-Item $template -ErrorAction SilentlyContinue
}

# Build record: what went into this image, written only after a successful build.
$out = @(Get-Content $buildLog) -replace '\x1b\[[0-9;]*m', ''
$published = $out | Select-String 'SharedImageGalleryImageVersion: (\S+)' | Select-Object -Last 1
if (-not $published) {
    Write-Warning "Packer didn't report a gallery version, so no build record was written. Log: $buildLog"
    exit 0
}
$galleryVersion = $published.Matches[0].Groups[1].Value
function Get-Field([string]$Line, [string]$Name) {
    if ($Line -match "\b$Name=(`"[^`"]*`"|\S+)") { $Matches[1].Trim('"') }
}
$vdaLine = "$($out | Where-Object { $_ -match 'build-input: vda=' } | Select-Object -Last 1)"
$optLine = "$($out | Where-Object { $_ -match 'build-input: optimizer=' } | Select-Object -Last 1)"
$vmLine  = "$($out | Where-Object { $_ -match 'build-vm: ' } | Select-Object -Last 1)"
$record = [ordered]@{
    schema       = 1
    built_utc    = (Get-Date).ToUniversalTime().ToString("o")
    template     = $Os
    network      = $(if ($privateNetwork) { "private" } else { "public" })
    gallery      = [ordered]@{ resource_group = $vars.image_resource_group; name = $vars.gallery_name; image = $vars.gallery_image_name; version = $galleryVersion }
    base_image   = [ordered]@{ urn = $baseImage; version = $baseVersion }
    installers   = [ordered]@{
        vda       = [ordered]@{ file = (Get-Field $vdaLine 'vda'); sha256 = (Get-Field $vdaLine 'sha256'); thumbprint = (Get-Field $vdaLine 'thumbprint'); signer = $(if ($vdaLine -match 'signer=(.+)$') { $Matches[1].Trim() }) }
        optimizer = [ordered]@{ file = (Get-Field $optLine 'optimizer'); sha256 = (Get-Field $optLine 'sha256'); template = (Get-Field $optLine 'template') }
    }
    build_vm     = [ordered]@{ os = (Get-Field $vmLine 'os'); build = (Get-Field $vmLine 'build'); secure_boot = (Get-Field $vmLine 'secureboot'); tpm = (Get-Field $vmLine 'tpm') }
    windows_update = [ordered]@{
        enabled   = (-not $SkipWindowsUpdate)
        excluded  = @('Preview', 'KB5007651') + $WindowsUpdateExclude
        installed = @($out | Where-Object { $_ -match 'Found Windows update' } | ForEach-Object { [regex]::Matches($_, 'KB\d+') | ForEach-Object Value } | Sort-Object -Unique)
    }
    apps         = @($out | ForEach-Object { if ($_ -match 'installed-app: ([^|\s]+)\|(\S+)') { [ordered]@{ id = $Matches[1]; version = $Matches[2] } } })
    downloads    = @($out | ForEach-Object { if ($_ -match 'download: (.+)$') { $Matches[1].Trim() } })
    tools        = [ordered]@{ packer = "$(packer version | Select-Object -First 1)".Trim(); plugins = $plugins; citrix_packer_tools = $packerToolsCommit; scripts = $VdaVersion }
}
$recordName = "$($vars.gallery_image_name)-$galleryVersion.json"
$recordPath = Join-Path $recordDir $recordName
$record | ConvertTo-Json -Depth 8 | Set-Content -Path $recordPath
Write-Host "`nBuild record: $recordPath"

# Keep a copy next to the installers, and the key fields on the gallery version itself.
$storageAccount = ([uri]$vars.vda_blob_url).Host.Split('.')[0]
az storage container create --auth-mode login --account-name $storageAccount --name build-records --only-show-errors -o none 2>$null
az storage blob upload --auth-mode login --account-name $storageAccount --container-name build-records --file $recordPath --name $recordName --overwrite --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { Write-Warning "Couldn't upload the build record to $storageAccount/build-records (needs Storage Blob Data Contributor). The local copy stands." }
az sig image-version update --resource-group $vars.image_resource_group --gallery-name $vars.gallery_name --gallery-image-definition $vars.gallery_image_name --gallery-image-version $galleryVersion `
    --set "tags.vda=$($record.installers.vda.file)" "tags.vdaSha256=$($record.installers.vda.sha256)" "tags.baseImage=$baseVersion" "tags.packerTools=$($packerToolsCommit.Substring(0, 12))" "tags.buildRecord=build-records/$recordName" `
    --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { Write-Warning "Couldn't tag gallery version $galleryVersion with the build record's key fields." }

Write-Host "`nBuild complete. Run 04-export-from-gallery.ps1 to export the OS VHD (+ VMGS) and get the SAS URIs for Terraform."
