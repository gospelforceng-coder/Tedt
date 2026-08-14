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

# --- Winget-based delta ---
$baselineWingetIds = @($baseline.wingetList | ForEach-Object { Parse-WingetLine $_ } | Where-Object { $_ } | Select-Object -ExpandProperty Id)
$currentWingetEntries = @($current.wingetList | ForEach-Object { Parse-WingetLine $_ } | Where-Object { $_ })
$newWingetApps = $currentWingetEntries | Where-Object { $_.Id -notin $baselineWingetIds -and -not (Test-IsExcluded $_.Name) }

# --- Registry-based delta (catches non-winget installs) ---
$baselineNames = @($baseline.registrySoftware | ForEach-Object { $_.DisplayName }) | Where-Object { $_ }
$currentRegistry = @($current.registrySoftware)
$newRegistryApps = $currentRegistry | Where-Object {
    $_.DisplayName -and ($_.DisplayName -notin $baselineNames) -and -not (Test-IsExcluded $_.DisplayName)
}

$alreadyCoveredNames = @($newWingetApps | ForEach-Object { $_.Name.ToLower() })
$delta = @()
$skipped = @()

foreach ($app in $newWingetApps) {
    $delta += [ordered]@{ name = $app.Name; wingetId = $app.Id; resolved = $true; matchType = "winget-list" }
}

foreach ($app in $newRegistryApps) {
    $cleanName = ($app.DisplayName.ToLower() -replace '[^a-z0-9]', '')
    $alreadyHandled = $alreadyCoveredNames | Where-Object {
        ($_ -replace '[^a-z0-9]', '') -match [regex]::Escape($cleanName.Substring(0, [Math]::Min(6, $cleanName.Length)))
    }
    if ($alreadyHandled) { continue }

    Write-Host "Searching winget for match: $($app.DisplayName)..." -ForegroundColor Gray
    $wingetId = $null
    try {
        $searchResult = winget search --name "$($app.DisplayName)" --accept-source-agreements 2>$null
        $parsedResults = @($searchResult | ForEach-Object { Parse-WingetLine $_ } | Where-Object { $_ })
        if ($parsedResults.Count -gt 0) { $wingetId = $parsedResults[0].Id }
    } catch {}

    $delta += [ordered]@{
        name      = $app.DisplayName
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