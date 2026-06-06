# T-07 -- Validate the SP.Sdk path (campaign templates / work items) for the daily privileged attestation

## Read
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` -- the `New-SailPointData`
  generator: tracked-roles block (`$trackedPrivilegedRoles`, `$privRoleMgr`, lines 567-588),
  the 30-day daily-campaign loop (lines 705-819), `Get-IsoTimestamp` / `Format-Id`, and the
  `$data` assembly + Write-Host summary.
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/SdkHandlers.ps1` -- confirmed the
  mock ALREADY serves GET `/v3/campaign-templates`, `/:id`, `/:id/schedule`, `/v3/work-items`,
  `/summary`, `/count`, `/completed`, reading from `data.campaignTemplates`,
  `data.campaignTemplateSchedules` (a DICT keyed by templateId), `data.workItems`. The work-items
  handler treats state `Finished`/`Completed` as completed (everything else open) and filters by
  `ownerId`. The template POST copyFields list includes `type`.
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Modules/SP.Sdk/SP.SdkCampaignTemplates.psm1`
  and `SP.SdkWorkItems.psm1` -- the Get-* functions (incl. the `items`-wrapper unwrap path) and the
  endpoints they hit. `SP.Sdk.psd1` NestedModules wires both psm1s; FunctionsToExport lists them.
- The two CLI wrappers `Scripts/Invoke-SPSdkCampaignTemplates.ps1` + `Scripts/Invoke-SPSdkWorkItems.ps1`.
- `Tests/SP.ManagerCert30DaySim.Tests.ps1` (Layer-A/Layer-B split, fixture loader, in-memory-store
  mock style in MC-04) and `Tests/SP.SdkCampaignTemplates.Tests.ps1` (mock `Invoke-SPApiRequest`
  `-ModuleName SP.SdkCampaignTemplates`, `Get-SPConfig -ModuleName SP.SdkCommon`, `Should -Invoke ...
  -ParameterFilter { $Endpoint -eq ... }`).
- `Scripts/Invoke-SP30DayManagerCertSim.ps1` -- module chain, `$worstExitCode`/WARN pattern.

THE GAP CONFIRMED: the T-03 regenerated `State/SailPointData.json` had NO `campaignTemplates` /
`campaignTemplateSchedules` / `workItems`, so the SDK path returned empty against the daily-cadence
dataset.

## Did
1. **Mock seed enrichment (MOCK repo, additive).** In `New-BulkSeedData.ps1` `New-SailPointData`,
   AFTER the 30-day daily-campaign loop (`$campaigns = $campaignList.ToArray()`) and BEFORE `$data`
   assembly, built three NEW collections REUSING already-settled `$trackedPrivilegedRoles` /
   `$privRoleMgr`:
   - `campaignTemplates`: ONE per tracked priv role (10), `id=tmpl-priv-NN`, `type='MANAGER'`,
     `deadlineDuration='P1D'`, `ownerRef` = the role's responsible manager.
   - `campaignTemplateSchedules`: dict keyed by template id, each `type='DAILY'`,
     `hours={LIST:[9]}`, `timeZoneId='America/New_York'`.
   - `workItems`: per-(manager, role) CERTIFICATION tasks across recent days 1-3 (30 total), with a
     deliberate open(`Pending`)/completed(`Finished`) spread so `/summary` is non-zero on BOTH.
     The only rng-drawing was avoided -- the open/closed split is purely positional and placed AFTER
     the daily loop, so all earlier RNG draws (MC-01..MC-07 anchors) are unchanged.
   Added all three to the returned `$data` dict + three Write-Host count lines.
2. **Regenerated + reloaded** `State/SailPointData.json` (seed 20260606) and restarted the
   NON-ELEVATED mock (T-03 procedure). Backup: `State/_backups/SailPointData.20260606-061331.json`.
3. **Sim driver (TOOLKIT, additive).** Added `-IncludeSdkPath` switch + SP.Sdk to the module chain +
   a new "Step F" that calls `Get-SPSdkCampaignTemplates` / `Get-SPSdkTemplateSchedule` /
   `Get-SPSdkWorkItemsSummary` / `Get-SPSdkWorkItems` / `Get-SPSdkCompletedWorkItems` and writes
   `sdk-path.json` to the capture dir. Default OFF; empty = WARN (not fatal); skipped under -WhatIf.
4. **Validation (TOOLKIT, additive).** Refreshed the frozen fixture
   `Tests/TestData/ManagerCert30DaySim.State.json`; appended `Describe "MC-08: ..."` with Layer-A
   (data-truth: >=10 MANAGER templates, ownerRef in tracked-manager set, DAILY schedules, work-items
   open+completed, owners subset of tracked managers) and Layer-B (real SP.Sdk functions over mocked
   transport hitting the correct endpoints). MC-01..MC-07 untouched.

NOTE: the spec's `Tests/SP.SdkWorkItems.Tests.ps1` does not exist in this repo (work-items SDK
coverage lives in `SP.SdkBridge.Tests.ps1` + now MC-08 Layer-B); ran SdkBridge as the work-items
regression instead. The live CLI proof required temporarily pointing the gitignored-convention
`Config/settings.local.json` BaseUrl at the reloadable `localhost:8080` instance (the config's
`10.0.0.143:8080` is a separate, stale, non-reloadable LAN instance); the file was restored to
`http://10.0.0.143:8080/v3` verbatim after the proof (verified).

## Files
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (MOCK repo -- additive collections + summary)
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (MOCK repo -- regenerated)
- `C:/temp/Coding/API-mockserver/State/_backups/SailPointData.20260606-061331.json` (MOCK repo -- backup)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Scripts/Invoke-SP30DayManagerCertSim.ps1` (TOOLKIT -- -IncludeSdkPath + Step F)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/SP.ManagerCert30DaySim.Tests.ps1` (TOOLKIT -- MC-08)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/TestData/ManagerCert30DaySim.State.json` (TOOLKIT -- refreshed fixture)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-07-t-07.md` (TOOLKIT -- this record)

## Verification

### 1) Generator parse (mock) => ParseErrors=0
```
ParseErrors=0
```

### 2) Probe regenerate + assert (then deleted)
```
campaignTemplates=10
allMANAGER+ownerRef=True
schedule_tmpl-priv-01_type=DAILY
workItems=30
open=7 finished=23
identities=100
trackedPriv=10
dailyCamps=30
owner_id-gen-002_items=3
probe-deleted
```

### 3) Reload procedure (mock) -- DOWN poll then ok poll
```
DOWN=True
{"port":8080,"status":"ok","profiles":["SailPoint-ISC",...],"uptime":"2026-06-06T06:14:07Z"}
OK=True
```
Generator summary on the real reload (State/SailPointData.json):
```
  Identities:100  Priv Roles:10  SDK Templates:10  SDK Schedules:10  SDK WorkItems:30  Daily Campaigns:30
```

### 4) Live CLI proof (toolkit; settings.local.json temporarily -> localhost, then restored)
- `Invoke-SPSdkCampaignTemplates.ps1 -Action List -OutputMode JSON` (EXIT 0):
  `ResultCount=10`, `priv_names=10`, `first=tmpl-priv-01 | Daily Privileged Role Attestation - AD-SG-Admins-3 | type=MANAGER | owner=id-gen-001`
- `Invoke-SPSdkCampaignTemplates.ps1 -Action Schedule -TemplateId tmpl-priv-01 -OutputMode JSON` (EXIT 0):
  `schedule.type=DAILY hours=9 tz=America/New_York`
- `Invoke-SPSdkWorkItems.ps1 -OutputMode JSON` (EXIT 0):
  `Summary.open=7 completed=23 total=30`, `ResultCount=7`, `item0 type=CERTIFICATION ownerId=id-gen-001 state=Pending`
- `Invoke-SPSdkWorkItems.ps1 -OwnerId id-gen-002 -OutputMode JSON` (EXIT 0):
  `ResultCount=1`, `distinct_owners=id-gen-002`

### 5) Sim-driver SDK step (toolkit, mock up)
```
SIM_EXIT=0
  Step F: SP.Sdk path (campaign templates / schedules / work-items)
    Templates: 10
    Work-items: open=7 completed=23
sdk-path.json: Templates=10  SchedulesSampled=3 (type0=DAILY)  WI open=7 completed=23 total=30  OpenWorkItems=7 CompletedWorkItems=23
```
HELP (no -IncludeSdkPath) EXIT 0, syntax line now shows `[-IncludeSdkPath]`.

### 6) Affected Pester (toolkit)
```
Describing MC-08: SP.Sdk path yields the same privileged-attestation / manager-accountability outcome
 Context Layer A: data-truth on the frozen fixture        [+] x6
 Context Layer B: real SP.Sdk functions over mocked transport [+] x4
Tests completed in 6.96s
Tests Passed: 55, Failed: 0, Skipped: 0   (MC-01..MC-07 still green + new MC-08)

SP.SdkCampaignTemplates: Passed=22 Failed=0
SP.SdkBridge (work-items coverage): Passed=44 Failed=0
```
(`SP.SdkWorkItems.Tests.ps1` does not exist in repo; SdkBridge used instead.)

### 7) Param-surface regression (toolkit)
```
SP.CliScripts: Passed=75 Failed=0
```

## Commit
- MOCK repo:    b06c1dc  feat(seed): add SP.Sdk-path collections (campaign templates/schedules/work-items) for daily priv attestation (T-07)
- TOOLKIT repo: 4d7bcf8  test(sim): prove the SP.Sdk path for daily privileged attestation (T-07)

## Status
DONE
