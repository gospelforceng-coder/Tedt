[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$ReWinRoot
)

$ErrorActionPreference = "Stop"

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "        RESTORING RDP USER CONFIGURATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# Note: raw installer execution was removed from this script. Software
# installs now happen via winget in restore.ps1 step 4 (parallelized).
# This script now only restores ReWin-managed config (browser, git, vscode,
# terminal, env vars, file associations, etc.) - which is why this step is
# now fast instead of the ~25 min it used to take.

$ReWinRoot = (Resolve-Path $ReWinRoot).Path
Set-Location $ReWinRoot

$restoreScript = Join-Path $ReWinRoot "src\restore\restore_config.ps1"
if (!(Test-Path $restoreScript)) {
    throw "ReWin restore script not found: $restoreScript"
}

. $restoreScript

$options = @{
    RestoreEnvironmentVariables = $true
    RestoreScheduledTasks       = $false
    RestoreServices             = $false
    RestoreNetwork             = $false
    RestoreFileAssociations     = $true
    RestoreWindowsSettings      = $true
    RestoreAppConfigs           = $true

    vscode          = $true
    git_config      = $true
    ssh_config      = $true
    terminal        = $true
    powershell      = $true
    browser_chrome  = $true
    browser_firefox = $true
    browser_edge    = $true
    cursor          = $true
    ai_configs      = $true
}

Write-Host "Restoring ReWin configuration..." -ForegroundColor Yellow
Start-FullRestore -PackagePath $PackagePath -Options $options
Write-Host "[OK] Configuration restore complete." -ForegroundColor Green