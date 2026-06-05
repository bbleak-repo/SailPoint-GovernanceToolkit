# Round 1
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-01 -- SP.SdkBridge.psm1 read functions (9)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-01 table row + section; Goal body lists 9 functions)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round-file template)
- `Modules/SP.Gui/SP.GuiBridge.psm1` (return-shape + row-shaping convention; `Get-SPGuiCampaignList` 176-190 catch pattern, `_Original`/IsSelected at 158-173, `Get-SPGuiAuditCampaigns` 422-524 for cert-campaign cache + column names CampaignId/CampaignName)
- Backing SP.Sdk reads: `SP.SdkCampaignTemplates.psm1` (Get-SPSdkCampaignTemplates, Get-SPSdkTemplateSchedule 404->Success/Data=$null), `SP.SdkApprovals.psm1` (OwnerId/Limit/Offset params), `SP.SdkWorkItems.psm1` (Get-SPSdkWorkItems, Get-SPSdkWorkItemsSummary -> open/completed/total; summary param is OwnerId), `SP.SdkWorkflows.psm1` (Get-SPSdkWorkflows, Get-SPSdkWorkflowExecutions -WorkflowId), `SP.SdkCampaignFilters.psm1` (-IncludeSystemFilters [bool] default $true, Offset->'start'), `SP.SdkCertSummaries.psm1` (Get-SPSdkIdentitySummaries; Get-SPSdkAccessSummaries -Type ROLE|ACCESS_PROFILE|ENTITLEMENT; Get-SPSdkDecisionSummary non-paginated)

**Did:** Created the single new file `Modules/SP.Gui/SP.SdkBridge.psm1` containing the 9 READ bridge functions named in the SDK-01 Goal body (the "(6)" in the title is stale; the Goal lists 9 and the orchestrator says 9). Each function is `[CmdletBinding()][OutputType([hashtable])]`, generates a CorrelationID via `[guid]::NewGuid().ToString()` when absent, splats only non-empty optional params to its backing SP.Sdk read, consumes `$r.Success`/`$r.Data` directly (no re-unwrap of `.items`), and returns `@{Success;Data;Error}` with the body wrapped in try/catch so it never throws (catch returns `Success=$false;Data=@();Error=...` and logs via `Write-SPLog -Component 'SP.SdkBridge' -Severity ERROR`). Module top uses `Set-StrictMode -Version 1` per GuiBridge. Checkbox grids (Templates/Approvals/WorkItems/Workflows/Filters and the cert summary grids) emit `IsSelected=$false`; Executions is read-only (no IsSelected). Every row carries `_Raw` = original item. Per-row schedule probe sets `Scheduled` (404 -> $false, no error). WorkItems returns rows + a `Summary` key (Open/Completed/Total) from one call (summary failure non-fatal). Approvals routes Pending vs Completed and emits the matching column set.

**Scope decisions taken (cert trio, per middle-loop ESCALATE recommendation B / SDK-18 defer-default):** all 9 shells authored so the module surface is complete for SDK-04/06. CertSummaries + DecisionSummary are wired live to their existing backings (`Get-SPSdkIdentitySummaries`/`Get-SPSdkAccessSummaries`/`Get-SPSdkDecisionSummary`). `Get-SPGuiSdkCertCampaigns` has no valid SP.Api/SP.Certifications backing (module does not exist; SP.Api has only `Get-SPCampaign` by-ID), so it backs onto the existing GUI campaign cache `Get-SPGuiAuditCampaigns` (SP.GuiBridge) when loaded, returning Id/Name pairs; if that command is absent it returns `Success=$false` + a descriptive Error (no throw) to be finalized under SDK-18.

**Plan disagreements recorded:**
1. Title says "(6)" read functions; Goal body + orchestrator say 9. Implemented 9.
2. `Get-SPGuiSdkCertCampaigns` plan cites `SP.Api/SP.Certifications` which does not exist; backed onto `Get-SPGuiAuditCampaigns` instead.
3. `Get-SPSdkCampaignFilters` exposes bool `-IncludeSystemFilters` (default $true); bridge exposes `-IncludeSystem` switch. Decision: preserve include-all by default -- the bridge always forwards `-IncludeSystemFilters:$true` so the switch never narrows below the backing default. Documented in the function help.

**Files:** `Modules/SP.Gui/SP.SdkBridge.psm1` (new).

**Verification (Windows PowerShell 5.1, powershell.exe):**
  - AST parse: `[Parser]::ParseFile` -> 0 errors.
  - Import: `Import-Module -Force` clean; `Get-Command -Module SP.SdkBridge` lists all 9 functions.
  - Functional (backings mocked as global stubs returning `@{Success=$true;Data=@(sample);Error=$null}`):
    - Templates: Success=True, IsSelected/_Raw present, Scheduled=False on 404 case.
    - Approvals -State Pending calls Get-SPSdkPendingApprovals + emits RequestType column; -State Completed calls Get-SPSdkCompletedApprovals + emits ReviewedBy column (mock call assertion passed).
    - WorkItems: Data rows + Summary{Open=5;Completed=2;Total=7} from one call.
    - Workflows IsSelected present; Executions has NO IsSelected (read-only).
    - Filters SystemFilter bool + IsSelected; CertSummaries(Access ROLE) returns rows; DecisionSummary single row + _Raw; CertCampaigns w/o GuiBridge returns Success=$false (no throw).
    - Backing Success=$false -> bridge Success=$false, Data is empty array, Error passed through (no throw).
    - Backing throws -> bridge Success=$false with descriptive Error (no throw).
  - Pester: n/a (SDK-01 adds no tests; SDK-06 owns bridge tests).
  - XAML parse: n/a (no XAML touched).
  - Manifest: n/a (psd1 registration is SDK-04).

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-01 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS
