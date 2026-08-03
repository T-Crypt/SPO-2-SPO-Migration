#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    50-Inventory.ps1
    Source enumeration. Uses PAGED enumeration (Get-PnPListItem -PageSize) and
    a CLIENT-SIDE filter for delta, deliberately avoiding CAML queries on the
    Modified field which fail past the 5,000-item list view threshold.

    Multi-library support: a site row may name several libraries via
    include/exclude filters; each library is enumerated independently.
#>

<#
    Resolve-SPOLibraries
    Decide which document libraries on a site should be migrated. Applies the
    include/exclude filters from the site row against a list of candidate
    library titles. Pure so it is unit-testable without a tenant.
#>
function Resolve-SPOLibraries {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]] $Available,
        [string] $Include,
        [string] $Exclude
    )

    $includeList = @()
    if (-not [string]::IsNullOrWhiteSpace($Include)) {
        $includeList = $Include -split '[;,|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    $excludeList = @()
    if (-not [string]::IsNullOrWhiteSpace($Exclude)) {
        $excludeList = $Exclude -split '[;,|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    $result = foreach ($lib in $Available) {
        $keep = $true
        if ($includeList.Count -gt 0) {
            $keep = $false
            foreach ($pat in $includeList) {
                if ($lib -like $pat) { $keep = $true; break }
            }
        }
        if ($keep -and $excludeList.Count -gt 0) {
            foreach ($pat in $excludeList) {
                if ($lib -like $pat) { $keep = $false; break }
            }
        }
        if ($keep) { $lib }
    }

    ,@($result)
}

<#
    Test-SPOItemInDelta
    Pure delta predicate: is a file's LastModified strictly newer than the
    cutoff? Null/invalid dates are treated as "in delta" (safer to recopy).
#>
function Test-SPOItemInDelta {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [datetime] $LastModified,
        [datetime] $Cutoff
    )
    if ($null -eq $LastModified) { return $true }
    return ($LastModified -gt $Cutoff)
}

<#
    New-SPOInventoryItem
    Normalise a raw list item into the flat shape the engine + ledger consume.
#>
function New-SPOInventoryItem {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $ServerRelativeUrl,
        [Parameter(Mandatory)][string] $LibraryServerRelativeUrl,
        [long]     $Length = 0,
        [datetime] $LastModified,
        [string]   $Name
    )
    if ([string]::IsNullOrEmpty($Name)) {
        $Name = ($ServerRelativeUrl -split '/')[-1]
    }
    [pscustomobject]@{
        PSTypeName               = 'SPOMigrate.InventoryItem'
        Name                     = $Name
        ServerRelativeUrl        = $ServerRelativeUrl
        LibraryServerRelativeUrl = $LibraryServerRelativeUrl
        Length                   = [long]$Length
        LastModified             = $LastModified
    }
}

<#
    Get-SPOInventory
    Enumerate one library with paging and (optionally) a client-side delta
    filter. The actual PnP calls are wrapped in Invoke-SPOResilient and pushed
    through a $Fetcher scriptblock so tests can inject a fake enumerator.

    $Fetcher signature: param($PageSize) -> IEnumerable of raw items, each with
    .FieldValues.FileRef, .FieldValues.File_x0020_Size, .FieldValues.Modified
#>
function Get-SPOInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string] $LibraryServerRelativeUrl,
        [Parameter(Mandatory)][scriptblock] $Fetcher,
        [int] $PageSize = 500,
        [SPOMigrationMode] $Mode = [SPOMigrationMode]::Full,
        [datetime] $DeltaCutoff,
        [string] $Scope = 'main'
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $raw = & $Fetcher $PageSize

    foreach ($r in $raw) {
        # tolerate both rich PnP items and simple test doubles
        $fileRef = $null; $size = 0; $modified = $null; $name = $null
        if ($r.PSObject.Properties['FieldValues'] -and $r.FieldValues) {
            $fv = $r.FieldValues
            if ($fv.ContainsKey('FileRef'))            { $fileRef = [string]$fv['FileRef'] }
            if ($fv.ContainsKey('File_x0020_Size'))    { [long]::TryParse([string]$fv['File_x0020_Size'], [ref]$size) | Out-Null }
            if ($fv.ContainsKey('Modified') -and $fv['Modified']) { $modified = [datetime]$fv['Modified'] }
            if ($fv.ContainsKey('FileLeafRef'))        { $name = [string]$fv['FileLeafRef'] }
        }
        else {
            if ($r.PSObject.Properties['ServerRelativeUrl']) { $fileRef = [string]$r.ServerRelativeUrl }
            if ($r.PSObject.Properties['Length'])            { $size = [long]$r.Length }
            if ($r.PSObject.Properties['LastModified'] -and $r.LastModified) { $modified = [datetime]$r.LastModified }
            if ($r.PSObject.Properties['Name'])              { $name = [string]$r.Name }
        }

        if ([string]::IsNullOrEmpty($fileRef)) { continue }
        # folders have no size field in the same way; skip anything ending in '/'
        if ($fileRef.EndsWith('/')) { continue }

        if ($Mode -eq [SPOMigrationMode]::Delta -and $PSBoundParameters.ContainsKey('DeltaCutoff')) {
            $when = if ($modified) { [datetime]$modified } else { [datetime]::MinValue }
            if (-not (Test-SPOItemInDelta -LastModified $when -Cutoff $DeltaCutoff)) {
                continue
            }
        }

        $itemModified = if ($modified) { [datetime]$modified } else { [datetime]::MinValue }
        $items.Add((New-SPOInventoryItem -ServerRelativeUrl $fileRef `
                    -LibraryServerRelativeUrl $LibraryServerRelativeUrl `
                    -Length $size -LastModified $itemModified `
                    -Name $name))
    }

    Write-SPOLogInfo "Inventory: $($items.Count) file(s) in $LibraryServerRelativeUrl (mode=$Mode)" -Scope $Scope
    ,$items.ToArray()
}
