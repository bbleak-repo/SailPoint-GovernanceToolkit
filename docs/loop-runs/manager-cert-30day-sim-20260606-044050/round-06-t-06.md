# T-06 -- Add additive rolling 7-day/30-day trend HTML view

## Read
- Spec: `docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-06-t-06-spec.md`.
- `Modules/SP.Audit/SP.Audit.psd1` (FunctionsToExport; ASCII).
- `Modules/SP.Audit/SP.AuditReportHtml.psm1`:
  - `Export-SPCampaignTrendHtml` (~line 4378) -- mirrored inline-CSS / `Join-Path`
    output / `[System.IO.File]::WriteAllText` + UTF-8-no-BOM / `ConvertTo-SafeHtml`
    idiom.
  - `ConvertTo-SafeHtml` (~line 27).
  - File TAIL: discovered an explicit `Export-ModuleMember -Function @(...)` list
    (~line 10585). Because the test imports the `.psm1` FLAT (Import-SPTestModules),
    the new function had to be added to BOTH that list AND the psd1.
- `Modules/SP.Audit/SP.AuditAnalytics.psm1` `_ParseDateUtc` (~line 511) --
  InvariantCulture + RoundtripKind UTC parse, copied inline as `_RtParseDateUtc`.
- `Scripts/Invoke-SP30DayManagerCertSim.ps1`: Step C `#endregion` (~637) / Step D
  `#region` (~639) insertion point; `Write-SimAudit`, `Add-ReportFiles`,
  `$reportPaths`, `$mockBaseUrl`, `$trackedRoles`, `$utf8NoBom`, `$worstExitCode`.
- `Tests/Import-TestModules.ps1` (`Import-SPTestModules -Core -Audit`).
- `Tests/SP.ManagerCert30DaySim.Tests.ps1` (fixture-load idiom).
- `Tests/TestData/ManagerCert30DaySim.State.json` (fixture shape, confirmed via a
  throwaway inspection script): 30 `camp-daily-priv-*` campaigns each with 10
  `managerAttestation` items {managerId,managerName,status,decisionsMade,decisionsTotal};
  1366 changelog events {date,groupId,groupName,identityId,operation ADD|REMOVE};
  10 `trackedPrivilegedRoles`; statuses attested/overdue/missed; priv-scoped 30d
  REMOVEs = 41; missed total = 2; changelog max date 2026-06-06.
- Mock: `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1`
  confirms `GET /v3/membership-changelog`; campaigns served from State as-is
  (managerAttestation preserved) via `GET /v3/campaigns`.

## Did
- Appended ONE new exported function `Export-SPRollingTrendHtml` at the end of
  `SP.AuditReportHtml.psm1` (before the trailing `Export-ModuleMember`). It:
  - Parses dates with an inline `_RtParseDateUtc` (InvariantCulture + RoundtripKind,
    UTC) mirroring `Measure-SPCampaignTrends._ParseDateUtc`; tolerates
    PSCustomObject OR hashtable input via `_RtProp` / `_RtInt` safe accessors.
  - Anchor = `-AnchorDate` if bound, else MAX parseable date across
    campaigns.created + changelog.date, else `Get-Date` last resort.
  - For each window (default 7, 30): contiguous per-calendar-day buckets
    `cutoff.Date..anchor.Date` (in-window = `>= cutoff && <= anchor`, matching the
    mock changelog from-date semantics). Each day carries: manager accountability
    (Attested/Overdue/Missed + DecisionsMade/Total), priv-scoped membership change
    (Added/Removed; scoped to tracked-role groupIds, falls back to ALL groups with
    a note), and Decided/Pending (decisionsMade vs remaining -- NO fabricated
    approve/revoke; only emits Approved/Revoked if attestation objects expose
    explicit fields).
  - Renders self-contained inline-CSS HTML (UTF-8 no-BOM via
    `New-Object System.Text.UTF8Encoding($false)` + `[System.IO.File]::WriteAllText`),
    escaping user text with the existing `ConvertTo-SafeHtml`. Two window sections,
    each a KPI strip + per-day table.
  - Returns `@{Success;Data=@{Path;Windows(keyed '7'/'30');AnchorDate};Error}`.
    Empty input -> Success=$true + zeroed-calendar HTML; failures caught (no throw)
    -> Success=$false. `Write-SPLog` INFO start/finish + ERROR on catch, Component
    `SP.AuditReport`.
  - Optional `New-ComposableReport` reuse is `Get-Command`-guarded (RC absent in the
    unit test); no SP.Audit RequiredModules change.
- Added `'Export-SPRollingTrendHtml'` to the `Export-ModuleMember` list in the
  psm1 AND to `FunctionsToExport` in `SP.Audit.psd1` (after
  `Export-SPCampaignTrendHtml`, with a T-06 comment; kept ASCII).
- Wired additive **Step E: Rolling 7/30-day trend HTML** into
  `Invoke-SP30DayManagerCertSim.ps1` between Step C `#endregion` and Step D
  `#region`. Gated by `-not $SkipReports`; fetches daily campaigns
  (`GET /v3/campaigns`) + changelog (`GET /v3/membership-changelog`) from the live
  mock, calls the new function under `<OutputPath>/rolling-trend`, adds the HTML to
  `$reportPaths`, records `Write-SimAudit -Step 'E-RollingTrend'`. Fully guarded:
  any failure downgrades to WARN (`worstExitCode -> max(1)`) + writes
  `rolling-trend-skipped.json`; NEVER fails the whole sim.
- Created `Tests/SP.RollingTrendHtml.Tests.ps1` (Pester 5, 16 It-blocks) mirroring
  the T-05 fixture-load idiom; imports only `-Core -Audit` (RC absent).
- Did NOT alter `Measure-SPCampaignTrends`, `Export-SPCampaignTrendHtml`, or the
  weekly digest.

## Files
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` (EDIT: appended `Export-SPRollingTrendHtml` + Export-ModuleMember entry)
- `Modules/SP.Audit/SP.Audit.psd1` (EDIT: added `Export-SPRollingTrendHtml` to FunctionsToExport)
- `Scripts/Invoke-SP30DayManagerCertSim.ps1` (EDIT: additive Step E)
- `Tests/SP.RollingTrendHtml.Tests.ps1` (CREATE: Pester 5 unit suite)
- `docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-06-t-06.md` (this record)

## Verification
All commands run from `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit`
(Windows PowerShell 5.1).

1) Parser -- 0 errors on each changed/new file:
```
AuditHtml=0
Sim=0
Test=0
```

2) psd1 ASCII guard:
```
NonAscii=0
```

3) Manifest import + export discoverable:
```
EXPORTED
```

4) Affected suite ONLY (`Invoke-Pester -Path .\Tests\SP.RollingTrendHtml.Tests.ps1 -Output Detailed`):
```
Pester v5.7.1
Discovery found 16 tests in 290ms.
Describing Export-SPRollingTrendHtml
  [+] is exported and available as a command
  [+] returns a Success=$true envelope with a null Error
  [+] writes an HTML file that exists on disk
  [+] produces a non-empty, well-formed HTML document
  [+] renders BOTH a 7-day and a 30-day rolling section in the HTML
  [+] exposes both windows in the returned Data.Windows structure
  [+] has multiple distinct day buckets in the 30-day window
  [+] has a monotone 7-day day-count not exceeding the 30-day day-count
  [+] detects privileged-role REMOVE events in the 30-day window (>0) and >= the 7-day window
  [+] priv-scoped 30-day Removed matches the fixture-derived expected count
  [+] renders an Added / Removed indicator in the HTML
  [+] reports manager accountability with Missed > 0 in the 30-day window
  [+] sums attested+overdue+missed > 0 across the 30-day window
  [+] renders attested / overdue / missed accountability tokens in the HTML
  [+] handles empty input gracefully (Success + valid HTML still written)
  [+] is deterministic for a fixed -AnchorDate (identical 30-day buckets on repeat runs)
Tests completed in 4.34s
Tests Passed: 16, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

## Commit
<filled in after commit below>

## Status
DONE
