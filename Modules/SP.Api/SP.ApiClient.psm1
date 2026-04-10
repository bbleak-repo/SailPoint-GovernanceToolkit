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

# Script-scoped rate limiter queue: stores DateTime of each request timestamp
# within the current sliding window.
$script:RequestTimestamps = [System.Collections.Generic.Queue[datetime]]::new()

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
        # Invoke-RestMethod in PS5.1 wraps in ErrorRecord; check ErrorDetails
        if ($statusCode -eq 0 -and $Exception.Message -match '(\d{3})') {
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
        Request body hashtable. Converted to JSON for POST/PUT/PATCH.
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
        [hashtable]$Body,

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
    $queryString = Build-SPQueryString -QueryParams $QueryParams
    $fullUrl     = $baseUrl + $cleanEndpoint + $queryString

    # Retry loop
    $maxRetries      = $config.Api.RetryCount
    $retryDelaySec   = $config.Api.RetryDelaySeconds
    $timeoutSec      = $config.Api.TimeoutSeconds
    $attempt         = 0
    $lastStatusCode  = 0
    $lastError       = ''

    while ($attempt -le $maxRetries) {
        # Rate limiting: wait if window is saturated
        $waitMs = Get-SPRateLimitWaitMs -Config $config
        if ($waitMs -gt 0) {
            Write-SPLog -Message "Rate limit reached. Waiting $waitMs ms before request." `
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

            # Attach body for mutating methods
            if ($Method -in @('POST', 'PUT', 'PATCH') -and $null -ne $Body) {
                $invokeParams['Body']        = $Body | ConvertTo-Json -Depth 20
                $invokeParams['ContentType'] = 'application/json'
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

            # Determine if we should retry
            $shouldRetry = ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599))

            if ($shouldRetry -and $attempt -lt $maxRetries) {
                if ($statusCode -eq 429) {
                    $waitRetryMs = Get-SPRetryAfterMs -Exception $exc -DefaultDelaySeconds $retryDelaySec
                    Write-SPLog -Message "Rate limited (429). Waiting $waitRetryMs ms before retry." `
                        -Severity WARN -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                    Start-Sleep -Milliseconds $waitRetryMs
                }
                else {
                    Write-SPLog -Message "Server error ($statusCode). Waiting $retryDelaySec s before retry." `
                        -Severity WARN -Component 'SP.ApiClient' -Action 'Invoke-SPApiRequest' `
                        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                    Start-Sleep -Seconds $retryDelaySec
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
