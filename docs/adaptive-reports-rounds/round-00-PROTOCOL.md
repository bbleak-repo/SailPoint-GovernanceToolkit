# Adaptive Reports — 3-Loop Autonomous Protocol

**Created:** 2026-06-05
**Backlog:** `docs/adaptive-reports-backlog.md` (AR-01..AR-20)
**Plan:** `docs/planning/ADAPTIVE_REPORTS.md` (Opus 4.8 reconciled)
**Branch:** `feature/adaptive-reports`
**Backup floor:** `_backups/SailPoint-GovernanceToolkit-20260605-154412.zip`
**Budget:** ~22 rounds, ending before the live interactive FlaUI run (AR-19).

This file is the contract for the loop. Each round is written as `round-NN.md` in
this directory by the **inner** agent, matching the existing `*-rounds/`
convention used by prior phases (phase7-sdk-gui, deltacert, campaign-search, …).

**Prime directive — additive, not destructive.** Every change ADDS a new module,
script, tab, or test. No existing report, script, module export, or GUI tab is
removed or rewired. If an item appears to require editing existing behavior,
that is a scope flag → escalate to the human; do not silently change it.

---

## The three loops

```
OUTER (orchestrator, Opus)
  | selects next eligible backlog item, owns branch + round ledger, enforces budget
  v
MIDDLE (feature refinement, Opus)
  | turns one backlog item into a concrete, reviewed work spec; defers scope calls up
  v
INNER (implementation, Opus)
  | writes code + tests, runs headless verification, writes round-NN.md
  ^
  | CODE REVIEW gate at each step (independent Opus reviewer) -- must PASS to advance
```

### Outer loop — Orchestration
**Runs:** once per round, up to budget.
1. Read `adaptive-reports-backlog.md`. Pick the lowest-numbered `Status: TODO`
   whose `Depends On` are all `DONE`/`DEFERRED`.
2. Hand that one item to the middle loop.
3. On return, read the new `round-NN.md` + the code-review verdict.
4. PASS → flip the item `DONE` (AR-19 → `AUTHORED`) in the backlog, commit on
   the feature branch, continue.
5. FAIL → leave `TODO`, append reviewer findings to the round file as the next
   round's input, re-dispatch (max 2 retries → `BLOCKED`, escalate to human).
6. Stop when AR-01..AR-18 + AR-20 `DONE`, AR-19 `AUTHORED`, OR budget exhausted,
   OR an item is `BLOCKED`.
**Never:** runs AR-19's interactive test; edits gitignored config/secrets; pushes
to `master`; **modifies the Group-Enumerator source repo** (it is read-only
reference); deletes/rewrites existing toolkit reports, scripts, or GUI tabs.

### Middle loop — Feature refinement
**Runs:** once per item.
1. Read the item + the relevant `ADAPTIVE_REPORTS.md` section + **the actual
   current code it touches** (don't trust the plan over the code), and — for port
   items — the **specific GE source file** named (read-only) so the verbatim copy
   / adaptation is faithful.
2. Produce a tight work spec: exact files, function signatures, the GE source to
   copy/adapt, the SP convention that applies (WPF closure/dispatcher, CLI-005
   read-only, return envelope, UTF-8 no-BOM HTML), and acceptance checks.
3. Resolve in-item ambiguity; **escalate genuine scope decisions to the human**
   (e.g., AR-07 fix-mock-vs-reroute; any item that would touch existing behavior).
4. Hand the spec to the inner loop; on return do a refinement pass (naming,
   convention adherence, dead code, namespacing) before the code-review gate.

### Inner loop — Implementation
**Runs:** once per spec.
1. Implement exactly the spec; match surrounding SP code style. Port items: copy
   the GE body **verbatim** except namespacing/renames the spec lists.
2. Run headless verification for the item's `Accept`:
   - `Invoke-Pester` on the affected/new test file(s) — and confirm the **full
     suite stays green** (baseline 1068 + new tests).
   - XAML: parse via `XamlReader` (no live window).
   - Module: `Import-Module -Force` + `Test-ModuleManifest`.
   - Scripts: `[Parser]::ParseFile` AST clean; CLI-00x where relevant.
3. Write `round-NN.md` (template below): what was done, files, verification
   output, what it READ (plan sections, SP code, GE source) and WROTE.
4. Hand the diff to the code-review gate. Do NOT self-approve.

### Code-review gate (each step)
An **independent** Opus reviewer (fresh context) checks the inner diff against:
the spec, the plan conventions, **additive-only** (nothing existing removed/
rewired — diff the export lists + tab list), WPF rules (local `$module` closure,
no `$script:` in raw delegates, no UI-thread API calls, `Application.Current.
Dispatcher`, tooltips present), CLI-005 (read-only → no SupportsShouldProcess),
UTF-8 no-BOM + RC escaper for HTML, tests actually assert behavior (not just
"runs"). Emits `PASS` or `FAIL + specific findings`. FAIL feeds the next round.

---

## Round file template (`round-NN.md`, written by inner)

```markdown
# Round N
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** AR-NN -- <title>

**Read:** <plan sections / SP code / GE source files consulted>
**Did:** <one-paragraph summary>
**Files:** <created/modified>  (additive? note any existing-file edits + why)
**Verification:**
  - Pester: <Passed/Failed/Total on affected files + full-suite delta>
  - XAML parse: <ok/errors>   Manifest/import: <ok/errors>   AST: <ok/errors>
**Review:** <PASS | FAIL: findings>
**Backlog update:** AR-NN -> <DONE|AUTHORED|BLOCKED>

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** <SUCCESS|RETRY|BLOCKED>
```

---

## Headless verification toolbox (what the loop CAN prove)

- **Pester** (`Invoke-Pester .\Tests\`) — full suite stays green; new tests:
  `SP.ReportComponents.Tests.ps1`, `SP.AdaptiveReports.Tests.ps1`, CLI additions.
- **Adapter→engine shape** — feed adapter output into `New-ComposableReport`,
  assert valid `<html>…</html>` + expected sections (no live window).
- **XAML well-formedness + control/tooltip presence** — `XamlReader::Load` +
  tree walk (AR-17 / W-09).
- **Module manifest + import** — `Test-ModuleManifest`, `Import-Module -Force`.
- **AST/parse + CLI-00x** — `[Parser]::ParseFile`; `SP.CliScripts.Tests.ps1`.

## The GUI-testing boundary (what the loop CANNOT do)

- **AR-19 interactive FlaUI** (real visible window, generate + open a report,
  screenshots) needs a live Windows STA session + mock at localhost:8080. The
  loop AUTHORS it; a human runs it as the final acceptance gate (mirrors SDK-19;
  see `[[feedback_flaui_mouse_doubleclick]]`).

---

## Pre-flight (before round 1)

1. Commit or stash the current working tree, then
   `git checkout -b feature/adaptive-reports` off the intended base.
2. Confirm the backup ZIP exists (`_backups/…-20260605-154412.zip`).
3. Start the mock: `API-MockServer` at localhost:8080 (SailPoint-ISC profile),
   **non-elevated** so the loop can manage it; reload with `-Fresh` if the SDK /
   entitlement seed is stale.
4. Confirm baseline Pester is green (**1068**) and `Invoke-FullGuiValidation`
   passes (W-08b green) on the current tree.
5. Outer loop begins at AR-01.
```
