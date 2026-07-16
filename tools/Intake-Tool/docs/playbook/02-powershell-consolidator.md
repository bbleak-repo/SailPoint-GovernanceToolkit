# PowerShell Consolidator -- Reference Guide

## Overview

`Merge-IAMIntakeData.ps1` reads existing Excel and Word questionnaires filled out by application teams, adaptively detects their format, maps fields to canonical names using fuzzy matching, normalizes values, and produces a consolidated XLSX workbook, interactive HTML browser, JSON payload, and per-product CSVs.

The script handles six format variants without requiring any configuration:

| Format | Detected By | Description |
|--------|-------------|-------------|
| **Structured** | Column vocabulary matching (`$script:StructuredHeaderRoles`) | Formal templates with banner rows, Q&A blocks, contacts, account tables. Answer taken from Responses/Answer column; guidance columns ignored. |
| **List** | Sheet name matches list patterns (roles, groups, entitlements) | Rows aggregate into app-level fields (`sp_rbacRoles`, `adGroups`, counts) |
| **Tabular** | 3+ uniformly filled columns, multiple data rows | One application record per row |
| **KeyValue** | 2-3 columns, question-like text in column A | One record per sheet |
| **MultiSection** | Key-value plus section markers (===, ---, all-caps) | Section-prefixed keys |
| **Docx** | `.docx` file extension | Tables extracted from `word/document.xml`: entitlement-schema tables become groups/roles, 2-column tables become key/value pairs |

## 1. Quick Start

```powershell
# First run -- auto-detect everything, save schema for reuse
.\Merge-IAMIntakeData.ps1 -Path \\server\IAM-Questionnaires -SaveSchema

# Subsequent runs -- reuse learned schema
.\Merge-IAMIntakeData.ps1 -Path \\server\IAM-Questionnaires -SchemaPath .\schema.json
```

The script always produces the XLSX workbook, HTML browser, JSON payload, and all CSVs. No flags needed.

## 2. Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Path` | string | Yes | -- | Directory containing .xlsx/.docx files, or a single file path |
| `-OutputPath` | string | No | `.\IAM-Intake-Consolidated` | Directory for output files (created if missing) |
| `-Product` | string | No | `All` | Filter per-product CSVs: `All`, `SailPoint`, `CyberArk`, `OktaEntra` |
| `-ShowUnmapped` | switch | No | -- | Display unmapped field names in console output |
| `-SchemaPath` | string | No | -- | Path to a previously saved schema JSON for reuse |
| `-SaveSchema` | switch | No | -- | Save detected column mappings as a reusable schema JSON |
| `-DryRun` | switch | No | -- | Analyze files and show results without writing output |

> **Note:** `-IncludeHtml` is accepted for backward compatibility but is no longer needed -- the HTML browser is always generated.

## 3. Adaptive Format Detection

### Detection Priority

The script evaluates each file/sheet in this order:

1. **Docx check**: If the file extension is `.docx`, bypass all sheet logic -- parse tables from `word/document.xml`
2. **List sheet check**: If the sheet name matches a list pattern (`role`, `rbac`, `group`, `entitlement`, `permission`, `membership`), treat as a list of roles/groups and aggregate
3. **Structured check**: Re-import the sheet with `-NoHeader`, scan rows against the structured header vocabulary. If any row yields 2+ vocabulary hits with a `key` or `acctName` role, classify as Structured
4. **Fingerprint scoring**: For everything else, score as Tabular vs KeyValue vs MultiSection based on column fill rates and text patterns

### Structured Format (Templates)

The structured parser handles formal questionnaire templates that have:
- **Banner rows**: Section headers in all-caps or styled text
- **Q&A blocks**: Question in one column, answer in a Responses/Answer column, guidance columns (Description, Options, Instructions) ignored
- **Contact blocks**: Name(s) and Email(s) columns
- **Account tables**: Rows with Account Name, Account Type, Interactive/Service classification. Rows marked "EXAMPLE ENTRY" are skipped.
- **Unknown sub-tables**: Preserved as `_detail_*` JSON blobs

The parser discovers column roles from header captions using `$script:StructuredHeaderRoles`, not fixed column positions. This makes it layout-agnostic -- columns can be in any order.

### Docx Format (Word Documents)

Word .docx files are opened as ZIP archives and the `word/document.xml` is parsed. Three types of tables are recognized:

| Table Type | Detection | Extraction |
|-----------|-----------|------------|
| Entitlement schema | First row contains "entitlement type" | Rows classified as groups or roles based on type column |
| Two-column KV | 80%+ of rows have exactly 2 cells | Key-value pairs added directly to record |
| Multi-column | Everything else | Preserved as `_detail_*` JSON |

No Word installation is required -- uses `System.IO.Compression.ZipFile` (built into .NET).

### List Sheets (Roles/Groups)

Sheets named with list patterns (case-insensitive: role, rbac, group, entitlement, permission, membership) are aggregated:

- **Group sheets** (name matches `group` or `membership`): Values become `adGroups` (semicolon-joined) and `adGroupCount`
- **Role sheets** (everything else): Values become `sp_rbacRoles` (semicolon-joined) and `sp_roleCount`
- Full per-row detail is preserved as `_detail_*` JSON

List sheet records inherit the app name from other sheets in the same workbook.

## 4. App Identity and Merge

### Filename-Anchored Identity

Files named `<AppName>_<Template>.xlsx` (e.g., `Versify_CyberArk Questionnaire.xlsx`) carry the app identity in the filename. The script extracts the leading app name token by stripping known template suffixes (questionnaire, cyberark, sailpoint, okta, intake, onboarding).

The filename anchor **wins over in-sheet names**, which often hold database or instance names rather than the business application name.

### Normalized Merge Key

App names are normalized aggressively for merge:
- Parentheticals stripped: `ServiceNow (SNOW)` -> `ServiceNow`
- Domain suffixes stripped: `Salesforce.com` -> `Salesforce`
- Company suffixes stripped: `Acme Inc` -> `Acme`
- Case-insensitive, all non-alphanumeric removed

Result: `"Salesforce.com"`, `"Salesforce"`, and `"salesforce"` all merge into one record.

### Conflict Tracking

When two source records disagree on a canonical field, the first value is kept and the disagreement is recorded:

- `_conflictCount`: Number of field-level disagreements
- `_conflicts`: Human-readable summary (e.g., `"authMethod: kept 'SAML', ignored 'OIDC' (from cyberark-questionnaire.xlsx)"`)
- `_nameVariants`: All raw app name spellings found across sources

Conflicts appear in the XLSX Conflicts sheet, the JSON `conflicts` array, and the HTML browser's provenance card.

## 5. Value Normalization

After canonical mapping, values are normalized to consistent forms:

| Field Type | Raw Values | Normalized |
|-----------|-----------|------------|
| Boolean fields | yes, Y, TRUE, 1, yep, enabled | Yes |
| Boolean fields | no, N, FALSE, 0, nope, disabled | No |
| Boolean fields | unknown, unsure, N/A, TBD, ? | Unknown |
| `deploymentType` | cloud, hosted, cloud-hosted | SaaS |
| `deploymentType` | on-prem, on-premises, self-hosted | On-Prem |
| `authMethod` | saml, saml 2.0, saml2 | SAML |
| `authMethod` | oidc, openid connect, oauth | OIDC |
| `mfaType` | totp, authenticator, google auth | Authenticator App |
| `ca_hlaPriority` | p0, critical, tier 0 | P0 |
| `okta_signOnMode` | saml_2_0, saml 2.0 | SAML 2.0 |

Boolean normalization applies to: `hasMfa`, `hasApi`, `adIntegration`, `sp_canExportCsv`, `sp_apiSupportsWrite`, `ca_canChangePasswordViaApi`, `ca_marketplace`, all `ca_modify*/manage*/sensitive*` fields, and `okta_hasScimProvisioning`.

## 6. Fuzzy Canonical Mapping

Each column name or question text is matched against ~200 aliases across 50+ canonical fields:

1. **Exact alias match** = 1.0 score
2. **Coverage-weighted containment** = 0.85 score (longer, more specific aliases win)
3. **Word overlap** = Jaccard coefficient
4. **Partial word match** = 0.7 bonus for prefix matches

Fields scoring below 0.40 are flagged as unmapped.

### Canonical Field Categories

**Shared**: `appName`, `appUrl`, `vendor`, `deploymentType`, `estimatedUsers`, `appOwnerName`, `appOwnerEmail`, `authMethod`, `hasMfa`, `mfaType`, `hasApi`, `adIntegration`, `description`

**SailPoint** (prefixed `sp_`): `sp_integrationPattern`, `sp_connectorType`, `sp_canExportCsv`, `sp_csvDeliveryMethod`, `sp_fileDeliveryMethod`, `sp_rbacRoles`, `sp_roleCount`, `sp_apiType`, `sp_apiSupportsWrite`, `sp_v2AccountType`, `sp_v2LastLogin`, `sp_v2RiskLevel`

**CyberArk** (prefixed `ca_`): `ca_hlaPriority`, `ca_tier`, `ca_accountTypes`, `ca_adminCount`, `ca_adminAuthMethod`, `ca_adminAccessMethod`, `ca_canChangePasswordViaApi`, `ca_adminMfaType`, `ca_cpmApproach`, `ca_psmApproach`, `ca_marketplace`, `ca_platformCategory`, `ca_modifySecurity`, `ca_manageUsers`, `ca_sensitiveData`, `ca_impactScope`, `ca_managesInfra`

**Okta/Entra** (prefixed `okta_`): `okta_currentIdp`, `okta_signOnMode`, `okta_hasScimProvisioning`, `okta_appLabel`, `okta_migrationTarget`, `okta_entraEquivalent`, `okta_knownGaps`, `okta_migrationWave`, `okta_conditionalAccess`, `okta_groupAssignments`, `okta_mfaPolicy`

> **Tip:** To teach the parser a new template vocabulary, extend `$script:StructuredHeaderRoles` (for column captions) and `$script:CanonicalFields` (for question text). Longer, more specific aliases always win over generic words.

## 7. Detail Fields (`_detail_*`)

Structured multi-row data that cannot be flattened into a single CSV cell is preserved as compact JSON blobs in `_detail_*` properties.

Sources:
- **Structured sheets**: Unrecognized sub-tables and account tables
- **List sheets**: Full per-row data from role/group lists
- **Docx files**: Unknown multi-column tables and entitlement schema tables

These are consumed by:
- **XLSX workbook**: `RolesGroups` and `Accounts` sheets flatten the detail JSON into tabular rows
- **HTML browser**: Rendered as dynamic tables within each app's section
- **JSON payload**: Included in each app's `details` dictionary

`_detail_*` fields are excluded from flat CSVs.

## 8. Output Files

### Always Generated

```
{OutputPath}/
  IAM-Intake-Consolidated-<date>.xlsx      -- Multi-sheet workbook (see below)
  IAM-Intake-Browser-<date>.html           -- Interactive HTML app browser
  IAM-Intake-Data.json                     -- Stable-name JSON payload
  IAM-Intake-<date>.json                   -- Date-stamped copy of JSON
  IAM-Intake-Consolidated-<date>.csv       -- Flat CSV, all apps, all fields
  IAM-Intake-SailPoint-<date>.csv          -- Shared + SailPoint columns
  IAM-Intake-CyberArk-<date>.csv           -- Shared + CyberArk columns
  IAM-Intake-OktaEntra-<date>.csv          -- Shared + Okta/Entra columns
  IAM-Intake-Mapping-<date>.json           -- Processing log
```

### Conditionally Generated

```
  IAM-Intake-Schema-<date>.json            -- (if -SaveSchema)
```

### XLSX Workbook Sheets

| Sheet | Contents |
|-------|----------|
| `Master` | All canonical fields plus name variants, conflict count, source files |
| `SailPoint` | Shared + SailPoint columns |
| `CyberArk` | Shared + CyberArk columns |
| `OktaEntra` | Shared + Okta/Entra columns |
| `RolesGroups` | Flattened role/group detail from `_detail_*` (excludes account tables) |
| `Accounts` | Flattened account detail: name, type, class, password dependencies, users |
| `Conflicts` | Cross-source disagreements: field, kept value, ignored value, source file |
| `Unmapped` | Questions the mapper could not resolve: question text and answer |
| `Log` | Processing log: file, sheet, format detected, score, column count, record count |

Sheets with zero rows are automatically omitted.

### HTML App Browser

Self-contained HTML with:
- Dropdown/search for selecting an application
- Per-app sections showing all canonical fields organized by product
- Provenance card (source files, name variants, confidence)
- Conflicts panel highlighting cross-source disagreements
- Dynamic detail tables for roles, groups, and accounts
- Print-friendly

### JSON Payload

Machine-readable format containing per-app records with:
- All canonical fields
- Detail sub-tables (parsed from `_detail_*` JSON)
- Conflicts array (field, kept, ignored, source)
- Unmapped questions
- Schema version and generation metadata

## 9. Schema Learning and Reuse

```powershell
# Save after first run
.\Merge-IAMIntakeData.ps1 -Path .\questionnaires -SaveSchema

# Reuse on subsequent runs
.\Merge-IAMIntakeData.ps1 -Path .\new-batch -SchemaPath .\IAM-Intake-Schema-2026-07-15.json
```

Benefits: faster processing, 100% confidence scores, consistent mapping, handles non-standard templates. Edit the JSON to fix incorrect mappings before reuse.

## 10. Examples

### Basic Consolidation

```powershell
.\Merge-IAMIntakeData.ps1 -Path C:\IAM\Questionnaires
```

### Full Run with Schema Save

```powershell
.\Merge-IAMIntakeData.ps1 -Path \\fileserver\iam-intake `
    -OutputPath C:\IAM\Reports `
    -SaveSchema -ShowUnmapped
```

### Process Only CyberArk Questionnaires

```powershell
.\Merge-IAMIntakeData.ps1 -Path .\questionnaires -Product CyberArk
```

### Dry Run (Preview Only)

```powershell
.\Merge-IAMIntakeData.ps1 -Path .\questionnaires -DryRun
```

### Mixed Excel and Word Files

```powershell
# The script automatically handles .xlsx and .docx in the same directory
.\Merge-IAMIntakeData.ps1 -Path C:\IAM\MixedFormats -SaveSchema
```

## 11. Extending the Parser

### Adding a New Canonical Field

1. Add to `$script:CanonicalFields` with aliases (longer, more specific aliases rank higher):
```powershell
newField = @('full alias text', 'shorter alias', 'question text verbatim')
```

2. If boolean, add to `$script:BooleanFields`
3. If custom normalization needed, add rule to `$script:NormalizationRules`
4. Add to the appropriate per-product column list in the output section

### Teaching a New Template Vocabulary

Add column caption mappings to `$script:StructuredHeaderRoles`:
```powershell
'new caption text' = 'role'  # role = key, value, guidance, detail, name, email, acctName, etc.
```

## 12. Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "ImportExcel module not installed" | Module missing | `Install-Module ImportExcel -Scope CurrentUser` |
| "No .xlsx files found" | Wrong path or files are .xls (old format) | Check path; convert .xls to .xlsx in Excel |
| Low mapping confidence | Unusual column names | Run `-SaveSchema`, edit JSON, rerun with `-SchemaPath` |
| Apps not merging correctly | Different app names | Check `_nameVariants` in output; the filename anchor usually resolves this |
| Conflicts showing up | Same field, different values across files | Expected behavior -- check the Conflicts XLSX sheet |
| "~$" temp files processed | Excel has files open | Close Excel first; script auto-skips `~$*` files |
| Detail tables empty | No structured/list sheets found | This is normal for simple tabular questionnaires |

> **Tip:** Review `IAM-Intake-Mapping-*.json` for full details about what was detected, and check the `Unmapped` sheet in the XLSX for questions the parser could not resolve.
