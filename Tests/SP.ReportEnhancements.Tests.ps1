#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Report Enhancements (R-01 through R-09)
.DESCRIPTION
    Tests: RE-01 through RE-09
    Covers:
        RE-01: Build-SPOrgTree returns LevelLabels for 4-level org
        RE-02: Group-SPAuditByLeadership groups by all levels (not just 2)
        RE-03: Export-SPLeadershipLevelHtml generates reports at each level
        RE-04: HTML contains <details> tags in Detailed mode, none in Summary mode
        RE-05: Get-SPDeltaReportData returns NewGrants + Revocations
        RE-06: Export-SPDeltaReportHtml generates valid HTML
        RE-07: Measure-SPAuditRubberStampRisk flags bulk-approve pattern
        RE-08: Get-SPAuditRiskFlags returns TERMINATED for terminated identity
        RE-09: Group-SPAuditDecisions includes Justification and RemediationStatus

    Mock scoping:
        RE-01 mocks within SP.DeltaCertQueries.
        RE-02/RE-03/RE-04 mock within SP.AuditReport.
        RE-05 mocks within SP.DeltaCertReport (cross-module and private helpers).
        RE-06 mocks Write-SPLog within SP.DeltaCertReport.
        RE-07/RE-08 are pure computation (only mock Write-SPLog in SP.AuditReport).
        RE-09 mocks Write-SPLog in SP.AuditReport.
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
    # Helper: 4-level org tree data (IC -> Mgr -> Dir -> VP -> President)
    # President -> VP1 -> DirA -> Mgr1 (Alice, Bob), Mgr2 (Carol)
    #                  -> DirB -> Mgr3 (Dave, Eve)
    #           -> VP2 -> DirC -> Mgr4 (Frank)
    # -----------------------------------------------------------------------
    function New-Mock4LevelOrgTreeData {
        return @{
            Nodes = @{
                'id-alice' = @{
                    Identity  = @{ Id = 'id-alice'; Name = 'Alice Johnson'; ManagerId = 'id-mgr1'; ManagerName = 'Mgr One'; Found = $true }
                    ManagerId = 'id-mgr1'; Level = 0; Children = @()
                }
                'id-bob' = @{
                    Identity  = @{ Id = 'id-bob'; Name = 'Bob Smith'; ManagerId = 'id-mgr1'; ManagerName = 'Mgr One'; Found = $true }
                    ManagerId = 'id-mgr1'; Level = 0; Children = @()
                }
                'id-carol' = @{
                    Identity  = @{ Id = 'id-carol'; Name = 'Carol Davis'; ManagerId = 'id-mgr2'; ManagerName = 'Mgr Two'; Found = $true }
                    ManagerId = 'id-mgr2'; Level = 0; Children = @()
                }
                'id-dave' = @{
                    Identity  = @{ Id = 'id-dave'; Name = 'Dave Lee'; ManagerId = 'id-mgr3'; ManagerName = 'Mgr Three'; Found = $true }
                    ManagerId = 'id-mgr3'; Level = 0; Children = @()
                }
                'id-eve' = @{
                    Identity  = @{ Id = 'id-eve'; Name = 'Eve Park'; ManagerId = 'id-mgr3'; ManagerName = 'Mgr Three'; Found = $true }
                    ManagerId = 'id-mgr3'; Level = 0; Children = @()
                }
                'id-frank' = @{
                    Identity  = @{ Id = 'id-frank'; Name = 'Frank Green'; ManagerId = 'id-mgr4'; ManagerName = 'Mgr Four'; Found = $true }
                    ManagerId = 'id-mgr4'; Level = 0; Children = @()
                }
                'id-mgr1' = @{
                    Identity  = @{ Id = 'id-mgr1'; Name = 'Mgr One'; ManagerId = 'id-dir-a'; ManagerName = 'Director A'; Found = $true }
                    ManagerId = 'id-dir-a'; Level = 1; Children = @('id-alice', 'id-bob')
                }
                'id-mgr2' = @{
                    Identity  = @{ Id = 'id-mgr2'; Name = 'Mgr Two'; ManagerId = 'id-dir-a'; ManagerName = 'Director A'; Found = $true }
                    ManagerId = 'id-dir-a'; Level = 1; Children = @('id-carol')
                }
                'id-mgr3' = @{
                    Identity  = @{ Id = 'id-mgr3'; Name = 'Mgr Three'; ManagerId = 'id-dir-b'; ManagerName = 'Director B'; Found = $true }
                    ManagerId = 'id-dir-b'; Level = 1; Children = @('id-dave', 'id-eve')
                }
                'id-mgr4' = @{
                    Identity  = @{ Id = 'id-mgr4'; Name = 'Mgr Four'; ManagerId = 'id-dir-c'; ManagerName = 'Director C'; Found = $true }
                    ManagerId = 'id-dir-c'; Level = 1; Children = @('id-frank')
                }
                'id-dir-a' = @{
                    Identity  = @{ Id = 'id-dir-a'; Name = 'Director A'; ManagerId = 'id-vp1'; ManagerName = 'VP Alpha'; Found = $true }
                    ManagerId = 'id-vp1'; Level = 2; Children = @('id-mgr1', 'id-mgr2')
                }
                'id-dir-b' = @{
                    Identity  = @{ Id = 'id-dir-b'; Name = 'Director B'; ManagerId = 'id-vp1'; ManagerName = 'VP Alpha'; Found = $true }
                    ManagerId = 'id-vp1'; Level = 2; Children = @('id-mgr3')
                }
                'id-dir-c' = @{
                    Identity  = @{ Id = 'id-dir-c'; Name = 'Director C'; ManagerId = 'id-vp2'; ManagerName = 'VP Beta'; Found = $true }
                    ManagerId = 'id-vp2'; Level = 2; Children = @('id-mgr4')
                }
                'id-vp1' = @{
                    Identity  = @{ Id = 'id-vp1'; Name = 'VP Alpha'; ManagerId = 'id-pres'; ManagerName = 'President'; Found = $true }
                    ManagerId = 'id-pres'; Level = 3; Children = @('id-dir-a', 'id-dir-b')
                }
                'id-vp2' = @{
                    Identity  = @{ Id = 'id-vp2'; Name = 'VP Beta'; ManagerId = 'id-pres'; ManagerName = 'President'; Found = $true }
                    ManagerId = 'id-pres'; Level = 3; Children = @('id-dir-c')
                }
                'id-pres' = @{
                    Identity  = @{ Id = 'id-pres'; Name = 'President'; ManagerId = ''; ManagerName = ''; Found = $true }
                    ManagerId = ''; Level = 4; Children = @('id-vp1', 'id-vp2')
                }
            }
            TopLeaders  = @('id-pres')
            Directors   = @('id-dir-a', 'id-dir-b', 'id-dir-c')
            Managers    = @('id-mgr1', 'id-mgr2', 'id-mgr3', 'id-mgr4')
            LevelLabels = @{
                0 = 'Individual Contributors'
                1 = 'Managers'
                2 = 'Directors'
                3 = 'Vice Presidents'
                4 = 'Senior Vice Presidents'
            }
            LevelNodes = @{
                1 = @('id-mgr1', 'id-mgr2', 'id-mgr3', 'id-mgr4')
                2 = @('id-dir-a', 'id-dir-b', 'id-dir-c')
                3 = @('id-vp1', 'id-vp2')
                4 = @('id-pres')
            }
            TopLevel    = 4
            LeafCount   = 6
            MaxDepthHit = $false
        }
    }

    # -----------------------------------------------------------------------
    # Helper: mock decisions for the 4-level org (6 identities)
    # -----------------------------------------------------------------------
    function New-Mock4LevelDecisions {
        return @{
            Approved = @(
                [PSCustomObject]@{ IdentityName = 'Alice Johnson'; AccessName = 'AD_Users';    AccessType = 'Entitlement'; ReviewerName = 'Mgr One';   DecisionDate = '2026-03-15T10:00:00Z'; AccountName = 'ajohnson@corp.com' }
                [PSCustomObject]@{ IdentityName = 'Bob Smith';     AccessName = 'AD_Users';    AccessType = 'Entitlement'; ReviewerName = 'Mgr One';   DecisionDate = '2026-03-15T10:05:00Z'; AccountName = 'bsmith@corp.com' }
                [PSCustomObject]@{ IdentityName = 'Dave Lee';      AccessName = 'VPN_Access';  AccessType = 'Entitlement'; ReviewerName = 'Mgr Three'; DecisionDate = '2026-03-15T11:00:00Z'; AccountName = 'dlee@corp.com' }
                [PSCustomObject]@{ IdentityName = 'Frank Green';   AccessName = 'AD_Users';    AccessType = 'Entitlement'; ReviewerName = 'Mgr Four';  DecisionDate = '2026-03-15T12:00:00Z'; AccountName = 'fgreen@corp.com' }
            )
            Revoked = @(
                [PSCustomObject]@{ IdentityName = 'Carol Davis'; AccessName = 'AD_Admins'; AccessType = 'Entitlement'; ReviewerName = 'Mgr Two'; DecisionDate = '2026-03-15T10:30:00Z'; AccountName = 'cdavis@corp.com' }
            )
            Pending = @(
                [PSCustomObject]@{ IdentityName = 'Eve Park'; AccessName = 'FileShare_RW'; AccessType = 'Entitlement'; ReviewerName = $null; DecisionDate = $null; AccountName = 'epark@corp.com' }
            )
        }
    }

    # -----------------------------------------------------------------------
    # Helper: mock leadership data (from Group-SPAuditByLeadership with Levels)
    # -----------------------------------------------------------------------
    function New-Mock4LevelLeadershipData {
        return @{
            Directors = @{
                'id-dir-a' = @{
                    Name = 'Director A'; Email = ''; TotalItems = 3; Approved = 2; Revoked = 1; Pending = 0; CompletionPct = 100.0
                    Managers = @{
                        'id-mgr1' = @{ Name = 'Mgr One'; Approved = 2; Revoked = 0; Pending = 0; AvgHours = $null }
                        'id-mgr2' = @{ Name = 'Mgr Two'; Approved = 0; Revoked = 1; Pending = 0; AvgHours = $null }
                    }
                }
                'id-dir-b' = @{
                    Name = 'Director B'; Email = ''; TotalItems = 2; Approved = 1; Revoked = 0; Pending = 1; CompletionPct = 50.0
                    Managers = @{
                        'id-mgr3' = @{ Name = 'Mgr Three'; Approved = 1; Revoked = 0; Pending = 1; AvgHours = $null }
                    }
                }
                'id-dir-c' = @{
                    Name = 'Director C'; Email = ''; TotalItems = 1; Approved = 1; Revoked = 0; Pending = 0; CompletionPct = 100.0
                    Managers = @{
                        'id-mgr4' = @{ Name = 'Mgr Four'; Approved = 1; Revoked = 0; Pending = 0; AvgHours = $null }
                    }
                }
            }
            Levels = @{
                2 = @{
                    Label = 'Directors'
                    Leaders = @{
                        'id-dir-a' = @{ Name = 'Director A'; TotalItems = 3; Approved = 2; Revoked = 1; Pending = 0; CompletionPct = 100.0; Managers = @{ 'id-mgr1' = @{ Name = 'Mgr One'; Approved = 2; Revoked = 0; Pending = 0; AvgHours = $null }; 'id-mgr2' = @{ Name = 'Mgr Two'; Approved = 0; Revoked = 1; Pending = 0; AvgHours = $null } } }
                        'id-dir-b' = @{ Name = 'Director B'; TotalItems = 2; Approved = 1; Revoked = 0; Pending = 1; CompletionPct = 50.0; Managers = @{ 'id-mgr3' = @{ Name = 'Mgr Three'; Approved = 1; Revoked = 0; Pending = 1; AvgHours = $null } } }
                        'id-dir-c' = @{ Name = 'Director C'; TotalItems = 1; Approved = 1; Revoked = 0; Pending = 0; CompletionPct = 100.0; Managers = @{ 'id-mgr4' = @{ Name = 'Mgr Four'; Approved = 1; Revoked = 0; Pending = 0; AvgHours = $null } } }
                    }
                }
                3 = @{
                    Label = 'Vice Presidents'
                    Leaders = @{
                        'id-vp1' = @{ Name = 'VP Alpha'; TotalItems = 5; Approved = 3; Revoked = 1; Pending = 1; CompletionPct = 80.0; Subordinates = @('id-dir-a', 'id-dir-b') }
                        'id-vp2' = @{ Name = 'VP Beta';  TotalItems = 1; Approved = 1; Revoked = 0; Pending = 0; CompletionPct = 100.0; Subordinates = @('id-dir-c') }
                    }
                }
                4 = @{
                    Label = 'Senior Vice Presidents'
                    Leaders = @{
                        'id-pres' = @{ Name = 'President'; TotalItems = 6; Approved = 4; Revoked = 1; Pending = 1; CompletionPct = 83.3; Subordinates = @('id-vp1', 'id-vp2') }
                    }
                }
            }
            Executive = @{
                'id-pres' = @{ Name = 'President'; TotalItems = 6; Approved = 4; Revoked = 1; Pending = 1; CompletionPct = 83.3; Directors = @('id-vp1', 'id-vp2') }
            }
            TopLevel = 4
        }
    }

    # -----------------------------------------------------------------------
    # Helper: delta report mock data
    # -----------------------------------------------------------------------
    function New-MockDeltaReportData {
        return @{
            NewGrants = @(
                [PSCustomObject]@{ IdentityId = 'id-001'; IdentityName = 'Alice Johnson'; SourceId = 'src-ad-001'; Entitlement = 'CN=GroupA,OU=Groups,DC=corp,DC=com'; Date = '2026-05-23T08:00:00Z' }
                [PSCustomObject]@{ IdentityId = 'id-002'; IdentityName = 'Bob Smith';     SourceId = 'src-ad-001'; Entitlement = 'CN=GroupB,OU=Groups,DC=corp,DC=com'; Date = '2026-05-23T09:00:00Z' }
            )
            Revocations = @(
                [PSCustomObject]@{ IdentityId = 'id-003'; IdentityName = 'Carol Davis'; SourceId = 'src-ad-001'; ItemName = 'GroupC'; ActivityCreated = '2026-05-23T10:00:00Z' }
            )
            CampaignsCreated = @(
                [PSCustomObject]@{ CampaignId = 'camp-001'; CampaignName = 'AD Delta Cert 2026-05-23 Mgr One'; Status = 'ACTIVE'; Created = '2026-05-23T07:00:00Z' }
            )
            PendingReviews = @(
                [PSCustomObject]@{ CertificationId = 'cert-001'; ReviewerName = 'Mgr One'; CampaignName = 'AD Delta Cert 2026-05-23 Mgr One'; AgeHours = 6 }
            )
            Anomalies = @()
            GeneratedAt = '2026-05-23 12:00:00 UTC'
            HoursBack = 24
            SourceIds = @('src-ad-001')
        }
    }
}

# ---------------------------------------------------------------------------
#region RE-01: Build-SPOrgTree returns LevelLabels for 4-level org
# ---------------------------------------------------------------------------

Describe "RE-01: Build-SPOrgTree returns LevelLabels for 4-level org" {

    Context "When given 6 identities forming a 4-level org tree (IC -> Mgr -> Dir -> VP -> President)" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:re01MockDetails = @{
                'id-alice' = New-MockIdentityDetail -IdentityId 'id-alice' -DisplayName 'Alice'     -ManagerId 'id-mgr1'  -ManagerName 'Mgr One'
                'id-bob'   = New-MockIdentityDetail -IdentityId 'id-bob'   -DisplayName 'Bob'       -ManagerId 'id-mgr1'  -ManagerName 'Mgr One'
                'id-carol' = New-MockIdentityDetail -IdentityId 'id-carol' -DisplayName 'Carol'     -ManagerId 'id-mgr2'  -ManagerName 'Mgr Two'
                'id-dave'  = New-MockIdentityDetail -IdentityId 'id-dave'  -DisplayName 'Dave'      -ManagerId 'id-mgr3'  -ManagerName 'Mgr Three'
                'id-eve'   = New-MockIdentityDetail -IdentityId 'id-eve'   -DisplayName 'Eve'       -ManagerId 'id-mgr3'  -ManagerName 'Mgr Three'
                'id-frank' = New-MockIdentityDetail -IdentityId 'id-frank' -DisplayName 'Frank'     -ManagerId 'id-mgr4'  -ManagerName 'Mgr Four'
                'id-mgr1'  = New-MockIdentityDetail -IdentityId 'id-mgr1'  -DisplayName 'Mgr One'   -ManagerId 'id-dir-a' -ManagerName 'Director A'
                'id-mgr2'  = New-MockIdentityDetail -IdentityId 'id-mgr2'  -DisplayName 'Mgr Two'   -ManagerId 'id-dir-a' -ManagerName 'Director A'
                'id-mgr3'  = New-MockIdentityDetail -IdentityId 'id-mgr3'  -DisplayName 'Mgr Three' -ManagerId 'id-dir-b' -ManagerName 'Director B'
                'id-mgr4'  = New-MockIdentityDetail -IdentityId 'id-mgr4'  -DisplayName 'Mgr Four'  -ManagerId 'id-dir-c' -ManagerName 'Director C'
                'id-dir-a' = New-MockIdentityDetail -IdentityId 'id-dir-a' -DisplayName 'Director A' -ManagerId 'id-vp1'  -ManagerName 'VP Alpha'
                'id-dir-b' = New-MockIdentityDetail -IdentityId 'id-dir-b' -DisplayName 'Director B' -ManagerId 'id-vp1'  -ManagerName 'VP Alpha'
                'id-dir-c' = New-MockIdentityDetail -IdentityId 'id-dir-c' -DisplayName 'Director C' -ManagerId 'id-vp2'  -ManagerName 'VP Beta'
                'id-vp1'   = New-MockIdentityDetail -IdentityId 'id-vp1'   -DisplayName 'VP Alpha'   -ManagerId 'id-pres' -ManagerName 'President'
                'id-vp2'   = New-MockIdentityDetail -IdentityId 'id-vp2'   -DisplayName 'VP Beta'    -ManagerId 'id-pres' -ManagerName 'President'
                'id-pres'  = New-MockIdentityDetail -IdentityId 'id-pres'  -DisplayName 'President'  -ManagerId ''         -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:re01MockDetails.ContainsKey($IdentityId)) {
                    return $script:re01MockDetails[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:RE01Result = Build-SPOrgTree `
                -IdentityIds @('id-alice','id-bob','id-carol','id-dave','id-eve','id-frank') `
                -MaxDepth 5
        }

        It "Should return Success=true" {
            $script:RE01Result.Success | Should -Be $true
        }

        It "Should contain LevelLabels with keys 0 through 4" {
            $labels = $script:RE01Result.Data.LevelLabels
            $labels | Should -Not -BeNullOrEmpty
            $labels.ContainsKey(0) | Should -Be $true
            $labels.ContainsKey(1) | Should -Be $true
            $labels.ContainsKey(2) | Should -Be $true
            $labels.ContainsKey(3) | Should -Be $true
            $labels.ContainsKey(4) | Should -Be $true
        }

        It "Should label Level 0 as Individual Contributors" {
            $script:RE01Result.Data.LevelLabels[0] | Should -Be 'Individual Contributors'
        }

        It "Should label Level 1 as Managers" {
            $script:RE01Result.Data.LevelLabels[1] | Should -Be 'Managers'
        }

        It "Should label Level 2 as Directors" {
            $script:RE01Result.Data.LevelLabels[2] | Should -Be 'Directors'
        }

        It "Should label Level 3 as Vice Presidents" {
            $script:RE01Result.Data.LevelLabels[3] | Should -Be 'Vice Presidents'
        }

        It "Should label Level 4 as Senior Vice Presidents" {
            $script:RE01Result.Data.LevelLabels[4] | Should -Be 'Senior Vice Presidents'
        }

        It "Should report TopLevel = 4" {
            $script:RE01Result.Data.TopLevel | Should -Be 4
        }

        It "Should have LevelNodes with distinct entries for levels 1 through 4" {
            $ln = $script:RE01Result.Data.LevelNodes
            $ln | Should -Not -BeNullOrEmpty
            $ln.ContainsKey(1) | Should -Be $true
            $ln.ContainsKey(2) | Should -Be $true
            $ln.ContainsKey(3) | Should -Be $true
            $ln.ContainsKey(4) | Should -Be $true
        }

        It "Should have 4 managers at level 1" {
            @($script:RE01Result.Data.LevelNodes[1]).Count | Should -Be 4
        }

        It "Should have 3 directors at level 2" {
            @($script:RE01Result.Data.LevelNodes[2]).Count | Should -Be 3
        }

        It "Should have 2 VPs at level 3" {
            @($script:RE01Result.Data.LevelNodes[3]).Count | Should -Be 2
        }

        It "Should have 1 president at level 4" {
            @($script:RE01Result.Data.LevelNodes[4]).Count | Should -Be 1
        }

        It "Should build 16 nodes total (6 leaves + 4 managers + 3 directors + 2 VPs + 1 president)" {
            $script:RE01Result.Data.Nodes.Count | Should -Be 16
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-02: Group-SPAuditByLeadership groups by all levels
# ---------------------------------------------------------------------------

Describe "RE-02: Group-SPAuditByLeadership groups by all levels (not just 2)" {

    Context "When given a 4-level org tree with decisions" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            $script:orgTree4   = New-Mock4LevelOrgTreeData
            $script:decisions4 = New-Mock4LevelDecisions

            $script:RE02Result = Group-SPAuditByLeadership `
                -Decisions $script:decisions4 `
                -OrgTree $script:orgTree4
        }

        It "Should return a Levels hashtable" {
            $script:RE02Result.ContainsKey('Levels') | Should -Be $true
            $script:RE02Result['Levels'] | Should -Not -BeNullOrEmpty
        }

        It "Should have Level 2 (Directors) in the Levels structure" {
            $script:RE02Result['Levels'].ContainsKey(2) | Should -Be $true
            $script:RE02Result['Levels'][2].Label | Should -Be 'Directors'
        }

        It "Should have Level 3 (Vice Presidents) in the Levels structure" {
            $script:RE02Result['Levels'].ContainsKey(3) | Should -Be $true
            $script:RE02Result['Levels'][3].Label | Should -Be 'Vice Presidents'
        }

        It "Should have Level 4 (Senior Vice Presidents) in the Levels structure" {
            $script:RE02Result['Levels'].ContainsKey(4) | Should -Be $true
            $script:RE02Result['Levels'][4].Label | Should -Be 'Senior Vice Presidents'
        }

        It "Should have 3 directors at Level 2" {
            $script:RE02Result['Levels'][2].Leaders.Count | Should -Be 3
        }

        It "Should have 2 VPs at Level 3" {
            $script:RE02Result['Levels'][3].Leaders.Count | Should -Be 2
        }

        It "Should attribute 5 items to VP Alpha (sum of Director A + Director B)" {
            $vp1 = $script:RE02Result['Levels'][3].Leaders['id-vp1']
            $vp1 | Should -Not -BeNullOrEmpty
            $vp1.TotalItems | Should -Be 5
        }

        It "Should attribute 1 item to VP Beta (Director C's total)" {
            $vp2 = $script:RE02Result['Levels'][3].Leaders['id-vp2']
            $vp2 | Should -Not -BeNullOrEmpty
            $vp2.TotalItems | Should -Be 1
        }

        It "Should report TopLevel = 4" {
            $script:RE02Result.TopLevel | Should -Be 4
        }

        It "Should preserve backward-compatible Directors key" {
            $script:RE02Result.ContainsKey('Directors') | Should -Be $true
            $script:RE02Result['Directors'].Count | Should -Be 3
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-03: Export-SPLeadershipLevelHtml generates reports at each level
# ---------------------------------------------------------------------------

Describe "RE-03: Export-SPLeadershipLevelHtml generates reports at each level" {

    Context "When generating Director-level reports for a 4-level org" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:RE03Dir = Join-Path $TestDrive 're-03-level'
            $null = New-Item -ItemType Directory -Path $script:RE03Dir -Force

            $leadershipData = New-Mock4LevelLeadershipData
            $decisions      = New-Mock4LevelDecisions
            $orgTree        = New-Mock4LevelOrgTreeData

            $script:RE03Paths = Export-SPLeadershipLevelHtml `
                -LeadershipData $leadershipData `
                -Decisions $decisions `
                -OrgTree $orgTree `
                -Level 2 `
                -StartLevel 4 `
                -LowestLevel 2 `
                -CampaignName 'Q1 2026 Review' `
                -DateRange '2026-01-01 to 2026-03-31' `
                -OutputPath $script:RE03Dir `
                -CorrelationID 're-03-corr'

            $script:RE03Files = @{}
            foreach ($fp in @($script:RE03Paths)) {
                if (Test-Path $fp) {
                    $name = Split-Path $fp -Leaf
                    $script:RE03Files[$name] = Get-Content -Path $fp -Raw
                }
            }
        }

        It "Should create 3 director HTML files" {
            @($script:RE03Paths).Count | Should -Be 3
        }

        It "Each file should contain valid HTML structure" {
            foreach ($name in $script:RE03Files.Keys) {
                $html = $script:RE03Files[$name]
                $html | Should -Match '<html'
                $html | Should -Match '</html>'
            }
        }

        It "Should include the campaign name in each report" {
            foreach ($name in $script:RE03Files.Keys) {
                $script:RE03Files[$name] | Should -Match 'Q1 2026 Review'
            }
        }

        It "Should use level label in file names" {
            $fileNames = @($script:RE03Files.Keys)
            # File names should include a director-level prefix
            foreach ($fn in $fileNames) {
                $fn | Should -Match '(?i)director'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-04: HTML detail modes (<details> in Detailed, none in Summary)
# ---------------------------------------------------------------------------

Describe "RE-04: HTML uses collapsible detail sections in Detailed mode, none in Summary mode" {

    Context "When generating reports in Detailed mode" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:RE04DetailedDir = Join-Path $TestDrive 're-04-detailed'
            $null = New-Item -ItemType Directory -Path $script:RE04DetailedDir -Force

            $leadershipData = New-Mock4LevelLeadershipData
            $decisions      = New-Mock4LevelDecisions
            $orgTree        = New-Mock4LevelOrgTreeData

            $script:RE04DetailedPaths = Export-SPLeadershipLevelHtml `
                -LeadershipData $leadershipData `
                -Decisions $decisions `
                -OrgTree $orgTree `
                -Level 2 `
                -StartLevel 4 `
                -LowestLevel 2 `
                -CampaignName 'Q1 2026 Review' `
                -OutputPath $script:RE04DetailedDir `
                -CorrelationID 're-04-detailed' `
                -DetailLevel 'Detailed'

            $script:RE04DetailedHtml = ''
            if (@($script:RE04DetailedPaths).Count -gt 0 -and (Test-Path $script:RE04DetailedPaths[0])) {
                $script:RE04DetailedHtml = Get-Content -Path $script:RE04DetailedPaths[0] -Raw
            }
        }

        It "Should contain detail-disclosure tags in Detailed mode" {
            $script:RE04DetailedHtml | Should -Match '<details'
        }

        It "Should auto-expand revocations with an open detail section" {
            # Revocation sections should be auto-expanded
            $script:RE04DetailedHtml | Should -Match '<details open'
        }
    }

    Context "When generating reports in Summary mode" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:RE04SummaryDir = Join-Path $TestDrive 're-04-summary'
            $null = New-Item -ItemType Directory -Path $script:RE04SummaryDir -Force

            $leadershipData = New-Mock4LevelLeadershipData
            $decisions      = New-Mock4LevelDecisions
            $orgTree        = New-Mock4LevelOrgTreeData

            $script:RE04SummaryPaths = Export-SPLeadershipLevelHtml `
                -LeadershipData $leadershipData `
                -Decisions $decisions `
                -OrgTree $orgTree `
                -Level 2 `
                -StartLevel 4 `
                -LowestLevel 2 `
                -CampaignName 'Q1 2026 Review' `
                -OutputPath $script:RE04SummaryDir `
                -CorrelationID 're-04-summary' `
                -DetailLevel 'Summary'

            $script:RE04SummaryHtml = ''
            if (@($script:RE04SummaryPaths).Count -gt 0 -and (Test-Path $script:RE04SummaryPaths[0])) {
                $script:RE04SummaryHtml = Get-Content -Path $script:RE04SummaryPaths[0] -Raw
            }
        }

        It "Should NOT contain detail-disclosure tags in Summary mode" {
            $script:RE04SummaryHtml | Should -Not -Match '<details'
        }

        It "Should still contain the campaign name" {
            $script:RE04SummaryHtml | Should -Match 'Q1 2026 Review'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-05: Get-SPDeltaReportData returns NewGrants + Revocations
# ---------------------------------------------------------------------------

Describe "RE-05: Get-SPDeltaReportData returns NewGrants + Revocations" {

    Context "When APIs return grant and revoke activities" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertReport { }

            # Mock the cross-module Get-SPDeltaGrantEvents
            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertReport {
                return @{
                    Success = $true
                    Data = @(
                        [PSCustomObject]@{
                            IdentityId      = 'id-001'
                            SourceId        = 'src-ad-001'
                            ItemName        = 'GroupA'
                            ActivityCreated = '2026-05-23T08:00:00Z'
                        },
                        [PSCustomObject]@{
                            IdentityId      = 'id-002'
                            SourceId        = 'src-ad-001'
                            ItemName        = 'GroupB'
                            ActivityCreated = '2026-05-23T09:00:00Z'
                        }
                    )
                    Error = $null
                }
            }

            # Mock identity detail for name resolution
            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertReport {
                param($IdentityId)
                $names = @{ 'id-001' = 'Alice Johnson'; 'id-002' = 'Bob Smith' }
                $name = if ($names.ContainsKey($IdentityId)) { $names[$IdentityId] } else { 'Unknown' }
                return @{ IdentityId = $IdentityId; DisplayName = $name; Found = $true }
            }

            # Mock the private revoke helper
            Mock Get-SPDeltaRevokeEvents -ModuleName SP.DeltaCertReport {
                return @{
                    Success = $true
                    Data = @(
                        [PSCustomObject]@{
                            IdentityId      = 'id-003'
                            IdentityName    = 'Carol Davis'
                            SourceId        = 'src-ad-001'
                            ItemName        = 'GroupC'
                            ActivityCreated = '2026-05-23T10:00:00Z'
                        }
                    )
                    Error = $null
                }
            }

            # Mock recent campaigns
            Mock Get-SPDeltaRecentCampaigns -ModuleName SP.DeltaCertReport {
                return @{
                    Success = $true
                    Data = @(
                        [PSCustomObject]@{
                            CampaignId   = 'camp-001'
                            CampaignName = 'AD Delta Cert 2026-05-23'
                            Status       = 'ACTIVE'
                            Created      = '2026-05-23T07:00:00Z'
                        }
                    )
                    Error = $null
                }
            }

            # Mock pending reviews
            Mock Get-SPDeltaPendingReviews -ModuleName SP.DeltaCertReport {
                return @{
                    Success = $true
                    Data = @(
                        [PSCustomObject]@{
                            CertificationId = 'cert-001'
                            ReviewerName    = 'Mgr One'
                            CampaignName    = 'AD Delta Cert 2026-05-23'
                            AgeHours        = 6
                        }
                    )
                    Error = $null
                }
            }
        }

        It "Should return Success=true" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            $result.Success | Should -Be $true
        }

        It "Should return 2 NewGrants" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            @($result.Data.NewGrants).Count | Should -Be 2
        }

        It "Should return 1 Revocation" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            @($result.Data.Revocations).Count | Should -Be 1
        }

        It "Should return 1 CampaignsCreated" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            @($result.Data.CampaignsCreated).Count | Should -Be 1
        }

        It "Should return 1 PendingReview" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            @($result.Data.PendingReviews).Count | Should -Be 1
        }

        It "Should resolve identity names in NewGrants" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            $result.Data.NewGrants[0].IdentityName | Should -Be 'Alice Johnson'
        }

        It "Should include GeneratedAt timestamp" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            $result.Data.GeneratedAt | Should -Not -BeNullOrEmpty
            $result.Data.GeneratedAt | Should -Match 'UTC'
        }

        It "Should return no anomalies for non-overdue reviews" {
            $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
            @($result.Data.Anomalies).Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-06: Export-SPDeltaReportHtml generates valid HTML
# ---------------------------------------------------------------------------

Describe "RE-06: Export-SPDeltaReportHtml generates valid HTML" {

    Context "When given complete delta report data" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertReport { }

            $script:RE06Dir = Join-Path $TestDrive 're-06-delta'
            $null = New-Item -ItemType Directory -Path $script:RE06Dir -Force

            $reportData = New-MockDeltaReportData
            $script:RE06Result = Export-SPDeltaReportHtml `
                -ReportData $reportData `
                -OutputPath $script:RE06Dir `
                -CorrelationID 're-06-corr'
        }

        It "Should return HtmlPath pointing to an existing file" {
            $script:RE06Result.HtmlPath | Should -Not -BeNullOrEmpty
            Test-Path $script:RE06Result.HtmlPath | Should -Be $true
        }

        It "Should return JsonlPath pointing to an existing file" {
            $script:RE06Result.JsonlPath | Should -Not -BeNullOrEmpty
            Test-Path $script:RE06Result.JsonlPath | Should -Be $true
        }

        It "Should generate valid HTML with proper structure" {
            $html = Get-Content -Path $script:RE06Result.HtmlPath -Raw
            $html | Should -Match '<!DOCTYPE html>'
            $html | Should -Match '<html'
            $html | Should -Match '</html>'
        }

        It "Should include all five report sections" {
            $html = Get-Content -Path $script:RE06Result.HtmlPath -Raw
            $html | Should -Match 'New Access Grants'
            $html | Should -Match 'Campaigns Created'
            $html | Should -Match 'Revocations'
            $html | Should -Match 'Pending Reviews'
            $html | Should -Match 'Anomalies'
        }

        It "Should include grant data (Alice Johnson)" {
            $html = Get-Content -Path $script:RE06Result.HtmlPath -Raw
            $html | Should -Match 'Alice Johnson'
        }

        It "Should include the generated-at timestamp" {
            $html = Get-Content -Path $script:RE06Result.HtmlPath -Raw
            $html | Should -Match '2026-05-23'
        }

        It "Should produce HTML under 20KB (compact report)" {
            $fileSize = (Get-Item $script:RE06Result.HtmlPath).Length
            $fileSize | Should -BeLessThan 20480
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-07: Measure-SPAuditRubberStampRisk flags bulk-approve pattern
# ---------------------------------------------------------------------------

Describe "RE-07: Measure-SPAuditRubberStampRisk flags bulk-approve pattern" {

    Context "When a reviewer approves 100 items in 30 seconds" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            # Build 100 APPROVE decisions with timestamps clustered in 30 seconds
            # Parse as UTC so the literal 'Z' in the formatted timestamps below is
            # truthful regardless of host timezone. Otherwise Parse() yields a
            # Local-kind value that, re-stamped with 'Z', mislabels local time as
            # UTC -- decisions can then sort before the campaign-created time and
            # distort the response-latency metric.
            $baseTime  = [datetime]::Parse('2026-03-15T10:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $approvals = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt 100; $i++) {
                $dt = $baseTime.AddSeconds($i * 0.3)  # 0.3 seconds apart = 30 seconds total
                $approvals.Add([PSCustomObject]@{
                    IdentityName = "User-$i"
                    AccessName   = 'AD_Users'
                    AccessType   = 'Entitlement'
                    ReviewerName = 'Rubber Stamper'
                    DecisionDate = $dt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    AccountName  = "user$i@corp.com"
                })
            }

            $script:re07Decisions = @{
                Approved = @($approvals.ToArray())
                Revoked  = @()
                Pending  = @()
            }

            $script:re07Certs = @(
                [PSCustomObject]@{
                    id       = 'cert-rubber-001'
                    reviewer = [PSCustomObject]@{ name = 'Rubber Stamper' }
                    created  = '2026-03-15T09:59:59Z'
                    signed   = $true
                    phase    = 'SIGNED'
                }
            )

            $script:RE07Result = Measure-SPAuditRubberStampRisk `
                -Decisions $script:re07Decisions `
                -Certifications $script:re07Certs
        }

        It "Should flag the reviewer as High risk" {
            $script:RE07Result.ReviewerRisks | Should -Not -BeNullOrEmpty
            $stamper = @($script:RE07Result.ReviewerRisks | Where-Object { $_.ReviewerName -eq 'Rubber Stamper' })
            $stamper.Count | Should -Be 1
            $stamper[0].Severity | Should -Be 'High'
        }

        It "Should set HasMediumOrHighRisk to true" {
            $script:RE07Result.HasMediumOrHighRisk | Should -Be $true
        }

        It "Should report 100% approval rate" {
            $stamper = @($script:RE07Result.ReviewerRisks | Where-Object { $_.ReviewerName -eq 'Rubber Stamper' })
            $stamper[0].ApprovalRate | Should -Be 100
        }

        It "Should detect high decision velocity (>50 items/min)" {
            $stamper = @($script:RE07Result.ReviewerRisks | Where-Object { $_.ReviewerName -eq 'Rubber Stamper' })
            $stamper[0].VelocityItemsPerMin | Should -BeGreaterThan 50
        }

        It "Should report multiple risk flags" {
            $stamper = @($script:RE07Result.ReviewerRisks | Where-Object { $_.ReviewerName -eq 'Rubber Stamper' })
            @($stamper[0].Flags).Count | Should -BeGreaterThan 1
        }
    }

    Context "When a reviewer takes 2 hours to review 20 items with some revocations" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            # Parse as UTC so the literal 'Z' in the formatted timestamps below is
            # truthful regardless of host timezone. Otherwise Parse() yields a
            # Local-kind value that, re-stamped with 'Z', mislabels local time as
            # UTC -- decisions can then sort before the campaign-created time and
            # distort the response-latency metric.
            $baseTime  = [datetime]::Parse('2026-03-15T10:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $approvals = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt 16; $i++) {
                $dt = $baseTime.AddMinutes($i * 7.5)  # every 7.5 mins over 2 hours
                $approvals.Add([PSCustomObject]@{
                    IdentityName = "User-$i"
                    AccessName   = 'AD_Users'
                    AccessType   = 'Entitlement'
                    ReviewerName = 'Careful Reviewer'
                    DecisionDate = $dt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    AccountName  = "user$i@corp.com"
                })
            }

            $revocations = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt 4; $i++) {
                $dt = $baseTime.AddMinutes(60 + $i * 15)
                $revocations.Add([PSCustomObject]@{
                    IdentityName = "RevokedUser-$i"
                    AccessName   = 'AD_Admins'
                    AccessType   = 'Entitlement'
                    ReviewerName = 'Careful Reviewer'
                    DecisionDate = $dt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    AccountName  = "revoked$i@corp.com"
                })
            }

            $script:re07CarefulDecisions = @{
                Approved = @($approvals.ToArray())
                Revoked  = @($revocations.ToArray())
                Pending  = @()
            }

            $script:re07CarefulCerts = @(
                [PSCustomObject]@{
                    id       = 'cert-careful-001'
                    reviewer = [PSCustomObject]@{ name = 'Careful Reviewer' }
                    created  = '2026-03-15T09:55:00Z'
                    signed   = $true
                    phase    = 'SIGNED'
                }
            )

            $script:RE07CarefulResult = Measure-SPAuditRubberStampRisk `
                -Decisions $script:re07CarefulDecisions `
                -Certifications $script:re07CarefulCerts
        }

        It "Should flag the careful reviewer as None risk" {
            $reviewer = @($script:RE07CarefulResult.ReviewerRisks | Where-Object { $_.ReviewerName -eq 'Careful Reviewer' })
            $reviewer.Count | Should -Be 1
            $reviewer[0].Severity | Should -Be 'None'
        }

        It "Should report 80% approval rate (16 of 20)" {
            $reviewer = @($script:RE07CarefulResult.ReviewerRisks | Where-Object { $_.ReviewerName -eq 'Careful Reviewer' })
            $reviewer[0].ApprovalRate | Should -Be 80
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-08: Get-SPAuditRiskFlags returns TERMINATED for terminated identity
# ---------------------------------------------------------------------------

Describe "RE-08: Get-SPAuditRiskFlags returns TERMINATED for terminated identity" {

    Context "When an identity is terminated but still has active access" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            $script:re08Decisions = @{
                Approved = @(
                    [PSCustomObject]@{
                        IdentityName = 'Term User'
                        IdentityId   = 'id-term-001'
                        AccessName   = 'AD_Users'
                        AccessType   = 'Entitlement'
                        ReviewerName = 'Manager1'
                        DecisionDate = '2026-03-15T10:00:00Z'
                    },
                    [PSCustomObject]@{
                        IdentityName = 'Active User'
                        IdentityId   = 'id-active-001'
                        AccessName   = 'AD_Users'
                        AccessType   = 'Entitlement'
                        ReviewerName = 'Manager1'
                        DecisionDate = '2026-03-15T10:05:00Z'
                    },
                    [PSCustomObject]@{
                        IdentityName = 'SVC-BackupAgent'
                        IdentityId   = 'id-svc-001'
                        AccessName   = 'AD_Admins'
                        AccessType   = 'Entitlement'
                        ReviewerName = 'Manager1'
                        DecisionDate = '2026-03-15T10:10:00Z'
                    }
                )
                Revoked = @()
                Pending = @()
            }

            $script:re08Identities = @{
                'id-term-001' = @{
                    lifecycleState = 'terminated'
                    manager        = $null
                    lastLogin      = '2025-01-01T00:00:00Z'
                }
                'id-active-001' = @{
                    lifecycleState = 'active'
                    manager        = 'id-mgr-001'
                    lastLogin      = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
                'id-svc-001' = @{
                    lifecycleState = 'active'
                    manager        = 'id-mgr-001'
                    lastLogin      = (Get-Date).AddDays(-200).ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
            }

            $script:RE08Result = Get-SPAuditRiskFlags `
                -Decisions $script:re08Decisions `
                -Identities $script:re08Identities
        }

        It "Should return TERMINATED flag for the terminated identity" {
            $termItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-term-001' })
            $termItem.Count | Should -Be 1
            @($termItem[0].RiskFlags) | Should -Contain 'TERMINATED'
        }

        It "Should return ORPHAN flag for the terminated identity (no manager)" {
            $termItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-term-001' })
            @($termItem[0].RiskFlags) | Should -Contain 'ORPHAN'
        }

        It "Should return STALE flag for the terminated identity (last login >90 days)" {
            $termItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-term-001' })
            @($termItem[0].RiskFlags) | Should -Contain 'STALE'
        }

        It "Should NOT flag the active user with TERMINATED" {
            $activeItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-active-001' })
            $activeItem.Count | Should -Be 1
            @($activeItem[0].RiskFlags) | Should -Not -Contain 'TERMINATED'
        }

        It "Should return SVC-ACCOUNT flag for service account naming pattern" {
            $svcItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-svc-001' })
            $svcItem.Count | Should -Be 1
            @($svcItem[0].RiskFlags) | Should -Contain 'SVC-ACCOUNT'
        }

        It "Should return PRIVILEGED flag for Admin entitlement on service account" {
            $svcItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-svc-001' })
            @($svcItem[0].RiskFlags) | Should -Contain 'PRIVILEGED'
        }

        It "Should return STALE flag for service account (last login >90 days)" {
            $svcItem = @($script:RE08Result.Decisions.Approved | Where-Object { $_.IdentityId -eq 'id-svc-001' })
            @($svcItem[0].RiskFlags) | Should -Contain 'STALE'
        }

        It "Should report correct Flagged count in Summary" {
            # Term user (3 flags), Active user (0 flags), Svc account (3 flags) = 2 flagged items
            $script:RE08Result.Summary.Flagged | Should -Be 2
        }

        It "Should report correct Total count in Summary" {
            $script:RE08Result.Summary.Total | Should -Be 3
        }

        It "Should track flag counts in Summary.ByFlag" {
            $script:RE08Result.Summary.ByFlag.TERMINATED    | Should -Be 1
            $script:RE08Result.Summary.ByFlag['SVC-ACCOUNT'] | Should -Be 1
            $script:RE08Result.Summary.ByFlag.PRIVILEGED    | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region RE-09: Group-SPAuditDecisions includes Justification and RemediationStatus
# ---------------------------------------------------------------------------

Describe "RE-09: Group-SPAuditDecisions includes Justification and RemediationStatus" {

    Context "When items have comment fields and campaign metadata" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }
        }

        It "Should include Justification from the item comment field" {
            $items = @(
                @{
                    Item = [PSCustomObject]@{
                        id              = 'item-just-1'
                        decision        = 'APPROVE'
                        identitySummary = [PSCustomObject]@{ name = 'Test User' }
                        access          = [PSCustomObject]@{ name = 'AD_Users'; type = 'Entitlement' }
                        reviewedBy      = [PSCustomObject]@{ name = 'Reviewer1' }
                        decisionDate    = '2026-03-15T10:00:00Z'
                        comment         = 'Access required for Q1 project'
                    }
                    CertificationId   = 'cert-just-001'
                    CertificationName = 'Test Cert'
                    CampaignName      = 'Test Campaign'
                }
            )
            $result = Group-SPAuditDecisions -Items $items
            @($result.Approved).Count | Should -Be 1
            $result.Approved[0].PSObject.Properties.Name | Should -Contain 'Justification'
            $result.Approved[0].Justification | Should -Be 'Access required for Q1 project'
        }

        It "Should include RemediationStatus property on each decision" {
            $items = @(
                @{
                    Item = [PSCustomObject]@{
                        id              = 'item-rem-1'
                        decision        = 'REVOKE'
                        identitySummary = [PSCustomObject]@{ name = 'Revoked User' }
                        access          = [PSCustomObject]@{ name = 'AD_Admins'; type = 'Entitlement' }
                        reviewedBy      = [PSCustomObject]@{ name = 'Reviewer1' }
                        decisionDate    = '2026-03-15T10:05:00Z'
                    }
                    CertificationId   = 'cert-rem-001'
                    CertificationName = 'Test Cert'
                    CampaignName      = 'Test Campaign'
                }
            )
            $result = Group-SPAuditDecisions -Items $items
            @($result.Revoked).Count | Should -Be 1
            $result.Revoked[0].PSObject.Properties.Name | Should -Contain 'RemediationStatus'
        }

        It "Should include CampaignStartDate when CampaignMetadata is provided" {
            $items = @(
                @{
                    Item = [PSCustomObject]@{
                        id              = 'item-camp-1'
                        decision        = 'APPROVE'
                        identitySummary = [PSCustomObject]@{ name = 'Camp User' }
                        access          = [PSCustomObject]@{ name = 'VPN'; type = 'Entitlement' }
                        reviewedBy      = [PSCustomObject]@{ name = 'Reviewer1' }
                        decisionDate    = '2026-03-15T11:00:00Z'
                    }
                    CertificationId   = 'cert-camp-001'
                    CertificationName = 'Test Cert'
                    CampaignName      = 'Test Campaign'
                }
            )
            $campaignMeta = @{
                StartDate      = '2026-03-01T00:00:00Z'
                DueDate        = '2026-03-31T23:59:59Z'
                CompletionDate = '2026-03-15T17:00:00Z'
            }
            $result = Group-SPAuditDecisions -Items $items -CampaignMetadata $campaignMeta
            $result.Approved[0].PSObject.Properties.Name | Should -Contain 'CampaignStartDate'
            $result.Approved[0].CampaignStartDate | Should -Be '2026-03-01T00:00:00Z'
        }

        It "Should include CampaignDueDate when CampaignMetadata is provided" {
            $items = @(
                @{
                    Item = [PSCustomObject]@{
                        id              = 'item-due-1'
                        decision        = 'APPROVE'
                        identitySummary = [PSCustomObject]@{ name = 'Due User' }
                        access          = [PSCustomObject]@{ name = 'VPN'; type = 'Entitlement' }
                        reviewedBy      = [PSCustomObject]@{ name = 'Reviewer1' }
                        decisionDate    = '2026-03-15T11:00:00Z'
                    }
                    CertificationId   = 'cert-due-001'
                    CertificationName = 'Test Cert'
                    CampaignName      = 'Test Campaign'
                }
            )
            $campaignMeta = @{
                StartDate      = '2026-03-01T00:00:00Z'
                DueDate        = '2026-03-31T23:59:59Z'
                CompletionDate = '2026-03-15T17:00:00Z'
            }
            $result = Group-SPAuditDecisions -Items $items -CampaignMetadata $campaignMeta
            $result.Approved[0].PSObject.Properties.Name | Should -Contain 'CampaignDueDate'
            $result.Approved[0].CampaignDueDate | Should -Be '2026-03-31T23:59:59Z'
        }

        It "Should include ReviewerEmail when CertReviewerEmailMap is provided" {
            $items = @(
                @{
                    Item = [PSCustomObject]@{
                        id              = 'item-email-1'
                        decision        = 'APPROVE'
                        identitySummary = [PSCustomObject]@{ name = 'Email User' }
                        access          = [PSCustomObject]@{ name = 'VPN'; type = 'Entitlement' }
                        reviewedBy      = [PSCustomObject]@{ name = 'Reviewer1' }
                        decisionDate    = '2026-03-15T11:00:00Z'
                    }
                    CertificationId   = 'cert-email-001'
                    CertificationName = 'Test Cert'
                    CampaignName      = 'Test Campaign'
                }
            )
            $emailMap = @{ 'cert-email-001' = 'reviewer1@corp.com' }
            $result = Group-SPAuditDecisions -Items $items -CertReviewerEmailMap $emailMap
            $result.Approved[0].PSObject.Properties.Name | Should -Contain 'ReviewerEmail'
            $result.Approved[0].ReviewerEmail | Should -Be 'reviewer1@corp.com'
        }

        It "Should default Justification to empty string when no comment" {
            $items = @(
                @{
                    Item = [PSCustomObject]@{
                        id              = 'item-nocomment-1'
                        decision        = 'APPROVE'
                        identitySummary = [PSCustomObject]@{ name = 'No Comment User' }
                        access          = [PSCustomObject]@{ name = 'AD_Users'; type = 'Entitlement' }
                        reviewedBy      = [PSCustomObject]@{ name = 'Reviewer1' }
                        decisionDate    = '2026-03-15T10:00:00Z'
                    }
                    CertificationId   = 'cert-noc-001'
                    CertificationName = 'Test Cert'
                    CampaignName      = 'Test Campaign'
                }
            )
            $result = Group-SPAuditDecisions -Items $items
            $result.Approved[0].Justification | Should -BeIn @('', $null, 'N/A')
        }
    }
}

#endregion
