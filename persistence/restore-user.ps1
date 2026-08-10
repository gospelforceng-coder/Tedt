[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$ReWinRoot,
    [string]$InstallersPath = ""
)

$ErrorActionPreference = "Stop"

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "        RESTORING RDP USER ENVIRONMENT" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Execute Web-Downloaded Installers under RDP User Session
if ($InstallersPath -and (Test-Path $InstallersPath)) {
    Write-Host "Installing detected web-downloaded packages..." -ForegroundColor Yellow
    $installers = Get-ChildItem -Path $InstallersPath -Include "*.exe", "*.msi" -Recurse -ErrorAction SilentlyContinue

    foreach ($file in $installers) {
        $ext = $file.Extension.ToLower()
        Write-Host "--> Running installer: $($file.Name)" -ForegroundColor Gray

        if ($ext -eq ".msi") {
            $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$($file.FullName)`" /qn /norestart" -PassThru -NoNewWindow
            $proc | Wait-Process -Timeout 180 -ErrorAction SilentlyContinue
        }
        elseif ($ext -eq ".exe") {
            # InnoSetup (VS Code, Cursor, etc.), NSIS, and general silent flags
            $argsList = @(
                "/VERYSILENT /NORESTART /MERGETASKS=`"!runcode`"", 
                "/VERYSILENT /ALLUSERS /NORESTART",
                "/S", 
                "/silent", 
                "/q"
            )
            
            $installed = $false
            foreach ($arg in $argsList) {
                $p = Start-Process -FilePath $file.FullName -ArgumentList $arg -PassThru -NoNewWindow
                $p | Wait-Process -Timeout 180 -ErrorAction SilentlyContinue
                if ($p.HasExited -and $p.ExitCode -eq 0) {
                    $installed = $true
                    break
                }
            }

            if (-not $installed) {
                # Fallback simple start if silent switches exit early
                Start-Process -FilePath $file.FullName -ArgumentList "/S" -Wait -NoNewWindow -ErrorAction SilentlyContinue
            }
        }
    }
}

# 2. Run ReWin Configuration Restore
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
Write-Host "[OK] User configuration and installer execution complete." -ForegroundColor Green