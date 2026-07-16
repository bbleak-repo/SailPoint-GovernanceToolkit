# IAM Application Integration Intake Toolkit

A toolkit that bridges application owners and IAM teams by collecting the data needed to onboard applications into **SailPoint** (access governance), **CyberArk** (privileged access management), and **Okta/Entra ID** (identity federation).

## The Problem

IAM teams need detailed technical information about every application to build integrations -- connector types, admin account details, authentication protocols, RBAC structures. Application owners know their apps but not IAM products. Today this data is gathered through ad-hoc emails and meetings, producing inconsistent results that slow onboarding.

## The Solution

Three tools that work together:

| Tool | What It Does | Who Uses It |
|------|-------------|-------------|
| **iam-intake-tool.html** | Browser-based wizard that asks plain-language questions and translates answers into IAM-actionable data | Application owners / SMEs |
| **Merge-IAMIntakeData.ps1** | Reads existing Excel questionnaires (any format), normalizes values, merges by app name, exports consolidated CSVs | IAM team |
| **Sync-SharePointSite.ps1** | Downloads/uploads files from SharePoint Server on-prem (2013+) via REST API | IAM team |

### Workflow

```
1. App owners fill out iam-intake-tool.html  --or--  Excel questionnaires on SharePoint
                              |                                    |
                              v                                    v
                     CSV/JSON exports              Sync-SharePointSite.ps1 downloads .xlsx
                              |                                    |
                              +------>  Merge-IAMIntakeData.ps1  <-+
                                               |
                                               v
                              Consolidated CSVs + HTML report
                                               |
                              +----------------+----------------+
                              |                |                |
                              v                v                v
                        SailPoint         CyberArk        Okta/Entra
                        onboarding        onboarding      migration
```

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for setup instructions.

## Tools at a Glance

### HTML Intake Tool (`iam-intake-tool.html`)

Self-contained, zero-dependency HTML file (108 KB). Open in any browser, works offline.

- 7-step wizard with live integration map summary panel
- "I don't know" answers trigger simpler rephrased questions
- Known App Catalog (15 pre-configured apps: ServiceNow, Salesforce, AWS, etc.)
- Login page analysis via bookmarklet or paste-source
- Auto-derives: SailPoint integration pattern (1-4), file delivery method (A-F), CyberArk HLA priority (P0-P3), Okta-to-Entra migration gaps
- Exports 5 CSVs + JSON, supports portfolio mode (multiple apps per session)
- localStorage persistence -- survives browser refresh

### Excel Consolidator (`Merge-IAMIntakeData.ps1`)

PowerShell 5.1+. Requires `ImportExcel` module (no Excel installation needed).

- **Adaptive format detection** -- auto-classifies each Excel sheet as Tabular, Key-Value, or Multi-Section
- **Fuzzy canonical mapping** -- 50+ fields with ~200 aliases, word-overlap scoring (handles "How do users authenticate?" matching to `authMethod`)
- **Value normalization** -- "Y", "yes", "TRUE", "1" all become "Yes"; "saml 2.0" becomes "SAML"
- **Cross-product merge** -- joins SailPoint + CyberArk + Okta records by app name
- **Schema learning** -- save detected mappings for reuse on future runs
- Outputs: consolidated CSV, per-product CSVs (SailPoint, CyberArk, Okta/Entra), HTML report, mapping log

### SharePoint Sync (`Sync-SharePointSite.ps1`)

PowerShell 5.1+. No external modules -- uses built-in `Invoke-WebRequest` with SharePoint REST API.

- Download, Upload, or bidirectional Sync
- 3-layer auth: explicit credential, default Windows (Kerberos/NTLM), interactive prompt
- Deep folder path support (`IT/Apps/IAM/AppsToMigrate/App1/...`)
- Conflict resolution: NewerWins, LocalWins, RemoteWins, ReportOnly
- `-WhatIf` for both download AND upload directions
- File filtering (`-Include "*.xlsx","*.docx"`, `-Exclude "~$*"`)
- Retry with exponential backoff, JSON Lines logging

## Documentation

| Document | Description |
|----------|-------------|
| [QUICKSTART.md](QUICKSTART.md) | 5-minute setup guide |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Architecture, conventions, how to extend |
| [docs/USER-GUIDE.html](docs/USER-GUIDE.html) | Full playbook (51 sections, open in browser) |

## Requirements

| Component | Requirement |
|-----------|-------------|
| HTML Intake Tool | Any modern browser (Chrome, Edge, Firefox, Safari) |
| Merge-IAMIntakeData.ps1 | PowerShell 5.1+ and `ImportExcel` module |
| Sync-SharePointSite.ps1 | PowerShell 5.1+ (no additional modules) |
| SharePoint target | SharePoint Server 2013, 2016, 2019, or SE (NOT SharePoint Online) |

## Consolidator Output Summary

| File | Purpose |
|------|---------|
| `IAM-Intake-Consolidated-<date>.xlsx` | Single workbook: Master, per-product sheets, RolesGroups, Accounts, Conflicts, Unmapped, Log |
| `IAM-Intake-Data.json` (+ dated copy) | Canonical machine-readable payload: per-app fields, details, conflicts, provenance |
| `IAM-Intake-Browser-<date>.html` | Self-contained app browser: dropdown/search, per-app sections, conflicts panel |
| `IAM-Intake-Consolidated-<date>.csv` | Flat consolidated CSV (all apps x all fields) |
| `IAM-Intake-SailPoint/CyberArk/OktaEntra-<date>.csv` | Per-product CSVs consumed by the sibling toolkits |
| `IAM-Intake-Mapping-<date>.json` | Processing log (formats detected, mapping scores) |

## HTML Intake Tool CSV Exports

| File | Columns | Purpose |
|------|---------|---------|
| `sailpoint-onboarding.csv` | 24 | Integration pattern, API/CSV capability, roles, v2 field availability |
| `cyberark-onboarding.csv` | 17 | HLA priority/tier, CPM/PSM approach, admin auth, marketplace status |
| `okta-entra-migration.csv` | 12 | SignOnMode, SCIM, migration target, Entra equivalent, gaps, wave |
| `login-analysis.csv` | 10 | Detected form fields, SAML/OIDC indicators, IdP, MFA signals |
| `app-inventory-master.csv` | All | Unified denormalized view across all products |

## License

Internal use only. Not for external distribution.
