#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit Logging Module
.DESCRIPTION
    Provides structured JSONL logging for the SailPoint ISC Governance Toolkit.
    Log entries are appended one per line for easy SIEM/Splunk ingestion.
.NOTES
    Module: SP.Logging
    Version: 1.0.0
#>

# Script-scoped variables
$script:LogConfig  = $null
$script:LogPath    = $null
$script:SeverityLevels = @{
    'DEBUG' = 0
    'INFO'  = 1
    'WARN'  = 2
    'ERROR' = 3
}

#region Internal Functions

function Get-SPLoggingConfig {
    <#
    .SYNOPSIS
        Gets logging configuration, caching the result
    .OUTPUTS
        [PSCustomObject] Logging configuration
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($null -eq $script:LogConfig) {
        try {
            if (Get-Command -Name Get-SPConfig -ErrorAction SilentlyContinue) {
                $config = Get-SPConfig
                $script:LogConfig = $config.Logging
            }
        }
        catch {
            # Fallback to defaults if config not available
            $script:LogConfig = [PSCustomObject]@{
                Path            = '.\Logs'
                FilePrefix      = 'GovernanceToolkit'
                MinimumSeverity = 'INFO'
                RetentionDays   = 30
            }
        }
    }
    return $script:LogConfig
}

function Test-SPSeverityLevel {
    <#
    .SYNOPSIS
        Tests if a severity level should be logged based on minimum severity
    .PARAMETER Severity
        The severity to test
    .PARAMETER MinimumSeverity
        The minimum severity threshold
    .OUTPUTS
        [bool] True if should be logged
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Severity,

        [Parameter(Mandatory)]
        [string]$MinimumSeverity
    )

    $severityValue = $script:SeverityLevels[$Severity]
    $minimumValue  = $script:SeverityLevels[$MinimumSeverity]

    if ($null -eq $severityValue) { $severityValue = 1 }
    if ($null -eq $minimumValue)  { $minimumValue  = 1 }

    return $severityValue -ge $minimumValue
}

#endregion

#region Public Functions

function Initialize-SPLogging {
    <#
    .SYNOPSIS
        Initializes the logging subsystem
    .DESCRIPTION
        Creates the log directory if it does not exist and initializes
        $script:LogFilePath with daily rotation naming. Called automatically
        on module load. Use -Force to re-initialize.
    .PARAMETER Force
        Force re-initialization even if already initialized
    .EXAMPLE
        Initialize-SPLogging
        Initialize-SPLogging -Force
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )

    if ($Force) {
        $script:LogConfig = $null
        $script:LogPath   = $null
    }

    $config = Get-SPLoggingConfig

    # Resolve relative path to absolute using module root
    $logDir = $config.Path
    if (-not [System.IO.Path]::IsPathRooted($logDir)) {
        $logDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\$($config.Path)"
        $logDir = [System.IO.Path]::GetFullPath($logDir)
    }

    # Create directory if it does not exist
    if (-not (Test-Path -Path $logDir -PathType Container)) {
        try {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Warning "Failed to create log directory: $logDir. Error: $($_.Exception.Message)"
        }
    }

    $script:LogPath = $logDir
}

function Get-SPLogPath {
    <#
    .SYNOPSIS
        Returns the path to today's log file
    .DESCRIPTION
        Calculates the log file path based on configuration and current date.
        Format: {LogPath}\{FilePrefix}_{YYYY-MM-DD}.json
    .OUTPUTS
        [string] Full path to today's log file
    .EXAMPLE
        $logFile = Get-SPLogPath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($null -eq $script:LogPath) {
        Initialize-SPLogging
    }

    $config     = Get-SPLoggingConfig
    $dateString = Get-Date -Format 'yyyy-MM-dd'
    $fileName   = '{0}_{1}.json' -f $config.FilePrefix, $dateString

    return Join-Path -Path $script:LogPath -ChildPath $fileName
}

function Write-SPLog {
    <#
    .SYNOPSIS
        Writes a structured JSONL log entry to the daily log file
    .DESCRIPTION
        Creates a flat JSON log entry appended to a daily rotating JSONL file.
        Filtered by configured MinimumSeverity. Falls back to console on write failure.
    .PARAMETER Message
        The log message (required)
    .PARAMETER Severity
        Log severity level: DEBUG, INFO, WARN, ERROR. Default: INFO
    .PARAMETER Component
        The component or module generating the log. Default: SP.Core
    .PARAMETER Action
        The action being performed (e.g., CreateCampaign, GetToken)
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries across operations
    .PARAMETER CampaignTestId
        Test case identifier (e.g., TC-001)
    .PARAMETER AdditionalFields
        Hashtable of additional fields to include in the log entry
    .EXAMPLE
        Write-SPLog -Message 'Token acquired' -Severity INFO -Component 'SP.Auth' -Action 'GetToken'
    .EXAMPLE
        Write-SPLog -Message 'Campaign created' -Severity INFO -Component 'SP.Campaigns' `
            -Action 'CreateCampaign' -CampaignTestId 'TC-001' `
            -AdditionalFields @{ CampaignId = 'abc123'; CampaignName = 'Q1 Review' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Severity = 'INFO',

        [Parameter()]
        [string]$Component = 'SP.Core',

        [Parameter()]
        [string]$Action,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId,

        [Parameter()]
        [hashtable]$AdditionalFields
    )

    # Get config and check severity threshold
    $config          = Get-SPLoggingConfig
    $minimumSeverity = if ($config.MinimumSeverity) { $config.MinimumSeverity } else { 'INFO' }

    if (-not (Test-SPSeverityLevel -Severity $Severity -MinimumSeverity $minimumSeverity)) {
        return
    }

    # Get current user (platform-safe)
    $currentUser = 'Unknown'
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        if ($env:USERNAME) { $currentUser = $env:USERNAME }
        elseif ($env:USER) { $currentUser = $env:USER }
    }

    # Resolve environment name from config
    $environmentName = 'Unknown'
    try {
        if (Get-Command -Name Get-SPConfig -ErrorAction SilentlyContinue) {
            $fullConfig      = Get-SPConfig
            $environmentName = $fullConfig.Global.EnvironmentName
        }
    }
    catch {
        # Leave as Unknown
    }

    # Build JSONL log entry
    $logEntry = [ordered]@{
        Timestamp      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Severity       = $Severity
        Component      = $Component
        Action         = if ($Action) { $Action } else { '' }
        Message        = $Message
        CorrelationID  = if ($CorrelationID) { $CorrelationID } else { '' }
        CampaignTestId = if ($CampaignTestId) { $CampaignTestId } else { '' }
        User           = $currentUser
        Environment    = $environmentName
        Host           = $env:COMPUTERNAME
    }

    # Append additional fields
    if ($AdditionalFields) {
        foreach ($key in $AdditionalFields.Keys) {
            $logEntry[$key] = $AdditionalFields[$key]
        }
    }

    # Convert to single-line JSON
    $jsonLine = $logEntry | ConvertTo-Json -Compress -Depth 10

    # Write to log file
    $logFile = Get-SPLogPath
    try {
        Add-Content -Path $logFile -Value $jsonLine -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $logFile. Error: $($_.Exception.Message)"
        Write-Warning "Log entry: $jsonLine"
    }
}

#endregion

# Initialize logging on module load
Initialize-SPLogging

# Export public functions
Export-ModuleMember -Function @(
    'Write-SPLog',
    'Get-SPLogPath',
    'Initialize-SPLogging'
)
