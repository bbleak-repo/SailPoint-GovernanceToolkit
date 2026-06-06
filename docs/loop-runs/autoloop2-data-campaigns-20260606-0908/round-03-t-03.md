# T-03 -- Disconnected campaign upload -> HTML: dated CSV snapshots -> register -> cert/batch -> harvest -> validated HTML

## Read
Inspected (read-only, to mirror conventions + confirm signatures):
- `Scripts/Invoke-SPDisconnectedAppRegistry.ps1` -- header/param/module-load style for the new generator.
- `Tests/SP.RegularCampaignUploadHtml.Tests.ps1` (T-02) -- discovery-scope mock probe, settings.local.json overlay/restore, child-process invocation, artifact-dir conventions.
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppValidator.psm1` -- EXACT CSV schemas (`id,name,givenName,familyName,e-mail,groups,IIQDisabled`; `id,name,displayName,description`), UTF-8 check, sort-order + IIQDisabled true/false rules, cross-reference rule.
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppReports.psm1` -- exporter signatures: `Export-SPDisconnectedAppDeltaHtml` (DeltaResult/AppName/OutputPath/ReportDate), `...DecisionHarvestHtml` (DecisionData/AppName), `...SlaHtml` (SlaData/DaysBack), `...BatchHtml` (BatchResults[]/...). Found a real rendering bug (see Did).
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppDelta.psm1` (`Compare-SPDisconnectedAppFiles` + Summary keys: TotalCurrent/TotalPrevious/...), `SP.DisconnectedAppSnapshot.psm1` (`Save-SPDisconnectedAppSnapshot`), `SP.DisconnectedAppAnalytics.psm1` (`Get-SPDisconnectedAppCampaignDecisions` output shape).
- `Scripts/Invoke-SPDisconnectedAppCert.ps1` -- param surface (AccountFilePath/EntitlementFilePath/SnapshotDir/OutputPath/ConfigPath/OutputMode) + exit codes. Found a real bug at line 595 (see Did).
- `Tests/Import-TestModules.ps1` -- `Import-SPTestModules -Core -Api -DisconnectedApps`.

## Did
1. **NEW generator** `Scripts/New-SPDisconnectedAppSnapshotData.ps1`: deterministic dated-CSV generator.
   - Seeded `[System.Random]::new($Seed)` drives ALL randomness -> byte-reproducible content.
   - Emits `{OutputDir}/{App}/{yyyy-MM-dd}-accounts.csv` (exact 7-col header) and, with `-WithEntitlements`, `{yyyy-MM-dd}-entitlements.csv` (exact 4-col header). UTF-8 no BOM via `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`; rows sorted by `id`; one entitlement row per group id so cross-reference passes; ~10% IIQDisabled=true deterministic. Optional `Save-SPDisconnectedAppSnapshot` copy when ReportDate is today. Returns `@{Success;Data=@{AccountFile;EntitlementFile;AccountRows;EntitlementRows;ReportDate;Seed;Snapshot};Error}`; supports `-OutputMode JSON`. WP5.1-safe.
2. **NEW e2e test** `Tests/SP.DisconnectedUploadHtml.Tests.ps1` (DA-UP-HTML-001..012): 7 always-run OFFLINE tests (generator headers/rows, validators+cross-ref, delta->HTML, decision-harvest->HTML, SLA->HTML, batch->HTML) + 2 LIVE tests (`-Skip` when mock down): cert run in a CHILD process (the script calls `exit`), and real `Get-SPDisconnectedAppCampaignDecisions` -> HTML with graceful empty-trail soft-path. Overlays/restores `settings.local.json` byte-for-byte; all artifacts under a per-run `Tests/_artifacts/disconnected-{stamp}` removed in AfterAll.
3. **Real-bug fix (rendering)** `Modules/SP.DisconnectedApps/SP.DisconnectedAppReports.psm1`: the summary-table row literals were built as newline-separated nested arrays inside `@(...)` with NO separating comma, e.g. `@( @('Total Current Accounts',$x) @('Total Previous',$y) )`. PowerShell flattens that to a flat scalar list, so `foreach`/`$row[0]`/`$row[1]` indexed into the label STRING and the summary tables rendered ONE CHARACTER per cell (`T`,`o`,`2`,`5`,...). Fixed by comma-prefixing each row literal (`,@(...)`) in the four summary loops T-03 exercises: Delta summary, Batch summary + error-detail rows + delivery rows, SLA summary, Decision-Harvest status rows + footer rows. (Team-dashboard rows left untouched -- not exercised by T-03.) DA-010 + DA-19-T existing tests still pass.
4. **Real-bug fix (cert script)** `Scripts/Invoke-SPDisconnectedAppCert.ps1` line ~595: `if ($resolved.Unresolved -gt 0)` compared the ARRAY of unresolved entries (iterated immediately below) against 0; under StrictMode with hashtable elements this throws `Cannot compare "System.Collections.Hashtable" because it is not IComparable`, aborting the cert whenever any identity is unresolved (the normal mock case). Changed to `if (@($resolved.Unresolved).Count -gt 0)`.

NOTE: changes 3 & 4 are surgical real-bug fixes (allowed by spec: "Do NOT alter existing ... behavior except real-bug fixes"); both add a guard / fix a literal and remove no behavior or exports.

## Files
- `Scripts/New-SPDisconnectedAppSnapshotData.ps1` (NEW)
- `Tests/SP.DisconnectedUploadHtml.Tests.ps1` (NEW)
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppReports.psm1` (MODIFIED -- real-bug fix, summary-row flattening)
- `Scripts/Invoke-SPDisconnectedAppCert.ps1` (MODIFIED -- real-bug fix, unresolved-count guard)
- `docs/loop-runs/autoloop2-data-campaigns-20260606-0908/round-03-t-03.md` (NEW -- this record)

## Verification

### Mock started fresh, non-elevated (confirmed UP)
```
Start-MockServer.ps1 -Port 8080  (background)
POST http://localhost:8080/oauth/token (client_id=mock&client_secret=mock)
-> MOCK UP 200
```

### Generator smoke (deterministic, JSON)
```
powershell -NoProfile -File .\Scripts\New-SPDisconnectedAppSnapshotData.ps1 -AppName PEP-Plus -WithEntitlements -AccountCount 25 -EntitlementCount 8 -Seed 42 -OutputMode JSON
{ "Success": true, "AppName": "PEP-Plus",
  "AccountFile": "...\DisconnectedApps\Imports\PEP-Plus\2026-06-06-accounts.csv",
  "EntitlementFile": "...\DisconnectedApps\Imports\PEP-Plus\2026-06-06-entitlements.csv",
  "AccountRows": 25, "EntitlementRows": 8, "ReportDate": "2026-06-06", "Seed": 42 }

powershell -NoProfile -File .\Scripts\New-SPDisconnectedAppSnapshotData.ps1 -AppName DebtNext -AccountCount 20 -Seed 7 -OutputMode JSON
{ ... "AccountRows": 20, "EntitlementRows": 0 ... }

Import-Csv checks:
PEP accounts rows=25 cols=id,name,givenName,familyName,e-mail,groups,IIQDisabled
PEP ent      rows=8  cols=id,name,displayName,description
DebtNext acc rows=20 cols=id,name,givenName,familyName,e-mail,groups,IIQDisabled
IIQDisabled distinct = false|true
```

### Validators on generated files (in-process)
```
PEP account  Success=True
PEP ent      Success=True
PEP crossref Success=True  orphans=0  (all 8 groups referenced by the 25 accounts)
DebtNext acc Success=True
```

### New Pester test (mock UP) -- all PASS, no fails
```
Invoke-Pester -Path .\Tests\SP.DisconnectedUploadHtml.Tests.ps1 -Output Detailed
[+] DA-UP-HTML-001 generates PEP-Plus dated accounts + entitlements CSVs with exact headers
[+] DA-UP-HTML-002 generates DebtNext accounts-only dated CSV with headers + rows
[+] DA-UP-HTML-003 generated files pass account/entitlement/cross-reference validation
[+] DA-UP-HTML-004 Compare-SPDisconnectedAppFiles -> Export-SPDisconnectedAppDeltaHtml HTML is correct
[+] DA-UP-HTML-005 Export-SPDisconnectedAppDecisionHarvestHtml renders decisions + revocations
[+] DA-UP-HTML-006 Export-SPDisconnectedAppSlaHtml renders the delivery report
[+] DA-UP-HTML-007 Export-SPDisconnectedAppBatchHtml renders per-app status
[+] DA-UP-HTML-010 Invoke-SPDisconnectedAppCert.ps1 (JSON) runs end-to-end   (child proc, exit in {0,1})
[+] DA-UP-HTML-012 Get-SPDisconnectedAppCampaignDecisions -> decision harvest HTML
Tests Passed: 9, Failed: 0, Skipped: 0
```
(LIVE Its are `-Skip:(-not $script:MockUp)`; with the mock down they SKIP, not fail -- the file still passes.)

### HTML content assertions (PowerShell -match, not cat)
```
DELTA file:   ...\Reports\PEP-Plus\delta-2026-06-06.html
  'Delta Summary'          = True
  'Total Current Accounts' = True   (was rendering 'T','o',... before the fix)
  'PEP-Plus'               = True
HARVEST file: ...\Reports\PEP-Plus\decision-harvest-2026-06-06.html
  'Decision Harvest'       = True
  'APPROVED'               = True
  'REVOKED'                = True
  'Olivia Smith'           = True   (a revoked identity)
```

### Affected-module regression (existing disconnected suite -- proves no regression)
```
Invoke-Pester -Path .\Tests\SP.DisconnectedApps.Tests.ps1 -Output Detailed
Tests Passed: 71, Failed: 3
  - DA-010  Export-SPDisconnectedAppDeltaHtml ...  [+] PASS (exporter I fixed)
  - DA-19-T Export-SPDisconnectedAppBatchHtml ...  [+] PASS (exporter I fixed)
  - 3 failures = DA-21-T (CommandNotFoundException: Get-SPAuditCertifications)
PRE-EXISTING: `git stash` (clean tree) run = Passed=71 Failed=3 (identical) -> NOT caused by T-03.
```

### Repo cleanliness
```
git status --short
 M Modules/SP.DisconnectedApps/SP.DisconnectedAppReports.psm1
 M Scripts/Invoke-SPDisconnectedAppCert.ps1
?? Scripts/New-SPDisconnectedAppSnapshotData.ps1
?? Tests/SP.DisconnectedUploadHtml.Tests.ps1
(settings.local.json restored byte-for-byte; Tests/_artifacts removed; no other tracked diffs)
```

## Commit
cf83d74 -- test(disconnected): T-03 disconnected upload -> snapshots/register/cert/harvest -> validated HTML e2e

## Status
DONE
