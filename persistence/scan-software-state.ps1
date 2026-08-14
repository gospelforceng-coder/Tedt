[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
$parent = Split-Path $OutputPath -Parent
if ($parent -and !(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

# 1. Winget inventory (raw list output - same format as your baseline file)
$wingetList = @()
try {
    $wingetList = @(
        winget list --accept-source-agreements 2>$null |
        ForEach-Object { $_.ToString().TrimEnd() } |
        Where-Object { $_ -and $_ -notmatch "^Name\s+Id\s+Version" -and $_ -notmatch "^-+$" }
    )
} catch { Write-Warning "Could not capture winget inventory." }

# 2. Registry uninstall entries (catches non-winget installs too)
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$registrySoftware = @(
    Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    ForEach-Object {
        [ordered]@{
            DisplayName    = $_.DisplayName
            DisplayVersion = $_.DisplayVersion
            Publisher      = $_.Publisher
            InstallDate    = $_.InstallDate
        }
    }
)

# 3. Chocolatey inventory
$chocoList = @()
if (Get-Command choco -ErrorAction SilentlyContinue) {
    try { $chocoList = @(choco list --limit-output 2>$null) } catch {}
}

$state = [ordered]@{
    scannedUtc       = (Get-Date).ToUniversalTime().ToString("o")
    computer         = $env:COMPUTERNAME
    wingetList       = $wingetList
    registrySoftware = $registrySoftware
    chocoList        = $chocoList
}

$state | ConvertTo-Json -Depth 12 | Set-Content $OutputPath -Encoding UTF8
Write-Host "[OK] Software state saved to $OutputPath" -ForegroundColor Green