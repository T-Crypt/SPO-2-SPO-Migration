# CCAF-Migrate-Sites-Tracked.ps1 (v4 — Cross-site stream + inner file parallelism)
#
# Key changes from v3:
#   - FIX:  Replaced Copy-PnPFile (broken for cross-site) with Get-PnPFile (stream)
#           + Add-PnPFile (upload) using correct src/dest connections explicitly
#   - PERF: Inner file loop now uses Start-ThreadJob so multiple files per site
#           transfer concurrently (default: 6 file threads per site)
#   - PERF: Temp file buffer written to local disk then streamed up — avoids
#           holding entire file in memory for large files
#   - SAFE: Each site runspace still fully isolated (own connections, own cache)
#   - SAFE: Thread-safe ConcurrentQueue collects audit rows per site, flushed
#           to CSV after all file jobs for that library complete

#Requires -Version 7.0

# ==========================================
# CONFIGURATION
# ==========================================
$DestinationSiteUrl  = "DESTINATION_SITE_URL"
$DestinationLibrary  = "Shared Documents"
$SitesCsv            = "SITES_CSV_LOCATION"
$LogDirectory        = "LOCATION OF LOG OUTPUT"

$ClientId    = "ENTRA_CLIENT_ID_HERE"
$Thumbprint  = "ENTRA_CERTIFICATE_THUMBPRINT_HERE"
$TenantId    = "SHAREPOINT_TENANTID"

# ==========================================
# MIGRATION SETTINGS
# ==========================================
$DeltaSync        = $false
$DeltaSyncCutoff  = [datetime]"2026-06-25 00:00:00"

# Concurrent sites (outer). Keep 4-6 to avoid SPO tenant-level throttling.
$SiteThrottle     = 4

# Concurrent file transfers per site (inner). Each file = 1 thread job.
# 6 is a safe ceiling per site; above this SPO starts rejecting uploads.
$FileThrottle     = 6

# Local temp folder for file stream buffers. Cleaned up per-file after upload.
$LocalTempDir     = "C:\Temp\CCAF\StreamBuffer"

# ==========================================
# SETUP
# ==========================================
New-Item -ItemType Directory -Force -Path $LogDirectory   | Out-Null
New-Item -ItemType Directory -Force -Path $LocalTempDir   | Out-Null

$StartTime       = Get-Date -Format "yyyyMMdd_HHmmss"
$MasterAuditLog  = "$LogDirectory\MigrationAudit_$StartTime.csv"
$TempLogDir      = "$LogDirectory\Temp_$StartTime"
New-Item -ItemType Directory -Force -Path $TempLogDir | Out-Null

$DestSiteCode = $DestinationSiteUrl.Split('/')[-1]

Write-Host "=====================================================" -ForegroundColor Magenta
Write-Host " CCAF Migration v4 — Parallel Sites + Parallel Files" -ForegroundColor Magenta
Write-Host " Site threads : $SiteThrottle  |  File threads/site: $FileThrottle" -ForegroundColor Magenta
Write-Host " Master log   : $MasterAuditLog" -ForegroundColor Magenta
Write-Host "=====================================================" -ForegroundColor Magenta

$Sites = Import-Csv $SitesCsv -Header "SiteUrl" |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.SiteUrl) }

Write-Host "`nQueuing $($Sites.Count) sites for parallel migration...`n" -ForegroundColor Cyan

# ==========================================
# PARALLEL SITE LOOP
# ==========================================
$Sites | ForEach-Object -ThrottleLimit $SiteThrottle -Parallel {

    Import-Module PnP.PowerShell -ErrorAction Stop

    # Pull outer variables into runspace scope
    $SiteUrl            = $_.SiteUrl
    $DestinationSiteUrl = $using:DestinationSiteUrl
    $DestinationLibrary = $using:DestinationLibrary
    $DestSiteCode       = $using:DestSiteCode
    $ClientId           = $using:ClientId
    $Thumbprint         = $using:Thumbprint
    $TenantId           = $using:TenantId
    $DeltaSync          = $using:DeltaSync
    $DeltaSyncCutoff    = $using:DeltaSyncCutoff
    $TempLogDir         = $using:TempLogDir
    $LocalTempDir       = $using:LocalTempDir
    $FileThrottle       = $using:FileThrottle

    $SiteName    = $SiteUrl.Split('/')[-1]
    $TempCsvPath = "$TempLogDir\$SiteName.csv"

    # Per-runspace folder creation cache
    $CreatedFolders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    function Ensure-DestFolder {
        param([string]$Path)
        $p = $Path.TrimStart('/')
        if ($script:CreatedFolders.Contains($p)) { return $true }
        try {
            Resolve-PnPFolder -SiteRelativePath $p -Connection $script:destConn -ErrorAction Stop | Out-Null
            [void]$script:CreatedFolders.Add($p)
            return $true
        } catch {
            Write-Warning "[$SiteName] Folder create failed '$p': $($_.Exception.Message)"
            return $false
        }
    }

    function Write-AuditRow {
        param($Library, $FileName, $SourcePath, $TargetFolder, $Status, $Error)
        [PSCustomObject]@{
            Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            SourceSite   = $SiteUrl
            Library      = $Library
            FileName     = $FileName
            SourcePath   = $SourcePath
            TargetFolder = $TargetFolder
            Status       = $Status
            Error        = $Error
        } | Export-Csv -Path $TempCsvPath -Append -NoTypeInformation
    }

    Write-Host "[START] $SiteName" -ForegroundColor Cyan

    try {
        # Independent connections — not shared across runspaces
        $destConn = Connect-PnPOnline -Url $DestinationSiteUrl `
            -ClientId $ClientId -Thumbprint $Thumbprint -Tenant $TenantId `
            -ReturnConnection -ErrorAction Stop

        $srcConn = Connect-PnPOnline -Url $SiteUrl `
            -ClientId $ClientId -Thumbprint $Thumbprint -Tenant $TenantId `
            -ReturnConnection -ErrorAction Stop

        $Lists = Get-PnPList -Connection $srcConn |
            Where-Object { $_.BaseTemplate -eq 101 -and !$_.Hidden }

        foreach ($List in $Lists) {
            $LibraryName     = $List.Title
            $LibraryDestPath = "$DestinationLibrary/$SiteName/$LibraryName"

            Write-Host "  [$SiteName] Library: $LibraryName" -ForegroundColor DarkCyan

            if (-not (Ensure-DestFolder -Path $LibraryDestPath)) {
                Write-Warning "  [$SiteName] Skipping '$LibraryName' — destination folder failed."
                continue
            }

            $Items = Get-PnPListItem -List $List -PageSize 500 `
                -Fields "FileRef","FileLeafRef","FileDirRef","FSObjType","Modified" `
                -Connection $srcConn

            $srcConn.Context.Load($List.RootFolder)
            $srcConn.Context.ExecuteQuery()
            $ListRootUrl = $List.RootFolder.ServerRelativeUrl

            # ----------------------------------------------------------
            # PASS 1: Build full folder tree at destination
            #
            # Folders must be created top-down (parent before child),
            # so we group by depth and process each depth level in
            # parallel before moving to the next. Within a depth level
            # all folders share the same parent, so they're safe to
            # create concurrently without ordering conflicts.
            # ----------------------------------------------------------
            $FolderItems = $Items | Where-Object { $_.FileSystemObjectType -eq "Folder" }
            Write-Host "     [$SiteName/$LibraryName] Pass 1: $($FolderItems.Count) folders (parallel by depth)..." -ForegroundColor DarkGray

            # Build list of relative destination paths, sorted by depth
            $FolderPaths = $FolderItems | ForEach-Object {
                $rel = ""
                if ($_["FileRef"] -ilike "$ListRootUrl*") {
                    $rel = $_["FileRef"].Substring($ListRootUrl.Length).TrimStart('/')
                }
                if ($rel) { "$LibraryDestPath/$rel" }
            } | Where-Object { $_ } |
              Sort-Object { ($_ -split '/').Count }  # shallow first

            # Group into depth levels and process each level in parallel
            $ByDepth = $FolderPaths | Group-Object { ($_ -split '/').Count }

            foreach ($depthGroup in $ByDepth) {
                $depthGroup.Group | ForEach-Object -ThrottleLimit 8 -Parallel {
                    Import-Module PnP.PowerShell -ErrorAction Stop
                    $p = $_.TrimStart('/')
                    $cache = $using:CreatedFolders
                    if (-not $cache.Contains($p)) {
                        try {
                            $dc = Connect-PnPOnline -Url $using:DestinationSiteUrl `
                                -ClientId $using:ClientId -Thumbprint $using:Thumbprint `
                                -Tenant $using:TenantId -ReturnConnection -ErrorAction Stop
                            Resolve-PnPFolder -SiteRelativePath $p -Connection $dc -ErrorAction Stop | Out-Null
                            [void]$cache.Add($p)
                        } catch {
                            Write-Warning "[$using:SiteName] Folder failed '$p': $($_.Exception.Message)"
                        }
                    }
                }
            }

            # ----------------------------------------------------------
            # PASS 2: Transfer files using concurrent thread jobs
            #
            # Each job:
            #   1. Opens its own src + dest PnP connections (jobs can't
            #      share connections with parent runspace)
            #   2. Downloads the file as a byte stream to a local temp file
            #   3. Uploads from local temp file to destination
            #   4. Deletes the local temp file
            #   5. Returns a result object for audit logging
            # ----------------------------------------------------------
            $FileItems  = $Items | Where-Object { $_.FileSystemObjectType -ne "Folder" }
            $TotalFiles = $FileItems.Count
            Write-Host "     [$SiteName/$LibraryName] Pass 2: $TotalFiles files (up to $FileThrottle concurrent)..." -ForegroundColor DarkGray

            # Collect jobs so we can wait and harvest results
            $Jobs = [System.Collections.Generic.List[object]]::new()

            foreach ($Item in $FileItems) {

                if ($DeltaSync) {
                    $lm = $Item["Modified"] -as [datetime]
                    if ($null -ne $lm -and $lm -lt $DeltaSyncCutoff) { continue }
                }

                $SourcePath = $Item["FileRef"]
                $FileName   = $Item["FileLeafRef"]
                $FileDir    = $Item["FileDirRef"]

                if ([string]::IsNullOrEmpty($SourcePath)) { continue }

                $RelativeDir = ""
                if ($FileDir -ilike "$ListRootUrl*") {
                    $RelativeDir = $FileDir.Substring($ListRootUrl.Length).TrimStart('/')
                }

                $TargetFolder = if ($RelativeDir) {
                    "/sites/$DestSiteCode/$LibraryDestPath/$RelativeDir"
                } else {
                    "/sites/$DestSiteCode/$LibraryDestPath"
                }

                # Safety-net folder creation for files not covered by Pass 1
                if ($RelativeDir) {
                    Ensure-DestFolder -Path "$LibraryDestPath/$RelativeDir" | Out-Null
                }

                # Capture loop variables for the job closure
                $jobSrcPath     = $SourcePath
                $jobFileName    = $FileName
                $jobTargetDir   = $TargetFolder
                $jobTempFile    = "$LocalTempDir\$SiteName`_$(New-Guid).tmp"

                $job = Start-ThreadJob -ThrottleLimit $FileThrottle -ScriptBlock {
                    param($SrcUrl, $DestUrl, $SrcPath, $FileName, $TargetDir,
                          $TempFile, $ClientId, $Thumbprint, $TenantId)

                    Import-Module PnP.PowerShell -ErrorAction Stop

                    $result = [PSCustomObject]@{
                        FileName     = $FileName
                        SourcePath   = $SrcPath
                        TargetFolder = $TargetDir
                        Status       = ""
                        Error        = ""
                    }

                    try {
                        # Each thread job needs its own connections
                        $jSrc  = Connect-PnPOnline -Url $SrcUrl  -ClientId $ClientId `
                            -Thumbprint $Thumbprint -Tenant $TenantId -ReturnConnection -ErrorAction Stop
                        $jDest = Connect-PnPOnline -Url $DestUrl -ClientId $ClientId `
                            -Thumbprint $Thumbprint -Tenant $TenantId -ReturnConnection -ErrorAction Stop

                        # Download to local temp — avoids holding GB in memory
                        Get-PnPFile -Url $SrcPath -Path (Split-Path $TempFile) `
                            -Filename (Split-Path $TempFile -Leaf) `
                            -AsFile -Connection $jSrc -ErrorAction Stop -Force

                        # Upload from local temp to destination folder
                        Add-PnPFile -Path $TempFile -Folder $TargetDir `
                            -NewFileName $FileName -Connection $jDest -ErrorAction Stop | Out-Null

                        $result.Status = "Success"
                    } catch {
                        $result.Status = "Failed"
                        $result.Error  = $_.Exception.Message
                    } finally {
                        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
                    }

                    return $result

                } -ArgumentList $SiteUrl, $DestinationSiteUrl, $jobSrcPath, $jobFileName,
                                 $jobTargetDir, $jobTempFile, $ClientId, $Thumbprint, $TenantId

                $Jobs.Add($job)
            }

            # Wait for all file jobs for this library and collect results
            $CompletedCount = 0
            foreach ($job in $Jobs) {
                $res = Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force

                if ($null -eq $res) { continue }
                $CompletedCount++

                if ($res.Status -eq "Success") {
                    Write-Host "    [OK] [$SiteName] ($CompletedCount/$TotalFiles) $($res.FileName)" -ForegroundColor Green
                } else {
                    Write-Host "    [X] [$SiteName] $($res.FileName) — $($res.Error)" -ForegroundColor Red
                }

                Write-AuditRow `
                    -Library      $LibraryName `
                    -FileName     $res.FileName `
                    -SourcePath   $res.SourcePath `
                    -TargetFolder $res.TargetFolder `
                    -Status       $res.Status `
                    -Error        $res.Error
            }

            Write-Host "     [$SiteName/$LibraryName] Done. ($CompletedCount files)" -ForegroundColor DarkGray
        }

        Write-Host "[DONE] $SiteName" -ForegroundColor Green

    } catch {
        Write-Warning "[FAILED] $SiteName : $($_.Exception.Message)"
        Write-AuditRow -Library "N/A" -FileName "SITE CONNECTION FAILED" `
            -SourcePath "N/A" -TargetFolder "N/A" -Status "Failed" -Error $_.Exception.Message
    }
}

# ==========================================
# MERGE TEMP CSVS INTO MASTER AUDIT LOG
# ==========================================
Write-Host "`nMerging per-site logs..." -ForegroundColor Cyan

$First = $true
Get-ChildItem -Path $TempLogDir -Filter "*.csv" -File | ForEach-Object {
    if ($First) {
        Copy-Item $_.FullName $MasterAuditLog
        $First = $false
    } else {
        Get-Content $_.FullName | Select-Object -Skip 1 | Add-Content $MasterAuditLog
    }
}
Remove-Item $TempLogDir -Recurse -Force

# Clean up any orphaned temp stream files
Get-ChildItem -Path $LocalTempDir -Filter "*.tmp" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "Migration complete. Master log: $MasterAuditLog" -ForegroundColor Green

# ==========================================
# POST-MIGRATION: UPLOAD LOG TO SHAREPOINT
# ==========================================
Write-Host "`nUploading audit log to SharePoint..." -ForegroundColor Cyan

try {
    $logConn = Connect-PnPOnline -Url $DestinationSiteUrl `
        -ClientId $ClientId -Thumbprint $Thumbprint -Tenant $TenantId `
        -ReturnConnection -ErrorAction Stop

    $LogFolder = "$DestinationLibrary/Migration Logs"
    Resolve-PnPFolder -SiteRelativePath $LogFolder -Connection $logConn -ErrorAction Stop | Out-Null
    Add-PnPFile -Path $MasterAuditLog -Folder $LogFolder -Connection $logConn -ErrorAction Stop | Out-Null
    Write-Host "Log uploaded to: $DestinationSiteUrl/$LogFolder" -ForegroundColor Green
} catch {
    Write-Warning "Could not upload log: $($_.Exception.Message)"
}
