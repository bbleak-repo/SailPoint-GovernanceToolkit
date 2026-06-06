# SailPoint ISC Governance Toolkit -- Disconnected App Operations

> **Source of truth.** This is the implementor's operational guide for running the
> disconnected-application certification pipeline end-to-end. For the app team's CSV
> format and delivery requirements, see the [App Onboarding Guide](04-onboarding-guide.md).
> Read [Foundations](00-foundations.md) and the [CLI Playbook](cli-playbook.md) first.

**Audience:** SailPoint implementors, governance engineers, and operations staff
responsible for running and monitoring the disconnected-app pipeline.

---

## Pipeline Overview

The disconnected-app pipeline transforms daily CSV exports from application teams into
targeted ISC certification campaigns and tracks the full lifecycle from file delivery
through remediation confirmation.

**End-to-end flow:**

1. **CSV arrives** -- app team delivers `accounts.csv` + `entitlements.csv` to the import directory
2. **Validate** -- column schema, encoding, referential integrity, field lengths
3. **Snapshot** -- today's validated CSV is stored as a date-stamped snapshot
4. **Delta detect** -- compare today's snapshot against the previous snapshot to identify changes
5. **Resolve identities** -- match changed accounts to ISC identities via the correlation attribute
6. **Create campaigns** -- one SEARCH campaign per manager for their direct reports' changes
7. **Collect decisions** -- harvest what reviewers decided (approve/revoke) after campaigns complete
8. **Track remediations** -- verify revocations were carried out in subsequent CSV deliveries
9. **Generate reports** -- delta summaries, batch status, SLA compliance, cross-app analytics

**Single-app vs batch processing:**

- **Single-app** (`Invoke-SPDisconnectedAppCert.ps1`) -- processes one application end-to-end.
  Use for testing, first-time onboarding, or re-processing a specific app after a failure.
- **Batch** (`Invoke-SPDisconnectedAppBatch.ps1`) -- iterates through all (or named)
  registered applications with error isolation. Use for the daily scheduled run.

The daily orchestrator (`Invoke-SPDailyOrchestrator.ps1`) calls the batch processor
as step 7, so in steady-state operation you rarely invoke either script directly.

---

## Registering Applications

Before an application can be processed, it must be registered in the toolkit's
configuration. Registration defines the file paths, campaign naming, deadlines,
and per-app overrides.

### Registration walkthrough

```powershell
# Register a new application
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register `
    -AppName 'PEP-Plus' `
    -AccountFilePath '\\fileserver\sailpoint-imports\PEP-Plus\accounts.csv' `
    -EntitlementFilePath '\\fileserver\sailpoint-imports\PEP-Plus\entitlements.csv' `
    -CampaignNamePrefix 'PEP+ Cert' `
    -DeadlineDays 2 `
    -SlaDays 1
```

Registration writes an entry to the `DisconnectedApps.Applications` array in
`settings.json`. You can also edit this array directly.

### Applications array structure

Each registered app is an object in `DisconnectedApps.Applications`:

| Key | Type | Required | Description |
|---|---|---|---|
| `Name` | String | Yes | Unique application name (used in campaign names, directories, logs) |
| `AccountFilePath` | String | Yes | Full path to the daily account CSV |
| `EntitlementFilePath` | String | No | Full path to the entitlement CSV (enables cross-reference validation) |
| `ISCSourceId` | String | No | If set, the toolkit can push the CSV to ISC as a source aggregation |
| `CorrelationAttribute` | String | No | Override the global `DisconnectedApps.CorrelationAttribute` (default `e-mail`) |
| `CampaignNamePrefix` | String | No | Override the global `DisconnectedApps.DefaultCampaignNamePrefix` |
| `DeadlineDays` | Integer | No | Days reviewers have to complete their certification (default from global) |
| `SlaDays` | Integer | No | Days the app team has to remediate revocations before escalation |
| `Enabled` | Boolean | No | Set to `false` to pause processing without removing the registration |

**Example configuration:**

```json
{
    "DisconnectedApps": {
        "Applications": [
            {
                "Name": "PEP-Plus",
                "AccountFilePath": "\\\\fileserver\\imports\\PEP-Plus\\accounts.csv",
                "EntitlementFilePath": "\\\\fileserver\\imports\\PEP-Plus\\entitlements.csv",
                "ISCSourceId": "",
                "CorrelationAttribute": "e-mail",
                "CampaignNamePrefix": "PEP+ Cert",
                "DeadlineDays": 2,
                "SlaDays": 1,
                "Enabled": true
            }
        ]
    }
}
```

### Per-app overrides

The global defaults under `DisconnectedApps` apply to all apps unless overridden
at the app level:

| Setting | Global Key | Per-App Override |
|---|---|---|
| Correlation attribute | `DisconnectedApps.CorrelationAttribute` | `Applications[].CorrelationAttribute` |
| Campaign name prefix | `DisconnectedApps.DefaultCampaignNamePrefix` | `Applications[].CampaignNamePrefix` |
| Reviewer deadline | `DisconnectedApps.DefaultDeadlineDays` | `Applications[].DeadlineDays` |
| Remediation SLA | (none -- app-level only) | `Applications[].SlaDays` |

### Directory scaffold

After registration, the toolkit creates these directories on first run:

```
DisconnectedApps/
  Imports/           <-- global import staging area
  Snapshots/
    PEP-Plus/        <-- date-stamped snapshots per app
      2026-06-01/
      2026-06-02/
  Reports/
    PEP-Plus/        <-- delta reports per app
```

Snapshot and report directories are auto-created per app. The import path
(`AccountFilePath`) can point anywhere -- a file share, a local directory, or a
mapped drive.

---

## Single App Processing

`Invoke-SPDisconnectedAppCert.ps1` runs the full pipeline for one application.

### End-to-end walkthrough

```powershell
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 `
    -AppName 'PEP-Plus' `
    -AccountFilePath '\\fileserver\imports\PEP-Plus\accounts.csv' `
    -EntitlementFilePath '\\fileserver\imports\PEP-Plus\entitlements.csv' `
    -Token $jwt
```

### What each step does

| Step | Action | Output |
|---|---|---|
| **Validate** | Checks required columns, encoding, referential integrity (account `groups` vs entitlement `id`) | Validation pass/fail + warnings |
| **Snapshot** | Copies today's validated CSV to `Snapshots/<AppName>/<date>/` | Date-stamped snapshot files |
| **Delta detect** | Compares today's snapshot against the previous snapshot | List of changes by type (added, removed, enabled, disabled, grants, revocations, attribute changes) |
| **Resolve identities** | Matches changed accounts to ISC identities via `CorrelationAttribute` (typically email) | ISC identity IDs + manager IDs for each changed account |
| **Create campaigns** | Groups changes by manager, creates one SEARCH campaign per manager | Campaign IDs, JSONL evidence |

### Expected output at each stage

- **No previous snapshot (first run):** all accounts are treated as "new." The system
  creates the baseline snapshot. Campaigns are created for all managers whose reports
  have accounts in the app.
- **No changes since last snapshot:** the script exits with code 1 (not an error).
  The log entry shows `Status=NoChanges`.
- **Changes detected:** campaigns are created only for managers whose direct reports
  had access changes. The delta report HTML is written to `Reports/<AppName>/`.

### First run behavior

On the very first run for a newly registered app, there is no previous snapshot to
compare against. The toolkit treats this as a baseline establishment:

1. All accounts in the CSV are classified as `AccountAdded`.
2. All entitlements assigned to those accounts are classified as `EntitlementGranted`.
3. Campaigns are created for every manager with direct reports in the app.
4. This is the expected "day 1 flood" -- subsequent days will only produce campaigns
   for actual changes.

> **Tip:** To establish the baseline without creating campaigns (useful for large apps),
> run the single-app processor with `-WhatIf` on the first day, then let the real run
> happen on day 2 when only genuine changes trigger campaigns.

---

## Batch Processing

`Invoke-SPDisconnectedAppBatch.ps1` processes all (or named) registered applications
in sequence with error isolation.

### Batch walkthrough

```powershell
# Process all enabled apps
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -Token $jwt

# Process specific apps only
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -AppNames 'PEP-Plus','DebtNext' -Token $jwt

# Preview mode (no campaigns created)
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -OutputMode Both
```

### Error isolation

One application's failure does not stop the batch. Each app is processed independently
and receives one of these statuses:

| Status | Meaning | Action |
|---|---|---|
| `Success` | Pipeline completed, campaigns created | None -- review the delta report |
| `NoChanges` | No differences between today's and yesterday's snapshot | None -- normal on quiet days |
| `ThresholdBlocked` | Account deletion threshold exceeded | Verify the CSV is a full export (see Delta Detection) |
| `Error` | Validation, correlation, or API failure | Check the log for the specific failure; re-run the single-app processor to debug |

### Exit codes

| Exit Code | Meaning |
|---|---|
| 0 | All apps succeeded or had no changes |
| 1 | Partial -- at least one app succeeded, at least one failed |
| 2 | All apps failed |

### Campaign naming convention

Each app's campaigns follow the naming pattern:

```
{CampaignNamePrefix} {YYYY-MM-DD} - {ManagerName}
```

For example: `PEP+ Cert 2026-06-05 - Jane Doe`

The prefix comes from the per-app `CampaignNamePrefix` (or the global
`DefaultCampaignNamePrefix` if not set). This naming convention enables:

- Filtering campaigns by app (search by prefix)
- Identifying the date the campaign was triggered
- Knowing which manager owns the review

---

## Delta Detection Deep Dive

Delta detection is the core mechanism that makes disconnected-app certification
efficient -- instead of re-certifying all access every day, only changes trigger
campaigns.

### How file comparison works

The toolkit compares today's CSV snapshot against the most recent previous snapshot,
row by row, using the account `id` as the join key:

1. Load today's snapshot and the previous day's snapshot
2. Index both by account `id`
3. For each account ID, compare all column values
4. Classify each difference as one of the 7 change types

### Change types

| Change Type | Detection Logic | Triggers Campaign | Example |
|---|---|---|---|
| `AccountAdded` | Account ID exists today but not in previous snapshot | Yes | New employee added to the app |
| `AccountRemoved` | Account ID existed previously but is absent today | No (logged only) | Terminated employee removed |
| `AccountDisabled` | `IIQDisabled` changed from `false` to `true` | No (logged only) | Account disabled during leave |
| `AccountEnabled` | `IIQDisabled` changed from `true` to `false` | Yes | Account re-enabled after leave |
| `EntitlementGranted` | New value appears in the `groups` column | Yes | User granted a new role |
| `EntitlementRevoked` | Value removed from the `groups` column | No (logged only) | Role removed from user |
| `AttributeChanged` | Any other column value changed (name, department, email) | No (logged only) | Department transfer |

**Campaign-triggering changes:** Only `AccountAdded`, `AccountEnabled`, and
`EntitlementGranted` create certification campaigns. These represent new or expanded
access that a manager should review. Removals and disablements are logged for the
audit trail but do not require reviewer action.

### Account deletion threshold protection

The `AccountDeletionThresholdPct` setting (default 20%) protects against accidental
mass deletion when an app team delivers a partial or corrupted CSV.

**How it works:**

1. Count the accounts in the previous snapshot: e.g. 500
2. Count the accounts in today's CSV: e.g. 350
3. Calculate the removal percentage: (500 - 350) / 500 = 30%
4. 30% > 20% threshold -- **processing is blocked**

**What it catches:**

- App team sent a delta file instead of a full export
- Export job failed partway through, producing a truncated file
- Wrong file delivered (e.g., a test file with 10 rows)

**How to override:**

If the mass removal is legitimate (e.g., org restructure, app decommissioning a
business unit), temporarily increase the threshold:

```json
{
    "DisconnectedApps": {
        "AccountDeletionThresholdPct": 50
    }
}
```

> **Warning:** Reset the threshold back to 20% (or your standard value) after the
> legitimate mass change is processed. A permanently high threshold defeats the
> safety protection.

---

## Post-Campaign Operations

After campaigns are created and reviewers make their decisions, two follow-up
processes close the loop: decision collection and remediation tracking.

### Decision Collection

When a disconnected-app campaign completes (all reviewers have signed off), the
orchestrator step 8 harvests the decisions.

**What happens:**

1. The orchestrator queries ISC for completed campaigns matching the app's
   `CampaignNamePrefix`
2. For each completed campaign, it pulls all access review items and their decisions
3. Decisions are written to the JSONL audit trail at
   `Audit/audit-YYYYMMDD-HHmmss.jsonl`

**Decision outcomes:**

| Decision | Meaning | Next Step |
|---|---|---|
| `APPROVE` | Manager confirmed the access is appropriate | No action -- access remains |
| `REVOKE` | Manager determined the access should be removed | Remediation tracking begins |

**Where decisions are stored:**

- **JSONL audit trail:** machine-parseable evidence in `Audit/` -- one entry per
  decision with full context (campaign, reviewer, identity, entitlement, timestamp)
- **Campaign audit report:** if `Invoke-SPCampaignAudit.ps1` is run, decisions appear
  in the per-campaign HTML report sections 4 (decisions) and 6 (remediation proof)

### Remediation Tracking

After a reviewer marks access as `REVOKE`, the toolkit monitors whether the app team
actually removed the access. This is tracked through subsequent CSV deliveries.

**How it works:**

1. Orchestrator step 9 (`Update-SPRemediationStatus`) runs daily
2. For each pending revocation, it checks today's CSV snapshot
3. If the revoked entitlement no longer appears in the account's `groups` column,
   the remediation is marked as `CONFIRMED`
4. If the entitlement still appears, the remediation remains `PENDING`
5. If the `SlaDays` threshold is exceeded, the status escalates to `OVERDUE`

**Remediation states:**

| State | Meaning | When |
|---|---|---|
| `PENDING` | Revocation decided, waiting for app team to act | Immediately after campaign completion |
| `CONFIRMED` | Revoked access no longer appears in the next CSV delivery | Next CSV delivery after remediation |
| `OVERDUE` | `SlaDays` exceeded without confirmation | `SlaDays` after the revocation decision |
| `ESCALATED` | Overdue remediation has been escalated via notification | After overdue notification sent |

**Investigating stuck remediations:**

1. Check the weekly digest's remediation tracking section for a summary of
   pending and overdue remediations per app
2. Query the JSONL audit trail for `Action=RemediationCheck` entries with
   `Status=Pending` or `Status=Overdue`
3. Common causes:
   - The app team did not process the revocation request
   - The CSV was not refreshed after the change was made
   - The revocation was partially applied (entitlement removed but account still active)
   - The next CSV delivery has not arrived yet

> **Tip:** The `SlaDays` setting per app should match the app team's change management
> SLA. For apps with manual revocation processes, set a higher value (e.g., 5 days).
> For apps with automated provisioning, 1 day is sufficient.

---

## Delivery Monitoring

The toolkit tracks CSV delivery status for all registered applications. This enables
proactive identification of apps that are failing to deliver files.

### Delivery states

| State | Meaning | Detection |
|---|---|---|
| `Delivered` | Today's CSV arrived and passed validation | File exists, modified today, validation passed |
| `Stale` | File exists but was not updated today | File modification date is older than today |
| `Missing` | No file found at the configured path | File does not exist at `AccountFilePath` |
| `Empty` | File exists but contains zero data rows (header only) | File has a header row but no account rows |

### SLA tracking

The toolkit maintains a 30-day delivery history per app. This history enables:

- **Reliability scoring:** percentage of days the app delivered on time
- **Pattern detection:** identifying apps that consistently deliver late (e.g.,
  always stale on Mondays due to weekend batch scheduling)
- **Trend alerting:** declining delivery reliability triggers a notification

### Chronic late delivery

When an app's 30-day delivery reliability drops below 80%, the daily orchestrator
log flags it with a `WARN` severity entry. This surfaces in:

- The daily orchestrator summary
- The weekly digest's disconnected-app section
- Notification backends (if configured)

Contact the app team to investigate their export scheduling when chronic late
delivery is detected.

---

## Cross-App Analytics

When multiple disconnected apps are registered, the toolkit provides cross-app
visibility that no single app team has.

### Identity Risk

Identities with access in 3 or more disconnected apps receive elevated scrutiny.
The batch summary report flags these identities because:

- More apps = more attack surface if the identity is compromised
- Cross-app access is harder for a single manager to evaluate
- Shared/service accounts appearing across multiple apps indicate potential
  credential sharing

### Entitlement Catalog

The entitlement files from all registered apps are combined into a unified catalog.
This enables:

- Searching for similar entitlements across apps (e.g., "ADMIN" roles)
- Identifying naming inconsistencies (same real access, different names)
- Risk-level comparison across the portfolio

### Team Dashboard

Each app team gets a per-app HTML status page showing:

- Current delivery status (delivered/stale/missing/empty)
- Last 30 days delivery history with reliability percentage
- Open campaigns and their completion status
- Pending and overdue remediations
- Delta summary for the most recent processing run

These dashboards are generated as part of the batch processing output in
`DisconnectedApps/Reports/<AppName>/`.

---

## ISC Source Integration

For organizations that want disconnected-app accounts visible in the ISC admin
console (not just through toolkit-generated campaigns), the toolkit supports
pushing CSV data to ISC as a source aggregation.

### When to use ISC source integration

- You want ISC's native campaign UI to display disconnected-app access
- You need disconnected-app access visible in ISC identity cubes
- Your compliance framework requires all access to be visible in one system
- You want to use ISC's built-in search and analytics on disconnected-app data

### Configuration

Set `ISCSourceId` on the app's registration to the ISC source ID created for
the disconnected app:

```json
{
    "Name": "PEP-Plus",
    "ISCSourceId": "2c91808a7f3e8b01017f3e9abc123456",
    "AccountFilePath": "..."
}
```

The global `DisconnectedApps.ISC` section controls the upload method:

| Key | Values | Description |
|---|---|---|
| `UploadMethod` | `API` or `FileDrop` | How accounts reach ISC |
| `FileDropBasePath` | Path | For `FileDrop`: the directory ISC's VA monitors |
| `WaitForAggregationSeconds` | Integer | Seconds to wait for ISC to complete aggregation after upload |

**API method:** the toolkit calls the ISC source aggregation API to upload
accounts directly. Requires `idn:sources:read` scope (to verify the source) and
network access to the ISC API.

**FileDrop method:** the toolkit writes the CSV to a directory monitored by the
ISC Virtual Appliance (VA). The VA picks up the file and triggers aggregation
automatically. Requires write access to the VA-monitored share.

> **Warning:** ISC source integration is optional and additive. The toolkit's own
> delta detection, campaign creation, and remediation tracking work independently
> of whether the data is also in ISC. Do not enable ISC integration until the
> basic pipeline is stable.

---

## What Can Go Wrong

### Bad CSV delivered (threshold blocks processing)

**Symptom:** batch status shows `ThresholdBlocked` for the app.

**Diagnosis:** the account count dropped by more than `AccountDeletionThresholdPct`
compared to the previous snapshot.

**Resolution:**
1. Verify the CSV is a full export, not a delta or partial file
2. If the removal is legitimate, temporarily increase the threshold in
   `settings.local.json` and re-run the single-app processor
3. Reset the threshold after processing

### App team sends delta instead of full export

**Symptom:** the first delta delivery appears to work (all accounts are "new"), but
the second delivery shows massive removals (all of the first day's accounts disappear
because they were not in the delta file).

**Diagnosis:** the threshold protection catches this on day 2.

**Resolution:** re-educate the app team. They must deliver ALL current accounts
every day, not just changes. Refer them to the App Onboarding Guide's "Full Export
Required" section.

### Identity not found in ISC (correlation failure)

**Symptom:** the log shows `Identity not found for correlation` warnings.
Campaigns are created for resolved identities but skipped for unresolved ones.

**Diagnosis:** the email (or other correlation attribute) in the CSV does not match
any active ISC identity.

**Resolution:**
1. Verify the `CorrelationAttribute` matches the ISC identity attribute
   (default `e-mail`)
2. Check if the identity is in an excluded lifecycle state
   (`ExcludeLifecycleStates`)
3. Verify the email format in the CSV matches ISC (e.g., `john.smith@corp.com`
   vs `jsmith@corp.com`)
4. Run `Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName <name>` to
   validate the correlation

### Campaign quota exceeded

**Symptom:** the single-app processor aborts with a `MaxCampaignsPerRun exceeded`
message.

**Diagnosis:** the number of unique managers for changed accounts exceeds
`MaxCampaignsPerRun` (default 20 per app, or `Safety.MaxCampaignsPerRun` globally).

**Resolution:**
1. Review whether the change volume is legitimate (e.g., first-day baseline flood)
2. Increase `MaxCampaignsPerRun` temporarily
3. Consider running the baseline with `-WhatIf` first

### File encoding issues

**Symptom:** validation fails with encoding errors. Characters appear garbled in
reports.

**Diagnosis:** the CSV was saved as UTF-16 (Excel's default "CSV" format) instead
of UTF-8.

**Resolution:** re-export the CSV as "CSV UTF-8 (Comma delimited)" from Excel,
or convert the file encoding:

```powershell
Get-Content -Path accounts.csv -Encoding Unicode | Set-Content -Path accounts-utf8.csv -Encoding UTF8
```
