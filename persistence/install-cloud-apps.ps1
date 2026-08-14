[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Urls,
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

# 0. Verify the target drive actually exists on this RDP before doing anything
$driveLetter = ($DestRoot -split ':')[0]
if (!(Test-Path "$driveLetter`:\")) {
    throw "Drive $driveLetter`: does not exist on this machine. Check the RDP's actual temp-drive letter (it may be E: or F: instead of D:)."
}

if (!(Test-Path $SevenZipPath)) {
    $7zCmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($7zCmd) { $SevenZipPath = $7zCmd.Source }
    else { throw "7-Zip executable not found." }
}

Write-Host "Installing gdown for Google Drive downloads..." -ForegroundColor Yellow
Invoke-Checked "pip install gdown" { python -m pip install --quiet gdown }

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

    $fileId = $null
    if ($url -match "file/d/([^/]+)") {
        $fileId = $Matches[1]
    } elseif ($url -match "id=([^&]+)") {
        $fileId = $Matches[1]
    } else {
        $fileId = $url.Trim()
    }

    # Use the canonical URL form (not --id) so --fuzzy actually works,
    # and pad the index so lexical sort == download order later.
    $paddedIndex = "{0:D3}" -f $partIndex
    $outPath = Join-Path $stage "part_$paddedIndex"
    $driveUrl = "https://drive.google.com/uc?id=$fileId"

    Write-Host "Downloading Google Drive File ID [$fileId]..." -ForegroundColor Yellow
    Invoke-Checked "gdown download for $fileId" {
        python -m gdown $driveUrl -O "$outPath" --fuzzy
    }

    if (!(Test-Path $outPath) -or (Get-Item $outPath).Length -eq 0) {
        throw "Downloaded file for $fileId is missing or empty. Likely hit Google Drive's virus-scan/quota warning page instead of the real file."
    }

    $partIndex++
}

if (!(Test-Path $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }

# 2. Extract primary downloaded archives to D:\Software
Write-Host "Extracting downloaded bundle parts to $DestRoot..." -ForegroundColor Gray
$downloadedFiles = Get-ChildItem -Path $stage -File | Sort-Object Name

if ($downloadedFiles.Count -eq 0) {
    throw "No files were downloaded into $stage - nothing to extract."
}

Invoke-Checked "7z extraction of $($downloadedFiles[0].Name)" {
    & $SevenZipPath x "$($downloadedFiles[0].FullName)" "-o$DestRoot" "-p$ArchivePassword" -y
}

# 3. Recursively find and extract inner password-locked archives
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

# Confirm something actually landed in DestRoot
$installedCount = (Get-ChildItem -Path $DestRoot -Recurse -File -ErrorAction SilentlyContinue).Count
if ($installedCount -eq 0) {
    throw "Extraction reported success but $DestRoot is empty. Check archive password / file integrity."
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

Write-Host "[OK] Multi-part software extraction complete at $DestRoot ($installedCount files)" -ForegroundColor Green