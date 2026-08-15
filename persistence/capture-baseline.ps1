# ==================================================
# capture-baseline.ps1
# ==================================================
[CmdletBinding()]
param(
    [string]$OutputPath = "D:\RDPState\baseline.json"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scanner = Join-Path $scriptDir "scan-software-state.ps1"

if (!(Test-Path $scanner)) {
    throw "scan-software-state.ps1 not found next to capture-baseline.ps1 at $scanner. Baseline must use the same schema as the live scan (wingetList/registrySoftware/chocoList) or the delta step will treat every installed app as new."
}

Write-Host "Capturing system software baseline..." -ForegroundColor Yellow

# IMPORTANT: baseline.json must be produced with the exact same schema as
# current-software-state.json (wingetList / registrySoftware / chocoList),
# otherwise compute-software-delta.ps1 can't match anything against it and
# every preinstalled app on the image will show up as "new" on restore.
& $scanner -OutputPath $OutputPath

$baseline = Get-Content $OutputPath -Raw | ConvertFrom-Json
$wingetCount = @($baseline.wingetList).Count
$registryCount = @($baseline.registrySoftware).Count

Write-Host "[OK] Baseline captured: $wingetCount winget entries, $registryCount registry entries -> $OutputPath" -ForegroundColor Green
Write-Host "[!] Run this ONCE, right after the RDP image is provisioned and before you install anything yourself." -ForegroundColor Cyan