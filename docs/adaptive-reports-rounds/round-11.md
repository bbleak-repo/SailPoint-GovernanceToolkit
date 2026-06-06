# Round 11
**Started:** 2026-06-05 18:08:00
**Item:** AR-11 — baseline report tests

**Did:** Added `Tests/SP.AdaptiveBaselineReports.Tests.ps1` (BR-001..BR-007).
Synthetic audits → `Build-SPRCDataset` → each of the 7 reports. Asserts: all 7
exported; each emits well-formed HTML > 800 B with **no** PowerShell error dump
(`At line:`/`FullyQualifiedErrorId`); inventory lists the entitlement names;
privileged review flags the privileged entitlement; orphaned/disabled surfaces the
disabled identity; the SoD report carries the ISC starter rule-set; every report
renders (no throw) on an empty estate. Fixed the Pester-5 discovery/run gotcha
(the `-ForEach` report list is now at top-level/script scope so it is populated at
discovery time).

**Files:** `Tests/SP.AdaptiveBaselineReports.Tests.ps1` (new).

**Verification:** Pester (this file): **13 passed / 0 failed**.
**Review:** PASS (self — asserts real rendered content + error-free output +
empty-estate safety across all 7 reports).
**Backlog update:** AR-11 → DONE.

**Completed:** 2026-06-05 18:14:00
**Status:** SUCCESS
