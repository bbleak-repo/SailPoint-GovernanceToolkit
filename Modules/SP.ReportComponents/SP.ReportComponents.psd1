@{
    RootModule           = 'SP.ReportComponents.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'ec37b644-7e69-41d0-8bf8-d373fb7f2622'
    Author               = 'SailPoint ISC Governance Toolkit'
    CompanyName          = 'SailPoint ISC Governance Toolkit'
    Copyright            = '(c) 2026 SailPoint ISC Governance Toolkit. All rights reserved.'
    Description          = 'Composable, data-source-agnostic HTML report-component engine (RC framework), ported verbatim from Group-Enumerator. Pure presentation; no SP.* or platform dependency.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    # SP.Shared is auto-imported by RC00-Framework if not already loaded.
    RequiredModules      = @()
    FunctionsToExport    = @(
        'New-ComposableReport', 'New-RCContext', 'Get-RCTheme', 'Get-RCSharedCss',
        'Register-RCComponent', 'Get-RCComponentRegistry', 'Get-RCComponentKeys',
        'Expand-RCComponentList', 'ConvertTo-RCComponentSpec', 'Test-RCRequirement',
        'ConvertTo-RCHtmlText', 'Get-RCProp', 'Get-RCDirectCount',
        'New-RCKpiCardsComponent', 'New-RCHeatmapComponent', 'New-RCTreeComponent',
        'New-RCDiffComponent', 'New-RCTopNComponent', 'New-RCGroupTableComponent'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
