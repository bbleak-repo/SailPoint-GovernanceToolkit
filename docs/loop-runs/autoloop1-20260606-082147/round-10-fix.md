# Round 10 -- INNER fix: phased campaign-lifecycle wiring (work item 4 gap)

## Bug (from the round-10 hunt)

Campaign-lifecycle proof gap. The mock added an additive two-phase complete
(`CampaignHandlers.ps1`): with `?phased=1`, ACTIVE -> COMPLETING on the first
call and COMPLETING -> COMPLETED on the next; without the flag it single-jumps
ACTIVE -> COMPLETED. The toolkit's `Complete-SPCampaign` never sent `?phased=1`
(zero "phased" references anywhere in Modules/ or Scripts/), so against the LIVE
mock the COMPLETING intermediate was never observed. `Tests/SP.CampaignLifecycle.Tests.ps1`
CAMP-LC-001 only saw the full STAGED->ACTIVE->COMPLETING->COMPLETED chain because
its MOCKED transport injected COMPLETING at the `/complete` response, not via the
real wiring. The "end-to-end" claim was stronger than what was exercised live.

## Did (minimal, additive)

1. `Modules/SP.Api/SP.Campaigns.psm1` -- added an opt-in `[switch]$Phased` to
   `Complete-SPCampaign`. When present it sends `-QueryParams @{ phased = '1' }`
   to `POST /campaigns/{id}/complete`. Default behaviour (switch omitted) sends
   NO query params -- unchanged single-call path. Also surfaced the response body
   as `Data` in the return envelope (was previously `@{Success;Error}` only;
   existing callers ignore `Data`, so this is additive). Safety guard, 400 guard,
   and `AllowCompleteCampaign` gate untouched.

2. `Scripts/Invoke-SP30DayManagerCertSim.ps1` -- the `-CompleteAllCampaigns`
   full-lifecycle path now calls `Complete-SPCampaign -Phased`, confirms the
   campaign entered COMPLETING (from the response `Data.status` or a follow-up
   `Get-SPCampaign`), records the COMPLETING intermediate, then issues the
   settling phased call and polls to COMPLETED. Tolerant of a backend that
   ignores the flag (single-jump). Default subset path (first 3) unchanged.

3. `Tests/SP.CampaignLifecycle.Tests.ps1` -- added CAMP-LC-005 (two contexts):
   asserts `Complete-SPCampaign -Phased` POSTs `/complete` with
   `QueryParams['phased'] -eq '1'` and surfaces returned `Data`; and that the
   default call (no `-Phased`) passes NO query params -- proving the real wiring
   and that the default path is preserved.

## Files

- C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Modules\SP.Api\SP.Campaigns.psm1
- C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Scripts\Invoke-SP30DayManagerCertSim.ps1
- C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\SP.CampaignLifecycle.Tests.ps1

No mock-repo changes (the mock already had the additive phased handler).

## Verification (real output)

Parse-check (all three files): OK.

Affected file `SP.CampaignLifecycle.Tests.ps1`:

```
Describing CAMP-LC-001: Full lifecycle STAGED->ACTIVE->COMPLETING->COMPLETED in order
   [+] Should observe STAGED -> ACTIVE -> COMPLETING -> COMPLETED in order
Describing CAMP-LC-002: Get-SPCampaignStatus settles COMPLETING to COMPLETED
   [+] Should return Success=true with Data.Status COMPLETED after multiple polls
Describing CAMP-LC-003: 400 guard intact -- completing a non-ACTIVE campaign fails
   [+] Should return Success=false with the 'ACTIVE status' error
Describing CAMP-LC-004: Safety still blocks completion when AllowCompleteCampaign is false
   [+] Should return Success=false, match AllowCompleteCampaign, call API 0 times
Describing CAMP-LC-005: -Phased wires ?phased=1 to the backend (real wiring)
   [+] Should POST /complete with QueryParams phased=1 and surface returned Data
   [+] Should POST /complete with NO query params (default path preserved)
Tests Passed: 6, Failed: 0, Skipped: 0
```

Regression `SP.Campaigns.Tests.ps1`: Tests Passed: 16, Failed: 0.

Full suite `Invoke-Pester .\Tests`:

```
Discovery found 1257 tests in 2.1s.
Tests completed in 424.52s
Tests Passed: 1257, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

## Commit

See structured result (committed on feature/manager-cert-30day-sim, no push).

## Status

DONE -- phased lifecycle now genuinely wired end-to-end; default path unchanged;
full suite green (1257/0).
