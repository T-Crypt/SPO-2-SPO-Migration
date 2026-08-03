#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    05-Logging.ps1
    Thread-aware structured logging. Every worker writes to the same log file
    through a mutex; the console sink is suppressed while the live dashboard is
    active so ANSI frames are not corrupted.
#>

$script:SPOLogState = [ordered]@{
    Path        = $null
    MinLevel    = 'Info'
    ConsoleSink = $true
    Mutex       = $null
}

$script:SPOLogLevels = @{
    Trace = 0
    Debug = 1
    Info  = 2
    Warn  = 3
    Error = 4
}

function Initialize-SPOLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error')]
        [string] $MinLevel = 'Info',
        [bool] $ConsoleSink = $true
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $script:SPOLogState.Path        = $Path
    $script:SPOLogState.MinLevel    = $MinLevel
    $script:SPOLogState.ConsoleSink = $ConsoleSink
    # A named mutex lets thread jobs serialise file appends safely.
    $script:SPOLogState.Mutex = [System.Threading.Mutex]::new($false, 'SPOMigrate.Log')
    Write-SPOLog -Level Info -Message "Log initialised at $Path (minLevel=$MinLevel)"
}

function Set-SPOLogConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool] $Enabled)
    $script:SPOLogState.ConsoleSink = $Enabled
}

function Write-SPOLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error')]
        [string] $Level = 'Info',
        [Parameter(Mandatory)][string] $Message,
        [string] $Scope = 'main'
    )

    $threshold = $script:SPOLogLevels[$script:SPOLogState.MinLevel]
    if ($script:SPOLogLevels[$Level] -lt $threshold) { return }

    $line = '{0} [{1,-5}] ({2}) {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),
        $Level.ToUpperInvariant(), $Scope, $Message

    if ($script:SPOLogState.Path) {
        $mutex = $script:SPOLogState.Mutex
        $held = $false
        try {
            if ($mutex) { $held = $mutex.WaitOne(2000) }
            Add-Content -LiteralPath $script:SPOLogState.Path -Value $line -Encoding utf8
        }
        catch {
            # Logging must never throw into the migration path.
        }
        finally {
            if ($held) { $mutex.ReleaseMutex() }
        }
    }

    if ($script:SPOLogState.ConsoleSink) {
        $color = switch ($Level) {
            'Trace' { 'DarkGray' }
            'Debug' { 'Gray' }
            'Info'  { 'Gray' }
            'Warn'  { 'Yellow' }
            'Error' { 'Red' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Write-SPOLogTrace { param([string]$Message, [string]$Scope = 'main') Write-SPOLog -Level Trace -Message $Message -Scope $Scope }
function Write-SPOLogDebug { param([string]$Message, [string]$Scope = 'main') Write-SPOLog -Level Debug -Message $Message -Scope $Scope }
function Write-SPOLogInfo  { param([string]$Message, [string]$Scope = 'main') Write-SPOLog -Level Info  -Message $Message -Scope $Scope }
function Write-SPOLogWarn  { param([string]$Message, [string]$Scope = 'main') Write-SPOLog -Level Warn  -Message $Message -Scope $Scope }
function Write-SPOLogError { param([string]$Message, [string]$Scope = 'main') Write-SPOLog -Level Error -Message $Message -Scope $Scope }
