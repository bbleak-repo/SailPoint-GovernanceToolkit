#Requires -Version 5.1
<#
.SYNOPSIS
    Live-mock end-to-end proof for the cache-honesty COMPLETED-campaign fix: runs the ACTUAL
    Invoke-SPDailyEvidenceReportV4b.ps1 against the Pode mock for a FORCE-CLOSED COMPLETED campaign
    (certs ISC-force-signed at closure, leftover items idNowAutoApproved) and asserts the produced
    HTML reports WHO did not complete correctly.

.DESCRIPTION
    Unlike the unit/integration tests (SP.ReviewerCompletionAttribution, SP.CompletionE2E) which drive
    the pipeline FUNCTIONS with a mocked HTTP seam, this harness runs the real report SCRIPT as a child
    process against the running mock and inspects the real HTML artifact. It exercises:
      - auth (OAuth client_credentials) + campaign enumeration against the mock,
      - Get-SPCachedCampaignItems writing/reading the real on-disk items cache (within TTL),
      - the COMPLETED reviewer-attribution + provenance-banner render.

    Asserts on camp-ch-completed-001 ('CH Completed Campaign 001', status COMPLETED in the seed):
      A1  Undecided work is attributed to the cert-ASSIGNED reviewers by NAME (Dana Done, Evan Done).
      A2  NO '(Unassigned)' collapse (the old-bug signature).
      A3  Evan's idNowAutoApproved items count as UNDECIDED (honest completion, not ISC's inflated 100%).
      A4  The 'completion unverified' provenance banner renders (first-seen-COMPLETED, no ACTIVE snapshot).

    Requires the mock at -MockBaseUrl with the camp-ch-* seed (Start-MockServer.ps1 -Fresh). If the mock
    is unreachable the harness reports BLOCKED (not FAIL). Cache/output land under the gitignored Audit\;
    the harness removes its own camp-ch-* artifacts unless -KeepArtifacts.

.NOTES
    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Harness\Test-CacheHonestyForcedClose.ps1
#>
[CmdletBinding()]
param(
    [Parameter()][string]$MockBaseUrl = 'http://localhost:8080',
    [Parameter()][switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$results = New-Object System.Collections.Generic.List[object]
function Add-Result { param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ id=$Id; result=$Result; note=$Note }))
}

# ---- mock reachable? ----
try { Invoke-RestMethod "$MockBaseUrl/health" -TimeoutSec 4 | Out-Null }
catch { Add-Result 'FC-MOCK' 'BLOCKED' "mock not reachable at $MockBaseUrl/health -- start it: Start-MockServer.ps1 -Fresh"; return }

# ---- mock-targeted config (auth + base url); Audit paths are left at repo defaults ----
$work = Join-Path $env:TEMP ("ch-forceclose-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$cfgPath = Join-Path $work 'mock-config.json'
$base = Get-Content (Join-Path $toolkitRoot 'Config\settings.json') -Raw | ConvertFrom-Json
$base.Global.EnvironmentName                  = 'MOCK-FORCECLOSE'
$base.Authentication.ConfigFile.TenantUrl     = $MockBaseUrl
$base.Authentication.ConfigFile.OAuthTokenUrl = "$MockBaseUrl/oauth/token"
$base.Authentication.ConfigFile.ClientId      = 'mock-test-client'
$base.Authentication.ConfigFile.ClientSecret  = 'mock-test-secret'
$base.Api.BaseUrl                             = "$MockBaseUrl/v3"
$base.Safety.RequireWhatIfOnProd             = $false
($base | ConvertTo-Json -Depth 25) | Set-Content -Path $cfgPath -Encoding utf8

# ---- run the ACTUAL report script ----
$v4b = Join-Path $toolkitRoot 'Scripts\Invoke-SPDailyEvidenceReportV4b.ps1'
$ps  = (Get-Command powershell.exe).Source
& $ps -NoProfile -ExecutionPolicy Bypass -File $v4b -ConfigPath $cfgPath -CampaignNameContains 'CH Completed' -DaysBack 60 -OutputMode HTML 2>&1 | Out-Null
# exit 5 is EXPECTED here (a force-closed/incomplete campaign yields Red KPIs) -- correctness is in the HTML.

$htmlDir = Join-Path $toolkitRoot 'Audit\daily-evidence'
$html = Get-ChildItem $htmlDir -Filter 'daily-evidence-v4b-*.html' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $html) { Add-Result 'FC-RUN' 'FAIL' 'no daily-evidence-v4b HTML produced'; return }
$c = Get-Content $html.FullName -Raw

# ---- assertions ----
$assignedOk = ($c -match 'Dana Done') -and ($c -match 'Evan Done')
Add-Result 'FC-A1-assigned-reviewers' ($(if ($assignedOk) {'PASS'} else {'FAIL'})) 'undecided work attributed to cert-assigned reviewers by name'

$noCollapse = -not ($c -match '\(Unassigned\)')
Add-Result 'FC-A2-no-unassigned-collapse' ($(if ($noCollapse) {'PASS'} else {'FAIL'})) "(Unassigned) collapse must be absent"

# Evan was ISC-force-signed but his 3 items are idNowAutoApproved -> they must count as UNDECIDED, so
# the undecided list has TWO reviewers (Dana + Evan), not one. (If auto-approve were treated as
# approved -- the ISC lie -- Evan would have 0 undecided and only Dana would appear.)
$autoApproveCounted = ($c -match '2 reviewer\(s\) with undecided items') -and ($c -match 'Evan Done')
Add-Result 'FC-A3-autoapprove-as-undecided' ($(if ($autoApproveCounted) {'PASS'} else {'FAIL'})) 'force-signed/auto-approved (idNowAutoApproved) items counted as undecided -> 2 reviewers incomplete'

$banner = ($c -match 'completion unverified') -and ($c -match 'No active-state capture')
Add-Result 'FC-A4-unverified-banner' ($(if ($banner) {'PASS'} else {'FAIL'})) 'first-seen-COMPLETED renders the unverified-provenance banner'

# ---- cleanup (Audit\ is gitignored; tidy our camp-ch-* artifacts) ----
if (-not $KeepArtifacts) {
    foreach ($f in @(Get-ChildItem (Join-Path $toolkitRoot 'Audit\.cache') -Filter 'items-camp-ch-*'  -ErrorAction SilentlyContinue) +
                   @(Get-ChildItem (Join-Path $toolkitRoot 'Audit\.cache') -Filter 'roster-camp-ch-*' -ErrorAction SilentlyContinue) +
                   @($html)) {
        try { [System.IO.File]::Delete($f.FullName) } catch { }
    }
    try { [System.IO.Directory]::Delete($work, $true) } catch { }
}

$fail = @($results | Where-Object result -eq 'FAIL').Count
Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary=$true; pass=@($results|? result -eq 'PASS').Count; fail=$fail; blocked=@($results|? result -eq 'BLOCKED').Count; html=$html.Name }))
if ($fail -gt 0) { exit 1 } else { exit 0 }
