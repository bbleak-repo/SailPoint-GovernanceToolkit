# Adaptive Reports — Backlog (AR-01 to AR-20)

**Created:** 2026-06-05
**Purpose:** Port the Group-Enumerator adaptive report engine (RC components +
baseline reports) and a report-selection GUI tab into the SailPoint ISC
Governance Toolkit, **as additions, not replacements** — CLI + GUI, mock-validated.
**Plan:** `docs/planning/ADAPTIVE_REPORTS.md` (Opus 4.8 reconciled).
**Protocol:** `docs/adaptive-reports-rounds/round-00-PROTOCOL.md` (3-loop autonomous).
**Branch:** `feature/adaptive-reports`
**Backup floor:** `_backups/SailPoint-GovernanceToolkit-20260605-154412.zip`.
**Data anchor (ratified):** entitlement-primary, campaign-secondary.

---

## How to use this file

Loop order: `AR-01 → AR-20`, respecting `Depends On`. The outer orchestrator
picks the lowest-numbered `TODO` whose dependencies are all `DONE`/`DEFERRED`.
Each item is sized S/M/L. CRITICAL/HIGH first. Every item except **AR-19**
(interactive FlaUI) is headless-verifiable in the loop.

---

## Phase Summary

| # | Priority | Item | Size | Depends | Status |
|---|----------|------|------|---------|--------|
| AR-01 | CRITICAL | `SP.ReportComponents` module — copy RC00–RC06 verbatim + manifest | M | none | DONE |
| AR-02 | HIGH | Pester: each RC component renders a valid HTML fragment | M | AR-01 | DONE |
| AR-03 | CRITICAL | `Build-SPRCDataset` — entitlement anchor (entitlement→group, identity→member) | L | AR-01 | DONE |
| AR-04 | HIGH | Pester: entitlement adapter → correct `GroupResults` shape (mock + synthetic) | M | AR-03 | DONE |
| AR-05 | CRITICAL | `Build-SPRCDataset` — campaign anchor (cert→group, identity→member) | M | AR-03 | DONE |
| AR-06 | HIGH | Pester: campaign adapter shape | S | AR-05 | DONE |
| AR-07 | MEDIUM | Mock-parity: serve the endpoints both adapters read (the `/v3/entitlements` 405) | M | AR-03,05 | DONE |
| AR-08 | HIGH | Port CLEAN baseline subset (B06 inventory, B03 privileged, B05 orphaned, B10 exec) | L | AR-01,03 | DONE |
| AR-09 | MEDIUM | Port B01 roster + B02 access-cert attestation | M | AR-08 | DONE |
| AR-10 | MEDIUM | Port B04 SoD with an ISC entitlement-conflict rule-set | M | AR-08 | DONE |
| AR-11 | HIGH | Pester: each baseline report emits valid HTML from adapted mock data | M | AR-08 | DONE |
| AR-12 | HIGH | CLI `Invoke-SPAdaptiveReport.ps1` (additive; -Anchor/-Components/-BaselineReport/-Theme + date period) | L | AR-03,05,08 | DONE |
| AR-13 | HIGH | Pester/AST for the CLI + CLI-00x convention compliance | S | AR-12 | DONE |
| AR-14 | HIGH | GUI: add **Adaptive Reports** TabItem to `MainWindow.xaml` (namespaced, tooltips) | L | AR-01 | TODO |
| AR-15 | HIGH | `Initialize-SPAdaptiveTab` region (runspace + dispatcher + `Wait-SPReportFileReady`) | L | AR-14,12 | TODO |
| AR-16 | LOW | `Show-SPDashboard.ps1` — load new modules + call `Initialize-SPAdaptiveTab` | S | AR-15 | TODO |
| AR-17 | MEDIUM | Headless structure test W-09 (XAML parse + control/tooltip presence) | M | AR-14 | TODO |
| AR-18 | LOW | Register W-09 in `Invoke-FullGuiValidation.ps1` | S | AR-17 | TODO |
| AR-19 | DEFERRED | Interactive FlaUI `Test-W09b-AdaptiveTabInteractive.ps1` — AUTHOR only, human-run | L | AR-17 | TODO |
| AR-20 | MEDIUM | Docs: playbook (CLI+GUI) + USER-GUIDE additions; regenerate HTML | M | AR-12,15 | TODO |
| AR-21 | HIGH | Adaptive→Leadership distribution: bands + WhatIf-SMTP preview + upper rollup (reuse existing fns) | L | AR-12 | DONE |
| AR-22 | HIGH | Pester/AST for the leadership-distribution mode (WhatIf-by-default, no-send) | M | AR-21 | DONE |

Exit criteria: AR-01..AR-18 + AR-20 `DONE`; AR-19 `AUTHORED`. Full Pester suite
green (current baseline **1068**, plus new adapter/component/report/CLI tests);
W-09 headless green; no parse/XAML/manifest errors; existing reports, scripts, and
GUI tabs unchanged (additive only).

---

## AR-01: SP.ReportComponents module (copy RC00–RC06)
- **Status:** `DONE` · **Depends:** none · **Size:** M
**Goal:** New `Modules/SP.ReportComponents/` containing **verbatim** copies of
`RC00-Framework.ps1` … `RC06-GroupTable.ps1` from
`C:\temp\Coding\EntraIDScripts\Group-Enumerator\Modules\ReportComponents\`, plus a
`SP.ReportComponents.psd1` (fresh GUID; `NestedModules` = the 7 RC files;
`FunctionsToExport` = `New-ComposableReport`, `New-RCContext`, `Get-RCTheme`,
`Get-RCSharedCss`, `Register-RCComponent`, and each `New-RC*Component`). Do NOT
alter component logic; preserve any intra-module dot-sourcing. No SP.* dependency
(pure presentation, sibling of SP.Core).
**Files:** `Modules/SP.ReportComponents/*` (new).
**Accept:** `Import-Module SP.ReportComponents.psd1` clean; `Test-ModuleManifest`
passes; `New-ComposableReport` resolves; a smoke call with a 2-group synthetic
Context emits non-empty `<html>…</html>`.

## AR-02: RC component render tests
- **Status:** `DONE` · **Depends:** AR-01 · **Size:** M
**Goal:** `Tests/SP.ReportComponents.Tests.ps1` (RC-001..) — build a synthetic
`GroupResults`/Context and assert each of KPI/heatmap/tree/topN/table returns an
HTML `<section>` with the expected counts/labels; assert `New-ComposableReport`
composes a full UTF-8 no-BOM page and half-width packing works. RC04 diff: a
minimal `Changes[]` fixture (no live changelog).
**Accept:** all new tests pass; included in the suite.

## AR-03: Entitlement adapter — `Build-SPRCDataset -Anchor Entitlement`
- **Status:** `DONE` · **Depends:** AR-01 · **Size:** L
> **Design note:** implemented as a PURE transform over pre-built campaign-audit
> data (the `Get-SPIdentityAccessSpread` shape: `.Decisions` items carrying
> IdentityId/IdentityName/SourceName/AccessName/RiskFlags) rather than pulling the
> API itself — fully unit-testable and uses only mock-proven campaign/cert/ARI
> endpoints. The CLI/GUI build the audits via the existing pipeline and pass them
> in. A live `/v3/entitlements` *catalog* enrichment is deferred to AR-07. Both
> anchors live in `SP.AdaptiveReports/SP.RCDataset.psm1` (AR-05 = campaign anchor).
**Goal:** New `Modules/SP.AdaptiveReports/SP.RCDataset.psm1`. `Build-SPRCDataset`
maps ISC entitlements → RC `GroupResults`: group = entitlement/access-profile/role
(`GroupName`,`Domain`=source), members = identities holding it
(`DisplayName`,`SamAccountName`,`Email`,`Enabled`=lifecycle active). Reads via
SP.Api/SP.Audit (`@{Success;Data;Error}`); route through whichever of
`/v3/entitlements` (+members) or `/v3/search` access-aggregations the mock serves
(coordinate with AR-07). `IsNested` for roles/access-profiles bundling
entitlements; `Skipped`+`Errors` on read failure. Module manifest
`SP.AdaptiveReports.psd1` (depends caller-side on SP.Core/Api/Audit/ReportComponents).
**Files:** `Modules/SP.AdaptiveReports/SP.RCDataset.psm1`, `…psd1` (new).
**Accept:** against the mock (or a fixture when the endpoint is absent) returns a
well-formed `GroupResults[]`; envelope on failure; unit-mockable.

## AR-04: Entitlement adapter tests
- **Status:** `DONE` · **Depends:** AR-03 · **Size:** M
**Goal:** `Tests/SP.AdaptiveReports.Tests.ps1` (AR-001..) — mock the SP.Api/Audit
reads; assert the produced `GroupResults` shape (keys, member fields, counts,
Enabled tri-state, Skipped on error). Feed the result into `New-ComposableReport`
to prove end-to-end shape compatibility.
**Accept:** tests pass; shape verified against the RC contract.

## AR-05: Campaign adapter — `Build-SPRCDataset -Anchor Campaign`
- **Status:** `DONE` · **Depends:** AR-03 · **Size:** M
> Implemented in the same `SP.RCDataset.psm1` write as AR-03 (one module, two
> anchors): `-Anchor Campaign` groups records by campaign (single synthetic
> 'ISC Campaigns' domain), members = distinct identities under each campaign.
> Smoke-verified rendering through the RC engine. Test = AR-06.
**Goal:** Second anchor in `SP.RCDataset.psm1`: group = certification (or
campaign), members = identities/ARIs under it; `Enabled` = identity active. Reuse
SP.Audit campaign/cert/ARI reads (endpoints proven by W-03b/W-05). Same
`GroupResults` output contract so all RC components/baseline reports render the
campaign view unchanged.
**Accept:** campaign anchor returns valid `GroupResults` from mock campaign data;
RC components render it.

## AR-06: Campaign adapter tests
- **Status:** `DONE` · **Depends:** AR-05 · **Size:** S
**Goal:** Extend `SP.AdaptiveReports.Tests.ps1` for the campaign anchor shape.
**Accept:** tests pass.

## AR-07: Mock-parity audit (the /v3/entitlements 405)
- **Status:** `DONE` · **Depends:** AR-03,05 · **Size:** M
> **Resolution (route, don't fix-mock):** the adapters consume campaign-audit data
> built from `/v3/campaigns` → `/v3/certifications` → `.../access-review-items`
> (all mock-served; proven by W-03b/W-05) and **never call `/v3/entitlements`** —
> so the mock's 405 there does NOT block the adaptive reports. End-to-end proof:
> `Tests/Harness/Test-AR07-AdapterMockParity.ps1` builds real audits from the
> running mock (4 campaigns, 81 decision items) and confirms both anchors produce
> non-empty GroupResults that render: **Entitlement = 7 groups / 31 members,
> Campaign = 4 groups / 81 members**. Coverage list: campaigns, certifications,
> access-review-items (used + served). **Deferred (documented, not blocking):** a
> live entitlement *catalog* enrichment via `Get-SPEntitlementInventory`
> (`/v3/entitlements`) — add once the mock serves that endpoint.
**Goal:** Audit which endpoints the two adapters call against the
`API-MockServer` SailPoint-ISC profile. The mock returned **405 on
`/v3/entitlements`** during report validation — either (a) add/fix the mock
handler+seed (in the mock repo) so the entitlement anchor has data, or (b) route
the entitlement anchor through an endpoint the mock already serves
(`/v3/search` aggregations) and document the choice. Log any gap; prefer the
least-invasive path that gives both anchors real mock data.
**Files:** (mock repo) `Profiles/SailPoint-ISC/*` as needed; note-only otherwise.
**Accept:** both anchors return non-empty `GroupResults` against the running mock;
documented coverage list.

## AR-08: Port CLEAN baseline reports
- **Status:** `DONE` · **Depends:** AR-01,03 · **Size:** L
> Ported B03/B05/B06/B10 **verbatim** (byte-identical; B03's privileged-name
> heuristic already covers ISC terms — privileged/elevated/global-admin/root/etc.
> — so no tune needed). Kept original `Export-*Report` names (unique, internal;
> CLI/GUI map friendly keys). New `SP.BaselineReports.psm1` dot-sources them.
> Manifest switched to **NestedModules-only** (no RootModule — the toolkit
> convention; RootModule+NestedModule each calling Export-ModuleMember suppressed
> the nested exports). Re-authored both psd1 as ASCII (New-ModuleManifest emits
> UTF-16, which broke repo grep/diff parity).
**Goal:** In `Modules/SP.AdaptiveReports/SP.BaselineReports.psm1`, port the CLEAN
governance subset over the adapted dataset, keeping the proven bodies, renamed:
`Export-SPRCInventoryReport` (B06), `Export-SPRCPrivilegedReviewReport` (B03 — ISC
privileged-pattern list), `Export-SPRCOrphanedDisabledReport` (B05),
`Export-SPRCGovernanceExecSummaryReport` (B10). Signature
`-GroupResults -OutputPath [-Title] [-Theme]`.
**Accept:** each emits valid HTML from a synthetic `GroupResults`.

## AR-09: Port roster + access-cert attestation
- **Status:** `DONE` · **Depends:** AR-08 · **Size:** M
> B01 (`Export-MembershipSnapshotRosterReport`) + B02
> (`Export-AccessCertificationAttestationReport`) ported **verbatim** (standard
> `-GroupResults -OutputPath -Title -Theme` signature; attestation cover sheet is
> internal). Added to the loader + manifest. Both render valid HTML.
**Goal:** `Export-SPRCRosterReport` (B01), `Export-SPRCAccessCertAttestationReport`
(B02 — attestation cover sheet + reviewer-decision columns).
**Accept:** valid HTML; print-safe styling preserved.

## AR-10: Port SoD with ISC rule-set
- **Status:** `DONE` · **Depends:** AR-08 · **Size:** M
> B04 (`Export-SodToxicComembershipReport`) — engine ported verbatim; the one
> ADAPT: replaced the AD-lab rule-set (`GG_Scale_000x`) with a **SailPoint ISC SoD
> Starter** (entitlement-name role aliases + the classic toxic pairs +
> risk tiers), clearly marked EDIT-for-your-tenant (rule-set is data, not logic).
> Renders the full SoD register (17.9 KB).
**Goal:** `Export-SPRCSodReport` (B04). Replace the GE rule-set block with an
ISC-appropriate **entitlement-conflict rule-set** (declarative: role aliases +
toxic pairs + risk tiers); keep the detection engine.
**Accept:** valid HTML; rule-set is data (editable), not hardcoded logic.

## AR-11: Baseline report tests
- **Status:** `DONE` · **Depends:** AR-08 · **Size:** M
**Goal:** Extend the adaptive-reports tests — each `Export-SPRC*` writes a
well-formed HTML file (has `<html>…</html>`, expected section markers, no error
dump) from adapted mock data.
**Accept:** tests pass.

## AR-12: CLI `Invoke-SPAdaptiveReport.ps1`
- **Status:** `DONE` · **Depends:** AR-03,05,08 · **Size:** L
> **Date period:** select the campaign window with `-Status` + `-DaysBack` (and
> `-CreatedAfter`/`-CreatedBefore`, reusing `Get-SPAuditCampaigns`). The
> leadership-distribution mode (bands, WhatIf-SMTP preview, upper-leadership rollup)
> is split into **AR-21** (so the base CLI stays focused and the distribution mode
> is reviewed separately). Read-only -> no SupportsShouldProcess (CLI-005).
**Goal:** Additive script. `[CmdletBinding()]` (read-only — **no**
SupportsShouldProcess), standard `-ConfigPath`/`-Token`/`-TokenExpiryMinutes`/
`-Help`, `[ValidateSet('Console','JSON','HTML','Both')]$OutputMode`, plus
`-Anchor Entitlement|Campaign`, `-Components <keys>`, `-BaselineReport <names>`,
`-Theme light|dark`, `-OutputPath`. Loads SP.* + the new modules, pulls data via
the adapter, renders via `New-ComposableReport` / `Export-SPRC*`. Exit codes
0/1/2/3/4. Comment-based help with examples.
**Accept:** runs against the mock producing valid HTML for both anchors; `-Help`
works; exits per contract.

## AR-13: CLI tests + convention compliance
- **Status:** `DONE` · **Depends:** AR-12 · **Size:** S
**Goal:** Add the script to the read-only set in `Tests/SP.CliScripts.Tests.ps1`
(CLI-005: no SupportsShouldProcess) and assert OutputMode ValidateSet + `-Help` +
AST-clean (CLI-001..004 stay green).
**Accept:** CLI-00x green including the new script.

## AR-14: GUI Adaptive Reports tab (XAML)
- **Status:** `TODO` · **Depends:** AR-01 · **Size:** L
**Goal:** Insert an **Adaptive Reports** TabItem in `Gui/MainWindow.xaml` (after
Governance, before Settings): anchor selector, component checkboxes (kpi/heatmap/
tree/topN/table), baseline-report checkboxes, theme selector, **Generate** +
**Open Folder/Report** + progress + status label. Namespaced x:Names
(`BtnAr*`/`ChkAr*`/`AdaptiveReports*`); every `Btn*`/`Chk*` a non-empty ToolTip;
reuse existing SP styles. Re-verify the window still fits the work area.
**Accept:** XAML parses via `XamlReader`; tab present; W-09 finds all controls.

## AR-15: Initialize-SPAdaptiveTab region
- **Status:** `TODO` · **Depends:** AR-14,12 · **Size:** L
**Goal:** `Initialize-SPAdaptiveTab` in `SP.MainWindow.psm1`: capture
`$module = $script:ThisModule`; `Find-Control` lookups; wire every handler with
`& $module { param(...) } $args` + `.GetNewClosure()`. Generate runs on a
background STA runspace (import SP.Core/Api/Audit/ReportComponents/AdaptiveReports
there); marshal status via `Invoke-OnDispatcher`. On success, open the HTML with
**`Wait-SPReportFileReady`** then `Start-Process`. No API/IO on the UI thread; no
`$script:` in raw delegates.
**Accept:** function parses; against the mock the tab generates a report and opens
it; headless logic paths covered where possible (full proof deferred to AR-19).

## AR-16: Show-SPDashboard wiring
- **Status:** `TODO` · **Depends:** AR-15 · **Size:** S
**Goal:** Add `SP.ReportComponents` + `SP.AdaptiveReports` to the module-load
chain and call `Initialize-SPAdaptiveTab` in the tab-init sequence (before
Settings).
**Accept:** launcher parses; chain loads the new modules; manifest OK.

## AR-17: Headless structure test (W-09)
- **Status:** `TODO` · **Depends:** AR-14 · **Size:** M
**Goal:** `Tests/Harness/Test-W09-AdaptiveTabStructure.ps1` (WG-09-01..): load
MainWindow.xaml without showing, assert the Adaptive Reports tab + its controls +
that every `Btn*`/`Chk*` has a ToolTip. Pattern: `Test-W08-SdkTabStructure.ps1`.
Runs on any OS.
**Accept:** green headless.

## AR-18: Register W-09 in full-GUI validation
- **Status:** `TODO` · **Depends:** AR-17 · **Size:** S
**Goal:** Add W-09 (headless) + a W-09b deferred entry to
`Tests/Harness/Invoke-FullGuiValidation.ps1` (mirror the W-08/W-08b wiring,
including the JSONL/ConfigPath param mapping so it runs correctly when authored).
**Accept:** full validation lists W-09; W-09b shows deferred until run live.

## AR-19: Interactive FlaUI W-09b (AUTHOR only)
- **Status:** `TODO` (→ `AUTHORED`) · **Depends:** AR-17 · **Size:** L
**Goal:** Author `Tests/Harness/Test-W09b-AdaptiveTabInteractive.ps1` (mirror
W-08b): navigate the tab, pick components/baseline + anchor, Generate against the
mock, assert a report file appears + opens, screenshots. STA guard, mock `/health`
probe → BLOCK live steps if down. **DO NOT RUN in the loop** — human runs it as
the final gate.
**Accept:** file parses; x:Names cross-checked against MainWindow.xaml; execution
deferred.

## AR-20: Docs
- **Status:** `TODO` · **Depends:** AR-12,15 · **Size:** M
**Goal:** Add an Adaptive Reports section to `docs/playbook/cli-playbook.md`
(the new script) and `docs/playbook/gui-playbook.md` (the new tab), plus a
Foundations mention; regenerate `docs/USER-GUIDE.html` via
`docs/playbook/build-userguide.py`. Note both anchors and the component/baseline
catalog.
**Accept:** HTML regenerates clean; new sections present; no stale claims.

## AR-21: Adaptive -> Leadership distribution (bands + WhatIf SMTP + upper rollup)
- **Status:** `DONE` · **Depends:** AR-12 · **Size:** L
> Implemented as a `-DistributeToLeadership` mode on `Invoke-SPAdaptiveReport.ps1`
> (additive switch). Reuses `Build-SPOrgTree` -> `Resolve-SPIdentityBand` ->
> `Group-SPAuditByLeadership` -> `Export-SPLeadershipExecutiveHtml` (upper rollup)
> + `Export-SPLeadershipBandHtml -TargetBands` (per-band) -> per-leader delivery via
> `Send-SPReport`. **WhatIf by default:** generates reports and prints "WOULD send ->
> <leader> <email> [band]" with **zero emails sent**; `-PreviewOnly` shows the plan +
> SMTP status and exits; `-SendReports` calls Send-SPReport (which still only emails
> when `Audit.Smtp.Enabled=$true`). Verified live (mock): 29 identities -> org tree
> (11 mgr/3 dir/1 top), bands B/C/D/E, exec rollup + 4 per-band reports, 3 simulated
> sends to directors, 0 emails. Added a compact-name match fallback so per-director
> files resolve to recipients. Existing `Invoke-SPReportDistribution.ps1` untouched.
**Goal:** Add a `-DistributeToLeadership` mode to `Invoke-SPAdaptiveReport.ps1`
(additive switch; off by default) that **reuses the existing** tiered leadership
machinery — no edits to existing files, no rebuild:
- Build the org tree + bands from the reviewed identities for the selected date
  window: `Build-SPOrgTree` -> (optional `Import-SPOrgChartSupplement` +
  `Merge-SPOrgTreeWithSupplement`) -> `Resolve-SPIdentityBand` ->
  `Group-SPAuditByLeadership`.
- **Upper-leadership main report** with director/VP chains broken down:
  `Export-SPLeadershipExecutiveHtml` (+ `Export-SPLeadershipDirectorHtml`).
- **Per-band** reports filtered by `-TargetBands`: `Export-SPLeadershipBandHtml`.
- Bundle the generated **adaptive** reports (estate-wide + the exec summary) into
  the distribution.
- **WhatIf SMTP by default:** `-PreviewOnly` -> `Show-SPReportDistributionPreview`
  (who-gets-what, no send). Otherwise simulate delivery via `Send-SPReport` with
  `Audit.Smtp.Enabled=$false` -> logs "would send to <leader>" (Action='Logged')
  WITHOUT sending. Only `-SendReports` + `Audit.Smtp.Enabled=$true` actually sends.
- Params mirror the existing distribution CLI: `-TargetBands`, `-LeadershipDepth`,
  `-OrgSupplementPath`, `-PreviewOnly`, `-SendReports`, `-DetailLevel`.
**Files:** `Scripts/Invoke-SPAdaptiveReport.ps1` (extend, additive).
**Accept:** against the mock, `-DistributeToLeadership -PreviewOnly` shows the plan;
the default (no -SendReports) simulates per-leader delivery (Action='Logged', zero
emails sent); upper-leadership exec rollup + per-band reports generated; existing
`Invoke-SPReportDistribution.ps1` untouched.

## AR-22: Leadership-distribution mode tests
- **Status:** `DONE` · **Depends:** AR-21 · **Size:** M
**Goal:** Pester/AST: the mode is WhatIf-by-default (mock `Send-SPReport`, assert
Action='Logged'/no send unless -SendReports + Smtp.Enabled); `-PreviewOnly` calls
the preview and exits without sending; CLI-005 (read-only, no SupportsShouldProcess)
holds for the script.
**Accept:** tests green; no real email path exercised.
