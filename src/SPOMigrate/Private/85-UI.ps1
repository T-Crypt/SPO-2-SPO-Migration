#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    85-UI.ps1
    Live console dashboard. Renders a single ANSI frame per tick (cursor home +
    overwrite, no scroll spam): per-site bars, aggregate throughput, ETA, a
    throttle counter and a rolling activity feed. Falls back to plain lines when
    the host is not interactive (CI, redirected output).
#>

$script:ESC = [char]27

function Test-SPOInteractiveHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($env:SPO_NO_UI -eq '1') { return $false }
    if ([System.Console]::IsOutputRedirected) { return $false }
    try { return [bool]$Host.UI.RawUI } catch { return $false }
}

function Get-SPOProgressBar {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int] $Done,
        [Parameter(Mandatory)][int] $Total,
        [int] $Width = 24
    )
    if ($Total -le 0) {
        return ('[' + ('·' * $Width) + ']   -')
    }
    $ratio = [math]::Min(1.0, [double]$Done / [double]$Total)
    $filled = [int][math]::Round($ratio * $Width)
    $bar = ('█' * $filled) + ('·' * ($Width - $filled))
    '[{0}] {1,3}%' -f $bar, [int]($ratio * 100)
}

function Get-SPOThroughput {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Progress)

    $elapsed = ([DateTime]::UtcNow - $Progress.StartedUtc).TotalSeconds
    if ($elapsed -le 0) { $elapsed = 0.001 }
    $bytesPerSec = $Progress.BytesMoved / $elapsed
    $filesPerSec = $Progress.FilesDone / $elapsed

    $remaining = [math]::Max(0, $Progress.FilesTotal - $Progress.FilesDone - $Progress.FilesFailed)
    $etaSeconds = if ($filesPerSec -gt 0) { $remaining / $filesPerSec } else { 0 }

    [pscustomobject]@{
        BytesPerSec = $bytesPerSec
        FilesPerSec = $filesPerSec
        EtaSeconds  = $etaSeconds
        ElapsedSeconds = $elapsed
    }
}

function Format-SPODashboard {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Progress)

    $tp = Get-SPOThroughput -Progress $Progress
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('╔══════════════════════════════════════════════════════════════════╗')
    [void]$sb.AppendLine('║  SPOMigrate — SharePoint → SharePoint transfer                     ║')
    [void]$sb.AppendLine('╠══════════════════════════════════════════════════════════════════╣')

    [System.Threading.Monitor]::Enter($Progress.Sync)
    try {
        foreach ($entry in $Progress.Sites.GetEnumerator()) {
            $name = $entry.Key
            $s = $entry.Value
            $short = ($name -split '/')[-1]
            if ($short.Length -gt 18) { $short = $short.Substring(0, 17) + '…' }
            $bar = Get-SPOProgressBar -Done ($s.Done + $s.Skipped) -Total $s.Total
            [void]$sb.AppendLine(('║ {0,-18} {1}  {2,4} ok {3,3} err ║' -f $short, $bar, $s.Done, $s.Failed))
        }

        [void]$sb.AppendLine('╠══════════════════════════════════════════════════════════════════╣')
        $overall = Get-SPOProgressBar -Done ($Progress.FilesDone + $Progress.FilesSkipped) -Total $Progress.FilesTotal -Width 30
        [void]$sb.AppendLine(('║ TOTAL {0}                        ║' -f $overall))
        [void]$sb.AppendLine(('║ {0,-14} {1,-16} {2,-16} throttle:{3,-3} ║' -f
            ("↑ " + (Format-SPOBytes $Progress.BytesMoved)),
            ((Format-SPOBytes $tp.BytesPerSec) + '/s'),
            ('ETA ' + (Format-SPODuration $tp.EtaSeconds)),
            $Progress.ThrottleEvents))
        [void]$sb.AppendLine('╠═ activity ════════════════════════════════════════════════════════╣')
        foreach ($line in $Progress.Activity) {
            $trimmed = if ($line.Length -gt 64) { $line.Substring(0, 63) + '…' } else { $line }
            [void]$sb.AppendLine(('║ {0,-64} ║' -f $trimmed))
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($Progress.Sync)
    }
    [void]$sb.AppendLine('╚══════════════════════════════════════════════════════════════════╝')
    $sb.ToString()
}

function Show-SPODashboardFrame {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Progress)

    $frame = Format-SPODashboard -Progress $Progress
    if (Test-SPOInteractiveHost) {
        # cursor home + clear-to-end, single write
        [System.Console]::Write("$script:ESC[H$script:ESC[2J")
        [System.Console]::Write($frame)
    }
    else {
        # non-interactive: emit a compact single-line status
        $tp = Get-SPOThroughput -Progress $Progress
        Write-Host ("[{0}/{1} files, {2} err, {3}, ETA {4}]" -f
            $Progress.FilesDone, $Progress.FilesTotal, $Progress.FilesFailed,
            (Format-SPOBytes $Progress.BytesMoved), (Format-SPODuration $tp.EtaSeconds))
    }
}
