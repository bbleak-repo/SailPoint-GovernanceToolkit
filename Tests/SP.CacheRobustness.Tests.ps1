#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for WI-13 cache-robustness cluster (G9-G12).
.DESCRIPTION
    Covers the four low-severity robustness hardening items:
      G9  - Test-SPAutoApproveMarker: config-driven, case-INSENSITIVE detection of the
            ISC force-sign marker (was a brittle case-sensitive inline string match).
            ConvertTo-SPCanonicalDecision now routes through it.
      G10 - Add-SPItemCacheLines: mutex-guarded, no-BOM append to the item-cache JSONL
            (private SP.AuditQueries helper, exercised via InModuleScope).
      G11 - A COMPLETED fetch returning 0 items writes a sealed-empty meta + empty items
            file so the layer-2 disk check HITs next run instead of re-fetching every run.
      G12 - Get-SPDecisionBucket: null-safe accessor so a malformed/missing audit
            ($audit['Decisions'] = $null) degrades to @() instead of throwing.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

#region G9: idNowAutoApproved resilience (config-driven, case-insensitive)

Describe "CR-G9: ConvertTo-SPCanonicalDecision / Test-SPAutoApproveMarker auto-approve marker" {

    It "Routes APPROVE + 'idNowAutoApproved' justification to Pending (force-sign lie)" {
        ConvertTo-SPCanonicalDecision -Decision 'APPROVE' -Justification 'idNowAutoApproved' | Should -Be 'Pending'
    }

    It "Matches the marker case-INSENSITIVELY (regression guard for the brittle match)" {
        ConvertTo-SPCanonicalDecision -Decision 'APPROVE' -Justification 'IDNOWAUTOAPPROVED' | Should -Be 'Pending'
        ConvertTo-SPCanonicalDecision -Decision 'APPROVE' -Justification 'prefix IdNowAutoApproved suffix' | Should -Be 'Pending'
    }

    It "Leaves a genuine APPROVE with no marker as Approved" {
        ConvertTo-SPCanonicalDecision -Decision 'APPROVE' -Justification 'Looks good, certified' | Should -Be 'Approved'
        ConvertTo-SPCanonicalDecision -Decision 'APPROVE' -Justification '' | Should -Be 'Approved'
    }

    It "Test-SPAutoApproveMarker returns the correct boolean for the default marker list" {
        Test-SPAutoApproveMarker -Justification 'idNowAutoApproved'  | Should -Be $true
        Test-SPAutoApproveMarker -Justification 'IDNOWAUTOAPPROVED'  | Should -Be $true
        Test-SPAutoApproveMarker -Justification 'genuine decision'   | Should -Be $false
        Test-SPAutoApproveMarker -Justification ''                   | Should -Be $false
    }

    Context "When config supplies an extra marker" {
        BeforeEach {
            Mock Get-SPConfig -ModuleName SP.AuditReportCore {
                [PSCustomObject]@{
                    Audit = [PSCustomObject]@{ AutoApproveMarkers = @('idNowAutoApproved', 'vendorAutoSign') }
                }
            }
        }

        It "Honors a config-supplied additional marker (config-extendable without code change)" {
            Test-SPAutoApproveMarker -Justification 'vendorAutoSign'  | Should -Be $true
            Test-SPAutoApproveMarker -Justification 'VENDORAUTOSIGN'  | Should -Be $true
            ConvertTo-SPCanonicalDecision -Decision 'APPROVE' -Justification 'vendorAutoSign' | Should -Be 'Pending'
            # Default marker still honored.
            Test-SPAutoApproveMarker -Justification 'idNowAutoApproved' | Should -Be $true
        }
    }
}

#endregion

#region G10: mutex-guarded, no-BOM item-cache append

Describe "CR-G10: Add-SPItemCacheLines mutex-guarded no-BOM append" {

    It "Appends across two calls preserving all lines, count, and no UTF-8 BOM" {
        $file = Join-Path $TestDrive 'items-g10.jsonl'

        InModuleScope SP.AuditQueries -Parameters @{ File = $file } {
            param($File)
            Add-SPItemCacheLines -Path $File -Content ("{`"a`":1}`r`n{`"b`":2}`r`n")
            Add-SPItemCacheLines -Path $File -Content ("{`"c`":3}`r`n")
        }

        $lines = @(Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 3
        ($lines -join '|') | Should -Match 'a.*b.*c'

        # First three bytes must NOT be a UTF-8 BOM (0xEF 0xBB 0xBF).
        $bytes = Get-Content -Path $file -Encoding Byte -TotalCount 3
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
    }
}

#endregion

#region G11: COMPLETED 0-item fetch seals empty meta (not re-fetched)

Describe "CR-G11: COMPLETED 0-item fetch writes sealed-empty meta" {

    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AuditQueries { }
        # Every cert returns Success with ZERO items -> $allItems stays empty.
        Mock Get-SPAuditCertificationItems -ModuleName SP.AuditQueries {
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $script:G11Certs = @(
            [PSCustomObject]@{
                id           = 'cert-empty-a'
                name         = 'Cert Empty A'
                campaign     = [PSCustomObject]@{ id = 'camp-empty-001' }
                phase        = 'SIGNED'
                reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-e1'; name = 'Empty Reviewer'; email = 'e1@corp.test' }
                reassignment = $null
            }
        )
        $script:G11CacheDir   = Join-Path $TestDrive 'g11cache'
        $script:G11MetaFile   = Join-Path $script:G11CacheDir 'items-camp-empty-001.meta.json'
        $script:G11ItemsFile  = Join-Path $script:G11CacheDir 'items-camp-empty-001.jsonl'
        $script:G11Completed  = [PSCustomObject]@{ id = 'camp-empty-001'; name = 'EmptyCompleted'; status = 'COMPLETED' }
    }

    It "Writes a sealed-empty meta (ItemCount=0, IsPermanent=true) + empty items file" {
        $r = Get-SPCachedCampaignItems -Campaign $script:G11Completed -CachePath $script:G11CacheDir -Certifications $script:G11Certs
        $r.Success   | Should -Be $true
        $r.ItemCount | Should -Be 0

        Test-Path $script:G11MetaFile  | Should -Be $true
        Test-Path $script:G11ItemsFile | Should -Be $true
        $meta = Get-Content $script:G11MetaFile -Raw | ConvertFrom-Json
        $meta.ItemCount   | Should -Be 0
        $meta.IsPermanent | Should -Be $true
    }

    It "Is NOT re-fetched on the next run -- disk layer-2 HITs (Get-SPAuditCertificationItems invoked once total)" {
        # Self-contained: a unique campaign id + cache dir so a prior It's memory/disk cache
        # cannot pre-satisfy the first fetch (the module-scope mem cache persists across Its).
        $cacheDir = Join-Path $TestDrive 'g11cache-2'
        $camp     = [PSCustomObject]@{ id = 'camp-empty-002'; name = 'EmptyCompleted2'; status = 'COMPLETED' }
        $certs    = @(
            [PSCustomObject]@{
                id           = 'cert-empty2-a'
                name         = 'Cert Empty2 A'
                campaign     = [PSCustomObject]@{ id = 'camp-empty-002' }
                phase        = 'SIGNED'
                reviewer     = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-rv-e2'; name = 'Empty Reviewer 2'; email = 'e2@corp.test' }
                reassignment = $null
            }
        )
        Clear-SPAuditItemCache -CampaignId 'camp-empty-002' -MemoryOnly

        # First run: cache miss -> fetch -> seal empty.
        $null = Get-SPCachedCampaignItems -Campaign $camp -CachePath $cacheDir -Certifications $certs
        # Drop the in-memory layer so the disk layer-2 path is exercised (not the mem early return).
        Clear-SPAuditItemCache -CampaignId 'camp-empty-002' -MemoryOnly
        # Second run: must be a permanent disk HIT, NOT a re-fetch.
        $r2 = Get-SPCachedCampaignItems -Campaign $camp -CachePath $cacheDir -Certifications $certs
        $r2.FromCache | Should -Be $true
        $r2.ItemCount | Should -Be 0

        Should -Invoke Get-SPAuditCertificationItems -ModuleName SP.AuditQueries -Times 1 -Exactly
    }
}

#endregion

#region G12: null-safe decision-bucket accessor

Describe "CR-G12: Get-SPDecisionBucket null-safe accessor" {

    It "Returns @() for an empty audit (no Decisions key)" {
        $b = Get-SPDecisionBucket -Audit @{} -Name 'Pending'
        @($b).Count | Should -Be 0
    }

    It "Returns @() without throwing when Decisions is null" {
        { Get-SPDecisionBucket -Audit @{ Decisions = $null } -Name 'Pending' } | Should -Not -Throw
        @(Get-SPDecisionBucket -Audit @{ Decisions = $null } -Name 'Pending').Count | Should -Be 0
    }

    It "Returns @() without throwing for a null audit" {
        { Get-SPDecisionBucket -Audit $null -Name 'Pending' } | Should -Not -Throw
        @(Get-SPDecisionBucket -Audit $null -Name 'Pending').Count | Should -Be 0
    }

    It "Returns the bucket contents when present (hashtable Decisions)" {
        $b = Get-SPDecisionBucket -Audit @{ Decisions = @{ Pending = @(1, 2) } } -Name 'Pending'
        @($b).Count | Should -Be 2
    }

    It "Returns @() for a missing named bucket" {
        @(Get-SPDecisionBucket -Audit @{ Decisions = @{ Approved = @(1) } } -Name 'Pending').Count | Should -Be 0
    }
}

#endregion
