#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x governance-correctness tests for leadership band attribution and
    org-chain rollups (T-03).
.DESCRIPTION
    Tests: LA-01 through LA-04
    Covers:
        LA-01: Build-SPOrgTree + Resolve-SPIdentityBand attribute the full A-E
               chain (CEO -> VP -> Director -> Manager -> IC) to the correct
               levels and band letters on known synthetic input.
        LA-02: Group-SPAuditByLeadership attributes each identity to the RIGHT
               leader and rolls up director/VP subtrees without double-count.
        LA-03: An orphaned/missing-manager identity lands in the documented
               __unmanaged__ bucket and is NOT silently dropped or mis-attributed.
        LA-04: Band attribution honors an ISC (jobLevel) override over depth on
               the same A-E chain (additive depth check).

    These tests assert against HAND-COMPUTED governance truth so a real semantic
    mismatch (wrong band letter, wrong leader attribution, double-counted rollup,
    orphan silently dropped) would fail rather than render-pass.

    Mock scoping (Bug-1 flat-import rule):
        Build-SPOrgTree / Resolve-SPIdentityBand live in SP.DeltaCertQueries ->
            mock Write-SPLog / Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries.
        Group-SPAuditByLeadership lives in SP.AuditReportCore ->
            mock Write-SPLog -ModuleName SP.AuditReportCore.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # -----------------------------------------------------------------------
    # Helper: build a mock identity detail result (mirrors
    # SP.LeadershipReport.Tests.ps1 lines 31-48 / SP.OrgChart.Tests.ps1).
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
    # Helper: local copy of the LR-03 org-tree fixture shape (do NOT import
    # across test files). Tree:
    #   VP -> DirA -> Mgr1 (Alice, Bob), Mgr2 (Carol)
    #         DirB -> Mgr3 (Dave, Eve)
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
}

# ---------------------------------------------------------------------------
#region LA-01: Build-SPOrgTree + Resolve-SPIdentityBand attribute the A-E chain
# ---------------------------------------------------------------------------

Describe "LA-01: Build-SPOrgTree + Resolve-SPIdentityBand attribute the full A-E chain" {

    Context "When given a 5-level chain CEO -> VP -> Director -> Manager -> IC" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            # Manager chain wired ic -> mgr -> dir -> vp -> ceo -> '' (top).
            # Unique ids prevent leakage from other Describe blocks via IdentityCache.
            $script:la01Details = @{
                'id-ic'   = New-MockIdentityDetail -IdentityId 'id-ic'   -DisplayName 'Ivy IC'      -ManagerId 'id-mgr' -ManagerName 'Mona Manager'
                'id-mgr'  = New-MockIdentityDetail -IdentityId 'id-mgr'  -DisplayName 'Mona Manager' -ManagerId 'id-dir' -ManagerName 'Dirk Director'
                'id-dir'  = New-MockIdentityDetail -IdentityId 'id-dir'  -DisplayName 'Dirk Director' -ManagerId 'id-vp'  -ManagerName 'Vera VP'
                'id-vp'   = New-MockIdentityDetail -IdentityId 'id-vp'   -DisplayName 'Vera VP'       -ManagerId 'id-ceo' -ManagerName 'Cory CEO'
                'id-ceo'  = New-MockIdentityDetail -IdentityId 'id-ceo'  -DisplayName 'Cory CEO'      -ManagerId ''       -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:la01Details.ContainsKey($IdentityId)) {
                    return $script:la01Details[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            # MaxDepth=4 is REQUIRED: default 3 would truncate the 5-deep chain and
            # drop id-ceo (level 4). See PITFALL (a).
            $script:la01Tree = Build-SPOrgTree -IdentityIds @('id-ic') -MaxDepth 4
            $script:la01Band = Resolve-SPIdentityBand -OrgTree $script:la01Tree.Data
        }

        It "Should return Success=true for Build-SPOrgTree" {
            $script:la01Tree.Success | Should -Be $true
        }

        It "Should build exactly 5 nodes (IC + Manager + Director + VP + CEO)" {
            $script:la01Tree.Data.Nodes.Count | Should -Be 5
        }

        It "Should assign the correct depth level to each rung of the chain" {
            $nodes = $script:la01Tree.Data.Nodes
            $nodes['id-ic'].Level  | Should -Be 0
            $nodes['id-mgr'].Level | Should -Be 1
            $nodes['id-dir'].Level | Should -Be 2
            $nodes['id-vp'].Level  | Should -Be 3
            $nodes['id-ceo'].Level | Should -Be 4
        }

        It "Should wire each child under its correct manager" {
            $nodes = $script:la01Tree.Data.Nodes
            @($nodes['id-mgr'].Children) | Should -Contain 'id-ic'
            @($nodes['id-dir'].Children) | Should -Contain 'id-mgr'
            @($nodes['id-vp'].Children)  | Should -Contain 'id-dir'
            @($nodes['id-ceo'].Children) | Should -Contain 'id-vp'
        }

        It "Should place the CEO (no manager) at the top of the chain via TopLeaders" {
            # CEO ManagerId='' => top of chain. TopLeaders captures level >=3 nodes.
            $script:la01Tree.Data.TopLeaders | Should -Contain 'id-ceo'
        }

        It "Should resolve the correct band letter for each level (E..A)" {
            $bands = $script:la01Band.Data.Bands
            $bands['id-ic']  | Should -Be 'E'
            $bands['id-mgr'] | Should -Be 'D'
            $bands['id-dir'] | Should -Be 'C'
            $bands['id-vp']  | Should -Be 'B'
            $bands['id-ceo'] | Should -Be 'A'
        }

        It "Should source every band from Depth (no supplement/cache present)" {
            foreach ($id in @('id-ic', 'id-mgr', 'id-dir', 'id-vp', 'id-ceo')) {
                $script:la01Band.Data.Sources[$id] | Should -Be 'Depth'
            }
        }

        It "Should summarise exactly one identity in each band A..E" {
            $summary = $script:la01Band.Data.Summary
            $summary['A'] | Should -Be 1
            $summary['B'] | Should -Be 1
            $summary['C'] | Should -Be 1
            $summary['D'] | Should -Be 1
            $summary['E'] | Should -Be 1
        }

        It "Should assign a non-null band to every node" {
            foreach ($nodeId in $script:la01Tree.Data.Nodes.Keys) {
                $script:la01Band.Data.Bands[$nodeId] | Should -Not -BeNullOrEmpty
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LA-02: Group-SPAuditByLeadership attributes to the RIGHT leader, no double-count
# ---------------------------------------------------------------------------

Describe "LA-02: Group-SPAuditByLeadership attributes each identity to the RIGHT leader and rolls up subtrees without double-count" {

    Context "When given decisions across both directors under one VP" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            $script:la02Tree = New-MockOrgTreeData

            # Known per-identity dispositions:
            #   DirA subtree: Alice(Approved), Bob(Approved) via Mgr1; Carol(Revoked) via Mgr2
            #   DirB subtree: Dave(Approved) via Mgr3; Eve(Pending) via Mgr3
            $script:la02Decisions = @{
                Approved = @(
                    [PSCustomObject]@{ IdentityName = 'Alice Johnson'; AccessName = 'AD_Users';  ReviewerName = 'Mgr One';   DecisionDate = '2026-03-15T10:00:00Z' }
                    [PSCustomObject]@{ IdentityName = 'Bob Smith';     AccessName = 'AD_Users';  ReviewerName = 'Mgr One';   DecisionDate = '2026-03-15T10:05:00Z' }
                    [PSCustomObject]@{ IdentityName = 'Dave Lee';      AccessName = 'VPN_Access'; ReviewerName = 'Mgr Three'; DecisionDate = '2026-03-15T11:00:00Z' }
                )
                Revoked = @(
                    [PSCustomObject]@{ IdentityName = 'Carol Davis';   AccessName = 'AD_Admins'; ReviewerName = 'Mgr Two';   DecisionDate = '2026-03-15T10:30:00Z' }
                )
                Pending = @(
                    [PSCustomObject]@{ IdentityName = 'Eve Park';      AccessName = 'FileShare'; ReviewerName = $null;       DecisionDate = $null }
                )
            }

            $script:la02Result = Group-SPAuditByLeadership `
                -Decisions $script:la02Decisions `
                -OrgTree $script:la02Tree
        }

        It "Should attribute Alice/Bob/Carol to Director A (id-dir-a)" {
            $dirA = $script:la02Result['Directors']['id-dir-a']
            $dirA | Should -Not -BeNullOrEmpty
            $dirA.TotalItems | Should -Be 3
            $dirA.Approved   | Should -Be 2   # Alice + Bob
            $dirA.Revoked    | Should -Be 1   # Carol
            $dirA.Pending    | Should -Be 0
        }

        It "Should attribute Dave/Eve to Director B (id-dir-b)" {
            $dirB = $script:la02Result['Directors']['id-dir-b']
            $dirB | Should -Not -BeNullOrEmpty
            $dirB.TotalItems | Should -Be 2
            $dirB.Approved   | Should -Be 1   # Dave
            $dirB.Revoked    | Should -Be 0
            $dirB.Pending    | Should -Be 1   # Eve
        }

        It "Should NOT cross-attribute: Director A holds none of Director B's identities" {
            # Director A's manager subtree must be exactly Mgr1 + Mgr2 (not Mgr3).
            $dirA = $script:la02Result['Directors']['id-dir-a']
            @($dirA.Managers.Keys) | Should -Contain 'id-mgr1'
            @($dirA.Managers.Keys) | Should -Contain 'id-mgr2'
            @($dirA.Managers.Keys) | Should -Not -Contain 'id-mgr3'
        }

        It "Should make each director's TotalItems == sum of its managers' items (no double-count)" {
            foreach ($dirId in @('id-dir-a', 'id-dir-b')) {
                $d = $script:la02Result['Directors'][$dirId]
                $mgrApproved = 0; $mgrRevoked = 0; $mgrPending = 0
                foreach ($mgrId in $d.Managers.Keys) {
                    $m = $d.Managers[$mgrId]
                    $mgrApproved += $m.Approved
                    $mgrRevoked  += $m.Revoked
                    $mgrPending  += $m.Pending
                }
                ($mgrApproved + $mgrRevoked + $mgrPending) | Should -Be $d.TotalItems
                $mgrApproved | Should -Be $d.Approved
                $mgrRevoked  | Should -Be $d.Revoked
                $mgrPending  | Should -Be $d.Pending
            }
        }

        It "Should roll the VP Executive total to the sum of both directors, counted once" {
            $vp = $script:la02Result['Executive']['id-vp']
            $vp | Should -Not -BeNullOrEmpty
            $vp.Name       | Should -Be 'VP Smith'
            $vp.TotalItems | Should -Be 5   # 3 (DirA) + 2 (DirB), each leaf counted once
            $vp.Approved   | Should -Be 3   # Alice, Bob, Dave
            $vp.Revoked    | Should -Be 1   # Carol
            $vp.Pending    | Should -Be 1   # Eve
        }

        It "Should reference exactly the two directors under the VP" {
            $vp = $script:la02Result['Executive']['id-vp']
            @($vp.Directors).Count | Should -Be 2
            @($vp.Directors) | Should -Contain 'id-dir-a'
            @($vp.Directors) | Should -Contain 'id-dir-b'
        }

        It "Should satisfy Approved + Revoked + Pending == TotalItems for every director AND the VP" {
            foreach ($dirId in $script:la02Result['Directors'].Keys) {
                $d = $script:la02Result['Directors'][$dirId]
                ($d.Approved + $d.Revoked + $d.Pending) | Should -Be $d.TotalItems
            }
            $vp = $script:la02Result['Executive']['id-vp']
            ($vp.Approved + $vp.Revoked + $vp.Pending) | Should -Be $vp.TotalItems
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LA-03: orphaned identity goes to __unmanaged__, not silently dropped
# ---------------------------------------------------------------------------

Describe "LA-03: orphaned/missing-manager identity goes to the documented __unmanaged__ bucket, not silently dropped" {

    Context "When a decision names an identity not present in the org tree" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            $script:la03Tree = New-MockOrgTreeData

            # One real identity (Alice -> DirA) plus one orphan whose name resolves
            # to no leaf node in the tree at all (mirror LR-03 unknown-identity case).
            $script:la03Decisions = @{
                Approved = @(
                    [PSCustomObject]@{ IdentityName = 'Alice Johnson';  AccessName = 'AD_Users'; ReviewerName = 'Mgr One'; DecisionDate = '2026-03-15T10:00:00Z' }
                    [PSCustomObject]@{ IdentityName = 'Orphan Olsen';   AccessName = 'VPN';      ReviewerName = 'Nobody';  DecisionDate = '2026-03-15T11:00:00Z' }
                )
                Revoked = @()
                Pending = @()
            }

            $script:la03Result = Group-SPAuditByLeadership `
                -Decisions $script:la03Decisions `
                -OrgTree $script:la03Tree
        }

        It "Should create the __unmanaged__ bucket with exactly the 1 orphan item" {
            $script:la03Result['Directors'].ContainsKey('__unmanaged__') | Should -Be $true
            $script:la03Result['Directors']['__unmanaged__'].TotalItems | Should -Be 1
            $script:la03Result['Directors']['__unmanaged__'].Approved   | Should -Be 1
        }

        It "Should NOT count the orphan under any real director" {
            # Director A holds only Alice (1 item); total across real directors == 1.
            $realTotal = 0
            foreach ($dirId in $script:la03Result['Directors'].Keys) {
                if ($dirId -eq '__unmanaged__') { continue }
                $realTotal += $script:la03Result['Directors'][$dirId].TotalItems
            }
            $realTotal | Should -Be 1
            $script:la03Result['Directors']['id-dir-a'].TotalItems | Should -Be 1
        }

        It "Should not silently drop any decision (real + unmanaged totals == 2)" {
            $allTotal = 0
            foreach ($dirId in $script:la03Result['Directors'].Keys) {
                $allTotal += $script:la03Result['Directors'][$dirId].TotalItems
            }
            $allTotal | Should -Be 2
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region LA-04: band attribution honors ISC (jobLevel) override over depth
# ---------------------------------------------------------------------------

Describe "LA-04: band attribution honors supplement/ISC override on the same A-E chain" {

    Context "When one node carries an ISC jobLevel that disagrees with its tree depth" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            $script:la04Details = @{
                'la04-ic'  = New-MockIdentityDetail -IdentityId 'la04-ic'  -DisplayName 'IC Four'      -ManagerId 'la04-mgr' -ManagerName 'Mgr Four'
                'la04-mgr' = New-MockIdentityDetail -IdentityId 'la04-mgr' -DisplayName 'Mgr Four'     -ManagerId 'la04-dir' -ManagerName 'Dir Four'
                'la04-dir' = New-MockIdentityDetail -IdentityId 'la04-dir' -DisplayName 'Dir Four'     -ManagerId ''         -ManagerName ''
            }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:la04Details.ContainsKey($IdentityId)) {
                    return $script:la04Details[$IdentityId]
                }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:la04Tree = Build-SPOrgTree -IdentityIds @('la04-ic') -MaxDepth 4

            # Seed an ISC band attribute on the IC node: jobLevel 'B' should WIN over
            # its depth (level 0 -> would be 'E'). Mirror OC-06 cache pattern.
            InModuleScope SP.IdentityService {
                $script:IdentityCache['la04-ic'] = @{
                    IdentityId  = 'la04-ic'
                    Email       = 'ic4@corp.com'
                    JobLevel    = 'B'
                    Found       = $true
                    DisplayName = 'IC Four'
                }
            }

            $script:la04Band = Resolve-SPIdentityBand -OrgTree $script:la04Tree.Data
        }

        AfterAll {
            InModuleScope SP.IdentityService {
                $script:IdentityCache.Remove('la04-ic')
            }
        }

        It "Should let ISC jobLevel override depth for the seeded node" {
            $script:la04Band.Data.Bands['la04-ic']   | Should -Be 'B'
            $script:la04Band.Data.Sources['la04-ic'] | Should -Be 'ISC'
        }

        It "Should still source the un-seeded nodes from Depth" {
            $script:la04Band.Data.Sources['la04-mgr'] | Should -Be 'Depth'
            $script:la04Band.Data.Sources['la04-dir'] | Should -Be 'Depth'
            # Manager at level 1 -> D, Director at level 2 -> C.
            $script:la04Band.Data.Bands['la04-mgr']   | Should -Be 'D'
            $script:la04Band.Data.Bands['la04-dir']   | Should -Be 'C'
        }
    }
}

#endregion
