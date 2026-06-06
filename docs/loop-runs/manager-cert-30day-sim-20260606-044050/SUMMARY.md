# Run Summary -- Manager Certification 30-Day Simulation

**Goal:** Build a richer mock-API dataset + CLI test harness to thoroughly exercise the
SailPoint governance toolkit, focused on **manager certification campaigns over a simulated 30 days**.
Primary use case: a **unique daily privileged-role attestation** -- a fixed set of ~10 tracked
privileged roles re-attested every day for 30 days by the responsible managers -- proving the flow
works via BOTH the custom toolkit code (New-SPCampaign/Start-SPCampaign + campaign audit + leadership
rollup) AND the SP.Sdk path (campaign templates / work items). Everything ADDITIVE.

**Branch (both repos):** feature/manager-cert-30day-sim -- never pushed; master/main untouched in both repos.
**Toolkit repo:** C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit
**Mock-API repo:** C:/temp/Coding/API-mockserver (separate git repo)
**Models:** Opus 4.8 (1M context) across planner / middle / inner / reviewer / hunter tiers.
**Rounds:** 7 work items (T-01..T-07) + 2 finalize bug-hunts (rounds 8-9).

---

## Per-item results

| Item | Repo | Description | Status | Commit | Review |
|------|------|-------------|--------|--------|--------|
| T-01 | mock | Extend New-BulkSeedData.ps1 -- 30-day sim dataset (100 users / 200 groups / 10 priv roles / dated changelog / 30 daily campaigns); seeded & structurally deterministic | DONE | 79a0be5 | PASS |
| T-02 | mock | Add GET /v3/membership-changelog mock endpoint (date-windowed Added/Removed, paging, filters) + integration harness | DONE | 9fda6f1 | PASS |
| T-03 | mock | Regenerate coherent 30-day State/SailPointData.json (+ timestamped backup); restart mock non-elevated; HTTP smoke + date-window proof | DONE | 9fa7efe | PASS |
| T-04 | toolkit | Add Invoke-SP30DayManagerCertSim.ps1 CLI sim driver -- campaign write round-trip, day-1..7 cadence, 7d/30d windows, SMTP-WhatIf | DONE | b58f64f | PASS |
| T-05 | toolkit | Add SP.ManagerCert30DaySim.Tests.ps1 + frozen fixture -- validates org/band rollup, SMTP-WhatIf, removal detection, write round-trip, deltas, priv roles, manager accountability | DONE | e4b2b9b | PASS |
| T-06 | toolkit | Add rolling 7/30-day manager-cert **trend HTML** view (Export-SPRollingTrendHtml) + test suite + sim-driver wiring | DONE | 9393225 | PASS |
| T-07 | mock + toolkit | Add SP.Sdk-path collections (campaign templates / schedules / work-items) to seed; prove SDK path live + via sim driver -IncludeSdkPath | DONE | mock b06c1dc / toolkit e7bb3bb | PASS |

All 7 items: **DONE / PASS** on first attempt (no retries needed). Commit hashes independently verified
to exist in their correct repos (toolkit commits in toolkit log; mock commits T-01/T-02/T-03/T-07 in
the API-mockserver log).

---

## Validation evidence (the point of the exercise)

- **Manager cert campaigns -> correct ORG/MANAGER reports** -- MC-01 exercises the real fixture
  manager chain id-gen-011 -> id-gen-006 -> id-gen-003 -> id-gen-001 with leadership bands A,B,C,E.
- **SMTP-WhatIf logs, never sends** -- MC-02 + sim Step B: Send-SPReport Action=Logged,
  Send-MailMessage invoked 0 times; every distribution pass printed "WOULD send" / "no email sent".
- **REMOVED-from-entitlement detection** -- MC-03: removal surfaced in BOTH 7-day and 30-day data-truth
  and via Get-SPDeltaRevokeEvents (InModuleScope, function is unexported). Genuine seeded removals:
  id-gen-006/ent-003 dated 2026-05-16 (30d-only) and id-gen-043/ent-009 dated 2026-05-30 (both windows).
- **Campaign WRITE round-trip** -- sim Step A: 10 MANAGER campaigns submitted + activated, all 10
  confirmed via Get-SPCampaign AND Search-SPCampaigns; MC-04 covers it in Pester.
- **7-day vs 30-day deltas/trends** -- MC-05 + sim Step C windows (7d & 30d audit/adaptive dirs).
- **Privileged-role reports** -- MC-06: 10 tracked priv roles, ent-003 members id-gen-069/035/050, churn correct.
- **Manager accountability** -- MC-07: id-gen-002 missed 3/4 in camp-daily-priv-01; monotone window rollup.
- **SP.Sdk path** -- T-07: 10 campaign templates (all MANAGER + owner ref; tmpl-priv-01 schedule DAILY),
  30 work items (open=7 / completed=23); proven live (Invoke-SPSdkCampaignTemplates, Invoke-SPSdkWorkItems)
  and via sim -IncludeSdkPath Step F; MC-08 (Layer-A x6 + Layer-B x4) covers it in Pester.

---

## Enrichment delivered

- **Rolling 7/30-day trend HTML view** (Export-SPRollingTrendHtml, T-06) -- new additive export on
  SP.Audit, with 16 passing tests; renders both 7-day and 30-day sections with priv-role
  added/removed and attested/overdue/missed indicators. Wired into the sim driver.

---

## Bugs fixed

None. No retries were required and the two finalize bug-hunts (rounds 8-9) found **0 real bugs**
(no failing tests, no regressions, no additive violations).

## Items BLOCKED or AUTHORED (human-run)

None blocked. Per the run's headless-only rule, the WPF dashboard / FlaUI / W-08b / W-09b GUI gates
were intentionally NOT exercised (human-run gates) -- no item depended on them. The sim driver's
campaign-complete path is safety-gated (Safety.AllowCompleteCampaign), completing only a 3-campaign
subset by default; full completion is left to an operator.

## Discrepancies the gate caught (claimed vs actual)

All immaterial; none changed a verdict:
- **T-01:** inner claimed actAdd=786; reviewer counted GRANT_ACCESS activities = 783
  (item-op vs activity-type counting). Byte-hash non-determinism honestly disclosed (UtcNow-anchored
  Get-IsoTimestamp); structural determinism -- the actual requirement -- fully met.
- **T-03:** changelog field is named "operation" (ADD/REMOVE), not "op". Reviewer re-run windowed
  count was 162 vs claimed 170 (relative-to-now filter; date rolled). Mock was DOWN at the turn
  boundary; reviewer restarted it non-elevated (no -Fresh) and re-confirmed it serves the new dataset.
- **T-07:** the journal round-07-t-07.md "## Commit" lists a pre-amend hash 4d7bcf8; the actual
  final toolkit commit is e7bb3bb (cosmetic stale-hash in the record only). Spec referenced
  SP.SdkWorkItems.Tests.ps1 which does not exist; work-items SDK coverage is provided by
  SP.SdkBridge.Tests.ps1 (44/0) plus new MC-08 Layer-B.

### Latent observations from bug-hunts (not bugs, not fixed)

- Export-SPRollingTrendHtml window math is inclusive of both ends (a "7-day window" renders 8
  calendar buckets); self-consistent and honestly labeled with the actual day count.
- Anchor date resolves to changelog max 2026-06-06, one day past the last daily campaign 2026-06-05,
  so the most-recent 7-day bucket shows changelog activity with zero campaigns -- cosmetic, honest.
- Mock GET /v3/membership-changelog from/to-date filter casts datetimes without InvariantCulture
  (locale-fuzzy); NOT on the validated path -- the sim driver fetches with a high limit and filters client-side.

---

## Full-suite gate (Finalize, toolkit)

Invoke-Pester .\Tests -- **Passed: 1229, Failed: 0, Total: 1229** (confirmed twice, rounds 8 and 9).

---

## Additive integrity

- Toolkit: 4 new files (Invoke-SP30DayManagerCertSim.ps1, 2 new test suites, 1 frozen fixture)
  plus journal docs; only modifications are additive edits to SP.Audit.psd1 + SP.AuditReportHtml.psm1
  to export the new Export-SPRollingTrendHtml. No existing function, test, export, or endpoint removed.
- Mock: extended New-BulkSeedData.ps1, added the /v3/membership-changelog handler + route,
  regenerated State/SailPointData.json (with backup). Regenerating test data is expected and not an
  additive violation. No existing handler/route/test removed.
- Neither repo pushed; master/main untouched in both.
