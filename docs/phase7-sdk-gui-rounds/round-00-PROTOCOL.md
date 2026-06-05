# Phase 7 SDK GUI Tab -- 3-Loop Autonomous Protocol

**Created:** 2026-06-04
**Backlog:** `docs/phase7-sdk-gui-backlog.md` (SDK-01..SDK-19)
**Plan:** `docs/planning/PHASE7_GUI_SDK_TAB.md` (Opus 4.8 reconciled)
**Branch:** `feature/phase7-sdk-gui-tab`
**Budget:** 20+ rounds, ending before the live interactive FlaUI run (SDK-19).

This file is the contract for the loop. Round files are written as
`round-NN.md` in this directory by the **inner** agent (one per round), matching
the existing `*-rounds/` convention used by prior phases.

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

### Outer loop -- Orchestration
**Runs:** once per round, repeats up to the budget.
**Does:**
1. Read `phase7-sdk-gui-backlog.md`. Pick the lowest-numbered item whose
   `Status: TODO` and whose `Depends On` are all `DONE`/`DEFERRED`.
2. Hand that one item to the middle loop.
3. On return, read the new `round-NN.md` + the code-review verdict.
4. If review PASS -> flip the item's `Status` to `DONE` (or `DEFERRED`/`AUTHORED`
   for SDK-18/SDK-19) in the backlog, commit, continue.
5. If review FAIL -> leave `TODO`, append the reviewer's findings to the round
   file as the next round's input, re-dispatch (max 2 retries, then escalate to
   the human via a `BLOCKED` status).
6. Stop when: all SDK-01..SDK-17 `DONE`; SDK-18 `DONE`/`DEFERRED`; SDK-19
   `AUTHORED`; OR budget exhausted; OR an item is `BLOCKED`.
**Never:** runs SDK-19's interactive test, edits gitignored config/secrets, or
pushes to `master` (works only on the feature branch).

### Middle loop -- Feature refinement
**Runs:** once per backlog item handed down.
**Does:**
1. Read the item + the relevant section of `PHASE7_GUI_SDK_TAB.md` + the actual
   current code it touches (don't trust the plan over the code).
2. Produce a tight work spec: exact files, function signatures, the SP.Sdk
   mapping to use, acceptance checks, and which WPF/testing convention applies
   (cite the plan's "WPF Framework Notes" / "GUI Testing Methods" numbers).
3. Resolve in-item ambiguity; **escalate genuine scope decisions to the human**
   (SDK-17 add-Both-vs-relax-test, SDK-18 ship-vs-defer) rather than guessing.
4. Hand the spec to the inner loop.
5. Receive inner's diff + round note; do a refinement pass (naming, convention
   adherence, dead code) before the formal code-review gate.

### Inner loop -- Implementation
**Runs:** once per work spec.
**Does:**
1. Implement exactly the spec. Match surrounding code style.
2. Run headless verification for the item's `Accept` criteria:
   - `Invoke-Pester` on the affected test file(s) (and the bridge tests).
   - XAML: parse via `XamlReader` (no live window).
   - Module: `Import-Module -Force` + `Test-ModuleManifest` where relevant.
3. Write `round-NN.md` (template below): what was done, files, verification
   output, and what it READ (plan sections, code) and WROTE.
4. Hand the diff to the code-review gate. Do NOT self-approve.

### Code-review gate (each step)
An **independent** Opus reviewer (fresh context) checks the inner diff against:
the spec, the plan conventions (WPF notes 1-6, testing notes), Safety integration
(SDK-03/12), no `$script:` in raw delegates, no UI-thread API calls, tooltips
present, tests actually assert behavior (not just "runs"). Emits `PASS` or `FAIL +
specific findings`. FAIL feeds back into the next round.

---

## Round file template (`round-NN.md`, written by inner)

```markdown
# Round N
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-NN -- <title>

**Read:** <plan sections / code files consulted>
**Did:** <one-paragraph summary of the change>
**Files:** <created/modified>
**Verification:**
  - Pester: <Passed/Failed/Total on affected files>
  - XAML parse: <ok/errors>
  - Manifest/import: <ok/errors>
**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-NN -> <DONE|DEFERRED|AUTHORED|BLOCKED>

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** <SUCCESS|RETRY|BLOCKED>
```

---

## Headless verification toolbox (what the loop CAN prove without a display)

- **Pester** unit/bridge tests (`Invoke-Pester .\Tests\`) -- full suite must stay
  green; new bridge tests added by SDK-06.
- **XAML well-formedness + control presence** -- `XamlReader::Load` + visual-tree
  walk (SDK-15 / W-08), runs with no window shown.
- **Module manifest + import** -- `Test-ModuleManifest`, `Import-Module -Force`.
- **AST/parse checks** -- `[Parser]::ParseFile` for scripts (as CLI tests do).

## The GUI-testing boundary (what the loop CANNOT do)

- **SDK-19 interactive FlaUI** (real visible window, mouse/keyboard, grid reads,
  screenshots) needs a live Windows STA GUI session + mock at localhost:8080.
  The loop AUTHORS it; a human runs it as the final acceptance gate. The (0,0)
  mouse-jump / DPI-fit interaction (testing note 6) only manifests with a real
  window, so it is intentionally outside the loop.

---

## Pre-flight (before round 1)

1. `git checkout -b feature/phase7-sdk-gui-tab` off current master.
2. Start the mock: `API-MockServer` at localhost:8080 (SailPoint-ISC profile).
3. Confirm baseline Pester is green (954 + the SP.CliScripts BeforeDiscovery fix
   from 2026-06-04; SDK-17 will green the last CLI-004 failure).
4. Outer loop begins at SDK-01.
