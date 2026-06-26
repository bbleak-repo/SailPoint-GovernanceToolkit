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
| Daily Evidence Report (v4b) | `Invoke-SPDailyEvidenceReportV4b.ps1` | CISO, auditors, IAM ops | Daily | Fork of V4 with bug fixes: donut chart, N/A reviewer warning, item-level reviewer %. Same features as V4 | HTML, JSON, JSONL |
| Daily Evidence Trending (v7) | `Invoke-SPDailyEvidenceReportV7.ps1` | CISO, leadership, IAM ops | Weekly / on-demand | Calendar-day visualization: completion progression, decision distribution, reviewer heatmap, compliance accountability, source-level breakdown. Reads daily-metrics.jsonl (no API calls) | HTML |
| Escalation Report | `Invoke-SPDeltaCertEscalate.ps1` | IAM ops, managers | Daily | Late reviewer escalation with org hierarchy, per-manager HTML, email routing CSV | HTML, CSV, TXT |
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

### Key ISC behaviors handled

| ISC Behavior | How Toolkit Handles It |
|---|---|
| Force-completion auto-approves remaining items with `decision: "APPROVE"` | `Group-SPAuditDecisions` checks `comments` for `idNowAutoApproved`; reclassifies to Undecided |
| Force-completion inflates cert `decisionsMade` to match `decisionsTotal` | Per-reviewer JSONL data computed from item-level counts, not cert-level |
| Force-completion sets all certs to `phase: SIGNED` | Reviewer % computed from item-level `pending=0`, not cert `Phase` |
| `reviewedBy` is `null` on auto-approved items | Cert-to-reviewer mapping resolves orphaned items via CertificationId + CertificationName fallback |
| `decision` is `null` on unsigned reviewer items (ACTIVE campaigns) | Items correctly classified as Undecided/Pending |

### V4b report sections

| Section | Content |
|---|---|
| **KPI Dashboard** | 6 governance KPIs (completion, overdue, revocations, remediation, high-risk, reviewer health) with domino chain |
| **Executive Summary** | Per-campaign donut chart (Approved/Revoked/Undecided), reviewer sign-off, deprovisioning status |
| **A. Campaign Completion Evidence** | Per-campaign table: Status, Total, Approved, Revoked, Undecided, Items %, Reviewer %, Created, Completed |
| **B. Reviewer Accountability** | ACTIVE: unsigned reviewers. COMPLETED: reviewers with undecided items (from item-level data) |
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

1. `Invoke-SPCampaignAudit.ps1 -Status ACTIVE -DetailLevel Detailed` -- reviewer accountability section
2. `Invoke-SPWeeklyDigest.ps1 -OutputMode HTML` -- reviewer performance section
3. `Invoke-SPCampaignSearch.ps1 -ReviewerIdentityId <id>` -- per-reviewer workload analysis
4. `Invoke-SPCampaignSearch.ps1 -ShowMetrics -ShowDeadlines` -- campaign-level KPIs with deadline urgency

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
