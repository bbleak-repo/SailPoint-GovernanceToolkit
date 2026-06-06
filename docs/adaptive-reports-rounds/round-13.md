# Round 13
**Started:** 2026-06-05 18:15:00
**Item:** AR-13 — CLI tests + CLI-00x convention compliance

**Read:** `Tests/SP.CliScripts.Tests.ps1` (the AllScripts / MutatingScripts /
ReadOnlyScripts matrices — duplicated across a top-level `BeforeDiscovery` and a
`BeforeAll` so they exist at both Pester phases).

**Did:** Registered `Invoke-SPAdaptiveReport.ps1` in **both** copies of `AllScripts`
and `ReadOnlyScripts` (replace_all). This subjects the new CLI to CLI-001 (AST
parse), CLI-002/003 (binding), and CLI-005 (read-only -> must NOT declare
SupportsShouldProcess), and its `OutputMode` ValidateSet (Console/JSON/HTML/Both)
satisfies CLI-004. Additive — only the test matrices changed.

**Files:** `Tests/SP.CliScripts.Tests.ps1` (updated).

**Verification:** `SP.CliScripts.Tests.ps1` **75 passed / 0 failed** (was 71; +4 for
the new script). The adaptive CLI is AST-clean, has no SupportsShouldProcess, and a
compliant OutputMode set.

**Review:** PASS (self — convention coverage added; the CLI satisfies all CLI-00x).
**Backlog update:** AR-13 → DONE.

**Completed:** 2026-06-05 18:20:00
**Status:** SUCCESS
