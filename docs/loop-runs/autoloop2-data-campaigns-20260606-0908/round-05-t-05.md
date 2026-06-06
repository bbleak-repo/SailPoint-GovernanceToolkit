# T-05 -- GUI surfacing (headless author+verify): privileged/accountability/trend/disconnected reports in Adaptive Reports tab

## Read
- `Gui/MainWindow.xaml` (lines 1718-1866) -- Adaptive Reports TabItem, `AdaptiveReportsTabContent`
  Grid, the Row-0 ScrollViewer StackPanel, and the existing Baseline Reports section
  (TextBlock + Border + WrapPanel of `ChkArBase*` checkboxes, closing at line 1838/1839).
- `Modules/SP.Gui/SP.MainWindow.psm1` -- `Invoke-GuiAdaptiveReport` (line 3149): the
  UI-thread gather (componentMap/baselineMap blocks, empty-selection guard,
  SessionStateProxy.SetVariable calls) and the background-runspace scriptBlock
  (module Import-Module list, audits build, gr/ds chain, baseline dispatch foreach).
- `Tests/Harness/Test-W09-AdaptiveTabStructure.ps1` -- the W-09 scaffold (STA guard,
  Add-Result, Load-Xaml, Get-NamedControl, Test-ControlsPresent, Get-FrameworkElements,
  WG-09-07 ToolTip logic, JSONL + exit-1-on-FAIL contract).
- `Tests/SP.SdkLoadUx.Tests.ps1` -- XAML-parse / Add-Type PresentationFramework idiom.
- Exporter signatures: `Export-SPCampaignTrendHtml` (TrendData hashtable, line 4378),
  `Export-SPAuditHtml` (CampaignAudits hashtable array, line 1292; privileged + reviewer
  accountability sections render via `Build-SingleCampaignHtml`), and
  `Export-SPDisconnectedAppDeltaHtml` (DeltaResult hashtable, line 102, SP.DisconnectedApps);
  `Measure-SPCampaignTrends` lives in SP.Audit\SP.AuditAnalytics.psm1.

## Did (strictly ADDITIVE)
1. **XAML** (`Gui/MainWindow.xaml`): added a new "Enriched Reports" SectionHeader +
   SectionBorder WrapPanel sibling immediately AFTER the Baseline Reports closing Border
   and BEFORE the StackPanel close, containing four named checkboxes (IsChecked False,
   each with a non-empty ToolTip, same style as the Baseline checkboxes):
   `ChkArEnrichedPrivilegedAttestation`, `ChkArEnrichedAccountability`,
   `ChkArEnrichedTrend`, `ChkArEnrichedDisconnected`. No Grid.Row attribute (inside the
   existing Row-0 StackPanel). No existing control renamed/removed.
2. **Handler wiring** (`Modules/SP.Gui/SP.MainWindow.psm1`, inside `Invoke-GuiAdaptiveReport`):
   - UI-thread gather: added an ordered `$enrichedMap` (four ChkArEnriched names ->
     keys privileged-attestation / accountability / trend / disconnected), a foreach
     Find-Control + IsChecked gather into `$enriched`, `$enrichedArr = $enriched.ToArray()`.
   - WIDENED the empty-selection guard to a third clause `$enriched.Count -eq 0`.
   - Added `$runspace.SessionStateProxy.SetVariable('Enriched', $enrichedArr)`.
   - Added `SP.DisconnectedApps\SP.DisconnectedApps.psd1` to the runspace Import-Module list.
   - Added an enriched-dispatch foreach AFTER the baseline dispatch: each branch wrapped
     in try/catch SOFT-SKIP (status note, no crash). privileged-attestation/accountability
     -> `Export-SPAuditHtml -CampaignAudits $audits.ToArray()`; trend ->
     `Measure-SPCampaignTrends` + `Export-SPCampaignTrendHtml`; disconnected throws a
     soft-skip (CSV/delta inputs not present in the adaptive runspace). Reuses the existing
     `BtnArGenerate` button -- no new button, no change to Initialize-SPAdaptiveTab hookups
     or Export-ModuleMember.
3. **Structure test** (NEW `Tests/Harness/Test-W09c-EnrichedReportsStructure.ps1`): cloned
   the W-09 scaffold; WG-09c-01 container present, WG-09c-02 all four ChkArEnriched present,
   WG-09c-03 every ChkArEnriched control has a non-empty ToolTip, WG-09c-04 BtnArGenerate
   still present. Same JSONL + summary + exit-1-on-FAIL contract.
4. **Pester test** (NEW `Tests/SP.AdaptiveTabEnrichedGui.Tests.ps1`): XAML-STA context
   (skipped off-STA via -Skip on apartment state) loads MainWindow.xaml and asserts each
   ChkArEnriched control resolves with a non-empty ToolTip; Source-wiring context asserts
   the four names, enrichedMap/enriched gather, SetVariable('Enriched'), the widened guard,
   and regression anchors (ChkArBasePrivileged/BtnArGenerate/Initialize-SPAdaptiveTab);
   XAML-source context asserts the four names + Enriched Reports header + legacy Baseline
   Reports header + AdaptiveReportsTabContent.

## Files
- `Gui/MainWindow.xaml` (added Enriched Reports section)
- `Modules/SP.Gui/SP.MainWindow.psm1` (enrichedMap gather, widened guard, SetVariable, import, dispatch)
- `Tests/Harness/Test-W09c-EnrichedReportsStructure.ps1` (NEW)
- `Tests/SP.AdaptiveTabEnrichedGui.Tests.ps1` (NEW)
- `docs/loop-runs/autoloop2-data-campaigns-20260606-0908/round-05-t-05.md` (this record)

## Verification (real commands + real output)

### (a) Headless STA XAML parse
```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName PresentationFramework,System.Xaml; $r=[System.Xml.XmlReader]::Create('Gui\MainWindow.xaml'); try { $w=[System.Windows.Markup.XamlReader]::Load($r); 'XAML-OK' } finally { $r.Close() }"
```
Output:
```
XAML-OK
```

### (b) New W-09c structure test (-STA)
```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Harness\Test-W09c-EnrichedReportsStructure.ps1
```
Output:
```
{"id":"WG-09c-01","result":"PASS","note":"Container Grid 'AdaptiveReportsTabContent' present (Grid)"}
{"id":"WG-09c-02","result":"PASS","note":"Enriched checkboxes: all 4 controls present"}
{"id":"WG-09c-03","result":"PASS","note":"All 4 ChkArEnriched* controls have a non-empty ToolTip"}
{"id":"WG-09c-04","result":"PASS","note":"BtnArGenerate present (Button) -- Generate button reused for enriched reports"}
{"summary":true,"pass":4,"fail":0,"blocked":0,"total":4}
EXIT=0
```

### (c) Existing W-09 structure test (regression, -STA)
```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Harness\Test-W09-AdaptiveTabStructure.ps1
```
Output:
```
{"id":"WG-09-01","result":"PASS","note":"Adaptive Reports tab found at index 6 (precedes Settings at index 7 of 8 tabs)"}
{"id":"WG-09-02","result":"PASS","note":"Container Grid 'AdaptiveReportsTabContent' present (Grid)"}
{"id":"WG-09-03","result":"PASS","note":"Options: all 3 controls present"}
{"id":"WG-09-04","result":"PASS","note":"Component checkboxes: all 5 controls present"}
{"id":"WG-09-05","result":"PASS","note":"Baseline checkboxes: all 7 controls present"}
{"id":"WG-09-06","result":"PASS","note":"Actions + progress + status: all 5 controls present"}
{"id":"WG-09-07","result":"PASS","note":"All 19 Btn*/Chk* controls have a non-empty ToolTip"}
{"summary":true,"pass":7,"fail":0,"blocked":0,"total":7}
EXIT=0
```
(WG-09-07 now counts 19 controls = 15 legacy + 4 new enriched, all with ToolTips.)

### (d) New enriched GUI Pester test (-STA, XAML context NOT skipped)
```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\Tests\SP.AdaptiveTabEnrichedGui.Tests.ps1 -Output Detailed"
```
Output (tail):
```
 Context XAML-STA (loaded WPF tree)
   [+] loads MainWindow.xaml and finds the Adaptive Reports tab content
   [+] resolves each ChkArEnriched control with a non-empty ToolTip
 Context Source wiring (SP.MainWindow.psm1)
   [+] references all four ChkArEnriched control names
   [+] defines an enrichedMap and gathers into an enriched list
   [+] sets the Enriched runspace variable
   [+] widens the empty-selection guard to reference enriched
   [+] still defines the legacy ChkArBasePrivileged / BtnArGenerate / Initialize-SPAdaptiveTab (regression)
 Context XAML source (MainWindow.xaml)
   [+] contains the four new ChkArEnriched names
   [+] contains the Enriched Reports section header
   [+] still contains the legacy Baseline Reports header + AdaptiveReportsTabContent (regression)
Tests completed in 1.79s
Tests Passed: 10, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### (e) Adjacent GUI/adaptive Pester regression
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\Tests\SP.SdkLoadUx.Tests.ps1,.\Tests\SP.AdaptiveReports.Tests.ps1,.\Tests\SP.AdaptiveCli.Tests.ps1 -Output Detailed"
```
Output (tail):
```
Tests completed in 5.79s
Tests Passed: 32, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### (f) Grep regression proof
`ChkArBasePrivileged|BtnArGenerate|AdaptiveReportsTabContent|Initialize-SPAdaptiveTab`:
- `Gui\MainWindow.xaml`: 3 matches (ChkArBasePrivileged, BtnArGenerate, AdaptiveReportsTabContent; Initialize-SPAdaptiveTab is psm1-only).
- `Modules\SP.Gui\SP.MainWindow.psm1`: 7 matches (all four anchors present).

### Extra: AST parse of modified psm1
```
[Parser]::ParseFile("Modules\SP.Gui\SP.MainWindow.psm1") -> PARSE-OK (0 errors)
```

## Commit
`469dbfd` -- feat(gui): surface enriched reports (privileged/accountability/trend/disconnected) in Adaptive Reports tab
(initial commit bdc1e48 was amended to 469dbfd to fold in this record's commit hash.)

## Status
DONE
