# T-01 -- SDK load-wait UX: disable/re-enable per-sub-tab Refresh/action buttons around the global load guard

## Read
- `Modules/SP.Gui/SP.MainWindow.psm1`:
  - `Set-SdkSubTabStatus` (ends ~line 4457) -- the shape to mirror (CmdletBinding, `$TabContent` param, Find-Control + null-guard, direct UI-thread write).
  - `Invoke-SdkGridRefresh` (~4459-4620): the SDK read engine; `$script:IsSdkRunning` guard + early-return 'already in progress' message at 4498-4501; `$script:IsSdkRunning = $true` at 4508; completion `finally { $script:IsSdkRunning = $false }` inside the DispatcherTimer `Add_Tick` body (`& $capturedModule {param($t,$ps,$rs,$async,$tab,$statusName,$onLoaded)}`).
  - `Invoke-SdkActionRun` (~4670-4822): the SDK write engine; mirror guard + message at 4711-4714; `$script:IsSdkRunning = $true` at 4721; success path early-clears IsSdkRunning at 4806 then runs `& $onSuccess $tab`; completion `finally` at 4815-4817.
- `Gui/SdkTab.xaml`: confirmed the 23 button x:Names (BtnSdkRefresh* + per-sub-tab action buttons) exist (Refresh anchors at lines 96, 198, 332, 445, 555, 666).
- `Tests/SP.ProductionReadiness.Tests.ps1` (lines 955-998): the `[Parser]::ParseFile` AST idiom mirrored by the new test.

## Did (ADDITIVE only)
1. Added module-private helper `Set-SdkSubTabButtonsEnabled` immediately after `Set-SdkSubTabStatus`. It null-guards `$TabContent`, then for each of the 23 SDK Refresh/action x:Names resolves the Button via `Find-Control`, null-guards the result, and writes `.IsEnabled = $Enabled` directly (UI-thread, mirrors `Set-SdkSubTabStatus`). NOT exported (private like Set-SdkSubTabStatus / Find-Control).
2. `Invoke-SdkGridRefresh`: added `Set-SdkSubTabButtonsEnabled -TabContent $TabContent -Enabled $false` immediately after `$script:IsSdkRunning = $true`.
3. `Invoke-SdkGridRefresh` completion `finally`: added `Set-SdkSubTabButtonsEnabled -TabContent $tab -Enabled $true` beside the IsSdkRunning clear.
4. `Invoke-SdkActionRun`: added `Set-SdkSubTabButtonsEnabled -TabContent $TabContent -Enabled $false` immediately after `$script:IsSdkRunning = $true`.
5. `Invoke-SdkActionRun` completion `finally`: added `Set-SdkSubTabButtonsEnabled -TabContent $tab -Enabled $true` beside the IsSdkRunning clear. (Did NOT add a re-enable at the 4806 early-clear -- OnSuccess re-disables/re-enables; the finally re-enable is the sufficient terminal place.)
6. New Pester file `Tests/SP.SdkLoadUx.Tests.ps1`: 9 pure-AST/text Its (parse-clean, import-clean, helper defined + targets IsEnabled/SDK buttons, both engines disable AFTER setting the guard with correct index order, both engines re-enable in Tick, 'already in progress' messages intact). No dashboard / FlaUI / W-08b.

Existing 'already in progress' status messages and the single-load safety are fully preserved. No exports/behavior removed.

## Files
- `Modules/SP.Gui/SP.MainWindow.psm1`
- `Tests/SP.SdkLoadUx.Tests.ps1`
- `docs/loop-runs/governance-report-hardening-20260605-230050/round-01-t-01.md`

## Verification (real output)

### 1) Parse check
```
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\Modules\SP.Gui\SP.MainWindow.psm1),[ref]$t,[ref]$e)|Out-Null; if($e){...} else {'PARSE OK'}
=> PARSE OK
```

### 2) Import check
```
Import-Module .\Modules\SP.Gui\SP.Gui.psd1 -Force -DisableNameChecking; 'IMPORT OK'
=> IMPORT OK
```

### 3) New test file
```
Invoke-Pester .\Tests\SP.SdkLoadUx.Tests.ps1 -Output Detailed
Tests Passed: 9, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
  [+] Module exists
  [+] parses with zero errors
  [+] imports clean
  [+] defines Set-SdkSubTabButtonsEnabled toggling IsEnabled on SDK buttons
  [+] Invoke-SdkGridRefresh disables buttons after setting IsSdkRunning=$true
  [+] Invoke-SdkActionRun disables buttons after setting IsSdkRunning=$true
  [+] Invoke-SdkGridRefresh re-enables buttons in completion Tick
  [+] Invoke-SdkActionRun re-enables buttons in completion Tick
  [+] keeps the existing "already in progress" single-load message intact
```

## Commit
See structured result (hash + subject).

## Status
DONE
