# Round 08 -- INNER fix

## Did
Fixed the audit-fidelity bug found by the round-08 hunt in the NEW T-04
campaign-lifecycle code in `Scripts/Invoke-SP30DayManagerCertSim.ps1`.

Under `-CompleteAllCampaigns`, the per-campaign observed-lifecycle list recorded
`ACTIVE` based on the CUMULATIVE counter `$writeResult.Activated -gt 0` instead of
THIS campaign's own activation result. If an earlier campaign activated but the
current campaign's activate failed, the current campaign still falsely recorded
`STAGED -> ACTIVE` in its Transitions audit entry (then `Complete-SPCampaign` hits
the mock 400 guard so `COMPLETED` was correctly NOT added). This let the
write-roundtrip lifecycle audit trail show a STAGED campaign as having reached
ACTIVE. Severity: audit-log fidelity only (no crash, no real API/state effect;
the happy-path all-activate case was unaffected).

Fix (minimal, additive): introduced a per-iteration boolean
`$thisCampaignActivated`, set to `$true` only when THIS campaign's
`$startResult.Success` is true, and gated `$observed.Add('ACTIVE')` on that flag
instead of the cumulative counter. The cumulative `$writeResult.Activated`
counter is unchanged (still incremented), so no existing behaviour/export/test
changes.

## Files
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Scripts\Invoke-SP30DayManagerCertSim.ps1`
  - Added `$thisCampaignActivated = $false` before the activate `ShouldProcess` block.
  - Set `$thisCampaignActivated = $true` alongside `$writeResult.Activated++` on this campaign's successful activation.
  - Changed line ~429 gate from `if ($writeResult.Activated -gt 0)` to `if ($thisCampaignActivated)`.

## Verification

Parse check:
```
[System.Management.Automation.Language.Parser]::ParseFile(...) -> PARSE OK
```

Affected tests (SP.CampaignLifecycle + SP.ManagerCert30DaySim):
```
Pester v5.7.1
Discovery found 69 tests in 713ms.
Tests completed in 5.34s
Tests Passed: 69, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

Full suite (Invoke-Pester .\Tests):
```
RESULT Passed=1255 Failed=0 Skipped=0 Total=1255
```

## Commit
See commitHash in structured result (branch feature/manager-cert-30day-sim, no push).

## Status
DONE -- bug fixed, affected tests + full suite green (1255/0).
