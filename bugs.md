# SailPoint Governance Toolkit — Bug Log

Findings from a no-ISC-line-of-sight test run on a real Windows box. Everything here was reproducible; none of it required network access to SailPoint ISC.

## Test environment

- Host: Windows 11 Pro 10.0.26200
- PowerShell: 5.1.26100.8115 Desktop edition
- Pester: 5.7.1 (also 3.4.0 present — 5.x selected via `Import-Module Pester -MinimumVersion 5.0`)
- Toolkit path: `C:\temp\Coding\SailPoint\SailPoint-GovernanceToolkit`
- settings.json: unmodified template (all `CHANGE_ME` values)
- Invocation: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ...` from a bash shell

## What works

Don't want to lose sight of the passing paths while we fix the bugs:

- `-WhatIf` dry-runs for `Invoke-GovernanceTest.ps1` (smoke / regression / full) — 1/2/4 tests PASS, exit 0, no network attempts.
- CSV cross-validation works (`test-identities.csv` ↔ `test-campaigns.csv`).
- Test-SPConnectivity Step 1 (config load + validation) passes.
- Exit-code contract for known failure modes: audit no-filter → 2, unknown TestId → 4.
- `-Help` / `Get-Help` responds on all four scripts.
- SP.Vault Pester tests all pass (slow — ~331s total for PBKDF2 600k iters across cases, expected).

**Assessment:** once real tenant values replace `CHANGE_ME` and ISC is reachable, live runs should succeed. The issues below are mostly around the test harness itself and defensive behavior on misconfiguration.

---

## Bug 1 — Pester suite: 56 of 207 tests fail on PS 5.1 Desktop

**Severity:** High (test harness credibility)

**Status:** Reproducible

### Summary
DEV.md claims the mock-scoping issue is PS7-only ("55 test failures on PS7 — they pass on PS 5.1 Desktop where mock scoping is more permissive"). On this box (PS 5.1 Desktop, Pester 5.7.1), we got **56 failures** — matching the PS7 symptom exactly.

### Evidence
```
Tests Passed: 151, Failed: 56, Skipped: 0  (of 207)
Duration: ~532s
```

Representative failure — AUTH-001:
```
Expected $true, but got $false.
at $result.Success | Should -Be $true, ...\SP.Auth.Tests.ps1:82
```

Smoking-gun evidence from ASRT-002:
```
Expected regular expression 'API unavailable' to match
'Get-SPCampaign failed: Auth token acquisition failed:
 The remote name could not be resolved: change_me.identitynow.com'
```
The real `Invoke-RestMethod` ran against the `change_me.identitynow.com` hostname from the real `Config/settings.json`, proving the `Mock Invoke-RestMethod -ModuleName SP.Auth { ... }` didn't intercept.

### Likely cause
Tests import `Modules\SP.Core\SP.Core.psd1` — an aggregator manifest whose `NestedModules` loads `SP.Auth.psm1`, `SP.Config.psm1`, etc. Mock targets `-ModuleName SP.Auth`. On the nested-module loading path (even on PS 5.1 Desktop in our harness), the mock isn't reaching the scope where `Invoke-RestMethod` is actually resolved. The DEV.md "PS 5.1 is permissive" assumption appears to be wrong, or something about our specific Pester 5.7.1 / module load order changed the behavior.

### Failing test groups
- AUTH-001 through AUTH-005 (SP.Auth)
- API-003 (retry-on-5xx)
- ASRT-001, ASRT-002 (Assert-SPCampaignStatus)
- AQ-005 (Get-SPAuditCampaignReport)
- DEC-001 through DEC-004 (SP.Decisions reassign / sign-off / batching)
- …and more in the 56 total

### Reproducer
```powershell
cd C:\temp\Coding\SailPoint\SailPoint-GovernanceToolkit
Import-Module Pester -MinimumVersion 5.0 -Force
$config = New-PesterConfiguration
$config.Run.Path = '.\Tests'
$config.Run.PassThru = $true
Invoke-Pester -Configuration $config
```

### Next steps
1. Pick one failing test (suggest AUTH-001 — smallest surface) and trace scope with `Get-Module`, `Get-Command Invoke-RestMethod` *after* the mock is declared.
2. Try one of:
   - Import each nested `.psm1` directly in the test file instead of the `.psd1` aggregator.
   - Change the mock targeting — possibly needs `-ModuleName SP.Core` since that's the containing manifest.
   - Add a `BeforeAll`-level `Import-Module SP.Auth` to force a top-level module scope.
3. Fix pattern once, apply across failing test files.

---

## Bug 2 — `Test-SPConfigFirstRun` doesn't detect `CHANGE_ME` placeholders

**Severity:** High (defensive guard doesn't guard)

**Status:** Reproducible

### Summary
The README / QUICKSTART strongly imply the toolkit will detect `CHANGE_ME` values and exit with guidance. It does not. `Test-SPConfigFirstRun` only checks for a `_FirstRun` PSNote property — absent from any real loaded config — so it returns `$false` even when every tenant field literally says `CHANGE_ME`.

### Evidence
`Modules\SP.Core\SP.Config.psm1:471`:
```powershell
return ($Config.PSObject.Properties.Name -contains '_FirstRun' -and $Config._FirstRun -eq $true)
```

With the unmodified template, running `Test-SPConnectivity.ps1` yields:
```
[PASS] Step 1: Load and validate settings.json (126ms)
       Environment: CHANGE_ME | Mode: ConfigFile
[FAIL] Step 2: Acquire OAuth 2.0 bearer token (110ms)
       Token acquisition failed: The remote name could not be resolved: 'change_me.identitynow.com'
```
Step 1 reports PASS with `Environment: CHANGE_ME` — the operator would reasonably expect the first-run guard to fire here.

### Fix direction
Either:
- Add a scan in `Test-SPConfigFirstRun` for any string field matching `^CHANGE_ME` across `Authentication.ConfigFile.*`, `Api.BaseUrl`, etc.
- Or surface a separate `Test-SPConfigHasPlaceholders` check and call it from `Test-SPConnectivity.ps1` before Step 2.

---

## Bug 3 — `Invoke-SPCampaignAudit.ps1` does not support `-WhatIf`

**Severity:** Medium (doc / feature mismatch)

**Status:** Reproducible

### Summary
README "Security Considerations" says: *"All scripts support -WhatIf. Pass -WhatIf during initial validation to confirm CSV data and configuration without making any API calls."* The audit script does not.

### Evidence
```
PS> .\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7 -WhatIf
Invoke-SPCampaignAudit.ps1 : A parameter cannot be found that matches parameter name 'WhatIf'.
```

`Scripts\Invoke-SPCampaignAudit.ps1:87` uses bare `[CmdletBinding()]` — no `SupportsShouldProcess`.

### Fix
Add `[CmdletBinding(SupportsShouldProcess)]` and gate any outbound API call (`Get-SPAuditCampaigns`, `Get-SPAuditCertifications`, etc.) behind a `-WhatIf` branch that only prints what would be fetched. Or update README to say "-WhatIf is supported on `Invoke-GovernanceTest.ps1`" and call out audit as read-only.

Note: the audit script is read-only in intent, so arguably `-WhatIf` is cosmetic. But docs promise it.

---

## Bug 4 — `ShouldProcess` NullReferenceException in non-interactive host

**Severity:** Medium (only bites via `-Command`)

**Status:** Reproducible under specific invocation

### Summary
`Invoke-GovernanceTest.ps1` (which legitimately uses `SupportsShouldProcess`) throws when `ShouldProcess` is called without an interactive host to confirm against.

### Evidence
```
PS> powershell.exe -NoProfile -Command ".\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke"
Exception calling "ShouldProcess" with "2" argument(s):
"Object reference not set to an instance of an object."
at Scripts\Invoke-GovernanceTest.ps1:181
```

`Scripts\Invoke-GovernanceTest.ps1:181`:
```powershell
if (-not $PSCmdlet.ShouldProcess($target, $message)) { ... exit 2 }
```

### Workaround
Passing `-Confirm:$false` lets execution proceed normally (observed: got past the guard, TC-001 ran and failed cleanly on the expected `change_me.identitynow.com` DNS error).

### Fix direction
Detect non-interactive host (`$Host.UI.RawUI` null, or `[Environment]::UserInteractive -eq $false`, or inspect `$Host.Name -eq 'ConsoleHost'` + `$PSCmdlet.Host.UI` availability) and skip or stream-confirm. Alternatively wrap the `ShouldProcess` call in try/catch and treat any exception as "operator hasn't confirmed — abort".

This matters for CI/CD runs or any orchestrator-launched invocation.

---

## Bug 5 — Bad `-ConfigPath` silently creates directories and writes template

**Severity:** Medium (typo → files in unexpected places)

**Status:** Reproducible

### Summary
Passing a `-ConfigPath` that points to a non-existent path causes the toolkit to silently create the parent directory tree and drop a fresh `CHANGE_ME` template there. No warning about the typo.

### Evidence
```
PS> .\Scripts\Invoke-GovernanceTest.ps1 -ConfigPath 'C:\does\not\exist.json' -WhatIf
================================================================================
  SAILPOINT ISC GOVERNANCE TOOLKIT - FIRST RUN SETUP
================================================================================
  A default configuration file has been created at:
  C:\does\not\exist.json
...
```
After: `C:\does\not\exist.json` exists; `C:\does\` was freshly created. (Cleaned up with `rm -rf C:/does/`.)

The behavior lives in `Modules\SP.Core\SP.Config.psm1` `New-SPConfigFile` (around line 494), which calls `New-Item -Path $configDir -ItemType Directory -Force`.

### Fix direction
Only auto-create the default path (`..\Config\settings.json`). For an explicit `-ConfigPath`, require the parent directory to exist — error out clearly if not. Or at minimum, prompt / require a `-Force` / `-InitConfig` flag to actually create the new file.

---

## Suggested triage order

1. **Bug 2** — easiest win, tightens real defensive behavior users will hit immediately.
2. **Bug 5** — small scope, similar flavor to #2.
3. **Bug 3** — if audit is truly read-only, a README edit is cheaper than wiring `-WhatIf`.
4. **Bug 1** — biggest scope; pick one failing test, trace, decide on a mocking pattern, apply it across files.
5. **Bug 4** — only matters for headless / CI execution. Fix after #1.

---

## Bug 6 — GUI: event handlers reference outer-function locals; crashes under StrictMode

**Severity:** High (1 confirmed crash; 20+ latent)

**Status:** Test Connectivity handler fixed; others still vulnerable

### Summary
Every `Add_Click({ ... })` handler in `Modules\SP.Gui\SP.MainWindow.psm1` references local variables from the enclosing `Initialize-*Tab` function (e.g. `$connStatus`, `$progressBar`, `$pbBrowserToken`). When the handler fires later, it runs in module scope and the local vars are not reliably visible. Under `Set-StrictMode -Version 1` (set at top of file) this raises `The variable '$X' cannot be retrieved because it has not been set`, the exception bubbles up through `Dispatcher.Invoke`, `ShowDialog()` returns, and the dashboard dies.

### Evidence
User clicked Test Connectivity in the Settings tab:
```
ERROR: Dashboard failed to launch: Exception calling "ShowDialog" with "0" argument(s):
"The variable '$connStatus' cannot be retrieved because it has not been set."
at Show-SPDashboard, ...\SP.MainWindow.psm1: line 1333
```

### Latent handlers with the same pattern (22 total)
Lines in `Modules\SP.Gui\SP.MainWindow.psm1`: 192, 199, 212, 225, 423, 438, 546, 553, **568 (fixed)**, 591, 614, 803, 810, 826, 833, 844, 1198, 1204, 1216, 1235.

### Fix applied (Test Connectivity only, line 568)
- Replaced reference to local `$connStatus` with a fresh `Find-Control -Parent $script:MainWindow -Name 'ConnectivityStatusText'` inside the handler (module-scope vars are always visible).
- Wrapped the body in try/catch + `Write-SPLog` + soft `Set-StatusMessage`.

### Safety net added
Before `ShowDialog()` (around line 1350): `Dispatcher.add_UnhandledException` hook that logs any future event-handler exception via `Write-SPLog` and sets `$e.Handled = $true` so the dashboard stays alive instead of tearing down. Plus a one-time `Initialize-SPLogging -Force` call at dashboard startup (this was missing — the dashboard was the only entry-point script that did not initialize structured logging, which is why the first `Write-SPLog` attempt silently no-op'd).

### Remaining work
Two reasonable options for the other 20+ handlers:
1. **Quickest:** add `.GetNewClosure()` to every `Add_Click({ ... })` — captures the outer locals into the script block at declaration time. Mechanical, low-risk.
2. **Cleanest:** refactor each handler to re-find its controls via `$script:MainWindow.FindName(...)` instead of closing over locals. More work, but makes the pattern obvious and removes reliance on closure semantics.

Given that only handlers that actually get clicked will crash, the dispatcher safety net makes option 1 or 2 a "next sprint" item rather than a blocker — the window will no longer die, but each broken handler will simply not do its work until it's fixed.

---

## Bug 7 — WPF `ProgressBar.CornerRadius` is not a valid property (FIXED)

**Severity:** High — prevented dashboard from loading at all

**Status:** FIXED on 2026-04-17

### Summary
`MainWindow.xaml` and `AuditTab.xaml` set `CornerRadius="4"` directly on `<ProgressBar>` elements. WPF's `ProgressBar` has no such property (only `Border` does). `XamlReader.Load` threw immediately and `Show-SPDashboard.ps1` aborted before the window could appear.

### Fix
Removed the invalid attribute from three ProgressBars:
- `Gui\MainWindow.xaml:254` (SuiteProgressBar)
- `Gui\MainWindow.xaml:641` (AuditProgressBar)
- `Gui\AuditTab.xaml:237` (AuditProgressBar — defensive; file appears unused by the launcher but kept in sync)

If rounded corners are desired later, wrap the ProgressBar in a styled `Border`, or retemplate via a `Style` + `ControlTemplate`. Not worth it for V1.

### Aside: dead XAML copies
`Show-SPDashboard.ps1` only loads `Gui\MainWindow.xaml` — which inlines all four tab UIs. The separate `CampaignTab.xaml`, `EvidenceTab.xaml`, `SettingsTab.xaml`, and `AuditTab.xaml` files appear to be unused copies. Candidates for deletion in a cleanup pass (and a source of drift — we just saw `AuditTab.xaml` had the same ProgressBar bug that was also in `MainWindow.xaml`).

---

## Bug 8 — Settings tab form was empty (FIXED)

**Severity:** High — users could not edit settings.json values via the GUI

**Status:** FIXED on 2026-04-17 (form inlined into `MainWindow.xaml`)

### Summary
`MainWindow.xaml` had this placeholder on the Settings tab:
```xml
<!-- Settings form - loaded from SettingsTab.xaml content via code -->
<ContentControl x:Name="SettingsFormHost"/>
```
The comment said "loaded from SettingsTab.xaml content via code" but **no injection code was ever written**. `Load-SettingsForm` (`Modules\SP.Gui\SP.MainWindow.psm1:642`) then called `Find-Control` for `TxtEnvironmentName`, `TxtTenantUrl`, `ChkDebugMode`, `ChkAllowComplete`, etc. — those controls only existed in the orphaned `Gui\SettingsTab.xaml` file that the launcher never loads. Every `Find-Control` returned null, every `$setField` silently skipped, and the Settings tab showed only the Quick Connect browser token section + the three bottom buttons.

### Fix applied
Inlined the Environment / Authentication / API / Testing / Safety sections from `SettingsTab.xaml` directly into `MainWindow.xaml`, matching the pattern used by the Campaign, Evidence, and Audit tabs (which are also fully inlined). Also added the six missing styles (`FieldLabel`, `FieldBox`, `FieldPassword`, `FieldCombo`, `SectionHeader`, `SectionBorder`) to `MainWindow.xaml`'s `Window.Resources` so the inlined fields render correctly.

The Quick Connect browser token section and the three action buttons (Save / Reset / Test Connectivity) were already present in `MainWindow.xaml` and were left in place — they were NOT duplicated from `SettingsTab.xaml`.

### Verified
Offline XAML parse + `FindName` lookup returns `TextBox` / `PasswordBox` / `CheckBox` / `ComboBox` / `Button` objects for all 12 sample controls checked.

### Remaining follow-ups

**Browse buttons are not wired.** `BtnBrowseIdentities`, `BtnBrowseCampaigns`, `BtnBrowseEvidence`, `BtnBrowseReports` render but have no `Add_Click` handler in `Initialize-SettingsTab`. Clicking does nothing. Needs a small `OpenFileDialog` / `FolderBrowserDialog` adapter and click handlers wired for each.

**PasswordBox values don't round-trip.** `Load-SettingsForm` and `Save-SettingsForm` (`SP.MainWindow.psm1:660`, `698`) only handle `TextBox` / `CheckBox` / `ComboBox` types. The new `PbClientSecret` field won't auto-populate from settings.json on load (reasonable — don't display secrets), and won't save back either (less reasonable — user edit is lost). Either:
- Explicitly opt-in: on load, ignore; on save, only write to settings.json when `PbClientSecret.Password` is non-empty (keeps existing secret if user didn't touch the field).
- Or remove the field entirely from the GUI and require `New-SPVault.ps1` for secrets.

**`SettingsTab.xaml` remains orphaned.** Now even more clearly dead — but deleting it is out-of-scope for this fix pass (see also Bug 7's note about other dead `*Tab.xaml` copies).

---

## 2026-04-17 follow-up pass — GUI cleanup

Batch fixes to close out Bug 6 / Bug 8 follow-ups and add an explicit exit UX.

### Fixed in `Modules\SP.Gui\SP.MainWindow.psm1` + `Gui\MainWindow.xaml`

1. **Explicit Close button** (top-right of menu bar, `x:Name="BtnCloseApp"`). Calls `$script:MainWindow.Close()`, same as `File > Exit` / title-bar X / Alt+F4. Visible, labeled, reachable without opening a menu.

2. **Bug 6 closed.** Added `.GetNewClosure()` to every `Add_Click` / `Add_SelectedItemChanged` / `Add_MouseDoubleClick` handler that referenced local variables from its enclosing `Initialize-*Tab` function — 22 total across Campaign, Evidence, Settings, Audit tabs. Under `Set-StrictMode -Version 1` these handlers previously raised `variable X cannot be retrieved because it has not been set` at fire-time; now the caller's locals are embedded at declaration time and remain visible. Menu handlers were already safe (only `$script:*` references).

3. **Bug 8 follow-up — Browse buttons wired.**
   - `BtnBrowseIdentities`, `BtnBrowseCampaigns` → `Microsoft.Win32.OpenFileDialog` (CSV filter, seeded with current path).
   - `BtnBrowseEvidence`, `BtnBrowseReports` → `System.Windows.Forms.FolderBrowserDialog` (seeded with current path).
   - Two thin helpers added: `Invoke-GuiFilePicker` and `Invoke-GuiFolderPicker`. They locate the target TextBox via `$script:MainWindow.FindName` (closure-safe).

4. **Bug 8 follow-up — `PbClientSecret` round-trip fixed, and an existing data-loss bug resolved.** `Save-SettingsForm` previously hardcoded `ClientSecret = 'VAULT_OR_ENV_ONLY'` on every save, silently overwriting any real secret on disk whenever the user clicked "Save Settings". New behavior: if `PbClientSecret.Password` is non-empty, write it; otherwise preserve whatever is already in `settings.json` (via a fresh `Get-SPConfig`). Never writes an empty string and never silently replaces a populated secret. Load path intentionally still does not populate the password box — avoids surfacing secrets on the screen.

### Verified
- Offline XAML parse + FindName: all 7 sample controls resolve (`BtnCloseApp`, 4 Browse buttons, `PbClientSecret`, `MenuExit`).
- Dashboard launches with log entry `SP.Gui / Start / Dashboard launched` in `Logs\GovernanceToolkit_2026-04-17.json`.
- `Dispatcher.UnhandledException` safety net from the earlier pass remains in place, so any remaining handler surprise will log + keep the window alive rather than crash.

### Not done in this pass
- Dead `Gui\*Tab.xaml` copies (Bug 7 aside) still on disk. Deletion is a separate cleanup.
- Bug 1 (Pester mock scoping on PS 5.1 Desktop), Bug 2 (CHANGE_ME detection), Bug 3 (`-WhatIf` on audit), Bug 4 (`ShouldProcess` non-interactive), Bug 5 (`-ConfigPath` auto-creates bogus dirs) — all still open from the initial triage.

---

## 2026-04-19 follow-up pass — open bugs sweep (branch: fix/open-bug-followups)

### Status after this pass

| # | Title | Status |
|---|---|---|
| 1 | Pester mock scoping — 56/207 failures | **Mostly fixed** (201/207 passing; 6 per-test issues remain — see below) |
| 2 | `Test-SPConfigFirstRun` doesn't detect `CHANGE_ME` | **FIXED** |
| 3 | `Invoke-SPCampaignAudit.ps1` missing `-WhatIf` | **FIXED** |
| 4 | `ShouldProcess` `NullReferenceException` in non-interactive host | **FIXED** |
| 5 | Bad `-ConfigPath` silently creates dirs | **FIXED** |
| 6 | GUI handler closure pattern | Fixed 2026-04-17 |
| 7 | `ProgressBar.CornerRadius` XAML | Fixed 2026-04-17 |
| 8 | Settings tab empty form | Fixed 2026-04-17 |

### Bug 2 fix — `Test-SPConfigFirstRun` detects `CHANGE_ME`

`Modules\SP.Core\SP.Config.psm1:445` — function now scans a curated list of required fields (`Authentication.ConfigFile.TenantUrl` / `OAuthTokenUrl` / `ClientId` / `ClientSecret`, `Api.BaseUrl`) for case-insensitive `CHANGE_ME` in addition to the pre-existing `_FirstRun` marker check. Verified: `Test-SPConnectivity.ps1` against an unmodified template now FAILs step 1 with "First-run configuration detected" instead of proceeding to a confusing DNS error on step 2.

### Bug 5 fix — `New-SPConfigFile` refuses to create parent dirs

`Modules\SP.Core\SP.Config.psm1:503` — throws `DirectoryNotFoundException` if the parent directory is missing, instead of `New-Item -Force`-ing a whole tree. `Get-SPConfig`'s existing try/catch surfaces this as a clean error at the entry script. Verified: `-ConfigPath 'C:\does\not\exist.json'` now prints `Cannot create config file: parent directory does not exist` and exits 4; `C:\does\` is not materialized. Regression in four CFG-007 tests (which relied on the old auto-create behavior) fixed in the same branch.

### Bug 4 fix — graceful `ShouldProcess` in non-interactive host

`Scripts\Invoke-GovernanceTest.ps1:173` — WhatIf guard now:
1. Short-circuits if `-Confirm:$false` or `$ConfirmPreference = 'None'` was already supplied.
2. Wraps `$PSCmdlet.ShouldProcess` in try/catch. On exception, prints actionable guidance ("Re-run with -WhatIf or -Confirm:$false") and exits 2.

Verified across three paths: no args → exit 2 with message (was: uncaught NullRef); `-WhatIf` → exit 0; `-Confirm:$false` → bypass, run, DNS fail → exit 1.

### Bug 3 fix — `-WhatIf` on `Invoke-SPCampaignAudit.ps1`

`Scripts\Invoke-SPCampaignAudit.ps1:87` — `[CmdletBinding(SupportsShouldProcess)]`. A `-WhatIf` short-circuit after config load + filter parsing prints exactly what would be queried (filters, output path, correlation ID) and exits 0 without any API call. Logs `Audit skipped: -WhatIf` for audit-trail parity.

### Bug 1 fix — Pester mock scoping (151 → 201 passing)

Two structural changes in the test harness:

1. **Direct `.psm1` imports via new `Tests/Import-TestModules.ps1`.** Test files previously imported `SP.Core.psd1` and other aggregator manifests, making each nested `.psm1` a *nested* module scope. Pester 5.7.1 on PS 5.1 Desktop does not reliably intercept mocks with `-ModuleName <nested-name>` in that layout. Helper imports each `.psm1` directly as a top-level module. Every `BeforeAll` became:
   ```powershell
   . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
   Import-SPTestModules -Core -Api [-Audit] [-Testing]
   ```
   The DEV.md claim that PS 5.1 was permissive to this pattern is wrong on Pester 5.7.1; the fix is required.

2. **`-ModuleName` added to cross-module mocks.** Mocks for functions called from a different module than the SUT's home (e.g. mocking `Get-SPCampaign` when exercising `Assert-SPCampaignStatus`) were missing `-ModuleName`. Added `-ModuleName SP.Assertions` across `SP.Assertions.Tests.ps1`, `-ModuleName SP.BatchRunner` across `SP.BatchRunner.Tests.ps1`, including the corresponding `Should -Invoke` assertions.

**Result:** 201/207 passing, 6 failing (~97% pass rate). Up from 151/207.

### Remaining 6 test failures (out of Bug 1 scope — per-test issues, not structural)

| Test ID | File | Suspected class of issue |
|---|---|---|
| API-003 (×2) | `SP.ApiClient.Tests.ps1` | Mock throws a half-built `WebException`; `Invoke-SPApiRequest`'s retry logic doesn't recognize it as a 500, so no retry fires. Mock fidelity, not scoping. |
| AQ-005 | `SP.AuditQueries.Tests.ps1` | `Get-SPAuditCampaignReport` "handles unavailable report API" — specific assertion about task-ID-returning endpoint. |
| BATCH-001 | `SP.BatchRunner.Tests.ps1` | Suite aggregation — `Results.Count` expected 3, got 0. Mock return-shape mismatch is the leading candidate. |
| BATCH-003 | `SP.BatchRunner.Tests.ps1` | 10-step WhatIf flow; expects specific step counts / SKIP markers. |
| DEC-001 | `SP.Decisions.Tests.ps1` | **Confirmed real production bug. FIXED 2026-04-19** on branch `fix/bulk-decide-single-batch-unwrap`. See Bug 9 below. |

All six are individually scoped. Treat each as its own follow-up commit / PR.

---

## Bug 9 — `Invoke-SPBulkDecide` makes N individual API calls instead of 1 batched call when item count equals BatchSize (FIXED)

**Severity:** High — real production bug with rate-limit and performance implications against live ISC

**Status:** FIXED on 2026-04-19 on branch `fix/bulk-decide-single-batch-unwrap`

### Summary
DEC-001 test flagged it: submitting exactly 250 items (the documented ISC batch size) resulted in 250 individual `POST /certifications/{id}/decide` calls with 1 item each, instead of 1 call with 250 items. The pattern generalized to any item count that fit in a single batch. Against a real ISC tenant this would chew through the sliding-window rate limit (95 req / 10 s) in seconds for any large certification.

### Root cause
`Modules\SP.Api\SP.Decisions.psm1:22` — `Split-SPItemsIntoBatches` uses:
```powershell
$batches = [System.Collections.Generic.List[object[]]]::new()
...
return $batches
```

PowerShell's pipeline auto-unwraps collections returned from functions. When the list contains **exactly one element** (one batch), the caller receives the inner `object[]` directly instead of the list. The caller's `foreach ($batch in $batches)` then iterates the 250 item-id strings one at a time, and each "batch" in the loop is a single string — so 250 `Invoke-SPApiRequest` calls get made.

When the list has 2+ elements (e.g. 500 items → 2 batches of 250), PowerShell emits each batch as a pipeline item, the caller gets an array of batch arrays, and the loop works correctly. That asymmetry is exactly why the 500-item test passed and the 250-item test failed.

### Fix
Change `return $batches` to `return ,$batches`. The unary comma operator wraps the return in a one-element array, so PowerShell's pipeline unwrapping emits the list as a single pipeline object and the caller receives the list intact, regardless of how many batches it contains.

### Verified
- `Invoke-Pester -Path .\Tests\SP.Decisions.Tests.ps1` → 18/18 passing (was 17/18 with DEC-001 failing)
- Full suite: 202/207 passing (was 201/207)
- No regressions on the 500-item or 251-item batch tests

### Remaining 5 failures (now, not 6)
Same as listed above minus DEC-001: API-003 (×2), AQ-005, BATCH-001, BATCH-003.

---

_Logged on 2026-04-17 (Bugs 6–8), updated 2026-04-19 (Bugs 1–5 swept + Bug 9 caught & fixed). Source: no-ISC-line-of-sight sessions on Windows 11 / PS 5.1 Desktop / Pester 5.7.1._
