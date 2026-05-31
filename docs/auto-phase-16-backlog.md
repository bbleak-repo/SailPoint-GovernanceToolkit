# Phase 16: Data Quality, Operational Visibility & Predictive Governance -- Backlog

**Created:** 2026-05-30
**Prereqs:** All Phases 1-12 complete, QH-01 to QH-20 complete
**Constraint:** NO GUI file changes

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `P16-01 -> P16-02 -> P16-03 -> P16-04 -> P16-05 -> P16-06 -> P16-07 -> P16-08 -> P16-09 -> P16-10`

**Parallel groups (items sharing no file targets):**
- **Group A** (independent): P16-01, P16-05, P16-06
- **Group B** (after P16-01): P16-02, P16-03, P16-07
- **Group C** (after P16-03): P16-04
- **Group D** (after P16-01, P16-03): P16-08
- **Group E** (after P16-06, P16-05): P16-09
- **Group F** (after P16-09): P16-10

---

## GUI Constraint (CRITICAL)

Do NOT modify these files:
- `Gui/*.xaml` (any XAML file)
- `Modules/SP.Gui/SP.MainWindow.psm1`
- `Modules/SP.Gui/SP.GuiBridge.psm1`
- `Modules/SP.Gui/SP.Gui.psd1`

Safe to modify:
- `Modules/SP.Audit/SP.AuditQueries.psm1` (add new functions)
- `Modules/SP.Audit/SP.AuditAnalytics.psm1` (add new functions)
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` (add new functions)
- `Modules/SP.Audit/SP.AuditOperations.psm1` (add new functions)
- `Modules/SP.Audit/SP.Audit.psd1` (export new functions)
- `Modules/SP.Api/SP.Campaigns.psm1` (add new functions)
- `Modules/SP.Api/SP.Api.psd1` (export new functions)
- `Config/settings.json` (add new config sections)
- `Scripts/` (NEW scripts only)
- `Tests/` (NEW test files)

---

## Phase Summary

| ID | Feature | Depends On | Files | Status |
|----|---------|------------|-------|--------|
| P16-01 | Orphan Account Detector | none | SP.AuditQueries, SP.AuditReportHtml, SP.Audit.psd1 | DONE |
| P16-02 | Source Aggregation Health Monitor | none | SP.AuditQueries, SP.AuditReportHtml, SP.Audit.psd1 | DONE |
| P16-03 | Identity Attribute Quality Score | none | SP.AuditQueries, SP.AuditReportHtml, SP.Audit.psd1 | DONE |
| P16-04 | Campaign Coverage Gap Analysis | none | SP.AuditAnalytics, SP.AuditReportHtml, SP.Audit.psd1 | DONE |
| P16-05 | Access Certification Completion Predictor | none | SP.AuditAnalytics, SP.AuditReportHtml, SP.Audit.psd1 | DONE |
| P16-06 | Governance Metrics Time Series Store | none | SP.AuditOperations, SP.Audit.psd1, settings.json | DONE |
| P16-07 | Reviewer Delegation Audit Trail | none | SP.AuditQueries, SP.AuditReportHtml, SP.Audit.psd1 | DONE |
| P16-08 | Invoke-SPDataQualityReport.ps1 | P16-01, P16-03 | Scripts/ (new) | PENDING |
| P16-09 | Invoke-SPGovernanceMetrics.ps1 | P16-05, P16-06 | Scripts/ (new) | PENDING |
| P16-10 | Pester Tests | P16-09 | Tests/ (new) | PENDING |

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Get-SPConfig` | SP.Config | P16-06, P16-08, P16-09 |
| `Invoke-SPApiRequest` | SP.ApiClient | P16-01, P16-02, P16-03, P16-07 |
| `Get-SPEntitlementInventory` | SP.AuditQueries | P16-01, P16-03, P16-04 |
| `Get-SPAccessProfileInventory` | SP.AuditQueries | P16-04 |
| `Get-SPRoleInventory` | SP.AuditQueries | P16-04 |
| `Get-SPAuditCampaigns` | SP.AuditQueries | P16-04, P16-05, P16-09 |
| `Get-SPAuditCampaignReport` | SP.AuditQueries | P16-04, P16-07 |
| `Get-SPSourceCampaignCoverage` | SP.AuditQueries | P16-04 |
| `Get-SPStaleAccess` | SP.AuditQueries | P16-04 |
| `Get-SPCampaignHealth` | SP.Campaigns | P16-05, P16-09 |
| `Get-SPCampaignDeadlineStatus` | SP.Campaigns | P16-05 |
| `Measure-SPCampaignMetrics` | SP.AuditReportCore | P16-05, P16-09 |
| `Measure-SPIdentityRisk` | SP.AuditAnalytics | P16-06, P16-09 |
| `Measure-SPSourceGovernance` | SP.AuditAnalytics | P16-06, P16-09 |
| `Measure-SPGovernanceMaturity` | SP.AuditAnalytics | P16-06, P16-09 |
| `Measure-SPReviewerReputation` | SP.AuditAnalytics | P16-06, P16-09 |
| `Get-SPOrchestratorHistory` | SP.AuditOperations | P16-06, P16-09 |
| `Export-SPAuditJsonl` | SP.AuditReportHtml | P16-06 |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReportHtml | P16-01, P16-02, P16-03, P16-04, P16-05, P16-07 |
| `ConvertTo-SafeHtml` | SP.AuditReportHtml | P16-01, P16-02, P16-03, P16-04, P16-05, P16-07 |
| `Write-SPLog` | SP.Logging | All |

---

## P16-01: Orphan Account Detector

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Get-SPOrphanAccounts` in SP.AuditQueries.psm1 and
`Export-SPOrphanAccountHtml` in SP.AuditReportHtml.psm1 that detect accounts in
ISC sources not correlated to any active identity.

Answers: "Which accounts exist in our sources but are not linked to any known
identity? Are there accounts belonging to terminated employees that were never
deprovisioned?"

Orphan accounts are a top audit finding in SOX, SOC 2, and ISO 27001 reviews.
They represent access that is not governed by any identity lifecycle process --
no certifications, no lifecycle triggers, no manager oversight. Common causes:
accounts created before ISC onboarding, manual account creation outside
provisioning, failed deprovisioning after termination, or correlation rule gaps.

The toolkit currently checks stale access (entitlements not recently reviewed)
and remediation status (revocations not yet provisioned), but has no visibility
into accounts that exist entirely outside the identity governance scope.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPOrphanAccounts` function
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- new `Export-SPOrphanAccountHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signatures:**
```powershell
function Get-SPOrphanAccounts {
    param(
        [Parameter(Mandatory)][string[]]$SourceIds,
        [Parameter()][switch]$IncludeDisabledAccounts,
        [Parameter()][switch]$IncludeServiceAccounts,
        [Parameter()][string]$CorrelationID
    )
}
```

**Get-SPOrphanAccounts flow:**
1. For each source in `$SourceIds`, query `GET /v3/accounts` (paginated,
   `limit=250&offset=N`, filter: `sourceId eq "{sourceId}"`).
2. For each account, check the `identityId` field:
   - **Uncorrelated**: `identityId` is null -- account has no identity link.
   - **Correlated**: `identityId` is present -- query `GET /v3/public-identities/{identityId}`
     to check lifecycle state.
     - If identity lifecycle state is `TERMINATED` or `INACTIVE`: classify as
       **TerminatedOwner**.
     - If identity not found (404): classify as **DanglingReference**.
     - If identity is active: skip (healthy account).
3. For uncorrelated accounts, check `disabled` field:
   - If disabled and `-IncludeDisabledAccounts` not set: skip.
   - Otherwise include.
4. For uncorrelated accounts, check account name patterns for service accounts
   (prefix `svc-`, `sa-`, `service.`, or containing `$` for AD machine accounts):
   - If service account and `-IncludeServiceAccounts` not set: skip.
   - Otherwise include with `IsServiceAccount = $true`.
5. Record per account: AccountId, AccountName, SourceId, SourceName, NativeIdentity,
   Disabled, HasEntitlements, EntitlementCount, Created, OrphanType
   (Uncorrelated/TerminatedOwner/DanglingReference), IsServiceAccount.
6. Batch identity lookups: deduplicate identity IDs and query in batches to minimize
   API calls for TerminatedOwner detection.

**Returns:**
```powershell
@{
    OrphanAccounts = @(
        @{
            AccountId        = 'acct-001'
            AccountName      = 'jsmith_old'
            SourceId         = 'src-ad-001'
            SourceName       = 'Corporate AD'
            NativeIdentity   = 'CN=jsmith_old,OU=Users,DC=corp'
            Disabled         = $false
            HasEntitlements  = $true
            EntitlementCount = 3
            Created          = '2024-03-15T00:00:00Z'
            OrphanType       = 'Uncorrelated'
            IsServiceAccount = $false
        }
    )
    Summary = @{
        TotalAccountsScanned = 1200
        TotalOrphans         = 18
        Uncorrelated         = 10
        TerminatedOwner      = 5
        DanglingReference    = 3
        DisabledOrphans      = 4
        ServiceAccountOrphans = 2
        OrphansWithEntitlements = 12
        PerSource = @{
            'Corporate AD'   = @{ Total = 500; Orphans = 12; OrphanPct = 2.4 }
            'Cloud Entra'    = @{ Total = 700; Orphans = 6;  OrphanPct = 0.9 }
        }
    }
}
```

New function `Export-SPOrphanAccountHtml`:
- Per-source orphan account table grouped by OrphanType
- OrphanType badges: Uncorrelated (red), TerminatedOwner (orange), DanglingReference (yellow)
- Accounts with entitlements highlighted (active access risk)
- Service accounts visually separated
- Summary card with orphan rate per source
- Recommendation section per OrphanType with remediation steps

**Acceptance Criteria:**
- Paginated account query handles >250 accounts per source
- Uncorrelated account (null identityId) classified correctly
- Terminated identity account classified as TerminatedOwner (not Uncorrelated)
- Identity 404 classified as DanglingReference
- Without `-IncludeDisabledAccounts`, disabled orphans excluded from results
- Without `-IncludeServiceAccounts`, service accounts excluded
- Empty source (0 accounts) returns valid entry with 0 orphans (not error)
- Identity lookups batched and deduplicated
- HTML report uses same styling as existing audit reports

**Tests:** P16-T01, P16-T02

---

## P16-02: Source Aggregation Health Monitor

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Get-SPSourceAggregationHealth` in SP.AuditQueries.psm1 and
`Export-SPSourceAggregationHealthHtml` in SP.AuditReportHtml.psm1 that query
source connection status and recent aggregation history to detect sources that
have stopped syncing or are experiencing data freshness issues.

Answers: "Are all our sources connected and aggregating successfully? When did
each source last sync? Are there sources that have been failing silently?"

Source aggregation is the foundation of identity governance. If a source stops
aggregating, ISC's view of accounts and entitlements becomes stale -- new accounts
are invisible, terminated accounts appear active, and entitlement changes go
undetected. Certification campaigns run against stale data are meaningless.

The toolkit monitors campaign health and governance coverage but has no
visibility into the data pipeline itself. A source that stops syncing does not
trigger any toolkit alert -- it silently degrades data quality until someone
notices discrepancies in a certification review.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPSourceAggregationHealth`
  function
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- new
  `Export-SPSourceAggregationHealthHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPSourceAggregationHealth {
    param(
        [Parameter()][string[]]$SourceIds,
        [Parameter()][int]$MaxAcceptableStalenessHours = 48,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Query `GET /v3/sources` (paginated) to get all sources (or filtered by
   `$SourceIds`). For each source, record: Id, Name, Type, ConnectorType,
   Enabled (the `healthy` and `status` fields from the API response).
2. For each source, query `GET /v3/account-aggregations` with
   `filters=sourceId eq "{sourceId}"&sorters=-started&limit=5` to get recent
   aggregation events.
3. From the most recent aggregation, extract: Started, Completed, Duration,
   Status (SUCCESS/ERROR/TERMINATED), TotalAccounts, AccountsProcessed,
   ErrorCount, WarningCount.
4. Calculate health indicators per source:
   - **DataFreshnessHours**: Hours since last successful aggregation completed.
   - **IsStale**: DataFreshnessHours > `$MaxAcceptableStalenessHours`.
   - **LastStatus**: Status of most recent aggregation.
   - **ConsecutiveFailures**: Count of consecutive non-SUCCESS aggregations
     from the 5 most recent.
   - **AvgDurationMinutes**: Average aggregation duration from recent history.
   - **AccountTrend**: Account count change between two most recent successful
     aggregations (increase, decrease, stable).
5. Classify source health:
   - **Healthy**: Last aggregation SUCCESS, not stale, 0 consecutive failures.
   - **Warning**: Last aggregation SUCCESS but stale, OR 1 consecutive failure,
     OR significant account count drop (>10% decrease).
   - **Critical**: 2+ consecutive failures, OR last aggregation ERROR with
     no successful aggregation within 2x MaxAcceptableStalenessHours.
   - **Unknown**: No aggregation history found.

**Returns:**
```powershell
@{
    Sources = @(
        @{
            SourceId              = 'src-ad-001'
            SourceName            = 'Corporate AD'
            SourceType            = 'Active Directory - Direct'
            Enabled               = $true
            HealthStatus          = 'Healthy'
            LastAggregation = @{
                Started           = '2026-05-30T02:00:00Z'
                Completed         = '2026-05-30T02:15:00Z'
                DurationMinutes   = 15
                Status            = 'SUCCESS'
                TotalAccounts     = 1200
                ErrorCount        = 0
            }
            DataFreshnessHours    = 12.5
            IsStale               = $false
            ConsecutiveFailures   = 0
            AvgDurationMinutes    = 14.2
            AccountTrend          = 'Stable'
            AccountTrendDetail    = '+2 accounts since previous aggregation'
        }
    )
    Summary = @{
        TotalSources        = 3
        Healthy             = 2
        Warning             = 1
        Critical            = 0
        Unknown             = 0
        StaleSources        = 0
        AvgFreshnessHours   = 18.3
        SourcesWithFailures = 1
    }
}
```

New function `Export-SPSourceAggregationHealthHtml`:
- Per-source health card with status badge (Healthy green, Warning yellow,
  Critical red, Unknown gray)
- Last aggregation details: timestamp, duration, account count
- Data freshness meter (visual bar showing hours since last sync)
- Consecutive failure count with trend arrow
- Account count trend indicator (up/down/stable arrow)
- Summary card with health distribution

**Acceptance Criteria:**
- Source with successful recent aggregation classified as Healthy
- Source with 2+ consecutive failures classified as Critical
- Source with no aggregation history classified as Unknown (not error)
- DataFreshnessHours calculated from last successful aggregation (not last attempt)
- Account trend calculated only from successful aggregations
- Without `$SourceIds`, queries all enabled sources
- Disabled sources excluded unless explicitly requested via SourceIds
- Paginated source query handles >250 sources
- HTML report uses same styling as existing audit reports

**Tests:** P16-T03, P16-T04

---

## P16-03: Identity Attribute Quality Score

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Measure-SPIdentityDataQuality` in SP.AuditQueries.psm1 and
`Export-SPIdentityDataQualityHtml` in SP.AuditReportHtml.psm1 that evaluate
the completeness and consistency of identity attributes across the tenant.

Answers: "How complete is our identity data? Which identities are missing
managers, departments, or other critical attributes? Which attributes are
most commonly incomplete?"

Identity data quality directly impacts governance effectiveness. A missing
manager means ISC cannot route certifications to the correct reviewer. A
missing department means role-based policies cannot be applied. An empty
email means notifications cannot be delivered. Poor identity data does not
cause visible errors -- it causes silent governance failures where the right
people never see the right reviews.

The toolkit extensively analyzes access decisions, campaign metrics, and
entitlement coverage, but assumes identity data is correct. This function
validates that assumption.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Measure-SPIdentityDataQuality`
  function
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- new `Export-SPIdentityDataQualityHtml`
  function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Measure-SPIdentityDataQuality {
    param(
        [Parameter()][int]$Limit = 500,
        [Parameter()][string[]]$RequiredAttributes,
        [Parameter()][switch]$ActiveOnly,
        [Parameter()][string]$CorrelationID
    )
}
```

**Default required attributes:**
`@('manager', 'department', 'email', 'title', 'location')`

Can be overridden with `$RequiredAttributes`.

**Flow:**
1. Query `GET /v3/public-identities` (paginated, `limit=250&offset=N`, up to
   `$Limit` total identities). If `-ActiveOnly`, filter by lifecycle state active.
2. For each identity, check each attribute in `$RequiredAttributes`:
   - Present and non-empty: Pass.
   - Null or empty string: Missing.
3. Additional quality checks per identity:
   - **ManagerSelfReference**: Manager ID equals identity ID (common data error).
   - **DuplicateEmail**: Same email address on multiple identities.
   - **StaleAttributes**: Identity has `modified` timestamp older than 365 days
     (may indicate the identity profile has not been refreshed).
4. Calculate per-attribute completeness:
   - Percentage of identities with that attribute populated.
5. Calculate per-identity quality score (0-100):
   - Each required attribute present = (100 / RequiredAttributeCount) points.
   - Deductions: ManagerSelfReference = -10, StaleAttributes = -5.
6. Calculate overall tenant quality score:
   - Average of all identity quality scores.

**Returns:**
```powershell
@{
    Identities = @(
        @{
            IdentityId      = 'id-001'
            IdentityName    = 'Alice Johnson'
            LifecycleState  = 'active'
            QualityScore    = 80.0
            MissingAttributes = @('location')
            Issues = @('Missing: location')
        }
    )
    AttributeCompleteness = @{
        manager    = @{ Present = 480; Missing = 20; Pct = 96.0 }
        department = @{ Present = 490; Missing = 10; Pct = 98.0 }
        email      = @{ Present = 500; Missing = 0;  Pct = 100.0 }
        title      = @{ Present = 450; Missing = 50; Pct = 90.0 }
        location   = @{ Present = 350; Missing = 150; Pct = 70.0 }
    }
    QualityIssues = @{
        ManagerSelfReference = @('id-042')
        DuplicateEmails      = @(
            @{ Email = 'shared@corp.com'; IdentityIds = @('id-010', 'id-011') }
        )
        StaleProfiles        = @('id-099', 'id-100')
    }
    Summary = @{
        TotalIdentitiesScanned = 500
        OverallQualityScore    = 87.3
        OverallQualityGrade    = 'B'
        WorstAttribute         = 'location'
        WorstAttributePct      = 70.0
        IdentitiesWithIssues   = 65
        QualityGradeDistribution = @{
            A = 300    # 90-100
            B = 120    # 80-89
            C = 50     # 70-79
            D = 20     # 60-69
            F = 10     # below 60
        }
    }
}
```

**Quality grade scale:**
- A (90-100): Excellent data quality
- B (80-89): Good, minor gaps
- C (70-79): Acceptable, notable gaps
- D (60-69): Poor, governance impact likely
- F (below 60): Critical, governance processes unreliable

New function `Export-SPIdentityDataQualityHtml`:
- Attribute completeness bar chart (horizontal bars per attribute, color by pct)
- Identity quality grade distribution pie/table
- Per-identity issue table (filterable by issue type)
- Quality issues callout section (self-referencing managers, duplicate emails)
- Summary card with overall grade and worst attribute
- Recommendations section with remediation steps per issue type

**Acceptance Criteria:**
- Identity with all required attributes scores 100
- Identity with 3/5 required attributes scores 60
- ManagerSelfReference detected when manager.id equals identity id
- DuplicateEmails groups identities sharing the same email
- StaleProfiles detected when identity modified > 365 days ago
- Without `$RequiredAttributes`, uses default 5-attribute list
- `-ActiveOnly` excludes inactive/terminated identities
- Empty identity list returns empty summary with 0 quality score (not error)
- HTML report uses same styling as existing audit reports

**Tests:** P16-T05, P16-T06

---

## P16-04: Campaign Coverage Gap Analysis

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Get-SPCampaignCoverageGaps` in SP.AuditAnalytics.psm1 and
`Export-SPCampaignCoverageGapHtml` in SP.AuditReportHtml.psm1 that identify
entitlements, access profiles, and identities that have NEVER been included
in any certification campaign.

Answers: "What parts of our access estate have never been reviewed? Are there
entitlements or identities completely outside our certification program?"

This is distinct from stale access detection (Get-SPStaleAccess), which finds
entitlements where the last review was too long ago. Coverage gap analysis finds
entitlements that have NEVER appeared in ANY campaign -- they exist in the
entitlement inventory but have zero review history. This represents a blind
spot in the governance program where access is granted but never evaluated.

Common causes: sources added to ISC after campaigns were designed, entitlements
created between campaign cycles and never scoped, roles or access profiles that
are not included in any campaign filter, or campaign scope rules that inadvertently
exclude certain account types.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditAnalytics.psm1` -- new `Get-SPCampaignCoverageGaps`
  function
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- new `Export-SPCampaignCoverageGapHtml`
  function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPCampaignCoverageGaps {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter(Mandatory)][hashtable]$EntitlementInventory,
        [Parameter()][hashtable]$AccessProfileInventory,
        [Parameter()][switch]$PrivilegedOnly,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$CampaignAudits`, build the set of all (SourceId, EntitlementName)
   pairs that have appeared in at least one certification decision. Also build
   the set of all IdentityIds that have been reviewed.
2. From `$EntitlementInventory.Data.Sources`, iterate all entitlements across
   all sources. For each entitlement, check whether it appears in the reviewed
   set.
3. Classify each entitlement:
   - **NeverReviewed**: Entitlement exists in inventory but has never appeared
     in any campaign decision.
   - **PartiallyReviewed**: Entitlement has been reviewed for some identities
     but not all identities who hold it (requires identity-entitlement mapping
     from campaign data).
   - **FullyCovered**: Entitlement has been reviewed for all known holders.
4. If `$AccessProfileInventory` provided, also check which access profiles
   contain only NeverReviewed entitlements (entire access profile is a gap).
5. If `-PrivilegedOnly`, filter results to privileged entitlements only.
6. Sort gaps by severity: privileged NeverReviewed > non-privileged NeverReviewed
   > PartiallyReviewed.

**Returns:**
```powershell
@{
    Gaps = @(
        @{
            SourceId         = 'src-ad-001'
            SourceName       = 'Corporate AD'
            EntitlementName  = 'AD-SG-LegacyFinance'
            Privileged       = $false
            CoverageStatus   = 'NeverReviewed'
            EstimatedHolders = 12
            Severity         = 'High'
            Recommendation   = 'Include in next Manager campaign for Corporate AD'
        }
    )
    UncoveredAccessProfiles = @(
        @{
            SourceName        = 'Corporate AD'
            AccessProfileName = 'Legacy Finance Bundle'
            EntitlementCount  = 3
            AllNeverReviewed  = $true
        }
    )
    Summary = @{
        TotalEntitlementsInInventory = 280
        FullyCovered                = 230
        PartiallyReviewed           = 20
        NeverReviewed               = 30
        CoveragePct                 = 82.1
        PrivilegedNeverReviewed     = 2
        PerSource = @{
            'Corporate AD' = @{
                Total = 150; Covered = 130; Gaps = 20; CoveragePct = 86.7
            }
            'Cloud Entra'  = @{
                Total = 130; Covered = 100; Gaps = 30; CoveragePct = 76.9
            }
        }
        UncoveredAccessProfileCount = 1
    }
}
```

New function `Export-SPCampaignCoverageGapHtml`:
- Per-source coverage bar (green = covered, red = NeverReviewed, yellow =
  PartiallyReviewed)
- Gap detail table grouped by source, sorted by severity
- Privileged NeverReviewed entitlements in red highlight box
- Uncovered access profiles section
- Summary card with overall coverage percentage
- Recommendation section with campaign scope suggestions

**Acceptance Criteria:**
- Entitlement in inventory but never in any campaign decision classified as NeverReviewed
- Entitlement reviewed in at least one campaign classified as FullyCovered or
  PartiallyReviewed depending on holder coverage
- Privileged NeverReviewed gets Severity = 'Critical'
- Non-privileged NeverReviewed gets Severity = 'High'
- `-PrivilegedOnly` filters to privileged entitlements only
- Without `$AccessProfileInventory`, UncoveredAccessProfiles section omitted
- Empty entitlement inventory returns 100% coverage (not error)
- Empty campaign audits returns 0% coverage with all entitlements as NeverReviewed
- HTML report uses same styling as existing audit reports

**Tests:** P16-T07, P16-T08

---

## P16-05: Access Certification Completion Predictor

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Get-SPCampaignCompletionForecast` in SP.AuditAnalytics.psm1 and
`Export-SPCampaignCompletionForecastHtml` in SP.AuditReportHtml.psm1 that predict
whether active campaigns will complete before their deadlines based on current
decision velocity.

Answers: "Will this campaign finish on time? At the current review rate, when
will it actually complete? Which reviewers are the bottleneck?"

The toolkit has campaign health monitoring (Get-SPCampaignHealth, which checks
completion percentage and deadline proximity) but does not predict future
completion. A campaign at 60% completion with 3 days remaining may or may not
finish on time -- it depends on the rate at which decisions are being made.
This function uses decision velocity (decisions per hour over recent windows)
to project the completion date and flag campaigns at risk of missing deadlines.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditAnalytics.psm1` -- new `Get-SPCampaignCompletionForecast`
  function
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- new
  `Export-SPCampaignCompletionForecastHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPCampaignCompletionForecast {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable[]]$CampaignHealthData,
        [Parameter()][int]$VelocityWindowHours = 48,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$CampaignAudits`, identify active campaigns (Status not COMPLETED or
   CANCELLED).
2. For each active campaign, extract decision history with timestamps.
3. Calculate decision velocity:
   - **OverallVelocity**: Total decisions / total elapsed hours since campaign start.
   - **RecentVelocity**: Decisions in the last `$VelocityWindowHours` /
     `$VelocityWindowHours`. This captures current pace, not historical average.
   - **PeakVelocity**: Highest decisions-per-hour in any rolling 24-hour window.
4. Project completion:
   - **RemainingItems**: Total items minus decided items.
   - **ProjectedHoursToComplete**: RemainingItems / RecentVelocity.
   - **ProjectedCompletionDate**: Now + ProjectedHoursToComplete (accounting for
     business hours only -- 8 hours/day, weekdays).
   - **DeadlineDate**: From `$CampaignHealthData` or campaign metadata.
   - **WillMeetDeadline**: ProjectedCompletionDate <= DeadlineDate.
   - **SlackHours**: DeadlineDate - ProjectedCompletionDate (positive = ahead,
     negative = behind).
5. Identify bottleneck reviewers: reviewers with the most remaining items and
   the lowest personal velocity.
6. Classify forecast confidence:
   - **High**: Campaign > 30% complete and velocity window has >= 20 decisions.
   - **Medium**: Campaign 10-30% complete or velocity window has 5-19 decisions.
   - **Low**: Campaign < 10% complete or velocity window has < 5 decisions.

**Returns:**
```powershell
@{
    Forecasts = @(
        @{
            CampaignId           = 'camp-001'
            CampaignName         = 'Q2 Access Review'
            TotalItems           = 200
            DecidedItems         = 140
            RemainingItems       = 60
            CompletionPct        = 70.0
            OverallVelocity      = 4.2      # decisions/hr
            RecentVelocity       = 6.1      # decisions/hr (last 48h)
            PeakVelocity         = 12.0     # decisions/hr (best 24h window)
            ProjectedHoursToComplete = 9.8
            ProjectedCompletionDate  = '2026-06-01T14:00:00Z'
            DeadlineDate         = '2026-06-03T23:59:00Z'
            WillMeetDeadline     = $true
            SlackHours           = 58.0
            Confidence           = 'High'
            BottleneckReviewers = @(
                @{
                    ReviewerName    = 'Dave Admin'
                    RemainingItems  = 25
                    PersonalVelocity = 1.2   # decisions/hr
                    ProjectedHours  = 20.8
                }
            )
        }
    )
    Summary = @{
        ActiveCampaigns   = 3
        OnTrack           = 2
        AtRisk            = 1
        WillMiss          = 0
        AvgCompletionPct  = 68.0
        CampaignsNeedingAttention = @('Monthly Cloud Audit')
    }
}
```

New function `Export-SPCampaignCompletionForecastHtml`:
- Per-campaign forecast card with progress bar and projected date
- Deadline countdown with color coding (green = on track, yellow = at risk,
  red = will miss)
- Velocity chart showing overall vs recent rate
- Bottleneck reviewer table per campaign
- Summary card with on-track/at-risk/will-miss distribution

**Acceptance Criteria:**
- Campaign with RecentVelocity 0 (no decisions in window) produces
  ProjectedCompletionDate = 'Unknown' and WillMeetDeadline = $false
- SlackHours negative means campaign is projected to miss deadline
- Business hours calculation skips weekends (Saturday, Sunday)
- Completed campaigns excluded from forecasts
- Without `$CampaignHealthData`, deadline extracted from campaign metadata
  if available; otherwise forecast produced without deadline comparison
- Empty campaign audits returns empty summary (not error)
- Bottleneck reviewers sorted by projected hours descending (worst first)
- HTML report uses same styling as existing audit reports

**Tests:** P16-T09, P16-T10

---

## P16-06: Governance Metrics Time Series Store

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Save-SPGovernanceMetrics`, `Get-SPGovernanceMetrics`, and
`Get-SPGovernanceMetricsTrend` in SP.AuditOperations.psm1 that persist
governance KPIs to a local JSONL time-series file for historical trend
analysis spanning weeks and months.

Answers: "How has our governance posture changed over the past 6 months?
Are we improving quarter over quarter? What does the long-term trend look like?"

The toolkit computes point-in-time governance analytics (identity risk, source
governance, campaign metrics, maturity score) but does not retain historical
values. Each run overwrites the previous. Compare-SPAuditPeriods (P13-06)
can compare two periods, but requires both periods' raw campaign data to be
available. After audit trail retention (P12-09) archives old data, historical
comparison becomes impossible.

This function captures a snapshot of key governance KPIs after each analytics
run and appends them to a JSONL time-series file. Future runs can then
query the time series to show trends without needing the underlying campaign
data.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditOperations.psm1` -- new `Save-SPGovernanceMetrics`,
  `Get-SPGovernanceMetrics`, `Get-SPGovernanceMetricsTrend` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions
- `Config/settings.json` -- add `Metrics` section

**Config section:**
```json
"Metrics": {
    "Path": ".\\Audit\\metrics",
    "RetentionDays": 365,
    "AutoCapture": true
}
```

**Function Signatures:**
```powershell
function Save-SPGovernanceMetrics {
    param(
        [Parameter()][hashtable]$IdentityRisk,
        [Parameter()][hashtable]$SourceGovernance,
        [Parameter()][hashtable]$CampaignMetrics,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][hashtable]$StaleAccess,
        [Parameter()][hashtable]$GovernanceMaturity,
        [Parameter()][hashtable]$OrchestratorHistory,
        [Parameter()][string]$Label,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPGovernanceMetrics {
    param(
        [Parameter()][int]$DaysBack = 90,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPGovernanceMetricsTrend {
    param(
        [Parameter()][int]$DaysBack = 180,
        [Parameter()][string[]]$MetricNames,
        [Parameter()][ValidateSet('Daily','Weekly','Monthly')]
        [string]$Granularity = 'Weekly',
        [Parameter()][string]$CorrelationID
    )
}
```

**Save-SPGovernanceMetrics flow:**
1. Extract KPIs from each provided analytics output:
   - From `$IdentityRisk`: HighRiskCount, AvgRiskScore.
   - From `$SourceGovernance`: OverallCoveragePct, AvgGovernanceScore,
     SourceGrades (per-source grade map).
   - From `$CampaignMetrics`: TotalCampaigns, AvgApprovalRate,
     AvgRevocationRate, AvgResponseHours.
   - From `$ReviewerReputation`: AvgReputationScore, AtRiskCount.
   - From `$StaleAccess`: TotalStaleItems, NeverReviewedCount,
     PrivilegedStaleCount.
   - From `$GovernanceMaturity`: OverallScore, OverallLevel.
   - From `$OrchestratorHistory`: SuccessRate, ConsecutiveSuccesses.
2. Build a metrics record:
   ```json
   {
       "timestamp": "2026-05-30T12:00:00Z",
       "label": "weekly-digest-2026-05-30",
       "metrics": {
           "identityRisk.highCount": 5,
           "identityRisk.avgScore": 28.5,
           "sourceGovernance.coveragePct": 82.3,
           "sourceGovernance.avgScore": 71.2,
           "campaigns.total": 12,
           "campaigns.avgApprovalRate": 83.0,
           "campaigns.avgResponseHours": 14.2,
           "reviewers.avgScore": 68.5,
           "reviewers.atRiskCount": 1,
           "staleAccess.totalItems": 22,
           "staleAccess.neverReviewed": 8,
           "maturity.overallScore": 68.5,
           "maturity.overallLevel": 4,
           "orchestrator.successRate": 92.9
       }
   }
   ```
3. Append to `{Metrics.Path}/governance-metrics.jsonl` using BOM-free UTF-8.
4. Apply retention: remove lines older than `$RetentionDays`.

**Get-SPGovernanceMetrics flow:**
1. Read `governance-metrics.jsonl`.
2. Filter to records within `$DaysBack`.
3. Return array of metric records sorted by timestamp ascending.

**Get-SPGovernanceMetricsTrend flow:**
1. Read metrics within `$DaysBack`.
2. If `$MetricNames` specified, filter to those metrics only. Default: all.
3. Group by `$Granularity` period (daily/weekly/monthly buckets).
4. For each bucket, compute: min, max, avg, latest value.
5. Calculate period-over-period change and direction for each metric.

**Returns (Save):**
```powershell
@{
    Success = $true
    Data = @{
        Timestamp  = '2026-05-30T12:00:00Z'
        MetricCount = 14
        FilePath   = 'Audit/metrics/governance-metrics.jsonl'
    }
}
```

**Returns (Trend):**
```powershell
@{
    Trends = @{
        'maturity.overallScore' = @{
            Periods = @(
                @{ Period = '2026-W18'; Avg = 62.0; Latest = 63.5 }
                @{ Period = '2026-W19'; Avg = 65.0; Latest = 66.0 }
                @{ Period = '2026-W20'; Avg = 68.5; Latest = 68.5 }
            )
            OverallDirection = 'Improving'
            TotalChange      = +6.5
            ChangePercent    = +10.5
        }
    }
    Summary = @{
        MetricsTracked = 14
        DataPointCount = 21
        OldestRecord   = '2026-01-15T06:00:00Z'
        NewestRecord   = '2026-05-30T12:00:00Z'
        ImprovingMetrics = 10
        DecliningMetrics = 2
        StableMetrics    = 2
    }
}
```

**Acceptance Criteria:**
- Save appends to existing JSONL file (does not overwrite)
- Null analytics inputs produce null metric values (not omitted keys)
- Retention removes records older than configured RetentionDays
- Get with DaysBack=0 returns only today's records
- Trend with Granularity=Monthly groups by calendar month
- Trend with Granularity=Weekly groups by ISO week number
- Direction classified: >2% change = Improving/Declining, else Stable
- Metrics directory created on first Save if it does not exist
- JSONL written BOM-free UTF-8 (same convention as Export-SPAuditJsonl)
- Empty metrics file returns empty trend (not error)

**Tests:** P16-T11, P16-T12

---

## P16-07: Reviewer Delegation Audit Trail

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Get-SPReviewerDelegations` in SP.AuditQueries.psm1 and
`Export-SPReviewerDelegationHtml` in SP.AuditReportHtml.psm1 that track and
analyze certification item reassignments within campaigns to detect delegation
patterns that may indicate governance avoidance.

Answers: "Which reviewers are reassigning their certification items instead of
reviewing them? Are there delegation chains where items bounce between multiple
reviewers? Are items being reassigned close to the deadline?"

ISC allows reviewers to reassign certification items to other reviewers. While
legitimate reassignment is a normal part of campaign operations (e.g., a
manager reassigns an item to a team lead with better knowledge), excessive or
pattern-based reassignment can indicate:
- Reviewer avoidance (delegating to avoid making access decisions)
- Rubber-stamp forwarding (reassigning to a known "approve all" reviewer)
- Deadline gaming (reassigning just before deadline to reset the clock)
- Circular reassignment (A->B->A, items never actually reviewed)

The toolkit tracks reviewer reputation and load but does not currently analyze
reassignment patterns.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPReviewerDelegations` function
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- new `Export-SPReviewerDelegationHtml`
  function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPReviewerDelegations {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][int]$DeadlineProximityHours = 24,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$CampaignAudits`, extract all certification items across all campaigns.
2. For each item, check the reviewer history (ISC tracks `reviewer` changes via
   the certification item's `reviewedBy` vs `certifiedBy` fields, and the
   campaign's `reassignment` events in audit logs).
3. Identify reassignment events: items where the final reviewer differs from
   the original assigned reviewer.
4. For each reassigned item, record: OriginalReviewer, FinalReviewer,
   ReassignmentChain (ordered list of all reviewers), ReassignmentCount,
   TimeSinceAssignment, TimeBeforeDeadline, FinalDecision.
5. Detect patterns:
   - **HighDelegator**: Reviewer who reassigned >30% of their assigned items.
   - **DeadlineDelegation**: Reassignment within `$DeadlineProximityHours` of
     campaign deadline.
   - **CircularDelegation**: Item assigned back to a previous reviewer in the chain.
   - **DelegateToApprover**: Reviewer consistently reassigns to someone who
     always approves (cross-reference with rubber-stamp risk data).
6. Calculate per-reviewer delegation metrics:
   - ItemsAssigned, ItemsReassigned, ReassignmentRate, AvgTimeBeforeDelegation.

**Returns:**
```powershell
@{
    Delegations = @(
        @{
            CampaignId          = 'camp-001'
            CampaignName        = 'Q2 Access Review'
            ItemId              = 'item-001'
            IdentityName        = 'Alice Johnson'
            EntitlementName     = 'AD-SG-Finance'
            OriginalReviewer    = 'Bob Manager'
            FinalReviewer       = 'Carol Admin'
            ReassignmentChain   = @('Bob Manager', 'Carol Admin')
            ReassignmentCount   = 1
            TimeBeforeDeadline  = 72.0
            FinalDecision       = 'Approved'
            Patterns            = @()
        }
    )
    ReviewerMetrics = @(
        @{
            ReviewerName        = 'Bob Manager'
            ItemsAssigned       = 40
            ItemsReassigned     = 15
            ReassignmentRate    = 37.5
            AvgHoursBeforeDelegation = 8.2
            Patterns            = @('HighDelegator')
        }
    )
    PatternSummary = @{
        HighDelegators       = 2
        DeadlineDelegations  = 3
        CircularDelegations  = 0
        DelegateToApprover   = 1
    }
    Summary = @{
        TotalItemsAnalyzed     = 500
        TotalReassigned        = 45
        OverallReassignmentRate = 9.0
        CampaignsWithDelegations = 3
        ReviewersWhoDelegate   = 8
    }
}
```

New function `Export-SPReviewerDelegationHtml`:
- Per-reviewer delegation metrics table with reassignment rate bar
- Pattern badges: HighDelegator (orange), DeadlineDelegation (red),
  CircularDelegation (red), DelegateToApprover (red)
- Delegation chain visualization (A -> B -> C) for multi-hop reassignments
- Deadline delegation timeline (items reassigned close to deadline)
- Summary card with overall reassignment rate and pattern counts
- Recommendations per pattern type

**Acceptance Criteria:**
- Reviewer with >30% reassignment rate flagged as HighDelegator
- Reassignment within DeadlineProximityHours flagged as DeadlineDelegation
- Item assigned A->B->A flagged as CircularDelegation
- Items with no reassignment excluded from Delegations array
- Empty campaign audits returns empty summary (not error)
- ReassignmentChain correctly orders all reviewers chronologically
- Without reassignment data in campaign audits, returns summary with
  "Reassignment data unavailable" note (not error)
- HTML report uses same styling as existing audit reports

**Tests:** P16-T13, P16-T14

---

## P16-08: Invoke-SPDataQualityReport.ps1

- **Status:** `PENDING`
- **Depends On:** P16-01, P16-03

**Description:**
New CLI script `Scripts/Invoke-SPDataQualityReport.ps1` that orchestrates a
comprehensive data quality assessment combining orphan account detection (P16-01),
identity attribute quality (P16-03), and source aggregation health (P16-02) into
a unified data quality report.

Answers: "How healthy is the data feeding our governance program? Where are the
data quality issues that could undermine certification accuracy?"

Data quality is the foundation that all governance processes rest on. If identity
data is incomplete, source aggregation is stale, or orphan accounts exist outside
the governance scope, then certification campaigns, risk scoring, and policy
compliance checks are operating on unreliable data. This script provides a
single command to assess data quality across all dimensions.

**File to Create:**
- `Scripts/Invoke-SPDataQualityReport.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string[]]$SourceId,

    # Section toggles
    [Parameter()][switch]$SkipOrphanAccounts,
    [Parameter()][switch]$SkipIdentityQuality,
    [Parameter()][switch]$SkipAggregationHealth,

    # Tuning
    [Parameter()][int]$IdentityLimit = 500,
    [Parameter()][int]$MaxStalenessHours = 48,

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

**Execution steps:**

```
Step 1: Configuration & Authentication
  -> Load config, validate with Test-SPConfiguration
  -> Acquire token

Step 2: Source Aggregation Health (unless -SkipAggregationHealth)
  -> Get-SPSourceAggregationHealth -SourceIds $SourceId
     -MaxAcceptableStalenessHours $MaxStalenessHours

Step 3: Orphan Account Detection (unless -SkipOrphanAccounts)
  -> Get-SPOrphanAccounts -SourceIds $SourceId
     -IncludeDisabledAccounts -IncludeServiceAccounts

Step 4: Identity Attribute Quality (unless -SkipIdentityQuality)
  -> Measure-SPIdentityDataQuality -Limit $IdentityLimit -ActiveOnly

Step 5: Composite Data Quality Score
  -> Calculate weighted score:
     - Aggregation health (30%): Healthy sources / total sources * 100
     - Orphan rate (30%): (1 - orphan accounts / total accounts) * 100
     - Identity quality (40%): OverallQualityScore from P16-03
  -> Grade: A (90+), B (80-89), C (70-79), D (60-69), F (<60)

Step 6: Report Generation
  -> Console: compact quality dashboard
  -> HTML: per-section reports + composite summary
  -> JSON: structured output

Step 7: Notification (if -SendNotification)
  -> Send summary if grade is D or F
```

**Console output:**
```
=== Data Quality Report ===
Timestamp:   2026-05-30T14:00:00Z
Sources:     src-ad-001, src-entra-001

--- Source Aggregation Health ---
  Healthy: 2 | Warning: 0 | Critical: 0
  Avg Data Freshness: 18.3 hours

--- Orphan Accounts ---
  Total Scanned: 1,200 | Orphans: 18 (1.5%)
  Uncorrelated: 10 | Terminated Owner: 5 | Dangling: 3

--- Identity Attribute Quality ---
  Score: 87.3 (Grade B) | Identities Scanned: 500
  Worst: location (70.0%) | Issues: 65 identities

--- Composite Data Quality ---
  Score: 84.2 (Grade B)
  Aggregation: 100.0 | Orphan Rate: 98.5 | Identity: 87.3

Result: DATA QUALITY GOOD (Grade B, 0 critical issues)
```

**Exit codes:**
- 0 = Grade A or B, no critical issues
- 1 = Grade C, warnings present
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Grade D or F, critical data quality issues

**Acceptance Criteria:**
- All 3 quality dimensions execute with proper error isolation
- Section failure does not prevent other sections or composite scoring
- Composite score uses weighted average of available sections
- Section skip switches exclude corresponding check and adjust weights
- `-WhatIf` shows what would be checked without API calls
- Console output fits in a standard 80-column terminal
- Works with both `-Token` and configured OAuth
- Exit code 5 when composite grade is D or F

**Tests:** P16-T15

---

## P16-09: Invoke-SPGovernanceMetrics.ps1

- **Status:** `PENDING`
- **Depends On:** P16-05, P16-06

**Description:**
New CLI script `Scripts/Invoke-SPGovernanceMetrics.ps1` that captures current
governance KPIs to the time-series store (P16-06), generates trend reports,
and optionally checks active campaign completion forecasts (P16-05).

Designed for scheduled execution (cron/Task Scheduler) after the daily
orchestrator and weekly digest. Captures the governance state at regular
intervals so that long-term trends are preserved even after raw audit data
is archived by retention policies.

**File to Create:**
- `Scripts/Invoke-SPGovernanceMetrics.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string[]]$SourceId,
    [Parameter()][int]$DaysBack = 90,

    # Modes
    [Parameter()][switch]$CaptureOnly,
    [Parameter()][switch]$TrendOnly,
    [Parameter()][switch]$IncludeCompletionForecast,

    # Trend options
    [Parameter()][int]$TrendDaysBack = 180,
    [Parameter()][ValidateSet('Daily','Weekly','Monthly')]
    [string]$TrendGranularity = 'Weekly',

    # Output
    [Parameter()][ValidateSet('Console','HTML','JSON','Both')]
    [string]$OutputMode = 'Console',
    [Parameter()][string]$OutputPath,

    # Alerting
    [Parameter()][switch]$AlertOnDecline,
    [Parameter()][string[]]$AlertRecipients,

    [Parameter()][switch]$Help,
    [Parameter()][switch]$WhatIf
)
```

**Execution steps:**

```
Step 1: Configuration & Authentication
  -> Load config, validate with Test-SPConfiguration
  -> Acquire token

Step 2: Current Analytics (unless -TrendOnly)
  -> Get-SPAuditCampaigns -DaysBack $DaysBack
  -> Measure-SPIdentityRisk, Measure-SPSourceGovernance,
     Measure-SPCampaignMetrics, Measure-SPReviewerReputation,
     Get-SPStaleAccess, Measure-SPGovernanceMaturity,
     Get-SPOrchestratorHistory
  -> Save-SPGovernanceMetrics with all results

Step 3: Campaign Completion Forecast (if -IncludeCompletionForecast)
  -> Get-SPCampaignCompletionForecast for active campaigns
  -> Flag campaigns at risk of missing deadline

Step 4: Trend Analysis (unless -CaptureOnly)
  -> Get-SPGovernanceMetricsTrend -DaysBack $TrendDaysBack
     -Granularity $TrendGranularity

Step 5: Decline Detection (if -AlertOnDecline)
  -> Check for metrics declining >5% over last 4 periods
  -> If found: Send-SPNotification with decline summary

Step 6: Output
  -> Console: KPI summary + trend arrows
  -> HTML: full metrics dashboard with trend charts
  -> JSON: structured metrics and trend data
```

**Console output:**
```
=== Governance Metrics Capture ===
Timestamp:   2026-05-30T06:00:00Z
Period:      90 days | Trend: 180 days (weekly)

--- Current KPIs ---
  Maturity Score:    68.5 (Level 4)   [+2.5 vs last week]
  Identity Risk:     5 High, 28.5 avg [stable]
  Source Coverage:   82.3%            [+1.2 vs last week]
  Campaign Approval: 83.0%           [stable]
  Reviewer Avg:      68.5            [-1.0 vs last week]
  Stale Access:      22 items        [-3 vs last week]
  Orchestrator:      92.9% success   [stable]

--- Campaign Completion Forecast ---
  Q2 Access Review: ON TRACK (58h slack, deadline Jun 3)
  Monthly Cloud:    AT RISK (reviewer Dave Admin bottleneck)

--- Trend Summary (26 weeks) ---
  Improving: maturity.overallScore (+10.5), sourceGovernance.coveragePct (+8.2)
  Declining: reviewers.avgScore (-3.1)
  Stable:    11 of 14 metrics

Metrics saved to Audit/metrics/governance-metrics.jsonl
```

**Exit codes:**
- 0 = Metrics captured, no declining trends
- 1 = Metrics captured, declining metrics detected
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Critical failure (cannot compute or save metrics)

**Acceptance Criteria:**
- `-CaptureOnly` saves metrics without generating trend report
- `-TrendOnly` generates trend report without computing new analytics
- `-IncludeCompletionForecast` adds campaign forecasts to output
- `-AlertOnDecline` triggers notification only for >5% decline over 4 periods
- Metric save is atomic (write to .tmp, then rename)
- Works with both `-Token` and configured OAuth
- Console output includes directional indicators vs previous period
- `-WhatIf` shows what would be captured without API calls

**Tests:** P16-T16

---

## P16-10: Pester Tests

- **Status:** `PENDING`
- **Depends On:** P16-09

**Description:**
Pester tests for all new functions added in P16-01 through P16-09.

**File to Create:**
- `Tests/SP.DataQualityMetrics.Tests.ps1`

**Test IDs:**

- P16-T01: Get-SPOrphanAccounts classifies null identityId as Uncorrelated
- P16-T02: Get-SPOrphanAccounts classifies terminated identity account as TerminatedOwner
- P16-T03: Get-SPSourceAggregationHealth classifies 2+ consecutive failures as Critical
- P16-T04: Get-SPSourceAggregationHealth classifies recent successful aggregation as Healthy
- P16-T05: Measure-SPIdentityDataQuality scores identity with all attributes as 100
- P16-T06: Measure-SPIdentityDataQuality detects ManagerSelfReference
- P16-T07: Get-SPCampaignCoverageGaps classifies entitlement never in any campaign as NeverReviewed
- P16-T08: Get-SPCampaignCoverageGaps returns 0% coverage with empty campaign audits
- P16-T09: Get-SPCampaignCompletionForecast predicts deadline miss with zero velocity
- P16-T10: Get-SPCampaignCompletionForecast calculates business hours skipping weekends
- P16-T11: Save-SPGovernanceMetrics appends to existing JSONL file
- P16-T12: Get-SPGovernanceMetricsTrend groups by weekly granularity correctly
- P16-T13: Get-SPReviewerDelegations flags >30% reassignment as HighDelegator
- P16-T14: Get-SPReviewerDelegations detects circular delegation (A->B->A)
- P16-T15: Invoke-SPDataQualityReport.ps1 syntax validation (PS AST parser)
- P16-T16: Invoke-SPGovernanceMetrics.ps1 syntax validation (PS AST parser)

**Mock patterns:**
- Mock `Invoke-SPApiRequest` for API calls (accounts, identities, sources,
  aggregations, certification items)
- Mock `Get-SPConfig` for config-dependent tests
- Mock `Measure-SPIdentityRisk`, `Measure-SPSourceGovernance`,
  `Measure-SPGovernanceMaturity`, `Measure-SPReviewerReputation`,
  `Get-SPStaleAccess`, `Get-SPOrchestratorHistory`,
  `Measure-SPCampaignMetrics` for metrics time series tests
- Use `TestDrive:\` for JSONL metrics file I/O tests
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
| API pagination | SP.AuditQueries.psm1 `Get-SPAuditCampaigns` | P16-01, P16-02, P16-03 |
| HTML report generation | SP.AuditReportHtml.psm1 `Build-SingleCampaignHtml` | P16-01, P16-02, P16-03, P16-04, P16-05, P16-07 |
| HTML table helpers | SP.AuditReportHtml.psm1 `Build-HtmlTableRow` / `Build-HtmlTableHeader` | P16-01, P16-02, P16-03, P16-04, P16-05, P16-07 |
| Identity risk aggregation | SP.AuditAnalytics.psm1 `Measure-SPIdentityRisk` | P16-06, P16-09 |
| Source governance scoring | SP.AuditAnalytics.psm1 `Measure-SPSourceGovernance` | P16-06, P16-09 |
| Stale access detection | SP.AuditQueries.psm1 `Get-SPStaleAccess` | P16-04, P16-06 |
| Campaign health monitoring | SP.Campaigns.psm1 `Get-SPCampaignHealth` | P16-05, P16-09 |
| JSONL write (BOM-free) | SP.AuditReportHtml.psm1 `Export-SPAuditJsonl` | P16-06 |
| CLI script structure | Invoke-SPDailyOrchestrator.ps1 (param block, module loading, error handling) | P16-08, P16-09 |
| Config defaults | SP.Config.psm1 `Get-SPConfigDefaults` | P16-06 |
| Notification dispatch | SP.AuditOperations.psm1 `Send-SPNotification` | P16-08, P16-09 |
| Compliance packaging | SP.AuditOperations.psm1 `Export-SPCompliancePackage` | P16-08 |
| Entitlement inventory | SP.AuditQueries.psm1 `Get-SPEntitlementInventory` | P16-01, P16-04 |
| Campaign metrics | SP.AuditReportCore.psm1 `Measure-SPCampaignMetrics` | P16-05, P16-06, P16-09 |
| Pester mock patterns | Tests/SP.ProductionReadiness.Tests.ps1, Tests/SP.OperationalIntelligence.Tests.ps1 | P16-10 |
| Orchestrator history | SP.AuditOperations.psm1 `Get-SPOrchestratorHistory` | P16-06, P16-09 |

---

## ISC API Endpoints (New in Phase 16)

| Endpoint | Method | Used By | Purpose |
|----------|--------|---------|---------|
| `/v3/accounts` | GET | P16-01 | List accounts per source (orphan detection) |
| `/v3/public-identities/{id}` | GET | P16-01 | Check identity lifecycle state for terminated owner detection |
| `/v3/account-aggregations` | GET | P16-02 | List recent aggregation events per source |
| `/v3/public-identities` | GET | P16-03 | List identities with attributes for quality scoring |

All other features consume existing function output or operate on local files
(metrics time series, trend analysis, coverage gap analysis).

**New PAT Scopes Required:**
- `idn:accounts:read` -- for orphan account detection and aggregation health

---

## Operational Reference (Post-Phase 16)

```powershell
# Orphan account detection
$orphans = Get-SPOrphanAccounts -SourceIds @('src-ad-001', 'src-entra-001') `
    -IncludeServiceAccounts
Export-SPOrphanAccountHtml -OrphanData $orphans -OutputPath '.\Audit'

# Source aggregation health
$aggHealth = Get-SPSourceAggregationHealth -SourceIds @('src-ad-001') `
    -MaxAcceptableStalenessHours 48
Export-SPSourceAggregationHealthHtml -HealthData $aggHealth -OutputPath '.\Audit'

# Identity data quality
$quality = Measure-SPIdentityDataQuality -Limit 500 -ActiveOnly
Export-SPIdentityDataQualityHtml -QualityData $quality -OutputPath '.\Audit'

# Campaign coverage gap analysis
$audits = Get-SPAuditCampaigns -DaysBack 365 | ForEach-Object {
    Get-SPAuditCampaignReport -CampaignId $_.id
}
$inventory = Get-SPEntitlementInventory -SourceIds @('src-ad-001') `
    -IncludeReviewHistory
$gaps = Get-SPCampaignCoverageGaps -CampaignAudits $audits `
    -EntitlementInventory $inventory
Export-SPCampaignCoverageGapHtml -GapData $gaps -OutputPath '.\Audit'

# Campaign completion prediction
$forecast = Get-SPCampaignCompletionForecast -CampaignAudits $audits `
    -VelocityWindowHours 48
Export-SPCampaignCompletionForecastHtml -ForecastData $forecast `
    -OutputPath '.\Audit'

# Governance metrics capture (daily cron)
$risk = Measure-SPIdentityRisk -CampaignAudits $audits
$governance = Measure-SPSourceGovernance -CampaignAudits $audits
$maturity = Measure-SPGovernanceMaturity -SourceGovernance $governance `
    -IdentityRisk $risk
Save-SPGovernanceMetrics -IdentityRisk $risk -SourceGovernance $governance `
    -GovernanceMaturity $maturity -Label 'daily-2026-05-30'

# Governance metrics trend (weekly review)
$trend = Get-SPGovernanceMetricsTrend -DaysBack 180 -Granularity Weekly

# Reviewer delegation audit
$delegations = Get-SPReviewerDelegations -CampaignAudits $audits `
    -DeadlineProximityHours 24
Export-SPReviewerDelegationHtml -DelegationData $delegations `
    -OutputPath '.\Audit'

# Comprehensive data quality report (scheduled)
.\Invoke-SPDataQualityReport.ps1 -SourceId 'src-ad-001','src-entra-001' `
    -OutputMode Both -OutputPath '.\Audit' -Token $token

# Governance metrics capture and trend (daily cron, after orchestrator)
.\Invoke-SPGovernanceMetrics.ps1 -SourceId 'src-ad-001' -DaysBack 90 `
    -IncludeCompletionForecast -TrendGranularity Weekly `
    -AlertOnDecline -AlertRecipients 'admin@corp.com' -Token $token

# Quick trend check (no new capture)
.\Invoke-SPGovernanceMetrics.ps1 -TrendOnly -TrendDaysBack 180 `
    -TrendGranularity Monthly -OutputMode Console
```
