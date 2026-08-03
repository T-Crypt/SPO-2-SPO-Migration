# Validation Report

This document records exactly what was validated when SPOMigrate was finished,
and — importantly — what was **not** possible to run in the build environment.

## Environment limitation (please read)

The finishing pass was executed in a sandbox whose outbound network is
restricted to PyPI only. `pwsh` could not be installed: GitHub releases,
`aka.ms`, `packages.microsoft.com`, and the npm registry all return HTTP 403,
`tdnf` has no PowerShell package and no root/`sudo`, and there is no .NET SDK.

**Consequently, `[Parser]::ParseFile`, PSScriptAnalyzer, and the Pester suite
could NOT be executed here.** They are wired into CI (`.github/workflows/ci.yml`)
and will run on Linux + Windows on first push. Until then, the checks below are
what was actually performed locally.

## What WAS validated locally

A PowerShell-aware structural validator (`ps_validate.py`, tokeniser that
understands `#`/`<# #>` comments, single/double quotes, `` ` `` escapes,
`$(...)` subexpressions, and `@"…"@` / `@'…'@` here-strings) was run across all
25 `.ps1`/`.psm1`/`.psd1` files:

- **Brace / paren / bracket balance:** 0 issues across 25 files.
- **String & here-string termination:** 0 unterminated literals.
- **Here-string terminators at column 0:** verified (none indented).
- **Backtick line-continuations with trailing whitespace:** none.
- **Cross-reference:** every internal `*-SPO*` function that is *called* is also
  *defined* (71 definitions; the only unresolved name was a stale doc-comment
  reference, since corrected).

## PS-specific issues fixed by hand during the finish

These are the classes of error a parse-check would surface; each was found and
corrected by inspection:

1. **Stray bare expression** — a leftover `$lib` statement in
   `Invoke-SPOSiteProcessor` was removed.
2. **Inline `if` in an argument position** — replaced with an assigned
   intermediate variable in `Test-SPOMigrationEnvironment`; a `$(if …)` in
   `Get-SPOInventory` was hoisted to a named variable for clarity.
3. **Scriptblock closure correctness** — the live PnP provider's scriptblocks
   reference `$Config`; because the factory returns them and exits, each is now
   materialised with `.GetNewClosure()` so `$Config` is captured rather than
   relying on dynamic scope.
4. **Dashboard scope safety** — replaced the `Register-ObjectEvent`
   timer (whose action block cannot see module-private render functions) with a
   throttled in-module repaint driven from `Update-SPOProgress`.
5. **Here-string closed by `"@)`** — refactored to assign the here-string to a
   variable first, then append, avoiding trailing-token-after-terminator
   ambiguity.

## What still needs a real `pwsh` run (do this on checkout)

```powershell
# 1. Parse-check
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object {
  $e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e) | Out-Null
  if ($e) { $e | ForEach-Object { Write-Warning "$($_.Extent.File):$($_.Extent.StartLineNumber) $($_.Message)" } }
}

# 2. Analyzer
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# 3. Tests (tenant-free, no PnP needed)
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
$env:SPO_NO_UI = '1'
Invoke-Pester ./tests
```

CI runs all three automatically. If the parse-check or analyzer flags anything,
it will be a small, localized fix — the module is structurally sound and the
call graph is internally consistent.

## Suite scope

- **12** `Describe` groups, **50** `It` assertions.
- Fully tenant-free: the engine talks to SharePoint only through an injectable
  `$Provider` of scriptblocks, and the tests supply an in-memory double for the
  Plan → Full → Resume → Report path.
