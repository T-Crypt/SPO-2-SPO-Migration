@{
    # Committed, non-secret defaults. Secrets belong in .env (git-ignored) or
    # SPO_* environment variables. Anything here can be overridden by .env,
    # environment variables, or explicit CLI parameters (in that order).

    DestinationLibrary = 'Shared Documents'
    SitesCsv           = 'config/sites.csv'
    LogDirectory       = 'logs'
    ReportDirectory    = 'reports'

    # Concurrency. Keep SiteThrottle 4-6 to avoid tenant-level throttling;
    # FileThrottle above ~6 causes SPO to start rejecting uploads.
    SiteThrottle       = 4
    FileThrottle       = 5

    # Tenant-wide request ceiling (token bucket) shared across all workers.
    RequestsPerSecond  = 25
    MaxRetries         = 6
    PageSize           = 500

    # Verification. Size is always checked; SHA-256 is opt-in (slower).
    VerifyHash         = $false
}
