# T-04 -- Resilience: prove graceful handling of 429/500/timeout during the daily attestation cadence, then reset injection

## Read
- `Modules/SP.Api/SP.ApiClient.psm1` -- `Invoke-SPApiRequest` retry loop, `Get-SPRetryAfterMs` (honors Retry-After header, else `DefaultDelaySeconds*1000`), `Get-SPStatusCodeFromException` (WebException.Response.StatusCode else regex `\(([45]\d{2})\)`), `$shouldRetry` on 429/5xx/status=0, 429 honors Retry-After (no backoff), 5xx/status=0 exponential backoff capped at MaxRetryDelaySeconds, terminal failure returns `@{Success=$false;Data=$null;StatusCode;Error="Request failed after N attempt(s): ..."}`.
- `Tests/SP.ApiClient.Tests.ps1` -- mocking patterns mirrored: `BeforeAll { . Import-TestModules.ps1; Import-SPTestModules -Core -Api }`, local `New-MockSPConfig` / `New-MockAuthResult`, `Mock Write-SPLog/Get-SPConfig/Get-SPAuthToken/Start-Sleep -ModuleName SP.ApiClient`, the API-008 L2 `$script:RecordedSleeps` recording-mock pattern, the API-007 `$script:CallCount` counter pattern.
- `Tests/Import-TestModules.ps1` -- flat-import rule (Bug-1) for `-ModuleName` mock resolution.
- `Scripts/Invoke-SP30DayManagerCertSim.ps1` -- param block: `-ConfigPath`, `-CadenceDays` (default 7), `-SkipWrite`; emits exit code.
- Mock repo `C:/temp/Coding/API-mockserver`: `Scripts/Set-ErrorPreset.ps1` (param `-PresetName`/`-ConfigPath`; patches mock-settings.json only, NO hot-reload -- requires mock restart), `Scripts/Set-TestScenario.ps1`, `Config/error-presets.json` (presets `rate-limiting` [429 + Retry-After], `sailpoint-slow`, `intermittent-failures`, and `none` exists at line 61 = reset target).

## Did
- Created `Tests/SP.ApiResilience.Tests.ps1` (the headless gate; mocked transport, no live server). Mirrors SP.ApiClient.Tests.ps1 exactly (same BeforeAll import, copied-in `New-MockSPConfig`/`New-MockAuthResult`, `Start-Sleep` always mocked). Four use-case Describe blocks:
  - RES-001 (429-with-Retry-After-then-success): proves the Retry-After honor WIRING. Used the spec-sanctioned least-brittle approach (a real header-bearing `HttpWebResponse` is not constructible under PS5.1 without a live socket): `Mock Get-SPRetryAfterMs -ModuleName SP.ApiClient { 2000 }` and a recording `Start-Sleep` mock; asserts the 429 retry slept exactly 2000ms (header-derived) NOT the 1s default backoff, that the final envelope is `Success=$true`/Data populated/Error empty, and that `Get-SPRetryAfterMs` was invoked. The header-construction approach was attempted but documented inline as brittle; fallback chosen + documented.
  - RES-002 (500-exhaust-then-failure): `Mock Invoke-RestMethod { throw [WebException]'(500) ...' }`, RetryCount=2. Asserts `{ ... } | Should -Not -Throw` (no crash), `Success=$false`, `StatusCode=500`, `Error -Match 'Request failed after'`, and `Data | Should -BeNullOrEmpty` (no silent data loss).
  - RES-003 (timeout/transient retry per policy): first call throws `[WebException]'The operation has timed out'` (status=0 path) then succeeds -> `Success=$true`, CallCount==2; second It: timeout persists -> `Success=$false`, Error non-empty, Data null, CallCount==3.
  - RES-004 (terminal-failure envelope shape): consolidated assertion that on 503 terminal failure the return is a `[hashtable]` with all four keys present, Data null, Error a non-empty `[string]`, with no unhandled exception. (Fixed a child-scope capture bug: assign to `$script:res004` inside the `Should -Not -Throw` scriptblock then read it back.)
- Created `Scripts/Invoke-SPResilienceProbe.ps1` (authored live probe; NOT auto-run as the gate). `try { apply preset via Set-ErrorPreset.ps1; run Invoke-SP30DayManagerCertSim.ps1 -CadenceDays N -SkipWrite; assert $LASTEXITCODE in {0,1} else FAIL } finally { ALWAYS reset via Set-ErrorPreset.ps1 -PresetName none, print the exact reset command, note scenario reset availability }`. Prints the mandatory "Set-ErrorPreset only patches mock-settings.json -- restart Start-MockServer.ps1 for it to take effect" operator note, which is why it is authored for a human and NOT executed as the headless gate.
- Did NOT modify `SP.ApiClient.psm1` (PROVE-IT item; additive only). No mock-side code change required.

## Files
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\SP.ApiResilience.Tests.ps1` (CREATE -- toolkit; mocked-transport Pester suite; the headless gate)
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Scripts\Invoke-SPResilienceProbe.ps1` (CREATE -- toolkit; authored live-mock probe, NOT auto-run)
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\docs\loop-runs\autoloop1-20260606-082147\round-04-t-04.md` (this record)

## Verification

### Headless gate -- new resilience suite (ALL GREEN)
`Invoke-Pester -Path '...\Tests\SP.ApiResilience.Tests.ps1' -Output Detailed`
```
Describing RES-001: 429 with Retry-After is honored then the request succeeds
 Context When a 429 carries Retry-After: 2 and the next call succeeds
   [+] Should retry after the 429 and return Success=true with Data populated and Error empty
   [+] Should honor the Retry-After delay (sleep 2000ms) on the 429 retry, not a backoff value
   [+] Should resolve the wait via Get-SPRetryAfterMs (honor wiring engaged)
Describing RES-002: Repeated 500s exhaust retries and return a clear failure envelope
 Context When the API always returns 500 (RetryCount=2 => 3 attempts)
   [+] Should NOT throw an unhandled exception (no crash)
   [+] Should return Success=false, StatusCode 500, a clear Error, and null Data (no silent data loss)
Describing RES-003: Transient timeout / WebException retries per policy
 Context When a timeout occurs once then the call succeeds
   [+] Should retry after the timeout and ultimately succeed (CallCount == failures+1)
   [+] Should call Start-Sleep before the retry
 Context When the timeout persists beyond RetryCount (RetryCount=2 => 3 attempts)
   [+] Should stop after 3 attempts and return Success=false with a non-empty Error
Describing RES-004: Terminal failure always returns the standard envelope shape
 Context When the API consistently fails (503)
   [+] Should return a complete @{Success;Data;StatusCode;Error} envelope with Data null and Error a non-empty string
Tests completed in 3.46s
Tests Passed: 9, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### Regression -- existing client suite stays green (additivity proof, no rewire)
`Invoke-Pester -Path '...\Tests\SP.ApiClient.Tests.ps1' -Output Detailed`
```
Tests Passed: 27, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### Parse/lint the authored probe (NOT auto-run)
`$null = [System.Management.Automation.Language.Parser]::ParseFile('...\Scripts\Invoke-SPResilienceProbe.ps1',[ref]$null,[ref]$null); 'PARSE-OK'`
```
PARSE-OK
```

### Clean-mock reset command -- AUTHORED ONLY (live probe NOT executed)
The live probe was NOT run (Set-ErrorPreset has no hot-reload; it is a human-run gate),
so no error preset was applied by this item and no clean-state proof against a live mock
is pasted. The exact reset command the probe runs in its `finally` block (authored) is:
```
& C:/temp/Coding/API-mockserver/Scripts/Set-ErrorPreset.ps1 -PresetName none
```
The mock was therefore left untouched/clean by this item (no injection applied).

## Commit
14d... see structured output (subject: `test(resilience): prove 429/500/timeout graceful handling + authored live mock probe (T-04)`)

## Status
DONE
