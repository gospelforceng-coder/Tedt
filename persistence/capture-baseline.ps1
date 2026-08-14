[CmdletBinding()]
param(
    [string]$OutputPath = "D:\RDPState\baseline.json"
)

$ErrorActionPreference = "Stop"

$dir = Split-Path -Parent $OutputPath
if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

Write-Host "Capturing system software baseline..." -ForegroundColor Yellow

$installed = @()

# Query Registry uninstall keys
$regPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($path in $regPaths) {
    Get-ItemProperty $path -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DisplayName) {
            $installed += [PSCustomObject]@{
                Name    = $_.DisplayName
                Version = $_.DisplayVersion
            }
        }
    }
}

$baseline = $installed | Sort-Object Name -Unique
$baseline | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host "[OK] Baseline captured ($($baseline.Count) applications) -> $OutputPath" -ForegroundColor Green
