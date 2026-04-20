# 🛡️ Azure Obsolescence Tracker

> Runbook PowerShell pour Azure Automation qui analyse l'ensemble de vos abonnements Azure et génère un rapport HTML interactif couvrant les risques d'obsolescence des OS, runtimes, clusters AKS, bases SQL, conformité TLS et retraits de services planifiés par Microsoft.

---

## Table des matières

- [Fonctionnalités](#fonctionnalités)
- [Prérequis](#prérequis)
- [Déploiement](#déploiement)
- [Paramètres configurables](#paramètres-configurables)
- [Modules de collecte](#modules-de-collecte)
- [Stratégie des données de cycle de vie](#stratégie-des-données-de-cycle-de-vie)
- [Rapport HTML](#rapport-html)
- [Accès réseau requis](#accès-réseau-requis)
- [Surveillance et diagnostics](#surveillance-et-diagnostics)
- [Limitations connues](#limitations-connues)

---

## Fonctionnalités

| Module | Couverture |
|--------|-----------|
| **VM OS** | Windows Server, Windows 10/11, Ubuntu, RHEL, CentOS, Debian, SLES |
| **App Service Runtimes** | .NET, Node.js, Java, Python, PHP + conformité TLS/HTTPS |
| **AKS** | Version Kubernetes vs versions supportées par Azure |
| **SQL** | Version serveur + version TLS minimale |
| **Retraits de services** | Recommandations Azure Advisor `ServiceUpgradeAndRetirement` |
| **Dépréciations d'API** | Fraîcheur des versions d'API ARM (placeholder) |
| **Conformité TLS** | Storage Accounts, Application Gateways, Redis Cache |
| **SKU VM dépréciés** | Advisor + ARG, filtré sur dépréciations de série/SKU |
| **Tags de cycle de vie** | Conformité du tag `lifecycle` sur les Resource Groups |

Le rapport HTML généré inclut :
- 11 onglets de navigation (Dashboard, VM OS, VM SKUs, Runtimes, AKS, SQL, TLS, Retirements, Lifecycle Tags, Executive, Diag)
- Graphiques Chart.js interactifs (clic pour naviguer vers la page de détail)
- Tables triables/filtrables avec système d'annotations par ligne (persisté en localStorage)
- Export CSV de toutes les tables
- Export PDF via html2canvas + jsPDF
- Mode sombre avec persistance
- Recherche globale multi-tables
- Score d'obsolescence composite (0–100)
- Page Executive Summary pour reporting managérial

---

## Prérequis

### Azure

- **Azure Automation Account** avec un runbook PowerShell
- **Managed Identity** (User-Assigned recommandé, System-Assigned en fallback) avec le rôle **Reader** sur tous les abonnements cibles
- **PowerShell 7** sur le Runbook Worker (recommandé pour le traitement parallèle) — PS 5.1 est supporté mais séquentiel

### Modules PowerShell requis

Les modules suivants doivent être importés dans votre Automation Account :

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

### Variables Automation Account

Créez les variables suivantes dans **Automation Account → Variables** :

| Nom de la variable | Description | Chiffré |
|--------------------|-------------|---------|
| `MI_OBSO` | Client ID de la User-Assigned Managed Identity | Non |
| `SMTP_SERVER` | Hostname du serveur SMTP | Non |
| `SMTP_PORT` | Port SMTP (ex: `587`) | Non |
| `SMTP_FROM` | Adresse email expéditeur | Non |
| `SMTP_TO` | Adresse(s) email destinataire(s) | Non |
| `SMTP_PASSWORD` | Mot de passe SMTP | **Oui** |

> **Note :** Si la variable `MI_OBSO` est absente ou vide, le script bascule automatiquement sur la System-Assigned Managed Identity.

---

## Déploiement

### 1. Importer les modules

Dans votre Automation Account, accédez à **Modules → Parcourir la galerie** et importez chacun des modules listés ci-dessus.

### 2. Créer les variables

Accédez à **Variables** et créez toutes les variables décrites dans le tableau ci-dessus. Pensez à cocher **Chiffré** pour `SMTP_PASSWORD`.

### 3. Attribuer les rôles à la Managed Identity

```bash
# Pour chaque abonnement cible
az role assignment create \
  --assignee "<client-id-de-la-managed-identity>" \
  --role "Reader" \
  --scope "/subscriptions/<subscription-id>"
```

### 4. Créer le Runbook

1. Dans votre Automation Account, accédez à **Runbooks → Créer un runbook**
2. Type : **PowerShell**, Version runtime : **7.2** (recommandé)
3. Collez le contenu du script
4. **Publiez** le runbook

### 5. Planifier l'exécution mensuelle

1. Accédez au runbook → **Planifications → Ajouter une planification**
2. Fréquence : **Mensuelle** (ex: 1er de chaque mois à 07h00)
3. Liez la planification au runbook

---

## Paramètres configurables

Tous les paramètres se trouvent en tête de script dans la section `CONFIGURABLE PARAMETERS` :

### Seuils de risque (jours avant EOL)

```powershell
$script:CriticalDays  = 90    # 0-90 jours   → Critique (rouge)
$script:HighDays      = 180   # 91-180 jours  → Élevé (orange)
$script:MediumDays    = 365   # 181-365 jours → Moyen (bleu)
                               # >365 jours    → Faible (vert)
```

### Périmètre de scan

```powershell
# Fenêtre de prospection (jours dans le futur pour anticiper les EOL)
$script:LookAheadDays = 365

# Regex pour exclure certains abonnements (insensible à la casse)
$script:ExcludeSubPattern = "Visual Studio|Dev/Test"
```

### Tag de cycle de vie

```powershell
$script:LifecycleTagName          = "lifecycle"    # Nom du tag à surveiller
$script:LifecycleTagFormat        = "MM.yyyy"      # Format attendu (ex: 03.2027)
$script:LifecycleTagDisplayFormat = "MM/yyyy"      # Format d'affichage dans le rapport
$script:LifecycleTagExcludeSubs   = "..."          # Regex d'abonnements à exclure
$script:LifecycleTagExcludeRGs    = "NetworkWatcherRG|DefaultResourceGroup|..."
$script:LifecycleTagWarningDays   = 90             # < 90j → Critique
$script:LifecycleTagCautionDays   = 180            # < 180j → Élevé
$script:LifecycleTagMaxYears      = 3              # > 3 ans → "Too far"
```

### Email

```powershell
$script:EmailSubjectTemplate = "[Azure Obsolescence] Monthly Lifecycle Report — {0}"
$script:ReportTitle          = "Azure Obsolescence Tracker"
```

---

## Modules de collecte

### 4a — VM OS (`Get-VMObsolescence`)

Analyse les VMs via leur **Image Reference** (Publisher/Offer/SKU) en priorité, puis le tag `os-version` en fallback. Les OS reconnus : Windows Server, Windows 10/11, Ubuntu, RHEL, CentOS, Debian, SLES.

Le tag `os-version` est utilisé pour :
- **Corriger** la version détectée par l'image (priorité au tag si plus précis)
- **Combler** les lacunes sur les images custom ou marketplace sans publisher reconnu

Formats de tag acceptés : `Windows Server 2019`, `Ubuntu 22.04`, `RHEL 8`, etc.

### 4b — App Service Runtimes (`Get-AppServiceObsolescence`)

Détecte le runtime depuis `LinuxFxVersion`/`WindowsFxVersion` ou les propriétés individuelles (`JavaVersion`, `PhpVersion`, etc.). Vérifie également la version TLS minimale et l'activation de HTTPS-only.

### 4c — AKS (`Get-AKSObsolescence`)

Compare la version `major.minor` de chaque cluster à la liste des versions supportées, obtenue via l'API ARM Azure après authentification. Toute version absente de cette liste est considérée hors support (EOL).

### 4d — SQL (`Get-SQLObsolescence`)

Analyse les Azure SQL Servers : version moteur, TLS minimal. Azure SQL étant un service PaaS managé, la plupart des entrées seront en risque Faible sauf en cas de TLS déprécié.

### 4e — Retraits de services (`Get-AdvisorDeprecations`)

Reproduit la logique du **workbook Azure Advisor Service Retirement** en 3 étapes :
1. API Metadata Advisor → catalogue des services en fin de vie
2. API Recommendations Advisor par abonnement → ressources impactées
3. Azure Resource Graph (`advisorresources`) → source complémentaire et déduplication

### 4f/4h — SKU VM dépréciés (`Get-VMSKUDeprecations`)

Filtre les recommandations Advisor contenant `series`, `SKU` ou `deprecat` sur `Microsoft.Compute/virtualMachines`, en excluant les recommandations de rightsizing. Croise avec l'inventaire VM (module 4a) pour enrichir avec le SKU actuel.

### 4g — TLS/SSL (`Get-TLSCompliance`)

Vérifie la version TLS minimale sur : Storage Accounts, Application Gateways, Redis Cache. Toute valeur inférieure à TLS 1.2 est signalée comme `Deprecated`.

### 4i — Tags de cycle de vie (`Get-LifecycleTagCompliance`)

Analyse le tag configurable (défaut : `lifecycle`) sur tous les Resource Groups. Statuts possibles : `Missing`, `Empty`, `Bad format`, `Expired`, `Imminent`, `Approaching`, `Too far`, `OK`.

---

## Stratégie des données de cycle de vie

Les dates EOL sont chargées **dynamiquement** à l'exécution depuis [endoflife.date](https://endoflife.date) :

| Produit | Slug API |
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

Les versions AKS supportées sont récupérées via l'API ARM Azure (`/providers/Microsoft.ContainerService/locations/{loc}/kubernetesVersions`).

**Fallback :** si une API est inaccessible (NSG, pare-feu, proxy), des données codées en dur servent de filet de sécurité. Une entrée `[WARN][EOLAPI]` est écrite dans le log de diagnostic. Vérifiez l'onglet **Diag** du rapport ou les logs du job Automation pour détecter ce cas.

> Pensez à mettre à jour périodiquement les valeurs de fallback dans le script en les comparant aux données de [endoflife.date](https://endoflife.date) et [Microsoft Learn Lifecycle](https://learn.microsoft.com/lifecycle).

---

## Rapport HTML

Le rapport est un fichier HTML **auto-contenu** envoyé en pièce jointe par email. Il s'ouvre dans n'importe quel navigateur moderne, sans serveur ni dépendances locales (les CDN sont chargés à l'ouverture).

### Score d'obsolescence (0–100)

Le score est calculé ainsi :
- **60 %** — fraction de ressources à risque Faible/Inconnu
- **25 %** — pénalité pour ressources EOL et Critiques
- **15 %** — pénalité pour TLS déprécié et retraits critiques

Un score **≥ 70** est considéré sain (vert), **40–69** en vigilance (orange), **< 40** en alerte (rouge).

### Annotations

Chaque ligne de table dispose d'un bouton 📝 permettant d'ajouter une note personnelle, persistée en `localStorage` du navigateur.

---

## Accès réseau requis

L'Automation Worker nécessite un accès HTTPS sortant vers :

| Domaine | Usage |
|---------|-------|
| `endoflife.date` | Données de cycle de vie OS/Runtime/SQL |
| `fonts.googleapis.com` | Polices du rapport HTML |
| `cdn.jsdelivr.net` | Chart.js |
| `cdnjs.cloudflare.com` | jsPDF, html2canvas |

> En l'absence d'accès à `endoflife.date`, le script utilise les données de fallback et log un avertissement. Le rapport reste fonctionnel mais les dates EOL peuvent être légèrement dépassées.

---

## Surveillance et diagnostics

Chaque exécution produit des entrées structurées dans les **logs du job Automation** avec le format :

```
[2025-01-15 08:12:34] [INFO]  [AUTH]   Connected with User MI (ClientId: ...)
[2025-01-15 08:12:36] [INFO]  [EOLAPI] Fetching lifecycle data from endoflife.date...
[2025-01-15 08:12:37] [WARN]  [EOLAPI] Failed to fetch endoflife.date/ubuntu.json: ...
[2025-01-15 08:13:45] [INFO]  [KPI]    Obsolescence Score: 72/100
```

Les niveaux de log sont `INFO`, `WARN` et `ERROR`. Les codes d'erreur fatals (`E001`–`E010`) lèvent une exception et arrêtent le runbook.

L'onglet **Diag** du rapport HTML affiche également l'intégralité du log de l'exécution courante.

---

## Limitations connues

- **Lecture seule** : le script ne crée, modifie ni supprime aucune ressource Azure.
- **Module 4f (API versions)** : placeholder — ne produit pas encore de résultats dans le rapport.
- **AKS EOL dates** : l'API ARM Azure liste les versions supportées mais ne retourne pas de dates d'EOL explicites. Toute version absente de la liste est traitée comme hors support.
- **Azure SQL** : service PaaS managé par Microsoft — les versions moteur ne sont pas directement contrôlables. Le module se concentre sur la conformité TLS.
- **Annotations** : stockées en `localStorage` du navigateur. Elles ne se transfèrent pas d'un poste à l'autre et sont perdues si le cache est vidé.

---

## Auteur & versions

| Version | Changements |
|---------|-------------|
| **1.2.0** | Stratégie lifecycle data clarifiée, commentaires traduits en anglais, module 4i (Lifecycle Tags) ajouté, prérequis réseau documentés |
| **1.1.0** | Détection Windows 10/11 Desktop, dédup SKU VM, hauteur dynamique graphique OS, paramètres configurables |
| **1.0.0** | Version initiale : 7 modules de scan, rapport HTML, envoi email |

**Auteur :** K-zimir
