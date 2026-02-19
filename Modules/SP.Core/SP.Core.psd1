@{
    # Script module or binary module file associated with this manifest.
    RootModule = ''

    # Version number of this module.
    ModuleVersion = '1.0.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop')

    # ID used to uniquely identify this module
    GUID = 'b3c4d5e6-f7a8-9012-bcde-f01234567890'

    # Author of this module
    Author = 'SailPoint Governance Toolkit Team'

    # Company or vendor of this module
    CompanyName = 'SailPoint Governance Toolkit'

    # Copyright statement for this module
    Copyright = '(c) 2026 SailPoint Governance Toolkit. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'SailPoint ISC Governance Toolkit - Core Foundation Module'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module.
    ScriptsToProcess = @()

    # Type files (.ps1xml) to be loaded when importing this module
    TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    # Load order matters: Config and Logging first (Auth depends on both, Vault on neither)
    NestedModules = @(
        'SP.Config.psm1',
        'SP.Logging.psm1',
        'SP.Vault.psm1',
        'SP.Auth.psm1'
    )

    # Functions to export from this module.
    FunctionsToExport = @(
        # SP.Config exports
        'Get-SPConfig',
        'Test-SPConfig',
        'Test-SPConfigFirstRun',
        'New-SPConfigFile',

        # SP.Logging exports
        'Write-SPLog',
        'Get-SPLogPath',
        'Initialize-SPLogging',

        # SP.Vault exports
        'Initialize-SPVault',
        'Set-SPVaultCredential',
        'Get-SPVaultCredential',
        'Test-SPVaultExists',
        'Remove-SPVaultCredential',

        # SP.Auth exports
        'Get-SPAuthToken',
        'Clear-SPAuthToken'
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
        'SP.Core.psd1',
        'SP.Config.psm1',
        'SP.Logging.psm1',
        'SP.Vault.psm1',
        'SP.Auth.psm1'
    )

    # Private data
    PrivateData = @{
        PSData = @{
            Tags         = @('SailPoint', 'ISC', 'IGA', 'Governance', 'Certification', 'Testing', 'Toolkit')
            ReleaseNotes = 'v1.0.0: Initial release - Config, Logging, Vault, Auth core modules.'
        }
    }
}
