# Azure Reporting Tools

> A collection of read-only Azure Automation runbooks that scan your subscriptions and deliver self-contained, interactive HTML reports by email. Each tool follows the same architecture: Managed Identity authentication, multi-subscription scanning via Azure PowerShell and Resource Graph, and a single-file HTML report with Chart.js dashboards, sortable tables, CSV/PDF export, and dark mode.

**All tools are read-only — they do not create, modify, or delete any Azure resource.**

---

## Tools

| Tool | Focus | Script | README |
|------|-------|--------|--------|
| 🛡️ **Azure Obsolescence Tracker** | Lifecycle & technical debt | [`Azure_Obsolescence_Tracker/`](./Azure_Obsolescence_Tracker/) | [→ README](./Azure_Obsolescence_Tracker/README.md) |
| 💰 **Azure FinOps Reporter** | Cost visibility & waste | [`finops/`](./finops/) | [→ README](./finops/README.md) |

---

## 🛡️ Azure Obsolescence Tracker

Scans all subscriptions for resources running on end-of-life or near-EOL software stacks, deprecated Azure services, and non-compliant security configurations. Lifecycle dates are fetched live from the [endoflife.date](https://endoflife.date) public API at runtime, with hardcoded fallback data used only when the API is unreachable.

**What it covers:**

- VM operating system lifecycle (Windows Server, Windows 10/11, Ubuntu, RHEL, CentOS, Debian, SLES)
- App Service runtime versions (.NET, Node.js, Java, Python, PHP) + TLS/HTTPS compliance
- AKS cluster Kubernetes versions vs Azure-supported versions
- Azure SQL Server versions and minimum TLS enforcement
- Azure Advisor service retirements and deprecations
- Deprecated VM SKU series
- TLS compliance across Storage Accounts, Application Gateways, Redis Cache
- Resource Group lifecycle tag tracking

**Report highlights:** Obsolescence Score (0–100), EOL timeline chart, per-resource risk classification (EOL / Critical / High / Medium / Low), Executive Summary page, per-row annotation system.

→ [Full documentation](./Azure_Obsolescence_Tracker/README.md)

---

## 💰 Azure FinOps Reporter

Scans all subscriptions for cost visibility, resource waste, and cloud spend optimisation opportunities. Built on the same Automation runbook architecture as the Obsolescence Tracker, it delivers a monthly HTML report covering rightsizing recommendations, idle resources, reservation coverage, and budget adherence.

**What it covers:**

- VM rightsizing and idle resource detection (via Azure Advisor cost recommendations)
- Unattached disks, unused public IPs, and orphaned resources
- Reserved Instance and Savings Plan coverage gaps
- Budget consumption and forecast trends (Azure Cost Management)
- Storage account tier optimisation
- Deprecated SKU cost impact

**Report highlights:** Monthly spend summary, waste breakdown by category, top rightsizing opportunities, RI/SP coverage chart, subscription-level cost heatmap.

→ [Full documentation](./finops/README.md)

---

## Shared Architecture

Both tools are built on the same foundation:

```
Azure Automation Runbook (PowerShell 7)
    │
    ├── Managed Identity authentication (User-Assigned or System-Assigned)
    ├── Multi-subscription scan (excludes Visual Studio / Dev/Test by default)
    ├── Azure PowerShell modules (Az.*)
    ├── Azure Resource Graph (cross-subscription queries)
    ├── Azure REST / ARM APIs
    │
    └── Self-contained HTML report
            ├── Chart.js interactive charts
            ├── Sortable / filterable tables
            ├── CSV + PDF export
            ├── localStorage annotations
            ├── Dark mode
            └── Email delivery via SMTP
```

### Common prerequisites

Both tools share the same module and infrastructure requirements:

**PowerShell modules** (import into your Automation Account):
```
Az.Accounts · Az.Resources · Az.Compute · Az.Network
Az.Storage · Az.Sql · Az.Aks · Az.Websites · Az.RedisCache · Az.Monitor
```

**Managed Identity:** assign the **Reader** role on all target subscriptions.

**SMTP variables** (create in Automation Account → Variables):

| Variable | Description | Encrypted |
|----------|-------------|-----------|
| `SMTP_SERVER` | SMTP hostname | No |
| `SMTP_PORT` | SMTP port (e.g. `587`) | No |
| `SMTP_FROM` | Sender address | No |
| `SMTP_TO` | Recipient address(es) | No |
| `SMTP_PASSWORD` | SMTP password | **Yes** |

Each tool uses its own Managed Identity variable (`MI_OBSO` for the Obsolescence Tracker, `MI_RI_FinOps` for the FinOps Reporter) so they can run under separate identities with scoped permissions if needed.

---

## Repository Structure

```
Azure_Reporting_Tools/
├── README.md                  ← You are here
│
├── Azure_Obsolescence_Tracker/
│   ├── README.md
│   └── AzureObsolescenceTracker.ps1
│
└── finops/
    ├── README.md
    └── AzureFinOpsReporter.ps1
```

---

## Deployment Overview

1. **Import modules** — add all required `Az.*` modules to your Automation Account
2. **Create variables** — SMTP settings + Managed Identity client ID per tool
3. **Assign Reader role** — on all target subscriptions for each Managed Identity
4. **Create runbooks** — one per tool, PowerShell 7.2 runtime recommended
5. **Schedule** — monthly trigger recommended (1st of month, early morning)

Refer to each tool's README for step-by-step deployment instructions and all configurable parameters.

---

## Design Principles

- **Read-only by design** — no ARM writes, no role assignments, no resource mutations
- **Fail-safe** — each scan module catches its own errors; a failure in one subscription does not abort the entire run
- **Live data over hardcoded tables** — lifecycle dates are fetched from public APIs at runtime; static fallback data is only used when APIs are unreachable, and a diagnostic warning is emitted
- **Self-contained reports** — the HTML output has no server dependency and opens in any modern browser
- **Structured diagnostics** — every run produces timestamped log entries accessible in the Automation job output and in the report's Diag tab

---

## Author

**K-zimir**
