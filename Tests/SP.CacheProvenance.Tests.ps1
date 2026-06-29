#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for WI-4 cache capture-provenance (G1).
.DESCRIPTION
    Tests: CP-001 / CP-002.
    Covers the WI-4 capture-provenance stamped onto the items meta by
    Get-SPCachedCampaignItems:
      (a) ACTIVE-then-COMPLETED transition  = verified  (CapturedWhileActive,
          FirstSeenStatus preserved, Unverified=$false).
      (b) first-seen-while-COMPLETED        = unverified (no prior ACTIVE snapshot,
          Unverified=$true).
    Both contexts share one TestDrive cache dir, so assertions read EXPLICIT meta
    filenames (items-<safeId>.meta.json) keyed by per-context campaign id.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

#region CP-001: ACTIVE-then-COMPLETED transition seals as VERIFIED

Describe "CP-001: ACTIVE->COMPLETED transition stamps verified provenance" {

    Context "When an ACTIVE campaign is cached then re-read as COMPLETED" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            # Items fetch is mocked so the cache-miss path runs without live API.
            # One decided (with reviewedBy) + one bare item so $allItems.Count>0.
            Mock Get-SPAuditCertificationItems -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = "$CertificationId-01"; decision = 'APPROVE'; reviewedBy = [PSCustomObject]@{ id = 'id-rv-1'; name = 'Alice Reviewer' } },
                        [PSCustomObject]@{ id = "$CertificationId-02" }
                    )
                    Error   = $null
                }
            }

            $script:CP001Certs = @(
                [PSCustomObject]@{
                    id           = 'cert-prov-a'
                    name         = 'Cert Prov A'
                    campaign     = [PSCustomObject]@{ id = 'camp-prov-active-001' }
                    phase        = 'ACTIVE'
                    reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-1'; name = 'Alice Reviewer'; email = 'alice@corp.test' }
                    reassignment = $null
                },
                [PSCustomObject]@{
                    id           = 'cert-prov-b'
                    name         = 'Cert Prov B'
                    campaign     = [PSCustomObject]@{ id = 'camp-prov-active-001' }
                    phase        = 'ACTIVE'
                    reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-2'; name = 'Bob Reviewer'; email = 'bob@corp.test' }
                    reassignment = $null
                }
            )

            $script:CP001CacheDir = Join-Path $TestDrive 'cacheprov'
            $script:CP001MetaFile = Join-Path $script:CP001CacheDir 'items-camp-prov-active-001.meta.json'
            $script:CP001Active    = [PSCustomObject]@{ id = 'camp-prov-active-001'; name = 'ProvActive'; status = 'ACTIVE' }
            $script:CP001Completed = [PSCustomObject]@{ id = 'camp-prov-active-001'; name = 'ProvActive'; status = 'COMPLETED' }
        }

        It "Should stamp FirstSeenStatus=ACTIVE / CapturedWhileActive / Unverified=false on first ACTIVE cache" {
            $null = Get-SPCachedCampaignItems -Campaign $script:CP001Active -CachePath $script:CP001CacheDir -Certifications $script:CP001Certs -TtlMinutes 180
            Test-Path $script:CP001MetaFile | Should -Be $true
            $meta = Get-Content $script:CP001MetaFile -Raw | ConvertFrom-Json
            $meta.FirstSeenStatus     | Should -Be 'ACTIVE'
            $meta.CapturedWhileActive | Should -Be $true
            $meta.Unverified          | Should -Be $false
        }

        It "Should keep FirstSeenStatus=ACTIVE / CapturedWhileActive=true / Unverified=false after sealing ACTIVE->COMPLETED" {
            # 1) Cache ACTIVE.
            $null = Get-SPCachedCampaignItems -Campaign $script:CP001Active -CachePath $script:CP001CacheDir -Certifications $script:CP001Certs -TtlMinutes 180
            # 2) Drop the in-memory layer so the disk seal-on-transition path runs (not the
            #    mem-cache early return).
            Clear-SPAuditItemCache -CampaignId 'camp-prov-active-001' -MemoryOnly
            # 3) Re-read the SAME campaign now COMPLETED -- triggers seal-on-transition.
            $null = Get-SPCachedCampaignItems -Campaign $script:CP001Completed -CachePath $script:CP001CacheDir -Certifications $script:CP001Certs -TtlMinutes 180

            $meta = Get-Content $script:CP001MetaFile -Raw | ConvertFrom-Json
            $meta.FirstSeenStatus     | Should -Be 'ACTIVE'
            $meta.CapturedWhileActive | Should -Be $true
            $meta.Unverified          | Should -Be $false
            $meta.IsPermanent         | Should -Be $true
        }
    }
}

#endregion

#region CP-002: first-seen-while-COMPLETED seals as UNVERIFIED

Describe "CP-002: first-seen-COMPLETED stamps unverified provenance" {

    Context "When a never-before-cached COMPLETED campaign is cached" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPAuditCertificationItems -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = "$CertificationId-01"; decision = 'APPROVE'; reviewedBy = [PSCustomObject]@{ id = 'id-rv-9'; name = 'Force Signed' } },
                        [PSCustomObject]@{ id = "$CertificationId-02" }
                    )
                    Error   = $null
                }
            }

            $script:CP002Certs = @(
                [PSCustomObject]@{
                    id           = 'cert-done-a'
                    name         = 'Cert Done A'
                    campaign     = [PSCustomObject]@{ id = 'camp-prov-completed-001' }
                    phase        = 'SIGNED'
                    reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-9'; name = 'Force Signed'; email = 'fs@corp.test' }
                    reassignment = $null
                },
                [PSCustomObject]@{
                    id           = 'cert-done-b'
                    name         = 'Cert Done B'
                    campaign     = [PSCustomObject]@{ id = 'camp-prov-completed-001' }
                    phase        = 'SIGNED'
                    reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-8'; name = 'Auto Approved'; email = 'aa@corp.test' }
                    reassignment = $null
                }
            )

            $script:CP002CacheDir  = Join-Path $TestDrive 'cacheprov'
            $script:CP002MetaFile  = Join-Path $script:CP002CacheDir 'items-camp-prov-completed-001.meta.json'
            $script:CP002Completed = [PSCustomObject]@{ id = 'camp-prov-completed-001'; name = 'ProvCompleted'; status = 'COMPLETED' }
        }

        It "Should stamp FirstSeenStatus=COMPLETED / CapturedWhileActive=false / Unverified=true" {
            $null = Get-SPCachedCampaignItems -Campaign $script:CP002Completed -CachePath $script:CP002CacheDir -Certifications $script:CP002Certs -TtlMinutes 180
            Test-Path $script:CP002MetaFile | Should -Be $true
            $meta = Get-Content $script:CP002MetaFile -Raw | ConvertFrom-Json
            $meta.FirstSeenStatus     | Should -Be 'COMPLETED'
            $meta.CapturedWhileActive | Should -Be $false
            $meta.Unverified          | Should -Be $true
            $meta.IsPermanent         | Should -Be $true
        }
    }
}

#endregion
