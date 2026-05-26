# Round 8 -- W-05: CLI Scripts Against Remote Mock

**Started:** 2026-05-23
**Phase:** W-05
**Status:** SUCCESS -- 8/8 PASS
**Harness:** `Tests\Harness\Test-W05-CliScripts.ps1`
**Mock:** http://10.0.0.143:8080 (reachable)
**Run command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Harness\Test-W05-CliScripts.ps1`

## Summary

| Result   | Count |
|----------|-------|
| PASS     | 8     |
| FAIL     | 0     |
| BLOCKED  | 0     |
| **Total**| **8** |

Exit code: 0.

## Per-test results

| ID         | Result | Note |
|------------|--------|------|
| WC-05-01   | PASS   | `Test-SPConnectivity.ps1` -- exit 0; first stdout line: `SailPoint ISC Governance Toolkit - Connectivity Test` |
| WC-05-02   | PASS   | `Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 365 -IncludeLeadershipRollup -LeadershipDepth 4 -DetailLevel Detailed` -- exit 0; wrote `Audit\leadership\executive-summary.html` + 3 per-leader HTML reports (director-AliceJohnson, director-BobSmith, director-CharlieWilliams) |
| WC-05-03   | PASS   | `Invoke-SPCampaignAudit.ps1 -Status ACTIVE -DaysBack 365` -- exit 0; `Found 8 campaign(s)` -- more than the backlog's 1-2 expectation, but the mock has accumulated AD-Delta-Cert campaigns from prior rounds so this is correct (script ran cleanly) |
| WC-05-04   | PASS   | `Invoke-SPADDeltaCert.ps1 -SourceId src-ad-001 -CampaignNamePrefix WinCLI-01` -- exit 0; `Identities: 0` reported (mock returned `DuplicatesExist` because the WinCLI-01 prefix already exists from a previous test) |
| WC-05-05   | PASS   | `Invoke-SPADDeltaCert.ps1 -SourceId src-ad-001 -ReviewerMode SourceOwner -CampaignNamePrefix WinCLI-02` -- exit 0 |
| WC-05-06   | PASS   | `Invoke-SPDeltaReport.ps1 -SourceId src-ad-001 -HoursBack 48` -- exit 0; `Delta Report Complete`; 1 HTML report written under `DeltaCert\reports\delta-2026-05-23.html` |
| WC-05-07   | PASS   | `Invoke-SPDeltaCertEscalate.ps1 -StaleHours 1 -WhatIf` -- exit 0; stdout contains `[WhatIf] Dry-run mode. No write API calls will be made.` |
| WC-05-08   | PASS   | `Invoke-SPCampaignAudit.ps1 -Status COMPLETED -WhatIf` -- exit 0; stdout contains `[WhatIf] Dry-run mode enabled. No API calls will be made.` |

## Artifacts

- Harness: `Tests\Harness\Test-W05-CliScripts.ps1`
- Per-test JSONL: `docs\windows-test-rounds\WC-05-results.jsonl`
- Harness stdout/stderr: `docs\windows-test-rounds\WC-05-stdout.txt`
- Per-script transcripts (stdout + stderr captured from each child powershell.exe):
  - `WC-05-01-Test-SPConnectivity.txt`
  - `WC-05-02-CampaignAudit-COMPLETED.txt`
  - `WC-05-03-CampaignAudit-ACTIVE.txt`
  - `WC-05-04-ADDeltaCert-Manager.txt`
  - `WC-05-05-ADDeltaCert-SourceOwner.txt`
  - `WC-05-06-DeltaReport-48h.txt`
  - `WC-05-07-DeltaCertEscalate-WhatIf.txt`
  - `WC-05-08-CampaignAudit-WhatIf.txt`
- Generated HTML reports (used by W-06):
  - `Audit\leadership\executive-summary.html`
  - `Audit\leadership\director-AliceJohnson.html`
  - `Audit\leadership\director-BobSmith.html`
  - `Audit\leadership\director-CharlieWilliams.html`
  - `Audit\campaign-audit-*.html` (per WC-05-02 detailed run; bundled with leadership artifacts)
  - `DeltaCert\reports\delta-2026-05-23.html`
- `DeltaCert\deltacert-audit.jsonl` updated with per-run entries from WC-05-04 + WC-05-05.

## Notes

- `Config\settings.json` was overlaid with the 10.0.0.143 mock configuration
  for this run (matching `Config\settings.local.json`). `git restore` after the
  run; verified `git diff Config\settings.json` is empty before commit.
- `Audit\` and `DeltaCert\` were cleaned before the harness runs so we observe
  fresh output from this round only.
- `Invoke-CliScript` helper launches each script as a child powershell.exe
  process (`-NoProfile -ExecutionPolicy Bypass -File`), redirects stdout and
  stderr through async `DataReceived` event handlers, and saves a unified
  transcript per script.
- No new bugs found this round; all 8 scripts behave correctly against the mock.

## Bugs fixed during harness development

The first run of the harness threw on WC-05-01 because the `Invoke-CliScript`
helper's `-Args` parameter rejected the empty array passed for the
zero-argument `Test-SPConnectivity.ps1`. Marked the parameter
`[AllowEmptyCollection()]` with a default of `@()`. WC-05-01 then passed.
