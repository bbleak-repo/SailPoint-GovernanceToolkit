#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Generic REST API Client
.DESCRIPTION
    Provides a generic, rate-limited, retry-capable REST client for the
    SailPoint ISC API. All calls go through Invoke-SPApiRequest which
    handles token acquisition, rate limiting, retries, and structured
    logging.
.NOTES
    Module: SP.ApiClient
    Version: 1.0.0
#>

# --- Ensure modern TLS for HTTPS calls to ISC ---
# Windows PowerShell 5.1 / .NET can negotiate TLS 1.0 by default, which modern
# SailPoint ISC tenants reject ("Could not create SSL/TLS secure channel"). Add
# TLS 1.2 (and 1.3 when the runtime supports it) without downgrading any protocol
# already enabled. This never triggers against the HTTP mock, only real tenants.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
    }
} catch { }

# Per-scope (per-runspace) sliding-window rate limiter.
# Correct for single-runspace CLI use; insufficient when multiple GUI background
# runspaces run simultaneously -- see SPApiRateLimiter in SP.Auth.psm1 for the
# AppDomain-static cross-runspace guard that complements this.
$script:RequestTimestamps = [System.Collections.Generic.Queue[datetime]]::new()

# Lazy configuration flag for SPApiRateLimiter.  Configure() is idempotent after
# the first call, but we avoid calling it on every request for performance.
$script:_sharedRateLimitConfigured = $false

#region Internal Functions

function Get-SPRateLimitWaitMs {
    <#
    .SYNOPSIS
        Calculates milliseconds to wait before the next request is allowed.
    .DESCRIPTION
        Inspects the sliding window queue.  Removes timestamps older than the
        window, then computes how long to sleep when the window is saturated.
    .PARAMETER Config
        The full configuration object (from Get-SPConfig).
    .OUTPUTS
        [int] Milliseconds to wait (0 if no wait needed).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $windowSeconds = $Config.Api.RateLimitWindowSeconds
    $maxRequests   = $Config.Api.RateLimitRequestsPerWindow
    $now           = Get-Date
    $windowStart   = $now.AddSeconds(-$windowSeconds)

    # Evict timestamps outside the window
    while ($script:RequestTimestamps.Count -gt 0 -and
           $script:RequestTimestamps.Peek() -lt $windowStart) {
        $script:RequestTimestamps.Dequeue() | Out-Null
    }

    if ($script:RequestTimestamps.Count -ge $maxRequests) {
        # Oldest timestamp in window: wait until it expires
        $oldest      = $script:RequestTimestamps.Peek()
        $expiresAt   = $oldest.AddSeconds($windowSeconds)
        $waitMs      = [int](($expiresAt - $now).TotalMilliseconds) + 50  # +50ms buffer
        if ($waitMs -lt 0) { $waitMs = 0 }
        return $waitMs
    }

    return 0
}

function Register-SPRequestTimestamp {
    <#
    .SYNOPSIS
        Records the current timestamp in the rate limiter queue.
    #>
    [CmdletBinding()]
    param()
    $script:RequestTimestamps.Enqueue((Get-Date))
}

function Build-SPQueryString {
    <#
    .SYNOPSIS
        Converts a hashtable of query parameters to a URL-encoded query string.
    .PARAMETER QueryParams
        Hashtable of key/value pairs.
    .OUTPUTS
        [string] Query string beginning with '?' or empty string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [hashtable]$QueryParams
    )

    if ($null -eq $QueryParams -or $QueryParams.Count -eq 0) {
        return ''
    }

    $pairs = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $QueryParams.Keys) {
        $encodedKey   = [System.Uri]::EscapeDataString($key)
        $encodedValue = [System.Uri]::EscapeDataString($QueryParams[$key].ToString())
        $pairs.Add("$encodedKey=$encodedValue")
    }

    return '?' + ($pairs -join '&')
}

function Get-SPStatusCodeFromException {
    <#
    .SYNOPSIS
        Extracts the HTTP status code from a WebException or similar.
    .PARAMETER Exception
        The caught exception object.
    .OUTPUTS
        [int] HTTP status code, or 0 if not determinable.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $statusCode = 0
    try {
        if ($Exception -is [System.Net.WebException]) {
            $webEx = [System.Net.WebException]$Exception
            if ($null -ne $webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
            }
        }
        elseif ($null -ne $Exception.InnerException) {
            if ($Exception.InnerException -is [System.Net.WebException]) {
                $webEx = [System.Net.WebException]$Exception.InnerException
                if ($null -ne $webEx.Response) {
                    $statusCode = [int]$webEx.Response.StatusCode
                }
            }
        }
        # Invoke-RestMethod in PS5.1 wraps in ErrorRecord; check ErrorDetails.
        # L1: restrict to plausible HTTP-error status codes (4xx/5xx) and require
        # the canonical WebException parenthesis format "(NNN)" so that bare
        # numbers in error messages — port numbers like "port 443", durations
        # like "200 ms", or error codes like "error 12002" — are never mistaken
        # for an HTTP status code.
        if ($statusCode -eq 0 -and $Exception.Message -match '\(([45]\d{2})\)') {
            $statusCode = [int]$Matches[1]
        }
    }
    catch {
        # Best-effort; return 0
    }
    return $statusCode
}

function Get-SPRetryAfterMs {
    <#
    .SYNOPSIS
        Extracts Retry-After header value (in ms) from a WebException response.
    .PARAMETER Exception
        The caught exception.
    .PARAMETER DefaultDelaySeconds
        Fallback delay if header not present.
    .OUTPUTS
        [int] Milliseconds to wait.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception,

        [Parameter(Mandatory)]
        [int]$DefaultDelaySeconds
    )

    $retryAfterMs = $DefaultDelaySeconds * 1000
    try {
        $webEx = $null
        if ($Exception -is [System.Net.WebException]) {
            $webEx = [System.Net.WebException]$Exception
        }
        elseif ($null -ne $Exception.InnerException -and
                $Exception.InnerException -is [System.Net.WebException]) {
            $webEx = [System.Net.WebException]$Exception.InnerException
        }

        if ($null -ne $webEx -and $null -ne $webEx.Response) {
            $retryAfterHeader = $webEx.Response.Headers['Retry-After']
            if (-not [string]::IsNullOrWhiteSpace($retryAfterHeader)) {
                $retrySeconds = [int]0
                if ([int]::TryParse($retryAfterHeader, [ref]$retrySeconds)) {
                    $retryAfterMs = $retrySeconds * 1000
                }
            }
        }
    }
    catch {
        # Use default
    }
    return $retryAfterMs
}

#endregion

#region Public Functions

function Invoke-SPApiRequest {
    <#
    .SYNOPSIS
        Generic rate-limited, retry-capable REST client for SailPoint ISC API.
    .DESCRIPTION
        Handles authentication token acquisition, sliding-window rate limiting,
        and exponential-style retry on 429 / 5xx responses.
        All requests and responses are logged via Write-SPLog.
        Returns a normalized hashtable: @{Success; Data; StatusCode; Error}.
    .PARAMETER Method
        HTTP method: GET, POST, PUT, DELETE, PATCH.
    .PARAMETER Endpoint
        Relative path appended to the configured Api.BaseUrl (e.g. "/campaigns").
    .PARAMETER Body
        Request body (hashtable or array). Converted to JSON for POST/PUT/PATCH.
        Arrays are supported for JSON Patch (RFC 6902) operations.
    .PARAMETER ContentType
        Content-Type header for the request body. Defaults to 'application/json'.
        Use 'application/json-patch+json' for RFC 6902 PATCH operations.
    .PARAMETER QueryParams
        Query string parameters as a hashtable.
    .PARAMETER CorrelationID
        Unique ID for tracing related operations across log entries.
    .PARAMETER CampaignTestId
        Test case identifier (e.g. TC-001) for log correlation.
    .PARAMETER RawResponse
        When specified, returns the raw Invoke-RestMethod response in Data
        without additional wrapping.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$object; StatusCode=$int; Error=$string}
    .EXAMPLE
        $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID $cid
        if ($result.Success) { $result.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter()]
        $Body,

        [Parameter()]
        [string]$ContentType = 'application/json',

        [Parameter()]
        [hashtable]$QueryParams,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId,

        [Parameter()]
        [switch]$RawResponse
    )

    # Generate CorrelationID if not provided
    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Retrieve configuration
    $config = $null
    try {
        $config = Get-SPConfig
    }
    catch {
        $errMsg = "Failed to load configuration: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.ApiClient' `
            -Action 'Invoke-SPApiRequest' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; StatusCode = 0; Error = $errMsg }
    }

    # Acquire auth token
    $authResult = $null
    try {
        $authResult = Get-SPAuthToken -CorrelationID $CorrelationID
    }
    catch {
        $errMsg = "Failed to acquire auth token: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.ApiClient' `
            -Action 'Invoke-SPApiRequest' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; StatusCode = 0; Error = $errMsg }
    }

    if (-not $authResult.Success) {
        $errMsg = "Auth token acquisition failed: $($authResult.Error)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.ApiClient' `
            -Action 'Invoke-SPApiRequest' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; StatusCode = 401; Error = $errMsg }
    }

    $headers = $authResult.Data.Headers

    # Build full URL
    $baseUrl     = $config.Api.BaseUrl.TrimEnd('/')
    $cleanEndpoint = if ($Endpoint.StartsWith('/')) { $Endpoint } else { '/' + $Endpoint }

    # Version-segment normalization: Api.BaseUrl is configured WITH the API version
    # (e.g. "https://tenant.api.identitynow.com/v3"), but some callers pass endpoints
    # that also carry the version prefix (e.g. '/v3/entitlements'). Without this guard
    # the request goes to '/v3/v3/entitlements' and 404s. If the base URL's last path
    # segment (v3, v2, beta, ...) matches the endpoint's first segment, drop the
    # duplicate from the endpoint so both endpoint styles work.
    $baseVersionSeg = ($baseUrl -split '/')[-1]
    if ($baseVersionSeg -match '^(v\d+|beta)$' -and
        ($cleanEndpoint -eq "/$baseVersionSeg" -or $cleanEndpoint.StartsWith("/$baseVersionSeg/", [System.StringComparison]::OrdinalIgnoreCase))) {
        $cleanEndpoint = $cleanEndpoint.Substring($baseVersionSeg.Length + 1)
        if (-not $cleanEndpoint.StartsWith('/')) { $cleanEndpoint = '/' + $cleanEndpoint }
    }

    $queryString = Build-SPQueryString -QueryParams $QueryParams
    $fullUrl     = $baseUrl + $cleanEndpoint + $queryString

    # Retry loop
    $maxRetries         = $config.Api.RetryCount
    $retryDelaySec      = $config.Api.RetryDelaySeconds
    $maxRetryDelaySec   = if ($config.Api.PSObject.Properties.Name -contains 'MaxRetryDelaySeconds' -and
                               $config.Api.MaxRetryDelaySeconds -gt 0) {
                              $config.Api.MaxRetryDelaySeconds
                          } else { 60 }
    $timeoutSec         = $config.Api.TimeoutSeconds
    $attempt            = 0
    $lastStatusCode     = 0
    $lastError          = ''

    # Lazy-configure the AppDomain-static cross-runspace rate limiter on first request
    # in this module scope. Subsequent calls skip this block (flag check is cheap).
    if (-not $script:_sharedRateLimitConfigured) {
        try {
            $sharedEnabled = $true
            if ($null -ne $config.PSObject.Properties['Api'] -and
                $null -ne $config.Api -and
                $null -ne $config.Api.PSObject.Properties['SharedRateLimitEnabled']) {
                $sharedEnabled = [bool]$config.Api.SharedRateLimitEnabled
            }
            $sharedMax = [int]$config.Api.RateLimitRequestsPerWindow
            $sharedWin = [int]$config.Api.RateLimitWindowSeconds
            [SPApiRateLimiter]::Configure($sharedMax, $sharedWin, $sharedEnabled)
        }
        catch {
            # SP.Core not yet imported or type not available -- shared limiter inactive
        }
        $script:_sharedRateLimitConfigured = $true
    }

    while ($attempt -le $maxRetries) {
        # Cross-runspace guard: blocks this runspace thread if the aggregate request
        # rate across all runspaces in this process has reached the window limit.
        # Complements the per-scope limiter below; no-op if SPApiRateLimiter is
        # unavailable (e.g. SP.Core not loaded in this session).
        try { [SPApiRateLimiter]::WaitForSlot() } catch { }

        # Per-scope rate limiting: wait if THIS runspace's window is saturated
        $waitMs = Get-SPRateLimitWaitMs -Config $config
        if ($waitMs -gt 0) {
            Write-SPLog -Message "Rate limit reached (per-scope). Waiting $waitMs ms before request." `
                -Severity WARN -Component 'SP.ApiClient' -Action 'RateLimit' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            Start-Sleep -Milliseconds $waitMs
        }

        Write-SPLog -Message "API Request: $Method $fullUrl (attempt $($attempt + 1) of $($maxRetries + 1))" `
            -Severity DEBUG -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        try {
            $invokeParams = @{
                Method      = $Method
                Uri         = $fullUrl
                Headers     = $headers
                TimeoutSec  = $timeoutSec
                ErrorAction = 'Stop'
            }

            # Attach body for mutating methods.
            # -InputObject (not pipeline): piping unrolls a single-element array, so a
            # one-operation RFC 6902 JSON Patch would serialize as {...} instead of
            # [{...}] and ISC rejects it with 400.
            if ($Method -in @('POST', 'PUT', 'PATCH') -and $null -ne $Body) {
                $invokeParams['Body']        = ConvertTo-Json -InputObject $Body -Depth 20
                $invokeParams['ContentType'] = $ContentType
            }

            # Record timestamp before the call
            Register-SPRequestTimestamp

            $response = Invoke-RestMethod @invokeParams

            Write-SPLog -Message "API Response: $Method $fullUrl -> Success" `
                -Severity DEBUG -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            return @{
                Success    = $true
                Data       = $response
                StatusCode = 200
                Error      = $null
            }
        }
        catch {
            $exc        = $_.Exception
            $statusCode = Get-SPStatusCodeFromException -Exception $exc
            $lastStatusCode = $statusCode
            $lastError  = $exc.Message

            Write-SPLog -Message "API Error: $Method $fullUrl -> Status $statusCode, Error: $lastError (attempt $($attempt + 1))" `
                -Severity WARN -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            # H2: 401 on the first attempt most likely means the cached OAuth
            # token has expired mid-run. Evict the cache, force-acquire a new
            # token, and retry ONCE with the fresh headers. If the second
            # attempt also 401s, the credentials are genuinely bad and we let
            # the normal fallthrough report it.
            if ($statusCode -eq 401 -and $attempt -eq 0) {
                Write-SPLog -Message "401 Unauthorized on first attempt; evicting cached token and refreshing." `
                    -Severity WARN -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                    -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                try { Clear-SPAuthToken } catch { }
                $refreshResult = $null
                try {
                    $refreshResult = Get-SPAuthToken -Force -CorrelationID $CorrelationID
                }
                catch {
                    $refreshResult = @{ Success = $false; Error = $_.Exception.Message }
                }
                if ($null -ne $refreshResult -and $refreshResult.Success) {
                    $headers = $refreshResult.Data.Headers
                    $attempt++
                    continue
                }
                # Refresh failed: stop retrying; caller sees 401/error.
                $lastError = "Token refresh after 401 failed: $($refreshResult.Error)"
                break
            }

            # Determine if we should retry.
            # H3: status=0 represents a WebException with no Response object -
            # transient connection-level failures (DNS blip, TLS hiccup,
            # connection reset). These are exactly the kind of thing a retry
            # will often paper over; not retrying makes long-running audits
            # fragile on flaky networks.
            $shouldRetry = (
                $statusCode -eq 429 -or
                ($statusCode -ge 500 -and $statusCode -le 599) -or
                $statusCode -eq 0
            )

            if ($shouldRetry -and $attempt -lt $maxRetries) {
                if ($statusCode -eq 429) {
                    # 429: always honor Retry-After; no exponential backoff here.
                    $waitRetryMs = Get-SPRetryAfterMs -Exception $exc -DefaultDelaySeconds $retryDelaySec
                    Write-SPLog -Message "Rate limited (429). Waiting $waitRetryMs ms before retry." `
                        -Severity WARN -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                    Start-Sleep -Milliseconds $waitRetryMs
                }
                else {
                    # L2: exponential backoff for 5xx AND status=0 connection
                    # failures (the H3-era constant-delay elseif was removed
                    # during merge - the $label below distinguishes the two
                    # cases for the log entry).
                    # delay = min(retryDelaySec * 2^attempt, maxRetryDelaySec)
                    # attempt is 0-indexed so the first retry uses delay * 1.
                    $backoffSec = [Math]::Min(
                        $retryDelaySec * [Math]::Pow(2, $attempt),
                        $maxRetryDelaySec
                    )
                    $label = if ($statusCode -eq 0) { 'Connection-level error (no HTTP status)' } else { "Server error ($statusCode)" }
                    Write-SPLog -Message "$label. Waiting $backoffSec s before retry (attempt $($attempt + 1), backoff). Underlying: $lastError" `
                        -Severity WARN -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                    Start-Sleep -Seconds $backoffSec
                }

                $attempt++
                continue
            }

            # Non-retryable or exhausted retries
            break
        }
    }

    # All retries exhausted or non-retryable failure
    $finalError = "Request failed after $($attempt + 1) attempt(s): $lastError (HTTP $lastStatusCode)"
    Write-SPLog -Message $finalError -Severity ERROR -Component 'SP.ApiClient' `
        -Action 'Invoke-SPApiRequest' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    return @{
        Success    = $false
        Data       = $null
        StatusCode = $lastStatusCode
        Error      = $finalError
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPApiRequest'
)
