#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Org Chart & Report Distribution features (OC-01 to OC-09)
.DESCRIPTION
    Tests:
        OC-01-T:  Import-SPOrgChartSupplement validates CSV and builds hashtable
        OC-01-T2: Circular reference in supplement detected
        OC-02-T:  Show-SPOrgTree renders ASCII with correct indentation
        OC-03-T:  Campaign org preview shows correct manager-to-identity mapping
        OC-04-T:  Report distribution preview shows correct recipient list
        OC-06-T:  Band classification uses supplement > ISC > depth fallback
        OC-07-T:  Per-band filtering produces correct report subset
        OC-09-T:  Gap detector identifies NoManager and ShallowChain gaps

    Mock scoping:
        OC-01 mocks Write-SPLog in SP.DeltaCertQueries.
        OC-02 uses pure in-memory data (no mocks beyond logging).
        OC-03 mocks Get-SPDeltaIdentityDetail in SP.DeltaCertQueries.
        OC-04 mocks Get-SPConfig in SP.DeltaCertQueries for SMTP status.
        OC-06 uses InModuleScope SP.IdentityService to populate $script:IdentityCache.
        OC-07 mocks Export-SPLeadershipLevelHtml in SP.AuditReport.
        OC-09 mocks Write-SPLog in SP.DeltaCertQueries and uses InModuleScope.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # -----------------------------------------------------------------------
    # Helper: build a mock identity detail result
    # -----------------------------------------------------------------------
    function New-MockIdentityDetail {
        param(
            [string]$IdentityId,
            [string]$DisplayName,
            [string]$ManagerId = '',
            [string]$ManagerName = '',
            [bool]$Found = $true
        )
        return @{
            IdentityId          = $IdentityId
            DisplayName         = $DisplayName
            ManagerId           = $ManagerId
            ManagerName         = $ManagerName
            IsActive            = $true
            Found               = $Found
            CloudLifecycleState = 'active'
        }
    }

    # -----------------------------------------------------------------------
    # Helper: build a mock org tree Data structure
    # Tree: VP -> DirA -> Mgr1 (Alice, Bob), Mgr2 (Carol)
    #            DirB -> Mgr3 (Dave, Eve)
    # -----------------------------------------------------------------------
    function New-MockOrgTreeData {
        return @{
            Nodes = @{
                'id-alice' = @{
                    Identity  = @{ Id = 'id-alice'; Name = 'Alice Johnson'; ManagerId = 'id-mgr1'; ManagerName = 'Mgr One'; Found = $true }
                    ManagerId = 'id-mgr1'
                    Level     = 0
                    Children  = @()
                }
                'id-bob' = @{
                    Identity  = @{ Id = 'id-bob'; Name = 'Bob Smith'; ManagerId = 'id-mgr1'; ManagerName = 'Mgr One'; Found = $true }
                    ManagerId = 'id-mgr1'
                    Level     = 0
                    Children  = @()
                }
                'id-carol' = @{
                    Identity  = @{ Id = 'id-carol'; Name = 'Carol Davis'; ManagerId = 'id-mgr2'; ManagerName = 'Mgr Two'; Found = $true }
                    ManagerId = 'id-mgr2'
                    Level     = 0
                    Children  = @()
                }
                'id-dave' = @{
                    Identity  = @{ Id = 'id-dave'; Name = 'Dave Lee'; ManagerId = 'id-mgr3'; ManagerName = 'Mgr Three'; Found = $true }
                    ManagerId = 'id-mgr3'
                    Level     = 0
                    Children  = @()
                }
                'id-eve' = @{
                    Identity  = @{ Id = 'id-eve'; Name = 'Eve Park'; ManagerId = 'id-mgr3'; ManagerName = 'Mgr Three'; Found = $true }
                    ManagerId = 'id-mgr3'
                    Level     = 0
                    Children  = @()
                }
                'id-mgr1' = @{
                    Identity  = @{ Id = 'id-mgr1'; Name = 'Mgr One'; ManagerId = 'id-dir-a'; ManagerName = 'Director A'; Found = $true }
                    ManagerId = 'id-dir-a'
                    Level     = 1
                    Children  = @('id-alice', 'id-bob')
                }
                'id-mgr2' = @{
                    Identity  = @{ Id = 'id-mgr2'; Name = 'Mgr Two'; ManagerId = 'id-dir-a'; ManagerName = 'Director A'; Found = $true }
                    ManagerId = 'id-dir-a'
                    Level     = 1
                    Children  = @('id-carol')
                }
                'id-mgr3' = @{
                    Identity  = @{ Id = 'id-mgr3'; Name = 'Mgr Three'; ManagerId = 'id-dir-b'; ManagerName = 'Director B'; Found = $true }
                    ManagerId = 'id-dir-b'
                    Level     = 1
                    Children  = @('id-dave', 'id-eve')
                }
                'id-dir-a' = @{
                    Identity  = @{ Id = 'id-dir-a'; Name = 'Director A'; ManagerId = 'id-vp'; ManagerName = 'VP Smith'; Found = $true }
                    ManagerId = 'id-vp'
                    Level     = 2
                    Children  = @('id-mgr1', 'id-mgr2')
                }
                'id-dir-b' = @{
                    Identity  = @{ Id = 'id-dir-b'; Name = 'Director B'; ManagerId = 'id-vp'; ManagerName = 'VP Smith'; Found = $true }
                    ManagerId = 'id-vp'
                    Level     = 2
                    Children  = @('id-mgr3')
                }
                'id-vp' = @{
                    Identity  = @{ Id = 'id-vp'; Name = 'VP Smith'; ManagerId = ''; ManagerName = ''; Found = $true }
                    ManagerId = ''
                    Level     = 3
                    Children  = @('id-dir-a', 'id-dir-b')
                }
            }
            TopLeaders  = @('id-vp')
            Directors   = @('id-dir-a', 'id-dir-b')
            Managers    = @('id-mgr1', 'id-mgr2', 'id-mgr3')
            LevelLabels = @{ 0 = 'Individual Contributors'; 1 = 'Managers'; 2 = 'Directors'; 3 = 'Vice Presidents' }
            LevelNodes  = @{
                1 = @('id-mgr1', 'id-mgr2', 'id-mgr3')
                2 = @('id-dir-a', 'id-dir-b')
                3 = @('id-vp')
            }
            TopLevel    = 3
            LeafCount   = 5
            MaxDepthHit = $false
        }
    }

    # -----------------------------------------------------------------------
    # Helper: build mock leadership data (Levels-based format)
    # -----------------------------------------------------------------------
    function New-MockLeadershipLevelsData {
        return @{
            Levels = @{
                3 = @{
                    Label   = 'Vice Presidents'
                    Leaders = @{
                        'id-vp' = @{
                            Name          = 'VP Smith'
                            TotalItems    = 5
                            Approved      = 3
                            Revoked       = 1
                            Pending       = 1
                            CompletionPct = 80.0
                            Subordinates  = @('id-dir-a', 'id-dir-b')
                        }
                    }
                }
                2 = @{
                    Label   = 'Directors'
                    Leaders = @{
                        'id-dir-a' = @{
                            Name          = 'Director A'
                            TotalItems    = 3
                            Approved      = 2
                            Revoked       = 1
                            Pending       = 0
                            CompletionPct = 100.0
                            Managers      = @{
                                'id-mgr1' = @{ Name = 'Mgr One'; Approved = 2; Revoked = 0; Pending = 0 }
                                'id-mgr2' = @{ Name = 'Mgr Two'; Approved = 0; Revoked = 1; Pending = 0 }
                            }
                        }
                        'id-dir-b' = @{
                            Name          = 'Director B'
                            TotalItems    = 2
                            Approved      = 1
                            Revoked       = 0
                            Pending       = 1
                            CompletionPct = 50.0
                            Managers      = @{
                                'id-mgr3' = @{ Name = 'Mgr Three'; Approved = 1; Revoked = 0; Pending = 1 }
                            }
                        }
                    }
                }
                1 = @{
                    Label   = 'Managers'
                    Leaders = @{
                        'id-mgr1' = @{
                            Name          = 'Mgr One'
                            TotalItems    = 2
                            Approved      = 2
                            Revoked       = 0
                            Pending       = 0
                            CompletionPct = 100.0
                        }
                        'id-mgr2' = @{
                            Name          = 'Mgr Two'
                            TotalItems    = 1
                            Approved      = 0
                            Revoked       = 1
                            Pending       = 0
                            CompletionPct = 100.0
                        }
                        'id-mgr3' = @{
                            Name          = 'Mgr Three'
                            TotalItems    = 2
                            Approved      = 1
                            Revoked       = 0
                            Pending       = 1
                            CompletionPct = 50.0
                        }
                    }
                }
            }
            TopLevel    = 3
            LevelLabels = @{ 0 = 'Individual Contributors'; 1 = 'Managers'; 2 = 'Directors'; 3 = 'Vice Presidents' }
        }
    }
}

# ---------------------------------------------------------------------------
#region OC-01-T: Import-SPOrgChartSupplement validates CSV and builds hashtable
# ---------------------------------------------------------------------------

Describe "OC-01-T: Import-SPOrgChartSupplement validates CSV and builds hashtable" {

    Context "When given a valid supplement CSV" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:csvPath = Join-Path $TestDrive 'valid-supplement.csv'
            @(
                'identityEmail,managerEmail,level,title,band'
                'alice@corp.com,bob@corp.com,IC,Software Engineer,E'
                'bob@corp.com,carol@corp.com,Manager,Engineering Manager,D'
                'carol@corp.com,dan@corp.com,Director,Director of Eng,C'
                'dan@corp.com,,VP,VP of Technology,B'
            ) | Set-Content -Path $script:csvPath -Encoding UTF8

            $script:OC01Result = Import-SPOrgChartSupplement -FilePath $script:csvPath
        }

        It "Should return Success=true" {
            $script:OC01Result.Success | Should -Be $true
        }

        It "Should return 4 entries" {
            $script:OC01Result.Data.Entries.Count | Should -Be 4
        }

        It "Should key entries by lowercase email" {
            $script:OC01Result.Data.Entries.ContainsKey('alice@corp.com') | Should -Be $true
            $script:OC01Result.Data.Entries.ContainsKey('dan@corp.com') | Should -Be $true
        }

        It "Should store correct band values" {
            $script:OC01Result.Data.Entries['alice@corp.com'].Band | Should -Be 'E'
            $script:OC01Result.Data.Entries['carol@corp.com'].Band | Should -Be 'C'
            $script:OC01Result.Data.Entries['dan@corp.com'].Band | Should -Be 'B'
        }

        It "Should set ManagerEmail to null for root entry" {
            $script:OC01Result.Data.Entries['dan@corp.com'].ManagerEmail | Should -BeNullOrEmpty
        }

        It "Should identify alice as a gap (her manager bob references carol, but alice's mgr is in the set)" {
            # alice -> bob -> carol -> dan (all in supplement), so no gaps from chain
            # but dan -> empty manager and that's the root, not a gap
            # Only entries whose manager is NOT in the supplement AND NOT null are gaps
            $script:OC01Result.Data.Gaps.Count | Should -Be 0
        }

        It "Should store title and level correctly" {
            $script:OC01Result.Data.Entries['bob@corp.com'].Title | Should -Be 'Engineering Manager'
            $script:OC01Result.Data.Entries['bob@corp.com'].Level | Should -Be 'Manager'
        }
    }

    Context "When CSV is missing required columns" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:badCsvPath = Join-Path $TestDrive 'bad-columns.csv'
            @(
                'email,manager,title'
                'a@b.com,c@d.com,Engineer'
            ) | Set-Content -Path $script:badCsvPath -Encoding UTF8

            $script:OC01BadColResult = Import-SPOrgChartSupplement -FilePath $script:badCsvPath
        }

        It "Should return Success=false" {
            $script:OC01BadColResult.Success | Should -Be $false
        }

        It "Should report missing columns in error" {
            $script:OC01BadColResult.Error | Should -Match 'missing required columns'
        }
    }

    Context "When CSV file does not exist" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:OC01MissingResult = Import-SPOrgChartSupplement -FilePath (Join-Path $TestDrive 'nonexistent.csv')
        }

        It "Should return Success=false" {
            $script:OC01MissingResult.Success | Should -Be $false
        }

        It "Should report file not found" {
            $script:OC01MissingResult.Error | Should -Match 'not found'
        }
    }

    Context "When CSV has an invalid band value" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:badBandPath = Join-Path $TestDrive 'bad-band.csv'
            @(
                'identityEmail,managerEmail,level,title,band'
                'x@corp.com,,VP,VP,Z'
            ) | Set-Content -Path $script:badBandPath -Encoding UTF8

            $script:OC01BadBandResult = Import-SPOrgChartSupplement -FilePath $script:badBandPath
        }

        It "Should return Success=false" {
            $script:OC01BadBandResult.Success | Should -Be $false
        }

        It "Should report validation error" {
            $script:OC01BadBandResult.Error | Should -Match 'validation error'
        }
    }

    Context "When CSV has entries whose manager is outside the supplement" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:gapCsvPath = Join-Path $TestDrive 'gap-supplement.csv'
            @(
                'identityEmail,managerEmail,level,title,band'
                'leaf@corp.com,external@corp.com,IC,Engineer,E'
                'root@corp.com,,President,CEO,A'
            ) | Set-Content -Path $script:gapCsvPath -Encoding UTF8

            $script:OC01GapResult = Import-SPOrgChartSupplement -FilePath $script:gapCsvPath
        }

        It "Should return Success=true" {
            $script:OC01GapResult.Success | Should -Be $true
        }

        It "Should report 1 gap (leaf whose manager is not in the supplement)" {
            $script:OC01GapResult.Data.Gaps.Count | Should -Be 1
            $script:OC01GapResult.Data.Gaps[0] | Should -Be 'leaf@corp.com'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-01-T2: Circular reference in supplement detected
# ---------------------------------------------------------------------------

Describe "OC-01-T2: Circular reference in supplement detected" {

    Context "When CSV contains a circular manager chain" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:cycleCsvPath = Join-Path $TestDrive 'cycle-supplement.csv'
            @(
                'identityEmail,managerEmail,level,title,band'
                'a@corp.com,b@corp.com,Manager,Mgr A,D'
                'b@corp.com,c@corp.com,Director,Dir B,C'
                'c@corp.com,a@corp.com,VP,VP C,B'
            ) | Set-Content -Path $script:cycleCsvPath -Encoding UTF8

            $script:OC01CycleResult = Import-SPOrgChartSupplement -FilePath $script:cycleCsvPath
        }

        It "Should return Success=false" {
            $script:OC01CycleResult.Success | Should -Be $false
        }

        It "Should report circular reference in error message" {
            $script:OC01CycleResult.Error | Should -Match 'Circular reference detected'
        }

        It "Should identify the revisited node in the error" {
            $script:OC01CycleResult.Error | Should -Match 'chain revisits'
        }
    }

    Context "When CSV has a self-referencing entry" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:selfRefPath = Join-Path $TestDrive 'self-ref.csv'
            @(
                'identityEmail,managerEmail,level,title,band'
                'loop@corp.com,loop@corp.com,Manager,Self Ref,D'
            ) | Set-Content -Path $script:selfRefPath -Encoding UTF8

            $script:OC01SelfResult = Import-SPOrgChartSupplement -FilePath $script:selfRefPath
        }

        It "Should return Success=false" {
            $script:OC01SelfResult.Success | Should -Be $false
        }

        It "Should detect the self-referencing circular reference" {
            $script:OC01SelfResult.Error | Should -Match 'Circular reference detected'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-02-T: Show-SPOrgTree renders ASCII with correct indentation
# ---------------------------------------------------------------------------

Describe "OC-02-T: Show-SPOrgTree renders ASCII with correct indentation" {

    Context "When rendering a 4-level org tree" {
        BeforeAll {
            $script:treeData = New-MockOrgTreeData
            $script:lines = @(Show-SPOrgTree -OrgTree $script:treeData -ShowBands)
            $script:output = $script:lines -join "`n"
        }

        It "Should render the VP as the root node" {
            $script:output | Should -Match 'VP Smith'
        }

        It "Should display band labels when -ShowBands is used" {
            $script:output | Should -Match '\[Band B\]'  # VP at level 3
            $script:output | Should -Match '\[Band C\]'  # Directors at level 2
            $script:output | Should -Match '\[Band E\]'  # ICs at level 0
        }

        It "Should use +-- for child branches" {
            $script:output | Should -Match '\+-- '
        }

        It "Should include a Summary line" {
            # (?m) so ^ matches the start of any line in the joined multi-line output
            # (the Summary/Depth lines are a footer, not the first line).
            $script:output | Should -Match '(?m)^Summary:'
        }

        It "Should include Depth line" {
            $script:output | Should -Match '(?m)^Depth: \d+ levels'
        }

        It "Should count 5 ICs in summary" {
            $script:output | Should -Match '5 ICs'
        }

        It "Should count 1 VP in summary" {
            $script:output | Should -Match '1 VP'
        }
    }

    Context "When -MaxChildrenShown truncates children" {
        BeforeAll {
            # Build a tree with a manager who has 6 direct reports
            $script:bigTree = @{
                Nodes = @{
                    'id-mgr' = @{
                        Identity  = @{ Id = 'id-mgr'; Name = 'Big Manager'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @('id-1','id-2','id-3','id-4','id-5','id-6')
                    }
                }
            }
            for ($i = 1; $i -le 6; $i++) {
                $script:bigTree.Nodes["id-$i"] = @{
                    Identity  = @{ Id = "id-$i"; Name = "Worker $i"; ManagerId = 'id-mgr'; ManagerName = 'Big Manager'; Found = $true }
                    ManagerId = 'id-mgr'
                    Level     = 0
                    Children  = @()
                }
            }

            $script:truncLines = @(Show-SPOrgTree -OrgTree $script:bigTree -MaxChildrenShown 3)
            $script:truncOutput = $script:truncLines -join "`n"
        }

        It "Should show only 3 children plus a truncation indicator" {
            $script:truncOutput | Should -Match '\.\.\. \(3 more\)'
        }
    }

    Context "When -Full shows all children without truncation" {
        BeforeAll {
            $script:fullLines = @(Show-SPOrgTree -OrgTree $script:bigTree -MaxChildrenShown 3 -Full)
            $script:fullOutput = $script:fullLines -join "`n"
        }

        It "Should not show a truncation indicator" {
            $script:fullOutput | Should -Not -Match '\.\.\. \(\d+ more\)'
        }

        It "Should render all 6 children" {
            for ($i = 1; $i -le 6; $i++) {
                $script:fullOutput | Should -Match "Worker $i"
            }
        }
    }

    Context "When given an empty org tree" {
        BeforeAll {
            $script:emptyLines = @(Show-SPOrgTree -OrgTree @{ Nodes = @{} })
            $script:emptyOutput = $script:emptyLines -join "`n"
        }

        It "Should output an empty tree message" {
            $script:emptyOutput | Should -Match 'empty org tree'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-03-T: Campaign org preview shows correct manager-to-identity mapping
# ---------------------------------------------------------------------------

Describe "OC-03-T: Show-SPCampaignOrgPreview maps managers to identities" {

    Context "When given 5 identities under 2 managers under 1 director" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:previewMock = @{
                'id-a1' = New-MockIdentityDetail -IdentityId 'id-a1' -DisplayName 'Alice' -ManagerId 'id-m1' -ManagerName 'Mgr One'
                'id-a2' = New-MockIdentityDetail -IdentityId 'id-a2' -DisplayName 'Bob'   -ManagerId 'id-m1' -ManagerName 'Mgr One'
                'id-a3' = New-MockIdentityDetail -IdentityId 'id-a3' -DisplayName 'Carol' -ManagerId 'id-m2' -ManagerName 'Mgr Two'
                'id-m1' = New-MockIdentityDetail -IdentityId 'id-m1' -DisplayName 'Mgr One' -ManagerId 'id-d1' -ManagerName 'Dir One'
                'id-m2' = New-MockIdentityDetail -IdentityId 'id-m2' -DisplayName 'Mgr Two' -ManagerId 'id-d1' -ManagerName 'Dir One'
                'id-d1' = New-MockIdentityDetail -IdentityId 'id-d1' -DisplayName 'Dir One' -ManagerId '' -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:previewMock.ContainsKey($IdentityId)) {
                    return $script:previewMock[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:previewLines = @(Show-SPCampaignOrgPreview -IdentityIds @('id-a1','id-a2','id-a3') -MaxDepth 3)
            $script:previewOutput = $script:previewLines -join "`n"
        }

        It "Should include Campaign Org Preview header" {
            $script:previewOutput | Should -Match '^Campaign Org Preview --'
        }

        It "Should report 3 identities in the header" {
            $script:previewOutput | Should -Match '3 identities'
        }

        It "Should show Mgr One managing Alice and Bob" {
            $script:previewOutput | Should -Match 'Mgr One'
            $script:previewOutput | Should -Match 'Alice'
            $script:previewOutput | Should -Match 'Bob'
        }

        It "Should show Mgr Two managing Carol" {
            $script:previewOutput | Should -Match 'Mgr Two'
            $script:previewOutput | Should -Match 'Carol'
        }

        It "Should report correct campaign count" {
            $script:previewOutput | Should -Match 'Campaigns that would be created: 2'
        }

        It "Should have no unmanaged identities" {
            $script:previewOutput | Should -Not -Match 'Unmanaged'
        }
    }

    Context "When an identity has no manager" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:unmgdMock = @{
                'id-managed'   = New-MockIdentityDetail -IdentityId 'id-managed'   -DisplayName 'Managed'   -ManagerId 'id-mgr' -ManagerName 'The Mgr'
                'id-unmanaged' = New-MockIdentityDetail -IdentityId 'id-unmanaged' -DisplayName 'Orphan'    -ManagerId '' -ManagerName ''
                'id-mgr'       = New-MockIdentityDetail -IdentityId 'id-mgr'       -DisplayName 'The Mgr'   -ManagerId '' -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:unmgdMock.ContainsKey($IdentityId)) {
                    return $script:unmgdMock[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:unmgdLines = @(Show-SPCampaignOrgPreview -IdentityIds @('id-managed','id-unmanaged') -MaxDepth 3)
            $script:unmgdOutput = $script:unmgdLines -join "`n"
        }

        It "Should list unmanaged identity" {
            $script:unmgdOutput | Should -Match 'Unmanaged \(no campaign\):.*Orphan'
        }

        It "Should report 1 campaign" {
            $script:unmgdOutput | Should -Match 'Campaigns that would be created: 1'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-04-T: Report distribution preview shows correct recipient list
# ---------------------------------------------------------------------------

Describe "OC-04-T: Show-SPReportDistributionPreview shows correct recipients" {

    Context "When given a 3-level org tree with leadership data" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            Mock Get-SPConfig -ModuleName SP.DeltaCertQueries {
                return [PSCustomObject]@{
                    Audit = [PSCustomObject]@{
                        Smtp = [PSCustomObject]@{
                            Enabled = $false
                            Server  = ''
                        }
                    }
                }
            }

            $script:distTree = New-MockOrgTreeData
            $script:distLeadership = New-MockLeadershipLevelsData

            $script:distLines = @(Show-SPReportDistributionPreview `
                -OrgTree $script:distTree `
                -LeadershipData $script:distLeadership)
            $script:distOutput = $script:distLines -join "`n"
        }

        It "Should include Report Distribution Preview header" {
            $script:distOutput | Should -Match 'Report Distribution Preview'
        }

        It "Should include separator line" {
            $script:distOutput | Should -Match '============================'
        }

        It "Should show VP Smith as Executive Summary recipient" {
            $script:distOutput | Should -Match 'Executive Summary \(1 report\)'
            $script:distOutput | Should -Match 'To: VP Smith'
        }

        It "Should show Director A and Director B as Director-level recipients" {
            $script:distOutput | Should -Match 'Directors Reports'
            $script:distOutput | Should -Match 'To: Director A'
            $script:distOutput | Should -Match 'To: Director B'
        }

        It "Should show Manager-level recipients" {
            $script:distOutput | Should -Match 'Managers Reports'
            $script:distOutput | Should -Match 'To: Mgr One'
            $script:distOutput | Should -Match 'To: Mgr Two'
            $script:distOutput | Should -Match 'To: Mgr Three'
        }

        It "Should include total report count" {
            # 1 VP + 2 directors + 3 managers = 6
            $script:distOutput | Should -Match 'Total: 6 reports to 6 recipients'
        }

        It "Should show SMTP status as NOT CONFIGURED" {
            $script:distOutput | Should -Match 'SMTP Status: NOT CONFIGURED'
        }
    }

    Context "When SMTP is configured" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            Mock Get-SPConfig -ModuleName SP.DeltaCertQueries {
                return [PSCustomObject]@{
                    Audit = [PSCustomObject]@{
                        Smtp = [PSCustomObject]@{
                            Enabled = $true
                            Server  = 'smtp.corp.com'
                        }
                    }
                }
            }

            $script:smtpTree = New-MockOrgTreeData
            $script:smtpLeadership = New-MockLeadershipLevelsData

            $script:smtpLines = @(Show-SPReportDistributionPreview `
                -OrgTree $script:smtpTree `
                -LeadershipData $script:smtpLeadership)
            $script:smtpOutput = $script:smtpLines -join "`n"
        }

        It "Should show SMTP as CONFIGURED with server name" {
            $script:smtpOutput | Should -Match 'SMTP Status: CONFIGURED \(Server: smtp\.corp\.com\)'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-06-T: Band classification uses supplement > ISC > depth fallback
# ---------------------------------------------------------------------------

Describe "OC-06-T: Resolve-SPIdentityBand uses correct priority order" {

    Context "When supplement, ISC, and depth sources are all available" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            # Build a small org tree with 3 nodes
            $script:bandTree = @{
                Nodes = @{
                    'id-supp' = @{
                        Identity  = @{ Id = 'id-supp'; Name = 'Supplement User'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @()
                        Email     = 'supp@corp.com'
                    }
                    'id-isc' = @{
                        Identity  = @{ Id = 'id-isc'; Name = 'ISC User'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @()
                    }
                    'id-depth' = @{
                        Identity  = @{ Id = 'id-depth'; Name = 'Depth User'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 2
                        Children  = @()
                    }
                }
            }

            # Supplement provides band for id-supp
            $script:bandSupplement = @{
                'supp@corp.com' = @{ IdentityEmail = 'supp@corp.com'; Band = 'A'; Title = 'President' }
            }

            # Pre-populate IdentityCache for ISC source
            # Pre-populate shared identity cache (SP.IdentityService) for ISC source
            InModuleScope SP.IdentityService {
                $script:IdentityCache['id-supp'] = @{
                    IdentityId  = 'id-supp'
                    Email       = 'supp@corp.com'
                    JobLevel    = 'D'
                    Found       = $true
                    DisplayName = 'Supplement User'
                }
                $script:IdentityCache['id-isc'] = @{
                    IdentityId  = 'id-isc'
                    Email       = 'isc@corp.com'
                    JobLevel    = 'B'
                    Found       = $true
                    DisplayName = 'ISC User'
                }
                # id-depth has no cache entry -- will use depth fallback
            }

            $script:bandResult = Resolve-SPIdentityBand `
                -OrgTree $script:bandTree `
                -Supplement $script:bandSupplement
        }

        AfterAll {
            # Clean up identity cache
            InModuleScope SP.IdentityService {
                $script:IdentityCache.Remove('id-supp')
                $script:IdentityCache.Remove('id-isc')
            }
        }

        It "Should return Success=true" {
            $script:bandResult.Success | Should -Be $true
        }

        It "Should assign band A to id-supp from supplement (overrides ISC D)" {
            $script:bandResult.Data.Bands['id-supp'] | Should -Be 'A'
            $script:bandResult.Data.Sources['id-supp'] | Should -Be 'Supplement'
        }

        It "Should assign band B to id-isc from ISC attribute" {
            $script:bandResult.Data.Bands['id-isc'] | Should -Be 'B'
            $script:bandResult.Data.Sources['id-isc'] | Should -Be 'ISC'
        }

        It "Should assign band C to id-depth from depth fallback (level 2 = C)" {
            $script:bandResult.Data.Bands['id-depth'] | Should -Be 'C'
            $script:bandResult.Data.Sources['id-depth'] | Should -Be 'Depth'
        }

        It "Should populate summary counts correctly" {
            $script:bandResult.Data.Summary['A'] | Should -Be 1
            $script:bandResult.Data.Summary['B'] | Should -Be 1
            $script:bandResult.Data.Summary['C'] | Should -Be 1
        }

        It "Should assign a band to every node (no nulls)" {
            foreach ($nodeId in $script:bandTree.Nodes.Keys) {
                $script:bandResult.Data.Bands[$nodeId] | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "When using custom BandMapping" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:customTree = @{
                Nodes = @{
                    'id-leaf' = @{
                        Identity  = @{ Id = 'id-leaf'; Name = 'Leaf'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 0
                        Children  = @()
                    }
                }
            }

            $script:customResult = Resolve-SPIdentityBand `
                -OrgTree $script:customTree `
                -BandMapping @{ 0 = 'C'; 1 = 'B'; 2 = 'A' }
        }

        It "Should use custom mapping: level 0 = C instead of default E" {
            $script:customResult.Data.Bands['id-leaf'] | Should -Be 'C'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-07-T: Per-band filtering produces correct report subset
# ---------------------------------------------------------------------------

Describe "OC-07-T: Export-SPLeadershipBandHtml filters by band" {

    Context "When TargetBands filters to B and C only" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            # Mock the delegated HTML generator to avoid full HTML rendering
            Mock Export-SPLeadershipLevelHtml -ModuleName SP.AuditReportHtml {
                param($LeadershipData, $Decisions, $OrgTree, $Level, $StartLevel,
                      $LowestLevel, $CampaignName, $DateRange, $OutputPath,
                      $CorrelationID, $DetailLevel, $BandData)
                # Return a fake file path for each level
                $levelLabel = switch ($Level) {
                    3 { 'vp' }
                    2 { 'directors' }
                    1 { 'managers' }
                    default { "level-$Level" }
                }
                return @(Join-Path $OutputPath "$levelLabel-report.html")
            }

            $script:oc07Dir = Join-Path $TestDrive 'oc-07'
            $null = New-Item -ItemType Directory -Path $script:oc07Dir -Force

            $script:oc07Leadership = New-MockLeadershipLevelsData
            $script:oc07OrgTree    = New-MockOrgTreeData
            $script:oc07Decisions  = @{ Approved = @(); Revoked = @(); Pending = @() }

            # Band assignments: VP=B, DirA=C, DirB=C, Mgr1=D, Mgr2=D, Mgr3=D
            $script:oc07BandData = @{
                Bands   = @{
                    'id-vp'    = 'B'
                    'id-dir-a' = 'C'
                    'id-dir-b' = 'C'
                    'id-mgr1'  = 'D'
                    'id-mgr2'  = 'D'
                    'id-mgr3'  = 'D'
                }
                Sources = @{
                    'id-vp'    = 'Depth'
                    'id-dir-a' = 'Depth'
                    'id-dir-b' = 'Depth'
                    'id-mgr1'  = 'Depth'
                    'id-mgr2'  = 'Depth'
                    'id-mgr3'  = 'Depth'
                }
                Summary = @{ A = 0; B = 1; C = 2; D = 3; E = 0 }
            }

            $script:oc07Result = Export-SPLeadershipBandHtml `
                -LeadershipData $script:oc07Leadership `
                -Decisions $script:oc07Decisions `
                -OrgTree $script:oc07OrgTree `
                -BandData $script:oc07BandData `
                -TargetBands @('B', 'C') `
                -CampaignName 'Band Filter Test' `
                -OutputPath $script:oc07Dir
        }

        It "Should return Success=true" {
            $script:oc07Result.Success | Should -Be $true
        }

        It "Should include bands B and C" {
            $script:oc07Result.Data.BandsIncluded | Should -Contain 'B'
            $script:oc07Result.Data.BandsIncluded | Should -Contain 'C'
        }

        It "Should NOT include band D" {
            $script:oc07Result.Data.BandsIncluded | Should -Not -Contain 'D'
        }

        It "Should skip 3 leaders (the D-band managers)" {
            $script:oc07Result.Data.LeadersSkipped | Should -Be 3
        }

        It "Should generate reports (VP + directors levels)" {
            $script:oc07Result.Data.ReportCount | Should -BeGreaterThan 0
        }
    }

    Context "When ExcludeBands removes D and E" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            Mock Export-SPLeadershipLevelHtml -ModuleName SP.AuditReportHtml {
                param($LeadershipData, $Decisions, $OrgTree, $Level, $StartLevel,
                      $LowestLevel, $CampaignName, $DateRange, $OutputPath,
                      $CorrelationID, $DetailLevel, $BandData)
                return @(Join-Path $OutputPath "level-$Level-report.html")
            }

            $script:oc07ExDir = Join-Path $TestDrive 'oc-07-exclude'
            $null = New-Item -ItemType Directory -Path $script:oc07ExDir -Force

            $script:oc07ExResult = Export-SPLeadershipBandHtml `
                -LeadershipData $script:oc07Leadership `
                -Decisions $script:oc07Decisions `
                -OrgTree $script:oc07OrgTree `
                -BandData $script:oc07BandData `
                -ExcludeBands @('D', 'E') `
                -CampaignName 'Exclude Test' `
                -OutputPath $script:oc07ExDir
        }

        It "Should return Success=true" {
            $script:oc07ExResult.Success | Should -Be $true
        }

        It "Should skip D-band leaders" {
            $script:oc07ExResult.Data.LeadersSkipped | Should -Be 3
        }
    }

    Context "When TargetBands and ExcludeBands both exclude all leaders" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:oc07EmptyDir = Join-Path $TestDrive 'oc-07-empty'
            $null = New-Item -ItemType Directory -Path $script:oc07EmptyDir -Force

            # ExcludeBands removes all valid bands
            $script:oc07EmptyResult = Export-SPLeadershipBandHtml `
                -LeadershipData $script:oc07Leadership `
                -Decisions $script:oc07Decisions `
                -OrgTree $script:oc07OrgTree `
                -BandData $script:oc07BandData `
                -ExcludeBands @('A', 'B', 'C', 'D', 'E') `
                -CampaignName 'Empty Test' `
                -OutputPath $script:oc07EmptyDir
        }

        It "Should return Success=false when all bands are excluded" {
            $script:oc07EmptyResult.Success | Should -Be $false
        }

        It "Should report empty band set in error" {
            $script:oc07EmptyResult.Error | Should -Match 'empty set'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region OC-09-T: Gap detector identifies NoManager and ShallowChain gaps
# ---------------------------------------------------------------------------

Describe "OC-09-T: Get-SPOrgChartGaps detects structural gaps" {

    Context "When tree has unmanaged leaves and shallow chains" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            # Pre-populate shared identity cache (SP.IdentityService) with email for managed nodes
            InModuleScope SP.IdentityService {
                $script:IdentityCache['id-mgr-ok'] = @{
                    IdentityId  = 'id-mgr-ok'
                    Email       = 'mgr@corp.com'
                    Found       = $true
                    DisplayName = 'Good Mgr'
                }
                $script:IdentityCache['id-mgr-noemail'] = @{
                    IdentityId  = 'id-mgr-noemail'
                    Email       = ''
                    Found       = $true
                    DisplayName = 'No Email Mgr'
                }
            }

            # Build a tree with gaps:
            # - id-orphan: leaf with no manager (NoManager gap)
            # - id-managed: leaf under id-mgr-ok (no gap)
            # - id-mgr-ok: manager at level 1, no manager above (chain depth 1 < 3 -> ShallowChain)
            #   BUT also has no manager -> OrphanedBranch
            # - id-mgr-noemail: manager at level 1, no email (MissingEmail gap)
            $script:gapTree = @{
                Nodes = @{
                    'id-orphan' = @{
                        Identity  = @{ Id = 'id-orphan'; Name = 'Orphan Leaf'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 0
                        Children  = @()
                    }
                    'id-managed' = @{
                        Identity  = @{ Id = 'id-managed'; Name = 'Managed Leaf'; ManagerId = 'id-mgr-ok'; ManagerName = 'Good Mgr'; Found = $true }
                        ManagerId = 'id-mgr-ok'
                        Level     = 0
                        Children  = @()
                    }
                    'id-mgr-ok' = @{
                        Identity  = @{ Id = 'id-mgr-ok'; Name = 'Good Mgr'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @('id-managed')
                    }
                    'id-mgr-noemail' = @{
                        Identity  = @{ Id = 'id-mgr-noemail'; Name = 'No Email Mgr'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @()
                    }
                }
                TopLeaders = @()
                TopLevel   = 1
                LevelLabels = @{ 0 = 'Individual Contributors'; 1 = 'Managers' }
            }

            $script:gapResult = Get-SPOrgChartGaps -OrgTree $script:gapTree -MinChainDepth 3
        }

        AfterAll {
            InModuleScope SP.IdentityService {
                $script:IdentityCache.Remove('id-mgr-ok')
                $script:IdentityCache.Remove('id-mgr-noemail')
            }
        }

        It "Should return Success=true" {
            $script:gapResult.Success | Should -Be $true
        }

        It "Should detect NoManager gap for orphan leaf" {
            $noMgrGaps = @($script:gapResult.Data.Gaps | Where-Object { $_.Type -eq 'NoManager' })
            $noMgrGaps.Count | Should -BeGreaterOrEqual 1
            $noMgrGaps.IdentityId | Should -Contain 'id-orphan'
        }

        It "Should detect ShallowChain gap (depth 1 < MinChainDepth 3)" {
            $shallowGaps = @($script:gapResult.Data.Gaps | Where-Object { $_.Type -eq 'ShallowChain' })
            $shallowGaps.Count | Should -BeGreaterOrEqual 1
            $shallowGaps[0].Depth | Should -BeLessThan 3
        }

        It "Should detect MissingEmail gap for leader without email" {
            $emailGaps = @($script:gapResult.Data.Gaps | Where-Object { $_.Type -eq 'MissingEmail' })
            $emailGaps.Count | Should -BeGreaterOrEqual 1
            $emailGaps.IdentityId | Should -Contain 'id-mgr-noemail'
        }

        It "Should compute summary with correct total node count" {
            $script:gapResult.Data.Summary.Total | Should -Be 4
        }

        It "Should have a non-zero gap rate" {
            $script:gapResult.Data.Summary.GapRate | Should -BeGreaterThan 0
        }

        It "Should generate recommendations" {
            $script:gapResult.Data.Recommendations.Count | Should -BeGreaterThan 0
        }

        It "Should include NoManager recommendation" {
            $recs = $script:gapResult.Data.Recommendations -join "`n"
            $recs | Should -Match 'no manager'
        }
    }

    Context "When tree has no gaps (complete chain)" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            InModuleScope SP.IdentityService {
                $script:IdentityCache['id-vp-clean'] = @{
                    IdentityId = 'id-vp-clean'; Email = 'vp@corp.com'; Found = $true; DisplayName = 'VP'
                }
                $script:IdentityCache['id-dir-clean'] = @{
                    IdentityId = 'id-dir-clean'; Email = 'dir@corp.com'; Found = $true; DisplayName = 'Dir'
                }
                $script:IdentityCache['id-mgr-clean'] = @{
                    IdentityId = 'id-mgr-clean'; Email = 'mgr@corp.com'; Found = $true; DisplayName = 'Mgr'
                }
            }

            $script:cleanTree = @{
                Nodes = @{
                    'id-leaf-clean' = @{
                        Identity  = @{ Id = 'id-leaf-clean'; Name = 'Leaf'; ManagerId = 'id-mgr-clean'; ManagerName = 'Mgr'; Found = $true }
                        ManagerId = 'id-mgr-clean'
                        Level     = 0
                        Children  = @()
                    }
                    'id-mgr-clean' = @{
                        Identity  = @{ Id = 'id-mgr-clean'; Name = 'Mgr'; ManagerId = 'id-dir-clean'; ManagerName = 'Dir'; Found = $true }
                        ManagerId = 'id-dir-clean'
                        Level     = 1
                        Children  = @('id-leaf-clean')
                    }
                    'id-dir-clean' = @{
                        Identity  = @{ Id = 'id-dir-clean'; Name = 'Dir'; ManagerId = 'id-vp-clean'; ManagerName = 'VP'; Found = $true }
                        ManagerId = 'id-vp-clean'
                        Level     = 2
                        Children  = @('id-mgr-clean')
                    }
                    'id-vp-clean' = @{
                        Identity  = @{ Id = 'id-vp-clean'; Name = 'VP'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 3
                        Children  = @('id-dir-clean')
                    }
                }
                TopLeaders  = @('id-vp-clean')
                TopLevel    = 3
                LevelLabels = @{ 0 = 'Individual Contributors'; 1 = 'Managers'; 2 = 'Directors'; 3 = 'Vice Presidents' }
            }

            $script:cleanResult = Get-SPOrgChartGaps -OrgTree $script:cleanTree -MinChainDepth 3
        }

        AfterAll {
            InModuleScope SP.IdentityService {
                $script:IdentityCache.Remove('id-vp-clean')
                $script:IdentityCache.Remove('id-dir-clean')
                $script:IdentityCache.Remove('id-mgr-clean')
            }
        }

        It "Should return Success=true" {
            $script:cleanResult.Success | Should -Be $true
        }

        It "Should find zero gaps" {
            $script:cleanResult.Data.Gaps.Count | Should -Be 0
        }

        It "Should have GapRate of 0" {
            $script:cleanResult.Data.Summary.GapRate | Should -Be 0.0
        }

        It "Should report all nodes as complete" {
            $script:cleanResult.Data.Summary.Complete | Should -Be 4
            $script:cleanResult.Data.Summary.Gaps | Should -Be 0
        }

        It "Should recommend no gaps" {
            $recs = $script:cleanResult.Data.Recommendations -join "`n"
            $recs | Should -Match 'No gaps detected'
        }
    }

    Context "When tree contains SupplementConflict records" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            InModuleScope SP.IdentityService {
                $script:IdentityCache['id-conflict-node'] = @{
                    IdentityId = 'id-conflict-node'; Email = 'conflict@corp.com'; Found = $true; DisplayName = 'Conflict User'
                }
                $script:IdentityCache['id-conflict-mgr'] = @{
                    IdentityId = 'id-conflict-mgr'; Email = 'mgr-c@corp.com'; Found = $true; DisplayName = 'Conflict Mgr'
                }
            }

            $script:conflictTree = @{
                Nodes = @{
                    'id-conflict-node' = @{
                        Identity  = @{ Id = 'id-conflict-node'; Name = 'Conflict User'; ManagerId = 'id-conflict-mgr'; ManagerName = 'Conflict Mgr'; Found = $true }
                        ManagerId = 'id-conflict-mgr'
                        Level     = 0
                        Children  = @()
                    }
                    'id-conflict-mgr' = @{
                        Identity  = @{ Id = 'id-conflict-mgr'; Name = 'Conflict Mgr'; ManagerId = ''; ManagerName = ''; Found = $true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @('id-conflict-node')
                    }
                }
                TopLeaders = @('id-conflict-mgr')
                TopLevel   = 1
                LevelLabels = @{ 0 = 'Individual Contributors'; 1 = 'Managers' }
                Conflicts = @(
                    @{
                        IdentityEmail = 'conflict@corp.com'
                        NodeId        = 'id-conflict-node'
                        ISCManagerId  = 'id-conflict-mgr'
                        SupplementMgr = 'other-mgr@corp.com'
                        Resolution    = 'ISC wins'
                    }
                )
            }

            $script:conflictResult = Get-SPOrgChartGaps -OrgTree $script:conflictTree
        }

        AfterAll {
            InModuleScope SP.IdentityService {
                $script:IdentityCache.Remove('id-conflict-node')
                $script:IdentityCache.Remove('id-conflict-mgr')
            }
        }

        It "Should detect SupplementConflict gap" {
            $conflictGaps = @($script:conflictResult.Data.Gaps | Where-Object { $_.Type -eq 'SupplementConflict' })
            $conflictGaps.Count | Should -Be 1
        }

        It "Should record ISC wins resolution" {
            $conflictGap = $script:conflictResult.Data.Gaps | Where-Object { $_.Type -eq 'SupplementConflict' }
            $conflictGap.Resolution | Should -Be 'ISC wins'
        }
    }
}

#endregion
