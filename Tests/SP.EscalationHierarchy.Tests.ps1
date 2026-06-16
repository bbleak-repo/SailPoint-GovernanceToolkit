#Requires -Modules Pester

<#
.SYNOPSIS
    Tests escalation per-manager HTML hierarchy rendering across multiple tiers.
.DESCRIPTION
    Creates org chains of varying depth, builds escalation levelData structures,
    and validates the renderSubTree recursion produces correct HTML content at
    each tier level.

    Org chain (5 levels):
      Reviewer:   Mgr Adams (006), Mgr Baker (007) -- late reviewers
      Level 2:    Dir Xavier (003) -- manages both reviewers
      Level 3:    VP Yamamoto (002) -- manages Dir Xavier
      Level 4:    SVP Zhang (001) -- manages VP Yamamoto

    6-level chain (adds a CEO above SVP):
      Level 5:    CEO Park (000) -- manages SVP Zhang
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core
}

Describe 'EH: Escalation Hierarchy -- per-manager HTML across tiers' {

    BeforeAll {
        # Identities for 5-level org
        $script:Identities = @{
            'id-000' = @{ IdentityId='id-000'; DisplayName='CEO Park'; ManagerId=''; ManagerName=''; IsActive=$true; Found=$true; CloudLifecycleState='active'; Email='ceo.park@corp.test'; JobLevel='CEO' }
            'id-001' = @{ IdentityId='id-001'; DisplayName='SVP Zhang'; ManagerId='id-000'; ManagerName='CEO Park'; IsActive=$true; Found=$true; CloudLifecycleState='active'; Email='svp.zhang@corp.test'; JobLevel='SVP' }
            'id-002' = @{ IdentityId='id-002'; DisplayName='VP Yamamoto'; ManagerId='id-001'; ManagerName='SVP Zhang'; IsActive=$true; Found=$true; CloudLifecycleState='active'; Email='vp.yamamoto@corp.test'; JobLevel='VP' }
            'id-003' = @{ IdentityId='id-003'; DisplayName='Dir Xavier'; ManagerId='id-002'; ManagerName='VP Yamamoto'; IsActive=$true; Found=$true; CloudLifecycleState='active'; Email='dir.xavier@corp.test'; JobLevel='Director' }
            'id-006' = @{ IdentityId='id-006'; DisplayName='Mgr Adams'; ManagerId='id-003'; ManagerName='Dir Xavier'; IsActive=$true; Found=$true; CloudLifecycleState='active'; Email='mgr.adams@corp.test'; JobLevel='Manager' }
            'id-007' = @{ IdentityId='id-007'; DisplayName='Mgr Baker'; ManagerId='id-003'; ManagerName='Dir Xavier'; IsActive=$true; Found=$true; CloudLifecycleState='active'; Email='mgr.baker@corp.test'; JobLevel='Manager' }
        }

        # Build fake late reviewer rows
        $script:LateRows = @(
            [PSCustomObject]@{ ReviewerName='Mgr Adams'; ReviewerEmail='mgr.adams@corp.test'; ReviewerIdentityId='id-006'; CertSigned=$false; CampaignName='Q2 Review'; CampaignId='camp-001'; SkipLevelIdentityId='id-003'; SkipLevelResolved=$true; Total=20; Approved=5; Revoked=2; Pending=13 }
            [PSCustomObject]@{ ReviewerName='Mgr Baker'; ReviewerEmail='mgr.baker@corp.test'; ReviewerIdentityId='id-007'; CertSigned=$false; CampaignName='Q2 Review'; CampaignId='camp-001'; SkipLevelIdentityId='id-003'; SkipLevelResolved=$true; Total=15; Approved=3; Revoked=1; Pending=11 }
        )

        # Helper: build chains and levelData from identities + lateRows
        function Build-TestEscalationData {
            param([int]$MaxLevels, [hashtable]$Identities, [object[]]$LateRows)

            $chains = [System.Collections.Generic.List[object]]::new()
            foreach ($row in $LateRows) {
                $chain = [System.Collections.Generic.List[object]]::new()
                $rid = $row.ReviewerIdentityId
                $rd = $Identities[$rid]
                $chain.Add(@{ IdentityId=$rid; DisplayName=$row.ReviewerName; Email=$row.ReviewerEmail; ManagerId=$rd.ManagerId; Found=$true; Row=$row })

                $curId = $rd.ManagerId
                for ($lvl = 1; $lvl -le $MaxLevels; $lvl++) {
                    if ([string]::IsNullOrWhiteSpace($curId)) { break }
                    $d = $Identities[$curId]
                    if ($null -eq $d -or -not $d.Found) { break }
                    $chain.Add(@{ IdentityId=$d.IdentityId; DisplayName=$d.DisplayName; Email=$d.Email; ManagerId=$d.ManagerId; Found=$true })
                    $curId = $d.ManagerId
                }
                $chains.Add($chain)
            }

            $levelData = @{}
            foreach ($chain in $chains) {
                $reviewerRow = $chain[0].Row
                for ($ci = 1; $ci -lt $chain.Count; $ci++) {
                    $ln = $ci + 1
                    $me = $chain[$ci]; $mid = [string]$me.IdentityId
                    if (-not $levelData.ContainsKey($ln)) { $levelData[$ln] = @{} }
                    if (-not $levelData[$ln].ContainsKey($mid)) {
                        $levelData[$ln][$mid] = @{
                            IdentityId=$mid; DisplayName=[string]$me.DisplayName; Email=[string]$me.Email
                            FirstName=([string]$me.DisplayName -split ' ')[0]
                            DirectReviewers=[System.Collections.Generic.List[object]]::new()
                            Subordinates=[ordered]@{}
                        }
                    }
                    $md = $levelData[$ln][$mid]
                    if ($ln -eq 2) { $md.DirectReviewers.Add($reviewerRow) }
                    else {
                        $se = $chain[$ci - 1]; $sid = [string]$se.IdentityId
                        if (-not $md.Subordinates.Contains($sid)) {
                            $md.Subordinates[$sid] = @{ IdentityId=$sid; DisplayName=[string]$se.DisplayName; Email=[string]$se.Email; Reviewers=[System.Collections.Generic.List[object]]::new() }
                        }
                        $md.Subordinates[$sid].Reviewers.Add($reviewerRow)
                    }
                }
            }
            return @{ Chains = $chains; LevelData = $levelData }
        }

        # Helper: renderSubTree (replicated from escalation script)
        function Invoke-RenderSubTree {
            param([System.Text.StringBuilder]$sb, [string]$mgrId, [int]$mgrLevel, [int]$targetLevel, [hashtable]$LevelData)

            if (-not $LevelData.ContainsKey($mgrLevel) -or -not $LevelData[$mgrLevel].ContainsKey($mgrId)) { return 0 }
            $mgrNode = $LevelData[$mgrLevel][$mgrId]
            $totalReviewers = 0

            if ($mgrLevel -eq 2) {
                $directRows = @($mgrNode.DirectReviewers)
                if ($directRows.Count -eq 0) { return 0 }
                $totalReviewers = $directRows.Count
                [void]$sb.AppendLine("<h2>$($mgrNode.DisplayName) -- $($directRows.Count) outstanding</h2>")
                [void]$sb.AppendLine('<table><tbody>')
                foreach ($r in $directRows) { [void]$sb.AppendLine("<tr><td>$($r.ReviewerName)</td><td>$($r.CampaignName)</td></tr>") }
                [void]$sb.AppendLine('</tbody></table>')
            }
            else {
                $childContent = New-Object System.Text.StringBuilder
                $childTotal = 0
                foreach ($subId in $mgrNode.Subordinates.Keys) {
                    $childCount = Invoke-RenderSubTree -sb $childContent -mgrId $subId -mgrLevel ($mgrLevel - 1) -targetLevel $targetLevel -LevelData $LevelData
                    $childTotal += $childCount
                }
                if ($childTotal -gt 0) {
                    [void]$sb.AppendLine("<h2>$($mgrNode.DisplayName) -- $childTotal outstanding</h2>")
                    [void]$sb.Append($childContent.ToString())
                    $totalReviewers = $childTotal
                }
            }
            return $totalReviewers
        }
    }

    Context 'EH-01: 4-level escalation (MaxLevels=3, levels 2-4)' {
        BeforeAll {
            # MaxLevels=3: reviewer -> Dir Xavier -> VP Yamamoto -> SVP Zhang
            $script:Result3 = Build-TestEscalationData -MaxLevels 3 -Identities $script:Identities -LateRows $script:LateRows
        }

        It 'chains should be length 4 (reviewer + 3 managers)' {
            $script:Result3.Chains[0].Count | Should -Be 4
        }

        It 'levelData should have levels 2, 3, 4' {
            @($script:Result3.LevelData.Keys | Sort-Object) | Should -Be @(2, 3, 4)
        }

        It 'level 2 has Dir Xavier with 2 direct reviewers' {
            $l2 = $script:Result3.LevelData[2]
            $l2.Count | Should -Be 1
            $l2['id-003'].DisplayName | Should -Be 'Dir Xavier'
            $l2['id-003'].DirectReviewers.Count | Should -Be 2
        }

        It 'level 3 has VP Yamamoto with Dir Xavier as subordinate' {
            $l3 = $script:Result3.LevelData[3]
            $l3['id-002'].Subordinates.Count | Should -Be 1
            $l3['id-002'].Subordinates.Keys | Should -Contain 'id-003'
        }

        It 'level 4 has SVP Zhang with VP Yamamoto as subordinate' {
            $l4 = $script:Result3.LevelData[4]
            $l4['id-001'].Subordinates.Count | Should -Be 1
            $l4['id-001'].Subordinates.Keys | Should -Contain 'id-002'
        }

        It 'level 2 HTML renders both reviewers under Dir Xavier' {
            $sb = New-Object System.Text.StringBuilder
            $count = Invoke-RenderSubTree -sb $sb -mgrId 'id-003' -mgrLevel 2 -targetLevel 2 -LevelData $script:Result3.LevelData
            $count | Should -Be 2
            $html = $sb.ToString()
            $html | Should -Match 'Mgr Adams'
            $html | Should -Match 'Mgr Baker'
        }

        It 'level 3 HTML renders VP Yamamoto -> Dir Xavier -> 2 reviewers' {
            $sb = New-Object System.Text.StringBuilder
            $count = Invoke-RenderSubTree -sb $sb -mgrId 'id-002' -mgrLevel 3 -targetLevel 3 -LevelData $script:Result3.LevelData
            $count | Should -Be 2
            $html = $sb.ToString()
            $html | Should -Match 'VP Yamamoto'
            $html | Should -Match 'Dir Xavier'
            $html | Should -Match 'Mgr Adams'
            $html | Should -Match 'Mgr Baker'
        }

        It 'level 4 HTML renders SVP Zhang -> VP Yamamoto -> Dir Xavier -> 2 reviewers' {
            $sb = New-Object System.Text.StringBuilder
            $count = Invoke-RenderSubTree -sb $sb -mgrId 'id-001' -mgrLevel 4 -targetLevel 4 -LevelData $script:Result3.LevelData
            $count | Should -Be 2
            $html = $sb.ToString()
            $html | Should -Match 'SVP Zhang'
            $html | Should -Match 'VP Yamamoto'
            $html | Should -Match 'Dir Xavier'
            $html | Should -Match 'Mgr Adams'
            $html | Should -Match 'Mgr Baker'
        }
    }

    Context 'EH-02: 5-level escalation (MaxLevels=4, levels 2-5 with CEO)' {
        BeforeAll {
            # MaxLevels=4: reviewer -> Dir Xavier -> VP Yamamoto -> SVP Zhang -> CEO Park
            $script:Result4 = Build-TestEscalationData -MaxLevels 4 -Identities $script:Identities -LateRows $script:LateRows
        }

        It 'chains should be length 5 (reviewer + 4 managers)' {
            $script:Result4.Chains[0].Count | Should -Be 5
        }

        It 'levelData should have levels 2, 3, 4, 5' {
            @($script:Result4.LevelData.Keys | Sort-Object) | Should -Be @(2, 3, 4, 5)
        }

        It 'level 5 has CEO Park' {
            $l5 = $script:Result4.LevelData[5]
            $l5.Count | Should -Be 1
            $l5['id-000'].DisplayName | Should -Be 'CEO Park'
        }

        It 'level 5 HTML renders CEO Park -> SVP Zhang -> VP Yamamoto -> Dir Xavier -> 2 reviewers' {
            $sb = New-Object System.Text.StringBuilder
            $count = Invoke-RenderSubTree -sb $sb -mgrId 'id-000' -mgrLevel 5 -targetLevel 5 -LevelData $script:Result4.LevelData
            $count | Should -Be 2
            $html = $sb.ToString()
            $html | Should -Match 'CEO Park'
            $html | Should -Match 'SVP Zhang'
            $html | Should -Match 'VP Yamamoto'
            $html | Should -Match 'Dir Xavier'
            $html | Should -Match 'Mgr Adams'
            $html | Should -Match 'Mgr Baker'
        }

        It 'level 4 HTML still renders correctly (SVP Zhang subtree)' {
            $sb = New-Object System.Text.StringBuilder
            $count = Invoke-RenderSubTree -sb $sb -mgrId 'id-001' -mgrLevel 4 -targetLevel 4 -LevelData $script:Result4.LevelData
            $count | Should -Be 2
            $html = $sb.ToString()
            $html | Should -Match 'SVP Zhang'
            $html | Should -Match 'VP Yamamoto'
            $html | Should -Match 'Dir Xavier'
            $html | Should -Match 'Mgr Adams'
        }
    }

    Context 'EH-03: Broken chain (manager not found in ISC)' {
        BeforeAll {
            # VP Yamamoto has no manager (simulate ISC data gap)
            $brokenIdentities = $script:Identities.Clone()
            $brokenIdentities['id-002'] = @{
                IdentityId='id-002'; DisplayName='VP Yamamoto'; ManagerId='id-999'
                ManagerName='Unknown VP'; IsActive=$true; Found=$true
                CloudLifecycleState='active'; Email='vp.yamamoto@corp.test'; JobLevel='VP'
            }
            # id-999 is NOT in identities -- chain will break
            $script:ResultBroken = Build-TestEscalationData -MaxLevels 4 -Identities $brokenIdentities -LateRows $script:LateRows
        }

        It 'chains should break at level 3 (VP Yamamoto has no resolvable manager)' {
            # Chain: reviewer -> Dir Xavier -> VP Yamamoto -> BREAK (id-999 not found)
            $script:ResultBroken.Chains[0].Count | Should -Be 3
        }

        It 'levelData should only have levels 2 and 3 (no 4 or 5)' {
            @($script:ResultBroken.LevelData.Keys | Sort-Object) | Should -Be @(2, 3)
        }

        It 'level 3 HTML still renders VP Yamamoto -> Dir Xavier -> reviewers' {
            $sb = New-Object System.Text.StringBuilder
            $count = Invoke-RenderSubTree -sb $sb -mgrId 'id-002' -mgrLevel 3 -targetLevel 3 -LevelData $script:ResultBroken.LevelData
            $count | Should -Be 2
            $html = $sb.ToString()
            $html | Should -Match 'VP Yamamoto'
            $html | Should -Match 'Dir Xavier'
            $html | Should -Match 'Mgr Adams'
            $html | Should -Match 'Mgr Baker'
        }
    }
}
