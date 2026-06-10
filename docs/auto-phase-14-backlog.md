# Phase 14: Governance Maturity & Compliance Automation -- Backlog

**Created:** 2026-05-23
**Prereqs:** All Phases 1-13 complete
**Constraint:** NO GUI file changes (Windows GUI testing in progress on W-01 to W-07)

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `P14-01 -> P14-02 -> P14-03 -> P14-04 -> P14-05 -> P14-06 -> P14-07 -> P14-08 -> P14-09 -> P14-10`

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
| P14-01 | Governance Maturity Scorecard | none | DONE |
| P14-02 | Remediation Priority Queue | none | DONE |
| P14-03 | Audit Evidence Integrity Chain | none | PENDING |
| P14-04 | Source Onboarding Readiness | none | PENDING |
| P14-05 | Reviewer Load Balancer | none | PENDING |
| P14-06 | Configuration Snapshot | none | DONE |
| P14-07 | Configuration Drift Report | P14-06 | PENDING |
| P14-08 | Campaign Template Library | none | PENDING |
| P14-09 | Invoke-SPGovernanceHealthCheck.ps1 | P14-01 | PENDING |
| P14-10 | Pester Tests | P14-09 | PENDING |

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Get-SPConfig` | SP.Config | P14-01, P14-06, P14-08, P14-09 |
| `Invoke-SPApiRequest` | SP.ApiClient | P14-04, P14-06 |
| `Measure-SPIdentityRisk` | SP.AuditReport | P14-01, P14-02, P14-09 |
| `Measure-SPSourceGovernance` | SP.AuditReport | P14-01, P14-02, P14-04, P14-09 |
| `Get-SPStaleAccess` | SP.AuditQueries | P14-01, P14-02, P14-09 |
| `Measure-SPReviewerReputation` | SP.AuditReport | P14-01, P14-05, P14-09 |
| `Measure-SPCampaignMetrics` | SP.AuditReport | P14-01, P14-05, P14-09 |
| `Measure-SPCampaignTrends` | SP.AuditReport | P14-01 |
| `Get-SPRemediationStatus` | SP.AuditQueries | P14-01, P14-02 |
| `Get-SPCampaignHealth` | SP.Campaigns | P14-09 |
| `Get-SPOrchestratorHistory` | SP.AuditReport | P14-01, P14-09 |
| `Test-SPGovernancePolicy` | SP.AuditReport | P14-01, P14-02, P14-09 |
| `Get-SPEntitlementInventory` | SP.AuditQueries | P14-04, P14-06 |
| `Get-SPAccessProfileInventory` | SP.AuditQueries | P14-04, P14-06 |
| `Get-SPRoleInventory` | SP.AuditQueries | P14-06 |
| `Get-SPAuditTrail` | SP.AuditReport | P14-03 |
| `Export-SPAuditJsonl` | SP.AuditReport | P14-03 |
| `Get-SPAuditCampaigns` | SP.AuditQueries | P14-05, P14-09 |
| `Measure-SPAuditReviewerMetrics` | SP.AuditReport | P14-05 |
| `Send-SPNotification` | SP.AuditReport | P14-09 |
| `Export-SPCompliancePackage` | SP.AuditReport | P14-09 |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReport | P14-01, P14-02, P14-04, P14-07 |
| `ConvertTo-SafeHtml` | SP.AuditReport | P14-01, P14-02, P14-04, P14-07 |
| `Write-SPLog` | SP.Logging | All |

---

## P14-01: Governance Maturity Scorecard

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Measure-SPGovernanceMaturity` in SP.AuditReport.psm1 that produces a
composite governance maturity assessment by scoring the organization across six
dimensions. Also new function `Export-SPGovernanceMaturityHtml` for HTML output.

Answers: "How mature is our governance program? Where should we invest to improve?"

The toolkit now produces per-dimension analytics (identity risk, source governance,
reviewer reputation, campaign metrics, stale access, policy compliance, remediation
status, orchestrator reliability), but there is no single view that synthesizes these
into an overall maturity assessment. A CISO or governance director needs a one-page
answer: "Are we at Level 3 or Level 4, and what is holding us back?"

This function consumes pre-computed analytics outputs and scores each dimension from
0 to 100, then maps to a five-level maturity model aligned with industry frameworks
(CMMI, common compliance frameworks).

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Measure-SPGovernanceMaturity` and
  `Export-SPGovernanceMaturityHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Measure-SPGovernanceMaturity {
    param(
        [Parameter()][hashtable]$SourceGovernance,
        [Parameter()][hashtable]$IdentityRisk,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][hashtable]$CampaignMetrics,
        [Parameter()][hashtable]$StaleAccess,
        [Parameter()][hashtable]$PolicyCompliance,
        [Parameter()][hashtable]$RemediationStatus,
        [Parameter()][hashtable]$OrchestratorHistory,
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][string]$CorrelationID
    )
}
```

**Maturity Dimensions (6):**

1. **Coverage** (weight 20%): How thoroughly is access governed?
   - Inputs: `$SourceGovernance.Summary.OverallCoveragePct`, `$EntitlementInventory`
   - Scoring: 100% coverage = 100, 0% = 0. Privileged coverage weighted 2x.
   - Penalties: Any source with Grade F = -15 per source.

2. **Timeliness** (weight 20%): How promptly are reviews completed?
   - Inputs: `$CampaignMetrics`, `$ReviewerReputation`
   - Scoring: Avg response hours < 12 = 100, > 72 = 0 (linear scale).
   - Bonus: 100% on-time campaign completion = +10.
   - Penalties: Any campaign overdue = -10 per campaign.

3. **Enforcement** (weight 20%): Are revocations actually carried out?
   - Inputs: `$RemediationStatus`, `$StaleAccess`
   - Scoring: SLA compliance rate maps directly (87% compliance = 87 score).
   - Penalties: Overdue remediations = -5 per item (max -20).
   - Bonus: Stale access < 5% of total = +10.

4. **Accountability** (weight 15%): Are reviewers performing their duties?
   - Inputs: `$ReviewerReputation`
   - Scoring: Avg reputation score maps directly.
   - Penalties: Any At Risk reviewer = -10 per reviewer (max -20).
   - Bonus: All reviewers Good or Excellent = +10.

5. **Documentation** (weight 10%): Is the audit trail complete?
   - Inputs: `$PolicyCompliance`, presence of audit trail files
   - Scoring: All policies evaluated (not skipped) = 80 baseline.
   - Bonus: Compliance evidence packages generated = +10.
   - Bonus: Policy compliance rate > 80% = +10.

6. **Automation** (weight 15%): Is the governance workflow automated?
   - Inputs: `$OrchestratorHistory`
   - Scoring: Orchestrator success rate maps directly (93% = 93).
   - Penalties: Consecutive failures > 2 = -15.
   - Bonus: Daily runs for 30+ days = +10.

**Maturity Levels:**
- Level 1 -- Initial (0-20): Ad-hoc governance, no consistent processes
- Level 2 -- Developing (21-40): Some processes defined, significant gaps
- Level 3 -- Defined (41-60): Processes documented, partially implemented
- Level 4 -- Managed (61-80): Measured and controlled governance
- Level 5 -- Optimizing (81-100): Continuous improvement, near-full coverage

**Returns:**
```powershell
@{
    OverallScore     = 68.5
    OverallLevel     = 4
    OverallLevelName = 'Managed'
    EvaluatedAt      = '2026-05-23T12:00:00Z'
    Dimensions = @{
        Coverage = @{
            Score       = 78.5
            Level       = 4
            Weight      = 0.20
            KeyFactors  = @('Overall coverage 78.5%', '1 source at Grade F')
            Improvement = 'Bring Legacy App source to Grade C or above'
        }
        Timeliness = @{
            Score       = 72.0
            Level       = 4
            Weight      = 0.20
            KeyFactors  = @('Avg response 14.2 hours', '100% on-time completion')
            Improvement = 'Reduce avg response time below 12 hours'
        }
        Enforcement = @{
            Score       = 87.0
            Level       = 5
            Weight      = 0.20
            KeyFactors  = @('SLA compliance 87%', '2 overdue remediations')
            Improvement = 'Clear 2 overdue remediations'
        }
        Accountability = @{
            Score       = 55.0
            Level       = 3
            Weight      = 0.15
            KeyFactors  = @('Avg reputation 65', '1 At Risk reviewer')
            Improvement = 'Address Dave Admin performance (At Risk tier)'
        }
        Documentation = @{
            Score       = 70.0
            Level       = 4
            Weight      = 0.10
            KeyFactors  = @('5/5 policies evaluated', '60% policy compliance')
            Improvement = 'Improve policy compliance above 80%'
        }
        Automation = @{
            Score       = 93.0
            Level       = 5
            Weight      = 0.15
            KeyFactors  = @('Orchestrator success 92.9%', '28 consecutive daily runs')
            Improvement = 'Investigate 2 failed runs for root cause'
        }
    }
    TopImprovements = @(
        'Address 1 At Risk reviewer (Accountability: +15 potential)',
        'Bring Legacy App source above Grade F (Coverage: +10 potential)',
        'Clear 2 overdue remediations (Enforcement: +5 potential)'
    )
}
```

New function `Export-SPGovernanceMaturityHtml`:
- Radar/spider chart visualization of 6 dimensions (HTML table-based)
- Overall maturity level badge with level name
- Per-dimension detail cards with score, level, key factors, and improvement action
- Top 3 improvement recommendations section
- Summary card with weighted overall score

**Acceptance Criteria:**
- All 6 dimensions produce a 0-100 score clamped to range
- Dimensions with null input data score 0 with note "Insufficient data"
- OverallScore is weighted average of dimension scores
- OverallLevel derived from OverallScore (not average of dimension levels)
- TopImprovements sorted by potential score impact (highest first)
- All null inputs returns Level 1 with all dimensions at 0 (not error)
- HTML report renders maturity level badge with color coding

**Tests:** P14-T01, P14-T02

---

## P14-02: Remediation Priority Queue

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Get-SPRemediationPriority` in SP.AuditReport.psm1 that synthesizes
identity risk, stale access, policy violations, and remediation status into a ranked
list of specific, actionable remediation items. Also new function
`Export-SPRemediationPriorityHtml` for HTML output and CSV export.

Answers: "What should we fix first? What is the single most impactful remediation
action we can take right now?"

Currently each analytics function identifies problems independently: identity risk
finds high-risk identities, stale access finds ungoverned entitlements, policy engine
finds violations, remediation status finds overdue revocations. But an operator
looking at these 4 reports has no guidance on priority. This function cross-references
all findings and produces a single ranked queue of concrete actions.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPRemediationPriority` and
  `Export-SPRemediationPriorityHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPRemediationPriority {
    param(
        [Parameter()][hashtable]$IdentityRisk,
        [Parameter()][hashtable]$StaleAccess,
        [Parameter()][hashtable]$PolicyCompliance,
        [Parameter()][hashtable]$RemediationStatus,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][int]$MaxItems = 50,
        [Parameter()][string]$CorrelationID
    )
}
```

**Action types and priority scoring:**

1. **RevokeAccess** (from IdentityRisk + StaleAccess):
   - Specific entitlement on a specific identity needs removal
   - Priority = IdentityRiskScore + (IsPrivileged ? 20 : 0) + (IsStale ? 15 : 0)
   - Source: High-risk identity with stale privileged access = highest priority

2. **CompletePendingRemediation** (from RemediationStatus):
   - A revocation decision was made but not yet provisioned
   - Priority = 80 + (IsOverdue ? 20 : 0) + (DaysOverdue * 2, max 20)
   - Source: Overdue remediations with no provisioning event

3. **ReviewStaleEntitlement** (from StaleAccess):
   - Entitlement exists but has never been reviewed or review has expired
   - Priority = 50 + (IsPrivileged ? 25 : 0) + (IsNeverReviewed ? 15 : 0)
   - Source: NeverReviewed privileged entitlements

4. **AddressReviewerPerformance** (from ReviewerReputation):
   - A reviewer is At Risk tier and needs coaching or reassignment
   - Priority = 60 + (ReputationScore < 20 ? 20 : 0)
   - Source: At Risk reviewers with active campaign assignments

5. **RemediatePolicyViolation** (from PolicyCompliance):
   - A specific policy is in FAIL state
   - Priority = (IsCritical ? 90 : 60) + ViolationCount
   - Source: Critical policy failures

**Per-item output:**
```powershell
@{
    Rank           = 1
    ActionType     = 'RevokeAccess'
    Priority       = 95
    Severity       = 'Critical'      # Critical (>=80) / High (>=60) / Medium (>=40) / Low (<40)
    Summary        = 'Revoke AD-SG-DomainAdmins from Alice Johnson'
    IdentityName   = 'Alice Johnson'
    IdentityId     = 'id-001'
    SourceName     = 'Corporate AD'
    EntitlementName = 'AD-SG-DomainAdmins'
    Rationale      = @(
        'Identity risk score 85 (High tier)',
        'Privileged entitlement',
        'Not reviewed in 145 days (stale)'
    )
    EstimatedEffort = 'Low'          # Low (single revoke) / Medium (needs investigation) / High (multi-step)
}
```

**Returns:**
```powershell
@{
    Items = @( ... )    # sorted by Priority descending
    Summary = @{
        TotalItems           = 35
        CriticalItems        = 5
        HighItems            = 12
        MediumItems          = 15
        LowItems             = 3
        ActionTypeBreakdown  = @{
            RevokeAccess               = 15
            CompletePendingRemediation  = 5
            ReviewStaleEntitlement      = 8
            AddressReviewerPerformance  = 2
            RemediatePolicyViolation    = 5
        }
    }
}
```

New function `Export-SPRemediationPriorityHtml`:
- Ranked table with severity badges (Critical red, High orange, Medium yellow, Low green)
- Per-item expandable rationale section
- Action type filter tabs
- Summary card with severity distribution
- "Export to CSV" note with column mapping for ServiceNow/Jira import

Also produces `remediation-priority-{date}.csv` alongside the HTML with columns:
Rank, ActionType, Priority, Severity, Summary, IdentityName, SourceName,
EntitlementName, EstimatedEffort

**Acceptance Criteria:**
- Items sorted by Priority descending (highest priority first)
- Privileged stale access on a high-risk identity ranks above non-privileged
- Overdue remediation ranks above pending remediation
- Critical policy violation ranks above warning policy violation
- `$MaxItems` truncates the output (default 50)
- All null inputs returns empty queue (not error)
- CSV output uses semicolons for multi-value Rationale field
- No duplicate items (same identity + entitlement pair deduplicated, highest priority kept)

**Tests:** P14-T03, P14-T04

---

## P14-03: Audit Evidence Integrity Chain

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Protect-SPAuditTrail` in SP.AuditReport.psm1 that appends a SHA-256
hash chain to existing JSONL audit trail files for tamper detection. Also new function
`Test-SPAuditTrailIntegrity` that verifies the chain.

For common compliance and audit programs, organizations must demonstrate that audit
evidence has not been altered after the fact. Currently JSONL files are plain text
with no integrity mechanism. An operator (or attacker) could edit a line to change
a decision from REVOKE to APPROVE without detection.

This function adds a `_hash` field to each JSONL line containing the SHA-256 hash
of the previous line's content, creating a hash chain similar to a blockchain. Any
modification to a historical line breaks the chain from that point forward.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Protect-SPAuditTrail` and
  `Test-SPAuditTrailIntegrity` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Protect-SPAuditTrail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][switch]$Force,
        [Parameter()][string]$CorrelationID
    )
}

function Test-SPAuditTrailIntegrity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][switch]$Detailed,
        [Parameter()][string]$CorrelationID
    )
}
```

**Protect-SPAuditTrail flow:**
1. Read the JSONL file line by line.
2. If any line already contains a `_hash` field and `-Force` is not set, return
   warning "File already has integrity chain. Use -Force to rebuild."
3. For line 1: compute `SHA256(line_content)` and add `"_hash": "GENESIS"`,
   `"_contentHash": "<sha256_of_line>"` to the JSON object.
4. For line N (N>1): compute `SHA256(previous_line_with_hash)` and add
   `"_hash": "<sha256_of_previous_line>"`, `"_contentHash": "<sha256_of_this_line>"`.
5. Write the modified lines to a temporary file, then replace the original atomically.
6. Write a `.integrity` sidecar file with: file path, line count, final hash,
   generation timestamp, toolkit version.

**Test-SPAuditTrailIntegrity flow:**
1. Read the JSONL file line by line.
2. For each line, parse the `_hash` and `_contentHash` fields.
3. If line 1: verify `_hash` equals `"GENESIS"`.
4. For line N: compute `SHA256(previous_line)` and verify it matches `_hash` on line N.
5. Verify `_contentHash` on each line matches the hash of the line content (excluding
   `_hash` and `_contentHash` fields).
6. Return integrity result.

**Returns (Protect-SPAuditTrail):**
```powershell
@{
    Success = $true
    Data = @{
        Path       = 'Audit/audit-2026-05-23.jsonl'
        LineCount  = 150
        FinalHash  = 'a1b2c3d4...'
        SidecarPath = 'Audit/audit-2026-05-23.jsonl.integrity'
    }
}
```

**Returns (Test-SPAuditTrailIntegrity):**
```powershell
@{
    Valid         = $true
    Path          = 'Audit/audit-2026-05-23.jsonl'
    LineCount     = 150
    FirstEvent    = '2026-05-23T06:00:00Z'
    LastEvent     = '2026-05-23T18:30:00Z'
    ChainStatus   = 'Intact'       # Intact / Broken / Missing
    BrokenAtLine  = $null           # line number where chain breaks (if broken)
    Details       = @()             # per-line detail (only with -Detailed)
}
```

When `-Detailed`, `Details` includes per-line: `LineNumber`, `Valid`, `ExpectedHash`,
`ActualHash`.

**Acceptance Criteria:**
- Protect then Test on same file returns Valid = true
- Modifying one character in a protected file causes Test to return Valid = false
- BrokenAtLine correctly identifies the first tampered line
- File without `_hash` fields returns ChainStatus = 'Missing'
- Empty JSONL file returns Valid = true with LineCount = 0
- `.integrity` sidecar file written with correct metadata
- Uses `[System.Security.Cryptography.SHA256]::Create()` (no external deps)
- Atomic file replacement (write to .tmp, then move) prevents corruption

**Tests:** P14-T05, P14-T06

---

## P14-04: Source Onboarding Readiness

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Test-SPSourceReadiness` in SP.AuditQueries.psm1 that evaluates whether
a source is properly configured for governance. Also new function
`Export-SPSourceReadinessHtml` in SP.AuditReport.psm1 for HTML output.

Answers: "Is this source ready to be included in certification campaigns? What is
missing?"

When onboarding a new source into ISC governance (e.g., adding a cloud application),
teams need a pre-flight checklist: does the source have an owner, are entitlements
cataloged, are access profiles defined, is it included in any campaign? Currently
this requires manually checking multiple ISC screens. This function automates the
checklist and produces a readiness grade.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Test-SPSourceReadiness` function
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPSourceReadinessHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Test-SPSourceReadiness {
    param(
        [Parameter(Mandatory)][string[]]$SourceIds,
        [Parameter()][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][hashtable]$AccessProfileInventory,
        [Parameter()][string]$CorrelationID
    )
}
```

**Readiness checks per source (10 criteria):**

1. **SourceExists**: Source ID resolves via `GET /v3/sources/{id}` (Pass/Fail)
2. **OwnerAssigned**: Source has a non-null owner (Pass/Fail)
3. **OwnerActive**: Source owner identity is in active lifecycle state (Pass/Warn)
4. **EntitlementsCataloged**: Source has > 0 entitlements in inventory (Pass/Fail)
5. **PrivilegedMarked**: If entitlements exist, at least one is marked privileged OR
   explicit confirmation that none are privileged (Pass/Warn)
6. **AccessProfilesDefined**: Source has > 0 access profiles (Pass/Warn)
7. **IncludedInCampaign**: Source has appeared in at least one campaign (Pass/Warn)
8. **RecentReview**: Source was included in a campaign within the last 365 days (Pass/Warn)
9. **EntitlementCoverage**: If in campaigns, > 50% of entitlements have been reviewed (Pass/Warn)
10. **DescriptionPopulated**: Source has a non-empty description in ISC (Pass/Info)

**Readiness grades:**
- **Ready**: All Pass, zero Fail, zero Warn
- **Ready with Warnings**: All Pass, zero Fail, 1+ Warn
- **Not Ready**: 1+ Fail
- **Unknown**: Source does not exist

**Returns:**
```powershell
@{
    Sources = @(
        @{
            SourceId          = 'src-ad-001'
            SourceName        = 'Corporate AD'
            SourceType        = 'Active Directory - Direct'
            ReadinessGrade    = 'Ready with Warnings'
            PassCount         = 8
            WarnCount         = 2
            FailCount         = 0
            Checks = @(
                @{ Name = 'SourceExists';         Result = 'Pass'; Detail = 'Source resolved' }
                @{ Name = 'OwnerAssigned';        Result = 'Pass'; Detail = 'Owner: Jane Admin' }
                @{ Name = 'OwnerActive';          Result = 'Pass'; Detail = 'Lifecycle: active' }
                @{ Name = 'EntitlementsCataloged'; Result = 'Pass'; Detail = '150 entitlements' }
                @{ Name = 'PrivilegedMarked';     Result = 'Pass'; Detail = '12 privileged' }
                @{ Name = 'AccessProfilesDefined'; Result = 'Warn'; Detail = '0 access profiles' }
                @{ Name = 'IncludedInCampaign';   Result = 'Pass'; Detail = '4 campaigns' }
                @{ Name = 'RecentReview';         Result = 'Pass'; Detail = 'Last: 2026-05-01' }
                @{ Name = 'EntitlementCoverage';  Result = 'Pass'; Detail = '86.7% coverage' }
                @{ Name = 'DescriptionPopulated'; Result = 'Warn'; Detail = 'No description' }
            )
            Recommendations = @(
                'Define access profiles to bundle entitlements for role-based access',
                'Add a source description for documentation completeness'
            )
        }
    )
    Summary = @{
        TotalSources = 3
        Ready        = 1
        ReadyWithWarnings = 1
        NotReady     = 1
        Unknown      = 0
    }
}
```

New function `Export-SPSourceReadinessHtml`:
- Per-source checklist card with Pass/Warn/Fail badges
- Readiness grade badge (green/yellow/red)
- Recommendations section per source
- Summary card with grade distribution

**Acceptance Criteria:**
- Source with all checks passing gets grade 'Ready'
- Source not found in ISC gets grade 'Unknown' with SourceExists = 'Fail'
- Source with 0 entitlements gets EntitlementsCataloged = 'Fail' and grade 'Not Ready'
- Without `$EntitlementInventory`, entitlement checks use API count only
- Without `$CampaignAudits`, campaign-related checks produce 'Warn' with "No campaign data"
- Without `$AccessProfileInventory`, access profile check uses "Unknown" (not Fail)
- Recommendations list is actionable and specific to the source's failures
- Empty SourceIds array returns empty summary (not error)

**Tests:** P14-T07, P14-T08

---

## P14-05: Reviewer Load Balancer

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Get-SPReviewerLoadForecast` in SP.AuditReport.psm1 that analyzes
current and projected reviewer workload to identify imbalances and suggest
redistributions. Also new function `Export-SPReviewerLoadForecastHtml` for HTML output.

Answers: "Which reviewers are overloaded? Which have capacity? How should we
redistribute pending items for optimal campaign completion?"

Currently campaigns assign certifications based on ISC's reviewer resolution (manager,
source owner, governance group). This can result in one manager getting 80 items while
another gets 5. The toolkit tracks reviewer performance (`Measure-SPReviewerReputation`)
but does not suggest operational rebalancing. This function combines current workload
data with historical throughput to identify bottlenecks and suggest reassignments.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPReviewerLoadForecast` and
  `Export-SPReviewerLoadForecastHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPReviewerLoadForecast {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][int]$TargetItemsPerReviewer = 40,
        [Parameter()][int]$MaxItemsPerReviewer = 80,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$CampaignAudits`, extract current reviewer assignments across all active or
   recent campaigns: reviewer name, identity ID, items assigned, items decided, items
   pending.
2. From `$ReviewerReputation` (if provided), get historical throughput: avg items per
   day (derived from avg response hours and items reviewed per campaign).
3. For each reviewer, calculate:
   - **CurrentLoad**: Total pending items across all campaigns
   - **HistoricalThroughput**: Items per day based on historical response time
   - **ProjectedCompletionDays**: CurrentLoad / HistoricalThroughput
   - **LoadRatio**: CurrentLoad / TargetItemsPerReviewer
   - **Status**: Overloaded (LoadRatio > 2.0) / Heavy (1.5-2.0) / Normal (0.5-1.5) /
     Light (< 0.5)
4. Identify imbalanced campaigns: campaigns where the max reviewer load is > 3x the
   min reviewer load.
5. Generate rebalancing suggestions: for each Overloaded reviewer, suggest moving
   items to Light reviewers in the same campaign (respecting ISC's reassignment
   constraints -- reviewer must have org authority over the identities).

**Returns:**
```powershell
@{
    Reviewers = @(
        @{
            ReviewerName           = 'Bob Manager'
            ReviewerIdentityId     = 'id-mgr-001'
            CurrentLoad            = 65
            PendingItems           = 45
            DecidedItems           = 20
            HistoricalThroughput   = 8.5      # items/day
            ProjectedCompletionDays = 5.3
            LoadRatio              = 1.625
            Status                 = 'Heavy'
            Campaigns              = @('Q2 Access Review', 'AD Delta Cert 2026-05-20')
        }
    )
    Suggestions = @(
        @{
            Action       = 'Reassign'
            FromReviewer = 'Bob Manager'
            ToReviewer   = 'Carol Admin'
            ItemCount    = 15
            Campaign     = 'Q2 Access Review'
            Rationale    = 'Bob: 65 items (Heavy), Carol: 12 items (Light). Move 15 items to equalize load.'
        }
    )
    Summary = @{
        TotalReviewers  = 15
        Overloaded      = 2
        Heavy           = 3
        Normal          = 8
        Light           = 2
        ImbalancedCampaigns = 1
        SuggestedReassignments = 3
    }
}
```

New function `Export-SPReviewerLoadForecastHtml`:
- Per-reviewer load bar chart (horizontal bars, color-coded by status)
- Load distribution histogram across all reviewers
- Suggestion cards with from/to reviewer and item count
- Campaign-level load distribution view
- Summary card with status distribution

**Acceptance Criteria:**
- Reviewer with 80+ pending items and TargetItemsPerReviewer=40 gets Status 'Overloaded'
- Reviewer with 0 pending items gets Status 'Light'
- Suggestions only propose reassignment within the same campaign
- Without `$ReviewerReputation`, HistoricalThroughput defaults to 10 items/day
- Reviewer with no historical data uses default throughput
- Empty CampaignAudits returns empty summary (not error)
- Suggestions never propose reassigning to an Overloaded reviewer

**Tests:** P14-T09, P14-T10

---

## P14-06: Configuration Snapshot

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Save-SPConfigurationSnapshot` in SP.AuditQueries.psm1 that captures a
point-in-time snapshot of the ISC tenant configuration and saves it as a JSON file.
Designed for configuration drift detection (P14-07) and change management auditing.

Answers: "What did our ISC configuration look like on this date?" and "What changed
between two points in time?"

Production ISC tenants change over time: sources are added, entitlements are created
or removed, access profiles are modified, roles are reconfigured. These changes
happen outside the toolkit (via ISC admin UI or API) and are currently invisible to
the governance workflow. A snapshot captures the current state so that future runs
can detect drift.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Save-SPConfigurationSnapshot` and
  `Get-SPConfigurationSnapshot` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Save-SPConfigurationSnapshot {
    param(
        [Parameter()][string[]]$SourceIds,
        [Parameter()][switch]$IncludeEntitlements,
        [Parameter()][switch]$IncludeAccessProfiles,
        [Parameter()][switch]$IncludeRoles,
        [Parameter()][string]$OutputPath,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPConfigurationSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string]$CorrelationID
    )
}
```

**Save-SPConfigurationSnapshot flow:**
1. If `$OutputPath` not provided, use `{Audit.OutputPath}/snapshots/`.
2. Query `GET /v3/sources` (paginated) to get all sources (or filtered by SourceIds).
   Record per source: Id, Name, Type, Description, Enabled, OwnerName, OwnerId,
   ConnectorType, AccountCount.
3. If `-IncludeEntitlements`: for each source, query `GET /v3/entitlements` (paginated).
   Record count per source, privileged count, entitlement names.
4. If `-IncludeAccessProfiles`: for each source, query `GET /v3/access-profiles`.
   Record count, names, enabled/requestable status.
5. If `-IncludeRoles`: query `GET /v3/roles`. Record count, names, membership type,
   access profile assignments.
6. Capture toolkit settings hash: SHA-256 of current `Config/settings.json` content.
7. Build snapshot JSON:
   ```json
   {
       "snapshotId": "guid",
       "capturedAt": "2026-05-23T12:00:00Z",
       "toolkitVersion": "1.0.0",
       "settingsHash": "abc123...",
       "scope": {
           "includeEntitlements": true,
           "includeAccessProfiles": true,
           "includeRoles": false
       },
       "sources": [ ... ],
       "summary": {
           "sourceCount": 3,
           "totalEntitlements": 280,
           "totalAccessProfiles": 48,
           "totalRoles": 15
       }
   }
   ```
8. Write to `{OutputPath}/snapshot-{YYYY-MM-DD-HHmmss}.json`.

**Get-SPConfigurationSnapshot flow:**
1. Read the JSON file at `$Path`.
2. Parse and return the snapshot object with metadata.

**Returns (Save):**
```powershell
@{
    Success = $true
    Data = @{
        SnapshotPath = 'Audit/snapshots/snapshot-2026-05-23-120000.json'
        SnapshotId   = 'guid'
        CapturedAt   = '2026-05-23T12:00:00Z'
        SourceCount  = 3
        Summary = @{
            Sources          = 3
            Entitlements     = 280
            AccessProfiles   = 48
            Roles            = 15
        }
    }
}
```

**Returns (Get):**
The parsed snapshot hashtable.

**Acceptance Criteria:**
- Snapshot JSON is valid and parseable by `Get-SPConfigurationSnapshot`
- Paginated source query handles > 250 sources
- Without `-IncludeEntitlements`, entitlement data is omitted (not empty)
- Snapshot file named with timestamp for chronological sorting
- Settings hash changes when settings.json is modified
- Empty source list (no sources in tenant) produces valid snapshot with 0 sources
- Snapshot directory created automatically if it does not exist

**Tests:** P14-T11, P14-T12

---

## P14-07: Configuration Drift Report

- **Status:** `PENDING`
- **Depends On:** P14-06

**Description:**
New function `Compare-SPConfigurationSnapshots` in SP.AuditReport.psm1 that compares
two configuration snapshots and produces a structured diff of all changes. Also new
function `Export-SPConfigurationDriftHtml` for HTML output.

Answers: "What changed in our ISC tenant between last month and today? Were any
entitlements added or removed? Did any source configurations change?"

Configuration drift is a common source of governance gaps: a new entitlement is
added to a source but never included in any certification campaign because nobody
realized it was created. A source owner changes but the governance team is not
notified. This function makes drift visible and auditable.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Compare-SPConfigurationSnapshots` and
  `Export-SPConfigurationDriftHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Compare-SPConfigurationSnapshots {
    param(
        [Parameter(Mandatory)][hashtable]$Baseline,
        [Parameter(Mandatory)][hashtable]$Current,
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:** Two snapshot hashtables from `Get-SPConfigurationSnapshot`.

**Comparison dimensions:**

1. **Sources**: Added, removed, modified (owner change, enabled/disabled, type change)
2. **Entitlements** (if both snapshots include them): Added, removed per source.
   Privileged flag changes.
3. **Access Profiles** (if both include them): Added, removed per source.
   Enabled/requestable changes.
4. **Roles** (if both include them): Added, removed. Membership type changes.
   Access profile assignment changes.
5. **Settings**: Hash comparison. Changed = true/false (content diff not computed,
   just whether the hash differs).

**Change classification:**
- **Added**: Present in Current but not in Baseline
- **Removed**: Present in Baseline but not in Current
- **Modified**: Present in both but with different attributes
- **Unchanged**: Present in both with identical attributes

**Returns:**
```powershell
@{
    Baseline = @{ SnapshotId = '...'; CapturedAt = '2026-04-23T12:00:00Z' }
    Current  = @{ SnapshotId = '...'; CapturedAt = '2026-05-23T12:00:00Z' }
    DriftDetected = $true
    Changes = @{
        Sources = @{
            Added   = @(@{ SourceId = 'src-new'; SourceName = 'New Cloud App' })
            Removed = @()
            Modified = @(
                @{
                    SourceId   = 'src-ad-001'
                    SourceName = 'Corporate AD'
                    Fields     = @(
                        @{ Field = 'OwnerName'; Baseline = 'Jane Admin'; Current = 'Mike Admin' }
                    )
                }
            )
        }
        Entitlements = @{
            Added   = @(@{ SourceName = 'Corporate AD'; EntitlementName = 'AD-SG-NewGroup'; Privileged = $false })
            Removed = @(@{ SourceName = 'Corporate AD'; EntitlementName = 'AD-SG-DeprecatedGroup' })
            PrivilegedChanges = @()
        }
        AccessProfiles = @{
            Added   = @()
            Removed = @()
            Modified = @()
        }
        Roles = @{
            Added   = @()
            Removed = @()
            Modified = @()
        }
        SettingsChanged = $false
    }
    Summary = @{
        TotalChanges     = 4
        SourceChanges    = 2
        EntitlementChanges = 2
        AccessProfileChanges = 0
        RoleChanges      = 0
        SettingsChanged  = $false
        RiskIndicators   = @(
            'New source src-new not yet included in any campaign',
            'Source owner changed for Corporate AD -- verify governance routing'
        )
    }
}
```

New function `Export-SPConfigurationDriftHtml`:
- Side-by-side snapshot metadata (baseline date vs current date)
- Per-dimension change tables with Added/Removed/Modified badges
- Risk indicator callout section for changes that may affect governance
- Summary card with total change count
- No changes = "No drift detected" confirmation badge

**Acceptance Criteria:**
- Identical snapshots produce DriftDetected = false with 0 TotalChanges
- New source in Current not in Baseline appears in Sources.Added
- Source with changed owner appears in Sources.Modified with field detail
- New entitlement appears in Entitlements.Added
- Snapshots with different scope (one has entitlements, other does not) produces
  warning "Scope mismatch: entitlement comparison skipped"
- Risk indicators generated for changes that may affect governance coverage
- Empty snapshots (0 sources) compared to populated snapshot shows all as Added

**Tests:** P14-T13, P14-T14

---

## P14-08: Campaign Template Library

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New functions `Save-SPCampaignTemplate`, `Get-SPCampaignTemplate`, and
`Get-SPCampaignTemplateList` in SP.Config.psm1 that implement a local template
library for reusable campaign configurations.

Answers: "I run the same quarterly access review every 3 months. Can I save the
parameters and recall them instead of typing them each time?"

Currently every campaign run requires specifying all parameters: source IDs, reviewer
mode, deadline days, hours back, campaign name prefix, exclusion patterns. For
recurring campaigns (quarterly reviews, monthly delta certs), operators re-enter the
same values every time. Templates store named parameter sets that can be recalled
and passed to existing campaign functions.

**Files to Modify:**
- `Modules/SP.Core/SP.Config.psm1` -- new `Save-SPCampaignTemplate`,
  `Get-SPCampaignTemplate`, `Get-SPCampaignTemplateList`,
  `Remove-SPCampaignTemplate` functions
- `Modules/SP.Core/SP.Core.psd1` -- export new functions
- `Config/settings.json` -- add `Templates` section

**Config section:**
```json
"Templates": {
    "Path": ".\\Config\\templates"
}
```

**Function Signatures:**
```powershell
function Save-SPCampaignTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$Description,
        [Parameter()][ValidateSet('DeltaCert','Audit','GovernanceReport','WeeklyDigest','HealthCheck')]
        [string]$Type = 'DeltaCert',
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPCampaignTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPCampaignTemplateList {
    param(
        [Parameter()][string]$Type,
        [Parameter()][string]$CorrelationID
    )
}

function Remove-SPCampaignTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$CorrelationID
    )
}
```

**Template file format:** `{Templates.Path}/{name}.json`
```json
{
    "name": "quarterly-ad-review",
    "description": "Quarterly access review for Corporate AD",
    "type": "DeltaCert",
    "createdAt": "2026-05-23T12:00:00Z",
    "modifiedAt": "2026-05-23T12:00:00Z",
    "parameters": {
        "SourceId": ["src-ad-001"],
        "HoursBack": 2160,
        "DeadlineDays": 14,
        "ReviewerMode": "Manager",
        "CampaignNamePrefix": "Q2 AD Review"
    }
}
```

**Save-SPCampaignTemplate flow:**
1. Validate `$Name` is a safe filename (alphanumeric, hyphens, underscores only).
2. Validate `$Parameters` hashtable is not empty.
3. Check if template already exists. If yes, update `modifiedAt` (overwrite).
4. Create templates directory if it does not exist.
5. Write JSON file to `{Templates.Path}/{name}.json`.

**Get-SPCampaignTemplate flow:**
1. Read `{Templates.Path}/{name}.json`.
2. Return the parsed template object including the `Parameters` hashtable,
   ready to be splatted into campaign functions.

**Get-SPCampaignTemplateList flow:**
1. List all `.json` files in `{Templates.Path}/`.
2. Parse each, extract name, description, type, dates.
3. If `$Type` specified, filter to matching type.
4. Return sorted by name.

**Returns (Save):**
```powershell
@{
    Success = $true
    Data = @{
        Name = 'quarterly-ad-review'
        Path = 'Config/templates/quarterly-ad-review.json'
        Action = 'Created'   # or 'Updated'
    }
}
```

**Returns (Get):**
```powershell
@{
    Success = $true
    Data = @{
        Name        = 'quarterly-ad-review'
        Description = 'Quarterly access review for Corporate AD'
        Type        = 'DeltaCert'
        CreatedAt   = '2026-05-23T12:00:00Z'
        ModifiedAt  = '2026-05-23T12:00:00Z'
        Parameters  = @{
            SourceId  = @('src-ad-001')
            HoursBack = 2160
            DeadlineDays = 14
            ReviewerMode = 'Manager'
            CampaignNamePrefix = 'Q2 AD Review'
        }
    }
}
```

**Returns (List):**
```powershell
@{
    Success = $true
    Data = @(
        @{ Name = 'quarterly-ad-review'; Type = 'DeltaCert'; Description = '...'; ModifiedAt = '...' }
        @{ Name = 'weekly-digest-all'; Type = 'WeeklyDigest'; Description = '...'; ModifiedAt = '...' }
    )
}
```

**Acceptance Criteria:**
- Template name with spaces or special characters rejected with descriptive error
- Save then Get returns identical Parameters hashtable
- Save with existing name overwrites and updates modifiedAt
- Get with non-existent name returns Success = false with descriptive error
- List with no templates returns empty array (not error)
- List with Type filter returns only matching templates
- Remove deletes the file and returns confirmation
- Remove with non-existent name returns Success = false
- Templates directory created on first Save if it does not exist
- Template JSON is human-readable (indented)

**Tests:** P14-T15, P14-T16

---

## P14-09: Invoke-SPGovernanceHealthCheck.ps1

- **Status:** `PENDING`
- **Depends On:** P14-01

**Description:**
New CLI script `Scripts/Invoke-SPGovernanceHealthCheck.ps1` that runs a comprehensive
real-time governance health check combining active campaign health, orchestrator
reliability, identity risk highlights, policy compliance status, stale access
indicators, and the governance maturity scorecard (P14-01) into a single operational
dashboard.

Designed for: daily operations check-in, pre-meeting governance status review, and
on-demand "is everything OK?" verification. Unlike the weekly digest (P12-08) which
is retrospective and scheduled, this script captures the current moment with emphasis
on actionable alerts.

**File to Create:**
- `Scripts/Invoke-SPGovernanceHealthCheck.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string[]]$SourceId,

    # Section toggles
    [Parameter()][switch]$SkipCampaignHealth,
    [Parameter()][switch]$SkipOrchestratorHealth,
    [Parameter()][switch]$SkipIdentityRisk,
    [Parameter()][switch]$SkipPolicyCheck,
    [Parameter()][switch]$SkipStaleAccess,
    [Parameter()][switch]$SkipMaturityScore,

    # Depth controls
    [Parameter()][int]$OrchestratorDaysBack = 7,
    [Parameter()][int]$CampaignDaysBack = 30,

    # Output
    [Parameter()][ValidateSet('Console','HTML','JSON','Both')]
    [string]$OutputMode = 'Console',
    [Parameter()][string]$OutputPath,

    # Notification
    [Parameter()][switch]$AlertOnRed,
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

Step 2: Campaign Health (unless -SkipCampaignHealth)
  -> Get-SPCampaignHealth for all active campaigns
  -> Flag Red/Yellow campaigns for alert

Step 3: Orchestrator Health (unless -SkipOrchestratorHealth)
  -> Get-SPOrchestratorHistory -DaysBack $OrchestratorDaysBack
  -> Flag consecutive failures or declining success rate

Step 4: Identity Risk Snapshot (unless -SkipIdentityRisk)
  -> Get-SPAuditCampaigns -DaysBack $CampaignDaysBack
  -> Measure-SPIdentityRisk for High-tier identities only (fast path)

Step 5: Policy Compliance (unless -SkipPolicyCheck)
  -> Test-SPGovernancePolicy with available data

Step 6: Stale Access Summary (unless -SkipStaleAccess)
  -> Get-SPStaleAccess summary counts

Step 7: Maturity Score (unless -SkipMaturityScore)
  -> Measure-SPGovernanceMaturity with all collected data

Step 8: Alert (if -AlertOnRed)
  -> If any Red campaigns OR critical policy failures OR maturity < Level 3:
     Send-SPNotification with alert summary

Step 9: Output
  -> Console: compact dashboard (see below)
  -> HTML: full health check report
  -> JSON: structured output
```

**Console output:**
```
=== Governance Health Check ===
Timestamp:     2026-05-23T14:30:00Z
Sources:       src-ad-001, src-entra-001

--- Active Campaigns ---
  Green: 3 | Yellow: 1 | Red: 0
  Yellow: Q2 Access Review (67% complete, 3 days remaining)

--- Orchestrator (7 days) ---
  Runs: 7/7 successful | Avg: 2m 15s | Trend: Stable

--- Identity Risk ---
  High: 5 | Top: Alice Johnson (85), Bob ServiceAcct (72)

--- Policy Compliance ---
  PASS: 3/5 | FAIL: 2 (POL-001 Critical, POL-004 Warning)

--- Stale Access ---
  Total: 22 | Privileged: 2 | Never Reviewed: 8

--- Governance Maturity ---
  Level 4 (Managed) | Score: 68.5/100
  Weakest: Accountability (55) | Strongest: Automation (93)

Overall Status: HEALTHY (2 warnings)
```

**Exit codes:**
- 0 = All healthy, no alerts
- 1 = Warnings present (Yellow campaigns, non-critical policy failures)
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Critical issues (Red campaigns, critical policy failures, maturity < Level 2)

**Acceptance Criteria:**
- All 7 health sections generate with real or partial data
- Section skip switches exclude the corresponding check
- Exit code 5 when any Red campaign exists
- Exit code 1 when only Yellow campaigns or non-critical warnings
- `-AlertOnRed` sends notification only when critical issues detected
- `-WhatIf` shows what would be checked without API calls
- Console output fits in a standard 80-column terminal
- HTML output is a self-contained file with same styling as audit reports
- Works with both `-Token` and configured OAuth

**Tests:** P14-T17

---

## P14-10: Pester Tests

- **Status:** `PENDING`
- **Depends On:** P14-09

**Description:**
Pester tests for all new functions added in P14-01 through P14-09.

**File to Create:**
- `Tests/SP.GovernanceMaturity.Tests.ps1`

**Test IDs:**

- P14-T01: Measure-SPGovernanceMaturity scores Level 5 when all dimensions are 90+
- P14-T02: Measure-SPGovernanceMaturity scores Level 1 with all null inputs
- P14-T03: Get-SPRemediationPriority ranks privileged stale access above non-privileged
- P14-T04: Get-SPRemediationPriority deduplicates same identity+entitlement pairs
- P14-T05: Protect-SPAuditTrail then Test-SPAuditTrailIntegrity returns Valid
- P14-T06: Test-SPAuditTrailIntegrity detects tampered line in protected file
- P14-T07: Test-SPSourceReadiness returns 'Not Ready' for source with 0 entitlements
- P14-T08: Test-SPSourceReadiness returns 'Ready' for fully configured source
- P14-T09: Get-SPReviewerLoadForecast identifies Overloaded reviewer above MaxItems
- P14-T10: Get-SPReviewerLoadForecast suggestions never target Overloaded reviewers
- P14-T11: Save-SPConfigurationSnapshot creates valid JSON with source data
- P14-T12: Get-SPConfigurationSnapshot reads and parses saved snapshot
- P14-T13: Compare-SPConfigurationSnapshots detects added source
- P14-T14: Compare-SPConfigurationSnapshots returns DriftDetected=false for identical snapshots
- P14-T15: Save-SPCampaignTemplate then Get-SPCampaignTemplate returns identical parameters
- P14-T16: Save-SPCampaignTemplate rejects name with special characters
- P14-T17: Invoke-SPGovernanceHealthCheck.ps1 syntax validation (PS AST parser)

**Mock patterns:**
- Mock `Invoke-SPApiRequest` for API calls (sources, entitlements)
- Mock `Get-SPConfig` for config-dependent tests
- Mock `Measure-SPIdentityRisk`, `Measure-SPSourceGovernance`, `Get-SPStaleAccess`,
  `Measure-SPReviewerReputation`, `Test-SPGovernancePolicy`,
  `Get-SPOrchestratorHistory`, `Get-SPRemediationStatus`,
  `Measure-SPCampaignMetrics` for maturity scorecard tests (pass pre-computed results)
- Use `TestDrive:\` for JSONL integrity chain tests (create, protect, tamper, verify)
- Use `TestDrive:\` for snapshot JSON file creation and comparison
- Use `TestDrive:\` for template file creation and retrieval
- Use `TestDrive:\` for HTML output verification

**Files to Modify:**
- `Tests/Import-TestModules.ps1` -- add module imports if needed

**Acceptance Criteria:**
- All 17 tests pass on PowerShell 7 (pwsh)
- No dependencies on external services (all API calls mocked)
- Tests are self-contained (create and clean up their own test data)

---

## Existing Patterns to Follow

| Pattern | Location | Reuse In |
|---------|----------|----------|
| API pagination | SP.AuditQueries.psm1 `Get-SPAuditCampaigns` | P14-04, P14-06 |
| HTML report generation | SP.AuditReport.psm1 `Build-SingleCampaignHtml` | P14-01, P14-02, P14-04, P14-05, P14-07 |
| HTML table helpers | SP.AuditReport.psm1 `Build-HtmlTableRow` / `Build-HtmlTableHeader` | P14-01, P14-02, P14-04, P14-05, P14-07 |
| Identity risk aggregation | SP.AuditReport.psm1 `Measure-SPIdentityRisk` | P14-01, P14-02 |
| Source governance scoring | SP.AuditReport.psm1 `Measure-SPSourceGovernance` | P14-01, P14-04 |
| Reviewer reputation | SP.AuditReport.psm1 `Measure-SPReviewerReputation` | P14-01, P14-05 |
| Policy compliance | SP.AuditReport.psm1 `Test-SPGovernancePolicy` | P14-01, P14-02 |
| Config defaults | SP.Config.psm1 `Get-SPConfigDefaults` | P14-08 |
| Config file I/O | SP.Config.psm1 `Get-SPConfig` / `New-SPConfigFile` | P14-08 |
| JSONL read/parse | SP.AuditReport.psm1 `Get-SPAuditTrail` | P14-03 |
| JSONL write (BOM-free) | SP.AuditReport.psm1 `Export-SPAuditJsonl` | P14-03 |
| SHA-256 hashing | SP.AuditReport.psm1 `Export-SPCompliancePackage` (artifact hashes) | P14-03, P14-06 |
| CLI script structure | Invoke-SPDailyOrchestrator.ps1 (param block, module loading, error handling) | P14-09 |
| Weekly digest script | Invoke-SPWeeklyDigest.ps1 (multi-section console + HTML output) | P14-09 |
| Pester mock patterns | Tests/SP.ProductionReadiness.Tests.ps1, Tests/SP.OperationalIntelligence.Tests.ps1, Tests/SP.GovernanceDepth.Tests.ps1 | P14-10 |
| CSV export | SP.AuditReport.psm1 `Export-SPAuditCsv` | P14-02 |
| Entitlement inventory | SP.AuditQueries.psm1 `Get-SPEntitlementInventory` | P14-04, P14-06 |
| Period comparison | SP.AuditReport.psm1 `Compare-SPAuditPeriods` | P14-07 |

---

## ISC API Endpoints (New in Phase 14)

| Endpoint | Method | Used By | Purpose |
|----------|--------|---------|---------|
| `/v3/sources` | GET | P14-04, P14-06 | List all sources (paginated) |

All other features consume existing function output or operate on local files
(JSONL integrity, templates, snapshots).

**New PAT Scopes Required:**
- None. `idn:sources:read` is already required from Phase 11.

---

## Operational Reference (Post-Phase 14)

```powershell
# Daily health check (the "is everything OK?" command)
.\Invoke-SPGovernanceHealthCheck.ps1 -SourceId 'src-ad-001' -Token $token

# With alerting on critical issues
.\Invoke-SPGovernanceHealthCheck.ps1 -SourceId 'src-ad-001' -Token $token `
    -AlertOnRed -AlertRecipients 'admin@company.com'

# Full HTML health report
.\Invoke-SPGovernanceHealthCheck.ps1 -SourceId 'src-ad-001' -Token $token `
    -OutputMode HTML -OutputPath '.\Audit'

# Governance maturity assessment (standalone)
$audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object {
    Get-SPAuditCampaignReport -CampaignId $_.id
}
$risk = Measure-SPIdentityRisk -CampaignAudits $audits
$governance = Measure-SPSourceGovernance -CampaignAudits $audits
$reputation = Measure-SPReviewerReputation -CampaignAudits $audits
$stale = Get-SPStaleAccess -CampaignAudits $audits
$policy = Test-SPGovernancePolicy -IdentityRisk $risk -SourceGovernance $governance
$orchestrator = Get-SPOrchestratorHistory -DaysBack 30
Measure-SPGovernanceMaturity -SourceGovernance $governance `
    -IdentityRisk $risk -ReviewerReputation $reputation `
    -StaleAccess $stale -PolicyCompliance $policy `
    -OrchestratorHistory $orchestrator

# Remediation priority queue
Get-SPRemediationPriority -IdentityRisk $risk -StaleAccess $stale `
    -PolicyCompliance $policy -MaxItems 20

# Protect audit trail for compliance
Protect-SPAuditTrail -Path '.\Audit\audit-2026-05-23.jsonl'
Test-SPAuditTrailIntegrity -Path '.\Audit\audit-2026-05-23.jsonl'

# Source onboarding readiness
Test-SPSourceReadiness -SourceIds @('src-new-app')

# Reviewer load balancing
Get-SPReviewerLoadForecast -CampaignAudits $audits `
    -ReviewerReputation $reputation -TargetItemsPerReviewer 40

# Configuration snapshot and drift detection
Save-SPConfigurationSnapshot -SourceIds @('src-ad-001') `
    -IncludeEntitlements -IncludeAccessProfiles
# ... time passes ...
$baseline = Get-SPConfigurationSnapshot -Path '.\Audit\snapshots\snapshot-2026-04-23.json'
$current  = Get-SPConfigurationSnapshot -Path '.\Audit\snapshots\snapshot-2026-05-23.json'
Compare-SPConfigurationSnapshots -Baseline $baseline -Current $current

# Campaign templates
Save-SPCampaignTemplate -Name 'quarterly-ad-review' `
    -Description 'Quarterly Corporate AD access review' `
    -Type DeltaCert `
    -Parameters @{
        SourceId = @('src-ad-001')
        HoursBack = 2160
        DeadlineDays = 14
        ReviewerMode = 'Manager'
    }
$template = Get-SPCampaignTemplate -Name 'quarterly-ad-review'
Invoke-SPDeltaCertRun @($template.Data.Parameters)
```
