# Round 8
**Started:** 2026-05-22 08:53:41

---

**G-08: UI Consistency Pass -- DONE**

**Feature:** G-08 UI Consistency Pass
**Commit:** `42c41c4`

**Files modified:**
- `Gui/MainWindow.xaml` -- 3 fixes
- `Modules/SP.Gui/SP.MainWindow.psm1` -- 4 fixes

**Changes made:**
1. **Button styles:** `BtnApplyToken` replaced inline style with `ToolkitButton`; `BtnClearToken` replaced inline style with `SecondaryButton`
2. **Button naming:** `BtnClearToken` renamed from "Clear" to "Clear Token" (verb+noun consistency)
3. **Progress bars:** Campaign tab progress bar restructured to 3-column layout with `SuiteProgressPercent` TextBlock, matching Audit/DeltaCert pattern. `Invoke-GuiTestRun` updated with `ProgressPercent` parameter, runspace variable, and completion handler.
4. **Tab content margins:** All 5 tabs already use `Margin="12,8"` -- no changes needed
5. **Dialog colors:** All 3 dialog XAMLs already use identical color constants -- no changes needed
6. **Orphaned controls:** `BtnExportAll` wired in `Initialize-EvidenceTab` (opens Evidence folder in Explorer)

**Validation:** XML well-formedness (4 XAML files) and PS AST syntax check both passed.

**Completed:** 2026-05-22 08:59:31
**Status:** SUCCESS - more features remain
