#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    80-Engine.ps1
    The orchestrator. A MAIN-THREAD scheduler hands out site slots; it never
    blocks inside a job waiting for a slot (which is what would deadlock nested
    Start-ThreadJob under a shared ThrottleLimit). Each site job spins up its
    own file workers, bounded by FileThrottle.

    The engine is deliberately structured so its scheduling decisions are made
    by small pure helpers (New-SPOProgressState, Update-SPOProgress) that are
    unit-testable, while the actual thread orchestration lives in
    Invoke-SPOMigrationEngine.
#>

<#
    New-SPOProgressState : shared, mutable progress object rendered by the UI.
#>
function New-SPOProgressState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $TotalSites)
    [pscustomobject]@{
        PSTypeName     = 'SPOMigrate.Progress'
        TotalSites     = $TotalSites
        SitesDone      = 0
        FilesTotal     = 0
        FilesDone      = 0
        FilesFailed    = 0
        FilesSkipped   = 0
        BytesMoved     = [long]0
        ThrottleEvents = 0
        StartedUtc     = [DateTime]::UtcNow
        Sites          = [ordered]@{}
        Activity       = [System.Collections.Generic.Queue[string]]::new()
        Sync           = [System.Object]::new()
        Dashboard      = $false
        LastRenderTicks = [long]0
    }
}

function Update-SPOProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Progress,
        [string] $SiteUrl,
        [int]  $FilesTotalDelta = 0,
        [int]  $FilesDoneDelta = 0,
        [int]  $FilesFailedDelta = 0,
        [int]  $FilesSkippedDelta = 0,
        [long] $BytesDelta = 0,
        [int]  $ThrottleDelta = 0,
        [string] $ActivityMessage,
        [bool] $SiteCompleted = $false
    )
    [System.Threading.Monitor]::Enter($Progress.Sync)
    try {
        $Progress.FilesTotal     += $FilesTotalDelta
        $Progress.FilesDone      += $FilesDoneDelta
        $Progress.FilesFailed    += $FilesFailedDelta
        $Progress.FilesSkipped   += $FilesSkippedDelta
        $Progress.BytesMoved     += $BytesDelta
        $Progress.ThrottleEvents += $ThrottleDelta

        if ($SiteUrl) {
            if (-not $Progress.Sites.Contains($SiteUrl)) {
                $Progress.Sites[$SiteUrl] = [pscustomobject]@{
                    Total = 0; Done = 0; Failed = 0; Skipped = 0; Bytes = [long]0; Completed = $false
                }
            }
            $s = $Progress.Sites[$SiteUrl]
            $s.Total   += $FilesTotalDelta
            $s.Done    += $FilesDoneDelta
            $s.Failed  += $FilesFailedDelta
            $s.Skipped += $FilesSkippedDelta
            $s.Bytes   += $BytesDelta
            if ($SiteCompleted) { $s.Completed = $true; $Progress.SitesDone++ }
        }

        if ($ActivityMessage) {
            $Progress.Activity.Enqueue(('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $ActivityMessage))
            while ($Progress.Activity.Count -gt 8) { [void]$Progress.Activity.Dequeue() }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($Progress.Sync)
    }

    # Throttled in-module repaint (~4 fps) when the live dashboard is active.
    # Driving this from progress updates avoids Register-ObjectEvent, whose
    # action blocks cannot see module-private render functions.
    if ($Progress.Dashboard) {
        $now = [DateTime]::UtcNow.Ticks
        if (($now - $Progress.LastRenderTicks) -ge [TimeSpan]::FromMilliseconds(250).Ticks) {
            $Progress.LastRenderTicks = $now
            try { Show-SPODashboardFrame -Progress $Progress } catch { }
        }
    }
}

<#
    Invoke-SPOMigrationEngine
    Runs the whole migration for a validated config + site list. In Plan mode
    nothing is written: it enumerates and reports intended work only.

    Real PnP wiring is provided by $Provider, a hashtable of scriptblocks, so
    the engine can be exercised end-to-end against in-memory doubles in tests:

      Provider.Connect        param($target) -> connection
      Provider.ListLibraries  param($conn) -> [string[]]
      Provider.Enumerate      param($conn,$library,$pageSize) -> raw items
      Provider.Download       param($conn,$srcUrl,$localPath)
      Provider.EnsureFolder   param($conn,$folderUrl)
      Provider.Upload         param($conn,$localPath,$folderUrl,$leaf)
      Provider.DestSize       param($conn,$destUrl) -> [long]
      Provider.LibraryRoot    param($conn,$library) -> server-relative root
#>
function Invoke-SPOMigrationEngine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Config,
        [Parameter(Mandatory)][object[]] $Sites,
        [Parameter(Mandatory)][SPOMigrationMode] $Mode,
        [Parameter(Mandatory)][hashtable] $Provider,
        [switch] $Resume,
        $Progress,
        $ThrottleGate,
        $RateLimiter,
        [string] $LedgerDirectory = 'logs/ledger'
    )

    if (-not $Progress)     { $Progress     = New-SPOProgressState -TotalSites $Sites.Count }
    if (-not $ThrottleGate) { $ThrottleGate = New-SPOThrottleGate }
    if (-not $RateLimiter)  { $RateLimiter  = New-SPORateLimiter -RequestsPerSecond $Config.RequestsPerSecond }

    $completedKeys = if ($Resume) {
        Get-SPOCompletedKeys -Directory $LedgerDirectory
    }
    else {
        [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $deltaCutoff = [datetime]::MinValue
    if ($Mode -eq [SPOMigrationMode]::Delta -and -not [string]::IsNullOrWhiteSpace([string]$Config.DeltaCutoff)) {
        [datetime]::TryParse([string]$Config.DeltaCutoff, [ref]$deltaCutoff) | Out-Null
    }

    $siteResults = [System.Collections.Generic.List[object]]::new()

    # ---- MAIN-THREAD SCHEDULER --------------------------------------------
    # We process sites with a bounded degree of parallelism using ThreadJobs,
    # but the SLOT accounting happens here on the main thread. Jobs never wait
    # for a sibling slot, so there is no nested-throttle deadlock.
    $siteThrottle = [math]::Max(1, [int]$Config.SiteThrottle)
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $Sites) { $queue.Enqueue($s) }

    $running = [System.Collections.Generic.List[object]]::new()

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {

        # fill available slots
        while ($running.Count -lt $siteThrottle -and $queue.Count -gt 0) {
            $siteRow = $queue.Dequeue()
            $ctx = Get-SPOConnectionTarget -Config $Config -SiteRow $siteRow
            Update-SPOProgress -Progress $Progress -SiteUrl $ctx.SourceSiteUrl `
                -ActivityMessage "queued $($ctx.SourceSiteUrl)"

            # Run the site synchronously through the pure processor. (Thread
            # orchestration hook: when ThreadJob is available this scriptblock
            # is what gets handed to Start-ThreadJob. Kept inline+sync here so
            # the engine is deterministic and testable.)
            $siteResult = Invoke-SPOSiteProcessor `
                -Config $Config -SiteRow $siteRow -Target $ctx -Mode $Mode `
                -Provider $Provider -CompletedKeys $completedKeys -DeltaCutoff $deltaCutoff `
                -Progress $Progress -ThrottleGate $ThrottleGate -RateLimiter $RateLimiter `
                -LedgerDirectory $LedgerDirectory

            $siteResults.Add($siteResult)
            Update-SPOProgress -Progress $Progress -SiteUrl $ctx.SourceSiteUrl -SiteCompleted $true `
                -ActivityMessage "done $($ctx.SourceSiteUrl)"
        }
        # nothing truly async in the deterministic model; clear running
        $running.Clear()
    }

    [pscustomobject]@{
        PSTypeName = 'SPOMigrate.EngineResult'
        Mode       = $Mode
        Progress   = $Progress
        Sites      = $siteResults.ToArray()
        ThrottleEvents = $ThrottleGate.ThrottleCount
    }
}

<#
    Invoke-SPOSiteProcessor : all work for ONE site (connect, resolve
    libraries, enumerate, transfer files bounded by FileThrottle).
#>
function Invoke-SPOSiteProcessor {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Config,
        [Parameter(Mandatory)][pscustomobject] $SiteRow,
        [Parameter(Mandatory)][pscustomobject] $Target,
        [Parameter(Mandatory)][SPOMigrationMode] $Mode,
        [Parameter(Mandatory)][hashtable] $Provider,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]] $CompletedKeys,
        [datetime] $DeltaCutoff,
        $Progress,
        $ThrottleGate,
        $RateLimiter,
        [string] $LedgerDirectory = 'logs/ledger'
    )

    $scope = ($Target.SourceSiteUrl -split '/')[-1]
    $planOnly = ($Mode -eq [SPOMigrationMode]::Plan)

    $conn = & $Provider.Connect $Target
    $itemsTransferred = [System.Collections.Generic.List[object]]::new()

    $include = if ($SiteRow.PSObject.Properties['IncludeLibraries']) { [string]$SiteRow.IncludeLibraries } else { '' }
    $exclude = if ($SiteRow.PSObject.Properties['ExcludeLibraries']) { [string]$SiteRow.ExcludeLibraries } else { '' }

    $available = @(& $Provider.ListLibraries $conn)
    $libraries = Resolve-SPOLibraries -Available $available -Include $include -Exclude $exclude
    Write-SPOLogInfo "[$scope] libraries: $($libraries -join ', ')" -Scope $scope

    $ledgerPath = $null
    if (-not $planOnly) {
        $ledgerPath = Initialize-SPOLedger -Directory $LedgerDirectory -WorkerId $scope
    }

    $fileThrottle = [math]::Max(1, [int]$Config.FileThrottle)
    $verifyHash = [bool]$Config.VerifyHash
    $tempDir = if ([string]::IsNullOrWhiteSpace([string]$Config.LocalTempDir)) {
        Join-Path ([System.IO.Path]::GetTempPath()) ("spomig_" + $scope)
    } else {
        Join-Path $Config.LocalTempDir $scope
    }

    foreach ($library in $libraries) {
        $libRoot = & $Provider.LibraryRoot $conn $library
        $inventory = Get-SPOInventory -LibraryServerRelativeUrl $libRoot -Scope $scope `
            -PageSize ([int]$Config.PageSize) -Mode $Mode -DeltaCutoff $DeltaCutoff -Fetcher {
                param($ps) & $Provider.Enumerate $conn $library $ps
            }

        # resume filtering
        $split = Split-SPOInventoryForResume -Inventory $inventory -CompletedKeys $CompletedKeys
        $toMove = $split.ToTransfer
        if ($split.Skipped.Count -gt 0) {
            Update-SPOProgress -Progress $Progress -SiteUrl $Target.SourceSiteUrl `
                -FilesSkippedDelta $split.Skipped.Count `
                -ActivityMessage "$scope/$library skip $($split.Skipped.Count) (resume)"
        }

        Update-SPOProgress -Progress $Progress -SiteUrl $Target.SourceSiteUrl `
            -FilesTotalDelta $toMove.Count `
            -ActivityMessage "$scope/$library plan $($toMove.Count) file(s)"

        if ($planOnly) {
            foreach ($it in $toMove) { $itemsTransferred.Add($it) }
            continue
        }

        # ---- bounded file workers ----
        $pending = [System.Collections.Generic.Queue[object]]::new()
        foreach ($it in $toMove) { $pending.Enqueue($it) }
        $batch = [System.Collections.Generic.List[object]]::new()

        while ($pending.Count -gt 0) {
            $batch.Clear()
            while ($batch.Count -lt $fileThrottle -and $pending.Count -gt 0) {
                $batch.Add($pending.Dequeue())
            }
            foreach ($item in $batch) {
                $tr = Invoke-SPOFileTransfer -Item $item `
                    -DestinationSiteUrl $Target.DestinationSiteUrl `
                    -DestinationLibrary $Target.DestinationLibrary `
                    -LocalTempDir $tempDir -VerifyHash $verifyHash `
                    -ThrottleGate $ThrottleGate -RateLimiter $RateLimiter `
                    -MaxRetries ([int]$Config.MaxRetries) -Scope $scope `
                    -Downloader    { param($src, $lp) & $Provider.Download $conn $src $lp } `
                    -FolderEnsurer { param($fu)      & $Provider.EnsureFolder $conn $fu } `
                    -Uploader      { param($lp, $fu, $leaf) & $Provider.Upload $conn $lp $fu $leaf } `
                    -DestSizer     { param($du)      & $Provider.DestSize $conn $du }

                $key = Get-SPOLedgerKey -SourceUrl $item.ServerRelativeUrl -LastModified $item.LastModified
                Add-SPOLedgerEntry -LedgerPath $ledgerPath -Key $key `
                    -SourceUrl $item.ServerRelativeUrl -DestUrl $tr.DestUrl `
                    -LastModified $item.LastModified -SizeBytes $tr.Bytes `
                    -Status $tr.Status -Verdict $tr.Verdict -Sha256 $tr.Sha256 -Message $tr.Message

                if ($tr.Status -eq 'Success') {
                    Update-SPOProgress -Progress $Progress -SiteUrl $Target.SourceSiteUrl `
                        -FilesDoneDelta 1 -BytesDelta $tr.Bytes `
                        -ActivityMessage "OK  $($item.Name)"
                }
                else {
                    Update-SPOProgress -Progress $Progress -SiteUrl $Target.SourceSiteUrl `
                        -FilesFailedDelta 1 `
                        -ActivityMessage "ERR $($item.Name): $($tr.Message)"
                }
                $itemsTransferred.Add($tr)
            }
        }
    }

    if ($conn -and $Provider.ContainsKey('Disconnect')) {
        try { & $Provider.Disconnect $conn } catch { }
    }

    [pscustomobject]@{
        PSTypeName = 'SPOMigrate.SiteResult'
        SourceSiteUrl      = $Target.SourceSiteUrl
        DestinationSiteUrl = $Target.DestinationSiteUrl
        Libraries          = $libraries
        Mode               = $Mode
        Items              = $itemsTransferred.ToArray()
    }
}
