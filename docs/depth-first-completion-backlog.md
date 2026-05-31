# Depth-First Completion -- Backlog (DF-01 to DF-10)

**Created:** 2026-05-31
**Purpose:** Finish what's started. Complete P13, close P14 payoff items, add ITSM export.
**Priority:** Depth over breadth. Every item builds on an existing foundation.

---

## Serial order: `DF-01 -> DF-02 -> DF-03 -> DF-04 -> DF-05 -> DF-06 -> DF-07 -> DF-08 -> DF-09 -> DF-10`

---

## Phase Summary

| ID | Feature | Source | Depends On | Status |
|----|---------|--------|------------|--------|
| DF-01 | Policy Compliance Report | P13-05 | P13-04 (DONE) | DONE |
| DF-02 | Governance Dashboard Data Export | P13-08 | none | DONE |
| DF-03 | Invoke-SPGovernanceReport.ps1 | P13-09 | DF-02 | PENDING |
| DF-04 | Phase 13 Pester Tests | P13-10 | DF-03 | PENDING |
| DF-05 | Audit Evidence Integrity Chain | P14-03 | none | PENDING |
| DF-06 | Source Onboarding Readiness | P14-04 | none | PENDING |
| DF-07 | Configuration Drift Report | P14-07 | P14-06 (DONE) | PENDING |
| DF-08 | Invoke-SPGovernanceHealthCheck.ps1 | P14-09 | DF-07 | PENDING |
| DF-09 | Bulk Remediation Ticket Export | P15-04 | none | PENDING |
| DF-10 | Phase 16 Pester Tests | P16-10 | none | PENDING |

---

## DF-01: Policy Compliance Report (P13-05)

- **Status:** `DONE`
- **Depends On:** P13-04 Governance Policy Engine (DONE)

**What exists:** `Test-SPGovernancePolicy` returns pass/fail results per policy.
**What's missing:** HTML report rendering those results into a dashboard.

**Build:** `Export-SPPolicyComplianceHtml` in SP.AuditReportHtml.psm1
- Input: policy results from Test-SPGovernancePolicy
- Output: HTML with pass/fail badges, policy descriptions, violation details
- Color: green=pass, red=fail, orange=warning
- Export in SP.Audit.psd1

**Files:** Modules/SP.Audit/SP.AuditReportHtml.psm1, Modules/SP.Audit/SP.Audit.psd1

---

## DF-02: Governance Dashboard Data Export (P13-08)

- **Status:** `DONE`
- **Depends On:** none

**Build:** `Export-SPGovernanceDashboardData` in SP.AuditOperations.psm1
- Produces a unified JSON/CSV dataset combining: campaign metrics, policy results,
  identity risk scores, source governance grades, reviewer performance
- Designed for Power BI / Tableau / Splunk consumption
- Single flat table with one row per campaign-identity-entitlement combination

**Files:** Modules/SP.Audit/SP.AuditOperations.psm1, Modules/SP.Audit/SP.Audit.psd1

---

## DF-03: Invoke-SPGovernanceReport.ps1 (P13-09)

- **Status:** `PENDING`
- **Depends On:** DF-02

**The "run everything" script.** Single command that produces a complete governance
report package: campaign audit + leadership rollup + policy compliance + data quality +
dashboard export. The script an auditor asks for.

**Build:** New CLI script combining:
1. Campaign audit (existing Invoke-SPCampaignAudit logic)
2. Policy compliance (DF-01)
3. Data quality report (P16-08, existing)
4. Dashboard data export (DF-02)
5. Leadership rollup (existing)
6. Package everything into one output directory with manifest

**Parameters:** -Status, -DaysBack, -IncludeLeadershipRollup, -IncludePolicyCheck,
-IncludeDataQuality, -OutputPath, -ConfigPath, -Token, -OutputMode

**Files:** Scripts/Invoke-SPGovernanceReport.ps1 (NEW)

---

## DF-04: Phase 13 Pester Tests (P13-10)

- **Status:** `PENDING`
- **Depends On:** DF-03

**Tests for P13 functions:** Test-SPGovernancePolicy, Export-SPPolicyComplianceHtml,
Measure-SPAuditPeriodComparison, Get-SPAccessProfileInventory, Get-SPRoleInventory,
Get-SPMultiSourceIdentityCorrelation, Export-SPGovernanceDashboardData.

**Files:** Tests/SP.GovernanceDepth.Tests.ps1 (NEW)

---

## DF-05: Audit Evidence Integrity Chain (P14-03)

- **Status:** `PENDING`
- **Depends On:** none

**Build:** `New-SPAuditEvidenceChain` in SP.AuditOperations.psm1
- Reads all JSONL audit trail files in a date range
- Computes SHA-256 hash per file
- Creates a chain: each hash includes the previous hash (blockchain-lite)
- Writes manifest.json with file paths, hashes, chain links, timestamps
- Detects tampering: if any file is modified, the chain breaks

**Why it matters:** SOX auditors ask "can you prove this evidence wasn't modified
after the fact?" This provides cryptographic proof.

**Files:** Modules/SP.Audit/SP.AuditOperations.psm1, Modules/SP.Audit/SP.Audit.psd1

---

## DF-06: Source Onboarding Readiness (P14-04)

- **Status:** `PENDING`
- **Depends On:** none

**Build:** `Test-SPSourceOnboardingReadiness` in SP.AuditQueries.psm1
- Pre-flight checklist for adding a new source to ISC governance
- Checks: source exists, schema configured, correlation rules set, accounts aggregated,
  entitlements aggregated, owner assigned, test campaign can be created
- Returns structured pass/fail per check with remediation guidance

**Files:** Modules/SP.Audit/SP.AuditQueries.psm1, Modules/SP.Audit/SP.Audit.psd1

---

## DF-07: Configuration Drift Report (P14-07)

- **Status:** `PENDING`
- **Depends On:** P14-06 Configuration Snapshot (DONE)

**What exists:** `Save-SPConfigurationSnapshot` and `Get-SPConfigurationSnapshot`.
**What's missing:** The comparison that makes snapshots useful.

**Build:** `Compare-SPConfigurationSnapshots` + `Export-SPConfigDriftHtml`
- Input: two snapshot files (or "latest" vs "previous")
- Compares: sources added/removed, entitlements changed, schema modifications,
  correlation rule changes, owner changes
- HTML report with diff-style presentation (added=green, removed=red, changed=orange)

**Files:** Modules/SP.Audit/SP.AuditAnalytics.psm1, Modules/SP.Audit/SP.AuditReportHtml.psm1, SP.Audit.psd1

---

## DF-08: Invoke-SPGovernanceHealthCheck.ps1 (P14-09)

- **Status:** `PENDING`
- **Depends On:** DF-07

**Build:** CLI script that runs all health checks in one command:
1. Source aggregation health (P16-02, existing)
2. Data quality score (P16-03, existing)
3. Policy compliance (DF-01)
4. Config drift since last snapshot (DF-07)
5. Orphan accounts (P16-01, existing)
6. Campaign coverage gaps (P16-04, existing)

**Output:** Console summary with pass/fail per check + optional HTML report.

**Files:** Scripts/Invoke-SPGovernanceHealthCheck.ps1 (NEW)

---

## DF-09: Bulk Remediation Ticket Export (P15-04)

- **Status:** `PENDING`
- **Depends On:** none

**Build:** `Export-SPRemediationTickets` in SP.AuditOperations.psm1
- Reads revocation decisions from campaign audit data
- For disconnected apps: reads remediation tracker (DA-22)
- Exports CSV formatted for ServiceNow/Jira import:
  Columns: TicketType, Priority, AssignedTo, AppName, IdentityName, AccountId,
  EntitlementRevoked, ReviewerName, DecisionDate, DueDate, Description
- Each revocation = one ticket row

**Files:** Modules/SP.Audit/SP.AuditOperations.psm1, Modules/SP.Audit/SP.Audit.psd1

---

## DF-10: Phase 16 Pester Tests (P16-10)

- **Status:** `PENDING`
- **Depends On:** none

**Tests for P16 functions:** Get-SPOrphanAccounts, Get-SPSourceAggregationHealth,
Measure-SPIdentityAttributeQuality, Get-SPCampaignCoverageGaps,
Predict-SPCampaignCompletion, Save-SPGovernanceMetrics, Get-SPReviewerDelegationAudit.

**Files:** Tests/SP.DataQuality.Tests.ps1 (NEW)
