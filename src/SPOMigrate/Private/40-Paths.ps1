#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    40-Paths.ps1
    SharePoint / OneDrive path safety. All checks run BEFORE a download so we
    never pull bytes we can't legally re-upload. Pure functions -> unit tested.

    Rules enforced (SPO/ODB constraints):
      * illegal characters:  " * : < > ? / \ |  (plus control chars)
      * a leaf cannot start/end with a space, or end with a period
      * reserved leaf names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, and the
        SharePoint-reserved "_vti_", "forms" at library root, leading "~$")
      * full decoded path <= 400 chars
      * any single segment (leaf) <= 128 chars
#>

$script:SPOIllegalLeafChars = @('"', '*', ':', '<', '>', '?', '/', '\', '|')

$script:SPOReservedNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

function Test-SPOLeafName {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Leaf)

    $problems = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($Leaf)) {
        $problems.Add('empty segment')
    }
    else {
        if ($Leaf.Length -gt 128) {
            $problems.Add("segment exceeds 128 chars ($($Leaf.Length))")
        }
        foreach ($c in $script:SPOIllegalLeafChars) {
            if ($Leaf.Contains($c)) {
                $problems.Add("illegal character '$c'")
            }
        }
        foreach ($ch in $Leaf.ToCharArray()) {
            if ([int]$ch -lt 32) {
                $problems.Add('control character')
                break
            }
        }
        if ($Leaf.StartsWith(' ') -or $Leaf.EndsWith(' ')) {
            $problems.Add('leading/trailing space')
        }
        if ($Leaf.EndsWith('.')) {
            $problems.Add('trailing period')
        }
        if ($Leaf.StartsWith('~$')) {
            $problems.Add('reserved Office lock prefix "~$"')
        }
        $stem = ($Leaf -split '\.')[0]
        if ($script:SPOReservedNames -contains $stem.ToUpperInvariant()) {
            $problems.Add("reserved device name '$stem'")
        }
        if ($Leaf -match '_vti_') {
            $problems.Add('reserved token "_vti_"')
        }
    }

    [pscustomobject]@{
        PSTypeName = 'SPOMigrate.LeafCheck'
        Leaf       = $Leaf
        IsValid    = ($problems.Count -eq 0)
        Problems   = $problems.ToArray()
    }
}

function Test-SPOPathSafety {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [int] $MaxPath = 400,
        [int] $MaxLeaf = 128
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $normalized = $RelativePath -replace '\\', '/'
    $normalized = $normalized -replace '/{2,}', '/'

    if ($normalized.Length -gt $MaxPath) {
        $problems.Add("path exceeds $MaxPath chars ($($normalized.Length))")
    }

    $segments = $normalized.Trim('/') -split '/'
    foreach ($seg in $segments) {
        if ([string]::IsNullOrEmpty($seg)) { continue }
        $check = Test-SPOLeafName -Leaf $seg
        if (-not $check.IsValid) {
            foreach ($p in $check.Problems) {
                $problems.Add("segment '$seg': $p")
            }
        }
    }

    [pscustomobject]@{
        PSTypeName = 'SPOMigrate.PathCheck'
        Path       = $normalized
        IsValid    = ($problems.Count -eq 0)
        Problems   = $problems.ToArray()
    }
}

<#
    Get-SPODestinationUrl
    Compose the destination server-relative URL for a file. Preserves the
    folder structure BELOW the source library root and grafts it under the
    destination library. This is the spot the original script dropped the
    template folder — here we keep every intermediate segment intact.
#>
function Get-SPODestinationUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $DestinationSiteUrl,
        [Parameter(Mandatory)][string] $DestinationLibrary,
        [Parameter(Mandatory)][string] $SourceServerRelativeUrl,
        [Parameter(Mandatory)][string] $SourceLibraryServerRelativeUrl
    )

    $srcRoot = ConvertTo-SPOServerRelativeUrl -Url $SourceLibraryServerRelativeUrl
    $srcItem = ConvertTo-SPOServerRelativeUrl -Url $SourceServerRelativeUrl

    # Strip the library root prefix to obtain the sub-path (may be empty).
    $subPath = $srcItem
    if ($srcItem.StartsWith($srcRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $subPath = $srcItem.Substring($srcRoot.Length)
    }
    $subPath = $subPath.TrimStart('/')

    $destSiteRel = ConvertTo-SPOServerRelativeUrl -Url $DestinationSiteUrl
    $composed = Join-SPOUrl $destSiteRel $DestinationLibrary $subPath
    if (-not $composed.StartsWith('/')) { $composed = '/' + $composed }
    $composed -replace '/{2,}', '/'
}

<#
    Split-SPODestinationUrl
    Return the folder + leaf halves of a destination server-relative URL so the
    transfer layer can ensure the folder exists before Add-PnPFile.
#>
function Split-SPODestinationUrl {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $ServerRelativeUrl)

    $clean = ConvertTo-SPOServerRelativeUrl -Url $ServerRelativeUrl
    $idx = $clean.LastIndexOf('/')
    if ($idx -le 0) {
        return [pscustomobject]@{ Folder = '/'; Leaf = $clean.TrimStart('/') }
    }
    [pscustomobject]@{
        Folder = $clean.Substring(0, $idx)
        Leaf   = $clean.Substring($idx + 1)
    }
}
