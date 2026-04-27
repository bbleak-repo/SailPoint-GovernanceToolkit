#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Campaign Audit Query Functions
.DESCRIPTION
    Provides functions for auditing SailPoint ISC certification campaigns:
    retrieving campaigns with date filtering, fetching certifications with
    reviewer classification, pulling access review items, downloading or
    importing campaign report CSVs, and resolving provisioning events for
    specific identities.

    All HTTP calls are delegated to Invoke-SPApiRequest.  Report downloads
    that require the legacy /cc/api endpoint call Invoke-RestMethod directly
    using the bearer token from Get-SPAuthToken.

    ISC API constraints observed in this module:
      - Campaign list filtering supports: id, name, status only (no date).
        Date filtering is applied client-side on the 'created' field.
      - Bulk decide cap: 250 items.
      - Rate limit: 95 requests / 10 s.
.NOTES
    Module: SP.AuditQueries
    Version: 1.0.0
#>

# Module-scope source name cache to avoid redundant API calls within a session.
$script:SourceNameCache = @{}

#region Internal Functions

function Get-SPAuditSourceName {
    <#
    .SYNOPSIS
        Resolves a source ID to its display name, with in-memory caching.
    .DESCRIPTION
        Calls GET /sources/{sourceId} once per unique ID per session.
        On success the name is cached; on failure the sourceId is returned
        as the fallback display value so callers always receive a string.
    .PARAMETER SourceId
        The SailPoint ISC source ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [string] Source display name, or sourceId on error.
    .EXAMPLE
        $name = Get-SPAuditSourceName -SourceId 'src-abc123' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Return cached name immediately
    if ($script:SourceNameCache.ContainsKey($SourceId)) {
        return $script:SourceNameCache[$SourceId]
    }

    Write-SPLog -Message "Resolving source name for ID '$SourceId'" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditSourceName' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/sources/$SourceId" `
            -CorrelationID $CorrelationID

        if ($result.Success -and $null -ne $result.Data) {
            $sourceName = $result.Data.name
            if ([string]::IsNullOrWhiteSpace($sourceName)) {
                $sourceName = $SourceId
            }
            $script:SourceNameCache[$SourceId] = $sourceName
            return $sourceName
        }
    }
    catch {
        Write-SPLog -Message "Get-SPAuditSourceName failed for '$SourceId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAuditSourceName' `
            -CorrelationID $CorrelationID
    }

    # Fallback: cache and return the raw ID so we do not call the API again
    $script:SourceNameCache[$SourceId] = $SourceId
    return $SourceId
}

#endregion

#region Public Functions

function Get-SPAuditCampaigns {
    <#
    .SYNOPSIS
        Retrieves certification campaigns with optional name, status, and date filters.
    .DESCRIPTION
        GETs /v3/campaigns with detail=FULL and auto-paginates across all pages.
        Name and status filters are applied server-side via the ISC 'filters' query
        parameter.  Date filtering is applied client-side because the ISC campaign
        API does not support filtering on the 'created' field directly.

        Supported server-side filter operators used here:
          name eq "..."    - exact name match
          name sw "..."    - starts-with match
          name co "..."    - substring (contains) match
          status in (...)  - one or more status values
    .PARAMETER CampaignName
        Optional exact name match. Translates to: name eq "..."
    .PARAMETER CampaignNameStartsWith
        Optional starts-with name match. Translates to: name sw "..."
        Ignored if CampaignName is also specified.
    .PARAMETER CampaignNameContains
        Optional substring (contains) name match. Translates to: name co "..."
        Ignored if CampaignName or CampaignNameStartsWith is also specified.
        This is the recommended filter for fuzzy searching -- ISC does not support
        wildcards (*test*) and the admin UI only does prefix matching.
    .PARAMETER Status
        Optional array of status values to filter by.
        Valid values: STAGED, ACTIVATING, ACTIVE, COMPLETING, COMPLETED, ERROR.
        Translates to: status in ("COMPLETED","ACTIVE")
    .PARAMETER DaysBack
        Number of calendar days to look back from now when filtering campaigns
        by their 'created' timestamp. Filtering is client-side. Default: 30.
        Set to 0 or a negative number to disable date filtering.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([campaign objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCampaigns -Status 'COMPLETED','ACTIVE' -DaysBack 90
        $campaigns = $result.Data
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CampaignName 'Q1 2026 Access Review' -DaysBack 0
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignName,

        [Parameter()]
        [string]$CampaignNameStartsWith,

        [Parameter()]
        [string]$CampaignNameContains,

        [Parameter()]
        [string[]]$Status,

        [Parameter()]
        [int]$DaysBack = 30,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting audit campaigns: Name='$CampaignName', NameSW='$CampaignNameStartsWith', NameCO='$CampaignNameContains', Status='$($Status -join ',')' DaysBack=$DaysBack" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
        -CorrelationID $CorrelationID

    try {
        # Build server-side filter expression
        $filterParts = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($CampaignName)) {
            $escaped = $CampaignName.Replace('"', '\"')
            $filterParts.Add("name eq `"$escaped`"")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) {
            $escaped = $CampaignNameStartsWith.Replace('"', '\"')
            $filterParts.Add("name sw `"$escaped`"")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
            $escaped = $CampaignNameContains.Replace('"', '\"')
            $filterParts.Add("name co `"$escaped`"")
        }

        if ($null -ne $Status -and $Status.Count -gt 0) {
            $quotedStatuses = ($Status | ForEach-Object { "`"$_`"" }) -join ','
            $filterParts.Add("status in ($quotedStatuses)")
        }

        $queryParams = @{
            'detail' = 'FULL'
            'limit'  = '250'
            'offset' = '0'
        }

        if ($filterParts.Count -gt 0) {
            $queryParams['filters'] = ($filterParts -join ' and ')
        }

        # Auto-paginate
        $allCampaigns = [System.Collections.Generic.List[object]]::new()
        $pageSize     = 250
        $offset       = 0
        $pageNum      = 0

        do {
            $pageNum++
            $queryParams['offset'] = $offset.ToString()

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCampaigns failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize: API may wrap items or return array directly
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($campaign in $page) {
                    $allCampaigns.Add($campaign)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) campaigns (running total: $($allCampaigns.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCampaigns.Count) campaigns before date filtering" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
            -CorrelationID $CorrelationID

        # Client-side date filter on 'created' field
        $filteredCampaigns = [System.Collections.Generic.List[object]]::new()
        if ($DaysBack -gt 0) {
            $cutoff = (Get-Date).AddDays(-$DaysBack)
            foreach ($campaign in $allCampaigns) {
                $createdRaw = $campaign.created
                if ($null -eq $createdRaw) {
                    # No created date -- include to avoid silent exclusion
                    $filteredCampaigns.Add($campaign)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = [datetime]$createdRaw
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate
                    }
                }

                if ($null -eq $createdDate -or $createdDate -ge $cutoff) {
                    $filteredCampaigns.Add($campaign)
                }
            }

            Write-SPLog -Message "Date filter (last $DaysBack days): $($allCampaigns.Count) -> $($filteredCampaigns.Count) campaigns" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID
        }
        else {
            foreach ($campaign in $allCampaigns) { $filteredCampaigns.Add($campaign) }
            Write-SPLog -Message "Date filtering disabled (DaysBack=$DaysBack). Returning all $($filteredCampaigns.Count) campaigns." `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = $filteredCampaigns.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCertifications {
    <#
    .SYNOPSIS
        Retrieves all certifications for a campaign with reviewer classification.
    .DESCRIPTION
        GETs /v3/certifications filtered by campaign.id and auto-paginates.
        Each certification is annotated with a 'ReviewerClassification' property:
          'Primary'    - reviewer taken from cert.reviewer (no reassignment)
          'Reassigned' - reviewer taken from cert.reassignment (reassigned cert)
        The effective reviewer object is surfaced as 'EffectiveReviewer' on each
        returned certification object for convenient downstream processing.
    .PARAMETER CampaignId
        The campaign ID to retrieve certifications for. Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([cert objects with classification]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCertifications -CampaignId 'camp-abc123' -CorrelationID $cid
        foreach ($cert in $result.Data) {
            "$($cert.EffectiveReviewer.displayName) [$($cert.ReviewerClassification)]"
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting audit certifications for campaign '$CampaignId' (auto-paginating)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
        -CorrelationID $CorrelationID

    try {
        $allCerts = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0

        do {
            $pageNum++
            $queryParams = @{
                'filters' = "campaign.id eq `"$CampaignId`""
                'limit'   = $pageSize.ToString()
                'offset'  = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/certifications' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCertifications failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($cert in $page) {
                    # Classify reviewer: reassigned vs primary
                    $classification   = 'Primary'
                    $effectiveReviewer = $cert.reviewer

                    if ($null -ne $cert.PSObject.Properties['reassignment'] -and
                        $null -ne $cert.reassignment) {
                        $classification    = 'Reassigned'
                        # The reassignment object contains the new reviewer
                        if ($null -ne $cert.reassignment.PSObject.Properties['to'] -and
                            $null -ne $cert.reassignment.to) {
                            $effectiveReviewer = $cert.reassignment.to
                        }
                    }

                    # Attach classification properties (Add-Member works on PS custom objects)
                    $cert | Add-Member -MemberType NoteProperty -Name 'ReviewerClassification' `
                        -Value $classification -Force
                    $cert | Add-Member -MemberType NoteProperty -Name 'EffectiveReviewer' `
                        -Value $effectiveReviewer -Force

                    $allCerts.Add($cert)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) certifications (running total: $($allCerts.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCerts.Count) total certifications for campaign '$CampaignId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allCerts.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCertifications failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCertificationItems {
    <#
    .SYNOPSIS
        Retrieves all access review items for a single certification, auto-paginating.
    .DESCRIPTION
        GETs /v3/certifications/{certId}/access-review-items and auto-paginates.
        Each item includes decision (APPROVE/REVOKE), access (type/name),
        identitySummary, and account details as returned by the ISC API.
    .PARAMETER CertificationId
        The certification ID to retrieve access review items for. Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([item objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCertificationItems -CertificationId 'cert-xyz' -CorrelationID $cid
        $items = $result.Data
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting access review items for certification '$CertificationId' (auto-paginating)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
        -CorrelationID $CorrelationID

    try {
        $allItems = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $endpoint = "/certifications/$CertificationId/access-review-items"

        do {
            $pageNum++
            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint $endpoint `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCertificationItems failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allItems.Add($item) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) access review items (running total: $($allItems.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allItems.Count) total access review items for certification '$CertificationId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allItems.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCertificationItems failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCampaignReport {
    <#
    .SYNOPSIS
        Downloads a campaign report CSV from the SailPoint ISC legacy report API.
    .DESCRIPTION
        Two-step process:
          Step 1: GET /v3/campaigns/{campaignId}/reports
                  Finds the matching reportType entry and extracts taskResultId.
          Step 2: GET /cc/api/report/get/{taskResultId}?format=csv
                  Downloads the CSV using a direct Invoke-RestMethod call against
                  the tenant base URL (not the /v3 API base).  The bearer token is
                  obtained from Get-SPAuthToken.

        The legacy /cc/api endpoint is NOT routed through Invoke-SPApiRequest because
        its URL root differs from Api.BaseUrl (/v3).  The function builds the full
        URL from Authentication.ConfigFile.TenantUrl.

        Graceful fallback:
          If the legacy endpoint returns 403 or 404, the function returns Success=$false
          with an instructional error message advising the caller to download the CSV
          manually and use Import-SPAuditCampaignReport instead.

        If OutputDir is specified and the download succeeds, the CSV is written to
        disk as: {OutputDir}\{CampaignId}_{ReportType}.csv
    .PARAMETER CampaignId
        The campaign ID to download the report for. Mandatory.
    .PARAMETER ReportType
        The report type to download.
        Valid values: CAMPAIGN_STATUS_REPORT, CERTIFICATION_SIGNOFF_REPORT
    .PARAMETER OutputDir
        Optional directory path where the downloaded CSV file will be saved.
        If omitted the CSV content is returned in Data but not written to disk.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=[string CSV content or $null]; Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCampaignReport -CampaignId 'camp-abc' `
                    -ReportType CAMPAIGN_STATUS_REPORT -OutputDir 'C:\Reports'
        if ($result.Success) { Write-Host "Saved to $($result.Data)" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter(Mandatory)]
        [ValidateSet('CAMPAIGN_STATUS_REPORT', 'CERTIFICATION_SIGNOFF_REPORT')]
        [string]$ReportType,

        [Parameter()]
        [string]$OutputDir,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Downloading campaign report: CampaignId='$CampaignId', ReportType='$ReportType'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: List available reports for the campaign
        $reportsResult = Invoke-SPApiRequest -Method GET `
            -Endpoint "/campaigns/$CampaignId/reports" `
            -CorrelationID $CorrelationID

        if (-not $reportsResult.Success) {
            $errMsg = "Failed to list reports for campaign '$CampaignId': $($reportsResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Find the matching report entry
        $reportsData = $reportsResult.Data
        if ($null -eq $reportsData) { $reportsData = @() }

        # API may return array directly or object with items
        if ($reportsData.PSObject.Properties.Name -contains 'items') {
            $reportsData = $reportsData.items
        }
        # Force array wrap (H1 fix) - a single report in the .items array
        # would otherwise be unwrapped to a bare object and the foreach below
        # would iterate its PROPERTIES instead of finding the single report.
        $reportsData = @($reportsData)

        $matchingReport = $null
        foreach ($report in $reportsData) {
            if ($report.type -eq $ReportType -or $report.reportType -eq $ReportType) {
                $matchingReport = $report
                break
            }
        }

        if ($null -eq $matchingReport) {
            $errMsg = "Report type '$ReportType' not found in campaign '$CampaignId' report list. " +
                      "The campaign may not be completed, or this report type is unavailable."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Extract taskResultId - field name varies by ISC version
        $taskResultId = $null
        foreach ($prop in @('taskResultId', 'task_result_id', 'taskId', 'id')) {
            if ($null -ne $matchingReport.PSObject.Properties[$prop]) {
                $taskResultId = $matchingReport.$prop
                if (-not [string]::IsNullOrWhiteSpace($taskResultId)) { break }
            }
        }

        if ([string]::IsNullOrWhiteSpace($taskResultId)) {
            $errMsg = "Could not extract taskResultId from report object for type '$ReportType'. " +
                      "Use Import-SPAuditCampaignReport to import a manually downloaded CSV."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        Write-SPLog -Message "Found report '$ReportType' with taskResultId='$taskResultId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        # Step 2: Download CSV - try v3 API first, fall back to legacy /cc/api
        # v3 endpoint: GET /reports/{taskResultId}?fileFormat=csv  (available since Nov 2023)
        # Legacy:      GET /cc/api/report/get/{taskResultId}?format=csv (deprecated Feb 2024)
        $csvContent = $null

        # --- Attempt v3 first via Invoke-SPApiRequest ---
        Write-SPLog -Message "Attempting v3 report download for taskResultId='$taskResultId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        $v3Result = Invoke-SPApiRequest -Method GET `
            -Endpoint "/reports/$taskResultId" `
            -QueryParams @{ fileFormat = 'csv' } `
            -RawResponse `
            -CorrelationID $CorrelationID

        if ($v3Result.Success -and $null -ne $v3Result.Data) {
            $csvContent = $v3Result.Data
            Write-SPLog -Message "v3 report download succeeded for taskResultId='$taskResultId'" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID
        }
        else {
            # --- Silent fallback to legacy /cc/api ---
            Write-SPLog -Message "v3 report download failed (StatusCode=$($v3Result.StatusCode)). Falling back to legacy /cc/api." `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID

            $config    = Get-SPConfig
            $tenantUrl = $config.Authentication.ConfigFile.TenantUrl.TrimEnd('/')

            if ([string]::IsNullOrWhiteSpace($tenantUrl)) {
                $tenantUrl = $config.Api.BaseUrl -replace '/v3$', '' -replace '/v3/', ''
                $tenantUrl = $tenantUrl.TrimEnd('/')
            }

            $reportUrl = "$tenantUrl/cc/api/report/get/$taskResultId" + '?format=csv'

            Write-SPLog -Message "Calling legacy report URL: $reportUrl" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID

            $authResult = Get-SPAuthToken -CorrelationID $CorrelationID
            if (-not $authResult.Success) {
                $errMsg = "Cannot acquire auth token for report download: $($authResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $timeoutSec = 120
            try {
                $configTimeout = $config.Api.TimeoutSeconds
                if ($configTimeout -gt 0) { $timeoutSec = $configTimeout }
            }
            catch { }

            try {
                $csvContent = Invoke-RestMethod `
                    -Uri        $reportUrl `
                    -Method     GET `
                    -Headers    $authResult.Data.Headers `
                    -TimeoutSec $timeoutSec `
                    -ErrorAction Stop
            }
            catch {
                $exc        = $_.Exception
                $statusCode = 0
                try {
                    if ($exc -is [System.Net.WebException] -and $null -ne $exc.Response) {
                        $statusCode = [int]$exc.Response.StatusCode
                    }
                    elseif ($exc.Message -match '(\d{3})') {
                        $statusCode = [int]$Matches[1]
                    }
                }
                catch { }

                if ($statusCode -eq 403 -or $statusCode -eq 404) {
                    $errMsg = "Campaign report API unavailable (v3 and legacy both failed) for taskResultId='$taskResultId'. " +
                              "Download the CSV manually from the SailPoint UI and use " +
                              "Import-SPAuditCampaignReport -CsvDirectoryPath to import it."
                    Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $errMsg = "Report download failed (HTTP $statusCode): $($exc.Message)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }
        }

        # Optionally persist to disk
        if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
            if (-not (Test-Path -Path $OutputDir -PathType Container)) {
                New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
            }
            $safeReportType = $ReportType -replace '[^A-Za-z0-9_\-]', '_'
            $fileName       = "${CampaignId}_${safeReportType}.csv"
            $filePath       = Join-Path -Path $OutputDir -ChildPath $fileName
            Set-Content -Path $filePath -Value $csvContent -Encoding UTF8
            Write-SPLog -Message "Campaign report saved to '$filePath'" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = $csvContent; Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCampaignReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Import-SPAuditCampaignReport {
    <#
    .SYNOPSIS
        Imports manually downloaded campaign report CSVs from a local directory.
    .DESCRIPTION
        Scans CsvDirectoryPath for files matching two patterns:
          *Status*Report*.csv   -> loaded as the campaign status report
          *Sign*Off*.csv        -> loaded as the sign-off report
        Both patterns are case-insensitive.  Files are parsed with Import-Csv.
        At least one matching file must be found for Success=$true.

        Useful when Get-SPAuditCampaignReport is blocked by legacy API restrictions
        and the CSV was downloaded manually from the SailPoint ISC UI.
    .PARAMETER CsvDirectoryPath
        Directory that contains the manually downloaded CSV file(s). Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                StatusReport = [object[]] or $null
                SignOffReport = [object[]] or $null
            }
            Error = $string
        }
    .EXAMPLE
        $result = Import-SPAuditCampaignReport -CsvDirectoryPath 'C:\Downloads\Reports'
        if ($result.Success) {
            $status  = $result.Data.StatusReport
            $signOff = $result.Data.SignOffReport
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvDirectoryPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Importing campaign report CSVs from '$CsvDirectoryPath'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
        -CorrelationID $CorrelationID

    try {
        if (-not (Test-Path -Path $CsvDirectoryPath -PathType Container)) {
            $errMsg = "CSV directory not found: '$CsvDirectoryPath'"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $allCsvFiles = Get-ChildItem -Path $CsvDirectoryPath -Filter '*.csv' -File -ErrorAction Stop

        if ($null -eq $allCsvFiles -or $allCsvFiles.Count -eq 0) {
            $errMsg = "No CSV files found in '$CsvDirectoryPath'"
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $statusReportData  = $null
        $signOffReportData = $null
        $foundAny          = $false

        foreach ($file in $allCsvFiles) {
            $name = $file.Name

            # Status report pattern: *Status*Report*.csv (case-insensitive)
            if ($name -imatch 'Status.*Report' -or $name -imatch 'Report.*Status') {
                Write-SPLog -Message "Loading status report from '$($file.FullName)'" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
                    -CorrelationID $CorrelationID
                $statusReportData = Import-Csv -Path $file.FullName -ErrorAction Stop
                $foundAny = $true
                continue
            }

            # Sign-off report pattern: *Sign*Off*.csv (case-insensitive)
            if ($name -imatch 'Sign.*Off' -or $name -imatch 'Signoff' -or $name -imatch 'SignOff') {
                Write-SPLog -Message "Loading sign-off report from '$($file.FullName)'" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
                    -CorrelationID $CorrelationID
                $signOffReportData = Import-Csv -Path $file.FullName -ErrorAction Stop
                $foundAny = $true
                continue
            }
        }

        if (-not $foundAny) {
            $errMsg = "No matching CSV files found in '$CsvDirectoryPath'. " +
                      "Expected files matching '*Status*Report*.csv' or '*Sign*Off*.csv'."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $statusCount  = if ($null -ne $statusReportData) { @($statusReportData).Count } else { 0 }
        $signOffCount = if ($null -ne $signOffReportData) { @($signOffReportData).Count } else { 0 }

        Write-SPLog -Message "Imported campaign reports: StatusReport=$statusCount rows, SignOffReport=$signOffCount rows" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                StatusReport  = $statusReportData
                SignOffReport = $signOffReportData
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Import-SPAuditCampaignReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditIdentityEvents {
    <#
    .SYNOPSIS
        Retrieves provisioning account-activity events for a specific identity.
    .DESCRIPTION
        GETs /v3/account-activities filtered by requested-for={identityId} and
        auto-paginates.  Client-side date filtering is applied on the 'created'
        field using the DaysBack parameter.

        For each activity, the source name for items within the activity is resolved
        via Get-SPAuditSourceName (which uses an in-module cache).  Each returned
        activity object is annotated with a 'ResolvedSourceNames' property containing
        a hashtable keyed by sourceId with display names as values.

        This function is designed for post-campaign audit use cases: understanding
        what provisioning changes occurred for an identity near a campaign date.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to query events for. Mandatory.
    .PARAMETER DaysBack
        Number of calendar days to look back from now for events. Default: 2.
        Set to 0 to disable date filtering and return all available events.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([activity objects with ResolvedSourceNames]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditIdentityEvents -IdentityId 'id-abc123' -DaysBack 7 -CorrelationID $cid
        foreach ($event in $result.Data) {
            $event.action
            $event.ResolvedSourceNames
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [int]$DaysBack = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting identity events for '$IdentityId' (DaysBack=$DaysBack)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
        -CorrelationID $CorrelationID

    try {
        $allActivities = [System.Collections.Generic.List[object]]::new()
        $pageSize      = 250
        $offset        = 0
        $pageNum       = 0

        do {
            $pageNum++
            $queryParams = @{
                'requested-for' = $IdentityId
                'limit'         = $pageSize.ToString()
                'offset'        = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/account-activities' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditIdentityEvents failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($activity in $page) { $allActivities.Add($activity) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) account activities (running total: $($allActivities.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allActivities.Count) total account activities before date filtering" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
            -CorrelationID $CorrelationID

        # Client-side date filter
        $filteredActivities = [System.Collections.Generic.List[object]]::new()
        if ($DaysBack -gt 0) {
            $cutoff = (Get-Date).AddDays(-$DaysBack)
            foreach ($activity in $allActivities) {
                $createdRaw = $activity.created
                if ($null -eq $createdRaw) {
                    $filteredActivities.Add($activity)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = [datetime]$createdRaw
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate
                    }
                }

                if ($null -eq $createdDate -or $createdDate -ge $cutoff) {
                    $filteredActivities.Add($activity)
                }
            }

            Write-SPLog -Message "Date filter (last $DaysBack days): $($allActivities.Count) -> $($filteredActivities.Count) activities" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
                -CorrelationID $CorrelationID
        }
        else {
            foreach ($activity in $allActivities) { $filteredActivities.Add($activity) }
        }

        # Resolve source names for items within each activity
        foreach ($activity in $filteredActivities) {
            $resolvedNames = @{}

            $activityItems = $null
            if ($null -ne $activity.PSObject.Properties['items'] -and $null -ne $activity.items) {
                $activityItems = $activity.items
            }

            if ($null -ne $activityItems) {
                foreach ($actItem in $activityItems) {
                    # Source ID may be on the item directly or nested under source/sourceRef
                    $sourceId = $null
                    foreach ($prop in @('sourceId', 'source_id')) {
                        if ($null -ne $actItem.PSObject.Properties[$prop]) {
                            $sourceId = $actItem.$prop
                            if (-not [string]::IsNullOrWhiteSpace($sourceId)) { break }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($sourceId) -and
                        $null -ne $actItem.PSObject.Properties['source'] -and
                        $null -ne $actItem.source -and
                        $null -ne $actItem.source.PSObject.Properties['id']) {
                        $sourceId = $actItem.source.id
                    }

                    if (-not [string]::IsNullOrWhiteSpace($sourceId) -and
                        -not $resolvedNames.ContainsKey($sourceId)) {
                        $resolvedNames[$sourceId] = Get-SPAuditSourceName `
                            -SourceId $sourceId -CorrelationID $CorrelationID
                    }
                }
            }

            $activity | Add-Member -MemberType NoteProperty -Name 'ResolvedSourceNames' `
                -Value $resolvedNames -Force
        }

        Write-SPLog -Message "Returning $($filteredActivities.Count) account activities for identity '$IdentityId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $filteredActivities.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditIdentityEvents failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPAuditCampaigns',
    'Get-SPAuditCertifications',
    'Get-SPAuditCertificationItems',
    'Get-SPAuditCampaignReport',
    'Import-SPAuditCampaignReport',
    'Get-SPAuditIdentityEvents'
)
