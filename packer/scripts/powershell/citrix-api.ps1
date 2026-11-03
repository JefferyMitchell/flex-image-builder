# citrix-api.ps1
# Shared helpers for the Citrix DaaS Quick Deploy (catalogservice) API. Dot-sourced by
# 06-import-to-citrix.ps1, 07-update-catalog-image.ps1 and 08-delete-catalog.ps1; not run directly.
#
# Credentials come from environment variables only, the same ones the Terraform provider reads:
#   CITRIX_CUSTOMER_ID    Citrix Cloud customer ID (or pass -CustomerId)
#   CITRIX_CLIENT_ID      API client ID           (or pass -ClientId)
#   CITRIX_CLIENT_SECRET  API client secret       (environment variable only, never a parameter)
# The secret is sent once, to the token endpoint, and never printed. The token lasts an hour, and
# Invoke-CitrixApi gets a new one when it has less than five minutes left.
#
# Notes on the API (each one cost time to find):
# - The auth header is "CwsAuth Bearer=<token>", not a plain "Bearer <token>".
# - Image and catalog calls are site-scoped: /catalogservice/{customerId}/{siteId}/... The site ID
#   isn't shown in the console; it comes from GET /cvad/manage/me (Customers[0].Sites[0].Id).
# - The API ignores request fields it doesn't recognize and still succeeds, so every write is
#   followed by a read-back of the fields that matter.
# - Every request carries Content-Type: application/json. A DELETE without it gets HTTP 415, even
#   with an empty body.

$ErrorActionPreference = "Stop"

$script:CitrixApi = $null
$script:CitrixImageList = $null

function Connect-CitrixApi {
    param(
        [string]$ApiHost = "api.cloud.com",
        [string]$CustomerId = $env:CITRIX_CUSTOMER_ID,
        [string]$ClientId = $env:CITRIX_CLIENT_ID,
        [string]$SiteId
    )
    if (-not $CustomerId) { Write-Error "Set CITRIX_CUSTOMER_ID (or pass -CustomerId)." }
    if (-not $ClientId)   { Write-Error "Set CITRIX_CLIENT_ID (or pass -ClientId)." }
    if (-not $env:CITRIX_CLIENT_SECRET) { Write-Error "Set CITRIX_CLIENT_SECRET. The client secret is read from the environment only." }

    $script:CitrixApi = @{
        ApiHost    = $ApiHost
        CustomerId = $CustomerId
        ClientId   = $ClientId
        Token      = $null
        Expires    = [DateTime]::MinValue
    }
    Update-CitrixToken

    if (-not $SiteId) {
        $me = Invoke-CitrixRequest -Method GET -Uri "https://$ApiHost/cvad/manage/me"
        $sites = @($me.Customers | Where-Object { $_.Id -eq $CustomerId } | ForEach-Object { $_.Sites })
        if (-not $sites) { $sites = @($me.Customers[0].Sites) }
        if (-not $sites -or -not $sites[0].Id) { Write-Error "GET /cvad/manage/me returned no site for customer $CustomerId." }
        if ($sites.Count -gt 1) { Write-Warning "Customer has $($sites.Count) sites; using the first ($($sites[0].Id)). Pass -SiteId to choose." }
        $SiteId = $sites[0].Id
    }
    $script:CitrixApi.SiteId  = $SiteId
    $script:CitrixApi.BaseUri = "https://$ApiHost/catalogservice/$CustomerId/$SiteId"
    Write-Host "  Citrix API : $ApiHost, customer $CustomerId, site $SiteId"
}

function Update-CitrixToken {
    $ctx = $script:CitrixApi
    $form = @{
        grant_type    = "client_credentials"
        client_id     = $ctx.ClientId
        client_secret = $env:CITRIX_CLIENT_SECRET
    }
    $resp = Invoke-WebRequest -Method POST -Uri "https://$($ctx.ApiHost)/cctrustoauth2/root/tokens/clients" `
        -Body $form -ContentType "application/x-www-form-urlencoded" -SkipHttpErrorCheck
    if ($resp.StatusCode -ne 200) {
        Write-Error "Citrix token request failed (HTTP $($resp.StatusCode)). Check CITRIX_CLIENT_ID, CITRIX_CLIENT_SECRET and -ApiHost."
    }
    $tok = $resp.Content | ConvertFrom-Json
    $ctx.Token   = $tok.access_token
    $ctx.Expires = [DateTime]::UtcNow.AddSeconds([int]$tok.expires_in)
}

# Low-level call with the CwsAuth headers. Throws on any non-2xx status with the API's error body
# (never the request body, which can hold a password).
function Invoke-CitrixRequest {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        $Body
    )
    $ctx = $script:CitrixApi
    if ($ctx.Expires -lt [DateTime]::UtcNow.AddMinutes(5)) { Update-CitrixToken }
    $headers = @{
        Authorization       = "CwsAuth Bearer=$($ctx.Token)"
        "Citrix-CustomerId" = $ctx.CustomerId
        Accept              = "application/json"
    }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
    $resp = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers -Body $json `
        -ContentType "application/json" -SkipHttpErrorCheck
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -gt 299) {
        $err = [Exception]::new("$Method $Uri returned HTTP $($resp.StatusCode): $($resp.Content)")
        $err.Data["StatusCode"] = [int]$resp.StatusCode
        throw $err
    }
    if (-not $resp.Content) { return $null }
    try { return $resp.Content | ConvertFrom-Json } catch { return $resp.Content }
}

# Call relative to the site-scoped Quick Deploy base: Invoke-CitrixApi GET "images/$id".
# Paths containing $import / $updateImage must be single-quoted (or escaped) in the caller.
function Invoke-CitrixApi {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        $Body
    )
    Invoke-CitrixRequest -Method $Method -Uri "$($script:CitrixApi.BaseUri)/$Path" -Body $Body
}

function Get-CitrixImage([string]$ImageId) {
    Invoke-CitrixApi GET "images/$ImageId"
}

# The image's entry in the site's image list (fetched once). For Citrix-prepared images the detail
# GET above reports hyperVGen V1 and no region, even for Gen2 images; the list has the right values.
function Find-CitrixImageInList([string]$ImageId) {
    if ($null -eq $script:CitrixImageList) { $script:CitrixImageList = @((Invoke-CitrixApi GET "images").items) }
    $script:CitrixImageList | Where-Object { $_.id -eq $ImageId } | Select-Object -First 1
}

function Get-CitrixCatalog([string]$CatalogId) {
    Invoke-CitrixApi GET "catalogs/$CatalogId"
}

# Resolves -CatalogName to an ID. Fails unless exactly one catalog has that name.
function Find-CitrixCatalogId([string]$Name) {
    $list = Invoke-CitrixApi GET "catalogs"
    $found = @($list.items | Where-Object { $_.name -eq $Name })
    if ($found.Count -eq 0) {
        Write-Error "No catalog named '$Name'. Catalogs: $(($list.items.name | Sort-Object) -join ', ')"
    }
    if ($found.Count -gt 1) { Write-Error "$($found.Count) catalogs are named '$Name'. Pass -CatalogId instead." }
    $found[0].id
}

# Catalog state from catalogs/status, which keeps answering while a catalog is being deleted.
# Returns an object with state, subState, statusMessage...; state is "NotFound" once it's gone.
function Get-CitrixCatalogStatus([string]$CatalogId) {
    $resp = Invoke-CitrixApi GET "catalogs/status?catalogId=$CatalogId"
    $entry = $null
    if ($resp.catalogsStatus) { $entry = $resp.catalogsStatus.PSObject.Properties[$CatalogId].Value }
    if (-not $entry) { return [pscustomobject]@{ state = "NotFound" } }
    $entry
}

# The generation and Trusted Launch flags of an image, normalized for comparison.
function Get-ImageFlags($Image) {
    [pscustomobject]@{
        hyperVGen         = "$($Image.hyperVGen)"
        vtpmEnabled       = [bool]$Image.vtpmEnabled
        secureBootEnabled = [bool]$Image.secureBootEnabled
    }
}

# Returns the names of the flags that differ between two Get-ImageFlags results.
function Compare-ImageFlags($Expected, $Actual) {
    @("hyperVGen", "vtpmEnabled", "secureBootEnabled") | Where-Object { $Expected.$_ -ne $Actual.$_ }
}

# A SAS URI without its token, for logs.
function Format-SafeUri([string]$Uri) {
    if (-not $Uri) { return "" }
    ($Uri -split '\?')[0] + $(if ($Uri.Contains('?')) { '?<SAS>' } else { '' })
}
