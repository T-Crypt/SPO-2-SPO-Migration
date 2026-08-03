#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    90-Report.ps1
    Self-contained HTML report — blueprint-blue on cool paper, IBM Plex, with a
    per-site "transfer tape" band and an inspection-stamp verdict
    (VERIFIED / ATTENTION / STOPPED). No external assets: all CSS inline, fonts
    fall back gracefully. Config is redacted before it ever reaches the page.
#>

function ConvertTo-SPOReportModel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $EngineResult,
        [Parameter(Mandatory)][pscustomobject] $Config
    )

    $p = $EngineResult.Progress
    $verdict = if ($p.FilesFailed -eq 0 -and $p.FilesDone -gt 0) {
        'VERIFIED'
    }
    elseif ($p.FilesDone -eq 0 -and $p.FilesTotal -eq 0) {
        'VERIFIED'
    }
    elseif ($p.FilesFailed -gt 0 -and $p.FilesDone -gt 0) {
        'ATTENTION'
    }
    else {
        'STOPPED'
    }

    [pscustomobject]@{
        Verdict        = $verdict
        Mode           = [string]$EngineResult.Mode
        GeneratedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
        FilesTotal     = $p.FilesTotal
        FilesDone      = $p.FilesDone
        FilesFailed    = $p.FilesFailed
        FilesSkipped   = $p.FilesSkipped
        BytesMoved     = $p.BytesMoved
        ThrottleEvents = $p.ThrottleEvents
        RedactedConfig = (Get-SPORedactedConfig -Config $Config)
        Sites          = $EngineResult.Sites
        Progress       = $p
    }
}

function ConvertTo-SPOHtmlEncoded {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-SPOHtmlReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $EngineResult,
        [Parameter(Mandatory)][pscustomobject] $Config,
        [Parameter(Mandatory)][string] $Path
    )

    $m = ConvertTo-SPOReportModel -EngineResult $EngineResult -Config $Config

    $stampClass = switch ($m.Verdict) {
        'VERIFIED'  { 'stamp-verified' }
        'ATTENTION' { 'stamp-attention' }
        default     { 'stamp-stopped' }
    }

    # per-site rows
    $siteRows = [System.Text.StringBuilder]::new()
    [System.Threading.Monitor]::Enter($m.Progress.Sync)
    try {
        foreach ($entry in $m.Progress.Sites.GetEnumerator()) {
            $name = ConvertTo-SPOHtmlEncoded ([string]$entry.Key)
            $s = $entry.Value
            $total = [math]::Max(1, $s.Total)
            $pctDone = [int](100 * ($s.Done / $total))
            $pctSkip = [int](100 * ($s.Skipped / $total))
            $pctFail = [int](100 * ($s.Failed / $total))
            $siteBlock = @"
      <div class="site">
        <div class="site-head"><span class="site-name">$name</span>
          <span class="site-stat">$($s.Done) moved · $($s.Skipped) skipped · $($s.Failed) attention · $(Format-SPOBytes $s.Bytes)</span></div>
        <div class="tape">
          <div class="tape-done" style="width:$pctDone%"></div>
          <div class="tape-skip" style="width:$pctSkip%"></div>
          <div class="tape-fail" style="width:$pctFail%"></div>
        </div>
      </div>
"@
            [void]$siteRows.AppendLine($siteBlock)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($m.Progress.Sync)
    }

    # redacted config rows
    $cfgRows = [System.Text.StringBuilder]::new()
    foreach ($prop in $m.RedactedConfig.PSObject.Properties) {
        $k = ConvertTo-SPOHtmlEncoded $prop.Name
        $v = ConvertTo-SPOHtmlEncoded ([string]$prop.Value)
        [void]$cfgRows.AppendLine("        <tr><td>$k</td><td>$v</td></tr>")
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SPOMigrate Report — $($m.Verdict)</title>
<style>
  :root {
    --ink:#0b3d91; --ink-soft:#4166a8; --paper:#eef3fb; --line:#c3d2ec;
    --done:#2f6fed; --skip:#9db8e6; --fail:#e0603a; --stamp:#0b3d91;
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--paper); color:var(--ink);
    font-family:'IBM Plex Sans','Segoe UI',system-ui,sans-serif; }
  .wrap { max-width:960px; margin:0 auto; padding:32px 24px 64px; }
  header { display:flex; justify-content:space-between; align-items:flex-start;
    border-bottom:2px solid var(--ink); padding-bottom:16px; }
  h1 { font-family:'IBM Plex Mono',ui-monospace,monospace; font-size:22px;
    letter-spacing:.5px; margin:0; }
  .sub { color:var(--ink-soft); font-size:13px; margin-top:4px; }
  .stamp { border:3px solid var(--stamp); border-radius:8px; padding:8px 14px;
    font-family:'IBM Plex Mono',monospace; font-weight:700; letter-spacing:2px;
    transform:rotate(-6deg); font-size:18px; }
  .stamp-verified { color:#0b7a3b; border-color:#0b7a3b; }
  .stamp-attention { color:#b8560f; border-color:#b8560f; }
  .stamp-stopped { color:#a01b1b; border-color:#a01b1b; }
  .cards { display:grid; grid-template-columns:repeat(5,1fr); gap:12px; margin:24px 0; }
  .card { background:#fff; border:1px solid var(--line); border-radius:8px;
    padding:14px; text-align:center; }
  .card .n { font-family:'IBM Plex Mono',monospace; font-size:24px; }
  .card .l { font-size:11px; text-transform:uppercase; letter-spacing:1px; color:var(--ink-soft); }
  h2 { font-family:'IBM Plex Mono',monospace; font-size:15px; letter-spacing:1px;
    border-left:4px solid var(--ink); padding-left:10px; margin-top:32px; }
  .site { background:#fff; border:1px solid var(--line); border-radius:8px;
    padding:12px 14px; margin-bottom:10px; }
  .site-head { display:flex; justify-content:space-between; font-size:13px; margin-bottom:8px; }
  .site-name { font-family:'IBM Plex Mono',monospace; }
  .site-stat { color:var(--ink-soft); }
  .tape { display:flex; height:14px; border-radius:4px; overflow:hidden;
    background:repeating-linear-gradient(90deg,#dbe6f7,#dbe6f7 6px,#e7effb 6px,#e7effb 12px); }
  .tape-done { background:var(--done); }
  .tape-skip { background:var(--skip); }
  .tape-fail { background:var(--fail); }
  table { width:100%; border-collapse:collapse; background:#fff;
    border:1px solid var(--line); border-radius:8px; overflow:hidden; font-size:13px; }
  td { padding:7px 12px; border-bottom:1px solid var(--line); }
  td:first-child { font-family:'IBM Plex Mono',monospace; color:var(--ink-soft); width:38%; }
  footer { margin-top:40px; font-size:11px; color:var(--ink-soft); text-align:center; }
</style>
</head>
<body>
  <div class="wrap">
    <header>
      <div>
        <h1>SPOMigrate</h1>
        <div class="sub">Mode: $($m.Mode) &nbsp;·&nbsp; Generated $($m.GeneratedUtc)</div>
      </div>
      <div class="stamp $stampClass">$($m.Verdict)</div>
    </header>

    <div class="cards">
      <div class="card"><div class="n">$($m.FilesTotal)</div><div class="l">Planned</div></div>
      <div class="card"><div class="n">$($m.FilesDone)</div><div class="l">Moved</div></div>
      <div class="card"><div class="n">$($m.FilesSkipped)</div><div class="l">Skipped</div></div>
      <div class="card"><div class="n">$($m.FilesFailed)</div><div class="l">Attention</div></div>
      <div class="card"><div class="n">$(Format-SPOBytes $m.BytesMoved)</div><div class="l">Transferred</div></div>
    </div>

    <h2>PER-SITE TRANSFER TAPE</h2>
$($siteRows.ToString())

    <h2>RUN CONFIGURATION (REDACTED)</h2>
    <table>
$($cfgRows.ToString())
    </table>

    <footer>Throttle cooldown events: $($m.ThrottleEvents) &nbsp;·&nbsp; SPOMigrate self-contained report — no external assets, secrets redacted.</footer>
  </div>
</body>
</html>
"@

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $html -Encoding utf8
    Write-SPOLogInfo "HTML report written to $Path (verdict=$($m.Verdict))"
    $Path
}
