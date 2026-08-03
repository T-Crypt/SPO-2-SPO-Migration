# Entra (Azure AD) App-Only Setup

SPOMigrate authenticates as an **app-only** identity using a certificate, so it
can run unattended across many site collections without a signed-in user. This
guide walks through creating the app registration, granting SharePoint
permissions, and generating the certificate.

---

## 1. Create the certificate

Run the cross-platform helper (works on Windows, macOS, Linux — no
`New-SelfSignedCertificate` required):

```powershell
./tools/New-MigrationCertificate.ps1 -Subject 'SPOMigrate' -OutputDirectory ./certs
```

It writes:

| File | Purpose | Handling |
|------|---------|----------|
| `SPOMigrate_<date>.pfx` | private key | **secret** — never commit |
| `SPOMigrate_<date>.cer` | public key | upload to Entra |

and prints the **thumbprint**. Keep it — you'll paste it into `.env`.

> On Windows, import the `.pfx` into `Cert:\CurrentUser\My` so PnP can locate it
> by thumbprint. On Linux/macOS, PnP uses the `.pfx` path + password directly.

---

## 2. Register the application

1. **Entra admin center → App registrations → New registration.**
2. Name it `SPOMigrate`. Single tenant is fine.
3. No redirect URI is needed for certificate app-only auth.
4. Note the **Application (client) ID** and **Directory (tenant) ID**.

---

## 3. Upload the certificate

1. Open the app → **Certificates & secrets → Certificates → Upload certificate.**
2. Upload the `.cer` produced in step 1.
3. Confirm the thumbprint matches what the script printed.

---

## 4. Grant SharePoint permissions

SPOMigrate reads from source sites and writes to the destination, so it needs
tenant-wide SharePoint access.

1. App → **API permissions → Add a permission → SharePoint → Application
   permissions.**
2. Add **`Sites.FullControl.All`** (required to create folders and upload to
   arbitrary libraries).
   - If your governance forbids `FullControl`, `Sites.ReadWrite.All` works for
     content but may fail on some folder-provisioning calls.
3. Click **Grant admin consent**.

---

## 5. Wire it into SPOMigrate

Either run the wizard:

```powershell
./migration.ps1 -Setup
```

or edit `.env` directly:

```dotenv
SPO_TENANT_ID=contoso.onmicrosoft.com
SPO_CLIENT_ID=<application-client-id>
SPO_CERT_THUMBPRINT=<thumbprint>
SPO_DEST_SITE_URL=https://contoso.sharepoint.com/sites/Archive
```

Then validate:

```powershell
./migration.ps1 -Preflight
```

All checks should read **PASS** before you run a real migration.

---

## Security notes

- `.env`, `*.pfx`, `*.cer`, and `*.key` are git-ignored by default.
- SPOMigrate redacts the thumbprint and any secret before it reaches logs or the
  HTML report (`Get-SPORedactedConfig`).
- Rotate the certificate before expiry; re-run the cert tool and re-upload the
  new `.cer`.
