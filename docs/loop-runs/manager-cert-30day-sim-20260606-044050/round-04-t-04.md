# T-04 -- Build the 30-day simulation CLI driver in the toolkit (loads dataset, exercises toolkit headlessly, captures outputs)

## Read
- `Scripts/Invoke-SPDailyOrchestrator.ps1` -- the closest sibling (mutating multi-step CLI orchestrator). Mirrored its header (`#Requires -Version 5.1`, comment-based help with exit codes, `[CmdletBinding(SupportsShouldProcess)]` with NO explicit `-WhatIf`, `Set-StrictMode -Version 1`, `$ErrorActionPreference='Stop'`, `if($Help){Get-Help...}`), module-load + config/logging/auth block (Resolve-SPConfigPath / Get-SPConfig / Test-SPConfigFirstRun / Test-SPConfig / Initialize-SPLogging / Set-SPBrowserToken), the child-process invocation + JSON-parse pattern (lines 962-996), the `$WhatIfPreference` read (line 405), and the JSONL audit block (`[System.IO.File]::AppendAllText` + UTF8-no-BOM, lines 1306-1322).
- `Scripts/Invoke-SPCampaignAudit.ps1` -- param surface (Status ValidateSet, DaysBack, IncludeLeadershipRollup, OutputMode, OutputPath, Token); exit codes (0 ok / 1 no campaigns / 2 param / 3 auth / 4 config).
- `Scripts/Invoke-SPAdaptiveReport.ps1` -- param surface (Anchor, BaselineReport ValidateSet incl. `privileged`, DaysBack, DistributeToLeadership, SendReports, DetailLevel, OutputMode incl. JSON). Confirmed default `-DistributeToLeadership` WITHOUT `-SendReports` = simulate / "WOULD send" / no email.
- `Modules/SP.Api/SP.Campaigns.psm1` -- New-SPCampaign (Type MANAGER, CertifierIdentityId, CorrelationID, CampaignTestId; returns `@{Success;Data;Error}` with `.Data.id`), Start-SPCampaign, Complete-SPCampaign (gated by `Safety.AllowCompleteCampaign`), Get-SPCampaign, Search-SPCampaigns (`name co` keyword).
- `Config/settings.local.json` -- mock at `http://10.0.0.143:8080` (`Api.BaseUrl` `.../v3`), `Safety.MaxCampaignsPerRun=10`, `Safety.AllowCompleteCampaign=true`, `Audit.Smtp.Enabled=false` (so Send-SPReport logs not sends).
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (line 79908) -- `trackedPrivilegedRoles`: the 10 fixed privileged roles with id/name/responsibleManagerId/responsibleManagerName. There is NO dedicated mock endpoint to read these, so the driver carries the fixed list (per spec "OR a fixed local list").
- `Tests/SP.CliScripts.Tests.ps1` -- the affected param-surface suite (CLI-001..005); uses hardcoded script lists (does not auto-discover), so adding a new script is additive.

## Did
- Created ONE additive CLI driver `Scripts/Invoke-SP30DayManagerCertSim.ps1`. No existing script or module was edited.
- Param block mirrors the sibling: `[CmdletBinding(SupportsShouldProcess)]` (no explicit `-WhatIf`; reads `$WhatIfPreference`), `-OutputMode` `[ValidateSet('Console','JSON','Both')]`, plus `-ConfigPath -Token -TokenExpiryMinutes -CadenceDays -SkipWrite -SkipReports -SendReports -OutputPath -DetailLevel -Help`.
- Step A (WRITE round-trip, gated by `$PSCmdlet.ShouldProcess`): submits up to `Safety.MaxCampaignsPerRun` (=10) MANAGER campaigns (one per tracked privileged role, certifier = responsibleManagerId) via `New-SPCampaign`, then `Start-SPCampaign`, then `Complete-SPCampaign` for the first 3 when `Safety.AllowCompleteCampaign`. Confirms round-trip via `Get-SPCampaign` (per id) AND `Search-SPCampaigns -Keyword 'Sim Manager Cert'`. Writes `write-roundtrip.json`.
- Step B (daily cadence days 1..CadenceDays, default 7): per day calls `Invoke-SPCampaignAudit.ps1 -Status ACTIVE,COMPLETED -DaysBack $d -IncludeLeadershipRollup -OutputMode JSON`, `Invoke-SPAdaptiveReport.ps1 -Anchor Entitlement -BaselineReport privileged -DaysBack $d`, and the SMTP-WhatIf `Invoke-SPAdaptiveReport.ps1 ... -DistributeToLeadership` (NO `-SendReports` unless the driver's own `-SendReports`). Child exit 1 ("no campaigns in window") treated as WARN, not fatal.
- Step C (windowed): 7-day -> `windows\7d` and 30-day -> `windows\30d` audit + adaptive passes.
- Step D (capture): top-level `sim-summary.json` (CorrelationID, Run timestamps, MockBaseUrl, Write{Submitted/Activated/Completed/Confirmed/Ids/Names}, Cadence{Days;PerDay}, Windows{SevenDay;ThirtyDay}, ReportPaths, ExitCode) + `sim-audit.jsonl` (one line per step, UTF8 no-BOM via `AppendAllText`). Echoes every generated report path for T-05.
- Error/exit semantics copied from the sibling: per-step try/catch, `$worstExitCode` tracking (0 ok / 1 warnings / 5 critical write failure), `exit $worstExitCode`. `@{Success;Data;Error}` `.Success` checks on every module-function call. OutputMode switch at the end (Console / JSON / Both).
- PS 5.1 only: nested 2-arg Join-Path, `[System.Collections.Generic.List[object]]`, ShouldProcess gated on writes only. Capture-dir `New-Item` uses `-WhatIf:$false` so the infra dir is created even in dry-run (otherwise downstream artifact writes fail).

## Files
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Scripts/Invoke-SP30DayManagerCertSim.ps1` (CREATE)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-04-t-04.md` (CREATE - this record)

## Verification

### 1) Parser -- 0 errors
```
$e=$null; $t=$null; $null=[Parser]::ParseFile('...Invoke-SP30DayManagerCertSim.ps1',[ref]$t,[ref]$e); 'ParseErrors=' + @($e).Count
```
Output:
```
ParseErrors=0
```

### 2) Param surface
```
$c=Get-Command '...Invoke-SP30DayManagerCertSim.ps1'
'SupportsShouldProcess=' + $c.Parameters.ContainsKey('WhatIf')
'OutputModeSet=' + ((...ValidateSetAttribute).ValidValues -join ',')
```
Output:
```
SupportsShouldProcess=True
OutputModeSet=Console,JSON,Both
```

### 3) Help renders (clean import path)
```
powershell -NoProfile -File Scripts\Invoke-SP30DayManagerCertSim.ps1 -Help   ;  HELP-EXIT=0
```
Output (syntax line; -WhatIf/-Confirm shown as common params from SupportsShouldProcess, no collision):
```
Invoke-SP30DayManagerCertSim.ps1 [[-ConfigPath] <string>] [[-Token] <string>] [[-TokenExpiryMinutes] <int>] [[-CadenceDays] <int>] [[-OutputPath] <string>] [[-DetailLevel] <string>] [[-OutputMode] <string>] [-SkipWrite] [-SkipReports] [-SendReports] [-Help] [-WhatIf] [-Confirm] [<CommonParameters>]
----HELP-EXIT=0----
```

### 4) Mock UP + WhatIf dry-run (no mutations, exit 0)
```
(Invoke-RestMethod 'http://10.0.0.143:8080/health').status   ->   ok
powershell -NoProfile -File Scripts\Invoke-SP30DayManagerCertSim.ps1 -ConfigPath Config\settings.local.json -WhatIf -OutputMode Console -CadenceDays 1 -SkipReports
```
Output (tail): write steps printed `[WhatIf] Would submit + activate: Sim Manager Cert <role> <stamp>` for all 10 roles (NO API calls); `write-roundtrip.json` + `sim-summary.json` written; `Result: WHATIF`; `EXIT=0`.

### 5) Full headless end-to-end against the running non-elevated mock (the real gate)
```
powershell -NoProfile -File Scripts\Invoke-SP30DayManagerCertSim.ps1 -ConfigPath Config\settings.local.json -OutputMode Both   ;   EXIT=1
```
Real results (run dir `Audit\sim-30day-20260606-052838`):
- Step A write round-trip: 10 submitted + activated; round-trip **confirmed 10/10 via Get-SPCampaign**; **10 names returned by Search-SPCampaigns**. `sim-summary.json` Write block = `Submitted=10 Activated=10 Completed=3 Confirmed=10` (3 completed = first-3 subset gated by AllowCompleteCampaign). Ids: camp-974cd548, camp-8462d7d2, camp-83807edf, camp-9462869d, camp-66074aff, camp-874807a7, camp-0d1d5a5b, camp-541d4eb3, camp-2cc7b708, camp-586c6e74.
- Step B cadence: days 1..7 ran (`day-01`..`day-07` dirs). day-01 adaptive + smtp-whatif returned child exit 1 (empty 1-day window) -> WARN (non-fatal, by design); days 02-07 audit/adaptive/smtp-whatif all `OK (exit 0)`.
- SMTP-WhatIf: every leadership-distribution pass printed `Distribution (simulate / WhatIf -- no email sent):` and `[C] WOULD send -> ... director-*.html` then `=> 2 simulated (no email sent), 1 skipped`. **Zero "Sent".**
- Step C windows: `7d/audit OK`, `7d/adaptive OK`, `30d/audit OK`, `30d/adaptive OK`.
- Step D: `Reports captured: 403`; `sim-summary.json` + `sim-audit.jsonl` (27 lines) + `write-roundtrip.json` written.
- Capture dir layout confirmed: `day-01..day-07`, `windows\7d`, `windows\30d`, plus the 3 top-level artifacts.
- `Result: SUCCESS (with warnings)`; `EXIT=1` (the sole warning source = the legitimate empty day-01 window).

### 6) Affected-tests only -- CLI param-surface suite
```
Invoke-Pester -Path .\Tests\SP.CliScripts.Tests.ps1 -Output Detailed
```
Output:
```
Tests Passed: 75, Failed: 0, Skipped: 0
RESULT Passed=75 Failed=0 Skipped=0
```

## Commit
`b58f64f` -- feat(sim): add 30-day manager-cert simulation CLI driver (T-04)
(The script + this record were committed together; this hash line is corrected in a
small doc-only follow-up commit so the recorded hash is the real one for the script.)

## Status
DONE
