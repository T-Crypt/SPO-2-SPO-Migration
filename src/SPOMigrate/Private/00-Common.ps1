#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    00-Common.ps1
    Foundation helpers shared across the whole module: types, small utilities,
    and pure functions with no external dependencies so they are trivially
    unit-testable without a tenant.
#>

# --------------------------------------------------------------------------
# Enums
# --------------------------------------------------------------------------
enum SPOMigrationMode {
    Plan
    Full
    Delta
    Verify
}

enum SPOErrorClass {
    Throttle
    Transient
    Locked
    Auth
    NotFound
    Fatal
}

enum SPOItemVerdict {
    Verified
    Attention
    Stopped
    Skipped
    Pending
}

# --------------------------------------------------------------------------
# New-SPOResult : a tiny discriminated-result helper so callers can branch on
# success without relying on exceptions for control flow.
# --------------------------------------------------------------------------
function New-SPOResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool] $Success,
        [object]   $Value,
        [string]   $Message,
        [SPOErrorClass] $ErrorClass = [SPOErrorClass]::Fatal
    )
    [pscustomobject]@{
        PSTypeName = 'SPOMigrate.Result'
        Success    = $Success
        Value      = $Value
        Message    = $Message
        ErrorClass = $ErrorClass
    }
}

# --------------------------------------------------------------------------
# ConvertTo-SPOBool : robust truthy parser for .env / CSV values.
# Accepts 1/0, true/false, yes/no, on/off (case-insensitive).
# --------------------------------------------------------------------------
function ConvertTo-SPOBool {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(ValueFromPipeline)] $Value,
        [bool] $Default = $false
    )
    process {
        if ($null -eq $Value) { return $Default }
        if ($Value -is [bool]) { return $Value }
        $s = ([string]$Value).Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($s)) { return $Default }
        switch ($s) {
            '1'     { return $true }
            'true'  { return $true }
            'yes'   { return $true }
            'y'     { return $true }
            'on'    { return $true }
            '0'     { return $false }
            'false' { return $false }
            'no'    { return $false }
            'n'     { return $false }
            'off'   { return $false }
            default { return $Default }
        }
    }
}

# --------------------------------------------------------------------------
# Get-SPOTimestamp : filesystem-safe timestamp used for log/report names.
# --------------------------------------------------------------------------
function Get-SPOTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param([datetime] $When = (Get-Date))
    $When.ToString('yyyyMMdd_HHmmss')
}

# --------------------------------------------------------------------------
# Format-SPOBytes : human-friendly byte formatter (1024 base).
# --------------------------------------------------------------------------
function Format-SPOBytes {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromPipeline)][double] $Bytes = 0)
    process {
        if ($Bytes -lt 0) { $Bytes = 0 }
        $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
        $idx = 0
        $val = [double]$Bytes
        while ($val -ge 1024 -and $idx -lt ($units.Count - 1)) {
            $val = $val / 1024
            $idx++
        }
        if ($idx -eq 0) {
            '{0} {1}' -f [int]$val, $units[$idx]
        }
        else {
            '{0:N2} {1}' -f $val, $units[$idx]
        }
    }
}

# --------------------------------------------------------------------------
# Format-SPODuration : seconds -> "1h 02m 03s"
# --------------------------------------------------------------------------
function Format-SPODuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([double] $Seconds = 0)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [timespan]::FromSeconds([math]::Round($Seconds))
    if ($ts.TotalHours -ge 1) {
        '{0}h {1:00}m {2:00}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
    }
    elseif ($ts.TotalMinutes -ge 1) {
        '{0}m {1:00}s' -f [int]$ts.TotalMinutes, $ts.Seconds
    }
    else {
        '{0}s' -f [int]$ts.TotalSeconds
    }
}

# --------------------------------------------------------------------------
# ConvertTo-SPOServerRelativeUrl : normalise a URL to a server-relative path.
# Strips scheme+host, collapses duplicate slashes, trims trailing slash.
# --------------------------------------------------------------------------
function ConvertTo-SPOServerRelativeUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Url)

    $u = $Url.Trim()
    if ($u -match '^[a-z]+://') {
        # strip scheme and host
        $noscheme = $u -replace '^[a-z]+://', ''
        $slash = $noscheme.IndexOf('/')
        if ($slash -ge 0) {
            $u = $noscheme.Substring($slash)
        }
        else {
            $u = '/'
        }
    }
    if (-not $u.StartsWith('/')) { $u = '/' + $u }
    # collapse duplicate slashes
    $u = $u -replace '/{2,}', '/'
    if ($u.Length -gt 1) { $u = $u.TrimEnd('/') }
    $u
}

# --------------------------------------------------------------------------
# Join-SPOUrl : join URL segments with exactly one slash between each.
# --------------------------------------------------------------------------
function Join-SPOUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromRemainingArguments)][string[]] $Segments)

    $parts = foreach ($s in $Segments) {
        if (-not [string]::IsNullOrEmpty($s)) { $s.Trim('/') }
    }
    ($parts | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join '/'
}

# --------------------------------------------------------------------------
# Get-SPOHostFromUrl : return scheme://host for an absolute URL, else $null.
# --------------------------------------------------------------------------
function Get-SPOHostFromUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Url)
    if ($Url -match '^([a-z]+://[^/]+)') {
        return $Matches[1]
    }
    return $null
}
