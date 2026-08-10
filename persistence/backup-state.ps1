[CmdletBinding()]
param(
    [string]$ReWinRoot = "",
    [string]$StageRoot = "D:\RDPState\stage",
    [string]$LocalCheckpointRoot = "D:\RDPState\checkpoints",
    [string]$RemoteRoot = "mydrive:rdp-backups",
    [string]$UserName = "RDP",
    [Parameter(Mandatory)][string]$UserPassword
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (!$ReWinRoot) {
    $ReWinRoot = Join-Path $scriptDir "..\tools\ReWin"
}
if (Test-Path $ReWinRoot) {
    $ReWinRoot = (Resolve-Path $ReWinRoot).Path
}

$scanner = Join-Path $ReWinRoot "src\scanner\main_scanner.ps1"
if (!(Test-Path $scanner)) { throw "ReWin scanner not found at $scanner" }

function New-Directory {
    param([string]$Path)
    if (!(Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-NextGeneration {
    param([string]$Root)
    New-Directory $Root
    $dirs = @(Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{6}$' } | Sort-Object Name)
    if (!$dirs) { return 1 }
    return ([int]$dirs[-1].Name + 1)
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (!(Test-Path $Source)) { return }
    New-Directory $Destination
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /MT:16 /NP /NFL /NDL /XD "Temp" "tmp" "Cache" "Caches" "Code Cache" "GPUCache" "CrashDumps" "node_modules" ".git" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on $Source" }
}

$generation = Get-NextGeneration $LocalCheckpointRoot
$generationName = "{0:D6}" -f $generation
$stage = Join-Path $StageRoot $generationName
$rewinOut = Join-Path $stage "rewin"
$userOut = Join-Path $stage "user-data"
$toolsOut = Join-Path $stage "installed-tools\Software"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Directory $rewinOut
New-Directory $userOut

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       CREATING CHECKPOINT $generationName" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Run ReWin Scanner as RDP User
Write-Host "[1/6] Scanning RDP user environment..." -ForegroundColor Yellow
$taskName = "RDP-State-Scan-$generationName"
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scanner`" -OutputPath `"$rewinOut`" -BackupAppConfigs -NonInteractive"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Highest

$task = New-ScheduledTask -Action $action -Principal $principal
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -User $UserName -Password $UserPassword | Out-Null
Start-ScheduledTask -TaskName $taskName

$timer = [Diagnostics.Stopwatch]::StartNew()
$timeout = 1800
while ($timer.Elapsed.TotalSeconds -lt $timeout) {
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    if ($info.LastRunTime -gt [datetime]::MinValue -and $info.State -eq "Ready") { break }
    Start-Sleep -Seconds 5
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

# Flatten ReWin Scan Directory Output
$scan = Get-ChildItem $rewinOut -Directory -Filter "Scan_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (!$scan) { throw "ReWin scan did not produce a Scan_* output directory." }

Get-ChildItem $scan.FullName -Force | ForEach-Object {
    Move-Item -Path $_.FullName -Destination $rewinOut -Force
}
Remove-Item $scan.FullName -Recurse -Force -ErrorAction SilentlyContinue

# Remove Sensitivities
$licenseFile = Join-Path $rewinOut "license_keys.json"
if (Test-Path $licenseFile) { Remove-Item $licenseFile -Force }

# 2. Validate ReWin Outputs
Write-Host "[2/6] Validating ReWin output..." -ForegroundColor Yellow
$required = @("software_inventory.json", "package_mappings.json", "config_backup.json")
foreach ($file in $required) {
    if (!(Test-Path (Join-Path $rewinOut $file))) { throw "ReWin output missing: $file" }
}

# 3. Build Migration Package
Write-Host "[3/6] Building migration package..." -ForegroundColor Yellow
$mappings = Get-Content (Join-Path $rewinOut "package_mappings.json") -Raw | ConvertFrom-Json
$package = [ordered]@{
    export_date = (Get-Date).ToUniversalTime().ToString("o")
    drives      = @{ primary = "C:"; secondary = "D:"; data = "D:" }
    software    = @($mappings)
    configs     = @{
        env_vars = $true; scheduled_tasks = $false; services = $false
        network = $false; file_assoc = $true; explorer = $true; app_configs = $true
        vscode = $true; git_config = $true; ssh_config = $true; terminal = $true
        powershell = $true; browser_chrome = $true; browser_firefox = $true; browser_edge = $true
    }
}
$package | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $rewinOut "migration_package.json") -Encoding UTF8

# 4. Copy User Data & D:\ Drive Portable Apps
Write-Host "[4/6] Backing up user files and D:\Software..." -ForegroundColor Yellow
$profile = "C:\Users\$UserName"
$paths = @{
    Desktop   = Join-Path $profile "Desktop"
    Documents = Join-Path $profile "Documents"
    Downloads = Join-Path $profile "Downloads"
    Pictures  = Join-Path $profile "Pictures"
    Videos    = Join-Path $profile "Videos"
    Projects  = Join-Path $profile "Projects"
}
foreach ($name in $paths.Keys) {
    if (Test-Path $paths[$name]) {
        Copy-Tree $paths[$name] (Join-Path $userOut $name)
    }
}

if (Test-Path "D:\Software") {
    Write-Host "Backing up portable software from D:\Software..." -ForegroundColor Gray
    Copy-Tree "D:\Software" $toolsOut
}

# 5. Save Software State
Write-Host "[5/6] Recording software state..." -ForegroundColor Yellow
$softwareState = @(
    $mappings | ForEach-Object {
        [ordered]@{
            name          = $_.SoftwareName
            version       = $_.Version
            wingetId      = $_.WingetId
            chocolateyId  = $_.ChocolateyId
            installMethod = $_.InstallMethod
        }
    }
)
$softwareState | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $stage "software-state.json") -Encoding UTF8

# 6. Build Manifest, Compress Zip, and Upload
Write-Host "[6/6] Publishing Checkpoint..." -ForegroundColor Yellow
$manifest = [ordered]@{
    schemaVersion  = 1
    generation     = $generation
    createdUtc     = (Get-Date).ToUniversalTime().ToString("o")
    sourceComputer = $env:COMPUTERNAME
    sourceUser     = $UserName
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $stage "checkpoint.json") -Encoding UTF8

$zipDir = Join-Path $LocalCheckpointRoot "archives"
New-Directory $zipDir
$zip = Join-Path $zipDir "$generationName.zip"
Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal -Force

# Upload archive zip FIRST (Fast target for restore)
& rclone copyto $zip "$RemoteRoot/archives/$generationName.zip" --quiet
# Upload loose generation folder as fallback
& rclone copy $stage "$RemoteRoot/generations/$generationName" --quiet

$current = [ordered]@{
    schemaVersion  = 1
    generation     = $generation
    status         = "READY"
    createdUtc     = $manifest.createdUtc
}
$currentPath = Join-Path $stage "current.json"
$current | ConvertTo-Json -Depth 8 | Set-Content $currentPath -Encoding UTF8
& rclone copyto $currentPath "$RemoteRoot/current.json"

Write-Host "==============================================" -ForegroundColor Green
Write-Host "      CHECKPOINT $generationName IS READY" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
