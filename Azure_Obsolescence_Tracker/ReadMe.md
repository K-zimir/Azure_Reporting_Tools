# 🛡️ Azure Obsolescence Tracker

> PowerShell runbook for Azure Automation that scans all your Azure subscriptions and generates a self-contained, interactive HTML report covering OS lifecycle risks, runtime EOL, AKS cluster versions, SQL compliance, TLS posture, planned service retirements, and resource group lifecycle tag tracking.

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Configurable Parameters](#configurable-parameters)
- [Scan Modules](#scan-modules)
- [Lifecycle Data Strategy](#lifecycle-data-strategy)
- [HTML Report](#html-report)
- [Network Requirements](#network-requirements)
- [Monitoring & Diagnostics](#monitoring--diagnostics)
- [Known Limitations](#known-limitations)

---

## Features

| Module | Coverage |
|--------|----------|
| **VM OS** | Windows Server, Windows 10/11, Ubuntu, RHEL, CentOS, Debian, SLES |
| **App Service Runtimes** | .NET, Node.js, Java, Python, PHP + TLS/HTTPS compliance |
| **AKS** | Cluster Kubernetes version vs Azure-supported versions |
| **SQL** | Server version + minimum TLS version |
| **Service Retirements** | Azure Advisor `ServiceUpgradeAndRetirement` recommendations |
| **Deprecated API Versions** | ARM provider API version freshness (placeholder) |
| **TLS Compliance** | Storage Accounts, Application Gateways, Redis Cache |
| **Deprecated VM SKUs** | Advisor + ARG, filtered on series/SKU deprecations |
| **Lifecycle Tags** | `lifecycle` tag compliance on Resource Groups |

The generated HTML report includes:
- 11 navigation tabs: Dashboard, VM OS, VM SKUs, Runtimes, AKS, SQL, TLS, Retirements, Lifecycle Tags, Executive, Diag
- Interactive Chart.js charts (clickable — navigate to detail page)
- Sortable/filterable tables with per-row annotation system (localStorage-backed)
- CSV export for all tables
- PDF export via html2canvas + jsPDF
- Dark mode toggle with persistence
- Global search across all tables
- Composite Obsolescence Score (0–100)
- Executive Summary page for management reporting

---

## Prerequisites

### Azure

- **Azure Automation Account** with a PowerShell runbook
- **Managed Identity** (User-Assigned recommended, System-Assigned as fallback) with the **Reader** role assigned on all target subscriptions
- **PowerShell 7** runtime on the Runbook Worker (recommended for parallel processing) — PS 5.1 is supported but runs sequentially

### Required PowerShell Modules

The following modules must be imported into your Automation Account:

```
Az.Accounts
Az.Resources
Az.Compute
Az.Network
Az.Storage
Az.Sql
Az.Aks
Az.Websites
Az.RedisCache
Az.Monitor
```

### Automation Account Variables

Create the following variables under **Automation Account → Variables**:

| Variable Name | Description | Encrypted |
|---------------|-------------|-----------|
| `MI_OBSO` | Client ID of the User-Assigned Managed Identity | No |
| `SMTP_SERVER` | SMTP server hostname | No |
| `SMTP_PORT` | SMTP port (e.g. `587`) | No |
| `SMTP_FROM` | Sender email address | No |
| `SMTP_TO` | Recipient email address(es) | No |
| `SMTP_PASSWORD` | SMTP password | **Yes** |

> **Note:** If the `MI_OBSO` variable is missing or empty, the script automatically falls back to the System-Assigned Managed Identity.

---

## Deployment

### 1. Import the Modules

In your Automation Account, go to **Modules → Browse gallery** and import each module listed above.

### 2. Create the Variables

Go to **Variables** and create all variables described in the table above. Make sure to check **Encrypted** for `SMTP_PASSWORD`.

### 3. Assign Roles to the Managed Identity

```bash
# Repeat for each target subscription
az role assignment create \
  --assignee "<managed-identity-client-id>" \
  --role "Reader" \
  --scope "/subscriptions/<subscription-id>"
```

### 4. Create the Runbook

1. In your Automation Account, go to **Runbooks → Create a runbook**
2. Type: **PowerShell**, Runtime version: **7.2** (recommended)
3. Paste the script content
4. **Publish** the runbook

### 5. Schedule Monthly Execution

1. Open the runbook → **Schedules → Add a schedule**
2. Frequency: **Monthly** (e.g. 1st of each month at 7:00 AM)
3. Link the schedule to the runbook

---

## Configurable Parameters

All parameters are located at the top of the script under the `CONFIGURABLE PARAMETERS` section.

### Risk Thresholds (days until EOL)

```powershell
$script:CriticalDays  = 90    # 0–90 days    → Critical (red)
$script:HighDays      = 180   # 91–180 days  → High (orange)
$script:MediumDays    = 365   # 181–365 days → Medium (blue)
                               # >365 days    → Low (green)
```

### Scan Scope

```powershell
# Look-ahead window: how far in the future to flag upcoming EOLs (days)
$script:LookAheadDays = 365

# Regex pattern to exclude subscriptions from scanning (case-insensitive)
$script:ExcludeSubPattern = "Visual Studio|Dev/Test"
```

### Lifecycle Tag Tracking

```powershell
$script:LifecycleTagName          = "lifecycle"  # Tag name to track
$script:LifecycleTagFormat        = "MM.yyyy"    # Expected format (e.g. 03.2027)
$script:LifecycleTagDisplayFormat = "MM/yyyy"    # Display format in the report
$script:LifecycleTagExcludeSubs   = "..."        # Regex to exclude subscriptions
$script:LifecycleTagExcludeRGs    = "NetworkWatcherRG|DefaultResourceGroup|..."
$script:LifecycleTagWarningDays   = 90           # < 90 days → Critical
$script:LifecycleTagCautionDays   = 180          # < 180 days → High
$script:LifecycleTagMaxYears      = 3            # > 3 years → "Too far"
```

### Email

```powershell
$script:EmailSubjectTemplate = "[Azure Obsolescence] Monthly Lifecycle Report — {0}"
$script:ReportTitle          = "Azure Obsolescence Tracker"
```

---

## Scan Modules

### 4a — VM OS (`Get-VMObsolescence`)

Scans all VMs by reading the **Image Reference** (Publisher/Offer/SKU) as the primary source, with the `os-version` tag as a fallback. Recognized OS families: Windows Server, Windows 10/11, Ubuntu, RHEL, CentOS, Debian, SLES.

The `os-version` tag is used to:
- **Refine** the version detected from the image (tag takes precedence when more precise)
- **Fill gaps** for custom or marketplace images with no recognized publisher

Accepted tag formats: `Windows Server 2019`, `Ubuntu 22.04`, `RHEL 8`, etc.

### 4b — App Service Runtimes (`Get-AppServiceObsolescence`)

Detects the runtime from `LinuxFxVersion`/`WindowsFxVersion` or individual SiteConfig properties (`JavaVersion`, `PhpVersion`, etc.). Also checks the minimum TLS version and HTTPS-only enforcement per app.

### 4c — AKS (`Get-AKSObsolescence`)

Compares the `major.minor` version of each cluster against the list of Azure-supported Kubernetes versions, fetched live from the ARM API after authentication. Any version absent from that list is treated as out of support (EOL).

### 4d — SQL (`Get-SQLObsolescence`)

Scans Azure SQL Servers for engine version and minimum TLS setting. Since Azure SQL is a fully managed PaaS service, most entries will be Low risk unless TLS is deprecated.

### 4e — Service Retirements (`Get-AdvisorDeprecations`)

Mirrors the logic of the **Azure Advisor Service Retirement Workbook** in 3 steps:
1. Advisor Metadata API → tenant-level catalog of retiring services
2. Advisor Recommendations API per subscription → impacted resources
3. Azure Resource Graph (`advisorresources`) → supplementary source with deduplication

### 4f/4h — Deprecated VM SKUs (`Get-VMSKUDeprecations`)

Filters Advisor recommendations containing `series`, `SKU`, or `deprecat` on `Microsoft.Compute/virtualMachines`, excluding right-sizing recommendations. Cross-references the VM inventory (module 4a) to enrich results with the current SKU.

### 4g — TLS/SSL Compliance (`Get-TLSCompliance`)

Checks the minimum TLS version on Storage Accounts, Application Gateways, and Redis Cache. Any value below TLS 1.2 is flagged as `Deprecated`.

### 4i — Lifecycle Tag Tracking (`Get-LifecycleTagCompliance`)

Scans the configurable tag (default: `lifecycle`) on all Resource Groups. Possible statuses: `Missing`, `Empty`, `Bad format`, `Expired`, `Imminent`, `Approaching`, `Too far`, `OK`.

---

## Lifecycle Data Strategy

EOL dates are loaded **dynamically at runtime** from [endoflife.date](https://endoflife.date):

| Product | API Slug |
|---------|----------|
| Windows Server | `windows-server` |
| Windows 10/11 | `windows` |
| Ubuntu | `ubuntu` |
| RHEL | `rhel` |
| .NET | `dotnet` |
| Node.js | `nodejs` |
| Java | `microsoft-build-of-openjdk` |
| Python | `python` |
| PHP | `php` |
| SQL Server | `mssqlserver` |

Supported AKS versions are fetched from the Azure ARM API (`/providers/Microsoft.ContainerService/locations/{loc}/kubernetesVersions`) after authentication.

**Fallback behavior:** if an API call fails (NSG, firewall, proxy, timeout), hardcoded data is used as a safety net and a `[WARN][EOLAPI]` entry is written to the diagnostic log. Check the **Diag** tab of the report or the Automation job logs to detect this condition.

> Periodically review and refresh the hardcoded fallback values in the script against [endoflife.date](https://endoflife.date) and [Microsoft Learn Lifecycle](https://learn.microsoft.com/lifecycle) to keep them accurate.

---

## HTML Report

The report is a **self-contained HTML file** sent as an email attachment. It opens in any modern browser with no server or local dependencies required (CDN assets are loaded on open).

### Obsolescence Score (0–100)

The score is computed as follows:
- **60%** — fraction of resources at Low/Unknown risk
- **25%** — penalty for EOL and Critical resources
- **15%** — penalty for deprecated TLS and critical service retirements

A score **≥ 70** is considered healthy (green), **40–69** warrants attention (orange), **< 40** is critical (red).

### Annotations

Each table row has a 📝 button to add a personal note, persisted in the browser's `localStorage`.

---

## Network Requirements

The Automation Worker requires outbound HTTPS access to the following domains:

| Domain | Purpose |
|--------|---------|
| `endoflife.date` | OS / Runtime / SQL lifecycle dates |
| `fonts.googleapis.com` | HTML report fonts |
| `cdn.jsdelivr.net` | Chart.js |
| `cdnjs.cloudflare.com` | jsPDF, html2canvas |

> If `endoflife.date` is unreachable, the script falls back to hardcoded data and logs a warning. The report remains fully functional but EOL dates may be slightly outdated.

---

## Monitoring & Diagnostics

Each execution produces structured entries in the **Automation job logs** in the following format:

```
[2025-01-15 08:12:34] [INFO]  [AUTH]   Connected with User MI (ClientId: ...)
[2025-01-15 08:12:36] [INFO]  [EOLAPI] Fetching lifecycle data from endoflife.date...
[2025-01-15 08:12:37] [WARN]  [EOLAPI] Failed to fetch endoflife.date/ubuntu.json: ...
[2025-01-15 08:13:45] [INFO]  [KPI]    Obsolescence Score: 72/100
```

Log levels are `INFO`, `WARN`, and `ERROR`. Fatal error codes (`E001`–`E010`) throw an exception and halt the runbook.

The **Diag** tab of the HTML report also displays the full diagnostic log for the current execution.

---

## Known Limitations

- **Read-only**: the script does not create, modify, or delete any Azure resource.
- **Module 4f (API versions)**: placeholder — does not yet produce results in the report.
- **AKS EOL dates**: the Azure ARM API lists supported versions but does not return explicit EOL dates. Any version absent from the supported list is treated as out of support.
- **Azure SQL**: fully managed PaaS service — engine versions are not directly controllable. The module focuses on TLS compliance.
- **Annotations**: stored in browser `localStorage`. They do not transfer between machines and are lost if the browser cache is cleared.

---

## Author & Changelog

| Version | Changes |
|---------|---------|
| **1.2.0** | Clarified lifecycle data strategy, comments translated to English, module 4i (Lifecycle Tags) added, network requirements documented |
| **1.1.0** | Windows 10/11 Desktop detection, VM SKU dedup fix, dynamic OS chart height, right-size exclusion, configurable parameters |
| **1.0.0** | Initial release: 7 scan modules, HTML report, email delivery |

**Author:** K-zimir
