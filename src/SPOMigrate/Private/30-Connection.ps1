#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    30-Connection.ps1
    PnP.PowerShell connection management. Each site runspace gets its own
    isolated connection object (own cache, own token) — connections are never
    shared across threads. All connect calls go through Invoke-SPOResilient.
#>

function Test-SPOPnPAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $null -ne (Get-Module -ListAvailable -Name 'PnP.PowerShell' -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}

function Assert-SPOPnPModule {
    [CmdletBinding()]
    param()
    if (-not (Test-SPOPnPAvailable)) {
        throw "PnP.PowerShell is not installed. Run: Install-Module PnP.PowerShell -Scope CurrentUser"
    }
    Import-Module PnP.PowerShell -ErrorAction Stop
}

<#
    Connect-SPOSite
    Opens an isolated, returnable connection to a single site via
    certificate + app-only auth. Returns an SPOMigrate.Result whose Value is
    the PnP connection object.
#>
function Connect-SPOSite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SiteUrl,
        [Parameter(Mandatory)][string] $ClientId,
        [Parameter(Mandatory)][string] $Thumbprint,
        [Parameter(Mandatory)][string] $TenantId,
        $ThrottleGate,
        $RateLimiter,
        [string] $Scope = 'main'
    )

    Invoke-SPOResilient -OperationName "connect:$SiteUrl" -Scope $Scope `
        -ThrottleGate $ThrottleGate -RateLimiter $RateLimiter -Action {
            Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId `
                -Thumbprint $Thumbprint -Tenant $TenantId `
                -ReturnConnection -ErrorAction Stop
        }
}

function Disconnect-SPOSite {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $Connection)
    process {
        if ($null -eq $Connection) { return }
        try {
            Disconnect-PnPOnline -Connection $Connection -ErrorAction SilentlyContinue
        }
        catch {
            Write-SPOLogTrace "Disconnect ignored: $($_.Exception.Message)"
        }
    }
}

<#
    Get-SPOConnectionTarget
    Given the migration config and a per-site row, resolve the effective
    destination site + library, honouring per-site overrides in sites.csv.
#>
function Get-SPOConnectionTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Config,
        [Parameter(Mandatory)][pscustomobject] $SiteRow
    )

    $destSite = if ($SiteRow.PSObject.Properties['DestinationSiteUrl'] -and
                    -not [string]::IsNullOrWhiteSpace([string]$SiteRow.DestinationSiteUrl)) {
        [string]$SiteRow.DestinationSiteUrl
    }
    else {
        [string]$Config.DestinationSiteUrl
    }

    $destLib = if ($SiteRow.PSObject.Properties['DestinationLibrary'] -and
                   -not [string]::IsNullOrWhiteSpace([string]$SiteRow.DestinationLibrary)) {
        [string]$SiteRow.DestinationLibrary
    }
    else {
        [string]$Config.DestinationLibrary
    }

    [pscustomobject]@{
        PSTypeName         = 'SPOMigrate.ConnectionTarget'
        SourceSiteUrl      = [string]$SiteRow.SiteUrl
        DestinationSiteUrl = $destSite
        DestinationLibrary = $destLib
    }
}
