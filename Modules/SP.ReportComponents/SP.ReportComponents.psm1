# SP.ReportComponents.psm1 -- root module for the composable report-component engine.
#
# Loads the RC framework (a verbatim, data-source-agnostic copy of the
# Group-Enumerator ReportComponents library -- see docs/planning/ADAPTIVE_REPORTS.md
# and docs/adaptive-reports-backlog.md AR-01). RC00 MUST load first: it defines
# the registry ($script:RCComponentRegistry) + Register-RCComponent; RC01..RC06
# self-register against it at dot-source. Dot-sourcing all RC files into this one
# module scope keeps the registry, framework functions, and components in a single
# consistent scope (New-ComposableReport reads the same $script: registry the
# components registered into).
#
# This module is pure presentation (no SP.* dependency, no AD/Graph/ISC calls); it
# takes a generic GroupResults data bag and emits HTML. The SailPoint data is
# mapped into that shape by SP.AdaptiveReports (AR-03/AR-05).

$here = $PSScriptRoot

foreach ($rc in @(
    'RC00-Framework.ps1',   # first: registry + Register-RCComponent + framework
    'RC01-KpiCards.ps1',
    'RC02-Heatmap.ps1',
    'RC03-Tree.ps1',
    'RC04-Diff.ps1',
    'RC05-TopN.ps1',
    'RC06-GroupTable.ps1'
)) {
    . (Join-Path $here $rc)
}

Export-ModuleMember -Function @(
    # Framework / composer
    'New-ComposableReport', 'New-RCContext', 'Get-RCTheme', 'Get-RCSharedCss',
    'Register-RCComponent', 'Get-RCComponentRegistry', 'Get-RCComponentKeys',
    'Expand-RCComponentList', 'ConvertTo-RCComponentSpec', 'Test-RCRequirement',
    'ConvertTo-RCHtmlText', 'Get-RCProp', 'Get-RCDirectCount',
    # Components
    'New-RCKpiCardsComponent', 'New-RCHeatmapComponent', 'New-RCTreeComponent',
    'New-RCDiffComponent', 'New-RCTopNComponent', 'New-RCGroupTableComponent'
)
