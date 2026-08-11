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

function Get-InstallerSwitch {
    param([string]$FilePath)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $sampleLen = [Math]::Min($bytes.Length, 2MB)
    $sample = [System.Text.Encoding]::ASCII.GetString($bytes[0..($sampleLen - 1)])

    if ($sample -match "Inno Setup")            { return "/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART /ALLUSERS" }
    if ($sample -match "Nullsoft")               { return "/S" }
    if ($sample -match "InstallShield")          { return "/s /v/qn" }
    if ($sample -match "WiseMain|WISE INSTALLATION") { return "/s" }
    return $null
}

function Wait-ForInstallerCompletion {
    param([System.Diagnostics.Process]$Proc, [string]$FilePath, [int]$TimeoutSeconds = 300)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $parentAlive = -not $Proc.HasExited
        $childAlive = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -eq $FilePath -and -not $_.HasExited } catch { $false }
        }
        if (-not $parentAlive -and -not $childAlive) { return $true }
    }
    return $false
}

# 1. Execute Web-Downloaded Installers under RDP User Session
if ($InstallersPath -and (Test-Path $InstallersPath)) {
    Write-Host "Installing detected web-downloaded packages..." -ForegroundColor Yellow
    $installers = Get-ChildItem -Path $InstallersPath -Include "*.exe", "*.msi" -Recurse -ErrorAction SilentlyContinue
    $manualLog = "D:\RDPState\manual-install-needed.txt"

    foreach ($file in $installers) {
        $ext = $file.Extension.ToLower()
        Write-Host "--> Processing: $($file.Name)" -ForegroundColor Gray

        if ($ext -eq ".msi") {
            $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$($file.FullName)`" /qn /norestart" -PassThru -NoNewWindow
            $done = Wait-ForInstallerCompletion -Proc $proc -FilePath $file.FullName
            if (-not $done) {
                Write-Host "  Timed out waiting for MSI install" -ForegroundColor Yellow
                Add-Content -Path $manualLog -Value $file.FullName
            } else {
                Write-Host "  Done" -ForegroundColor Green
            }
        }
        elseif ($ext -eq ".exe") {
            $switch = Get-InstallerSwitch -FilePath $file.FullName

            if (-not $switch) {
                Write-Host "  Unknown installer type - flagging for manual install" -ForegroundColor Yellow
                Add-Content -Path $manualLog -Value $file.FullName
                continue
            }

            Write-Host "  Using switch: $switch" -ForegroundColor Gray
            $proc = Start-Process -FilePath $file.FullName -ArgumentList $switch -PassThru -NoNewWindow
            $done = Wait-ForInstallerCompletion -Proc $proc -FilePath $file.FullName

            if (-not $done) {
                Write-Host "  Timed out - may still be running or hung. Flagging." -ForegroundColor Yellow
                Add-Content -Path $manualLog -Value $file.FullName
            } else {
                Write-Host "  Done" -ForegroundColor Green
            }
        }
    }

    if (Test-Path $manualLog) {
        Write-Host ""
        Write-Host "Some installers need manual attention - see $manualLog" -ForegroundColor Yellow
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