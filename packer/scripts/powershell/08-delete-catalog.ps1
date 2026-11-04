# 08-delete-catalog.ps1
# Deletes a Citrix DaaS (Quick Deploy) catalog, sending the domain service account so the backend can
# remove the machines' AD computer accounts. Waits until the catalog is gone (NotFound).
#
# Why: for a domain-joined catalog, a delete without the join credentials ends in Error
# (ErrorDeletionUnknown). The Terraform provider's delete (citrix_quickdeploy_catalog) sends only
# deleteVm and deleteResourceLocationIfUnused, so `terraform destroy` fails the same way. Sending this
# credentialed delete again also recovers a catalog left in Error by an earlier delete.
#
# With Terraform, the order matters:
#   1. .\08-delete-catalog.ps1 -CatalogName <name> -TerraformDir <dir>   # delete, wait for NotFound, state rm
#   2. terraform destroy                                                 # everything else
# If you run terraform destroy while the delete is still running, the provider's own delete fails with
# "Deletion of this catalog is already in progress" and the destroy stops.
#
# Usage:
#   $env:CITRIX_CUSTOMER_ID / CITRIX_CLIENT_ID / CITRIX_CLIENT_SECRET as for 06-import-to-citrix.ps1
#   $env:TF_VAR_domain_service_account_password = "<join account password>"   # same variable Terraform uses
#   .\08-delete-catalog.ps1 -CatalogName "Task Worker Desktop" -WhatIf      # show what would happen
#   .\08-delete-catalog.ps1 -CatalogName "Task Worker Desktop"              # asks to confirm
#   .\08-delete-catalog.ps1 -CatalogName "Task Worker Desktop" -Confirm:$false   # unattended (pipelines, scripts)
#
# The service account defaults to the one the catalog was created with (domainServiceAccount).
# The password is read only from the environment variable named by -PasswordVariable, and never printed.

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High", DefaultParameterSetName = "ByName")]
param(
    [Parameter(Mandatory, ParameterSetName = "ByName")] [string]$CatalogName,
    [Parameter(Mandatory, ParameterSetName = "ById")]   [string]$CatalogId,

    # Domain account for the delete, e.g. svc-join@example.com. Default: the catalog's own.
    [string]$ServiceAccount,

    # Environment variable holding that account's password.
    [string]$PasswordVariable = "TF_VAR_domain_service_account_password",

    # Also remove the catalog's resource location (and its connectors) if no other catalog uses it.
    [switch]$DeleteResourceLocationIfUnused,

    # Optional: after NotFound, run `terraform state rm` for the catalog in this directory.
    [string]$TerraformDir,
    [string]$TerraformAddress = "module.catalog.citrix_quickdeploy_catalog.this",

    # A domain-joined delete usually takes 8-15 minutes.
    [int]$TimeoutMinutes = 45,
    [int]$PollSeconds = 30,

    [string]$ApiHost = "api.cloud.com",
    [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
    [string]$ClientId = $env:CITRIX_CLIENT_ID,
    [string]$SiteId
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "citrix-api.ps1")

Write-Host "`nConnecting to Citrix Cloud..."
Connect-CitrixApi -ApiHost $ApiHost -CustomerId $CustomerId -ClientId $ClientId -SiteId $SiteId

if ($CatalogName) { $CatalogId = Find-CitrixCatalogId $CatalogName }
$status = Get-CitrixCatalogStatus $CatalogId
if ($status.state -eq "NotFound") {
    Write-Host "Catalog $CatalogId doesn't exist (NotFound). Nothing to delete."
} else {
    $catalog = Get-CitrixCatalog $CatalogId
    Write-Host "`nCatalog: $($catalog.name) ($CatalogId)"
    Write-Host "  state $($status.state), domain-joined $([bool]$catalog.domainJoined), $($catalog.totalMachinesInCatalog) machine(s), region $($catalog.region)"

    $body = [ordered]@{
        forceDelete                    = $false
        deleteVm                       = $true
        deleteResourceLocationIfUnused = [bool]$DeleteResourceLocationIfUnused
    }
    if ($catalog.domainJoined -and $status.state -ne "Deleting") {
        if (-not $ServiceAccount) { $ServiceAccount = $catalog.domainServiceAccount }
        if (-not $ServiceAccount) { Write-Error "The catalog is domain-joined: pass -ServiceAccount." }
        $password = [Environment]::GetEnvironmentVariable($PasswordVariable)
        if (-not $password) {
            Write-Error "The catalog is domain-joined: set `$env:$PasswordVariable to the password of $ServiceAccount."
        }
        $body.serviceAccount         = $ServiceAccount
        $body.serviceAccountPassword = $password
        Write-Host "  join account: $ServiceAccount (password from `$env:$PasswordVariable)"
    }

    if ($status.state -eq "Deleting") {
        Write-Host "`nA delete is already running; waiting for it."
    } elseif (& {
        # Without a console to answer the prompt (a pipeline, Run Command, ssh without a tty), PowerShell
        # fails with "Object reference not set to an instance of an object". Say what to do instead.
        try { $PSCmdlet.ShouldProcess("$($catalog.name) ($CatalogId) and its machines", "Delete catalog") }
        catch { Write-Error "Can't ask for confirmation in this session ($($_.Exception.Message)). To delete without asking, add -Confirm:`$false." }
    }) {
        if ($status.state -eq "Error") { Write-Host "`nThe catalog is in Error (often a failed delete); sending the credentialed delete again." }
        Write-Host "`nDeleting..."
        # Content-Type: application/json is set on every request; without it this call returns 415.
        Invoke-CitrixApi DELETE "catalogs/$($CatalogId)?async=true" $body | Out-Null
        Write-Host "  Accepted."
    } else {
        return
    }

    # ── Wait for NotFound ──────────────────────────────────────────────────────
    Write-Host "`nWaiting for the catalog to be gone (Deleting → NotFound)..."
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $last = ""
    while ($true) {
        $status = Get-CitrixCatalogStatus $CatalogId
        $now = "$($status.state)/$($status.subState)"
        if ($now -ne $last) {
            Write-Host "  $([DateTime]::UtcNow.ToString('HH:mm:ss'))Z  $($status.state)$(if ($status.subState) { " ($($status.subState))" })$(if ($status.estimatedTimeInMinute) { ", estimate $($status.estimatedTimeInMinute) min" })"
            $last = $now
        }
        if ($status.state -eq "NotFound") { break }
        if ($status.state -eq "Error") {
            Write-Error ("The delete ended in Error: $($status.statusMessage) $($status.catalogErrorDetails) " +
                "Check the join account and its password, then run this script again; it re-sends the credentialed delete.")
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            Write-Error "The catalog is still $($status.state) after $TimeoutMinutes minutes. Run this script again to keep waiting."
        }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Host "`nCatalog deleted."
}

# ── Terraform state ────────────────────────────────────────────────────────────
if ($TerraformDir) {
    $inState = terraform -chdir="$TerraformDir" state list 2>$null | Where-Object { $_ -eq $TerraformAddress }
    if ($inState) {
        Write-Host "`nRemoving $TerraformAddress from the Terraform state in $TerraformDir..."
        terraform -chdir="$TerraformDir" state rm $TerraformAddress
        if ($LASTEXITCODE -ne 0) { Write-Error "terraform state rm failed (exit $LASTEXITCODE)" }
    } else {
        Write-Host "`n$TerraformAddress isn't in the Terraform state in $TerraformDir."
    }
    Write-Host "Next: terraform -chdir=`"$TerraformDir`" destroy"
} else {
    Write-Host "`nIf Terraform manages this catalog, remove it from state before destroying the rest:"
    Write-Host "  terraform state rm $TerraformAddress"
    Write-Host "  terraform destroy"
}
