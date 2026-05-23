# Phase 11: Production Readiness -- Backlog

**Created:** 2026-05-23
**Prereqs:** All Phases 1-10 complete
**Constraint:** NO GUI file changes (Windows GUI testing in progress on W-01 to W-07)

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `P11-01 -> P11-02 -> P11-03 -> P11-04 -> P11-05 -> P11-06 -> P11-07 -> P11-08 -> P11-09 -> P11-10`

---

## GUI Constraint (CRITICAL)

Windows agents are currently testing the GUI. Do NOT modify these files:
- `Gui/*.xaml` (any XAML file)
- `Modules/SP.Gui/SP.MainWindow.psm1`
- `Modules/SP.Gui/SP.GuiBridge.psm1`
- `Modules/SP.Gui/SP.Gui.psd1`
- Any existing CLI scripts in `Scripts/` (being tested)

Safe to modify:
- `Modules/SP.Api/SP.Campaigns.psm1` (add new functions)
- `Modules/SP.Api/SP.ApiClient.psm1` (add new functions)
- `Modules/SP.Api/SP.Api.psd1` (export new functions)
- `Modules/SP.Audit/SP.AuditQueries.psm1` (add new functions)
- `Modules/SP.Audit/SP.AuditReport.psm1` (add new functions)
- `Modules/SP.Audit/SP.Audit.psd1` (export new functions)
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` (add new functions)
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` (export new functions)
- `Modules/SP.Core/SP.Config.psm1` (add config defaults)
- `Config/settings.json` (add new config sections)
- `Scripts/` (NEW scripts only)
- `Tests/` (NEW test files)

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| P11-01 | Configuration Validator | none | DONE |
| P11-02 | Audit Trail Consolidator | none | DONE |
| P11-03 | CSV Export for Audit Data | none | DONE |
| P11-04 | Remediation Verification | none | PENDING |
| P11-05 | Campaign Health Monitor | none | PENDING |
| P11-06 | Campaign Trend Analytics | P11-03 | PENDING |
| P11-07 | Entitlement Inventory Report | none | PENDING |
| P11-08 | Cross-Campaign Reviewer Analysis | P11-06 | PENDING |
| P11-09 | Daily Orchestrator Script | P11-01, P11-05 | PENDING |
| P11-10 | Pester Tests | P11-09 | PENDING |

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Get-SPConfig` | SP.Config | P11-01, P11-09 |
| `Invoke-SPApiRequest` | SP.ApiClient | P11-04, P11-05, P11-07 |
| `Search-SPCampaigns` | SP.Campaigns | P11-05, P11-06 |
| `Get-SPCampaignDeadlineStatus` | SP.Campaigns | P11-05 |
| `Get-SPAuditCampaigns` | SP.AuditQueries | P11-06, P11-08 |
| `Get-SPAuditCertifications` | SP.AuditQueries | P11-05 |
| `Group-SPAuditDecisions` | SP.AuditReport | P11-03, P11-04, P11-06 |
| `Measure-SPAuditReviewerMetrics` | SP.AuditReport | P11-08 |
| `Measure-SPAuditRubberStampRisk` | SP.AuditReport | P11-08 |
| `Measure-SPCampaignMetrics` | SP.AuditReport | P11-06 |
| `Get-SPAuditRiskFlags` | SP.AuditReport | P11-03 |
| `Export-SPAuditJsonl` | SP.AuditReport | P11-02 |
| `Get-SPAuditIdentityEvents` | SP.AuditQueries | P11-04 |
| `Get-SPDeltaCertStaleCertifications` | SP.DeltaCertQueries | P11-05 |
| `Invoke-SPDeltaCertRun` | SP.DeltaCertRunner | P11-09 |
| `Invoke-SPDeltaCertCleanup` | SP.DeltaCertRunner | P11-09 |
| `Invoke-SPDeltaCertEscalate` | SP.DeltaCertRunner | P11-09 |
| `Get-SPDeltaReportData` | SP.DeltaCertReport | P11-09 |
| `Export-SPDeltaReportHtml` | SP.DeltaCertReport | P11-09 |
| `Write-SPLog` | SP.Logging | All |
| `Get-SPAuthToken` | SP.Auth | P11-01 |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReport | P11-07 |
| `ConvertTo-SafeHtml` | SP.AuditReport | P11-07 |

---

## P11-01: Configuration Validator

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Test-SPConfiguration` in SP.Config.psm1 that validates the full
settings.json against expected schema, checks field types, validates cross-field
dependencies, and optionally tests API connectivity and ISC entity resolution.

Currently the toolkit has `Test-SPConfig` (checks for missing top-level keys) and
`Test-SPConfigFirstRun` (checks for CHANGE_ME sentinels). Neither validates field
types, range constraints, or whether configured ISC entity IDs (SourceIds,
FallbackReviewerIdentityId) actually exist in the tenant.

**Files to Modify:**
- `Modules/SP.Core/SP.Config.psm1` -- new `Test-SPConfiguration` function
- `Modules/SP.Core/SP.Core.psd1` -- export new function

**Function Signature:**
```powershell
function Test-SPConfiguration {
    param(
        [Parameter()][string]$ConfigPath,
        [Parameter()][switch]$ValidateConnectivity,
        [Parameter()][switch]$ResolveEntities,
        [Parameter()][string]$CorrelationID
    )
}
```

**Validation Rules:**
1. **Schema validation**: Every key in settings.json maps to a known config path.
   Unknown keys produce a WARN (not error -- allows forward compatibility).
2. **Type checks**: Numeric fields (HoursBack, DeadlineDays, TimeoutSeconds, etc.)
   are positive integers. Boolean fields are actual booleans. Array fields are arrays.
3. **Range checks**: `Api.RateLimitRequestsPerWindow` <= 100. `Api.TimeoutSeconds` > 0.
   `Safety.MaxCampaignsPerRun` > 0 and <= 250. `DeltaCert.DefaultHoursBack` > 0.
   `Audit.LeadershipDepth` between 1 and 10.
4. **Cross-field dependencies**: If `Authentication.Mode` is `Vault`, then
   `Vault.VaultPath` must not be empty. If `DeltaCert.Escalation.CampaignNamePrefix`
   is set, it should match `DeltaCert.CampaignNamePrefix` (warn if different).
5. **Path checks**: `Logging.Path`, `Audit.OutputPath`, `DeltaCert.OutputPath` --
   parent directory must exist (or be creatable).
6. **Regex validation**: `DeltaCert.ExcludeDisplayNamePatterns` entries must be valid
   regex (test with `[regex]::new()` in try/catch).
7. **Connectivity** (when `-ValidateConnectivity`): Call `Get-SPAuthToken` and
   `Invoke-SPApiRequest -Method GET -Endpoint '/campaigns?limit=1'` to verify auth +
   API access.
8. **Entity resolution** (when `-ResolveEntities`): For each `DeltaCert.SourceIds`,
   call `GET /v3/sources/{id}` and verify 200. For `FallbackReviewerIdentityId`, call
   identity search. Report missing entities.

**Returns:**
```powershell
@{
    Valid    = $true|$false
    Errors   = @('Authentication.ConfigFile.TenantUrl is empty')
    Warnings = @('Unknown key "CustomField" found')
    Info     = @('API connectivity verified', 'Source src-ad-001 resolved: Corporate AD')
}
```

**Acceptance Criteria:**
- Empty TenantUrl -> error
- Negative TimeoutSeconds -> error
- Invalid regex in ExcludeDisplayNamePatterns -> error with pattern name
- Unknown config key -> warning (not error)
- `-ValidateConnectivity` with valid mock -> Info message with API version
- `-ResolveEntities` with invalid SourceId -> error naming the source ID

**Tests:** P11-T01, P11-T02

---

## P11-02: Audit Trail Consolidator

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Get-SPAuditTrail` in SP.AuditReport.psm1 that reads all JSONL audit
files across the toolkit and produces a unified, chronologically sorted timeline.

Currently audit events are written to three separate JSONL files:
- `{Audit.OutputPath}/audit-*.jsonl` -- campaign audit events
- `{DeltaCert.OutputPath}/deltacert-audit.jsonl` -- delta cert run events
- `{DeltaCert.OutputPath}/deltacert-escalation.jsonl` -- escalation events

There is no way to see a consolidated view of "everything that happened on May 20th"
or "all operations involving source src-ad-001 this week."

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPAuditTrail` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Get-SPAuditTrail {
    param(
        [Parameter()][DateTime]$After,
        [Parameter()][DateTime]$Before,
        [Parameter()][string]$CorrelationID,
        [Parameter()][string[]]$EventType,     # 'CampaignAudit','DeltaCertRun','Escalation'
        [Parameter()][string]$SourceId,
        [Parameter()][string]$AuditOutputPath,
        [Parameter()][string]$DeltaCertOutputPath,
        [Parameter()][int]$MaxEvents = 500
    )
}
```

**Flow:**
1. Resolve paths from config if not provided: `Get-SPConfig` for Audit.OutputPath
   and DeltaCert.OutputPath.
2. Find all `*.jsonl` files in both directories.
3. Read each file line-by-line, parse JSON, normalize to a common schema:
   `Timestamp`, `EventType`, `Action`, `CorrelationID`, `SourceIds`, `Summary`,
   `Details` (original event), `FilePath`.
4. Apply filters: date range, correlation ID, event type, source ID.
5. Sort by Timestamp descending (newest first).
6. Return first `$MaxEvents` entries.

**Normalization mapping:**
- Campaign audit JSONL: `EventType='CampaignAudit'`, `Action` from the audit action field
- Delta cert JSONL: `EventType='DeltaCertRun'`, `Summary` = "Created N campaigns for N identities"
- Escalation JSONL: `EventType='Escalation'`, `Summary` = "Escalated N certifications"

New function `Export-SPAuditTrailHtml` generates a timeline HTML report:
- Each event is a row with timestamp, type badge (color-coded), action, summary
- Links to related HTML reports where applicable
- Filterable by event type via CSS classes

**Acceptance Criteria:**
- Events from all 3 JSONL sources appear in unified timeline
- Filtering by date range returns only events within the window
- Filtering by CorrelationID returns only matching events
- Empty directories return empty array (not error)
- Malformed JSONL lines are skipped with WARN log (not crash)
- HTML timeline renders with color-coded event type badges

**Tests:** P11-T03, P11-T04

---

## P11-03: CSV Export for Audit Data

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Export-SPAuditCsv` in SP.AuditReport.psm1 that exports campaign audit
data to CSV files suitable for import into GRC tools (ServiceNow GRC, RSA Archer),
SIEM platforms (Splunk, Sentinel), or SharePoint/Excel.

The existing `Export-SPAuditJsonl` writes machine-readable JSONL, and `Export-SPAuditHtml`
writes human-readable HTML. CSV fills the gap for downstream integration -- many
compliance teams require tabular data they can import into their own reporting tools.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPAuditCsv` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Export-SPAuditCsv {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][string[]]$Sheets,   # 'Decisions','Reviewers','Campaigns','Remediation'
        [Parameter()][string]$CorrelationID
    )
}
```

**Output files (one CSV per data type):**

1. `decisions-{correlationId}.csv` -- One row per access review decision
   Columns: CampaignName, CampaignType, CampaignStatus, IdentityName, IdentityId,
   AccountName, SourceName, EntitlementName, AccessType, Decision, DecisionDate,
   ReviewerName, ReviewerEmail, Justification, RemediationStatus, RemediationDate,
   RiskFlags, CampaignStartDate, CampaignDueDate, SystemTimestamp

2. `reviewers-{correlationId}.csv` -- One row per reviewer per campaign
   Columns: CampaignName, ReviewerName, ReviewerIdentityId, ItemsAssigned,
   ItemsDecided, ItemsPending, ApprovalRate, RevocationRate, AvgResponseHours,
   FastestResponseHours, SlowestResponseHours, RubberStampRisk

3. `campaigns-{correlationId}.csv` -- One row per campaign
   Columns: CampaignId, CampaignName, CampaignType, Status, Created, Deadline,
   Completed, TotalItems, Approved, Revoked, Pending, CompletionPct, ReviewerCount,
   AvgResponseHours, MedianResponseHours

4. `remediation-{correlationId}.csv` -- One row per revoked item
   Columns: CampaignName, IdentityName, AccountName, EntitlementRevoked, DecisionDate,
   RemediationStatus, RemediationDate, ProvisioningEventId, DaysToRemediate

**Implementation:**
Use `Export-Csv -NoTypeInformation -Encoding UTF8` (PS 5.1 compatible).
Build arrays of `[PSCustomObject]` for each sheet, then export.

**Acceptance Criteria:**
- CSV files open correctly in Excel with proper column headers
- No BOM issues (use `-Encoding UTF8` which is BOM-free on PS 5.1 via workaround)
- Date columns in ISO 8601 format (sortable in Excel)
- Risk flags joined with semicolons for CSV compatibility (not arrays)
- Empty fields are empty strings (not "null" or "$null")
- `-Sheets 'Decisions'` generates only the decisions CSV

**Tests:** P11-T05

---

## P11-04: Remediation Verification

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none

**Description:**
New function `Get-SPRemediationStatus` in SP.AuditQueries.psm1 that takes revocation
decisions from a campaign audit and verifies whether the revocations were actually
provisioned by checking ISC account-activity events.

Currently `Group-SPAuditDecisions` includes a `RemediationStatus` field populated
from `Get-SPAuditIdentityEvents`, but it only checks for generic provisioning events
within a time window. This function provides deeper verification:

1. For each REVOKE decision, search for a matching REVOKE_ACCESS account-activity
   event where: `targetIdentityId` matches the revoked identity, `sourceName` matches,
   and the activity timestamp is after the decision date.
2. Classify each revocation as:
   - **Provisioned**: Matching REVOKE_ACCESS event found
   - **Pending**: No matching event, but within the expected SLA window
   - **Overdue**: No matching event, past the expected SLA window
   - **Failed**: A matching event found but with error status

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPRemediationStatus` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Get-SPRemediationStatus {
    param(
        [Parameter(Mandatory)][PSCustomObject[]]$RevocationDecisions,
        [Parameter()][int]$SlaHours = 48,
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:** Each revocation decision must have: IdentityId, IdentityName, SourceName,
EntitlementName, DecisionDate.

**Flow:**
1. Get unique identity IDs from revocation decisions.
2. For each identity, query `GET /v3/account-activities` with filters:
   `type eq "REVOKE_ACCESS"` and `requested-for` matching the identity.
3. Match each revocation decision to a provisioning event by source + entitlement.
4. Classify based on match result + timing.

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Items = @(
            @{
                IdentityName    = 'Alice Johnson'
                EntitlementName = 'AD-SG-Finance'
                DecisionDate    = '2026-05-20T14:30:00Z'
                Status          = 'Provisioned'   # Provisioned|Pending|Overdue|Failed
                ProvisioningDate = '2026-05-20T14:35:00Z'
                DaysToRemediate = 0.003
            }
        )
        Summary = @{
            Total       = 10
            Provisioned = 7
            Pending     = 2
            Overdue     = 1
            Failed      = 0
            AvgDaysToRemediate = 0.15
        }
    }
}
```

**Acceptance Criteria:**
- Revocation with matching REVOKE_ACCESS event -> Status = 'Provisioned'
- Revocation within SLA window with no event -> Status = 'Pending'
- Revocation past SLA window with no event -> Status = 'Overdue'
- AvgDaysToRemediate calculated only from Provisioned items
- Works with 0 revocations (returns empty summary, not error)

**Tests:** P11-T06, P11-T07

---

## P11-05: Campaign Health Monitor

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none

**Description:**
New function `Get-SPCampaignHealth` in SP.Campaigns.psm1 that checks all active
campaigns for operational health indicators. Designed for daily monitoring and
alerting -- answers "are any campaigns in trouble right now?"

Unlike `Get-SPCampaignDeadlineStatus` (which classifies deadline urgency), this
function provides a broader health assessment including reviewer responsiveness,
completion velocity, and anomaly detection.

**Files to Modify:**
- `Modules/SP.Api/SP.Campaigns.psm1` -- new `Get-SPCampaignHealth` function
- `Modules/SP.Api/SP.Api.psd1` -- export new function

**Function Signature:**
```powershell
function Get-SPCampaignHealth {
    param(
        [Parameter()][string[]]$Status = @('ACTIVE'),
        [Parameter()][int]$DaysBack = 30,
        [Parameter()][int]$StaleReviewerHours = 48,
        [Parameter()][string]$CorrelationID
    )
}
```

**Health indicators per campaign:**
1. **DeadlineStatus**: Overdue / Critical / Warning / OnTrack (reuse deadline logic)
2. **CompletionVelocity**: Items decided per day. Extrapolate: will it finish before deadline?
3. **StaleReviewers**: Certifications with no action past `StaleReviewerHours`
4. **UnresponsiveReviewers**: Reviewers who have not signed off any certifications
5. **OverallHealth**: Red / Yellow / Green based on weighted indicators

**Health scoring:**
- **Red**: Overdue deadline, OR >50% certs stale, OR 0 decisions made after 48h
- **Yellow**: Critical/Warning deadline, OR >25% certs stale, OR velocity too slow to finish
- **Green**: OnTrack deadline, <25% stale, velocity on pace

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Campaigns = @(
            @{
                CampaignId        = 'camp-001'
                CampaignName      = 'Q2 Access Review'
                OverallHealth     = 'Yellow'
                DeadlineStatus    = 'Warning'
                TotalItems        = 100
                DecidedItems      = 45
                PendingItems      = 55
                CompletionPct     = 45.0
                CompletionVelocity = 15.0    # items/day
                ProjectedCompletion = '2026-05-28'
                StaleReviewerCount = 2
                StaleReviewers     = @('Bob Manager', 'Carol Admin')
                DaysRemaining      = 3
            }
        )
        Summary = @{
            Red    = 0
            Yellow = 1
            Green  = 2
            Total  = 3
        }
    }
}
```

**Acceptance Criteria:**
- Overdue campaign -> Red health
- Campaign with no decisions after 48h -> Red health
- Campaign on pace with healthy reviewers -> Green health
- Projected completion date calculated from velocity (items_remaining / velocity)
- Empty active campaigns list returns Green summary (no issues)
- Stale reviewers listed by name (not just ID)

**Tests:** P11-T08, P11-T09

---

## P11-06: Campaign Trend Analytics

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** P11-03

**Description:**
New function `Measure-SPCampaignTrends` in SP.AuditReport.psm1 that compares metrics
across multiple campaign cycles to show whether governance posture is improving or
degrading over time. Answers: "Are approval rates going up? Are reviewers getting
faster? Is our revocation rate decreasing?"

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Measure-SPCampaignTrends` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Measure-SPCampaignTrends {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignMetrics,
        [Parameter()][string]$GroupBy = 'Month',  # 'Week','Month','Quarter','Year'
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:** Array of campaign metric objects from `Measure-SPCampaignMetrics`.

**Flow:**
1. Group campaigns by time period (based on campaign creation date).
2. For each period, aggregate: total items, approval rate, revocation rate,
   completion rate, avg reviewer response time, reviewer count.
3. Calculate deltas between consecutive periods (change in approval rate, etc.).
4. Identify trends: improving (3+ consecutive periods of improvement), degrading
   (3+ consecutive periods of decline), stable (within +/- 2%).

**Returns:**
```powershell
@{
    Periods = @(
        @{
            Label          = '2026-Q1'
            CampaignCount  = 4
            TotalItems     = 500
            ApprovalRate   = 85.0
            RevocationRate = 12.0
            CompletionRate = 97.0
            AvgResponseHrs = 18.5
            Deltas         = @{
                ApprovalRate   = +2.0    # vs previous period
                RevocationRate = -1.5
                AvgResponseHrs = -3.2    # negative = faster = good
            }
        }
    )
    Trends = @{
        ApprovalRate   = 'Improving'   # Improving|Degrading|Stable
        RevocationRate = 'Stable'
        CompletionRate = 'Improving'
        AvgResponseHrs = 'Improving'
    }
    Summary = @{
        EarliestCampaign = '2026-01-15'
        LatestCampaign   = '2026-05-20'
        TotalCampaigns   = 12
        OverallDirection = 'Improving'  # majority of trends
    }
}
```

New function `Export-SPCampaignTrendHtml` generates a trend report:
- Period-over-period comparison table with directional arrows
- Color-coded deltas: green for improvement, red for degradation, gray for stable
- Summary section with overall governance posture assessment

**Acceptance Criteria:**
- 3 campaigns across 3 months produce 3 period entries with correct deltas
- Single-campaign input produces 1 period with no deltas (baseline)
- Trend detection requires 3+ periods (fewer = 'Insufficient Data')
- Decreasing AvgResponseHrs is classified as 'Improving' (faster is better)
- HTML report renders trend table with directional indicators

**Tests:** P11-T10, P11-T11

---

## P11-07: Entitlement Inventory Report

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none

**Description:**
New function `Get-SPEntitlementInventory` in SP.AuditQueries.psm1 that queries ISC
`/v3/entitlements` to build a per-source entitlement catalog. Combined with the
existing source coverage analysis (`Get-SPSourceCampaignCoverage`), this identifies
entitlements that have never been reviewed in any campaign.

ISC API endpoint: `GET /v3/entitlements` supports pagination and filtering by
`source.id`, `type`, and `attribute`. Returns entitlement objects with `id`, `name`,
`displayName`, `type`, `attribute`, `source`, `owner`, `privileged`, `description`.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPEntitlementInventory` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Get-SPEntitlementInventory {
    param(
        [Parameter()][string[]]$SourceIds,
        [Parameter()][switch]$IncludeReviewHistory,
        [Parameter()][int]$DaysBack = 365,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Query `GET /v3/entitlements` for each source ID (paginated, use
   `Invoke-SPApiRequest`). If no SourceIds provided, query all.
2. For each entitlement, record: Id, Name, DisplayName, Type, Attribute,
   SourceId, SourceName, Privileged, OwnerName.
3. If `-IncludeReviewHistory`: cross-reference entitlement names against
   access review items from recent campaigns (using `Get-SPAuditCampaigns` +
   `Get-SPAuditCertificationItems`). Mark each entitlement as reviewed or unreviewed.
4. Generate summary: total entitlements per source, privileged count,
   reviewed vs unreviewed count.

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Sources = @{
            'src-ad-001' = @{
                SourceName       = 'Corporate AD'
                TotalEntitlements = 150
                Privileged        = 12
                Reviewed          = 130    # (only with -IncludeReviewHistory)
                Unreviewed        = 20
                Entitlements = @(
                    @{ Name; DisplayName; Type; Privileged; Reviewed; LastReviewDate }
                )
            }
        }
        Summary = @{
            TotalSources      = 2
            TotalEntitlements = 280
            TotalPrivileged   = 20
            ReviewCoverage    = 92.8   # % of entitlements reviewed at least once
        }
    }
}
```

New function `Export-SPEntitlementInventoryHtml` generates an HTML inventory report:
- Per-source sections with entitlement tables
- Privileged entitlements highlighted in red
- Unreviewed entitlements highlighted in orange
- Summary card with coverage percentage

**Acceptance Criteria:**
- Paginated entitlement query handles >250 entitlements per source
- Privileged entitlements (ISC `privileged=true`) correctly identified
- Without `-IncludeReviewHistory`, Reviewed/Unreviewed fields are null
- With `-IncludeReviewHistory`, cross-reference matches by entitlement name + source
- HTML report groups entitlements by source with sortable columns
- Empty source (no entitlements) shows "No entitlements found" (not error)

**Tests:** P11-T12

---

## P11-08: Cross-Campaign Reviewer Analysis

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** P11-06

**Description:**
New function `Measure-SPReviewerReputation` in SP.AuditReport.psm1 that aggregates
reviewer performance and behavior patterns across multiple campaigns to build a
reviewer reputation profile. Identifies systemic issues (consistently slow reviewers,
chronic rubber-stampers) vs one-time anomalies.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Measure-SPReviewerReputation` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Measure-SPReviewerReputation {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][int]$MinCampaigns = 2,
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:** Array of campaign audit data (same structure used by `Export-SPAuditCsv`),
each containing ReviewerMetrics and RubberStampRisk data.

**Per-reviewer metrics (across all campaigns):**
1. **CampaignsParticipated**: Count of campaigns this reviewer was in
2. **TotalItemsReviewed**: Lifetime items reviewed
3. **AvgResponseHours**: Weighted average response time across campaigns
4. **ResponseTrend**: Getting faster or slower over time?
5. **ApprovalRate**: Lifetime approval percentage
6. **RubberStampCount**: Number of campaigns flagged for rubber-stamping
7. **EscalationCount**: Number of times this reviewer's certs were escalated
8. **ReputationScore**: Composite score (0-100) based on weighted factors
9. **ReputationTier**: Excellent (80+) / Good (60-79) / Needs Attention (40-59) / At Risk (<40)

**Scoring weights:**
- Response time (30%): Faster = higher score
- Completion rate (25%): Higher = better
- Decision diversity (20%): Mix of approve/revoke = higher (100% approve = lower)
- Consistency (15%): Low variance across campaigns = higher
- Escalation history (10%): Fewer escalations = higher

**Returns:**
```powershell
@{
    Reviewers = @(
        @{
            ReviewerName       = 'Bob Manager'
            ReviewerIdentityId = 'id-mgr-001'
            CampaignsParticipated = 5
            TotalItemsReviewed = 120
            AvgResponseHours   = 8.5
            ResponseTrend      = 'Improving'
            LifetimeApprovalRate = 82.0
            RubberStampCount   = 0
            EscalationCount    = 1
            ReputationScore    = 78
            ReputationTier     = 'Good'
        }
    )
    Summary = @{
        TotalReviewers   = 15
        Excellent        = 5
        Good             = 7
        NeedsAttention   = 2
        AtRisk           = 1
    }
}
```

**Acceptance Criteria:**
- Reviewer appearing in 5 campaigns gets aggregated metrics across all 5
- Reviewer with 100% approval rate across 50+ items gets lower decision diversity score
- Reviewer with 1 campaign and `MinCampaigns=2` is excluded (insufficient data)
- ReputationScore is 0-100 with no divide-by-zero errors
- Sorted by ReputationScore ascending (worst first, for actionability)

**Tests:** P11-T13

---

## P11-09: Daily Orchestrator Script

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** P11-01, P11-05

**Description:**
New CLI script `Scripts/Invoke-SPDailyOrchestrator.ps1` that runs the full daily
governance workflow as a single coordinated operation. Designed for scheduled task /
cron execution with comprehensive error handling and consolidated reporting.

Currently the daily workflow requires 4 separate script invocations with independent
configuration, error handling, and output. A scheduled task operator must chain them
manually and handle partial failures. The orchestrator consolidates this into one
invocation with dependency-aware execution and a consolidated daily summary.

**File to Create:**
- `Scripts/Invoke-SPDailyOrchestrator.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string[]]$SourceId,
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,

    # Step toggles (all default to $true)
    [Parameter()][switch]$SkipValidation,
    [Parameter()][switch]$SkipCleanup,
    [Parameter()][switch]$SkipDeltaCert,
    [Parameter()][switch]$SkipDeltaReport,
    [Parameter()][switch]$SkipEscalation,
    [Parameter()][switch]$SkipHealthCheck,

    # Overrides
    [Parameter()][int]$HoursBack,
    [Parameter()][int]$DeadlineDays,
    [Parameter()][string]$ReviewerMode,
    [Parameter()][int]$StaleHours,
    [Parameter()][string]$CampaignNamePrefix,

    # Output
    [Parameter()][ValidateSet('Console','JSON','Both')]
    [string]$OutputMode = 'Console',
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$Help,
    [Parameter()][switch]$WhatIf
)
```

**Execution steps (in order, with dependency handling):**
```
Step 1: Configuration Validation (Test-SPConfiguration)
  -> If errors: abort with exit code 4
  -> If warnings: log and continue

Step 2: Campaign Cleanup (Invoke-SPDeltaCertCleanup)
  -> Auto-complete past-due delta cert campaigns
  -> If failure: log WARN, continue (non-blocking)

Step 3: Delta Cert Run (Invoke-SPDeltaCertRun)
  -> Create campaigns for new AD access grants
  -> If failure: log ERROR, continue to health check

Step 4: Delta Report (Get-SPDeltaReportData + Export-SPDeltaReportHtml)
  -> Generate daily change report
  -> If failure: log WARN, continue (non-blocking)

Step 5: Escalation (Invoke-SPDeltaCertEscalate)
  -> Escalate stale certifications
  -> If failure: log WARN, continue (non-blocking)

Step 6: Health Check (Get-SPCampaignHealth)
  -> Check all active campaign health
  -> If Red campaigns found: log WARN with campaign names

Step 7: Daily Summary
  -> Consolidate results from all steps
  -> Write summary to console / JSON / JSONL audit trail
  -> Exit code based on worst result
```

**Exit codes:**
- 0 = All steps succeeded
- 1 = One or more non-critical steps had warnings
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration validation failed
- 5 = Critical step failed (delta cert creation or escalation error)

**Daily summary output:**
```
=== Daily Governance Orchestrator Summary ===
Date:       2026-05-23
Duration:   2m 34s
Config:     VALID (2 warnings)
Cleanup:    Completed 1 stale campaign
Delta Cert: Created 3 campaigns for 12 identities
Delta Rpt:  5 new grants, 2 revocations (report: DeltaCert/reports/delta-2026-05-23.html)
Escalation: Escalated 1 certification, skipped 0
Health:     3 active campaigns (2 Green, 1 Yellow)
Result:     SUCCESS
```

**JSONL audit trail event:**
Appended to `{DeltaCert.OutputPath}/orchestrator-audit.jsonl` with fields:
Timestamp, CorrelationID, Action='DailyOrchestrator', Steps (per-step results),
DurationSeconds, ExitCode.

**Acceptance Criteria:**
- All 6 steps execute in order with proper error isolation
- Step failure does not prevent subsequent steps from running
- `-SkipDeltaCert` omits step 3 (and so on for each toggle)
- `-WhatIf` passes through to all sub-steps
- Console summary shows status of every step
- JSONL event logged regardless of success/failure
- Exit code reflects worst outcome across all steps
- Works with both `-Token` (browser auth) and configured OAuth

**Tests:** P11-T14

---

## P11-10: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** P11-09

**Description:**
Pester tests for all new functions added in P11-01 through P11-09.

**File to Create:**
- `Tests/SP.ProductionReadiness.Tests.ps1`

**Test IDs:**

- P11-T01: Test-SPConfiguration returns error for empty TenantUrl
- P11-T02: Test-SPConfiguration returns warning for unknown config key
- P11-T03: Get-SPAuditTrail reads and merges JSONL files from multiple directories
- P11-T04: Get-SPAuditTrail filters by date range correctly
- P11-T05: Export-SPAuditCsv produces valid CSV with correct column headers
- P11-T06: Get-SPRemediationStatus classifies Provisioned when matching event exists
- P11-T07: Get-SPRemediationStatus classifies Overdue when past SLA with no event
- P11-T08: Get-SPCampaignHealth returns Red for overdue campaign
- P11-T09: Get-SPCampaignHealth returns Green for on-track campaign
- P11-T10: Measure-SPCampaignTrends calculates correct deltas between periods
- P11-T11: Measure-SPCampaignTrends identifies Improving trend for 3+ improving periods
- P11-T12: Get-SPEntitlementInventory handles paginated entitlement responses
- P11-T13: Measure-SPReviewerReputation excludes reviewers below MinCampaigns threshold
- P11-T14: Invoke-SPDailyOrchestrator.ps1 syntax validation (PS AST parser)

**Mock patterns:**
- Mock `Invoke-SPApiRequest` for API calls (entitlements, account-activities)
- Mock `Get-SPConfig` for config validation tests
- Mock `Search-SPCampaigns`, `Get-SPAuditCertifications` for health monitor
- Use `TestDrive:\` for JSONL file creation in consolidator tests
- Use `TestDrive:\` for CSV output verification

**Files to Modify:**
- `Tests/Import-TestModules.ps1` -- add module imports if needed

**Acceptance Criteria:**
- All 14 tests pass on PowerShell 7 (pwsh)
- No dependencies on external services (all API calls mocked)
- Tests are self-contained (create and clean up their own test data)

---

## Existing Patterns to Follow

| Pattern | Location | Reuse In |
|---------|----------|----------|
| API pagination | SP.AuditQueries.psm1 `Get-SPAuditCampaigns` | P11-07 |
| JSONL read/parse | SP.DeltaCertReport.psm1 `Get-SPDeltaReportData` | P11-02 |
| JSONL write (BOM-free) | SP.AuditReport.psm1 `Export-SPAuditJsonl` | P11-02, P11-09 |
| HTML report generation | SP.AuditReport.psm1 `Build-SingleCampaignHtml` | P11-06, P11-07 |
| CSV export | Standard `Export-Csv -NoTypeInformation` | P11-03 |
| Config defaults | SP.Config.psm1 `Get-SPConfigDefaults` | P11-01 |
| CLI script structure | Invoke-SPCampaignAudit.ps1 (param block, module loading, error handling) | P11-09 |
| Pester mock patterns | Tests/SP.AuditReport.Tests.ps1 | P11-10 |
| Health classification | SP.Campaigns.psm1 `Get-SPCampaignDeadlineStatus` | P11-05 |
| Metric aggregation | SP.AuditReport.psm1 `Measure-SPCampaignMetrics` | P11-06, P11-08 |

---

## ISC API Endpoints (New in Phase 11)

| Endpoint | Method | Used By | Purpose |
|----------|--------|---------|---------|
| `/v3/entitlements` | GET | P11-07 | List entitlements per source |
| `/v3/sources/{id}` | GET | P11-01 | Validate configured source IDs |
| `/v3/account-activities` | GET | P11-04 | Match revocation events (existing endpoint, new filter) |

All other features reuse data already fetched by existing functions.

---

## Daily Operations Reference (Post-Phase 11)

```powershell
# Single daily command (replaces 4 separate scripts)
.\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $token

# With overrides
.\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' `
    -HoursBack 48 -StaleHours 12 -Token $token

# Skip specific steps
.\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' `
    -SkipEscalation -SkipHealthCheck -Token $token

# Dry run
.\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -WhatIf

# Weekly: Full audit with trend analysis
.\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30 `
    -IncludeLeadershipRollup -DetailLevel Detailed

# Monthly: Entitlement inventory
.\Invoke-SPEntitlementInventory.ps1 -SourceId 'src-ad-001' `
    -IncludeReviewHistory -OutputMode HTML

# Quarterly: Trend analysis + reviewer reputation (via CSV export pipeline)
```
