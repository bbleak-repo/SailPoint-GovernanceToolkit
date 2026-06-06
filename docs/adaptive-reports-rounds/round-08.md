# Round 8
**Started:** 2026-06-05 17:30:00
**Item:** AR-08 — port CLEAN baseline reports (B03, B05, B06, B10)

**Read:** the GE BaselineReports B03/B05/B06/B10 (structure + B03 privileged-name
list). Confirmed each is self-contained: B0x-prefixed helpers (no cross-file
collision), no external deps, no RC-framework calls — safe to dot-source together.

**Did:** Copied B03/B05/B06/B10 **verbatim** into
`Modules/SP.AdaptiveReports/BaselineReports/` (B05/B06/B10 SHA-identical; B03 too —
its privileged heuristic already includes privileged/elevated/global-admin/security-
admin/root/sudo/super-user, which match ISC entitlement names, so no ISC tune was
needed). Added `SP.BaselineReports.psm1` (dot-source loader, exports the 4 public
`Export-*Report` fns; B0x helpers stay private). Original function names kept (unique,
internal — the CLI/GUI will map friendly keys). Re-authored both module manifests as
ASCII (New-ModuleManifest writes UTF-16, breaking repo grep/diff parity) and switched
SP.AdaptiveReports to **NestedModules-only** (RootModule + NestedModule each calling
Export-ModuleMember had suppressed the nested exports — only Build-SPRCDataset showed).
Additive; the only edit to a prior file is the AR-01/AR-03 manifest re-encoding.

**Files:** `Modules/SP.AdaptiveReports/BaselineReports/B0{3,5,6,10}-*.ps1` (new),
`Modules/SP.AdaptiveReports/SP.BaselineReports.psm1` (new),
`Modules/SP.AdaptiveReports/SP.AdaptiveReports.psd1` + `SP.ReportComponents/SP.ReportComponents.psd1`
(re-authored ASCII).

**Verification:**
  - Both manifests ASCII; `Test-ModuleManifest` OK (19 / 5 exports).
  - Import surfaces all 5 (Build-SPRCDataset + 4 reports).
  - Each report renders well-formed HTML from real adapter GroupResults:
    Inventory 4.0 KB, Privileged 6.4 KB (flags "Domain Admins"), Orphaned/Disabled
    3.8 KB, Exec Summary 8.9 KB.
  - Formal Pester: AR-11.

**Review:** PASS (self — verbatim port verified; manifest export wiring fixed and
proven; additive).
**Backlog update:** AR-08 → DONE.

**Completed:** 2026-06-05 17:44:00
**Status:** SUCCESS
