# SailPoint ISC Governance Toolkit -- Reporting & Analytics

> **Source of truth.** This is the consolidated guide to every report the toolkit
> generates, who it is for, and how to produce it. Reporting capabilities are built into
> many scripts across the toolkit -- this guide maps them all to audiences and use cases.
> Read [Foundations](00-foundations.md) first for setup and authentication.

**Audience:** SailPoint implementors, governance leads, compliance officers, and
anyone who needs to know "what report do I give to whom?"

---

## Report Types at a Glance

| Report | Script | Audience | Frequency | What It Contains | Output |
|---|---|---|---|---|---|
| Campaign Audit | `Invoke-SPCampaignAudit.ps1` | Compliance, auditors | After campaigns | 7-section audit with decisions, reviewer accountability, remediation proof | HTML, Text, JSONL |
| Leadership Rollup | `Invoke-SPCampaignAudit.ps1 -IncludeLeadershipRollup` | VPs, directors | After campaigns | Per-leader decision summaries rolled up the org tree | HTML |
| Delta Report | `Invoke-SPDeltaReport.ps1` | Governance operations | Daily | Grants, revocations, pending certs, anomalies | HTML, JSONL |
| Disconnected App Delta | `Invoke-SPDisconnectedAppCert.ps1` / `Batch` | Governance team, app teams | Daily | Per-app changes, processing status | HTML, JSONL |
| Governance Health Check | `Invoke-SPGovernanceHealthCheck.ps1` | Governance leads | Weekly / pre-audit | 6-dimension health score with pass/fail/warn per check | HTML, JSON |
| Governance Report | `Invoke-SPGovernanceReport.ps1` | Auditors, governance leads | Quarterly | Combined audit + leadership + policy + data quality package | HTML, JSONL |
| Data Quality Report | `Invoke-SPDataQualityReport.ps1` | IAM operations | Weekly | Orphan accounts, identity quality, source health | HTML, JSON |
| Governance Metrics | `Invoke-SPGovernanceMetrics.ps1` | KPI dashboards, BI tools | Daily (automated) | KPI time-series + trend reports + completion forecasts | HTML, JSON, JSONL |
| Daily Evidence Report | `Invoke-SPDailyEvidenceReport.ps1` | CISO, VP Security, auditors | Daily | 6-KPI executive dashboard + domino risk tracker + audit evidence registers | HTML, JSON, JSONL |
| Daily Evidence Report (v2) | `Invoke-SPDailyEvidenceReportV2.ps1` | CISO, VP Security, auditors | Daily | Lean rewrite: per-campaign executive summary (donut), scope, completion, reviewer accountability, decision summary (no KPI dashboard) | HTML, JSONL |
| Daily Evidence Report (v4) | `Invoke-SPDailyEvidenceReportV4.ps1` | CISO, auditors, IAM ops | Daily | Focused evidence: KPI dashboard, campaign completion with undecided detection (idNowAutoApproved), revoked register, new scope, reviewer accountability. Writes daily-metrics.jsonl for V7 | HTML, JSON, JSONL |
| Daily Evidence Report (v4b) | `Invoke-SPDailyEvidenceReportV4b.ps1` | CISO, auditors, IAM ops | Daily | Fork of V4 with bug fixes: donut chart, N/A reviewer warning, item-level reviewer %. Same features as V4. CAUTION: its diff-based "Newly Decided" flags routine catch-up approvals on single-campaign daily runs -- use V4g/V8 (state DB) for authoritative newly-decided | HTML, JSON, JSONL |
| Daily Evidence Report (v4g) | `Invoke-SPDailyEvidenceReportV4g.ps1` | CISO, auditors, IAM ops | Daily | V4 + persistent entitlement state DB (entitlement-state.jsonl). Authoritative Newly Decided (observed PENDING/UNDECIDED -> decided transitions only; first-seen-already-decided and reassignment re-approvals excluded), Re-Approved After Revoke register, honest APPROVE/REVOKE/PENDING/UNDECIDED states (idNowAutoApproved-aware) | HTML, JSON, JSONL |
| Daily Evidence Trending (v7) | `Invoke-SPDailyEvidenceReportV7.ps1` | CISO, leadership, IAM ops | Weekly / on-demand | Calendar-day visualization: completion progression, decision distribution, reviewer heatmap, compliance accountability, source-level breakdown. Reads daily-metrics.jsonl (no API calls) | HTML |
| Escalation Report | `Invoke-SPDeltaCertEscalate.ps1` | IAM ops, managers | Daily | Late reviewer escalation with org hierarchy, per-manager HTML, email routing CSV | HTML, CSV, TXT |
| State-Powered Evidence (V8) | `Invoke-SPDailyEvidenceReportV8.ps1` | CISO, auditors, IAM ops | Daily / on-demand | 8-section state-driven report: entitlement state KPIs, privileged access breakdown by source, newly decided + re-approved after revoke, chronically unreviewed, dropped scope, reviewer engagement + weekly compliance + heatmap, campaign summary | HTML |
| Governance Trend Dashboard | `Invoke-SPGovernanceTrendScrape.ps1` | Leadership, CISO | Monthly | Multi-report trend: KPI cards, decision distribution chart, completion/reviewer trend lines, month-over-month comparison, per-day detail. Scraped from existing HTML reports | HTML |
| Pending Reviewer Tracker | `Invoke-SPPendingReviewerScrape.ps1` | IAM ops, compliance | Weekly | Chronic pending bars, missed-review streaks (consecutive REPORT days -- weekends do not reset), heatmap, gaming pattern detection (alternating/day-of-week/declining/burst/bare minimum). Auto-MinMisses scaling. Scrapes production daily-evidence-v4b-*.html by default | HTML |
| Decision Activity Tracker | `Invoke-SPDecisionScrape.ps1` | IAM ops, auditors | Weekly / on-demand | Revoked + new-scope decisions scraped from daily evidence HTML: de-duplicates the cumulative daily registers, buckets by each item's own Decision Date, KPI tiles incl. approved campaign-to-date, combined + revoked-only + adds-only adaptive charts, raw per-day table, top revoked entitlements/identities, source breakdown | HTML |
| Weekly Digest | `Invoke-SPWeeklyDigest.ps1` | Governance leadership | Weekly | Campaign activity, health, risk, reviewer performance, remediation | HTML, JSON |
| Leadership Distribution | `Invoke-SPReportDistribution.ps1` | Per-leader delivery | After campaigns | Band-filtered reports, optionally emailed via SMTP | HTML |
| Adaptive Composable | `Invoke-SPAdaptiveReport.ps1` | Presentation, analysis | On-demand | KPI cards, heatmap, top-N bars, drill-down tree, group table | HTML |
| Adaptive Baselines | `Invoke-SPAdaptiveReport.ps1 -BaselineReport` | Various (see below) | On-demand | 7 pre-built reports: inventory, privileged, orphaned, SoD, roster, access-cert, exec-summary | HTML |
| Campaign Comparison | `Invoke-SPCampaignSearch.ps1 -CompareIds` | Governance analysis | On-demand | Side-by-side metric comparison of 2+ campaigns | CSV, HTML |
| Source Coverage | `Invoke-SPCampaignSearch.ps1 -SourceCoverage` | Governance leads | Monthly | Which sources have/haven't been audited by campaigns | HTML, CSV |
| Orchestrator Summary | `Invoke-SPDailyOrchestrator.ps1` | Operations | Daily | 11-step run status with per-step timing and exit codes | JSONL |
| Entitlement History | `Invoke-SPEntitlementHistory.ps1` | Governance analysis, compliance | On-demand | Multi-snapshot timeline showing how entitlement decisions evolved across campaigns | HTML |
| Cache Validation (diagnostic) | `Invoke-SPCacheValidate.ps1` | IAM operations, troubleshooting | On-demand | SHA-256 integrity checks + schema validation of all toolkit cache files | Status bar summary (no report file) |
| ISC Reconciliation | `Invoke-SPIscReconciliation.ps1` | Governance leads, auditors | On-demand | Discrepancy export comparing local governance data against ISC source-of-truth | HTML, JSON |

---

## Campaign Audit Reports

The campaign audit report is the toolkit's primary compliance artifact. It provides
complete evidence that access was reviewed, who reviewed it, what they decided, and
whether revocations were carried out.

### Report sections

| Section | Content |
|---|---|
| **1. Executive Summary** | Campaign metadata, completion status, key KPIs (approval rate, completion rate, reviewer count, response time) |
| **2. Reviewer Accountability** | Per-reviewer breakdown: items assigned, items decided, sign-off status, response time |
| **3. Performance Metrics** | Anti-rubber-stamping analysis, decision distribution, bulk-approve detection |
| **4. Decisions** | Every access review item with decision, reviewer, timestamp, identity, entitlement |
| **5. Campaign Reports** | ISC-generated campaign report CSV data (if available) |
| **6. Remediation Proof** | For revoked items: identity lifecycle events, account status, UPN/sAMAccountName resolution |
| **7. Metadata** | Run parameters, toolkit version, data provenance, scope coverage |

### Detail levels

| Level | Content |
|---|---|
| `Summary` | Executive summary + KPIs only (1-2 pages) |
| `Detailed` | Summary + reviewer accountability + decisions (5-10 pages) |
| `Verbose` | All 7 sections, full remediation proof (10-30+ pages) |

### How to generate

```powershell
# All completed campaigns in the last 7 days, verbose detail
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7 -DetailLevel Verbose

# One campaign by name
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignName 'Q2 Manager Review' -OutputMode HTML

# Fuzzy search for campaigns containing "manager"
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'manager' -DaysBack 30
```

### Who gets them

- **Compliance team:** the full verbose report as compliance and audit evidence
- **Audit committee:** summary-level reports for quarterly review meetings
- **Campaign owners:** detailed-level reports for their specific campaigns

> **Tip:** Use `-OutputMode Both` to get both console output for immediate review
> and JSON artifacts for archival and SIEM ingestion.

---

## Leadership Rollup Reports

Leadership rollups transform flat campaign data into hierarchical reports that match
your organization's management structure. Each leader sees only their portion of the
review.

### What they contain

- **Per-VP report:** aggregated decisions for all directors and managers in the VP's
  organization, with approval rates and exception counts
- **Per-director report:** department-level detail with per-manager breakdowns
- **Per-manager report:** individual decisions for each direct report

### Band classification

The toolkit maps org-tree depth to leadership bands:

| Band | Role Level | Org Depth | Report Content |
|---|---|---|---|
| **A** | President / CEO | 4+ above reviewed identity | Executive summary only |
| **B** | VP / SVP | 3 above reviewed identity | Aggregated division rollup |
| **C** | Director | 2 above reviewed identity | Department-level detail |
| **D** | Manager | 1 above reviewed identity | Direct-report individual decisions |
| **E** | Individual Contributor | 0 (the reviewed identity) | Not a report recipient |

Band mapping is configured in `Leadership.DefaultBandMapping` in `settings.json`.

### Org chart depth configuration

The `-LeadershipDepth` parameter controls how many levels above the reviewed identity
the toolkit walks when building the org tree:

| Depth | Result |
|---|---|
| 1 | Manager only (band D) |
| 2 | Manager + Director (bands D, C) |
| 3 | Manager + Director + VP (bands D, C, B) |
| 4 | Full hierarchy up to President (bands D, C, B, A) |

### How to generate

```powershell
# Generate leadership rollups with the audit (combined run)
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30 `
    -IncludeLeadershipRollup -LeadershipDepth 3

# Standalone distribution with preview
.\Scripts\Invoke-SPReportDistribution.ps1 -Status COMPLETED -DaysBack 30 -PreviewOnly

# Send reports to leaders via SMTP
.\Scripts\Invoke-SPReportDistribution.ps1 -Status COMPLETED -SendReports -TargetBands B,C
```

### Report distribution

`Invoke-SPReportDistribution.ps1` handles the delivery of leadership reports:

| Parameter | Description |
|---|---|
| `-PreviewOnly` | Show who-gets-what without generating or sending |
| `-SendReports` | Generate and email each report via SMTP |
| `-TargetBands <letters>` | Limit delivery to specific bands (e.g., `B,C` for VPs and directors) |
| `-OrgSupplementPath <csv>` | Override ISC's org tree with a supplement CSV for gap-filling |

> **Tip:** Always run with `-PreviewOnly` first to verify the distribution plan.
> Sending a VP's report to the wrong person is a governance incident.

---

## Daily Evidence Reports (V4 / V4b / V7)

The daily evidence pipeline is the primary compliance and governance reporting tool for
organizations running daily privileged role attestation campaigns. It consists of three
scripts that work together:

- **V4 / V4b** = the data engine (fetches from ISC, generates HTML evidence, writes `daily-metrics.jsonl`)
- **V7** = the trending visualizer (reads `daily-metrics.jsonl`, renders calendar-day charts -- no API calls)

### Architecture

```
ISC API --> V4/V4b --> cache + snapshots + daily-metrics.jsonl --> V7 trending charts
                  \--> HTML evidence report (per-campaign detail)
```

V4/V4b calls the ISC API, processes items through `idNowAutoApproved` detection
(reclassifies force-closed auto-approved items as Undecided), maps items to reviewers
via certification ID, and writes honest per-reviewer data to `daily-metrics.jsonl`.
V7 reads that JSONL and renders calendar-day-oriented charts with one data point per
day -- no duplicate labels, no API calls.

### Running the daily pipeline

```powershell
# Step 1: V4b generates evidence + JSONL (uses cache if valid)
.\Scripts\Invoke-SPDailyEvidenceReportV4b.ps1 -DaysBack 18 -OutputMode Both

# Step 2: V7 generates trending visualization from JSONL
.\Scripts\Invoke-SPDailyEvidenceReportV7.ps1 -DaysBack 18 -OutputMode Both

# V7 with exact date range
.\Scripts\Invoke-SPDailyEvidenceReportV7.ps1 -StartDate '2026-06-15' -EndDate '2026-06-19' -OutputMode Both
```

### Cache management

V4/V4b uses a two-layer items cache (memory + disk) to avoid re-fetching from ISC
on every run. Three modes:

| Flag | Behavior | When to Use |
|---|---|---|
| *(default)* | Read from cache if valid, write on miss | Normal daily runs |
| `-NoCache` | Skip cache read AND write; existing cache preserved | Comparing fresh vs cached side-by-side |
| `-RefreshCache` | Skip cache read, fetch fresh, overwrite cache with new data | After reviewers sign off; need real-time numbers AND updated cache |

The cache also includes **seal-on-transition**: if a campaign was ACTIVE when cached
but is now COMPLETED, the cache is automatically sealed as permanent. This preserves
the honest ACTIVE-state data and prevents ISC's post-completion inflation from
overwriting it.

**Provenance & freshness.** A campaign first seen *after* it already COMPLETED has no honest
ACTIVE-state capture to preserve, so V4/V4b stamp it `Unverified` and the report shows a red
**"⚠ no active-state capture — completion unverified"** banner — run the daily capture *while
campaigns are ACTIVE* to avoid it. The ACTIVE-cache TTL (`Audit.CacheActiveTtlMinutes`, default 180
min) can optionally **shrink near a deadline** via `Audit.NearDeadlineCapture`
(`Enabled` / `WindowMinutes` 1440 / `TtlMinutes` 15) to capture a fresher final picture. The
`captureDate` time axis defaults to the campaign's created date (campaign-to-campaign); pass
`-PerRunDay` to switch V4/V4b to a per-run-day axis for a single long-running campaign.

### Key ISC behaviors handled

| ISC Behavior | How Toolkit Handles It |
|---|---|
| Force-completion auto-approves remaining items with `decision: "APPROVE"` | `Group-SPAuditDecisions` checks `comments` for `idNowAutoApproved`; reclassifies to Undecided |
| Force-completion inflates cert `decisionsMade` to match `decisionsTotal` | Per-reviewer JSONL data computed from item-level counts, not cert-level |
| Force-completion sets all certs to `phase: SIGNED` | Reviewer % computed from item-level `pending=0`, not cert `Phase` |
| `reviewedBy` is `null` on undecided / auto-approved items | Undecided items are attributed to the **cert-assigned reviewer** via a cert-to-reviewer roster **sealed at ACTIVE state** (keyed on ISC identity ID), not the empty `reviewedBy` — so COMPLETED campaigns name the accountable reviewer instead of collapsing to `(Unassigned)` |
| `decision` is `null` on unsigned reviewer items (ACTIVE campaigns) | Items correctly classified as Undecided/Pending |

### V4b report sections

| Section | Content |
|---|---|
| **KPI Dashboard** | 6 governance KPIs (completion, overdue, revocations, remediation, high-risk, reviewer health) with domino chain |
| **Executive Summary** | Per-campaign donut chart (Approved/Revoked/Undecided), reviewer sign-off, deprovisioning status |
| **A. Campaign Completion Evidence** | Per-campaign table: Status, Total, Approved, Revoked, Undecided, Items %, Reviewer %, Created, Completed |
| **B. Reviewer Accountability** | ACTIVE: unsigned reviewers (cert `Phase`). COMPLETED: undecided items attributed to the **cert-assigned reviewer** from the ACTIVE-sealed roster (no `(Unassigned)` collapse) |
| **Decision Summary** | Revoked register with remediation status, New Scope -- Approved Access |

### V7 report sections

| Section | Content |
|---|---|
| **KPI Banner** | Completion %, Approved, Revoked, Undecided, Reviewers, Priv Pending, N-Day Change, Days to Deadline |
| **Completion Progression** | SVG line chart showing completion % per calendar day |
| **Decision Distribution** | Stacked bars (Approved/Revoked/Undecided) per day |
| **Per-Reviewer Accountability** | Direction arrows, first/yesterday/today completion, stalled detection |
| **Reviewer Activity Heatmap** | 180-row x N-day SVG grid; absolute decisions per day; inactive rows in red |
| **Completion Projection** | Velocity-based linear projection with 3-day + N-day velocity labels |
| **Campaign Completion Evidence** | Merged table: Day, Campaign, Status, Total, Approved, Revoked, Undecided, Items %, Reviewer %, Decided +/-, Completion +/- |
| **Decision Activity Stacked Bars** | Revoked + Newly Decided + New Scope per day with cumulative line |
| **Cross-Campaign Risk Matrix** | Only renders for mixed campaign types (hidden for daily recurring) |
| **Reviewer Completion Progression** | Side-by-side bars: Items Decided % vs Reviewers Completed % |
| **Source-Level Completion** | Per-source table: AD, AWS, ServiceNow, SAP with thermometer bars |
| **Decision Velocity** | Day-over-day delta chart (approved/revoked/undecided changes) |
| **Reviewer Compliance Accountability** | Categorized: Never Complied, Absent/Unreassigned, At Risk, Compliant |

### Terminology

The toolkit uses **"Undecided"** (not "Pending") in all HTML output to match SailPoint
ISC's GUI terminology. Internally, variables still use `$pending` / `$d['Pending']`
for backward compatibility.

### Output files

| File | Written By | Read By | Content |
|---|---|---|---|
| `daily-evidence-v4b-{timestamp}.html` | V4b | Human | Per-campaign evidence HTML |
| `daily-evidence-v4b-{timestamp}_fresh.html` | V4b with `-NoCache` | Human | Fresh-data variant |
| `daily-evidence-v7-{prefix}-{timestamp}.html` | V7 | Human | Calendar-day trending HTML |
| `Audit/metrics/daily-metrics.jsonl` | V4/V4b | V7 | Per-campaign JSONL records |
| `Audit/.cache/items-{campaignId}.jsonl` | V4/V4b | V4/V4b (cache) | Cached ISC items per campaign |
| `Audit/.cache/items-{campaignId}.meta.json` | V4/V4b | V4/V4b (cache) | Cache metadata (TTL, status, seal) |
| `Audit/Snapshots/{campaignId}/*.json` | V4/V4b | Diff engine | Per-campaign snapshot for cross-campaign diff |

---

## State-Powered Evidence (V8)

V8 reads from pre-computed state files (`entitlement-state.jsonl` + `reviewer-state.jsonl`)
for fast, accurate reporting without ISC API calls. Target execution: <30 seconds.

### Running V8

```powershell
# Daily evidence (auto-refreshes state files if stale)
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -OutputMode Both

# June only
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -StartDate '2026-06-01' -EndDate '2026-06-30'

# Filter to Daily Attestation series
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -CampaignNameContains 'Daily'

# Read-only (no state file refresh)
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -NoRefresh
```

### V8 report sections

| Section | Content |
|---|---|
| **1. Entitlement State Summary** | KPI tiles: Approved / Revoked / Pending / Undecided with percentages |
| **1b. Privileged Access Summary** | Privileged KPIs: total, approved, revoked, exposure (pending+undecided). Per-source breakdown (AD, AWS, ServiceNow, SAP) with decided % per source |
| **2. Newly Decided** | Entitlements with PENDING/UNDECIDED -> decision transition in the date window. Includes the **Re-Approved After Revoke** sub-table: observed REVOKE -> APPROVE re-grants in the window, with the revocation day mined from each record's state log |
| **3. Chronically Unreviewed** | Items with consecutive undecided campaigns >= threshold (default 5) |
| **4. Dropped from Scope** | Entitlements no longer in any active campaign |
| **5. Reviewer Engagement Summary** | Engagement score table + KPI tiles |
| **6. Reviewer Weekly Compliance** | Current ISO week misses per reviewer |
| **7. Reviewer Engagement Heatmap** | 14-day dayLog grid (C/P/M/U per day) |
| **8. Campaign Summary** | Per-day metrics from daily-metrics.jsonl |

### Prerequisites

V8 requires state files. Populate them with:
```powershell
# Option 1: V8 auto-refreshes on first run (default)
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1

# Option 2: Explicit state update
.\Scripts\Update-SPStateFiles.ps1
```

---

## Governance Trend Dashboard (Monthly Scraper)

Produces leadership-ready monthly governance metrics by scraping existing daily
evidence HTML reports. No API calls -- reads the reports you already generate.

### Running the trend dashboard

```powershell
# June monthly
.\Scripts\Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-06-01' -Until '2026-06-30'

# Two-month comparison with MoM deltas
.\Scripts\Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-05-01' -Until '2026-06-30'

# Custom report folder
.\Scripts\Invoke-SPGovernanceTrendScrape.ps1 -Path 'C:\Reports' -Since '2026-06-01'
```

### Dashboard sections

| Section | Content |
|---|---|
| **Executive KPI Cards** | Campaign days, avg completion, avg reviewer %, revoked items, new scope, priv undecided, revoke rate |
| **Decision Distribution** | Stacked bar chart (approved/revoked/undecided per day) |
| **Completion + Reviewer Trend** | Dual-axis line chart (items decided % + reviewer completed %) |
| **Month-over-Month** | Table with trend arrows (only when data spans 2+ months) |
| **Campaign Detail** | Per-day breakdown with color-coded completion and status |

---

## Pending Reviewer Tracker (Scraper)

Identifies chronic non-compliant reviewers and detects gaming patterns by scraping
daily evidence HTML reports.

### Running the tracker

```powershell
# Default (auto-MinMisses based on campaign count)
.\Scripts\Invoke-SPPendingReviewerScrape.ps1 -Path .\Audit\daily-evidence -Since '2026-06-01'

# Explicit threshold
.\Scripts\Invoke-SPPendingReviewerScrape.ps1 -MinMisses 3 -Top 25

# Override file pattern for V4e reports
.\Scripts\Invoke-SPPendingReviewerScrape.ps1 -FilePattern 'daily-evidence-v4e-*.html'
```

The default `-FilePattern` matches the production V4b output (`daily-evidence-v4b-*.html`)
plus the legacy/mock name (`Daily-Attestation-Evidence-Report-*.html`); pass one or more
patterns to override. Streaks count consecutive REPORT days, so weekends and holidays with
no report do not reset a run; a completed day does. Reviewer names are resolved from each
table's header row (V4d-style item tables fall back to their subhead names), and
placeholder rows (`N/A`, "No undecided reviewers.", V4e empty-state rows) are filtered.

### Auto-MinMisses

| Report Days Found | Default MinMisses |
|---|---|
| 1-5 | 1 (show all) |
| 6+ | 3 (focus on chronic) |

### Gaming pattern detection (> 5 campaigns)

| Pattern | What It Catches |
|---|---|
| **Alternating** | Miss-complete-miss (avoids streak flags) |
| **Day-of-week** | Always misses same day (shift worker or gaming) |
| **Declining** | Strong start, tapering off |
| **Burst compliance** | Long idle then single completion before escalation |
| **Bare minimum** | 30-59% miss rate (borderline) |

Each reviewer gets a composite gaming score (0-100) and risk label:
Monitor (<30), Concerning (30-59), High Risk (60+).

---

## Decision Activity Tracker (Scraper)

Summarizes revoked and newly approved access decisions by scraping the same daily
evidence HTML reports. Like the Pending Reviewer Tracker it is read-only and
dependency-free: no ISC API, no cache.

### Critical semantics: cumulative snapshots and decision dates

The V4b registers are CUMULATIVE campaign snapshots -- every daily report re-lists all
revocations and new-scope approvals made so far, and each row carries the item's own
Decision Date. The scraper therefore:

- **De-duplicates** items across the window (identity + access + source + reviewer +
  decision date; first sighting wins). Without this, a 30-day window counted every
  revocation once per day it survived in the register.
- **Buckets by each item's own Decision Date**, not the report file's date -- a June 25
  report contributes decisions to June 8-24 buckets if that is when they were decided.
  The decision-day window can therefore start before the first report file.
- **Scrapes the approved campaign-to-date total** from the campaign summary table when
  present (latest snapshot plus growth across the window).

### Running the tracker

```powershell
# Default limits (500 detail rows, 15 ranking rows)
.\Scripts\Invoke-SPDecisionScrape.ps1 -Path .\Audit\daily-evidence -DaysBack 30

# Explicit window and larger detail registers
.\Scripts\Invoke-SPDecisionScrape.ps1 -Since '2026-07-01' -Until '2026-07-31' -Top 2000
```

### Dashboard contents

| Section | Content |
|---|---|
| **Decision Activity Summary** | KPI tiles: distinct revoked, distinct new scope, approved campaign-to-date (when scrapeable), net change, report days, decision days, per-decision-day averages |
| **Daily Decision Trend** | Three adaptive charts on one aligned date axis -- combined paired red/green, revoked-only, new-scope-only -- plus a raw per-day numbers table. Bar width and date-label density adapt to the window (15-90+ days); labels rotate below the axis |
| **Revoked Access Register** | Collapsible detail (capped at 500 rows by default; `-Top` overrides, truncation disclosed) |
| **Top Revoked Entitlements / Identities** | Risk concentration rankings |
| **New Scope Detail** | Collapsible register of truly new approved access |
| **Source Breakdown** | Revoked vs new scope per source system |

Note: "Newly Decided" approvals of pre-existing items are intentionally excluded from
New Scope and Net Change -- that signal belongs to the V4g/V8 state pipeline.

---

## Delta Certification Reports

The daily delta report is the operations team's primary tool for understanding what
changed in the last 24 hours across monitored AD sources.

### What they contain

- **New grants:** accounts that received new entitlements (groups, roles)
- **Revocations:** entitlements removed from accounts
- **Pending certifications:** delta-cert campaigns that are still awaiting reviewer action
- **Anomalies:** unusual patterns (bulk grants, after-hours changes, service account modifications)

### How to generate

```powershell
# Standard daily report
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -Token $jwt

# Extended look-back (catch up after a missed day)
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 48

# Multiple sources
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001','src-ad-002'
```

### Who gets them

- **Governance operations team:** daily review of access changes
- **Security operations:** anomaly detection (piped to SIEM via JSONL)
- **IAM managers:** awareness of change volume and patterns

### Frequency

Daily, typically generated by the orchestrator as step 4. The HTML report is written
to `DeltaCert/reports/` and the JSONL to the same directory for SIEM pickup.

---

## Disconnected App Reports

Disconnected-app reporting is integrated into the batch processing pipeline. These
reports are generated automatically during batch runs.

### Delta summary

Per-app HTML report showing what changed in today's CSV delivery:

- Accounts added, removed, disabled, enabled
- Entitlements granted, revoked
- Attribute changes
- Identity correlation results (matched vs unmatched)

Generated in `DisconnectedApps/Reports/<AppName>/`.

### Batch summary

Aggregate report across all processed apps showing:

| Column | Content |
|---|---|
| App Name | Application identifier |
| Status | `Success`, `NoChanges`, `ThresholdBlocked`, `Error` |
| Changes | Count of detected changes by type |
| Campaigns | Number of campaigns created |
| Correlation | Matched vs unmatched account count |
| Duration | Processing time |

### Team dashboard

Per-app status page designed for distribution to the app team:

- Current delivery status (delivered/stale/missing/empty)
- 30-day delivery history with reliability percentage
- Open campaigns and completion status
- Pending and overdue remediations

### SLA compliance

30-day delivery history per app with:

- Delivery reliability percentage (target: 95%+)
- Remediation SLA compliance (revocations confirmed within `SlaDays`)
- Trend indicators (improving/declining/stable)

### How to generate

Disconnected-app reports are generated automatically as part of the batch run:

```powershell
# Reports are created during batch processing
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -Token $jwt -OutputMode Both

# Re-run a single app to regenerate its reports
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' `
    -AccountFilePath '\\fileserver\imports\PEP-Plus\accounts.csv' -Token $jwt
```

---

## Governance Health and Compliance

### Health check report

The governance health check assesses six dimensions of governance posture:

| Dimension | What It Checks | Grade Criteria |
|---|---|---|
| **Source Aggregation** | Are sources aggregating on schedule? | Stale sources (>48h) degrade the grade |
| **Data Quality** | Are identity attributes populated and consistent? | Orphan accounts, missing attributes |
| **Policy Compliance** | Are governance policies being followed? | Campaign coverage, SoD violations |
| **Config Drift** | Has the toolkit config changed from the baseline? | Unexpected safety setting changes |
| **Orphan Accounts** | Are there accounts not linked to an identity? | Orphan count as a percentage of total |
| **Campaign Coverage** | Have all sources been reviewed recently? | Sources without a campaign in 90 days |

Each dimension receives a pass/fail/warn status. The overall grade (A through F) is
a weighted composite.

```powershell
.\Scripts\Invoke-SPGovernanceHealthCheck.ps1 -OutputMode HTML
```

### Governance report (combined evidence package)

The "one report to rule them all" -- assembles audit, leadership rollup, policy
compliance, and data quality into one output directory with a manifest:

```powershell
.\Scripts\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 `
    -IncludeLeadershipRollup -IncludeDataQuality -IncludePolicyCheck `
    -DetailLevel Verbose
```

The output directory (`Reports/`) contains:

- Campaign audit reports (per-campaign HTML)
- Leadership rollup reports (per-leader HTML)
- Data quality report (HTML + JSON)
- Policy compliance report (HTML)
- A manifest file listing all artifacts with timestamps and SHA-256 hashes

### Data quality report

Focused assessment of identity data hygiene:

```powershell
.\Scripts\Invoke-SPDataQualityReport.ps1 -OutputMode HTML
```

| Dimension | Weight | What It Measures |
|---|---|---|
| Orphan Accounts | 40% | Accounts not correlated to any identity |
| Identity Attribute Quality | 35% | Completeness of key attributes (email, manager, department) |
| Source Aggregation Health | 25% | Freshness of source data |

Exit codes reflect the grade: 0 = A/B (healthy), 1 = C (needs attention),
5 = D/F (critical -- action required).

### Compliance evidence package

For external auditors, package the toolkit's output as compliance evidence:

1. Run the governance report with full options:
   ```powershell
   .\Scripts\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 `
       -IncludeLeadershipRollup -IncludeDataQuality -IncludePolicyCheck
   ```
2. Collect the `Reports/` output directory -- it includes a manifest with SHA-256
   hashes for integrity verification
3. Include the JSONL audit trail files from `Audit/` for machine-verifiable provenance
4. For compliance evidence, include the leadership rollup reports to demonstrate reviewer accountability

**Control mapping:**

| Control objective | Toolkit Evidence |
|---|---|
| Periodic access review / certification | Campaign Audit (Verbose) + Leadership Rollup |
| Segregation of duties | Adaptive SoD Baseline (`-BaselineReport sod`) |
| Logical access controls | Campaign Audit + Data Quality Report |
| Access reviewed prior to provisioning | Delta Report (daily new-grant certification) |
| Timely access removal | Remediation Tracking (Weekly Digest) |
| Review of access rights | Governance Report (full package) |
| Removal of access | Delta Report + Remediation Tracking |

---

## Analytics and BI Export

The toolkit generates data suitable for ingestion into Power BI, Tableau, Splunk,
and other analytics platforms.

### Governance metrics time series

`Invoke-SPGovernanceMetrics.ps1` captures KPIs to a JSONL time-series store and
generates trend reports:

```powershell
# Capture today's metrics (daily scheduled run)
.\Scripts\Invoke-SPGovernanceMetrics.ps1 -CaptureOnly

# Generate a 90-day trend report
.\Scripts\Invoke-SPGovernanceMetrics.ps1 -TrendOnly -TrendDaysBack 90 `
    -TrendGranularity Monthly -OutputMode HTML

# Full capture + trend + completion forecast
.\Scripts\Invoke-SPGovernanceMetrics.ps1 -IncludeCompletionForecast -OutputMode Both
```

**KPIs captured per period:**

| Metric | Description |
|---|---|
| Campaign completion rate | Percentage of campaigns completed within deadline |
| Average reviewer response time | Mean time from certification assignment to first decision |
| Approval rate | Percentage of items approved vs total decided |
| Revocation rate | Percentage of items revoked vs total decided |
| Pending items | Count of undecided access review items |
| Reviewer count | Unique reviewers active in the period |
| Source coverage | Percentage of sources covered by campaigns |
| Active campaign count | Campaigns currently ACTIVE or ACTIVATING |
| Completed campaign count | Campaigns completed in this period |
| Overdue campaign count | Active campaigns past their deadline |
| Avg days to complete | Average duration from campaign start to completion |
| Reviewer completion % | Average completion percentage across active reviewers |
| Reviewers not started | Reviewers with zero decisions made |

### Per-campaign trend enrichment

Each campaign snapshot also captures scope change and risk metrics in the
per-campaign JSONL time-series (`{CampaignTrendPath}/{env}/{campaignId}.jsonl`):

| Metric | Description |
|---|---|
| `scope.added` | Items added since last snapshot (new access entering scope) |
| `scope.removed` | Items removed since last snapshot |
| `scope.changed` | Items whose decision changed between snapshots |
| `scope.revokedItems` | Total items with REVOKE decision in this capture |
| `scope.totalSources` | Distinct sources in scope |
| `timing.daysSinceStart` | Days elapsed since campaign created |
| `timing.daysUntilDeadline` | Days remaining until deadline (negative if overdue) |
| `risk.privilegedApproved` | Privileged items with APPROVE decision |
| `risk.privilegedTotal` | Total privileged items in scope |

### Governance trend dashboard

The toolkit produces a single-page HTML governance dashboard with KPI cards, inline
SVG sparklines (no JavaScript), direction indicators, and alert callouts:

```powershell
# Generate dashboard data + render HTML
$data = Get-SPGovernanceDashboardData -Period Last30Days
Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath '.\Reports\'

# With period-over-period comparison
$comparison = Compare-SPGovernancePeriods -Period1 '2026-05' -Period2 '2026-06'
Export-SPGovernanceDashboardHtml -DashboardData $data -PeriodComparison $comparison `
    -OutputPath '.\Reports\'

# Check for governance alerts (declining metrics, overdue campaigns)
Get-SPGovernanceAlerts -LookbackDays 30
```

The dashboard HTML uses inline CSS only (Word/email compatible), with CSS-triangle
direction arrows and inline SVG sparkline bar charts. No external dependencies.

### Campaign comparison

Compare two or more campaigns side-by-side for trend analysis:

```powershell
.\Scripts\Invoke-SPCampaignSearch.ps1 -CompareIds 'camp-q1','camp-q2' -OutputMode CSV
```

### Dashboard data export

The governance report optionally exports dashboard-ready data:

```powershell
.\Scripts\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90
```

Unless `-SkipDashboardExport` is specified, this writes structured JSON suitable
for Power BI or Tableau import alongside the HTML reports.

### JSONL for SIEM ingestion

Every toolkit operation writes structured JSONL to `Audit/` and `Logs/`. These
files are designed for SIEM ingestion:

- **Audit trail JSONL:** per-decision evidence with full provenance
- **Daily log JSONL:** structured operational events with severity, component,
  action, and correlation ID
- **Delta report JSONL:** per-change events for real-time access monitoring

> **Tip:** Point your SIEM file collector at the `Audit/` and `Logs/` directories.
> The JSONL format parses cleanly in Splunk, Elastic, and Azure Sentinel without
> custom parsers.

---

## Adaptive Reports

Adaptive reports are composable, themeable HTML reports that provide rich
visualizations over governance data. They sit alongside (not replace) the standard
reports.

### What they are

The adaptive report engine provides two capabilities:

1. **Composable components:** KPI cards, heatmap, top-N bar chart, drill-down tree,
   group table -- mix and match to build custom dashboards
2. **Baseline report library:** 7 pre-built reports covering common governance
   analysis needs

### Baseline reports

| Code | Report Name | Audience | Frequency | What It Shows |
|---|---|---|---|---|
| `inventory` | Entitlement Inventory | Access review | On-demand | Full inventory of entitlements, access profiles, and roles with assignment counts |
| `privileged` | Privileged Access Review | Security | Quarterly | Privileged entitlements with holder details and review status |
| `orphaned` | Orphaned/Disabled Access | IAM operations | Monthly | Disabled or orphaned accounts that still have active entitlements |
| `sod` | Separation of Duties | Compliance | Quarterly | Toxic entitlement combinations across identities |
| `roster` | Certification Roster | Certification admin | On-demand | All certifications with reviewer assignments and completion status |
| `access-cert` | Access Cert Attestation | Compliance | After campaigns | Per-identity attestation of all access decisions |
| `exec-summary` | Governance Executive Summary | Executives | Quarterly | High-level governance KPIs with trend indicators |

### How to generate

```powershell
# Composable dashboard with selected components
.\Scripts\Invoke-SPAdaptiveReport.ps1 `
    -Anchor Entitlement `
    -Components kpi-cards,heatmap,top-n,group-table `
    -DaysBack 180

# Multiple baseline reports
.\Scripts\Invoke-SPAdaptiveReport.ps1 `
    -BaselineReport inventory,privileged,exec-summary `
    -DaysBack 180

# All baseline reports, dark theme
.\Scripts\Invoke-SPAdaptiveReport.ps1 `
    -BaselineReport all `
    -Theme dark `
    -CreatedAfter 2026-01-01 -CreatedBefore 2026-03-31

# Campaign-centric view (campaigns as groups)
.\Scripts\Invoke-SPAdaptiveReport.ps1 `
    -Anchor Campaign `
    -BaselineReport roster,exec-summary
```

### Theme support

| Theme | Use Case |
|---|---|
| `light` (default) | Standard reports, printing, email distribution |
| `dark` | Presentation mode, dashboard screens, executive briefings |

Reports are written to `Audit/adaptive/` by default.

---

## Weekly and Periodic Reports

### Weekly governance digest

A consolidated weekly summary covering six sections:

| Section | Content |
|---|---|
| **Campaign Activity** | New campaigns, completions, deadline status across the week |
| **Governance Health** | Current health check grade and dimension scores |
| **Identity Risk** | High-risk identities, excessive access, new privileged grants |
| **Reviewer Performance** | Response times, completion rates, anti-rubber-stamping metrics |
| **Remediation Tracking** | Pending, confirmed, and overdue remediations per app |
| **Orchestrator Reliability** | Daily orchestrator run statuses and error summary |

### How to generate

```powershell
# Standard weekly digest
.\Scripts\Invoke-SPWeeklyDigest.ps1 -OutputMode HTML

# With notification delivery
.\Scripts\Invoke-SPWeeklyDigest.ps1 -SendNotification -NotifyRecipients 'gov-team@corp.com'

# Skip sections you don't need
.\Scripts\Invoke-SPWeeklyDigest.ps1 -SkipIdentityRisk -SkipReviewerAnalysis -OutputMode HTML
```

### Scheduling

Schedule the weekly digest via Task Scheduler or cron to run every Monday morning
after the daily orchestrator completes:

```powershell
# Task Scheduler action (example)
powershell.exe -ExecutionPolicy Bypass -File "C:\Toolkit\Scripts\Invoke-SPWeeklyDigest.ps1" `
    -ConfigPath "C:\Toolkit\Config\settings.local.json" -OutputMode HTML -SendNotification
```

---

## Daily Evidence Script Quick Reference

### Execution order and dependencies

```
   ISC API
      |
      v
  Invoke-SPCachePopulate (module function, shared cache population)
      |
      +---> V4b (calls cache populate internally + daily-metrics.jsonl + HTML)
      |
      +---> V4e (read-only, series engine, stable scope key)
      |          requires: items cache
      |
      +---> V7 (calendar-day visualization from daily-metrics.jsonl)
      |          requires: daily-metrics.jsonl from V4b
      |
      +---> Update-SPStateFiles (populate entitlement-state + reviewer-state)
      |          requires: items cache
      |
      +---> V8 (state-powered report)
                 - auto-refreshes state files from cache if stale
                 - with -AutoFetch: auto-populates cache from ISC if empty
                 - single entry point: V8 -AutoFetch -Token <t> does everything

  HTML report files (from any of the above)
      |
      +---> Governance Trend Scraper (monthly dashboard from HTML files)
      +---> Pending Reviewer Scraper (chronic non-compliance from HTML files)
```

**V8 single entry point** (new): With `-AutoFetch`, V8 detects an empty cache
and calls `Invoke-SPCachePopulate` to fetch from ISC before proceeding. Without
`-AutoFetch`, V8 behaves identically to before (read-only from existing data).

### Script summary

| Script | Purpose | Calls ISC? | Writes Cache? | Prerequisites | Key Output |
|---|---|---|---|---|---|
| `Invoke-SPDailyEvidenceReportV4b.ps1` | Daily evidence with KPI dashboard, reviewer accountability, revoked register, new scope | YES | YES | ISC token/config | HTML + daily-metrics.jsonl |
| `Invoke-SPDailyEvidenceReportV4e.ps1` | Series-aware attestation delta with stable scope key. Honest newly-attested + decision transitions | NO | NO | Items cache (from V4b) | HTML |
| `Invoke-SPDailyEvidenceReportV7.ps1` | Calendar-day trending visualization with charts | NO | NO | daily-metrics.jsonl (from V4b) | HTML |
| `Invoke-SPDailyEvidenceReportV8.ps1` | State-powered report: entitlement + reviewer state, privileged breakdown, chronic unreviewed, weekly compliance | NO (auto-refresh from cache) | State files | State files or items cache | HTML |
| `Update-SPStateFiles.ps1` | Populate/refresh entitlement-state.jsonl + reviewer-state.jsonl from cache | NO | State files | Items cache (from V4b) | JSONL state files |
| `Invoke-SPGovernanceTrendScrape.ps1` | Monthly governance dashboard from existing HTML reports | NO | NO | HTML report files | HTML dashboard |
| `Invoke-SPPendingReviewerScrape.ps1` | Chronic pending reviewer tracker with gaming detection | NO | NO | HTML report files | HTML dashboard |
| `Invoke-SPDeltaCertEscalate.ps1` | Reviewer escalation with org hierarchy | YES | NO | ISC token/config | HTML + CSV + TXT |

### Common workflows

**Daily morning run:**
```powershell
.\Scripts\Invoke-SPDailyEvidenceReportV4b.ps1 -DaysBack 18 -OutputMode Both
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -OutputMode Both
```
V4b fetches from ISC and populates cache + JSONL. V8 auto-refreshes state files
from the cache and generates the state-powered report. No need to run V4e/V7
separately unless you want those specific views.

**Weekly leadership report:**
```powershell
.\Scripts\Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-07-21' -Until '2026-07-25'
.\Scripts\Invoke-SPPendingReviewerScrape.ps1 -Since '2026-07-21'
```

**Monthly compliance report:**
```powershell
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -StartDate '2026-06-01' -EndDate '2026-06-30' -CampaignNameContains 'Daily'
.\Scripts\Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-06-01' -Until '2026-06-30'
```

**Fresh data (stale cache or after force-close):**
```powershell
.\Scripts\Invoke-SPDailyEvidenceReportV4b.ps1 -DaysBack 18 -RefreshCache -OutputMode Both
```

---

## Choosing the Right Report

Use this decision tree to find the right report for your situation.

### "I need evidence for auditors"

1. `Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 -IncludeLeadershipRollup -IncludeDataQuality -IncludePolicyCheck` -- full evidence package
2. `Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DetailLevel Verbose` -- per-campaign deep dive
3. `Invoke-SPAdaptiveReport.ps1 -BaselineReport sod` -- separation of duties analysis

### "My VP wants a dashboard"

1. `Invoke-SPAdaptiveReport.ps1 -BaselineReport exec-summary -Theme dark` -- executive summary
2. `Invoke-SPReportDistribution.ps1 -Status COMPLETED -TargetBands B -PreviewOnly` -- VP-level rollup (preview first)
3. `Invoke-SPGovernanceHealthCheck.ps1 -OutputMode HTML` -- governance posture snapshot

### "What changed today?"

1. `Invoke-SPDeltaReport.ps1 -SourceId <ids>` -- AD source changes (grants, revocations)
2. Check `DisconnectedApps/Reports/<AppName>/` for disconnected-app delta summaries
3. Review `Logs/GovernanceToolkit-<today>.log` for the orchestrator summary

### "Are my reviewers doing their job?"

1. `Invoke-SPDailyEvidenceReportV8.ps1` -- Section 5-7: engagement score, weekly compliance, heatmap (state-powered, most current)
2. `Invoke-SPPendingReviewerScrape.ps1 -Since '2026-06-01'` -- chronic non-compliance tracker with gaming pattern detection
3. `Invoke-SPCampaignAudit.ps1 -Status ACTIVE -DetailLevel Detailed` -- reviewer accountability section
4. `Invoke-SPCampaignSearch.ps1 -ReviewerIdentityId <id>` -- per-reviewer workload analysis

### "What's the privileged access exposure?"

1. `Invoke-SPDailyEvidenceReportV8.ps1` -- Section 1b: privileged breakdown by source (AD/AWS/ServiceNow/SAP) with decided %
2. `Invoke-SPDailyEvidenceReportV4e.ps1 -SeriesName 'Daily'` -- series-aware privileged items with honest newly-attested

### "Give me a monthly trend for leadership"

1. `Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-06-01' -Until '2026-06-30'` -- monthly dashboard with KPIs, charts, MoM comparison
2. `Invoke-SPDailyEvidenceReportV7.ps1 -StartDate '2026-06-01' -EndDate '2026-06-30'` -- calendar-day visualization
3. `Invoke-SPDailyEvidenceReportV8.ps1 -StartDate '2026-06-01' -EndDate '2026-06-30'` -- state-driven with privileged breakdown

### "Which apps haven't been reviewed?"

1. `Invoke-SPCampaignSearch.ps1 -SourceCoverage -OutputMode HTML` -- source coverage gap analysis
2. `Invoke-SPGovernanceHealthCheck.ps1 -OutputMode HTML` -- campaign coverage dimension
3. `Invoke-SPDisconnectedAppRegistry.ps1 -Action List` -- registered apps vs actively processing

### "I need data for Power BI"

1. `Invoke-SPGovernanceMetrics.ps1 -CaptureOnly` -- capture today's KPIs to JSONL time series
2. `Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90` -- structured JSON + dashboard export
3. `Invoke-SPCampaignSearch.ps1 -ShowMetrics -OutputMode CSV` -- campaign metrics as CSV
4. Point Power BI at `Audit/metrics/` (JSONL) and `Reports/` (JSON) for automated refresh

### "Are revocations actually being carried out?"

1. `Invoke-SPWeeklyDigest.ps1 -OutputMode HTML` -- remediation tracking section
2. `Invoke-SPCampaignAudit.ps1 -DetailLevel Verbose` -- section 6 (remediation proof) per campaign
3. Query `Audit/` JSONL for `Action=RemediationCheck` entries with `Status=Pending` or `Status=Overdue`
