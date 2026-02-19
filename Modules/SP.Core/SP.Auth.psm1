#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit Authentication Module
.DESCRIPTION
    Provides OAuth 2.0 client_credentials authentication for SailPoint ISC.
    Supports two modes:
      - ConfigFile: ClientId/ClientSecret read directly from settings.json
      - Vault:      ClientId/ClientSecret retrieved from encrypted SP.Vault
    Token is cached with a 5-minute expiry buffer.
.NOTES
    Module: SP.Auth
    Version: 1.0.0
#>

# Script-scoped variables
$script:CurrentToken = $null
$script:TokenExpiry  = $null

#region Internal Functions

function Get-SPCredentialsFromConfig {
    <#
    .SYNOPSIS
        Reads ClientId and ClientSecret from the ConfigFile authentication section
    .OUTPUTS
        [hashtable] @{ClientId=[string]; ClientSecret=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    $config     = Get-SPConfig
    $cfgSection = $config.Authentication.ConfigFile

    if ([string]::IsNullOrWhiteSpace($cfgSection.ClientId)) {
        throw 'Authentication.ConfigFile.ClientId is not configured in settings.json'
    }
    if ([string]::IsNullOrWhiteSpace($cfgSection.ClientSecret)) {
        throw 'Authentication.ConfigFile.ClientSecret is not configured in settings.json'
    }

    Write-SPLog -Message 'Read credentials from ConfigFile mode' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    return @{
        ClientId      = $cfgSection.ClientId
        ClientSecret  = $cfgSection.ClientSecret
        OAuthTokenUrl = $cfgSection.OAuthTokenUrl
    }
}

function Get-SPCredentialsFromVault {
    <#
    .SYNOPSIS
        Retrieves ClientId and ClientSecret from the encrypted vault
    .OUTPUTS
        [hashtable] @{ClientId=[string]; ClientSecret=[string]; OAuthTokenUrl=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    $config       = Get-SPConfig
    $vaultSection = $config.Authentication.Vault
    $cfgSection   = $config.Authentication.ConfigFile

    if ([string]::IsNullOrWhiteSpace($vaultSection.VaultPath)) {
        throw 'Authentication.Vault.VaultPath is not configured in settings.json'
    }

    # Prompt for vault passphrase at runtime
    $passphrase = Read-Host -Prompt 'Enter vault passphrase' -AsSecureString

    Write-SPLog -Message 'Retrieving credentials from vault' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    $result = Get-SPVaultCredential `
        -VaultPath    $vaultSection.VaultPath `
        -Passphrase   $passphrase `
        -Key          $vaultSection.CredentialKey

    $passphrase.Dispose()

    if (-not $result.Success) {
        throw "Failed to retrieve credentials from vault: $($result.Error)"
    }

    return @{
        ClientId      = $result.Data.ClientId
        ClientSecret  = $result.Data.ClientSecret
        OAuthTokenUrl = $cfgSection.OAuthTokenUrl
    }
}

#endregion

#region Public Functions

function Get-SPAuthToken {
    <#
    .SYNOPSIS
        Acquires an OAuth 2.0 bearer token for SailPoint ISC API calls
    .DESCRIPTION
        Authenticates using client_credentials grant. Credential source is
        determined by Authentication.Mode in settings.json:
          - 'ConfigFile' reads from Authentication.ConfigFile
          - 'Vault'      reads from SP.Vault using Authentication.Vault settings
        Token is cached and reused until expiry minus 5-minute buffer.
        Returns a hashtable with Mode, Token, Headers, and ExpiresAt.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if not provided.
    .PARAMETER Force
        Force re-authentication even if a cached token is still valid.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=@{Mode; Token; Headers; ExpiresAt}; Error=[string]}
    .EXAMPLE
        $auth = Get-SPAuthToken
        if ($auth.Success) { Invoke-RestMethod -Headers $auth.Data.Headers -Uri $url }
    .EXAMPLE
        $auth = Get-SPAuthToken -Force -CorrelationID 'RUN-001'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$Force
    )

    try {
        # Generate correlation ID if not provided
        if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
            $CorrelationID = [guid]::NewGuid().ToString()
        }

        # Return cached token if valid and not forced
        if (-not $Force -and $null -ne $script:CurrentToken -and $null -ne $script:TokenExpiry) {
            if ($script:TokenExpiry -gt (Get-Date).AddMinutes(5)) {
                Write-SPLog -Message 'Using cached authentication token' -Severity 'DEBUG' `
                    -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID
                return @{ Success = $true; Data = $script:CurrentToken; Error = $null }
            }
        }

        Write-SPLog -Message 'Acquiring new OAuth 2.0 token' -Severity 'INFO' `
            -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID

        $config = Get-SPConfig
        $mode   = $config.Authentication.Mode

        # Resolve credentials based on mode
        $creds = $null
        if ($mode -eq 'ConfigFile') {
            $creds = Get-SPCredentialsFromConfig -CorrelationID $CorrelationID
        }
        elseif ($mode -eq 'Vault') {
            $creds = Get-SPCredentialsFromVault -CorrelationID $CorrelationID
        }
        else {
            throw "Unknown Authentication.Mode '$mode'. Valid values: ConfigFile, Vault"
        }

        if ([string]::IsNullOrWhiteSpace($creds.OAuthTokenUrl)) {
            throw 'Authentication.ConfigFile.OAuthTokenUrl is not configured in settings.json'
        }

        # Build form body for client_credentials grant
        $body = 'grant_type=client_credentials' +
                '&client_id=' + [uri]::EscapeDataString($creds.ClientId) +
                '&client_secret=' + [uri]::EscapeDataString($creds.ClientSecret)

        $timeoutSeconds = 60
        if ($config.Api.TimeoutSeconds) { $timeoutSeconds = $config.Api.TimeoutSeconds }

        $response = Invoke-RestMethod `
            -Uri         $creds.OAuthTokenUrl `
            -Method      Post `
            -Body        $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -TimeoutSec  $timeoutSeconds `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($response.access_token)) {
            throw 'ISC OAuth response did not contain access_token'
        }

        $expiresIn = if ($response.expires_in) { [int]$response.expires_in } else { 749 }
        $expiresAt = (Get-Date).AddSeconds($expiresIn)

        $tokenData = @{
            Mode      = $mode
            Token     = $response.access_token
            Headers   = @{
                'Authorization' = "Bearer $($response.access_token)"
                'Content-Type'  = 'application/json'
            }
            ExpiresAt = $expiresAt
        }

        # Cache the token
        $script:CurrentToken = $tokenData
        $script:TokenExpiry  = $expiresAt

        Write-SPLog -Message "OAuth 2.0 token acquired (mode: $mode, expires: $($expiresAt.ToString('yyyy-MM-ddTHH:mm:ssZ')))" `
            -Severity 'INFO' -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $tokenData; Error = $null }
    }
    catch {
        Write-SPLog -Message "Authentication failed: $($_.Exception.Message)" `
            -Severity 'ERROR' -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID

        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Clear-SPAuthToken {
    <#
    .SYNOPSIS
        Clears the cached authentication token from memory
    .DESCRIPTION
        Removes the cached token and expiry from script scope.
        Call when finished with API operations or on script exit.
    .EXAMPLE
        Clear-SPAuthToken
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:CurrentToken) {
        $script:CurrentToken.Token   = $null
        $script:CurrentToken.Headers = $null
        $script:CurrentToken         = $null
    }

    $script:TokenExpiry = $null
    [System.GC]::Collect()

    Write-SPLog -Message 'Cached auth token cleared from memory' `
        -Severity 'DEBUG' -Component 'SP.Auth' -Action 'ClearToken'
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-SPAuthToken',
    'Clear-SPAuthToken'
)
