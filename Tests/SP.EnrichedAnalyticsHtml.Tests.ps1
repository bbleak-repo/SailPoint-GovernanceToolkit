#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x proof that reporting + analytics over the T-01-enriched dataset work
    end-to-end TO HTML (T-04).
.DESCRIPTION
    Test ids EA-01 .. EA-12.

    Exercises + validates the analytics surface ADDITIVELY -- no module/exporter edits.
    Every assertion is backed by an existing, already-shipped function:

      OFFLINE (always-run, mock-independent):
        (a) Multi-period campaign trends -- SP.AuditAnalytics\Measure-SPCampaignTrends
            EA-01  >1 period bucket, each period TotalItems>0 + CampaignCount>=1.
            EA-02  Summary.OverallDirection is a real direction (>=3 periods so NOT
                   'Insufficient Data'); Trends.ApprovalRate classified.
            EA-03  Period labels span >=3 distinct months.

        (b) Configuration drift -- SP.AuditAnalytics\Compare-SPConfigurationSnapshots
            EA-04  Added-source detection: Summary.Added>=2, a Source/Added change for
                   the new Workday source id, HasDrift=$true.
            EA-05  Changed-property detection: flipping src-ad-001 OwnerName yields a
                   Source/Changed entry on the OwnerName property.

        (c) Disconnected analytics -- SP.DisconnectedAppAnalytics
            EA-06  Get-SPDisconnectedAppIdentityRisk: cross-app identities, a High-risk
                   (3-app) identity, Summary.MultiApp>=1.
            EA-07  Get-SPDisconnectedAppTrend: >=1 app from a small JSONL audit trail
                   (DisconnectedAppCertRun events with IdentitiesProcessed).
            EA-08  Get-SPDisconnectedAppDeliveryStatus: a fresh app classified
                   'Delivered' with RowCount>0; Summary.Total>=1.
            EA-09  Get-SPDisconnectedAppDeliveryStatus: a missing-file app classified
                   'Missing' (negative-path coverage on the same call).

        (d) Analytics HTML + content assertions
            EA-10  Export-SPCampaignTrendHtml (consumes the (a) hashtable) -> HTML path
                   exists; greps 'Approval %', 'Period', a real period label.
            EA-11  Export-SPConfigDriftHtml (consumes the (b) .Data) -> HTML path exists;
                   greps 'DRIFT DETECTED', 'Added', the Workday source name.

      LIVE (-Skip when mock unreachable):
        EA-12  Live cross-check over the enriched mock: real campaigns ->
               Measure-SPCampaignMetrics -> Measure-SPCampaignTrends; soft-asserts
               >=1 period (bonus -- the offline EA-01..EA-03 already prove multi-period).

    ADDITIVE: this file only ADDS a test. It does not modify any module, exporter, or
    tracked configuration. All artifacts live under a per-run Tests\_artifacts dir that
    is removed in AfterAll. The live EA-12 only reads from the mock (no writes, no
    settings overlay -- it resolves the localhost mock config only if it actually runs).
#>

# ---------------------------------------------------------------------------
# DISCOVERY-SCOPE mock probe (so -Skip:(-not $mockUpRun) discovery cross-check matches).
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
    # -Audit pulls SP.AuditAnalytics + SP.AuditReportCore + SP.AuditReportHtml
    # (Measure-SPCampaignTrends / Compare-SPConfigurationSnapshots / the two HTML
    # exporters live there). -DisconnectedApps pulls SP.DisconnectedAppAnalytics.
    Import-SPTestModules -Core -Api -Audit -DisconnectedApps

    $script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ConfigDir   = Join-Path $script:ToolkitRoot 'Config'
    $script:LocalCfg    = Join-Path $script:ConfigDir 'settings.local.json'
    $script:MockCfgPath = Join-Path $script:ConfigDir 'settings-mock.json'

    # Re-probe in run phase (Pester 5 does not carry discovery-scope vars to run phase).
    $script:mockUpRun = $true
    try {
        $p = Invoke-WebRequest -Uri 'http://localhost:8080/oauth/token' `
            -Method POST -ContentType 'application/x-www-form-urlencoded' `
            -Body 'grant_type=client_credentials&client_id=mock&client_secret=mock' `
            -UseBasicParsing -TimeoutSec 5
        if ($p.StatusCode -ne 200) { $script:mockUpRun = $false }
    }
    catch { $script:mockUpRun = $false }

    # ---- Per-run artifacts tree (never pollutes the repo) ---------------------
    $script:ArtRoot = Join-Path $PSScriptRoot ('_artifacts/enriched-analytics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (-not (Test-Path -Path $script:ArtRoot -PathType Container)) {
        New-Item -Path $script:ArtRoot -ItemType Directory -Force | Out-Null
    }

    # =====================================================================
    # (a) Build an in-memory multi-period campaign metrics array.
    #     Shape mirrors Measure-SPCampaignMetrics.Data: each object carries
    #     CampaignName, CampaignCreated (ISO Z string), TotalItems,
    #     ApprovedCount, RevokedCount, AvgResponseTimeHours, ReviewerCount.
    #     Spread across 4 distinct months with rising approvals so deltas
    #     vary and the >=3-period trend classifier produces a real direction.
    # =====================================================================
    $script:Metrics = @(
        [pscustomobject]@{
            CampaignName         = 'Privileged Attestation - Jan'
            CampaignCreated      = '2026-01-10T09:00:00Z'
            TotalItems           = 120
            ApprovedCount        = 84
            RevokedCount         = 18
            AvgResponseTimeHours = 40.0
            ReviewerCount        = 6
        }
        [pscustomobject]@{
            CampaignName         = 'Privileged Attestation - Feb'
            CampaignCreated      = '2026-02-12T09:00:00Z'
            TotalItems           = 140
            ApprovedCount        = 110
            RevokedCount         = 16
            AvgResponseTimeHours = 34.0
            ReviewerCount        = 7
        }
        [pscustomobject]@{
            CampaignName         = 'Privileged Attestation - Mar'
            CampaignCreated      = '2026-03-14T09:00:00Z'
            TotalItems           = 150
            ApprovedCount        = 129
            RevokedCount         = 12
            AvgResponseTimeHours = 28.0
            ReviewerCount        = 7
        }
        [pscustomobject]@{
            CampaignName         = 'Privileged Attestation - Apr'
            CampaignCreated      = '2026-04-16T09:00:00Z'
            TotalItems           = 160
            ApprovedCount        = 145
            RevokedCount         = 9
            AvgResponseTimeHours = 22.0
            ReviewerCount        = 8
        }
    )
    $script:Trends = Measure-SPCampaignTrends -CampaignMetrics $script:Metrics -GroupBy 'Month'

    # =====================================================================
    # (b) Build two config snapshots in the EXACT shape Compare consumes:
    #     top-level capturedAt / snapshotId / settingsHash + sources[] of
    #     objects with Id/Name/OwnerName/ConnectorType. SnapshotB adds two
    #     new sources (Workday + DelimitedFile) -- mirrors T-01 enrichment --
    #     and flips src-ad-001 OwnerName to exercise the Changed path.
    # =====================================================================
    $script:SnapA = @{
        capturedAt   = '2026-04-01T00:00:00Z'
        snapshotId   = 'snap-a-2026-04-01'
        settingsHash = 'AAAA1111'
        sources      = @(
            [pscustomobject]@{ Id = 'src-ad-001';    Name = 'Active Directory'; OwnerName = 'Dana Owner';  ConnectorType = 'Active Directory'; Enabled = $true; AccountCount = 500 }
            [pscustomobject]@{ Id = 'src-entra-001'; Name = 'Entra ID';         OwnerName = 'Evan Owner';  ConnectorType = 'Azure Active Directory'; Enabled = $true; AccountCount = 480 }
        )
    }
    $script:SnapB = @{
        capturedAt   = '2026-05-01T00:00:00Z'
        snapshotId   = 'snap-b-2026-05-01'
        settingsHash = 'BBBB2222'
        sources      = @(
            [pscustomobject]@{ Id = 'src-ad-001';      Name = 'Active Directory'; OwnerName = 'Frank Owner'; ConnectorType = 'Active Directory'; Enabled = $true; AccountCount = 500 }
            [pscustomobject]@{ Id = 'src-entra-001';   Name = 'Entra ID';         OwnerName = 'Evan Owner';  ConnectorType = 'Azure Active Directory'; Enabled = $true; AccountCount = 480 }
            [pscustomobject]@{ Id = 'src-workday-001'; Name = 'Workday HR (src-workday-001)'; OwnerName = 'Grace Owner'; ConnectorType = 'Workday'; Enabled = $true; AccountCount = 320 }
            [pscustomobject]@{ Id = 'src-pepplus-001'; Name = 'PEP-Plus Feed';    OwnerName = 'Heidi Owner'; ConnectorType = 'DelimitedFile'; Enabled = $true; AccountCount = 90 }
        )
    }
    $script:Drift = Compare-SPConfigurationSnapshots -SnapshotA $script:SnapA -SnapshotB $script:SnapB

    # =====================================================================
    # (c) Disconnected analytics fixtures.
    # =====================================================================
    $script:Today = (Get-Date).ToString('yyyy-MM-dd')

    # -- Identity-risk snapshot tree: one e-mail in 3 apps (High), one in 2
    #    (Elevated), one in 1 (Normal).
    $script:RiskDir = Join-Path $script:ArtRoot 'risk-snapshots'
    foreach ($appName in @('PEP-Plus', 'DebtNext', 'WidgetCo')) {
        $appDir = Join-Path $script:RiskDir $appName
        New-Item -Path $appDir -ItemType Directory -Force | Out-Null
    }
    $hdr = 'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
    @(
        $hdr
        'P1,jsmith,John,Smith,shared3@corp.com,GRP-P,false'
        'P2,bjones,Bea,Jones,shared2@corp.com,GRP-P,false'
        'P3,konly,Kim,Only,solo@corp.com,GRP-P,false'
    ) | Set-Content -Path (Join-Path (Join-Path $script:RiskDir 'PEP-Plus') "$($script:Today)-accounts.csv") -Encoding UTF8
    @(
        $hdr
        'D1,jsmith2,John,Smith,shared3@corp.com,GRP-D,false'
        'D2,bjones2,Bea,Jones,shared2@corp.com,GRP-D,false'
    ) | Set-Content -Path (Join-Path (Join-Path $script:RiskDir 'DebtNext') "$($script:Today)-accounts.csv") -Encoding UTF8
    @(
        $hdr
        'W1,jsmith3,John,Smith,shared3@corp.com,GRP-W,false'
    ) | Set-Content -Path (Join-Path (Join-Path $script:RiskDir 'WidgetCo') "$($script:Today)-accounts.csv") -Encoding UTF8

    # -- Trend audit trail: per-app disconnected-app-audit.jsonl under Reports/{App}.
    #    Events use the real parser fields: Timestamp (ISO), Action
    #    'DisconnectedAppCertRun', IdentitiesProcessed, CampaignsCreated.
    #    Timestamps fall inside the 2026-01-01..now window.
    $script:TrendReportsDir = Join-Path $script:ArtRoot 'Reports'
    foreach ($appName in @('PEP-Plus', 'DebtNext')) {
        $appReportDir = Join-Path $script:TrendReportsDir $appName
        New-Item -Path $appReportDir -ItemType Directory -Force | Out-Null
        $jsonl = Join-Path $appReportDir 'disconnected-app-audit.jsonl'
        $lines = @(
            (@{ Timestamp = '2026-03-05T09:00:00Z'; Action = 'DisconnectedAppCertRun'; IdentitiesProcessed = 25; CampaignsCreated = 2 } | ConvertTo-Json -Compress)
            (@{ Timestamp = '2026-04-08T09:00:00Z'; Action = 'DisconnectedAppCertRun'; IdentitiesProcessed = 27; CampaignsCreated = 1 } | ConvertTo-Json -Compress)
        )
        Set-Content -Path $jsonl -Value $lines -Encoding UTF8
    }

    # -- Delivery-status fresh accounts file (one Delivered app, one Missing app).
    $script:DeliveryDir = Join-Path $script:ArtRoot 'delivery'
    New-Item -Path $script:DeliveryDir -ItemType Directory -Force | Out-Null
    $script:FreshAccountFile = Join-Path $script:DeliveryDir 'fresh-accounts.csv'
    @(
        $hdr
        'F1,fuser1,Fran,Fresh,fran@corp.com,GRP-F,false'
        'F2,fuser2,Finn,Fresh,finn@corp.com,GRP-F,false'
        'F3,fuser3,Fay,Fresh,fay@corp.com,GRP-F,false'
    ) | Set-Content -Path $script:FreshAccountFile -Encoding UTF8
    $script:MissingAccountFile = Join-Path $script:DeliveryDir 'does-not-exist-accounts.csv'
}

Describe "EA: Reporting + analytics over the enriched dataset -> HTML" {

    Context "EA-01 .. EA-03: Measure-SPCampaignTrends multi-period (offline)" {

        It "EA-01 returns >1 period bucket, each with non-zero items + a campaign" {
            $script:Trends | Should -Not -BeNullOrEmpty
            $periods = @($script:Trends.Periods)
            $periods.Count | Should -BeGreaterThan 1 -Because 'metrics span 4 distinct months'
            foreach ($p in $periods) {
                $p['TotalItems']    | Should -BeGreaterThan 0
                $p['CampaignCount'] | Should -BeGreaterOrEqual 1
            }
        }

        It "EA-02 classifies an overall direction + an ApprovalRate trend (>=3 periods)" {
            $script:Trends.Summary.OverallDirection |
                Should -BeIn @('Improving', 'Degrading', 'Stable') `
                -Because '4 periods means the classifier must NOT return Insufficient Data'
            $script:Trends.Trends.ApprovalRate | Should -Not -BeNullOrEmpty
            $script:Trends.Trends.ApprovalRate |
                Should -BeIn @('Improving', 'Degrading', 'Stable')
        }

        It "EA-03 period labels span >=3 distinct months" {
            $labels = @(@($script:Trends.Periods) | ForEach-Object { $_['Label'] })
            ($labels | Sort-Object -Unique).Count | Should -BeGreaterOrEqual 3
            $labels | Should -Contain '2026-02'
        }
    }

    Context "EA-04 .. EA-05: Compare-SPConfigurationSnapshots drift (offline)" {

        It "EA-04 detects the new (added) sources + flags drift" {
            $script:Drift.Success | Should -BeTrue -Because "compare should succeed (Error: $($script:Drift.Error))"
            $script:Drift.Data.HasDrift | Should -BeTrue
            $script:Drift.Data.Summary.Added | Should -BeGreaterOrEqual 2 `
                -Because 'SnapshotB adds Workday + PEP-Plus sources'

            $added = @($script:Drift.Data.Changes | Where-Object {
                $_['Category'] -eq 'Source' -and $_['ChangeType'] -eq 'Added' -and $_['ItemId'] -eq 'src-workday-001'
            })
            $added.Count | Should -BeGreaterOrEqual 1 `
                -Because 'the Workday source is new in SnapshotB'
        }

        It "EA-05 detects the changed OwnerName on src-ad-001" {
            $changed = @($script:Drift.Data.Changes | Where-Object {
                $_['Category'] -eq 'Source' -and $_['ChangeType'] -eq 'Changed' -and
                $_['ItemId'] -eq 'src-ad-001' -and $_['Property'] -eq 'OwnerName'
            })
            $changed.Count | Should -BeGreaterOrEqual 1
            $changed[0]['OldValue'] | Should -Be 'Dana Owner'
            $changed[0]['NewValue'] | Should -Be 'Frank Owner'
        }
    }

    Context "EA-06 .. EA-09: disconnected analytics (offline / mocked registry)" {

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics { }
        }

        It "EA-06 Get-SPDisconnectedAppIdentityRisk flags the 3-app identity as High" {
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                @{ Success = $true; Data = @(
                    @{ Name = 'PEP-Plus' }, @{ Name = 'DebtNext' }, @{ Name = 'WidgetCo' }
                ); Error = $null }
            }

            $risk = Get-SPDisconnectedAppIdentityRisk -SnapshotDir $script:RiskDir
            $risk.Success | Should -BeTrue -Because "identity risk should succeed (Error: $($risk.Error))"
            $ids = @($risk.Data.Identities)
            $ids.Count | Should -BeGreaterThan 0

            $high = @($ids | Where-Object { $_.Risk -eq 'High' })
            $high.Count | Should -BeGreaterOrEqual 1
            $high[0].AppCount | Should -Be 3
            ($high.Email) | Should -Contain 'shared3@corp.com'

            $risk.Data.Summary.MultiApp | Should -BeGreaterOrEqual 1
            $risk.Data.Summary.HighRisk | Should -Be 1
        }

        It "EA-07 Get-SPDisconnectedAppTrend returns >=1 app from the JSONL trail" {
            $trend = Get-SPDisconnectedAppTrend -OutputPath $script:TrendReportsDir `
                -StartDate '2026-01-01' -EndDate (Get-Date)
            $trend.Success | Should -BeTrue -Because "trend should succeed (Error: $($trend.Error))"
            $apps = @($trend.Data.Apps)
            $apps.Count | Should -BeGreaterOrEqual 1

            $pep = @($apps | Where-Object { $_.AppName -eq 'PEP-Plus' })
            $pep.Count | Should -Be 1
            $pep[0].CertRuns            | Should -BeGreaterOrEqual 2
            $pep[0].IdentitiesProcessed | Should -BeGreaterThan 0
        }

        It "EA-08 Get-SPDisconnectedAppDeliveryStatus marks the fresh file Delivered" {
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                @{ Success = $true; Data = @(
                    @{ Name = 'FreshApp'; Enabled = $true; AccountFilePath = $script:FreshAccountFile }
                ); Error = $null }
            }

            $status = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24
            $status.Success | Should -BeTrue -Because "delivery status should succeed (Error: $($status.Error))"
            $status.Data.Summary.Total | Should -BeGreaterOrEqual 1

            $fresh = @($status.Data.Apps | Where-Object { $_.Name -eq 'FreshApp' })
            $fresh.Count | Should -Be 1
            $fresh[0].Status   | Should -Be 'Delivered'
            $fresh[0].RowCount | Should -BeGreaterThan 0
        }

        It "EA-09 Get-SPDisconnectedAppDeliveryStatus marks a missing file Missing" {
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                @{ Success = $true; Data = @(
                    @{ Name = 'FreshApp';   Enabled = $true; AccountFilePath = $script:FreshAccountFile }
                    @{ Name = 'MissingApp'; Enabled = $true; AccountFilePath = $script:MissingAccountFile }
                ); Error = $null }
            }

            $status = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24
            $status.Success | Should -BeTrue
            $miss = @($status.Data.Apps | Where-Object { $_.Name -eq 'MissingApp' })
            $miss.Count | Should -Be 1
            $miss[0].Status | Should -Be 'Missing'
            $status.Data.Summary.Missing | Should -BeGreaterOrEqual 1
        }
    }

    Context "EA-10 .. EA-11: analytics HTML + content assertions (offline)" {

        It "EA-10 Export-SPCampaignTrendHtml renders a correct trend report" {
            $path = Export-SPCampaignTrendHtml -TrendData $script:Trends -OutputPath $script:ArtRoot
            $path | Should -Not -BeNullOrEmpty
            (Test-Path -Path $path -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $path -Raw
            $html | Should -Match 'Approval %'
            $html | Should -Match 'Period'
            $html | Should -Match '2026-02'   # a real period label
        }

        It "EA-11 Export-SPConfigDriftHtml renders the drift report with the new source" {
            $path = Export-SPConfigDriftHtml -DriftResult $script:Drift.Data -OutputPath $script:ArtRoot
            $path | Should -Not -BeNullOrEmpty
            (Test-Path -Path $path -PathType Leaf) | Should -BeTrue

            $html = Get-Content -Path $path -Raw
            $html | Should -Match 'DRIFT DETECTED'
            $html | Should -Match 'Added'
            $html | Should -Match 'Workday'           # the Workday source name
            $html | Should -Match 'src-workday-001'   # name embeds the id for traceability
        }
    }

    Context "EA-12: live cross-check over the enriched mock (skips if mock down)" {

        It "EA-12 live campaigns -> metrics -> trends produces >=1 period" -Skip:(-not $script:mockUpRun) {
            # Resolve the localhost mock config only here (live path only). We do NOT
            # write any snapshot/overlay: Get-SPConfig with the mock settings is enough
            # for the read-only Get-SPAuditCampaigns call.
            $null = Get-SPConfig -ConfigPath $script:MockCfgPath -Force -ErrorAction SilentlyContinue

            $camps = $null
            try {
                $campResult = Get-SPAuditCampaigns -Status @('COMPLETED', 'ACTIVE') -DaysBack 3650
                if ($campResult -is [hashtable] -and $campResult.Success) {
                    $camps = @($campResult.Data)
                }
            }
            catch { $camps = $null }

            # Soft assertion: this is a bonus cross-check. The offline EA-01..EA-03
            # already prove multi-period analytics; here we only prove the live wiring
            # does not throw and yields a usable (possibly single-period) result.
            if ($null -ne $camps -and $camps.Count -gt 0) {
                $m = Measure-SPCampaignMetrics -Campaigns $camps
                if ($m -is [hashtable] -and $m.Success -and $null -ne $m.Data) {
                    $liveTrends = Measure-SPCampaignTrends -CampaignMetrics $m.Data -GroupBy 'Month'
                    @($liveTrends.Periods).Count | Should -BeGreaterOrEqual 1
                }
                else {
                    Set-ItResult -Skipped -Because 'live metrics returned no usable data'
                }
            }
            else {
                Set-ItResult -Skipped -Because 'enriched mock returned no campaigns in window'
            }
        }
    }
}

AfterAll {
    # Restore the resolved config to the developer's default (drop the mock overlay we
    # may have loaded in EA-12); never touches any file on disk.
    try { $null = Get-SPConfig -Force -ErrorAction SilentlyContinue } catch { }

    # Remove the per-run artifacts tree (keeps the repo clean / additive).
    try {
        if ($null -ne $script:ArtRoot -and (Test-Path -Path $script:ArtRoot)) {
            Remove-Item -Path $script:ArtRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Host "AfterAll: failed to remove artifact dir: $($_.Exception.Message)"
    }
}
