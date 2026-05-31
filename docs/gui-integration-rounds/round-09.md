# Round 9
**Started:** 2026-05-31 14:48:00

GU-09 complete. All 9 items are now DONE.

**Verification report (12 checks, Opus model):**

| # | Check | Result |
|---|---|---|
| 1-4, 6-12 | Control coverage, tab order, colors, dialog pattern, async runspace, wiring, XML, PS syntax | PASS |
| 5 | Bridge function exports | FAIL -- fixed |

**Two fixes applied:**

- **M-1** (`SP.GuiBridge.psm1`): `Get-SPGuiDisconnectedAppStatus` was in the `.psd1` FunctionsToExport but missing from `Export-ModuleMember` in the `.psm1`. Added to the export list.
- **M-2** (`SP.MainWindow.psm1`): `Save-SettingsForm` was hard-coding `RetryDelaySeconds=5`, `RateLimitRequestsPerWindow=95`, `RateLimitWindowSeconds=10` instead of reading from `TxtRetryDelay`/`TxtRateLimit`/`TxtRateWindow` controls. Fixed with `TryParse` reads matching the existing pattern.

All 9 GU items are DONE. The backlog has no remaining PENDING items.

