[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string[]]$Urls,
    [string]$DestRoot = "D:\Software",
    [string]$ArchivePassword = "123",
    [string]$SevenZipPath = "C:\Program Files\7-Zip\7z.exe"
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

# 1. Verify Target Drive Exists
$driveLetter = ($DestRoot -split ':')[0]
if (!(Test-Path "$driveLetter`:\")) {
    throw "Drive $driveLetter`: does not exist on this machine."
}

# 2. Verify 7-Zip Executable
if (!(Test-Path $SevenZipPath)) {
    $7zCmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($7zCmd) { $SevenZipPath = $7zCmd.Source }
    else { throw "7-Zip executable not found." }
}

Write-Host "Installing/updating gdown for Google Drive downloads..." -ForegroundColor Yellow
Invoke-Checked "pip install gdown" { python -m pip install --quiet --upgrade gdown }

$stage = "D:\RDPState\software-stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   DOWNLOADING MULTI-PART GOOGLE DRIVE BUNDLE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 3. Download Google Drive Files into staging
foreach ($url in $Urls) {
    if ([string]::IsNullOrWhiteSpace($url)) { continue }

    $fileId = $null
    if ($url -match "file/d/([^/]+)") {
        $fileId = $Matches[1]
    } elseif ($url -match "id=([^&]+)") {
        $fileId = $Matches[1]
    } else {
        $fileId = $url.Trim()
    }

    Write-Host "Downloading Google Drive File ID [$fileId]..." -ForegroundColor Yellow
    
    # Pass direct ID or URL without unsupported flags
    $downloadTarget = "https://drive.google.com/uc?id=$fileId"
    python -m gdown $downloadTarget -O "$stage/"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Direct download attempt failed for $fileId. Retrying with raw URL..." -ForegroundColor Yellow
        python -m gdown "$url" -O "$stage/"
    }
}

$downloadedFiles = Get-ChildItem -Path $stage -File | Sort-Object Name
if ($downloadedFiles.Count -eq 0) {
    throw "No files were downloaded into $stage - check Google Drive permissions or links."
}

if (!(Test-Path $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }

# 4. Extract ALL Standalone & Primary Volume Archives
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   EXTRACTING DOWNLOADED ARCHIVES TO $DestRoot" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# Identify standalone archives and primary split parts (.001, .part1.rar, .zip, .7z)
# Exclude secondary split volumes (.002+, .part2.rar+, .z02+) as 7-Zip handles those automatically
$archivesToExtract = $downloadedFiles | Where-Object {
    $_.Name -notmatch "\.(00[2-9]|0[1-9][0-9]|[1-9][0-9][0-9])$" -and
    $_.Name -notmatch "\.part(0*[2-9]|[1-9][0-9]+)\.rar$" -and
    $_.Name -notmatch "\.z(0*[2-9]|[1-9][0-9]+)$" -and
    ($_.Extension -match "\.(zip|7z|rar|exe)$" -or $_.Name -match "\.001$")
}

if ($archivesToExtract.Count -eq 0) {
    # Fallback if pattern matching doesn't hit: attempt extraction on all downloaded files
    $archivesToExtract = $downloadedFiles
}

foreach ($arc in $archivesToExtract) {
    Write-Host "Extracting archive: $($arc.Name) -> $DestRoot..." -ForegroundColor Gray
    
    Invoke-Checked "7z extraction of $($arc.Name)" {
        & $SevenZipPath x "$($arc.FullName)" "-o$DestRoot" "-p$ArchivePassword" -y
    }
}

# 5. Extract Nested Password-Protected Inner Archives
Write-Host "Checking for password-protected inner archives inside $DestRoot..." -ForegroundColor Yellow
$innerArchives = Get-ChildItem -Path $DestRoot -Include "*.zip", "*.7z", "*.rar" -Recurse -ErrorAction SilentlyContinue

foreach ($arc in $innerArchives) {
    $targetDir = Join-Path $arc.DirectoryName $arc.BaseName
    Write-Host "Extracting inner archive: $($arc.Name) -> $targetDir" -ForegroundColor Gray

    Invoke-Checked "7z extraction of $($arc.Name)" {
        & $SevenZipPath x "$($arc.FullName)" "-o$targetDir" "-p$ArchivePassword" -y
    }
    Remove-Item $arc.FullName -Force -ErrorAction SilentlyContinue
}

# 6. Verify Files Landed in Target Path
$installedCount = (Get-ChildItem -Path $DestRoot -Recurse -File -ErrorAction SilentlyContinue).Count
if ($installedCount -eq 0) {
    throw "Extraction reported success but $DestRoot is empty. Check archive password or file integrity."
}

# Cleanup Stage Directory
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# 7. Add D:\Software to System PATH
$currentPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$DestRoot*") {
    $newPath = "$currentPath;$DestRoot"
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    $env:Path += ";$DestRoot"
    Write-Host "[OK] Added $DestRoot to System PATH" -ForegroundColor Green
}

Write-Host "[OK] Multi-part software extraction complete at $DestRoot ($installedCount files)" -ForegroundColor Green
