# Changelog

All notable changes to SPOMigrate are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versioning is
[SemVer](https://semver.org/).

## [1.0.0] - 2026-08-03

### Added
- First release: SPOMigrate PowerShell 7 module + `migration.ps1` CLI.
- Six public cmdlets: `Start-SPOMigration`, `Show-SPOMigrationWizard`,
  `Test-SPOMigrationEnvironment`, `Get-SPOMigrationStatus`,
  `New-SPOMigrationReport`, `Import-SPOMigrationConfig`.
- Layered configuration (`settings.psd1` -> `.env` -> `SPO_*` env -> CLI) with
  secret redaction.
- Four modes: **Plan**, **Full**, **Delta**, **Verify**.
- Resumable, append-only per-worker CSV ledger keyed on source URL +
  last-modified; changed files are re-copied.
- `Invoke-SPOResilient`: error classification, `Retry-After` handling, global
  throttle cooldown, tenant-wide RPS ceiling, fail-fast auth.
- Pre-download path safety (illegal chars, reserved names, 400/128 limits).
- Verified transfers (size, optional SHA-256); mismatches re-copied not skipped.
- Delta via paged enumeration + client-side filter (avoids the 5,000-item CAML
  threshold failure).
- Multi-library per site with include/exclude filters and per-site destination
  overrides in `sites.csv`.
- Live console dashboard and self-contained HTML report.
- Cross-platform certificate tool (no `New-SelfSignedCertificate`).
- ~40 tenant-free Pester tests and a Linux+Windows CI pipeline with parse-check,
  PSScriptAnalyzer, and a committed-secret scan.

### Changed from the original `CCAF-Migrate-Sites` script
- Single script -> structured module.
- `$DeltaSync` boolean -> four explicit modes.
- `Copy-PnPFile` (broken cross-site) -> `Get-PnPFile` stream + `Add-PnPFile`.
- Main-thread site scheduler replaces nested job waits (deadlock fix).
