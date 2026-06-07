# Round 02 -- T-02 CODE-REVIEW GATE

Item: Toolkit -- make W-08b interactive SDK test data-adaptive (read expected
counts from the live mock at runtime).

Reviewed commit 94c4e36 (test) + 8cbcd4e (record). Branch
feature/manager-cert-30day-sim. Independent fresh-eyes review.

## VERDICT: FAIL (real bug in the runtime probe; fixable, additive)

The refactor is structurally correct and additive for 6 of 7 collections, but
the WORKFLOWS probe uses a different array-count idiom than every other probe
and returns the WRONG runtime value, which defeats the item's core goal for the
workflows collection and would make WG-08-18 FAIL / WG-08-19 under-assert on the
correct (served) dataset.

## Headless checks I re-ran

1) Parse/compile (absolute path):
   errors=0

2) AutomationId / x:Name cross-check vs Gui\MainWindow.xaml -- all 19 = True:
   SdkTemplateGrid, SdkApprovalGrid, RbSdkPending, RbSdkCompleted,
   SdkWorkItemGrid, SdkWiBadgeOpen, SdkWiBadgeCompleted, SdkWiBadgeTotal,
   ChkSdkShowCompleted, SdkWorkflowGrid, ChkSdkIncludeSystem, SdkFilterGrid,
   SdkExecutionGrid, BtnSdkViewExecutions, SdkWorkItemStatusLabel,
   BtnSdkRefreshTemplates, BtnSdkRefreshApprovals, BtnSdkRefreshWorkflows,
   BtnSdkRefreshFilters = True (each).

3) Surviving hard-coded literals driving PASS/FAIL: NONE. The only
   -Expected 3/4/6 / '4'/'2'/'6' / wf-004 hits (lines 300, 771) are COMMENTS.
   No `Count -eq 3/4/6`, no `badgeOpen -eq '4'`, etc. remain as live assertions.

4) Probe helper builds Bearer token via POST /oauth/token (lines 248-253) and is
   invoked ONLY inside `if ($mockUp)` after the /health check (lines 328-331).
   Correct placement and auth pattern.

5) Live helper execution (dot-sourced the actual committed
   Get-SPMockExpectedCounts against the mock at http://localhost:8080):
     Templates=10, ApprovalsPending=4, ApprovalsCompleted=4,
     WorkItemsOpen=7, WorkItemsCompleted=23, WorkItemsTotal=30,
     ShowCompletedTotal=30, Filters=3   -- ALL CORRECT
     Workflows=1            <-- WRONG (endpoint serves 4)
     DisabledWorkflowId=''  <-- WRONG (endpoint serves wf-004 as enabled=false)

## ROOT CAUSE (real bug)

Line 297:
    $wf = @(Invoke-RestMethod -Uri "$v3/workflows" ... )
    $out.Workflows = $wf.Count           # -> 1, should be 4

Every other probe assigns to $r first then counts:  $r = Invoke-RestMethod...;
@($r).Count  -> correct. Wrapping the cmdlet invocation directly in @(...)
collapses the deserialized JSON array to a single object here. Reproduced
directly against the live endpoint:
    Pattern A ($r = IRM; @($r).Count)            = 4   (correct)
    Pattern B (@(IRM ...).Count)                 = 1   (wrong)
Because $wf is the single wrapper object, the disabled-workflow filter
`$wf | Where-Object { $_.enabled -eq $false }` finds nothing (top-level object
has no .enabled), so DisabledWorkflowId stays empty.

## Downstream impact

- $expWorkflows resolves to 1 -> WG-08-18 asserts `$rows.Count -eq 1`, but the
  SdkWorkflowGrid will show 4 -> step FAILS against correct data.
- $expDisabledWfId = $null -> WG-08-19 can never reach the strong PASS branch
  (requires `$wantDisabledId` non-null); it silently degrades to the soft-note
  branch even though served data fully supports the strong wf-004 assertion.

This is exactly the "read counts/disabled id from served data" behaviour the
item requires, broken specifically for workflows.

## Claim reconciliation

Inner CLAIMED verification reported "workflows=4 (disabled id=['wf-004'])". The
actual committed helper returns Workflows=1 / DisabledWorkflowId=''. The inner
appears to have probed the endpoint manually (Pattern A) and reported that,
rather than the value the committed Pattern-B code produces. claimsVerified=false
for that line. (Parse=0, x:Name=all True, literal-scan, $mockUp-guard, token --
all other claims verified true.)

## Commit hygiene (all good)

- Only T-02 files in 94c4e36 (harness + round-02 record); 8cbcd4e records hash.
- Co-Authored-By present. On feature branch only; ahead of origin (NOT pushed).
- master/main untouched. Additive (only the function + a guarded block + the
  -Expected/comparison values changed; no existing mechanic removed).

## Required fix (one line, additive)

Change line 297 to the same idiom as the other probes:
    $wf = Invoke-RestMethod -Uri "$v3/workflows" -Headers $headers -TimeoutSec 5 -ErrorAction Stop
    $out.Workflows = @($wf).Count
(then the existing `$wf | Where-Object { $_.enabled -eq $false }` works.)
