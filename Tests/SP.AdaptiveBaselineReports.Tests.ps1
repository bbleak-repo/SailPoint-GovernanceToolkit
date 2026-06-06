#Requires -Version 5.1
<#
    SP.AdaptiveBaselineReports.Tests.ps1  (BR-001 .. BR-010)

    AR-11: verifies the ported baseline reports (B01/B02/B03/B04/B05/B06/B10) each
    emit a well-formed HTML file from real adapter output (Build-SPRCDataset), with
    no PowerShell error leaking into the markup. Reports are pure renderers over the
    RC GroupResults shape, so synthetic audits -> adapter -> report is the full path.
#>

# Defined at top-level/script scope so it is available at Pester DISCOVERY time
# (when -ForEach data is evaluated) as well as at run time.
$script:ReportFns = @(
    'Export-MembershipSnapshotRosterReport',
    'Export-AccessCertificationAttestationReport',
    'Export-PrivilegedGroupReviewReport',
    'Export-SodToxicComembershipReport',
    'Export-OrphanedDisabledMembersReport',
    'Export-GroupInventoryCatalogReport',
    'Export-GovernanceExecutiveSummaryReport'
)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.AdaptiveReports\SP.AdaptiveReports.psd1') -Force -DisableNameChecking -ErrorAction Stop

    $script:Audits = @(
        @{ CampaignName = 'Q1 Access Review'; CampaignId = 'c1'; Decisions = @{
            Approved = @(
                @{ IdentityId = 'id-a'; IdentityName = 'Alice Admin'; SourceName = 'AD';   AccessName = 'Domain Admins'; Decision = 'APPROVE'; RiskFlags = @('PRIVILEGED') },
                @{ IdentityId = 'id-b'; IdentityName = 'Bob Disabled'; SourceName = 'AD';   AccessName = 'Domain Admins'; Decision = 'APPROVE'; RiskFlags = @('PRIVILEGED', 'DISABLED') },
                @{ IdentityId = 'id-c'; IdentityName = 'Carol';        SourceName = 'Okta'; AccessName = 'App Reader';    Decision = 'APPROVE'; RiskFlags = @() })
            Revoked = @( @{ IdentityId = 'id-d'; IdentityName = 'Dan'; SourceName = 'AD'; AccessName = 'Helpdesk'; Decision = 'REVOKE'; RiskFlags = @() } )
            Pending = @() } }
    )
    $script:Gr = (Build-SPRCDataset -CampaignAudits $script:Audits -Anchor Entitlement).Data.GroupResults

    function script:Render-Report {
        param([string]$Fn, $GroupResults)
        $out = Join-Path $TestDrive ("{0}-{1}.html" -f $Fn, ([guid]::NewGuid().ToString('N')))
        & $Fn -GroupResults $GroupResults -OutputPath $out -Theme light | Out-Null
        return (Get-Content -Raw -Path $out)
    }
}

Describe 'SP.AdaptiveReports — baseline reports' {

    It 'BR-001: all 7 baseline report functions are exported' {
        $exported = (Get-Command -Module SP.AdaptiveReports).Name
        foreach ($r in $script:ReportFns) { $exported | Should -Contain $r }
    }

    It 'BR-002: <Fn> emits well-formed HTML with no error dump' -ForEach @(
        $script:ReportFns | ForEach-Object { @{ Fn = $_ } }
    ) {
        $html = script:Render-Report -Fn $Fn -GroupResults $script:Gr
        $html       | Should -Match '(?is)</html>'
        $html.Length | Should -BeGreaterThan 800
        $html       | Should -Not -Match 'At line:\d+ char:\d+'
        $html       | Should -Not -Match 'FullyQualifiedErrorId'
    }

    It 'BR-003: inventory lists the entitlement-group names' {
        $html = script:Render-Report -Fn 'Export-GroupInventoryCatalogReport' -GroupResults $script:Gr
        $html | Should -Match 'Domain Admins'
        $html | Should -Match 'App Reader'
    }

    It 'BR-004: privileged review flags the privileged entitlement' {
        $html = script:Render-Report -Fn 'Export-PrivilegedGroupReviewReport' -GroupResults $script:Gr
        $html | Should -Match 'Domain Admins'   # matches the privileged name heuristic
    }

    It 'BR-005: orphaned/disabled surfaces the disabled identity' {
        $html = script:Render-Report -Fn 'Export-OrphanedDisabledMembersReport' -GroupResults $script:Gr
        $html | Should -Match 'Bob Disabled'
    }

    It 'BR-006: SoD report carries the ISC starter rule-set' {
        $html = script:Render-Report -Fn 'Export-SodToxicComembershipReport' -GroupResults $script:Gr
        $html | Should -Match 'SailPoint ISC SoD Starter'
    }

    It 'BR-007: every report renders (no throw) on empty GroupResults' {
        foreach ($r in $script:ReportFns) {
            { script:Render-Report -Fn $r -GroupResults @() } | Should -Not -Throw -Because "$r must tolerate an empty estate"
        }
    }
}
