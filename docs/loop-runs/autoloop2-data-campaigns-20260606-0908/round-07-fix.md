# Round 07 - INNER (fix)

## Bug fixed

EA-12 live cross-check was permanently skipped (the suite's only Skip).

In `Tests/SP.EnrichedAnalyticsHtml.Tests.ps1`, the EA-12 `It` block gated on
`-Skip:(-not $script:mockUpRun)`. But Pester 5 evaluates `-Skip` at **discovery**
time, and `$script:mockUpRun` is only assigned inside `BeforeAll` (run phase).
At discovery `$script:mockUpRun` is `$null`, so `-not $null` = `$true` and the
test ALWAYS skipped regardless of mock state.

The discovery-scope probe at the top of the file correctly sets `$script:MockUp`
(the same variable the sibling live files
`SP.RegularCampaignUploadHtml.Tests.ps1` and `SP.DisconnectedUploadHtml.Tests.ps1`
use for their `-Skip`, which run live). The fix aligns EA-12 with that pattern.

## Did

1. Changed the EA-12 `-Skip` predicate from `$script:mockUpRun` to
   `$script:MockUp` (the discovery-scope variable), matching the sibling live
   test files.
2. Corrected the misleading discovery-probe comment (it previously named
   `$mockUpRun`, reinforcing the mismatch); it now explains that `-Skip` is a
   discovery-time evaluation that must gate on `$script:MockUp`.

This is additive/corrective only -- no module, exporter, endpoint, export, or
other test was removed or rewired. The `$script:mockUpRun` re-probe inside
`BeforeAll` is left in place (it is still available to run-phase code).

## Files

- `Tests/SP.EnrichedAnalyticsHtml.Tests.ps1`
  - line ~393: `-Skip:(-not $script:mockUpRun)` -> `-Skip:(-not $script:MockUp)`
  - lines ~55-57: corrected discovery-probe comment

## Verification

Mock probed UP before runs:

```
MOCK UP: 200
```

Affected file (mock up) -- EA-12 now ENTERS the test body (no longer skipped at
discovery). It then in-body soft-skips via `Set-ItResult -Skipped` because the
enriched mock returned no campaigns in the window (a pre-existing, intentional
soft cross-check guard in the test body -- NOT the discovery-time bug):

```
Describing EA: Reporting + analytics over the enriched dataset -> HTML
 Context EA-12: live cross-check over the enriched mock (skips if mock down)
   [!] EA-12 live campaigns -> metrics -> trends produces >=1 period is skipped, because enriched mock returned no campaigns in window 2.85s
Tests Passed: 11, Failed: 0, Skipped: 1, Inconclusive: 0, NotRun: 0
RESULT: Passed=11 Failed=0 Skipped=1
```

Note the difference from the bug: previously the skip reason was the discovery
`-Skip` predicate firing unconditionally; now the test runs its body, exercises
the live `Get-SPAuditCampaigns` read path, and only soft-skips when the live
query yields no campaigns. Sibling-file consistency confirmed via grep --
EA-12 now uses the identical `-Skip:(-not $script:MockUp)` predicate as the
RegularCampaignUpload and DisconnectedUpload live tests.

Full suite (Finalize gate):

```
FULL SUITE: Passed=1293 Failed=0 Skipped=1 Total=1294 Time=563s
```

0 failures. The single remaining Skip is EA-12's in-body run-phase soft-skip
(legitimate), not the discovery-time defect.

## Commit

See structured result for the hash. Commit on branch
`feature/manager-cert-30day-sim`, not pushed.

## Status

DONE.
