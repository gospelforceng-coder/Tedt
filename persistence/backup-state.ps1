[CmdletBinding()]
param (
    [string]$StageRoot = "D:\RDPState\stage",
    [string]$LocalCheckpointRoot = "D:\RDPState\checkpoints",
    [string]$RemoteRoot = "mydrive:rdp-backups",
    [string]$UserName = "RDP"
)

$ErrorActionPreference = "SilentlyContinue"

Write-Host "⚡ Starting High-Speed Differential Backup..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 1. Clear staging directory
if (Test-Path $StageRoot) { Remove-Item $StageRoot -Recurse -Force }
New-Item -ItemType Directory -Path "$StageRoot\user-data" -Force | Out-Null
New-Item -ItemType Directory -Path "$StageRoot\installed-tools" -Force | Out-Null

# 2. Export Winget list as fallback backup
Write-Host "📦 Exporting installed software manifest..." -ForegroundColor Yellow
winget export -o "$StageRoot\installed-tools\packages.json" --accept-source-agreements

# 3. Stage custom applications installed on Drive D:
if (Test-Path "D:\Software") {
    Write-Host "📁 Staging portable software from D:\Software..." -ForegroundColor Yellow
    Copy-Item -Path "D:\Software" -Destination "$StageRoot\installed-tools\Software" -Recurse -Force
}

# 4. Stage User Data & AppData (Browser profiles, IDE settings)
Write-Host "📁 Staging C:\Users\RDP configuration and profile data..." -ForegroundColor Yellow
$userProfile = "C:\Users\$UserName"
$targets = @("Desktop", "Documents", "Downloads", "Pictures", "Videos", "AppData\Roaming")

foreach ($target in $targets) {
    $src = Join-Path $userProfile $target
    $dest = Join-Path "$StageRoot\user-data" $target
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dest -Recurse -Force
    }
}

# 5. Compress into a single zip archive on Drive D:
if (-not (Test-Path $LocalCheckpointRoot)) { New-Item -ItemType Directory -Path $LocalCheckpointRoot -Force | Out-Null }
$zipPath = Join-Path $LocalCheckpointRoot "latest_state.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Host "🗜️ Compressing backup state archive..." -ForegroundColor Yellow
Compress-Archive -Path "$StageRoot\*" -DestinationPath $zipPath -CompressionLevel Fastest

# 6. Upload zip to Google Drive via RClone
Write-Host "🚀 Uploading backup archive via RClone..." -ForegroundColor Cyan
rclone copy "$zipPath" "$RemoteRoot" --fast-list --transfers 16

$sw.Stop()
Write-Host "🎉 Backup completed in $($sw.Elapsed.TotalSeconds.ToString('N2')) seconds!" -ForegroundColor Green
