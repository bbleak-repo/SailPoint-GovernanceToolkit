@{
    # Module GUID
    GUID              = 'f3a1b2c4-5d6e-7f89-0a1b-2c3d4e5f6a7b'

    # Module version
    ModuleVersion     = '1.0.0'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Compatible editions
    CompatiblePSEditions = @('Desktop')

    # Module author and description
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = 'Internal'
    Description       = 'SailPoint ISC Governance Toolkit - Shared Utilities. Provides common HTML helpers, property accessors, and file-writing functions used across all report-generating modules. No dependencies on SP.Core, SP.Api, or any other toolkit module.'
    Copyright         = '(c) 2026. All rights reserved.'

    # No dependencies -- SP.Shared is a leaf module loaded before everything else.
    RequiredModules   = @()

    # Root module is empty; nested modules load in order.
    RootModule        = ''

    # Sub-modules
    NestedModules     = @(
        'SP.HtmlHelpers.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        'ConvertTo-SPHtmlSafe'
        'Format-SPHtmlDate'
        'Get-SPObjectProperty'
        'Get-SPHtmlColorPalette'
        'New-SPHtmlDocument'
        'Write-SPHtmlFile'
    )

    # Do not export variables or aliases
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}
