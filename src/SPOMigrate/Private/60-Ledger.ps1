#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    60-Ledger.ps1
    Resumable, append-only ledger. Every transfer attempt is appended to a
    per-worker CSV. The ledger key is:

        source server-relative URL  +  '|'  +  last-modified (ISO-8601, UTC)

    Because the key embeds LastModified, an edited source file produces a NEW
    key and is therefore re-copied on the next run rather than being treated as
    "already done". -Resume rebuilds the set of SUCCEEDED keys and skips only
    those, retrying everything else.
#>

$script:SPOLedgerHeader = 'Key,SourceUrl,DestUrl,LastModifiedUtc,SizeBytes,Status,Verdict,Sha256,Attempt,TimestampUtc,Message'

<#
    Get-SPOLedgerKey : the canonical resumability key. Pure + deterministic.
#>
function Get-SPOLedgerKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $SourceUrl,
        [datetime] $LastModified
    )
    $src = ConvertTo-SPOServerRelativeUrl -Url $SourceUrl
    $stamp = if ($null -eq $LastModified) {
        '0'
    }
    else {
        $LastModified.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    '{0}|{1}' -f $src, $stamp
}

function Initialize-SPOLedger {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $WorkerId
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }
    $safeWorker = $WorkerId -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $Directory ("ledger_{0}.csv" -f $safeWorker)
    if (-not (Test-Path -LiteralPath $path)) {
        Set-Content -LiteralPath $path -Value $script:SPOLedgerHeader -Encoding utf8
    }
    $path
}

<#
    Add-SPOLedgerEntry : append one attempt. Thread safety is provided by the
    caller owning one ledger file per worker (no cross-thread writes), so no
    lock is required here.
#>
function Add-SPOLedgerEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LedgerPath,
        [Parameter(Mandatory)][string] $Key,
        [string] $SourceUrl,
        [string] $DestUrl,
        [datetime] $LastModified,
        [long]   $SizeBytes = 0,
        [ValidateSet('Success', 'Failed', 'Skipped')]
        [string] $Status = 'Failed',
        [SPOItemVerdict] $Verdict = [SPOItemVerdict]::Pending,
        [string] $Sha256 = '',
        [int]    $Attempt = 1,
        [string] $Message = ''
    )

    $lm = if ($null -eq $LastModified) { '' } else { $LastModified.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
    $row = [pscustomobject]@{
        Key             = $Key
        SourceUrl       = $SourceUrl
        DestUrl         = $DestUrl
        LastModifiedUtc = $lm
        SizeBytes       = $SizeBytes
        Status          = $Status
        Verdict         = $Verdict
        Sha256          = $Sha256
        Attempt         = $Attempt
        TimestampUtc    = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        Message         = ($Message -replace '[\r\n]+', ' ')
    }
    # Export a single row without the header, appended to the worker ledger.
    $line = ($row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)
    Add-Content -LiteralPath $LedgerPath -Value $line -Encoding utf8
}

<#
    Get-SPOCompletedKeys : rebuild the set of keys that have at least one
    Success row across ALL ledger files in a directory. Used by -Resume.
#>
function Get-SPOCompletedKeys {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory)][string] $Directory)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Directory)) { return $set }

    $files = Get-ChildItem -LiteralPath $Directory -Filter 'ledger_*.csv' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $rows = Import-Csv -LiteralPath $f.FullName
        }
        catch {
            Write-SPOLogWarn "Could not parse ledger $($f.Name): $($_.Exception.Message)"
            continue
        }
        foreach ($r in $rows) {
            if ($r.PSObject.Properties['Status'] -and $r.Status -eq 'Success' -and
                $r.PSObject.Properties['Key'] -and -not [string]::IsNullOrEmpty($r.Key)) {
                [void]$set.Add($r.Key)
            }
        }
    }
    $set
}

<#
    Split-SPOInventoryForResume : given the full inventory and the completed-key
    set, return { ToTransfer = [...] ; Skipped = [...] }.
#>
function Split-SPOInventoryForResume {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Inventory,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]] $CompletedKeys
    )

    $toTransfer = [System.Collections.Generic.List[object]]::new()
    $skipped    = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $Inventory) {
        $key = Get-SPOLedgerKey -SourceUrl $item.ServerRelativeUrl -LastModified $item.LastModified
        if ($CompletedKeys.Contains($key)) {
            $skipped.Add($item)
        }
        else {
            $toTransfer.Add($item)
        }
    }

    [pscustomobject]@{
        ToTransfer = $toTransfer.ToArray()
        Skipped    = $skipped.ToArray()
    }
}
