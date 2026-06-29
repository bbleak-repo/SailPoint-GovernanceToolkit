#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for WI-8 last-capture staleness / near-deadline TTL shrink (G5).
.DESCRIPTION
    Covers the opt-in (default-OFF) deadline-aware ACTIVE-cache TTL shrink helper
    Get-SPAuditEffectiveCacheTtl and its wire-in to Get-SPCachedCampaignItems.

    Direct-helper cases (ST-001..ST-007): Get-SPConfig is mocked to return a
    PSCustomObject Audit.NearDeadlineCapture; -Now and a fixed -BaseTtl 180 are injected.
      ST-001 feature disabled / key absent + near deadline -> 180 unchanged.
      ST-002 enabled + deadline beyond WindowMinutes        -> 180.
      ST-003 enabled + deadline inside window               -> nearTtl (15).
      ST-004 enabled + nearTtl > base                       -> base (never raises).
      ST-005 enabled + no/blank/garbage .deadline           -> 180 (graceful).
      ST-006 enabled + deadline already passed              -> shrunk (near-final).
      ST-007 regression-lock: Get-SPAuditActiveCacheTtl -> 180 with no config.
    Wiring case (ST-008): an aged (60m) ACTIVE disk cache near deadline is a MISS
    (re-fetch) when the feature is ENABLED, but a HIT when DISABLED -- proving the
    shrink reaches the disk-TTL check in Get-SPCachedCampaignItems.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

#region ST-001..006 : Get-SPAuditEffectiveCacheTtl direct cases

Describe "SP.CacheStaleness: Get-SPAuditEffectiveCacheTtl (WI-8 / G5)" {

    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AuditQueries { }
        $script:Now = [datetime]'2026-06-27T12:00:00'

        # Helper to build a config PSCustomObject with an Audit.NearDeadlineCapture block.
        function script:New-NdcConfig {
            param([bool]$Enabled = $true, [int]$WindowMinutes = 1440, [int]$TtlMinutes = 15)
            [PSCustomObject]@{
                Audit = [PSCustomObject]@{
                    NearDeadlineCapture = [PSCustomObject]@{
                        Enabled       = $Enabled
                        WindowMinutes = $WindowMinutes
                        TtlMinutes    = $TtlMinutes
                    }
                }
            }
        }

        # Campaign with a deadline N minutes from $script:Now (string, ISO-8601 round-trip).
        function script:New-DeadlineCampaign {
            param([int]$MinutesFromNow)
            [PSCustomObject]@{
                id       = 'camp-st'
                name     = 'STCampaign'
                status   = 'ACTIVE'
                deadline = $script:Now.AddMinutes($MinutesFromNow).ToString('o')
            }
        }
    }

    It "ST-001a: feature DISABLED + near deadline -> base 180 unchanged" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $false }
        $camp = script:New-DeadlineCampaign -MinutesFromNow 60
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-001b: config key ABSENT + near deadline -> base 180 unchanged" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { [PSCustomObject]@{ Audit = [PSCustomObject]@{ CacheActiveTtlMinutes = 180 } } }
        $camp = script:New-DeadlineCampaign -MinutesFromNow 60
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-002: ENABLED + deadline beyond WindowMinutes -> base 180" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true -WindowMinutes 1440 -TtlMinutes 15 }
        $camp = script:New-DeadlineCampaign -MinutesFromNow 2880   # 2 days out > 24h window
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-003: ENABLED + deadline inside window -> nearTtl 15" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true -WindowMinutes 1440 -TtlMinutes 15 }
        $camp = script:New-DeadlineCampaign -MinutesFromNow 60     # inside 24h window
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 15
    }

    It "ST-004: ENABLED + nearTtl > base -> base (never raises)" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true -WindowMinutes 1440 -TtlMinutes 500 }
        $camp = script:New-DeadlineCampaign -MinutesFromNow 60
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-005a: ENABLED + MISSING .deadline -> base 180 (graceful)" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true }
        $camp = [PSCustomObject]@{ id = 'camp-st'; name = 'STCampaign'; status = 'ACTIVE' }
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-005b: ENABLED + BLANK .deadline -> base 180 (graceful)" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true }
        $camp = [PSCustomObject]@{ id = 'camp-st'; name = 'STCampaign'; status = 'ACTIVE'; deadline = '   ' }
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-005c: ENABLED + GARBAGE .deadline -> base 180 (graceful)" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true }
        $camp = [PSCustomObject]@{ id = 'camp-st'; name = 'STCampaign'; status = 'ACTIVE'; deadline = 'not-a-date' }
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 180
    }

    It "ST-006: ENABLED + deadline already PASSED -> shrunk 15 (near-final)" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries { script:New-NdcConfig -Enabled $true -WindowMinutes 1440 -TtlMinutes 15 }
        $camp = script:New-DeadlineCampaign -MinutesFromNow (-60)   # 1h past deadline
        Get-SPAuditEffectiveCacheTtl -Campaign $camp -BaseTtl 180 -Now $script:Now | Should -Be 15
    }
}

#endregion

#region ST-007 : regression-lock on base helper

Describe "SP.CacheStaleness: Get-SPAuditActiveCacheTtl regression-lock (ST-007)" {

    It "ST-007a: returns 180 when Get-SPConfig THROWS (no config)" {
        Mock Write-SPLog -ModuleName SP.AuditQueries { }
        Mock Get-SPConfig -ModuleName SP.AuditQueries { throw 'no config' }
        # Get-SPAuditActiveCacheTtl is an internal (non-exported) helper -> InModuleScope.
        InModuleScope SP.AuditQueries { Get-SPAuditActiveCacheTtl } | Should -Be 180
    }

    It "ST-007b: returns 180 when config lacks the Audit key" {
        Mock Write-SPLog -ModuleName SP.AuditQueries { }
        Mock Get-SPConfig -ModuleName SP.AuditQueries { [PSCustomObject]@{ Other = 1 } }
        InModuleScope SP.AuditQueries { Get-SPAuditActiveCacheTtl } | Should -Be 180
    }
}

#endregion

#region ST-008 : wiring -- shrink reaches the disk-TTL check

Describe "SP.CacheStaleness: near-deadline shrink wires into Get-SPCachedCampaignItems (ST-008)" {

    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AuditQueries { }
        # On a MISS the items are re-fetched; mock so the cache-miss path runs offline.
        Mock Get-SPAuditCertificationItems -ModuleName SP.AuditQueries {
            return @{
                Success = $true
                Data    = @(
                    [PSCustomObject]@{ id = "$CertificationId-01"; decision = 'APPROVE'; reviewedBy = [PSCustomObject]@{ id = 'id-rv-1'; name = 'Alice Reviewer' } }
                )
                Error   = $null
            }
        }

        # Deadline 60 min out -> inside the default 24h window when the feature is ON.
        $script:ST8Deadline = (Get-Date).AddMinutes(60).ToString('o')
        $script:ST8Certs = @(
            [PSCustomObject]@{
                id           = 'cert-st8-a'
                name         = 'Cert ST8 A'
                campaign     = [PSCustomObject]@{ id = 'camp-st8' }
                phase        = 'ACTIVE'
                reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-1'; name = 'Alice Reviewer'; email = 'alice@corp.test' }
                reassignment = $null
            }
        )
        $script:ST8Campaign = [PSCustomObject]@{ id = 'camp-st8'; name = 'ST8'; status = 'ACTIVE'; deadline = $script:ST8Deadline }
        $script:ST8CacheDir = Join-Path $TestDrive 'cachestale'
        $script:ST8ItemsFile = Join-Path $script:ST8CacheDir 'items-camp-st8.jsonl'
        $script:ST8MetaFile  = Join-Path $script:ST8CacheDir 'items-camp-st8.meta.json'

        # Helper: pre-write an ACTIVE items cache + meta aged ~60 minutes.
        function script:Write-AgedCache {
            if (-not (Test-Path $script:ST8CacheDir)) { New-Item -Path $script:ST8CacheDir -ItemType Directory -Force | Out-Null }
            $wrapped = [PSCustomObject]@{
                Item              = [PSCustomObject]@{ id = 'cert-st8-a-01'; decision = 'APPROVE' }
                CertificationId   = 'cert-st8-a'
                CertificationName = 'Cert ST8 A'
                CampaignName      = 'ST8'
            }
            ($wrapped | ConvertTo-Json -Depth 12 -Compress) | Set-Content $script:ST8ItemsFile -Encoding UTF8
            $meta = [ordered]@{
                CampaignId          = 'camp-st8'
                CampaignName        = 'ST8'
                Status              = 'ACTIVE'
                IsPermanent         = $false
                CapturedWhileActive = $true
                FirstSeenStatus     = 'ACTIVE'
                Unverified          = $false
                CachedAt            = (Get-Date).AddMinutes(-60).ToString('o')
                CertCount           = 1
                ItemCount           = 1
            }
            $meta | ConvertTo-Json | Set-Content $script:ST8MetaFile -Encoding UTF8
        }
    }

    It "ST-008a: aged-60m cache is a HIT when feature DISABLED (base 180 TTL)" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries {
            [PSCustomObject]@{ Audit = [PSCustomObject]@{ NearDeadlineCapture = [PSCustomObject]@{ Enabled = $false } } }
        }
        script:Write-AgedCache
        Clear-SPAuditItemCache -CampaignId 'camp-st8' -MemoryOnly
        $res = Get-SPCachedCampaignItems -Campaign $script:ST8Campaign -CachePath $script:ST8CacheDir -Certifications $script:ST8Certs -TtlMinutes 180
        $res.Success   | Should -Be $true
        $res.FromCache | Should -Be $true
    }

    It "ST-008b: aged-60m cache is a MISS (re-fetch) when feature ENABLED + near deadline" {
        Mock Get-SPConfig -ModuleName SP.AuditQueries {
            [PSCustomObject]@{ Audit = [PSCustomObject]@{ NearDeadlineCapture = [PSCustomObject]@{ Enabled = $true; WindowMinutes = 1440; TtlMinutes = 15 } } }
        }
        script:Write-AgedCache
        Clear-SPAuditItemCache -CampaignId 'camp-st8' -MemoryOnly
        $res = Get-SPCachedCampaignItems -Campaign $script:ST8Campaign -CachePath $script:ST8CacheDir -Certifications $script:ST8Certs -TtlMinutes 180
        $res.Success   | Should -Be $true
        $res.FromCache | Should -Be $false
    }
}

#endregion
