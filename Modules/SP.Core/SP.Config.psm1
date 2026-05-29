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
            MaxRetryDelaySeconds     = 60
            RateLimitRequestsPerWindow = 95
            RateLimitWindowSeconds   = 10
            # M2: hard ceiling on auto-paginators. At default page size 250
            # this caps any single Get-All* / Search-*Campaigns call at
            # 50,000 items. Raise via settings.json if a tenant legitimately
            # exceeds that. The point is to fail loudly rather than spin
            # forever if the API ever returns full pages indefinitely
            # (offset bug, cursor drift, tenant-side regression).
            MaxPaginationPages       = 200
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
            IncludeLeadershipRollup  = $false
            LeadershipDepth          = 3
            RiskIndicators = @{
                StaleAccessDays        = 90
                PrivilegedPatterns     = @('Admin', 'Root', 'DBA', 'Domain Admins')
                ServiceAccountPatterns = @('^SVC-', '^svc-')
            }
            Smtp = @{
                Enabled       = $false
                Server        = ''
                Port          = 587
                From          = ''
                UseSsl        = $true
                SubjectPrefix = '[SailPoint Audit]'
            }
        }
        Notification = @{
            Backends = @('Log')
            Smtp = @{
                Server = ''
                Port   = 587
                From   = ''
                UseSsl = $true
            }
            Webhook = @{
                Url            = ''
                Method         = 'POST'
                Headers        = @{}
                IncludePayload = $true
            }
        }
        Retention = @{
            Enabled     = $false
            ArchiveDays = 30
            DeleteDays  = 90
            ArchivePath = '.\Archive'
            Paths       = @('Audit', 'DeltaCert', 'Logs')
        }
        DisconnectedApps = @{
            ImportBasePath             = '.\DisconnectedApps\Imports'
            SnapshotPath               = '.\DisconnectedApps\Snapshots'
            ReportPath                 = '.\DisconnectedApps\Reports'
            SnapshotRetentionDays      = 30
            DefaultCampaignNamePrefix  = 'Disconnected App Cert'
            DefaultDeadlineDays        = 2
            CorrelationAttribute       = 'e-mail'
            AccountDeletionThresholdPct = 20
            RequiredAccountColumns     = @('id', 'name', 'givenName', 'familyName', 'e-mail', 'groups', 'IIQDisabled')
            RequiredEntitlementColumns = @('id', 'name', 'displayName', 'description')
            Applications               = @()
        }
        DeltaCert = @{
            SourceIds                  = @()
            DefaultHoursBack           = 24
            DefaultDeadlineDays        = 2
            FallbackReviewerIdentityId = ''
            CampaignNamePrefix         = 'AD Delta Cert'
            MaxCampaignsPerRun         = 50
            CleanupDaysStale           = 3
            OutputPath                 = '.\DeltaCert'
            DefaultReviewerMode        = 'Manager'
            ExcludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
            ExcludeDisplayNamePatterns = @()
            ExcludeIdentityIds         = @()
            Escalation = @{
                DefaultStaleHours      = 24
                MaxEscalationLevels    = 2
                CampaignNamePrefix     = 'AD Delta Cert'
            }
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
            # Key missing from loaded config - use default and warn (once per key per session)
            $result[$key] = $Defaults[$key]
            if ($null -eq $script:SPConfigWarnedKeys) {
                $script:SPConfigWarnedKeys = New-Object 'System.Collections.Generic.HashSet[string]'
            }
            if ($script:SPConfigWarnedKeys.Add($currentPath)) {
                $warningMsg = "Configuration key '$currentPath' not found. Using default value."
                Write-Warning $warningMsg
                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message $warningMsg -Severity 'WARN' -Component 'SP.Config' -Action 'MergeConfig'
                }
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
                if ($null -eq $script:SPConfigWarnedKeys) {
                    $script:SPConfigWarnedKeys = New-Object 'System.Collections.Generic.HashSet[string]'
                }
                $sentinel = "UNKNOWN:$currentPath"
                if ($script:SPConfigWarnedKeys.Add($sentinel)) {
                    $warningMsg = "Unknown configuration key '$currentPath' found. This key is not recognized."
                    Write-Warning $warningMsg
                    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                        Write-SPLog -Message $warningMsg -Severity 'WARN' -Component 'SP.Config' -Action 'MergeConfig'
                    }
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
                OAuthTokenUrl = 'https://CHANGE_ME.api.identitynow.com/oauth/token'
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
            MaxRetryDelaySeconds       = 60
            RateLimitRequestsPerWindow = 95
            RateLimitWindowSeconds     = 10
            MaxPaginationPages         = 200
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
        Audit = [ordered]@{
            OutputPath               = '.\Audit'
            DefaultDaysBack          = 30
            DefaultIdentityEventDays = 2
            DefaultStatuses          = @('COMPLETED', 'ACTIVE')
            IncludeCampaignReports   = $true
            IncludeIdentityEvents    = $true
            IncludeLeadershipRollup  = $false
            LeadershipDepth          = 3
            RiskIndicators = [ordered]@{
                StaleAccessDays        = 90
                PrivilegedPatterns     = @('Admin', 'Root', 'DBA', 'Domain Admins')
                ServiceAccountPatterns = @('^SVC-', '^svc-')
            }
            Smtp = [ordered]@{
                Enabled       = $false
                Server        = ''
                Port          = 587
                From          = ''
                UseSsl        = $true
                SubjectPrefix = '[SailPoint Audit]'
            }
        }
        Notification = [ordered]@{
            Backends = @('Log')
            Smtp = [ordered]@{
                Server = ''
                Port   = 587
                From   = ''
                UseSsl = $true
            }
            Webhook = [ordered]@{
                Url            = ''
                Method         = 'POST'
                Headers        = @{}
                IncludePayload = $true
            }
        }
        Retention = [ordered]@{
            Enabled     = $false
            ArchiveDays = 30
            DeleteDays  = 90
            ArchivePath = '.\Archive'
            Paths       = @('Audit', 'DeltaCert', 'Logs')
        }
        DisconnectedApps = [ordered]@{
            ImportBasePath             = '.\DisconnectedApps\Imports'
            SnapshotPath               = '.\DisconnectedApps\Snapshots'
            ReportPath                 = '.\DisconnectedApps\Reports'
            SnapshotRetentionDays      = 30
            DefaultCampaignNamePrefix  = 'Disconnected App Cert'
            DefaultDeadlineDays        = 2
            CorrelationAttribute       = 'e-mail'
            AccountDeletionThresholdPct = 20
            RequiredAccountColumns     = @('id', 'name', 'givenName', 'familyName', 'e-mail', 'groups', 'IIQDisabled')
            RequiredEntitlementColumns = @('id', 'name', 'displayName', 'description')
            Applications               = @()
        }
        DeltaCert = [ordered]@{
            SourceIds                  = @()
            DefaultHoursBack           = 24
            DefaultDeadlineDays        = 2
            FallbackReviewerIdentityId = ''
            CampaignNamePrefix         = 'AD Delta Cert'
            MaxCampaignsPerRun         = 50
            CleanupDaysStale           = 3
            OutputPath                 = '.\DeltaCert'
            DefaultReviewerMode        = 'Manager'
            ExcludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
            ExcludeDisplayNamePatterns = @()
            ExcludeIdentityIds         = @()
            Escalation = [ordered]@{
                DefaultStaleHours   = 24
                MaxEscalationLevels = 2
                CampaignNamePrefix  = 'AD Delta Cert'
            }
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

function Test-SPConfiguration {
    <#
    .SYNOPSIS
        Comprehensive configuration validation for production readiness
    .DESCRIPTION
        Validates settings.json against the expected schema, checks field types,
        validates cross-field dependencies, and optionally tests API connectivity
        and ISC entity resolution. Returns a structured result with Errors,
        Warnings, and Info messages.

        Unlike Test-SPConfig (checks for missing top-level keys) and
        Test-SPConfigFirstRun (checks for CHANGE_ME sentinels), this function
        validates field types, range constraints, regex patterns, and whether
        configured ISC entity IDs actually exist in the tenant.
    .PARAMETER ConfigPath
        Path to the settings.json file. Defaults to auto-resolved path.
    .PARAMETER ValidateConnectivity
        When set, tests API authentication and basic endpoint access.
    .PARAMETER ResolveEntities
        When set, verifies that configured SourceIds and FallbackReviewerIdentityId
        exist in the ISC tenant. Implies -ValidateConnectivity.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Valid; Errors; Warnings; Info }
    .EXAMPLE
        $result = Test-SPConfiguration
        if (-not $result.Valid) { $result.Errors | ForEach-Object { Write-Error $_ } }
    .EXAMPLE
        Test-SPConfiguration -ValidateConnectivity -ResolveEntities
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string]$ConfigPath,
        [Parameter()][switch]$ValidateConnectivity,
        [Parameter()][switch]$ResolveEntities,
        [Parameter()][string]$CorrelationID
    )

    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $info     = [System.Collections.Generic.List[string]]::new()

    # --- Load config ---
    $configParams = @{ Force = $true }
    if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }

    try {
        $config = Get-SPConfig @configParams
    }
    catch {
        $errors.Add("Failed to load configuration: $($_.Exception.Message)")
        return @{ Valid = $false; Errors = @($errors); Warnings = @($warnings); Info = @($info) }
    }

    if ($null -eq $config) {
        $errors.Add('Get-SPConfig returned null')
        return @{ Valid = $false; Errors = @($errors); Warnings = @($warnings); Info = @($info) }
    }

    # First-run check
    if (Test-SPConfigFirstRun -Config $config) {
        $errors.Add('Configuration contains CHANGE_ME placeholder values. Complete first-run setup before validating.')
        return @{ Valid = $false; Errors = @($errors); Warnings = @($warnings); Info = @($info) }
    }

    # --- Schema validation: detect unknown top-level keys ---
    $defaults = Get-SPConfigDefaults
    $knownTopKeys = $defaults.Keys
    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -notin $knownTopKeys) {
            $warnings.Add("Unknown top-level key '$($prop.Name)' found")
        }
    }

    # --- Required string fields must not be empty ---
    $requiredStrings = @(
        @('Authentication.ConfigFile.TenantUrl',  { $config.Authentication.ConfigFile.TenantUrl }),
        @('Authentication.ConfigFile.OAuthTokenUrl', { $config.Authentication.ConfigFile.OAuthTokenUrl }),
        @('Authentication.ConfigFile.ClientId',   { $config.Authentication.ConfigFile.ClientId }),
        @('Authentication.ConfigFile.ClientSecret', { $config.Authentication.ConfigFile.ClientSecret }),
        @('Api.BaseUrl',                          { $config.Api.BaseUrl }),
        @('Authentication.Mode',                  { $config.Authentication.Mode })
    )
    foreach ($entry in $requiredStrings) {
        $fieldName = $entry[0]
        $getter    = $entry[1]
        try {
            $val = & $getter
            if ([string]::IsNullOrWhiteSpace($val)) {
                $errors.Add("$fieldName is empty")
            }
        }
        catch {
            $errors.Add("$fieldName is missing or inaccessible")
        }
    }

    # --- HTTPS enforcement warning for non-mock environments ---
    $envName = ''
    try { $envName = [string]$config.Global.EnvironmentName } catch { }
    $isMockEnv = ($envName -imatch 'mock|localhost|test|dev')
    foreach ($urlField in @(
        @('Authentication.ConfigFile.TenantUrl',   { $config.Authentication.ConfigFile.TenantUrl }),
        @('Authentication.ConfigFile.OAuthTokenUrl', { $config.Authentication.ConfigFile.OAuthTokenUrl }),
        @('Api.BaseUrl',                           { $config.Api.BaseUrl })
    )) {
        try {
            $urlVal = [string](& $urlField[1])
            if (-not [string]::IsNullOrWhiteSpace($urlVal) -and
                $urlVal.StartsWith('http://') -and -not $isMockEnv) {
                $warnings.Add("$($urlField[0]) uses HTTP (not HTTPS). This sends credentials in cleartext. Use HTTPS for production environments.")
            }
        } catch { }
    }

    # --- Type checks: positive integers ---
    $positiveIntegers = @(
        @('Api.TimeoutSeconds',              { $config.Api.TimeoutSeconds }),
        @('Api.RetryCount',                  { $config.Api.RetryCount }),
        @('Api.RetryDelaySeconds',           { $config.Api.RetryDelaySeconds }),
        @('Api.MaxRetryDelaySeconds',        { $config.Api.MaxRetryDelaySeconds }),
        @('Api.RateLimitRequestsPerWindow',  { $config.Api.RateLimitRequestsPerWindow }),
        @('Api.RateLimitWindowSeconds',      { $config.Api.RateLimitWindowSeconds }),
        @('Api.MaxPaginationPages',          { $config.Api.MaxPaginationPages }),
        @('Logging.RetentionDays',           { $config.Logging.RetentionDays }),
        @('Audit.DefaultDaysBack',           { $config.Audit.DefaultDaysBack }),
        @('Audit.DefaultIdentityEventDays',  { $config.Audit.DefaultIdentityEventDays }),
        @('Audit.LeadershipDepth',           { $config.Audit.LeadershipDepth }),
        @('Audit.Smtp.Port',                 { $config.Audit.Smtp.Port }),
        @('Audit.RiskIndicators.StaleAccessDays', { $config.Audit.RiskIndicators.StaleAccessDays }),
        @('DeltaCert.DefaultHoursBack',      { $config.DeltaCert.DefaultHoursBack }),
        @('DeltaCert.DefaultDeadlineDays',   { $config.DeltaCert.DefaultDeadlineDays }),
        @('DeltaCert.MaxCampaignsPerRun',    { $config.DeltaCert.MaxCampaignsPerRun }),
        @('DeltaCert.CleanupDaysStale',      { $config.DeltaCert.CleanupDaysStale }),
        @('DeltaCert.Escalation.DefaultStaleHours',   { $config.DeltaCert.Escalation.DefaultStaleHours }),
        @('DeltaCert.Escalation.MaxEscalationLevels', { $config.DeltaCert.Escalation.MaxEscalationLevels }),
        @('Safety.MaxCampaignsPerRun',       { $config.Safety.MaxCampaignsPerRun }),
        @('Testing.DecisionBatchSize',       { $config.Testing.DecisionBatchSize }),
        @('Testing.CampaignActivationTimeoutSeconds', { $config.Testing.CampaignActivationTimeoutSeconds }),
        @('Testing.CampaignCompleteTimeoutSeconds',   { $config.Testing.CampaignCompleteTimeoutSeconds })
    )
    foreach ($entry in $positiveIntegers) {
        $fieldName = $entry[0]
        $getter    = $entry[1]
        try {
            $val = & $getter
            if ($null -ne $val) {
                $numVal = $val -as [int]
                if ($null -eq $numVal -or $numVal -le 0) {
                    $errors.Add("$fieldName must be a positive integer (got '$val')")
                }
            }
        }
        catch { }  # Field missing -- already covered by schema merge warnings
    }

    # --- Type checks: booleans ---
    $boolFields = @(
        @('Global.DebugMode',              { $config.Global.DebugMode }),
        @('Safety.RequireWhatIfOnProd',    { $config.Safety.RequireWhatIfOnProd }),
        @('Safety.AllowCompleteCampaign',  { $config.Safety.AllowCompleteCampaign }),
        @('Audit.IncludeCampaignReports',  { $config.Audit.IncludeCampaignReports }),
        @('Audit.IncludeIdentityEvents',   { $config.Audit.IncludeIdentityEvents }),
        @('Audit.IncludeLeadershipRollup', { $config.Audit.IncludeLeadershipRollup }),
        @('Audit.Smtp.Enabled',            { $config.Audit.Smtp.Enabled }),
        @('Audit.Smtp.UseSsl',             { $config.Audit.Smtp.UseSsl }),
        @('Testing.WhatIfByDefault',       { $config.Testing.WhatIfByDefault })
    )
    foreach ($entry in $boolFields) {
        $fieldName = $entry[0]
        $getter    = $entry[1]
        try {
            $val = & $getter
            if ($null -ne $val -and $val -isnot [bool]) {
                $errors.Add("$fieldName must be a boolean (got '$val')")
            }
        }
        catch { }
    }

    # --- Type checks: arrays ---
    $arrayFields = @(
        @('Audit.DefaultStatuses',             { $config.Audit.DefaultStatuses }),
        @('Audit.RiskIndicators.PrivilegedPatterns',    { $config.Audit.RiskIndicators.PrivilegedPatterns }),
        @('Audit.RiskIndicators.ServiceAccountPatterns', { $config.Audit.RiskIndicators.ServiceAccountPatterns }),
        @('DeltaCert.SourceIds',               { $config.DeltaCert.SourceIds }),
        @('DeltaCert.ExcludeLifecycleStates',  { $config.DeltaCert.ExcludeLifecycleStates }),
        @('DeltaCert.ExcludeDisplayNamePatterns', { $config.DeltaCert.ExcludeDisplayNamePatterns }),
        @('DeltaCert.ExcludeIdentityIds',      { $config.DeltaCert.ExcludeIdentityIds })
    )
    foreach ($entry in $arrayFields) {
        $fieldName = $entry[0]
        $getter    = $entry[1]
        try {
            $val = & $getter
            if ($null -ne $val -and $val -isnot [array] -and $val -isnot [System.Collections.IEnumerable]) {
                # Allow single strings that JSON parsers may unwrap from one-element arrays
                if ($val -isnot [string]) {
                    $errors.Add("$fieldName must be an array (got type $($val.GetType().Name))")
                }
            }
        }
        catch { }
    }

    # --- Range checks ---
    try {
        $rateLimit = $config.Api.RateLimitRequestsPerWindow -as [int]
        if ($null -ne $rateLimit -and $rateLimit -gt 100) {
            $errors.Add("Api.RateLimitRequestsPerWindow must be <= 100 (got $rateLimit)")
        }
    } catch { }

    try {
        $maxCamp = $config.Safety.MaxCampaignsPerRun -as [int]
        if ($null -ne $maxCamp -and $maxCamp -gt 250) {
            $errors.Add("Safety.MaxCampaignsPerRun must be <= 250 (got $maxCamp)")
        }
    } catch { }

    try {
        $depth = $config.Audit.LeadershipDepth -as [int]
        if ($null -ne $depth -and ($depth -lt 1 -or $depth -gt 10)) {
            $errors.Add("Audit.LeadershipDepth must be between 1 and 10 (got $depth)")
        }
    } catch { }

    # --- Cross-field dependencies ---
    try {
        if ($config.Authentication.Mode -eq 'Vault') {
            $vaultPath = $config.Authentication.Vault.VaultPath
            if ([string]::IsNullOrWhiteSpace($vaultPath)) {
                $errors.Add("Authentication.Mode is 'Vault' but Vault.VaultPath is empty")
            }
        }
    } catch { }

    try {
        $mainPrefix = $config.DeltaCert.CampaignNamePrefix
        $escPrefix  = $config.DeltaCert.Escalation.CampaignNamePrefix
        if (-not [string]::IsNullOrEmpty($mainPrefix) -and
            -not [string]::IsNullOrEmpty($escPrefix) -and
            $mainPrefix -ne $escPrefix) {
            $warnings.Add("DeltaCert.CampaignNamePrefix ('$mainPrefix') differs from DeltaCert.Escalation.CampaignNamePrefix ('$escPrefix')")
        }
    } catch { }

    # --- Path checks: parent directory must exist or be creatable ---
    $pathFields = @(
        @('Logging.Path',        { $config.Logging.Path }),
        @('Audit.OutputPath',    { $config.Audit.OutputPath }),
        @('DeltaCert.OutputPath', { $config.DeltaCert.OutputPath })
    )
    foreach ($entry in $pathFields) {
        $fieldName = $entry[0]
        $getter    = $entry[1]
        try {
            $pathVal = & $getter
            if (-not [string]::IsNullOrWhiteSpace($pathVal)) {
                $resolvedPath = $pathVal
                # Resolve relative paths from toolkit root
                if (-not [System.IO.Path]::IsPathRooted($resolvedPath)) {
                    $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
                    $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $resolvedPath))
                }
                $parentDir = Split-Path -Path $resolvedPath -Parent
                if (-not [string]::IsNullOrEmpty($parentDir) -and -not (Test-Path -Path $parentDir -PathType Container)) {
                    $warnings.Add("$fieldName parent directory does not exist: $parentDir")
                }
            }
        }
        catch { }
    }

    # --- Regex validation: ExcludeDisplayNamePatterns ---
    try {
        $patterns = $config.DeltaCert.ExcludeDisplayNamePatterns
        if ($null -ne $patterns) {
            foreach ($pattern in $patterns) {
                if (-not [string]::IsNullOrWhiteSpace($pattern)) {
                    try {
                        [regex]::new($pattern) | Out-Null
                    }
                    catch {
                        $errors.Add("DeltaCert.ExcludeDisplayNamePatterns contains invalid regex '$pattern': $($_.Exception.Message)")
                    }
                }
            }
        }
    } catch { }

    # Also validate ServiceAccountPatterns
    try {
        $svcPatterns = $config.Audit.RiskIndicators.ServiceAccountPatterns
        if ($null -ne $svcPatterns) {
            foreach ($pattern in $svcPatterns) {
                if (-not [string]::IsNullOrWhiteSpace($pattern)) {
                    try {
                        [regex]::new($pattern) | Out-Null
                    }
                    catch {
                        $errors.Add("Audit.RiskIndicators.ServiceAccountPatterns contains invalid regex '$pattern': $($_.Exception.Message)")
                    }
                }
            }
        }
    } catch { }

    $info.Add("Schema validation complete: $($errors.Count) error(s), $($warnings.Count) warning(s)")

    # --- Connectivity validation (optional) ---
    if ($ValidateConnectivity -or $ResolveEntities) {
        try {
            $token = Get-SPAuthToken -Config $config
            if ($token) {
                $info.Add('API authentication successful')
            }
            else {
                $errors.Add('API authentication failed: Get-SPAuthToken returned null')
            }
        }
        catch {
            $errors.Add("API authentication failed: $($_.Exception.Message)")
        }

        if ($errors.Count -eq 0 -or ($errors | Where-Object { $_ -notmatch 'authentication' })) {
            try {
                $testResponse = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns?limit=1' -Config $config
                if ($null -ne $testResponse) {
                    $info.Add('API connectivity verified')
                }
            }
            catch {
                $errors.Add("API connectivity test failed: $($_.Exception.Message)")
            }
        }
    }

    # --- Entity resolution (optional) ---
    if ($ResolveEntities) {
        # Resolve SourceIds
        try {
            $sourceIds = $config.DeltaCert.SourceIds
            if ($null -ne $sourceIds -and $sourceIds.Count -gt 0) {
                foreach ($srcId in $sourceIds) {
                    try {
                        $source = Invoke-SPApiRequest -Method GET -Endpoint "/v3/sources/$srcId" -Config $config
                        if ($null -ne $source -and $source.name) {
                            $info.Add("Source $srcId resolved: $($source.name)")
                        }
                        else {
                            $errors.Add("Source ID '$srcId' not found in tenant")
                        }
                    }
                    catch {
                        $errors.Add("Source ID '$srcId' could not be resolved: $($_.Exception.Message)")
                    }
                }
            }
        } catch { }

        # Resolve FallbackReviewerIdentityId
        try {
            $reviewerId = $config.DeltaCert.FallbackReviewerIdentityId
            if (-not [string]::IsNullOrWhiteSpace($reviewerId)) {
                try {
                    $identity = Invoke-SPApiRequest -Method GET -Endpoint "/v3/identities/$reviewerId" -Config $config
                    if ($null -ne $identity -and $identity.name) {
                        $info.Add("FallbackReviewer $reviewerId resolved: $($identity.name)")
                    }
                    else {
                        $errors.Add("FallbackReviewerIdentityId '$reviewerId' not found in tenant")
                    }
                }
                catch {
                    $errors.Add("FallbackReviewerIdentityId '$reviewerId' could not be resolved: $($_.Exception.Message)")
                }
            }
        } catch { }
    }

    # Log summary
    $logComponent = 'SP.Config'
    $logAction    = 'Test-SPConfiguration'
    $logMsg = "Validation complete: Valid=$($errors.Count -eq 0), Errors=$($errors.Count), Warnings=$($warnings.Count)"
    if ($CorrelationID) { $logMsg = "[$CorrelationID] $logMsg" }
    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        $severity = if ($errors.Count -gt 0) { 'ERROR' } else { 'INFO' }
        Write-SPLog -Message $logMsg -Severity $severity -Component $logComponent -Action $logAction
    }

    return @{
        Valid    = ($errors.Count -eq 0)
        Errors   = @($errors)
        Warnings = @($warnings)
        Info     = @($info)
    }
}

function Resolve-SPConfigPath {
    <#
    .SYNOPSIS
        Returns the toolkit's config file path, honoring the settings.local.json override.
    .DESCRIPTION
        Convention: when settings.local.json exists next to settings.json, the local
        file is used. This lets the tracked settings.json template stay as the
        CHANGE_ME example while developers run against a gitignored
        settings.local.json with stubs or real values. Entry-point scripts call this
        instead of hardcoding the settings.json path so every entry point — GUI,
        CLI runner, audit, vault setup, connectivity test — respects the same rule.
    .PARAMETER ToolkitRoot
        Path to the toolkit root (containing the Config\ directory). If omitted,
        resolves relative to this module's location.
    .OUTPUTS
        [string] Absolute path to the config file. The file is NOT required to exist;
        Get-SPConfig handles the missing-file first-run flow.
    .EXAMPLE
        $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $myRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$ToolkitRoot
    )

    if ([string]::IsNullOrEmpty($ToolkitRoot)) {
        $ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }

    $configDir   = [System.IO.Path]::GetFullPath((Join-Path $ToolkitRoot 'Config'))
    $localPath   = Join-Path $configDir 'settings.local.json'
    $defaultPath = Join-Path $configDir 'settings.json'

    if (Test-Path -Path $localPath -PathType Leaf) {
        return $localPath
    }
    return $defaultPath
}

function Get-SPConfig {
    <#
    .SYNOPSIS
        Loads configuration from settings.json
    .DESCRIPTION
        Reads the configuration file, merges with defaults, and returns a PSCustomObject.
        Caches the result by path. Use -Force to bypass cache.

        Local override convention: when -ConfigPath is omitted, settings.local.json
        next to settings.json wins if present. This lets the tracked settings.json
        stay as the CHANGE_ME template while developers run against a gitignored
        settings.local.json with stubs or real values.
    .PARAMETER ConfigPath
        Path to the settings.json file. Defaults to ..\..\Config\settings.local.json
        if present, otherwise ..\..\Config\settings.json (relative to the module
        location).
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

    # Determine config path. When -ConfigPath is not supplied, defer to
    # Resolve-SPConfigPath which honors the settings.local.json override.
    if (-not $ConfigPath) {
        $ConfigPath = Resolve-SPConfigPath
        Write-Verbose "Resolved default config path: $ConfigPath"
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
        Returns true if the configuration object is either:
          - a first-run placeholder (the _FirstRun marker set by Get-SPConfig
            when it auto-creates settings.json), OR
          - has unreplaced CHANGE_ME placeholder values in any required field.

        Either case means the operator has not finished configuring the
        toolkit and downstream steps (token acquisition, API calls) will fail
        in a confusing way.
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

    if ($Config.PSObject.Properties.Name -contains '_FirstRun' -and $Config._FirstRun -eq $true) {
        return $true
    }

    # Detect an unconfigured settings.json (all CHANGE_ME placeholders).
    # We only look at a curated set of required fields - checking every string
    # would false-positive on legitimate free-text values like EnvironmentName
    # set to a string that happens to contain 'CHANGE'.
    $fieldsToCheck = @(
        { $Config.Authentication.ConfigFile.TenantUrl },
        { $Config.Authentication.ConfigFile.OAuthTokenUrl },
        { $Config.Authentication.ConfigFile.ClientId },
        { $Config.Authentication.ConfigFile.ClientSecret },
        { $Config.Api.BaseUrl }
    )
    foreach ($getter in $fieldsToCheck) {
        $value = $null
        try { $value = & $getter } catch { continue }
        if ($null -ne $value -and $value -is [string] -and $value -match '(?i)CHANGE_ME') {
            return $true
        }
    }

    return $false
}

function New-SPConfigFile {
    <#
    .SYNOPSIS
        Creates a new configuration file with safe defaults
    .DESCRIPTION
        Generates a settings.json file with CHANGE_ME sentinel values.
        Called automatically on first run when no configuration file exists.

        The parent directory MUST already exist. If it doesn't, this function
        throws instead of silently creating arbitrary directory trees - a
        user-supplied typo like -ConfigPath 'C:\does\not\exist.json' would
        otherwise materialize 'C:\does\not\' on disk with no warning.
    .PARAMETER ConfigPath
        Path where the configuration file should be created. Parent directory
        must already exist.
    .OUTPUTS
        [string] Path to the created configuration file
    .EXCEPTION
        Throws [System.IO.DirectoryNotFoundException] if the parent directory
        does not already exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $configDir = Split-Path -Path $ConfigPath -Parent
    if (-not (Test-Path -Path $configDir -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new(
            "Cannot create config file: parent directory does not exist. " +
            "Create the directory first, or supply a -ConfigPath inside an " +
            "existing directory. Path given: '$ConfigPath' (parent: '$configDir')."
        )
    }

    $jsonContent = Get-SPConfigTemplate
    Set-Content -Path $ConfigPath -Value $jsonContent -Encoding UTF8

    return $ConfigPath
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-SPConfig',
    'Resolve-SPConfigPath',
    'Test-SPConfig',
    'Test-SPConfigFirstRun',
    'Test-SPConfiguration',
    'New-SPConfigFile'
)
