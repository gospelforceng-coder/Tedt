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

if (!(Get-Command rclone -ErrorAction SilentlyContinue)) {
    throw "rclone is not installed."
}

function New-Directory {
    param([string]$Path)
    if (!(Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (!(Test-Path $Source)) { return }
    New-Directory $Destination
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /MT:16 /NP /NFL /NDL | Out-Null
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

# 2. Download Checkpoint Archive
Write-Host "[2/7] Downloading checkpoint archive $generation..." -ForegroundColor Yellow
$archiveZip = Join-Path $LocalRoot "$generation.zip"
& rclone copyto "$RemoteRoot/archives/$generation.zip" $archiveZip --quiet

if (Test-Path $archiveZip) {
    Expand-Archive -Path $archiveZip -DestinationPath $generationDir -Force
    Remove-Item $archiveZip -Force
} else {
    & rclone copy "$RemoteRoot/generations/$generation" $generationDir --progress
}

# 3. Validate Checkpoint
Write-Host "[3/7] Validating checkpoint..." -ForegroundColor Yellow
$requiredFiles = @("checkpoint.json", "software-state.json", "rewin\migration_package.json")
foreach ($file in $requiredFiles) {
    if (!(Test-Path (Join-Path $generationDir $file))) {
        throw "Required checkpoint file missing: $file"
    }
}

# 4. Restore Portable Apps (D:\Software)
Write-Host "[4/7] Restoring portable applications..." -ForegroundColor Yellow
$portableSource = Join-Path $generationDir "installed-tools\Software"
if (Test-Path $portableSource) {
    if (!(Test-Path "D:\Software")) { New-Item -ItemType Directory -Path "D:\Software" -Force | Out-Null }
    Copy-Tree $portableSource "D:\Software"
    $env:Path += ";D:\Software"
    [System.Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
}

# 5. Install Software via Winget & Choco
Write-Host "[5/7] Restoring package-managed software..." -ForegroundColor Yellow
$softwareState = Get-Content (Join-Path $generationDir "software-state.json") -Raw | ConvertFrom-Json

$installedWinget = ""
try { $installedWinget = winget list --accept-source-agreements 2>$null | Out-String } catch {}

foreach ($app in $softwareState) {
    if ($app.wingetId) {
        if ($installedWinget -and $installedWinget.Contains($app.wingetId)) {
            Write-Host "Skipping $($app.name) - Already installed." -ForegroundColor Gray
            continue
        }
        Write-Host "Installing $($app.name) [$($app.wingetId)] via Winget..." -ForegroundColor Gray
        winget install --id $app.wingetId --exact --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity --silent
        continue
    }
    if ($app.chocolateyId -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $($app.name) via Choco..." -ForegroundColor Gray
        choco install $app.chocolateyId -y
        continue
    }
}

# 6. Restore User Configuration & Auto-Run Custom Installers as RDP User
Write-Host "[6/7] Restoring RDP user configuration & running installers..." -ForegroundColor Yellow
$userScript = Join-Path $scriptDir "restore-user.ps1"
$packagePath = Join-Path $generationDir "rewin"
$installersFolder = Join-Path $generationDir "installed-tools\installers"

$taskName = "RDP-State-Restore-$generation"
$taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$userScript`" -PackagePath `"$packagePath`" -ReWinRoot `"$ReWinRoot`" -InstallersPath `"$installersFolder`""

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Highest

$task = New-ScheduledTask -Action $action -Principal $principal
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -User $UserName -Password $UserPassword | Out-Null
Start-ScheduledTask -TaskName $taskName

$timeout = 1200
$timer = [Diagnostics.Stopwatch]::StartNew()
while ($timer.Elapsed.TotalSeconds -lt $timeout) {
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    if ($info.LastRunTime -gt [datetime]::MinValue -and $info.State -eq "Ready") { break }
    Start-Sleep -Seconds 5
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

# 7. Restore User Data Files
Write-Host "[7/7] Restoring user files..." -ForegroundColor Yellow
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

Write-Host "==============================================" -ForegroundColor Green
Write-Host "       RDP RESTORE COMPLETED: $generation" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green