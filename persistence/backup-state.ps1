[CmdletBinding()]
param(
    [string]$ReWinRoot = "",
    [string]$StageRoot = "D:\RDPState\stage",
    [string]$LocalCheckpointRoot = "D:\RDPState\checkpoints",
    [string]$RemoteRoot = "mydrive:rdp-backups",
    [string]$UserName = "RDP",
    [string]$BaselinePath = "D:\RDPState\baseline.json",
    [string]$ExclusionListPath = "D:\RDPState\excluded-from-winget.json",
    [Parameter(Mandatory)][string]$UserPassword
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (!$ReWinRoot) { $ReWinRoot = Join-Path $scriptDir "..\tools\ReWin" }
if (Test-Path $ReWinRoot) { $ReWinRoot = (Resolve-Path $ReWinRoot).Path }

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
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /MT:32 /NP /NFL /NDL /XD "Temp" "tmp" "Cache" "Caches" "Code Cache" "GPUCache" "CrashDumps" "node_modules" ".git" "Service Worker" "blob_storage" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on $Source" }
}

# Folders under AppData\Local that are always skipped regardless of baseline,
# since they're OS/browser caches already handled elsewhere (ReWin config
# restore covers browser_chrome/browser_firefox) or are pure driver/OS cache.
$alwaysSkipLocalFolders = @(
    "Microsoft", "Google", "Mozilla", "Packages", "Temp",
    "D3DSCache", "NVIDIA", "NVIDIA Corporation", "Package Cache",
    "CrashDumps", "ConnectedDevicesPlatform"
)

function Get-BaselineNameTokens {
    param([string]$BaselinePath)
    if (!(Test-Path $BaselinePath)) { return @() }
    $baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json
    $tokens = @()
    foreach ($m in $baseline.registrySoftware) {
        if ($m.DisplayName) {
            $clean = ($m.DisplayName -replace '[^a-zA-Z0-9]', '').ToLower()
            if ($clean.Length -ge 4) { $tokens += $clean }
        }
    }
    foreach ($line in $baseline.wingetList) {
        $parts = $line -split '\s{2,}' | Where-Object { $_ -ne '' }
        if ($parts.Count -ge 1) {
            $clean = ($parts[0] -replace '[^a-zA-Z0-9]', '').ToLower()
            if ($clean.Length -ge 4) { $tokens += $clean }
        }
    }
    return $tokens | Select-Object -Unique
}

function Test-MatchesBaselineApp {
    param([string]$FolderName, [array]$BaselineTokens)
    $cleanFolder = ($FolderName -replace '[^a-zA-Z0-9]', '').ToLower()
    foreach ($token in $BaselineTokens) {
        $shortToken = $token.Substring(0, [Math]::Min(6, $token.Length))
        if ($cleanFolder -match [regex]::Escape($shortToken) -or $token -match [regex]::Escape($cleanFolder)) {
            return $true
        }
    }
    return $false
}

$generation = Get-NextGeneration $LocalCheckpointRoot
$generationName = "{0:D6}" -f $generation
$stage = Join-Path $StageRoot $generationName
$rewinOut = Join-Path $stage "rewin"
$userOut = Join-Path $stage "user-data"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Directory $rewinOut
New-Directory $userOut

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       CREATING CHECKPOINT $generationName" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Capture current software state (registry + winget + choco)
Write-Host "[1/5] Scanning current software state..." -ForegroundColor Yellow
$currentStatePath = Join-Path $stage "current-software-state.json"
& (Join-Path $scriptDir "scan-software-state.ps1") -OutputPath $currentStatePath

# 2. Compute delta against baseline (excludes pre-installed + your manual-install list)
Write-Host "[2/5] Computing software delta..." -ForegroundColor Yellow
$deltaPath = Join-Path $stage "software-delta.json"
& (Join-Path $scriptDir "compute-software-delta.ps1") `
    -BaselinePath $BaselinePath `
    -CurrentPath $currentStatePath `
    -OutputPath $deltaPath `
    -ExclusionListPath $ExclusionListPath

# 3. Copy user files - unconditional, no installer-filtering logic.
Write-Host "[3/5] Backing up user files and presets..." -ForegroundColor Yellow
$profile = "C:\Users\$UserName"
$paths = @{
    Desktop        = Join-Path $profile "Desktop"
    Documents      = Join-Path $profile "Documents"
    Downloads      = Join-Path $profile "Downloads"
    Pictures       = Join-Path $profile "Pictures"
    Videos         = Join-Path $profile "Videos"
    Projects       = Join-Path $profile "Projects"
    AppDataRoaming = Join-Path $profile "AppData\Roaming"
}
foreach ($name in $paths.Keys) {
    if (Test-Path $paths[$name]) {
        Copy-Tree $paths[$name] (Join-Path $userOut $name)
    }
}

# 3b. Copy AppData\Local, but ONLY folders belonging to apps that are NOT
# part of the baseline (pre-installed on first boot). Baseline apps' Local
# folders are dev-tool caches/metadata (Unity, MongoDB, NuGet, .NET SDKs,
# etc.) - large, not needed, and never restored anyway since those apps
# aren't reinstalled by the delta process.
Write-Host "[3b/5] Backing up AppData\Local for user-added apps..." -ForegroundColor Yellow
$localAppData = Join-Path $profile "AppData\Local"
if (Test-Path $localAppData) {
    $baselineTokens = Get-BaselineNameTokens -BaselinePath $BaselinePath
    $localOut = Join-Path $userOut "AppDataLocal"

    Get-ChildItem $localAppData -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $folder = $_
        if ($folder.Name -in $alwaysSkipLocalFolders) {
            return
        }
        if (Test-MatchesBaselineApp -FolderName $folder.Name -BaselineTokens $baselineTokens) {
            Write-Host "Skipping AppData\Local\$($folder.Name) - baseline app" -ForegroundColor DarkGray
            return
        }
        Write-Host "Backing up AppData\Local\$($folder.Name)..." -ForegroundColor Gray
        Copy-Tree $folder.FullName (Join-Path $localOut $folder.Name)
    }
}

if (Test-Path "D:\Software") {
    Write-Host "Backing up portable applications from D:\Software..." -ForegroundColor Gray
    Copy-Tree "D:\Software" (Join-Path $stage "installed-tools\Software")
}

# 4. Run ReWin config scan (browser configs, vscode, git, terminal, etc.)
Write-Host "[4/5] Running ReWin scanner..." -ForegroundColor Yellow
$scanner = Join-Path $ReWinRoot "src\scanner\main_scanner.ps1"
if (Test-Path $scanner) {
    $taskName = "RDP-State-Scan-$generationName"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scanner`" -OutputPath `"$rewinOut`" -BackupAppConfigs -NonInteractive"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Highest
    $task = New-ScheduledTask -Action $action -Principal $principal
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -User $UserName -Password $UserPassword | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 1800) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt [datetime]::MinValue -and $info.State -eq "Ready") { break }
        Start-Sleep -Seconds 5
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

    $scan = Get-ChildItem $rewinOut -Directory -Filter "Scan_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($scan) {
        Get-ChildItem $scan.FullName -Force | ForEach-Object { Move-Item -Path $_.FullName -Destination $rewinOut -Force }
        Remove-Item $scan.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$manifest = [ordered]@{
    schemaVersion  = 3
    generation     = $generation
    createdUtc     = (Get-Date).ToUniversalTime().ToString("o")
    sourceComputer = $env:COMPUTERNAME
    sourceUser     = $UserName
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $stage "checkpoint.json") -Encoding UTF8

# 5. Publish checkpoint - direct folder sync, no zip step
Write-Host "[5/5] Publishing checkpoint..." -ForegroundColor Yellow
& rclone copy $stage "$RemoteRoot/generations/$generationName" --transfers 16 --checkers 16 --quiet

$current = [ordered]@{ schemaVersion = 3; generation = $generation; status = "READY"; createdUtc = $manifest.createdUtc }
$currentPath = Join-Path $stage "current.json"
$current | ConvertTo-Json -Depth 8 | Set-Content $currentPath -Encoding UTF8
& rclone copyto $currentPath "$RemoteRoot/current.json"

Write-Host "==============================================" -ForegroundColor Green
Write-Host "      CHECKPOINT $generationName IS READY" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
