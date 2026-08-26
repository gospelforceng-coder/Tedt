[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$Urls = @(
        "https://drive.google.com/file/d/1dGEsc-2JzA8TaOG_NHUUmTqoFHcUxqzw/view?usp=drivesdk",
        "https://drive.google.com/file/d/1yqBWQSH2RY9gz7ZCE2J16k6j77z2owhI/view?usp=drivesdk",
        "https://drive.google.com/file/d/1OzIs5_vSfKIEnDa6ABa57gdt2MZcflu1/view?usp=drivesdk",
        "https://drive.google.com/file/d/1q57S-1w8yKdxtBr_5HpRgVHO3mKc-ITF/view?usp=drivesdk",
        "https://drive.google.com/file/d/1r6vukCciIE32V1qGdLEqr5KauFaiMZte/view?usp=drivesdk",
        "https://drive.google.com/file/d/1fejroZdX_wszMFle9EUXDpnTwgpZ5Ntd/view?usp=drivesdk",
        "https://drive.google.com/file/d/1Np16vmK9S35a73o74O-nuAWIH-CjlKxa/view?usp=drivesdk"
    ),
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

# 3. Download Google Drive Files into staging with unique output names
$counter = 1
foreach ($url in $Urls) {
    if ([string]::IsNullOrWhiteSpace($url)) { continue }

    Write-Host "[$counter/$($Urls.Count)] Downloading file from URL..." -ForegroundColor Yellow
    
    # Save to a unique indexed filename initially to avoid overwriting multi-part files
    $targetFilePath = Join-Path $stage "part_$counter.tmp"
    
    try {
        # Using --fuzzy lets gdown extract file IDs directly from standard web view links
        python -m gdown "$url" --fuzzy -O "$targetFilePath"
    } catch {
        Write-Host "[WARNING] Failed to download link #$counter: $url" -ForegroundColor Red
    }
    
    $counter++
}

# Rename downloaded files back to their original names if gdown preserved metadata, 
# or clean up stage structure
$downloadedFiles = Get-ChildItem -Path $stage -File | Sort-Object Name
Write-Host "[OK] Total files successfully downloaded to staging: $($downloadedFiles.Count)" -ForegroundColor Green

if ($downloadedFiles.Count -eq 0) {
    throw "No files were downloaded into $stage - check Google Drive permissions or links."
}

if (!(Test-Path $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }

# 4. Extract ALL Standalone & Primary Volume Archives
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   EXTRACTING DOWNLOADED ARCHIVES TO $DestRoot" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# Identify primary volume archives (.001, .part1.rar, .zip, .7z) or attempt direct extraction
$archivesToExtract = $downloadedFiles | Where-Object {
    $_.Name -notmatch "\.(00[2-9]|0[1-9][0-9]|[1-9][0-9][0-9])$" -and
    $_.Name -notmatch "\.part(0*[2-9]|[1-9][0-9]+)\.rar$" -and
    $_.Name -notmatch "\.z(0*[2-9]|[1-9][0-9]+)$" -and
    ($_.Extension -match "\.(zip|7z|rar|exe|tmp)$" -or $_.Name -match "\.001$")
}

if ($archivesToExtract.Count -eq 0) {
    $archivesToExtract = $downloadedFiles
}

foreach ($arc in $archivesToExtract) {
    Write-Host "Extracting archive: $($arc.Name) -> $DestRoot..." -ForegroundColor Gray
    
    # 7-Zip handles split volumes automatically when pointing to part 1 or .001/.tmp files
    & $SevenZipPath x "$($arc.FullName)" "-o$DestRoot" "-p$ArchivePassword" -y
}

# 5. Extract Nested Password-Protected Inner Archives
Write-Host "Checking for password-protected inner archives inside $DestRoot..." -ForegroundColor Yellow
$innerArchives = Get-ChildItem -Path $DestRoot -Include "*.zip", "*.7z", "*.rar" -Recurse -ErrorAction SilentlyContinue

foreach ($arc in $innerArchives) {
    $targetDir = Join-Path $arc.DirectoryName $arc.BaseName
    Write-Host "Extracting inner archive: $($arc.Name) -> $targetDir" -ForegroundColor Gray

    & $SevenZipPath x "$($arc.FullName)" "-o$targetDir" "-p$ArchivePassword" -y
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
