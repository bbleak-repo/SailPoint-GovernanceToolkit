# T-06 (SPEC) -- Add additive rolling 7-day/30-day TREND HTML view (Export-SPRollingTrendHtml)

ROLE: MIDDLE (spec only -- do NOT implement). Concrete spec the INNER follows.
Everything ADDITIVE; commit to the TOOLKIT repo only on branch
`feature/manager-cert-30day-sim`. NEVER push; NEVER touch master/main.

---

## 0. Objective

ADD ONE new exported function `Export-SPRollingTrendHtml` that consumes the
30-day daily-campaign + manager-attestation + membership-changelog data and
renders a self-contained HTML file with TWO rolling-window sections (7-day and
30-day), each broken into day buckets, showing:

1. **Manager accountability day-over-day** -- per simulated day: attested /
   overdue / missed counts across the daily privileged campaign's
   `managerAttestation` array (+ decisionsMade/decisionsTotal rollup).
2. **Privileged-role membership change** -- per day: ADD / REMOVE counts from the
   membership changelog scoped to the tracked privileged-role groupIds.
3. **Decision approve/revoke** -- per day: approve vs revoke totals (derive from
   the attestation `decisionsMade` and, if present, any per-day decision tallies;
   see section 3 for the exact derivation contract).

The toolkit already has `Measure-SPCampaignTrends` + `Export-SPCampaignTrendHtml`
(PERIOD aggregation: Week/Month/Quarter) and the weekly digest, but NO ROLLING
per-DAY 7/30-day trend view. This is purely additive and MUST NOT alter
`Measure-SPCampaignTrends`, `Export-SPCampaignTrendHtml`, or the weekly digest.

---

## 1. Files to CREATE / EDIT (all additive)

1. **EDIT** `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- APPEND one new function
   `Export-SPRollingTrendHtml` at the END of the file (after the last existing
   function, before any trailing `Export-ModuleMember` if one exists -- check the
   file tail; this module is a NestedModule so exports are controlled by the psd1,
   not `Export-ModuleMember`). Do NOT modify any existing function.
   - Rationale for module home: `SP.AuditReportHtml.psm1` is the existing HTML
     export submodule (it already hosts `Export-SPCampaignTrendHtml`,
     `Export-SPLeadership*Html`, etc.) and the psd1 already groups the
     HTML-export family. Mirror `Export-SPCampaignTrendHtml`
     (`SP.AuditReportHtml.psm1` line ~4378) for the inline-CSS, `Join-Path`
     output, `[System.IO.File]::WriteAllText` + UTF-8 idiom.

2. **EDIT** `Modules/SP.Audit/SP.Audit.psd1` -- ADD the single string
   `'Export-SPRollingTrendHtml'` to the `FunctionsToExport` array (append a new
   line near the other `Export-SP*Html` entries, e.g. after
   `'Export-SPCampaignTrendHtml'` at line 78, with a `# T-06 ...` comment).
   The psd1 is confirmed ASCII (0 non-ASCII bytes) -- keep it ASCII.

3. **EDIT** `Scripts/Invoke-SP30DayManagerCertSim.ps1` -- ADD an additive new
   step (suggest **Step E: Rolling 7/30-day trend HTML**) AFTER Step C and BEFORE
   Step D's summary write (i.e. insert a new `#region Step E` between the
   `#endregion` that closes Step C at ~line 637 and `#region Step D` at ~line
   639). It must:
   - Be guarded by `-not $SkipReports` (same gate as Steps B/C); print a
     `[SKIPPED]` line otherwise (mirror the Step B/C skip blocks).
   - Acquire the daily-campaign + changelog data the function needs. The sim
     driver runs READ-ONLY against the mock and already imports the module chain;
     the trend function should accept already-loaded data (see section 2 param
     contract). The driver SHOULD source the data the same way the rest of the
     sim does -- via the existing toolkit query path if one returns the daily
     campaigns + attestation + changelog; if no single CLI query returns the
     `managerAttestation`/changelog shape, the driver MAY read it from the
     captured window-run JSON OR (acceptable, additive) load the frozen fixture
     path is NOT appropriate for the live driver -- instead pass whatever the
     existing audit/adaptive child runs already captured. **If acquiring live
     data is brittle, gate Step E behind a try/catch that downgrades to a WARN
     (worstExitCode -> max(1)) and writes a `rolling-trend-skipped.json` note --
     never let Step E make the whole sim FAIL.** Output the HTML under
     `Join-Path $OutputPath 'rolling-trend'` and add it to `$reportPaths` via the
     existing `Add-ReportFiles` helper (or `$reportPaths.Add($htmlPath)`).
   - Record a `Write-SimAudit -Step 'E-RollingTrend' -Status ... -Detail @{...}`
     line, mirroring the other steps.
   - The PRIMARY/authoritative verification of the function is the new unit test
     (section 4) against the frozen fixture; the sim-driver wiring is the
     CLI-reachability requirement and may be best-effort/guarded.

4. **CREATE** `Tests/SP.RollingTrendHtml.Tests.ps1` -- a Pester 5 unit suite that
   loads the frozen fixture, calls `Export-SPRollingTrendHtml`, and asserts the
   `@{Success=$true}` envelope + a non-empty HTML file containing distinct 7-day
   and 30-day rolling sections with per-day buckets and at least one
   added/removed AND one attested/overdue series. (Details in section 4.)

DO NOT touch `Modules/SP.ReportComponents/*` -- reuse it only OPTIONALLY (see
section 5). DO NOT add the function to any module that re-exports via
`Export-ModuleMember` in a way that would change another module's surface.

---

## 2. `Export-SPRollingTrendHtml` -- signature + contract

```powershell
function Export-SPRollingTrendHtml {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # Daily privileged campaigns, each an object with: id, name, type,
        # created (ISO8601 string), and a managerAttestation array of objects:
        #   { managerId, managerName, status (attested|overdue|missed),
        #     decisionsMade [int], decisionsTotal [int] }
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$DailyCampaigns,

        # Membership changelog events: { date (ISO8601), groupId, groupName,
        #   identityId, operation (ADD|REMOVE) }
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Changelog = @(),

        # Tracked privileged roles: { id, name, responsibleManagerId,
        #   responsibleManagerName }. Used to SCOPE the changelog ADD/REMOVE to
        #   privileged-role groupIds for the "privileged-role membership change"
        #   series. If empty, the privileged-role series falls back to ALL groups
        #   (and the HTML notes the scope).
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$TrackedRoles = @(),

        [Parameter(Mandatory)]
        [string]$OutputPath,        # DIRECTORY (mirror Export-SPCampaignTrendHtml)

        # Fixed reference date for window math. Default = max(campaign.created,
        # changelog.date). NEVER silently use Get-Date for the cutoff if data
        # carries dates -- mirrors the T-05 "anchor date" rule so output is
        # deterministic for a static dataset.
        [Parameter()]
        [datetime]$AnchorDate,

        # Windows to render (days). Default @(7, 30). Each becomes one section.
        [Parameter()]
        [int[]]$WindowDays = @(7, 30),

        [Parameter()]
        [string]$CorrelationID
    )
    ...
    return @{ Success = $true; Data = @{ Path = $htmlFile; Windows = @{...}; AnchorDate = ... }; Error = $null }
}
```

### Return envelope (MANDATORY -- house rule)
- ALWAYS return `@{ Success = [bool]; Data = <hashtable or $null>; Error = <string or $null> }`.
- On success: `Success=$true`, `Data.Path` = the written HTML file path,
  `Data.Windows` = a hashtable keyed by window-day (e.g. `'7'`,`'30'`) holding the
  computed per-day buckets (so the test can assert structure without re-parsing
  HTML), `Error=$null`.
- On failure (e.g. can't write file): `Success=$false`, `Data=$null`, `Error=<msg>`.
  Wrap the body in try/catch; log via `Write-SPLog -Severity ERROR ...` and
  return the failure envelope -- do NOT throw.
- Empty input is NOT a failure: if `DailyCampaigns` and `Changelog` are both
  empty, still write a valid HTML file (with "no data in window" notices in each
  section) and return `Success=$true`. (Mirror RC components' graceful-empty
  behaviour.)

### Logging
- `Write-SPLog -Message "Export-SPRollingTrendHtml: ..." -Severity INFO
  -Component 'SP.AuditReport' -Action 'Export-SPRollingTrendHtml'
  -CorrelationID $CorrelationID` at start and on completion (mirror
  `Measure-SPCampaignTrends` / `Export-SPCampaignTrendHtml` logging).
- Auto-generate `$CorrelationID` with `[guid]::NewGuid().ToString()` when blank
  (same idiom as the neighbouring functions).

---

## 3. Computation contract (the per-day rolling buckets)

All date parsing MUST use the InvariantCulture + `RoundtripKind` pattern already
present in `Measure-SPCampaignTrends._ParseDateUtc`
(`SP.AuditAnalytics.psm1` ~line 511) -- copy that helper inline (a private
nested `function` or a script-local helper inside `Export-SPRollingTrendHtml`).
Compare in UTC.

### Anchor + window
- `$anchor` = `$AnchorDate` if bound; else the MAX parseable date across
  `$DailyCampaigns[].created` and `$Changelog[].date`; else `(Get-Date).ToUniversalTime()`
  as last resort (only when no data carries a date).
- For each `W` in `$WindowDays`: `cutoff = $anchor.AddDays(-$W)`. A row is "in
  window" when its date `>= cutoff` AND `<= $anchor`. This MUST match the mock's
  membership-changelog endpoint semantics (`[datetime]$_.date >= from-date`,
  documented in `Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1`
  and replicated in T-05) so the HTML windowing agrees with what the mock serves.

### Day buckets (the "distinct day buckets" the verification requires)
- Within each window, bucket BY CALENDAR DAY (`date.ToUniversalTime().Date`,
  format key `yyyy-MM-dd`). Produce one row per day from `cutoff.Date` ..
  `anchor.Date` inclusive (so empty days render as zero rows, giving a true
  rolling series), OR per day that has data -- EITHER is acceptable, but the
  output MUST contain MULTIPLE distinct day rows for the 30-day section given the
  fixture (which spans ~30 days). Prefer the full contiguous range so the trend
  reads as a calendar.

### Series per day (each day row carries):
1. **Manager accountability** -- for the daily campaign(s) whose `created` falls
   on that day, sum across its `managerAttestation`:
   - `Attested` = count(status -eq 'attested')
   - `Overdue`  = count(status -eq 'overdue')
   - `Missed`   = count(status -eq 'missed')
   - `DecisionsMade` = sum(decisionsMade), `DecisionsTotal` = sum(decisionsTotal)
   (status compare case-insensitively; tolerate missing fields via a safe
   accessor like the RC `Get-RCProp` pattern OR PSObject.Properties guard --
   data is PSCustomObject from ConvertFrom-Json.)
2. **Privileged-role membership change** -- ADD/REMOVE counts from `$Changelog`
   on that day, scoped to `groupId` IN the tracked-role id set (when
   `$TrackedRoles` non-empty); else all groups. `Added`/`Removed` ints.
3. **Decision approve/revoke** -- DERIVATION CONTRACT: the fixture's
   `managerAttestation` carries `decisionsMade`/`decisionsTotal` but NOT an
   explicit approve/revoke split. Therefore:
   - `Decided` = sum(decisionsMade) for the day; `Pending` = sum(decisionsTotal -
     decisionsMade) (floored at 0).
   - Approve/Revoke split: if any attestation object exposes explicit
     `approvals`/`revocations` (or `approved`/`revoked`) properties, sum those;
     OTHERWISE label the series "Decided / Pending" (decisionsMade vs remaining)
     and DO NOT fabricate an approve/revoke ratio. The HTML series MUST be
     honest about what it shows. (The test only requires "a decision series";
     Decided/Pending satisfies it.)

### Window summary (per window, above the day table)
- Totals across the window: total Attested/Overdue/Missed, total Added/Removed
  (privileged-scoped), total Decided/Pending, count of daily campaigns, count of
  distinct days with data. Render as a small KPI strip (inline styled, like
  `Export-SPCampaignTrendHtml`'s summary) so the "rolling trend" reads at a glance.

Expose these computed structures in the returned `Data.Windows[$W]` so the unit
test can assert on data, not only HTML text.

---

## 4. Unit test -- `Tests/SP.RollingTrendHtml.Tests.ps1`

Pester 5. Mirror the import + fixture idiom from
`Tests/SP.ManagerCert30DaySim.Tests.ps1` (T-05) and the HTML-export assertion
style from existing `Export-SP*Html` suites.

### Setup
```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Audit      # gives Write-SPLog + SP.AuditReportHtml
    $fixturePath = Join-Path $PSScriptRoot 'TestData\ManagerCert30DaySim.State.json'
    $script:State = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
    $script:Daily = @($script:State.campaigns | Where-Object { $_.id -like 'camp-daily-priv-*' })
    $script:Changelog = @($script:State.membershipChangelog)
    $script:Tracked = @($script:State.trackedPrivilegedRoles)
    $script:OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rolltrend-" + [guid]::NewGuid().ToString('N'))
}
AfterAll { if ($script:OutDir -and (Test-Path $script:OutDir)) { Remove-Item $script:OutDir -Recurse -Force -ErrorAction SilentlyContinue } }
```
(2-arg `Join-Path`; PS 5.1. `Import-SPTestModules -Audit` imports
`SP.AuditReportHtml.psm1` which will then contain the new function.)

### Required It-blocks (each asserts a REAL outcome -- no always-true asserts)
1. **Function is exported / available** -- `Get-Command Export-SPRollingTrendHtml
   -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty`.
2. **Success envelope** -- call with the fixture's `$Daily`,`$Changelog`,
   `$Tracked`,`-OutputPath $OutDir`; assert `$r.Success -eq $true`,
   `$r.Error -eq $null` (or empty), `$r.Data.Path` non-empty and `Test-Path`.
3. **Non-empty HTML file** -- read the file; assert length > 0 and it contains
   `<!DOCTYPE html` and `</html>`.
4. **Both windows present** -- the HTML contains a 7-day section AND a 30-day
   section. Assert on stable anchors the implementer emits, e.g. the strings
   `7-day` (or `7 day`) and `30-day` (case-insensitive `-match`), AND
   `$r.Data.Windows.Contains('7')` / `.Contains('30')` (assert on the returned
   data structure, the robust check).
5. **Distinct day buckets** -- `$r.Data.Windows['30']` per-day collection has
   `.Count -ge 2` distinct day keys (the 30-day window spans multiple days in the
   fixture). Assert the 7-day day-count `<=` the 30-day day-count (monotone).
6. **Added/Removed series present + correct** -- assert the 30-day window's
   summed `Removed` (privileged-scoped) is `> 0` (the fixture has 41 priv-role
   REMOVEs in 30d) and `>= ` the 7-day summed `Removed`. The HTML contains a
   removed/added indicator (e.g. `Removed` / `-` token).
7. **Attested/Overdue/Missed series present + correct** -- assert the 30-day
   window summed `Missed` is `> 0` (fixture seeds missed/overdue) and that the
   summed (Attested+Overdue+Missed) across all 30 daily campaigns equals
   `30 * 10 = 300` IF all 30 days are in the 30-day window (re-derive from data;
   the implementer/test should compute, not hardcode blindly -- but the seed has
   30 campaigns x 10 managers). At minimum assert summed total `> 0` and the HTML
   contains `attested`/`overdue`/`missed` tokens.
8. **Empty-input graceful** -- call with `-DailyCampaigns @() -Changelog @()
   -OutputPath $OutDir`; assert `Success -eq $true` and a valid (non-empty) HTML
   file is still written.
9. **Deterministic anchor** -- call twice with an explicit `-AnchorDate` (the
   max changelog date) and assert the two runs produce the SAME per-day bucket
   counts in `Data.Windows['30']` (no `Get-Date` drift).

Target ~10-14 It blocks; `Failed: 0`, `Skipped: 0`.

---

## 5. OPTIONAL RC reuse (only "where it fits")

The item says "reusing the SP.ReportComponents composable engine where it fits."
The RC `New-ComposableReport` contract is built around `GroupResults`
(group/member shape) + a changelog, which does NOT cleanly map to
daily-campaign/attestation buckets. Therefore:
- It is ACCEPTABLE and PREFERRED for the main view to be SELF-CONTAINED inline
  HTML (mirroring `Export-SPCampaignTrendHtml`) so `SP.Audit` keeps no hard
  dependency on `SP.ReportComponents` (the psd1 `RequiredModules` is empty by
  design).
- IF the implementer wants RC reuse, the ONLY clean fit is the privileged-role
  membership-change panel via the existing `diff` component: build a
  `New-RCContext -GroupResults @() -Changes <priv-scoped events>` and call
  `New-RCDiffComponent`/`New-ComposableReport` ONLY when the RC module is already
  loaded in the session (`Get-Command New-ComposableReport -EA SilentlyContinue`).
  Guard it so the function NEVER fails if SP.ReportComponents is absent (the unit
  test imports only `-Core -Audit`, so RC will NOT be loaded -- the function MUST
  work without it). Do NOT add `SP.ReportComponents` to `SP.Audit` RequiredModules.
- Net: RC reuse is OPTIONAL and MUST be behind a `Get-Command` guard. The
  deliverable is correct with or without it.

---

## 6. PS 5.1 / house rules (MUST follow)
- Windows PowerShell 5.1 ONLY: 2-arg `Join-Path` (nest for 3 segments), no
  ternary/`??`/`?.`, `.Contains()` not `.ContainsKey()` for OrderedDictionary.
- `@{Success;Data;Error}` envelope; never throw to the caller.
- `Write-SPLog` for logging; UTF-8 (no BOM) file write via
  `New-Object System.Text.UTF8Encoding($false)` +
  `[System.IO.File]::WriteAllText` (the proven idiom in
  `Export-SPCampaignTrendHtml` / RC00 `New-ComposableReport`).
- HTML escape user-facing text (manager names, group names) -- reuse the existing
  `ConvertTo-SafeHtml` helper already used in `SP.AuditReportHtml.psm1`
  (`Export-SPCampaignTrendHtml` calls it). Do NOT introduce a new escape helper.
- ASCII source; `SP.Audit.psd1` stays ASCII.
- Conventional commit ending in the required Co-Authored-By trailer.

---

## 7. HEADLESS VERIFICATION (the gate)

From `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit` (Windows PowerShell 5.1):

1. Parser -- 0 errors on each changed/new file:
```
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Modules/SP.Audit/SP.AuditReportHtml.psm1',[ref]$null,[ref]$e);'AuditHtml='+@($e).Count"
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Scripts/Invoke-SP30DayManagerCertSim.ps1',[ref]$null,[ref]$e);'Sim='+@($e).Count"
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Tests/SP.RollingTrendHtml.Tests.ps1',[ref]$null,[ref]$e);'Test='+@($e).Count"
```
Expect each `=0`.

2. psd1 ASCII guard:
```
powershell -NoProfile -Command "$b=[System.IO.File]::ReadAllBytes('Modules/SP.Audit/SP.Audit.psd1');'NonAscii='+@($b|?{$_-gt127}).Count"
```
Expect `NonAscii=0`.

3. Import the manifest + confirm the new export is discoverable:
```
powershell -NoProfile -Command "Import-Module ./Modules/SP.Core/SP.Core.psd1 -Force -DisableNameChecking; Import-Module ./Modules/SP.Audit/SP.Audit.psd1 -Force -DisableNameChecking; if (Get-Command Export-SPRollingTrendHtml -EA SilentlyContinue) { 'EXPORTED' } else { 'MISSING' }"
```
Expect `EXPORTED`. (SP.Core first so Write-SPLog resolves.)

4. Run ONLY the new suite (the affected-tests gate for this item):
```
Invoke-Pester -Path .\Tests\SP.RollingTrendHtml.Tests.ps1 -Output Detailed
```
PASS criteria: `Failed: 0`, `Skipped: 0`, `Passed` >= ~10. Paste the real Pester
summary line into the INNER record. Do NOT run the full `Invoke-Pester .\Tests`
(that is the Finalize gate).

---

## 8. Commit (TOOLKIT repo only, branch feature/manager-cert-30day-sim)
```
feat(audit): add rolling 7/30-day manager-cert trend HTML view (Export-SPRollingTrendHtml, T-06)
```
ending in:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
Commit the module + psd1 + sim-driver wiring + the new test + this/the INNER
record together (or per house style, the record may be a separate commit).
