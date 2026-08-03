#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Produce the self-contained HTML migration report.
.DESCRIPTION
    Accepts either a live SPOMigrate.EngineResult (from Start-SPOMigration) or,
    when only ledgers exist, reconstructs a summary from disk. Writes a single
    self-contained .html file and returns its path.
.EXAMPLE
    New-SPOMigrationReport -EngineResult $r -Config $cfg -Path reports/run.html
.EXAMPLE
    New-SPOMigrationReport -Config $cfg -FromLedger logs/ledger
#>
function New-SPOMigrationReport {
    [CmdletBinding(DefaultParameterSetName = 'Engine')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Engine')]
        [pscustomobject] $EngineResult,

        [Parameter(Mandatory, ParameterSetName = 'Ledger')]
        [string] $FromLedger,

        [Parameter(Mandatory)][pscustomobject] $Config,
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $dir = if ([string]::IsNullOrWhiteSpace([string]$Config.ReportDirectory)) { 'reports' } else { [string]$Config.ReportDirectory }
        $Path = Join-Path $dir ("SPOMigrate_{0}.html" -f (Get-SPOTimestamp))
    }

    if ($PSCmdlet.ParameterSetName -eq 'Ledger') {
        $status = Get-SPOMigrationStatus -LedgerDirectory $FromLedger
        $progress = New-SPOProgressState -TotalSites 0
        $progress.FilesTotal   = $status.UniqueItems
        $progress.FilesDone    = $status.Succeeded
        $progress.FilesFailed  = $status.Failed
        $progress.FilesSkipped = $status.Skipped
        $progress.BytesMoved   = $status.BytesMoved
        $EngineResult = [pscustomobject]@{
            PSTypeName = 'SPOMigrate.EngineResult'
            Mode       = 'Report'
            Progress   = $progress
            Sites      = @()
            ThrottleEvents = 0
        }
    }

    New-SPOHtmlReport -EngineResult $EngineResult -Config $Config -Path $Path
}
