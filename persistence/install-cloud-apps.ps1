[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Urls,
    [string]$DestRoot = "D:\Software",
    [string]$ArchivePassword = "123",
    [string]$SevenZipPath = "C:\Program Files\7-Zip\7z.exe"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $SevenZipPath)) {
    $7zCmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($7zCmd) { $SevenZipPath = $7zCmd.Source }
    else { throw "7-Zip executable not found." }
}

# Ensure Python gdown module is installed for downloading Google Drive files reliably
Write-Host "Installing gdown for Google Drive downloads..." -ForegroundColor Yellow
python -m pip install --quiet gdown

$stage = "D:\RDPState\software-stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   DOWNLOADING MULTI-PART GOOGLE DRIVE BUNDLE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Download each Google Drive file link
$partIndex = 1
foreach ($url in $Urls) {
    if ([string]::IsNullOrWhiteSpace($url)) { continue }
    
    # Extract Google Drive File ID from standard view URLs
    $fileId = $null
    if ($url -match "file/d/([^/]+)") {
        $fileId = $Matches[1]
    } elseif ($url -match "id=([^&]+)") {
        $fileId = $Matches[1]
    } else {
        $fileId = $url.Trim()
    }

    $outPath = Join-Path $stage "part_$partIndex"
    Write-Host "Downloading Google Drive File ID [$fileId]..." -ForegroundColor Yellow
    
    # Download using gdown
    python -m gdown --id "$fileId" -O "$outPath" --fuzzy
    
    $partIndex++
}

if (!(Test-Path $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }

# 2. Extract primary downloaded archives to D:\Software
Write-Host "Extracting downloaded bundle parts to $DestRoot..." -ForegroundColor Gray
$downloadedFiles = Get-ChildItem -Path $stage

# Pass the first file or all split parts to 7-Zip
& $SevenZipPath x "$($downloadedFiles[0].FullName)" "-o$DestRoot" "-p$ArchivePassword" -y | Out-Null

# 3. Recursively find and extract inner password-locked archives
Write-Host "Checking for password-protected inner archives inside $DestRoot..." -ForegroundColor Yellow
$innerArchives = Get-ChildItem -Path $DestRoot -Include "*.zip", "*.7z", "*.rar" -Recurse -ErrorAction SilentlyContinue

foreach ($arc in $innerArchives) {
    $targetDir = Join-Path $arc.DirectoryName $arc.BaseName
    Write-Host "Extracting inner archive: $($arc.Name) -> $targetDir" -ForegroundColor Gray
    
    & $SevenZipPath x "$($arc.FullName)" "-o$targetDir" "-p$ArchivePassword" -y | Out-Null
    Remove-Item $arc.FullName -Force -ErrorAction SilentlyContinue
}

# Clean up stage directory
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# 4. Add D:\Software to System PATH
$currentPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$DestRoot*") {
    $newPath = "$currentPath;$DestRoot"
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    $env:Path += ";$DestRoot"
    Write-Host "[OK] Added $DestRoot to System PATH" -ForegroundColor Green
}

Write-Host "[OK] Multi-part software extraction complete at $DestRoot" -ForegroundColor Green
