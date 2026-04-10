@{
    # Script module or binary module file associated with this manifest.
    RootModule = ''

    # Version number of this module.
    ModuleVersion = '1.0.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop')

    # ID used to uniquely identify this module
    GUID = 'f2a8c3e1-7b4d-4e09-a1f5-d6c2b8e49031'

    # Author of this module
    Author = 'SailPoint Governance Toolkit Team'

    # Company or vendor of this module
    CompanyName = 'SailPoint Governance Toolkit'

    # Copyright statement for this module
    Copyright = '(c) 2026 SailPoint Governance Toolkit. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'SailPoint ISC Governance Toolkit - WPF GUI Module (Dashboard + Bridge Adapter)'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Dependency: SP.Core, SP.Api, and SP.Testing must be imported before SP.Gui (caller handles import order).
    RequiredModules = @()

    # WPF assemblies loaded at runtime by SP.MainWindow.psm1 (Windows only).
    # Not listed in RequiredAssemblies to allow import on non-Windows for testing.
    RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    ScriptsToProcess = @()

    # Type files (.ps1xml) to be loaded when importing this module
    TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess.
    # Load order: bridge first (no WPF dependencies), then main window (depends on bridge).
    NestedModules = @(
        'SP.GuiBridge.psm1',
        'SP.MainWindow.psm1'
    )

    # Functions to export from this module
    FunctionsToExport = @(
        'Show-SPDashboard',
        'Invoke-SPGuiTest',
        'Get-SPGuiCampaignList',
        'Get-SPGuiIdentityList',
        'Test-SPGuiConnectivity',
        'Set-SPGuiBrowserToken',
        'Get-SPGuiAuditCampaigns',
        'Invoke-SPGuiAudit',
        'Get-SPGuiAuditReports'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # DSC resources to export from this module
    DscResourcesToExport = @()

    # List of all modules packaged with this module
    ModuleList = @()

    # List of all files packaged with this module
    FileList = @(
        'SP.Gui.psd1',
        'SP.GuiBridge.psm1',
        'SP.MainWindow.psm1'
    )

    # Private data passed to the module specified in RootModule
    PrivateData = @{
        PSData = @{
            Tags         = @('SailPoint', 'ISC', 'IGA', 'Governance', 'WPF', 'GUI', 'Dashboard')
            ReleaseNotes = 'v1.0.0: Initial release - WPF dashboard with Campaign, Evidence, and Settings tabs. v1.1.0: Added Audit tab bridge functions (Get-SPGuiAuditCampaigns, Invoke-SPGuiAudit, Get-SPGuiAuditReports).'
        }
    }
}
