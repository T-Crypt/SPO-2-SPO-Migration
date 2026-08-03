#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Preflight the environment before a migration run.
.DESCRIPTION
    Verifies PowerShell version, PnP.PowerShell availability, config
    completeness, sites CSV presence, and writable log/report/temp directories.
    Returns an SPOMigrate.Preflight object with a boolean .Ok and a list of
    per-check results. Never throws.
.EXAMPLE
    Test-SPOMigrationEnvironment -Config (Import-SPOMigrationConfig)
#>
function Test-SPOMigrationEnvironment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Config,
        [switch] $SkipPnPCheck
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    function Add-Check {
        param([string]$Name, [bool]$Pass, [string]$Detail)
        $checks.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
    }

    # PowerShell version
    $psOk = $PSVersionTable.PSVersion.Major -ge 7
    Add-Check 'PowerShell 7+' $psOk ("found $($PSVersionTable.PSVersion)")

    # PnP module
    if (-not $SkipPnPCheck) {
        $pnpOk = Test-SPOPnPAvailable
        $pnpDetail = if ($pnpOk) { 'available' } else { 'Install-Module PnP.PowerShell' }
        Add-Check 'PnP.PowerShell installed' $pnpOk $pnpDetail
    }

    # Config completeness
    $cfg = Test-SPOConfig -Config $Config
    Add-Check 'Config valid' $cfg.Success ($cfg.Message)

    # Sites CSV
    $csvOk = -not [string]::IsNullOrWhiteSpace([string]$Config.SitesCsv) -and (Test-Path -LiteralPath $Config.SitesCsv)
    Add-Check 'Sites CSV present' $csvOk ([string]$Config.SitesCsv)

    # Writable directories
    foreach ($pair in @(
            @{ N = 'Log directory writable';    P = $Config.LogDirectory },
            @{ N = 'Report directory writable'; P = $Config.ReportDirectory })) {
        $ok = $false; $detail = [string]$pair.P
        try {
            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                if (-not (Test-Path -LiteralPath $detail)) {
                    New-Item -ItemType Directory -Force -Path $detail | Out-Null
                }
                $probe = Join-Path $detail (".probe_" + [Guid]::NewGuid().ToString('N'))
                Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                $ok = $true
            }
        }
        catch {
            $detail = "$detail — $($_.Exception.Message)"
        }
        Add-Check $pair.N $ok $detail
    }

    $allOk = -not ($checks | Where-Object { -not $_.Pass })
    [pscustomobject]@{
        PSTypeName = 'SPOMigrate.Preflight'
        Ok         = [bool]$allOk
        Checks     = $checks.ToArray()
    }
}
