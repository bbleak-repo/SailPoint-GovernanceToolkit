<#
.SYNOPSIS
    Tests for the V7 reconciliation guard and schemaVersion suspect gate
    (docs/BUG-V7-REVOKED-GAP-20260710.md).

    DV7R-01: legacy suspect-shaped records are KEPT and totals reconcile
    DV7R-02: schemaVersion=2 records are never flagged suspect
    DV7R-03: the reconciliation guard FIRES when a same-day sibling campaign is dropped
    DV7R-04: first-approval engine fields (V4f) -- date/campaign set, auto-approve never counts
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    $script:ToolkitRoot = Split-Path $PSScriptRoot -Parent
    $script:V7Path = Join-Path $script:ToolkitRoot 'Scripts\Invoke-SPDailyEvidenceReportV7.ps1'

    function New-DV7Record {
        param([string]$Date, [string]$CampId, [int]$Revoked, [int]$Pending, [int]$SchemaVersion = 0)
        $appr = 200 - $Revoked - $Pending
        $comp = if ($Pending -eq 0) { 100 } else { [math]::Round((($appr + $Revoked) / 200) * 100, 1) }
        $o = [ordered]@{}
        if ($SchemaVersion -gt 0) { $o['schemaVersion'] = $SchemaVersion }
        $o['captureDate']      = $Date
        $o['captureTimestamp'] = "${Date}T18:00:00Z"
        $o['correlationId']    = 'test'
        $o['campaign'] = [ordered]@{ id = $CampId; name = "Daily Attestation - $Date"; status = 'COMPLETED'
                                     created = "${Date}T06:00:00Z"; deadline = ''; completed = '2026-06-30T23:00:00Z' }
        $o['summary']  = [ordered]@{ totalItems = 200; approved = $appr; revoked = $Revoked; pending = $Pending
                                     completionPct = $comp; completionPctByReviewer = $comp
                                     reviewersTotal = 10; reviewersSigned = 10; reviewersNotStarted = 0; reviewersInProgress = 0
                                     privilegedTotal = 10; privilegedApproved = 9; privilegedRevoked = 1; privilegedPending = 0
                                     distinctIdentities = 150; distinctSources = 2 }
        $o['reviewers'] = @(); $o['sources'] = @(); $o['diff'] = [ordered]@{ newlyApprovedCount = 0; newlyDecidedCount = 0 }
        return ($o | ConvertTo-Json -Depth 6 -Compress)
    }

    function Invoke-DV7 {
        param([string]$MetricsDir, [string]$OutDir)
        # V7 resolves Metrics.Path via Get-SPConfig -- run it in a child process with a
        # scoped settings.local.json is heavy; instead run V7 with mocked config is not
        # possible cross-process. Use the local-config override file approach.
        $cfgDir  = Join-Path $script:ToolkitRoot 'Config'
        $localCfg = Join-Path $cfgDir 'settings.local.json'
        $backup = $null
        if (Test-Path $localCfg) { $backup = Get-Content $localCfg -Raw }
        @{
            Api            = @{ BaseUrl = 'https://t.api.identitynow.com/v3' }
            Authentication = @{ Mode = 'ConfigFile'; ConfigFile = @{ TenantUrl = 'https://t.identitynow.com'; OAuthTokenUrl = 'https://t.api.identitynow.com/oauth/token'; ClientId = 't'; ClientSecret = 't' } }
            Metrics        = @{ Path = $MetricsDir }
        } | ConvertTo-Json -Depth 5 | Set-Content $localCfg -Encoding UTF8
        try {
            $console = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:V7Path `
                -StartDate '2026-06-01' -EndDate '2026-06-30' -OutputPath $OutDir 2>&1 | Out-String
        }
        finally {
            if ($null -ne $backup) { Set-Content $localCfg -Value $backup -Encoding UTF8 }
            else { Remove-Item $localCfg -Force -ErrorAction SilentlyContinue }
        }
        return $console
    }
}

Describe 'DV7R-01: legacy suspect-shaped records are kept and reconcile' {
    It 'keeps genuinely-finished COMPLETED days and the displayed totals match the JSONL' {
        $mDir = Join-Path $TestDrive 'dv7r01'
        New-Item -ItemType Directory -Force $mDir | Out-Null
        # 3 legacy records: 2 genuinely finished (suspect signature), 1 with leftovers
        $lines = @(
            (New-DV7Record -Date '2026-06-01' -CampId 'c1' -Revoked 10 -Pending 0),
            (New-DV7Record -Date '2026-06-02' -CampId 'c2' -Revoked 15 -Pending 0),
            (New-DV7Record -Date '2026-06-03' -CampId 'c3' -Revoked 20 -Pending 25)
        )
        Set-Content (Join-Path $mDir 'daily-metrics.jsonl') -Value ($lines -join "`n") -Encoding UTF8

        $console = Invoke-DV7 -MetricsDir $mDir -OutDir (Join-Path $TestDrive 'dv7r01-out')

        $console | Should -Match '3 records -> 3 calendar day\(s\), 2 suspect flagged'
        $console | Should -Match 'Reconciliation OK: displayed totals match in-window JSONL \(approved=530 revoked=45 pending=25\)'
    }
}

Describe 'DV7R-02: schemaVersion=2 records are never flagged suspect' {
    It 'flags 0 suspect for v2-stamped genuinely-finished records' {
        $mDir = Join-Path $TestDrive 'dv7r02'
        New-Item -ItemType Directory -Force $mDir | Out-Null
        $lines = @(
            (New-DV7Record -Date '2026-06-01' -CampId 'c1' -Revoked 10 -Pending 0 -SchemaVersion 2),
            (New-DV7Record -Date '2026-06-02' -CampId 'c2' -Revoked 15 -Pending 0 -SchemaVersion 2)
        )
        Set-Content (Join-Path $mDir 'daily-metrics.jsonl') -Value ($lines -join "`n") -Encoding UTF8

        $console = Invoke-DV7 -MetricsDir $mDir -OutDir (Join-Path $TestDrive 'dv7r02-out')

        $console | Should -Match '2 records -> 2 calendar day\(s\), 0 suspect flagged'
        $console | Should -Match 'Reconciliation OK'
    }
}

Describe 'DV7R-03: reconciliation guard fires on a dropped same-day sibling' {
    It 'prints the delta and names the excluded sibling campaign' {
        $mDir = Join-Path $TestDrive 'dv7r03'
        New-Item -ItemType Directory -Force $mDir | Out-Null
        $lines = @(
            (New-DV7Record -Date '2026-06-01' -CampId 'c1' -Revoked 10 -Pending 5 -SchemaVersion 2),
            (New-DV7Record -Date '2026-06-02' -CampId 'c2' -Revoked 15 -Pending 5 -SchemaVersion 2),
            (New-DV7Record -Date '2026-06-02' -CampId 'c2-sibling' -Revoked 7 -Pending 3 -SchemaVersion 2)
        )
        Set-Content (Join-Path $mDir 'daily-metrics.jsonl') -Value ($lines -join "`n") -Encoding UTF8

        $console = Invoke-DV7 -MetricsDir $mDir -OutDir (Join-Path $TestDrive 'dv7r03-out')

        $console | Should -Match 'RECONCILIATION WARNING'
        $console | Should -Match 'Delta: revoked 7'
        $console | Should -Match 'same-day sibling campaign dropped by one-record-per-day resolution'
    }
}

Describe 'DV7R-04: first-approval engine fields (V4f)' {
    It 'sets FirstGenuineApprovalDate/Campaign from the first GENUINE approval, never an auto-approve' {
        # 3 instances: OI1 auto-approved (masked), OI2 pending, OI3 genuine approve.
        function New-DV7Item {
            param([string]$Decision, [string]$Comment, [string]$DecisionDate)
            [PSCustomObject]@{
                Item = [PSCustomObject]@{
                    id              = 'itm-1'
                    identitySummary = [PSCustomObject]@{ identityId = 'id-u1'; name = 'User One' }
                    access          = [PSCustomObject]@{ id = 'ent-1'; name = 'Finance-RW'; type = 'ENTITLEMENT' }
                    account         = [PSCustomObject]@{ nativeIdentity = 'CN=u1'; sourceId = 'src-1' }
                    decision        = $Decision
                    comments        = $Comment
                    decisionDate    = $DecisionDate
                    reviewedBy      = $null
                }
                CertificationId = 'cert-x'; CertificationName = 'Cert X'; CampaignName = 'C'
            }
        }
        $i1 = @{ OrderIndex = 1; CampaignId = 'c1'; CampaignName = 'Daily - 2026-06-01'; Status = 'COMPLETED'; Unverified = $false
                 PeriodToken = '2026-06-01'; Items = @((New-DV7Item -Decision 'APPROVE' -Comment 'idNowAutoApproved' -DecisionDate '2026-06-01T20:00:00Z')); Roster = @() }
        $i2 = @{ OrderIndex = 2; CampaignId = 'c2'; CampaignName = 'Daily - 2026-06-02'; Status = 'COMPLETED'; Unverified = $false
                 PeriodToken = '2026-06-02'; Items = @((New-DV7Item -Decision $null -Comment '' -DecisionDate '')); Roster = @() }
        $i3 = @{ OrderIndex = 3; CampaignId = 'c3'; CampaignName = 'Daily - 2026-06-03'; Status = 'COMPLETED'; Unverified = $false
                 PeriodToken = '2026-06-03'; Items = @((New-DV7Item -Decision 'APPROVE' -Comment 'looks right' -DecisionDate '2026-06-03T14:30:00Z')); Roster = @() }

        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2, $i3)
        $r.Success | Should -BeTrue
        $rec = @($r.Data.Items)[0]
        # The OI1 auto-approve must NOT register: first GENUINE approval is OI3.
        $rec.FirstGenuineApprovalOrderIndex | Should -Be 3
        $rec.FirstGenuineApprovalCampaign   | Should -Be 'Daily - 2026-06-03'
        $rec.FirstGenuineApprovalDate       | Should -Be '2026-06-03'
    }

    It 'falls back to the instance day when the item has no DecisionDate' {
        function New-DV7Item2 {
            param([string]$Decision)
            [PSCustomObject]@{
                Item = [PSCustomObject]@{
                    id              = 'itm-2'
                    identitySummary = [PSCustomObject]@{ identityId = 'id-u2'; name = 'User Two' }
                    access          = [PSCustomObject]@{ id = 'ent-2'; name = 'HR-RO'; type = 'ENTITLEMENT' }
                    account         = [PSCustomObject]@{ nativeIdentity = 'CN=u2'; sourceId = 'src-1' }
                    decision        = $Decision
                    comments        = ''
                    decisionDate    = ''
                    reviewedBy      = $null
                }
                CertificationId = 'cert-y'; CertificationName = 'Cert Y'; CampaignName = 'C'
            }
        }
        $i1 = @{ OrderIndex = 1; CampaignId = 'c1'; CampaignName = 'Daily - 2026-06-10'; Status = 'COMPLETED'; Unverified = $false
                 PeriodToken = '2026-06-10'; Items = @((New-DV7Item2 -Decision $null)); Roster = @() }
        $i2 = @{ OrderIndex = 2; CampaignId = 'c2'; CampaignName = 'Daily - 2026-06-11'; Status = 'COMPLETED'; Unverified = $false
                 PeriodToken = '2026-06-11'; Items = @((New-DV7Item2 -Decision 'APPROVE')); Roster = @() }

        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rec = @($r.Data.Items)[0]
        $rec.FirstGenuineApprovalOrderIndex | Should -Be 2
        $rec.FirstGenuineApprovalDate       | Should -Be '2026-06-11'   # instance PeriodToken day
    }
}
