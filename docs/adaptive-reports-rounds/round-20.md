# Round 20
**Started:** 2026-06-05 19:25:00
**Item:** AR-20 -- Docs: GUI playbook + regenerate

**Read:** `round-00-PROTOCOL.md` (loop rules + round template);
`docs/adaptive-reports-backlog.md` AR-20 detail (lines 312-319) + Phase Summary row;
`docs/playbook/gui-playbook.md` (full — mirrored the "## 4. Delta Cert tab" multi-table
and "## 6. SDK Features tab" sub-grouped + callout templates); `Gui/MainWindow.xaml`
1718-1866 (authoritative Adaptive control names + tooltips); `docs/playbook/cli-playbook.md`
435-474 (authoritative anchor/component/baseline key names + the stale "forthcoming" GUI
line); `docs/playbook/build-userguide.py` (parse_gui keys sections off `##` H2, derives ids
via make_sid from title text).

**Did:** Added the GUI half of AR-20 (CLI + Foundations docs were already done). Inserted a
new "## 7. Adaptive Reports tab" section in `gui-playbook.md` between SDK Features and
Settings, mirroring the existing tab sections: Purpose / When-to-use, then four control
tables (Report Options: Anchor/Theme/Days Back; Components with component keys
kpi-cards/heatmap/tree/top-n/group-table; Baseline Reports with keys
inventory/privileged/orphaned/exec-summary/roster/access-cert/sod; Actions:
Generate/Open Folder/Open Report + progress bar/status label), a Workflow line (default
output `Audit\adaptive`), a `>` callout that leadership distribution is CLI-only via
`Invoke-SPAdaptiveReport.ps1 -DistributeToLeadership`, and a Related-CLI line. Updated the
intro ("7 tabs"→"8 tabs", tab list), the Contents list (added 7. Adaptive Reports,
Settings 7→8), and renumbered the existing Settings header "## 7."→"## 8." (additive
renumber; build script regenerates ids/sidebar/JS). Removed the stale
"*(Adaptive Reports tab — forthcoming.)*" phrase in `cli-playbook.md` line 474. Regenerated
`docs/USER-GUIDE.html` via `build-userguide.py` (generated output, not hand-edited).

**Files:**
- `docs/playbook/gui-playbook.md` (EDIT — additive new H2 section + intro/contents/Settings
  renumber; no existing section rewritten)
- `docs/playbook/cli-playbook.md` (EDIT — one phrase, removed stale "forthcoming" claim)
- `docs/USER-GUIDE.html` (REGENERATED via build-userguide.py — not hand-edited)
- `docs/adaptive-reports-backlog.md` (EDIT — AR-20 TODO→DONE in table row + detail header
  + completion `>` note)
- `docs/adaptive-reports-rounds/round-20.md` (NEW — this file)

**Verification:** (docs-only; no Pester/XAML/manifest needed per spec)
  - `python docs/playbook/build-userguide.py` → clean exit; "Sections: 28 (Foundations: 11,
    CLI: 8, GUI: 9)" — GUI count incremented 8→9 vs. pre-edit; `gui-adaptive-reports-tab`
    appears in the printed Section IDs list.
  - `rg "Adaptive Reports tab" docs/USER-GUIDE.html` → 3 matches.
  - `rg "gui-adaptive-reports-tab" docs/USER-GUIDE.html` → 4 matches (section div, nav,
    mobile nav, JS ids array).
  - `rg "BtnArGenerate|AdaptiveReportsAnchorCombo|ChkArCompKpiCards" docs/USER-GUIDE.html`
    → 3 matches.
  - `rg "DistributeToLeadership" docs/USER-GUIDE.html` → 1 match (CLI-only callout).
  - `rg "8. Settings tab" docs/USER-GUIDE.html` → present (header + nav); Settings not
    destroyed, renumbered to 8.
  - `rg "forthcoming" docs/playbook/cli-playbook.md` → NO match (stale claim removed).
  - `rg "AR-20.*DONE" docs/adaptive-reports-backlog.md` → table row + exit criteria.

**Review:** PASS (additive only — diffed: no GUI tab section removed/rewired; Settings
preserved, only renumbered; one CLI phrase changed; USER-GUIDE.html is regenerated output).

**Backlog update:** AR-20 -> DONE

**Completed:** 2026-06-05 19:29:27
**Status:** SUCCESS
