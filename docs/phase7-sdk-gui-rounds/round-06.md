# Round 6
**Started:** <START_TIMESTAMP>
**Item:** SDK-06 -- Tests/SP.SdkBridge.Tests.ps1 (SDK-BR-001..007 + Safety)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-06 row line 35 + section lines 148-161)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (bridge mapping table, Safety & What-If integration, Test Plan ~line 516)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round-file template + headless toolbox)
- `docs/phase7-sdk-gui-rounds/round-05.md` (SDK-05 forward note flagging the Invoke-SPApiRequest plan error)
- `Modules/SP.Gui/SP.SdkBridge.psm1` (READ-ONLY -- 9 Get-SPGuiSdk* reads, 5 Invoke-SPGuiSdk*Action dispatchers, private Test-SPGuiSdkSafetyGate)
- `Tests/Import-TestModules.ps1` (Import-SPTestModules -SdkBridge, wired by SDK-05)
- `Tests/SP.SdkApprovals.Tests.ps1` (style/convention template)
- `Modules/SP.Sdk/*` (confirmed wrapper fn names: Get-SPSdkTemplateSchedule, Get-SPSdkWorkItemsSummary, New-SPSdkPatchReplace, Set-SPSdkOOOFallbackWorkflow, Test-SPSdkWorkflow, Update-SPSdkWorkflow, Complete-SPSdkWorkItem, Remove-SPSdkCampaignTemplate, Remove-SPSdkCampaignFilter)

**Did:** Created `Tests/SP.SdkBridge.Tests.ps1`, a pure Pester 5.x unit test (no live mock
server, no network, no UI). `BeforeAll` dot-sources Import-TestModules.ps1 and calls
`Import-SPTestModules -Core -Api -Sdk -SdkBridge` (flat import so `Mock -ModuleName
SP.SdkBridge` reaches the call sites under WinPS 5.1 / Pester 5.x, Bug-1). Every Context's
BeforeEach silences `Mock Write-SPLog -ModuleName SP.SdkBridge { }`. Tests mock the SP.Sdk
WRAPPER functions (Get/Approve/Deny/Forward/Update/Test/Set/Remove/Complete/New-SPSdk*) at
-ModuleName SP.SdkBridge returning the @{Success;Data;Error} envelope -- NOT Invoke-SPApiRequest.
Coverage: SDK-BR-001 (template rows, IsSelected, _Raw, Scheduled=$true/$false via schedule
Data non-null/null), SDK-BR-002/003 (State routing -> pending vs completed backing + matching
column sets, asserting pending-only columns are absent on completed rows), SDK-BR-004
(single call returns .Data rows AND .Summary=@{Open;Completed;Total}; failed summary is
non-fatal -> rows + zeroed Summary), SDK-BR-005 (Enabled bool + TriggerType from .enabled /
.trigger.type, int counts), SDK-BR-006 (Approve/Deny/Forward routing, missing-arg negatives
invoke backing 0 times, out-of-set Action -Should -Throw), SDK-BR-007 (Toggle -> Update via
New-SPSdkPatchReplace on '/enabled', Test -> Test-SPSdkWorkflow, CreateOOO ->
Set-SPSdkOOOFallbackWorkflow, each with arg-validation negatives). SDK-03 Safety: terminal
gate proven both directions for Template Delete and WorkItem Complete (blocked + backing 0x
when AllowCompleteCampaign=$false; proceeds + backing 1x when $true); bulk cap proven for
Filter Delete (N=3 > cap=2 refused whole, Error names count and cap, backing 0x; N=2 within
cap proceeds); non-gated routing-only verbs (Approval Approve, Workflow Toggle) succeed even
with AllowCompleteCampaign=$false. Safety config is toggled via
`Mock Get-SPConfig -ModuleName SP.SdkBridge` returning a [PSCustomObject] with a .Safety
[PSCustomObject] (the gate uses PSObject.Properties.Name -contains, so plain hashtables would
not satisfy its guards).

PLAN DISAGREEMENT (code over plan, recorded): PHASE7_GUI_SDK_TAB.md Test Plan (~line 516)
instructs "Mock Invoke-SPApiRequest at the module level". That is WRONG for the bridge layer
-- SP.SdkBridge.psm1 never calls Invoke-SPApiRequest; it calls the SP.Sdk wrapper functions
and consumes their @{Success;Data;Error} envelopes. The tests therefore mock the SP.Sdk
envelope layer at -ModuleName SP.SdkBridge, not the HTTP layer. (This matches the SDK-05
forward note in round-05.md.) Secondary note: SDK-06 is strictly test-only; SP.SdkBridge.psm1
(SDK-01/02/03) was NOT modified.

SCOPE NOTE: WPF conventions (GetNewClosure / & $module / runspace / XamlReader) do NOT apply
to SDK-06 -- this is pure headless Pester for synchronous, UI-free bridge functions; no GUI
scaffolding was added. Cert-summary functions (Get-SPGuiSdkCertSummaries/DecisionSummary/
CertCampaigns) are scope-gated to SDK-18 and were intentionally left uncovered (no verified
fixtures); deep cert-summary tests deferred to SDK-18.

**Files:** `Tests/SP.SdkBridge.Tests.ps1` (new)

**Verification:**
  - Parse: `[Parser]::ParseFile` ParseErrors=0
  - Pester (this file only, New-PesterConfiguration, WinPS 5.1 / Pester v5.7.1): P=34 F=0 Total=34
    - 12 It across SDK-BR-001..007 + 22 It across the four SDK-03 Safety contexts
    - file is discovered by the existing `*.Tests.ps1` glob (34 tests found in discovery)
  - XAML parse: n/a (no XAML touched)
  - Manifest/import: n/a (test-only; no manifest/production-module edits)

**Review:** <PENDING -- independent code-review gate>
**Backlog update:** SDK-06 -> DONE

**Completed:** <END_TIMESTAMP>
**Status:** SUCCESS
