[CmdletBinding()]
param(
    [string]$OutputPath = "D:\RDPState\baseline.json"
)

$ErrorActionPreference = "Stop"
$parent = Split-Path $OutputPath -Parent
if (!(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "      CAPTURING FRESH WINDOWS BASELINE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

$winget = @()
try {
    $winget = @(
        winget list --accept-source-agreements 2>$null |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -and $_ -notmatch "^Name\s+Id\s+Version" -and $_ -notmatch "^-+$" }
    )
} catch {
    Write-Warning "Could not capture winget inventory."
}

$python = @()
if (Get-Command python -ErrorAction SilentlyContinue) {
    try {
        $json = python -m pip list --format=json 2>$null
        if ($json) { $python = @($json | ConvertFrom-Json) }
    } catch {}
}

$node = @()
if (Get-Command npm -ErrorAction SilentlyContinue) {
    try {
        $json = npm list -g --depth=0 --json 2>$null
        if ($json) { $node = ($json | ConvertFrom-Json).dependencies }
    } catch {}
}

$baseline = [ordered]@{
    schemaVersion  = 1
    createdUtc     = (Get-Date).ToUniversalTime().ToString("o")
    computer       = $env:COMPUTERNAME
    windows        = (Get-CimInstance Win32_OperatingSystem).Caption
    wingetList     = $winget
    pythonPackages = $python
    nodeGlobal     = $node
}

$baseline | ConvertTo-Json -Depth 12 | Set-Content $OutputPath -Encoding UTF8
Write-Host "Baseline saved to: $OutputPath" -ForegroundColor Green
