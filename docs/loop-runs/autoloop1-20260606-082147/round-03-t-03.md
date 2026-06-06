# T-03 -- Exercise the full STAGED->ACTIVE->COMPLETING->COMPLETED campaign lifecycle end-to-end under a controlled flag

## Read
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/CampaignHandlers.ps1` lines 330-405 -- `$CompleteCampaignHandler`: today guards `$currentStatus -ne 'ACTIVE'` -> 400, then jumps ACTIVE->COMPLETED. Dual IDictionary/PSObject write pattern + `Set-PodeState` mirrors `$ActivateCampaignHandler` (lines 335-348).
- `Modules/SP.Api/SP.Campaigns.psm1`: `Get-SPCampaignStatus` (367-477, blocking poller `-TargetStatus`/`-TimeoutSeconds`/`-PollIntervalSeconds`, returns `@{Success;Data=@{Status;Campaign};Error}`); `Complete-SPCampaign` (safety guard 946-962 reads `$config.Safety.AllowCompleteCampaign`, posts `/campaigns/$CampaignId/complete` at 969); `Start-SPCampaign` posts `/campaigns/$id/activate` returns `.Data`; `New-SPCampaign` POST `/campaigns`. Confirmed the spec's "Wait-SPCampaignStatus" does NOT exist -- used `Get-SPCampaignStatus`.
- `Scripts/Invoke-SP30DayManagerCertSim.ps1`: param block (95-134), Safety reads (243-257), Step A completion gate `if ($allowComplete -and $writeResult.Submitted -le 3)` (395-407), `$writeResult` init (351-358), `$writeCapture` (456-466), `Write-SimAudit` (306-325 / 473-476).
- `Tests/SP.Campaigns.Tests.ps1` -- `New-MockSPConfig` helper (17-37), CAMP-004 sequenced `$script:PollCount` poller (207-278), CAMP-005 safety-block + allowed paths (280-324).

## Did
- **Mock (PART 1):** added an ADDITIVE opt-in two-phase completion to `$CompleteCampaignHandler`. Reads `$WebEvent.Query['phased']` ('1'/'true' enables). Now allows completion from ACTIVE **or** COMPLETING (so a 2nd call settles); any other status still returns the EXACT `Campaign must be in ACTIVE status to complete. Current status: <x>` 400. When phased+ACTIVE -> sets `COMPLETING` (no settle); phased+COMPLETING -> `COMPLETED`; not-phased -> `COMPLETED` (single-call jump unchanged). Same dual-write + `Set-PodeState`. Route file untouched.
- **Driver (PART 2):** added `[switch]$CompleteAllCampaigns` + `.PARAMETER` doc; `$completeAll` = OR of the switch and an optional `Safety.CompleteAllCampaigns` config flag (defensive PSObject.Properties guard, default `$false`). Added a PARALLEL completion branch gated behind `$completeAll -and $allowComplete` that completes EVERY submitted campaign (drops the `-le 3` ceiling), seeds the observed sequence (STAGED, ACTIVE), calls `Complete-SPCampaign` then `Get-SPCampaignStatus -TargetStatus 'COMPLETED' -TimeoutSeconds 30 -PollIntervalSeconds 1`, appends `COMPLETED`, and records `@{Id;Observed}` into a new `$writeResult.Transitions` list. The original first-3 branch is KEPT as `elseif` (default path byte-identical). Extended `$writeCapture` with additive `CompleteAll`/`Transitions` keys and added an `A-Lifecycle` `Write-SimAudit` step.
- **Tests (PART 3):** new `Tests/SP.CampaignLifecycle.Tests.ps1` (CAMP-LC-001..004) mirroring SP.Campaigns.Tests.ps1 patterns: ordered full lifecycle over sequenced mocked transport; COMPLETING-settle poll; 400 non-ACTIVE guard; AllowCompleteCampaign=false still blocks with 0 API calls.

## Files
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/CampaignHandlers.ps1` (mock repo -- EDIT)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Scripts/Invoke-SP30DayManagerCertSim.ps1` (toolkit -- EDIT)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/SP.CampaignLifecycle.Tests.ps1` (toolkit -- CREATE)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/autoloop1-20260606-082147/round-03-t-03.md` (this record)

## Verification
1) Parse mock handler + AST-parse driver (PowerShell tool, Bash mangled `$ErrorActionPreference`):
```
$ErrorActionPreference='Stop'; . 'C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/CampaignHandlers.ps1'; Write-Host 'HANDLERS-OK'; $null=[System.Management.Automation.Language.Parser]::ParseFile('.../Invoke-SP30DayManagerCertSim.ps1',[ref]$null,[ref]$null); Write-Host 'DRIVER-PARSE-OK'
-->
HANDLERS-OK
DRIVER-PARSE-OK
```
2) New lifecycle suite (headless gate, mocked transport):
```
Invoke-Pester -Path '.../Tests/SP.CampaignLifecycle.Tests.ps1' -Output Detailed
-->
Tests Passed: 4, Failed: 0, Skipped: 0
  [+] CAMP-LC-001 Should observe STAGED -> ACTIVE -> COMPLETING -> COMPLETED in order
  [+] CAMP-LC-002 Should return Success=true with Data.Status COMPLETED after multiple polls
  [+] CAMP-LC-003 Should return Success=false with the 'ACTIVE status' error
  [+] CAMP-LC-004 Should return Success=false, match AllowCompleteCampaign, call API 0 times
```
3) Existing campaign suite (regression):
```
Invoke-Pester -Path '.../Tests/SP.Campaigns.Tests.ps1' -Output Detailed
-->
Tests Passed: 16, Failed: 0, Skipped: 0   (CAMP-001..005 all green)
```
Live mock step (#5) skipped -- optional, not the gate; no error injection/scenario was touched so nothing to reset.

## Commit
- Mock repo (C:/temp/Coding/API-mockserver): see commit hash in structured result `notes`.
- Toolkit repo: see `commitHash` in structured result.

## Status
DONE
