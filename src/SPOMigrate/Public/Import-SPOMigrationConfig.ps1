#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Build the merged, layered migration configuration.
.DESCRIPTION
    Merges settings.psd1 defaults, an optional .env file, SPO_* environment
    variables and explicit parameters (in that increasing order of precedence)
    into a single SPOMigrate.Config object.
.EXAMPLE
    Import-SPOMigrationConfig -SiteThrottle 6 | Get-SPORedactedConfig
#>
function Import-SPOMigrationConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $SettingsPath = 'config/settings.psd1',
        [string] $DotEnvPath   = '.env',
        [string] $DestinationSiteUrl,
        [string] $DestinationLibrary,
        [string] $SitesCsv,
        [string] $LogDirectory,
        [string] $ReportDirectory,
        [string] $LocalTempDir,
        [string] $ClientId,
        [string] $Thumbprint,
        [string] $TenantId,
        [int]    $SiteThrottle,
        [int]    $FileThrottle,
        [int]    $RequestsPerSecond,
        [int]    $MaxRetries,
        [string] $DeltaCutoff,
        [switch] $VerifyHash,
        [int]    $PageSize
    )

    # Only forward parameters the caller actually set.
    $overrides = @{}
    foreach ($name in @('DestinationSiteUrl', 'DestinationLibrary', 'SitesCsv',
            'LogDirectory', 'ReportDirectory', 'LocalTempDir', 'ClientId',
            'Thumbprint', 'TenantId', 'SiteThrottle', 'FileThrottle',
            'RequestsPerSecond', 'MaxRetries', 'DeltaCutoff', 'PageSize')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $overrides[$name] = $PSBoundParameters[$name]
        }
    }
    if ($PSBoundParameters.ContainsKey('VerifyHash')) {
        $overrides['VerifyHash'] = [bool]$VerifyHash
    }

    Import-SPOMigrationConfigInternal -SettingsPath $SettingsPath `
        -DotEnvPath $DotEnvPath -CliOverrides $overrides
}
