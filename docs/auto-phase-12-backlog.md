# Phase 12: Operational Intelligence -- Backlog

**Created:** 2026-05-23
**Prereqs:** All Phases 1-11 complete
**Constraint:** NO GUI file changes (Windows GUI testing in progress on W-01 to W-07)

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `P12-01 -> P12-02 -> P12-03 -> P12-04 -> P12-05 -> P12-06 -> P12-07 -> P12-08 -> P12-09 -> P12-10`

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
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` (add new functions)
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` (export new functions)
- `Modules/SP.Core/SP.Config.psm1` (add config defaults)
- `Config/settings.json` (add new config sections)
- `Scripts/` (NEW scripts only)
- `Tests/` (NEW test files)

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| P12-01 | Compliance Evidence Package | none | DONE |
| P12-02 | Identity Risk Scoring | none | DONE |
| P12-03 | Source Governance Scorecard | none | DONE |
| P12-04 | Stale Access Detector | P12-03 | PENDING |
| P12-05 | Campaign Completion Summary | none | PENDING |
| P12-06 | Notification Dispatcher | none | PENDING |
| P12-07 | Orchestrator Run History | none | PENDING |
| P12-08 | Weekly Governance Digest Script | P12-02, P12-07 | PENDING |
| P12-09 | Log Retention and Archival | none | PENDING |
| P12-10 | Pester Tests | P12-09 | PENDING |

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Get-SPConfig` | SP.Config | P12-01, P12-06, P12-07, P12-08, P12-09 |
| `Invoke-SPApiRequest` | SP.ApiClient | P12-02, P12-03, P12-04 |
| `Search-SPCampaigns` | SP.Campaigns | P12-02, P12-05 |
| `Get-SPAuditCampaigns` | SP.AuditQueries | P12-02, P12-05 |
| `Get-SPAuditCertifications` | SP.AuditQueries | P12-02, P12-05 |
| `Get-SPAuditCertificationItems` | SP.AuditQueries | P12-02, P12-04 |
| `Group-SPAuditDecisions` | SP.AuditReport | P12-02, P12-05 |
| `Measure-SPAuditReviewerMetrics` | SP.AuditReport | P12-05 |
| `Measure-SPAuditRubberStampRisk` | SP.AuditReport | P12-02 |
| `Get-SPAuditRiskFlags` | SP.AuditReport | P12-02 |
| `Measure-SPCampaignMetrics` | SP.AuditReport | P12-05 |
| `Measure-SPCampaignTrends` | SP.AuditReport | P12-08 |
| `Measure-SPReviewerReputation` | SP.AuditReport | P12-08 |
| `Get-SPEntitlementInventory` | SP.AuditQueries | P12-03, P12-04 |
| `Get-SPRemediationStatus` | SP.AuditQueries | P12-05, P12-08 |
| `Get-SPCampaignHealth` | SP.Campaigns | P12-08 |
| `Get-SPAuditTrail` | SP.AuditReport | P12-01, P12-07 |
| `Export-SPAuditCsv` | SP.AuditReport | P12-01 |
| `Export-SPAuditHtml` | SP.AuditReport | P12-01 |
| `Export-SPAuditTrailHtml` | SP.AuditReport | P12-01 |
| `Export-SPCampaignTrendHtml` | SP.AuditReport | P12-01 |
| `Export-SPEntitlementInventoryHtml` | SP.AuditReport | P12-01 |
| `Send-SPReport` | SP.AuditReport | P12-06 |
| `Write-SPLog` | SP.Logging | All |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReport | P12-02, P12-03, P12-05 |
| `ConvertTo-SafeHtml` | SP.AuditReport | P12-02, P12-03, P12-05 |

---

## P12-01: Compliance Evidence Package

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Export-SPCompliancePackage` in SP.AuditReport.psm1 that bundles all
audit artifacts from a given date range into a single ZIP file with a JSON manifest.
This is the "hand to auditors" deliverable -- one file containing every report, CSV,
JSONL trail, and remediation proof for a review period.

Auditors for SOX 404, SOC 2, and ISO 27001 need a self-contained evidence package
they can ingest without navigating the toolkit's directory structure. Currently the
toolkit produces artifacts spread across Audit/, DeltaCert/, and leadership/
subdirectories with no index.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPCompliancePackage` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Export-SPCompliancePackage {
    param(
        [Parameter()][DateTime]$After,
        [Parameter()][DateTime]$Before,
        [Parameter()][string]$AuditOutputPath,
        [Parameter()][string]$DeltaCertOutputPath,
        [Parameter()][string]$OutputPath = '.',
        [Parameter()][string]$PackageName,
        [Parameter()][ValidateSet('Full','AuditOnly','DeltaCertOnly')]
        [string]$Scope = 'Full',
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Resolve paths from config if not provided.
2. Scan `AuditOutputPath` for: `*.html`, `*.csv`, `*.jsonl`, `*.txt` matching date range.
3. Scan `DeltaCertOutputPath` for: `*.html`, `*.jsonl` matching date range.
4. Scan `AuditOutputPath/leadership/` for leadership report HTML files.
5. Build a JSON manifest with:
   - `PackageId`: GUID
   - `GeneratedAt`: ISO 8601 timestamp
   - `DateRange`: `{After, Before}`
   - `ToolkitVersion`: from config
   - `Artifacts[]`: each with `{FileName, OriginalPath, Type, Category, SizeBytes, SHA256}`
   - `Summary`: `{TotalArtifacts, TotalSizeBytes, Categories}`
6. Create ZIP using `System.IO.Compression.ZipFile`:
   - `manifest.json` at root
   - `audit/` subfolder for audit artifacts
   - `deltacert/` subfolder for delta cert artifacts
   - `leadership/` subfolder for leadership reports
   - `csv/` subfolder for CSV exports
7. Name: `compliance-evidence-{YYYY-MM-DD}-to-{YYYY-MM-DD}.zip` (or `$PackageName`).

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        PackagePath    = 'C:\toolkit\compliance-evidence-2026-Q1.zip'
        PackageId      = 'a1b2c3d4-...'
        ArtifactCount  = 15
        TotalSizeBytes = 245000
        Categories     = @{
            AuditReports     = 4
            CsvExports       = 3
            AuditTrails      = 2
            LeadershipReports = 3
            DeltaCertReports = 2
            RemediationProof = 1
        }
    }
}
```

**Acceptance Criteria:**
- ZIP contains manifest.json with SHA256 hash per artifact
- Artifacts organized into subfolders by category
- Date range filter excludes files outside the window (by file modification time)
- Empty date range (no After/Before) includes all artifacts
- `-Scope AuditOnly` excludes DeltaCert directory scan
- ZIP is valid and extractable by standard tools
- Works on both PS 5.1 (Windows) and PS 7 (cross-platform)

**Tests:** P12-T01, P12-T02

---

## P12-02: Identity Risk Scoring

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Measure-SPIdentityRisk` in SP.AuditReport.psm1 that aggregates risk
signals per identity across all audited campaigns to produce a composite risk score.
Answers: "Which identities should we prioritize for access review?"

Currently risk flags exist per access-review item (`Get-SPAuditRiskFlags` returns
STALE, PRIVILEGED, ORPHAN, TERMINATED per item) but there is no identity-level
aggregation. An identity with 5 STALE flags and 3 PRIVILEGED flags across multiple
campaigns is a higher risk than one with a single flag, but the current system does
not surface this.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Measure-SPIdentityRisk` and
  `Export-SPIdentityRiskHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Measure-SPIdentityRisk {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][int]$HighRiskThreshold = 70,
        [Parameter()][int]$MediumRiskThreshold = 40,
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:** Array of campaign audit data (same structure used by `Export-SPAuditCsv`),
each containing decision data with risk flags, reviewer metrics, and identity events.

**Per-identity risk signals (accumulated across campaigns):**
1. **StaleAccessCount**: Number of access items flagged STALE (>90 days unreviewed)
2. **PrivilegedAccessCount**: Number of entitlements matching privileged patterns
3. **RubberStampApprovals**: Items approved by reviewers flagged for rubber-stamping
4. **OrphanAccountFlag**: Identity has orphan accounts (no manager, no source owner)
5. **OverdueRemediations**: Revocations past SLA that have not been provisioned
6. **ApprovalOnlyHistory**: Identity has never had access revoked across all campaigns
7. **CampaignsReviewed**: How many campaigns included this identity
8. **LastReviewDate**: Most recent campaign decision date for this identity

**Risk scoring (0-100):**
- Privileged access: +15 per privileged entitlement (max 30)
- Stale access: +10 per stale item (max 20)
- Rubber-stamp approvals: +10 per rubber-stamp approval (max 20)
- Orphan account: +15 (flat)
- Overdue remediation: +15 per overdue item (max 15)
- Approval-only history with 3+ campaigns: +10
- Not reviewed in 180+ days: +10

**Returns:**
```powershell
@{
    Identities = @(
        @{
            IdentityId           = 'id-001'
            IdentityName         = 'Alice Johnson'
            RiskScore            = 65
            RiskTier             = 'Medium'   # High (>=70) / Medium (>=40) / Low (<40)
            StaleAccessCount     = 3
            PrivilegedAccessCount = 2
            RubberStampApprovals = 1
            OrphanAccountFlag    = $false
            OverdueRemediations  = 0
            ApprovalOnlyHistory  = $true
            CampaignsReviewed    = 4
            LastReviewDate       = '2026-05-15'
            TopRiskFactors       = @('Privileged Access', 'Stale Access', 'Approval-Only History')
        }
    )
    Summary = @{
        TotalIdentities = 80
        High            = 5
        Medium          = 12
        Low             = 63
        AvgRiskScore    = 28.5
    }
}
```

New function `Export-SPIdentityRiskHtml` generates an HTML risk report:
- Sortable table with all identities, scored highest-risk first
- Risk tier badges (red/orange/green)
- Per-identity expandable detail showing contributing risk factors
- Summary card with tier distribution

**Acceptance Criteria:**
- Identity with 2 privileged + 3 stale items scores higher than identity with 1 of each
- Identity appearing in 0 campaigns gets score 0 (no data, not high risk)
- Rubber-stamp detection uses `Measure-SPAuditRubberStampRisk` output per campaign
- HTML report groups identities by risk tier with expandable detail rows
- Empty campaign audit input returns empty summary (not error)
- Risk score clamped to 0-100 range

**Tests:** P12-T03, P12-T04

---

## P12-03: Source Governance Scorecard

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Measure-SPSourceGovernance` in SP.AuditReport.psm1 that calculates a
governance coverage score per configured source. Answers: "How well is each source
being governed? Where are the blind spots?"

Currently `Get-SPSourceCampaignCoverage` (Phase 10) identifies which sources have
been included in campaigns vs never audited, but it does not calculate depth of
coverage -- a source included in one campaign that reviewed 5 of 150 entitlements
appears "covered" when 97% of its entitlements remain unreviewed.

This function combines entitlement inventory data (P11-07) with campaign review
history to produce a per-source governance grade.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Measure-SPSourceGovernance` and
  `Export-SPSourceGovernanceHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Measure-SPSourceGovernance {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][int]$ReviewWindowDays = 365,
        [Parameter()][string]$CorrelationID
    )
}
```

**Per-source metrics:**
1. **TotalEntitlements**: From entitlement inventory (or 'Unknown' if not provided)
2. **ReviewedEntitlements**: Entitlements that appeared in at least one campaign decision
3. **EntitlementCoveragePct**: ReviewedEntitlements / TotalEntitlements * 100
4. **PrivilegedEntitlements**: Count of privileged entitlements
5. **PrivilegedReviewedPct**: % of privileged entitlements that were reviewed
6. **CampaignCount**: Number of campaigns that included this source
7. **LastReviewDate**: Most recent campaign completion date for this source
8. **DaysSinceLastReview**: Calendar days since last review
9. **AvgReviewCycledays**: Average days between review campaigns
10. **GovernanceGrade**: A (90%+) / B (75-89%) / C (60-74%) / D (40-59%) / F (<40%)

**Grade calculation (weighted):**
- Entitlement coverage (40%): Higher coverage = better grade
- Privileged coverage (25%): Privileged entitlements must be reviewed more strictly
- Review recency (20%): Recent review within window = better
- Campaign frequency (15%): Multiple campaigns = better

**Returns:**
```powershell
@{
    Sources = @(
        @{
            SourceId               = 'src-ad-001'
            SourceName             = 'Corporate AD'
            TotalEntitlements      = 150
            ReviewedEntitlements   = 130
            EntitlementCoveragePct = 86.7
            PrivilegedEntitlements = 12
            PrivilegedReviewedPct  = 100.0
            CampaignCount          = 4
            LastReviewDate         = '2026-05-01'
            DaysSinceLastReview    = 22
            GovernanceGrade        = 'B'
            GovernanceScore        = 82.3
        }
    )
    Summary = @{
        TotalSources       = 3
        GradeDistribution  = @{ A = 1; B = 1; C = 0; D = 1; F = 0 }
        OverallCoveragePct = 78.5
        AvgGovernanceScore = 71.2
    }
}
```

New function `Export-SPSourceGovernanceHtml`:
- Per-source card with grade badge (color-coded A-F)
- Entitlement coverage bar chart (reviewed vs unreviewed)
- Privileged entitlement highlight section
- Last review date with recency indicator
- Summary card with overall coverage percentage

**Acceptance Criteria:**
- Source with 100% coverage + recent review + privileged fully covered -> Grade A
- Source with 0 campaigns -> Grade F (never reviewed)
- Source not in entitlement inventory -> grade based on campaign data only (coverage = 'Unknown')
- Empty campaign audit input returns empty summary (not error)
- HTML report renders grade badges with appropriate colors

**Tests:** P12-T05, P12-T06

---

## P12-04: Stale Access Detector

- **Status:** `PENDING`
- **Depends On:** P12-03

**Description:**
New function `Get-SPStaleAccess` in SP.AuditQueries.psm1 that identifies entitlements
and identity-entitlement pairs that have not been reviewed in any campaign within a
configurable window. Answers: "What access has never been certified or has gone
stale since the last review?"

This is different from the per-item STALE risk flag (which marks items not reviewed
in 90 days within a single campaign). This function looks across the entire campaign
history to find entitlements that have never appeared in any review, and identities
whose specific access has not been reviewed recently.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPStaleAccess` function
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPStaleAccessHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPStaleAccess {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][int]$StaleDays = 180,
        [Parameter()][string[]]$SourceIds,
        [Parameter()][switch]$PrivilegedOnly,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Build a map of every identity-entitlement pair seen in any campaign decision,
   with the most recent decision date for each.
2. If `$EntitlementInventory` is provided, cross-reference to find entitlements that
   appear in the inventory but have never appeared in any campaign decision.
3. Apply `$StaleDays` threshold: any pair not reviewed within the window is "stale."
4. If `-PrivilegedOnly`, filter to only privileged entitlements.
5. Classify each stale item:
   - **NeverReviewed**: Entitlement exists in inventory but has zero campaign decisions
   - **Expired**: Last review was more than `$StaleDays` ago
   - **PartialCoverage**: Entitlement reviewed for some identities but not all holders

**Returns:**
```powershell
@{
    StaleItems = @(
        @{
            SourceId         = 'src-ad-001'
            SourceName       = 'Corporate AD'
            EntitlementName  = 'AD-SG-LegacyApp'
            Privileged       = $false
            Classification   = 'NeverReviewed'
            IdentityCount    = 8      # identities holding this entitlement
            LastReviewDate   = $null
            DaysSinceReview  = $null
        }
    )
    Summary = @{
        TotalStaleItems  = 25
        NeverReviewed    = 10
        Expired          = 12
        PartialCoverage  = 3
        PrivilegedStale  = 2
        SourceBreakdown  = @{
            'Corporate AD' = 15
            'Cloud Entra'  = 10
        }
    }
}
```

New function `Export-SPStaleAccessHtml`:
- Grouped by source, then sorted by classification (NeverReviewed first)
- Privileged entitlements highlighted in red
- Summary card with total stale count and source breakdown
- Last review date column with color-coded recency

**Acceptance Criteria:**
- Entitlement in inventory but never in any campaign -> Classification = 'NeverReviewed'
- Entitlement reviewed 200 days ago with StaleDays=180 -> Classification = 'Expired'
- `-PrivilegedOnly` filters to privileged entitlements only
- Without `$EntitlementInventory`, only checks campaign history (no NeverReviewed items)
- Empty campaign audit input returns empty summary (not error)

**Tests:** P12-T07, P12-T08

---

## P12-05: Campaign Completion Summary

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Export-SPCampaignCompletionReport` in SP.AuditReport.psm1 that generates
a focused summary report for a single completed campaign. Designed to answer: "How
did this campaign go?" with KPIs, reviewer performance, and remediation tracking in
one page.

Currently the combined audit report (`Export-SPAuditHtml`) covers multiple campaigns
in one report. For operational use, teams need a per-campaign wrap-up that a campaign
owner can review and file as evidence. This is also the natural attachment for the
notification dispatcher (P12-06).

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPCampaignCompletionReport` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Export-SPCampaignCompletionReport {
    param(
        [Parameter(Mandatory)][hashtable]$CampaignAudit,
        [Parameter()][hashtable]$PreviousCycleAudit,
        [Parameter()][hashtable]$RemediationStatus,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:**
- `$CampaignAudit`: Single campaign audit data (from `Get-SPAuditCampaignReport`)
- `$PreviousCycleAudit`: Optional -- same campaign type from previous cycle for comparison
- `$RemediationStatus`: Optional -- output from `Get-SPRemediationStatus`

**Report sections:**
1. **Campaign header**: Name, type, dates, duration, status
2. **KPI dashboard**:
   - Completion rate (% items decided)
   - Approval rate vs revocation rate
   - Avg reviewer response time (hours)
   - On-time completion (yes/no vs deadline)
3. **Cycle-over-cycle comparison** (if `$PreviousCycleAudit` provided):
   - Delta in approval rate, response time, revocation count
   - Arrow indicators (up/down) with color coding
4. **Reviewer scorecard**:
   - Per-reviewer: items assigned, decided, pending, avg response hours
   - Rubber-stamp risk flag per reviewer
5. **Remediation tracking** (if `$RemediationStatus` provided):
   - Per-revocation: status (Provisioned/Pending/Overdue/Failed)
   - Avg days to remediate
   - SLA compliance percentage
6. **Risk summary**:
   - Top risk flags found (STALE, PRIVILEGED, ORPHAN, etc.)
   - Count per flag type

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        ReportPath    = 'Audit/completion-Q2-Access-Review-2026-05-23.html'
        CampaignName  = 'Q2 Access Review'
        KPIs = @{
            CompletionRate    = 100.0
            ApprovalRate      = 82.0
            RevocationRate    = 15.0
            AvgResponseHours  = 12.5
            OnTimeCompletion  = $true
        }
    }
}
```

**Acceptance Criteria:**
- Single-campaign report generates one HTML file with all 6 sections
- Without PreviousCycleAudit, comparison section shows "No prior cycle data"
- Without RemediationStatus, remediation section shows "Not available"
- KPI calculations match existing `Measure-SPCampaignMetrics` output
- HTML uses the same styling conventions as `Export-SPAuditHtml`
- File naming: `completion-{campaign-name-slug}-{date}.html`

**Tests:** P12-T09

---

## P12-06: Notification Dispatcher

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Send-SPNotification` in SP.AuditReport.psm1 that replaces the
`Send-SPReport` stub with a working notification system supporting SMTP email and
HTTP webhook backends. Also new function `Send-SPWebhook` for webhook delivery.

The existing `Send-SPReport` is a logging-only stub that acknowledges the intent
to send but does not deliver. For production use, teams need actual delivery of
health alerts, escalation notices, and completion reports.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Send-SPNotification` and
  `Send-SPWebhook` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions
- `Config/settings.json` -- add `Notification` section
- `Modules/SP.Core/SP.Config.psm1` -- add Notification defaults

**Config section:**
```json
"Notification": {
    "Backends": ["Log"],
    "Smtp": {
        "Server": "",
        "Port": 587,
        "From": "",
        "UseSsl": true,
        "CredentialMode": "None"
    },
    "Webhook": {
        "Url": "",
        "Method": "POST",
        "Headers": {},
        "IncludePayload": true
    }
}
```

`Backends` array controls which delivery methods are active: `Log` (always, writes
to Write-SPLog), `Smtp` (sends email), `Webhook` (HTTP POST).

**Function Signature:**
```powershell
function Send-SPNotification {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [Parameter()][ValidateSet('Info','Warning','Critical')]
        [string]$Severity = 'Info',
        [Parameter()][string]$Category,        # 'HealthAlert','Escalation','Completion','Digest'
        [Parameter()][string[]]$Recipients,    # email addresses (for SMTP)
        [Parameter()][string[]]$Attachments,   # file paths
        [Parameter()][hashtable]$Metadata,     # extra fields for webhook payload
        [Parameter()][string]$CorrelationID
    )
}

function Send-SPWebhook {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Payload,
        [Parameter()][string]$Method = 'POST',
        [Parameter()][hashtable]$Headers,
        [Parameter()][int]$TimeoutSeconds = 30,
        [Parameter()][string]$CorrelationID
    )
}
```

**Send-SPNotification flow:**
1. Read `Notification.Backends` from config.
2. **Log backend** (always): `Write-SPLog` at severity-mapped level with subject + body.
3. **Smtp backend** (if in Backends):
   - Validate Smtp config is populated. If not, WARN and skip.
   - Build `Send-MailMessage` call: `-SmtpServer`, `-From`, `-To $Recipients`,
     `-Subject "$SubjectPrefix $Subject"`, `-Body $Body`, `-BodyAsHtml`,
     `-Attachments $Attachments`, `-UseSsl:$UseSsl`.
   - PS 7 deprecation note: `Send-MailMessage` is deprecated in PS 7. Use it with
     `-WarningAction SilentlyContinue` for now. Document that PS 7 users should
     prefer the Webhook backend.
4. **Webhook backend** (if in Backends):
   - Build JSON payload: `{ timestamp, severity, category, subject, body, metadata }`.
   - Call `Send-SPWebhook` with configured URL + headers.
   - Compatible with Slack Incoming Webhooks, Microsoft Teams, PagerDuty, generic HTTP.

**Send-SPWebhook flow:**
1. `ConvertTo-Json -Depth 10` the payload.
2. `Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers -Body $json
   -ContentType 'application/json' -TimeoutSec $TimeoutSeconds`.
3. Return `@{ Success; StatusCode; Response; Error }`.

**Returns (Send-SPNotification):**
```powershell
@{
    Success = $true
    Data = @{
        Backends = @(
            @{ Backend = 'Log';     Status = 'Sent' }
            @{ Backend = 'Smtp';    Status = 'Sent' }
            @{ Backend = 'Webhook'; Status = 'Sent'; StatusCode = 200 }
        )
    }
}
```

**Acceptance Criteria:**
- With `Backends = ['Log']`, only logs -- no SMTP or HTTP calls
- With `Backends = ['Log','Webhook']`, logs and sends HTTP POST
- Webhook payload is valid JSON with all expected fields
- Missing SMTP config produces WARN log and skips (not error)
- Missing Webhook URL produces WARN log and skips (not error)
- `$Attachments` paths validated before send (non-existent file -> WARN, skip attachment)
- Send-SPWebhook returns HTTP status code for caller inspection

**Tests:** P12-T10, P12-T11

---

## P12-07: Orchestrator Run History

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Get-SPOrchestratorHistory` in SP.AuditReport.psm1 that parses the
`orchestrator-audit.jsonl` file written by `Invoke-SPDailyOrchestrator.ps1` (P11-09)
and produces an operational dashboard of daily run history. Also new function
`Export-SPOrchestratorHistoryHtml` for HTML output.

For production operations, teams need visibility into: "Is the daily orchestrator
running reliably? What failed? Are run times increasing?" Currently the JSONL file
exists but there is no function to parse it into a usable summary.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPOrchestratorHistory` and
  `Export-SPOrchestratorHistoryHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPOrchestratorHistory {
    param(
        [Parameter()][string]$JournalPath,
        [Parameter()][int]$DaysBack = 30,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. If `$JournalPath` not provided, resolve from config: `{DeltaCert.OutputPath}/orchestrator-audit.jsonl`.
2. Read each JSONL line, parse JSON.
3. Filter to events within `$DaysBack`.
4. For each run, extract: Timestamp, CorrelationID, ExitCode, DurationSeconds,
   and per-step results (Config validation, Cleanup, DeltaCert, DeltaReport,
   Escalation, HealthCheck).
5. Calculate operational metrics:
   - **RunCount**: Total runs in window
   - **SuccessRate**: % of runs with ExitCode 0
   - **AvgDuration**: Average run duration in seconds
   - **DurationTrend**: Getting faster or slower?
   - **FailureBreakdown**: Count per exit code (1=warnings, 4=config, 5=critical)
   - **StepReliability**: Per-step success rate
   - **ConsecutiveFailures**: Current streak of non-zero exit codes (if any)
   - **LastSuccessfulRun**: Timestamp of most recent ExitCode=0

**Returns:**
```powershell
@{
    Runs = @(
        @{
            Timestamp       = '2026-05-23T06:00:00Z'
            CorrelationID   = 'abc-123'
            ExitCode        = 0
            DurationSeconds = 154
            Steps = @{
                ConfigValidation = 'OK'
                Cleanup          = 'OK'
                DeltaCert        = 'Created 3 campaigns'
                DeltaReport      = 'OK'
                Escalation       = 'Escalated 1'
                HealthCheck      = '2 Green, 1 Yellow'
            }
        }
    )
    Metrics = @{
        RunCount             = 28
        SuccessRate          = 92.9
        AvgDurationSeconds   = 145
        DurationTrend        = 'Stable'
        FailureBreakdown     = @{ ExitCode1 = 2; ExitCode5 = 0 }
        ConsecutiveFailures  = 0
        LastSuccessfulRun    = '2026-05-23T06:00:00Z'
        StepReliability = @{
            ConfigValidation = 100.0
            Cleanup          = 96.4
            DeltaCert        = 92.9
            DeltaReport      = 100.0
            Escalation       = 100.0
            HealthCheck      = 100.0
        }
    }
}
```

New function `Export-SPOrchestratorHistoryHtml`:
- Daily run timeline with exit code color coding (green=0, yellow=1, red=4/5)
- Operational metrics dashboard cards
- Per-step reliability bars
- Duration trend line (simple HTML table-based visualization)
- Failure detail section for non-zero exit code runs

**Acceptance Criteria:**
- Parses JSONL lines written by Invoke-SPDailyOrchestrator format
- Malformed JSONL lines skipped with WARN (not crash)
- DaysBack filter works correctly
- Empty/missing JSONL file returns empty metrics (not error)
- SuccessRate calculated as percentage with one decimal
- ConsecutiveFailures counts from most recent run backwards
- HTML report renders timeline with color-coded exit codes

**Tests:** P12-T12, P12-T13

---

## P12-08: Weekly Governance Digest Script

- **Status:** `PENDING`
- **Depends On:** P12-02, P12-07

**Description:**
New CLI script `Scripts/Invoke-SPWeeklyDigest.ps1` that generates a comprehensive
weekly governance summary combining campaign activity, health status, identity risk
changes, reviewer performance, and orchestrator reliability into one report. Designed
for weekly distribution to governance leadership.

**File to Create:**
- `Scripts/Invoke-SPWeeklyDigest.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][int]$DaysBack = 7,
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string[]]$SourceId,

    # Section toggles
    [Parameter()][switch]$SkipCampaignSummary,
    [Parameter()][switch]$SkipIdentityRisk,
    [Parameter()][switch]$SkipReviewerAnalysis,
    [Parameter()][switch]$SkipOrchestratorHealth,
    [Parameter()][switch]$SkipRemediationTracking,

    # Output
    [Parameter()][ValidateSet('Console','HTML','JSON','Both')]
    [string]$OutputMode = 'Console',
    [Parameter()][string]$OutputPath,

    # Notification
    [Parameter()][switch]$SendNotification,
    [Parameter()][string[]]$NotifyRecipients,

    [Parameter()][switch]$Help,
    [Parameter()][switch]$WhatIf
)
```

**Report sections:**

1. **Campaign Activity Summary** (uses `Search-SPCampaigns`, `Measure-SPCampaignMetrics`):
   - Campaigns created/completed/still active this week
   - Total items reviewed, approval/revocation breakdown
   - Comparison to previous week (delta)

2. **Current Health Status** (uses `Get-SPCampaignHealth`):
   - Active campaign health: Red/Yellow/Green counts
   - Stale reviewer alerts
   - Projected completion dates for active campaigns

3. **Identity Risk Highlights** (uses `Measure-SPIdentityRisk` from P12-02):
   - Top 10 highest-risk identities
   - New high-risk identities since last week
   - Risk tier distribution changes

4. **Reviewer Performance** (uses `Measure-SPReviewerReputation`):
   - Top 5 / bottom 5 reviewers by reputation score
   - Response time trends
   - New rubber-stamp flags this week

5. **Remediation Tracking** (uses `Get-SPRemediationStatus`):
   - SLA compliance rate (% provisioned within SLA)
   - Overdue remediations requiring attention
   - Avg days to remediate trend

6. **Orchestrator Health** (uses `Get-SPOrchestratorHistory` from P12-07):
   - Runs this week: success/failure count
   - Average duration trend
   - Step-level failures (if any)

**Console output:**
```
=== Weekly Governance Digest ===
Period:         2026-05-16 to 2026-05-23
Generated:      2026-05-23T12:00:00Z

--- Campaign Activity ---
  Created: 5 | Completed: 3 | Active: 4
  Items Reviewed: 250 | Approved: 210 (84%) | Revoked: 35 (14%)
  vs Last Week: +2 campaigns, -3% approval rate

--- Active Campaign Health ---
  Red: 0 | Yellow: 1 | Green: 3

--- Top Identity Risks ---
  1. Alice Johnson     Score: 85 (High) - Privileged, Stale, Approval-Only
  2. Bob ServiceAcct   Score: 72 (High) - Orphan, Privileged

--- Reviewer Performance ---
  Best:  Carol Manager  (Score: 92, Avg 4.2h)
  Worst: Dave Admin     (Score: 38, Avg 72h, Rubber-stamp)

--- Remediation SLA ---
  Compliance: 87% (13 of 15 within 48h SLA)
  Overdue: 2 items requiring attention

--- Orchestrator Health ---
  Runs: 7/7 successful | Avg: 2m 15s | Trend: Stable
```

**HTML output:** Full report with all sections, using the same CSS styling as
existing audit reports. Saved to `{Audit.OutputPath}/digest-{date}.html`.

**Exit codes:**
- 0 = Digest generated successfully
- 1 = One or more sections had warnings (partial data)
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Critical section failed

When `-SendNotification` is set, calls `Send-SPNotification` (P12-06) with the
digest as body/attachment.

**Acceptance Criteria:**
- All 6 sections generate with real API data
- Section skip switches exclude the corresponding section
- `-OutputMode HTML` produces a self-contained HTML file
- Console output is concise and scannable
- `-WhatIf` shows what would be generated without API calls
- `-SendNotification` triggers notification dispatch if configured
- Works with both `-Token` and configured OAuth

**Tests:** P12-T14

---

## P12-09: Log Retention and Archival

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Invoke-SPLogRetention` in SP.AuditReport.psm1 that implements retention
policies for the toolkit's output directories. Archives old files to compressed ZIP
and removes files past their retention period. For production deployments that run
daily, output directories grow indefinitely without cleanup.

Currently `Logging.RetentionDays` (30) exists in config but is not enforced by any
function. JSONL files, HTML reports, and CSV exports accumulate without bound.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Invoke-SPLogRetention` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function
- `Config/settings.json` -- add `Retention` section
- `Modules/SP.Core/SP.Config.psm1` -- add Retention defaults

**Config section:**
```json
"Retention": {
    "Enabled": false,
    "ArchiveDays": 30,
    "DeleteDays": 90,
    "ArchivePath": ".\\Archive",
    "Paths": ["Audit", "DeltaCert", "Logs"]
}
```

**Function Signature:**
```powershell
function Invoke-SPLogRetention {
    param(
        [Parameter()][int]$ArchiveDays,
        [Parameter()][int]$DeleteDays,
        [Parameter()][string]$ArchivePath,
        [Parameter()][string[]]$Paths,
        [Parameter()][switch]$WhatIf,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Read retention config if parameters not provided.
2. Check `Retention.Enabled` -- if false, log INFO and return (safety default).
3. For each path in `$Paths`:
   a. Find files older than `$ArchiveDays` but younger than `$DeleteDays`.
   b. Create monthly archive ZIP: `{ArchivePath}/{path}-{YYYY-MM}.zip`.
   c. Add qualifying files to the ZIP.
   d. Remove archived files from source directory.
4. Find files older than `$DeleteDays` in archive directory.
5. Delete expired archives.
6. Log all actions to Write-SPLog.

**Safety guards:**
- `Retention.Enabled` must be `true` (default `false` -- opt-in)
- Minimum `ArchiveDays` = 7 (refuse to archive files less than 7 days old)
- Minimum `DeleteDays` = 30 (refuse to delete files less than 30 days old)
- `DeleteDays` must be > `ArchiveDays` (validate at start)
- `-WhatIf` lists all actions without performing them
- Never delete files that are not toolkit-generated (skip unknown extensions)

**Known extensions (safe to archive/delete):**
`.html`, `.csv`, `.jsonl`, `.txt`, `.log`, `.json`

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Archived = @{
            FileCount  = 15
            TotalBytes = 524000
            Archives   = @('Archive/Audit-2026-03.zip', 'Archive/DeltaCert-2026-03.zip')
        }
        Deleted = @{
            FileCount  = 3
            TotalBytes = 45000
            Files      = @('Archive/Audit-2026-01.zip')
        }
        Skipped = @{
            FileCount = 2
            Reasons   = @('Unknown extension: .bak', 'File locked: audit.jsonl')
        }
    }
}
```

**Acceptance Criteria:**
- `Retention.Enabled = false` produces INFO log and no-op return (safe default)
- Files older than ArchiveDays are moved to monthly ZIP archives
- Files older than DeleteDays are permanently removed
- ArchiveDays < 7 rejected with error
- DeleteDays <= ArchiveDays rejected with error
- `-WhatIf` describes all actions without performing them
- Locked files (open by another process) skipped with WARN (not crash)
- ZIP archives are valid and extractable

**Tests:** P12-T15, P12-T16

---

## P12-10: Pester Tests

- **Status:** `PENDING`
- **Depends On:** P12-09

**Description:**
Pester tests for all new functions added in P12-01 through P12-09.

**File to Create:**
- `Tests/SP.OperationalIntelligence.Tests.ps1`

**Test IDs:**

- P12-T01: Export-SPCompliancePackage creates ZIP with manifest.json containing artifact hashes
- P12-T02: Export-SPCompliancePackage -Scope AuditOnly excludes DeltaCert artifacts
- P12-T03: Measure-SPIdentityRisk scores identity with 2 privileged + 3 stale items higher than 1 each
- P12-T04: Measure-SPIdentityRisk returns empty summary for empty campaign input
- P12-T05: Measure-SPSourceGovernance assigns Grade A to source with 100% coverage and recent review
- P12-T06: Measure-SPSourceGovernance assigns Grade F to source with 0 campaigns
- P12-T07: Get-SPStaleAccess classifies entitlement in inventory but not in campaigns as NeverReviewed
- P12-T08: Get-SPStaleAccess classifies entitlement reviewed 200 days ago as Expired (StaleDays=180)
- P12-T09: Export-SPCampaignCompletionReport generates HTML with all 6 sections
- P12-T10: Send-SPNotification with Backends=['Log'] only logs, no HTTP calls
- P12-T11: Send-SPWebhook sends JSON POST and returns status code
- P12-T12: Get-SPOrchestratorHistory parses JSONL and calculates correct SuccessRate
- P12-T13: Get-SPOrchestratorHistory returns empty metrics for missing JSONL file
- P12-T14: Invoke-SPWeeklyDigest.ps1 syntax validation (PS AST parser)
- P12-T15: Invoke-SPLogRetention with Enabled=false returns no-op
- P12-T16: Invoke-SPLogRetention with WhatIf describes actions without performing them

**Mock patterns:**
- Mock `Invoke-SPApiRequest` for API calls (campaigns, certifications, entitlements)
- Mock `Get-SPConfig` for config-dependent tests
- Mock `Invoke-RestMethod` for webhook tests
- Mock `Send-MailMessage` for SMTP tests (verify it is NOT called when not configured)
- Use `TestDrive:\` for ZIP creation, JSONL parsing, and file retention tests
- Use `TestDrive:\` for HTML output verification

**Files to Modify:**
- `Tests/Import-TestModules.ps1` -- add module imports if needed

**Acceptance Criteria:**
- All 16 tests pass on PowerShell 7 (pwsh)
- No dependencies on external services (all API calls mocked)
- Tests are self-contained (create and clean up their own test data)

---

## Existing Patterns to Follow

| Pattern | Location | Reuse In |
|---------|----------|----------|
| ZIP creation | `System.IO.Compression.ZipFile` (standard .NET) | P12-01, P12-09 |
| JSONL read/parse | SP.AuditReport.psm1 `Get-SPAuditTrail` | P12-07 |
| JSONL write (BOM-free) | SP.AuditReport.psm1 `Export-SPAuditJsonl` | P12-08 |
| HTML report generation | SP.AuditReport.psm1 `Build-SingleCampaignHtml` | P12-02, P12-03, P12-04, P12-05 |
| HTML table helpers | SP.AuditReport.psm1 `Build-HtmlTableRow` / `Build-HtmlTableHeader` | P12-02, P12-03, P12-05 |
| Risk flag detection | SP.AuditReport.psm1 `Get-SPAuditRiskFlags` | P12-02 |
| Reviewer metrics | SP.AuditReport.psm1 `Measure-SPAuditReviewerMetrics` | P12-05 |
| Campaign metrics | SP.AuditReport.psm1 `Measure-SPCampaignMetrics` | P12-05 |
| Config defaults | SP.Config.psm1 `Get-SPConfigDefaults` | P12-06, P12-09 |
| CLI script structure | Invoke-SPDailyOrchestrator.ps1 (param block, module loading, error handling) | P12-08 |
| Pester mock patterns | Tests/SP.ProductionReadiness.Tests.ps1 | P12-10 |
| Send-MailMessage stub | SP.AuditReport.psm1 `Send-SPReport` | P12-06 |
| Webhook / REST call | SP.ApiClient.psm1 `Invoke-SPApiRequest` (pattern, not reuse) | P12-06 |
| Entitlement inventory | SP.AuditQueries.psm1 `Get-SPEntitlementInventory` | P12-03, P12-04 |

---

## ISC API Endpoints (No New Endpoints in Phase 12)

Phase 12 builds analytics on top of data already fetched by existing functions.
No new ISC API endpoints are introduced. All features consume existing function
output (campaign audits, entitlement inventory, remediation status, etc.).

---

## Weekly Operations Reference (Post-Phase 12)

```powershell
# Daily -- unchanged from Phase 11
.\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $token

# Weekly -- new in Phase 12
.\Invoke-SPWeeklyDigest.ps1 -SourceId 'src-ad-001' -Token $token `
    -OutputMode Both -SendNotification

# Monthly -- compliance evidence packaging
$audits = Get-SPAuditCampaigns -DaysBack 30 | ForEach-Object {
    Get-SPAuditCampaignReport -CampaignId $_.id
}
Export-SPCompliancePackage -After (Get-Date).AddDays(-30) -Before (Get-Date)

# Quarterly -- governance scorecard
$audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object {
    Get-SPAuditCampaignReport -CampaignId $_.id
}
$inventory = Get-SPEntitlementInventory -SourceIds @('src-ad-001') -IncludeReviewHistory
Measure-SPSourceGovernance -CampaignAudits $audits -EntitlementInventory $inventory.Data

# Ad-hoc -- identity risk review
Measure-SPIdentityRisk -CampaignAudits $audits | Where-Object { $_.RiskTier -eq 'High' }

# Maintenance -- log retention (monthly cron)
Invoke-SPLogRetention -WhatIf   # preview first
Invoke-SPLogRetention           # execute
```
