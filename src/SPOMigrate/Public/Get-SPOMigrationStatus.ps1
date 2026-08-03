#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Summarise migration progress from the on-disk ledgers.
.DESCRIPTION
    Aggregates every ledger_*.csv in the ledger directory into per-status counts
    and a de-duplicated view (latest attempt per key wins). Works whether or not
    a run is currently in progress, so it can be used for -Status snapshots.
.EXAMPLE
    Get-SPOMigrationStatus -LedgerDirectory logs/ledger
#>
function Get-SPOMigrationStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $LedgerDirectory = 'logs/ledger'
    )

    $result = [pscustomobject]@{
        PSTypeName    = 'SPOMigrate.Status'
        LedgerDir     = $LedgerDirectory
        TotalAttempts = 0
        UniqueItems   = 0
        Succeeded     = 0
        Failed        = 0
        Skipped       = 0
        BytesMoved    = [long]0
        Attention     = 0
        Workers       = 0
    }

    if (-not (Test-Path -LiteralPath $LedgerDirectory)) {
        Write-SPOLogWarn "No ledger directory at $LedgerDirectory"
        return $result
    }

    $files = Get-ChildItem -LiteralPath $LedgerDirectory -Filter 'ledger_*.csv' -File -ErrorAction SilentlyContinue
    $result.Workers = $files.Count

    # latest attempt per key
    $latest = @{}
    foreach ($f in $files) {
        try { $rows = Import-Csv -LiteralPath $f.FullName } catch { continue }
        foreach ($r in $rows) {
            if (-not $r.PSObject.Properties['Key']) { continue }
            $result.TotalAttempts++
            $key = $r.Key
            if ([string]::IsNullOrEmpty($key)) { continue }
            $ts = [datetime]::MinValue
            if ($r.PSObject.Properties['TimestampUtc']) {
                [datetime]::TryParse([string]$r.TimestampUtc, [ref]$ts) | Out-Null
            }
            if (-not $latest.ContainsKey($key) -or $ts -ge $latest[$key].Ts) {
                $latest[$key] = [pscustomobject]@{ Ts = $ts; Row = $r }
            }
        }
    }

    $result.UniqueItems = $latest.Count
    foreach ($v in $latest.Values) {
        $r = $v.Row
        $status = if ($r.PSObject.Properties['Status']) { [string]$r.Status } else { '' }
        switch ($status) {
            'Success' {
                $result.Succeeded++
                $sz = 0
                if ($r.PSObject.Properties['SizeBytes']) { [long]::TryParse([string]$r.SizeBytes, [ref]$sz) | Out-Null }
                $result.BytesMoved += $sz
            }
            'Skipped' { $result.Skipped++ }
            default   { $result.Failed++ }
        }
        if ($r.PSObject.Properties['Verdict'] -and [string]$r.Verdict -eq 'Attention') {
            $result.Attention++
        }
    }

    $result
}
