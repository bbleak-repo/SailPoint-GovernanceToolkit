# Round 2 -- T-02: Invoke-SPCampaignAudit.ps1
**Started:** 2026-05-23 15:35
**Completed:** 2026-05-23 15:42
**Mock Server:** Pode on localhost:8080 (SailPoint-ISC profile)
**Branch:** feature/cli-tests

---

## Test Results

| Test | Parameters | Expected | Actual | Result |
|------|-----------|----------|--------|--------|
| TC-02-01 | `-Status COMPLETED -DaysBack 365 -OutputMode Console` | 1 campaign, exit 0, 25 items (16A/4R/5P) | 1 campaign, exit 0, 25 items (16A/4R/5P) | PASS |
| TC-02-02 | `-Status ACTIVE -DaysBack 365 -OutputMode Console` | 1-2 campaigns, exit 0 | 2 campaigns (camp-active-001 + camp-delta-001), exit 0 | PASS |
| TC-02-03 | `-Status COMPLETED,ACTIVE -DaysBack 365 -OutputMode Console` | 2-3 campaigns, exit 0 | 3 campaigns (active + completed + delta), exit 0 | PASS |
| TC-02-04 | `-CampaignNameContains 'Annual' -DaysBack 365 -OutputMode Console` | 1 campaign (2025 Annual Access Review), exit 0 | 1 campaign (2025 Annual Access Review), exit 0 | PASS |
| TC-02-05 | `-Status COMPLETED -DaysBack 365 -DetailLevel Summary -OutputMode Console` | No `<details open>` tags | 0 `<details open>` tags in combined HTML | PASS |
| TC-02-06 | `-Status COMPLETED -DaysBack 365 -DetailLevel Verbose -OutputMode Console` | All sections `<details open>` | 10 `<details open>` tags in combined HTML | PASS |
| TC-02-07 | `-Status COMPLETED -DaysBack 365 -IncludeLeadershipRollup -LeadershipDepth 2 -OutputMode Console` | Director reports, no VP-level | 3 director reports + executive summary, exit 0 | PASS |

**Score: 7/7 PASS**

---

## Data Validation (TC-02-01)

JSONL audit trail verified:
- CampaignName: 2025 Annual Access Review
- DecisionsApproved: 16
- DecisionsRevoked: 4
- DecisionsPending: 5
- Total items: 25 (matches 5 certs x 5 items)
- RubberStampRisk.HasMediumOrHighRisk: false

Output files generated:
- Per-campaign HTML + TXT in `Audit/2025 Annual Access Review/`
- Combined HTML in `Audit/campaign-audit-combined-*.html`
- JSONL audit trail in `Audit/audit-*.jsonl`

---

## Data Validation (TC-02-02)

Two ACTIVE campaigns found:
- camp-active-001: Q1 2026 Source Owner Review (25 items across 5 certs)
- camp-delta-001: AD Delta Cert 2026-05-23 (0 items across 3 certs)
Campaign reports (CSV) correctly unavailable for ACTIVE campaigns (not yet completed).

---

## Data Validation (TC-02-07)

Leadership rollup with depth=2:
- Org tree: 25 leaves, 11 managers, 0 directors, 3 top leaders
- Level 2 (Executive Leadership): 3 reports generated (overwriting executive-summary.html)
- Backward-compatible director reports: Alice Johnson, Bob Smith, Charlie Williams
- No VP-level reports generated (correct for depth=2)

---

## Bugs Found

None.

---

## Screenshots

| File | Description |
|------|-------------|
| `tc02-combined_full.png` | Full-page combined audit report (TC-02-07 run) |
| `tc02-combined_viewport.png` | Viewport capture of combined report |
| `tc02-leadership_full.png` | Executive summary leadership report |
| `tc02-leadership_viewport.png` | Viewport capture of leadership report |

---

## Notes

- Campaign report CSVs are only available for COMPLETED campaigns. ACTIVE campaigns
  correctly show warnings about unavailable report types.
- The `co` (contains) filter for CampaignNameContains works correctly against the mock API.
- DetailLevel Summary renders all content inline (no `<details>` wrappers). Verbose wraps
  sections in `<details open>` for expandable display.
- Leadership depth=2 stops at the VP/executive level (the identities' managers are directors,
  so 2 levels up reaches VPs). The org tree labels them "Executive Leadership" at level 2.
