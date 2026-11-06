# lab-05-collect-results.ps1
# Copies build records, logs and any other files you name into a results folder, with secrets and
# identifiers removed, so they can be shared. See docs/lab-environment.md.
#
# Secrets (SAS tokens, passwords, client secrets, bearer tokens, private keys, and the values of the
# lab's secret environment variables) are removed and flagged, because a secret in a log needs follow-up.
# Identifiers (GUIDs, email addresses, public IP addresses, storage account names, and anything in
# -RedactText) are removed without a flag. It reports what it found but never prints the values.
#
# This is pattern matching, so read the results before you share them. It can miss things.
#
# Usage:
#   .\lab-05-collect-results.ps1
#   .\lab-05-collect-results.ps1 -Path C:\temp\import-output.txt -RedactText my-tenant.example, rg-mine
#
# Exits with 1 if it found a secret: rotate or revoke it, and work out how it got there.

[CmdletBinding()]
param(
    # Build records and logs. Default: build-records in the repo.
    [string]$RecordsDir = (Join-Path $PSScriptRoot "..\..\..\build-records"),

    # More files to include.
    [string[]]$Path = @(),

    # More text to remove, such as tenant or resource names.
    [string[]]$RedactText = @(),

    # Where to write the results. Default: lab-results in the repo, which is git-ignored.
    [string]$OutDir = (Join-Path $PSScriptRoot "..\..\..\lab-results")
)

$ErrorActionPreference = "Stop"

$secretPatterns = @(
    @{ Type = "SAS token";        Pattern = '\?[^\s"''<>]*\bsig=[^\s"''<>&]+[^\s"''<>]*';  Replace = '?<sas-removed>' }
    @{ Type = "Bearer token";     Pattern = '(?i)(Bearer[ =])[A-Za-z0-9\-._~+/]{8,}=*';    Replace = '$1<token-removed>' }
    @{ Type = "JWT";              Pattern = '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*'; Replace = '<token-removed>' }
    @{ Type = "Private key";      Pattern = '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|\z)'; Replace = '<private-key-removed>' }
    @{ Type = "Storage key";      Pattern = '(?i)(AccountKey=)[^;\s"'']+';                 Replace = '$1<key-removed>' }
    @{ Type = "Named secret";     Pattern = '(?i)("?\b(?:client_secret|clientSecret|password|passwd|userpass|winrm_password)\b"?\s*[:=]\s*"?)(?!<|\{\{|"|\s|\$|sensitive)[^\s",;]+'; Replace = '$1<secret-removed>' }
)

$identifierPatterns = @(
    @{ Type = "GUID";          Pattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'; Replace = '<guid>' }
    @{ Type = "Email address"; Pattern = '(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b';                          Replace = '<email>' }
    @{ Type = "Public IP";     Pattern = '\b(?!(?:10|127|0)\.)(?!192\.168\.)(?!172\.(?:1[6-9]|2\d|3[01])\.)(?!169\.254\.)(?:\d{1,3}\.){3}\d{1,3}\b(?!\.\d)'; Replace = '<ip>' }
    @{ Type = "Storage name";  Pattern = '(?i)\b[a-z0-9]{3,24}(\.(?:blob|file|queue|table|dfs)\.core\.windows\.net)'; Replace = '<storage-account>$1' }
)

$secretVariables = "CITRIX_CLIENT_SECRET", "TF_VAR_citrix_client_secret", "TF_VAR_domain_service_account_password", "ARM_CLIENT_SECRET", "AZURE_CLIENT_SECRET"

function Remove-Sensitive([string]$Text, [hashtable]$Counts) {
    # Exact values first, so a pattern can't leave part of one behind.
    foreach ($name in $secretVariables) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $value.Length -ge 4 -and $Text.Contains($value)) {
            $Counts["Secret: value of $name"] = ([regex]::Matches($Text, [regex]::Escape($value))).Count
            $Text = $Text.Replace($value, "<secret-removed>")
        }
    }
    foreach ($p in $secretPatterns) {
        $n = ([regex]::Matches($Text, $p.Pattern)).Count
        if ($n) { $Counts["Secret: $($p.Type)"] = $n; $Text = [regex]::Replace($Text, $p.Pattern, $p.Replace) }
    }
    foreach ($item in $RedactText) {
        if ($item -and $Text.Contains($item)) {
            $Counts["Identifier: named text"] = [int]$Counts["Identifier: named text"] + ([regex]::Matches($Text, [regex]::Escape($item))).Count
            $Text = $Text.Replace($item, "<redacted>")
        }
    }
    foreach ($p in $identifierPatterns) {
        $n = ([regex]::Matches($Text, $p.Pattern)).Count
        if ($n) { $Counts["Identifier: $($p.Type)"] = $n; $Text = [regex]::Replace($Text, $p.Pattern, $p.Replace) }
    }
    $Text
}

$files = @()
if (Test-Path $RecordsDir) { $files += @(Get-ChildItem $RecordsDir -File -Recurse | Where-Object Extension -in ".json", ".log", ".txt", ".md") }
foreach ($item in $Path) {
    if (-not (Test-Path $item -PathType Leaf)) { throw "Not a file: $item" }
    $files += Get-Item $item
}
if (-not $files.Count) { throw "Nothing to collect. Looked in $RecordsDir. Use -Path to add files." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$rows = foreach ($file in $files) {
    $counts = @{}
    $clean = Remove-Sensitive ([IO.File]::ReadAllText($file.FullName)) $counts
    [IO.File]::WriteAllText((Join-Path $OutDir $file.Name), $clean, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ File = $file.Name; Counts = $counts }
}

$secretTotal = 0
$lines = @("# Lab results", "", "Collected $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))Z. Read these files before you share them: removal is pattern matching and can miss things.", "", "| File | Secrets flagged | Identifiers removed |", "|---|---|---|")
foreach ($row in $rows) {
    $secrets = @($row.Counts.Keys | Where-Object { $_ -like "Secret:*" } | Sort-Object)
    $ids = @($row.Counts.Keys | Where-Object { $_ -like "Identifier:*" } | Sort-Object)
    $secretTotal += $secrets.Count
    $secretText = if ($secrets) { ($secrets | ForEach-Object { "$($_ -replace '^Secret: ') ($($row.Counts[$_]))" }) -join ", " } else { "none" }
    $idText = if ($ids) { ($ids | ForEach-Object { "$($_ -replace '^Identifier: ') ($($row.Counts[$_]))" }) -join ", " } else { "none" }
    $lines += "| $($row.File) | $secretText | $idText |"
}
[IO.File]::WriteAllText((Join-Path $OutDir "summary.md"), (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

$lines | Select-Object -Skip 4 | ForEach-Object { Write-Host $_ }
Write-Host "`nResults: $OutDir"
if ($secretTotal) {
    Write-Warning "Secrets were found in the source files. They're removed from the results, but the originals still contain them. Rotate or revoke them."
    exit 1
}
