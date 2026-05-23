# Visual Report Review -- Iterative Backlog

**Created:** 2026-05-23
**Prereqs:** All Phases 1-9 complete, Pode mock server with 80-identity enterprise org

---

## How to Use This File

This is a **review-and-fix loop**, not a pure implementation backlog.
Each round: generate reports -> screenshot -> review -> fix -> re-screenshot -> commit.

**Serial order:**
```
V-01 -> V-02 -> V-03 -> V-04 -> V-05 -> V-06 -> V-07 -> V-08
```

---

## Tools

| Tool | Path | Purpose |
|------|------|---------|
| Playwright Python | `/Users/xand/Documents/Projects/CyberArk-CPM-PSM-TestKit/cpm-simulator/venv/bin/python` | Runs capture.py |
| capture.py | `/Users/xand/Documents/Projects/.claude-frameworks/playwright-capture/capture.py` | Screenshots HTML files |
| review.py | `/Users/xand/Documents/Projects/.claude-frameworks/playwright-capture/review.py` | Generates AI review prompt |
| Pode mock | `/Users/xand/Documents/Projects/API-MockServer/Start-MockServer.ps1` | Simulates ISC API |
| Mock seed data | `/Users/xand/Documents/Projects/API-MockServer/Profiles/SailPoint-ISC/seed-data.json` | Ground truth for data verification |

**Shorthand variables for agent prompts:**
```bash
PY="/Users/xand/Documents/Projects/CyberArk-CPM-PSM-TestKit/cpm-simulator/venv/bin/python"
CAP="/Users/xand/Documents/Projects/.claude-frameworks/playwright-capture/capture.py"
OUTDIR="docs/visual-review/screenshots"
TOOLKIT="/Users/xand/Documents/Projects/SailPoint/tools/SailPoint-GovernanceToolkit"
```

---

## Phase Summary

| ID | Review Cycle | Depends On | Status |
|----|-------------|------------|--------|
| V-01 | Generate all reports against mock | none | PENDING |
| V-02 | Campaign audit report review | V-01 | PENDING |
| V-03 | Executive summary review | V-01 | PENDING |
| V-04 | VP + Director reports review | V-01 | PENDING |
| V-05 | Delta report review | V-01 | PENDING |
| V-06 | Compliance sections review | V-01 | PENDING |
| V-07 | Cross-report data consistency | V-02 to V-06 | PENDING |
| V-08 | Fix implementation + re-capture | V-07 | PENDING |

---

## V-01: Generate All Reports Against Mock

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none

**Description:**
Start the Pode mock server, swap toolkit to mock config, and generate every report type.
This creates the HTML files that V-02 through V-06 will screenshot and review.

**Steps:**
```bash
# 1. Start mock server
cd /Users/xand/Documents/Projects/API-MockServer
pwsh -NoProfile -File Start-MockServer.ps1 &
sleep 3

# 2. Swap toolkit to mock config
cd $TOOLKIT
python3 -c "
import json
with open('Config/settings.json') as f: cfg = json.load(f)
cfg['Authentication']['ConfigFile']['TenantUrl'] = 'http://localhost:8080'
cfg['Authentication']['ConfigFile']['OAuthTokenUrl'] = 'http://localhost:8080/oauth/token'
cfg['Authentication']['ConfigFile']['ClientId'] = 'mock'
cfg['Authentication']['ConfigFile']['ClientSecret'] = 'mock'
cfg['Api']['BaseUrl'] = 'http://localhost:8080/v3'
cfg['Global']['EnvironmentName'] = 'MOCK-SERVER'
cfg['Safety']['RequireWhatIfOnProd'] = False
cfg['Audit']['DefaultDaysBack'] = 365
with open('Config/settings.json','w') as f: json.dump(cfg,f,indent=4)
"

# 3. Generate campaign audit with leadership rollup (all 3 detail levels)
pwsh -NoProfile -Command '
  .\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 365 `
      -IncludeLeadershipRollup -LeadershipDepth 4 -DetailLevel Verbose -OutputMode Console
'

# 4. Generate delta report
pwsh -NoProfile -Command '
  .\Scripts\Invoke-SPDeltaReport.ps1 -SourceId "src-ad-001" -HoursBack 48 -OutputMode Console
'

# 5. Restore real config
# (copy settings-real.json back)
```

**Output expected:**
```
Audit/
  campaign-audit-combined-*.html          (full campaign audit, 7+ sections)
  2025 Annual Access Review/
    campaign-audit-*.html                 (per-campaign)
    campaign-audit-*.txt                  (text summary)
  leadership/
    executive-summary.html                (President level)
    vp-AliceJohnson.html                  (VP of Engineering)
    vp-BobSmith.html                      (VP of Operations)
    vp-CharlieWilliams.html               (VP of Security)
    director-*.html                       (12 director reports)
  audit-*.jsonl                           (audit trail)
DeltaCert/
  reports/
    delta-*.html                          (daily delta report)
```

**Acceptance Criteria:**
- All report files generated without errors
- At least 1 executive, 3 VP, and 12 director reports
- Delta report generated with new grants and revocations
- JSONL audit trail written

---

## V-02: Campaign Audit Report Review

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-01

**Description:**
Screenshot the combined campaign audit report and review for visual quality and data accuracy.

**Capture:**
```bash
$PY $CAP Audit/campaign-audit-combined-*.html --full-page --output-dir $OUTDIR --prefix audit
$PY $CAP Audit/campaign-audit-combined-*.html --scroll-captures --scroll-step 900 --output-dir $OUTDIR --prefix audit-scroll
```

**Review checklist:**
- [ ] Header: campaign name, date range, correlation ID visible
- [ ] Executive dashboard: donut chart renders, percentages correct
- [ ] Reviewer accountability table: all reviewers listed with correct counts
- [ ] Reviewer performance: time-to-decision metrics, color-coded response times
- [ ] Decision summary: Approved/Revoked/Pending counts match mock data
- [ ] Risk indicators: STALE/PRIVILEGED/ORPHAN/TERMINATED badges visible where applicable
- [ ] Anti-rubber-stamping: section present if applicable, velocity scores shown
- [ ] Campaign reports section: CSV data or "unavailable" message
- [ ] Remediation proof: revoked items with provisioning status
- [ ] Compliance fields: justification column, remediation status, system timestamps
- [ ] Audit metadata: correlation ID, environment name, duration

**Data verification against mock:**
Read `/Users/xand/Documents/Projects/API-MockServer/Profiles/SailPoint-ISC/seed-data.json`
and verify:
- Total certification items = 25 (5 certs x 5 items for completed campaign)
- Approved count matches items with decision=APPROVE
- Revoked count matches items with decision=REVOKE
- Reviewer names match certification reviewer fields

---

## V-03: Executive Summary Review

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-01

**Description:**
Screenshot the leadership executive summary and verify the org tree is correct.

**Capture:**
```bash
$PY $CAP Audit/leadership/executive-summary.html --full-page --output-dir $OUTDIR --prefix exec
```

**Review checklist:**
- [ ] Header: correct top-level leader name (Richard Sterling, President)
- [ ] Donut chart: approval/revocation split renders correctly
- [ ] VP table: shows 3 VPs (Alice Johnson, Bob Smith, Charlie Williams)
- [ ] Per-VP metrics: total items, approved, revoked, pending, completion %
- [ ] Color coding: green >= 95%, orange 80-95%, red < 80%
- [ ] Level label: "Vice Presidents" (not hardcoded "Directors")
- [ ] Navigation links: links to VP reports work

**Data verification:**
- VP names match identities id-vp-1, id-vp-2, id-vp-3 in seed data
- VP-level aggregates sum correctly across their directors

---

## V-04: VP + Director Reports Review

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-01

**Description:**
Screenshot VP and Director level reports. Verify each level shows correct subordinates
and the expandable detail sections work.

**Capture:**
```bash
# VP reports
for f in Audit/leadership/vp-*.html; do
    name=$(basename "$f" .html)
    $PY $CAP "$f" --full-page --output-dir $OUTDIR --prefix "$name"
done

# Sample 3 director reports (one per VP branch)
$PY $CAP Audit/leadership/director-DianaBrown.html --full-page --output-dir $OUTDIR --prefix dir-eng
$PY $CAP Audit/leadership/director-HelenDavis.html --full-page --output-dir $OUTDIR --prefix dir-ops
$PY $CAP Audit/leadership/director-LisaTaylor.html --full-page --output-dir $OUTDIR --prefix dir-sec
```

**Review checklist:**
- [ ] VP report shows correct directors (4 per VP)
- [ ] Director report shows ICs with decisions
- [ ] Expandable sections: `<details>` tags present, revocations auto-expanded
- [ ] Level labels: "Vice Presidents" for VP, "Directors" for Director level
- [ ] Navigation: parent/child links between levels
- [ ] Per-manager identity tables: identity name, account (UPN), access, decision, date
- [ ] Color-coded completion percentages

---

## V-05: Delta Report Review

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-01

**Description:**
Screenshot the delta report and verify it's lightweight and changes-only.

**Capture:**
```bash
$PY $CAP DeltaCert/reports/delta-*.html --full-page --output-dir $OUTDIR --prefix delta
```

**Review checklist:**
- [ ] Report is compact (1-2 viewport heights max)
- [ ] Section 1: New Access Grants (identity, source, entitlement, date)
- [ ] Section 2: Campaigns Created (if any created during this window)
- [ ] Section 3: Revocations (identity, access revoked, reviewer)
- [ ] Section 4: Pending Reviews (items awaiting decision)
- [ ] NO full campaign detail (no reviewer accountability, no remediation proof)
- [ ] Timestamp: "as of {date/time}" visible
- [ ] Color coding: green for completed, orange for pending, red for overdue

**Data verification:**
- New grants count matches account-activities in seed data within the time window
- Revocation items match items with decision=REVOKE

---

## V-06: Compliance Sections Review

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-01

**Description:**
Focused review of compliance-specific sections across all report types.

**Capture (element-level):**
```bash
# If sections have IDs/classes, capture specific elements
$PY $CAP Audit/campaign-audit-combined-*.html --full-page --output-dir $OUTDIR --prefix compliance
```

**Review checklist:**
- [ ] Anti-rubber-stamping section: decision velocity table, risk levels
- [ ] Risk badges: inline colored spans (STALE, PRIVILEGED, ORPHAN, TERMINATED)
- [ ] Compliance fields in decision tables: Justification, Remediation Status, System Timestamp
- [ ] 18 mandatory fields present in JSONL output (verify via jq/python)
- [ ] Reassignment chain visible for reassigned certifications
- [ ] Campaign start/due/completion dates present

---

## V-07: Cross-Report Data Consistency

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-02 to V-06

**Description:**
Verify the same data is consistent across all report views. Read the mock seed data
and compare numbers across:

1. Campaign audit total items == sum of all VP reports' items
2. Executive summary VP totals == sum of their director reports
3. Director report items == individual identity decisions in their section
4. Delta report new grants == account activities in seed data
5. Risk badges in campaign audit match risk badges in leadership reports
6. Compliance fields in HTML match JSONL audit trail

**No screenshots needed** -- this is a data-level code review.

---

## V-08: Enhancement Implementation

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** V-07

**Description:**
Fix all issues identified in V-02 through V-07. For each finding:
1. Fix the HTML generation code in SP.AuditReport.psm1 or SP.DeltaCertReport.psm1
2. Re-generate reports against mock
3. Re-capture screenshots to verify fix
4. Log before/after in the round MD file

After all fixes, run syntax checks on modified files and commit.

---

## Agent Loop Prompt Template

The agent loop for this backlog uses a **different pattern** than code backlogs.
Each round must:

1. Check if Pode mock server is running (curl localhost:8080/health)
2. If not, start it
3. Ensure mock config is active (check settings.json BaseUrl)
4. Read the backlog for the next PENDING review cycle
5. Execute the capture commands listed
6. Use the Read tool on each generated PNG to visually inspect
7. Read the seed-data.json for data verification
8. Log findings in the round MD file
9. If fixes needed: edit code, re-generate, re-capture, verify
10. Mark DONE, commit, push
