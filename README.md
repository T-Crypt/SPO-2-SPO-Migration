# SPO-2-SPO Migration Tool

## Overview
The **SPO-2-SPO Migration Tool** is a high-performance, enterprise-grade PowerShell 7 automation script designed to consolidate and migrate Microsoft 365 SharePoint Online (SPO) and Teams-connected sites into a single, unified SharePoint destination. 

Built using the `PnP.PowerShell` module, this tool bypasses traditional SharePoint API bottlenecks by utilizing multi-threaded parallel processing for both sites and individual files. It features built-in Delta Sync capabilities, strict folder hierarchy preservation, and robust error-handling to prevent partial transfers and duplicate files.

## Key Features
* **App-Only Authentication:** Uses an Entra ID (Azure AD) App Registration with certificate-based authentication for uninterrupted, headless execution.
* **Double-Parallelism:** Utilizes PowerShell 7 Runspaces (`ForEach-Object -Parallel` and `Start-ThreadJob`) to process multiple sites and multiple files simultaneously.
* **Folder Hierarchy Preservation:** Dynamically maps and recreates deep nested folder structures from the source library into the destination library.
* **Delta Sync Engine:** Allows for rapid "catch-up" migrations by comparing file `Modified` timestamps, skipping untouched files to dramatically reduce cutover time.
* **Stream Buffering:** Downloads files to a temporary local cache before uploading to the destination, preventing local RAM exhaustion when moving terabytes of data.
* **Comprehensive Auditing:** Generates real-time, per-file CSV transfer logs detailing Success/Failure statuses, which are automatically merged and uploaded directly to the destination SharePoint site upon completion.

## Prerequisites
1. **Environment:** * [PowerShell 7.0+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) (Required for parallel processing features).
   * Run terminal as **Administrator**.
2. **Modules:**
   * `PnP.PowerShell` (Install via: `Install-Module PnP.PowerShell -Scope CurrentUser`)
3. **Microsoft 365 Configuration:**
   * An Entra ID App Registration with `Sites.ReadWrite.All` Application Permissions.
   * A self-signed certificate uploaded to the App Registration (Thumbprint required).
   * Adequate destination SharePoint storage capacity.

## Repository Structure
```text
SPO-2-SPO-Migration/
│
├── migration.ps1        # The core execution engine
├── sites.csv            # Input list of source site URLs to migrate
├── .gitignore           # Ignores local temp files and sensitive logs
└── README.md            # Project documentation
```

## Configuration
Before running the script, open `migration.ps1` and configure the following variables in the **CONFIGURATION** block:

* `$DestinationSiteUrl`: The root URL of your unified target site.
* `$DestinationLibrary`: The target document library (e.g., "Shared Documents").
* `$SitesCsv`: Local path to your `sites.csv` file.
* `$LogDirectory`: Local directory where temporary and final CSV logs will be stored.
* `$ClientId`: Your Entra ID Application (Client) ID.
* `$Thumbprint`: The thumbprint of your authentication certificate.
* `$TenantId`: Your Microsoft 365 tenant domain (e.g., `company.onmicrosoft.com`).

## Usage Options

### 1. Initial Bulk Migration (Phase 1)
For the first massive data copy, ensure the Delta Sync variables inside `migration.ps1` are set as follows:

```powershell
$DeltaSync       = $false
$DeltaSyncCutoff = [datetime]"2026-01-01 00:00:00" # Ignored when DeltaSync is false
```

### 2. Delta Sync (Cutover Phase)
To catch up on files that users modified while the initial bulk migration was running, update the script:

```powershell
$DeltaSync       = $true
$DeltaSyncCutoff = [datetime]"2026-06-25 00:00:00" # Set to the exact date/time your initial sync started
```

## Execution
Run the script directly from your PowerShell 7 console:

```powershell
.\migration.ps1
```

## Throttling & Limitations
Microsoft 365 strictly enforces API rate limits. The script defaults to safe parallelization thresholds:

* `$SiteThrottle = 4` (Concurrent sites)
* `$FileThrottle = 6` (Concurrent files per site)

**Warning:** Increasing these numbers beyond 6-10 per tenant can result in immediate "429 Too Many Requests" throttling errors, causing the migration to fail.

---

## Required Additional Repository Files

### `sites.csv`
This is the required input file. It should sit in the same directory as your script (or wherever you map `$SitesCsv` to). It only requires a single header column.

```csv
SiteUrl
[https://contoso.sharepoint.com/sites/Site1](https://contoso.sharepoint.com/sites/Site1)
[https://contoso.sharepoint.com/sites/Site2](https://contoso.sharepoint.com/sites/Site2)
[https://contoso.sharepoint.com/sites/Site3](https://contoso.sharepoint.com/sites/Site3)
```

### `.gitignore`
If you are storing this in GitHub, Azure DevOps, or another version control system, you **must** include this `.gitignore` file. It ensures you do not accidentally commit your massive CSV audit logs or temporary cached migration files to your repository.

```text
# Ignore Local PowerShell Cache
*.clixml

# Ignore temporary stream buffers and downloaded files
StreamBuffer/
*.tmp
*.iso
*.exe
*.pdf
*.docx
*.xlsx

# Ignore Migration Audit Logs
MigrationLogs/
*.csv
!sites.csv

# Ignore OS generated files
.DS_Store
Thumbs.db
```
