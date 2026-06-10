# SailPoint ISC Governance Toolkit -- Disconnected App Onboarding Guide

> **Source of truth.** This is the onboarding guide for application teams delivering
> CSV exports for disconnected-application certification. It covers file format, column
> definitions, delivery requirements, validation, and common mistakes. Based on the
> v2 template (`Config/Templates/v2/ONBOARDING-GUIDE.md`).

**Audience:** application owners and teams responsible for delivering CSV exports to
the disconnected-application certification pipeline.

---

## What This Is

Your application needs to be included in the organization's SailPoint ISC access review
process. Because your application does not have a direct connector to SailPoint, you will
provide daily CSV exports of your users and their access (roles/groups/permissions).

These files are used to:
1. **Detect changes** -- who got new access? who was removed? what changed?
2. **Create certification campaigns** -- managers review their team's access in your app
3. **Generate audit evidence** -- compliance and audit reports

The toolkit automatically compares each day's export against the previous snapshot,
identifies changes, resolves accounts to corporate identities, and creates targeted
certification campaigns for the affected managers.

---

## What You Need to Deliver

Two CSV files, delivered daily by **04:00 UTC**:

## Account File

One row per account. Contains **all** current active and disabled accounts.

**Required columns:**

| Column | Format | Max Length | Description | Example |
|--------|--------|-----------|-------------|---------|
| `id` | String | 128 chars | Unique account ID within your app | `EMP10045` |
| `name` | String | 128 chars | Username / login | `jsmith` |
| `givenName` | String | 128 chars | First name | `John` |
| `familyName` | String | 128 chars | Last name | `Smith` |
| `e-mail` | String (email) | 256 chars | Primary email address (used to match to corporate identity) | `john.smith@corp.com` |
| `department` | String | 128 chars | Department name | `Treasury` |
| `groups` | String (multi-valued) | -- | Comma-separated entitlement IDs. Values must match `id` in the entitlement file. Wrap in double quotes if multiple. | `"PEP-ADMIN,PEP-REPORTS"` |
| `IIQDisabled` | `true` or `false` | -- | `false` = active account, `true` = disabled/inactive account | `false` |

**Optional columns (recommended for v2):**

| Column | Format | Description | Example |
|--------|--------|-------------|---------|
| `accountType` | String | Account classification: `standard`, `admin`, `service`, `shared` | `standard` |
| `created` | Date (YYYY-MM-DD) | Date the account was created in your app | `2024-03-15` |
| `lastLogin` | DateTime (ISO 8601) | Last successful login timestamp. Empty if unknown. | `2026-05-27T14:30:00Z` |

**Example:**

```csv
id,name,givenName,familyName,e-mail,department,groups,IIQDisabled,accountType,created,lastLogin
EMP10001,jsmith,John,Smith,john.smith@corp.com,Treasury,"PEP-ADMIN,PEP-REPORTS",false,standard,2024-03-15,2026-05-27T14:30:00Z
EMP10002,jdoe,Jane,Doe,jane.doe@corp.com,Operations,PEP-READONLY,false,standard,2025-01-10,2026-05-28T09:15:00Z
SVC-PEP-01,svc-pep-batch,PEP,Batch Service,,,PEP-ADMIN,false,service,2023-01-01,2026-05-28T04:00:00Z
```

---

## Entitlement File

One row per unique entitlement (role, group, permission, or license) that your application manages.

**Required columns:**

| Column | Format | Max Length | Description | Example |
|--------|--------|-----------|-------------|---------|
| `id` | String | 128 chars | Unique entitlement ID. Must match values used in accounts `groups` column. | `PEP-ADMIN` |
| `name` | String | 128 chars | Technical name | `PEP-ADMIN` |
| `displayName` | String | 128 chars | Human-readable name shown to reviewers | `PEP+ System Administrator` |
| `description` | String | 2000 chars | What this entitlement grants. Be specific -- reviewers use this to decide approve/revoke. | `Full admin access including user management and config` |

**Optional columns (recommended for v2):**

| Column | Format | Description | Example |
|--------|--------|-------------|---------|
| `owner` | String (email) | Email of the person responsible for this entitlement. Shown to reviewers as the subject matter expert. | `security-ops@corp.com` |
| `type` | String | Entitlement classification: `role`, `group`, `permission`, `license`. Default: `group`. | `role` |
| `riskLevel` | String | Risk classification: `low`, `medium`, `high`, `critical`. Default: `low`. | `critical` |

**Example:**

```csv
id,name,displayName,description,owner,type,riskLevel
PEP-ADMIN,PEP-ADMIN,PEP+ System Administrator,Full administrative access to PEP+ ACH processing system,security-ops@corp.com,role,critical
PEP-READONLY,PEP-READONLY,PEP+ Read Only,View-only access to transaction data and reports,treasury-lead@corp.com,role,low
```

---

## File Format Rules

| Rule | Details |
|------|---------|
| **Encoding** | UTF-8 (without BOM preferred; BOM accepted). In Excel: Save As > CSV UTF-8. |
| **Delimiter** | Comma (`,`) |
| **Header row** | First row must be the column headers exactly as shown (case-sensitive) |
| **Multi-valued groups** | Wrap in double quotes: `"ROLE-A,ROLE-B,ROLE-C"` |
| **Empty values** | Leave the field empty (two consecutive commas): `...,Treasury,,true` |
| **Dates** | Account dates: `YYYY-MM-DD`. Timestamps: `YYYY-MM-DDTHH:mm:ssZ` (UTC) |
| **Sorting** | Sort the account file by the `id` column (ascending) |
| **Line endings** | Either CR+LF (Windows) or LF (Unix) -- both accepted |
| **Special characters** | Entitlement IDs: use letters, numbers, hyphens, underscores only. No commas, no special characters. |
| **Maximum rows** | Up to 100,000 rows per file. Contact the governance team if your app exceeds this. |

---

## Full Export Required

**Deliver a FULL export every day** -- every current account and entitlement, not just changes.

The governance system automatically detects what changed by comparing today's file against
yesterday's. You do NOT need to calculate deltas or track changes yourself.

- **Day 1:** 500 accounts in file. System treats all 500 as "new" (baseline).
- **Day 2:** 500 accounts, identical to day 1. System detects "no changes." No action.
- **Day 3:** 501 accounts (1 new hire added). System detects 1 addition. Only that person's
  manager receives a certification campaign.
- **Day 4:** 499 accounts (2 terminated). System detects 2 removals. Logged for audit trail.

**Do NOT send only the changes.** Do NOT send an empty file when nothing changed.
Always send the complete current state.

---

## Entitlement Design Guidance

Each distinct level of access that should be independently reviewable and revocable
is one entitlement. Ask yourself: "Could I grant or remove this access without
affecting other access?" If yes, it is a separate entitlement.

| Your App Has | Entitlement File Should Have |
|-------------|------------------------------|
| 3 roles (Admin, User, Viewer) | 3 rows |
| 5 permission groups | 5 rows |
| 1 role + 3 add-on permissions | 4 rows (role + each permission separately) |
| License tiers (Basic, Pro, Enterprise) | 3 rows |

**Do NOT combine multiple access levels into one entitlement** (e.g., "Admin-and-Reports").
Keep them separate so reviewers can revoke one without affecting the other.

---

## Multiple Account Types

If a user has more than one account in your app (e.g., a standard account AND an admin
account), include both as separate rows with different `id` values:

```csv
id,name,givenName,familyName,e-mail,department,groups,IIQDisabled,accountType
EMP10001,jsmith,John,Smith,john.smith@corp.com,Treasury,PEP-READONLY,false,standard
EMP10001-ADM,jsmith-admin,John,Smith,john.smith@corp.com,Treasury,PEP-ADMIN,false,admin
```

Both accounts correlate to the same corporate identity via the `e-mail` field.

---

## Where to Deliver

Drop both files into your application's import directory:

```
\\fileserver\sailpoint-imports\{YourAppName}\accounts.csv
\\fileserver\sailpoint-imports\{YourAppName}\entitlements.csv
```

Replace `{YourAppName}` with your registered application name (e.g., `PEP-Plus`, `DebtNext`).

**Deadline:** Files must be refreshed by **04:00 UTC** daily (including weekends if your
application processes access on weekends).

---

## Export Workflow Patterns

How you produce the daily CSV depends on your application's architecture. Here are the
common patterns:

### REST API Export

If your application has a REST API with user/role endpoints:

1. Script a daily job that calls `GET /api/users` and `GET /api/roles` (or equivalent).
2. Transform the API response into the CSV format above.
3. Write the files to the import directory.

This is the preferred pattern -- it is reliable, automatable, and produces consistent
output. Schedule via cron, Task Scheduler, or your CI/CD pipeline.

### SQL/Database Export

If your application stores accounts in a relational database:

1. Write a SQL query that joins users to their roles/groups.
2. Export the result set as CSV (e.g. `bcp`, `sqlcmd -o`, or a scheduled SSIS package).
3. Write the files to the import directory.

Ensure the query produces ALL active and disabled accounts, not just recent changes.

### SCIM Export

If your application supports SCIM 2.0:

1. Query `GET /scim/v2/Users` with pagination.
2. Map SCIM attributes (`userName`, `emails`, `groups`) to the CSV columns.
3. Export and deliver as above.

### Manual / Spreadsheet Export

For small applications with no API:

1. The application administrator exports the user list from the admin UI.
2. Open in Excel, map columns to the required format.
3. **Save As > CSV UTF-8** (not the default Excel CSV, which is UTF-16).
4. Deliver to the import directory.

This is the least desirable pattern -- it depends on a human and is error-prone.
Automate as soon as possible.

---

## Validate Before Going Live

Before your first production delivery, validate your files using the self-service test command:

```powershell
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName "YourAppName"
```

This checks:
- All required columns are present
- No duplicate account IDs
- Email addresses are valid format
- Entitlement IDs in account file match entitlement file
- File encoding is UTF-8
- Field lengths within limits

Fix any errors reported before requesting production activation.

---

## Disconnected App Workflow Diagrams

The following PlantUML diagrams in `docs/designs/disconnected-app-workflows/` illustrate
the end-to-end pipeline:

| Diagram | What It Shows |
|---------|---------------|
| `01-overview-all-patterns.puml` | Overview of all export patterns and how they feed the certification pipeline |
| `02-pattern-a-rest-api.puml` | REST API export pattern detail |
| `03-pattern-b-sql-export.puml` | SQL/database export pattern detail |
| `04-pattern-c-ad-plus-db.puml` | Hybrid AD + database pattern |
| `05-pattern-e-manual-fallback.puml` | Manual/spreadsheet fallback pattern |
| `06-product-owner-value.puml` | Product-owner value proposition (why this matters) |

---

## Common Mistakes

| Mistake | What Happens | How to Fix |
|---------|-------------|------------|
| File saved as UTF-16 (Excel default "CSV") | Validation fails with encoding error | Use "CSV UTF-8" in Excel Save As |
| Column names in wrong case (`Email` vs `e-mail`) | Columns not recognized (case-sensitive) | Match header names exactly from template |
| Entitlement ID not in entitlement file | Validation warning: unmatched group reference | Add the entitlement to the entitlement file |
| Comma inside an entitlement ID (`APP,ADMIN`) | Splits into two entitlements | Use hyphens: `APP-ADMIN` |
| Empty file delivered | Threshold protection blocks processing (mass deletion detected) | Always deliver full export, even if nothing changed |
| Sending only changes (delta file) | Missing accounts treated as removals | Always send ALL current accounts |
| `IIQDisabled` set to `yes`/`no` instead of `true`/`false` | Validation error | Use lowercase `true` or `false` only |
| Description over 2000 characters | Truncated in SailPoint UI | Shorten description to key information |
| Multiple accounts for same user with same `id` | Only first row processed | Use distinct IDs (e.g., `EMP10001`, `EMP10001-ADM`) |

---

## Registration and Lifecycle

Once your CSV files are validated, the governance team registers your application:

```powershell
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register `
    -AppName 'YourAppName' `
    -AccountFilePath '\\fileserver\sailpoint-imports\YourAppName\accounts.csv' `
    -EntitlementFilePath '\\fileserver\sailpoint-imports\YourAppName\entitlements.csv'
```

After registration:
- The daily orchestrator automatically picks up your app in the disconnected-app batch (step 7).
- First-day delivery creates the baseline snapshot (all accounts treated as "new").
- Subsequent deliveries create campaigns only for changes.
- To temporarily pause certification without removing the registration, set `Enabled: false` in the app's config.
- To decommission, run `Invoke-SPDisconnectedAppRegistry.ps1 -Action Unregister -AppName 'YourAppName'`.

---

## Support

For questions about file format, validation errors, or onboarding:

- **ServiceNow:** Queue: `IAM-SailPoint-Governance` (Category: Disconnected App Onboarding)
- **Email:** sailpoint-governance@corp.com
- **Teams:** #sailpoint-governance channel

For urgent issues (file delivery failure, campaign errors):

- **PagerDuty:** `sailpoint-oncall` escalation policy
