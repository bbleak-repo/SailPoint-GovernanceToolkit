#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit Configuration Module
.DESCRIPTION
    Provides configuration loading, validation, and default value management
    for the SailPoint ISC Governance Toolkit.
.NOTES
    Module: SP.Config
    Version: 1.0.0
#>

# Script-scoped variables
$script:ConfigCache = $null
$script:ConfigPath  = $null

#region Internal Functions

function Get-SPConfigDefaults {
    <#
    .SYNOPSIS
        Returns default configuration values
    .OUTPUTS
        [hashtable] Default configuration structure
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        Global = @{
            EnvironmentName  = 'Unknown'
            DebugMode        = $false
            ToolkitVersion   = '1.0.0'
        }
        Authentication = @{
            Mode       = 'ConfigFile'
            ConfigFile = @{
                TenantUrl     = ''
                OAuthTokenUrl = ''
                ClientId      = ''
                ClientSecret  = ''
            }
            Vault = @{
                VaultPath        = '.\Data\sp-vault.enc'
                Pbkdf2Iterations = 600000
                CredentialKey    = 'sailpoint-isc'
            }
        }
        Logging = @{
            Path             = '.\Logs'
            FilePrefix       = 'GovernanceToolkit'
            MinimumSeverity  = 'INFO'
            RetentionDays    = 30
        }
        Api = @{
            BaseUrl                  = ''
            TimeoutSeconds           = 60
            RetryCount               = 3
            RetryDelaySeconds        = 5
            RateLimitRequestsPerWindow = 95
            RateLimitWindowSeconds   = 10
        }
        Testing = @{
            IdentitiesCsvPath                  = '.\Config\test-identities.csv'
            CampaignsCsvPath                   = '.\Config\test-campaigns.csv'
            EvidencePath                       = '.\Evidence'
            ReportsPath                        = '.\Reports'
            DecisionBatchSize                  = 250
            ReassignSyncMax                    = 50
            ReassignAsyncMax                   = 500
            CampaignActivationTimeoutSeconds   = 300
            CampaignCompleteTimeoutSeconds     = 600
            DefaultDecision                    = 'APPROVE'
            WhatIfByDefault                    = $false
        }
        Safety = @{
            MaxCampaignsPerRun      = 10
            RequireWhatIfOnProd     = $true
            AllowCompleteCampaign   = $false
        }
        Audit = @{
            OutputPath               = '.\Audit'
            DefaultDaysBack          = 30
            DefaultIdentityEventDays = 2
            DefaultStatuses          = @('COMPLETED', 'ACTIVE')
            IncludeCampaignReports   = $true
            IncludeIdentityEvents    = $true
        }
    }
}

function Merge-SPConfigWithDefaults {
    <#
    .SYNOPSIS
        Merges loaded configuration with defaults, warns on missing keys
    .PARAMETER LoadedConfig
        The configuration loaded from JSON file
    .PARAMETER Defaults
        The default configuration hashtable
    .PARAMETER ParentPath
        Current path in config hierarchy (for logging)
    .OUTPUTS
        [hashtable] Merged configuration
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $LoadedConfig,

        [Parameter(Mandatory)]
        [hashtable]$Defaults,

        [Parameter()]
        [string]$ParentPath = ''
    )

    $result = @{}

    foreach ($key in $Defaults.Keys) {
        $currentPath = if ($ParentPath) { "$ParentPath.$key" } else { $key }

        if ($null -eq $LoadedConfig -or -not ($LoadedConfig.PSObject.Properties.Name -contains $key)) {
            # Key missing from loaded config - use default and warn
            $result[$key] = $Defaults[$key]
            $warningMsg = "Configuration key '$currentPath' not found. Using default value."
            Write-Warning $warningMsg

            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warningMsg -Severity 'WARN' -Component 'SP.Config' -Action 'MergeConfig'
            }
        }
        elseif ($Defaults[$key] -is [hashtable]) {
            # Recursively merge nested hashtables
            $result[$key] = Merge-SPConfigWithDefaults -LoadedConfig $LoadedConfig.$key -Defaults $Defaults[$key] -ParentPath $currentPath
        }
        else {
            # Use loaded value
            $result[$key] = $LoadedConfig.$key
        }
    }

    # Check for unknown keys in loaded config (not in defaults)
    if ($null -ne $LoadedConfig -and $LoadedConfig.PSObject.Properties) {
        foreach ($prop in $LoadedConfig.PSObject.Properties) {
            if (-not $Defaults.ContainsKey($prop.Name)) {
                $currentPath = if ($ParentPath) { "$ParentPath.$($prop.Name)" } else { $prop.Name }
                $warningMsg = "Unknown configuration key '$currentPath' found. This key is not recognized."
                Write-Warning $warningMsg

                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message $warningMsg -Severity 'WARN' -Component 'SP.Config' -Action 'MergeConfig'
                }

                # Still include unknown keys in result
                $result[$prop.Name] = $prop.Value
            }
        }
    }

    return $result
}

function ConvertTo-SPConfigObject {
    <#
    .SYNOPSIS
        Converts hashtable to PSCustomObject recursively
    .PARAMETER Hashtable
        The hashtable to convert
    .OUTPUTS
        [PSCustomObject] Converted object
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Hashtable
    )

    $result = @{}
    foreach ($key in $Hashtable.Keys) {
        if ($Hashtable[$key] -is [hashtable]) {
            $result[$key] = ConvertTo-SPConfigObject -Hashtable $Hashtable[$key]
        }
        else {
            $result[$key] = $Hashtable[$key]
        }
    }
    return [PSCustomObject]$result
}

function Get-SPConfigTemplate {
    <#
    .SYNOPSIS
        Returns the default settings.json template content as a string
    .OUTPUTS
        [string] JSON template
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $template = [ordered]@{
        Global = [ordered]@{
            EnvironmentName = 'CHANGE_ME'
            DebugMode       = $false
            ToolkitVersion  = '1.0.0'
        }
        Authentication = [ordered]@{
            Mode       = 'ConfigFile'
            ConfigFile = [ordered]@{
                TenantUrl     = 'https://CHANGE_ME.api.identitynow.com'
                OAuthTokenUrl = 'https://CHANGE_ME.identitynow.com/oauth/token'
                ClientId      = 'CHANGE_ME'
                ClientSecret  = 'CHANGE_ME_DO_NOT_USE_IN_PRODUCTION'
            }
            Vault = [ordered]@{
                VaultPath        = '.\Data\sp-vault.enc'
                Pbkdf2Iterations = 600000
                CredentialKey    = 'sailpoint-isc'
            }
        }
        Logging = [ordered]@{
            Path            = '.\Logs'
            FilePrefix      = 'GovernanceToolkit'
            MinimumSeverity = 'INFO'
            RetentionDays   = 30
        }
        Api = [ordered]@{
            BaseUrl                    = 'https://CHANGE_ME.api.identitynow.com/v3'
            TimeoutSeconds             = 60
            RetryCount                 = 3
            RetryDelaySeconds          = 5
            RateLimitRequestsPerWindow = 95
            RateLimitWindowSeconds     = 10
        }
        Testing = [ordered]@{
            IdentitiesCsvPath                = '.\Config\test-identities.csv'
            CampaignsCsvPath                 = '.\Config\test-campaigns.csv'
            EvidencePath                     = '.\Evidence'
            ReportsPath                      = '.\Reports'
            DecisionBatchSize                = 250
            ReassignSyncMax                  = 50
            ReassignAsyncMax                 = 500
            CampaignActivationTimeoutSeconds = 300
            CampaignCompleteTimeoutSeconds   = 600
            DefaultDecision                  = 'APPROVE'
            WhatIfByDefault                  = $false
        }
        Safety = [ordered]@{
            MaxCampaignsPerRun    = 10
            RequireWhatIfOnProd   = $true
            AllowCompleteCampaign = $false
        }
    }

    return $template | ConvertTo-Json -Depth 10
}

function Write-SPFirstRunMessage {
    <#
    .SYNOPSIS
        Displays first-run guidance to the user
    .PARAMETER ConfigPath
        Path to the newly created configuration file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $divider = '=' * 80

    Write-Host ''
    Write-Host $divider -ForegroundColor Cyan
    Write-Host '  SAILPOINT ISC GOVERNANCE TOOLKIT - FIRST RUN SETUP' -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  A default configuration file has been created at:' -ForegroundColor Green
    Write-Host "  $ConfigPath" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  REQUIRED: Update all CHANGE_ME values before proceeding.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  1. Global.EnvironmentName - your environment label (e.g. Sandbox, Prod)' -ForegroundColor White
    Write-Host '  2. Authentication.ConfigFile.TenantUrl - your ISC API base URL' -ForegroundColor White
    Write-Host '  3. Authentication.ConfigFile.OAuthTokenUrl - your ISC OAuth token URL' -ForegroundColor White
    Write-Host '  4. Authentication.ConfigFile.ClientId / ClientSecret - OAuth client creds' -ForegroundColor White
    Write-Host '  5. Api.BaseUrl - same as TenantUrl with /v3 path' -ForegroundColor White
    Write-Host ''
    Write-Host $divider -ForegroundColor Cyan
    Write-Host ''
}

#endregion

#region Public Functions

function Get-SPConfig {
    <#
    .SYNOPSIS
        Loads configuration from settings.json
    .DESCRIPTION
        Reads the configuration file, merges with defaults, and returns a PSCustomObject.
        Caches the result by path. Use -Force to bypass cache.
    .PARAMETER ConfigPath
        Path to the settings.json file. Defaults to ..\..\Config\settings.json
        relative to the module location.
    .PARAMETER Force
        Force reload even if cached.
    .OUTPUTS
        [PSCustomObject] Full configuration object
    .EXAMPLE
        $config = Get-SPConfig
        $config.Global.EnvironmentName
    .EXAMPLE
        $config = Get-SPConfig -ConfigPath 'C:\Custom\settings.json' -Force
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [Parameter()]
        [switch]$Force
    )

    # Determine config path
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\Config\settings.json'
        $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    }

    # Return cached config if available and not forced
    if (-not $Force -and $null -ne $script:ConfigCache -and $script:ConfigPath -eq $ConfigPath) {
        return $script:ConfigCache
    }

    # Check if config file exists - if not, create it and guide the user
    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        $createdPath = New-SPConfigFile -ConfigPath $ConfigPath
        Write-SPFirstRunMessage -ConfigPath $createdPath

        return [PSCustomObject]@{
            _FirstRun   = $true
            _ConfigPath = $createdPath
            _Message    = 'Configuration file created. Please review and update required settings, then run again.'
        }
    }

    # Load JSON file
    try {
        $jsonContent = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        $loadedConfig = $jsonContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch [System.ArgumentException] {
        throw "Invalid JSON in configuration file: $ConfigPath. Error: $($_.Exception.Message)"
    }
    catch {
        throw "Failed to read configuration file: $ConfigPath. Error: $($_.Exception.Message)"
    }

    # Get defaults and merge
    $defaults      = Get-SPConfigDefaults
    $mergedConfig  = Merge-SPConfigWithDefaults -LoadedConfig $loadedConfig -Defaults $defaults

    # Convert to PSCustomObject
    $configObject = ConvertTo-SPConfigObject -Hashtable $mergedConfig

    # Cache the result
    $script:ConfigCache = $configObject
    $script:ConfigPath  = $ConfigPath

    return $configObject
}

function Test-SPConfig {
    <#
    .SYNOPSIS
        Validates configuration against required schema
    .DESCRIPTION
        Checks that required sections and fields exist and are non-empty.
        Returns true if valid, false if any check fails (no throw).
    .PARAMETER Config
        The configuration object to validate (from Get-SPConfig)
    .OUTPUTS
        [bool] True if valid
    .EXAMPLE
        $config = Get-SPConfig
        if (Test-SPConfig -Config $config) { Write-Host 'Config is valid' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Config
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # Required sections
    $requiredSections = @('Api', 'Authentication', 'Logging')
    foreach ($section in $requiredSections) {
        if (-not ($Config.PSObject.Properties.Name -contains $section)) {
            $errors.Add("Missing required section: $section")
        }
    }

    # Api.BaseUrl
    if ($Config.PSObject.Properties.Name -contains 'Api') {
        if ([string]::IsNullOrWhiteSpace($Config.Api.BaseUrl)) {
            $errors.Add('Api.BaseUrl cannot be empty')
        }
    }

    # Authentication.Mode
    if ($Config.PSObject.Properties.Name -contains 'Authentication') {
        if ([string]::IsNullOrWhiteSpace($Config.Authentication.Mode)) {
            $errors.Add('Authentication.Mode cannot be empty')
        }
    }

    # Logging.Path
    if ($Config.PSObject.Properties.Name -contains 'Logging') {
        if ([string]::IsNullOrWhiteSpace($Config.Logging.Path)) {
            $errors.Add('Logging.Path cannot be empty')
        }
    }

    if ($errors.Count -gt 0) {
        foreach ($err in $errors) {
            Write-Warning "SP.Config validation: $err"
        }
        return $false
    }

    return $true
}

function Test-SPConfigFirstRun {
    <#
    .SYNOPSIS
        Checks if the config result indicates first-run state
    .DESCRIPTION
        Returns true if the configuration object is a first-run placeholder,
        indicating the user needs to configure settings before proceeding.
    .PARAMETER Config
        The configuration object from Get-SPConfig
    .OUTPUTS
        [bool] True if this is a first-run configuration
    .EXAMPLE
        $config = Get-SPConfig
        if (Test-SPConfigFirstRun -Config $config) {
            Write-Host 'Please configure settings.json and run again'
            exit 0
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Config
    )

    return ($Config.PSObject.Properties.Name -contains '_FirstRun' -and $Config._FirstRun -eq $true)
}

function New-SPConfigFile {
    <#
    .SYNOPSIS
        Creates a new configuration file with safe defaults
    .DESCRIPTION
        Generates a settings.json file with CHANGE_ME sentinel values.
        Called automatically on first run when no configuration file exists.
    .PARAMETER ConfigPath
        Path where the configuration file should be created
    .OUTPUTS
        [string] Path to the created configuration file
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    # Ensure directory exists
    $configDir = Split-Path -Path $ConfigPath -Parent
    if (-not (Test-Path -Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }

    $jsonContent = Get-SPConfigTemplate
    Set-Content -Path $ConfigPath -Value $jsonContent -Encoding UTF8

    return $ConfigPath
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-SPConfig',
    'Test-SPConfig',
    'Test-SPConfigFirstRun',
    'New-SPConfigFile'
)
