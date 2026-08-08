[CmdletBinding()]
param(
    [string]$GenerationPath = "D:\RDPState\restore",

    [string]$UserName = "RDP"
)

$ErrorActionPreference = "Stop"

$currentPath = Join-Path `
    $GenerationPath `
    "current.json"

$generation = Get-ChildItem `
    $GenerationPath `
    -Directory `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "^\d{6}$"
    } |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (!$generation) {
    throw "No restored generation found."
}

$profile = "C:\Users\$UserName"

$results = [ordered]@{

    Generation = $generation.Name

    Desktop =
        Test-Path "$profile\Desktop"

    Documents =
        Test-Path "$profile\Documents"

    Downloads =
        Test-Path "$profile\Downloads"

    ReWinPackage =
        Test-Path (
            Join-Path `
                $generation.FullName `
                "rewin\migration_package.json"
        )

    SoftwareState =
        Test-Path (
            Join-Path `
                $generation.FullName `
                "software-state.json"
        )
}

$results |
    ConvertTo-Json `
        -Depth 5

if ($results.Values -contains $false) {
    exit 1
}