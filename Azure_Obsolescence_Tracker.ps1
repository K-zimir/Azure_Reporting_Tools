#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Storage, Az.Sql, Az.Aks, Az.Websites, Az.RedisCache, Az.Monitor

<#
.SYNOPSIS
    Azure Obsolescence Tracker — Interactive HTML report generator.

.DESCRIPTION
    Scans all Azure subscriptions accessible by the Managed Identity and generates
    a self-contained, interactive HTML report covering:

    DATA COLLECTION MODULES
      4a. VM OS Lifecycle        — Windows Server/Desktop, Ubuntu, RHEL, CentOS, Debian, SLES
      4b. App Service Runtimes   — .NET, Node.js, Java, Python, PHP + TLS/HTTPS compliance
      4c. AKS Kubernetes         — Cluster version vs supported K8s versions
      4d. SQL Databases          — Server version + TLS minimum version
      4e. Service Retirements    — Azure Advisor "ServiceUpgradeAndRetirement" recommendations
      4f. Deprecated API Vers.   — ARM provider API version freshness (placeholder)
      4g. TLS/SSL Compliance     — Storage Accounts, App Gateways, Redis Cache
      4h. VM SKU Deprecations    — Advisor + ARG, filtered on series/SKU deprecation only
      4i. Lifecycle Tag Tracking — Resource Group tag compliance (configurable tag name/format)

    LIFECYCLE DATA STRATEGY (dynamic + fallback)
      OS, Runtime and SQL lifecycle dates are fetched LIVE at runtime from the
      endoflife.date public API (https://endoflife.date/api/{product}.json).
      Hardcoded fallback data is only used when the API call fails (network error,
      timeout, or empty response). A WARN diagnostic entry is written whenever the
      script falls back to static data — check the Diag tab in the report.

      AKS supported versions are fetched from the Azure ARM API
      (/providers/Microsoft.ContainerService/locations/{loc}/kubernetesVersions)
      AFTER authentication. A static fallback list is used until then and kept
      if the ARM call fails.

      IMPORTANT: If the Automation Account has no outbound Internet access to
      endoflife.date (NSG, firewall, proxy), the script will silently fall back
      to the hardcoded data on every run. Monitor the Diag tab or job logs for
      [WARN][EOLAPI] entries to detect this condition.

    HTML REPORT FEATURES
      - 11 navigation tabs: Dashboard, VM OS, VM SKUs, Runtimes, AKS, SQL, TLS,
        Retirements, Lifecycle Tags, Executive, Diag
      - Interactive Chart.js charts (clickable → navigate to detail page)
      - Sortable/filterable tables with per-row annotation system (localStorage-backed)
      - Master/Detail view for Retirements (checkbox-driven resource filtering)
      - CSV export (all tables, includes annotations)
      - PDF export via html2canvas + jsPDF
      - Dark mode toggle with persistence
      - Global search across all tables
      - Obsolescence Score (0-100 composite maturity metric)
      - Executive Summary page for management reporting

    ARCHITECTURE
      The script uses two PowerShell here-strings:
        $jsBlock       = @'...'@   — Single-quoted: contains ALL JavaScript (no PS interpolation)
        $htmlContent   = @"..."@   — Double-quoted: contains HTML/CSS + PS variable injection
      This separation is CRITICAL — any JavaScript with arrow functions (=>) or template
      literals must stay in $jsBlock. The $htmlContent only contains:
        - HTML structure with PS variables ($reportDate, $subCount, etc.)
        - <script> tag with const declarations (const vmData=$jsVMs;) and $jsBlock injection
      DO NOT put raw JS code in $htmlContent or PS interpolation will break it.

    DEPLOYMENT
      Designed for Azure Automation (Runbook) with a User-Assigned Managed Identity.
      SMTP credentials are stored as Automation Variables (see CONFIGURABLE PARAMETERS).
      READ-ONLY: this script does NOT modify, create, or delete any Azure resource.

    NETWORK REQUIREMENTS
      Outbound HTTPS to:
        - endoflife.date     (lifecycle data — fallback used if unreachable)
        - fonts.googleapis.com, cdn.jsdelivr.net, cdnjs.cloudflare.com
          (HTML report CDN assets — report still works offline but unstyled)

.VERSION
    1.2.0

.AUTHOR
    K-zimir.

.CHANGELOG
    v1.2.0  — Clarified lifecycle data strategy in header (dynamic API + fallback).
               Comments and cartouche translated to English throughout.
               Added 4i (Lifecycle Tag) to module list in synopsis.
               Added network requirements section.
    v1.1.0  — Windows 10/11 Desktop detection, VM SKU dedup fix, OS chart dynamic height,
               right-size exclusion, configurable parameters, code documentation.
    v1.0.0  — Initial release: 7 scan modules, HTML report, email delivery.

.NOTES
    - OS, Runtime and SQL lifecycle dates are loaded dynamically from endoflife.date
      at runtime. Hardcoded fallback values (sections: $OSLifecycle fallback,
      $RuntimeLifecycle fallback, $SQLLifecycle fallback) are ONLY used when the API
      is unreachable. Review and update fallback values periodically as a safety net.
    - AKS versions are fetched live from the Azure ARM API after authentication,
      with a static fallback list used if that call fails. The fallback does NOT
      reflect the current state of Azure-supported Kubernetes versions.
    - Advisor retirement data is fetched live via REST API. No hardcoded retirement list.
    - The Managed Identity needs Reader role on all target subscriptions.
    - SMTP variables must exist in the Automation Account (see CONFIGURABLE PARAMETERS).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
$WarningPreference = "SilentlyContinue"

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURABLE PARAMETERS — Adjust these to match your environment
# ══════════════════════════════════════════════════════════════════════════════

# ── Risk Thresholds (days until EOL) ─────────────────────────────────────────
# Resources are classified into risk levels based on days remaining until EOL.
# Adjust these to match your organization's risk appetite.
$script:CriticalDays  = 90    # 0-90 days   → Critical (red)
$script:HighDays      = 180   # 91-180 days  → High (orange)
$script:MediumDays    = 365   # 181-365 days → Medium (blue)
                               # >365 days    → Low (green)

# ── Scan Scope ───────────────────────────────────────────────────────────────
# Look-ahead window: how far in the future to flag upcoming EOLs (days)
$script:LookAheadDays = 365

# Regex pattern to EXCLUDE subscriptions from scanning (case-insensitive).
# Default excludes Visual Studio and Dev/Test subscriptions.
$script:ExcludeSubPattern = "Visual Studio|Dev/Test"

# ── Authentication ───────────────────────────────────────────────────────────
# Name of the Automation Variable that stores the User Managed Identity Client ID.
# If the variable is missing or empty, the script falls back to System MI.
$script:ManagedIdentityVariable = "MI_OBSO"

# ── SMTP / Email Delivery ────────────────────────────────────────────────────
# These are the names of Azure Automation Variables used for email delivery.
# Create them in your Automation Account → Variables (encrypt the password).
$script:SmtpServerVar   = "SMTP_SERVER"    # SMTP server hostname
$script:SmtpPortVar     = "SMTP_PORT"      # SMTP port (587 for TLS)
$script:SmtpPasswordVar = "SMTP_PASSWORD"  # SMTP password (encrypted variable)
$script:SmtpFromVar     = "SMTP_FROM"      # Sender email address
$script:SmtpToVar       = "SMTP_TO"        # Recipient email address(es)

# ── Email Subject ────────────────────────────────────────────────────────────
# Template for the email subject line. {0} is replaced with the month/year at runtime.
$script:EmailSubjectTemplate = "[Azure Obsolescence] Monthly Lifecycle Report — {0}"

# ── Report Branding ──────────────────────────────────────────────────────────
# Title shown in the HTML report header and browser tab
$script:ReportTitle = "Azure Obsolescence Tracker"

# ── Lifecycle Tag Tracking ───────────────────────────────────────────────────
# Name of the Azure tag to track for project lifecycle / end-of-project dates.
# This tag should be set on Resource Groups with a date value.
$script:LifecycleTagName = "lifecycle"

# Expected date format in the tag value (PowerShell datetime format).
# Common formats: "MM.yyyy" for 03.2027, "yyyy-MM" for 2027-03, "MM/yyyy" for 03/2027
$script:LifecycleTagFormat = "MM.yyyy"

# Display format shown in the report (for human-readable output)
$script:LifecycleTagDisplayFormat = "MM/yyyy"

# Regex pattern for subscriptions to EXCLUDE from lifecycle tag scanning.
# Leave empty "" to scan all subscriptions.
$script:LifecycleTagExcludeSubs = "Abonnement Visual Studio Professional|Sub"

# Regex pattern for Resource Groups to EXCLUDE from lifecycle tag scanning.
# Example: "rg-terraform-state|rg-backup|NetworkWatcherRG"
$script:LifecycleTagExcludeRGs = "NetworkWatcherRG|DefaultResourceGroup|cloud-shell-storage|AzureBackupRG"

# Thresholds for lifecycle tag date assessment (in days)
$script:LifecycleTagWarningDays  = 90    # < 90 days  → Critical (red)
$script:LifecycleTagCautionDays  = 180   # < 180 days → High (orange)
$script:LifecycleTagMaxYears     = 3     # > 3 years  → Flagged as "Too far" (blue)

# ─── Script-level diagnostics ────────────────────────────────────────────────
$script:DiagnosticLog = [System.Collections.Generic.List[string]]::new()
$script:StartTime     = Get-Date

function Write-Diag {
    param([string]$Code, [string]$Level, [string]$Message)
    $ts  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] [$Code] $Message"
    $script:DiagnosticLog.Add($line)
    Write-Host $line
}

function Exit-WithError {
    param([string]$Code, [string]$Message)
    Write-Diag -Code $Code -Level "ERROR" -Message $Message
    Write-Diag -Code "DIAG" -Level "INFO"  -Message "Full diagnostic log follows:"
    $script:DiagnosticLog | ForEach-Object { Write-Host $_ }
    throw "[$Code] $Message"
}

function Get-SafeAutomationVariable {
    param([string]$Name)
    try {
        $val = Get-AutomationVariable -Name $Name
        if ([string]::IsNullOrEmpty($val)) {
            Write-Diag -Code "E010" -Level "WARN" -Message "Automation variable '$Name' is empty."
        }
        return $val
    }
    catch {
        Exit-WithError -Code "E010" -Message "Cannot retrieve Automation variable '$Name'. Error: $_"
    }
}

# ==============================================================================
# REFERENCE DATA — OS / Runtime / SQL / AKS Lifecycle Dates
# ==============================================================================
# Lifecycle dates are fetched DYNAMICALLY from the endoflife.date public API at
# runtime. Hardcoded fallback data below is only activated when the API is
# unreachable (network error, timeout, DNS failure, or empty response).
#
# When the fallback is used, a [WARN][EOLAPI] entry is written to the diagnostic
# log — visible in the Diag tab of the HTML report and in the Automation job logs.
#
# AKS versions follow a different flow: a static list is defined here and replaced
# after authentication by a live Azure ARM API call (Update-AKSVersionsFromAPI).
# The static list is only kept if the ARM call fails.
#
# Recommendation: periodically review and refresh the fallback values below
# against https://endoflife.date and https://learn.microsoft.com/lifecycle
# to ensure they remain accurate as a last-resort safety net.

# ── Helper: Fetch JSON from endoflife.date API ──────────────────────────────
function Get-EndOfLifeData {
    param([string]$Product)
    try {
        $url = "https://endoflife.date/api/$Product.json"
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 -ErrorAction Stop
        return $response
    }
    catch {
        Write-Diag -Code "EOLAPI" -Level "WARN" -Message "Failed to fetch endoflife.date/$Product.json: $_"
        return $null
    }
}

# ── Helper: Resolve EOL field — endoflife.date can return a boolean or a date string ──
# true  = still supported (no EOL date) → return "9999-12-31" sentinel
# false = already retired with no date  → return empty string
# string = actual date                  → return as-is
function Resolve-EolDate {
    param($EolValue)
    if ($EolValue -is [bool]) {
        if ($EolValue) { return "9999-12-31" } else { return "" }
    }
    return [string]$EolValue
}

# ── Build OS Lifecycle from API ─────────────────────────────────────────────
# Fetches data for each OS product slug. On success, populates $script:OSLifecycle.
# On partial or total failure, merges hardcoded fallback entries for missing products.
Write-Diag -Code "EOLAPI" -Level "INFO" -Message "Fetching lifecycle data from endoflife.date..."

$script:OSLifecycle = [System.Collections.Generic.List[hashtable]]::new()

# Map: endoflife.date product slug → OS display name + version transform function
$osProducts = @(
    @{ Slug="windows-server"; Product="Windows Server"; VersionMap={ param($c) $c.cycle } }
    @{ Slug="windows";        Product="__WINDOWS__";    VersionMap={ param($c) $c.cycle } }
    @{ Slug="ubuntu";         Product="Ubuntu";         VersionMap={ param($c) if ($c.lts -and $c.lts -ne $false) { "$($c.cycle) LTS" } else { $c.cycle } } }
    @{ Slug="rhel";           Product="RHEL";           VersionMap={ param($c) $c.cycle } }
    @{ Slug="centos";         Product="CentOS";         VersionMap={ param($c) $c.cycle } }
    @{ Slug="debian";         Product="Debian";         VersionMap={ param($c) $c.cycle } }
    @{ Slug="sles";           Product="SLES";           VersionMap={ param($c) $c.cycle } }
)

$osApiFailed = $false
foreach ($osProd in $osProducts) {
    $data = Get-EndOfLifeData -Product $osProd.Slug
    if ($data) {
        foreach ($cycle in $data) {
            $eolDate = Resolve-EolDate -EolValue $cycle.eol
            if (-not $eolDate -or $eolDate -eq "9999-12-31") { continue }
            $extProp = $cycle.PSObject.Properties["extendedSupport"]
            $extDate = if ($extProp -and $extProp.Value -and $extProp.Value -ne $false) {
                Resolve-EolDate -EolValue $extProp.Value
            } else { $eolDate }
            $version = & $osProd.VersionMap $cycle
            $ltsProp = $cycle.PSObject.Properties["lts"]
            $ltsNote = if ($ltsProp -and $ltsProp.Value -and $ltsProp.Value -ne $false) { "LTS" } else { "" }
            $supProp = $cycle.PSObject.Properties["support"]
            $supportNote = if ($supProp -and $supProp.Value -and $supProp.Value -ne $false) { "Mainstream: $($supProp.Value)" } else { "" }
            $notes = @($ltsNote, $supportNote) | Where-Object { $_ } | Join-String -Separator " — "
            if (-not $notes) { $notes = "From endoflife.date" }

            # Special handling: the "windows" slug on endoflife.date covers both
            # Windows 10 and Windows 11 cycles (e.g. "10-22H2", "11-24H2").
            # We split them into separate products; other versions (8, 7) are skipped.
            $prodName = $osProd.Product
            if ($prodName -eq "__WINDOWS__") {
                # cycle is like "10-22H2", "11-24H2" etc.
                if ($version -match "^10") { $prodName = "Windows 10" }
                elseif ($version -match "^11") { $prodName = "Windows 11" }
                else { continue } # Skip other Windows versions (8, 7, etc.)
            }

            $script:OSLifecycle.Add(@{
                Product  = $prodName
                Version  = $version
                EOL      = $eolDate
                Extended = $extDate
                Notes    = $notes
            })
        }
        Write-Diag -Code "EOLAPI" -Level "INFO" -Message "  $($osProd.Product): loaded $(@($data).Count) cycles from API"
    } else {
        $osApiFailed = $true
    }
}

# Add Windows 10/11 Enterprise editions — they share the same base EOL dates
# but have specific extended support timelines worth tracking separately.
$w10Base = $script:OSLifecycle | Where-Object { $_.Product -eq "Windows 10" } | Select-Object -First 1
if ($w10Base) {
    $script:OSLifecycle.Add(@{ Product="Windows 10"; Version="Enterprise"; EOL=$w10Base.EOL; Extended="2028-10-14"; Notes="ESU until Oct 2028 (free on Azure)" })
    $script:OSLifecycle.Add(@{ Product="Windows 10"; Version="Enterprise for Virtual Desktops"; EOL=$w10Base.EOL; Extended="2028-10-14"; Notes="ESU free on AVD until Oct 2028" })
    $script:OSLifecycle.Add(@{ Product="Windows 10"; Version="Pro"; EOL=$w10Base.EOL; Extended="2028-10-14"; Notes="ESU available (paid)" })
}
$w11Base = $script:OSLifecycle | Where-Object { $_.Product -eq "Windows 11" } | Select-Object -First 1
if ($w11Base) {
    $script:OSLifecycle.Add(@{ Product="Windows 11"; Version="Enterprise"; EOL=$w11Base.EOL; Extended=$w11Base.Extended; Notes="Current" })
    $script:OSLifecycle.Add(@{ Product="Windows 11"; Version="Enterprise for Virtual Desktops"; EOL=$w11Base.EOL; Extended=$w11Base.Extended; Notes="Current" })
    $script:OSLifecycle.Add(@{ Product="Windows 11"; Version="Pro"; EOL=$w11Base.EOL; Extended=$w11Base.Extended; Notes="Current" })
}

# ── Fallback: if any OS API call failed, merge hardcoded defaults ────────────
# Only entries not already populated by the API are added (no override of live data).
# Review these dates periodically against https://endoflife.date
if ($osApiFailed -or $script:OSLifecycle.Count -eq 0) {
    Write-Diag -Code "EOLAPI" -Level "WARN" -Message "API partially/fully failed — merging hardcoded OS fallback data"
    $fallbackOS = @(
        @{ Product="Windows Server"; Version="2012 R2";  EOL="2023-10-10"; Extended="2026-10-13"; Notes="FALLBACK — ESU Year 3 ends Oct 2026" }
        @{ Product="Windows Server"; Version="2016";     EOL="2027-01-12"; Extended="2027-01-12"; Notes="FALLBACK" }
        @{ Product="Windows Server"; Version="2019";     EOL="2029-01-09"; Extended="2029-01-09"; Notes="FALLBACK" }
        @{ Product="Windows Server"; Version="2022";     EOL="2031-10-14"; Extended="2031-10-14"; Notes="FALLBACK" }
        @{ Product="Ubuntu";         Version="20.04 LTS"; EOL="2025-04-02"; Extended="2030-04-02"; Notes="FALLBACK" }
        @{ Product="Ubuntu";         Version="22.04 LTS"; EOL="2027-04-01"; Extended="2032-04-01"; Notes="FALLBACK" }
        @{ Product="Ubuntu";         Version="24.04 LTS"; EOL="2029-04-25"; Extended="2034-04-25"; Notes="FALLBACK" }
        @{ Product="RHEL";           Version="8";   EOL="2029-05-31"; Extended="2032-05-31"; Notes="FALLBACK" }
        @{ Product="RHEL";           Version="9";   EOL="2032-05-31"; Extended="2035-05-31"; Notes="FALLBACK" }
        @{ Product="Windows 10";     Version="Enterprise"; EOL="2025-10-14"; Extended="2028-10-14"; Notes="FALLBACK — ESU free on Azure" }
        @{ Product="Windows 10";     Version="Enterprise for Virtual Desktops"; EOL="2025-10-14"; Extended="2028-10-14"; Notes="FALLBACK" }
        @{ Product="Windows 11";     Version="Enterprise"; EOL="2027-10-14"; Extended="2027-10-14"; Notes="FALLBACK" }
    )
    foreach ($fb in $fallbackOS) {
        $exists = $script:OSLifecycle | Where-Object { $_.Product -eq $fb.Product -and $_.Version -eq $fb.Version }
        if (-not $exists) { $script:OSLifecycle.Add($fb) }
    }
}
Write-Diag -Code "EOLAPI" -Level "INFO" -Message "OS Lifecycle: $($script:OSLifecycle.Count) entries loaded."

# ── Build Runtime Lifecycle from API ────────────────────────────────────────
# Same pattern as OS: live API first, hardcoded fallback only if API fails.
$script:RuntimeLifecycle = [System.Collections.Generic.List[hashtable]]::new()

$runtimeProducts = @(
    @{ Slug="dotnet";  Runtime=".NET"     }
    @{ Slug="nodejs";  Runtime="Node.js"  }
    @{ Slug="microsoft-build-of-openjdk"; Runtime="Java" }
    @{ Slug="python";  Runtime="Python"   }
    @{ Slug="php";     Runtime="PHP"      }
)

$rtApiFailed = $false
foreach ($rtProd in $runtimeProducts) {
    $data = Get-EndOfLifeData -Product $rtProd.Slug
    if ($data) {
        foreach ($cycle in $data) {
            $eolDate = Resolve-EolDate -EolValue $cycle.eol
            if (-not $eolDate -or $eolDate -eq "9999-12-31") { continue }
            $ltsPropRt = $cycle.PSObject.Properties["lts"]
            $isLts = ($ltsPropRt -and ($ltsPropRt.Value -eq $true -or ($ltsPropRt.Value -is [string] -and $ltsPropRt.Value -ne "false")))
            $notes = if ($isLts) { "LTS" } else { "STS" }

            $script:RuntimeLifecycle.Add(@{
                Runtime = $rtProd.Runtime
                Version = [string]$cycle.cycle
                EOL     = $eolDate
                LTS     = $isLts
                Notes   = $notes
            })
        }
        Write-Diag -Code "EOLAPI" -Level "INFO" -Message "  $($rtProd.Runtime): loaded $(@($data).Count) cycles from API"
    } else {
        $rtApiFailed = $true
    }
}

# ── Runtime fallback — only used if API is unreachable ──────────────────────
if ($rtApiFailed -or $script:RuntimeLifecycle.Count -eq 0) {
    Write-Diag -Code "EOLAPI" -Level "WARN" -Message "API partially/fully failed — merging hardcoded Runtime fallback"
    $fallbackRT = @(
        @{ Runtime=".NET";    Version="8.0";  EOL="2026-11-10"; LTS=$true;  Notes="FALLBACK" }
        @{ Runtime=".NET";    Version="9.0";  EOL="2026-05-12"; LTS=$false; Notes="FALLBACK" }
        @{ Runtime="Node.js"; Version="20";   EOL="2026-04-30"; LTS=$true;  Notes="FALLBACK" }
        @{ Runtime="Node.js"; Version="22";   EOL="2027-04-30"; LTS=$true;  Notes="FALLBACK" }
        @{ Runtime="Java";    Version="17";   EOL="2029-09-30"; LTS=$true;  Notes="FALLBACK" }
        @{ Runtime="Java";    Version="21";   EOL="2031-09-30"; LTS=$true;  Notes="FALLBACK" }
        @{ Runtime="Python";  Version="3.12"; EOL="2028-10-02"; LTS=$false; Notes="FALLBACK" }
        @{ Runtime="PHP";     Version="8.3";  EOL="2027-12-31"; LTS=$false; Notes="FALLBACK" }
    )
    foreach ($fb in $fallbackRT) {
        $exists = $script:RuntimeLifecycle | Where-Object { $_.Runtime -eq $fb.Runtime -and $_.Version -eq $fb.Version }
        if (-not $exists) { $script:RuntimeLifecycle.Add($fb) }
    }
}
Write-Diag -Code "EOLAPI" -Level "INFO" -Message "Runtime Lifecycle: $($script:RuntimeLifecycle.Count) entries loaded."

# ── Build SQL Lifecycle from API ────────────────────────────────────────────
# Uses the "mssqlserver" slug on endoflife.date.
$script:SQLLifecycle = [System.Collections.Generic.List[hashtable]]::new()
$sqlData = Get-EndOfLifeData -Product "mssqlserver"
if ($sqlData) {
    foreach ($cycle in $sqlData) {
        $eolDate = Resolve-EolDate -EolValue $cycle.eol
        if (-not $eolDate -or $eolDate -eq "9999-12-31") { continue }
        $extSqlProp = $cycle.PSObject.Properties["extendedSupport"]
        $extDate = if ($extSqlProp -and $extSqlProp.Value -and $extSqlProp.Value -ne $false) {
            Resolve-EolDate -EolValue $extSqlProp.Value
        } else { $eolDate }
        $script:SQLLifecycle.Add(@{
            Product  = "SQL Server"
            Version  = [string]$cycle.cycle
            EOL      = $eolDate
            Extended = $extDate
            Notes    = "From endoflife.date"
        })
    }
    Write-Diag -Code "EOLAPI" -Level "INFO" -Message "  SQL Server: loaded $(@($sqlData).Count) cycles from API"
} else {
    # ── SQL fallback — only used if API is unreachable ───────────────────────
    Write-Diag -Code "EOLAPI" -Level "WARN" -Message "SQL API failed — using hardcoded fallback"
    $script:SQLLifecycle = @(
        @{ Product="SQL Server"; Version="2016"; EOL="2026-07-14"; Extended="2026-07-14"; Notes="FALLBACK" }
        @{ Product="SQL Server"; Version="2017"; EOL="2027-10-12"; Extended="2027-10-12"; Notes="FALLBACK" }
        @{ Product="SQL Server"; Version="2019"; EOL="2030-01-08"; Extended="2030-01-08"; Notes="FALLBACK" }
        @{ Product="SQL Server"; Version="2022"; EOL="2033-01-11"; Extended="2033-01-11"; Notes="FALLBACK" }
    )
}
Write-Diag -Code "EOLAPI" -Level "INFO" -Message "SQL Lifecycle: $($script:SQLLifecycle.Count) entries loaded."

# ── AKS Versions: static bootstrap, replaced after authentication ────────────
# This list is used as a temporary placeholder until Update-AKSVersionsFromAPI
# runs successfully after Connect-AzAccount. If the ARM call fails, this list
# is kept as-is. The Azure ARM API does not provide explicit EOL dates for K8s
# versions — any version absent from the supported list is treated as out of support.
# Review and refresh this list periodically from:
# https://learn.microsoft.com/azure/aks/supported-kubernetes-versions
$script:AKSVersions = @(
    @{ Version="1.29"; EOL="2025-03-01"; Notes="FALLBACK — Out of support" }
    @{ Version="1.30"; EOL="2025-07-01"; Notes="FALLBACK" }
    @{ Version="1.31"; EOL="2025-11-01"; Notes="FALLBACK" }
    @{ Version="1.32"; EOL="2026-03-01"; Notes="FALLBACK" }
    @{ Version="1.33"; EOL="2026-07-01"; Notes="FALLBACK" }
)

# Replaces the static AKS version list with live data from the Azure ARM API.
# Called after Connect-AzAccount succeeds. Uses the first subscription and
# westeurope as the query location (version availability is region-independent).
# If the call fails, the static fallback list defined above is preserved.
function Update-AKSVersionsFromAPI {
    param([string]$SubscriptionId, [string]$Location)
    Write-Diag -Code "AKSAPI" -Level "INFO" -Message "Fetching AKS supported versions from Azure API..."
    try {
        $apiPath = "/subscriptions/$SubscriptionId/providers/Microsoft.ContainerService/locations/$Location/kubernetesVersions?api-version=2024-02-01"
        $resp = Invoke-AzRestMethod -Path $apiPath -Method GET -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            $result = ($resp.Content | ConvertFrom-Json)
            $versions = $result.values | Where-Object { $_.capabilities.supportPlan -contains "KubernetesOfficial" }
            if ($versions) {
                $newAKS = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($v in $versions) {
                    $ver = $v.version
                    if ($ver -match "^\d+\.\d+$") {
                        # The ARM API lists supported versions but does not return explicit EOL dates.
                        # An empty EOL field here means "currently supported" — assessed as Low risk.
                        # Any cluster version NOT in this list is treated as out of support (EOL).
                        $newAKS.Add(@{
                            Version = $ver
                            EOL     = ""
                            Notes   = "Supported (from Azure API)"
                        })
                    }
                }
                # Any version in our scan that's NOT in this list is unsupported
                if ($newAKS.Count -gt 0) {
                    $script:AKSVersions = $newAKS.ToArray()
                    Write-Diag -Code "AKSAPI" -Level "INFO" -Message "  AKS: $($newAKS.Count) supported versions loaded from Azure API"
                    return
                }
            }
        }
        Write-Diag -Code "AKSAPI" -Level "WARN" -Message "  AKS API returned no usable data, keeping fallback"
    }
    catch {
        Write-Diag -Code "AKSAPI" -Level "WARN" -Message "  AKS API failed: $_ — keeping fallback"
    }
}

# ==============================================================================
# 1. AUTHENTICATION — Connect using Managed Identity
# ==============================================================================
# Tries User-Assigned MI first (client ID read from Automation Variable),
# falls back to System-Assigned MI if the variable is absent or empty.
Write-Diag -Code "AUTH" -Level "INFO" -Message "Authenticating with Managed Identity..."
try {
    $clientId = $null
    try { $clientId = Get-AutomationVariable -Name $script:ManagedIdentityVariable } catch {}
    if ($clientId) {
        Connect-AzAccount -Identity -AccountId $clientId -ErrorAction Stop | Out-Null
        Write-Diag -Code "AUTH" -Level "INFO" -Message "Connected with User MI (ClientId: $clientId)."
    } else {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Diag -Code "AUTH" -Level "INFO" -Message "Connected with System Managed Identity."
    }
}
catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -match "401|Unauthorized|identity") {
        Exit-WithError -Code "E001" -Message "Auth failed — check MI roles. Detail: $errMsg"
    }
    Exit-WithError -Code "E001" -Message "Authentication failed: $errMsg"
}

# ==============================================================================
# 2. SUBSCRIPTION DISCOVERY — Find all enabled subs, exclude by pattern
# ==============================================================================
Write-Diag -Code "SUB" -Level "INFO" -Message "Enumerating subscriptions..."
try {
    $allSubs = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" }
    $subscriptions = $allSubs | Where-Object {
        $_.Name -notmatch $script:ExcludeSubPattern
    }
    if (-not $subscriptions) {
        Exit-WithError -Code "E002" -Message "No enabled subscriptions found."
    }
    $excluded = @($allSubs).Count - @($subscriptions).Count
    Write-Diag -Code "SUB" -Level "INFO" -Message "Found $($allSubs.Count) sub(s). Excluded $excluded VS/DevTest. Processing $(@($subscriptions).Count)."
}
catch {
    Exit-WithError -Code "E002" -Message "Subscription listing failed: $_"
}

# ==============================================================================
# 3. PERFORMANCE — detect PS7 for per-subscription parallelism
# ==============================================================================
$script:CanParallel = $PSVersionTable.PSVersion.Major -ge 7
Write-Diag -Code "PERF" -Level "INFO" -Message "PowerShell $($PSVersionTable.PSVersion). Parallel: $($script:CanParallel)."

# Refresh AKS version list now that authentication is complete.
# Uses the first available subscription and westeurope as the query location.
try {
    $firstSub = $subscriptions | Select-Object -First 1
    Update-AKSVersionsFromAPI -SubscriptionId $firstSub.Id -Location "westeurope"
} catch {
    Write-Diag -Code "AKSAPI" -Level "WARN" -Message "AKS version fetch skipped: $_"
}

# ==============================================================================
# HELPER — Compute risk level from days until EOL
# ==============================================================================
function Get-RiskLevel {
    param([int]$DaysUntilEOL)
    if ($DaysUntilEOL -le 0)                    { return "EOL" }
    if ($DaysUntilEOL -le $script:CriticalDays)  { return "Critical" }
    if ($DaysUntilEOL -le $script:HighDays)       { return "High" }
    if ($DaysUntilEOL -le $script:MediumDays)     { return "Medium" }
    return "Low"
}

function Get-DaysUntilEOL {
    param([string]$EOLDate)
    try {
        $eol = [datetime]::ParseExact($EOLDate, "yyyy-MM-dd", $null)
        return [math]::Round(($eol - (Get-Date)).TotalDays, 0)
    }
    catch { return 9999 }
}

# ==============================================================================
# 4a. VM OS INVENTORY & EOL DETECTION
# ==============================================================================
# Scans all VMs across subscriptions. Detects OS type and version from:
#   1. Image Reference (Publisher/Offer/SKU) — most reliable source
#   2. os-version tag (fallback for custom/marketplace images with no publisher match)
# Supports: Windows Server, Windows 10/11 Desktop, Ubuntu, RHEL, CentOS,
#           Debian, SLES. Unrecognized images → "Windows (Other)" / "Linux (Other)".
# Each VM is matched against $OSLifecycle (live API data or fallback) to determine
# EOL date and risk level using fuzzy version matching.
function Get-VMObsolescence {
    param([object[]]$Subscriptions)
    Write-Diag -Code "VMOS" -Level "INFO" -Message "Scanning VM OS versions..."
    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $vms = Get-AzVM -Status -ErrorAction SilentlyContinue

            foreach ($vm in $vms) {
                $osType    = "Unknown"
                $osVersion = "Unknown"
                $osOffer   = ""
                $osSku     = ""
                $publisher = ""
                $osTagValue = ""

                # ── Read os-version tag (case-insensitive) ──
                $vmTags = $vm.Tags
                if ($vmTags) {
                    foreach ($tagKey in $vmTags.Keys) {
                        if ($tagKey -ieq "os-version") {
                            $osTagValue = $vmTags[$tagKey]
                            break
                        }
                    }
                }

                try {
                    $imageRef = $vm.StorageProfile.ImageReference
                    $publisher = $imageRef.Publisher
                    $osOffer   = $imageRef.Offer
                    $osSku     = $imageRef.Sku

                    # Detect OS from image reference
                    if ($publisher -match "MicrosoftWindowsServer") {
                        $osType = "Windows Server"
                        if ($osSku -match "2025") { $osVersion = "2025" }
                        elseif ($osSku -match "2022") { $osVersion = "2022" }
                        elseif ($osSku -match "2019") { $osVersion = "2019" }
                        elseif ($osSku -match "2016") { $osVersion = "2016" }
                        elseif ($osSku -match "2012-R2|2012-r2") { $osVersion = "2012 R2" }
                        elseif ($osSku -match "2012") { $osVersion = "2012" }
                        else { $osVersion = $osSku }
                    }
                    elseif ($publisher -match "MicrosoftWindowsDesktop") {
                        # Windows 10 / Windows 11 client OS (AVD, dev/test, etc.)
                        if ($osOffer -match "windows-11" -or $osSku -match "win11") {
                            $osType = "Windows 11"
                        } else {
                            $osType = "Windows 10"
                        }
                        # Detect edition from SKU
                        if ($osSku -match "evd|avd|virtualdesktops|multi-?session") {
                            $osVersion = "Enterprise for Virtual Desktops"
                        }
                        elseif ($osSku -match "ent-?ltsc-?2019|ltsc-?2019") {
                            $osVersion = "Enterprise LTSC 2019"
                        }
                        elseif ($osSku -match "ent-?ltsc|ltsc-?2021|ltsc") {
                            $osVersion = "Enterprise LTSC 2021"
                        }
                        elseif ($osSku -match "ent|enterprise") {
                            $osVersion = "Enterprise"
                        }
                        elseif ($osSku -match "pro") {
                            $osVersion = "Pro"
                        }
                        else {
                            $osVersion = "Enterprise"
                        }
                    }
                    elseif ($publisher -match "Canonical") {
                        $osType = "Ubuntu"
                        # Try SKU first, then Offer for version detection
                        $ubuSource = "$osSku $osOffer"
                        if ($ubuSource -match "24[\._]04|24_04") { $osVersion = "24.04 LTS" }
                        elseif ($ubuSource -match "22[\._]04|22_04") { $osVersion = "22.04 LTS" }
                        elseif ($ubuSource -match "20[\._]04|20_04") { $osVersion = "20.04 LTS" }
                        elseif ($ubuSource -match "18[\._]04|18_04") { $osVersion = "18.04 LTS" }
                        else { $osVersion = $osSku }
                    }
                    elseif ($publisher -match "RedHat") {
                        $osType = "RHEL"
                        if ($osSku -match "^9|rhel9") { $osVersion = "9" }
                        elseif ($osSku -match "^8|rhel8") { $osVersion = "8" }
                        elseif ($osSku -match "^7|rhel7") { $osVersion = "7" }
                        else { $osVersion = $osSku }
                    }
                    elseif ($publisher -match "OpenLogic") {
                        $osType = "CentOS"
                        if ($osSku -match "^8") { $osVersion = "8" }
                        elseif ($osSku -match "^7") { $osVersion = "7" }
                        else { $osVersion = $osSku }
                    }
                    elseif ($publisher -match "SUSE") {
                        $osType = "SLES"
                        if ($osSku -match "15-sp5|15_sp5") { $osVersion = "15 SP5" }
                        elseif ($osSku -match "12-sp5|12_sp5") { $osVersion = "12 SP5" }
                        else { $osVersion = $osSku }
                    }
                    elseif ($publisher -match "Debian|credativ") {
                        $osType = "Debian"
                        if ($osSku -match "^12|bookworm") { $osVersion = "12 Bookworm" }
                        elseif ($osSku -match "^11|bullseye") { $osVersion = "11 Bullseye" }
                        elseif ($osSku -match "^10|buster") { $osVersion = "10 Buster" }
                        else { $osVersion = $osSku }
                    }
                    else {
                        $osType = if ($vm.OSProfile.WindowsConfiguration) { "Windows (Other)" } 
                                  elseif ($vm.OSProfile.LinuxConfiguration) { "Linux (Other)" }
                                  else { "Unknown" }
                        $osVersion = "$publisher/$osOffer/$osSku"
                    }
                } catch {
                    $osType = if ($vm.StorageProfile.OsDisk.OsType -eq "Windows") { "Windows (Custom)" } else { "Linux (Custom)" }
                }

                # If OS is still unresolved or weak (Custom/Other), try the os-version tag.
                # Expected tag formats: "Windows Server 2019", "Ubuntu 22.04", "RHEL 8", etc.
                $osSource = "Image"
                if ($osTagValue -and ($osType -eq "Unknown" -or $osVersion -eq "Unknown" -or
                    $osType -match "Custom|Other")) {
                    # Parse the os-version tag: expected formats like "Windows Server 2019",
                    # "Ubuntu 22.04", "RHEL 8", "CentOS 7", etc.
                    $tagLower = $osTagValue.ToLower()
                    if ($tagLower -match "windows.*server.*(\d{4}(\s*r2)?)") {
                        $osType = "Windows Server"; $osVersion = $Matches[1].Trim()
                    }
                    elseif ($tagLower -match "ubuntu.*(\d{2}\.\d{2})") {
                        $osType = "Ubuntu"; $osVersion = "$($Matches[1]) LTS"
                    }
                    elseif ($tagLower -match "rhel|red\s*hat") {
                        if ($tagLower -match "(\d+)") { $osType = "RHEL"; $osVersion = $Matches[1] }
                    }
                    elseif ($tagLower -match "centos") {
                        if ($tagLower -match "(\d+)") { $osType = "CentOS"; $osVersion = $Matches[1] }
                    }
                    elseif ($tagLower -match "debian") {
                        if ($tagLower -match "(\d+)") {
                            $osType = "Debian"
                            $debVer = $Matches[1]
                            $debName = switch ($debVer) { "10" { "10 Buster" } "11" { "11 Bullseye" } "12" { "12 Bookworm" } default { $debVer } }
                            $osVersion = $debName
                        }
                    }
                    elseif ($tagLower -match "sles|suse") {
                        if ($tagLower -match "(\d+\s*sp\d+)") { $osType = "SLES"; $osVersion = $Matches[1] }
                        elseif ($tagLower -match "(\d+)") { $osType = "SLES"; $osVersion = $Matches[1] }
                    }
                    else {
                        # Use raw tag value as-is
                        $osVersion = $osTagValue
                    }
                    $osSource = "Tag"
                }
                # Both image and tag available: use tag to refine/correct the image-detected version
                elseif ($osTagValue -and $osVersion -ne "Unknown") {
                    $osSource = "Image+Tag"
                    $tagLower = $osTagValue.ToLower()
                    if ($osType -eq "Ubuntu" -and $tagLower -match "(\d{2}\.\d{2})") {
                        $osVersion = "$($Matches[1]) LTS"
                    }
                    elseif ($osType -eq "Windows Server" -and $tagLower -match "(\d{4}(\s*r2)?)") {
                        $osVersion = $Matches[1].Trim()
                    }
                    elseif ($osType -match "Windows 1[01]" -and $tagLower -match "(enterprise|pro|ltsc)") {
                        $osVersion = (Get-Culture).TextInfo.ToTitleCase($Matches[1])
                    }
                    elseif ($osType -eq "RHEL" -and $tagLower -match "(\d+)") {
                        $osVersion = $Matches[1]
                    }
                    elseif ($osType -eq "Debian" -and $tagLower -match "(\d+)") {
                        $osVersion = $Matches[1]
                    }
                    elseif ($osType -eq "SLES" -and $tagLower -match "(\d+[\s\-_]*sp\d+)") {
                        $osVersion = $Matches[1] -replace '[\-_]',' '
                    }
                }

                # Match detected OS/version against lifecycle data.
                # Four progressive matching strategies are attempted:
                #   1. Exact match (Product + Version)
                #   2. Detected version starts with lifecycle version (e.g. "11 Bullseye" → "11")
                #   3. Lifecycle version starts with detected version (e.g. "24.04 LTS" → "24.04")
                #   4. Normalized comparison (strip spaces/dashes, case-insensitive)
                $eolDate     = ""
                $extEolDate  = ""
                $eolNotes    = ""
                $daysToEol   = 9999
                $riskLevel   = "Unknown"

                # Try exact match first, then progressively looser matches
                $match = $script:OSLifecycle | Where-Object { $_.Product -eq $osType -and $_.Version -eq $osVersion } | Select-Object -First 1
                if (-not $match) {
                    # Try: detected version starts with lifecycle version (e.g. "11 Bullseye" starts with "11")
                    $match = $script:OSLifecycle | Where-Object {
                        $_.Product -eq $osType -and $osVersion -match "^$([regex]::Escape($_.Version))(\s|$)"
                    } | Select-Object -First 1
                }
                if (-not $match) {
                    # Try: lifecycle version starts with detected version (e.g. API "24.04 LTS" matches detected "24.04")
                    $match = $script:OSLifecycle | Where-Object {
                        $_.Product -eq $osType -and $_.Version -match "^$([regex]::Escape($osVersion))(\s|$)"
                    } | Select-Object -First 1
                }
                if (-not $match) {
                    # Try: normalize both (remove spaces, dashes, case) and compare
                    $normVer = ($osVersion -replace '[\s\-_]','').ToLower()
                    $match = $script:OSLifecycle | Where-Object {
                        $_.Product -eq $osType -and (($_.Version -replace '[\s\-_]','').ToLower() -eq $normVer)
                    } | Select-Object -First 1
                }
                if ($match) {
                    $eolDate    = $match.EOL
                    $extEolDate = $match.Extended
                    $eolNotes   = $match.Notes
                    $daysToEol  = Get-DaysUntilEOL -EOLDate $match.Extended
                    $riskLevel  = Get-RiskLevel -DaysUntilEOL $daysToEol
                }

                $powerState = try { $vm.PowerState } catch { "Unknown" }
                $vmSize     = try { $vm.HardwareProfile.VmSize } catch { "" }

                $results.Add(@{
                    Subscription  = $sub.Name
                    Name          = $vm.Name
                    ResourceGroup = $vm.ResourceGroupName
                    Location      = $vm.Location
                    Size          = $vmSize
                    PowerState    = $powerState
                    OSType        = $osType
                    OSVersion     = $osVersion
                    ImageSku      = $osSku
                    OsTagValue    = $osTagValue
                    OsSource      = $osSource
                    EOLDate       = $eolDate
                    ExtendedEOL   = $extEolDate
                    DaysToEOL     = $daysToEol
                    RiskLevel     = $riskLevel
                    Notes         = $eolNotes
                    Category      = "OS"
                })
            }
        }
        catch {
            Write-Diag -Code "VMOS" -Level "WARN" -Message "VM scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "VMOS" -Level "INFO" -Message "Found $($results.Count) VMs scanned for OS obsolescence."
    return $results
}

# ==============================================================================
# 4b. APP SERVICE RUNTIME OBSOLESCENCE
# ==============================================================================
# Scans all App Services (Web Apps, Function Apps) for runtime version EOL.
# Detects runtime from LinuxFxVersion/WindowsFxVersion or config properties.
# Also checks TLS minimum version and HTTPS-only enforcement per app.
# Each app is matched against $RuntimeLifecycle (live API data or fallback)
# for EOL risk assessment.
function Get-AppServiceObsolescence {
    param([object[]]$Subscriptions)
    Write-Diag -Code "APPSVC" -Level "INFO" -Message "Scanning App Service runtimes..."
    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $webApps = Get-AzWebApp -ErrorAction SilentlyContinue

            foreach ($app in $webApps) {
                $runtime    = "Unknown"
                $runtimeVer = "Unknown"
                $stack      = ""

                try {
                    $config = $app.SiteConfig
                    # .NET
                    if ($config.NetFrameworkVersion -and $config.NetFrameworkVersion -ne "Off") {
                        $runtime = ".NET Framework"
                        $runtimeVer = $config.NetFrameworkVersion
                    }
                    # .NET Core / .NET 6+
                    # Linux/Windows FX version string (e.g. "DOTNET|8.0", "NODE|20", "PYTHON|3.12")
                    $linuxFx = $config.LinuxFxVersion
                    $winFx   = $config.WindowsFxVersion
                    $fxVer   = if ($linuxFx) { $linuxFx } elseif ($winFx) { $winFx } else { "" }

                    if ($fxVer -match "DOTNETCORE\|(\d+\.\d+)" -or $fxVer -match "DOTNET\|(\d+\.\d+)") {
                        $runtime = ".NET"; $runtimeVer = $Matches[1]
                    }
                    elseif ($fxVer -match "NODE\|(\d+)") {
                        $runtime = "Node.js"; $runtimeVer = $Matches[1]
                    }
                    elseif ($fxVer -match "PYTHON\|(\d+\.\d+)") {
                        $runtime = "Python"; $runtimeVer = $Matches[1]
                    }
                    elseif ($fxVer -match "JAVA\|(\d+)") {
                        $runtime = "Java"; $runtimeVer = $Matches[1]
                    }
                    elseif ($fxVer -match "PHP\|(\d+\.\d+)") {
                        $runtime = "PHP"; $runtimeVer = $Matches[1]
                    }

                    # SiteConfig individual properties (Windows apps, older API versions)
                    if ($config.PythonVersion -and $config.PythonVersion -ne "Off") {
                        $runtime = "Python"; $runtimeVer = $config.PythonVersion
                    }
                    # Java
                    if ($config.JavaVersion -and $config.JavaVersion -ne "Off") {
                        $runtime = "Java"; $runtimeVer = $config.JavaVersion
                    }
                    # PHP
                    if ($config.PhpVersion -and $config.PhpVersion -ne "Off" -and $config.PhpVersion -ne "") {
                        $runtime = "PHP"; $runtimeVer = $config.PhpVersion
                    }
                    # Node
                    if ($config.NodeVersion -and $config.NodeVersion -ne "") {
                        $runtime = "Node.js"; $runtimeVer = ($config.NodeVersion -replace "~","" -replace "^(\d+).*",'$1')
                    }

                    $stack = $fxVer
                } catch {}

                # Match lifecycle
                $eolDate   = ""
                $daysToEol = 9999
                $riskLevel = "Unknown"
                $eolNotes  = ""

                $match = $script:RuntimeLifecycle | Where-Object {
                    $_.Runtime -eq $runtime -and $runtimeVer -match "^$([regex]::Escape($_.Version))"
                } | Select-Object -First 1

                if ($match) {
                    $eolDate   = $match.EOL
                    $daysToEol = Get-DaysUntilEOL -EOLDate $match.EOL
                    $riskLevel = Get-RiskLevel -DaysUntilEOL $daysToEol
                    $eolNotes  = $match.Notes
                }

                # Check TLS
                $minTls    = try { $config.MinTlsVersion } catch { "" }
                $tlsStatus = "OK"
                if ($minTls -and $minTls -lt "1.2") { $tlsStatus = "Deprecated" }

                $httpsOnly = try { [bool]$app.HttpsOnly } catch { $false }
                $appKind   = try { $app.Kind } catch { "" }

                $results.Add(@{
                    Subscription  = $sub.Name
                    Name          = $app.Name
                    ResourceGroup = $app.ResourceGroup
                    Location      = $app.Location
                    Kind          = $appKind
                    Runtime       = $runtime
                    RuntimeVersion= $runtimeVer
                    Stack         = $stack
                    EOLDate       = $eolDate
                    DaysToEOL     = $daysToEol
                    RiskLevel     = $riskLevel
                    Notes         = $eolNotes
                    MinTLS        = $minTls
                    TLSStatus     = $tlsStatus
                    HttpsOnly     = $httpsOnly
                    Category      = "Runtime"
                })
            }
        }
        catch {
            Write-Diag -Code "APPSVC" -Level "WARN" -Message "App Service scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "APPSVC" -Level "INFO" -Message "Found $($results.Count) App Services scanned."
    return $results
}

# ==============================================================================
# 4c. AKS CLUSTER VERSION OBSOLESCENCE
# ==============================================================================
# Scans all AKS clusters for Kubernetes version currency.
# Extracts the major.minor version and matches against $AKSVersions
# (populated from the Azure ARM API, or the static fallback if that failed).
# Clusters running a version absent from the supported list are marked EOL.
# Node count is aggregated across all agent pools per cluster.
function Get-AKSObsolescence {
    param([object[]]$Subscriptions)
    Write-Diag -Code "AKS" -Level "INFO" -Message "Scanning AKS cluster versions..."
    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $clusters = Get-AzAksCluster -ErrorAction SilentlyContinue

            foreach ($cluster in $clusters) {
                $k8sVersion = try { $cluster.KubernetesVersion } catch { "" }
                $majorMinor = ""
                if ($k8sVersion -match "^(\d+\.\d+)") { $majorMinor = $Matches[1] }

                $eolDate   = ""
                $daysToEol = 9999
                $riskLevel = "Unknown"
                $eolNotes  = ""

                $match = $script:AKSVersions | Where-Object { $_.Version -eq $majorMinor } | Select-Object -First 1
                if ($match) {
                    $eolDate = $match.EOL
                    if ($eolDate) {
                        # Fallback list entry: has an explicit EOL date → calculate risk normally
                        $daysToEol = Get-DaysUntilEOL -EOLDate $eolDate
                        $riskLevel = Get-RiskLevel -DaysUntilEOL $daysToEol
                    } else {
                        # Live API entry: no EOL date means currently supported → Low risk
                        $daysToEol = 9999
                        $riskLevel = "Low"
                    }
                    $eolNotes = $match.Notes
                } else {
                    # Version not found in the supported list (live or fallback) → out of support
                    $riskLevel = "EOL"
                    $daysToEol = -1
                    $eolNotes  = "Out of support — not in Azure supported versions"
                }

                $nodeCount = 0
                try {
                    foreach ($pool in $cluster.AgentPoolProfiles) {
                        $nodeCount += $pool.Count
                    }
                } catch {}

                $results.Add(@{
                    Subscription    = $sub.Name
                    Name            = $cluster.Name
                    ResourceGroup   = $cluster.ResourceGroupName
                    Location        = $cluster.Location
                    K8sVersion      = $k8sVersion
                    K8sMinorVersion = $majorMinor
                    NodeCount       = $nodeCount
                    EOLDate         = $eolDate
                    DaysToEOL       = $daysToEol
                    RiskLevel       = $riskLevel
                    Notes           = $eolNotes
                    Category        = "Kubernetes"
                })
            }
        }
        catch {
            Write-Diag -Code "AKS" -Level "WARN" -Message "AKS scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "AKS" -Level "INFO" -Message "Found $($results.Count) AKS clusters scanned."
    return $results
}

# ==============================================================================
# 4d. SQL DATABASE VERSION & TLS
# ==============================================================================
# Scans Azure SQL Servers and their databases.
# Checks server version, minimum TLS setting, and SKU/edition.
# Note: Azure SQL Database is a fully managed PaaS service — Microsoft handles
# engine version lifecycle. Most entries will be Low risk unless TLS is deprecated.
function Get-SQLObsolescence {
    param([object[]]$Subscriptions)
    Write-Diag -Code "SQL" -Level "INFO" -Message "Scanning SQL resources..."
    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null

            # Azure SQL Servers
            $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
            foreach ($server in $sqlServers) {
                $serverVersion = try { $server.ServerVersion } catch { "" }
                $minTls        = try { $server.MinimalTlsVersion } catch { "" }
                $tlsStatus     = if ($minTls -and $minTls -lt "1.2") { "Deprecated" } else { "OK" }

                $dbs = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.DatabaseName -ne "master" }

                foreach ($db in $dbs) {
                    $sku     = try { $db.SkuName } catch { "" }
                    $edition = try { $db.Edition } catch { "" }

                    $dbRiskLevel = if ($tlsStatus -eq "Deprecated") { "High" } else { "Low" }
                    $dbNotes     = if ($tlsStatus -eq "Deprecated") { "TLS < 1.2 deprecated" } else { "Azure SQL — managed lifecycle" }

                    $results.Add(@{
                        Subscription  = $sub.Name
                        ServerName    = $server.ServerName
                        DatabaseName  = $db.DatabaseName
                        ResourceGroup = $server.ResourceGroupName
                        Location      = $server.Location
                        ServerVersion = $serverVersion
                        SKU           = $sku
                        Edition       = $edition
                        MinTLS        = $minTls
                        TLSStatus     = $tlsStatus
                        DaysToEOL     = 9999
                        RiskLevel     = $dbRiskLevel
                        Notes         = $dbNotes
                        Category      = "SQL"
                    })
                }
            }
        }
        catch {
            Write-Diag -Code "SQL" -Level "WARN" -Message "SQL scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "SQL" -Level "INFO" -Message "Found $($results.Count) SQL databases scanned."
    return $results
}

# ==============================================================================
# 4e. AZURE ADVISOR SERVICE RETIREMENT RECOMMENDATIONS
# ==============================================================================
# Mirrors the data sources used by the Azure Advisor Service Retirement Workbook:
#   Step 1 — Advisor Metadata API: fetches the full catalog of retiring services
#            (retirement dates, feature names, migration links). Tenant-scoped,
#            no subscription context needed.
#   Step 2 — Advisor Recommendations API: retrieves impacted resources per
#            subscription, filtered on SubCategory = ServiceUpgradeAndRetirement.
#            Paginates up to 20 pages per subscription. Falls back to API version
#            2023-01-01 if the 2025 version is unavailable.
#   Step 3 — Azure Resource Graph (advisorresources): cross-subscription query
#            as a supplementary source to catch recommendations missed by Step 2.
#            Results are deduplicated against Step 2 output.
# No hardcoded retirement list — all data is fetched live from Azure Advisor.
function Get-AdvisorDeprecations {
    param([object[]]$Subscriptions)
    Write-Diag -Code "RETIRE" -Level "INFO" -Message "Retrieving Service Retirement data (Advisor Workbook method)..."
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $seen    = @{}

    # ── Step 1: Advisor Metadata API — tenant-level catalog of retiring services ──
    $retirementCatalog = @{} # keyed by recommendationTypeId → { displayName, retirementDate, retirementFeatureName, learnMoreLink, supportedResourceType }
    Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [1] Fetching Advisor Metadata (retirement catalog)..."
    try {
        $metaFilter = "recommendationCategory eq 'HighAvailability' and recommendationSubCategory eq 'ServiceUpgradeAndRetirement'"
        $metaFilterEnc = [uri]::EscapeDataString($metaFilter)
        $metaApiPath = "/providers/Microsoft.Advisor/metadata?api-version=2025-01-01&`$filter=$metaFilterEnc&`$expand=ibiza"
        $metaResp = Invoke-AzRestMethod -Path $metaApiPath -Method GET -ErrorAction SilentlyContinue

        if ($metaResp -and $metaResp.StatusCode -eq 200) {
            $metaBody = $metaResp.Content | ConvertFrom-Json
            if ($metaBody.value -and $metaBody.value.Count -gt 0) {
                $supportedValues = $metaBody.value[0].properties.supportedValues
                if ($supportedValues) {
                    foreach ($sv in $supportedValues) {
                        $typeId = try { [string]$sv.id } catch { "" }
                        if (-not $typeId) { continue }

                        $displayName = try { [string]$sv.displayName } catch { "" }
                        $retDate     = ""
                        $featureName = ""
                        $link        = ""
                        $resType     = try { [string]$sv.supportedResourceType } catch { "" }

                        try {
                            $sp = $sv.sourceProperties.serviceRetirement
                            if ($sp) {
                                $retDate     = try { [string]$sp.retirementDate } catch { "" }
                                $featureName = try { [string]$sp.retirementFeatureName } catch { "" }
                            }
                        } catch {}

                        try { $link = [string]$sv.learnMoreLink } catch {}

                        $retirementCatalog[$typeId] = @{
                            DisplayName    = $displayName
                            FeatureName    = $featureName
                            RetireDate     = $retDate
                            LearnMoreLink  = $link
                            ResourceType   = $resType
                        }
                    }
                }
            }
            Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [1] Catalog: $($retirementCatalog.Count) retiring services/features loaded."
        } else {
            Write-Diag -Code "RETIRE" -Level "WARN" -Message "  [1] Metadata API returned $($metaResp.StatusCode). Trying without expand..."
            # Retry without $expand=ibiza
            $metaApiPath2 = "/providers/Microsoft.Advisor/metadata?api-version=2025-01-01&`$filter=$metaFilterEnc"
            $metaResp2 = Invoke-AzRestMethod -Path $metaApiPath2 -Method GET -ErrorAction SilentlyContinue
            if ($metaResp2 -and $metaResp2.StatusCode -eq 200) {
                $metaBody2 = $metaResp2.Content | ConvertFrom-Json
                if ($metaBody2.value -and $metaBody2.value.Count -gt 0) {
                    $supportedValues2 = $metaBody2.value[0].properties.supportedValues
                    if ($supportedValues2) {
                        foreach ($sv in $supportedValues2) {
                            $typeId = try { [string]$sv.id } catch { "" }
                            if (-not $typeId) { continue }
                            $displayName = try { [string]$sv.displayName } catch { "" }
                            $retDate = ""
                            $featureName = ""
                            $link = ""
                            $resType = try { [string]$sv.supportedResourceType } catch { "" }
                            try { $sp = $sv.sourceProperties.serviceRetirement; if ($sp) { $retDate = try { [string]$sp.retirementDate } catch { "" }; $featureName = try { [string]$sp.retirementFeatureName } catch { "" } } } catch {}
                            try { $link = [string]$sv.learnMoreLink } catch {}
                            $retirementCatalog[$typeId] = @{ DisplayName=$displayName; FeatureName=$featureName; RetireDate=$retDate; LearnMoreLink=$link; ResourceType=$resType }
                        }
                    }
                }
                Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [1] Catalog (retry): $($retirementCatalog.Count) loaded."
            }
        }
    }
    catch {
        Write-Diag -Code "RETIRE" -Level "WARN" -Message "  [1] Metadata API failed: $_"
    }

    # ── Step 2: Advisor Recommendations API — impacted resources per subscription ──
    Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [2] Fetching impacted resources per subscription..."
    $totalRecs = 0

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null

            $filter = "Category eq 'HighAvailability' and SubCategory eq 'ServiceUpgradeAndRetirement'"
            $filterEnc = [uri]::EscapeDataString($filter)
            $apiPath = "/subscriptions/$($sub.Id)/providers/Microsoft.Advisor/recommendations?api-version=2025-01-01&`$filter=$filterEnc&`$expand=resourceMetadata"
            $subCount = 0
            $pageNum  = 0

            while ($apiPath -and $pageNum -lt 20) {
                $pageNum++
                $resp = Invoke-AzRestMethod -Path $apiPath -Method GET -ErrorAction SilentlyContinue
                if (-not $resp -or $resp.StatusCode -ne 200) {
                    # Fallback to 2023-01-01 API version
                    if ($pageNum -eq 1) {
                        $apiPath = "/subscriptions/$($sub.Id)/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01&`$expand=resourceMetadata"
                        $resp = Invoke-AzRestMethod -Path $apiPath -Method GET -ErrorAction SilentlyContinue
                        if (-not $resp -or $resp.StatusCode -ne 200) {
                            Write-Diag -Code "RETIRE" -Level "WARN" -Message "  [2] API failed for '$($sub.Name)': $($resp.StatusCode)"
                            break
                        }
                    } else { break }
                }

                $body = $resp.Content | ConvertFrom-Json
                if ($body.value) {
                    foreach ($rec in $body.value) {
                        $p = $rec.properties

                        # Filter for ServiceUpgradeAndRetirement (needed when using 2023-01-01 fallback)
                        $recSubCat = ""
                        try { $recSubCat = [string]$p.extendedProperties.recommendationSubCategory } catch {}
                        if (-not $recSubCat) { try { $recSubCat = [string]$p.subCategory } catch {} }
                        # For 2023 API, also check recommendationControl
                        if (-not $recSubCat) { try { $recSubCat = [string]$p.extendedProperties.recommendationControl } catch {} }
                        if ($recSubCat -and $recSubCat -ne "ServiceUpgradeAndRetirement") { continue }

                        $recTypeId     = try { [string]$p.recommendationTypeId } catch { "" }
                        $impactedField = try { [string]$p.impactedField } catch { "" }
                        $impactedValue = try { [string]$p.impactedValue } catch { "" }
                        $resourceId    = try { [string]$p.resourceMetadata.resourceId } catch { "" }
                        $problem       = try { [string]$p.shortDescription.problem } catch { "" }
                        $solution      = try { [string]$p.shortDescription.solution } catch { "" }
                        $impact        = try { [string]$p.impact } catch { "" }

                        # Enrich with retirement date and migration link from the catalog
                        $retireDate   = ""
                        $featureName  = ""
                        $learnMoreLink = ""
                        if ($recTypeId -and $retirementCatalog.ContainsKey($recTypeId)) {
                            $cat = $retirementCatalog[$recTypeId]
                            $retireDate    = $cat["RetireDate"]
                            $featureName   = $cat["FeatureName"]
                            $learnMoreLink = $cat["LearnMoreLink"]
                            if (-not $problem) { $problem = $cat["DisplayName"] }
                        }

                        # Fallback: extract date/feature from extendedProperties if not in catalog
                        if (-not $retireDate) {
                            try { $retireDate = [string]$p.extendedProperties.retirementDate } catch {}
                        }
                        if (-not $featureName) {
                            try { $featureName = [string]$p.extendedProperties.retirementFeatureName } catch {}
                        }
                        if (-not $learnMoreLink) {
                            try {
                                $ext = $p.extendedProperties
                                if ($ext) {
                                    $extProps = $ext.PSObject.Properties
                                    foreach ($prop in $extProps) {
                                        if ([string]$prop.Value -match "^https?://") { $learnMoreLink = [string]$prop.Value; break }
                                    }
                                }
                            } catch {}
                        }

                        # Resource details
                        $resourceName = $impactedValue
                        if (-not $resourceName -and $resourceId) { $resourceName = ($resourceId -split "/")[-1] }
                        $resourceGroup = ""
                        if ($resourceId -match "/resourceGroups/([^/]+)") { $resourceGroup = $Matches[1] }

                        # Use featureName as the problem if more descriptive
                        $displayProblem = if ($featureName -and $featureName.Length -gt 5) { $featureName } else { $problem }
                        if (-not $displayProblem) { $displayProblem = "Service retirement" }

                        $daysToRetire = 9999
                        if ($retireDate) { $daysToRetire = Get-DaysUntilEOL -EOLDate $retireDate }
                        $riskLevel = if ($retireDate -and $daysToRetire -ne 9999) {
                            Get-RiskLevel -DaysUntilEOL $daysToRetire
                        } else { if ($impact -eq "High") { "High" } else { "Medium" } }

                        # Classify VM SKU vs general
                        $subCategory = "Service Retirement"
                        if ($impactedField -match "Microsoft\.Compute/virtualMachines") {
                            $subCategory = "VM SKU Deprecation"
                        }

                        $dedupKey = "$($sub.Id)|$resourceId|$recTypeId"
                        if ($seen.ContainsKey($dedupKey)) { continue }
                        $seen[$dedupKey] = $true

                        $serviceField = if ($impactedField) { $impactedField } else { $featureName }

                        $results.Add(@{
                            Subscription    = $sub.Name
                            Service         = $serviceField
                            ResourceName    = $resourceName
                            ResourceGroup   = $resourceGroup
                            ResourceId      = $resourceId
                            Detail          = $displayProblem
                            Solution        = $solution
                            RetireDate      = $retireDate
                            DaysToRetire    = $daysToRetire
                            Impact          = $impact
                            RiskLevel       = $riskLevel
                            LearnMoreLink   = $learnMoreLink
                            SubCategory     = $subCategory
                            AdvisorCategory = "HighAvailability"
                            Category        = "Service Retirement"
                        })
                        $subCount++
                    }
                }

                $apiPath = $null
                $nl = $null
                try { $nl = $body.PSObject.Properties["nextLink"]; if ($nl) { $nl = $nl.Value } } catch {}
                if ($nl) {
                    try { $apiPath = ([uri]$nl).PathAndQuery } catch {}
                }
            }
            $totalRecs += $subCount
            Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [2] '$($sub.Name)': $subCount impacted resources."
        }
        catch {
            Write-Diag -Code "RETIRE" -Level "WARN" -Message "  [2] Failed '$($sub.Name)': $_"
        }
    }

    # ── Step 3: Azure Resource Graph — supplementary cross-subscription query ──
    Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [3] ARG advisorresources query..."
    $argCount = 0
    try {
        $allSubIds = @($Subscriptions | ForEach-Object { $_.Id })
        $argQuery = "advisorresources " +
            "| where type == 'microsoft.advisor/recommendations' " +
            "| where tostring(properties.category) has 'HighAvailability' " +
            "| where properties.extendedProperties.recommendationSubCategory == 'ServiceUpgradeAndRetirement' " +
            "   or properties.extendedProperties.recommendationControl == 'ServiceUpgradeAndRetirement' " +
            "| extend resourceId = tolower(tostring(properties.resourceMetadata.resourceId)) " +
            "| project subscriptionId, resourceGroup, resourceId, " +
            "    impactedValue = tostring(properties.impactedValue), " +
            "    impactedField = tostring(properties.impactedField), " +
            "    problem = tostring(properties.shortDescription.problem), " +
            "    solution = tostring(properties.shortDescription.solution), " +
            "    impact = tostring(properties.impact), " +
            "    recommendationTypeId = tostring(properties.recommendationTypeId), " +
            "    retirementDate = tostring(properties.extendedProperties.retirementDate), " +
            "    retirementFeature = tostring(properties.extendedProperties.retirementFeatureName)"
        $argBody = @{ subscriptions = $allSubIds; query = $argQuery } | ConvertTo-Json -Depth 4
        $argApiPath = "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
        $argResp = Invoke-AzRestMethod -Path $argApiPath -Method POST -Payload $argBody -ErrorAction SilentlyContinue

        if ($argResp -and $argResp.StatusCode -eq 200) {
            $argData = ($argResp.Content | ConvertFrom-Json).data
            if ($argData) {
                foreach ($row in $argData) {
                    $subId   = try { [string]$row.subscriptionId } catch { "" }
                    $resId   = try { [string]$row.resourceId } catch { "" }
                    $recType = try { [string]$row.recommendationTypeId } catch { "" }

                    $dedupKey = "$subId|$resId|$recType"
                    if ($seen.ContainsKey($dedupKey)) { continue }
                    $seen[$dedupKey] = $true

                    $subName = ""
                    $subMatch = $Subscriptions | Where-Object { $_.Id -eq $subId } | Select-Object -First 1
                    if ($subMatch) { $subName = $subMatch.Name } else { $subName = $subId }

                    $impVal    = try { [string]$row.impactedValue } catch { "" }
                    $impField  = try { [string]$row.impactedField } catch { "" }
                    $problem   = try { [string]$row.problem } catch { "" }
                    $solution  = try { [string]$row.solution } catch { "" }
                    $retDate   = try { [string]$row.retirementDate } catch { "" }
                    $retFeat   = try { [string]$row.retirementFeature } catch { "" }
                    $rg        = try { [string]$row.resourceGroup } catch { "" }
                    $impact    = try { [string]$row.impact } catch { "" }

                    # Enrich from catalog
                    $link = ""
                    if ($recType -and $retirementCatalog.ContainsKey($recType)) {
                        $cat = $retirementCatalog[$recType]
                        if (-not $retDate) { $retDate = $cat["RetireDate"] }
                        if (-not $retFeat) { $retFeat = $cat["FeatureName"] }
                        $link = $cat["LearnMoreLink"]
                        if (-not $problem) { $problem = $cat["DisplayName"] }
                    }

                    $resourceName = $impVal
                    if (-not $resourceName -and $resId) { $resourceName = ($resId -split "/")[-1] }
                    $displayProblem = if ($retFeat -and $retFeat.Length -gt 5) { $retFeat } else { $problem }

                    $daysToRetire = 9999
                    if ($retDate) { $daysToRetire = Get-DaysUntilEOL -EOLDate $retDate }
                    $riskLevel = if ($retDate -and $daysToRetire -ne 9999) { Get-RiskLevel -DaysUntilEOL $daysToRetire } else { "Medium" }

                    $subCat = "Service Retirement"
                    if ($impField -match "Microsoft\.Compute/virtualMachines") { $subCat = "VM SKU Deprecation" }

                    $serviceField2 = if ($impField) { $impField } else { $retFeat }

                    $results.Add(@{
                        Subscription    = $subName
                        Service         = $serviceField2
                        ResourceName    = $resourceName
                        ResourceGroup   = $rg
                        ResourceId      = $resId
                        Detail          = $displayProblem
                        Solution        = $solution
                        RetireDate      = $retDate
                        DaysToRetire    = $daysToRetire
                        Impact          = $impact
                        RiskLevel       = $riskLevel
                        LearnMoreLink   = $link
                        SubCategory     = $subCat
                        AdvisorCategory = "HighAvailability"
                        Category        = "Service Retirement"
                    })
                    $argCount++
                }
            }
        }
        Write-Diag -Code "RETIRE" -Level "INFO" -Message "  [3] ARG: $argCount new resources."
    }
    catch {
        Write-Diag -Code "RETIRE" -Level "WARN" -Message "  [3] ARG failed: $_"
    }

    Write-Diag -Code "RETIRE" -Level "INFO" -Message "Service Retirement total: $($results.Count) impacted resources (catalog: $($retirementCatalog.Count) services, API: $totalRecs, ARG: $argCount)."
    return $results
}

# ==============================================================================
# 4f / 4h. VM SKU DEPRECATION
# ==============================================================================
# Builds a deduplicated view of VMs with deprecated SKU series.
# Does NOT use a hardcoded list of deprecated SKUs — all data comes from:
#   1. Advisor results (from 4e) filtered on Detail containing "series"/"SKU"/"deprecat"
#      and impactedField = Microsoft.Compute/virtualMachines.
#   2. Azure Resource Graph advisorresources (same filter, catches recommendations
#      that may not appear in the standard Advisor REST API per subscription).
# Exclusion: "Right-size", "underutilized", "Shutdown" recommendations are filtered
# out to avoid conflating cost/performance recommendations with deprecation notices.
# Dedup key: subscription + VM name (case-insensitive). Advisor (Step 1) takes
# priority over ARG (Step 2) for the same VM when both sources return a record.
# VM inventory ($VMInventory from 4a) is used to enrich results with the current SKU.
function Get-VMSKUDeprecations {
    param([object[]]$Subscriptions, [object[]]$VMInventory, [object[]]$AdvisorData)
    Write-Diag -Code "VMSKU" -Level "INFO" -Message "Building VM SKU deprecation view from Advisor data..."
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $seen    = @{}

    # ── Step 1: Filter VM SKU deprecations from Advisor results ──────────────
    $vmSkuRecs = $AdvisorData | Where-Object {
        $h = [hashtable]$_
        ($h["Detail"] -match "(?i)series|SKU|deprecat") -and
        ($h["Detail"] -notmatch "(?i)right.size|underutilized|shutdown") -and (
            $h["Service"] -match "Microsoft\.Compute/virtualMachines" -or
            $h["ResourceId"] -match "Microsoft\.Compute/virtualMachines" -or
            $h["Service"] -match "virtualMachines"
        )
    }
    Write-Diag -Code "VMSKU" -Level "INFO" -Message "  Found $(@($vmSkuRecs).Count) VM SKU deprecation recommendations from Advisor."

    foreach ($recRaw in $vmSkuRecs) {
        $rec = [hashtable]$recRaw
        $resourceId   = $rec["ResourceId"]
        $resourceName = $rec["ResourceName"]
        $subName      = $rec["Subscription"]

        # Enrich with actual VM size from the inventory scan
        $vmSku    = ""
        $vmRG     = $rec["ResourceGroup"]
        $vmMatch  = $VMInventory | Where-Object {
            $h = [hashtable]$_
            ($h["Name"] -eq $resourceName -and $h["Subscription"] -eq $subName) -or
            ($resourceId -and $h["Name"] -and $resourceId -match $h["Name"])
        } | Select-Object -First 1

        if ($vmMatch) {
            $vmH   = [hashtable]$vmMatch
            $vmSku = $vmH["Size"]
            if (-not $vmRG) { $vmRG = $vmH["ResourceGroup"] }
        }

        $dedupKey = ("$subName|$resourceName").ToLower()
        if ($seen.ContainsKey($dedupKey)) { continue }
        $seen[$dedupKey] = $true

        $results.Add(@{
            Subscription   = $subName
            VMName         = $resourceName
            ResourceGroup  = $vmRG
            CurrentSKU     = $vmSku
            Problem        = $rec["Detail"]
            Solution       = $rec["Solution"]
            RetireDate     = $rec["RetireDate"]
            DaysToRetire   = $rec["DaysToRetire"]
            RiskLevel      = $rec["RiskLevel"]
            LearnMoreLink  = $rec["LearnMoreLink"]
            Category       = "VM SKU Deprecation"
        })
    }

    # ── Also scan Azure Resource Graph for VM SKU retirement advisories ──
    # This catches recommendations that might not appear in the standard Advisor API
    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null

            $argQuery = "advisorresources " +
                "| where type == 'microsoft.advisor/recommendations' " +
                "| where properties.impactedField =~ 'Microsoft.Compute/virtualMachines' " +
                "| where properties.shortDescription.problem contains 'series' or properties.shortDescription.problem contains 'Series' or properties.shortDescription.problem contains 'SKU' or properties.shortDescription.problem contains 'deprecat' " +
                "| where properties.shortDescription.problem !contains 'Right-size' and properties.shortDescription.problem !contains 'underutilized' and properties.shortDescription.problem !contains 'Shutdown' " +
                "| project subscriptionId, resourceGroup, name=properties.impactedValue, problem=properties.shortDescription.problem, solution=properties.shortDescription.solution, impact=properties.impact, extendedProperties=properties.extendedProperties, resourceId=properties.resourceMetadata.resourceId"

            $argResult = $null
            try {
                $argApiPath = "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
                $argBody = @{
                    subscriptions = @($sub.Id)
                    query = $argQuery
                } | ConvertTo-Json -Depth 4
                $argResp = Invoke-AzRestMethod -Path $argApiPath -Method POST -Payload $argBody -ErrorAction SilentlyContinue
                if ($argResp -and $argResp.StatusCode -eq 200) {
                    $argResult = ($argResp.Content | ConvertFrom-Json).data
                }
            } catch {
                Write-Diag -Code "VMSKU" -Level "WARN" -Message "  ARG query failed for '$($sub.Name)': $_"
            }

            if ($argResult) {
                foreach ($row in $argResult) {
                    $vmName = try { [string]$row.name } catch { "" }
                    if (-not $vmName) { continue }

                    $rId = try { [string]$row.resourceId } catch { "" }
                    if ($rId -and $rId -notmatch "Microsoft\.Compute/virtualMachines") { continue }

                    # Advisor data takes priority — skip if already added from Step 1
                    $dedupKey = ("$($sub.Name)|$vmName").ToLower()
                    if ($seen.ContainsKey($dedupKey)) { continue }
                    $seen[$dedupKey] = $true

                    $problem  = try { [string]$row.problem } catch { "" }
                    $solution = try { [string]$row.solution } catch { "" }
                    $rId      = try { [string]$row.resourceId } catch { "" }
                    $rg       = ""
                    if ($rId -match "/resourceGroups/([^/]+)") { $rg = $Matches[1] }

                    # Get SKU from VM inventory
                    $vmSku = ""
                    $vmMatch = $VMInventory | Where-Object {
                        ([hashtable]$_)["Name"] -eq $vmName -and ([hashtable]$_)["Subscription"] -eq $sub.Name
                    } | Select-Object -First 1
                    if ($vmMatch) { $vmSku = ([hashtable]$vmMatch)["Size"] }

                    # Try to extract a retirement date from extendedProperties
                    $retireDate = ""
                    try {
                        $ext = $row.extendedProperties
                        if ($ext) {
                            $extProps = $ext.PSObject.Properties
                            foreach ($prop in $extProps) {
                                $keyLower = $prop.Name.ToLower()
                                if ($keyLower -match "date|retire|eol|end") {
                                    try {
                                        $parsed = [datetime]::Parse([string]$prop.Value)
                                        if ($parsed.Year -ge 2024) { $retireDate = $parsed.ToString("yyyy-MM-dd"); break }
                                    } catch {}
                                }
                            }
                        }
                    } catch {}

                    # Fallback: extract date from the problem/solution text
                    if (-not $retireDate) {
                        $fullText = "$problem $solution"
                        if ($fullText -match '(\d{4})-(\d{2})-(\d{2})') {
                            try {
                                $parsed = [datetime]::Parse($Matches[0])
                                if ($parsed.Year -ge 2024) { $retireDate = $parsed.ToString("yyyy-MM-dd") }
                            } catch {}
                        }
                    }

                    $daysToRetire = if ($retireDate) { Get-DaysUntilEOL -EOLDate $retireDate } else { 9999 }
                    $riskLevel = if ($retireDate) { Get-RiskLevel -DaysUntilEOL $daysToRetire } else { "Medium" }

                    # Extract link
                    $link = ""
                    try {
                        if ($row.extendedProperties) {
                            $extProps = $row.extendedProperties.PSObject.Properties
                            foreach ($prop in $extProps) {
                                if ([string]$prop.Value -match "^https?://") { $link = [string]$prop.Value; break }
                            }
                        }
                    } catch {}

                    $results.Add(@{
                        Subscription   = $sub.Name
                        VMName         = $vmName
                        ResourceGroup  = $rg
                        CurrentSKU     = $vmSku
                        Problem        = $problem
                        Solution       = $solution
                        RetireDate     = $retireDate
                        DaysToRetire   = $daysToRetire
                        RiskLevel      = $riskLevel
                        LearnMoreLink  = $link
                        Category       = "VM SKU Deprecation"
                    })
                }
            }
        }
        catch {
            Write-Diag -Code "VMSKU" -Level "WARN" -Message "VM SKU ARG scan failed '$($sub.Name)': $_"
        }
    }

    Write-Diag -Code "VMSKU" -Level "INFO" -Message "Found $($results.Count) VM SKU deprecations (Advisor + ARG)."
    return $results
}

# ==============================================================================
# 4f. DEPRECATED API VERSIONS SCAN (placeholder)
# ==============================================================================
# Currently a placeholder — iterates resources and resolves latest stable API
# versions from the ARM provider registry but does not emit results.
# Intended for a future release that flags resources deployed with outdated
# or preview API versions.
function Get-APIVersionObsolescence {
    param([object[]]$Subscriptions)
    Write-Diag -Code "APIVER" -Level "INFO" -Message "Scanning ARM API version freshness..."
    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null

            # Get all resources and check if they use preview or old API versions
            $resources = Get-AzResource -ErrorAction SilentlyContinue

            foreach ($res in $resources) {
                $resType = $res.ResourceType
                $apiVer  = ""

                try {
                    # Get latest stable API version for this resource type
                    $provider = $resType.Split("/")[0]
                    $typeName = $resType.Substring($provider.Length + 1)
                    $provInfo = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
                    $typeInfo = $provInfo.ResourceTypes | Where-Object { $_.ResourceTypeName -eq $typeName } | Select-Object -First 1

                    if ($typeInfo -and $typeInfo.ApiVersions) {
                        $latestStable = $typeInfo.ApiVersions | Where-Object { $_ -notmatch "preview" } | Select-Object -First 1
                        $latestAny    = $typeInfo.ApiVersions | Select-Object -First 1
                        $apiVer = if ($latestStable) { $latestStable } else { $latestAny }
                    }
                } catch {}
            }
        }
        catch {
            Write-Diag -Code "APIVER" -Level "WARN" -Message "API version scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "APIVER" -Level "INFO" -Message "API version scan complete."
    return $results
}

# ==============================================================================
# 4g. TLS/SSL COMPLIANCE SCAN
# ==============================================================================
# Checks TLS minimum version on: Storage Accounts, Application Gateways, Redis Cache.
# Any resource with TLS < 1.2 is flagged as "Deprecated" with Critical/High risk.
# App Service TLS is checked separately in 4b (Get-AppServiceObsolescence).
function Get-TLSCompliance {
    param([object[]]$Subscriptions)
    Write-Diag -Code "TLS" -Level "INFO" -Message "Scanning TLS compliance..."
    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null

            # Storage Accounts: MinimumTlsVersion must be TLS1_2 or higher
            $storageAccounts = Get-AzStorageAccount -ErrorAction SilentlyContinue
            foreach ($sa in $storageAccounts) {
                $minTls = try { $sa.MinimumTlsVersion } catch { "" }
                $status = "OK"
                $risk   = "Low"
                if (-not $minTls -or $minTls -eq "TLS1_0" -or $minTls -eq "TLS1_1") {
                    $status = "Deprecated"
                    $risk   = "Critical"
                }

                $saMinTlsDisp = if ($minTls) { $minTls } else { "Not set (default)" }
                $saNotes      = if ($status -eq "Deprecated") { "TLS 1.0/1.1 deprecated — upgrade to TLS 1.2" } else { "Compliant" }

                $results.Add(@{
                    Subscription  = $sub.Name
                    ResourceType  = "Storage Account"
                    Name          = $sa.StorageAccountName
                    ResourceGroup = $sa.ResourceGroupName
                    Location      = $sa.Location
                    MinTLS        = $saMinTlsDisp
                    Status        = $status
                    RiskLevel     = $risk
                    Notes         = $saNotes
                    Category      = "TLS"
                })
            }

            # Application Gateways: flag old SSL policies (AppGwSslPolicy20150501) or TLS < 1.2
            $appGws = Get-AzApplicationGateway -ErrorAction SilentlyContinue
            foreach ($gw in $appGws) {
                $sslPolicy   = try { $gw.SslPolicy.PolicyType } catch { "" }
                $sslPolicyName = try { $gw.SslPolicy.PolicyName } catch { "" }
                $minProtocol = try { $gw.SslPolicy.MinProtocolVersion } catch { "" }
                $status = "OK"
                $risk   = "Low"

                if ($minProtocol -match "TLSv1_0|TLSv1_1" -or $sslPolicyName -match "AppGwSslPolicy20150501") {
                    $status = "Deprecated"
                    $risk   = "High"
                }

                $gwMinTlsDisp = if ($minProtocol) { $minProtocol } else { $sslPolicyName }
                $gwNotes      = if ($status -eq "Deprecated") { "Old SSL policy — upgrade to TLS 1.2+" } else { "Compliant" }

                $results.Add(@{
                    Subscription  = $sub.Name
                    ResourceType  = "Application Gateway"
                    Name          = $gw.Name
                    ResourceGroup = $gw.ResourceGroupName
                    Location      = $gw.Location
                    MinTLS        = $gwMinTlsDisp
                    Status        = $status
                    RiskLevel     = $risk
                    Notes         = $gwNotes
                    Category      = "TLS"
                })
            }

            # Check Key Vaults (TLS is always 1.2 for KV, but check certificates expiry)
            # Redis Cache TLS
            try {
                $redisCaches = Get-AzRedisCache -ErrorAction SilentlyContinue
                foreach ($redis in $redisCaches) {
                    $minTls = try { $redis.MinimumTlsVersion } catch { "" }
                    $status = "OK"
                    $risk   = "Low"
                    if ($minTls -and $minTls -lt "1.2") {
                        $status = "Deprecated"; $risk = "High"
                    }
                    $redisMinTlsDisp = if ($minTls) { $minTls } else { "Not set" }
                    $redisNotes      = if ($status -eq "Deprecated") { "TLS < 1.2 — upgrade required" } else { "Compliant" }
                    $results.Add(@{
                        Subscription  = $sub.Name
                        ResourceType  = "Redis Cache"
                        Name          = $redis.Name
                        ResourceGroup = $redis.ResourceGroupName
                        Location      = $redis.Location
                        MinTLS        = $redisMinTlsDisp
                        Status        = $status
                        RiskLevel     = $risk
                        Notes         = $redisNotes
                        Category      = "TLS"
                    })
                }
            } catch {}
        }
        catch {
            Write-Diag -Code "TLS" -Level "WARN" -Message "TLS scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "TLS" -Level "INFO" -Message "Found $($results.Count) resources scanned for TLS."
    return $results
}

# ==============================================================================
# 4i. LIFECYCLE TAG TRACKING
# ==============================================================================
# Scans all Resource Groups for the presence and validity of a configurable tag
# (default: "lifecycle", format: "MM.yyyy"). Tag status is assessed as:
#   Missing   — RG has no such tag
#   Empty     — tag exists but value is blank
#   Bad format — value does not match the expected date format
#   Expired   — date is in the past
#   Imminent  — date is within $LifecycleTagWarningDays (< 90d)
#   Approaching — date is within $LifecycleTagCautionDays (< 180d)
#   Too far   — date is more than $LifecycleTagMaxYears in the future
#   OK        — date is between caution threshold and max years
# Subscriptions and RGs matching the exclude patterns are skipped entirely.
function Get-LifecycleTagCompliance {
    param([object[]]$Subscriptions)
    Write-Diag -Code "LCTAG" -Level "INFO" -Message "Scanning lifecycle tag '$($script:LifecycleTagName)' on Resource Groups..."
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $tagName = $script:LifecycleTagName
    $fmt     = $script:LifecycleTagFormat

    foreach ($sub in $Subscriptions) {
        # Skip excluded subscriptions
        if ($script:LifecycleTagExcludeSubs -and $sub.Name -match $script:LifecycleTagExcludeSubs) { continue }

        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $rgs = Get-AzResourceGroup -ErrorAction SilentlyContinue

            foreach ($rg in $rgs) {
                $rgName = $rg.ResourceGroupName

                # Skip excluded RGs
                if ($script:LifecycleTagExcludeRGs -and $rgName -match $script:LifecycleTagExcludeRGs) { continue }

                $tagValue  = ""
                $tagStatus = "Missing"
                $parsedDate = $null
                $daysLeft   = 9999
                $riskLevel  = "High"

                # Check if tag exists
                $rgTags = $rg.Tags
                if ($rgTags) {
                    $found = $false
                    foreach ($key in $rgTags.Keys) {
                        if ($key -ieq $tagName) {
                            $tagValue = [string]$rgTags[$key]
                            $found = $true
                            break
                        }
                    }
                    if ($found) {
                        if ([string]::IsNullOrWhiteSpace($tagValue)) {
                            $tagStatus = "Empty"
                            $riskLevel = "High"
                        } else {
                            # Try to parse the date
                            try {
                                $parsedDate = [datetime]::ParseExact($tagValue.Trim(), $fmt, [System.Globalization.CultureInfo]::InvariantCulture)
                                $daysLeft = [math]::Round(($parsedDate - (Get-Date)).TotalDays, 0)

                                if ($daysLeft -lt 0) {
                                    $tagStatus = "Expired"
                                    $riskLevel = "EOL"
                                }
                                elseif ($daysLeft -le $script:LifecycleTagWarningDays) {
                                    $tagStatus = "Imminent"
                                    $riskLevel = "Critical"
                                }
                                elseif ($daysLeft -le $script:LifecycleTagCautionDays) {
                                    $tagStatus = "Approaching"
                                    $riskLevel = "High"
                                }
                                elseif ($daysLeft -gt ($script:LifecycleTagMaxYears * 365)) {
                                    $tagStatus = "Too far"
                                    $riskLevel = "Medium"
                                }
                                else {
                                    $tagStatus = "OK"
                                    $riskLevel = "Low"
                                }
                            }
                            catch {
                                $tagStatus = "Bad format"
                                $riskLevel = "High"
                            }
                        }
                    }
                }

                # Count resources in this RG
                $resCount = 0
                try { $resCount = @(Get-AzResource -ResourceGroupName $rgName -ErrorAction SilentlyContinue).Count } catch {}

                $results.Add(@{
                    Subscription  = $sub.Name
                    ResourceGroup = $rgName
                    Location      = $rg.Location
                    TagName       = $tagName
                    TagValue      = $tagValue
                    ParsedDate    = if ($parsedDate) { $parsedDate.ToString("yyyy-MM-dd") } else { "" }
                    DaysLeft      = $daysLeft
                    TagStatus     = $tagStatus
                    RiskLevel     = $riskLevel
                    ResourceCount = $resCount
                    Category      = "Lifecycle Tag"
                })
            }
        }
        catch {
            Write-Diag -Code "LCTAG" -Level "WARN" -Message "Lifecycle tag scan failed '$($sub.Name)': $_"
        }
    }
    Write-Diag -Code "LCTAG" -Level "INFO" -Message "Found $($results.Count) Resource Groups scanned for lifecycle tag."
    return $results
}

# ==============================================================================
# 5. COLLECT ALL DATA — Run all scan functions sequentially
# ==============================================================================
# Each function returns an array of hashtables. The @() wrapper ensures
# single-result outputs are still treated as arrays downstream.
Write-Diag -Code "DATA" -Level "INFO" -Message "Starting data collection..."
$script:CollectStart = Get-Date

$vmObsolescence      = @(Get-VMObsolescence       -Subscriptions $subscriptions)
$appSvcObsolescence  = @(Get-AppServiceObsolescence -Subscriptions $subscriptions)
$aksObsolescence     = @(Get-AKSObsolescence       -Subscriptions $subscriptions)
$sqlObsolescence     = @(Get-SQLObsolescence       -Subscriptions $subscriptions)
$serviceRetirements  = @(Get-AdvisorDeprecations   -Subscriptions $subscriptions)
$vmSkuDeprecations   = @(Get-VMSKUDeprecations     -Subscriptions $subscriptions -VMInventory $vmObsolescence -AdvisorData $serviceRetirements)
$tlsCompliance       = @(Get-TLSCompliance         -Subscriptions $subscriptions)
$lifecycleTags       = @(Get-LifecycleTagCompliance -Subscriptions $subscriptions)

$collectElapsed = [math]::Round(((Get-Date) - $script:CollectStart).TotalSeconds, 1)
Write-Diag -Code "DATA" -Level "INFO" -Message "All data collected in ${collectElapsed}s."

# ==============================================================================
# 6. COMPUTE KPIs — Aggregate risk metrics across all modules
# ==============================================================================
# Merges all scan results into $allRisks, then counts resources per risk level.
# Merges OS, Runtime, AKS, SQL and TLS results into $allRisks for global counts.
# The Obsolescence Score (0-100, higher = better) is a weighted composite:
#   60% — fraction of resources at Low/Unknown risk
#   25% — penalty for EOL and Critical resources
#   15% — penalty for deprecated TLS and critical service retirements
$allRisks = [System.Collections.Generic.List[hashtable]]::new()
foreach ($item in $vmObsolescence)     { $allRisks.Add($item) }
foreach ($item in $appSvcObsolescence) { $allRisks.Add($item) }
foreach ($item in $aksObsolescence)    { $allRisks.Add($item) }
foreach ($item in $sqlObsolescence)    { $allRisks.Add($item) }
foreach ($item in $tlsCompliance)      { $allRisks.Add($item) }

$totalResources = $allRisks.Count
$eolCount       = @($allRisks | Where-Object { ([hashtable]$_)["RiskLevel"] -eq "EOL" }).Count
$criticalCount  = @($allRisks | Where-Object { ([hashtable]$_)["RiskLevel"] -eq "Critical" }).Count
$highCount      = @($allRisks | Where-Object { ([hashtable]$_)["RiskLevel"] -eq "High" }).Count
$mediumCount    = @($allRisks | Where-Object { ([hashtable]$_)["RiskLevel"] -eq "Medium" }).Count
$lowCount       = @($allRisks | Where-Object { ([hashtable]$_)["RiskLevel"] -eq "Low" }).Count
$unknownCount   = @($allRisks | Where-Object { ([hashtable]$_)["RiskLevel"] -eq "Unknown" }).Count

$tlsIssues      = @($tlsCompliance | Where-Object { ([hashtable]$_)["Status"] -eq "Deprecated" }).Count
$retirementsCritical = @($serviceRetirements | Where-Object { ([hashtable]$_)["RiskLevel"] -in @("EOL","Critical") }).Count

# Obsolescence Score (0-100, higher = better)
$safeFraction = if ($totalResources -gt 0) {
    ($lowCount + $unknownCount) / $totalResources
} else { 1.0 }
$tlsPenalty = [math]::Min(15, $tlsIssues * 3)
$retirePenalty = [math]::Min(10, $retirementsCritical * 2)
$obsolescenceScore = [math]::Max(0, [math]::Min(100,
    [math]::Round($safeFraction * 100 * 0.6 + (100 - $eolCount - $criticalCount) * 0.25 + (100 - $tlsPenalty - $retirePenalty) * 0.15, 0)
))

Write-Diag -Code "KPI" -Level "INFO" -Message "Obsolescence Score: $obsolescenceScore/100"
Write-Diag -Code "KPI" -Level "INFO" -Message "VMs: $($vmObsolescence.Count), AppSvc: $($appSvcObsolescence.Count), AKS: $($aksObsolescence.Count), SQL: $($sqlObsolescence.Count)"
Write-Diag -Code "KPI" -Level "INFO" -Message "EOL: $eolCount, Critical: $criticalCount, High: $highCount, Medium: $mediumCount, Low: $lowCount"
Write-Diag -Code "KPI" -Level "INFO" -Message "TLS issues: $tlsIssues, Service retirements critical: $retirementsCritical"

# ==============================================================================
# 7. HELPER — Convert PowerShell hashtable arrays to JavaScript array literals
# ==============================================================================
# Serializes an array of hashtables into a JS array string: [{...}, {...}]
# All values are string-escaped (quotes, backslashes, newlines).
# Used to inject data into the HTML <script> block as const vmData=[...];
function ConvertTo-JsArray {
    param([object[]]$Items, [string[]]$Fields)
    $lines = foreach ($item in $Items) {
        $props = foreach ($f in $Fields) {
            $val = if ($item -is [hashtable]) { $item[$f] } else { $item.$f }
            if ($null -eq $val) { $val = "" }
            $escaped = ($val.ToString()) -replace "\\", "\\\\" -replace '"', '\"' -replace "`n", " " -replace "`r", ""
            "`"$f`": `"$escaped`""
        }
        "{" + ($props -join ", ") + "}"
    }
    return "[" + ($lines -join ",`n") + "]"
}

# ==============================================================================
# 8. BUILD JS DATA PAYLOADS — Serialize scan results for HTML injection
# ==============================================================================
# Each $js* variable becomes a JS array literal string that will be injected
# into the HTML via the double-quoted here-string: const vmData=$jsVMs;
$jsVMs = ConvertTo-JsArray -Items $vmObsolescence -Fields @(
    "Subscription","Name","ResourceGroup","Location","Size","PowerState","OSType","OSVersion","ImageSku","OsTagValue","OsSource","EOLDate","ExtendedEOL","DaysToEOL","RiskLevel","Notes","Category")

$jsAppSvc = ConvertTo-JsArray -Items $appSvcObsolescence -Fields @(
    "Subscription","Name","ResourceGroup","Location","Kind","Runtime","RuntimeVersion","Stack","EOLDate","DaysToEOL","RiskLevel","Notes","MinTLS","TLSStatus","HttpsOnly","Category")

$jsAKS = ConvertTo-JsArray -Items $aksObsolescence -Fields @(
    "Subscription","Name","ResourceGroup","Location","K8sVersion","K8sMinorVersion","NodeCount","EOLDate","DaysToEOL","RiskLevel","Notes","Category")

$jsSQL = ConvertTo-JsArray -Items $sqlObsolescence -Fields @(
    "Subscription","ServerName","DatabaseName","ResourceGroup","Location","ServerVersion","SKU","Edition","MinTLS","TLSStatus","DaysToEOL","RiskLevel","Notes","Category")

$jsRetirements = ConvertTo-JsArray -Items $serviceRetirements -Fields @(
    "Subscription","Service","ResourceName","ResourceGroup","ResourceId","Detail","Solution","RetireDate","DaysToRetire","Impact","RiskLevel","LearnMoreLink","SubCategory","AdvisorCategory","Category")

$jsVMSKU = ConvertTo-JsArray -Items $vmSkuDeprecations -Fields @(
    "Subscription","VMName","ResourceGroup","CurrentSKU","Problem","Solution","RetireDate","DaysToRetire","RiskLevel","LearnMoreLink","Category")

$jsTLS = ConvertTo-JsArray -Items $tlsCompliance -Fields @(
    "Subscription","ResourceType","Name","ResourceGroup","Location","MinTLS","Status","RiskLevel","Notes","Category")

$jsLifecycleTags = ConvertTo-JsArray -Items $lifecycleTags -Fields @(
    "Subscription","ResourceGroup","Location","TagName","TagValue","ParsedDate","DaysLeft","TagStatus","RiskLevel","ResourceCount","Category")

$reportDate  = (Get-Date).ToString("MMMM yyyy", [System.Globalization.CultureInfo]'en-US')
$reportGenAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss UTC")
$subCount    = $subscriptions.Count
$diagText    = ($script:DiagnosticLog -join "`n") -replace '\\','\\\\' -replace '"','\"' -replace "`r","" -replace "`n","\\n"

$valTotalRes    = $totalResources
$valEOL         = $eolCount
$valCritical    = $criticalCount
$valHigh        = $highCount
$valMedium      = $mediumCount
$valLow         = $lowCount
$valTLSIssues   = $tlsIssues
$valRetireCrit  = $retirementsCritical
$valScore       = $obsolescenceScore
$valVMCount     = $vmObsolescence.Count
$valAppSvcCount = $appSvcObsolescence.Count
$valAKSCount    = $aksObsolescence.Count
$valSQLCount    = $sqlObsolescence.Count
$valRetireCount = $serviceRetirements.Count
$valTLSCount    = $tlsCompliance.Count
$valVMSKUCount  = $vmSkuDeprecations.Count
$valLCTagCount  = $lifecycleTags.Count
$valLCTagIssues = @($lifecycleTags | Where-Object { ([hashtable]$_)["TagStatus"] -ne "OK" }).Count
$valLookAhead   = $script:LookAheadDays

Write-Diag -Code "HTML" -Level "INFO" -Message "Building HTML report..."

# ==============================================================================
# 9. JavaScript block (single-quoted here-string — no $ interpolation)
# ==============================================================================
$jsBlock = @'
function showPage(id,btn){document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.querySelectorAll('nav button').forEach(b=>b.classList.remove('active'));document.getElementById('page-'+id).classList.add('active');btn.classList.add('active')}
function toggleTheme(){const h=document.documentElement,d=h.getAttribute('data-theme')==='dark';h.setAttribute('data-theme',d?'':'dark');document.getElementById('themeBtn').textContent=d?'🌙':'☀️';try{localStorage.setItem('obso-theme',d?'light':'dark')}catch(e){}}
try{if(localStorage.getItem('obso-theme')==='dark')document.documentElement.setAttribute('data-theme','dark')}catch(e){}
function handleGlobalSearch(q){q=q.toLowerCase().trim();document.querySelectorAll('table tbody tr').forEach(r=>{r.style.display=!q||r.textContent.toLowerCase().includes(q)?'':'none'})}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function riskTag(l){const m={EOL:'eol',Critical:'critical',High:'orange',Medium:'blue',Low:'green',Unknown:'muted'};return'<span class="tag tag-'+(m[l]||'muted')+'">'+esc(l)+'</span>'}
function daysDisplay(d){const v=parseInt(d);if(isNaN(v)||v>9000)return'<span style="color:var(--muted)">—</span>';function fmt(n){const a=Math.abs(n),y=Math.floor(a/365),m=Math.floor((a%365)/30),dd=a%30;if(y>0&&m>0)return y+'y '+m+'m';if(y>0)return y+'y';if(m>0&&dd>0)return m+'m '+dd+'d';if(m>0)return m+'m';return dd+'d'}const t=fmt(v);if(v<0)return'<span style="color:var(--eol);font-weight:800">'+fmt(v)+' overdue</span>';if(v<=90)return'<span style="color:var(--red);font-weight:700">'+t+'</span>';if(v<=180)return'<span style="color:var(--orange);font-weight:600">'+t+'</span>';if(v<=365)return'<span style="color:var(--blue)">'+t+'</span>';return'<span style="color:var(--green)">'+t+'</span>'}
function fmtDate(d){if(!d||d==='')return'—';try{const dt=new Date(d);const dd=String(dt.getDate()).padStart(2,'0');const mm=String(dt.getMonth()+1).padStart(2,'0');return dd+'/'+mm+'/'+dt.getFullYear()}catch(e){return esc(d)}}
function navigateTo(pageId,filterField,filterValue){const btn=document.querySelector('nav button[onclick*="'+pageId+'"]');if(btn){showPage(pageId,btn);setTimeout(()=>{const inputs=document.querySelectorAll('#page-'+pageId+' .filter-input');inputs.forEach(inp=>{if(inp.dataset&&inp.dataset.field===filterField){if(inp.tagName==='SELECT'){for(let o of inp.options){if(o.value.toLowerCase()===String(filterValue).toLowerCase()){inp.value=o.value;break}}}else{inp.value=filterValue}inp.dispatchEvent(new Event(inp.tagName==='SELECT'?'change':'input'))}})},100)}}
function statusPill(data,f){f=f||'RiskLevel';const e=data.filter(r=>r[f]==='EOL').length,c=data.filter(r=>r[f]==='Critical').length,h=data.filter(r=>r[f]==='High').length;if(e>0||c>0)return'<span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:var(--red);margin-right:6px"></span>';if(h>0)return'<span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:var(--orange);margin-right:6px"></span>';return'<span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:var(--green);margin-right:6px"></span>'}
function pageKPI(id,items){const el=document.getElementById(id);if(!el)return;const e=items.filter(r=>r.RiskLevel==='EOL').length,c=items.filter(r=>r.RiskLevel==='Critical').length,h=items.filter(r=>r.RiskLevel==='High').length,m=items.filter(r=>r.RiskLevel==='Medium').length,lo=items.filter(r=>r.RiskLevel==='Low').length;el.innerHTML='<div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px"><div style="background:var(--eol-soft);padding:6px 14px;border-radius:8px;font-size:12px">'+statusPill(items)+'<strong style="color:var(--eol)">'+e+'</strong> <span style="font-size:10px;color:var(--muted)">EOL</span></div><div style="background:var(--critical-soft);padding:6px 14px;border-radius:8px;font-size:12px"><strong style="color:var(--critical)">'+c+'</strong> <span style="font-size:10px;color:var(--muted)">Critical</span></div><div style="background:var(--orange-soft);padding:6px 14px;border-radius:8px;font-size:12px"><strong style="color:var(--orange)">'+h+'</strong> <span style="font-size:10px;color:var(--muted)">High</span></div><div style="background:var(--blue-soft);padding:6px 14px;border-radius:8px;font-size:12px"><strong style="color:var(--blue)">'+m+'</strong> <span style="font-size:10px;color:var(--muted)">Medium</span></div><div style="background:var(--green-soft);padding:6px 14px;border-radius:8px;font-size:12px"><strong style="color:var(--green)">'+lo+'</strong> <span style="font-size:10px;color:var(--muted)">Low</span></div><div style="background:var(--bg);padding:6px 14px;border-radius:8px;font-size:12px;border:1px solid var(--border)"><strong>'+items.length+'</strong> <span style="font-size:10px;color:var(--muted)">Total</span></div></div>'}
function tfoot(id,n,l){const el=document.getElementById(id);if(el)el.innerHTML='<tr style="background:var(--bg)"><td colspan="20" style="padding:8px 12px;font-size:10px;font-weight:700;color:var(--muted);border-top:2px solid var(--border)">'+n+' '+l+'</td></tr>'}

const _AK='obso_annotations_v1';let _an={};try{_an=JSON.parse(localStorage.getItem(_AK)||'{}')}catch(e){_an={}}
function _as(){try{localStorage.setItem(_AK,JSON.stringify(_an))}catch(e){}}
function gak(t,r){return t+'::'+Object.keys(r).slice(0,3).map(k=>String(r[k]||'').substring(0,40)).join('|')}
function renderAnnotCell(t,r,i){const k=gak(t,r),v=_an[k]||'',h=v.length>0,id='a-'+t+'-'+i;return'<td class="annot-cell"><div class="annot-wrapper"><button class="annot-toggle '+(h?'has-note':'')+'" onclick="tai(\''+id+'\')" title="'+(h?esc(v):'Note')+'">'+(h?'📝':'＋')+'</button><div class="annot-input-wrap" id="'+id+'" style="display:none"><textarea class="annot-textarea" rows="2" placeholder="Note..." onblur="sai(\''+esc(t)+'\','+i+',this)" onkeydown="if(event.key===\'Enter\'&&!event.shiftKey){event.preventDefault();this.blur()}">'+esc(v)+'</textarea></div></div></td>'}
function tai(id){const el=document.getElementById(id);if(!el)return;const h=el.style.display==='none';document.querySelectorAll('.annot-input-wrap').forEach(w=>w.style.display='none');if(h){el.style.display='block';const ta=el.querySelector('textarea');if(ta){ta.focus();ta.selectionStart=ta.value.length}}}
function sai(t,i,ta){const w=ta.closest('.annot-input-wrap');if(w)w.style.display='none';const m=_arm[t];if(!m||!m[i])return;const k=gak(t,m[i]);if(ta.value.trim())_an[k]=ta.value.trim();else delete _an[k];_as();const b=ta.closest('.annot-wrapper').querySelector('.annot-toggle');if(b){const h=ta.value.trim().length>0;b.className='annot-toggle '+(h?'has-note':'');b.textContent=h?'📝':'＋'}}
const _arm={};function rar(t,d){_arm[t]={};d.forEach((r,i)=>{_arm[t][i]=r})}

const _tb={};
function regT(bi,hi,d,fn,dk,da){_tb[bi]={data:d,fn,st:{key:null,asc:true}};const th=document.getElementById(hi);if(!th)return;const ths=th.querySelectorAll('th[data-key]');function go(k,a){_tb[bi].st={key:k,asc:a};ths.forEach(h=>{delete h.dataset.sortdir});const t=th.querySelector('th[data-key="'+k+'"]');if(t)t.dataset.sortdir=a?'asc':'desc';document.getElementById(bi).innerHTML=fn(sk(d,k,a))}ths.forEach(t=>t.addEventListener('click',()=>{const k=t.dataset.key,s=_tb[bi].st;go(k,s.key===k?!s.asc:true)}));if(dk)go(dk,da!==false);else document.getElementById(bi).innerHTML=fn(d)}
function sk(d,k,a){return[...d].sort((x,y)=>{const va=x[k]??'',vb=y[k]??'',na=parseFloat(String(va).replace(/[^0-9.-]/g,'')),nb=parseFloat(String(vb).replace(/[^0-9.-]/g,''));if(!isNaN(na)&&!isNaN(nb))return a?na-nb:nb-na;return a?String(va).localeCompare(String(vb)):String(vb).localeCompare(String(va))})}
function bfr(c,fields,fn){const el=document.getElementById(c);if(!el)return;el.innerHTML='<label style="font-size:10px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.5px;align-self:center">Filters:</label>'+fields.map(f=>f.options?'<select class="filter-input" data-field="'+f.key+'" onchange="af(\''+c+'\')"><option value="">'+f.label+'</option>'+f.options.map(o=>'<option>'+esc(o)+'</option>').join('')+'</select>':'<input class="filter-input" data-field="'+f.key+'" placeholder="'+f.label+'" oninput="af(\''+c+'\')" />').join('');el._f=fn}
function af(c){const el=document.getElementById(c),f={};el.querySelectorAll('.filter-input').forEach(i=>{if(i.value)f[i.dataset.field]=i.value.toLowerCase()});el._f(f)}
function mf(r,f){return Object.entries(f).every(([k,v])=>String(r[k]||'').toLowerCase().includes(v))}

function downloadCSV(d,fn){if(!d||!d.length){alert('No data.');return}const ks=Object.keys(d[0]).filter(k=>!k.startsWith('_'));const rows=[ks.join(','),...d.map(r=>ks.map(k=>'"'+String(r[k]||'').replace(/"/g,'""')+'"').join(','))];const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([rows.join('\r\n')],{type:'text/csv'}));a.download=fn+'_'+new Date().toISOString().slice(0,10)+'.csv';a.click()}
function downloadAllCSV(){downloadCSV([...vmData,...appSvcData,...aksData,...sqlData,...tlsData,...retireData],'obsolescence_full')}

async function generatePDF(){const btn=document.getElementById('pdf-btn');if(btn){btn.textContent='⏳ Generating...';btn.disabled=true}try{const{jsPDF}=window.jspdf;const pdf=new jsPDF({orientation:'landscape',unit:'mm',format:'a4'});const W=pdf.internal.pageSize.getWidth(),H=pdf.internal.pageSize.getHeight(),M=8,HH=10;let pn=0;function hdr(t,p){pdf.setFillColor(30,27,75);pdf.rect(0,0,W,HH,'F');pdf.setTextColor(255);pdf.setFontSize(9);pdf.setFont('helvetica','bold');pdf.text('Azure Obsolescence Report',M,7);pdf.setFont('helvetica','normal');pdf.text(t,W/2,7,{align:'center'});pdf.text('Page '+p,W-M,7,{align:'right'})}async function captureSections(parentId,sectionSelector,title){const parent=document.getElementById(parentId);if(!parent)return;const origDisplay=parent.style.display;parent.style.display='block';const sections=sectionSelector?parent.querySelectorAll(sectionSelector):[];if(!sections.length){const c=await html2canvas(parent,{scale:1.5,useCORS:true,windowWidth:1400});if(pn>0)pdf.addPage();pn++;hdr(title,pn);const iw=W-2*M,ih=(c.height*iw)/c.width;let y=HH+2;if(ih>H-HH-4){const pages=Math.ceil(ih/(H-HH-4));for(let i=0;i<pages;i++){if(i>0){pdf.addPage();pn++;hdr(title+' (cont.)',pn)}const sy=i*(H-HH-4)*c.width/iw;const sh=Math.min((H-HH-4)*c.width/iw,c.height-sy);const tc=document.createElement('canvas');tc.width=c.width;tc.height=sh;tc.getContext('2d').drawImage(c,0,sy,c.width,sh,0,0,c.width,sh);pdf.addImage(tc.toDataURL('image/jpeg',.9),'JPEG',M,HH+2,iw,(sh*iw)/c.width)}}else{if(pn>0)pdf.addPage();pn++;hdr(title,pn);pdf.addImage(c.toDataURL('image/jpeg',.9),'JPEG',M,HH+2,iw,ih)}}else{let y=HH+2;let first=true;for(const sec of sections){const c=await html2canvas(sec,{scale:1.5,useCORS:true,windowWidth:1400});const iw=W-2*M,ih=(c.height*iw)/c.width;if(!first&&(y+ih>H-4)){pdf.addPage();pn++;hdr(title+' (cont.)',pn);y=HH+2}if(first){if(pn>0)pdf.addPage();pn++;hdr(title,pn);y=HH+2;first=false}pdf.addImage(c.toDataURL('image/jpeg',.9),'JPEG',M,y,iw,Math.min(ih,H-y-2));y+=ih+3}}parent.style.display=origDisplay}await captureSections('page-dashboard','.kpi-grid,.charts-row,.chart-card.chart-full,.charts-2col,.section','Dashboard');await captureSections('page-executive','','Executive Summary');pdf.save('Azure_Obsolescence_Report.pdf')}catch(e){console.error(e);alert('PDF failed: '+e.message)}if(btn){btn.textContent='📄 PDF';btn.disabled=false}}

function renderVMRows(d){rar('vm',d);if(!d.length)return'<tr><td colspan="15" style="text-align:center;color:var(--muted);padding:32px">No VMs.</td></tr>';return d.map((v,i)=>{const src=v.OsSource==='Tag'?'<span class="tag tag-orange">Tag</span>':v.OsSource==='Image+Tag'?'<span class="tag tag-green">Img+Tag</span>':'<span class="tag tag-muted">Image</span>';const tv=v.OsTagValue?'<span style="font-size:9px;color:var(--muted)">'+esc(v.OsTagValue)+'</span>':'';return'<tr><td class="col-sub">'+esc(v.Subscription)+'</td><td class="col-name"><strong>'+esc(v.Name)+'</strong></td><td class="col-rg">'+esc(v.ResourceGroup)+'</td><td>'+esc(v.Location)+'</td><td style="font-size:10px">'+esc(v.Size)+'</td><td>'+(v.PowerState==='VM running'?'<span class="tag tag-green">Running</span>':'<span class="tag tag-muted">Stopped</span>')+'</td><td><strong>'+esc(v.OSType)+'</strong></td><td>'+esc(v.OSVersion)+'</td><td>'+src+' '+tv+'</td><td>'+fmtDate(v.EOLDate)+'</td><td>'+daysDisplay(v.DaysToEOL)+'</td><td>'+riskTag(v.RiskLevel)+'</td><td style="font-size:10px;color:var(--text-secondary)">'+esc(v.Notes)+'</td>'+renderAnnotCell('vm',v,i)+'</tr>'}).join('')}
function renderVMSKURows(d){rar('vmsku',d);if(!d.length)return'<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:32px">No deprecated SKUs.</td></tr>';return d.map((s,i)=>{const lk=s.LearnMoreLink?'<a href="'+esc(s.LearnMoreLink)+'" target="_blank" style="color:var(--primary);font-size:10px">📄 Guide</a>':'';return'<tr><td class="col-sub">'+esc(s.Subscription)+'</td><td class="col-name"><strong>'+esc(s.VMName)+'</strong></td><td class="col-rg">'+esc(s.ResourceGroup)+'</td><td><span class="tag tag-red" style="font-family:var(--mono)">'+esc(s.CurrentSKU)+'</span></td><td style="font-size:10px">'+esc(s.Problem)+'</td><td style="font-size:10px;color:var(--green)">'+esc(s.Solution)+'</td><td>'+fmtDate(s.RetireDate)+'</td><td>'+daysDisplay(s.DaysToRetire)+'</td><td>'+riskTag(s.RiskLevel)+'</td><td>'+lk+'</td></tr>'}).join('')}
function renderAppSvcRows(d){rar('appsvc',d);if(!d.length)return'<tr><td colspan="13" style="text-align:center;color:var(--muted);padding:32px">No apps.</td></tr>';return d.map((a,i)=>'<tr><td class="col-sub">'+esc(a.Subscription)+'</td><td class="col-name"><strong>'+esc(a.Name)+'</strong></td><td class="col-rg">'+esc(a.ResourceGroup)+'</td><td>'+esc(a.Kind)+'</td><td><strong>'+esc(a.Runtime)+'</strong></td><td>'+esc(a.RuntimeVersion)+'</td><td>'+fmtDate(a.EOLDate)+'</td><td>'+daysDisplay(a.DaysToEOL)+'</td><td>'+riskTag(a.RiskLevel)+'</td><td>'+(a.TLSStatus==='Deprecated'?'<span class="tag tag-red">⚠ '+esc(a.MinTLS)+'</span>':'<span class="tag tag-green">'+esc(a.MinTLS)+'</span>')+'</td><td>'+(String(a.HttpsOnly)==='True'?'<span class="tag tag-green">✓</span>':'<span class="tag tag-red">✗</span>')+'</td><td style="font-size:10px;color:var(--text-secondary)">'+esc(a.Notes)+'</td>'+renderAnnotCell('appsvc',a,i)+'</tr>').join('')}
function renderAKSRows(d){rar('aks',d);if(!d.length)return'<tr><td colspan="11">No AKS.</td></tr>';return d.map((a,i)=>'<tr><td class="col-sub">'+esc(a.Subscription)+'</td><td class="col-name"><strong>'+esc(a.Name)+'</strong></td><td class="col-rg">'+esc(a.ResourceGroup)+'</td><td>'+esc(a.Location)+'</td><td><strong>'+esc(a.K8sVersion)+'</strong></td><td style="text-align:center">'+a.NodeCount+'</td><td>'+fmtDate(a.EOLDate)+'</td><td>'+daysDisplay(a.DaysToEOL)+'</td><td>'+riskTag(a.RiskLevel)+'</td><td style="font-size:10px;color:var(--text-secondary)">'+esc(a.Notes)+'</td>'+renderAnnotCell('aks',a,i)+'</tr>').join('')}
function renderSQLRows(d){rar('sql',d);if(!d.length)return'<tr><td colspan="11">No SQL.</td></tr>';return d.map((s,i)=>'<tr><td class="col-sub">'+esc(s.Subscription)+'</td><td class="col-name"><strong>'+esc(s.ServerName)+'</strong></td><td>'+esc(s.DatabaseName)+'</td><td class="col-rg">'+esc(s.ResourceGroup)+'</td><td>'+esc(s.ServerVersion)+'</td><td>'+esc(s.SKU)+'</td><td>'+esc(s.MinTLS)+'</td><td>'+(s.TLSStatus==='Deprecated'?'<span class="tag tag-red">⚠</span>':'<span class="tag tag-green">OK</span>')+'</td><td>'+riskTag(s.RiskLevel)+'</td><td style="font-size:10px;color:var(--text-secondary)">'+esc(s.Notes)+'</td>'+renderAnnotCell('sql',s,i)+'</tr>').join('')}
function renderTLSRows(d){rar('tls',d);if(!d.length)return'<tr><td colspan="10">No TLS.</td></tr>';return d.map((t,i)=>'<tr><td class="col-sub">'+esc(t.Subscription)+'</td><td>'+esc(t.ResourceType)+'</td><td class="col-name"><strong>'+esc(t.Name)+'</strong></td><td class="col-rg">'+esc(t.ResourceGroup)+'</td><td>'+esc(t.Location)+'</td><td><strong>'+esc(t.MinTLS)+'</strong></td><td>'+(t.Status==='Deprecated'?'<span class="tag tag-red">⚠ Deprecated</span>':'<span class="tag tag-green">✓ OK</span>')+'</td><td>'+riskTag(t.RiskLevel)+'</td><td style="font-size:10px;color:var(--text-secondary)">'+esc(t.Notes)+'</td>'+renderAnnotCell('tls',t,i)+'</tr>').join('')}

// ── RETIREMENT MASTER/DETAIL ─────────────────────────────────────────────────
let _rc={};
function buildRetirementPage(){
  try {
  if(!retireData.length){const kE=document.getElementById('retire-kpis');if(kE)kE.innerHTML='<div style="padding:20px;background:var(--green-soft);border-radius:10px;text-align:center;margin-bottom:14px"><span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:var(--green);margin-right:6px"></span><strong style="color:var(--green)">No deprecation recommendations found.</strong><br><span style="font-size:11px;color:var(--text-secondary)">Azure Advisor and Service Health did not return any recommendations for your subscriptions.</span></div>';const mE=document.getElementById('retire-master');if(mE)mE.innerHTML='<div style="text-align:center;color:var(--muted);padding:32px">No data available.</div>';const dE=document.getElementById('retire-detail-tbody');if(dE)dE.innerHTML='<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:32px">No data.</td></tr>';return}
  // Group by Detail (problem) — truncate key to 200 chars to avoid grouping issues with long HTML
  const g={};retireData.forEach(r=>{
    let k=(r.Detail||r.Solution||'Unknown').replace(/<[^>]*>/g,'').substring(0,200).trim();
    if(!k)k='Unknown';
    if(!g[k])g[k]={detail:k,solution:r.Solution||'',service:r.Service||'',link:r.LearnMoreLink||'',retireDate:r.RetireDate||'',riskLevel:r.RiskLevel||'Low',resources:[]};
    g[k].resources.push(r);
    const ro={EOL:0,Critical:1,High:2,Medium:3,Low:4,Unknown:5};
    if((ro[r.RiskLevel]||5)<(ro[g[k].riskLevel]||5))g[k].riskLevel=r.RiskLevel;
    if(r.RetireDate&&(!g[k].retireDate||r.RetireDate<g[k].retireDate))g[k].retireDate=r.RetireDate;
    if(!g[k].link&&r.LearnMoreLink)g[k].link=r.LearnMoreLink;
    if(!g[k].solution&&r.Solution)g[k].solution=r.Solution;
  });
  const sorted=Object.values(g).sort((a,b)=>(a.retireDate||'9999').localeCompare(b.retireDate||'9999'));
  if(!Object.keys(_rc).length)sorted.forEach((g,i)=>{_rc[i]=true});
  // KPIs
  const kE=document.getElementById('retire-kpis');
  if(kE){const tp=sorted.length,tr=retireData.length,ep=sorted.filter(g=>g.riskLevel==='EOL').length,hp=sorted.filter(g=>g.riskLevel==='High'||g.riskLevel==='Critical').length;kE.innerHTML='<div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px"><div style="background:var(--eol-soft);padding:8px 16px;border-radius:8px">'+statusPill(retireData)+'<strong style="color:var(--eol);font-size:18px">'+tp+'</strong> <span style="font-size:10px;color:var(--muted)">distinct problems</span></div><div style="background:var(--orange-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--orange);font-size:18px">'+tr+'</strong> <span style="font-size:10px;color:var(--muted)">impacted resources</span></div><div style="background:var(--red-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--red);font-size:18px">'+ep+'</strong> <span style="font-size:10px;color:var(--muted)">already retired</span></div><div style="background:var(--blue-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--blue);font-size:18px">'+hp+'</strong> <span style="font-size:10px;color:var(--muted)">critical / high</span></div></div>'}
  // Master table
  const mE=document.getElementById('retire-master');
  if(mE){mE.innerHTML='<table><thead><tr><th style="width:30px"><input type="checkbox" id="rsa" checked onchange="tra(this.checked)"></th><th data-key="detail">Problem</th><th data-key="service">Service</th><th data-key="solution">Solution</th><th data-key="retireDate">Retire Date</th><th data-key="riskLevel">Risk</th><th data-key="count">Resources</th><th>Guide</th></tr></thead><tbody>'+sorted.map((g,i)=>{const c=_rc[i]!==false,lk=g.link?'<a href="'+esc(g.link)+'" target="_blank" style="color:var(--primary);font-size:10px">📄 Link</a>':'';return'<tr style="cursor:pointer;'+(g.riskLevel==='EOL'?'background:var(--eol-soft)':'')+'"><td><input type="checkbox" '+(c?'checked':'')+' onchange="trg('+i+',this.checked)"></td><td style="font-size:11px;max-width:350px" title="'+esc(g.detail)+'">'+esc(g.detail.length>120?g.detail.substring(0,117)+'...':g.detail)+'</td><td class="col-sub" title="'+esc(g.service)+'">'+esc(g.service)+'</td><td style="font-size:10px;color:var(--green);max-width:250px" title="'+esc(g.solution)+'">'+esc(g.solution.length>100?g.solution.substring(0,97)+'...':g.solution)+'</td><td>'+fmtDate(g.retireDate)+'</td><td>'+riskTag(g.riskLevel)+'</td><td style="text-align:center;font-weight:700;font-size:14px">'+g.resources.length+'</td><td>'+lk+'</td></tr>'}).join('')+'</tbody><tfoot><tr style="background:var(--bg)"><td colspan="6" style="border-top:2px solid var(--border);padding:8px;font-size:10px;font-weight:700;color:var(--muted)">'+sorted.length+' distinct problems</td><td style="border-top:2px solid var(--border);padding:8px;font-weight:800;text-align:center;font-size:14px">'+retireData.length+'</td><td style="border-top:2px solid var(--border)"></td></tr></tfoot></table>'}
  window._rg=sorted;rrd();
  const rcE=document.getElementById('retire-count');if(rcE)rcE.textContent=retireData.length+' resources';
  } catch(e) { console.error('buildRetirementPage error:',e); const el=document.getElementById('retire-master'); if(el) el.innerHTML='<div style="color:var(--red);padding:20px">Error rendering retirement page: '+e.message+'<br>retireData has '+retireData.length+' items.</div>'; }
}
function trg(i,c){_rc[i]=c;rrd()}
function tra(c){(window._rg||[]).forEach((g,i)=>{_rc[i]=c});document.querySelectorAll('#retire-master tbody input[type=checkbox]').forEach(cb=>{cb.checked=c});rrd()}
function rrd(){try{const gs=window._rg||[],fl=[];gs.forEach((g,i)=>{if(_rc[i]!==false)fl.push(...g.resources)});const el=document.getElementById('retire-detail-tbody');if(!el)return;rar('retire',fl);if(!fl.length){el.innerHTML='<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:32px">No resources selected. Check problems above.</td></tr>'}else{el.innerHTML=fl.map((r,i)=>{const lk=r.LearnMoreLink?'<a href="'+esc(r.LearnMoreLink)+'" target="_blank" style="color:var(--primary);font-size:10px">📄</a>':'';return'<tr style="'+(parseInt(r.DaysToRetire)<0?'background:var(--eol-soft)':'')+'"><td class="col-sub">'+esc(r.Subscription||'')+'</td><td>'+esc(r.Service||'')+'</td><td class="col-name"><strong>'+esc(r.ResourceName||'')+'</strong></td><td class="col-rg">'+esc(r.ResourceGroup||'')+'</td><td style="font-size:10px" title="'+esc(r.Detail||'')+'">'+esc((r.Detail||'').length>80?(r.Detail||'').substring(0,77)+'...':r.Detail||'')+'</td><td>'+fmtDate(r.RetireDate)+'</td><td>'+daysDisplay(r.DaysToRetire)+'</td><td>'+riskTag(r.RiskLevel||'Unknown')+'</td><td>'+lk+'</td>'+renderAnnotCell('retire',r,i)+'</tr>'}).join('')}const cE=document.getElementById('retire-detail-count');if(cE)cE.textContent=fl.length+' / '+retireData.length;tfoot('retire-detail-tfoot',fl.length,'impacted resources')}catch(e){console.error('rrd error:',e)}}

function buildKPIs(){const sc=obsoScore>=70?'var(--green)':obsoScore>=40?'var(--orange)':'var(--red)';document.getElementById('kpi-row').innerHTML='<div class="kpi-card purple"><div class="kpi-icon">🛡️</div><div class="kpi-label">Obsolescence Score</div><div class="kpi-value" style="color:'+sc+'">'+obsoScore+'<span style="font-size:14px;color:var(--muted)">/100</span></div><div class="kpi-sub">composite maturity</div></div><div class="kpi-card eol"><div class="kpi-icon">💀</div><div class="kpi-label">End of Life</div><div class="kpi-value" style="color:var(--eol)">'+valEOL+'</div><div class="kpi-sub">resources past EOL</div></div><div class="kpi-card orange"><div class="kpi-icon">🔥</div><div class="kpi-label">Critical / High</div><div class="kpi-value" style="color:var(--orange)">'+(valCritical+valHigh)+'</div><div class="kpi-sub">'+valCritical+' critical · '+valHigh+' high</div></div><div class="kpi-card blue"><div class="kpi-icon">📊</div><div class="kpi-label">Total Scanned</div><div class="kpi-value">'+valTotalRes+'</div><div class="kpi-sub">across '+subCount+' subs</div></div><div class="kpi-card red"><div class="kpi-icon">🔒</div><div class="kpi-label">TLS Issues</div><div class="kpi-value" style="color:var(--red)">'+valTLSIssues+'</div><div class="kpi-sub">deprecated TLS</div></div><div class="kpi-card cyan"><div class="kpi-icon">📅</div><div class="kpi-label">Retirements</div><div class="kpi-value" style="color:var(--cyan)">'+retireData.length+'</div><div class="kpi-sub">impacted resources</div></div>'}

function buildCharts(){if(typeof Chart==='undefined')return;if(typeof ChartDataLabels!=='undefined')Chart.register(ChartDataLabels);Chart.defaults.animation={duration:600};Chart.defaults.plugins.tooltip.backgroundColor='rgba(15,23,42,.92)';Chart.defaults.plugins.datalabels={display:false};const allR=[...vmData,...appSvcData,...aksData,...sqlData,...tlsData],tot=Math.max(allR.length,1);const eC=allR.filter(r=>r.RiskLevel==='EOL').length,cC=allR.filter(r=>r.RiskLevel==='Critical').length,hC=allR.filter(r=>r.RiskLevel==='High').length,mC=allR.filter(r=>r.RiskLevel==='Medium').length,lC=allR.filter(r=>r.RiskLevel==='Low').length;const RC=['#dc2626','#ea580c','#f59e0b','#3b82f6','#10b981'];
if(document.getElementById('chartCatRisk')){const cats=['OS','Runtime','Kubernetes','SQL','TLS'],catPages={OS:'vms',Runtime:'appsvc',Kubernetes:'aks',SQL:'sql',TLS:'tls'},rl=['EOL','Critical','High','Medium','Low'],cd={};cats.forEach(c=>{cd[c]={};rl.forEach(r=>cd[c][r]=0)});allR.forEach(r=>{const c=r.Category||'Other';if(cd[c])cd[c][r.RiskLevel]=(cd[c][r.RiskLevel]||0)+1});new Chart(document.getElementById('chartCatRisk'),{type:'bar',data:{labels:cats,datasets:rl.map((r,i)=>({label:r,data:cats.map(c=>cd[c][r]||0),backgroundColor:RC[i],borderRadius:3}))},options:{onClick:(e,el)=>{if(el.length){const idx=el[0].index;const cat=cats[idx];const page=catPages[cat];if(page)navigateTo(page,'RiskLevel','')}},plugins:{legend:{position:'top',labels:{boxWidth:10,font:{size:10}}}},scales:{x:{stacked:true},y:{stacked:true,beginAtZero:true}},maintainAspectRatio:true}})}
if(document.getElementById('chartRisk'))new Chart(document.getElementById('chartRisk'),{type:'doughnut',data:{labels:['EOL','Critical','High','Medium','Low'],datasets:[{data:[eC,cC,hC,mC,lC],backgroundColor:RC,borderWidth:0}]},options:{cutout:'65%',plugins:{datalabels:{display:function(ctx){return ctx.dataset.data[ctx.dataIndex]>0},color:'#fff',font:{weight:'bold',size:11},formatter:function(v){return v}},legend:{position:'bottom',labels:{boxWidth:10,font:{size:10}}}}}});
const now=new Date(),qB={};allR.forEach(r=>{const d=parseInt(r.DaysToEOL);if(isNaN(d)||d>730||d<-730)return;const dt=new Date(now.getTime()+d*86400000),q='Q'+Math.ceil((dt.getMonth()+1)/3)+' '+dt.getFullYear(),s=dt.getFullYear()*10+Math.ceil((dt.getMonth()+1)/3);if(!qB[q])qB[q]={label:q,sk:s,count:0,eol:0};qB[q].count++;if(d<=0)qB[q].eol++});const qS=Object.values(qB).sort((a,b)=>a.sk-b.sk);
if(document.getElementById('chartTimeline'))new Chart(document.getElementById('chartTimeline'),{type:'bar',data:{labels:qS.map(q=>q.label),datasets:[{label:'EOL',data:qS.map(q=>q.eol),backgroundColor:'#ef4444',borderRadius:4},{label:'Upcoming',data:qS.map(q=>q.count-q.eol),backgroundColor:'#f59e0b',borderRadius:4}]},options:{plugins:{legend:{position:'top',labels:{boxWidth:10,font:{size:10}}}},scales:{x:{stacked:true},y:{stacked:true,beginAtZero:true}},maintainAspectRatio:true}});
const osC={};function normOS(s){return s.replace(/\b\w/g,c=>c.toUpperCase())}vmData.forEach(v=>{const k=normOS(v.OSType+' '+v.OSVersion);osC[k]=(osC[k]||0)+1});const osL=Object.keys(osC).sort((a,b)=>osC[b]-osC[a]),osCol=osL.map(l=>{const v=vmData.find(x=>normOS(x.OSType+' '+x.OSVersion)===l);return v&&(v.RiskLevel==='EOL'||v.RiskLevel==='Critical')?'#ef4444':v&&v.RiskLevel==='High'?'#f59e0b':v&&v.RiskLevel==='Medium'?'#3b82f6':'#10b981'});
if(document.getElementById('chartOS')){const osWrap=document.getElementById('chartOS-wrap');const dynH=Math.max(200,osL.length*22);osWrap.style.height=dynH+'px';const _osChart=new Chart(document.getElementById('chartOS'),{type:'bar',data:{labels:osL,datasets:[{data:osL.map(l=>osC[l]),backgroundColor:osCol,borderRadius:6}]},options:{indexAxis:'y',onClick:(e,el)=>{if(el.length){const idx=el[0].index;const osName=osL[idx];const parts=osName.split(' ');navigateTo('vms','OSType',parts[0])}},plugins:{legend:{display:false}},scales:{x:{beginAtZero:true,ticks:{stepSize:1}}},maintainAspectRatio:false,responsive:true}})};
const rtC={};appSvcData.forEach(a=>{const k=a.Runtime+' '+a.RuntimeVersion;rtC[k]=(rtC[k]||0)+1});const rtL=Object.keys(rtC),rtCol=rtL.map(l=>{const a=appSvcData.find(x=>x.Runtime+' '+x.RuntimeVersion===l);if(!a)return'#94a3b8';const r=a.RiskLevel;return r==='EOL'?'#dc2626':r==='Critical'?'#ea580c':r==='High'?'#f59e0b':r==='Medium'?'#3b82f6':r==='Unknown'?'#94a3b8':'#10b981'});
if(document.getElementById('chartRuntime'))new Chart(document.getElementById('chartRuntime'),{type:'doughnut',data:{labels:rtL,datasets:[{data:rtL.map(l=>rtC[l]),backgroundColor:rtCol,borderWidth:0}]},options:{onClick:(e,el)=>{if(el.length){const idx=el[0].index;const rt=rtL[idx].split(' ')[0];navigateTo('appsvc','Runtime',rt)}},cutout:'55%',plugins:{datalabels:{display:function(ctx){return ctx.dataset.data[ctx.dataIndex]>0},color:'#fff',font:{weight:'bold',size:10},formatter:function(v){return v}},legend:{position:'bottom',labels:{boxWidth:10,font:{size:10}}}}}});
const tlsOk=tlsData.filter(t=>t.Status!=='Deprecated').length,tlsBad=tlsData.filter(t=>t.Status==='Deprecated').length;
if(document.getElementById('chartTLS'))new Chart(document.getElementById('chartTLS'),{type:'doughnut',data:{labels:['TLS OK','TLS Deprecated'],datasets:[{data:[tlsOk,tlsBad],backgroundColor:['#10b981','#ef4444'],borderWidth:0}]},options:{onClick:(e,el)=>{if(el.length){const idx=el[0].index;navigateTo('tls','Status',idx===0?'OK':'Deprecated')}},cutout:'65%',plugins:{datalabels:{display:function(ctx){return ctx.dataset.data[ctx.dataIndex]>0},color:'#fff',font:{weight:'bold',size:12},formatter:function(v,ctx){const t=ctx.dataset.data.reduce((a,b)=>a+b,0);return t?Math.round(v/t*100)+'%':''}},legend:{position:'bottom',labels:{boxWidth:10,font:{size:10}}}}}})}

function buildTopActions(){const a=[];vmData.filter(v=>v.RiskLevel==='EOL'||v.RiskLevel==='Critical').forEach(v=>a.push({n:v.Name,t:'VM',d:v.OSType+' '+v.OSVersion,r:v.RiskLevel,s:v.Subscription}));appSvcData.filter(x=>x.RiskLevel==='EOL'||x.RiskLevel==='Critical').forEach(x=>a.push({n:x.Name,t:'AppSvc',d:x.Runtime+' '+x.RuntimeVersion,r:x.RiskLevel,s:x.Subscription}));aksData.filter(x=>x.RiskLevel==='EOL').forEach(x=>a.push({n:x.Name,t:'AKS',d:'K8s '+x.K8sVersion,r:x.RiskLevel,s:x.Subscription}));tlsData.filter(t=>t.Status==='Deprecated').forEach(t=>a.push({n:t.Name,t:t.ResourceType,d:t.Notes,r:'Critical',s:t.Subscription}));const el=document.getElementById('top-actions');if(el)el.innerHTML=a.slice(0,8).map((x,i)=>'<div style="display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--bg);border-radius:10px;margin-bottom:6px;border-left:3px solid '+(x.r==='EOL'?'var(--eol)':'var(--orange)')+'"><span style="font-size:15px;font-weight:800;color:var(--primary);min-width:24px">'+(i+1)+'</span><div style="flex:1"><strong>'+esc(x.n)+'</strong> '+riskTag(x.r)+' <span class="tag tag-muted">'+x.t+'</span><br><span style="font-size:10px;color:var(--text-secondary)">'+esc(x.d)+' · '+esc(x.s)+'</span></div></div>').join('')}

function buildRetirementTimeline(){const el=document.getElementById('retirement-timeline');if(!el)return;const u={};retireData.forEach(r=>{const k=r.Detail||r.Solution;if(!u[k])u[k]=r});const s=Object.values(u).sort((a,b)=>(a.RetireDate||'9999').localeCompare(b.RetireDate||'9999')).slice(0,12);el.innerHTML='<div style="display:flex;flex-direction:column;gap:6px">'+s.map(r=>{const ir=parseInt(r.DaysToRetire)<0,c=ir?'var(--eol)':'#3b82f6';return'<div style="display:flex;align-items:center;gap:12px;padding:8px 14px;background:'+(ir?'var(--eol-soft)':'var(--bg)')+';border-radius:8px;border-left:4px solid '+c+'"><div style="min-width:80px;font-family:var(--mono);font-size:10px;font-weight:700;color:'+c+'">'+fmtDate(r.RetireDate)+'</div><div style="flex:1;font-size:11px"><strong>'+esc(r.Service)+'</strong> — '+esc(r.Detail)+'</div>'+riskTag(r.RiskLevel)+'</div>'}).join('')+'</div>'}

function buildScoreBreakdown(){const el=document.getElementById('score-breakdown');if(!el)return;const a=[...vmData,...appSvcData,...aksData,...sqlData,...tlsData],t=Math.max(a.length,1);function b(l,v){const c=v>=70?'var(--green)':v>=40?'var(--orange)':'var(--red)';return'<div style="margin-bottom:14px"><div style="display:flex;justify-content:space-between;margin-bottom:4px"><span style="font-size:11px;font-weight:600">'+l+'</span><span style="font-size:12px;font-weight:800;color:'+c+';font-family:var(--mono)">'+v+'%</span></div><div class="progress-bar"><div class="progress-fill" style="width:'+v+'%;background:'+c+'"></div></div></div>'}const sf=Math.round(a.filter(r=>r.RiskLevel==='Low').length/t*100),os=vmData.length?Math.round(vmData.filter(v=>v.RiskLevel==='Low').length/vmData.length*100):100,rt=appSvcData.length?Math.round(appSvcData.filter(x=>x.RiskLevel==='Low'||x.RiskLevel==='Medium').length/appSvcData.length*100):100,tl=tlsData.length?Math.round(tlsData.filter(x=>x.Status!=='Deprecated').length/tlsData.length*100):100,ak=aksData.length?Math.round(aksData.filter(x=>x.RiskLevel==='Low').length/aksData.length*100):100;el.innerHTML='<div style="display:grid;grid-template-columns:1fr 1fr;gap:20px"><div>'+b('Overall',obsoScore)+b('OS Health',os)+b('Runtime',rt)+'</div><div>'+b('TLS',tl)+b('K8s',ak)+b('Safe Resources',sf)+'</div></div>'}

function buildExecutive(){const el=document.getElementById('exec-content');if(!el)return;const sc=obsoScore>=70?'var(--green)':obsoScore>=40?'var(--orange)':'var(--red)';el.innerHTML='<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:20px"><div style="text-align:center;padding:18px;background:var(--bg);border-radius:12px"><div style="font-size:30px;font-weight:900;color:'+sc+';font-family:var(--mono)">'+obsoScore+'/100</div><div style="font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;margin-top:4px">Score</div></div><div style="text-align:center;padding:18px;background:var(--bg);border-radius:12px"><div style="font-size:30px;font-weight:900;color:var(--eol);font-family:var(--mono)">'+valEOL+'</div><div style="font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;margin-top:4px">EOL</div></div><div style="text-align:center;padding:18px;background:var(--bg);border-radius:12px"><div style="font-size:30px;font-weight:900;color:var(--orange);font-family:var(--mono)">'+(valCritical+valHigh)+'</div><div style="font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;margin-top:4px">Critical+High</div></div></div><div style="display:grid;grid-template-columns:1fr 1fr;gap:12px"><div style="padding:14px;background:var(--eol-soft);border-radius:10px;border-left:4px solid var(--eol)"><div style="font-size:10px;font-weight:700;color:var(--eol);text-transform:uppercase">Immediate</div><div style="margin-top:6px;font-size:12px">• '+vmData.filter(v=>v.RiskLevel==='EOL').length+' VMs EOL<br>• '+appSvcData.filter(a=>a.RiskLevel==='EOL').length+' Apps EOL<br>• '+valTLSIssues+' TLS issues<br>• '+valVMSKUCount+' deprecated SKUs</div></div><div style="padding:14px;background:var(--orange-soft);border-radius:10px;border-left:4px solid var(--orange)"><div style="font-size:10px;font-weight:700;color:var(--orange);text-transform:uppercase">Plan 6 Months</div><div style="margin-top:6px;font-size:12px">• '+vmData.filter(v=>v.RiskLevel==='High').length+' VMs approaching EOL<br>• '+retireData.length+' Advisor deprecations</div></div></div><div style="text-align:center;padding-top:12px;border-top:1px solid var(--border);margin-top:16px"><p style="font-size:10px;color:var(--muted)">⚠ Read-only · Azure Automation</p></div>'}

function buildAllTables(){
  pageKPI('vm-kpis',vmData);bfr('vm-filters',[{key:'Subscription',label:'Sub',options:[...new Set(vmData.map(v=>v.Subscription))].sort()},{key:'OSType',label:'OS',options:[...new Set(vmData.map(v=>v.OSType))].sort()},{key:'RiskLevel',label:'Risk',options:[...new Set(vmData.map(v=>v.RiskLevel))].sort()},{key:'Name',label:'Name'}],f=>{const d=Object.keys(f).length?vmData.filter(r=>mf(r,f)):vmData;document.getElementById('vm-tbody').innerHTML=renderVMRows(d);document.getElementById('vm-count').textContent=d.length+'/'+vmData.length;tfoot('vm-tfoot',d.length,'VMs')});regT('vm-tbody','vm-thead',vmData,renderVMRows,'DaysToEOL',true);document.getElementById('vm-count').textContent=vmData.length+' VMs';tfoot('vm-tfoot',vmData.length,'VMs');
  pageKPI('vmsku-kpis',vmSkuData);regT('vmsku-tbody','vmsku-thead',vmSkuData,renderVMSKURows,'DaysToRetire',true);document.getElementById('vmsku-count').textContent=vmSkuData.length+' SKUs';tfoot('vmsku-tfoot',vmSkuData.length,'deprecated SKUs');
  pageKPI('appsvc-kpis',appSvcData);bfr('app-filters',[{key:'Subscription',label:'Sub',options:[...new Set(appSvcData.map(a=>a.Subscription))].sort()},{key:'Runtime',label:'Runtime',options:[...new Set(appSvcData.map(a=>a.Runtime))].sort()},{key:'RiskLevel',label:'Risk',options:[...new Set(appSvcData.map(a=>a.RiskLevel))].sort()}],f=>{const d=Object.keys(f).length?appSvcData.filter(r=>mf(r,f)):appSvcData;document.getElementById('app-tbody').innerHTML=renderAppSvcRows(d);document.getElementById('app-count').textContent=d.length+'/'+appSvcData.length;tfoot('app-tfoot',d.length,'apps')});regT('app-tbody','app-thead',appSvcData,renderAppSvcRows,'DaysToEOL',true);document.getElementById('app-count').textContent=appSvcData.length+' apps';tfoot('app-tfoot',appSvcData.length,'apps');
  pageKPI('aks-kpis',aksData);regT('aks-tbody','aks-thead',aksData,renderAKSRows,'DaysToEOL',true);document.getElementById('aks-count').textContent=aksData.length+' clusters';tfoot('aks-tfoot',aksData.length,'clusters');
  pageKPI('sql-kpis',sqlData);regT('sql-tbody','sql-thead',sqlData,renderSQLRows,'RiskLevel',true);document.getElementById('sql-count').textContent=sqlData.length+' databases';tfoot('sql-tfoot',sqlData.length,'databases');
  pageKPI('tls-kpis',tlsData);bfr('tls-filters',[{key:'Subscription',label:'Sub',options:[...new Set(tlsData.map(t=>t.Subscription))].sort()},{key:'ResourceType',label:'Type',options:[...new Set(tlsData.map(t=>t.ResourceType))].sort()},{key:'Status',label:'Status',options:['OK','Deprecated']}],f=>{const d=Object.keys(f).length?tlsData.filter(r=>mf(r,f)):tlsData;document.getElementById('tls-tbody').innerHTML=renderTLSRows(d);document.getElementById('tls-count').textContent=d.length+'/'+tlsData.length;tfoot('tls-tfoot',d.length,'resources')});regT('tls-tbody','tls-thead',tlsData,renderTLSRows,'RiskLevel',false);document.getElementById('tls-count').textContent=tlsData.length+' resources';tfoot('tls-tfoot',tlsData.length,'resources');
  buildRetirementPage();
  buildLifecycleTagPage();
}

// ── LIFECYCLE TAG RENDERER ──────────────────────────────────────────────
function statusTag(s){const m={OK:'green',Missing:'red',Empty:'orange',Expired:'eol','Bad format':'red',Imminent:'critical',Approaching:'orange','Too far':'blue'};return'<span class="tag tag-'+(m[s]||'muted')+'">'+esc(s)+'</span>'}
function renderLCTagRows(data){
  rar('lctag',data);
  if(!data.length)return'<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:32px">No Resource Groups found.</td></tr>';
  return data.map((t,i)=>{
    const st=t.TagStatus,tv=t.TagValue||'',dl=parseInt(t.DaysLeft);
    const daysCol=st==='Missing'||st==='Empty'||st==='Bad format'?'<span style="color:var(--muted)">—</span>':daysDisplay(t.DaysLeft);
    const valDisplay=st==='Missing'?'<span style="color:var(--red);font-style:italic">not set</span>':st==='Empty'?'<span style="color:var(--orange);font-style:italic">empty</span>':st==='Bad format'?'<span style="color:var(--red)" title="Expected format shown in legend">'+esc(tv)+'</span>':'<strong>'+esc(tv)+'</strong>';
    return'<tr style="'+(st==='Expired'?'background:var(--eol-soft)':st==='Missing'||st==='Empty'?'background:var(--red-soft)':'')+'">'+'<td class="col-sub">'+esc(t.Subscription)+'</td>'+'<td class="col-name"><strong>'+esc(t.ResourceGroup)+'</strong></td>'+'<td>'+esc(t.Location)+'</td>'+'<td>'+valDisplay+'</td>'+'<td>'+statusTag(st)+'</td>'+'<td>'+daysCol+'</td>'+'<td>'+riskTag(t.RiskLevel)+'</td>'+'<td style="text-align:center">'+t.ResourceCount+'</td>'+renderAnnotCell('lctag',t,i)+'</tr>'
  }).join('');
}
function buildLifecycleTagPage(){
  try{
    // KPIs
    const kE=document.getElementById('lctag-kpis');
    if(kE){
      const total=lcTagData.length,missing=lcTagData.filter(t=>t.TagStatus==='Missing').length,empty=lcTagData.filter(t=>t.TagStatus==='Empty').length,bad=lcTagData.filter(t=>t.TagStatus==='Bad format').length,expired=lcTagData.filter(t=>t.TagStatus==='Expired').length,imminent=lcTagData.filter(t=>t.TagStatus==='Imminent').length,approaching=lcTagData.filter(t=>t.TagStatus==='Approaching').length,ok=lcTagData.filter(t=>t.TagStatus==='OK').length,toofar=lcTagData.filter(t=>t.TagStatus==='Too far').length;
      kE.innerHTML='<div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px">'+'<div style="background:var(--bg);padding:8px 16px;border-radius:8px"><strong style="font-size:18px">'+total+'</strong> <span style="font-size:10px;color:var(--muted)">RGs scanned</span></div>'+'<div style="background:var(--red-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--red);font-size:18px">'+missing+'</strong> <span style="font-size:10px;color:var(--muted)">missing</span></div>'+'<div style="background:var(--orange-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--orange);font-size:18px">'+empty+'</strong> <span style="font-size:10px;color:var(--muted)">empty</span></div>'+'<div style="background:var(--red-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--red);font-size:18px">'+bad+'</strong> <span style="font-size:10px;color:var(--muted)">bad format</span></div>'+'<div style="background:var(--eol-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--eol);font-size:18px">'+expired+'</strong> <span style="font-size:10px;color:var(--muted)">expired</span></div>'+'<div style="background:var(--critical-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--critical);font-size:18px">'+imminent+'</strong> <span style="font-size:10px;color:var(--muted)">&lt;3m</span></div>'+'<div style="background:var(--orange-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--orange);font-size:18px">'+approaching+'</strong> <span style="font-size:10px;color:var(--muted)">&lt;6m</span></div>'+'<div style="background:var(--green-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--green);font-size:18px">'+ok+'</strong> <span style="font-size:10px;color:var(--muted)">OK</span></div>'+'<div style="background:var(--blue-soft);padding:8px 16px;border-radius:8px"><strong style="color:var(--blue);font-size:18px">'+toofar+'</strong> <span style="font-size:10px;color:var(--muted)">&gt;3y</span></div>'+'</div>'
    }
    // Filters
    const subs=[...new Set(lcTagData.map(t=>t.Subscription))].sort();
    const statuses=[...new Set(lcTagData.map(t=>t.TagStatus))].sort();
    bfr('lctag-filters',[{key:'Subscription',label:'Subscription',options:subs},{key:'ResourceGroup',label:'Resource Group'},{key:'TagStatus',label:'Status',options:statuses},{key:'RiskLevel',label:'Risk',options:['EOL','Critical','High','Medium','Low']}],f=>{const d=Object.keys(f).length?lcTagData.filter(r=>mf(r,f)):lcTagData;document.getElementById('lctag-tbody').innerHTML=renderLCTagRows(d);document.getElementById('lctag-count').textContent=d.length+'/'+lcTagData.length+' RGs';tfoot('lctag-tfoot',d.length,'resource groups')});
    // Sort by DaysLeft ascending (expired/missing first) — use TagStatus priority then DaysLeft
    const sortedLC=[...lcTagData].sort((a,b)=>{const prio={Expired:0,Imminent:1,Approaching:2,Missing:3,Empty:4,'Bad format':5,'Too far':6,OK:7};const pa=prio[a.TagStatus]!==undefined?prio[a.TagStatus]:8;const pb=prio[b.TagStatus]!==undefined?prio[b.TagStatus]:8;if(pa!==pb)return pa-pb;return(parseInt(a.DaysLeft)||9999)-(parseInt(b.DaysLeft)||9999)});
    regT('lctag-tbody','lctag-thead',sortedLC,renderLCTagRows,'DaysLeft',true);
    document.getElementById('lctag-count').textContent=lcTagData.length+' RGs';
    tfoot('lctag-tfoot',lcTagData.length,'resource groups');
  }catch(e){console.error('buildLifecycleTagPage error:',e)}
}

// ── INIT NAV BADGES ──
try{document.getElementById('nav-vm-badge').textContent=vmData.filter(v=>v.RiskLevel==='EOL'||v.RiskLevel==='Critical').length||''}catch(e){}
try{document.getElementById('nav-vmsku-badge').textContent=vmSkuData.length||''}catch(e){}
try{document.getElementById('nav-app-badge').textContent=appSvcData.filter(a=>a.RiskLevel==='EOL'||a.RiskLevel==='Critical').length||''}catch(e){}
try{document.getElementById('nav-tls-badge').textContent=tlsData.filter(t=>t.Status==='Deprecated').length||''}catch(e){}
try{document.getElementById('nav-retire-badge').textContent=retireData.length||''}catch(e){}
try{document.getElementById('nav-lctag-badge').textContent=lcTagData.filter(t=>t.TagStatus==='Missing'||t.TagStatus==='Empty'||t.TagStatus==='Bad format'||t.TagStatus==='Expired').length||''}catch(e){}
try{document.getElementById('diag-box').textContent=(typeof diagLog==='string'?diagLog:'').replace(/\\n/g,'\n')}catch(e){}

buildKPIs();buildTopActions();buildRetirementTimeline();buildScoreBreakdown();buildAllTables();buildExecutive();setTimeout(buildCharts,50);
'@

# ==============================================================================
# 10. HTML REPORT (double-quoted here-string — PS variables ARE interpolated)
# ==============================================================================
# This here-string uses @"..."@ so PowerShell replaces $jsVMs, $reportDate, etc.
# The <script> section contains ONLY:
#   - const declarations with $ps_variables (interpolated by PS at runtime)
#   - $jsBlock injection (the single-quoted JS block from section 9)
# NO raw JavaScript code should appear here — put it in $jsBlock instead.
$htmlContent = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>Azure Obsolescence Tracker — $reportDate</title>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=DM+Sans:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>
:root{--primary:#6366f1;--primary-soft:#eef2ff;--primary-dark:#4338ca;--bg:#f5f5f7;--card:#fff;--text:#0f172a;--text-secondary:#475569;--muted:#94a3b8;--border:#e2e8f0;--border-subtle:#f1f5f9;--red:#ef4444;--red-soft:#fef2f2;--orange:#f59e0b;--orange-soft:#fffbeb;--green:#10b981;--green-soft:#ecfdf5;--blue:#3b82f6;--blue-soft:#eff6ff;--purple:#8b5cf6;--purple-soft:#f5f3ff;--cyan:#06b6d4;--cyan-soft:#ecfeff;--eol:#dc2626;--eol-soft:#fef2f2;--critical:#f97316;--critical-soft:#fff7ed;--shadow-sm:0 1px 3px rgba(15,23,42,.06);--shadow-md:0 4px 16px rgba(15,23,42,.08);--shadow-lg:0 10px 40px rgba(15,23,42,.12);--radius:16px;--radius-sm:10px;--font:'DM Sans',system-ui,sans-serif;--mono:'JetBrains Mono',monospace}
[data-theme="dark"]{--bg:#0c0f1a;--card:#161b2e;--text:#e2e8f0;--text-secondary:#94a3b8;--muted:#64748b;--border:#1e293b;--border-subtle:#1e293b;--primary-soft:#1e1b4b;--shadow-sm:0 1px 3px rgba(0,0,0,.3);--shadow-md:0 4px 16px rgba(0,0,0,.3);--red-soft:#450a0a;--orange-soft:#451a03;--green-soft:#052e16;--blue-soft:#172554;--purple-soft:#2e1065;--cyan-soft:#083344;--eol-soft:#450a0a;--critical-soft:#431407}
*{box-sizing:border-box;margin:0;padding:0}body{font-family:var(--font);background:var(--bg);color:var(--text);font-size:14px;line-height:1.5;transition:background .3s,color .3s}::-webkit-scrollbar{width:6px;height:6px}::-webkit-scrollbar-thumb{background:var(--muted);border-radius:3px}
.topbar{background:linear-gradient(135deg,#1e1b4b,#312e81,#4338ca);color:#f8fafc;padding:16px 32px;display:flex;align-items:center;justify-content:space-between}.topbar h1{font-size:18px;font-weight:800}.topbar .meta{font-size:11px;opacity:.55;margin-top:3px}.topbar-actions{display:flex;gap:8px;align-items:center}.btn-ghost{padding:7px 14px;border-radius:var(--radius-sm);border:none;cursor:pointer;font-size:11px;font-weight:600;font-family:var(--font);background:rgba(255,255,255,.1);color:#fff;transition:.15s}.btn-ghost:hover{background:rgba(255,255,255,.2)}.theme-toggle{width:34px;height:34px;border-radius:50%;background:rgba(255,255,255,.1);border:none;cursor:pointer;color:#fff;font-size:15px;display:flex;align-items:center;justify-content:center}.global-search{position:relative;width:240px}.global-search input{width:100%;padding:7px 10px 7px 30px;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.15);border-radius:var(--radius-sm);color:#fff;font-size:11px;font-family:var(--font)}.global-search input::placeholder{color:rgba(255,255,255,.4)}.global-search .icon{position:absolute;left:8px;top:50%;transform:translateY(-50%);font-size:13px;opacity:.5}
nav{background:var(--card);border-bottom:1px solid var(--border);padding:0 32px;display:flex;gap:0;position:sticky;top:0;z-index:100;box-shadow:var(--shadow-sm);overflow-x:auto}nav button{padding:12px 16px;border:none;background:none;cursor:pointer;font-size:11.5px;font-weight:500;font-family:var(--font);color:var(--muted);border-bottom:2.5px solid transparent;transition:.15s;white-space:nowrap;display:flex;align-items:center;gap:5px}nav button.active{color:var(--primary);border-bottom-color:var(--primary);font-weight:700}nav button:hover{color:var(--primary);background:var(--primary-soft)}nav .nav-badge{background:var(--red);color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:10px}
.page{display:none;padding:24px 32px;max-width:1440px;margin:0 auto}.page.active{display:block;animation:fadeIn .25s ease}@keyframes fadeIn{from{opacity:0;transform:translateY(6px)}to{opacity:1}}
.kpi-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:22px}.kpi-card{background:var(--card);border-radius:var(--radius);padding:18px 20px;box-shadow:var(--shadow-sm);border:1px solid var(--border-subtle);position:relative;overflow:hidden;transition:transform .15s}.kpi-card:hover{transform:translateY(-3px);box-shadow:var(--shadow-md)}.kpi-card::before{content:'';position:absolute;top:0;left:0;right:0;height:3.5px}.kpi-card.red::before{background:var(--red)}.kpi-card.orange::before{background:var(--orange)}.kpi-card.green::before{background:var(--green)}.kpi-card.purple::before{background:var(--purple)}.kpi-card.cyan::before{background:var(--cyan)}.kpi-card.blue::before{background:var(--blue)}.kpi-card.eol::before{background:var(--eol)}.kpi-icon{width:36px;height:36px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px;margin-bottom:10px}.kpi-card.red .kpi-icon{background:var(--red-soft)}.kpi-card.orange .kpi-icon{background:var(--orange-soft)}.kpi-card.green .kpi-icon{background:var(--green-soft)}.kpi-card.purple .kpi-icon{background:var(--purple-soft)}.kpi-card.cyan .kpi-icon{background:var(--cyan-soft)}.kpi-card.blue .kpi-icon{background:var(--blue-soft)}.kpi-card.eol .kpi-icon{background:var(--eol-soft)}.kpi-label{font-size:10px;font-weight:600;text-transform:uppercase;color:var(--muted);letter-spacing:.6px;margin-bottom:4px}.kpi-value{font-size:26px;font-weight:800;line-height:1.1;font-family:var(--mono)}.kpi-sub{font-size:10px;color:var(--muted);margin-top:4px}
.charts-row{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-bottom:18px}.charts-2col{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:18px}.chart-card{background:var(--card);border-radius:var(--radius);padding:20px;box-shadow:var(--shadow-sm);border:1px solid var(--border-subtle)}.chart-card h3{font-size:13px;font-weight:700;margin-bottom:14px;display:flex;align-items:center;gap:8px}.chart-card h3 .chip{font-size:9px;font-weight:700;padding:2px 8px;border-radius:8px;background:var(--primary-soft);color:var(--primary)}.chart-card canvas{display:block;width:100%!important;max-height:220px;cursor:pointer}.chart-full{grid-column:1/-1}.chart-full canvas{max-height:none!important}
.section{background:var(--card);border-radius:var(--radius);padding:20px;box-shadow:var(--shadow-sm);border:1px solid var(--border-subtle);margin-bottom:18px}.section-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px;padding-bottom:12px;border-bottom:1px solid var(--border)}.section-header h2{font-size:15px;font-weight:700;display:flex;align-items:center;gap:8px}.badge{background:var(--bg);border:1px solid var(--border);border-radius:20px;padding:2px 10px;font-size:10px;font-weight:600;color:var(--muted)}
.filter-bar{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:12px;align-items:center}.filter-input{padding:5px 8px;border:1px solid var(--border);border-radius:var(--radius-sm);font-size:11px;background:var(--card);color:var(--text);font-family:var(--font);min-width:120px}.filter-input:focus{outline:none;border-color:var(--primary)}
.table-wrap{overflow-x:auto;border-radius:var(--radius-sm);border:1px solid var(--border)}table{width:100%;border-collapse:collapse;font-size:11.5px}thead tr{background:var(--bg)}th{padding:10px 12px;text-align:left;font-weight:700;font-size:9.5px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);border-bottom:2px solid var(--border);white-space:nowrap;cursor:pointer;user-select:none}th:hover{color:var(--primary)}th[data-key]::after{content:' ⇅';opacity:.3;font-size:9px}th[data-key][data-sortdir='asc']::after{content:' ↑';opacity:1;color:var(--primary)}th[data-key][data-sortdir='desc']::after{content:' ↓';opacity:1;color:var(--primary)}td{padding:9px 12px;border-bottom:1px solid var(--border-subtle);vertical-align:middle}tr:last-child td{border-bottom:none}tr:hover td{background:var(--primary-soft)}.col-name{max-width:160px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.col-rg{max-width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.col-sub{max-width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tag{display:inline-flex;align-items:center;gap:3px;padding:2px 8px;border-radius:6px;font-size:9.5px;font-weight:700}.tag-red{background:var(--red-soft);color:var(--red)}.tag-orange{background:var(--orange-soft);color:var(--orange)}.tag-green{background:var(--green-soft);color:var(--green)}.tag-blue{background:var(--blue-soft);color:var(--blue)}.tag-purple{background:var(--purple-soft);color:var(--purple)}.tag-muted{background:var(--bg);color:var(--muted)}.tag-eol{background:#450a0a;color:#fca5a5;font-weight:800}.tag-critical{background:var(--critical-soft);color:var(--critical)}[data-theme="dark"] .tag-eol{background:#7f1d1d;color:#fecaca}
.progress-bar{height:8px;border-radius:4px;background:var(--border);overflow:hidden}.progress-fill{height:100%;border-radius:4px;transition:width .6s ease}
.csv-btn{padding:5px 12px;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-sm);font-size:11px;cursor:pointer;font-weight:600;color:var(--primary);font-family:var(--font)}.csv-btn:hover{background:var(--primary-soft);border-color:var(--primary)}
.annot-cell{width:40px;min-width:40px;padding:4px 6px!important;vertical-align:middle}.annot-wrapper{position:relative;display:flex;align-items:center}.annot-toggle{width:26px;height:26px;border-radius:6px;border:1px solid var(--border);background:var(--bg);color:var(--muted);font-size:13px;cursor:pointer;display:flex;align-items:center;justify-content:center;line-height:1;padding:0}.annot-toggle:hover{border-color:var(--primary);color:var(--primary)}.annot-toggle.has-note{background:var(--orange-soft);border-color:var(--orange);color:var(--orange)}.annot-input-wrap{position:absolute;right:0;top:100%;z-index:50;margin-top:4px;width:220px}.annot-textarea{width:100%;padding:8px;border:2px solid var(--primary);border-radius:var(--radius-sm);font-size:11px;font-family:var(--font);background:var(--card);color:var(--text);resize:vertical;box-shadow:var(--shadow-md);min-height:48px}
.legend-box{background:var(--blue-soft);border-radius:8px;padding:8px 14px;font-size:11px;margin-bottom:12px;color:var(--text-secondary)}
.disclaimer{background:#eef2ff;border-bottom:2.5px solid var(--primary);color:#3730a3;padding:7px 32px;font-size:11px;display:flex;align-items:center;gap:6px;font-weight:500}[data-theme="dark"] .disclaimer{background:#1e1b4b;color:#a5b4fc}
footer{text-align:center;padding:16px;color:var(--muted);font-size:10px;border-top:1px solid var(--border);margin-top:10px}
@media(max-width:1024px){.charts-row,.charts-2col{grid-template-columns:1fr}}@media print{nav,.topbar,.disclaimer,footer{display:none!important}.page{display:block!important;padding:10px}}
</style></head><body>
<div class="disclaimer"><strong>⚠ Read-only analysis.</strong> This tool does NOT modify any Azure resource.</div>
<noscript><div style="padding:40px;text-align:center;color:red;font-size:18px">⚠ JavaScript is required to display this report. Please enable JavaScript in your browser.</div></noscript>
<div class="topbar"><div style="display:flex;align-items:center;gap:14px"><div style="font-size:22px">🛡️</div><div><h1>Azure Obsolescence Tracker — $reportDate</h1><div class="meta">Generated: $reportGenAt | Subscriptions: $subCount | Look-ahead: $valLookAhead days</div></div></div><div class="topbar-actions"><div class="global-search"><span class="icon">🔍</span><input type="text" placeholder="Search…" oninput="handleGlobalSearch(this.value)"/></div><button class="btn-ghost" id="pdf-btn" onclick="generatePDF()">📄 PDF</button><button class="btn-ghost" onclick="downloadAllCSV()">⬇ CSV</button><button class="theme-toggle" onclick="toggleTheme()" id="themeBtn">🌙</button></div></div>
<nav><button class="active" onclick="showPage('dashboard',this)">📊 Dashboard</button><button onclick="showPage('vms',this)">🖥 VM OS <span class="nav-badge" id="nav-vm-badge"></span></button><button onclick="showPage('vmsku',this)">⚙️ VM SKUs <span class="nav-badge" id="nav-vmsku-badge"></span></button><button onclick="showPage('appsvc',this)">⚡ Runtimes <span class="nav-badge" id="nav-app-badge"></span></button><button onclick="showPage('aks',this)">☸ AKS</button><button onclick="showPage('sql',this)">🗄 SQL</button><button onclick="showPage('tls',this)">🔒 TLS <span class="nav-badge" id="nav-tls-badge"></span></button><button onclick="showPage('retirements',this)">📅 Retirements <span class="nav-badge" id="nav-retire-badge"></span></button><button onclick="showPage('lctags',this)">🏷 Lifecycle <span class="nav-badge" id="nav-lctag-badge"></span></button><button onclick="showPage('executive',this)">📋 Executive</button><button onclick="showPage('diag',this)">🔧 Diag</button></nav>

<div class="page active" id="page-dashboard"><div class="kpi-grid" id="kpi-row"></div>
<div class="charts-row"><div class="chart-card"><h3>🏗 Risk by Category <span class="chip" style="cursor:help" title="Click a bar to navigate to the page">clickable</span></h3><canvas id="chartCatRisk" height="200"></canvas></div><div class="chart-card"><h3>📊 Risk Distribution</h3><canvas id="chartRisk" height="200"></canvas></div><div class="chart-card"><h3>⏰ EOL Timeline</h3><canvas id="chartTimeline" height="200"></canvas></div></div>
<div class="chart-card chart-full" style="margin-bottom:18px"><h3>🖥 OS Version Landscape <span class="chip" style="cursor:help" title="Click a bar to filter VMs by OS">clickable</span></h3><div id="chartOS-wrap"><canvas id="chartOS"></canvas></div></div>
<div class="charts-2col"><div class="chart-card"><h3>⚡ Runtime Versions <span class="chip" style="cursor:help" title="Click a segment to filter by runtime">clickable</span></h3><canvas id="chartRuntime" height="200"></canvas></div><div class="chart-card"><h3>🔒 TLS Compliance <span class="chip" style="cursor:help" title="Click to filter TLS page">clickable</span></h3><canvas id="chartTLS" height="200"></canvas></div></div>
<div class="charts-2col"><div class="section"><div class="section-header"><h2>🚨 Top Urgent Actions</h2><span class="badge">Immediate</span></div><div id="top-actions"></div></div><div class="section"><div class="section-header"><h2>📈 Score Breakdown</h2></div><div id="score-breakdown"></div></div></div>
<div class="chart-card chart-full" style="margin-bottom:18px"><h3>📅 Service Retirement Timeline</h3><div id="retirement-timeline"></div></div></div>

<div class="page" id="page-vms"><div class="section"><div class="section-header"><h2>🖥 VM Operating System Lifecycle</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="vm-count">0</span><button class="csv-btn" onclick="downloadCSV(vmData,'vm_os')">⬇ CSV</button></div></div><div id="vm-kpis"></div><div class="filter-bar" id="vm-filters"></div><div class="legend-box"><strong>OS detection:</strong> <span class="tag tag-muted">Image</span> from VM image. <span class="tag tag-orange">Tag</span> from <code>os-version</code> tag. <span class="tag tag-green">Img+Tag</span> both.</div><div class="table-wrap"><table><thead id="vm-thead"><tr><th data-key="Subscription">Sub</th><th data-key="Name">VM</th><th data-key="ResourceGroup">RG</th><th data-key="Location">Region</th><th data-key="Size">Size</th><th data-key="PowerState">State</th><th data-key="OSType">OS</th><th data-key="OSVersion">Version</th><th data-key="OsSource">Source</th><th data-key="EOLDate">EOL</th><th data-key="DaysToEOL">Days</th><th data-key="RiskLevel">Risk</th><th>Notes</th><th>📝</th></tr></thead><tbody id="vm-tbody"></tbody><tfoot id="vm-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-vmsku"><div class="section"><div class="section-header"><h2>⚙️ Deprecated VM SKUs</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="vmsku-count">0</span><button class="csv-btn" onclick="downloadCSV(vmSkuData,'vmsku')">⬇ CSV</button></div></div><div id="vmsku-kpis"></div><div class="legend-box" style="background:var(--orange-soft)"><strong>VM SKU Deprecation:</strong> Advisor + known deprecated series (A, Dv2, NV, NC, H).</div><div class="table-wrap"><table><thead id="vmsku-thead"><tr><th data-key="Subscription">Sub</th><th data-key="VMName">VM</th><th data-key="ResourceGroup">RG</th><th data-key="CurrentSKU">SKU</th><th>Problem</th><th>Migration</th><th data-key="RetireDate">Retire</th><th data-key="DaysToRetire">Days</th><th data-key="RiskLevel">Risk</th><th>Guide</th></tr></thead><tbody id="vmsku-tbody"></tbody><tfoot id="vmsku-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-appsvc"><div class="section"><div class="section-header"><h2>⚡ App Service Runtimes</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="app-count">0</span><button class="csv-btn" onclick="downloadCSV(appSvcData,'runtimes')">⬇ CSV</button></div></div><div id="appsvc-kpis"></div><div class="filter-bar" id="app-filters"></div><div class="table-wrap"><table><thead id="app-thead"><tr><th data-key="Subscription">Sub</th><th data-key="Name">App</th><th data-key="ResourceGroup">RG</th><th data-key="Kind">Kind</th><th data-key="Runtime">Runtime</th><th data-key="RuntimeVersion">Ver</th><th data-key="EOLDate">EOL</th><th data-key="DaysToEOL">Days</th><th data-key="RiskLevel">Risk</th><th data-key="MinTLS">TLS</th><th>HTTPS</th><th>Notes</th><th>📝</th></tr></thead><tbody id="app-tbody"></tbody><tfoot id="app-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-aks"><div class="section"><div class="section-header"><h2>☸ AKS Kubernetes</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="aks-count">0</span><button class="csv-btn" onclick="downloadCSV(aksData,'aks')">⬇ CSV</button></div></div><div id="aks-kpis"></div><div class="table-wrap"><table><thead id="aks-thead"><tr><th data-key="Subscription">Sub</th><th data-key="Name">Cluster</th><th data-key="ResourceGroup">RG</th><th data-key="Location">Region</th><th data-key="K8sVersion">K8s</th><th data-key="NodeCount">Nodes</th><th data-key="EOLDate">EOL</th><th data-key="DaysToEOL">Days</th><th data-key="RiskLevel">Risk</th><th>Notes</th><th>📝</th></tr></thead><tbody id="aks-tbody"></tbody><tfoot id="aks-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-sql"><div class="section"><div class="section-header"><h2>🗄 SQL Databases</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="sql-count">0</span><button class="csv-btn" onclick="downloadCSV(sqlData,'sql')">⬇ CSV</button></div></div><div id="sql-kpis"></div><div class="table-wrap"><table><thead id="sql-thead"><tr><th data-key="Subscription">Sub</th><th data-key="ServerName">Server</th><th data-key="DatabaseName">DB</th><th data-key="ResourceGroup">RG</th><th data-key="ServerVersion">Ver</th><th data-key="SKU">SKU</th><th data-key="MinTLS">TLS</th><th data-key="TLSStatus">Status</th><th data-key="RiskLevel">Risk</th><th>Notes</th><th>📝</th></tr></thead><tbody id="sql-tbody"></tbody><tfoot id="sql-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-tls"><div class="section"><div class="section-header"><h2>🔒 TLS/SSL Compliance</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="tls-count">0</span><button class="csv-btn" onclick="downloadCSV(tlsData,'tls')">⬇ CSV</button></div></div><div id="tls-kpis"></div><div class="filter-bar" id="tls-filters"></div><div class="table-wrap"><table><thead id="tls-thead"><tr><th data-key="Subscription">Sub</th><th data-key="ResourceType">Type</th><th data-key="Name">Name</th><th data-key="ResourceGroup">RG</th><th data-key="Location">Region</th><th data-key="MinTLS">TLS</th><th data-key="Status">Status</th><th data-key="RiskLevel">Risk</th><th>Notes</th><th>📝</th></tr></thead><tbody id="tls-tbody"></tbody><tfoot id="tls-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-retirements"><div class="section"><div class="section-header"><h2>📅 Azure Advisor Deprecations & Retirements</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="retire-count">0</span><button class="csv-btn" onclick="downloadCSV(retireData,'retirements')">⬇ CSV</button></div></div>
<div id="retire-kpis"></div>
<div class="legend-box" style="background:var(--primary-soft)"><strong>Master/Detail:</strong> Check problems in the top table to filter impacted resources below. All checked by default. Click 📄 for migration guide.</div>
<h3 style="font-size:13px;font-weight:700;margin-bottom:8px">📋 Problems (grouped)</h3>
<div class="table-wrap" id="retire-master" style="margin-bottom:16px"></div>
<h3 style="font-size:13px;font-weight:700;margin-bottom:8px">📦 Impacted Resources <span class="badge" id="retire-detail-count"></span></h3>
<div class="table-wrap"><table><thead><tr><th>Sub</th><th>Service</th><th>Resource</th><th>RG</th><th>Problem</th><th>Retire Date</th><th>Days Left</th><th>Risk</th><th>Guide</th><th>📝</th></tr></thead><tbody id="retire-detail-tbody"></tbody><tfoot id="retire-detail-tfoot"></tfoot></table></div>
</div></div>

<div class="page" id="page-lctags"><div class="section"><div class="section-header"><h2>🏷 Lifecycle Tag Compliance</h2><div style="display:flex;gap:6px;align-items:center"><span class="badge" id="lctag-count">0</span><button class="csv-btn" onclick="downloadCSV(lcTagData,'lifecycle_tags')">⬇ CSV</button></div></div><div id="lctag-kpis"></div><div class="legend-box"><strong>Tag:</strong> <code>$($script:LifecycleTagName)</code> — Expected format: <code>$($script:LifecycleTagFormat)</code>. <span class="tag tag-eol">Expired</span> past date <span class="tag tag-critical">Imminent</span> &lt;90d <span class="tag tag-orange">Approaching</span> &lt;6m <span class="tag tag-green">OK</span> 6m–3y <span class="tag tag-blue">Too far</span> &gt;3y <span class="tag tag-red">Missing/Empty/Bad</span></div><div class="filter-bar" id="lctag-filters"></div><div class="table-wrap"><table><thead id="lctag-thead"><tr><th data-key="Subscription">Subscription</th><th data-key="ResourceGroup">Resource Group</th><th data-key="Location">Region</th><th data-key="TagValue">Tag Value</th><th data-key="TagStatus">Status</th><th data-key="DaysLeft">Days Left</th><th data-key="RiskLevel">Risk</th><th data-key="ResourceCount">Resources</th><th>📝</th></tr></thead><tbody id="lctag-tbody"></tbody><tfoot id="lctag-tfoot"></tfoot></table></div></div></div>

<div class="page" id="page-executive"><div style="background:var(--card);border-radius:var(--radius);padding:28px;box-shadow:var(--shadow-lg);border:1px solid var(--border-subtle);max-width:800px;margin:0 auto"><div style="text-align:center;margin-bottom:24px;padding-bottom:18px;border-bottom:2.5px solid var(--border)"><div style="font-size:11px;color:var(--primary);font-weight:700;text-transform:uppercase;letter-spacing:1.5px;margin-bottom:4px">Executive Summary</div><h2 style="font-size:22px;font-weight:900">Azure Obsolescence — $reportDate</h2><p style="color:var(--muted);font-size:11px;margin-top:4px">$subCount subscriptions · Read-only</p></div><div id="exec-content"></div></div></div>

<div class="page" id="page-diag"><div class="section"><div class="section-header"><h2>🔧 Diagnostics</h2></div><div style="background:#0f172a;color:#38bdf8;font-family:var(--mono);font-size:10px;padding:16px;border-radius:10px;white-space:pre-wrap;max-height:400px;overflow-y:auto" id="diag-box"></div></div></div>
<footer>Azure Obsolescence Tracker · $reportDate · v1.0.0 · Read-only</footer>
<script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-datalabels@2.2.0/dist/chartjs-plugin-datalabels.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js"></script>
<script>
const vmData=$jsVMs;const appSvcData=$jsAppSvc;const aksData=$jsAKS;const sqlData=$jsSQL;const retireData=$jsRetirements;const vmSkuData=$jsVMSKU;const tlsData=$jsTLS;const lcTagData=$jsLifecycleTags;const diagLog="$diagText";const obsoScore=$valScore;const valEOL=$valEOL;const valCritical=$valCritical;const valHigh=$valHigh;const valMedium=$valMedium;const valLow=$valLow;const valTotalRes=$valTotalRes;const valTLSIssues=$valTLSIssues;const valRetireCrit=$valRetireCrit;const valVMSKUCount=$valVMSKUCount;const valLCTagCount=$valLCTagCount;const valLCTagIssues=$valLCTagIssues;const subCount=$subCount;
$jsBlock
</script></body></html>
"@

Write-Diag -Code "HTML" -Level "INFO" -Message "HTML report built (`$(`$htmlContent.Length) chars)."

# ==============================================================================
# 11. CREATE ATTACHMENT — Package HTML report as email attachment
# ==============================================================================
Write-Diag -Code "ATTACH" -Level "INFO" -Message "Creating email attachment..."
try {
    $htmlBytes      = [System.Text.Encoding]::UTF8.GetBytes($htmlContent)
    $htmlStream     = [System.IO.MemoryStream]::new($htmlBytes)
    $attachmentName = "AzureObsolescenceReport_$((Get-Date).ToString('yyyy-MM')).html"
    $attachment     = [System.Net.Mail.Attachment]::new($htmlStream, $attachmentName, "text/html")
    Write-Diag -Code "ATTACH" -Level "INFO" -Message "Attachment '$attachmentName' ready ($([math]::Round($htmlBytes.Length/1024,1)) KB)."
}
catch {
    Exit-WithError -Code "E009" -Message "Attachment creation failed: $_"
}

# ==============================================================================
# 12. SEND EMAIL — Deliver report via SMTP with KPI summary body
# ==============================================================================
# The email body ($kpiSummary) is a lightweight HTML with key metrics.
# The full interactive HTML report is sent as an attachment.
# SMTP credentials are read from Azure Automation Variables (see CONFIGURABLE PARAMETERS).
Write-Diag -Code "MAIL" -Level "INFO" -Message "Preparing email..."
try {
    $exportdate   = Get-Date
    $date         = $exportdate.ToString('MMMM yyyy', [System.Globalization.CultureInfo]'en-us')
    $emailsubject = $script:EmailSubjectTemplate -f $date

    $kpiSummary = @"
<html><body style="font-family:'Segoe UI',sans-serif;color:#1a1a2e;font-size:14px">
<div style="background:linear-gradient(135deg,#1e1b4b,#4338ca);color:#fff;padding:20px 28px;border-radius:8px 8px 0 0">
  <h2 style="margin:0">🛡️ Azure Obsolescence Report — $date</h2>
  <p style="margin:4px 0 0;opacity:.7;font-size:12px">Generated: $reportGenAt | Score: $valScore/100</p>
</div>
<div style="padding:20px 28px;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 8px 8px">
  <p>Please find the monthly Azure Obsolescence HTML report attached. Open in any browser.</p>
  <table style="border-collapse:collapse;width:100%;margin:16px 0">
    <tr><td style="padding:10px;background:#fef2f2;border-radius:6px;font-weight:700">💀 End-of-Life Resources</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#dc2626">$valEOL</td></tr>
    <tr><td style="padding:10px;background:#fff7ed;border-radius:6px;font-weight:700">🔥 Critical / High Risk</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#f97316">$valCritical critical / $valHigh high</td></tr>
    <tr><td style="padding:10px;background:#eff6ff;border-radius:6px;font-weight:700">📊 Total Resources Scanned</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#3b82f6">$valTotalRes</td></tr>
    <tr><td style="padding:10px;background:#fef2f2;border-radius:6px;font-weight:700">🔒 TLS Compliance Issues</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#ef4444">$valTLSIssues</td></tr>
    <tr><td style="padding:10px;background:#ecfeff;border-radius:6px;font-weight:700">📅 Service Retirements</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#06b6d4">$valRetireCount ($valRetireCrit already retired)</td></tr>
    <tr><td style="padding:10px;background:#fff7ed;border-radius:6px;font-weight:700">⚙️ Deprecated VM SKUs</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#f97316">$valVMSKUCount</td></tr>
    <tr><td style="padding:10px;background:#eff6ff;border-radius:6px;font-weight:700">🏷 Lifecycle Tag Issues</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#3b82f6">$valLCTagIssues / $valLCTagCount RGs</td></tr>
    <tr><td style="padding:10px;background:#f5f3ff;border-radius:6px;font-weight:700">🛡️ Obsolescence Score</td>
        <td style="padding:10px;text-align:right;font-size:20px;font-weight:800;color:#6366f1">$valScore / 100</td></tr>
  </table>
  <p style="color:#94a3b8;font-size:12px">⚠ Read-only. No changes applied. Generated by Azure Automation.</p>
</div>
</body></html>
"@

    $SmtpPort   = Get-SafeAutomationVariable -Name $script:SmtpPortVar
    $SmtpServer = Get-SafeAutomationVariable -Name $script:SmtpServerVar
    $SMTPPSWD   = Get-SafeAutomationVariable -Name $script:SmtpPasswordVar
    $smtpUser   = Get-SafeAutomationVariable -Name $script:SmtpFromVar
    $smtpTo     = Get-SafeAutomationVariable -Name $script:SmtpToVar

    $securePassword = ConvertTo-SecureString $SMTPPSWD -AsPlainText -Force
    $smtpClient             = New-Object Net.Mail.SmtpClient($SmtpServer, [int]$SmtpPort)
    $smtpClient.EnableSsl   = $true
    $smtpClient.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $securePassword)

    $mailMessage            = New-Object Net.Mail.MailMessage
    $mailMessage.From       = $smtpUser
    $mailMessage.To.Add($smtpTo)
    $mailMessage.Subject    = $emailsubject
    $mailMessage.IsBodyHtml = $true
    $mailMessage.Body       = $kpiSummary
    $mailMessage.Attachments.Add($attachment)

    $smtpClient.Send($mailMessage)
    Write-Diag -Code "MAIL" -Level "INFO" -Message "Email sent to '$smtpTo'."
}
catch {
    Exit-WithError -Code "E008" -Message "Email sending failed: $_"
}
finally {
    if ($null -ne $attachment) { $attachment.Dispose() }
    if ($null -ne $htmlStream) { $htmlStream.Dispose() }
}


# ==============================================================================
# 13. SUMMARY — Console output for Azure Automation job log
# ==============================================================================
$elapsed = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1)
Write-Diag -Code "DONE" -Level "INFO" -Message "Script completed in ${elapsed}s."
Write-Output "=============================================="
Write-Output " Azure Obsolescence Tracker v1.0.0 — SUMMARY"
Write-Output "=============================================="
Write-Output " Subscriptions     : $(@($subscriptions).Count)"
Write-Output " VMs scanned       : $valVMCount"
Write-Output " App Services      : $valAppSvcCount"
Write-Output " AKS clusters      : $valAKSCount"
Write-Output " SQL databases     : $valSQLCount"
Write-Output " TLS resources     : $valTLSCount"
Write-Output " Service retirements: $valRetireCount"
Write-Output " Deprecated VM SKUs : $valVMSKUCount"
Write-Output " Lifecycle tag RGs  : $valLCTagCount ($valLCTagIssues issues)"
Write-Output " ─────────────────────────────────────────────"
Write-Output " EOL resources     : $valEOL"
Write-Output " Critical          : $valCritical"
Write-Output " High              : $valHigh"
Write-Output " Medium            : $valMedium"
Write-Output " Low               : $valLow"
Write-Output " TLS issues        : $valTLSIssues"
Write-Output " Obsolescence Score: $valScore/100"
Write-Output " Duration          : ${elapsed}s"
Write-Output " Look-ahead        : $valLookAhead days"
Write-Output "=============================================="
