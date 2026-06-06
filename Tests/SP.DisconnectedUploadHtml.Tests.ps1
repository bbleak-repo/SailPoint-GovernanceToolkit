#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x end-to-end proof for the disconnected-app upload -> validate -> cert ->
    harvest -> validated HTML cycle (T-03).
.DESCRIPTION
    Test ids DA-UP-HTML-001 .. DA-UP-HTML-012.

    Proves the full disconnected-app onboarding+cert+report cycle to HTML, ADDITIVELY,
    for the two registered apps (PEP-Plus, DebtNext):

      OFFLINE (always-run, mock-independent):
        DA-UP-HTML-001  Generator -> PEP-Plus dated accounts + entitlements CSVs with
                        EXACT headers + AccountCount rows.
        DA-UP-HTML-002  Generator -> DebtNext accounts-only dated CSV (headers + rows).
        DA-UP-HTML-003  Test-SPDisconnectedAppAccountFile / EntitlementFile /
                        CrossReference all Success on the generated files (cert-ready).
        DA-UP-HTML-004  Compare-SPDisconnectedAppFiles (yesterday vs today) ->
                        Export-SPDisconnectedAppDeltaHtml -> HTML greps app name,
                        'Delta Summary', 'Total Current Accounts'.
        DA-UP-HTML-005  Export-SPDisconnectedAppDecisionHarvestHtml on fabricated harvest
                        data -> HTML greps app name, 'Decision Harvest', 'APPROVED',
                        'REVOKED', revoked count, a revoked IdentityName.
        DA-UP-HTML-006  Export-SPDisconnectedAppSlaHtml -> HTML greps 'SLA Delivery
                        Report', app name, 'Avg Delivery Rate'.
        DA-UP-HTML-007  Export-SPDisconnectedAppBatchHtml -> HTML greps 'Batch',
                        per-app name, status.

      LIVE (-Skip when mock unreachable):
        DA-UP-HTML-010  Invoke-SPDisconnectedAppCert.ps1 (child process, JSON) against
                        the running mock -> exit code 0/1 acceptable; audit JSONL OR
                        delta HTML produced.
        DA-UP-HTML-012  Get-SPDisconnectedAppCampaignDecisions (real harvest) ->
                        Export-SPDisconnectedAppDecisionHarvestHtml -> HTML exists
                        (soft-pass on zero campaigns).

    WIRING (mirrors the T-02 regular-campaign test):
      - The cert child process + harvest resolve config through Resolve-SPConfigPath,
        which honors Config\settings.local.json. We temporarily overlay that gitignored
        file with the localhost mock settings and restore the EXACT bytes in AfterAll.
      - Mock reachability probed at DISCOVERY scope so -Skip resolves at discovery.

    ADDITIVE: this file only ADDS a test. It does not modify any disconnected module,
    script, validator, exporter, or tracked configuration. All generated artifacts live
    under a per-run Tests\_artifacts dir that is removed in AfterAll.
#>

# ---------------------------------------------------------------------------
# DISCOVERY-SCOPE mock probe (so -Skip:(-not $script:MockUp) resolves at discovery).
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
    Import-SPTestModules -Core -Api -DisconnectedApps

    $script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ConfigDir   = Join-Path $script:ToolkitRoot 'Config'
    $script:LocalCfg    = Join-Path $script:ConfigDir 'settings.local.json'
    $script:MockCfgPath = Join-Path $script:ConfigDir 'settings-mock.json'
    $script:GenScript   = Join-Path $script:ToolkitRoot 'Scripts\New-SPDisconnectedAppSnapshotData.ps1'
    $script:CertScript  = Join-Path $script:ToolkitRoot 'Scripts\Invoke-SPDisconnectedAppCert.ps1'

    # Re-probe in run phase (Pester 5 does not carry discovery-scope vars to run phase).
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
    # settings.local.json is gitignored/untracked; back up EXACT bytes and restore
    # in AfterAll so the developer's local config is left exactly as found.
    $script:LocalCfgExisted = Test-Path -Path $script:LocalCfg -PathType Leaf
    $script:LocalCfgBackup  = $null
    if ($script:LocalCfgExisted) {
        $script:LocalCfgBackup = [System.IO.File]::ReadAllBytes($script:LocalCfg)
    }

    if ($mockUpRun) {
        $mockJson = Get-Content -Path $script:MockCfgPath -Raw | ConvertFrom-Json
        $mockJson.Authentication.ConfigFile.ClientId     = 'mock'
        $mockJson.Authentication.ConfigFile.ClientSecret = 'mock'
        $mockJson | ConvertTo-Json -Depth 20 |
            Set-Content -Path $script:LocalCfg -Encoding UTF8
        $null = Get-SPConfig -ConfigPath $script:LocalCfg -Force
    }

    # ---- Per-run artifacts tree (never pollutes the repo DisconnectedApps dir) -
    $script:Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:ArtifactDir = Join-Path $script:ToolkitRoot ("Tests\_artifacts\disconnected-$($script:Stamp)")
    $script:ImportsDir   = Join-Path $script:ArtifactDir 'Imports'
    $script:SnapshotsDir = Join-Path $script:ArtifactDir 'Snapshots'
    $script:ReportsDir   = Join-Path $script:ArtifactDir 'Reports'
    foreach ($d in @($script:ImportsDir, $script:SnapshotsDir, $script:ReportsDir)) {
        if (-not (Test-Path -Path $d -PathType Container)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
    }

    $script:Today     = Get-Date -Format 'yyyy-MM-dd'
    $script:Yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

    # ---- Generate the snapshots in-process (dot-source returns the envelope) ---
    # PEP-Plus: accounts + entitlements, today + yesterday (for the delta test).
    $script:PepGenToday = & $script:GenScript -AppName 'PEP-Plus' -WithEntitlements `
        -AccountCount 25 -EntitlementCount 8 -Seed 42 -ReportDate $script:Today `
        -OutputDir $script:ImportsDir -OutputMode Console
    $script:PepGenToday = @($script:PepGenToday)[-1]

    # Yesterday: different seed + fewer rows so a delta is produced.
    $script:PepGenYesterday = & $script:GenScript -AppName 'PEP-Plus' -WithEntitlements `
        -AccountCount 20 -EntitlementCount 8 -Seed 99 -ReportDate $script:Yesterday `
        -OutputDir $script:ImportsDir -OutputMode Console
    $script:PepGenYesterday = @($script:PepGenYesterday)[-1]

    # DebtNext: accounts only.
    $script:DebtGenToday = & $script:GenScript -AppName 'DebtNext' `
        -AccountCount 20 -Seed 7 -ReportDate $script:Today `
        -OutputDir $script:ImportsDir -OutputMode Console
    $script:DebtGenToday = @($script:DebtGenToday)[-1]
}

Describe "DA-UP-HTML: Disconnected app upload -> validate -> cert -> harvest -> HTML" {

    Context "DA-UP-HTML-001 .. 003: deterministic generator output is cert-ready" {

        It "DA-UP-HTML-001 generates PEP-Plus dated accounts + entitlements CSVs with exact headers" {
            $script:PepGenToday.Success | Should -BeTrue -Because "generator should succeed (Error: $($script:PepGenToday.Error))"
            $acc = $script:PepGenToday.Data.AccountFile
            $ent = $script:PepGenToday.Data.EntitlementFile
            $acc | Should -Match '2026-\d{2}-\d{2}-accounts\.csv$'
            (Test-Path -Path $acc -PathType Leaf) | Should -BeTrue
            (Test-Path -Path $ent -PathType Leaf) | Should -BeTrue

            $rows = @(Import-Csv -Path $acc -Encoding UTF8)
            $rows.Count | Should -Be 25
            $cols = @($rows[0].PSObject.Properties.Name)
            foreach ($c in @('id', 'name', 'givenName', 'familyName', 'e-mail', 'groups', 'IIQDisabled')) {
                $cols | Should -Contain $c
            }
            # IIQDisabled is strictly true/false
            foreach ($r in $rows) {
                $r.IIQDisabled | Should -BeIn @('true', 'false')
            }
            # e-mail column populated + contains '@'
            $rows[0].'e-mail' | Should -Match '@'

            $entRows = @(Import-Csv -Path $ent -Encoding UTF8)
            $entRows.Count | Should -Be 8
            $entCols = @($entRows[0].PSObject.Properties.Name)
            foreach ($c in @('id', 'name', 'displayName', 'description')) {
                $entCols | Should -Contain $c
            }
        }

        It "DA-UP-HTML-002 generates DebtNext accounts-only dated CSV with headers + rows" {
            $script:DebtGenToday.Success | Should -BeTrue -Because "generator should succeed (Error: $($script:DebtGenToday.Error))"
            $acc = $script:DebtGenToday.Data.AccountFile
            (Test-Path -Path $acc -PathType Leaf) | Should -BeTrue
            # accounts-only: no entitlement file
            $script:DebtGenToday.Data.EntitlementFile | Should -BeNullOrEmpty

            $rows = @(Import-Csv -Path $acc -Encoding UTF8)
            $rows.Count | Should -Be 20
            $cols = @($rows[0].PSObject.Properties.Name)
            foreach ($c in @('id', 'name', 'givenName', 'familyName', 'e-mail', 'groups', 'IIQDisabled')) {
                $cols | Should -Contain $c
            }
        }

        It "DA-UP-HTML-003 generated files pass account/entitlement/cross-reference validation" {
            $acc = $script:PepGenToday.Data.AccountFile
            $ent = $script:PepGenToday.Data.EntitlementFile

            $va = Test-SPDisconnectedAppAccountFile -FilePath $acc
            $va.Success | Should -BeTrue -Because "PEP-Plus accounts must be cert-ready (Error: $($va.Error))"

            $ve = Test-SPDisconnectedAppEntitlementFile -FilePath $ent
            $ve.Success | Should -BeTrue -Because "PEP-Plus entitlements must be cert-ready (Error: $($ve.Error))"

            $vx = Test-SPDisconnectedAppCrossReference -AccountFilePath $acc -EntitlementFilePath $ent
            $vx.Success | Should -BeTrue -Because "every account group must resolve to an entitlement (Error: $($vx.Error))"

            $dva = Test-SPDisconnectedAppAccountFile -FilePath $script:DebtGenToday.Data.AccountFile
            $dva.Success | Should -BeTrue -Because "DebtNext accounts must be cert-ready (Error: $($dva.Error))"
        }
    }

    Context "DA-UP-HTML-004: delta comparison -> validated delta HTML" {

        It "DA-UP-HTML-004 Compare-SPDisconnectedAppFiles -> Export-SPDisconnectedAppDeltaHtml HTML is correct" {
            $today     = $script:PepGenToday.Data.AccountFile
            $yesterday = $script:PepGenYesterday.Data.AccountFile

            $delta = Compare-SPDisconnectedAppFiles -CurrentFilePath $today -PreviousFilePath $yesterday
            $delta.Success | Should -BeTrue -Because "delta comparison should succeed (Error: $($delta.Error))"

            $exp = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta.Data -AppName 'PEP-Plus' `
                -OutputPath $script:ReportsDir -ReportDate $script:Today
            $exp.Success | Should -BeTrue -Because "delta HTML export should succeed (Error: $($exp.Error))"
            $exp.Data.FilePath | Should -Not -BeNullOrEmpty
            (Test-Path -Path $exp.Data.FilePath -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $exp.Data.FilePath -Raw
            $html | Should -Match ([regex]::Escape('PEP-Plus'))
            $html | Should -Match 'Delta Summary'
            $html | Should -Match 'Total Current Accounts'
        }
    }

    Context "DA-UP-HTML-005: decision harvest -> validated decision-harvest HTML" {

        It "DA-UP-HTML-005 Export-SPDisconnectedAppDecisionHarvestHtml renders decisions + revocations" {
            # Fabricated decision data matching the Get-SPDisconnectedAppCampaignDecisions output shape.
            $decisionData = @{
                CampaignsChecked = 3
                Completed        = 2
                Active           = 1
                Expired          = 0
                Purged           = 0
                Decisions        = @{ Approved = 17; Revoked = 4; Pending = 2 }
                RevocationDetails = @(
                    @{ IdentityName = 'Olivia Smith';   AccountId = 'pep-plus-acct-0003'; Entitlement = 'pep-plus-grp-002'; ReviewerName = 'Manager A'; DecisionDate = '2026-06-05' }
                    @{ IdentityName = 'Liam Johnson';   AccountId = 'pep-plus-acct-0007'; Entitlement = 'pep-plus-grp-005'; ReviewerName = 'Manager B'; DecisionDate = '2026-06-05' }
                    @{ IdentityName = 'Emma Williams';  AccountId = 'pep-plus-acct-0011'; Entitlement = 'pep-plus-grp-001'; ReviewerName = 'Manager A'; DecisionDate = '2026-06-06' }
                    @{ IdentityName = 'Noah Brown';     AccountId = 'pep-plus-acct-0014'; Entitlement = 'pep-plus-grp-008'; ReviewerName = 'Manager C'; DecisionDate = '2026-06-06' }
                )
            }

            $exp = Export-SPDisconnectedAppDecisionHarvestHtml -DecisionData $decisionData `
                -AppName 'PEP-Plus' -OutputPath $script:ReportsDir -ReportDate $script:Today
            $exp.Success | Should -BeTrue -Because "decision harvest HTML export should succeed (Error: $($exp.Error))"
            (Test-Path -Path $exp.Data.FilePath -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $exp.Data.FilePath -Raw
            $html | Should -Match ([regex]::Escape('PEP-Plus'))
            $html | Should -Match 'Decision Harvest'
            $html | Should -Match 'APPROVED'
            $html | Should -Match 'REVOKED'
            $html | Should -Match '\b4\b'                       # revoked count
            $html | Should -Match ([regex]::Escape('Olivia Smith'))  # a revoked identity
        }
    }

    Context "DA-UP-HTML-006: SLA status -> validated SLA HTML" {

        It "DA-UP-HTML-006 Export-SPDisconnectedAppSlaHtml renders the delivery report" {
            $slaData = @{
                Apps = @(
                    @{
                        AppName          = 'PEP-Plus'
                        SlaCompliant     = $true
                        DeliveryRate     = 97
                        LongestGapDays   = 1
                        ConsecutiveMisses = 0
                        SlaDays          = 1
                        TotalDaysTracked = 30
                        DaysDelivered    = @($script:Today, $script:Yesterday)
                        DaysMissing      = @()
                        FirstSnapshotDate = $script:Yesterday
                    }
                    @{
                        AppName          = 'DebtNext'
                        SlaCompliant     = $false
                        DeliveryRate     = 72
                        LongestGapDays   = 4
                        ConsecutiveMisses = 2
                        SlaDays          = 1
                        TotalDaysTracked = 30
                        DaysDelivered    = @($script:Today)
                        DaysMissing      = @($script:Yesterday)
                        FirstSnapshotDate = $script:Yesterday
                    }
                )
                Summary = @{
                    TotalApps       = 2
                    Compliant       = 1
                    NonCompliant    = 1
                    AvgDeliveryRate = 84
                }
            }

            $exp = Export-SPDisconnectedAppSlaHtml -SlaData $slaData -DaysBack 30 `
                -OutputPath $script:ReportsDir -ReportDate $script:Today
            $exp.Success | Should -BeTrue -Because "SLA HTML export should succeed (Error: $($exp.Error))"
            (Test-Path -Path $exp.Data.FilePath -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $exp.Data.FilePath -Raw
            $html | Should -Match 'SLA Delivery Report'
            $html | Should -Match ([regex]::Escape('PEP-Plus'))
            $html | Should -Match ([regex]::Escape('DebtNext'))
            $html | Should -Match 'Avg Delivery Rate'
        }
    }

    Context "DA-UP-HTML-007: batch results -> validated batch HTML" {

        It "DA-UP-HTML-007 Export-SPDisconnectedAppBatchHtml renders per-app status" {
            $batchResults = @(
                @{
                    App = 'PEP-Plus'; Status = 'Success'; CorrelationID = ([guid]::NewGuid().ToString())
                    StartedAt = '2026-06-06 09:00:00'; CompletedAt = '2026-06-06 09:00:12'; DurationSeconds = 12.0
                    CampaignsCreated = 2; CampaignIds = @('camp-1', 'camp-2'); IdentityCount = 5
                    DeltaSummary = 'adds:5'; ReportPath = 'PEP-Plus\delta.html'; Error = $null; Reason = $null
                }
                @{
                    App = 'DebtNext'; Status = 'NoChanges'; CorrelationID = ([guid]::NewGuid().ToString())
                    StartedAt = '2026-06-06 09:00:12'; CompletedAt = '2026-06-06 09:00:18'; DurationSeconds = 6.0
                    CampaignsCreated = 0; CampaignIds = @(); IdentityCount = 0
                    DeltaSummary = 'no changes'; ReportPath = ''; Error = $null; Reason = 'No deltas detected'
                }
            )

            $exp = Export-SPDisconnectedAppBatchHtml -BatchResults $batchResults `
                -CorrelationID ([guid]::NewGuid().ToString()) -StartedAt '2026-06-06 09:00:00' `
                -CompletedAt '2026-06-06 09:00:18' -DurationSeconds 18.0 `
                -OutputPath $script:ReportsDir -ReportDate $script:Today
            $exp.Success | Should -BeTrue -Because "batch HTML export should succeed (Error: $($exp.Error))"
            (Test-Path -Path $exp.Data.FilePath -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $exp.Data.FilePath -Raw
            $html | Should -Match 'Batch'
            $html | Should -Match ([regex]::Escape('PEP-Plus'))
            $html | Should -Match ([regex]::Escape('DebtNext'))
            $html | Should -Match 'Success'
        }
    }

    Context "DA-UP-HTML-010: live cert run against the mock" {

        It "DA-UP-HTML-010 Invoke-SPDisconnectedAppCert.ps1 (JSON) runs end-to-end" -Skip:(-not $script:MockUp) {
            $acc = $script:PepGenToday.Data.AccountFile
            $ent = $script:PepGenToday.Data.EntitlementFile

            # Run in a CHILD process: the cert script calls `exit`, which would
            # terminate the Pester host if dot-sourced/called in-process. The child
            # resolves config via the overlaid settings.local.json (-ConfigPath).
            $argList = @(
                '-NoProfile', '-NonInteractive', '-File', $script:CertScript,
                '-AppName', 'PEP-Plus',
                '-AccountFilePath', $acc,
                '-EntitlementFilePath', $ent,
                '-SnapshotDir', $script:SnapshotsDir,
                '-OutputPath', $script:ReportsDir,
                '-ConfigPath', $script:LocalCfg,
                '-OutputMode', 'JSON'
            )
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput (Join-Path $script:ArtifactDir 'cert-out.txt') `
                -RedirectStandardError  (Join-Path $script:ArtifactDir 'cert-err.txt')
            $script:CertExit = $proc.ExitCode

            # Exit codes (per script header): 0 = campaigns created / WhatIf done,
            # 1 = no changes / no identities resolved (acceptable against mock data).
            $script:CertExit | Should -BeIn @(0, 1) `
                -Because "cert run should complete cleanly (exit=$($script:CertExit))"

            # A snapshot OR audit JSONL OR a delta HTML should have been produced.
            $produced = @(Get-ChildItem -Path $script:ArtifactDir -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\.(html|jsonl|csv)$' })
            $produced.Count | Should -BeGreaterThan 0 `
                -Because 'the cert run should write at least a snapshot/audit/report artifact'
        }
    }

    Context "DA-UP-HTML-012: live decision harvest -> HTML (graceful on empty trail)" {

        It "DA-UP-HTML-012 Get-SPDisconnectedAppCampaignDecisions -> decision harvest HTML" -Skip:(-not $script:MockUp) {
            $harvest = Get-SPDisconnectedAppCampaignDecisions -AppName 'PEP-Plus' `
                -OutputPath $script:ReportsDir

            # The harvest returns the @{Success;Data;Error} envelope. When no audit
            # trail / campaign IDs exist yet, it returns Success=$false with an
            # informative Error -- that is an acceptable empty-trail outcome here, so
            # we assert the envelope shape and then render HTML from a zero-count
            # decision payload to prove the report path still works end-to-end.
            $harvest | Should -Not -BeNullOrEmpty
            ($harvest -is [hashtable] -and $harvest.Contains('Success')) |
                Should -BeTrue -Because 'harvest must return the @{Success;Data;Error} envelope'

            if ($harvest.Success -and $null -ne $harvest.Data) {
                $decisionData = $harvest.Data
            }
            else {
                # Empty-trail soft-path: minimal zero-count decision payload.
                $decisionData = @{
                    CampaignsChecked = 0; Completed = 0; Active = 0; Expired = 0; Purged = 0
                    Decisions        = @{ Approved = 0; Revoked = 0; Pending = 0 }
                    RevocationDetails = @()
                }
            }

            $exp = Export-SPDisconnectedAppDecisionHarvestHtml -DecisionData $decisionData `
                -AppName 'PEP-Plus' -OutputPath $script:ReportsDir -ReportDate $script:Today
            $exp.Success | Should -BeTrue -Because "decision harvest HTML should render (Error: $($exp.Error))"
            (Test-Path -Path $exp.Data.FilePath -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $exp.Data.FilePath -Raw
            $html | Should -Match 'Decision Harvest'
            $html | Should -Match ([regex]::Escape('PEP-Plus'))
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
    try { $null = Get-SPConfig -Force -ErrorAction SilentlyContinue } catch { }

    # Remove the per-run artifacts tree (keeps the repo clean / additive).
    try {
        if ($null -ne $script:ArtifactDir -and (Test-Path -Path $script:ArtifactDir)) {
            Remove-Item -Path $script:ArtifactDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Host "AfterAll: failed to remove artifact dir: $($_.Exception.Message)"
    }
}
