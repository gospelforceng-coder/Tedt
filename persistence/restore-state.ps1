[CmdletBinding()]
param(
    [string]$RemoteRoot = "mydrive:rdp-backups",
    [string]$LocalRoot = "D:\RDPState\restore",
    [string]$ReWinRoot = "",
    [string]$UserName = "RDP",
    [Parameter(Mandatory)][string]$UserPassword
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (!$ReWinRoot) { $ReWinRoot = Join-Path $scriptDir "..\tools\ReWin" }
if (Test-Path $ReWinRoot) { $ReWinRoot = (Resolve-Path $ReWinRoot).Path }

if (!(Get-Command rclone -ErrorAction SilentlyContinue)) { throw "rclone is not installed." }

function New-Directory {
    param([string]$Path)
    if (!(Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (!(Test-Path $Source)) { return }
    New-Directory $Destination
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /MT:32 /NP /NFL /NDL | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed: $Source" }
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "              RDP STATE RESTORE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

if (Test-Path $LocalRoot) { Remove-Item $LocalRoot -Recurse -Force }
New-Directory $LocalRoot

# 1. Read Current Checkpoint
Write-Host "[1/7] Checking checkpoint..." -ForegroundColor Yellow
$currentPath = Join-Path $LocalRoot "current.json"
& rclone copyto "$RemoteRoot/current.json" $currentPath --quiet
if ($LASTEXITCODE -ne 0 -or !(Test-Path $currentPath)) {
    Write-Host "No persistent checkpoint exists. Fresh start." -ForegroundColor Cyan
    exit 0
}
$current = Get-Content $currentPath -Raw | ConvertFrom-Json
if ($current.status -ne "READY") { throw "Checkpoint is not READY." }
$generation = "{0:D6}" -f [int]$current.generation
$generationDir = Join-Path $LocalRoot $generation
New-Directory $generationDir

# 2. Download checkpoint
Write-Host "[2/7] Downloading checkpoint $generation..." -ForegroundColor Yellow
& rclone copy "$RemoteRoot/generations/$generation" $generationDir --transfers 16 --checkers 16 --progress

# 3. Restore plain user files
Write-Host "[3/7] Restoring user files and portable software..." -ForegroundColor Yellow
$profile = "C:\Users\$UserName"
$userData = Join-Path $generationDir "user-data"
$restoreMap = @{
    Desktop   = Join-Path $profile "Desktop"
    Documents = Join-Path $profile "Documents"
    Downloads = Join-Path $profile "Downloads"
    Pictures  = Join-Path $profile "Pictures"
    Videos    = Join-Path $profile "Videos"
    Projects  = Join-Path $profile "Projects"
}
foreach ($name in $restoreMap.Keys) {
    $source = Join-Path $userData $name
    if (Test-Path $source) {
        Write-Host "Restoring $name..." -ForegroundColor Gray
        Copy-Tree $source $restoreMap[$name]
    }
}

# Restore portable software to D:\Software
$portableSource = Join-Path $generationDir "installed-tools\Software"
if (Test-Path $portableSource) {
    if (!(Test-Path "D:\Software")) { New-Item -ItemType Directory -Path "D:\Software" -Force | Out-Null }
    Write-Host "Restoring software binaries to D:\Software..." -ForegroundColor Gray
    Copy-Tree $portableSource "D:\Software"
    
    $sysPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($sysPath -notlike "*D:\Software*") {
        [System.Environment]::SetEnvironmentVariable("Path", "$sysPath;D:\Software", "Machine")
        $env:Path += ";D:\Software"
    }
}

# 4. Install software from the delta list
Write-Host "[4/7] Installing user-added software via winget..." -ForegroundColor Yellow
$deltaPath = Join-Path $generationDir "software-delta.json"
if (Test-Path $deltaPath) {
    $delta = Get-Content $deltaPath -Raw | ConvertFrom-Json
    $manualLog = "D:\RDPState\manual-install-needed.txt"

    $jobs = foreach ($app in ($delta | Where-Object { $_.resolved })) {
        Write-Host "Queuing $($app.name) [$($app.wingetId)]..." -ForegroundColor Gray
        Start-Job -ScriptBlock {
            param($id)
            winget install --id $id --exact --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity --silent --force
        } -ArgumentList $app.wingetId
    }
    if ($jobs) {
        $jobs | Wait-Job | Out-Null
        $jobs | Receive-Job
        $jobs | Remove-Job
    }

    foreach ($app in ($delta | Where-Object { -not $_.resolved })) {
        Write-Host "No winget match for $($app.name) - flagging for manual install" -ForegroundColor Yellow
        Add-Content -Path $manualLog -Value $app.name
    }
}

# 5. Restore AppData
Write-Host "[5/7] Restoring app data (presets, configs, login sessions)..." -ForegroundColor Yellow
$appDataRoamingSource = Join-Path $userData "AppDataRoaming"
if (Test-Path $appDataRoamingSource) {
    Copy-Tree $appDataRoamingSource (Join-Path $profile "AppData\Roaming")
}
$appDataLocalSource = Join-Path $userData "AppDataLocal"
if (Test-Path $appDataLocalSource) {
    Get-ChildItem $appDataLocalSource -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Restoring AppData\Local\$($_.Name)..." -ForegroundColor Gray
        Copy-Tree $_.FullName (Join-Path $profile "AppData\Local\$($_.Name)")
    }
}

# 6. Restore ReWin config
Write-Host "[6/7] Restoring ReWin configuration..." -ForegroundColor Yellow
$packagePath = Join-Path $generationDir "rewin"
if (Test-Path (Join-Path $packagePath "migration_package.json")) {
    $userScript = Join-Path $scriptDir "restore-user.ps1"
    $taskName = "RDP-State-Restore-$generation"
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$userScript`" -PackagePath `"$packagePath`" -ReWinRoot `"$ReWinRoot`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Highest
    $task = New-ScheduledTask -Action $action -Principal $principal
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -User $UserName -Password $UserPassword | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $timeout = 600
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $timeout) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt [datetime]::MinValue -and $info.State -eq "Ready") { break }
        Start-Sleep -Seconds 5
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Write-Host "[7/7] Done." -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Green
Write-Host "       RDP RESTORE COMPLETED: $generation" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
if (Test-Path "D:\RDPState\manual-install-needed.txt") {
    Write-Host "Some apps need manual install - see D:\RDPState\manual-install-needed.txt" -ForegroundColor Yellow
}
