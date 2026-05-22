# Round 5
**Started:** 2026-05-22 00:40:25

---

**F-06: Stale Certification Detection -- IMPLEMENTED**

**Feature:** `Get-SPDeltaCertStaleCertifications` -- finds active delta cert certifications that have been open longer than a configurable threshold with no reviewer action.

**Files modified:**
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- new function added (~150 lines)
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- exported `Get-SPDeltaCertStaleCertifications`
- `Tests/SP.DeltaCert.Tests.ps1` -- added DC-027, DC-028; updated BeforeAll to import `-Audit` module
- `docs/deltacert-backlog.md` -- F-06 status updated to DONE

**Tests added:**
- DC-027: Verifies only unsigned certs past threshold are returned (signed certs excluded)
- DC-028: Verifies empty array returned when all certs are within threshold

**Test results:** 42/43 pass (DC-023 JSONL test failure is pre-existing, unrelated)

**Issues encountered:**
- `Get-SPAuditCertifications` mock failed initially because the SP.Audit module wasn't imported in the test BeforeAll. Fixed by adding `-Audit` flag to `Import-SPTestModules`.

**Commit:** `6097f81` (feature) + `539905d` (backlog hash fixup)

**Completed:** 2026-05-22 00:44:53
**Status:** SUCCESS - more features remain
