#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Delta Certification Report Generator
.DESCRIPTION
    Produces lightweight operational reports showing only what changed since
    the last run. NOT a full campaign audit -- this reads account-activity
    events and active campaign state to surface actionable daily deltas.

    Functions:
        Get-SPDeltaReportData    - Gathers delta data (grants, revocations,
                                   campaigns, pending reviews, anomalies)
        Export-SPDeltaReportHtml - Renders a 1-2 page HTML report + JSONL output

    Reuses Get-SPDeltaGrantEvents from SP.DeltaCertQueries for new-grant
    detection. Queries the ISC API directly for revocation events and
    campaign/certification state.

.NOTES
    Module: SP.DeltaCertReport
    Version: 1.0.0
#>

$script:DeltaReportVersion = '1.0.0'

$_spSharedPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'SP.Shared\SP.Shared.psd1'
if ((Test-Path $_spSharedPsd1) -and -not (Get-Command ConvertTo-SPHtmlSafe -ErrorAction Ignore)) {
    Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking
}

#region Internal Helpers

function Get-SPDeltaRevokeEvents {
    <#
    .SYNOPSIS
        Retrieves REVOKE_ACCESS account-activity events within a time window.
    .DESCRIPTION
        Mirrors Get-SPDeltaGrantEvents but filters for type eq "REVOKE_ACCESS".
        Auto-paginates and applies client-side date and source filtering.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SourceIds = @(),

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceFilter = if ($SourceIds.Count -gt 0) { $SourceIds -join ',' } else { '(all)' }
    Write-SPLog -Message "Getting delta revoke events: SourceIds='$sourceFilter', HoursBack=$HoursBack" `
        -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaRevokeEvents' `
        -CorrelationID $CorrelationID

    try {
        $allActivities = [System.Collections.Generic.List[object]]::new()
        $pageSize      = 250
        $offset        = 0
        $pageNum       = 0

        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached: $maxPages pages fetched " +
                          "(accumulated $($allActivities.Count) activities)."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertReport' `
                    -Action 'Get-SPDeltaRevokeEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'filters' = 'type eq "REVOKE_ACCESS"'
                'limit'   = $pageSize.ToString()
                'offset'  = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/account-activities' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPDeltaRevokeEvents failed at page ${pageNum}: $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertReport' `
                    -Action 'Get-SPDeltaRevokeEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and
                $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($activity in $page) { $allActivities.Add($activity) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        # Client-side date and source filtering
        $cutoff    = (Get-Date).ToUniversalTime().AddHours(-$HoursBack)
        $sourceSet = if ($SourceIds.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new($SourceIds)
        } else {
            $null
        }
        $revokeEvents = [System.Collections.Generic.List[object]]::new()

        foreach ($activity in $allActivities) {
            $createdRaw  = $activity.created
            $createdDate = $null
            if ($null -ne $createdRaw) {
                if ($createdRaw -is [datetime]) {
                    $createdDate = [datetime]$createdRaw
                }
                else {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsed)) {
                        $createdDate = $parsed
                    }
                }
            }
            if ($null -ne $createdDate -and $createdDate -lt $cutoff) { continue }

            # Extract identity ID from requestedFor
            $identityId = ''
            if ($null -ne $activity.PSObject.Properties['requestedFor'] -and
                $null -ne $activity.requestedFor) {
                $rf = $activity.requestedFor
                if ($rf -is [System.Collections.IEnumerable] -and $rf -isnot [string]) {
                    $rfArr = @($rf)
                    if ($rfArr.Count -gt 0 -and $null -ne $rfArr[0] -and
                        $null -ne $rfArr[0].PSObject.Properties['id']) {
                        $identityId = [string]$rfArr[0].id
                    }
                }
                elseif ($null -ne $rf.PSObject.Properties['id']) {
                    $identityId = [string]$rf.id
                }
            }
            if ([string]::IsNullOrWhiteSpace($identityId)) { continue }

            # Extract identity display name
            $identityName = ''
            if ($null -ne $activity.PSObject.Properties['requestedFor'] -and
                $null -ne $activity.requestedFor) {
                $rf = $activity.requestedFor
                if ($rf -is [System.Collections.IEnumerable] -and $rf -isnot [string]) {
                    $rfArr = @($rf)
                    if ($rfArr.Count -gt 0 -and $null -ne $rfArr[0]) {
                        foreach ($prop in @('displayName', 'name')) {
                            if ($null -ne $rfArr[0].PSObject.Properties[$prop] -and
                                -not [string]::IsNullOrWhiteSpace($rfArr[0].$prop)) {
                                $identityName = [string]$rfArr[0].$prop
                                break
                            }
                        }
                    }
                }
                else {
                    foreach ($prop in @('displayName', 'name')) {
                        if ($null -ne $rf.PSObject.Properties[$prop] -and
                            -not [string]::IsNullOrWhiteSpace($rf.$prop)) {
                            $identityName = [string]$rf.$prop
                            break
                        }
                    }
                }
            }

            # Examine provisioning items for REMOVE operations
            $activityItems = $null
            if ($null -ne $activity.PSObject.Properties['items'] -and
                $null -ne $activity.items) {
                $activityItems = @($activity.items)
            }
            if ($null -eq $activityItems -or $activityItems.Count -eq 0) { continue }

            foreach ($item in $activityItems) {
                if ($null -eq $item) { continue }

                # Extract source ID
                $itemSourceId = ''
                foreach ($prop in @('sourceId', 'source_id')) {
                    if ($null -ne $item.PSObject.Properties[$prop] -and
                        -not [string]::IsNullOrWhiteSpace($item.$prop)) {
                        $itemSourceId = [string]$item.$prop
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($itemSourceId) -and
                    $null -ne $item.PSObject.Properties['source'] -and
                    $null -ne $item.source -and
                    $null -ne $item.source.PSObject.Properties['id']) {
                    $itemSourceId = [string]$item.source.id
                }

                # Source filter
                if ($null -ne $sourceSet -and -not $sourceSet.Contains($itemSourceId)) {
                    continue
                }

                $itemName  = if ($null -ne $item.PSObject.Properties['name']  -and $null -ne $item.name)  { [string]$item.name  } else { '' }
                $itemValue = if ($null -ne $item.PSObject.Properties['value'] -and $null -ne $item.value) { [string]$item.value } else { '' }
                if ([string]::IsNullOrWhiteSpace($itemName)) { $itemName = $itemValue }

                $revokeEvents.Add([PSCustomObject]@{
                    IdentityId      = $identityId
                    IdentityName    = $identityName
                    SourceId        = $itemSourceId
                    ActivityId      = if ($null -ne $activity.PSObject.Properties['id']) { [string]$activity.id } else { '' }
                    ActivityCreated = if ($null -ne $createdDate) { $createdDate.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
                    ItemName        = $itemName
                    ItemValue       = $itemValue
                })
            }
        }

        Write-SPLog -Message "Found $($revokeEvents.Count) REVOKE event(s) in the last $HoursBack hours" `
            -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaRevokeEvents' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $revokeEvents.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaRevokeEvents failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertReport' `
            -Action 'Get-SPDeltaRevokeEvents' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDeltaRecentCampaigns {
    <#
    .SYNOPSIS
        Finds delta cert campaigns created within the time window.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $searchResult = Search-SPCampaigns -Keyword $CampaignNamePrefix `
            -CorrelationID $CorrelationID

        if (-not $searchResult.Success) {
            Write-SPLog -Message "Campaign search failed: $($searchResult.Error)" `
                -Severity WARN -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaRecentCampaigns' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $cutoff   = (Get-Date).ToUniversalTime().AddHours(-$HoursBack)
        $recent   = [System.Collections.Generic.List[object]]::new()

        foreach ($campaign in @($searchResult.Data)) {
            if ($null -eq $campaign) { continue }

            $createdDate = $null
            if ($null -ne $campaign.PSObject.Properties['created'] -and
                $null -ne $campaign.created) {
                $raw = $campaign.created
                if ($raw -is [datetime]) {
                    $createdDate = [datetime]$raw
                }
                else {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($raw.ToString(), [ref]$parsed)) {
                        $createdDate = $parsed
                    }
                }
            }

            if ($null -ne $createdDate -and $createdDate -lt $cutoff) { continue }

            $status = ''
            if ($null -ne $campaign.PSObject.Properties['status']) {
                $status = [string]$campaign.status
            }

            $recent.Add([PSCustomObject]@{
                CampaignId   = [string]$campaign.id
                CampaignName = if ($null -ne $campaign.PSObject.Properties['name']) { [string]$campaign.name } else { '' }
                Status       = $status
                Created      = if ($null -ne $createdDate) { $createdDate.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
            })
        }

        Write-SPLog -Message "Found $($recent.Count) campaign(s) created in the last $HoursBack hours" `
            -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaRecentCampaigns' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $recent.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaRecentCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertReport' `
            -Action 'Get-SPDeltaRecentCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDeltaPendingReviews {
    <#
    .SYNOPSIS
        Retrieves pending (unsigned) certifications from active delta cert campaigns.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $searchResult = Search-SPCampaigns -Keyword $CampaignNamePrefix `
            -Status @('ACTIVE') -CorrelationID $CorrelationID

        if (-not $searchResult.Success) {
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $activeCampaigns = @($searchResult.Data)
        if ($activeCampaigns.Count -eq 0) {
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $nowUtc   = (Get-Date).ToUniversalTime()
        $pending  = [System.Collections.Generic.List[object]]::new()

        foreach ($campaign in $activeCampaigns) {
            $campaignId   = [string]$campaign.id
            $campaignName = if ($null -ne $campaign.PSObject.Properties['name']) { [string]$campaign.name } else { '' }

            $certResult = Get-SPAuditCertifications -CampaignId $campaignId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) { continue }

            foreach ($cert in @($certResult.Data)) {
                # Skip completed certifications
                $signedValue = $null
                if ($cert.PSObject.Properties.Name -contains 'signed') {
                    $signedValue = $cert.signed
                }
                if ($null -ne $signedValue -and -not [string]::IsNullOrWhiteSpace([string]$signedValue)) {
                    continue
                }

                # Calculate age in hours
                $certCreated = $null
                if ($cert.PSObject.Properties.Name -contains 'created' -and
                    -not [string]::IsNullOrWhiteSpace([string]$cert.created)) {
                    try {
                        if ($cert.created -is [datetime]) {
                            $certCreated = ([datetime]$cert.created).ToUniversalTime()
                        }
                        else {
                            $certCreated = [datetime]::Parse([string]$cert.created).ToUniversalTime()
                        }
                    } catch { }
                }

                $ageHours = 0
                if ($null -ne $certCreated) {
                    $ageHours = [math]::Round(($nowUtc - $certCreated).TotalHours, 1)
                }

                # Reviewer info
                $reviewerName = ''
                if ($cert.PSObject.Properties.Name -contains 'EffectiveReviewer' -and
                    $null -ne $cert.EffectiveReviewer) {
                    foreach ($prop in @('displayName', 'name')) {
                        if ($null -ne $cert.EffectiveReviewer.PSObject.Properties[$prop] -and
                            -not [string]::IsNullOrWhiteSpace($cert.EffectiveReviewer.$prop)) {
                            $reviewerName = [string]$cert.EffectiveReviewer.$prop
                            break
                        }
                    }
                }

                $pending.Add([PSCustomObject]@{
                    CertificationId = [string]$cert.id
                    CampaignName    = $campaignName
                    ReviewerName    = $reviewerName
                    AgeHours        = $ageHours
                    Created         = if ($null -ne $certCreated) { $certCreated.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
                })
            }
        }

        Write-SPLog -Message "Found $($pending.Count) pending review(s) across $($activeCampaigns.Count) active campaign(s)" `
            -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaPendingReviews' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $pending.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaPendingReviews failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertReport' `
            -Action 'Get-SPDeltaPendingReviews' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region Public Functions

function Get-SPDeltaReportData {
    <#
    .SYNOPSIS
        Gathers delta certification data for the specified time window.
    .DESCRIPTION
        Queries ISC for account-activity events (grants and revocations),
        recently created delta cert campaigns, and pending certifications
        to produce a structured report dataset. Returns only changes within
        the time window -- not full campaign history.

        Data sources:
          - GET /v3/account-activities (GRANT_ACCESS) via Get-SPDeltaGrantEvents
          - GET /v3/account-activities (REVOKE_ACCESS) via internal helper
          - GET /v3/campaigns (delta cert prefix search)
          - GET /v3/certifications (pending items on active campaigns)

    .PARAMETER SourceIds
        Array of SailPoint ISC source IDs to monitor. If empty, all sources.
    .PARAMETER HoursBack
        Hours to look back for changes. Default: 24.
    .PARAMETER CampaignNamePrefix
        Prefix for delta cert campaign names. Default: 'AD Delta Cert'.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                NewGrants        = @([PSCustomObject])
                Revocations      = @([PSCustomObject])
                CampaignsCreated = @([PSCustomObject])
                PendingReviews   = @([PSCustomObject])
                Anomalies        = @([PSCustomObject])
                GeneratedAt      = [string]
                HoursBack        = [int]
                SourceIds        = [string[]]
            }
            Error   = $string
        }
    .EXAMPLE
        $result = Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24
        $result.Data.NewGrants.Count
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SourceIds = @(),

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceFilter = if ($SourceIds.Count -gt 0) { $SourceIds -join ',' } else { '(all)' }
    Write-SPLog -Message "Get-SPDeltaReportData: SourceIds='$sourceFilter', HoursBack=$HoursBack" `
        -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaReportData' `
        -CorrelationID $CorrelationID

    try {
        $generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'

        # 1. New grants (reuses existing function)
        $grantResult = Get-SPDeltaGrantEvents -SourceIds $SourceIds -HoursBack $HoursBack `
            -CorrelationID $CorrelationID
        $newGrants = @()
        if ($grantResult.Success -and $null -ne $grantResult.Data) {
            $newGrants = @($grantResult.Data)
        }

        # Resolve display names for grant events
        $grantsWithNames = [System.Collections.Generic.List[object]]::new()
        foreach ($grant in $newGrants) {
            $identityName = ''
            $detail = Get-SPDeltaIdentityDetail -IdentityId $grant.IdentityId `
                -CorrelationID $CorrelationID
            if ($detail.Found) {
                $identityName = $detail.DisplayName
            }
            $grantsWithNames.Add([PSCustomObject]@{
                IdentityId      = $grant.IdentityId
                IdentityName    = $identityName
                SourceId        = $grant.SourceId
                Entitlement     = $grant.ItemName
                Date            = $grant.ActivityCreated
            })
        }

        # 2. Revocations
        $revokeResult = Get-SPDeltaRevokeEvents -SourceIds $SourceIds -HoursBack $HoursBack `
            -CorrelationID $CorrelationID
        $revocations = @()
        if ($revokeResult.Success -and $null -ne $revokeResult.Data) {
            $revocations = @($revokeResult.Data)
        }

        # 3. Campaigns created in the time window
        $campaignResult = Get-SPDeltaRecentCampaigns -CampaignNamePrefix $CampaignNamePrefix `
            -HoursBack $HoursBack -CorrelationID $CorrelationID
        $campaignsCreated = @()
        if ($campaignResult.Success -and $null -ne $campaignResult.Data) {
            $campaignsCreated = @($campaignResult.Data)
        }

        # 4. Pending reviews on active campaigns
        $pendingResult = Get-SPDeltaPendingReviews -CampaignNamePrefix $CampaignNamePrefix `
            -CorrelationID $CorrelationID
        $pendingReviews = @()
        if ($pendingResult.Success -and $null -ne $pendingResult.Data) {
            $pendingReviews = @($pendingResult.Data)
        }

        # 5. Anomalies: past-due reviews (>48h), inactive reviewers
        $anomalies = [System.Collections.Generic.List[object]]::new()
        foreach ($review in $pendingReviews) {
            if ($review.AgeHours -gt 48) {
                $anomalies.Add([PSCustomObject]@{
                    Type        = 'PastDue'
                    Description = "Certification pending for $($review.AgeHours) hours"
                    Reviewer    = $review.ReviewerName
                    Campaign    = $review.CampaignName
                    AgeHours    = $review.AgeHours
                })
            }
        }

        $reportData = @{
            NewGrants        = @($grantsWithNames.ToArray())
            Revocations      = $revocations
            CampaignsCreated = $campaignsCreated
            PendingReviews   = $pendingReviews
            Anomalies        = @($anomalies.ToArray())
            GeneratedAt      = $generatedAt
            HoursBack        = $HoursBack
            SourceIds        = $SourceIds
        }

        $totalChanges = $grantsWithNames.Count + $revocations.Count
        Write-SPLog -Message "Delta report data complete: $($grantsWithNames.Count) grants, $($revocations.Count) revocations, $($campaignsCreated.Count) campaigns, $($pendingReviews.Count) pending, $($anomalies.Count) anomalies" `
            -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Get-SPDeltaReportData' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $reportData; Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaReportData failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertReport' `
            -Action 'Get-SPDeltaReportData' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDeltaReportHtml {
    <#
    .SYNOPSIS
        Generates a lightweight HTML delta report and JSONL output.
    .DESCRIPTION
        Renders the structured data from Get-SPDeltaReportData into a compact
        1-2 page HTML report with five sections:
          1. New Access Grants
          2. Campaigns Created
          3. Revocations
          4. Pending Reviews
          5. Anomalies

        Also writes a JSONL file containing each data element as a structured
        event for SIEM ingestion.

        All CSS is inline (Word-compatible). Colors:
          green  = #339933 (completed actions)
          orange = #FF8800 (pending items)
          red    = #CC3333 (overdue/anomalies)
          blue   = #336699 (headers)

    .PARAMETER ReportData
        Structured data hashtable from Get-SPDeltaReportData.
    .PARAMETER OutputPath
        Directory for output files. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID embedded in report metadata.
    .OUTPUTS
        [hashtable] @{
            HtmlPath  = [string]
            JsonlPath = [string]
        }
    .EXAMPLE
        $data = (Get-SPDeltaReportData -SourceIds @('src-ad-001') -HoursBack 24).Data
        $paths = Export-SPDeltaReportHtml -ReportData $data -OutputPath 'DeltaCert/reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ReportData,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $dateStamp    = (Get-Date).ToString('yyyy-MM-dd')
    $generatedAt  = $ReportData.GeneratedAt
    $hoursBack    = $ReportData.HoursBack
    $sourceLabel  = if ($ReportData.SourceIds.Count -gt 0) { $ReportData.SourceIds -join ', ' } else { 'All Sources' }

    $newGrants        = @($ReportData.NewGrants)
    $revocations      = @($ReportData.Revocations)
    $campaignsCreated = @($ReportData.CampaignsCreated)
    $pendingReviews   = @($ReportData.PendingReviews)
    $anomalies        = @($ReportData.Anomalies)

    $totalChanges = $newGrants.Count + $revocations.Count

    # --- Build HTML ---
    $html = [System.Text.StringBuilder]::new()

    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="en">')
    [void]$html.AppendLine('<head>')
    [void]$html.AppendLine('    <meta charset="UTF-8">')
    [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
    [void]$html.AppendLine("    <title>Delta Report - $(ConvertTo-SPHtmlSafe $dateStamp)</title>")
    [void]$html.AppendLine('</head>')
    [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
    [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

    # Header
    [void]$html.AppendLine("<h1 style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; font-size:22px; margin-bottom:4px;"">Delta Certification Report</h1>")
    [void]$html.AppendLine("<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:12px; margin-bottom:16px;"">As of $(ConvertTo-SPHtmlSafe $generatedAt) | Last $hoursBack hours | Sources: $(ConvertTo-SPHtmlSafe $sourceLabel)</p>")

    # Summary cards
    [void]$html.AppendLine('<table style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px; margin-bottom:24px;">')
    [void]$html.AppendLine('    <thead>')
    [void]$html.AppendLine('        <tr>')
    [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:8px 16px; text-align:left;">Metric</th>')
    [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:8px 16px; text-align:right;">Count</th>')
    [void]$html.AppendLine('        </tr>')
    [void]$html.AppendLine('    </thead>')
    [void]$html.AppendLine('    <tbody>')
    [void]$html.AppendLine("        <tr><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0;"">New Access Grants</td><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0; text-align:right; font-weight:bold; color:#336699;"">$($newGrants.Count)</td></tr>")
    [void]$html.AppendLine("        <tr style=""background:#f9f9f9;""><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0;"">Revocations</td><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0; text-align:right; font-weight:bold; color:#339933;"">$($revocations.Count)</td></tr>")
    [void]$html.AppendLine("        <tr><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0;"">Campaigns Created</td><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0; text-align:right; font-weight:bold;"">$($campaignsCreated.Count)</td></tr>")

    $pendingColor = if ($pendingReviews.Count -gt 0) { '#FF8800' } else { '#339933' }
    [void]$html.AppendLine("        <tr style=""background:#f9f9f9;""><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0;"">Pending Reviews</td><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0; text-align:right; font-weight:bold; color:${pendingColor};"">$($pendingReviews.Count)</td></tr>")

    $anomalyColor = if ($anomalies.Count -gt 0) { '#CC3333' } else { '#339933' }
    [void]$html.AppendLine("        <tr><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0;"">Anomalies</td><td style=""padding:7px 16px; border-bottom:1px solid #e0e0e0; text-align:right; font-weight:bold; color:${anomalyColor};"">$($anomalies.Count)</td></tr>")
    [void]$html.AppendLine('    </tbody>')
    [void]$html.AppendLine('</table>')

    # --- Section 1: New Access Grants ---
    [void]$html.AppendLine("<h2 style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; font-size:16px; margin-top:24px;"">1. New Access Grants</h2>")

    if ($newGrants.Count -eq 0) {
        [void]$html.AppendLine("<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:13px; font-style:italic;"">No new access grants in the last $hoursBack hours.</p>")
    }
    else {
        [void]$html.AppendLine('<table style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:12px; margin-bottom:16px;">')
        [void]$html.AppendLine('    <thead>')
        [void]$html.AppendLine('        <tr>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Identity</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Source</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Entitlement</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Date</th>')
        [void]$html.AppendLine('        </tr>')
        [void]$html.AppendLine('    </thead>')
        [void]$html.AppendLine('    <tbody>')

        $rowIdx = 0
        foreach ($grant in $newGrants) {
            $bgStyle = if ($rowIdx % 2 -eq 1) { ' background:#f9f9f9;' } else { '' }
            $nameDisplay = if (-not [string]::IsNullOrWhiteSpace($grant.IdentityName)) {
                (ConvertTo-SPHtmlSafe $grant.IdentityName)
            } else {
                (ConvertTo-SPHtmlSafe $grant.IdentityId)
            }
            [void]$html.AppendLine("        <tr style=""$bgStyle""><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$nameDisplay</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $grant.SourceId)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $grant.Entitlement)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $grant.Date)</td></tr>")
            $rowIdx++
        }

        [void]$html.AppendLine('    </tbody>')
        [void]$html.AppendLine('</table>')
    }

    # --- Section 2: Campaigns Created ---
    [void]$html.AppendLine("<h2 style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; font-size:16px; margin-top:24px;"">2. Campaigns Created</h2>")

    if ($campaignsCreated.Count -eq 0) {
        [void]$html.AppendLine("<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:13px; font-style:italic;"">No campaigns created in the last $hoursBack hours.</p>")
    }
    else {
        [void]$html.AppendLine('<table style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:12px; margin-bottom:16px;">')
        [void]$html.AppendLine('    <thead>')
        [void]$html.AppendLine('        <tr>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Campaign Name</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Status</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Created</th>')
        [void]$html.AppendLine('        </tr>')
        [void]$html.AppendLine('    </thead>')
        [void]$html.AppendLine('    <tbody>')

        $rowIdx = 0
        foreach ($camp in $campaignsCreated) {
            $bgStyle = if ($rowIdx % 2 -eq 1) { ' background:#f9f9f9;' } else { '' }

            $statusColor = switch ($camp.Status) {
                'COMPLETED'  { '#339933' }
                'ACTIVE'     { '#336699' }
                'STAGED'     { '#FF8800' }
                'ACTIVATING' { '#FF8800' }
                default      { '#333333' }
            }

            [void]$html.AppendLine("        <tr style=""$bgStyle""><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $camp.CampaignName)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0; color:${statusColor}; font-weight:bold;"">$(ConvertTo-SPHtmlSafe $camp.Status)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $camp.Created)</td></tr>")
            $rowIdx++
        }

        [void]$html.AppendLine('    </tbody>')
        [void]$html.AppendLine('</table>')
    }

    # --- Section 3: Revocations ---
    [void]$html.AppendLine("<h2 style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #339933; padding-bottom:6px; font-size:16px; margin-top:24px;"">3. Revocations</h2>")

    if ($revocations.Count -eq 0) {
        [void]$html.AppendLine("<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:13px; font-style:italic;"">No revocations in the last $hoursBack hours.</p>")
    }
    else {
        [void]$html.AppendLine('<table style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:12px; margin-bottom:16px;">')
        [void]$html.AppendLine('    <thead>')
        [void]$html.AppendLine('        <tr>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Identity</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Access Revoked</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Date</th>')
        [void]$html.AppendLine('        </tr>')
        [void]$html.AppendLine('    </thead>')
        [void]$html.AppendLine('    <tbody>')

        $rowIdx = 0
        foreach ($rev in $revocations) {
            $bgStyle = if ($rowIdx % 2 -eq 1) { ' background:#f9f9f9;' } else { '' }
            $nameDisplay = if (-not [string]::IsNullOrWhiteSpace($rev.IdentityName)) {
                (ConvertTo-SPHtmlSafe $rev.IdentityName)
            } else {
                (ConvertTo-SPHtmlSafe $rev.IdentityId)
            }
            [void]$html.AppendLine("        <tr style=""$bgStyle""><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$nameDisplay</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0; color:#CC3333;"">$(ConvertTo-SPHtmlSafe $rev.ItemName)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $rev.ActivityCreated)</td></tr>")
            $rowIdx++
        }

        [void]$html.AppendLine('    </tbody>')
        [void]$html.AppendLine('</table>')
    }

    # --- Section 4: Pending Reviews ---
    [void]$html.AppendLine("<h2 style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #FF8800; padding-bottom:6px; font-size:16px; margin-top:24px;"">4. Pending Reviews</h2>")

    if ($pendingReviews.Count -eq 0) {
        [void]$html.AppendLine("<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#339933; font-size:13px; font-style:italic;"">No pending reviews. All certifications are complete.</p>")
    }
    else {
        [void]$html.AppendLine('<table style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:12px; margin-bottom:16px;">')
        [void]$html.AppendLine('    <thead>')
        [void]$html.AppendLine('        <tr>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Campaign</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:left;">Reviewer</th>')
        [void]$html.AppendLine('            <th style="background:#34495e; color:#fff; padding:6px 10px; text-align:right;">Age (hours)</th>')
        [void]$html.AppendLine('        </tr>')
        [void]$html.AppendLine('    </thead>')
        [void]$html.AppendLine('    <tbody>')

        $rowIdx = 0
        foreach ($review in $pendingReviews) {
            $bgStyle = if ($rowIdx % 2 -eq 1) { ' background:#f9f9f9;' } else { '' }

            $ageColor = if ($review.AgeHours -gt 48) { '#CC3333' }
                        elseif ($review.AgeHours -gt 24) { '#FF8800' }
                        else { '#333333' }

            [void]$html.AppendLine("        <tr style=""$bgStyle""><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $review.CampaignName)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $review.ReviewerName)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0; text-align:right; color:${ageColor}; font-weight:bold;"">$($review.AgeHours)</td></tr>")
            $rowIdx++
        }

        [void]$html.AppendLine('    </tbody>')
        [void]$html.AppendLine('</table>')
    }

    # --- Section 5: Anomalies ---
    [void]$html.AppendLine("<h2 style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #CC3333; padding-bottom:6px; font-size:16px; margin-top:24px;"">5. Anomalies</h2>")

    if ($anomalies.Count -eq 0) {
        [void]$html.AppendLine("<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#339933; font-size:13px; font-style:italic;"">No anomalies detected.</p>")
    }
    else {
        [void]$html.AppendLine('<table style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:12px; margin-bottom:16px;">')
        [void]$html.AppendLine('    <thead>')
        [void]$html.AppendLine('        <tr>')
        [void]$html.AppendLine('            <th style="background:#CC3333; color:#fff; padding:6px 10px; text-align:left;">Type</th>')
        [void]$html.AppendLine('            <th style="background:#CC3333; color:#fff; padding:6px 10px; text-align:left;">Description</th>')
        [void]$html.AppendLine('            <th style="background:#CC3333; color:#fff; padding:6px 10px; text-align:left;">Reviewer</th>')
        [void]$html.AppendLine('            <th style="background:#CC3333; color:#fff; padding:6px 10px; text-align:left;">Campaign</th>')
        [void]$html.AppendLine('        </tr>')
        [void]$html.AppendLine('    </thead>')
        [void]$html.AppendLine('    <tbody>')

        $rowIdx = 0
        foreach ($anomaly in $anomalies) {
            $bgStyle = if ($rowIdx % 2 -eq 1) { ' background:#f9f9f9;' } else { '' }
            [void]$html.AppendLine("        <tr style=""$bgStyle""><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0; color:#CC3333; font-weight:bold;"">$(ConvertTo-SPHtmlSafe $anomaly.Type)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $anomaly.Description)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $anomaly.Reviewer)</td><td style=""padding:5px 10px; border-bottom:1px solid #e0e0e0;"">$(ConvertTo-SPHtmlSafe $anomaly.Campaign)</td></tr>")
            $rowIdx++
        }

        [void]$html.AppendLine('    </tbody>')
        [void]$html.AppendLine('</table>')
    }

    # Footer
    [void]$html.AppendLine("<div style=""margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; text-align:center;"">")
    [void]$html.AppendLine("    SailPoint ISC Governance Toolkit - Delta Report v$script:DeltaReportVersion | Generated: $(ConvertTo-SPHtmlSafe $generatedAt) | Correlation ID: $(ConvertTo-SPHtmlSafe $CorrelationID)")
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('</div>')
    [void]$html.AppendLine('</body>')
    [void]$html.AppendLine('</html>')

    # Write HTML file
    $htmlFileName = "delta-${dateStamp}.html"
    $htmlFilePath = Join-Path -Path $OutputPath -ChildPath $htmlFileName
    $html.ToString() | Set-Content -Path $htmlFilePath -Encoding UTF8

    Write-SPLog -Message "Delta report HTML written: $htmlFilePath" `
        -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Export-SPDeltaReportHtml' `
        -CorrelationID $CorrelationID

    # Write JSONL file
    $jsonlFileName = "delta-${dateStamp}.jsonl"
    $jsonlFilePath = Join-Path -Path $OutputPath -ChildPath $jsonlFileName
    $utf8NoBom     = New-Object System.Text.UTF8Encoding($false)

    $jsonlEvents = [System.Collections.Generic.List[object]]::new()

    # Header event
    $jsonlEvents.Add([ordered]@{
        Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'DeltaReportGenerated'
        CorrelationID = $CorrelationID
        Data          = [ordered]@{
            HoursBack   = $hoursBack
            SourceIds   = $ReportData.SourceIds
            GeneratedAt = $generatedAt
            Summary     = [ordered]@{
                NewGrants        = $newGrants.Count
                Revocations      = $revocations.Count
                CampaignsCreated = $campaignsCreated.Count
                PendingReviews   = $pendingReviews.Count
                Anomalies        = $anomalies.Count
            }
        }
    })

    foreach ($grant in $newGrants) {
        $jsonlEvents.Add([ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'DeltaNewGrant'
            CorrelationID = $CorrelationID
            Data          = [ordered]@{
                IdentityId  = $grant.IdentityId
                IdentityName = $grant.IdentityName
                SourceId    = $grant.SourceId
                Entitlement = $grant.Entitlement
                Date        = $grant.Date
            }
        })
    }

    foreach ($rev in $revocations) {
        $jsonlEvents.Add([ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'DeltaRevocation'
            CorrelationID = $CorrelationID
            Data          = [ordered]@{
                IdentityId   = $rev.IdentityId
                IdentityName = $rev.IdentityName
                ItemName     = $rev.ItemName
                Date         = $rev.ActivityCreated
            }
        })
    }

    foreach ($camp in $campaignsCreated) {
        $jsonlEvents.Add([ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'DeltaCampaignCreated'
            CorrelationID = $CorrelationID
            Data          = [ordered]@{
                CampaignId   = $camp.CampaignId
                CampaignName = $camp.CampaignName
                Status       = $camp.Status
                Created      = $camp.Created
            }
        })
    }

    foreach ($review in $pendingReviews) {
        $jsonlEvents.Add([ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'DeltaPendingReview'
            CorrelationID = $CorrelationID
            Data          = [ordered]@{
                CertificationId = $review.CertificationId
                CampaignName    = $review.CampaignName
                ReviewerName    = $review.ReviewerName
                AgeHours        = $review.AgeHours
            }
        })
    }

    foreach ($anomaly in $anomalies) {
        $jsonlEvents.Add([ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'DeltaAnomaly'
            CorrelationID = $CorrelationID
            Data          = [ordered]@{
                Type        = $anomaly.Type
                Description = $anomaly.Description
                Reviewer    = $anomaly.Reviewer
                Campaign    = $anomaly.Campaign
            }
        })
    }

    foreach ($evt in $jsonlEvents) {
        $jsonLine = $evt | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::AppendAllText($jsonlFilePath, "$jsonLine`n", $utf8NoBom)
    }

    Write-SPLog -Message "Delta report JSONL written ($($jsonlEvents.Count) events): $jsonlFilePath" `
        -Severity INFO -Component 'SP.DeltaCertReport' -Action 'Export-SPDeltaReportHtml' `
        -CorrelationID $CorrelationID

    return @{
        HtmlPath  = $htmlFilePath
        JsonlPath = $jsonlFilePath
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPDeltaReportData',
    'Export-SPDeltaReportHtml'
)
