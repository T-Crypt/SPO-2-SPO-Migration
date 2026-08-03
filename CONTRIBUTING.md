# Contributing to SPOMigrate

Thanks for helping improve the tool. A few conventions keep the module coherent
and the test suite meaningful.

## Ground rules
- **Target PowerShell 7+.** No Windows-only cmdlets on the hot path
  (`New-SelfSignedCertificate`, WMI, etc.).
- **Keep PnP at the edge.** Only `New-SPOLivePnPProvider` may call PnP cmdlets.
  Everything else takes a `$Provider` / scriptblock so it stays tenant-free and
  testable.
- **Secrets never leak.** Anything sensitive must route through
  `Get-SPORedactedConfig` before logs or reports. Add new secret keys to
  `$script:SPOSecretKeys`.

## Project layout
Private helpers are numbered (`00`..`90`) and dot-sourced in that order. Put new
helpers in the file that matches their responsibility, or add a new numbered file
if it's a new concern. Public cmdlets live one-per-file under `Public/` and must
be added to both the `.psd1` manifest and `.psm1` export list.

## Before you push
```powershell
# parse-check
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object {
  $e=$null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e) | Out-Null
  if ($e){ $e | ForEach-Object { Write-Warning "$($_.Extent.File): $($_.Message)" } }
}

Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

$env:SPO_NO_UI='1'; Invoke-Pester ./tests
```

All three must be clean. CI runs the same on Linux and Windows.

## Style
- 4-space indentation, open brace on the same line.
- Comment-based help on every public cmdlet.
- New behaviour needs a test. Prefer testing a small pure helper over the whole
  engine where possible.
