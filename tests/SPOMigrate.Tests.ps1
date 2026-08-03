#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    SPOMigrate.Tests.ps1
    Tenant-free Pester suite. Everything here runs against pure functions and
    in-memory provider doubles — no SharePoint, no network, no PnP module.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    $script:ManifestPath = Join-Path $ModuleRoot 'src/SPOMigrate/SPOMigrate.psd1'
    Import-Module $ManifestPath -Force

    # Re-dot-source the private files into THIS scope so tests can call helpers
    # directly (they are not exported from the module).
    $priv = Join-Path $ModuleRoot 'src/SPOMigrate/Private'
    Get-ChildItem -Path $priv -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
}

Describe 'Common helpers' {
    It 'ConvertTo-SPOBool parses truthy values' {
        ConvertTo-SPOBool -Value 'true'  | Should -BeTrue
        ConvertTo-SPOBool -Value '1'     | Should -BeTrue
        ConvertTo-SPOBool -Value 'yes'   | Should -BeTrue
        ConvertTo-SPOBool -Value 'on'    | Should -BeTrue
    }
    It 'ConvertTo-SPOBool parses falsy values' {
        ConvertTo-SPOBool -Value 'false' | Should -BeFalse
        ConvertTo-SPOBool -Value '0'     | Should -BeFalse
        ConvertTo-SPOBool -Value 'no'    | Should -BeFalse
    }
    It 'ConvertTo-SPOBool honours default on empty' {
        ConvertTo-SPOBool -Value '' -Default $true | Should -BeTrue
    }
    It 'Format-SPOBytes renders units' {
        Format-SPOBytes 512        | Should -Be '512 B'
        Format-SPOBytes 1024       | Should -Be '1.00 KB'
        Format-SPOBytes 1048576    | Should -Be '1.00 MB'
    }
    It 'Format-SPODuration renders h/m/s' {
        Format-SPODuration 5     | Should -Be '5s'
        Format-SPODuration 65    | Should -Be '1m 05s'
        Format-SPODuration 3665  | Should -Be '1h 01m 05s'
    }
    It 'ConvertTo-SPOServerRelativeUrl strips scheme+host' {
        ConvertTo-SPOServerRelativeUrl 'https://x.sharepoint.com/sites/A/Shared Documents/f.txt' |
            Should -Be '/sites/A/Shared Documents/f.txt'
    }
    It 'ConvertTo-SPOServerRelativeUrl collapses slashes and trims' {
        ConvertTo-SPOServerRelativeUrl '/sites//A//lib/' | Should -Be '/sites/A/lib'
    }
    It 'Join-SPOUrl joins with single slashes' {
        Join-SPOUrl '/sites/A/' '/Shared Documents' 'sub/' | Should -Be 'sites/A/Shared Documents/sub'
    }
}

Describe 'Config layering' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('spocfg_' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $script:settings = Join-Path $tmp 'settings.psd1'
        @"
@{ SiteThrottle = 3; FileThrottle = 4; DestinationLibrary = 'Docs' }
"@ | Set-Content -LiteralPath $settings
        $script:dotenv = Join-Path $tmp '.env'
        "SPO_SITE_THROTTLE=6`nSPO_TENANT_ID=contoso.onmicrosoft.com" | Set-Content -LiteralPath $dotenv
    }
    AfterAll { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'settings.psd1 overrides schema defaults' {
        $c = Import-SPOMigrationConfigInternal -SettingsPath $settings -DotEnvPath 'nope.env' -EnvTable @{}
        $c.FileThrottle | Should -Be 4
        $c.DestinationLibrary | Should -Be 'Docs'
    }
    It '.env overrides settings.psd1' {
        $c = Import-SPOMigrationConfigInternal -SettingsPath $settings -DotEnvPath $dotenv -EnvTable @{}
        $c.SiteThrottle | Should -Be 6
        $c.TenantId | Should -Be 'contoso.onmicrosoft.com'
    }
    It 'env vars override .env' {
        $c = Import-SPOMigrationConfigInternal -SettingsPath $settings -DotEnvPath $dotenv -EnvTable @{ SPO_SITE_THROTTLE = '9' }
        $c.SiteThrottle | Should -Be 9
    }
    It 'CLI overrides everything' {
        $c = Import-SPOMigrationConfigInternal -SettingsPath $settings -DotEnvPath $dotenv -EnvTable @{ SPO_SITE_THROTTLE = '9' } -CliOverrides @{ SiteThrottle = 2 }
        $c.SiteThrottle | Should -Be 2
    }
    It 'Get-SPORedactedConfig masks the thumbprint' {
        $c = Import-SPOMigrationConfigInternal -SettingsPath $settings -DotEnvPath 'nope' -EnvTable @{ SPO_CERT_THUMBPRINT = 'ABCDEF0123456789' }
        $r = Get-SPORedactedConfig -Config $c
        $r.Thumbprint | Should -Match '^\*+6789$'
    }
}

Describe 'Error classification' {
    It 'classifies HTTP 429 as Throttle' {
        $ex = [Exception]::new('Server returned 429 Too Many Requests')
        Get-SPOErrorClass -ErrorObject $ex | Should -Be ([SPOErrorClass]::Throttle)
    }
    It 'classifies 401/token errors as Auth' {
        Get-SPOErrorClass -ErrorObject ([Exception]::new('401 Unauthorized: token expired')) |
            Should -Be ([SPOErrorClass]::Auth)
    }
    It 'classifies locked files as Locked' {
        Get-SPOErrorClass -ErrorObject ([Exception]::new('The file is locked for shared use')) |
            Should -Be ([SPOErrorClass]::Locked)
    }
    It 'classifies not-found as NotFound' {
        Get-SPOErrorClass -ErrorObject ([Exception]::new('File not found')) |
            Should -Be ([SPOErrorClass]::NotFound)
    }
    It 'classifies timeouts as Transient' {
        Get-SPOErrorClass -ErrorObject ([Exception]::new('The operation timed out')) |
            Should -Be ([SPOErrorClass]::Transient)
    }
    It 'extracts Retry-After seconds from a message' {
        Get-SPORetryAfterSeconds -ErrorObject ([Exception]::new('throttled, retry-after: 42')) | Should -Be 42
    }
    It 'backoff is bounded by the cap' {
        (Get-SPOBackoffSeconds -Attempt 10 -BaseSeconds 1 -CapSeconds 30) | Should -BeLessOrEqual 30
    }
}

Describe 'Invoke-SPOResilient' {
    It 'returns the value on first success' {
        $r = Invoke-SPOResilient -Action { 'ok' } -MaxRetries 3
        $r.Success | Should -BeTrue
        $r.Value | Should -Be 'ok'
    }
    It 'fails fast on auth without exhausting retries' {
        $script:calls = 0
        $r = Invoke-SPOResilient -MaxRetries 6 -Action {
            $script:calls++
            throw [Exception]::new('401 Unauthorized')
        }
        $r.Success | Should -BeFalse
        $r.ErrorClass | Should -Be ([SPOErrorClass]::Auth)
        $script:calls | Should -Be 1
    }
    It 'retries transient errors then succeeds' {
        $script:n = 0
        $r = Invoke-SPOResilient -MaxRetries 5 -BaseSeconds 0 -Action {
            $script:n++
            if ($script:n -lt 3) { throw [Exception]::new('timed out') }
            'done'
        }
        $r.Success | Should -BeTrue
        $script:n | Should -Be 3
    }
    It 'gives up after MaxRetries on persistent transient errors' {
        $r = Invoke-SPOResilient -MaxRetries 2 -BaseSeconds 0 -Action { throw [Exception]::new('connection reset') }
        $r.Success | Should -BeFalse
    }
}

Describe 'Rate limiter + throttle gate' {
    It 'rate limiter hands out a token immediately when full' {
        $lim = New-SPORateLimiter -RequestsPerSecond 5
        { Request-SPORateToken -Limiter $lim } | Should -Not -Throw
    }
    It 'global cooldown pushes CooldownUntil into the future' {
        $gate = New-SPOThrottleGate
        Set-SPOGlobalCooldown -Gate $gate -Seconds 2
        $gate.CooldownUntil | Should -BeGreaterThan ([DateTime]::UtcNow.Ticks)
        $gate.ThrottleCount | Should -Be 1
    }
}

Describe 'Path safety' {
    It 'accepts a clean path' {
        (Test-SPOPathSafety -RelativePath '/sites/A/Shared Documents/folder/file.docx').IsValid | Should -BeTrue
    }
    It 'rejects illegal characters' {
        (Test-SPOPathSafety -RelativePath '/sites/A/bad:name?.txt').IsValid | Should -BeFalse
    }
    It 'rejects reserved device names' {
        (Test-SPOLeafName -Leaf 'CON.txt').IsValid | Should -BeFalse
    }
    It 'rejects the Office lock prefix' {
        (Test-SPOLeafName -Leaf '~$budget.xlsx').IsValid | Should -BeFalse
    }
    It 'rejects trailing period and spaces' {
        (Test-SPOLeafName -Leaf 'report.').IsValid | Should -BeFalse
        (Test-SPOLeafName -Leaf ' report').IsValid | Should -BeFalse
    }
    It 'enforces the 128-char leaf limit' {
        (Test-SPOLeafName -Leaf ('a' * 129)).IsValid | Should -BeFalse
    }
    It 'enforces the 400-char path limit' {
        $long = '/sites/A/' + ('b' * 400)
        (Test-SPOPathSafety -RelativePath $long).IsValid | Should -BeFalse
    }
}

Describe 'Destination URL composition' {
    It 'preserves the sub-folder structure below the library root' {
        $dest = Get-SPODestinationUrl `
            -DestinationSiteUrl 'https://x.sharepoint.com/sites/Archive' `
            -DestinationLibrary 'Shared Documents' `
            -SourceServerRelativeUrl '/sites/A/Shared Documents/Templates/2026/plan.docx' `
            -SourceLibraryServerRelativeUrl '/sites/A/Shared Documents'
        $dest | Should -Be '/sites/Archive/Shared Documents/Templates/2026/plan.docx'
    }
    It 'does not drop the template folder (regression)' {
        $dest = Get-SPODestinationUrl `
            -DestinationSiteUrl 'https://x.sharepoint.com/sites/Archive' `
            -DestinationLibrary 'Docs' `
            -SourceServerRelativeUrl '/sites/A/Lib/Template/child/file.txt' `
            -SourceLibraryServerRelativeUrl '/sites/A/Lib'
        $dest | Should -Match 'Template/child/file.txt$'
    }
    It 'splits folder and leaf correctly' {
        $s = Split-SPODestinationUrl -ServerRelativeUrl '/sites/A/Docs/sub/f.txt'
        $s.Folder | Should -Be '/sites/A/Docs/sub'
        $s.Leaf   | Should -Be 'f.txt'
    }
}

Describe 'Ledger + resume' {
    BeforeAll {
        $script:ldir = Join-Path ([System.IO.Path]::GetTempPath()) ('spoled_' + [Guid]::NewGuid().ToString('N'))
    }
    AfterAll { Remove-Item -LiteralPath $ldir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'ledger key embeds last-modified so edits produce a new key' {
        $k1 = Get-SPOLedgerKey -SourceUrl '/sites/A/Docs/f.txt' -LastModified ([datetime]'2026-01-01Z')
        $k2 = Get-SPOLedgerKey -SourceUrl '/sites/A/Docs/f.txt' -LastModified ([datetime]'2026-02-01Z')
        $k1 | Should -Not -Be $k2
    }
    It 'records a success and rebuilds the completed set' {
        $path = Initialize-SPOLedger -Directory $ldir -WorkerId 'siteA'
        $key = Get-SPOLedgerKey -SourceUrl '/sites/A/Docs/f.txt' -LastModified ([datetime]'2026-01-01Z')
        Add-SPOLedgerEntry -LedgerPath $path -Key $key -SourceUrl '/sites/A/Docs/f.txt' `
            -DestUrl '/sites/B/Docs/f.txt' -LastModified ([datetime]'2026-01-01Z') `
            -SizeBytes 10 -Status 'Success' -Verdict Verified
        $set = Get-SPOCompletedKeys -Directory $ldir
        $set.Contains($key) | Should -BeTrue
    }
    It 'resume splits inventory into skip vs transfer' {
        $key = Get-SPOLedgerKey -SourceUrl '/sites/A/Docs/f.txt' -LastModified ([datetime]'2026-01-01Z')
        $completed = [System.Collections.Generic.HashSet[string]]::new()
        [void]$completed.Add($key)
        $inv = @(
            New-SPOInventoryItem -ServerRelativeUrl '/sites/A/Docs/f.txt' -LibraryServerRelativeUrl '/sites/A/Docs' -LastModified ([datetime]'2026-01-01Z')
            New-SPOInventoryItem -ServerRelativeUrl '/sites/A/Docs/g.txt' -LibraryServerRelativeUrl '/sites/A/Docs' -LastModified ([datetime]'2026-01-01Z')
        )
        $split = Split-SPOInventoryForResume -Inventory $inv -CompletedKeys $completed
        $split.Skipped.Count | Should -Be 1
        $split.ToTransfer.Count | Should -Be 1
        $split.ToTransfer[0].Name | Should -Be 'g.txt'
    }
    It 'a changed file (new mtime) is NOT skipped on resume' {
        $oldKey = Get-SPOLedgerKey -SourceUrl '/sites/A/Docs/f.txt' -LastModified ([datetime]'2026-01-01Z')
        $completed = [System.Collections.Generic.HashSet[string]]::new()
        [void]$completed.Add($oldKey)
        $inv = @(New-SPOInventoryItem -ServerRelativeUrl '/sites/A/Docs/f.txt' -LibraryServerRelativeUrl '/sites/A/Docs' -LastModified ([datetime]'2026-05-01Z'))
        $split = Split-SPOInventoryForResume -Inventory $inv -CompletedKeys $completed
        $split.ToTransfer.Count | Should -Be 1
    }
}

Describe 'Inventory + delta' {
    It 'delta predicate keeps items newer than cutoff' {
        Test-SPOItemInDelta -LastModified ([datetime]'2026-07-01') -Cutoff ([datetime]'2026-06-25') | Should -BeTrue
        Test-SPOItemInDelta -LastModified ([datetime]'2026-06-01') -Cutoff ([datetime]'2026-06-25') | Should -BeFalse
    }
    It 'library filter honours include/exclude globs' {
        $libs = Resolve-SPOLibraries -Available @('Documents', 'Brand Assets', 'Forms', 'OldStuff') `
            -Include 'Doc*;Brand*' -Exclude 'Forms'
        $libs | Should -Contain 'Documents'
        $libs | Should -Contain 'Brand Assets'
        $libs | Should -Not -Contain 'Forms'
        $libs | Should -Not -Contain 'OldStuff'
    }
    It 'inventory client-side filters delta via the fetcher double' {
        $raw = @(
            [pscustomobject]@{ ServerRelativeUrl = '/sites/A/Docs/new.txt'; Length = 5; LastModified = [datetime]'2026-07-10'; Name = 'new.txt' }
            [pscustomobject]@{ ServerRelativeUrl = '/sites/A/Docs/old.txt'; Length = 5; LastModified = [datetime]'2026-05-10'; Name = 'old.txt' }
        )
        $inv = Get-SPOInventory -LibraryServerRelativeUrl '/sites/A/Docs' -Mode Delta `
            -DeltaCutoff ([datetime]'2026-06-25') -Fetcher { param($ps) $raw }
        $inv.Count | Should -Be 1
        $inv[0].Name | Should -Be 'new.txt'
    }
}

Describe 'Transfer verification' {
    It 'size match yields Verified' {
        (Compare-SPOTransfer -SourceSize 100 -DestSize 100).Verdict | Should -Be ([SPOItemVerdict]::Verified)
    }
    It 'size mismatch yields Attention' {
        (Compare-SPOTransfer -SourceSize 100 -DestSize 90).Verdict | Should -Be ([SPOItemVerdict]::Attention)
    }
    It 'hash mismatch yields Attention when hashing is on' {
        (Compare-SPOTransfer -SourceSize 100 -DestSize 100 -SourceHash 'AAA' -DestHash 'BBB' -VerifyHash $true).Verdict |
            Should -Be ([SPOItemVerdict]::Attention)
    }
}

Describe 'Engine end-to-end (in-memory provider)' {
    BeforeAll {
        # A fully in-memory SharePoint double.
        $script:store = @{
            '/sites/A/Shared Documents' = @(
                [pscustomobject]@{ ServerRelativeUrl = '/sites/A/Shared Documents/a.txt'; Length = 3;  LastModified = [datetime]'2026-07-01'; Name = 'a.txt' }
                [pscustomobject]@{ ServerRelativeUrl = '/sites/A/Shared Documents/sub/b.txt'; Length = 7; LastModified = [datetime]'2026-07-02'; Name = 'b.txt' }
            )
        }
        $script:uploaded = @{}
        $script:provider = @{
            Connect       = { param($t) [pscustomobject]@{ Site = $t.SourceSiteUrl } }
            Disconnect    = { param($c) }
            ListLibraries = { param($c) @('Shared Documents') }
            LibraryRoot   = { param($c, $lib) '/sites/A/Shared Documents' }
            Enumerate     = { param($c, $lib, $ps) $script:store['/sites/A/Shared Documents'] }
            Download      = { param($c, $src, $lp)
                $item = $script:store['/sites/A/Shared Documents'] | Where-Object { $_.ServerRelativeUrl -eq $src }
                Set-Content -LiteralPath $lp -Value ('x' * [int]$item.Length) -NoNewline
            }
            EnsureFolder  = { param($c, $fu) }
            Upload        = { param($c, $lp, $fu, $leaf)
                $script:uploaded["$fu/$leaf"] = (Get-Item -LiteralPath $lp).Length
            }
            DestSize      = { param($c, $du) [long]$script:uploaded[$du] }
        }
        $script:cfg = Import-SPOMigrationConfigInternal -SettingsPath 'none' -DotEnvPath 'none' -EnvTable @{} -CliOverrides @{
            DestinationSiteUrl = 'https://x.sharepoint.com/sites/B'
            DestinationLibrary = 'Shared Documents'
            ClientId = 'id'; TenantId = 'tid'; Thumbprint = 'tp'
            SiteThrottle = 2; FileThrottle = 2
        }
        $script:sites = @([pscustomobject]@{ SiteUrl = '/sites/A' })
        $script:ldir = Join-Path ([System.IO.Path]::GetTempPath()) ('spoeng_' + [Guid]::NewGuid().ToString('N'))
    }
    AfterAll { Remove-Item -LiteralPath $ldir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Plan mode writes nothing but plans all files' {
        $r = Invoke-SPOMigrationEngine -Config $cfg -Sites $sites -Mode Plan -Provider $provider -LedgerDirectory $ldir
        $r.Progress.FilesTotal | Should -Be 2
        $r.Progress.FilesDone | Should -Be 0
        $script:uploaded.Count | Should -Be 0
    }

    It 'Full mode transfers and verifies every file' {
        $script:uploaded = @{}
        $r = Invoke-SPOMigrationEngine -Config $cfg -Sites $sites -Mode Full -Provider $provider -LedgerDirectory $ldir
        $r.Progress.FilesDone | Should -Be 2
        $r.Progress.FilesFailed | Should -Be 0
        $script:uploaded.Count | Should -Be 2
        $script:uploaded['/sites/B/Shared Documents/sub/b.txt'] | Should -Be 7
    }

    It 'Resume skips the files already recorded as Success' {
        $r = Invoke-SPOMigrationEngine -Config $cfg -Sites $sites -Mode Full -Provider $provider -LedgerDirectory $ldir -Resume
        $r.Progress.FilesSkipped | Should -BeGreaterOrEqual 2
    }
}

Describe 'Report generation' {
    It 'produces a self-contained HTML file with a verdict stamp' {
        $cfg = Import-SPOMigrationConfigInternal -SettingsPath 'none' -DotEnvPath 'none' -EnvTable @{} -CliOverrides @{ Thumbprint = 'SECRET123456' }
        $progress = New-SPOProgressState -TotalSites 1
        $progress.FilesTotal = 2; $progress.FilesDone = 2
        $engine = [pscustomobject]@{ Mode = 'Full'; Progress = $progress; Sites = @(); ThrottleEvents = 0 }
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('rep_' + [Guid]::NewGuid().ToString('N') + '.html')
        New-SPOHtmlReport -EngineResult $engine -Config $cfg -Path $out | Out-Null
        $html = Get-Content -LiteralPath $out -Raw
        $html | Should -Match 'VERIFIED'
        $html | Should -Not -Match 'SECRET123456'   # secret must be redacted
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}
