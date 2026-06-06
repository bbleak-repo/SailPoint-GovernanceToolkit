#Requires -Version 5.1
<#
    SP.AdaptiveReports.Tests.ps1  (AR-001 .. AR-009)

    AR-04 (entitlement anchor) + AR-06 (campaign anchor): verifies Build-SPRCDataset
    pivots campaign-audit decision data into the RC GroupResults shape correctly.
    The adapter is a pure transform, so these tests use synthetic audits (matching
    the production decision-item shape) and assert grouping, dedup, disabled
    mapping, and end-to-end render compatibility with the RC engine.
#>

BeforeAll {
    $modRoot = Join-Path $PSScriptRoot '..\Modules'
    Import-Module (Join-Path $modRoot 'SP.AdaptiveReports\SP.AdaptiveReports.psd1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $modRoot 'SP.ReportComponents\SP.ReportComponents.psd1') -Force -ErrorAction Stop

    $script:Audits = @(
        @{ CampaignName = 'Q1 Access Review'; CampaignId = 'camp-1'; Decisions = @{
            Approved = @(
                @{ IdentityId = 'id-alice'; IdentityName = 'Alice'; SourceName = 'AD';   AccessName = 'Domain Admins'; Decision = 'APPROVE'; RiskFlags = @('PRIVILEGED') },
                @{ IdentityId = 'id-bob';   IdentityName = 'Bob';   SourceName = 'AD';   AccessName = 'Domain Admins'; Decision = 'APPROVE'; RiskFlags = @('PRIVILEGED', 'DISABLED') },
                @{ IdentityId = 'id-carol'; IdentityName = 'Carol'; SourceName = 'Okta'; AccessName = 'App-Reader';    Decision = 'APPROVE'; RiskFlags = @() })
            Revoked  = @( @{ IdentityId = 'id-dan'; IdentityName = 'Dan'; SourceName = 'AD'; AccessName = 'Helpdesk'; Decision = 'REVOKE'; RiskFlags = @() } )
            Pending  = @() } },
        @{ CampaignName = 'Q2 Access Review'; CampaignId = 'camp-2'; Decisions = @{
            Approved = @( @{ IdentityId = 'id-alice'; IdentityName = 'Alice'; SourceName = 'Okta'; AccessName = 'App-Reader'; Decision = 'APPROVE'; RiskFlags = @() } )
            Revoked = @(); Pending = @() } }
    )

    function script:Render-Dataset {
        param($Result)
        $ctx = New-RCContext -GroupResults $Result.Data.GroupResults -StaleResults $Result.Data.StaleResults -Theme light
        $out = Join-Path $TestDrive ("ds-{0}.html" -f ([guid]::NewGuid().ToString('N')))
        New-ComposableReport -Components @('kpi-cards', 'top-n', 'group-table') -Context $ctx -Title 'DS' -OutputPath $out | Out-Null
        return (Get-Content -Raw -Path $out)
    }
    function script:Group-ByName { param($Result, [string]$Name) @($Result.Data.GroupResults | Where-Object { $_.Data.GroupName -eq $Name })[0] }
}

Describe 'SP.AdaptiveReports — entitlement anchor (AR-04)' {
    BeforeAll { $script:E = Build-SPRCDataset -CampaignAudits $script:Audits -Anchor Entitlement }

    It 'AR-001: returns the Success/Data/Error envelope with GroupResults + StaleResults' {
        $script:E.Success | Should -BeTrue
        $script:E.Error   | Should -BeNullOrEmpty
        $script:E.Data.Keys | Should -Contain 'GroupResults'
        $script:E.Data.Keys | Should -Contain 'StaleResults'
    }

    It 'AR-002: groups by entitlement x source (3 distinct entitlement-groups)' {
        @($script:E.Data.GroupResults).Count | Should -Be 3
        ($script:E.Data.GroupResults.Data.GroupName | Sort-Object -Unique) | Should -Be @('App-Reader', 'Domain Admins', 'Helpdesk')
    }

    It 'AR-003: dedups identities across campaigns (Okta/App-Reader holds 2 distinct)' {
        $g = script:Group-ByName -Result $script:E -Name 'App-Reader'
        $g.Data.Domain | Should -Be 'Okta'
        $g.Data.MemberCount | Should -Be 2          # Carol (Q1) + Alice (Q2)
        ($g.Data.Members.SamAccountName | Sort-Object) | Should -Be @('id-alice', 'id-carol')
    }

    It 'AR-004: maps RiskFlags DISABLED -> member Enabled=$false and StaleResults.Disabled' {
        $g = script:Group-ByName -Result $script:E -Name 'Domain Admins'
        $bob = @($g.Data.Members | Where-Object { $_.SamAccountName -eq 'id-bob' })[0]
        $bob.Enabled | Should -BeFalse
        $alice = @($g.Data.Members | Where-Object { $_.SamAccountName -eq 'id-alice' })[0]
        $alice.Enabled | Should -BeTrue
        ($script:E.Data.StaleResults.Disabled.SamAccountName) | Should -Contain 'id-bob'
    }

    It 'AR-005: empty audits -> Success with 0 groups (no throw)' {
        $empty = Build-SPRCDataset -CampaignAudits @() -Anchor Entitlement
        $empty.Success | Should -BeTrue
        @($empty.Data.GroupResults).Count | Should -Be 0
    }

    It 'AR-006: output renders through the RC engine' {
        $html = script:Render-Dataset -Result $script:E
        $html | Should -Match '(?is)</html>'
        $html | Should -Match 'Domain Admins'
    }
}

Describe 'SP.AdaptiveReports — campaign anchor (AR-06)' {
    BeforeAll { $script:C = Build-SPRCDataset -CampaignAudits $script:Audits -Anchor Campaign }

    It 'AR-007: groups by campaign under a single synthetic domain' {
        @($script:C.Data.GroupResults).Count | Should -Be 2
        ($script:C.Data.GroupResults.Data.Domain | Sort-Object -Unique) | Should -Be @('ISC Campaigns')
        ($script:C.Data.GroupResults.Data.GroupName | Sort-Object) | Should -Be @('Q1 Access Review', 'Q2 Access Review')
    }

    It 'AR-008: distinct identities per campaign (Q1 = 4: alice, bob, carol, dan)' {
        $q1 = script:Group-ByName -Result $script:C -Name 'Q1 Access Review'
        $q1.Data.MemberCount | Should -Be 4
        $q2 = script:Group-ByName -Result $script:C -Name 'Q2 Access Review'
        $q2.Data.MemberCount | Should -Be 1
    }

    It 'AR-009: output renders through the RC engine' {
        $html = script:Render-Dataset -Result $script:C
        $html | Should -Match '(?is)</html>'
        $html | Should -Match 'Q1 Access Review'
    }
}
