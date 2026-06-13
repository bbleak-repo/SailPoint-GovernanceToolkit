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
    Description       = 'SailPoint ISC Governance Toolkit - Shared Utilities. Provides common HTML helpers, property accessors, file-writing functions, identity resolution services, and a generic in-memory cache service with optional TTL. SP.HtmlHelpers and SP.CacheService have no dependencies; SP.IdentityService depends on SP.Core and SP.Api (caller handles import order).'
    Copyright         = '(c) 2026. All rights reserved.'

    # No RequiredModules -- SP.HtmlHelpers and SP.CacheService are dependency-free;
    # SP.IdentityService depends on SP.Core + SP.Api but the project pattern is
    # caller-handles-order.
    RequiredModules   = @()

    # Root module is empty; nested modules load in order.
    RootModule        = ''

    # Sub-modules (load order: HtmlHelpers first -- no deps; CacheService second --
    # no deps; IdentityService last -- depends on SP.Core/SP.Api at runtime).
    NestedModules     = @(
        'SP.HtmlHelpers.psm1'
        'SP.CacheService.psm1'
        'SP.IdentityService.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.HtmlHelpers
        'ConvertTo-SPHtmlSafe'
        'Format-SPHtmlDate'
        'Get-SPObjectProperty'
        'Get-SPHtmlColorPalette'
        'New-SPHtmlDocument'
        'Write-SPHtmlFile'

        # SP.CacheService
        'New-SPCacheStore'
        'Get-SPCachedItem'
        'Set-SPCachedItem'
        'Test-SPCacheValid'
        'Clear-SPCacheStore'
        'Export-SPCacheStore'
        'Import-SPCacheStore'
        'Add-SPCacheStoreEntry'
        'Compress-SPCacheStore'

        # SP.IdentityService
        'Get-SPIdentityDetail'
        'Search-SPIdentityByEmail'
        'Set-SPIdentityCacheEntry'
        'Get-SPIdentityCacheEntry'
        'Clear-SPIdentityCache'
        'Get-SPIdentityCacheInfo'
        'Import-SPIdentityCacheFromDisk'
        'Save-SPIdentityCacheEntry'
    )

    # Do not export variables or aliases
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}
