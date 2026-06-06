# Round 16
**Started:** 2026-06-05 19:05:00
**Item:** AR-16 -- Show-SPDashboard wiring

**Read:** `docs/adaptive-reports-backlog.md` (AR-16 item + Phase Summary row);
`docs/adaptive-reports-rounds/round-00-PROTOCOL.md` (loop rules + round template);
`Scripts/Show-SPDashboard.ps1` (#region Module Load, lines 174-214 — the five
path-var build + foreach import loop); `Modules/SP.Gui/SP.MainWindow.psm1`
(Show-SPDashboard function tab-init dispatch loop, lines 5958-6002 — the
SDK/Delta-Cert tab blocks mirrored here, plus the `Initialize-SPAdaptiveTab`
definition at 3066 and its export at 6096); `Gui/MainWindow.xaml` (confirmed
the tab content `x:Name="AdaptiveReportsTabContent"` at line 1720).

**Did:** Two additive, surgical edits, both mirror-of-existing-pattern.
EDIT 1 — in the launcher's `#region Module Load`, added three new
`Join-Path`-built path vars (`$deltaCertModulePath`,
`$reportComponentsModulePath`, `$adaptiveReportsModulePath`) after
`$guiModulePath`, and inserted three matching `@{ Path; Name; Required = $true }`
hashtable entries into the import foreach list, positioned right after the
`SP.Audit` entry so the load order is
Core→Api→Audit→DeltaCert→ReportComponents→AdaptiveReports→Sdk→Gui (deps before
dependents). The existing import loop body is unchanged. EDIT 2 — in the
`Show-SPDashboard` function's tab-init dispatch loop in `SP.MainWindow.psm1`,
inserted an "Adaptive Reports tab" block (`Find-Control … 'AdaptiveReportsTabContent'`
→ `Initialize-SPAdaptiveTab -TabContent $adaptiveTab`) immediately before the
existing Settings-tab block, mirroring the SDK and Delta-Cert blocks. No existing
path var, foreach entry, `Initialize-*Tab` call, import, or export was removed or
reordered destructively.

**Files:**
- `Scripts/Show-SPDashboard.ps1` — modified (additive: 3 path vars + 3 foreach
  entries inside #region Module Load).
- `Modules/SP.Gui/SP.MainWindow.psm1` — modified (additive: 1 tab-init block
  before the Settings block).
- `docs/adaptive-reports-backlog.md` — AR-16 flipped TODO→DONE (Phase Summary row
  + item section header).
- `docs/adaptive-reports-rounds/round-16.md` — this file (new).

**Verification:**
  - Pester: n/a for this item (AR-16 is launcher/module-load wiring; no new test
    file. The W-09 structure harness is AR-17/AR-18. Full suite not run per loop
    rule — outer loop runs the full gate at finalize.)
  - AST: `[Parser]::ParseFile` on `Scripts/Show-SPDashboard.ps1` → **0 parse
    errors**; on `Modules/SP.Gui/SP.MainWindow.psm1` → **0 parse errors**.
  - Manifest/import: `Test-ModuleManifest` on `SP.ReportComponents.psd1`,
    `SP.AdaptiveReports.psd1`, `SP.DeltaCert.psd1` → all OK ("manifests OK").
  - Grep — launcher chain: `SP.ReportComponents|SP.AdaptiveReports|SP.DeltaCert`
    in `Show-SPDashboard.ps1` → 6 hits (lines 188-190 path vars + 196-198 foreach
    entries), all three names present.
  - Grep — tab-init call: `Initialize-SPAdaptiveTab -TabContent` in
    `SP.MainWindow.psm1` → 1 hit at line 5982 (inside the tab-init loop).
  - Grep — ordering: `AdaptiveReportsTabContent` at line 5980 < `SettingsTabContent`
    at line 5986 → adaptive block precedes Settings block, as specified.

**Review:** PASS (self-checked against spec; independent code-review gate is the
outer loop's responsibility). Additive-only confirmed: no removed/reordered
entries; the three module entries and one tab block are pure insertions. The
runspace block (3258-3269) and manifests were not touched.

**Backlog update:** AR-16 -> DONE

**Completed:** 2026-06-05 19:07:34
**Status:** SUCCESS
