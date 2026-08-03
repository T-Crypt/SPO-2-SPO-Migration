# Troubleshooting

Symptom-first guide. For most issues, start with:

```powershell
./migration.ps1 -Preflight      # environment + config sanity
./migration.ps1 -Status         # what the ledger says happened
```

---

## Authentication

**`AADSTS700027` / "client assertion contains an invalid signature"**
The certificate PnP is using doesn't match the `.cer` uploaded to Entra.
- Confirm `SPO_CERT_THUMBPRINT` matches the thumbprint the cert tool printed.
- On Windows, ensure the `.pfx` is imported into `Cert:\CurrentUser\My`.

**`401 Unauthorized` immediately, every item**
SPOMigrate **fails fast** on auth by design (it won't burn retries on a dead
token). Check:
- admin consent was granted for `Sites.FullControl.All`;
- the certificate hasn't expired;
- tenant/client IDs are correct (`./migration.ps1 -Preflight`).

---

## Throttling

**Lots of `throttled; global cooldown` warnings**
Expected under load — the tool honours `Retry-After` and cools *all* workers
together. If it's constant:
- lower `SPO_SITE_THROTTLE` (try 3) and `SPO_FILE_THROTTLE` (try 4);
- lower `SPO_RPS` (try 15);
- run large jobs outside business hours.

The HTML report footer shows the total cooldown-event count for a run.

---

## Uploads failing

**`Add-PnPFile` rejects uploads above ~6 concurrent**
That's a SPO limit, not a bug. Keep `SPO_FILE_THROTTLE` ≤ 6.

**Files reported as `Attention` (size mismatch)**
Verification caught a partial/failed upload. These are **not** marked Success,
so a normal `-Resume` re-copies them. If they persist, enable hash verification
to rule out corruption:

```dotenv
SPO_VERIFY_HASH=true
```

**Path/name rejected before download**
The path safety check blocked an illegal SharePoint name (illegal chars,
reserved device name like `CON`, `~$` lock prefix, trailing period/space, or a
segment > 128 / path > 400 chars). Rename at the source, then re-run.

---

## Delta

**Delta missed recently-changed files, or errored on large lists**
SPOMigrate deliberately avoids CAML-on-`Modified` (which fails past the 5,000-item
list view threshold) and instead pages the whole list and filters client-side.
Make sure `SPO_DELTA_CUTOFF` is set and parseable, e.g.:

```dotenv
SPO_DELTA_CUTOFF=2026-06-25 00:00:00
```

Items with no/invalid modified date are treated as **in delta** (safer to
recopy).

---

## Resume

**Resume re-copied files I thought were done**
The ledger key includes last-modified. If the source file changed, its key
changed, so it's intentionally re-copied. If files are re-copied without changing,
check that all workers wrote to the same ledger directory
(`<LogDirectory>/ledger`).

**Resume skipped a file that failed verification**
It shouldn't — only `Success` rows populate the completed set. Confirm with
`./migration.ps1 -Status`; `Attention`/`Failed` items are never skipped.

---

## Dashboard / console

**Garbled output or no dashboard**
The live dashboard needs an interactive host. In CI or when output is redirected
it falls back to compact status lines automatically. Force plain output with:

```powershell
$env:SPO_NO_UI = '1'
```

---

## Getting more detail

Raise log verbosity by editing the `Initialize-SPOLog -MinLevel` call, or inspect
the per-run log in `logs/SPOMigrate_<timestamp>.log` and the per-worker ledgers in
`logs/ledger/ledger_*.csv`.
