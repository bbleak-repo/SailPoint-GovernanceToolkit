#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x LIVE-MOCK end-to-end proof for the regular campaign upload -> audit
    HTML write path (T-02).
.DESCRIPTION
    Test ids CAMP-UP-HTML-001 .. CAMP-UP-HTML-006.

    Exercises the TOOLKIT write path against the running mock server
    (http://localhost:8080) and proves the generated audit HTML is correct and
    complete:

      CAMP-UP-HTML-001  New-SPCampaign -Type MANAGER       -> @{Success;Data;Error}, Data.id set.
      CAMP-UP-HTML-002  New-SPCampaign -Type SOURCE_OWNER  -> same, using a live SourceId.
      CAMP-UP-HTML-003  New-SPCampaign -Type SEARCH        -> same, using an identity query.
      CAMP-UP-HTML-004  Start-SPCampaign activates all 3   -> @{Success}.
      CAMP-UP-HTML-005  Invoke-SPCampaignAudit.ps1 (JSON)  -> CampaignsAudited >= 3, OutputPath matches.
      CAMP-UP-HTML-006  Combined audit HTML content        -> campaign names + 'Executive Summary'
                                                              + 'Approved'/'Revoked' + 'Campaign ID:'.

    WIRING (critical, mirrors the toolkit's own config resolution):
      - New-SPCampaign / Start-SPCampaign -> Invoke-SPApiRequest -> Get-SPConfig (NO path)
        and Get-SPAuthToken -> Get-SPConfig (NO path). Both resolve the live BaseUrl
        through Resolve-SPConfigPath, which honors Config\settings.local.json when it
        exists (else Config\settings.json). The audit SCRIPT runs in a child process
        and likewise resolves its nested-module config that way.
      - To point the WHOLE chain (in-process create/activate AND the child-process
        audit) at the localhost mock WITHOUT mutating any tracked repo file, this test
        temporarily overlays Config\settings.local.json (a developer-local, GITIGNORED
        file) with the localhost mock settings, then RESTORES the original byte-for-byte
        in AfterAll. settings.local.json is intentionally untracked, so this overlay
        never appears in git and the developer's local config is left exactly as found.

    MOCK-REACHABILITY GATE:
      - Probed once at DISCOVERY scope (Pester 5 evaluates -Skip at discovery). When the
        mock is unreachable every live It is -Skip'd so the file PASSES cleanly.

    ADDITIVE: this file only ADDS a test. It does not modify SP.Campaigns / SP.Api /
    audit / HTML code, and it does not change any tracked configuration.
#>

# ---------------------------------------------------------------------------
# DISCOVERY-SCOPE mock probe (so -Skip:(-not $script:MockUp) resolves correctly).
# ---------------------------------------------------------------------------
$script:MockUp = $true
try {
    $probe = Invoke-WebRequest -Uri 'http://localhost:8080/oauth/token' `
        -Method POST -ContentType 'application/x-www-form-urlencoded' `
        -Body 'grant_type=client_credentials&client_id=mock&client_secret=mock' `
        -UseBasicParsing -TimeoutSec 5
    if ($probe.StatusCode -ne 200) { $script:MockUp = $false }
}
catch {
    $script:MockUp = $false
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    $script:ConfigDir   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Config'))
    $script:LocalCfg    = Join-Path $script:ConfigDir 'settings.local.json'
    $script:MockCfgPath = Join-Path $script:ConfigDir 'settings-mock.json'

    # Discovery-scope $script:MockUp is NOT carried into the run phase in Pester 5,
    # so re-probe here (run phase) to decide whether to overlay config + fetch ids.
    # (-Skip on each It still uses the discovery-scope probe above.)
    $mockUpRun = $true
    try {
        $p = Invoke-WebRequest -Uri 'http://localhost:8080/oauth/token' `
            -Method POST -ContentType 'application/x-www-form-urlencoded' `
            -Body 'grant_type=client_credentials&client_id=mock&client_secret=mock' `
            -UseBasicParsing -TimeoutSec 5
        if ($p.StatusCode -ne 200) { $mockUpRun = $false }
    }
    catch { $mockUpRun = $false }

    # ---- Overlay settings.local.json with the localhost mock config ----------
    # settings.local.json is gitignored/untracked; we back up the EXACT bytes (if
    # any) and restore them in AfterAll. This makes Resolve-SPConfigPath -> the
    # localhost mock for BOTH the in-process New/Start calls and the child-process
    # audit, without touching any tracked file.
    $script:LocalCfgExisted = Test-Path -Path $script:LocalCfg -PathType Leaf
    $script:LocalCfgBackup  = $null
    if ($script:LocalCfgExisted) {
        $script:LocalCfgBackup = [System.IO.File]::ReadAllBytes($script:LocalCfg)
    }

    if ($mockUpRun) {
        $mockJson = Get-Content -Path $script:MockCfgPath -Raw | ConvertFrom-Json
        # Mock OAuth accepts client_id/secret = 'mock'/'mock'.
        $mockJson.Authentication.ConfigFile.ClientId     = 'mock'
        $mockJson.Authentication.ConfigFile.ClientSecret = 'mock'
        $mockJson | ConvertTo-Json -Depth 20 |
            Set-Content -Path $script:LocalCfg -Encoding UTF8
        # Bust any cached config/token from a prior import so the overlay is honored.
        $null = Get-SPConfig -ConfigPath $script:LocalCfg -Force
    }

    # ---- Deterministic run tag; TYPE embedded in the NAME --------------------
    $script:Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:RunTag = "AutoLoop2-Upload-$($script:Stamp)"
    $script:MgrId  = $null
    $script:SrcOwnId = $null
    $script:SearchId = $null
    $script:CreatedIds = @()

    # ---- Data-driven IDs fetched live from the mock --------------------------
    $script:SourceId = $null
    $script:CertId   = $null
    if ($mockUpRun) {
        try {
            $srcResp = Invoke-SPApiRequest -Method GET -Endpoint '/sources' -QueryParams @{ limit = 1 }
            if ($srcResp.Success -and $srcResp.Data) {
                $firstSrc = $srcResp.Data | Select-Object -First 1
                $script:SourceId = $firstSrc.id
                # The mock does not serve a GET identities list; derive a real
                # certifier identity from the source owner.
                if ($firstSrc.owner -and $firstSrc.owner.id) {
                    $script:CertId = $firstSrc.owner.id
                }
            }
        }
        catch {
            Write-Host "BeforeAll: failed to fetch source/cert ids: $($_.Exception.Message)"
        }
    }

    # ---- Audit output dir (left for inspection) ------------------------------
    $script:AuditDir = Join-Path $env:TEMP "sp-autoloop2-audit-$($script:Stamp)"
    $script:AuditScript = (Join-Path $PSScriptRoot '..\Scripts\Invoke-SPCampaignAudit.ps1')
}

Describe "CAMP-UP-HTML: Regular campaign upload (MANAGER/SOURCE_OWNER/SEARCH) -> audit HTML" {

    Context "CAMP-UP-HTML-001 .. 003: New-SPCampaign returns the envelope with a created id" {

        It "CAMP-UP-HTML-001 creates a MANAGER campaign" -Skip:(-not $script:MockUp) {
            if ([string]::IsNullOrWhiteSpace($script:CertId)) {
                Set-ItResult -Skipped -Because 'mock returned no certifier identity id (source owner missing)'
                return
            }
            $cid = [guid]::NewGuid().ToString()
            $r = New-SPCampaign -Name "$($script:RunTag)-MANAGER" -Type MANAGER `
                -CertifierIdentityId $script:CertId -CorrelationID $cid
            $r | Should -Not -BeNullOrEmpty
            $r.Success | Should -BeTrue -Because "New-SPCampaign MANAGER should succeed (Error: $($r.Error))"
            $r.Data.id | Should -Not -BeNullOrEmpty
            if ($r.Data.PSObject.Properties.Name -contains 'type' -and $r.Data.type) {
                $r.Data.type | Should -Be 'MANAGER'
            }
            $script:MgrId = $r.Data.id
            $script:CreatedIds += $script:MgrId
        }

        It "CAMP-UP-HTML-002 creates a SOURCE_OWNER campaign" -Skip:(-not $script:MockUp) {
            if ([string]::IsNullOrWhiteSpace($script:SourceId)) {
                Set-ItResult -Skipped -Because 'mock returned no source id'
                return
            }
            $cid = [guid]::NewGuid().ToString()
            $r = New-SPCampaign -Name "$($script:RunTag)-SOURCE_OWNER" -Type SOURCE_OWNER `
                -SourceId $script:SourceId -CorrelationID $cid
            $r | Should -Not -BeNullOrEmpty
            $r.Success | Should -BeTrue -Because "New-SPCampaign SOURCE_OWNER should succeed (Error: $($r.Error))"
            $r.Data.id | Should -Not -BeNullOrEmpty
            if ($r.Data.PSObject.Properties.Name -contains 'type' -and $r.Data.type) {
                $r.Data.type | Should -Be 'SOURCE_OWNER'
            }
            $script:SrcOwnId = $r.Data.id
            $script:CreatedIds += $script:SrcOwnId
        }

        It "CAMP-UP-HTML-003 creates a SEARCH campaign" -Skip:(-not $script:MockUp) {
            if ([string]::IsNullOrWhiteSpace($script:CertId)) {
                Set-ItResult -Skipped -Because 'mock returned no certifier identity id'
                return
            }
            $cid = [guid]::NewGuid().ToString()
            $r = New-SPCampaign -Name "$($script:RunTag)-SEARCH" -Type SEARCH `
                -SearchFilter '@access(source.name:*)' -CertifierIdentityId $script:CertId `
                -CorrelationID $cid
            $r | Should -Not -BeNullOrEmpty
            $r.Success | Should -BeTrue -Because "New-SPCampaign SEARCH should succeed (Error: $($r.Error))"
            $r.Data.id | Should -Not -BeNullOrEmpty
            if ($r.Data.PSObject.Properties.Name -contains 'type' -and $r.Data.type) {
                $r.Data.type | Should -Be 'SEARCH'
            }
            $script:SearchId = $r.Data.id
            $script:CreatedIds += $script:SearchId
        }
    }

    Context "CAMP-UP-HTML-004: Start-SPCampaign activates the uploaded campaigns" {

        It "CAMP-UP-HTML-004 activates all 3 uploaded campaigns" -Skip:(-not $script:MockUp) {
            $ids = @($script:MgrId, $script:SrcOwnId, $script:SearchId) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($ids.Count -lt 3) {
                Set-ItResult -Skipped -Because "fewer than 3 campaigns were created ($($ids.Count)); upload steps did not all land"
                return
            }
            foreach ($id in $ids) {
                $s = Start-SPCampaign -CampaignId $id -CorrelationID ([guid]::NewGuid().ToString())
                $s | Should -Not -BeNullOrEmpty
                $s.Success | Should -BeTrue -Because "Start-SPCampaign should activate $id (Error: $($s.Error))"
            }
        }
    }

    Context "CAMP-UP-HTML-005: Invoke-SPCampaignAudit.ps1 (JSON) audits the uploaded campaigns" {

        It "CAMP-UP-HTML-005 audits >= 3 campaigns and reports the requested OutputPath" -Skip:(-not $script:MockUp) {
            $ids = @($script:MgrId, $script:SrcOwnId, $script:SearchId) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($ids.Count -lt 3) {
                Set-ItResult -Skipped -Because "fewer than 3 campaigns were created; cannot prove >=3 audited"
                return
            }

            # OutputMode JSON; filter to this run's campaigns by name. The child
            # process resolves config via the overlaid settings.local.json.
            $raw = & $script:AuditScript -CampaignNameContains $script:RunTag `
                -OutputMode JSON -OutputPath $script:AuditDir -Status STAGED,ACTIVE 2>$null
            $script:AuditExit = $LASTEXITCODE

            $rawText = ($raw | Out-String)
            # The script may emit progress lines before the JSON object; extract the
            # final JSON object robustly (first '{' .. last '}').
            $startIdx = $rawText.IndexOf('{')
            $endIdx   = $rawText.LastIndexOf('}')
            $startIdx | Should -BeGreaterOrEqual 0 -Because "audit must emit a JSON object (exit=$($script:AuditExit), raw: $rawText)"
            $jsonText = $rawText.Substring($startIdx, ($endIdx - $startIdx + 1))
            $script:Summary = $jsonText | ConvertFrom-Json

            $script:AuditExit | Should -Be 0 -Because "audit should exit 0 when campaigns match"
            $script:Summary.CampaignsAudited | Should -BeGreaterOrEqual 3 `
                -Because "all 3 uploaded campaigns ($($script:RunTag)-*) should be audited"
            # OutputPath in the summary should resolve to the same dir we requested.
            ([System.IO.Path]::GetFullPath($script:Summary.OutputPath)) |
                Should -Be ([System.IO.Path]::GetFullPath($script:AuditDir))
        }
    }

    Context "CAMP-UP-HTML-006: combined audit HTML content is correct and complete" {

        It "CAMP-UP-HTML-006 combined HTML contains campaign names, summary and decision labels" -Skip:(-not $script:MockUp) {
            if (-not (Test-Path -Path $script:AuditDir)) {
                Set-ItResult -Skipped -Because 'audit output dir not present (audit step skipped/failed)'
                return
            }
            $combined = Get-ChildItem -Path $script:AuditDir -Recurse `
                -Filter 'campaign-audit-combined-*.html' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $combined | Should -Not -BeNullOrEmpty -Because 'a combined audit HTML file should be generated'

            $html = Get-Content -Path $combined.FullName -Raw

            # (i) Each campaign NAME appears -- the TYPE label is embedded in the name,
            #     so this simultaneously proves the type string is present.
            $html | Should -Match ([regex]::Escape("$($script:RunTag)-MANAGER"))
            $html | Should -Match ([regex]::Escape("$($script:RunTag)-SOURCE_OWNER"))
            $html | Should -Match ([regex]::Escape("$($script:RunTag)-SEARCH"))

            # (ii) Executive Summary heading.
            $html | Should -Match 'Executive Summary'

            # (iii) Decisions/summary indicators.
            $html | Should -Match 'Approved'
            $html | Should -Match 'Revoked'
            $html | Should -Match 'Campaign ID:'
        }
    }
}

AfterAll {
    # Restore settings.local.json byte-for-byte (or remove if we created it).
    try {
        if ($script:LocalCfgExisted) {
            if ($null -ne $script:LocalCfgBackup) {
                [System.IO.File]::WriteAllBytes($script:LocalCfg, $script:LocalCfgBackup)
            }
        }
        elseif (Test-Path -Path $script:LocalCfg -PathType Leaf) {
            Remove-Item -Path $script:LocalCfg -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Host "AfterAll: failed to restore settings.local.json: $($_.Exception.Message)"
    }
    # Reset the config cache so later tests in the same session re-resolve cleanly.
    try { $null = Get-SPConfig -Force -ErrorAction SilentlyContinue } catch { }
    # NB: $script:AuditDir is intentionally LEFT for inspection.
}
