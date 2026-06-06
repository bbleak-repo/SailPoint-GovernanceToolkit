# T-02 -- Regular campaign upload -> HTML: New/Start-SPCampaign for MANAGER+SOURCE_OWNER+SEARCH, audit to HTML

## Read
- `Tests/SP.CampaignLifecycle.Tests.ps1` (header/import convention; `Import-SPTestModules -Core -Api`).
- `Tests/Import-TestModules.ps1` (flat .psm1 import; `-Core` brings Get-SPConfig, `-Api` brings New/Start-SPCampaign + Invoke-SPApiRequest).
- `Modules/SP.Api/SP.Campaigns.psm1` (New-SPCampaign l.129, Build-SPCampaignBody l.19 -- type at l.75, SOURCE_OWNER sourceIds l.83-87, MANAGER/SEARCH certifiers, Start-SPCampaign l.235 POSTs `/campaigns/{id}/activate`; both return `@{Success;Data;Error}`).
- `Modules/SP.Api/SP.ApiClient.psm1` (Invoke-SPApiRequest l.287 calls `Get-SPConfig` with NO path; BaseUrl at l.318).
- `Modules/SP.Core/SP.Config.psm1` (Get-SPConfig l.1277 caches by path; no-path -> `Resolve-SPConfigPath` l.1195 which honors `Config/settings.local.json` when present, else `settings.json`).
- `Modules/SP.Core/SP.Auth.psm1` (Get-SPAuthToken l.125 -> `Get-SPConfig` no-path l.176; ConfigFile mode OAuth against `OAuthTokenUrl` l.203).
- `Scripts/Invoke-SPCampaignAudit.ps1` (params: `-ConfigPath`, `-CampaignNameContains` l.115, `-Status` ValidateSet STAGED/ACTIVE/COMPLETING/COMPLETED l.118, `-OutputMode` JSON l.134; imports modules via .psd1 so nested config resolves through Resolve-SPConfigPath; emits summary JSON l.944).
- `Config/settings-mock.json` (BaseUrl `http://localhost:8080/v3`, OAuthTokenUrl localhost).

### Key wiring findings
- The mock listens ONLY on `127.0.0.1:8080`. `Config/settings.local.json` (the resolved default) pointed at `http://10.0.0.143:8080`, which is DOWN. So both the in-process New/Start calls AND the child-process audit resolve config via `Resolve-SPConfigPath` -> `settings.local.json`, NOT via the script's `-ConfigPath` for the nested no-path callers.
- `settings.local.json` is **gitignored and untracked** (`git check-ignore` exit 0; `git ls-files --error-unmatch` fails). Therefore the test temporarily overlays it with the localhost mock config and restores the exact original bytes in AfterAll -- no tracked file is touched and the developer's local config is left exactly as found.
- Pester 5 quirk: `$script:MockUp` set at DISCOVERY scope is available to `-Skip` but NOT inside `BeforeAll` (run phase). The test re-probes inside `BeforeAll` for the overlay/fetch, and keeps the discovery-scope probe purely for `-Skip`.
- Mock serves `GET /v3/sources` (returns `src-ad-001`, owner `id-gen-001`) but NOT a GET identities list (`/v3/public-identities` -> 405). The certifier identity id is derived from the source owner (`owner.id`).

## Did
- Added ONE new Pester 5.x test file `Tests/SP.RegularCampaignUploadHtml.Tests.ps1` (ids CAMP-UP-HTML-001..006). Live-mock end-to-end write+activate+audit+HTML proof, gated to SKIP cleanly when the mock is down.
- No production code changed. No tracked config changed.

## Files
- `Tests/SP.RegularCampaignUploadHtml.Tests.ps1` (new)
- `docs/loop-runs/autoloop2-data-campaigns-20260606-0908/round-02-t-02.md` (this record)

## Verification

### 1. Mock reachable (non-elevated, 127.0.0.1:8080)
```
curl -s -X POST http://localhost:8080/oauth/token -d 'grant_type=client_credentials&client_id=mock&client_secret=mock'
{"expires_in":749,"refresh_token":"mock-refresh-...","token_type":"Bearer","access_token":"mock-token-..."}
Get-NetTCPConnection -LocalPort 8080 -State Listen -> LocalAddress 127.0.0.1  OwningProcess 2880
```

### 2. New test run -- `Invoke-Pester .\Tests\SP.RegularCampaignUploadHtml.Tests.ps1 -Output Detailed`
```
Describing CAMP-UP-HTML: Regular campaign upload (MANAGER/SOURCE_OWNER/SEARCH) -> audit HTML
 Context CAMP-UP-HTML-001 .. 003: New-SPCampaign returns the envelope with a created id
   [+] CAMP-UP-HTML-001 creates a MANAGER campaign            192ms
   [+] CAMP-UP-HTML-002 creates a SOURCE_OWNER campaign        33ms
   [+] CAMP-UP-HTML-003 creates a SEARCH campaign              36ms
 Context CAMP-UP-HTML-004: Start-SPCampaign activates the uploaded campaigns
   [+] CAMP-UP-HTML-004 activates all 3 uploaded campaigns    175ms
 Context CAMP-UP-HTML-005: Invoke-SPCampaignAudit.ps1 (JSON) audits the uploaded campaigns
   ... Found 3 campaign(s). Processing AutoLoop2-Upload-...-MANAGER / -SOURCE_OWNER / -SEARCH ...
   [+] CAMP-UP-HTML-005 audits >= 3 campaigns and reports the requested OutputPath  1.03s
 Context CAMP-UP-HTML-006: combined audit HTML content is correct and complete
   [+] CAMP-UP-HTML-006 combined HTML contains campaign names, summary and decision labels  36ms
Tests Passed: 6, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### 3. Manual write-path proof (real envelopes)
```
SourceId=src-ad-001 CertId=id-gen-001
MANAGER      => {"Error":null,"Data":{"id":"camp-ff7a9d68","type":"MANAGER","status":"STAGED","name":"verify-141806-MANAGER",...},"Success":true}
SOURCE_OWNER => {"Error":null,"Data":{"id":"camp-521ffcd6","type":"SOURCE_OWNER","status":"STAGED","name":"verify-141806-SOURCE_OWNER",...},"Success":true}
SEARCH       => {"Error":null,"Data":{"id":"camp-07cc4b8a","type":"SEARCH","status":"STAGED","name":"verify-141806-SEARCH",...},"Success":true}
ACTIVATE camp-ff7a9d68 success=True
ACTIVATE camp-521ffcd6 success=True
ACTIVATE camp-07cc4b8a success=True
```

### 4. Audit JSON proof (summary object emitted by Invoke-SPCampaignAudit.ps1 -OutputMode JSON)
```
{
    "CorrelationID":  "4e9fa997-...",
    "StartedAt":  "2026-06-06T21:17:..Z",
    "CompletedAt":  "2026-06-06T21:17:..Z",
    "CampaignsAudited":  3,
    "OutputPath":  "C:\\Users\\THEAOF~1\\AppData\\Local\\Temp\\sp-autoloop2-audit-20260606-141742",
    "Environment":  "MOCK-SERVER"
}
```
(child process stdout also showed: `Found 3 campaign(s).` and per-campaign HTML written for MANAGER/SOURCE_OWNER/SEARCH.)

### 5. HTML content grep proof (combined file from the test run)
```
Combined = ...\sp-autoloop2-audit-20260606-141742\campaign-audit-combined-20260606-141744.html
Select-String pattern hits:
  AutoLoop2-Upload-.*-MANAGER       hits=4
  AutoLoop2-Upload-.*-SOURCE_OWNER  hits=4
  AutoLoop2-Upload-.*-SEARCH        hits=4
  Executive Summary                 hits=9
  Approved                          hits=7
  Revoked                           hits=19
  Campaign ID:                      hits=3
```

### 6. Cleanliness
```
git status --short  ->  ?? Tests/SP.RegularCampaignUploadHtml.Tests.ps1   (only the new file)
settings.local.json restored: Authentication.ConfigFile.TenantUrl = http://10.0.0.143:8080 (original)
git check-ignore Config/settings.local.json -> ignored (never staged)
```

## Commit
- `3a3081d` -- `test(campaign): T-02 regular campaign upload (MANAGER/SOURCE_OWNER/SEARCH) -> audit HTML e2e against mock`

## Status
DONE
