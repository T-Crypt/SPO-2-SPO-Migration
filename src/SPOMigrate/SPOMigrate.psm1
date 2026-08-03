#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    SPOMigrate.psm1
    Module loader. Dot-sources Private (ordered by numeric prefix) then Public,
    and exports only the Public functions. Keeping the file split this way means
    every helper is individually testable and the public surface stays small.
#>

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath

# Private helpers load first, in numeric order (00, 05, 10, ...).
$privateFiles = Get-ChildItem -Path (Join-Path $here 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name
foreach ($file in $privateFiles) {
    . $file.FullName
}

# Public functions.
$publicFiles = Get-ChildItem -Path (Join-Path $here 'Public') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name
foreach ($file in $publicFiles) {
    . $file.FullName
}

$publicNames = @(
    'Start-SPOMigration'
    'Show-SPOMigrationWizard'
    'Test-SPOMigrationEnvironment'
    'Get-SPOMigrationStatus'
    'New-SPOMigrationReport'
    'Import-SPOMigrationConfig'
)

Export-ModuleMember -Function $publicNames
