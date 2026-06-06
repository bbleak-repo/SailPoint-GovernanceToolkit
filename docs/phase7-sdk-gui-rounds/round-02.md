# Round 2
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-02 -- SP.SdkBridge.psm1 write dispatchers (5, -Action verbs)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-02 table row + per-item section; SDK-03 boundary)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (bridge mapping table, Safety/What-If, WPF Framework Notes 1-6, GUI Testing Methods)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Modules/SP.Gui/SP.SdkBridge.psm1` (SDK-01 read conventions; lines 55-72, 95-101 return/never-throw/CorrelationID patterns)
- Backing SP.Sdk signatures (verified against code, not the plan):
  `Modules/SP.Sdk/SP.SdkCampaignTemplates.psm1`, `SP.SdkApprovals.psm1`,
  `SP.SdkWorkItems.psm1`, `SP.SdkWorkflows.psm1`, `SP.SdkCampaignFilters.psm1`,
  `SP.SdkPatch.psm1` (New-SPSdkPatchReplace).

**Did:**
Appended five `#region <domain> (WRITE)` blocks to the EXISTING `SP.SdkBridge.psm1`
(after the read regions, before `Export-ModuleMember`) and extended the export list
with the five new names (14 functions total). Each dispatcher follows the SDK-01
read conventions verbatim: `[CmdletBinding()][OutputType([hashtable])]`,
auto-generated `CorrelationID` when blank, whole body in a never-throwing try/catch
(catch logs via `Write-SPLog -Component 'SP.SdkBridge' -Severity ERROR` and returns
`@{Success=$false;Data=@();Error=...}`). Body is a `switch ($Action)` that validates
verb-specific required params BEFORE the backing call (returning a precise
`Action <Verb> requires -<Param>` message with NO backing call when missing), routes
each verb to its mapped SP.Sdk function passing the bridge CorrelationID through,
and returns `@{Success=$true;Data=$result.Data;Error=$null}` on success or passes
`$result.Error` through unchanged on backing failure. ValidateSet is the primary
unknown-verb guard; a `default {}` arm returning `'Unknown action: <Action>'` is the
belt-and-suspenders the Accept asks for. Optional backing params (Comment, Body,
SendNotifications, FallbackDays, WorkflowName) use the splat-only-when-present
pattern. A single one-line `# SDK-03 inserts the Safety / What-If gate here.` marker
sits at the top of each try-body. NO MessageBox, NO Dispatcher, NO `$script:` state,
NO Get-SPConfig/Safety -- pure/synchronous, runnable from the SDK-11 background
runspace.

**Files:** modified `Modules/SP.Gui/SP.SdkBridge.psm1`.

**Plan disagreements (resolved by trusting the code; no escalation needed):**
1. Workflow **Toggle**: mapping table maps `Set-SPSdkWorkflow` (full PUT needing a
   complete WorkflowBody the GUI does not hold). Implemented via
   `Update-SPSdkWorkflow -PatchOperations @(New-SPSdkPatchReplace -Path '/enabled'
   -Value $Enabled)` (PATCH application/json-patch+json). Requires `-WorkflowId` and
   `-Enabled` (presence checked via `$PSBoundParameters.ContainsKey('Enabled')` so a
   literal `$false` is accepted).
2. Filter **Update vs Delete asymmetry**: backing `Update-SPSdkCampaignFilter` takes
   a SINGLE `[string]$FilterId` (full-replacement POST /campaign-filters/{id}) while
   `Remove-SPSdkCampaignFilter` takes `[string[]]$FilterId` (bulk POST
   /campaign-filters/delete). The dispatcher declares `[string[]]$FilterId` and on
   Update uses the first element; on Delete forwards the whole array.
3. SDK-02 **Goal** text overlaps Safety/What-If, but the SDK-02 **Accept** is routing
   only and SDK-03 exists separately -> Safety is OUT of scope here (single marker
   comment per dispatcher).
4. Cert Summaries has NO write dispatcher (read-only per the mapping table) -- none added.

**Verification:** (headless, no live window; backing SP.Sdk + Write-SPLog stubbed at
global scope to record invocations -- SDK-05 flat-load / Mock -ModuleName deferred to
SDK-06's test file)
  - AST parse (`[Parser]::ParseFile`): 0 errors.
  - `Import-Module -Force`: OK; `Get-Command -Module SP.SdkBridge` = **14** (9 reads + 5 writes).
  - Routing: all 18 verb->backing pairs invoke the CORRECT single SP.Sdk function
    (Template Create/Update/Delete/SetSchedule/RemoveSchedule; Approval
    Approve/Deny/Forward; WorkItem Complete/Forward/BulkApprove/BulkReject; Workflow
    Toggle/Test/CreateOOO; Filter Create/Update/Delete) and return Success=$true.
  - Toggle builds a single `{op=replace; path=/enabled; value=$Enabled}` op -- verified.
  - Missing-required-param: Deny w/o Comment, Forward w/o NewOwnerId, Toggle w/o
    Enabled, Create w/o Template, WorkItem Forward w/o TargetOwnerId all return
    Success=$false naming the missing param with ZERO backing calls.
  - Backing-failure pass-through: mocked `@{Success=$false;Error='boom'}` ->
    dispatcher returns `@{Success=$false;Data=@();Error='boom'}`.
  - Backing-throw safety: mocked backing `throw 'kaboom'` -> caught, returns
    Success=$false with descriptive Error (no propagation).
  - Unknown verb: ValidateSet rejects an out-of-set verb (parameter-binding error);
    default{} arm provides the explicit `Unknown action: <Action>` path.
  - PSScriptAnalyzer (Warning+Error): the 5 new dispatchers are clean (approved verb
    `Invoke`, singular nouns); the only warnings are PRE-EXISTING SDK-01 read-function
    items (PSUseSingularNouns on Get-...s, PSReviewUnusedParameter IncludeSystem) --
    no new findings introduced.
  - Pester (re-verification pass, run after SDK-06's `Tests/SP.SdkBridge.Tests.ps1`
    landed): New-PesterConfiguration over that file -> **P=34 F=0** (Skipped=0,
    Total=34, ~3.5s). The 34 cases assert the full SDK-02 acceptance contract --
    all 18 verb->backing routings, the Toggle->Update-SPSdkWorkflow `/enabled`
    PATCH op, the Filter Update(single)/Delete(bulk) asymmetry, missing-required-
    param zero-call paths, unknown-verb, backing-failure pass-through, never-throw,
    PLUS the SDK-03 Safety-gate cases (which remain present in the live code).
  - XAML parse: n/a (no XAML touched).
  - Manifest/import: `Import-Module -Force` OK; `Get-Command -Module SP.SdkBridge`
    = **14** (9 reads + 5 writes); all 5 dispatchers in Export-ModuleMember
    (L1252-1256). No psd1 touched (SDK-04 owns that).

**Re-verification pass (post-SDK-03):** This round was re-run as a
verification/refinement pass. SDK-02's five dispatchers were already authored and
SDK-03 had since layered `Test-SPGuiSdkSafetyGate` (L33) plus per-verb gate calls
(Template Delete/RemoveSchedule, WorkItem Complete/BulkApprove/BulkReject, Filter
Delete) on top of the same dispatchers. NO source changes were made -- re-authoring
from the SDK-02 spec would have regressed SDK-03. The two documented plan-vs-code
disagreements (Toggle -> Update-SPSdkWorkflow not Set-SPSdkWorkflow; Filter
Update single-id vs Delete bulk string[]) remain correctly resolved in the code.
Confirmed headlessly: AST 0 errors, import + 14 exports, P=34/F=0 on the bridge
tests, Safety gating intact.

**Review:** PASS (verification pass: spec acceptance contract satisfied by existing
code; SDK-03 regression guard confirmed intact; no code changes).
**Backlog update:** SDK-02 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS
