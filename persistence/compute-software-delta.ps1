# ==================================================
# compute-software-delta.ps1
# ==================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$CurrentPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ExclusionListPath = ""
)

$ErrorActionPreference = "Stop"

function Parse-WingetLine {
    param([string]$Line)
    $parts = $Line -split '\s{2,}' | Where-Object { $_ -ne '' }
    if ($parts.Count -ge 3) {
        return [pscustomobject]@{
            Name   = $parts[0].Trim()
            Id     = $parts[1].Trim()
            Source = $parts[-1].Trim()
        }
    }
    return $null
}

# winget prints a synthetic "ARP\..." path in the Id column for programs it
# only detected via Add/Remove Programs (no real winget source/catalog entry).
# That string is NOT installable via `winget install --id`, so it must never
# be trusted as a resolved ID - it has to go through name-based search instead.
function Test-IsRealWingetId {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    if ($Id -match '^ARP\\') { return $false }
    return $true
}

$excludedNames = @()
if ($ExclusionListPath -and (Test-Path $ExclusionListPath)) {
    $excludedNames = @((Get-Content $ExclusionListPath -Raw | ConvertFrom-Json).excludedAppNames | ForEach-Object { $_.ToLower() })
}

function Test-IsExcluded {
    param([string]$Name)
    foreach ($ex in $excludedNames) {
        if ($Name.ToLower() -match [regex]::Escape($ex)) { return $true }
    }
    return $false
}

$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json
$current  = Get-Content $CurrentPath -Raw | ConvertFrom-Json

if (-not ($baseline.PSObject.Properties.Name -contains 'wingetList') -or
    -not ($baseline.PSObject.Properties.Name -contains 'registrySoftware')) {
    throw "Baseline at $BaselinePath is missing wingetList/registrySoftware - it was not produced by scan-software-state.ps1's schema. Re-run capture-baseline.ps1 before computing a delta, or everything on the system will look 'new'."
}

# --- Winget-based delta ---
$baselineWingetIds = @($baseline.wingetList | ForEach-Object { Parse-WingetLine $_ } | Where-Object { $_ } | Select-Object -ExpandProperty Id)
$currentWingetEntries = @($current.wingetList | ForEach-Object { Parse-WingetLine $_ } | Where-Object { $_ })

# Split current winget entries into ones with a real catalog ID vs ARP-only
# pseudo-IDs. Only real IDs can skip straight to "resolved".
$newWingetEntries = $currentWingetEntries | Where-Object { $_.Id -notin $baselineWingetIds -and -not (Test-IsExcluded $_.Name) }
$newWingetApps        = $newWingetEntries | Where-Object { Test-IsRealWingetId $_.Id }
$newWingetNeedsSearch = $newWingetEntries | Where-Object { -not (Test-IsRealWingetId $_.Id) }

# --- Registry-based delta (catches non-winget installs) ---
$baselineNames = @($baseline.registrySoftware | ForEach-Object { $_.DisplayName }) | Where-Object { $_ }
$currentRegistry = @($current.registrySoftware)
$newRegistryApps = $currentRegistry | Where-Object {
    $_.DisplayName -and ($_.DisplayName -notin $baselineNames) -and -not (Test-IsExcluded $_.DisplayName)
}

$delta = @()
$skipped = @()

# Apps with a real, directly-installable winget ID
foreach ($app in $newWingetApps) {
    $delta += [ordered]@{ name = $app.Name; wingetId = $app.Id; resolved = $true; matchType = "winget-list" }
}

# Everything else that needs a name-based winget search: ARP-only winget-list
# entries (like Android Studio) plus registry-only entries. Combine and dedupe
# by cleaned name so the same app doesn't get searched/queued twice.
$namesNeedingSearch = @()
$namesNeedingSearch += $newWingetNeedsSearch | ForEach-Object { [pscustomobject]@{ Name = $_.Name } }
$namesNeedingSearch += $newRegistryApps | ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName } }

$seenClean = @{}
foreach ($app in $namesNeedingSearch) {
    $cleanName = ($app.Name.ToLower() -replace '[^a-z0-9]', '')
    if ($seenClean.ContainsKey($cleanName)) { continue }
    $seenClean[$cleanName] = $true

    Write-Host "Searching winget for match: $($app.Name)..." -ForegroundColor Gray
    $wingetId = $null
    try {
        $searchResult = winget search --name "$($app.Name)" --accept-source-agreements 2>$null
        $parsedResults = @($searchResult | ForEach-Object { Parse-WingetLine $_ } | Where-Object { $_ })
        if ($parsedResults.Count -gt 0) { $wingetId = $parsedResults[0].Id }
    } catch {}

    $delta += [ordered]@{
        name      = $app.Name
        wingetId  = $wingetId
        resolved  = [bool]$wingetId
        matchType = if ($wingetId) { "winget-search" } else { "unresolved" }
    }
}

foreach ($app in ($currentRegistry | Where-Object { $_.DisplayName -and (Test-IsExcluded $_.DisplayName) })) {
    $skipped += $app.DisplayName
}

$delta | ConvertTo-Json -Depth 8 | Set-Content $OutputPath -Encoding UTF8

$resolvedCount = @($delta | Where-Object { $_.resolved }).Count
Write-Host "[OK] Delta: $($delta.Count) new apps, $resolvedCount resolved to winget." -ForegroundColor Green
if ($skipped.Count -gt 0) {
    Write-Host "Excluded from winget (manual install apps present): $($skipped -join ', ')" -ForegroundColor DarkGray
}
Write-Host "Saved to $OutputPath" -ForegroundColor Green