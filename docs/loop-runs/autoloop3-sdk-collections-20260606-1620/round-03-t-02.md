# T-02 -- Toolkit: make W-08b interactive SDK test data-adaptive (read expected counts from the live mock at runtime)

## Read
- `Tests/Harness/Test-W08b-SdkTabInteractive.ps1` lines 210-310 (the `Get-SPMockExpectedCounts`
  probe helper). Confirmed 6 of 7 collection probes already use the correct Pattern A
  idiom (`$r = Invoke-RestMethod ...` then `@($r).Count`). The workflows probe at lines
  296-303 used a different, buggy idiom: it wrapped the `Invoke-RestMethod` call DIRECTLY
  in `@(...)`, collapsing the deserialized JSON array into a single wrapper object so
  `$wf.Count` returned 1 (should be 4) and the `Where-Object { $_.enabled -eq $false }`
  filter found nothing (wrapper has no `.enabled`), leaving `DisabledWorkflowId` empty.
- `Gui/MainWindow.xaml` -- confirmed all 19 SDK-tab AutomationIds used by the test exist.

## Did
Single targeted, additive fix (the only defect the reviewer flagged). In
`Get-SPMockExpectedCounts`:
- Line 297 OLD: `$wf = @(Invoke-RestMethod -Uri "$v3/workflows" -Headers $headers -TimeoutSec 5 -ErrorAction Stop)`
  NEW: `$wf = Invoke-RestMethod -Uri "$v3/workflows" -Headers $headers -TimeoutSec 5 -ErrorAction Stop`
- Line 298 OLD: `$out.Workflows = $wf.Count`
  NEW: `$out.Workflows = @($wf).Count`

This mirrors the exact Pattern A idiom used by every other probe in the same function
(campaign-templates, approvals, work-items, campaign-filters). Lines 299-303 (the comment +
the `$disabled = @($wf | Where-Object { $_.enabled -eq $false })` filter + the
`DisabledWorkflowId` assignment) were left EXACTLY as-is -- once `$wf` is the real array
they already yield `wf-004`. No other lines changed. Script remains AUTHOR-ONLY; the live
STA FlaUI W-08b was NOT executed.

## Files
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\Harness\Test-W08b-SdkTabInteractive.ps1`
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\docs\loop-runs\autoloop3-sdk-collections-20260606-1620\round-03-t-02.md` (this record)

## Verification

### 1) Parse/compile (assert parseErrors=0)
```
PS> $errs=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/Harness/Test-W08b-SdkTabInteractive.ps1',[ref]$null,[ref]$errs); 'parseErrors=' + @($errs).Count
parseErrors=0
```

### 2) Live helper execution against running mock (http://localhost:8080)
Extracted the `Get-SPMockExpectedCounts` function (src lines 210-310) into a scratch .ps1,
dot-sourced it, and invoked it (avoids the script body's `exit`/STA requirement):
```
Templates          : 10
ApprovalsPending   : 4
ApprovalsCompleted : 4
WorkItemsOpen      : 7
WorkItemsCompleted : 23
WorkItemsTotal     : 30
ShowCompletedTotal : 30
Workflows          : 4
DisabledWorkflowId : wf-004
Filters            : 3
```
The previously-wrong fields are now correct: **Workflows=4** and **DisabledWorkflowId=wf-004**.
All other fields unchanged from the prior (already-correct) refactor.

### 3) No bad idiom survives
```
Grep `@\(Invoke-RestMethod`  in harness -> 0 matches
Grep `\$out\.Workflows = @\(\$wf\)\.Count`  -> 1 match (line 298)
Grep `\$wf = Invoke-RestMethod`  -> 1 match (line 297)
```

### 4) No live hard-coded literals driving PASS/FAIL
```
Grep `-Expected 3|-Expected 4|-Expected 6|-eq '4'|-eq '2'|-eq '6'|'wf-004'`
 -> only hit: line 300 `# rather than hard-coding 'wf-004' -- robust to any seed.` (COMMENT)
```

### 5) x:Name cross-check (all >=1 in Gui/MainWindow.xaml)
SdkTemplateGrid=1, SdkApprovalGrid=1, RbSdkPending=1, RbSdkCompleted=1, SdkWorkItemGrid=1,
SdkWiBadgeOpen=1, SdkWiBadgeCompleted=1, SdkWiBadgeTotal=1, ChkSdkShowCompleted=1,
SdkWorkflowGrid=1, ChkSdkIncludeSystem=1, SdkFilterGrid=1, SdkExecutionGrid=1,
BtnSdkViewExecutions=1, SdkWorkItemStatusLabel=1, BtnSdkRefreshTemplates=1,
BtnSdkRefreshApprovals=1, BtnSdkRefreshWorkflows=1, BtnSdkRefreshFilters=1.

DID NOT run: Invoke-Pester on the harness, the full suite (Finalize only), the WPF
dashboard, or the STA FlaUI W-08b (deferred human gate).

## Commit
fix(test): W-08b workflows probe -- count served JSON array correctly (4 not 1)
(branch feature/manager-cert-30day-sim; not pushed). See `git log -1` for the
current HEAD hash (the record was amended into the same commit, so the hash is
the latest HEAD on the branch).

## Status
DONE
