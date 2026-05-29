#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Leadership Report pipeline
.DESCRIPTION
    Tests: LR-01 through LR-06
    Covers:
        LR-01: Build-SPOrgTree -- tree building with 5 identities, 2 managers, 1 director
        LR-02: Build-SPOrgTree -- cycle detection in manager chains
        LR-03: Group-SPAuditByLeadership -- aggregation math validation
        LR-04: Export-SPLeadershipExecutiveHtml -- HTML structure and director rows
        LR-05: Export-SPLeadershipDirectorHtml -- per-director file generation and isolation
        LR-06: Send-SPReport -- stub logs intent without SMTP calls

    Mock scoping:
        LR-01/LR-02 mock within SP.DeltaCertQueries.
        LR-03 uses pure in-memory data (no mocks needed beyond logging).
        LR-04/LR-05 mock Write-SPLog in SP.AuditReport and write to $TestDrive.
        LR-06 mocks Get-SPConfig in SP.AuditReport to control SMTP settings.
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
    # Helper: build a mock org tree Data structure (for LR-03/04/05)
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
            LeafCount   = 5
            MaxDepthHit = $false
        }
    }

    # -----------------------------------------------------------------------
    # Helper: build mock decisions for leadership grouping (LR-03/04/05)
    # 5 identities: 3 approved, 1 revoked, 1 pending
    # -----------------------------------------------------------------------
    function New-MockDecisions {
        return @{
            Approved = @(
                [PSCustomObject]@{
                    IdentityName  = 'Alice Johnson'
                    AccessName    = 'AD_Users'
                    AccessType    = 'Entitlement'
                    ReviewerName  = 'Mgr One'
                    DecisionDate  = '2026-03-15T10:00:00Z'
                    AccountName   = 'ajohnson@corp.com'
                },
                [PSCustomObject]@{
                    IdentityName  = 'Bob Smith'
                    AccessName    = 'AD_Users'
                    AccessType    = 'Entitlement'
                    ReviewerName  = 'Mgr One'
                    DecisionDate  = '2026-03-15T10:05:00Z'
                    AccountName   = 'bsmith@corp.com'
                },
                [PSCustomObject]@{
                    IdentityName  = 'Dave Lee'
                    AccessName    = 'VPN_Access'
                    AccessType    = 'Entitlement'
                    ReviewerName  = 'Mgr Three'
                    DecisionDate  = '2026-03-15T11:00:00Z'
                    AccountName   = 'dlee@corp.com'
                }
            )
            Revoked = @(
                [PSCustomObject]@{
                    IdentityName  = 'Carol Davis'
                    AccessName    = 'AD_Admins'
                    AccessType    = 'Entitlement'
                    ReviewerName  = 'Mgr Two'
                    DecisionDate  = '2026-03-15T10:30:00Z'
                    AccountName   = 'cdavis@corp.com'
                }
            )
            Pending = @(
                [PSCustomObject]@{
                    IdentityName  = 'Eve Park'
                    AccessName    = 'FileShare_RW'
                    AccessType    = 'Entitlement'
                    ReviewerName  = $null
                    DecisionDate  = $null
                    AccountName   = 'epark@corp.com'
                }
            )
        }
    }

    # -----------------------------------------------------------------------
    # Helper: build mock leadership data (from Group-SPAuditByLeadership)
    # -----------------------------------------------------------------------
    function New-MockLeadershipData {
        return @{
            Directors = @{
                'id-dir-a' = @{
                    Name          = 'Director A'
                    Email         = ''
                    TotalItems    = 3
                    Approved      = 2
                    Revoked       = 1
                    Pending       = 0
                    CompletionPct = 100.0
                    Managers      = @{
                        'id-mgr1' = @{ Name = 'Mgr One';  Approved = 2; Revoked = 0; Pending = 0; AvgHours = 4.2 }
                        'id-mgr2' = @{ Name = 'Mgr Two';  Approved = 0; Revoked = 1; Pending = 0; AvgHours = 8.5 }
                    }
                }
                'id-dir-b' = @{
                    Name          = 'Director B'
                    Email         = ''
                    TotalItems    = 2
                    Approved      = 1
                    Revoked       = 0
                    Pending       = 1
                    CompletionPct = 50.0
                    Managers      = @{
                        'id-mgr3' = @{ Name = 'Mgr Three'; Approved = 1; Revoked = 0; Pending = 1; AvgHours = 12.0 }
                    }
                }
            }
            Executive = @{
                'id-vp' = @{
                    Name          = 'VP Smith'
                    TotalItems    = 5
                    Approved      = 3
                    Revoked       = 1
                    Pending       = 1
                    CompletionPct = 80.0
                    Directors     = @('id-dir-a', 'id-dir-b')
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
#region LR-01: Build-SPOrgTree with 5 identities, 2 managers, 1 director
# ---------------------------------------------------------------------------

Describe "LR-01: Build-SPOrgTree builds correct tree structure" {

    Context "When given 5 identities under 2 managers under 1 director" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            # Map of identity ID -> mock detail response
            $script:mockDetails = @{
                'id-alice' = New-MockIdentityDetail -IdentityId 'id-alice' -DisplayName 'Alice' -ManagerId 'id-mgr1' -ManagerName 'Manager One'
                'id-bob'   = New-MockIdentityDetail -IdentityId 'id-bob'   -DisplayName 'Bob'   -ManagerId 'id-mgr1' -ManagerName 'Manager One'
                'id-carol' = New-MockIdentityDetail -IdentityId 'id-carol' -DisplayName 'Carol' -ManagerId 'id-mgr1' -ManagerName 'Manager One'
                'id-dave'  = New-MockIdentityDetail -IdentityId 'id-dave'  -DisplayName 'Dave'  -ManagerId 'id-mgr2' -ManagerName 'Manager Two'
                'id-eve'   = New-MockIdentityDetail -IdentityId 'id-eve'   -DisplayName 'Eve'   -ManagerId 'id-mgr2' -ManagerName 'Manager Two'
                'id-mgr1'  = New-MockIdentityDetail -IdentityId 'id-mgr1'  -DisplayName 'Manager One' -ManagerId 'id-dir' -ManagerName 'Director'
                'id-mgr2'  = New-MockIdentityDetail -IdentityId 'id-mgr2'  -DisplayName 'Manager Two' -ManagerId 'id-dir' -ManagerName 'Director'
                'id-dir'   = New-MockIdentityDetail -IdentityId 'id-dir'   -DisplayName 'Director' -ManagerId '' -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:mockDetails.ContainsKey($IdentityId)) {
                    return $script:mockDetails[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:LR01Result = Build-SPOrgTree -IdentityIds @('id-alice','id-bob','id-carol','id-dave','id-eve') -MaxDepth 3
        }

        It "Should return Success=true" {
            $script:LR01Result.Success | Should -Be $true
        }

        It "Should build 8 nodes total (5 leaves + 2 managers + 1 director)" {
            $script:LR01Result.Data.Nodes.Count | Should -Be 8
        }

        It "Should have 5 leaf nodes at Level 0" {
            $leaves = @($script:LR01Result.Data.Nodes.Keys | Where-Object { $script:LR01Result.Data.Nodes[$_].Level -eq 0 })
            $leaves.Count | Should -Be 5
        }

        It "Should have 2 manager nodes at Level 1" {
            $script:LR01Result.Data.Managers.Count | Should -Be 2
        }

        It "Should report LeafCount = 5" {
            $script:LR01Result.Data.LeafCount | Should -Be 5
        }

        It "Should have Manager One with 3 children (Alice, Bob, Carol)" {
            $mgr1Children = @($script:LR01Result.Data.Nodes['id-mgr1'].Children)
            $mgr1Children.Count | Should -Be 3
            $mgr1Children | Should -Contain 'id-alice'
            $mgr1Children | Should -Contain 'id-bob'
            $mgr1Children | Should -Contain 'id-carol'
        }

        It "Should have Manager Two with 2 children (Dave, Eve)" {
            $mgr2Children = @($script:LR01Result.Data.Nodes['id-mgr2'].Children)
            $mgr2Children.Count | Should -Be 2
            $mgr2Children | Should -Contain 'id-dave'
            $mgr2Children | Should -Contain 'id-eve'
        }

        It "Should have director as top of chain with both managers as children" {
            $dirChildren = @($script:LR01Result.Data.Nodes['id-dir'].Children)
            $dirChildren.Count | Should -Be 2
            $dirChildren | Should -Contain 'id-mgr1'
            $dirChildren | Should -Contain 'id-mgr2'
        }

        It "Should not set MaxDepthHit (tree is 3 levels: leaf + mgr + dir)" {
            # MaxDepth=3, but the tree only reaches depth 2 (mgr at 1, dir at 2),
            # so MaxDepthHit should be false
            $script:LR01Result.Data.MaxDepthHit | Should -Be $false
        }

        It "Should not duplicate nodes for shared managers" {
            # Both Alice/Bob/Carol share id-mgr1 -- only one node should exist
            $nodeKeys = @($script:LR01Result.Data.Nodes.Keys)
            $mgr1Count = @($nodeKeys | Where-Object { $_ -eq 'id-mgr1' }).Count
            $mgr1Count | Should -Be 1
        }
    }

    Context "When MaxDepth=2 limits the tree height" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:depthMockDetails = @{
                'id-leaf'   = New-MockIdentityDetail -IdentityId 'id-leaf'   -DisplayName 'Leaf'    -ManagerId 'id-mgr'  -ManagerName 'Manager'
                'id-mgr'    = New-MockIdentityDetail -IdentityId 'id-mgr'    -DisplayName 'Manager' -ManagerId 'id-dir'  -ManagerName 'Director'
                'id-dir'    = New-MockIdentityDetail -IdentityId 'id-dir'    -DisplayName 'Director'-ManagerId 'id-vp'   -ManagerName 'VP'
                'id-vp'     = New-MockIdentityDetail -IdentityId 'id-vp'     -DisplayName 'VP'      -ManagerId '' -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:depthMockDetails.ContainsKey($IdentityId)) {
                    return $script:depthMockDetails[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:LR01DepthResult = Build-SPOrgTree -IdentityIds @('id-leaf') -MaxDepth 2
        }

        It "Should set MaxDepthHit=true when chain exceeds MaxDepth" {
            $script:LR01DepthResult.Data.MaxDepthHit | Should -Be $true
        }

        It "Should stop at director level and not include VP" {
            $script:LR01DepthResult.Data.Nodes.ContainsKey('id-vp') | Should -Be $false
        }

        It "Should have 3 nodes (leaf + manager + director)" {
            $script:LR01DepthResult.Data.Nodes.Count | Should -Be 3
        }
    }

    Context "When all identities have no manager" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName "User $IdentityId" -ManagerId '' -ManagerName ''
            }

            $script:LR01NoMgrResult = Build-SPOrgTree -IdentityIds @('id-1', 'id-2')
        }

        It "Should have only leaf nodes" {
            $script:LR01NoMgrResult.Data.Nodes.Count | Should -Be 2
        }

        It "Should have empty TopLeaders list" {
            $script:LR01NoMgrResult.Data.TopLeaders.Count | Should -Be 0
        }

        It "Should have empty Managers list" {
            $script:LR01NoMgrResult.Data.Managers.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LR-02: Build-SPOrgTree with cyclic manager reference
# ---------------------------------------------------------------------------

Describe "LR-02: Build-SPOrgTree handles cyclic manager references" {

    Context "When identity A's manager is B and B's manager is A (direct cycle)" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:cycleMockDetails = @{
                'id-a' = New-MockIdentityDetail -IdentityId 'id-a' -DisplayName 'User A' -ManagerId 'id-b' -ManagerName 'User B'
                'id-b' = New-MockIdentityDetail -IdentityId 'id-b' -DisplayName 'User B' -ManagerId 'id-a' -ManagerName 'User A'
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:cycleMockDetails.ContainsKey($IdentityId)) {
                    return $script:cycleMockDetails[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:LR02Result = Build-SPOrgTree -IdentityIds @('id-a') -MaxDepth 5
        }

        It "Should return Success=true (cycle is handled, not fatal)" {
            $script:LR02Result.Success | Should -Be $true
        }

        It "Should not crash or enter an infinite loop" {
            $script:LR02Result | Should -Not -BeNullOrEmpty
        }

        It "Should contain both nodes" {
            $script:LR02Result.Data.Nodes.ContainsKey('id-a') | Should -Be $true
            $script:LR02Result.Data.Nodes.ContainsKey('id-b') | Should -Be $true
        }

        It "Should have logged a WARN about the cycle" {
            # Build-SPOrgTree runs in the Context BeforeAll, so assert against the
            # Context scope (Should -Invoke defaults to the It scope, which sees 0).
            Should -Invoke Write-SPLog -ModuleName SP.DeltaCertQueries -Scope Context -Times 1 -Exactly -ParameterFilter {
                $Severity -eq 'WARN' -and $Message -match 'Cycle detected'
            }
        }
    }

    Context "When identity chains to itself (self-referencing manager)" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                # Self-referencing: manager points to self
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Self Ref' -ManagerId $IdentityId -ManagerName 'Self Ref'
            }

            $script:LR02SelfResult = Build-SPOrgTree -IdentityIds @('id-self') -MaxDepth 5
        }

        It "Should return Success=true" {
            $script:LR02SelfResult.Success | Should -Be $true
        }

        It "Should only have 1 node (the leaf itself)" {
            $script:LR02SelfResult.Data.Nodes.Count | Should -Be 1
        }

        It "Should have logged a WARN about the cycle" {
            Should -Invoke Write-SPLog -ModuleName SP.DeltaCertQueries -Scope Context -Times 1 -Exactly -ParameterFilter {
                $Severity -eq 'WARN' -and $Message -match 'Cycle detected'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LR-03: Group-SPAuditByLeadership aggregation math
# ---------------------------------------------------------------------------

Describe "LR-03: Group-SPAuditByLeadership aggregation math" {

    Context "When given decisions and a complete org tree" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:orgTree   = New-MockOrgTreeData
            $script:decisions = New-MockDecisions

            $script:reviewerMetrics = @{
                ReviewerMetrics = @(
                    [PSCustomObject]@{ Name = 'Mgr One';   AvgHours = 4.2 }
                    [PSCustomObject]@{ Name = 'Mgr Two';   AvgHours = 8.5 }
                    [PSCustomObject]@{ Name = 'Mgr Three'; AvgHours = 12.0 }
                )
            }

            $script:LR03Result = Group-SPAuditByLeadership `
                -Decisions $script:decisions `
                -OrgTree $script:orgTree `
                -ReviewerMetrics $script:reviewerMetrics
        }

        It "Should return a hashtable with Directors and Executive keys" {
            $script:LR03Result.ContainsKey('Directors') | Should -Be $true
            $script:LR03Result.ContainsKey('Executive') | Should -Be $true
        }

        It "Should have 2 directors (Director A and Director B)" {
            $script:LR03Result['Directors'].Count | Should -Be 2
            $script:LR03Result['Directors'].ContainsKey('id-dir-a') | Should -Be $true
            $script:LR03Result['Directors'].ContainsKey('id-dir-b') | Should -Be $true
        }

        It "Should attribute 3 items to Director A (Alice approved, Bob approved, Carol revoked)" {
            $dirA = $script:LR03Result['Directors']['id-dir-a']
            $dirA.TotalItems | Should -Be 3
            $dirA.Approved   | Should -Be 2
            $dirA.Revoked    | Should -Be 1
            $dirA.Pending    | Should -Be 0
        }

        It "Should attribute 2 items to Director B (Dave approved, Eve pending)" {
            $dirB = $script:LR03Result['Directors']['id-dir-b']
            $dirB.TotalItems | Should -Be 2
            $dirB.Approved   | Should -Be 1
            $dirB.Revoked    | Should -Be 0
            $dirB.Pending    | Should -Be 1
        }

        It "Should compute CompletionPct correctly: (Approved + Revoked) / Total * 100" {
            $dirA = $script:LR03Result['Directors']['id-dir-a']
            $dirA.CompletionPct | Should -Be 100.0

            $dirB = $script:LR03Result['Directors']['id-dir-b']
            $dirB.CompletionPct | Should -Be 50.0
        }

        It "Should sum manager-level counts to match director-level totals" {
            $dirA = $script:LR03Result['Directors']['id-dir-a']
            $mgrApproved = 0; $mgrRevoked = 0; $mgrPending = 0
            foreach ($mgrId in $dirA.Managers.Keys) {
                $m = $dirA.Managers[$mgrId]
                $mgrApproved += $m.Approved
                $mgrRevoked  += $m.Revoked
                $mgrPending  += $m.Pending
            }
            $mgrApproved | Should -Be $dirA.Approved
            $mgrRevoked  | Should -Be $dirA.Revoked
            $mgrPending  | Should -Be $dirA.Pending
        }

        It "Should map reviewer AvgHours to the correct manager" {
            $dirA = $script:LR03Result['Directors']['id-dir-a']
            $dirA.Managers['id-mgr1'].AvgHours | Should -Be 4.2
            $dirA.Managers['id-mgr2'].AvgHours | Should -Be 8.5
        }

        It "Should have VP Smith in Executive rollup with correct totals" {
            $vp = $script:LR03Result['Executive']['id-vp']
            $vp | Should -Not -BeNullOrEmpty
            $vp.Name       | Should -Be 'VP Smith'
            $vp.TotalItems | Should -Be 5
            $vp.Approved   | Should -Be 3
            $vp.Revoked    | Should -Be 1
            $vp.Pending    | Should -Be 1
        }

        It "Should satisfy Approved + Revoked + Pending = TotalItems for every director" {
            foreach ($dirId in $script:LR03Result['Directors'].Keys) {
                $d = $script:LR03Result['Directors'][$dirId]
                ($d.Approved + $d.Revoked + $d.Pending) | Should -Be $d.TotalItems
            }
        }
    }

    Context "When an identity name cannot be resolved in the org tree" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:orgTreeSmall = New-MockOrgTreeData
            # Decisions include a name that is not in the org tree
            $script:decisionsWithUnknown = @{
                Approved = @(
                    [PSCustomObject]@{ IdentityName = 'Alice Johnson'; AccessName = 'AD_Users'; ReviewerName = 'Mgr One'; DecisionDate = '2026-03-15T10:00:00Z' }
                    [PSCustomObject]@{ IdentityName = 'Unknown Person'; AccessName = 'VPN'; ReviewerName = 'Nobody'; DecisionDate = '2026-03-15T11:00:00Z' }
                )
                Revoked = @()
                Pending = @()
            }

            $script:LR03UnknownResult = Group-SPAuditByLeadership `
                -Decisions $script:decisionsWithUnknown `
                -OrgTree $script:orgTreeSmall
        }

        It "Should place unresolved identity under __unmanaged__ bucket" {
            $script:LR03UnknownResult['Directors'].ContainsKey('__unmanaged__') | Should -Be $true
            $script:LR03UnknownResult['Directors']['__unmanaged__'].TotalItems | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LR-04: Export-SPLeadershipExecutiveHtml generates valid HTML
# ---------------------------------------------------------------------------

Describe "LR-04: Export-SPLeadershipExecutiveHtml generates valid HTML" {

    Context "When given well-formed leadership data" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:LR04Dir = Join-Path $TestDrive 'lr-04-exec'
            $null = New-Item -ItemType Directory -Path $script:LR04Dir -Force

            $leadershipData = New-MockLeadershipData

            $script:LR04FilePath = Export-SPLeadershipExecutiveHtml `
                -LeadershipData $leadershipData `
                -CampaignName 'Q1 2026 Access Review' `
                -DateRange '2026-01-01 to 2026-03-31' `
                -OutputPath $script:LR04Dir `
                -CorrelationID 'lr-04-corr'

            if (Test-Path $script:LR04FilePath) {
                $script:LR04Html = Get-Content -Path $script:LR04FilePath -Raw
            }
            else {
                $script:LR04Html = ''
            }
        }

        It "Should create executive-summary.html" {
            $script:LR04FilePath | Should -Not -BeNullOrEmpty
            Test-Path $script:LR04FilePath | Should -Be $true
            (Split-Path $script:LR04FilePath -Leaf) | Should -Be 'executive-summary.html'
        }

        It "Should generate non-empty HTML content" {
            $script:LR04Html | Should -Not -BeNullOrEmpty
            $script:LR04Html.Length | Should -BeGreaterThan 100
        }

        It "Should contain opening and closing html tags" {
            $script:LR04Html | Should -Match '<html'
            $script:LR04Html | Should -Match '</html>'
        }

        It "Should include the campaign name" {
            $script:LR04Html | Should -Match 'Q1 2026 Access Review'
        }

        It "Should include both director names in the report" {
            $script:LR04Html | Should -Match 'Director A'
            $script:LR04Html | Should -Match 'Director B'
        }

        It "Should show director rows sorted by completion % ascending (Director B 50% before Director A 100%)" {
            # Director B (50%) should appear before Director A (100%) in the HTML
            $posB = $script:LR04Html.IndexOf('Director B')
            $posA = $script:LR04Html.IndexOf('Director A')
            $posB | Should -BeLessThan $posA
        }

        It "Should color-code completion: green for >=95%, red for <80%" {
            # Director A at 100% should have green (#339933)
            # Director B at 50% should have red (#CC3333)
            $script:LR04Html | Should -Match '#339933'
            $script:LR04Html | Should -Match '#CC3333'
        }

        It "Should contain a table element for director rows" {
            $script:LR04Html | Should -Match '<table'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LR-05: Export-SPLeadershipDirectorHtml generates per-director files
# ---------------------------------------------------------------------------

Describe "LR-05: Export-SPLeadershipDirectorHtml generates per-director files" {

    Context "When given leadership data with 2 directors" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:LR05Dir = Join-Path $TestDrive 'lr-05-directors'
            $null = New-Item -ItemType Directory -Path $script:LR05Dir -Force

            $leadershipData = New-MockLeadershipData
            $decisions      = New-MockDecisions
            $orgTree        = New-MockOrgTreeData

            $script:LR05Paths = Export-SPLeadershipDirectorHtml `
                -LeadershipData $leadershipData `
                -Decisions $decisions `
                -OrgTree $orgTree `
                -CampaignName 'Q1 2026 Access Review' `
                -DateRange '2026-01-01 to 2026-03-31' `
                -OutputPath $script:LR05Dir `
                -CorrelationID 'lr-05-corr'

            # Read content of each generated file
            $script:LR05Files = @{}
            foreach ($fp in @($script:LR05Paths)) {
                if (Test-Path $fp) {
                    $name = Split-Path $fp -Leaf
                    $script:LR05Files[$name] = Get-Content -Path $fp -Raw
                }
            }
        }

        It "Should create exactly 2 director HTML files" {
            @($script:LR05Paths).Count | Should -Be 2
        }

        It "Should name files using sanitized director names" {
            $fileNames = @($script:LR05Files.Keys)
            $fileNames | Should -Contain 'director-DirectorA.html'
            $fileNames | Should -Contain 'director-DirectorB.html'
        }

        It "Director A's report should contain Mgr One and Mgr Two but NOT Mgr Three" {
            $htmlA = $script:LR05Files['director-DirectorA.html']
            $htmlA | Should -Match 'Mgr One'
            $htmlA | Should -Match 'Mgr Two'
            $htmlA | Should -Not -Match 'Mgr Three'
        }

        It "Director B's report should contain Mgr Three but NOT Mgr One or Mgr Two" {
            $htmlB = $script:LR05Files['director-DirectorB.html']
            $htmlB | Should -Match 'Mgr Three'
            $htmlB | Should -Not -Match 'Mgr One'
            $htmlB | Should -Not -Match 'Mgr Two'
        }

        It "Director A's report should show identity-level details for Alice and Bob" {
            $htmlA = $script:LR05Files['director-DirectorA.html']
            $htmlA | Should -Match 'Alice Johnson'
            $htmlA | Should -Match 'Bob Smith'
        }

        It "Director B's report should show identity-level details for Dave and Eve" {
            $htmlB = $script:LR05Files['director-DirectorB.html']
            $htmlB | Should -Match 'Dave Lee'
            $htmlB | Should -Match 'Eve Park'
        }

        It "Each director report should contain a navigation link to executive-summary.html" {
            foreach ($name in $script:LR05Files.Keys) {
                $script:LR05Files[$name] | Should -Match 'executive-summary\.html'
            }
        }

        It "Each director report should have valid HTML structure" {
            foreach ($name in $script:LR05Files.Keys) {
                $html = $script:LR05Files[$name]
                $html | Should -Match '<html'
                $html | Should -Match '</html>'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LR-06: Send-SPReport stub logs intent without SMTP calls
# ---------------------------------------------------------------------------

Describe "LR-06: Send-SPReport stub logs intent without SMTP calls" {

    Context "When SMTP is disabled (default)" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
            Mock Send-MailMessage -ModuleName SP.AuditReport { }

            Mock Get-SPConfig -ModuleName SP.AuditReport {
                return [PSCustomObject]@{
                    Audit = [PSCustomObject]@{
                        Smtp = [PSCustomObject]@{
                            Enabled       = $false
                            Server        = ''
                            Port          = 587
                            From          = ''
                            UseSsl        = $true
                            SubjectPrefix = '[SailPoint Audit]'
                        }
                    }
                }
            }

            $script:LR06DisabledResult = Send-SPReport `
                -ReportPath 'C:\Audit\leadership\executive-summary.html' `
                -RecipientEmail 'vp@corp.com' `
                -RecipientName 'VP Smith' `
                -CorrelationID 'lr-06-corr'
        }

        It "Should return Success=true" {
            $script:LR06DisabledResult.Success | Should -Be $true
        }

        It "Should return Action=Logged (not Sent)" {
            $script:LR06DisabledResult.Data.Action | Should -Be 'Logged'
        }

        It "Should return the correct recipient email" {
            $script:LR06DisabledResult.Data.Recipient | Should -Be 'vp@corp.com'
        }

        It "Should return the correct file path" {
            $script:LR06DisabledResult.Data.File | Should -Be 'C:\Audit\leadership\executive-summary.html'
        }

        It "Should build default subject with prefix and recipient name" {
            $script:LR06DisabledResult.Data.Subject | Should -Match '\[SailPoint Audit\]'
            $script:LR06DisabledResult.Data.Subject | Should -Match 'VP Smith'
        }

        It "Should log at DEBUG level when SMTP is disabled" {
            # Send-SPReport runs in the Context BeforeAll -- assert at Context scope.
            Should -Invoke Write-SPLog -ModuleName SP.AuditReport -Scope Context -ParameterFilter {
                $Severity -eq 'DEBUG' -and $Message -match 'SMTP disabled'
            }
        }

        It "Should NOT invoke Send-MailMessage" {
            Should -Not -Invoke Send-MailMessage -ModuleName SP.AuditReport -Scope Context
        }
    }

    Context "When SMTP is enabled (stub mode)" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
            Mock Send-MailMessage -ModuleName SP.AuditReport { }

            Mock Get-SPConfig -ModuleName SP.AuditReport {
                return [PSCustomObject]@{
                    Audit = [PSCustomObject]@{
                        Smtp = [PSCustomObject]@{
                            Enabled       = $true
                            Server        = 'smtp.corp.com'
                            Port          = 587
                            From          = 'noreply@corp.com'
                            UseSsl        = $true
                            SubjectPrefix = '[Corp Audit]'
                        }
                    }
                }
            }

            $script:LR06EnabledResult = Send-SPReport `
                -ReportPath 'C:\Audit\leadership\director-DirA.html' `
                -RecipientEmail 'director.a@corp.com' `
                -RecipientName 'Director A' `
                -CorrelationID 'lr-06-corr-enabled'
        }

        It "Should return Success=true" {
            $script:LR06EnabledResult.Success | Should -Be $true
        }

        It "Should return Action=Logged (stub, not actually sent)" {
            $script:LR06EnabledResult.Data.Action | Should -Be 'Logged'
        }

        It "Should log at INFO level when SMTP is enabled (stub)" {
            Should -Invoke Write-SPLog -ModuleName SP.AuditReport -Scope Context -ParameterFilter {
                $Severity -eq 'INFO' -and $Message -match 'SMTP stub'
            }
        }

        It "Should use custom SubjectPrefix from config" {
            $script:LR06EnabledResult.Data.Subject | Should -Match '\[Corp Audit\]'
        }

        It "Should NOT invoke Send-MailMessage (stub only)" {
            Should -Not -Invoke Send-MailMessage -ModuleName SP.AuditReport -Scope Context
        }
    }

    Context "When SMTP config is unavailable" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            Mock Get-SPConfig -ModuleName SP.AuditReport {
                return [PSCustomObject]@{}
            }

            $script:LR06NoConfigResult = Send-SPReport `
                -ReportPath 'C:\Audit\report.html' `
                -RecipientEmail 'test@corp.com' `
                -RecipientName 'Test User'
        }

        It "Should return Success=true (graceful degradation)" {
            $script:LR06NoConfigResult.Success | Should -Be $true
        }

        It "Should treat missing config as SMTP disabled" {
            $script:LR06NoConfigResult.Data.Action | Should -Be 'Logged'
        }
    }
}

#endregion
