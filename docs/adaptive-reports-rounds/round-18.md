# Round 18
**Started:** 2026-06-05 00:00:00
**Item:** AR-18 -- Register W-09 in full-GUI validation

**Read:** `docs/adaptive-reports-backlog.md` (AR-18 item + Phase Summary row),
`docs/adaptive-reports-rounds/round-00-PROTOCOL.md` (loop rules + round template),
`Tests/Harness/Invoke-FullGuiValidation.ps1` (the only file touched -- the existing
W-08 / W-08b stanzas it mirrors), `Tests/Harness/Test-W09-AdaptiveTabStructure.ps1`
(the harness being registered; confirmed it emits its JSONL to STDOUT with the same
contract as W-08).

**Did:** Registered the W-09 (headless Adaptive Reports tab structure) and W-09b
(deferred interactive FlaUI) phases in `Invoke-FullGuiValidation.ps1` by mirroring
the existing W-08 / W-08b wiring exactly. Five additive edits, no existing phase /
helper / mock-lifecycle / JSONL-parser code removed or rewired:
(1) the `.DESCRIPTION` Phases block gets two new doc lines (W-09, W-09b);
(2) the `.PARAMETER HarnessFilter` enumeration appends `W-09, W-09b` (doc-only --
the filter validation reads `$allPhases.Keys` dynamically);
(3) the `$allPhases` ordered registry gains a `'W-09'` entry (copy of W-08:
`NeedsMock=$false`, `NeedsSta=$true`, `NeedsConfigPath=$true`) and a `'W-09b'` entry
(copy of W-08b: `NeedsMock=$true`, `NeedsSta=$true`, `NeedsConfigPath=$true`);
(4) the `switch ($Name)` param-mapping gains a `'W-09'` arm passing ONLY
`-ConfigPath` (matching W-08, which would otherwise reject unknown params under
`ErrorActionPreference=Stop`) and a `'W-09b'` arm passing the
`-ConfigPath/-JsonlPath/-ScreenshotDir/-MockBaseUrl` shape (matching W-08b);
(5) **load-bearing:** the stdout->JSONL bridge guard was widened from
`if ($Name -eq 'W-08')` to `if ($Name -eq 'W-08' -or $Name -eq 'W-09')` (comment
updated to mention WG-09-01..NN) because W-09 has the same stdout-JSONL behavior --
without this it would report 0 pass / 0 fail (correct exit code, lost counts).
W-09b points at a not-yet-existing script (`Test-W09b-AdaptiveTabInteractive.ps1`,
authored later by AR-19) and relies on the existing missing-script auto-SKIP path
(lines ~373-376); it needs no bridge (it writes to `-JsonlPath` like W-08b).

**Files:** `Tests/Harness/Invoke-FullGuiValidation.ps1` (modified -- additive only:
2 doc lines, 1 param-doc line, 2 registry entries, 2 switch arms, 1 widened bridge
guard; no existing arm/entry/helper removed). Docs: `docs/adaptive-reports-backlog.md`
(AR-18 -> DONE in both the Phase Summary row and the item header),
`docs/adaptive-reports-rounds/round-18.md` (this file).

**Verification:**
  - AST parse: `[Parser]::ParseFile` on `Invoke-FullGuiValidation.ps1` -> `ParseErrors=0`.
  - Grep `W-09` -> 10 matching lines (doc x2 + param-doc x1, registry x2, switch
    comment+arm x2 each, bridge comment+guard); `Name -eq 'W-09'` -> exactly 1 hit
    (the widened bridge guard).
  - W-09 harness standalone (allowed; never shows a window):
    `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File Test-W09-AdaptiveTabStructure.ps1`
    -> EXIT=0 with WG-09-01..07 all PASS and a trailing
    `{"summary":true,"pass":7,"fail":0,"blocked":0,"total":7}` line.
  - Orchestrator NOT run end-to-end (FORBIDDEN this loop -- would start the mock and
    open the real WPF dashboard). W-09b correctly SKIPs via the missing-script path
    until AR-19 authors `Test-W09b-AdaptiveTabInteractive.ps1`.
  - Pester: N/A -- this item touches only the orchestrator harness wiring, no module
    code or `*.Tests.ps1`; the affected harness is exercised by the standalone run above.
  - XAML parse / Manifest / import: N/A (no XAML or module changes).

**Review:** PENDING (independent code-review gate runs next).
**Backlog update:** AR-18 -> DONE

**Completed:** 2026-06-05 00:00:00
**Status:** SUCCESS
