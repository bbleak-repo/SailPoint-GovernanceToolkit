# Adaptive Reports — Architecture & Reconciled Plan

**Created:** 2026-06-05
**Status:** Plan (Opus 4.8 reconciled from a read-only portability analysis of
`C:\temp\Coding\EntraIDScripts\Group-Enumerator`).
**Backlog:** `docs/adaptive-reports-backlog.md` (AR-01 … AR-20)
**Protocol:** `docs/adaptive-reports-rounds/round-00-PROTOCOL.md`
**Backup taken first:** `C:\temp\coding\SailPoint\_backups\SailPoint-GovernanceToolkit-20260605-154412.zip` (83.4 MB full snapshot, rollback point).

> **Source of truth:** edit this Markdown. The backlog cites item numbers here.
> The middle loop reads this **plus the actual current code** (never trust the
> plan over the code).

---

## 1. Goal & principles

Port the **adaptive report engine** and **WPF report-selection experience** from
the Group-Enumerator tool into the SailPoint ISC Governance Toolkit — as
**additions, not replacements**. Nothing existing is removed or rewired; every
new capability lands as a new module, a new CLI script, and a new GUI tab that
sit alongside the current reports.

Principles (in priority order):
1. **Additive & reversible.** New `SP.ReportComponents` + `SP.AdaptiveReports`
   modules, a new `Invoke-SPAdaptiveReport.ps1`, a new **Adaptive Reports** GUI
   tab. Existing scripts/tabs/reports are untouched. The pre-run backup is the
   rollback floor.
2. **Port proven code verbatim where it is data-source-agnostic.** The RC
   component framework is copied unchanged; only namespacing/manifest wrapping is
   added. The *only* net-new logic is the data adapter.
3. **Both CLI and GUI**, sharing the same modules + data adapters + Safety/output
   conventions, exactly like the rest of the toolkit.
4. **Clean & safe.** PS 5.1, SP.* layering rules, `@{Success;Data;Error}` envelope
   for new SP.Api/adapter calls, `Write-SPLog` logging, no secrets, mock-validated.

---

## 2. Source analysis (what was built there)

From the read-only analysis of `Group-Enumerator` (do NOT modify that repo):

### 2.1 RC ReportComponents framework — **CLEAN (crown jewel)**
`Modules\ReportComponents\RC00-Framework.ps1` + `RC01..RC06`. A composable HTML
report engine, 100% data-source-agnostic (no Graph/AD/LDAP anywhere):

- **Component contract:** `New-RC<Name>Component(-Context, -Options, -Palette)` →
  returns an HTML `<section>` fragment (never a full page); self-registers via
  `Register-RCComponent`.
- **Context:** `New-RCContext` builds a uniform envelope:
  `@{ GroupResults[]; Enumerated[]; StaleResults?; Changes?; ChangeLogPath?;
  Domains[]; IsCrossDomain; Theme; Metadata }`.
- **Composer:** `New-ComposableReport` takes an ordered component list
  (`'kpi-cards'`,`'heatmap:half'`,`'tree:half'`,…), renders each with graceful
  skip on missing prerequisites, packs half-width pairs side-by-side, injects
  palette-driven shared CSS, writes UTF-8 no-BOM HTML.
- **Theme:** `Get-RCTheme light|dark` → palette hashtable of CSS tokens;
  `Get-RCSharedCss` uses only tokens (no hardcoded colors).
- **Helpers (StrictMode-safe, accept hashtable OR PSCustomObject):**
  `Get-RCProp`, `Get-RCDirectCount`, `ConvertTo-RCHtmlText`.

| Component | Fn | Input | Port |
|---|---|---|---|
| RC00 framework | `New-ComposableReport` | component list + Context | CLEAN |
| RC01 KPI cards | `New-RCKpiCardsComponent` | GroupResults | CLEAN |
| RC02 heatmap | `New-RCHeatmapComponent` | Enumerated | CLEAN |
| RC03 tree | `New-RCTreeComponent` | Enumerated | CLEAN |
| RC04 diff | `New-RCDiffComponent` | Changes[] / ChangeLogPath | ADAPT (changelog) |
| RC05 top-N | `New-RCTopNComponent` | Enumerated | CLEAN |
| RC06 group table | `New-RCGroupTableComponent` | GroupResults | CLEAN |

### 2.2 Baseline reports B01–B10 — mostly **CLEAN**
All share one signature: `Export-<Name>Report -GroupResults -OutputPath [-Title]
[-Theme dark|light]`. No external imports. Governance-relevant subset:

| Rpt | Fn | Concept | Port |
|---|---|---|---|
| B01 | `Export-MembershipSnapshotRosterReport` | certification roster | CLEAN |
| B02 | `Export-AccessCertificationAttestationReport` | UAR sign-off sheet | CLEAN |
| B03 | `Export-PrivilegedGroupReviewReport` | privileged review (name heuristics) | CLEAN |
| B04 | `Export-SodToxicComembershipReport` | SoD / toxic combos | ADAPT (rule-set) |
| B05 | `Export-OrphanedDisabledMembersReport` | disabled-still-has-access | CLEAN |
| B06 | `Export-GroupInventoryCatalogReport` | inventory/catalog | CLEAN |
| B07 | empty/stale groups | hygiene | CLEAN (likely) |
| B08 | membership change attestation | change trail | ADAPT (changelog) |
| B09 | nested membership audit | nesting | ADAPT |
| B10 | `Export-GovernanceExecutiveSummaryReport` | exec summary (numbers-only) | CLEAN |

### 2.3 GUI — **compatible patterns, ADAPT the two deltas**
Both apps already share: STA launcher → background runspace → `DispatcherTimer`
polling a synchronized hashtable → `.GetNewClosure()` + module re-entry. The GE
**Reports tab** is a report-selection UI (component/baseline checkboxes + theme +
preview). `Gui\Styles.xaml` is a self-contained dark theme that **already
matches** SP's inline styles. SP's `Tests\Harness\SP.UiTest.psm1` is a **superset**
of GE's FlaUI harness — nothing to port there.

**Two deltas to adapt to SP's (safer) conventions when porting GUI code:**
- Dispatcher: GE uses `$script:MainWindow.Dispatcher`; **SP uses
  `[System.Windows.Application]::Current.Dispatcher`** (`Invoke-OnDispatcher`).
- Module re-entry: GE stores `$script:ThisModule` globally; **SP captures a local
  `$module` in the closure** (`& $module { param(...) } $args` + `.GetNewClosure()`).
  See `[[project_wpf_module_scope_gotcha]]`.

---

## 3. Target architecture (what we build here)

### 3.1 New modules
```
Modules\SP.ReportComponents\
    SP.ReportComponents.psd1          # manifest; NestedModules = RC00..RC06
    RC00-Framework.ps1                # verbatim copy (namespace-safe)
    RC01-KpiCards.ps1 … RC06-GroupTable.ps1
Modules\SP.AdaptiveReports\
    SP.AdaptiveReports.psd1
    SP.RCDataset.psm1                 # the adapters (entitlement + campaign)
    SP.BaselineReports.psm1           # ported B0x Export-SP* functions
```
Layering: `SP.ReportComponents` depends on nothing (pure presentation, sibling of
SP.Core). `SP.AdaptiveReports` depends on SP.Core + SP.Api + SP.Audit (to read
ISC data) + SP.ReportComponents. The GUI tab lives in the existing SP.Gui.

> **Why copy RC verbatim rather than rewrite:** it is proven, self-contained, and
> data-agnostic. Copying minimizes risk; the manifest/namespacing is the only
> change. If any RC file dot-sources a sibling, preserve that within the module.

### 3.2 The data adapter — the crux (`Build-SPRCDataset`)
Maps ISC data → the RC `GroupResults` shape:
```
GroupResults[i] = @{
  Data = @{ Domain; GroupName; MemberCount; IsNested; Skipped;
            Members = @( @{ DisplayName; SamAccountName; Email; Enabled } ) }
  Errors = @()
}
```
**Decision (human-ratified 2026-06-05): entitlement-primary, campaign-secondary —
two anchors, one RC engine.**

- **Entitlement anchor (primary)** — `Build-SPRCDataset -Anchor Entitlement`:
  - "Group" = an ISC **entitlement / access profile / role**
    (`GroupName` = entitlement name, `Domain` = source name).
  - "Members" = the **identities that hold it** (`DisplayName`/`SamAccountName` =
    identity name/alias, `Email`, `Enabled` = identity lifecycle active?).
  - `IsNested` = role/access-profile that bundles entitlements; `Skipped` = read
    failure. Enables: inventory (B06), top-N most-assigned (RC05), privileged
    entitlement review (B03 with an ISC privileged-pattern list), disabled
    identity still holding access (B05), SoD toxic entitlement combos (B04 with an
    ISC rule-set), governance exec summary (B10), heatmap/tree/KPI.
  - Reads: `GET /v3/entitlements` (+ members) and/or `POST /v3/search` for the
    identity↔entitlement mapping. **Mock-parity flag:** the mock returned **405 on
    `/v3/entitlements`** during report validation — AR-07 confirms/extends the
    mock or routes the adapter through `/v3/search` access aggregations.
- **Campaign anchor (secondary)** — `Build-SPRCDataset -Anchor Campaign`:
  - "Group" = a **certification** (or campaign); `Domain` = campaign name.
  - "Members" = the **identities/access-review-items** under it; `Enabled` =
    identity active. Renders the same RC components/baseline reports over a
    campaign view. Reads campaigns/certs/ARIs (endpoints already proven on the
    mock via W-03b/W-05).

The adapter is the **only** net-new logic and is fully unit-testable against
synthetic + mock data. Keep platform reads behind the `@{Success;Data;Error}`
envelope.

### 3.3 Ported baseline reports
Port the CLEAN governance subset over the adapted dataset, renamed to the SP
convention but keeping the proven body: `Export-SPRCInventoryReport` (B06),
`Export-SPRCPrivilegedReviewReport` (B03), `Export-SPRCOrphanedDisabledReport`
(B05), `Export-SPRCGovernanceExecSummaryReport` (B10), `Export-SPRCRosterReport`
(B01), `Export-SPRCAccessCertAttestationReport` (B02), and
`Export-SPRCSodReport` (B04 — with an ISC entitlement-conflict rule-set). RC04
diff / B08 changelog reports are **deferred** (need a change-event adapter).

### 3.4 CLI — `Invoke-SPAdaptiveReport.ps1` (additive)
Thin wrapper following toolkit script conventions: `[CmdletBinding()]`
(read-only → **no** `SupportsShouldProcess`, per CLI-005), standard `-ConfigPath`
/ `-Token` / `-TokenExpiryMinutes` / `-Help`, `[ValidateSet('Console','HTML','JSON','Both')]
$OutputMode`. New params: `-Anchor Entitlement|Campaign`, `-Components <keys>`
(composable list), `-BaselineReport <names>`, `-Theme light|dark`, `-OutputPath`.
Pulls data → adapts → `New-ComposableReport` / `Export-SPRC*` → HTML/JSONL.
Exit codes mirror the report scripts (0 ok · 1 no data/warnings · 2 param · 3 auth
· 4 config).

### 3.5 GUI — new **Adaptive Reports** tab (additive)
Insert a TabItem (after Governance, before Settings) hosting: anchor selector
(Entitlement/Campaign), composable-component checkboxes (kpi/heatmap/tree/topN/
table), baseline-report checkboxes, theme selector, **Generate** + **Open**
buttons, progress + status. Wiring (`Initialize-SPAdaptiveTab` in
`SP.MainWindow.psm1`):
- All handlers via `& $module { param(...) } $args` + `.GetNewClosure()` (NOT
  GE's `$script:ThisModule`).
- Generation runs on a **background STA runspace** (import SP.Core/Api/Audit/
  ReportComponents/AdaptiveReports there); marshal status back via
  `Invoke-OnDispatcher` (SP's `Application.Current.Dispatcher`).
- On success, open the HTML with the **`Wait-SPReportFileReady`** helper added in
  the report-flow work (poll until flushed/readable) then `Start-Process`.
- Every `Btn*`/`Chk*` gets a non-empty ToolTip; reuse existing SP styles
  (`ToolkitButton`/`ToolkitTabItem`/`FieldLabel`); namespaced control x:Names
  (`AdaptiveReports*` / `BtnAr*` / `ChkAr*`) to avoid collisions.

### 3.6 Theme
Reuse SP's existing inline resource styles (already equivalent to GE's
`Styles.xaml`). No new theme file required; if a shared `Styles.xaml` is later
desired, merge — do not duplicate.

---

## 4. Conventions the loop must follow

- **PS 5.1 + SP layering** (see README "Layering rules"). New module manifests:
  fresh GUID, `NestedModules`, explicit `FunctionsToExport`, `RequiredModules=@()`.
- **WPF notes:** local `$module` closure capture; no `$script:` in raw delegates;
  no API/IO on the UI thread (use the runspace); `Application.Current.Dispatcher`
  for marshaling. (`[[project_wpf_module_scope_gotcha]]`,
  `[[feedback_flaui_mouse_doubleclick]]`.)
- **CLI policy:** read-only scripts have **no** `SupportsShouldProcess` (CLI-005);
  `OutputMode` ValidateSet = `Console/JSON/HTML/Both`; `-Help` works (CLI tests
  CLI-001..005 in `Tests/SP.CliScripts.Tests.ps1`).
- **HTML:** UTF-8 no-BOM; inline/token CSS (Word-paste safe); HTML-encode via the
  RC escaper. Don't reintroduce the `ConvertTo-SafeHtml`-not-exported trap — RC
  ships its own `ConvertTo-RCHtmlText`.
- **Return envelope** `@{Success;Data;Error}` for new SP.Api/adapter reads;
  `Write-SPLog` for logging.

---

## 5. Headless verification vs. GUI boundary

**Headless (loop can prove):** Pester (adapters → shape, components → valid HTML
fragment, baseline reports → valid HTML, CLI AST/param + CLI-00x); XAML parse +
control/tooltip presence (W-09); `Test-ModuleManifest` + `Import-Module -Force`.

**GUI boundary (loop CANNOT do):** the interactive FlaUI run (W-09b) needs a live
STA window + mock at :8080 — **authored only**, human-run as the final gate,
matching SDK-19.

---

## 6. Item map (mirrors the backlog)

Foundation: AR-01 SP.ReportComponents (copy RC00–06), AR-02 component Pester.
Adapters: AR-03 entitlement adapter, AR-04 its Pester, AR-05 campaign adapter,
AR-06 its Pester, AR-07 mock-parity (the `/v3/entitlements` 405).
Reports: AR-08 CLEAN baseline subset, AR-09 roster+access-cert, AR-10 SoD
rule-set, AR-11 baseline Pester.
CLI: AR-12 `Invoke-SPAdaptiveReport.ps1`, AR-13 CLI Pester/convention.
GUI: AR-14 tab XAML, AR-15 `Initialize-SPAdaptiveTab`, AR-16 dashboard wiring,
AR-17 W-09 structure test, AR-18 register in full-GUI validation, AR-19 W-09b
authored-only.
Docs: AR-20 playbook + USER-GUIDE additions (regenerate HTML).
