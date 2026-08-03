#Requires -Version 7.0
<#
.SYNOPSIS
    SPOMigrate CLI — SharePoint-to-SharePoint migration entry point.
.DESCRIPTION
    Thin front-end over the SPOMigrate module. Handles the operator verbs:

        -Setup       run the interactive wizard, write .env, then exit
        -Preflight   validate environment + config, then exit
        -Mode        Plan | Full | Delta | Verify   (default: Plan)
        -Resume      skip previously succeeded items
        -Report      regenerate an HTML report from the ledger, then exit
        -Status      print a ledger summary, then exit
        -Dashboard   show the live console dashboard during the run

.EXAMPLE
    ./migration.ps1 -Setup
.EXAMPLE
    ./migration.ps1 -Preflight
.EXAMPLE
    ./migration.ps1 -Mode Plan
.EXAMPLE
    ./migration.ps1 -Mode Full -Resume -Dashboard
.EXAMPLE
    ./migration.ps1 -Status
.EXAMPLE
    ./migration.ps1 -Report
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Setup,
    [switch] $Preflight,

    [ValidateSet('Plan', 'Full', 'Delta', 'Verify')]
    [string] $Mode = 'Plan',

    [switch] $Resume,
    [switch] $Report,
    [switch] $Status,
    [switch] $Dashboard,

    [string] $EnvFile = '.env',
    [string] $SettingsFile = 'config/settings.psd1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'src/SPOMigrate/SPOMigrate.psd1'
Import-Module $modulePath -Force

# Build config once from the layered sources.
$config = Import-SPOMigrationConfig -SettingsPath $SettingsFile -DotEnvPath $EnvFile

if ($Setup) {
    Show-SPOMigrationWizard -Path $EnvFile -Current $config | Out-Null
    return
}

if ($Preflight) {
    $result = Test-SPOMigrationEnvironment -Config $config
    foreach ($check in $result.Checks) {
        $mark = if ($check.Pass) { 'PASS' } else { 'FAIL' }
        $color = if ($check.Pass) { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1,-28} {2}" -f $mark, $check.Name, $check.Detail) -ForegroundColor $color
    }
    if (-not $result.Ok) { exit 1 }
    return
}

if ($Status) {
    $ledgerDir = Join-Path ([string]$config.LogDirectory) 'ledger'
    $s = Get-SPOMigrationStatus -LedgerDirectory $ledgerDir
    Write-Host "SPOMigrate status ($ledgerDir)" -ForegroundColor Cyan
    Write-Host ("  Unique items : {0}" -f $s.UniqueItems)
    Write-Host ("  Succeeded    : {0}" -f $s.Succeeded)
    Write-Host ("  Failed       : {0}" -f $s.Failed)
    Write-Host ("  Skipped      : {0}" -f $s.Skipped)
    Write-Host ("  Attention    : {0}" -f $s.Attention)
    Write-Host ("  Bytes moved  : {0}" -f $s.BytesMoved)
    return
}

if ($Report) {
    $ledgerDir = Join-Path ([string]$config.LogDirectory) 'ledger'
    $path = New-SPOMigrationReport -Config $config -FromLedger $ledgerDir
    Write-Host "Report written to $path" -ForegroundColor Green
    return
}

# Default: run a migration.
$null = Start-SPOMigration -Mode $Mode -Config $config -Resume:$Resume -Dashboard:$Dashboard
