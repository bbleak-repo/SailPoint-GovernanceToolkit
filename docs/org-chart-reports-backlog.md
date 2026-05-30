# Org Chart & Report Distribution -- Backlog (OC-01 to OC-10)

**Created:** 2026-05-29
**Prereqs:** Leadership reports (L-01 to L-08), DA-21 to DA-30 (production features)
**Purpose:** Org chart visibility, report distribution preview, and supplemental org data

---

## How to Use This File

Agent loop: `OC-01 -> OC-02 -> OC-03 -> OC-04 -> OC-05 -> OC-06 -> OC-07 -> OC-08 -> OC-09 -> OC-10`

---

## Context

Leadership reports depend on ISC's manager chain data (from HR/AD). When ISC's org data
is incomplete (missing senior leaders, gaps in manager chains), reports show truncated
trees. Additionally, users want to PREVIEW the org structure and report distribution
before running campaigns -- "who would receive what?" -- without actually creating
campaigns or sending emails.

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| OC-01 | Org Chart Supplement Import (CSV override) | none | DONE |
| OC-02 | ASCII Org Tree Renderer (terminal visualization) | none | DONE |
| OC-03 | Campaign Org Chart Preview | OC-02 | DONE |
| OC-04 | Report Distribution Preview | OC-03 | DONE |
| OC-05 | Org Chart HTML Export (visual tree report) | OC-02 | DONE |
| OC-06 | Band/Level Classification Engine | OC-01 | DONE |
| OC-07 | Per-Band Leadership Reports | OC-06 | PENDING |
| OC-08 | Report Distribution CLI (Invoke-SPReportDistribution.ps1) | OC-04 | PENDING |
| OC-09 | Org Chart Gap Detector | OC-01 | PENDING |
| OC-10 | Pester Tests | OC-09 | PENDING |

---

## OC-01: Org Chart Supplement Import

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
When ISC's manager chain data is incomplete (no HR feed, AD gaps at senior levels),
allow importing a supplemental org chart CSV that overrides or fills gaps in the
identity-to-manager mapping used by `Build-SPOrgTree`.

The supplement is for REPORT GENERATION ONLY -- it does not modify ISC identity records.

**Supplement CSV format** (`Config/org-chart-supplement.csv`):
```csv
identityEmail,managerEmail,level,title,band
john.smith@corp.com,jane.manager@corp.com,IC,Software Engineer,E
jane.manager@corp.com,bob.director@corp.com,Manager,Engineering Manager,D
bob.director@corp.com,alice.vp@corp.com,Director,Director of Engineering,C
alice.vp@corp.com,richard.pres@corp.com,VP,VP of Technology,B
richard.pres@corp.com,,President,President & CEO,A
```

**Band convention:**
- **A** = C-suite / President
- **B** = SVP / VP
- **C** = Director
- **D** = Manager / Sr. Manager
- **E** = Individual Contributor

**Function:** `Import-SPOrgChartSupplement`
- Input: `-FilePath` (path to supplement CSV)
- Validates: required columns, email format, no circular references
- Builds: hashtable keyed by email -> {managerEmail, level, title, band}
- Returns: `@{Success; Data=@{Entries; Conflicts; Gaps}; Error}`

**Function:** `Merge-SPOrgTreeWithSupplement`
- Input: org tree from `Build-SPOrgTree` + supplement data
- For each identity in the tree: if supplement has a manager override, use it
- For identities NOT in ISC but IN the supplement: add them as synthetic nodes
- Returns: enriched org tree

**Files to Create:**
- `Config/org-chart-supplement.csv` -- template with example rows
- New functions in `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` or new file

**Config addition:**
```json
"Leadership": {
    "OrgChartSupplementPath": "",
    "UseSupplementForReports": false,
    "DefaultBandMapping": {
        "0": "E", "1": "D", "2": "C", "3": "B", "4": "A"
    }
}
```

**Acceptance Criteria:**
- Supplement CSV fills gaps where ISC has no manager
- ISC data takes precedence when both exist (supplement is fallback only)
- Circular reference detection prevents infinite loops
- Config toggle controls whether supplement is used

---

## OC-02: ASCII Org Tree Renderer

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Show-SPOrgTree` that renders the org tree as ASCII art in the terminal.
Useful for quick visualization without generating HTML reports.

**Example output:**
```
Richard Sterling (President) [Band A]
+-- Alice Johnson (VP of Engineering) [Band B]
|   +-- Diana Brown (Director, Eng Team 1) [Band C]
|   |   +-- Patricia Martin (Engineer) [Band E]
|   |   +-- Jack Green (Engineer) [Band E]
|   |   +-- ... (3 more)
|   +-- Fiona Garcia (Director, Eng Team 3) [Band C]
|   |   +-- ... (5 reports)
|   +-- George Miller (Director, Eng Team 4) [Band C]
|       +-- ... (5 reports)
+-- Bob Smith (VP of Operations) [Band B]
|   +-- Helen Davis (Director, Ops Team 1) [Band C]
|   |   +-- ... (5 reports)
|   +-- ... (3 more directors)
+-- Charlie Williams (VP of Security) [Band B]
    +-- ... (4 directors, 20 reports)

Summary: 1 President, 3 VPs, 12 Directors, 60 ICs
Depth: 4 levels | Unmanaged: 2 | Service Accounts: 2
```

**Function:** `Show-SPOrgTree`
```powershell
function Show-SPOrgTree {
    param(
        [Parameter(Mandatory)][hashtable]$OrgTree,
        [Parameter()][int]$MaxChildrenShown = 5,
        [Parameter()][switch]$ShowBands,
        [Parameter()][switch]$Full  # show all children, don't truncate
    )
}
```

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- new function
- Export in manifest

**Acceptance Criteria:**
- Tree-style ASCII output with box-drawing characters (|, +, --)
- Truncates children at MaxChildrenShown with "(N more)" indicator
- -Full shows all children
- -ShowBands displays band letter if available (from supplement or auto-detect)
- Summary line at bottom with counts per level

---

## OC-03: Campaign Org Chart Preview

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** OC-02

**Description:**
Before creating campaigns, preview the org tree for a specific set of identities
(from a delta detection or campaign scope). Shows which managers would receive
campaigns and how many identities each would review.

**Function:** `Show-SPCampaignOrgPreview`
```powershell
function Show-SPCampaignOrgPreview {
    param(
        [Parameter(Mandatory)][string[]]$IdentityIds,
        [Parameter()][int]$MaxDepth = 3,
        [Parameter()][string]$CorrelationID
    )
}
```

**Output (ASCII):**
```
Campaign Org Preview -- 25 identities across 3 VP branches

Alice Johnson (VP of Engineering) -- 6 identities to review
  +-- Diana Brown (Director) -- 2 identities
  |   Manager for: Patricia Martin, Jack Green
  +-- George Miller (Director) -- 3 identities
  |   Manager for: Henry King, Emily Allen, Frank Sanchez
  +-- Fiona Garcia (Director) -- 1 identity
      Manager for: Carl Hall

Bob Smith (VP of Operations) -- 10 identities to review
  +-- Helen Davis (Director) -- 3 identities
  ...

Unmanaged (no campaign): Helen Park, Ivan Torres

Campaigns that would be created: 8 (one per manager with affected reports)
```

**Acceptance Criteria:**
- Shows which managers would get campaigns and which identities they'd review
- Highlights unmanaged identities (no campaign for them unless fallback configured)
- Works with -WhatIf pattern (preview without creating)

---

## OC-04: Report Distribution Preview

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** OC-03

**Description:**
Preview which leadership reports would be generated and who would receive them
if SMTP distribution were enabled. Shows the full distribution plan without sending.

**Function:** `Show-SPReportDistributionPreview`
```powershell
function Show-SPReportDistributionPreview {
    param(
        [Parameter(Mandatory)][hashtable]$OrgTree,
        [Parameter(Mandatory)][hashtable]$LeadershipData,
        [Parameter()][switch]$IncludeEmail  # resolve and show email addresses
    )
}
```

**Output (ASCII):**
```
Report Distribution Preview
============================

Executive Summary (1 report)
  To: Richard Sterling (richard.sterling@corp.com) [President, Band A]

VP Reports (3 reports)
  To: Alice Johnson (alice.johnson@corp.com) [VP Engineering, Band B]
      Content: 4 directors, 20 ICs, 83.3% completion
  To: Bob Smith (bob.smith@corp.com) [VP Operations, Band B]
      Content: 4 directors, 20 ICs, 70% completion
  To: Charlie Williams (charlie.williams@corp.com) [VP Security, Band B]
      Content: 4 directors, 20 ICs, 88.9% completion

Director Reports (12 reports)
  To: Diana Brown (diana.brown@corp.com) [Director Eng Team 1, Band C]
      Content: 5 ICs, 100% completion
  To: Edward Jones (edward.jones@corp.com) [Director Eng Team 2, Band C]
      Content: 5 ICs, 80% completion
  ... (10 more)

Total: 16 reports to 16 recipients
SMTP Status: NOT CONFIGURED (reports will be generated but not emailed)
```

**Acceptance Criteria:**
- Shows every report that would be generated with recipient
- Email resolution from ISC identity (via Get-SPAuditAccountForIdentity)
- SMTP status indicator (configured/not configured)
- Works as dry-run before actual report generation

---

## OC-05: Org Chart HTML Export

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** OC-02

**Description:**
Generate a visual org chart as a self-contained HTML file. Uses nested `<div>` elements
with CSS borders to create a top-down tree layout (no JavaScript, Word-compatible).

Unlike the ASCII renderer (terminal), this produces a printable/shareable document.

**Function:** `Export-SPOrgChartHtml`
- Input: org tree, output path
- Generates: `org-chart-{date}.html`
- Shows: each node with name, title, band, direct report count
- Color-coded by band: A=purple, B=blue, C=green, D=orange, E=gray
- Nodes link to the corresponding leadership report if one exists

**Acceptance Criteria:**
- Self-contained HTML (inline CSS, no JS)
- Readable when printed on letter/A4 paper
- Handles orgs up to 100 nodes without layout breaking
- Color-coded by band/level

---

## OC-06: Band/Level Classification Engine

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** OC-01

**Description:**
Assign band classifications (A-E) to each identity in the org tree. Three sources
of band data, in priority order:

1. **Supplement CSV** (OC-01) -- explicit band column (highest priority)
2. **ISC identity attributes** -- `attributes.jobLevel` or `attributes.band` if populated
3. **Auto-detect from depth** -- fallback: depth 0=E, 1=D, 2=C, 3=B, 4+=A

**Function:** `Resolve-SPIdentityBand`
```powershell
function Resolve-SPIdentityBand {
    param(
        [Parameter(Mandatory)][hashtable]$OrgTree,
        [Parameter()][hashtable]$Supplement,
        [Parameter()][hashtable]$BandMapping  # depth -> band letter
    )
    # Returns: hashtable of identityId -> band letter
}
```

**Config:**
```json
"Leadership": {
    "DefaultBandMapping": { "0": "E", "1": "D", "2": "C", "3": "B", "4": "A" },
    "ISCBandAttribute": "jobLevel"
}
```

**Acceptance Criteria:**
- Supplement band overrides ISC attribute which overrides depth-based auto-detect
- Every identity gets a band assignment (no nulls)
- Custom band mappings supported via config

---

## OC-07: Per-Band Leadership Reports

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** OC-06

**Description:**
Generate leadership reports targeted at specific bands. A C-band director sees only
their D-band managers and E-band ICs. A B-band VP sees their C-band directors' rollups.

This extends the existing `Export-SPLeadershipLevelHtml` to filter by band.

**New parameters:**
```powershell
-TargetBands @('B','C')  # generate reports for VP and Director bands only
-ExcludeBands @('E')     # exclude IC-level detail
```

**Use case:** "Generate reports for all C-band and above" produces:
- 1 executive summary (A-band: President)
- 3 VP reports (B-band)
- 12 director reports (C-band)
- NO manager or IC reports

**Acceptance Criteria:**
- Band-based filtering produces correct subset of reports
- Report headers show band designation: "VP Report (Band B): Alice Johnson"
- Works with both ISC-derived and supplement-derived bands

---

## OC-08: Report Distribution CLI

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** OC-04

**Description:**
New CLI script `Scripts/Invoke-SPReportDistribution.ps1` that generates leadership
reports AND optionally distributes them via SMTP.

Combines: campaign audit + leadership rollup + report generation + email distribution.

**Parameters:**
```powershell
-Status COMPLETED           # campaign filter
-DaysBack 30                # date range
-LeadershipDepth 4          # org tree depth
-TargetBands @('B','C')     # which bands get reports
-SendReports                # actually send via SMTP (default: preview only)
-PreviewOnly                # show distribution plan, don't generate or send
-OrgSupplementPath "..."    # optional org chart supplement CSV
-ConfigPath, -Token, -OutputMode
```

**Flow:**
1. If -PreviewOnly: build org tree, show distribution preview (OC-04), exit
2. Run campaign audit with leadership rollup
3. Generate per-band reports (OC-07)
4. If -SendReports: for each report, resolve recipient email, send via SMTP
5. Log distribution to JSONL audit trail

**Exit codes:** 0=success, 1=no campaigns, 2=param error, 3=auth error, 4=SMTP failure

**Acceptance Criteria:**
- Preview mode shows full distribution plan without generating reports
- Generate mode creates reports but doesn't send (default)
- -SendReports sends each report to the corresponding leader's email
- Distribution log tracks: who got what, when, delivery status

---

## OC-09: Org Chart Gap Detector

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** OC-01

**Description:**
Analyze the org tree and identify gaps that would prevent complete leadership reporting.
Produces an actionable list of issues for the governance team to fix.

**Function:** `Get-SPOrgChartGaps`

**Gap types detected:**
- **No manager**: identity has no manager in ISC (and no supplement override)
- **Shallow chain**: identity's manager chain is <3 levels deep (reports truncated)
- **Missing email**: leader in the tree has no email (can't send reports)
- **Orphaned branch**: manager exists but has no manager themselves (branch ends prematurely)
- **Supplement conflict**: supplement says manager is X, ISC says Y (which wins?)
- **Circular reference**: A manages B manages A (should be caught by Build-SPOrgTree)

**Output:**
```powershell
@{
    Gaps = @(
        @{ Type='NoManager'; IdentityId='id-007'; Name='Helen Park'; Impact='No campaign, excluded from reports' }
        @{ Type='ShallowChain'; IdentityId='id-mgr-002'; Name='Nancy Director'; Depth=1; Impact='Reports stop at director level' }
        @{ Type='MissingEmail'; IdentityId='id-vp-001'; Name='Sarah Executive'; Impact='Cannot email VP report' }
    )
    Summary = @{ Total=200; Complete=195; Gaps=5; GapRate=2.5 }
    Recommendations = @(
        "Provide org chart supplement CSV for 5 identities with gaps"
        "Contact HR to populate manager field for Helen Park (id-007)"
    )
}
```

**Acceptance Criteria:**
- Detects all 6 gap types
- Generates actionable recommendations
- Gap rate calculation (% of identities with issues)
- Can be run as a pre-flight check before report generation

---

## OC-10: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** OC-09

**Description:**
Pester tests for OC-01 to OC-09.

**Test IDs:**
- OC-01-T: Import-SPOrgChartSupplement validates CSV and builds hashtable
- OC-01-T2: Circular reference in supplement detected
- OC-02-T: Show-SPOrgTree renders ASCII with correct indentation
- OC-03-T: Campaign org preview shows correct manager-to-identity mapping
- OC-04-T: Report distribution preview shows correct recipient list
- OC-06-T: Band classification uses supplement > ISC > depth fallback
- OC-07-T: Per-band filtering produces correct report subset
- OC-09-T: Gap detector identifies NoManager and ShallowChain gaps
