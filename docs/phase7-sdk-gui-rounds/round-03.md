# Round 3
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-03 -- Safety / What-If integration in the SDK-tab write dispatchers

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-03 table row + per-item section; Accept = "Pester proves a destructive verb is blocked when its Safety gate is off and proceeds when on")
- `docs/planning/PHASE7_GUI_SDK_TAB.md` ("Safety & What-If Integration" lines 375-398; WPF Framework Note 3 = bridge runs in a background STA runspace, no UI thread)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `docs/phase7-sdk-gui-rounds/round-02.md` (SDK-02 marker placement + global-stub verification style)
- `Modules/SP.Gui/SP.SdkBridge.psm1` (the 5 dispatchers + their `# SDK-03 inserts the Safety / What-If gate here.` markers)
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1:1050-1064` (the defensive Safety-config read idiom that the helper copies)
- `Modules/SP.Core/SP.Config.psm1:84-88 / 437-441` (authoritative Safety defaults: MaxCampaignsPerRun=10, RequireWhatIfOnProd=$true, AllowCompleteCampaign=$false)

**Did:**
Added one private helper `Test-SPGuiSdkSafetyGate` (after `Set-StrictMode`, before the
read regions; NOT exported) returning `@{ Allowed=$bool; Error=$string }`. It reads the
Safety config defensively (Get-SPConfig in a try, `PSObject.Properties['Safety']` +
`PSObject.Properties.Name -contains` guards, `[bool]`/`[int]` casts, fail-safe defaults)
and applies two HARD bridge-side gates: (a) the **AllowCompleteCampaign terminal gate**
(`-IsTerminal` verbs are blocked unless `Safety.AllowCompleteCampaign` is `$true`; default
config is `$false`, so terminal verbs block by default), and (b) the **MaxCampaignsPerRun
bulk cap** (`-IsBulk` with `-ItemCount` over the cap is refused with a message naming the
count and cap -- never truncates). On a config read failure or a missing Safety block the
gate FAILS SAFE (terminal verbs blocked) and never throws. Then I replaced each of the
five `# SDK-03 inserts ...` markers: the gate is called per-verb inside the relevant switch
arms for the classified terminal/destructive verbs -- **WorkItem** Complete/BulkApprove/
BulkReject (`-IsTerminal`), **Template** Delete/RemoveSchedule (`-IsTerminal`), **Filter**
Delete (`-IsTerminal -IsBulk -ItemCount @($FilterId).Count`) -- each as
`$gate = Test-SPGuiSdkSafetyGate ...; if (-not $gate.Allowed) { return @{ Success=$false;
Data=@(); Error=$gate.Error } }` BEFORE any backing SP.Sdk call. Approval and Workflow
dispatchers got their markers replaced with a routing-only Safety note (no
AllowCompleteCampaign gate -- see Plan disagreement below). Existing dispatcher/param
signatures and the Export-ModuleMember list are unchanged (still 14 public functions).

**Files:** modified `Modules/SP.Gui/SP.SdkBridge.psm1`; created this round file.
(Ad-hoc Pester `Tests/_sdk03_adhoc.Tests.ps1` was used for verification then DELETED --
the canonical Safety assertions land in `Tests/SP.SdkBridge.Tests.ps1` under SDK-06, which
also brings the SDK-05 flat-load so `Mock -ModuleName` reaches the call sites.)

**Plan disagreements (resolved by the middle loop per protocol step 3; NOT human-escalated --
only SDK-17/SDK-18 escalate):**
1. **"Mirror the MessageBox" vs no UI thread.** The plan's Safety section (lines 386-390)
   says to show a confirmation MessageBox mirroring `SP.MainWindow.psm1` `Invoke-GuiTestRun`.
   But the bridge is pure/synchronous, never-throws, and runs in a BACKGROUND STA runspace
   (WPF note 3) where there is NO UI thread -- a MessageBox there would throw/deadlock.
   `SP.MainWindow` itself proves the split: it shows the MessageBox on the UI thread BEFORE
   spawning the runspace. RESOLUTION: SDK-03 implements the testable POLICY in the bridge
   (block-vs-allow, returning the `@{Success=$false; Error='blocked by Safety...'}` envelope)
   and the interactive `RequireWhatIfOnProd` MessageBox stays in the UI click-handlers added
   under SDK-11 (which owns the `& $module {} + .GetNewClosure()` wiring, WPF note 2). The
   bridge gate is the enforcement of record; the MessageBox is advisory UX on top. This keeps
   SDK-03 inside its single authorized file and makes the Accept fully headless.
2. **RequireWhatIfOnProd not enforced in the bridge.** Consistent with (1): the bridge cannot
   prompt, so `RequireWhatIfOnProd` is deferred to the SDK-11 handler layer. The bridge's hard
   gates (AllowCompleteCampaign + MaxCampaignsPerRun) are the Accept witnesses (their defaults
   are already $false / 10, giving the headlessly-provable on/off cases).
3. **Approval Deny/Forward and Workflow Toggle/Test/CreateOOO NOT AllowCompleteCampaign-gated.**
   The plan's destructive list (line 381-383) names these, but the SDK-03 Accept explicitly
   expects non-terminal verbs (Approve, Test) to "still route regardless of
   AllowCompleteCampaign" and names only the work-item/template/filter terminal verbs as the
   block/proceed witnesses. Gating Deny/Forward/Toggle/Test/CreateOOO under
   AllowCompleteCampaign would make them blocked-by-default (the config default is $false),
   which is neither asked for by the Accept nor desirable for routine approval triage. Their
   confirmation belongs to the SDK-11 `RequireWhatIfOnProd` MessageBox (per (1)/(2)). The
   bridge gate fires only for the classified terminal/destructive/bulk verbs.

**Verification:** (headless; no live window. `Tests/_sdk03_adhoc.Tests.ps1` used InModuleScope
SP.SdkBridge to define Get-SPConfig + the SP.Sdk backings + Write-SPLog inside the module
session so the dispatchers' internal calls resolve to the stubs -- then deleted, since the
Tests file is SDK-06's.)
  - AST parse (`[Parser]::ParseFile`): **0 errors**.
  - `Import-Module -Force` + `Get-Command -Module SP.SdkBridge` (clean process): **14**
    functions; `Test-SPGuiSdkSafetyGate` is NOT exported.
  - Pester (ad-hoc, 7 tests): **P=7 F=0**. Cases proved:
    * BLOCKED-when-off: AllowCompleteCampaign=$false -> WorkItem Complete, Template Delete,
      Filter Delete all return `Success=$false` / Error matches 'blocked by Safety' AND zero
      backing calls.
    * PROCEEDS-when-on: AllowCompleteCampaign=$true -> Complete/BulkApprove/BulkReject/
      Template Delete/RemoveSchedule fall through, return Success=$true, backing invoked once each.
    * Bulk-cap (no truncation): MaxCampaignsPerRun=2 -> Filter Delete with 3 ids blocked,
      Error names '3 items' and 'MaxCampaignsPerRun (2)', backing NOT called; with 2 ids it
      proceeds and the backing receives ALL 2 ids.
    * Non-destructive verbs unaffected: Approve / Test / Forward route to their backings even
      with AllowCompleteCampaign=$false.
    * Defensive default: Get-SPConfig throws -> terminal verb BLOCKED, never throws, backing
      not called; Get-SPConfig returns no Safety block -> terminal verb BLOCKED.
  - PSScriptAnalyzer (Warning+Error): **9 findings, all PRE-EXISTING SDK-01 read-function items**
    (8x PSUseSingularNouns on the `Get-...s` reads; 1x PSReviewUnusedParameter on the SDK-01
    `IncludeSystem` switch). The new helper + 7 gate call-sites introduce **0 new findings**
    (Test-SPGuiSdkSafetyGate is a singular approved-verb noun and uses all its params).
  - XAML parse: n/a (no XAML touched).
  - Manifest/import: import OK (above); no psd1 touched (SDK-04).

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-03 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS
