# SPOMigrate

**Resumable, verified, throttle-aware SharePoint-to-SharePoint migration** for
PowerShell 7. Built by Xceptional from a single migration script into a proper,
tested module with a CLI, a live dashboard, and a self-contained HTML report.

---

## Why

The original script did the job but was a single file with hard-coded config, a
`$DeltaSync` boolean, `Copy-PnPFile` (which is broken across site collections),
and nested thread jobs that could deadlock. SPOMigrate keeps the good ideas —
parallel sites, parallel files, per-site audit — and hardens everything around
them.

## Highlights

- **Four modes:** `Plan` (dry-run), `Full`, `Delta`, `Verify`.
- **Resumable:** every attempt is journalled to a per-worker CSV ledger keyed on
  *source URL + last-modified*. `-Resume` retries only failures; changed files
  are re-copied, not skipped.
- **Throttle-aware:** `Invoke-SPOResilient` classifies errors, honours
  `Retry-After`, cools **all** workers together on 429s, enforces a tenant-wide
  requests/sec ceiling, and fails fast on auth.
- **Safe by construction:** path/name validation *before* download; verified
  transfers (size + optional SHA-256) so a bad copy is retried, never silently
  skipped.
- **No deadlocks:** a main-thread scheduler hands out site slots instead of
  waiting for them inside jobs.
- **Secrets stay secret:** layered config with redaction; `.env` and certs are
  git-ignored.
- **Cross-platform:** the certificate tool avoids `New-SelfSignedCertificate`.
- **Tested:** ~40 tenant-free Pester tests + Linux/Windows CI.

---

## Requirements

- PowerShell **7.0+**
- [`PnP.PowerShell`](https://pnp.github.io/powershell/) (for live runs)
- An Entra app registration with a certificate — see
  [`docs/ENTRA-SETUP.md`](docs/ENTRA-SETUP.md)

---

## Quick start

```powershell
# 1. Create a cert and register the Entra app (see docs/ENTRA-SETUP.md)
./tools/New-MigrationCertificate.ps1 -Subject 'SPOMigrate' -OutputDirectory ./certs

# 2. Configure interactively (writes .env)
./migration.ps1 -Setup

# 3. Copy the sample site list and edit it
Copy-Item config/sites.sample.csv config/sites.csv

# 4. Validate the environment
./migration.ps1 -Preflight

# 5. Dry-run to see exactly what would move
./migration.ps1 -Mode Plan

# 6. Migrate, with the live dashboard, resumable
./migration.ps1 -Mode Full -Resume -Dashboard
```

Then open the HTML report printed at the end of the run, or regenerate one:

```powershell
./migration.ps1 -Report      # rebuild a report from the ledger
./migration.ps1 -Status      # quick counts from the ledger
```

---

## CLI verbs

| Verb | Meaning |
|------|---------|
| `-Setup` | interactive wizard, writes `.env`, exits |
| `-Preflight` | validate environment + config, exits |
| `-Mode Plan\|Full\|Delta\|Verify` | run mode (default `Plan`) |
| `-Resume` | skip items already recorded as succeeded |
| `-Dashboard` | live console dashboard during the run |
| `-Report` | regenerate the HTML report from the ledger, exits |
| `-Status` | print a ledger summary, exits |

---

## The site list (`config/sites.csv`)

| Column | Required | Purpose |
|--------|----------|---------|
| `SiteUrl` | yes | source site collection URL |
| `DestinationSiteUrl` | no | per-site destination override |
| `DestinationLibrary` | no | per-site destination library override |
| `IncludeLibraries` | no | `;`-separated globs to include |
| `ExcludeLibraries` | no | `;`-separated globs to exclude |

See [`config/sites.sample.csv`](config/sites.sample.csv).

---

## Configuration precedence

```
config/settings.psd1  ->  .env  ->  SPO_* env vars  ->  CLI parameters
```

Full key reference lives in [`.env.example`](.env.example). Secrets are redacted
everywhere via `Get-SPORedactedConfig`.

---

## Public cmdlets

```powershell
Import-Module ./src/SPOMigrate/SPOMigrate.psd1

Start-SPOMigration            # run a migration
Show-SPOMigrationWizard       # write .env interactively
Test-SPOMigrationEnvironment  # preflight checks
Get-SPOMigrationStatus        # ledger summary
New-SPOMigrationReport        # HTML report
Import-SPOMigrationConfig     # build the merged config object
```

---

## Development

```powershell
$env:SPO_NO_UI = '1'
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Architecture and design rationale: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
Common issues: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

---

## License

MIT © Xceptional. See [`LICENSE`](LICENSE).
