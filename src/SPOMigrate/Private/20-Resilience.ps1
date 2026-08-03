#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    20-Resilience.ps1
    Invoke-SPOResilient wraps every SharePoint API call:
      * classifies the error (Throttle / Transient / Locked / Auth / NotFound)
      * honours Retry-After
      * on throttling, cools down ALL workers together via a shared gate
      * enforces a tenant-wide requests-per-second ceiling
      * fails fast on Auth (no point burning six retries on a dead token)

    The shared throttle gate and RPS limiter are exposed as thread-safe objects
    that the engine seeds into each worker's runspace.
#>

# --------------------------------------------------------------------------
# Get-SPOErrorClass : pure classifier. Given an ErrorRecord or Exception,
# return an [SPOErrorClass]. Kept pure so it is directly unit-testable.
# --------------------------------------------------------------------------
function Get-SPOErrorClass {
    [CmdletBinding()]
    [OutputType([SPOErrorClass])]
    param([Parameter(Mandatory)] $ErrorObject)

    $ex = $null
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorObject.Exception
    }
    elseif ($ErrorObject -is [Exception]) {
        $ex = $ErrorObject
    }

    $statusCode = 0
    $message    = ''
    if ($ex) {
        $message = [string]$ex.Message
        # dig for an HTTP status code on common exception shapes
        $resp = $ex.PSObject.Properties['Response']
        if ($resp -and $resp.Value) {
            $sc = $resp.Value.PSObject.Properties['StatusCode']
            if ($sc -and $sc.Value) {
                try { $statusCode = [int]$sc.Value } catch { $statusCode = 0 }
            }
        }
    }
    else {
        $message = [string]$ErrorObject
    }

    # explicit status codes win
    switch ($statusCode) {
        429 { return [SPOErrorClass]::Throttle }
        503 { return [SPOErrorClass]::Throttle }
        401 { return [SPOErrorClass]::Auth }
        403 { return [SPOErrorClass]::Auth }
        404 { return [SPOErrorClass]::NotFound }
        423 { return [SPOErrorClass]::Locked }
        500 { return [SPOErrorClass]::Transient }
        502 { return [SPOErrorClass]::Transient }
        504 { return [SPOErrorClass]::Transient }
    }

    $m = $message.ToLowerInvariant()
    if ($m -match 'throttl|too many requests|429|request limit|traffic') {
        return [SPOErrorClass]::Throttle
    }
    if ($m -match 'unauthor|access denied|forbidden|401|403|token|invalid_grant|expired') {
        return [SPOErrorClass]::Auth
    }
    if ($m -match 'locked|423|checked out|being used by another') {
        return [SPOErrorClass]::Locked
    }
    if ($m -match 'not found|404|does not exist|cannot be found') {
        return [SPOErrorClass]::NotFound
    }
    if ($m -match 'timed out|timeout|temporarily|reset by peer|connection|socket|502|503|504|500') {
        return [SPOErrorClass]::Transient
    }

    return [SPOErrorClass]::Fatal
}

# --------------------------------------------------------------------------
# Get-SPORetryAfterSeconds : extract a Retry-After hint (seconds) from an
# exception's headers/message. Returns 0 when none is present.
# --------------------------------------------------------------------------
function Get-SPORetryAfterSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] $ErrorObject)

    $ex = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    if ($null -eq $ex) { return 0 }

    # Try structured headers first
    $resp = $ex.PSObject.Properties['Response']
    if ($resp -and $resp.Value) {
        $headers = $resp.Value.PSObject.Properties['Headers']
        if ($headers -and $headers.Value) {
            try {
                $ra = $headers.Value['Retry-After']
                if ($ra) {
                    $secs = 0
                    if ([int]::TryParse([string]$ra, [ref] $secs)) { return $secs }
                }
            }
            catch { }
        }
    }

    # Fall back to scraping the message
    $msg = [string]$ex.Message
    if ($msg -match 'retry[- ]after[:\s]+(\d+)') {
        return [int]$Matches[1]
    }
    return 0
}

# --------------------------------------------------------------------------
# Get-SPOBackoffSeconds : exponential backoff with full jitter.
# base * 2^(attempt-1), capped, then randomised in [0, computed].
# --------------------------------------------------------------------------
function Get-SPOBackoffSeconds {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][int] $Attempt,
        [double] $BaseSeconds = 1.0,
        [double] $CapSeconds  = 60.0,
        [System.Random] $Random
    )
    if ($Attempt -lt 1) { $Attempt = 1 }
    $exp = $BaseSeconds * [math]::Pow(2, ($Attempt - 1))
    if ($exp -gt $CapSeconds) { $exp = $CapSeconds }
    if ($Random) {
        return [double]($Random.NextDouble() * $exp)
    }
    return [double]$exp
}

# --------------------------------------------------------------------------
# Shared coordination objects. These are plain objects so they can be passed
# into thread jobs (reference-shared across the process).
# --------------------------------------------------------------------------
function New-SPOThrottleGate {
    [CmdletBinding()]
    param()
    # CooldownUntil is UTC ticks; workers park until now >= CooldownUntil.
    [pscustomobject]@{
        PSTypeName    = 'SPOMigrate.ThrottleGate'
        CooldownUntil = [long]0
        Sync          = [System.Object]::new()
        ThrottleCount = [int]0
    }
}

function Set-SPOGlobalCooldown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Gate,
        [Parameter(Mandatory)][double] $Seconds
    )
    $until = [DateTime]::UtcNow.AddSeconds($Seconds).Ticks
    [System.Threading.Monitor]::Enter($Gate.Sync)
    try {
        if ($until -gt $Gate.CooldownUntil) {
            $Gate.CooldownUntil = $until
        }
        $Gate.ThrottleCount = $Gate.ThrottleCount + 1
    }
    finally {
        [System.Threading.Monitor]::Exit($Gate.Sync)
    }
}

function Wait-SPOGlobalCooldown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Gate,
        [int] $PollMs = 100
    )
    while ($true) {
        $now = [DateTime]::UtcNow.Ticks
        $until = $Gate.CooldownUntil
        if ($now -ge $until) { break }
        $remainMs = [int](([timespan]::FromTicks($until - $now)).TotalMilliseconds)
        Start-Sleep -Milliseconds ([math]::Min($remainMs, $PollMs))
    }
}

# --------------------------------------------------------------------------
# Token-bucket RPS limiter. Thread-safe acquire.
# --------------------------------------------------------------------------
function New-SPORateLimiter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $RequestsPerSecond)
    [pscustomobject]@{
        PSTypeName        = 'SPOMigrate.RateLimiter'
        RequestsPerSecond = [math]::Max(1, $RequestsPerSecond)
        Tokens            = [double]$RequestsPerSecond
        LastRefillTicks   = [DateTime]::UtcNow.Ticks
        Sync              = [System.Object]::new()
    }
}

function Request-SPORateToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Limiter,
        [int] $PollMs = 20
    )
    while ($true) {
        [System.Threading.Monitor]::Enter($Limiter.Sync)
        try {
            $now = [DateTime]::UtcNow.Ticks
            $elapsed = ([timespan]::FromTicks($now - $Limiter.LastRefillTicks)).TotalSeconds
            if ($elapsed -gt 0) {
                $Limiter.Tokens = [math]::Min(
                    $Limiter.RequestsPerSecond,
                    $Limiter.Tokens + ($elapsed * $Limiter.RequestsPerSecond))
                $Limiter.LastRefillTicks = $now
            }
            if ($Limiter.Tokens -ge 1) {
                $Limiter.Tokens = $Limiter.Tokens - 1
                return
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($Limiter.Sync)
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

# --------------------------------------------------------------------------
# Invoke-SPOResilient : the wrapper. $Action is a scriptblock performing a
# single API call. Coordination objects are optional so the function is unit
# testable on its own.
# --------------------------------------------------------------------------
function Invoke-SPOResilient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [string] $OperationName = 'operation',
        [int]    $MaxRetries    = 6,
        [double] $BaseSeconds   = 1.0,
        [double] $CapSeconds    = 60.0,
        $ThrottleGate,
        $RateLimiter,
        [string] $Scope = 'main',
        [System.Random] $Random = ([System.Random]::new())
    )

    $attempt = 0
    while ($true) {
        $attempt++

        if ($ThrottleGate) { Wait-SPOGlobalCooldown -Gate $ThrottleGate }
        if ($RateLimiter)  { Request-SPORateToken   -Limiter $RateLimiter }

        try {
            $value = & $Action
            return (New-SPOResult -Success $true -Value $value)
        }
        catch {
            $class = Get-SPOErrorClass -ErrorObject $_

            # Fail fast on auth — retrying a dead token wastes the whole budget.
            if ($class -eq [SPOErrorClass]::Auth) {
                Write-SPOLogError "[$OperationName] auth failure, not retrying: $($_.Exception.Message)" -Scope $Scope
                return (New-SPOResult -Success $false -Value $null -Message $_.Exception.Message -ErrorClass $class)
            }

            # NotFound is terminal for the item but not fatal for the run.
            if ($class -eq [SPOErrorClass]::NotFound) {
                Write-SPOLogWarn "[$OperationName] not found: $($_.Exception.Message)" -Scope $Scope
                return (New-SPOResult -Success $false -Value $null -Message $_.Exception.Message -ErrorClass $class)
            }

            if ($attempt -gt $MaxRetries) {
                Write-SPOLogError "[$OperationName] exhausted $MaxRetries retries ($class): $($_.Exception.Message)" -Scope $Scope
                return (New-SPOResult -Success $false -Value $null -Message $_.Exception.Message -ErrorClass $class)
            }

            $retryAfter = Get-SPORetryAfterSeconds -ErrorObject $_
            $wait = if ($retryAfter -gt 0) {
                [double]$retryAfter
            }
            else {
                Get-SPOBackoffSeconds -Attempt $attempt -BaseSeconds $BaseSeconds -CapSeconds $CapSeconds -Random $Random
            }

            if ($class -eq [SPOErrorClass]::Throttle -and $ThrottleGate) {
                # Cool down every worker, not just this one.
                Set-SPOGlobalCooldown -Gate $ThrottleGate -Seconds $wait
                Write-SPOLogWarn "[$OperationName] throttled; global cooldown ${wait}s (attempt $attempt/$MaxRetries)" -Scope $Scope
            }
            else {
                Write-SPOLogWarn "[$OperationName] $class; backing off ${wait}s (attempt $attempt/$MaxRetries)" -Scope $Scope
                Start-Sleep -Milliseconds ([int]($wait * 1000))
            }
        }
    }
}
