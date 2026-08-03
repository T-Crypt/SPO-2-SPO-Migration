#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Run a SharePoint-to-SharePoint migration.
.DESCRIPTION
    Loads config, validates it, builds the live PnP provider (unless one is
    injected for testing), and drives the engine in the requested mode:

        Plan   dry-run inventory, writes nothing
        Full   copy everything
        Delta  copy only items modified after DeltaCutoff (client-side filter)
        Verify re-check sizes/hashes of already-copied items

    Supports -Resume (skip previously succeeded keys) and an optional live
    dashboard. Returns an SPOMigrate.EngineResult.
.EXAMPLE
    Start-SPOMigration -Mode Plan
.EXAMPLE
    Start-SPOMigration -Mode Full -Resume -Dashboard
#>
function Start-SPOMigration {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Plan', 'Full', 'Delta', 'Verify')]
        [string] $Mode = 'Plan',
        [pscustomobject] $Config,
        [switch] $Resume,
        [switch] $Dashboard,
        [switch] $NoReport,
        [hashtable] $Provider,          # inject for tests; live provider built if absent
        [object[]] $Sites               # inject for tests; else read from CSV
    )

    if (-not $Config) { $Config = Import-SPOMigrationConfig }

    $migrationMode = [SPOMigrationMode]$Mode

    # ---- logging ----
    $ts = Get-SPOTimestamp
    $logPath = Join-Path ([string]$Config.LogDirectory) ("SPOMigrate_{0}.log" -f $ts)
    Initialize-SPOLog -Path $logPath -MinLevel 'Info' -ConsoleSink (-not $Dashboard)
    Write-SPOLogInfo "SPOMigrate starting — mode=$Mode resume=$Resume"
    Write-SPOLogInfo ("Config: " + ((Get-SPORedactedConfig -Config $Config) |
        ConvertTo-Json -Depth 3 -Compress))

    # ---- validate ----
    $valid = Test-SPOConfig -Config $Config
    if (-not $valid.Success) {
        Write-SPOLogError "Config invalid: $($valid.Message)"
        throw "Configuration is invalid: $($valid.Message)"
    }

    # ---- sites ----
    if (-not $Sites) {
        if (-not (Test-Path -LiteralPath $Config.SitesCsv)) {
            throw "Sites CSV not found: $($Config.SitesCsv)"
        }
        $Sites = @(Import-Csv -LiteralPath $Config.SitesCsv |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SiteUrl) })
    }
    if ($Sites.Count -eq 0) {
        Write-SPOLogWarn 'No sites to process.'
    }

    # ---- provider ----
    if (-not $Provider) {
        $Provider = New-SPOLivePnPProvider -Config $Config
    }

    $ledgerDir = Join-Path ([string]$Config.LogDirectory) 'ledger'
    $progress = New-SPOProgressState -TotalSites $Sites.Count
    $throttleGate = New-SPOThrottleGate
    $rateLimiter = New-SPORateLimiter -RequestsPerSecond $Config.RequestsPerSecond

    $whatIfBlocked = ($migrationMode -ne [SPOMigrationMode]::Plan) -and
                     (-not $PSCmdlet.ShouldProcess("$($Sites.Count) site(s)", "Migrate ($Mode)"))
    if ($whatIfBlocked) {
        Write-SPOLogWarn 'ShouldProcess declined; downgrading to Plan.'
        $migrationMode = [SPOMigrationMode]::Plan
    }

    # ---- optional dashboard ----
    # Repaints are driven from Update-SPOProgress (in-module, throttled) rather
    # than a background timer, so no Register-ObjectEvent scope issues.
    if ($Dashboard) {
        Set-SPOLogConsole -Enabled $false
        $progress.Dashboard = $true
    }

    try {
        $engineResult = Invoke-SPOMigrationEngine -Config $Config -Sites $Sites `
            -Mode $migrationMode -Provider $Provider -Progress $progress `
            -ThrottleGate $throttleGate -RateLimiter $rateLimiter `
            -LedgerDirectory $ledgerDir -Resume:$Resume
    }
    finally {
        if ($Dashboard) {
            $progress.Dashboard = $false
            Set-SPOLogConsole -Enabled $true
            Show-SPODashboardFrame -Progress $progress   # final frame
        }
    }

    Write-SPOLogInfo ("Complete — moved=$($progress.FilesDone) failed=$($progress.FilesFailed) " +
        "skipped=$($progress.FilesSkipped) bytes=$($progress.BytesMoved) throttle=$($throttleGate.ThrottleCount)")

    if (-not $NoReport) {
        $reportPath = New-SPOMigrationReport -EngineResult $engineResult -Config $Config
        Write-Host "Report: $reportPath" -ForegroundColor Cyan
    }

    $engineResult
}

<#
    New-SPOLivePnPProvider
    Builds the hashtable of PnP-backed scriptblocks the engine expects. This is
    the ONLY place that touches PnP.PowerShell cmdlets, keeping the rest of the
    module tenant-free and unit-testable.
#>
function New-SPOLivePnPProvider {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][pscustomobject] $Config)

    Assert-SPOPnPModule

    $provider = @{
        Connect = {
            param($target)
            $r = Connect-SPOSite -SiteUrl $target.SourceSiteUrl `
                -ClientId $Config.ClientId -Thumbprint $Config.Thumbprint -TenantId $Config.TenantId
            if (-not $r.Success) { throw "connect failed: $($r.Message)" }
            $r.Value
        }
        Disconnect = {
            param($conn)
            Disconnect-SPOSite -Connection $conn
        }
        ListLibraries = {
            param($conn)
            Get-PnPList -Connection $conn |
                Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden } |
                Select-Object -ExpandProperty Title
        }
        LibraryRoot = {
            param($conn, $library)
            $list = Get-PnPList -Identity $library -Connection $conn -Includes RootFolder
            $list.RootFolder.ServerRelativeUrl
        }
        Enumerate = {
            param($conn, $library, $pageSize)
            Get-PnPListItem -List $library -PageSize $pageSize -Connection $conn `
                -Fields 'FileRef', 'FileLeafRef', 'File_x0020_Size', 'Modified'
        }
        Download = {
            param($conn, $srcUrl, $localPath)
            $dir = Split-Path -Parent $localPath
            $leaf = Split-Path -Leaf $localPath
            Get-PnPFile -Url $srcUrl -Path $dir -Filename $leaf -AsFile -Force -Connection $conn
        }
        EnsureFolder = {
            param($conn, $folderUrl)
            Resolve-PnPFolder -SiteRelativePath $folderUrl -Connection $conn | Out-Null
        }
        Upload = {
            param($conn, $localPath, $folderUrl, $leaf)
            Add-PnPFile -Path $localPath -Folder $folderUrl -NewFileName $leaf -Connection $conn | Out-Null
        }
        DestSize = {
            param($conn, $destUrl)
            $f = Get-PnPFile -Url $destUrl -AsListItem -Connection $conn
            [long]$f['File_x0020_Size']
        }
    }

    # Capture $Config into each scriptblock so they remain valid after this
    # function returns (dynamic scoping would otherwise lose the local $Config).
    foreach ($k in @($provider.Keys)) {
        $provider[$k] = $provider[$k].GetNewClosure()
    }
    $provider
}
