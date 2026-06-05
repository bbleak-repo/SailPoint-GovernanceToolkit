# Round 16
**Started:** <inner-loop start timestamp>
**Item:** SDK-16 -- Invoke-FullGuiValidation.ps1: register W-08 + W-08b stub

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-16 row + section; SDK-15/SDK-19 context)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round-file template + headless verification toolbox / GUI-testing boundary)
- `Tests/Harness/Invoke-FullGuiValidation.ps1` (phase registry, HarnessFilter validation, Invoke-Harness param-mapping switch, stdout capture, JSONL parser, summary/exit logic)
- `Tests/Harness/Test-W08-SdkTabStructure.ps1` (the W-08 headless harness authored by SDK-15 -- actual param block + JSONL-to-stdout emission)

**Did:**
Registered the two SDK Features tab phases in the GUI validation orchestrator and nothing else. Appended `W-08` and `W-08b` to the `$allPhases` ordered hashtable (after `W-07`, preserving insertion order so they run last). `W-08` = `Test-W08-SdkTabStructure.ps1`, `NeedsMock=$false / NeedsSta=$true / NeedsConfigPath=$true` (it self-guards for STA and exits 2 otherwise -- WPF note 1 -- and only parses `MainWindow.xaml` via `XamlReader` -- WPF note 5 -- so it never touches the mock). `W-08b` = `Test-W08b-SdkTabInteractive.ps1` mirrors the interactive harnesses (`NeedsMock/NeedsSta/NeedsConfigPath` all `$true`) so it is pre-wired for when SDK-19 authors the script; until then its absence drives the orchestrator's existing missing-script SKIP path (`Invoke-Harness` returns `Result='SKIP' / Note='Script missing'`). Added a single `'W-08'` case to the param-mapping switch passing ONLY `-ConfigPath` (the harness has no other params), and a post-capture bridge that copies the child's captured stdout into the phase's `results.jsonl` for `W-08` so the shared JSONL parser tallies the real `WG-08-01..10` + `{summary}` counts. Updated the `.DESCRIPTION` Phases list and the `.PARAMETER HarnessFilter` short-name list. No new files; W-08b's harness intentionally NOT authored (that is SDK-19, the deferred post-loop interactive run).

**Divergence from plan (trust code over plan):**
`Test-W08-SdkTabStructure.ps1` accepts ONLY `-ConfigPath` and emits its JSONL to STDOUT (one line per `WG-08-NN` plus a final `{summary}` line), unlike W-02b/W-03b/W-04/W-05/W-06/W-07 which all take `-JsonlPath` and write the JSONL to that file. The orchestrator parses pass/fail from the `-JsonlPath` FILE and captures the child's stdout separately into `stdout.log`. A naive "wire it like the others" reading of the plan would pass `-JsonlPath`/`-ScreenshotDir`, which the harness (running `ErrorActionPreference=Stop`) would reject, and would also report 0 pass / 0 fail. Per the refinement spec's Decision A, W-08's switch case passes only `-ConfigPath`, and a `if ($Name -eq 'W-08') { [System.IO.File]::WriteAllText($jsonl, $outTask.Result) }` bridge after the stdout WriteAllText feeds the captured stdout into `$jsonl` so the existing parser surfaces the real 10/0 counts. W-08b needs no switch case (it auto-SKIPs before reaching the param mapping).

**Files:**
- Modified: `Tests/Harness/Invoke-FullGuiValidation.ps1` (header `.DESCRIPTION` Phases + `.PARAMETER HarnessFilter`; `$allPhases` registry +W-08/+W-08b; Invoke-Harness switch +'W-08' case; stdout->jsonl bridge for W-08)
- Modified: `docs/phase7-sdk-gui-backlog.md` (SDK-16 -> DONE, table row + section)
- Created: `docs/phase7-sdk-gui-rounds/round-16.md` (this file)

**Verification:** (headless; WinPS 5.1 Desktop via powershell.exe)
  - Parse (AC2): `[Parser]::ParseFile(Invoke-FullGuiValidation.ps1)` -> ParseErrors=0.
  - W-08 standalone (`powershell -STA -File Test-W08-SdkTabStructure.ps1`): EXIT=0, 11 stdout lines (WG-08-01..10 + `{summary}`), summary `{pass:10, fail:0, blocked:0, total:10}`.
  - HarnessFilter registration (AC3): orchestrator's "Valid:" list includes `W-08, W-08b`; `-HarnessFilter @('W-08','W-08b')` resolves to `Phases to run: W-08, W-08b` with no "Unknown harness name" throw.
  - End-to-end against live mock at localhost:8080 (AC4/AC5): `W-08 = PASS (10 pass, 0 fail, exit 0)`, `W-08b = SKIP (script not found)`; summary table row `W-08 | PASS | 10 | 0` proves the stdout->jsonl bridge; phase totals `1 PASS / 0 FAIL / 1 SKIP`; orchestrator exit code 0 (SKIP not counted as FAIL). Operator settings.local.json backed up and restored cleanly.
  - Regression (AC8): `-HarnessFilter @('smoke')` still resolves to `Phases to run: smoke` (no Unknown-harness throw); existing W-02b..W-07 cases unchanged.
  - Collateral (AC6/AC7): `git status --porcelain` before doc edits showed ONLY `Tests/Harness/Invoke-FullGuiValidation.ps1` modified; `git diff -- Tests/Harness/Test-W08-SdkTabStructure.ps1` empty.
  - Pester: n/a (orchestrator harness has no `*.Tests.ps1`; verified by parse + live invocation instead).
  - XAML parse: n/a (no XAML touched; W-08 harness exercises XamlReader and was run, EXIT=0).
  - Manifest/import: n/a (no module/manifest touched).

**Review:** <pending code-review gate>
**Backlog update:** SDK-16 -> DONE

**Completed:** <inner-loop completion timestamp>
**Status:** SUCCESS
