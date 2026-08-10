[CmdletBinding()]
param (
    [string]$RemoteRoot = "mydrive:rdp-backups",
    [string]$LocalRoot = "D:\RDPState\restore",
    [string]$ReWinRoot = "D:\RDPState\tools\ReWin",
    [string]$UserName = "RDP",
    [string]$UserPassword = ""
)

$ErrorActionPreference = "SilentlyContinue"

Write-Host "⚡ Starting Fast State Restore..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()

if (Test-Path $LocalRoot) { Remove-Item $LocalRoot -Recurse -Force }
New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null

$zipPath = Join-Path $LocalRoot "latest_state.zip"

# 1. Download Backup Archive
Write-Host "📥 Downloading latest backup package..." -ForegroundColor Cyan
rclone copy "$RemoteRoot/latest_state.zip" "$LocalRoot" --fast-list

if (Test-Path $zipPath) {
    Write-Host "📦 Extracting package contents..." -ForegroundColor Yellow
    $extractPath = Join-Path $LocalRoot "extracted"
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    # 2. Restore User Data & AppData Configurations
    $userDataPath = Join-Path $extractPath "user-data"
    $userProfile = "C:\Users\$UserName"
    if (Test-Path $userDataPath) {
        Write-Host "📁 Restoring user profile and AppData configs..." -ForegroundColor Yellow
        Copy-Item -Path "$userDataPath\*" -Destination $userProfile -Recurse -Force
    }

    # 3. Restore Large Portable Software to Drive D:\
    $toolsPath = Join-Path $extractPath "installed-tools\Software"
    if (Test-Path $toolsPath) {
        Write-Host "⚙️ Restoring installed applications to D:\Software..." -ForegroundColor Yellow
        if (-not (Test-Path "D:\Software")) { New-Item -ItemType Directory -Path "D:\Software" -Force | Out-Null }
        Copy-Item -Path "$toolsPath\*" -Destination "D:\Software" -Recurse -Force

        # Auto-register binaries to Windows PATH environment variable
        $env:Path += ";D:\Software"
        [System.Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
    }

    # 4. Fallback Silent Re-install via Winget Package Manifest
    $packageJson = Join-Path $extractPath "installed-tools\packages.json"
    if (Test-Path $packageJson) {
        Write-Host "🔄 Re-importing Winget package registrations..." -ForegroundColor Yellow
        winget import -i $packageJson --accept-package-agreements --accept-source-agreements --ignore-unavailable
    }

    Write-Host "✅ System, user state, and software restored successfully." -ForegroundColor Green
} else {
    Write-Host "ℹ️ No remote backup found. Initializing fresh instance environment." -ForegroundColor Yellow
}

$sw.Stop()
$elapsed = $sw.Elapsed.TotalSeconds.ToString("N2")
Write-Host "🎉 Restore completed in $elapsed seconds!" -ForegroundColor Green
