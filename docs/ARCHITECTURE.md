# Architecture

SPOMigrate is a PowerShell 7 **module** (not a single script). The public
surface is six cmdlets; everything else is a small, individually testable
private helper. This document explains how the pieces fit and why the tricky
decisions were made the way they were.

---

## Layout

```
migration.ps1                     CLI front-end (verbs -> module cmdlets)
src/SPOMigrate/
  SPOMigrate.psd1 / .psm1          manifest + loader (dot-source, export Public)
  Public/                         6 exported cmdlets
  Private/                        ordered helpers 00..90
config/  settings.psd1, sites.sample.csv
tools/   New-MigrationCertificate.ps1
tests/   SPOMigrate.Tests.ps1     ~40 tenant-free Pester tests
docs/    ENTRA-SETUP, ARCHITECTURE, TROUBLESHOOTING
```

The private files are numbered so the loader dot-sources them in dependency
order:

| File | Responsibility |
|------|----------------|
| `00-Common`     | enums, result type, URL + byte/duration helpers |
| `05-Logging`    | mutex-serialised structured logging, console toggle |
| `10-Config`     | layered config, typed coercion, redaction |
| `20-Resilience` | error classification, backoff, throttle gate, RPS bucket, `Invoke-SPOResilient` |
| `30-Connection` | per-site isolated PnP connections, target resolution |
| `40-Paths`      | leaf/path safety, destination URL composition |
| `50-Inventory`  | paged enumeration, client-side delta, library filtering |
| `60-Ledger`     | append-only CSV ledger, resume set rebuild |
| `70-Transfer`   | single-file stream copy + verification |
| `80-Engine`     | main-thread scheduler + per-site processor + progress |
| `85-UI`         | live console dashboard |
| `90-Report`     | self-contained HTML report |

---

## Configuration precedence

```
settings.psd1  ->  .env  ->  SPO_* env vars  ->  CLI parameters
   (lowest)                                        (highest)
```

`Import-SPOMigrationConfigInternal` implements this as four ordered overlays on
a schema (`$script:SPOConfigSchema`) that is the single source of truth for keys,
types and env-var names. `Get-SPORedactedConfig` masks anything whose key is in
`$script:SPOSecretKeys` so secrets never reach logs or the report.

---

## Modes

Instead of the original `$DeltaSync` boolean there are four explicit modes:

- **Plan** — dry-run. Enumerates and reports intended work; writes nothing.
- **Full** — copy everything.
- **Delta** — copy only items whose `Modified` is after `DeltaCutoff`.
- **Verify** — re-check sizes/hashes of already-copied items.

---

## Resumability

Every transfer attempt is appended to a **per-worker** CSV ledger. The key is:

```
<source server-relative URL> | <last-modified, ISO-8601 UTC>
```

Because the key embeds last-modified, an edited source file gets a **new** key
and is therefore re-copied on the next run rather than being treated as done.
`-Resume` rebuilds the set of keys with at least one `Success` row and skips only
those, retrying everything else. Per-worker files mean no cross-thread writes and
therefore no write lock on the hot path.

---

## Concurrency & the deadlock fix

Two levels of parallelism:

- **Sites** (outer) bounded by `SiteThrottle` (keep 4–6).
- **Files per site** (inner) bounded by `FileThrottle` (≤6; SPO rejects uploads
  above that).

The critical fix vs. the original: **site slots are handed out by a main-thread
scheduler**, never awaited from inside a job. Nested `Start-ThreadJob` calls
share a default `ThrottleLimit` of 5; if a site job blocked waiting for a child
slot while itself occupying one, file workers could starve and the run would
deadlock. The scheduler in `80-Engine` keeps slot accounting on the main thread,
so a running site never blocks on a sibling.

---

## Resilience

`Invoke-SPOResilient` wraps **every** API call and:

1. classifies the error — Throttle / Transient / Locked / Auth / NotFound / Fatal;
2. honours `Retry-After` when present, else uses exponential backoff with full
   jitter, capped;
3. on throttling, sets a **global cooldown** so *all* workers park together
   (backing off one worker while others keep hammering just prolongs the 429s);
4. enforces a tenant-wide **requests-per-second** ceiling via a shared token
   bucket;
5. **fails fast on Auth** — retrying a dead token only burns the retry budget.

---

## Transfer & verification

Cross-site copy uses **`Get-PnPFile` (stream) + `Add-PnPFile`**, never
`Copy-PnPFile` (broken across site collections). Bytes are streamed to a local
temp buffer, so large files don't sit entirely in memory. **Path safety is
checked before download.** After upload, destination size is compared (and
SHA-256 if enabled); a mismatch yields an `Attention` verdict and is **not**
recorded as `Success`, so it is re-copied next run instead of silently skipped.

---

## Testability

The engine talks to SharePoint only through a `$Provider` hashtable of
scriptblocks. Tests inject an in-memory provider, so the entire Plan → Full →
Resume → Report flow runs with no tenant, no network and no PnP module. The live
provider (`New-SPOLivePnPProvider`) is the single place PnP cmdlets appear.
