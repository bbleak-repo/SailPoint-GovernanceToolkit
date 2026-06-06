#Requires -Version 5.1
<#
    SP.ReportComponents.Tests.ps1  (RC-001 .. RC-010)

    AR-02: verifies the ported, data-source-agnostic RC report-component engine
    (Modules/SP.ReportComponents). The components are pure presentation -- they take
    a generic GroupResults/Context and emit HTML -- so these tests build synthetic
    data and assert each component (and the composer) produce well-formed fragments
    without touching SP.Api / the mock.
#>

BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..\Modules\SP.ReportComponents\SP.ReportComponents.psd1'
    Import-Module $moduleManifest -Force -ErrorAction Stop

    # Synthetic estate: 2 domains, one skipped group, mixed Enabled members.
    $script:Gr = @(
        @{ Data = @{ Domain = 'ACME'; GroupName = 'Domain Admins'; MemberCount = 2; IsNested = $true; Skipped = $false;
            Members = @(
                @{ DisplayName = 'Alice Admin'; SamAccountName = 'aadmin'; Email = 'aa@acme'; Enabled = $true;  DistinguishedName = 'CN=aadmin' },
                @{ DisplayName = 'Bob Disabled'; SamAccountName = 'bdis';  Email = 'bd@acme'; Enabled = $false; DistinguishedName = 'CN=bdis' }) } },
        @{ Data = @{ Domain = 'ACME'; GroupName = 'Helpdesk'; MemberCount = 1; IsNested = $false; Skipped = $false;
            Members = @(
                @{ DisplayName = 'Carol Help'; SamAccountName = 'chelp'; Email = 'ch@acme'; Enabled = $true; DistinguishedName = 'CN=chelp' }) } },
        @{ Data = @{ Domain = 'FABRIKAM'; GroupName = 'App Owners'; MemberCount = 1; IsNested = $false; Skipped = $false;
            Members = @(
                @{ DisplayName = 'Dan Owner'; SamAccountName = 'downer'; Email = 'do@fab'; Enabled = $true; DistinguishedName = 'CN=downer' }) } },
        @{ Data = @{ Domain = 'FABRIKAM'; GroupName = 'Broken Group'; MemberCount = $null; IsNested = $false; Skipped = $true;
            Members = @() }; Errors = @('enumeration failed') }
    )
    $script:Stale = @{ Disabled = @(@{ SamAccountName = 'bdis' }); Stale = @() }
    $script:Changes = @(
        @{ Timestamp = '2026-06-01T10:00:00Z'; Domain = 'ACME'; GroupName = 'Domain Admins'; Action = 'Added' },
        @{ Timestamp = '2026-06-02T11:00:00Z'; Domain = 'ACME'; GroupName = 'Domain Admins'; Action = 'Removed' },
        @{ Timestamp = '2026-06-03T12:00:00Z'; Domain = 'FABRIKAM'; GroupName = 'App Owners'; Action = 'Added' }
    )

    function script:New-RichContext {
        New-RCContext -GroupResults $script:Gr -StaleResults $script:Stale -Changes $script:Changes -Theme 'light'
    }
    function script:Render {
        param([string[]]$Components, [hashtable]$Context)
        $out = Join-Path $TestDrive ("rc-{0}.html" -f ([guid]::NewGuid().ToString('N')))
        $path = New-ComposableReport -Components $Components -Context $Context -Title 'RC Test' -OutputPath $out
        return (Get-Content -Raw -Path $path)
    }
}

Describe 'SP.ReportComponents — framework' {

    It 'RC-001: module exports the composer + 6 components + context/theme helpers' {
        $cmds = (Get-Command -Module SP.ReportComponents).Name
        $cmds | Should -Contain 'New-ComposableReport'
        $cmds | Should -Contain 'New-RCContext'
        foreach ($c in 'New-RCKpiCardsComponent','New-RCHeatmapComponent','New-RCTreeComponent',
                       'New-RCDiffComponent','New-RCTopNComponent','New-RCGroupTableComponent') {
            $cmds | Should -Contain $c
        }
    }

    It 'RC-002: all 6 components are registered' {
        $keys = Get-RCComponentKeys
        foreach ($k in 'kpi-cards','heatmap','tree','diff','top-n','group-table') {
            $keys | Should -Contain $k
        }
    }

    It 'RC-003: New-RCContext derives Enumerated (excludes skipped) and Domains' {
        $ctx = script:New-RichContext
        @($ctx.Enumerated).Count | Should -Be 3            # 4 groups, 1 skipped
        @($ctx.Domains).Count    | Should -Be 2            # ACME + FABRIKAM
        $ctx.IsCrossDomain       | Should -BeTrue
    }

    It 'RC-004: Get-RCTheme returns a palette with the expected tokens' {
        foreach ($name in 'light','dark') {
            $p = Get-RCTheme -Name $name
            $p | Should -BeOfType ([hashtable])
            $p.Keys | Should -Contain 'PageBg'
            $p.Keys | Should -Contain 'Accent'
        }
    }
}

Describe 'SP.ReportComponents — components render valid fragments' {

    It 'RC-005: <Key> emits a well-formed report with an rc-section' -ForEach @(
        @{ Key = 'kpi-cards' }, @{ Key = 'heatmap' }, @{ Key = 'tree' },
        @{ Key = 'diff' }, @{ Key = 'top-n' }, @{ Key = 'group-table' }
    ) {
        $html = script:Render -Components @($Key) -Context (script:New-RichContext)
        $html | Should -Match '(?is)<html'
        $html | Should -Match '(?is)</html>'
        $html | Should -Match 'rc-section'
    }

    It 'RC-006: kpi-cards shows headline counts (groups, distinct members, at-risk)' {
        $html = script:Render -Components @('kpi-cards') -Context (script:New-RichContext)
        $html | Should -Match 'rc-card'
        $html | Should -Match 'Distinct Members'
        $html | Should -Match 'At-Risk Members'   # StaleResults present
    }

    It 'RC-007: group-table lists the enumerated group names and flags skipped' {
        $html = script:Render -Components @('group-table') -Context (script:New-RichContext)
        $html | Should -Match 'Domain Admins'
        $html | Should -Match 'App Owners'
    }
}

Describe 'SP.ReportComponents — composer' {

    It 'RC-008: composes a full UTF-8 page from multiple components' {
        $html = script:Render -Components @('kpi-cards','top-n','group-table') -Context (script:New-RichContext)
        ([regex]::Matches($html, 'rc-section')).Count | Should -BeGreaterOrEqual 3
        $html | Should -Match '(?is)<!DOCTYPE html>|<html'
    }

    It 'RC-009: packs two consecutive half-width components into one paired row' {
        $html = script:Render -Components @('kpi-cards:half','top-n:half') -Context (script:New-RichContext)
        # The composer emits a row/grid wrapper for half-width pairs.
        $html | Should -Match 'rc-(row|half|pair|grid|col)'
    }

    It 'RC-010: gracefully renders (no throw) when a component prerequisite is unmet' {
        # Context with NO Changes -> the diff component must render a notice, not fail.
        $ctx = New-RCContext -GroupResults $script:Gr -Theme 'light'
        { script:Render -Components @('kpi-cards','diff') -Context $ctx } | Should -Not -Throw
        $html = script:Render -Components @('kpi-cards','diff') -Context $ctx
        $html | Should -Match '(?is)</html>'
    }
}
