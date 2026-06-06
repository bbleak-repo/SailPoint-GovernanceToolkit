# T-04 -- Reporting + analytics on enriched data: trends, snapshot diff, disconnected cross-app/30-day -> HTML

## Read
Inspected the existing functions + conventions before writing anything (ZERO module edits):

- `Tests/SP.DisconnectedUploadHtml.Tests.ps1` (T-03) -- copied the discovery-scope mock
  probe + BeforeAll re-probe + per-run `_artifacts` dir + AfterAll cleanup pattern.
- `Tests/Import-TestModules.ps1` -- confirmed `-Core -Api -DisconnectedApps` does NOT load
  the Audit family; the Audit analytics + HTML exporters live behind the **`-Audit`** switch
  (SP.AuditAnalytics, SP.AuditReportCore, SP.AuditReportHtml). The test therefore calls
  `Import-SPTestModules -Core -Api -Audit -DisconnectedApps`.
- `Tests/SP.DisconnectedApps.Tests.ps1` DA-17-T -- the cross-app identity-risk fixture shape
  and the `Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics` /
  `Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics` pattern (the analytics functions
  call Get-SPRegisteredApps, so the mock targets the module where the call resolves).
- `Modules/SP.Audit/SP.AuditAnalytics.psm1`
  - `Measure-SPCampaignTrends` (L455-739): returns a **hashtable** `@{Periods;Trends;Summary}`
    (NOT a Success envelope). Periods aggregate ApprovedCount/RevokedCount over
    `CampaignCreated`-month buckets; >=3 periods => Summary.OverallDirection is a real
    direction; Trends.ApprovalRate is classified.
  - `Compare-SPConfigurationSnapshots` (L4728-5145): consumes two hashtables with top-level
    `capturedAt/snapshotId/settingsHash` + `sources` array (Build-SourceIndex keys on .Id;
    compares Name/Enabled/OwnerName/OwnerId/ConnectorType/Description/AccountCount). Returns
    `@{Success;Data=@{Changes;HasDrift;Summary=@{Added;Removed;Changed;...}}}`. Added/Changed
    entries carry `Category='Source'`, `ChangeType`, `ItemId`, `Property`, `OldValue/NewValue`.
- `Modules/SP.Audit/SP.AuditReportHtml.psm1`
  - `Export-SPCampaignTrendHtml` (L4378): returns the HTML **path string**; header has
    `Period` + `Approval %`; rows emit the period Label (e.g. `2026-02`).
  - `Export-SPConfigDriftHtml` (L10395): consumes `Compare .Data`; banner `DRIFT DETECTED`,
    `Added` badge column; the Source change table prints the source **Name** (so the Workday
    source Name embeds `src-workday-001` for traceability).
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppAnalytics.psm1`
  - `Get-SPDisconnectedAppIdentityRisk` (L259): 1 app=Normal, 2=Elevated, 3+=High; Summary has
    TotalIdentities/SingleApp/MultiApp/HighRisk.
  - `Get-SPDisconnectedAppTrend` (L1378): reads `{OutputPath}/{App}/disconnected-app-audit.jsonl`;
    parser switches on `Action` and reads `Timestamp` (ISO) + `IdentitiesProcessed` +
    `CampaignsCreated` for `DisconnectedAppCertRun`. Only apps with in-window events appear.
  - `Get-SPDisconnectedAppDeliveryStatus` (L33): per-app AccountFilePath -> Delivered (fresh) /
    Stale / Missing / Disabled / Error; RowCount via Import-Csv; Summary.Total etc.

## Did
ADDED one Pester file `Tests/SP.EnrichedAnalyticsHtml.Tests.ps1` (ids EA-01..EA-12). No module,
exporter, script, or tracked config was modified.

- (a) EA-01..EA-03 -- in-memory 4-metric array spanning Jan/Feb/Mar/Apr 2026 with rising
  approvals -> `Measure-SPCampaignTrends -GroupBy Month`; assert >1 period, each TotalItems>0 +
  CampaignCount>=1, OverallDirection in {Improving,Degrading,Stable}, Trends.ApprovalRate set,
  >=3 distinct month labels incl. `2026-02`.
- (b) EA-04..EA-05 -- two hand-built snapshots; B adds Workday + DelimitedFile sources and flips
  src-ad-001 OwnerName -> `Compare-SPConfigurationSnapshots`; assert Success, HasDrift,
  Summary.Added>=2, a Source/Added entry for `src-workday-001`, and a Source/Changed OwnerName
  entry on src-ad-001 (Dana Owner -> Frank Owner).
- (c) EA-06..EA-09 -- disconnected analytics over generated fixtures:
  IdentityRisk (3/2/1-app emails -> High/Elevated/Normal); Trend (per-app JSONL with two
  DisconnectedAppCertRun events in 2026-03/04); DeliveryStatus fresh file -> Delivered (RowCount>0)
  and a missing file -> Missing.
- (d) EA-10..EA-11 -- `Export-SPCampaignTrendHtml` + `Export-SPConfigDriftHtml` -> path exists +
  Get-Content -Raw -match content assertions (`Approval %`/`Period`/`2026-02`;
  `DRIFT DETECTED`/`Added`/`Workday`/`src-workday-001`).
- (e) EA-12 -- OPTIONAL live cross-check, `-Skip:(-not $mockUpRun)`, soft It: fetch real
  enriched-mock campaigns -> metrics -> trends; uses `Set-ItResult -Skipped` if the live read
  yields no usable data (graceful per spec). It loads the localhost mock config read-only and
  does NOT overlay/restore settings.local.json (kept simple to avoid overlay risk).

All artifacts live under a per-run `Tests/_artifacts/enriched-analytics-*` dir removed in AfterAll.

## Files
- `Tests/SP.EnrichedAnalyticsHtml.Tests.ps1` (new)
- `docs/loop-runs/autoloop2-data-campaigns-20260606-0908/round-04-t-04.md` (this record)

## Verification
Repo root `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit`, branch `feature/manager-cert-30day-sim`.

### Mock probe (PowerShell)
```
Invoke-WebRequest http://localhost:8080/oauth/token (POST client_credentials) -> probe=200
```

### Primary headless gate
```
Invoke-Pester -Path .\Tests\SP.EnrichedAnalyticsHtml.Tests.ps1 -Output Detailed
```
REAL output (tail):
```
Describing EA: Reporting + analytics over the enriched dataset -> HTML
 Context EA-01 .. EA-03: Measure-SPCampaignTrends multi-period (offline)
   [+] EA-01 returns >1 period bucket, each with non-zero items + a campaign 135ms
   [+] EA-02 classifies an overall direction + an ApprovalRate trend (>=3 periods) 25ms
   [+] EA-03 period labels span >=3 distinct months 26ms
 Context EA-04 .. EA-05: Compare-SPConfigurationSnapshots drift (offline)
   [+] EA-04 detects the new (added) sources + flags drift 43ms
   [+] EA-05 detects the changed OwnerName on src-ad-001 45ms
 Context EA-06 .. EA-09: disconnected analytics (offline / mocked registry)
   [+] EA-06 Get-SPDisconnectedAppIdentityRisk flags the 3-app identity as High 322ms
   [+] EA-07 Get-SPDisconnectedAppTrend returns >=1 app from the JSONL trail 130ms
   [+] EA-08 Get-SPDisconnectedAppDeliveryStatus marks the fresh file Delivered 163ms
   [+] EA-09 Get-SPDisconnectedAppDeliveryStatus marks a missing file Missing 52ms
 Context EA-10 .. EA-11: analytics HTML + content assertions (offline)
   [+] EA-10 Export-SPCampaignTrendHtml renders a correct trend report 114ms
   [+] EA-11 Export-SPConfigDriftHtml renders the drift report with the new source 100ms
 Context EA-12: live cross-check over the enriched mock (skips if mock down)
   [!] EA-12 live campaigns -> metrics -> trends produces >=1 period 5ms
Tests completed in 3.54s
Tests Passed: 11, Failed: 0, Skipped: 1, Inconclusive: 0, NotRun: 0
```
EA-01..EA-11 PASS; EA-12 Skipped. Note on EA-12: the mock probe returns 200, but the toolkit's
resolved config (a developer `settings.local.json` overlay) points auth at a LAN host
`http://10.0.0.143:8080` with `mock-client` creds (verified:
`authMode=ConfigFile cid=mock-client tokenUrl=http://10.0.0.143:8080/oauth/token`), which is
unreachable from this run -> `Get-SPAuditCampaigns failed ... Auth token acquisition failed:
Unable to connect to the remote server`. EA-12 therefore self-skips gracefully via
Set-ItResult -Skipped, which is the spec-sanctioned soft outcome; the offline EA-01..EA-03
already prove multi-period analytics. Failed=0.

### Direct function-output proof (real)
```
periods=4 dir=Improving approvalTrend=Improving
added=2 hasdrift=True
identityRisk success=True highCount=1 highEmail=shared3@corp.com highAppCount=3 MultiApp=2 HighRisk=1
```

### HTML content checks (real grep hits, exporters run outside Pester)
```
trend_ApprovalPct=True trend_Period=True trend_2026-02=True
drift_DRIFT=True drift_Added=True drift_workdayId=True drift_Workday=True
```
(CampaignTrends-*.html matched 'Approval %' + 'Period' + '2026-02';
 ConfigDrift-*.html matched 'DRIFT DETECTED' + 'Added' + 'src-workday-001' + 'Workday'.)

### Cleanliness
```
git status --short
?? Tests/SP.EnrichedAnalyticsHtml.Tests.ps1
```
Only the new test file (pre-commit). No `_artifacts` leakage, no settings.local.json change
(EA-12 did not overlay it). Mock left clean (no error-injection/scenario touched).

## Commit
876778e (amended; initial 10869fc) -- test(analytics): EA-01..EA-12 enriched analytics + drift + disconnected -> HTML (T-04)

## Status
DONE
