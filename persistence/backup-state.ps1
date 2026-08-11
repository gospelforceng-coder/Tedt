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
if (!$ReWinRoot) { $ReWinRoot = Join-Path $scriptDir "..\tools\ReWin" }
if (Test-Path $ReWinRoot) { $ReWinRoot = (Resolve-Path $ReWinRoot).Path }

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
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /MT:32 /NP /NFL /NDL /XD "Temp" "tmp" "Cache" "Caches" "Code Cache" "GPUCache" "CrashDumps" "node_modules" ".git" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on $Source" }
}

$generation = Get-NextGeneration $LocalCheckpointRoot
$generationName = "{0:D6}" -f $generation
$stage = Join-Path $StageRoot $generationName
$rewinOut = Join-Path $stage "rewin"
$userOut = Join-Path $stage "user-data"
$toolsOut = Join-Path $stage "installed-tools\Software"
$installersOut = Join-Path $stage "installed-tools\installers"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Directory $rewinOut
New-Directory $userOut
New-Directory $installersOut

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
if ($scan) {
    Get-ChildItem $scan.FullName -Force | ForEach-Object {
        Move-Item -Path $_.FullName -Destination $rewinOut -Force
    }
    Remove-Item $scan.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

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

# 4. Copy User Files & Capture ONLY Installers Not Covered By Winget/Choco
Write-Host "[4/6] Backing up user files and setup installers..." -ForegroundColor Yellow
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

# Copy Portable Software from D:\Software
if (Test-Path "D:\Software") {
    Write-Host "Backing up portable applications from D:\Software..." -ForegroundColor Gray
    Copy-Tree "D:\Software" $toolsOut
}

# Build a lookup of software names already covered by winget/choco - these get
# installed via package manager on restore, so their raw installer should NOT
# also be captured. (This was the main cause of slow backups - e.g. capturing
# the 240MB VS Code installer when winget already handles VS Code.)
$coveredNames = @()
foreach ($m in $mappings) {
    if ($m.WingetId -or $m.ChocolateyId) {
        if ($m.SoftwareName) { $coveredNames += $m.SoftwareName.ToLower() }
    }
}

function Test-IsCoveredByPackageManager {
    param([string]$FileName)
    foreach ($name in $coveredNames) {
        $cleanName = ($name -replace '[^a-z0-9]', '')
        $cleanFile = ($FileName.ToLower() -replace '[^a-z0-9]', '')
        if ($cleanName.Length -ge 4 -and $cleanFile -match [regex]::Escape($cleanName)) {
            return $true
        }
    }
    return $false
}

# Find standalone installer files in Downloads / Desktop to auto-execute on restore.
# Only capture installers with NO winget/choco mapping - everything else installs
# faster and more reliably through Step 5 of restore.ps1 (winget/choco).
$searchFolders = @(Join-Path $profile "Downloads", Join-Path $profile "Desktop")
foreach ($folder in $searchFolders) {
    if (Test-Path $folder) {
        Get-ChildItem -Path $folder -Include "*.exe", "*.msi" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $looksLikeInstaller = $_.Name -match "(setup|install|installer)" -or $_.Length -gt 10MB
            if ($looksLikeInstaller) {
                if (Test-IsCoveredByPackageManager -FileName $_.Name) {
                    Write-Host "Skipping $($_.Name) - already covered by winget/choco" -ForegroundColor DarkGray
                } else {
                    Write-Host "Captured setup installer: $($_.Name)" -ForegroundColor Gray
                    Copy-Item -Path $_.FullName -Destination $installersOut -Force
                }
            }
        }
    }
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

# 6. Publish Checkpoint
Write-Host "[6/6] Publishing Checkpoint..." -ForegroundColor Yellow
$manifest = [ordered]@{
    schemaVersion  = 1
    generation     = $generation
    createdUtc     = (Get-Date).ToUniversalTime().ToString("o")
    sourceComputer = $env:COMPUTERNAME
    sourceUser     = $UserName
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $stage "checkpoint.json") -Encoding UTF8

# Skip zipping - Compress-Archive is single-threaded and slow on large trees.
# rclone copies the folder directly with parallel transfers instead.
& rclone copy $stage "$RemoteRoot/generations/$generationName" --transfers 16 --checkers 16 --quiet

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