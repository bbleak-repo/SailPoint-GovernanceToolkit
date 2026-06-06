# Round-05 FIX -- T-01 regression/race hardening + journal hash accuracy

Fixes the three real bugs surfaced by the round-04/05 hunt against the T-01 SDK
load-wait UX work (all ADDITIVE / behaviour-preserving).

## Bugs fixed

1. **T-01 additive/regression violation -- design-disabled button wrongly re-enabled.**
   `Set-SdkSubTabButtonsEnabled` (Modules/SP.Gui/SP.MainWindow.psm1) listed
   `BtnSdkRefreshSummaries` and unconditionally set `IsEnabled=$true` on the
   re-enable pass. That button is `IsEnabled="False"` BY DESIGN in
   `Gui/SdkTab.xaml` L198-200 (Cert-Summaries sub-tab deferred per SDK-18; the
   driving combos `CboSdkCertCampaign/CboSdkCertification/CboSdkAccessType` are
   also disabled). After the first SDK load completed, the blanket re-enable flipped
   this deferred control to clickable while its combos stayed disabled -- an
   inconsistent state and a behaviour change to a pre-existing intentionally-disabled
   control.

2. **T-01 race: action `finally` re-enable vs the chained post-action refresh.**
   In `Invoke-SdkActionRun`'s completion Tick the success path clears the guard and
   runs `$onSuccess` (e.g. `Invoke-SdkTemplateRefresh` -> `Invoke-SdkGridRefresh`),
   which RE-takes `$script:IsSdkRunning=$true` and re-disables the buttons for its
   own background load. Control then returned to the action's `finally`, which
   immediately re-enabled ALL buttons and cleared the guard while that chained
   refresh was still running -- a disable->enable->enable flicker and a window where
   SDK buttons were clickable during the chained load, partly defeating T-01's goal.

3. **Stale journal commit hashes (doc-accuracy).**
   `round-02-t-02.md` recorded `6e0c10c` (actual `c608f78`) and `round-03-t-03.md`
   recorded `9c7dd15` (actual `5e8d8ac`); the audit-trail hashes did not match
   `git log` even though the records self-noted that amends supersede the literal.

## Did

- **Bug 1 -- snapshot/restore prior IsEnabled** (`Set-SdkSubTabButtonsEnabled`):
  on `-Enabled $false` (disable for a load) the helper now SNAPSHOTS each button's
  current `IsEnabled` into a new module-scoped identity-keyed map
  `$script:SdkButtonEnabledSnapshot` (keyed by
  `[RuntimeHelpers]::GetHashCode($btn)` -- PS 5.1 / .NET 4.8 has no
  `ReferenceEqualityComparer` -- with the live control stored alongside for a
  `ReferenceEquals` identity check on read). On `-Enabled $true` it RESTORES the
  snapshotted prior value (default `$true` when no snapshot, preserving legacy
  behaviour for any control that was enabled going in) and removes the entry. Net:
  a control disabled-by-design stays disabled across a load cycle; a normal button
  comes back on. The snapshot write is re-entrancy-safe -- a NESTED disable does
  NOT overwrite an existing snapshot, so the original pre-disable state survives the
  action->chained-refresh nesting.

- **Bug 2 -- chained-refresh ownership** (`Invoke-SdkActionRun` Tick): after the
  success path runs `$onSuccess`, it checks `$script:IsSdkRunning`; if the chained
  refresh re-took the guard, a local `$chainedRefreshOwnsState` flag is set. The
  `finally` now SKIPS the guard-clear + re-enable when that flag is set, handing
  ownership to the chained refresh (which releases both in its own completion Tick).
  No flicker; no clickable window mid-chained-load.

- **Bug 3 -- doc accuracy**: corrected the recorded commit hash in
  `round-02-t-02.md` (`6e0c10c` -> `c608f78`) and `round-03-t-03.md`
  (`9c7dd15` -> `5e8d8ac`), each with an inline note citing
  `git log -- <record>`.

- **Tests**: extended `Tests/SP.SdkLoadUx.Tests.ps1` (additive -- existing 9 It
  blocks unchanged) with 5 new assertions: AST proofs that the snapshot map +
  `RuntimeHelpers::GetHashCode` + `$prior` restore are present and that no blanket
  `$btn.IsEnabled = $Enabled` remains; AST proof of the re-entrancy snapshot guard;
  AST proof of the `$chainedRefreshOwnsState` ownership skip in the action `finally`;
  and TWO functional (InModuleScope, real WPF NameScope) proofs that (a) a
  design-disabled button stays disabled across a full disable->re-enable cycle while
  an enabled one comes back on, and (b) a nested disable/single-enable preserves the
  original enabled state.

## Files
- `Modules/SP.Gui/SP.MainWindow.psm1` (EDIT -- `Set-SdkSubTabButtonsEnabled`
  snapshot/restore + new `$script:SdkButtonEnabledSnapshot` state var;
  `Invoke-SdkActionRun` chained-ownership skip)
- `Tests/SP.SdkLoadUx.Tests.ps1` (EDIT -- +5 additive assertions)
- `docs/loop-runs/governance-report-hardening-20260605-230050/round-02-t-02.md` (EDIT -- hash fix)
- `docs/loop-runs/governance-report-hardening-20260605-230050/round-03-t-03.md` (EDIT -- hash fix)
- `docs/loop-runs/governance-report-hardening-20260605-230050/round-05-fix.md` (this record)

## Verification

### (1) Parse-check (module + test) -- error messages only
```
MODULE PARSE OK
TEST PARSE OK
```

### (2) Affected test file -- Tests/SP.SdkLoadUx.Tests.ps1
`Invoke-Pester -Path .\Tests\SP.SdkLoadUx.Tests.ps1 -Output Detailed`
```
Describing T-01: SDK load-wait UX -- Set-SdkSubTabButtonsEnabled disable/re-enable
  [+] Module exists
  [+] parses with zero errors
  [+] imports clean
  [+] defines Set-SdkSubTabButtonsEnabled toggling IsEnabled on SDK buttons
  [+] Invoke-SdkGridRefresh disables buttons after setting IsSdkRunning=$true
  [+] Invoke-SdkActionRun disables buttons after setting IsSdkRunning=$true
  [+] Invoke-SdkGridRefresh re-enables buttons in completion Tick
  [+] Invoke-SdkActionRun re-enables buttons in completion Tick
  [+] keeps the existing "already in progress" single-load message intact
  [+] Set-SdkSubTabButtonsEnabled snapshots prior IsEnabled instead of forcing $true
  [+] Set-SdkSubTabButtonsEnabled nested disable does not overwrite the original snapshot
  [+] Invoke-SdkActionRun finally skips re-enable when a chained refresh took ownership
  [+] Set-SdkSubTabButtonsEnabled actually keeps a design-disabled button disabled after a load cycle
  [+] Set-SdkSubTabButtonsEnabled nested disable/enable preserves original enabled state
Tests completed in 2.53s
Tests Passed: 14, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### (3) Full suite -- Invoke-Pester .\Tests
```
Starting discovery in 39 files.
Discovery found 1158 tests in 2.34s.
...
Tests completed in 413.51s
Tests Passed: 1158, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
===SUMMARY===
Passed: 1158  Failed: 0  Skipped: 0  Total: 1158
```

Did NOT launch the dashboard / FlaUI / W-08b (human-run gates).

## Commit
`<filled after commit>` -- fix(sdk-gui): preserve design-disabled state + chained-refresh ownership in SDK load-wait UX

## Status
DONE
