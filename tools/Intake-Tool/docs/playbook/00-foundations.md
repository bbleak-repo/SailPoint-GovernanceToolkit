# IAM Application Integration Intake -- Foundations

## 1. What This Is

The IAM Application Integration Intake toolkit helps application owners provide the data that Identity & Access Management teams need to onboard applications into **SailPoint** (access governance), **CyberArk** (privileged access management), and **Okta/Entra ID** (identity federation and SSO).

It consists of three tools:

- **IAM Intake Tool** (`iam-intake-tool.html`) -- A self-contained HTML wizard that app owners fill out in their browser. Speaks their language (URLs, login methods, roles), not IAM jargon. Exports structured CSV and JSON files.
- **Intake Data Consolidator** (`Merge-IAMIntakeData.ps1`) -- A PowerShell script that adaptively reads existing Excel and Word questionnaires (any format -- tabular, key-value, structured templates, or .docx), normalizes the data, merges SailPoint, CyberArk, and Okta/Entra entries by application name, and produces a consolidated XLSX workbook, interactive HTML browser, JSON payload, and per-product CSVs.
- **SharePoint Sync Tool** (`Sync-SharePointSite.ps1`) -- A PowerShell script for bidirectional file sync with SharePoint Server on-premises (2013+) via REST API. Downloads questionnaire files from deep folder paths and uploads consolidated reports back.

Together, these tools replace ad-hoc emails and meetings with structured, repeatable data collection that feeds directly into IAM onboarding workflows.

## 2. Prerequisites

### HTML Intake Tool

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| Browser | Any modern browser | Chrome, Edge, Firefox, Safari (2020+) |
| Network | None | Works fully offline -- save and open locally |
| Authentication | None | No backend, no login required |

### PowerShell Consolidator

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| PowerShell | 5.1 (Windows) or 7.x (cross-platform) | Windows PowerShell ships with Windows 10/11 |
| ImportExcel module | Latest | `Install-Module ImportExcel -Scope CurrentUser` |
| Excel | NOT required | ImportExcel uses EPPlus (.NET library), not COM |
| Network | File system access to Excel files | Local, network share, or mapped drive |

## 3. Installation

### HTML Intake Tool

No installation required. Distribute `iam-intake-tool.html` to app owners via:

- Email attachment
- SharePoint/OneDrive shared link
- Internal documentation portal
- Network file share

The file is self-contained (108 KB) with zero external dependencies. App owners open it in any browser.

### PowerShell Consolidator

1. Copy `Merge-IAMIntakeData.ps1` to a working directory on the IAM team's Windows workstation or server.

2. Install the ImportExcel module (one-time):

```powershell
Install-Module ImportExcel -Scope CurrentUser
```

3. Verify:

```powershell
Get-Module -ListAvailable -Name ImportExcel
```

## 4. Architecture Overview

The data flows through three stages:

```
STAGE 1: Data Collection
  App Owner fills out iam-intake-tool.html  -or-
  App Owner fills out Excel/Word questionnaire (on SharePoint or local)

STAGE 2: Data Consolidation
  Sync-SharePointSite.ps1 downloads .xlsx/.docx from SharePoint (optional)
  Merge-IAMIntakeData.ps1 reads all formats, normalizes, merges by app name
  Outputs: XLSX workbook, HTML browser, JSON payload, per-product CSVs

STAGE 3: Product Onboarding
  SailPoint: IAM-Intake-SailPoint-<date>.csv -> GovernanceToolkit
  CyberArk:  IAM-Intake-CyberArk-<date>.csv -> Platform/Safe setup
  Okta:      IAM-Intake-OktaEntra-<date>.csv -> Migration toolkit
```

### Consolidator Output Files

| File | Description |
|------|-------------|
| `IAM-Intake-Consolidated-<date>.xlsx` | Multi-sheet workbook: Master, per-product, RolesGroups, Accounts, Conflicts, Unmapped, Log |
| `IAM-Intake-Browser-<date>.html` | Interactive HTML app browser with dropdown search and per-app sections |
| `IAM-Intake-Data.json` | Stable-name JSON payload (also date-stamped copy) |
| `IAM-Intake-Consolidated-<date>.csv` | Flat consolidated CSV (all apps, all fields) |
| `IAM-Intake-SailPoint/CyberArk/OktaEntra-<date>.csv` | Per-product CSVs for downstream toolkits |
| `IAM-Intake-Mapping-<date>.json` | Processing log (formats detected, mapping scores) |

### What Each Product Gets

| Product | Key Data Points | Downstream Action |
|---------|----------------|-------------------|
| **SailPoint** | Integration pattern (1-4), file delivery method (A-F), API capability, RBAC roles, v2 field availability | Connector selection, disconnected app onboarding, campaign setup |
| **CyberArk** | HLA priority (P0-P3), tier (0-3), CPM/PSM approach, admin auth method, MFA type, marketplace availability | Platform import, safe creation, connector deployment |
| **Okta/Entra** | Current IdP, signOnMode, SCIM status, migration target, gap analysis, wave assignment | App migration planning, Entra Enterprise App/App Registration setup |

## 5. How the Decision Trees Work

The HTML intake tool automatically derives IAM recommendations based on app owner answers. No IAM knowledge is required from the app owner.

### SailPoint Integration Pattern

The tool asks: "Does the app have an API?" and "Can the app export a list of users?"

| API? | Write? | CSV Export? | Result |
|------|--------|-------------|--------|
| Yes | Yes | -- | Pattern 3: Web Services Connector |
| Yes | No | -- | Pattern 4: Governance-Only |
| No | -- | Yes | Pattern 2: Flat File / CSV |
| No | -- | No | Pattern 4: Governance-Only (custom) |

If a known app is selected from the catalog (e.g., ServiceNow), the tool auto-assigns Pattern 1 (Direct Connector) because a native SailPoint connector exists.

### SailPoint File Delivery (Pattern 2 only)

| Has API? | Delivery Method | Result |
|----------|----------------|--------|
| Yes (REST/SOAP) | Any | Pattern A: MuleSoft API Integration |
| Yes | SFTP/Network | Pattern C: MuleSoft + GoAnywhere Combined |
| No | SFTP/Network | Pattern B: GoAnywhere MFT |
| No | Database query | Pattern D: Database Direct Export |
| No | Manual only | Pattern E: Manual Fallback |
| -- | Mainframe | Pattern F: Mainframe (JCL/REXX) |

### CyberArk HLA Classification

Six yes/no questions about the privileged account produce a score (0-6):

| Score | Priority | Tier | Meaning |
|-------|----------|------|---------|
| 5-6 or manages infrastructure | P0 | 0 | Control plane -- immediate onboarding |
| 3-4 | P1 | 1 | Server/app admin -- near-term |
| 2 | P2 | 2 | Limited scope -- standard timeline |
| 0-1 | P3 | 3 | Low risk -- planned |

### Okta-to-Entra Migration

| Okta signOnMode | Entra Equivalent | Typical Gaps |
|-----------------|-----------------|--------------|
| SAML 2.0 | Enterprise Application (SAML SSO) | Conditional Access rebuild, per-app email domain |
| OIDC | App Registration (OIDC) | Redirect URI re-registration, token policies |
| SWA | Enterprise App (Password-based SSO) | Different field capture, browser extension needed |
| Bookmark | MyApps linked app | Minimal -- recreate link |

## 6. Known App Catalog

The HTML intake tool includes 15 pre-configured applications. When an app owner selects one, wizard fields auto-populate with known answers:

| Application | SailPoint Pattern | CyberArk Marketplace | Okta OIN |
|-------------|-------------------|----------------------|----------|
| ServiceNow | 1 (Direct Connector) | Yes | Yes |
| Salesforce | 1 (Direct Connector) | Yes | Yes |
| AWS IAM | 1 (Direct Connector) | Yes | Yes |
| Microsoft Entra ID | 1 (Direct Connector) | Yes | Yes |
| GitHub Enterprise | 3 (Web Services) | Yes | Yes |
| Workday | 1 (Direct Connector) | Yes | Yes |
| Splunk | 3 (Web Services) | Yes | Yes |
| PagerDuty | 3 (Web Services) | No | Yes |
| SAP ECC | 1 (VA-Based) | Yes | No |
| Oracle EBS | 1 (VA-Based) | Yes | No |
| Active Directory | 1 (VA-Based) | Yes | No |
| Jira / Confluence | 3 (Web Services) | No | Yes |
| Slack Enterprise | 3 (Web Services) | No | Yes |
| Box | 3 (Web Services) | No | Yes |
| CrowdStrike | 4 (Governance-Only) | No | Yes |

> **Tip:** If your application is not in the catalog, the wizard still works -- you just answer each question manually instead of having fields pre-filled.

## 7. CSV Output Schemas

### sailpoint-onboarding.csv (24 columns)

Core fields: `appName`, `appUrl`, `deploymentType`, `iscIntegrationPattern`, `patternConfidence`, `fileDeliveryPattern`, `nativeConnectorAvailable`, `hasApi`, `apiType`, `apiSupportsWrite`, `canExportCsv`, `csvDeliveryMethod`, `estimatedAccountCount`, `rbacRolesIdentified`, `roleCount`, `dataDeliveryScheduleCapable`, `hasAdIntegration`

v2 fields: `v2AccountTypeAvailable`, `v2CreatedDateAvailable`, `v2LastLoginAvailable`, `v2EntitlementOwnerAvailable`, `v2EntitlementTypeAvailable`, `v2EntitlementRiskLevelAvailable`

### cyberark-onboarding.csv (17 columns)

`appName`, `appUrl`, `hlaPriority`, `tier`, `hlaScore`, `accountTypes`, `adminCount`, `authMethod`, `mfaType`, `canChangePasswordViaApi`, `cpmApproach`, `adminAccessMethod`, `psmApproach`, `marketplaceConnectorAvailable`, `estimatedEffortDays`, `platformCategory`, `notes`

### okta-entra-migration.csv (12 columns)

`appName`, `appUrl`, `currentIdp`, `signOnMode`, `hasScimProvisioning`, `oktaAppLabel`, `migrationTarget`, `entraEquivalentConfig`, `knownGaps`, `gapCount`, `recommendedMigrationWave`, `notes`

### app-inventory-master.csv

Unified denormalized view combining all product-specific columns with shared application identity fields. Each product's columns are prefixed (`sp_`, `ca_`, `okta_`, `login_`).

## 8. Data Persistence

### HTML Intake Tool

Data is stored in the browser's `localStorage`. This means:

- Data survives page refreshes and browser restarts
- Data is per-browser, per-device (not synced)
- Clearing browser data erases stored sessions
- localStorage has a 5 MB limit (supports ~50 applications)

> **Important:** Always export your data (CSV or JSON) before clearing browser data. The "Reset" button in the header clears all stored data permanently.

### PowerShell Consolidator

The consolidator is stateless -- it reads Excel files, processes them, and writes output files. No persistent state is maintained between runs.

The `-SaveSchema` flag saves the detected column mapping for reuse. The `-SchemaPath` flag loads a previously saved schema to skip auto-detection on subsequent runs.

## 9. Security Considerations

- The HTML intake tool runs entirely in the browser. No data is sent to any server.
- CSV exports may contain application URLs, owner names, and admin account details. Handle as **Internal/Confidential**.
- The login page bookmarklet captures page metadata (form fields, URL parameters) but not passwords or session tokens.
- The PowerShell consolidator reads from and writes to the local file system only.
- Excel files containing questionnaire data should be stored on access-controlled shares.

## 10. Getting Help

| Resource | Location |
|----------|----------|
| This playbook | `docs/USER-GUIDE.html` |
| HTML tool source | `iam-intake-tool.html` (view source for implementation details) |
| PowerShell script | `Merge-IAMIntakeData.ps1` (run with `-Help` for parameter documentation) |
| SailPoint patterns | `SailPoint/docs/connectors/INTEGRATION_PATTERNS.md` |
| CyberArk HLA guide | `CyberARK/docs/cyberark-hla-account-classification.md` |
| Okta migration toolkit | `Okta/okta-app-migration/` |
