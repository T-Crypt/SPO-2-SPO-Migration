#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    10-Config.ps1
    Layered configuration:

        settings.psd1 (committed defaults)
            -> .env file (developer/operator local overrides)
                -> process environment variables (SPO_*)
                    -> explicit CLI parameters (highest precedence)

    Secrets are never written to logs or reports: Get-SPORedactedConfig masks
    anything whose key is in $script:SPOSecretKeys.
#>

$script:SPOSecretKeys = @(
    'ClientSecret'
    'CertificatePassword'
    'Thumbprint'          # not strictly secret, but noisy/identifying
    'PfxPassword'
)

# The canonical key set with types + env-var mapping. This is the single
# source of truth for what a config object contains.
$script:SPOConfigSchema = @(
    @{ Key = 'DestinationSiteUrl'; Env = 'SPO_DEST_SITE_URL';  Type = 'string'; Default = '' }
    @{ Key = 'DestinationLibrary'; Env = 'SPO_DEST_LIBRARY';   Type = 'string'; Default = 'Shared Documents' }
    @{ Key = 'SitesCsv';           Env = 'SPO_SITES_CSV';      Type = 'string'; Default = 'config/sites.csv' }
    @{ Key = 'LogDirectory';       Env = 'SPO_LOG_DIR';        Type = 'string'; Default = 'logs' }
    @{ Key = 'ReportDirectory';    Env = 'SPO_REPORT_DIR';     Type = 'string'; Default = 'reports' }
    @{ Key = 'LocalTempDir';       Env = 'SPO_TEMP_DIR';       Type = 'string'; Default = '' }
    @{ Key = 'ClientId';           Env = 'SPO_CLIENT_ID';      Type = 'string'; Default = '' }
    @{ Key = 'Thumbprint';         Env = 'SPO_CERT_THUMBPRINT';Type = 'string'; Default = '' }
    @{ Key = 'TenantId';           Env = 'SPO_TENANT_ID';      Type = 'string'; Default = '' }
    @{ Key = 'SiteThrottle';       Env = 'SPO_SITE_THROTTLE';  Type = 'int';    Default = 4 }
    @{ Key = 'FileThrottle';       Env = 'SPO_FILE_THROTTLE';  Type = 'int';    Default = 5 }
    @{ Key = 'RequestsPerSecond';  Env = 'SPO_RPS';            Type = 'int';    Default = 25 }
    @{ Key = 'MaxRetries';         Env = 'SPO_MAX_RETRIES';    Type = 'int';    Default = 6 }
    @{ Key = 'DeltaCutoff';        Env = 'SPO_DELTA_CUTOFF';   Type = 'string'; Default = '' }
    @{ Key = 'VerifyHash';         Env = 'SPO_VERIFY_HASH';    Type = 'bool';   Default = $false }
    @{ Key = 'PageSize';           Env = 'SPO_PAGE_SIZE';      Type = 'int';    Default = 500 }
)

function Read-SPODotEnv {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $Path = '.env')

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        # strip surrounding single/double quotes
        if ($val.Length -ge 2) {
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $result[$key] = $val
    }
    $result
}

function ConvertTo-SPOTypedValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Type,
        [object] $Value,
        [object] $Default
    )
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrEmpty($Value))) {
        return $Default
    }
    switch ($Type) {
        'int' {
            [int] $parsed = 0
            if ([int]::TryParse([string]$Value, [ref] $parsed)) { return $parsed }
            return $Default
        }
        'bool' { return (ConvertTo-SPOBool -Value $Value -Default ([bool]$Default)) }
        default { return [string]$Value }
    }
}

<#
    Import-SPOMigrationConfigInternal
    Builds the merged configuration object honouring the precedence order.
    $CliOverrides is a hashtable of already-typed values (only keys the caller
    actually set). $EnvTable defaults to the live process environment but is
    injectable for tests.
#>
function Import-SPOMigrationConfigInternal {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]    $SettingsPath = 'config/settings.psd1',
        [string]    $DotEnvPath   = '.env',
        [hashtable] $CliOverrides = @{},
        [hashtable] $EnvTable
    )

    if (-not $PSBoundParameters.ContainsKey('EnvTable')) {
        $EnvTable = @{}
        foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $EnvTable[[string]$e.Key] = [string]$e.Value
        }
    }

    # Layer 0: schema defaults
    $merged = [ordered]@{}
    foreach ($field in $script:SPOConfigSchema) {
        $merged[$field.Key] = $field.Default
    }

    # Layer 1: settings.psd1
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $psd = Import-PowerShellDataFile -LiteralPath $SettingsPath
            foreach ($field in $script:SPOConfigSchema) {
                if ($psd.ContainsKey($field.Key)) {
                    $merged[$field.Key] = ConvertTo-SPOTypedValue -Type $field.Type -Value $psd[$field.Key] -Default $merged[$field.Key]
                }
            }
        }
        catch {
            Write-SPOLogWarn "Failed to import settings from ${SettingsPath}: $($_.Exception.Message)"
        }
    }

    # Layer 2: .env
    $dotenv = Read-SPODotEnv -Path $DotEnvPath
    foreach ($field in $script:SPOConfigSchema) {
        if ($dotenv.ContainsKey($field.Env)) {
            $merged[$field.Key] = ConvertTo-SPOTypedValue -Type $field.Type -Value $dotenv[$field.Env] -Default $merged[$field.Key]
        }
    }

    # Layer 3: environment variables
    foreach ($field in $script:SPOConfigSchema) {
        if ($EnvTable.ContainsKey($field.Env)) {
            $merged[$field.Key] = ConvertTo-SPOTypedValue -Type $field.Type -Value $EnvTable[$field.Env] -Default $merged[$field.Key]
        }
    }

    # Layer 4: explicit CLI overrides (already typed)
    foreach ($k in $CliOverrides.Keys) {
        if ($merged.Contains($k)) {
            $merged[$k] = $CliOverrides[$k]
        }
        else {
            $merged[$k] = $CliOverrides[$k]
        }
    }

    $obj = [pscustomobject]$merged
    $obj.PSObject.TypeNames.Insert(0, 'SPOMigrate.Config')
    $obj
}

function Get-SPORedactedConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, ValueFromPipeline)][pscustomobject] $Config)
    process {
        $clone = [ordered]@{}
        foreach ($prop in $Config.PSObject.Properties) {
            if ($script:SPOSecretKeys -contains $prop.Name) {
                $val = [string]$prop.Value
                if ([string]::IsNullOrEmpty($val)) {
                    $clone[$prop.Name] = ''
                }
                elseif ($val.Length -le 4) {
                    $clone[$prop.Name] = '****'
                }
                else {
                    $clone[$prop.Name] = ('*' * ($val.Length - 4)) + $val.Substring($val.Length - 4)
                }
            }
            else {
                $clone[$prop.Name] = $prop.Value
            }
        }
        [pscustomobject]$clone
    }
}

function Test-SPOConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject] $Config)

    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($required in @('DestinationSiteUrl', 'ClientId', 'TenantId', 'Thumbprint')) {
        if ([string]::IsNullOrWhiteSpace([string]$Config.$required)) {
            $problems.Add("Missing required setting: $required")
        }
    }
    if ($Config.SiteThrottle -lt 1 -or $Config.SiteThrottle -gt 10) {
        $problems.Add("SiteThrottle ($($Config.SiteThrottle)) should be between 1 and 10.")
    }
    if ($Config.FileThrottle -lt 1 -or $Config.FileThrottle -gt 8) {
        $problems.Add("FileThrottle ($($Config.FileThrottle)) should be between 1 and 8 (SPO rejects uploads above ~6).")
    }
    if ($Config.RequestsPerSecond -lt 1) {
        $problems.Add("RequestsPerSecond must be >= 1.")
    }

    New-SPOResult -Success ($problems.Count -eq 0) -Value $problems -Message (($problems -join '; '))
}
