[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "SilentlyContinue"

Write-Host "🔍 Generating high-speed baseline index..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$scanRoots = @(
    "C:\Users\RDP",
    "C:\Program Files",
    "C:\Program Files (x86)",
    "C:\ProgramData"
)

$excludePatterns = @(
    '\\AppData\\Local\\Temp',
    '\\AppData\\Local\\Microsoft\\Windows',
    '\\AppData\\Local\\Google\\Chrome\\User Data\\.*\\Cache',
    '\\AppData\\Local\\Packages',
    '\\AppData\\Local\\CrashDumps'
)

$baselineIndex = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($root in $scanRoots) {
    if (Test-Path $root) {
        $files = [System.IO.Directory]::EnumerateFiles($root, "*", [System.IO.SearchOption]::AllDirectories)
        foreach ($file in $files) {
            $skip = $false
            foreach ($pattern in $excludePatterns) {
                if ($file -match $pattern) { $skip = $true; break }
            }
            if (-not $skip) {
                [void]$baselineIndex.Add($file)
            }
        }
    }
}

$parentDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
$baselineIndex | ConvertTo-Json -Compress | Set-Content -Path $OutputPath -Encoding UTF8

$sw.Stop()
Write-Host "✅ Baseline captured in $($sw.Elapsed.TotalSeconds.ToString('N2')) seconds." -ForegroundColor Green
