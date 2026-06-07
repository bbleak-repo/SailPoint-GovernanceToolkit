# AutoLoop #3 -- SDK Collections Restore -- Run Summary

**Run ID:** autoloop3-sdk-collections-20260606-1620
**Date:** 2026-06-06
**Branch:** feature/manager-cert-30day-sim (both repos; never pushed; master/main untouched)
**Models:** Opus 4.8 (1M context) across all tiers (planner / middle / inner / reviewer / hunter)

## Goal

A live FlaUI GUI pass revealed that the regenerated enriched mock seed
(New-BulkSeedData) correctly populated Templates (10) and Work Items (7 open /
23 completed) but **dropped three SDK collections** -- the SDK tab's APPROVALS,
WORKFLOWS, and CAMPAIGN-FILTERS sub-tabs were empty because
/v3/access-request-approvals, /v3/workflows, and /v3/campaign-filters all
served 0 rows. Goal: restore those collections in the seed generator
(additive, deterministic, rich), make the SDK interactive test data-adaptive,
and add a Pester regression guard -- all verified headlessly. Live FlaUI /
W-08b / W-09b deferred to a human gate.

## Repos

| Repo | Path | Role |
|------|------|------|
| toolkit | C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit | tests + GUI harness |
| mock-api | C:/temp/Coding/API-mockserver | seed generator + served state |

## Per-item results

| Item | Description | Status | Attempts | Commit (repo) |
|------|-------------|--------|----------|---------------|
| **T-01** | MOCK: restore SDK approvals (pending+completed) / workflows (+executions) / campaign-filters in New-BulkSeedData.ps1; regenerate seed; restart fresh; verify non-empty | **DONE** | 1 | 4a0f057 (mock-api) |
| **T-02** | Make Test-W08b-SdkTabInteractive.ps1 data-adaptive: derive expected counts from live mock at runtime instead of hard-coded literals | **DONE** | 2 (1 retry) | 94c4e36 -> fix ebf1628 (toolkit) |
| **T-03** | Pester regression guard SP.MockSdkCollections.Tests.ps1: assert non-empty Approvals / Workflows / Filters / Templates / WorkItems | **DONE** | 1 (+1 finalize fix) | 99655d2 -> fix 00184af (toolkit) |

### T-01 -- Core fix (DONE, PASS first attempt)
Mock commit 4a0f057 adds 270 insertions / 0 deletions to
Scripts/New-BulkSeedData.ps1 (3 additive hunks) plus regenerated
seed-data.json and served State/SailPointData.json. Reviewer confirmed claims TRUE.

**Live verification (re-confirmed by Scribe, mock up on :8080):**
pending=4, completed=4, workflows=4, filters=3, templates=10.

**Regression guard -- enriched data NOT shrunk:** templates=10, sources=6,
work-items open=7 / completed=23, campaigns=38 (38 is the generator's own
deterministic output; the diff is pure insertion and touches no campaign,
source, work-item, or template generation).

Pre-existing unrelated failure noted (NOT introduced by this run): integration
Step 12 GET /v3/identities/id-pres -> 404 (id-pres is hard-coded in the test
and only exists in the hand-authored original seed; the bulk generator never
emitted it). No identity generation was touched.

### T-02 -- Data-adaptive SDK interactive test (DONE after 1 retry)
First attempt 94c4e36 refactored the harness to read expected counts from the
live mock via Get-SPMockExpectedCounts, but the **reviewer gate caught a real
bug** (see Discrepancies). Retry ebf1628 fixed the workflows probe.
Second-attempt review: PASS. Headless only -- live FlaUI W-08b was **not** run
(human gate). All 19 x:Name/AutomationIds resolve in Gui/MainWindow.xaml;
parse errors = 0; no surviving live hard-coded -Expected 3/4/6 literals
(only comments remain). Live helper now returns the correct adaptive values:
Workflows=4, DisabledWorkflowId=wf-004.

### T-03 -- Regression-guard Pester test (DONE; finalize hardened it)
Commit 99655d2 adds Tests/SP.MockSdkCollections.Tests.ps1 (8 It blocks)
asserting non-empty pending/completed approvals, approval-summary,
workflows + executions, campaign-filters, campaign-templates, and work-items
summary; mock-down -> Set-ItResult -Inconclusive so the full suite stays green
without a mock. **Finalize bug-hunt (round 5) found** that 3 of the assertions
used @(Invoke-RestMethod ...).Count as a direct expression, which in PS 5.1
always returns 1 and would NOT catch an empty [] -- defeating the precise
regression this test exists to catch. Fix 00184af switched those 3 blocks to
the assign-first idiom ($x = & $Probe '...'; @($x).Count). Scribe re-ran the
test: **8 passed / 0 failed / 0 skipped**.

## Bugs fixed during the run

1. **T-02 workflows probe miscount (reviewer-caught, fixed ebf1628).**
   Get-SPMockExpectedCounts read workflows via
   $wf = @(Invoke-RestMethod .../v3/workflows) -> $wf.Count (Pattern B),
   which in PS 5.1 collapses the deserialized JSON array to a single element,
   returning Workflows=1 instead of 4 and leaving DisabledWorkflowId
   empty instead of wf-004. This would have made WG-08-18 assert 1 row
   against a 4-row grid (FAIL on correct data) and degraded WG-08-19 to a
   soft note. Fixed to assign-first (@($wf).Count), matching the other probes.

2. **T-03 regression guard partially blind (hunter-caught, fixed 00184af).**
   Three It blocks (completed-approvals, campaign-filters, campaign-templates)
   used @(& $Probe '...').Count directly, always evaluating to 1 -- so an empty
   [] regression would still PASS, defeating the test's purpose. Fixed to the
   assign-first idiom so an empty collection correctly yields .Count = 0.

Both bugs were the **same PS 5.1 @() array-flatten trap** -- caught twice by
the independent gate/hunter rather than shipping.

## Discrepancies the gate caught (claimed vs actual)

| Round | Item | Claimed | Actual (gate-verified) | Resolution |
|-------|------|---------|------------------------|------------|
| 2 | T-02 | Inner claimed probe yields workflows=4 (disabled wf-004) | Committed helper actually returned Workflows=1, DisabledWorkflowId='' when dot-sourced against the live mock | Reviewer verdict FAIL -> retry; fixed in ebf1628 (round 3 PASS) |

All other inner claims across T-01, T-02 (attempt 2), and T-03 were verified
TRUE by the gate (parse, x:Name resolution, commit hashes, file scope,
not-pushed, master untouched).

## Items left BLOCKED or AUTHORED (human-run gates)

- **AUTHORED (human-run):** Live FlaUI Test-W08b-SdkTabInteractive.ps1
  (W-08b) -- authored and headless-validated (parse + x:Name cross-check +
  live runtime-count helper) but **never executed live** per the run protocol.
  Now data-adaptive, so it should track any future enriched dataset. **Run
  acceptance gate:** launch the WPF dashboard and run W-08b against the live
  mock to confirm the SDK tab grids/badges match the served counts
  (pending=4, completed=4, workflows=4, filters=3, templates=10,
  work-items 7/23, disabled workflow = wf-004).
- **No items BLOCKED.**

## Non-blocking pre-existing issue noted (not fixed -- predates run)

- Tests/Harness/Test-W08b-SdkTabInteractive.ps1 line 446 references an
  undefined $selected in a WG-08-13 FAIL-path message string, and line 472
  has a stale "# end: if $selected" comment. Removed before this autoloop began
  (present at b6930e5~1). Cosmetic only: non-strict expansion to empty string,
  on a FAIL branch, in an author-only harness. No functional impact.

## Full-suite gate (Finalize)

Invoke-Pester .\Tests  ->  Passed: 1301, Failed: 0, Skipped: 1, Total: 1302
The 1 skip is the EA-12 data-window inconclusive guard (not a failure).
Final bug-hunt (round 8): **0 bugs**. Mock left up and clean on
http://localhost:8080 (no error-injection / scenario state).

## Net outcome

All 3 planned items DONE. The core regression (empty SDK collections) is fixed
at the source (seed generator) and now serves rich deterministic data; the
interactive test is data-adaptive; and an automated Pester guard will catch any
future drop of these collections. Two instances of the same PS 5.1 array-flatten
trap were caught by the gate/hunter and fixed before finalize. Suite green
(1301/0/1).

---
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
