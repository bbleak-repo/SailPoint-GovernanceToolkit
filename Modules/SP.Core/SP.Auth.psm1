#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit Authentication Module
.DESCRIPTION
    Provides authentication for SailPoint ISC. Supports three modes:
      - ConfigFile:   ClientId/ClientSecret read directly from settings.json
      - Vault:        ClientId/ClientSecret retrieved from encrypted SP.Vault
      - BrowserToken: Pre-obtained JWT pasted from browser dev tools (no OAuth flow)

    OAuth modes use client_credentials grant. Token is cached with a 5-minute
    expiry buffer.

    Browser token mode is useful for quick one-off queries when you are already
    logged into the ISC admin console. Open browser dev tools (F12), go to the
    Network tab, copy the Authorization header value from any API call, and pass
    the JWT to Set-SPBrowserToken. ISC browser tokens are typically valid for
    ~12 minutes (720 seconds).
.NOTES
    Module: SP.Auth
    Version: 1.1.0
#>

# --- Ensure modern TLS for the OAuth token call to ISC ---
# Windows PowerShell 5.1 / .NET can negotiate TLS 1.0 by default, which modern
# SailPoint ISC tenants reject. The token request is the first real-tenant call,
# so enable TLS 1.2 (and 1.3 when supported) here without downgrading anything.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
    }
} catch { }

# Script-scoped variables (module-scope cache -- cleared on each fresh module import)
$script:CurrentToken = $null
$script:TokenExpiry  = $null

# AppDomain-wide static token cache -- survives background STA runspace imports.
# In the same powershell.exe process every runspace shares the AppDomain, so a
# static .NET type defined here is accessible from all runspaces. This is the only
# reliable way to share an acquired vault token with background runspaces: they
# cannot call Read-Host (no interactive host), so they read the pre-acquired token
# from this cache instead of re-prompting for the vault passphrase.
# The try/catch handles re-imports in background runspaces where the type already
# exists in the AppDomain -- Add-Type throws on duplicate, but the existing instance
# (and its stored token) is exactly what we want to reuse.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
public static class SPAuthRunspaceCache {
    public static readonly ConcurrentDictionary<string, object> Store =
        new ConcurrentDictionary<string, object>(StringComparer.Ordinal);
}
'@
} catch { }  # Type already defined in this AppDomain -- reuse the existing instance.

# ---------------------------------------------------------------------------
# SPApiRateLimiter: AppDomain-static cross-runspace rate limiter.
#
# Problem: SP.ApiClient's $script:RequestTimestamps is per-scope, so each GUI
# background STA runspace has an independent counter.  When several operations
# run simultaneously (e.g. Hierarchical Report + Delta Cert Escalation + Health
# Check) their individual counters never exceed 95/10s, but ISC sees the
# aggregate traffic and returns 429.
#
# Fix: a thread-safe sliding-window queue shared across ALL runspaces in the
# same powershell.exe process (AppDomain). SP.ApiClient calls WaitForSlot()
# before every ISC request. The existing per-scope limiter remains as a
# belt-and-suspenders guard for single-runspace CLI scenarios.
#
# Architecture note: separate from SPAuthRunspaceCache by design -- different
# access semantics (token = rarely-changing singleton; rate limit = updated on
# every API call with time-based eviction). Mixing them would obscure intent.
#
# The try/catch handles the common case of a background runspace reimporting
# this module after the type is already compiled in the AppDomain.
# ---------------------------------------------------------------------------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Threading;

public static class SPApiRateLimiter {

    private static readonly Queue<long> _timestamps = new Queue<long>();
    private static readonly object      _lock       = new object();
    private static int  _maxRequests = 95;
    private static int  _windowMs    = 10000;
    private static bool _enabled     = true;

    // Called once by SP.ApiClient at first use, using RateLimitRequestsPerWindow
    // and RateLimitWindowSeconds from settings.json.
    public static void Configure(int maxRequests, int windowSeconds, bool enabled) {
        lock (_lock) {
            if (maxRequests > 0)   _maxRequests = maxRequests;
            if (windowSeconds > 0) _windowMs    = windowSeconds * 1000;
            _enabled = enabled;
        }
    }

    // Called before every Invoke-RestMethod in Invoke-SPApiRequest.
    // Blocks the calling runspace thread until a slot is available in the
    // current window, then records the call timestamp and returns.
    // Thread-safe: the lock is held only for the check; sleeping happens outside.
    public static void WaitForSlot() {
        if (!_enabled) return;

        while (true) {
            long sleepMs = 0;
            lock (_lock) {
                long nowMs       = DateTime.UtcNow.Ticks / 10000L;
                long windowStart = nowMs - _windowMs;

                // Evict timestamps older than the window
                while (_timestamps.Count > 0 && _timestamps.Peek() < windowStart) {
                    _timestamps.Dequeue();
                }

                if (_timestamps.Count < _maxRequests) {
                    _timestamps.Enqueue(nowMs);
                    return; // slot acquired -- proceed with the API call
                }

                // Window saturated: calculate sleep duration and release the lock
                long oldestMs = _timestamps.Peek();
                sleepMs = (_windowMs - (nowMs - oldestMs)) + 5L; // +5ms buffer
                if (sleepMs < 1L) sleepMs = 1L;
            }
            // Sleep outside the lock so other runspaces can check while we wait
            Thread.Sleep((int)sleepMs);
        }
    }

    // Reset visible to tests and admin/reset tooling.
    public static void Reset() {
        lock (_lock) { _timestamps.Clear(); }
    }
}
'@
} catch { }  # Type already defined -- reuse the existing instance.

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

    # Resolve VaultPath to an absolute path anchored at the toolkit root.
    # The raw config value is often a relative path (e.g. ".\Data\sp-vault.enc").
    # [System.IO.File]::ReadAllBytes() resolves relative paths from the .NET
    # process working directory (Environment.CurrentDirectory), which is
    # C:\Windows\System32 when PowerShell is launched from a system context --
    # not the toolkit root. Using PSScriptRoot (Modules\SP.Core\) + two levels
    # up gives the toolkit root regardless of how or where PowerShell was started.
    $vaultPath = [string]$vaultSection.VaultPath
    if (-not [System.IO.Path]::IsPathRooted($vaultPath)) {
        $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $vaultPath   = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot ($vaultPath.TrimStart('.\').TrimStart('./'))))
    }

    if (-not (Test-Path -LiteralPath $vaultPath -PathType Leaf)) {
        throw ("Vault file not found at '$vaultPath'. " +
               "Run New-SPVault.ps1 to create it, or set Authentication.Vault.VaultPath " +
               "to an absolute path in Config\settings.local.json.")
    }

    # Prompt for vault passphrase at runtime.
    # In a background STA runspace Read-Host throws "host does not support user
    # interaction." If this happens it means the cross-runspace static cache was
    # empty (token not yet acquired or already expired). The pre-warm block in
    # Show-SPDashboard.ps1 prevents this on startup; a session expiry during a
    # long run requires clicking any action to re-authenticate.
    $passphrase = $null
    try {
        $passphrase = Read-Host -Prompt 'Enter vault passphrase' -AsSecureString
    } catch {
        throw ("Vault passphrase cannot be collected in this context (background runspace). " +
               "This usually means the session token has expired. " +
               "Click any action button in the dashboard to re-authenticate, or restart the dashboard.")
    }

    Write-SPLog -Message 'Retrieving credentials from vault' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    $result = Get-SPVaultCredential `
        -VaultPath    $vaultPath `
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

        # 1. Check AppDomain-wide static cache first.
        #    Background STA runspaces cannot call Read-Host (no interactive host), so
        #    they must reuse a token acquired by the UI thread. The static cache is the
        #    only mechanism that crosses runspace module-scope boundaries within one
        #    powershell.exe process.
        if (-not $Force) {
            try {
                $xToken  = [SPAuthRunspaceCache]::Store['Token']     -as [string]
                $xExpiry = [SPAuthRunspaceCache]::Store['ExpiresAt'] -as [datetime]
                if (-not [string]::IsNullOrWhiteSpace($xToken) -and
                    $null -ne $xExpiry -and
                    $xExpiry -gt (Get-Date).AddMinutes(5)) {
                    $xMode = [string][SPAuthRunspaceCache]::Store['Mode']
                    $xData = @{
                        Mode      = $xMode
                        Token     = $xToken
                        Headers   = @{ 'Authorization' = "Bearer $xToken"; 'Content-Type' = 'application/json' }
                        ExpiresAt = $xExpiry
                    }
                    # Also warm the module-scope cache so repeated calls in this
                    # runspace don't re-hit the static dictionary.
                    $script:CurrentToken = $xData
                    $script:TokenExpiry  = $xExpiry
                    Write-SPLog -Message 'Using cross-runspace cached authentication token' -Severity 'DEBUG' `
                        -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID
                    return @{ Success = $true; Data = $xData; Error = $null }
                }
            } catch { }
        }

        # 2. Check module-scope cache (same runspace / session).
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

        # Cache the token -- both module-scope (this runspace) and AppDomain-static
        # (all other runspaces in this process).
        $script:CurrentToken = $tokenData
        $script:TokenExpiry  = $expiresAt
        try {
            [SPAuthRunspaceCache]::Store['Token']     = $response.access_token
            [SPAuthRunspaceCache]::Store['ExpiresAt'] = $expiresAt
            [SPAuthRunspaceCache]::Store['Mode']      = $mode
        } catch { }

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

function Set-SPBrowserToken {
    <#
    .SYNOPSIS
        Injects a pre-obtained browser JWT as the active authentication token.
    .DESCRIPTION
        Accepts a bearer token obtained from the ISC admin console browser session
        (via dev tools Network tab) and caches it as the active authentication token.
        Subsequent calls to Get-SPAuthToken will return this token until it expires
        or is cleared.

        ISC browser tokens are typically valid for ~12 minutes (720 seconds).
        The function sets a conservative default expiry of 10 minutes from injection
        to account for time elapsed between copying the token and pasting it.

        To obtain a token from the browser:
        1. Log into SailPoint ISC admin console
        2. Open browser dev tools (F12) > Network tab
        3. Click any action that triggers an API call
        4. Find the request, copy the Authorization header value
        5. Strip the "Bearer " prefix if present, paste the JWT
    .PARAMETER Token
        The JWT bearer token string. The "Bearer " prefix is stripped automatically
        if present.
    .PARAMETER ExpiryMinutes
        Minutes until the token is considered expired. Default: 10.
        Set higher if you just obtained a fresh token; lower if some time has passed.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=@{Mode; ExpiresAt}; Error=[string]}
    .EXAMPLE
        Set-SPBrowserToken -Token 'eyJhbGciOiJSUzI1NiIs...'
    .EXAMPLE
        Set-SPBrowserToken -Token 'Bearer eyJhbGciOiJSUzI1NiIs...' -ExpiryMinutes 5
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$ExpiryMinutes = 10,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # Strip "Bearer " prefix if present
        $jwt = $Token.Trim()
        if ($jwt.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) {
            $jwt = $jwt.Substring(7).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($jwt)) {
            throw 'Token is empty after stripping Bearer prefix.'
        }

        # Basic JWT structure validation (3 dot-separated segments)
        $segments = $jwt.Split('.')
        if ($segments.Count -ne 3) {
            throw "Token does not appear to be a valid JWT (expected 3 segments, got $($segments.Count))."
        }

        $expiresAt = (Get-Date).AddMinutes($ExpiryMinutes)

        $tokenData = @{
            Mode      = 'BrowserToken'
            Token     = $jwt
            Headers   = @{
                'Authorization' = "Bearer $jwt"
                'Content-Type'  = 'application/json'
            }
            ExpiresAt = $expiresAt
        }

        # Cache the token -- both module-scope and AppDomain-static.
        $script:CurrentToken = $tokenData
        $script:TokenExpiry  = $expiresAt
        try {
            [SPAuthRunspaceCache]::Store['Token']     = $jwt
            [SPAuthRunspaceCache]::Store['ExpiresAt'] = $expiresAt
            [SPAuthRunspaceCache]::Store['Mode']      = 'BrowserToken'
        } catch { }

        Write-SPLog -Message "Browser token injected (expires: $($expiresAt.ToString('yyyy-MM-ddTHH:mm:ssZ')), segments: $($segments.Count))" `
            -Severity 'INFO' -Component 'SP.Auth' -Action 'SetBrowserToken' -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{ Mode = 'BrowserToken'; ExpiresAt = $expiresAt }
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Set-SPBrowserToken failed: $($_.Exception.Message)" `
            -Severity 'ERROR' -Component 'SP.Auth' -Action 'SetBrowserToken' -CorrelationID $CorrelationID

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

    # Also clear the AppDomain-static cross-runspace cache so background runspaces
    # don't serve a stale token after a 401 / explicit clear.
    # Note: after clearing, the NEXT Get-SPAuthToken call on the UI thread will
    # re-prompt for the vault passphrase and repopulate both caches.
    try {
        [SPAuthRunspaceCache]::Store.TryRemove('Token',     [ref]$null) | Out-Null
        [SPAuthRunspaceCache]::Store.TryRemove('ExpiresAt', [ref]$null) | Out-Null
        [SPAuthRunspaceCache]::Store.TryRemove('Mode',      [ref]$null) | Out-Null
    } catch { }

    [System.GC]::Collect()

    Write-SPLog -Message 'Cached auth token cleared from memory (module-scope + cross-runspace)' `
        -Severity 'DEBUG' -Component 'SP.Auth' -Action 'ClearToken'
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-SPAuthToken',
    'Set-SPBrowserToken',
    'Clear-SPAuthToken'
)
