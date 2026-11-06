# lab-01-check-prereqs.ps1
# Checks that a lab is ready to use, and lists what's missing. Read-only: it changes nothing.
# See docs/lab-environment.md.
#
# Checks: tools, the Azure subscription, your roles on it, free vCPU quota for the build VM, policies
# that may block public IPs, the Citrix environment variables, Citrix API access and the network connection.
# It doesn't print subscription IDs, tenant IDs or secrets, so its output is safe to share.
#
# Usage:
#   az login
#   $env:CITRIX_CUSTOMER_ID / CITRIX_CLIENT_ID / CITRIX_CLIENT_SECRET as for 06-import-to-citrix.ps1
#   .\lab-01-check-prereqs.ps1 -SubscriptionId <subscription-id> -Location <region> -Connection <connection name>
#
# Exits with 1 if any check fails. A WARN needs a decision from you, but doesn't stop the lab.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$Location,

    # vCPUs free for the build VM. The default build VM, Standard_D2s_v3, uses 2.
    [int]$RequiredVCpus = 2,
    # The quota family of the build VM's size, as listed by az vm list-usage.
    [string]$VmFamily = "standardDSv3Family",

    # The network connection the lab will use (name or ID).
    [string]$Connection,

    # Skip the Citrix checks, to check Azure on its own.
    [switch]$SkipCitrix,

    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    [string]$SiteId
)

$ErrorActionPreference = "Continue"
$script:results = [System.Collections.ArrayList]::new()

function Add-Check([string]$Status, [string]$Name, [string]$Detail) {
    [void]$script:results.Add([pscustomobject]@{ Status = $Status; Check = $Name; Detail = $Detail })
}

# Runs az and returns parsed JSON. $script:AzOk says whether the command succeeded.
function Invoke-AzJson {
    $output = & az @args -o json 2>$null
    $script:AzOk = $LASTEXITCODE -eq 0
    if (-not $script:AzOk -or -not $output) { return $null }
    # Assign first: Windows PowerShell 5.1 otherwise passes a JSON array down the pipeline as one item.
    $parsed = ($output | Out-String) | ConvertFrom-Json
    $parsed
}

# -- Tools ----------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -ge 7) { Add-Check PASS "PowerShell 7" "$($PSVersionTable.PSVersion)" }
else { Add-Check FAIL "PowerShell 7" "Running $($PSVersionTable.PSVersion). The Citrix scripts need PowerShell 7." }

foreach ($tool in "az", "packer", "git", "azcopy", "terraform") {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Add-Check PASS "Tool: $tool" "found" }
    else { Add-Check FAIL "Tool: $tool" "not found. Run lab-00-install-tools.ps1." }
}

# -- Azure ----------------------------------------------------------------------
$account = if (Get-Command az -ErrorAction SilentlyContinue) { Invoke-AzJson account show --subscription $SubscriptionId } else { $null }
if (-not $account) {
    Add-Check FAIL "Azure subscription" "Can't read it. Run az login, and check the subscription ID."
} else {
    if ($account.state -eq "Enabled") { Add-Check PASS "Azure subscription" "'$($account.name)' is enabled" }
    else { Add-Check FAIL "Azure subscription" "'$($account.name)' is $($account.state)" }

    # Roles: setup creates role assignments, so it needs Owner, or Contributor and User Access Administrator.
    $userId = & az ad signed-in-user show --query id -o tsv 2>$null
    $roles = if ($userId) {
        Invoke-AzJson role assignment list --assignee $userId --scope "/subscriptions/$SubscriptionId" --include-inherited --include-groups --query "[].roleDefinitionName"
    }
    if (-not $userId -or -not $script:AzOk) {
        Add-Check WARN "Roles for setup" "Can't read your role assignments. Setup needs Owner, or Contributor and User Access Administrator."
    } elseif ($roles -contains "Owner" -or ($roles -contains "Contributor" -and $roles -contains "User Access Administrator")) {
        Add-Check PASS "Roles for setup" (@($roles | Sort-Object -Unique) -join ", ")
    } else {
        Add-Check FAIL "Roles for setup" "You need Owner, or Contributor and User Access Administrator. You have: $(@($roles | Sort-Object -Unique) -join ', ')"
    }

    # Quota, for the region as a whole and for the build VM's family.
    $usage = Invoke-AzJson vm list-usage --location $Location --subscription $SubscriptionId
    if (-not $script:AzOk) {
        Add-Check WARN "vCPU quota" "Can't read quota for $Location."
    } else {
        foreach ($quota in @(@{ Key = "cores"; Label = "Regional vCPUs" }, @{ Key = $VmFamily; Label = "$VmFamily vCPUs" })) {
            $item = @($usage | Where-Object { $_.name.value -eq $quota.Key }) | Select-Object -First 1
            if (-not $item) { Add-Check WARN $quota.Label "Not listed for $Location."; continue }
            $free = [int]$item.limit - [int]$item.currentValue
            $detail = "$free free of $($item.limit) in $Location; the build needs $RequiredVCpus"
            if ($free -ge $RequiredVCpus) { Add-Check PASS $quota.Label $detail }
            else { Add-Check FAIL $quota.Label "$detail. Deallocate a VM, or request more quota." }
        }
    }

    # Policy. Names are only a hint: a build is the real test.
    $policies = Invoke-AzJson policy assignment list --subscription $SubscriptionId --disable-scope-strict-match --query "[].displayName"
    if (-not $script:AzOk) {
        Add-Check WARN "Public IP policy" "Can't read policy assignments."
    } else {
        $hits = @($policies | Where-Object { $_ -match "public\s*ip" })
        if ($hits.Count) { Add-Check WARN "Public IP policy" "May block public-network builds: $($hits -join '; '). See private-network builds in docs/custom-images.md." }
        else { Add-Check PASS "Public IP policy" "No assignment named for public IPs" }
    }
}

# -- Citrix ---------------------------------------------------------------------
if (-not $SkipCitrix) {
    $varsSet = $true
    foreach ($name in "CITRIX_CUSTOMER_ID", "CITRIX_CLIENT_ID", "CITRIX_CLIENT_SECRET") {
        if ([Environment]::GetEnvironmentVariable($name)) { Add-Check PASS "Variable: $name" "set" }
        else { Add-Check FAIL "Variable: $name" "not set"; $varsSet = $false }
    }

    if (-not $varsSet) {
        Add-Check WARN "Citrix API" "Skipped: set the variables above first."
    } elseif ($PSVersionTable.PSVersion.Major -lt 7) {
        Add-Check WARN "Citrix API" "Skipped: needs PowerShell 7."
    } else {
        try {
            $ErrorActionPreference = "Stop"
            . (Join-Path $PSScriptRoot "..\powershell\citrix-api.ps1")
            Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId 6>$null
            $connections = @((Invoke-CitrixApi GET "managedCapacity/onPremConnections").items)
            Add-Check PASS "Citrix API" "Signed in; $($connections.Count) network connection(s) listed"

            if ($Connection) {
                $conn = $connections | Where-Object { $_.id -eq $Connection -or $_.name -eq $Connection } | Select-Object -First 1
                if (-not $conn) {
                    Add-Check FAIL "Network connection" "'$Connection' isn't listed."
                } else {
                    $catalogCount = @($conn.catalogs).Count
                    if ($catalogCount) { Add-Check WARN "Network connection" "'$($conn.name)' has $catalogCount catalog(s). Opening a port affects all of them, so none should be in production." }
                    else { Add-Check PASS "Network connection" "'$($conn.name)' has no catalogs" }
                }
            } else {
                Add-Check WARN "Network connection" "Not checked. Pass -Connection."
            }
        } catch {
            Add-Check FAIL "Citrix API" "$($_.Exception.Message)"
        } finally {
            $ErrorActionPreference = "Continue"
        }
    }
}

# -- Results --------------------------------------------------------------------
$colors = @{ PASS = "Green"; WARN = "Yellow"; FAIL = "Red" }
Write-Host ""
foreach ($r in $script:results) {
    Write-Host ("  {0}  " -f $r.Status) -ForegroundColor $colors[$r.Status] -NoNewline
    Write-Host ("{0,-28} {1}" -f $r.Check, $r.Detail)
}
$failed = @($script:results | Where-Object Status -eq "FAIL").Count
$warned = @($script:results | Where-Object Status -eq "WARN").Count
Write-Host "`n$failed failed, $warned to review."
if ($failed) { exit 1 }
