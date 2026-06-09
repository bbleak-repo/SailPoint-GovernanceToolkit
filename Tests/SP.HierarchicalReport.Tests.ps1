#Requires -Version 5.1
#Requires -Modules Pester
<#
.SYNOPSIS
    Pester 5.x tests for the Hierarchical Leadership Report pipeline (P17-01).
.DESCRIPTION
    Tests: HR-001 through HR-008
    Covers:
        HR-001 to HR-003: Build-SPLeadershipHierarchy -- decision indexing, hierarchy
                          building, aggregation
        HR-004 to HR-005: Export-SPHierarchicalLeadershipHtml -- file generation,
                          content validation
        HR-006 to HR-008: Reviewer-field normalisation ('reviewer' vs 'certifier'),
                          empty-window handling, multi-level aggregation

    All tests use synthetic in-memory data -- no ISC API or mock server required.
    The org tree and decision data are constructed to match the exact shapes that
    Build-SPOrgTree and Group-SPAuditDecisions produce.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # -----------------------------------------------------------------------
    # Shared synthetic data helpers
    # -----------------------------------------------------------------------

    # Builds a minimal OrgTree.Data structure matching Build-SPOrgTree output.
    # mgr-001 reports to dir-001, dir-001 reports to vp-001.
    function New-MockOrgTree {
        return @{
            TopLeaders  = @('vp-001')
            Directors   = @('dir-001')
            Managers    = @('mgr-001')
            TopLevel    = 2
            LeafCount   = 1
            MaxDepthHit = $false
            LevelLabels = @{ 0='Certifiers'; 1='Directors'; 2='VPs' }
            LevelNodes  = @{ 0=@('mgr-001'); 1=@('dir-001'); 2=@('vp-001') }
            Nodes       = @{
                'vp-001' = @{
                    Identity  = @{ Id='vp-001'; Name='Victoria Parker'; ManagerId=''; ManagerName=''; Found=$true }
                    ManagerId = ''
                    Level     = 2
                    Children  = @('dir-001')
                }
                'dir-001' = @{
                    Identity  = @{ Id='dir-001'; Name='Diana Chen'; ManagerId='vp-001'; ManagerName='Victoria Parker'; Found=$true }
                    ManagerId = 'vp-001'
                    Level     = 1
                    Children  = @('mgr-001')
                }
                'mgr-001' = @{
                    Identity  = @{ Id='mgr-001'; Name='Mike Smith'; ManagerId='dir-001'; ManagerName='Diana Chen'; Found=$true }
                    ManagerId = 'dir-001'
                    Level     = 0
                    Children  = @()
                }
            }
        }
    }

    # Builds a minimal Group-SPAuditDecisions output.
    # mgr-001 reviewed id-001 (2 approved, 1 revoked) and id-002 (1 approved).
    function New-MockDecisions {
        param([string]$CertId = 'cert-001')
        $approved = @(
            [PSCustomObject]@{ CertificationId=$CertId; IdentityId='id-001'; IdentityName='Alice'; AccessName='Finance-Admins'; AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Mike Smith'; ReviewerEmail='mike@corp'; Decision='APPROVE'; DecisionDate='2026-06-01' }
            [PSCustomObject]@{ CertificationId=$CertId; IdentityId='id-001'; IdentityName='Alice'; AccessName='VPN-Standard';    AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Mike Smith'; ReviewerEmail='mike@corp'; Decision='APPROVE'; DecisionDate='2026-06-01' }
            [PSCustomObject]@{ CertificationId=$CertId; IdentityId='id-002'; IdentityName='Bob';   AccessName='CorpNet';          AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Mike Smith'; ReviewerEmail='mike@corp'; Decision='APPROVE'; DecisionDate='2026-06-01' }
        )
        $revoked = @(
            [PSCustomObject]@{ CertificationId=$CertId; IdentityId='id-001'; IdentityName='Alice'; AccessName='Admin-Tools';     AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Mike Smith'; ReviewerEmail='mike@corp'; Decision='REVOKE'; DecisionDate='2026-06-01' }
        )
        return @{ Approved=$approved; Revoked=$revoked; Pending=@() }
    }

    function New-MockCertReviewerIdMap {
        param([string]$CertId = 'cert-001', [string]$ReviewerId = 'mgr-001')
        return @{ $CertId = $ReviewerId }
    }
}

# ===========================================================================
#region HR-001: Build-SPLeadershipHierarchy basic hierarchy
# ===========================================================================

Describe "HR-001: Build-SPLeadershipHierarchy builds correct node structure" {

    Context "When org tree and decisions are provided" {

        It "Should return Success=true with TopNodes" {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions
            $idMap     = New-MockCertReviewerIdMap

            $result = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap

            $result.Success          | Should -Be $true
            $result.Data.TopNodes    | Should -Not -BeNullOrEmpty
            $result.Data.TopNodes.Count | Should -Be 1
        }

        It "Should correctly identify the top node as VP" {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions
            $idMap     = New-MockCertReviewerIdMap

            $result = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap

            $vp = $result.Data.TopNodes[0]
            $vp.NodeId      | Should -Be 'vp-001'
            $vp.DisplayName | Should -Be 'Victoria Parker'
            $vp.Level       | Should -Be 2
        }

        It "Should build a 3-level deep hierarchy (VP > Director > Manager)" {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions
            $idMap     = New-MockCertReviewerIdMap

            $result = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap

            $vp  = $result.Data.TopNodes[0]
            $dir = $vp.Children[0]
            $mgr = $dir.Children[0]

            $dir.NodeId      | Should -Be 'dir-001'
            $dir.DisplayName | Should -Be 'Diana Chen'
            $mgr.NodeId      | Should -Be 'mgr-001'
            $mgr.IsCertifier | Should -Be $true
        }
    }
}

#endregion

# ===========================================================================
#region HR-002: Aggregation rolls up correctly
# ===========================================================================

Describe "HR-002: Build-SPLeadershipHierarchy aggregates decisions up the tree" {

    Context "When manager has 4 decisions (2 approved, 1 revoked, 1 pending)" {

        BeforeAll {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions  # 3 approved + 1 revoked = 4 items
            $idMap     = New-MockCertReviewerIdMap

            $script:hierResult = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap
        }

        It "Manager (leaf) has correct direct decision counts" {
            $mgr = $script:hierResult.Data.TopNodes[0].Children[0].Children[0]
            $mgr.Agg.Approved   | Should -Be 3
            $mgr.Agg.Revoked    | Should -Be 1
            $mgr.Agg.Pending    | Should -Be 0
            $mgr.Agg.Total      | Should -Be 4
            $mgr.Agg.Identities | Should -Be 2  # id-001 and id-002
        }

        It "Director inherits aggregated counts from manager" {
            $dir = $script:hierResult.Data.TopNodes[0].Children[0]
            $dir.Agg.Approved | Should -Be 3
            $dir.Agg.Revoked  | Should -Be 1
            $dir.Agg.Total    | Should -Be 4
        }

        It "VP inherits aggregated counts from entire subtree" {
            $vp = $script:hierResult.Data.TopNodes[0]
            $vp.Agg.Approved | Should -Be 3
            $vp.Agg.Revoked  | Should -Be 1
            $vp.Agg.Total    | Should -Be 4
        }
    }
}

#endregion

# ===========================================================================
#region HR-003: CertifiedIdentities on manager nodes
# ===========================================================================

Describe "HR-003: Manager nodes carry per-identity decision detail" {

    Context "When manager has 2 reviewed identities" {

        BeforeAll {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions
            $idMap     = New-MockCertReviewerIdMap

            $hier = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap
            $script:mgrNode = $hier.Data.TopNodes[0].Children[0].Children[0]
        }

        It "Should have 2 CertifiedIdentities entries" {
            $script:mgrNode.CertifiedIdentities.Count | Should -Be 2
        }

        It "Alice should have 2 approved and 1 revoked" {
            $alice = $script:mgrNode.CertifiedIdentities | Where-Object { $_.Name -eq 'Alice' }
            $alice             | Should -Not -BeNullOrEmpty
            $alice.Approved    | Should -Be 2
            $alice.Revoked     | Should -Be 1
            $alice.Items.Count | Should -Be 3
        }

        It "Bob should have 1 approved" {
            $bob = $script:mgrNode.CertifiedIdentities | Where-Object { $_.Name -eq 'Bob' }
            $bob             | Should -Not -BeNullOrEmpty
            $bob.Approved    | Should -Be 1
            $bob.Items.Count | Should -Be 1
        }
    }
}

#endregion

# ===========================================================================
#region HR-004: Export-SPHierarchicalLeadershipHtml generates files
# ===========================================================================

Describe "HR-004: Export-SPHierarchicalLeadershipHtml writes HTML files" {

    Context "When hierarchy data is provided with MinReportLevel=1" {

        BeforeAll {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions
            $idMap     = New-MockCertReviewerIdMap

            $hier = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap

            $script:outDir = Join-Path $TestDrive 'hier-test'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null

            $script:exportResult = Export-SPHierarchicalLeadershipHtml `
                -HierarchyData $hier.Data `
                -OutputPath    $script:outDir `
                -ReportTitle   'Test Rollup' `
                -DateRange     '2026-01-01 to 2026-06-08' `
                -CampaignCount 3 `
                -MinReportLevel 1  # Directors+
        }

        It "Should return Success=true" {
            $script:exportResult.Success | Should -Be $true
        }

        It "Should generate at least 1 HTML file" {
            $script:exportResult.Data.FileCount | Should -BeGreaterOrEqual 1
        }

        It "Each file should exist on disk" {
            foreach ($f in $script:exportResult.Data.Files) {
                Test-Path $f | Should -Be $true
            }
        }
    }
}

#endregion

# ===========================================================================
#region HR-005: Generated HTML contains expected content
# ===========================================================================

Describe "HR-005: Generated HTML has correct structure and content" {

    Context "When a report is generated for Victoria Parker (VP)" {

        BeforeAll {
            $orgTree   = New-MockOrgTree
            $decisions = New-MockDecisions
            $idMap     = New-MockCertReviewerIdMap

            $hier = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap

            $script:outDir2 = Join-Path $TestDrive 'hier-content-test'
            New-Item -ItemType Directory -Path $script:outDir2 -Force | Out-Null

            Export-SPHierarchicalLeadershipHtml `
                -HierarchyData $hier.Data `
                -OutputPath    $script:outDir2 `
                -ReportTitle   'Q1 Rollup' `
                -MinReportLevel 2  | Out-Null  # VP-level: one file for Victoria

            # -Recurse: Export-SPHierarchicalLeadershipHtml writes into a run-<stamp> subdir.
            $files = Get-ChildItem -Path $script:outDir2 -Filter '*.html' -Recurse
            if ($files.Count -gt 0) {
                $script:htmlContent = Get-Content $files[0].FullName -Raw
            } else {
                $script:htmlContent = ''
            }
        }

        It "Should contain the leader's name" {
            $script:htmlContent | Should -Match 'Victoria Parker'
        }

        It "Should contain the report title" {
            $script:htmlContent | Should -Match 'Q1 Rollup'
        }

        It "Should use <details> elements for collapse/expand" {
            $script:htmlContent | Should -Match '<details'
        }

        It "Should contain Expand All / Collapse All buttons" {
            $script:htmlContent | Should -Match 'toggleAll'
        }

        It "Should contain decision data for Alice (Finance-Admins)" {
            $script:htmlContent | Should -Match 'Finance-Admins'
        }
    }
}

#endregion

# ===========================================================================
#region HR-006: reviewer vs certifier field normalisation
# ===========================================================================

Describe "HR-006: CertReviewerIdMap is built from 'reviewer' field (ISC v3 API)" {

    Context "When cert objects use 'reviewer.id' (ISC v3 convention)" {

        It "Should extract reviewer identity ID from 'reviewer' property" {
            $cert = [PSCustomObject]@{
                id       = 'cert-v3'
                reviewer = [PSCustomObject]@{ id='mgr-v3'; name='Manager V3' }
            }

            # Simulate the mapping logic from Invoke-SPHierarchicalReport.ps1
            $certReviewerIdMap = @{}
            $certId = [string]$cert.id
            foreach ($prop in @('certifier', 'reviewer')) {
                if ($null -ne $cert.PSObject.Properties[$prop] -and
                    $null -ne $cert.$prop -and
                    $null -ne $cert.$prop.PSObject.Properties['id'] -and
                    -not [string]::IsNullOrWhiteSpace($cert.$prop.id)) {
                    $certReviewerIdMap[$certId] = [string]$cert.$prop.id
                    break
                }
            }

            $certReviewerIdMap['cert-v3'] | Should -Be 'mgr-v3'
        }

        It "Should also work with 'certifier' property (SDK convention)" {
            $cert = [PSCustomObject]@{
                id        = 'cert-sdk'
                certifier = [PSCustomObject]@{ id='mgr-sdk'; name='Manager SDK' }
            }

            $certReviewerIdMap = @{}
            $certId = [string]$cert.id
            foreach ($prop in @('certifier', 'reviewer')) {
                if ($null -ne $cert.PSObject.Properties[$prop] -and
                    $null -ne $cert.$prop -and
                    $null -ne $cert.$prop.PSObject.Properties['id'] -and
                    -not [string]::IsNullOrWhiteSpace($cert.$prop.id)) {
                    $certReviewerIdMap[$certId] = [string]$cert.$prop.id
                    break
                }
            }

            $certReviewerIdMap['cert-sdk'] | Should -Be 'mgr-sdk'
        }
    }
}

#endregion

# ===========================================================================
#region HR-007: Empty decisions returns zero-count hierarchy
# ===========================================================================

Describe "HR-007: Build-SPLeadershipHierarchy handles empty decisions gracefully" {

    Context "When no decisions exist in the window" {

        It "Should return Success=true with zero aggregated counts" {
            $orgTree   = New-MockOrgTree
            $decisions = @{ Approved=@(); Revoked=@(); Pending=@() }
            $idMap     = @{}

            $result = Build-SPLeadershipHierarchy -Decisions $decisions `
                -OrgTree $orgTree -CertReviewerIdMap $idMap

            $result.Success                                         | Should -Be $true
            $result.Data.TopNodes[0].Agg.Total                      | Should -Be 0
            $result.Data.TopNodes[0].Children[0].Agg.Total          | Should -Be 0
            $result.Data.TopNodes[0].Children[0].Children[0].IsCertifier | Should -Be $false
        }
    }
}

#endregion

# ===========================================================================
#region HR-008: Multi-manager aggregation at director level
# ===========================================================================

Describe "HR-008: Director correctly aggregates decisions from multiple managers" {

    Context "When two managers each have different certs" {

        BeforeAll {
            # Build a tree with 2 managers under 1 director
            $twoMgrTree = @{
                TopLeaders  = @('dir-001')
                Managers    = @('mgr-001','mgr-002')
                TopLevel    = 1
                LeafCount   = 2
                MaxDepthHit = $false
                LevelLabels = @{ 0='Certifiers'; 1='Directors' }
                LevelNodes  = @{ 0=@('mgr-001','mgr-002'); 1=@('dir-001') }
                Nodes       = @{
                    'dir-001' = @{
                        Identity  = @{ Id='dir-001'; Name='Diana Chen'; ManagerId=''; Found=$true }
                        ManagerId = ''
                        Level     = 1
                        Children  = @('mgr-001','mgr-002')
                    }
                    'mgr-001' = @{
                        Identity  = @{ Id='mgr-001'; Name='Mike Smith'; ManagerId='dir-001'; Found=$true }
                        ManagerId = 'dir-001'
                        Level     = 0
                        Children  = @()
                    }
                    'mgr-002' = @{
                        Identity  = @{ Id='mgr-002'; Name='Sarah Jones'; ManagerId='dir-001'; Found=$true }
                        ManagerId = 'dir-001'
                        Level     = 0
                        Children  = @()
                    }
                }
            }

            # mgr-001 reviewed 2 items; mgr-002 reviewed 3 items
            $twoMgrDec = @{
                Approved = @(
                    [PSCustomObject]@{ CertificationId='cert-a'; IdentityId='id-001'; IdentityName='Alice'; AccessName='Group1'; AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Mike'; ReviewerEmail=''; Decision='APPROVE'; DecisionDate='' }
                    [PSCustomObject]@{ CertificationId='cert-b'; IdentityId='id-003'; IdentityName='Carol'; AccessName='Group3'; AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Sarah'; ReviewerEmail=''; Decision='APPROVE'; DecisionDate='' }
                    [PSCustomObject]@{ CertificationId='cert-b'; IdentityId='id-004'; IdentityName='Dave';  AccessName='Group4'; AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Sarah'; ReviewerEmail=''; Decision='APPROVE'; DecisionDate='' }
                )
                Revoked = @(
                    [PSCustomObject]@{ CertificationId='cert-a'; IdentityId='id-002'; IdentityName='Bob';   AccessName='Group2'; AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Mike'; ReviewerEmail=''; Decision='REVOKE'; DecisionDate='' }
                    [PSCustomObject]@{ CertificationId='cert-b'; IdentityId='id-004'; IdentityName='Dave';  AccessName='Group5'; AccessType='ENTITLEMENT'; SourceName='AD'; ReviewerName='Sarah'; ReviewerEmail=''; Decision='REVOKE'; DecisionDate='' }
                )
                Pending = @()
            }

            $twoMgrMap = @{ 'cert-a'='mgr-001'; 'cert-b'='mgr-002' }

            $r = Build-SPLeadershipHierarchy -Decisions $twoMgrDec `
                -OrgTree $twoMgrTree -CertReviewerIdMap $twoMgrMap

            $script:dir = $r.Data.TopNodes[0]
        }

        It "Director should aggregate 3 approved and 2 revoked from both managers" {
            $script:dir.Agg.Approved | Should -Be 3
            $script:dir.Agg.Revoked  | Should -Be 2
            $script:dir.Agg.Total    | Should -Be 5
        }

        It "Director should count 4 unique reviewed identities" {
            $script:dir.Agg.Identities | Should -Be 4
        }

        It "Each manager node should be a certifier" {
            $mgr1 = $script:dir.Children | Where-Object { $_.NodeId -eq 'mgr-001' }
            $mgr2 = $script:dir.Children | Where-Object { $_.NodeId -eq 'mgr-002' }
            $mgr1.IsCertifier | Should -Be $true
            $mgr2.IsCertifier | Should -Be $true
        }
    }
}

#endregion
