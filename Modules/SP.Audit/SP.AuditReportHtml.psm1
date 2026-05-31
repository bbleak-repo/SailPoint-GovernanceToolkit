#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Audit Report HTML and Export Generation
.DESCRIPTION
    Provides HTML, plain-text, JSONL, and CSV export functions for campaign audit data.
    Consumes structured output from SP.AuditReportCore and SP.AuditAnalytics. HTML output
    uses inline CSS only and table-based layout for Word copy-paste compatibility.
    No flexbox, no grid, no external stylesheets.
.NOTES
    Module: SP.Audit / SP.AuditReportHtml
    Version: 1.0.0
    Component: Audit Report Generation

    Color taxonomy:
        Green  #339933 - Approved / success
        Red    #CC3333 - Revoked / error
        Orange #FF8800 - Pending / warn
        Blue   #336699 - Info / neutral
        Gray   #777777 - N/A / footer
#>

$script:AuditReportVersion = '1.0.0'

#region HTML Rendering Helpers

function ConvertTo-SafeHtml {
    <#
    .SYNOPSIS
        HTML-encodes a value for safe embedding in markup.
    .DESCRIPTION
        Converts the input to a string and applies HtmlEncode. Returns an
        empty string for null or empty input rather than throwing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) { return '' }
    $str = [string]$Value
    if ([string]::IsNullOrWhiteSpace($str)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($str)
}


function Format-HtmlDate {
    <#
    .SYNOPSIS
        Formats an ISO 8601 date string to a readable date for HTML output.
    .DESCRIPTION
        Attempts to parse and reformat. Returns the raw string on parse failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$DateString
    )

    if ([string]::IsNullOrWhiteSpace($DateString)) { return '' }
    try {
        $dt = [datetime]::Parse($DateString)
        return $dt.ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        return $DateString
    }
}


function Build-HtmlTableRow {
    <#
    .SYNOPSIS
        Builds a single HTML <tr> with alternating background and inline styles.
    .PARAMETER Cells
        Array of cell value strings (already HTML-encoded).
    .PARAMETER IsAlternate
        When true applies a light gray background to the row.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Cells,

        [Parameter()]
        [bool]$IsAlternate = $false
    )

    $rowStyle = if ($IsAlternate) { ' style="background:#f9f9f9;"' } else { '' }
    $tdPadding = 'style="padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;"'

    $tds = ($Cells | ForEach-Object { "<td $tdPadding>$_</td>" }) -join ''
    return "<tr$rowStyle>$tds</tr>"
}


function Build-HtmlTableHeader {
    <#
    .SYNOPSIS
        Builds a styled HTML <thead><tr> row for audit tables.
    .PARAMETER Headers
        Array of header label strings (plain text, not encoded).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Headers
    )

    $thStyle = 'style="background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px;"'
    $ths = ($Headers | ForEach-Object { "<th $thStyle>$_</th>" }) -join ''
    return "<thead><tr>$ths</tr></thead>"
}


function Format-HoursDisplay {
    <#
    .SYNOPSIS
        Converts a decimal hours value to a human-readable string.
    .DESCRIPTION
        Under 1 hour    -> "X min"
        1-24 hours      -> "X.X hours"
        Over 24 hours   -> "X days, Y hours"
        Null input      -> "N/A"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Hours
    )

    if ($null -eq $Hours) { return 'N/A' }

    $h = [double]$Hours

    if ($h -lt 1) {
        $minutes = [int][Math]::Round($h * 60)
        return "$minutes min"
    }
    elseif ($h -le 24) {
        return "$([Math]::Round($h, 1)) hours"
    }
    else {
        $days  = [int][Math]::Floor($h / 24)
        $rem   = [int][Math]::Round($h % 24)
        return "$days days, $rem hours"
    }
}


function Format-RiskFlagBadges {
    <#
    .SYNOPSIS
        Renders risk flag badges as inline-styled HTML span elements.
    .DESCRIPTION
        Takes an array of risk flag strings and returns an HTML fragment with
        colored badge spans. Returns empty string if no flags.
        Colors: STALE=orange, PRIVILEGED=red, ORPHAN=red, TERMINATED=red, SVC-ACCOUNT=gray.
    .PARAMETER Flags
        Array of risk flag strings (e.g., 'TERMINATED', 'PRIVILEGED').
    .OUTPUTS
        [string] HTML badge markup or empty string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Flags
    )

    if ($null -eq $Flags -or $Flags.Count -eq 0) { return '' }

    $badgeStyle = "display:inline-block; padding:2px 6px; margin:0 3px 2px 0; border-radius:3px; font-size:10px; font-weight:bold; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; line-height:14px; vertical-align:middle;"

    $badges = foreach ($flag in $Flags) {
        $color = switch ($flag) {
            'STALE'       { 'color:#fff; background:#FF8800;' }
            'PRIVILEGED'  { 'color:#fff; background:#CC3333;' }
            'ORPHAN'      { 'color:#fff; background:#CC3333;' }
            'TERMINATED'  { 'color:#fff; background:#CC3333;' }
            'SVC-ACCOUNT' { 'color:#fff; background:#999999;' }
            default       { 'color:#fff; background:#777777;' }
        }
        "<span style=""$badgeStyle $color"">$([System.Net.WebUtility]::HtmlEncode($flag))</span>"
    }

    return ' ' + ($badges -join '')
}


#endregion HTML Rendering Helpers

#region Campaign HTML Builder

function Build-ExecutiveSummaryHtml {
    <#
    .SYNOPSIS
        Generates the Executive Summary dashboard HTML block for a campaign audit.
    .DESCRIPTION
        Produces the visual dashboard that appears before Section 1 in the report.
        Includes: status badge, campaign timeline, decision distribution donut chart,
        remediation completion bar, risk scorecard, and reviewer response time bars.
        All visuals use inline SVG and table-based layout for Word copy-paste compatibility.
        Gracefully handles missing ReviewerMetrics and RemediationProof.
    .PARAMETER CampaignAudit
        Hashtable with campaign audit data (same format as Build-SingleCampaignHtml).
    .OUTPUTS
        [string] HTML block for the executive summary dashboard.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CampaignAudit
    )

    # --- Extract core fields ---
    $status    = if ($CampaignAudit.ContainsKey('Status')    -and $null -ne $CampaignAudit['Status'])    { [string]$CampaignAudit['Status']    } else { '' }
    $createdRaw   = if ($CampaignAudit.ContainsKey('Created')   -and $null -ne $CampaignAudit['Created'])   { [string]$CampaignAudit['Created']   } else { '' }
    $completedRaw = if ($CampaignAudit.ContainsKey('Completed') -and $null -ne $CampaignAudit['Completed']) { [string]$CampaignAudit['Completed'] } else { '' }
    $deadlineRaw  = if ($CampaignAudit.ContainsKey('Deadline')  -and $null -ne $CampaignAudit['Deadline'])  { [string]$CampaignAudit['Deadline']  }
                    elseif ($CampaignAudit.ContainsKey('deadline') -and $null -ne $CampaignAudit['deadline']) { [string]$CampaignAudit['deadline'] }
                    else { '' }

    $decisions        = if ($CampaignAudit.ContainsKey('Decisions')        -and $null -ne $CampaignAudit['Decisions'])        { $CampaignAudit['Decisions']        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }
    $reviewers        = if ($CampaignAudit.ContainsKey('Reviewers')        -and $null -ne $CampaignAudit['Reviewers'])        { $CampaignAudit['Reviewers']        } else { @{ Primary = @(); Reassigned = @() } }
    $reviewerMetrics  = if ($CampaignAudit.ContainsKey('ReviewerMetrics')  -and $null -ne $CampaignAudit['ReviewerMetrics'])  { $CampaignAudit['ReviewerMetrics']  } else { $null }
    $remediationProof = if ($CampaignAudit.ContainsKey('RemediationProof') -and $null -ne $CampaignAudit['RemediationProof']) { $CampaignAudit['RemediationProof'] } else { $null }

    # --- Decision counts ---
    $approvedCount = if ($null -ne $decisions['Approved']) { @($decisions['Approved']).Count } else { 0 }
    $revokedCount  = if ($null -ne $decisions['Revoked'])  { @($decisions['Revoked']).Count  } else { 0 }
    $pendingCount  = if ($null -ne $decisions['Pending'])  { @($decisions['Pending']).Count  } else { 0 }
    $totalItems    = $approvedCount + $revokedCount + $pendingCount

    # --- Reviewer sign-off counts ---
    $primaryList    = if ($null -ne $reviewers['Primary'])    { @($reviewers['Primary'])    } else { @() }
    $reassignedList = if ($null -ne $reviewers['Reassigned']) { @($reviewers['Reassigned']) } else { @() }
    $allReviewers   = @($primaryList) + @($reassignedList)
    $totalReviewers = $allReviewers.Count
    $signedCount    = @($allReviewers | Where-Object { $null -ne $_ -and $_.Phase -eq 'SIGNED' }).Count

    # --- Status badge color ---
    $statusColor = switch ($status.ToUpperInvariant()) {
        'COMPLETED' { '#339933' }
        'ACTIVE'    { '#336699' }
        'STAGED'    { '#FF8800' }
        default     { '#777777' }
    }

    # --- Campaign duration calculation ---
    $durationDisplay = ''
    $dtCreated   = $null
    $dtCompleted = $null
    if (-not [string]::IsNullOrWhiteSpace($createdRaw)) {
        try {
            $dtCreated = [datetime]::Parse($createdRaw, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { $dtCreated = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($completedRaw)) {
        try {
            $dtCompleted = [datetime]::Parse($completedRaw, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { $dtCompleted = $null }
    }
    if ($null -ne $dtCreated -and $null -ne $dtCompleted) {
        $durationHours = ($dtCompleted - $dtCreated).TotalHours
        if ($durationHours -lt 0) { $durationHours = 0 }
        $durationDisplay = Format-HoursDisplay $durationHours
    }

    # --- Early/late calculation (requires deadline) ---
    $earlyLateHtml = ''
    if (-not [string]::IsNullOrWhiteSpace($deadlineRaw) -and $null -ne $dtCompleted) {
        try {
            $dtDeadline = [datetime]::Parse($deadlineRaw, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
            $diffHours  = ($dtDeadline - $dtCompleted).TotalHours
            if ($diffHours -gt 0) {
                $earlyLateHtml = "<span style=""color:#339933; font-weight:bold;"">$(Format-HoursDisplay $diffHours) early</span>"
            }
            elseif ($diffHours -lt 0) {
                $earlyLateHtml = "<span style=""color:#CC3333; font-weight:bold;"">$(Format-HoursDisplay ([Math]::Abs($diffHours))) late</span>"
            }
            else {
                $earlyLateHtml = "<span style=""color:#336699; font-weight:bold;"">On time</span>"
            }
        }
        catch { $earlyLateHtml = '' }
    }

    # --- Formatted timeline dates ---
    $createdDisplay   = Format-HtmlDate $createdRaw
    $completedDisplay = Format-HtmlDate $completedRaw
    $deadlineDisplay  = Format-HtmlDate $deadlineRaw

    # --- Decision donut SVG calculations ---
    # SVG donut: r=15.9, circumference ~100 units
    # stroke-dashoffset: first segment starts at top (offset=25 rotates -90 deg)
    $approvedPct = if ($totalItems -gt 0) { [Math]::Round($approvedCount / $totalItems * 100, 1) } else { 0 }
    $revokedPct  = if ($totalItems -gt 0) { [Math]::Round($revokedCount  / $totalItems * 100, 1) } else { 0 }
    $pendingPct  = if ($totalItems -gt 0) { [Math]::Round($pendingCount  / $totalItems * 100, 1) } else { 0 }

    # Adjust so they sum to exactly 100 (rounding drift)
    $sumPct = $approvedPct + $revokedPct + $pendingPct
    if ($sumPct -ne 100 -and $totalItems -gt 0) {
        $approvedPct = [Math]::Round(100 - $revokedPct - $pendingPct, 1)
    }

    # Segment 1 (Approved, green): offset=25 (top of circle), dasharray="approvedPct (100-approvedPct)"
    # Segment 2 (Revoked, red):   offset = -(approvedPct - 25)
    # Segment 3 (Pending, orange): offset = -(approvedPct + revokedPct - 25)
    $seg1Offset = 25
    $seg2Offset = -($approvedPct - 25)
    $seg3Offset = -($approvedPct + $revokedPct - 25)

    $seg1Remain = [Math]::Round(100 - $approvedPct, 1)
    $seg2Remain = [Math]::Round(100 - $revokedPct,  1)
    $seg3Remain = [Math]::Round(100 - $pendingPct,  1)

    $donutSvg = @"
    <svg width="140" height="140" viewBox="0 0 42 42" style="display:block; margin:0 auto;">
        <circle cx="21" cy="21" r="15.9" fill="transparent" stroke="#e0e0e0" stroke-width="3.2"></circle>
        <circle cx="21" cy="21" r="15.9" fill="transparent"
                stroke="#339933" stroke-width="3.2"
                stroke-dasharray="$approvedPct $seg1Remain"
                stroke-dashoffset="$seg1Offset"
                stroke-linecap="butt"></circle>
        <circle cx="21" cy="21" r="15.9" fill="transparent"
                stroke="#CC3333" stroke-width="3.2"
                stroke-dasharray="$revokedPct $seg2Remain"
                stroke-dashoffset="$seg2Offset"
                stroke-linecap="butt"></circle>
        <circle cx="21" cy="21" r="15.9" fill="transparent"
                stroke="#FF8800" stroke-width="3.2"
                stroke-dasharray="$pendingPct $seg3Remain"
                stroke-dashoffset="$seg3Offset"
                stroke-linecap="butt"></circle>
        <text x="21" y="19.5" text-anchor="middle" style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:5px; font-weight:bold; fill:#2c3e50;">$totalItems</text>
        <text x="21" y="24" text-anchor="middle" style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:2.8px; fill:#777;">items</text>
    </svg>
"@

    # --- Remediation bar ---
    $remediationHtml = ''
    if ($null -ne $remediationProof) {
        $totalRevoked     = [int]$remediationProof['TotalRevoked']
        $remCompleteCount = [int]$remediationProof['RemediationCompleteCount']
        $remPendingCount  = [int]$remediationProof['RemediationPendingCount']

        $remPct = if ($totalRevoked -gt 0) { [Math]::Round($remCompleteCount / $totalRevoked * 100, 1) } else { 0 }
        $remPendPct = [Math]::Round(100 - $remPct, 1)
        if ($remPendPct -lt 0) { $remPendPct = 0 }

        $remBigColor  = if ($remPct -ge 100) { '#339933' } else { '#FF8800' }
        $remBarColor  = $remBigColor
        $remPendColor = '#FF8800'

        # Progress bar: two cells. If 100% only one cell; if 0% only one cell.
        if ($remPct -ge 100) {
            $remBarHtml = @"
    <table style="width:100%; border-collapse:collapse; height:18px; margin-bottom:6px;">
    <tr>
        <td style="width:100%; background:#339933; height:18px; border-radius:4px;"></td>
    </tr>
    </table>
"@
        }
        elseif ($remPct -le 0) {
            $remBarHtml = @"
    <table style="width:100%; border-collapse:collapse; height:18px; margin-bottom:6px;">
    <tr>
        <td style="width:100%; background:#FF8800; height:18px; border-radius:4px;"></td>
    </tr>
    </table>
"@
        }
        else {
            $remBarHtml = @"
    <table style="width:100%; border-collapse:collapse; height:18px; margin-bottom:6px;">
    <tr>
        <td style="width:$($remPct)%; background:#339933; height:18px; border-radius:4px 0 0 4px;"></td>
        <td style="width:$($remPendPct)%; background:#FF8800; height:18px; border-radius:0 4px 4px 0;"></td>
    </tr>
    </table>
"@
        }

        $remediationHtml = @"
    <p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:12px; color:#555; margin:0 0 8px 0;">Remediation Completion</p>
    <div style="text-align:center; margin-bottom:10px;">
        <span style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:36px; font-weight:bold; color:$remBigColor;">$($remPct)%</span>
        <br/>
        <span style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; color:#777;">$remCompleteCount of $totalRevoked revoked items remediated</span>
    </div>
    $remBarHtml
    <table style="width:100%; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; border-collapse:collapse;">
    <tr>
        <td style="color:#339933; font-weight:bold; padding:2px 0;">$remCompleteCount Complete</td>
        <td style="color:#FF8800; font-weight:bold; text-align:right; padding:2px 0;">$remPendingCount Pending</td>
    </tr>
    </table>
    <div style="margin-top:12px; padding:6px 8px; background:#fff3cd; border-radius:4px; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; color:#856404;">
        Target: 100% remediation for SOX compliance
    </div>
"@
    }
    else {
        $remediationHtml = @"
    <p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:12px; color:#555; margin:0 0 8px 0;">Remediation Completion</p>
    <p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; color:#777777; font-style:italic;">Remediation data not available.</p>
"@
    }

    # --- Risk Scorecard ---
    # Reviewer completion
    $reviewerCompletionPct  = if ($totalReviewers -gt 0) { [Math]::Round($signedCount / $totalReviewers * 100, 0) } else { 0 }
    $reviewerCompletionText = "$($reviewerCompletionPct)%"
    $reviewerCompletionColor = if ($reviewerCompletionPct -ge 100) { '#339933' } else { '#FF8800' }

    # Pending items
    $pendingItemsColor = if ($pendingCount -eq 0) { '#339933' } else { '#FF8800' }

    # Remediation rate
    $remRatePct   = if ($null -ne $remediationProof) {
        $tr = [int]$remediationProof['TotalRevoked']
        if ($tr -gt 0) { [Math]::Round([int]$remediationProof['RemediationCompleteCount'] / $tr * 100, 1) } else { 0 }
    } else { $null }
    $remRateText  = if ($null -ne $remRatePct) { "$($remRatePct)%" } else { 'N/A' }
    $remRateColor = if ($null -eq $remRatePct) { '#777777' } elseif ($remRatePct -ge 100) { '#339933' } else { '#FF8800' }

    # On time
    $onTimeText  = 'N/A'
    $onTimeColor = '#777777'
    if (-not [string]::IsNullOrWhiteSpace($deadlineRaw) -and $null -ne $dtCompleted) {
        try {
            $dtDeadline2 = [datetime]::Parse($deadlineRaw, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
            if ($dtCompleted -le $dtDeadline2) {
                $onTimeText  = 'Yes'
                $onTimeColor = '#339933'
            }
            else {
                $onTimeText  = 'No'
                $onTimeColor = '#CC3333'
            }
        }
        catch { }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($durationDisplay)) {
        $onTimeText  = $durationDisplay
        $onTimeColor = '#336699'
    }

    # Slowest reviewer
    $slowestText  = 'N/A'
    $slowestColor = '#777777'
    if ($null -ne $reviewerMetrics -and $null -ne $reviewerMetrics['CampaignMaxHours']) {
        $maxH = $reviewerMetrics['CampaignMaxHours']
        $slowestText  = Format-HoursDisplay $maxH
        $slowestColor = if ($maxH -le 24) { '#339933' } elseif ($maxH -le 72) { '#336699' } else { '#FF8800' }
    }

    # Reassignment count
    $reassignCount = $reassignedList.Count
    $reassignColor = if ($reassignCount -eq 0) { '#339933' } else { '#336699' }

    $scorecardHtml = @"
    <p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:12px; color:#555; margin:0 0 8px 0;">Risk Indicators</p>
    <table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px;">
    <tr>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; width:20px;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$reviewerCompletionColor"/></svg></td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; color:#555;">Reviewer Completion</td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; font-weight:bold; text-align:right; color:$reviewerCompletionColor;">$reviewerCompletionText</td>
    </tr>
    <tr>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$pendingItemsColor"/></svg></td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; color:#555;">Pending Items</td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; font-weight:bold; text-align:right; color:$pendingItemsColor;">$pendingCount</td>
    </tr>
    <tr>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$remRateColor"/></svg></td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; color:#555;">Remediation Rate</td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; font-weight:bold; text-align:right; color:$remRateColor;">$remRateText</td>
    </tr>
    <tr>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$onTimeColor"/></svg></td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; color:#555;">Completed On Time</td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; font-weight:bold; text-align:right; color:$onTimeColor;">$onTimeText</td>
    </tr>
    <tr>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$slowestColor"/></svg></td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; color:#555;">Slowest Reviewer</td>
        <td style="padding:5px 4px; border-bottom:1px solid #e0e0e0; font-weight:bold; text-align:right; color:$slowestColor;">$slowestText</td>
    </tr>
    <tr>
        <td style="padding:5px 4px;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$reassignColor"/></svg></td>
        <td style="padding:5px 4px; color:#555;">Reassignments</td>
        <td style="padding:5px 4px; font-weight:bold; text-align:right; color:$reassignColor;">$reassignCount</td>
    </tr>
    </table>
"@

    # --- Reviewer response time bars ---
    $responseTimeBarsHtml = ''
    if ($null -ne $reviewerMetrics -and $null -ne $reviewerMetrics['ReviewerMetrics']) {
        $rmRows  = @($reviewerMetrics['ReviewerMetrics'])
        $maxHours = if ($null -ne $reviewerMetrics['CampaignMaxHours'] -and $reviewerMetrics['CampaignMaxHours'] -gt 0) {
            [double]$reviewerMetrics['CampaignMaxHours']
        } else { 1.0 }

        $campAvgDisplay    = Format-HoursDisplay $reviewerMetrics['CampaignAvgHours']
        $campMedianDisplay = Format-HoursDisplay $reviewerMetrics['CampaignMedianHours']

        $barRows = ''
        foreach ($rm in $rmRows) {
            if ($null -eq $rm -or $null -eq $rm.AvgHours) { continue }
            $avgH = [double]$rm.AvgHours
            $barPct  = [Math]::Round($avgH / $maxHours * 100, 1)
            if ($barPct -gt 100) { $barPct = 100 }
            $remPct2 = [Math]::Round(100 - $barPct, 1)
            if ($remPct2 -lt 0) { $remPct2 = 0 }

            $barColor = if ($avgH -le 24) { '#339933' } elseif ($avgH -le 72) { '#336699' } else { '#FF8800' }
            $avgLabel = Format-HoursDisplay $avgH
            $nameHtml = [System.Net.WebUtility]::HtmlEncode($rm.Name)

            if ($barPct -ge 100) {
                $barCellsHtml = "<td style=""width:100%; background:$barColor; height:14px; border-radius:3px;""></td>"
            }
            elseif ($barPct -le 0) {
                $barCellsHtml = "<td style=""width:100%; background:#e8e8e8; height:14px; border-radius:3px;""></td>"
            }
            else {
                $barCellsHtml = "<td style=""width:$($barPct)%; background:$barColor; height:14px; border-radius:3px 0 0 3px;""></td><td style=""width:$($remPct2)%; background:#e8e8e8; height:14px; border-radius:0 3px 3px 0;""></td>"
            }

            $barRows += @"
<tr>
    <td style="padding:4px 8px; width:140px; color:#555;">$nameHtml</td>
    <td style="padding:4px 0;">
        <table style="width:100%; border-collapse:collapse; height:14px;"><tr>$barCellsHtml</tr></table>
    </td>
    <td style="padding:4px 8px; width:90px; text-align:right; color:$barColor; font-weight:bold;">$avgLabel</td>
</tr>
"@
        }

        if (-not [string]::IsNullOrWhiteSpace($barRows)) {
            $responseTimeBarsHtml = @"
<p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:12px; color:#555; margin:16px 0 8px 0;">Reviewer Response Time</p>
<table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; margin-bottom:4px;">
$barRows
</table>
<table style="margin:4px 0 0 148px; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:10px; border-collapse:collapse;">
<tr>
    <td style="padding:1px 4px;"><svg width="10" height="10"><rect width="10" height="10" rx="2" fill="#339933"/></svg></td>
    <td style="padding:1px 4px; color:#777;">Under 24 hours</td>
    <td style="padding:1px 8px;"><svg width="10" height="10"><rect width="10" height="10" rx="2" fill="#336699"/></svg></td>
    <td style="padding:1px 4px; color:#777;">24-72 hours</td>
    <td style="padding:1px 8px;"><svg width="10" height="10"><rect width="10" height="10" rx="2" fill="#FF8800"/></svg></td>
    <td style="padding:1px 4px; color:#777;">Over 72 hours</td>
</tr>
</table>
<p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; color:#777; margin:8px 0 0 0; text-align:right;">Campaign average: $campAvgDisplay &nbsp;|&nbsp; Median: $campMedianDisplay</p>
"@
        }
    }

    # --- Timeline table rows ---
    $timelineRows = ''
    if (-not [string]::IsNullOrWhiteSpace($createdDisplay)) {
        $timelineRows += "<tr><td style=""padding:5px 8px; font-weight:bold; color:#555; width:130px;"">Created</td><td style=""padding:5px 8px; color:#2c3e50;"">$([System.Net.WebUtility]::HtmlEncode($createdDisplay))</td></tr>`n"
    }
    if (-not [string]::IsNullOrWhiteSpace($deadlineDisplay)) {
        $timelineRows += "<tr><td style=""padding:5px 8px; font-weight:bold; color:#555;"">Due Date</td><td style=""padding:5px 8px; color:#2c3e50;"">$([System.Net.WebUtility]::HtmlEncode($deadlineDisplay))</td></tr>`n"
    }
    if (-not [string]::IsNullOrWhiteSpace($completedDisplay)) {
        $timelineRows += "<tr><td style=""padding:5px 8px; font-weight:bold; color:#555;"">Completed</td><td style=""padding:5px 8px; color:#2c3e50;"">$([System.Net.WebUtility]::HtmlEncode($completedDisplay))</td></tr>`n"
    }
    if (-not [string]::IsNullOrWhiteSpace($durationDisplay)) {
        $timelineRows += "<tr><td style=""padding:5px 8px; font-weight:bold; color:#555;"">Duration</td><td style=""padding:5px 8px; color:#2c3e50;"">$([System.Net.WebUtility]::HtmlEncode($durationDisplay))</td></tr>`n"
    }
    if (-not [string]::IsNullOrWhiteSpace($earlyLateHtml)) {
        $timelineRows += "<tr><td style=""padding:5px 8px; font-weight:bold; color:#555;"">Result</td><td style=""padding:5px 8px;"">$earlyLateHtml</td></tr>`n"
    }

    # --- Assemble the full dashboard ---
    $html = @"
<!-- Executive Summary Dashboard -->
<div style="background:#f8f9fa; border:1px solid #dee2e6; border-radius:8px; padding:24px 28px; margin:20px 0 28px 0; page-break-inside:avoid;">

<h3 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin:0 0 16px 0; font-size:18px; border-bottom:2px solid #336699; padding-bottom:6px;">Executive Summary</h3>

<!-- Row 1: Status Badge + Campaign Timeline -->
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="width:50%; vertical-align:top; padding-right:16px;">
    <table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:0;">
    <tr>
        <td style="padding:12px 16px; background:$statusColor; border-radius:6px; text-align:center;" colspan="2">
            <span style="color:#ffffff; font-size:22px; font-weight:bold; letter-spacing:1px;">$([System.Net.WebUtility]::HtmlEncode($status))</span>
        </td>
    </tr>
    <tr>
        <td style="padding:8px 4px; text-align:center; color:#555; font-size:12px;">
            <span style="font-weight:bold; font-size:16px; color:#2c3e50;">$signedCount / $totalReviewers</span><br/>
            Reviewers Signed Off
        </td>
        <td style="padding:8px 4px; text-align:center; color:#555; font-size:12px;">
            <span style="font-weight:bold; font-size:16px; color:#2c3e50;">$($approvedCount + $revokedCount) / $totalItems</span><br/>
            Items Decided
        </td>
    </tr>
    </table>
</td>
<td style="width:50%; vertical-align:top; padding-left:16px;">
    <table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px;">
    $timelineRows
    </table>
</td>
</tr>
</table>

<!-- Row 2: Decision Donut + Remediation Bar + Risk Scorecard -->
<table style="width:100%; border-collapse:collapse; margin-bottom:8px;">
<tr>

<td style="width:33%; vertical-align:top; padding-right:12px; text-align:center;">
    <p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:12px; color:#555; margin:0 0 8px 0;">Decision Distribution</p>
    $donutSvg
    <table style="margin:8px auto 0 auto; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; border-collapse:collapse;">
    <tr>
        <td style="padding:2px 4px;"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#339933"/></svg></td>
        <td style="padding:2px 4px; color:#555;">Approved: $approvedCount ($($approvedPct)%)</td>
    </tr>
    <tr>
        <td style="padding:2px 4px;"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#CC3333"/></svg></td>
        <td style="padding:2px 4px; color:#555;">Revoked: $revokedCount ($($revokedPct)%)</td>
    </tr>
    <tr>
        <td style="padding:2px 4px;"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#FF8800"/></svg></td>
        <td style="padding:2px 4px; color:#555;">Pending: $pendingCount ($($pendingPct)%)</td>
    </tr>
    </table>
</td>

<td style="width:34%; vertical-align:top; padding:0 12px;">
    $remediationHtml
</td>

<td style="width:33%; vertical-align:top; padding-left:12px;">
    $scorecardHtml
</td>

</tr>
</table>

$responseTimeBarsHtml

</div>
<!-- End Executive Summary Dashboard -->

"@

    return $html
}


function Build-SingleCampaignHtml {
    <#
    .SYNOPSIS
        Generates the full HTML body content for one campaign audit.
    .DESCRIPTION
        Returns the inner HTML sections only (no DOCTYPE/html/head/body tags).
        Intended for inclusion in both per-campaign and combined HTML files.
    .PARAMETER CampaignAudit
        Hashtable with campaign audit data. See Export-SPAuditHtml for schema.
    .PARAMETER AnchorId
        Optional HTML id attribute for the section anchor (used by combined TOC).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CampaignAudit,

        [Parameter()]
        [string]$AnchorId = '',

        [Parameter()]
        [ValidateSet('Summary', 'Detailed', 'Verbose')]
        [string]$DetailLevel = 'Verbose'
    )

    $campaignName   = ConvertTo-SafeHtml ($CampaignAudit['CampaignName'])
    $campaignId     = ConvertTo-SafeHtml ($CampaignAudit['CampaignId'])
    $status         = ConvertTo-SafeHtml ($CampaignAudit['Status'])
    $created        = Format-HtmlDate   ($CampaignAudit['Created'])
    $completed      = Format-HtmlDate   ($CampaignAudit['Completed'])
    $totalCerts     = if ($CampaignAudit.ContainsKey('TotalCertifications')) { [int]$CampaignAudit['TotalCertifications'] } else { 0 }

    $decisions        = if ($CampaignAudit.ContainsKey('Decisions')         -and $null -ne $CampaignAudit['Decisions'])         { $CampaignAudit['Decisions']         } else { @{ Approved = @(); Revoked = @(); Pending = @() } }
    $reviewers        = if ($CampaignAudit.ContainsKey('Reviewers')         -and $null -ne $CampaignAudit['Reviewers'])         { $CampaignAudit['Reviewers']         } else { @{ Primary = @(); Reassigned = @() } }
    $events           = if ($CampaignAudit.ContainsKey('Events')            -and $null -ne $CampaignAudit['Events'])            { $CampaignAudit['Events']            } else { @{ Revoked = @(); Granted = @() } }
    $campRpts         = if ($CampaignAudit.ContainsKey('CampaignReports')   -and $null -ne $CampaignAudit['CampaignReports'])   { $CampaignAudit['CampaignReports']   } else { $null }
    $rptAvailable     = if ($CampaignAudit.ContainsKey('CampaignReportsAvailable')) { [bool]$CampaignAudit['CampaignReportsAvailable'] } else { $false }
    $reviewerMetrics  = if ($CampaignAudit.ContainsKey('ReviewerMetrics')   -and $null -ne $CampaignAudit['ReviewerMetrics'])   { $CampaignAudit['ReviewerMetrics']   } else { $null }
    $remediationProof = if ($CampaignAudit.ContainsKey('RemediationProof')  -and $null -ne $CampaignAudit['RemediationProof'])  { $CampaignAudit['RemediationProof']  } else { $null }
    $rubberStampRisk  = if ($CampaignAudit.ContainsKey('RubberStampRisk')   -and $null -ne $CampaignAudit['RubberStampRisk'])   { $CampaignAudit['RubberStampRisk']   } else { $null }

    $statusColor = switch ($status) {
        'COMPLETED' { '#339933' }
        'ACTIVE'    { '#336699' }
        'STAGED'    { '#FF8800' }
        default     { '#777777' }
    }

    $anchorAttr = if (-not [string]::IsNullOrWhiteSpace($AnchorId)) { " id=""$([System.Net.WebUtility]::HtmlEncode($AnchorId))""" } else { '' }

    $sectionHeadStyle = 'style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;"'
    $tableStyle       = 'style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px; margin-bottom:20px;"'
    $summaryTdLabel   = 'style="padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;"'
    $summaryTdValue   = 'style="padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;"'

    # Calculate campaign duration for Section 1
    $campaignDurationDisplay = ''
    $dtCampaignCreated   = $null
    $dtCampaignCompleted = $null
    $createdRawStr   = if ($CampaignAudit.ContainsKey('Created')   -and $null -ne $CampaignAudit['Created'])   { [string]$CampaignAudit['Created']   } else { '' }
    $completedRawStr = if ($CampaignAudit.ContainsKey('Completed') -and $null -ne $CampaignAudit['Completed']) { [string]$CampaignAudit['Completed'] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($createdRawStr)) {
        try {
            $dtCampaignCreated = [datetime]::Parse($createdRawStr, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { $dtCampaignCreated = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($completedRawStr)) {
        try {
            $dtCampaignCompleted = [datetime]::Parse($completedRawStr, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { $dtCampaignCompleted = $null }
    }
    if ($null -ne $dtCampaignCreated -and $null -ne $dtCampaignCompleted) {
        $campDurHours = ($dtCampaignCompleted - $dtCampaignCreated).TotalHours
        if ($campDurHours -lt 0) { $campDurHours = 0 }
        $campaignDurationDisplay = Format-HoursDisplay $campDurHours
    }

    $durationRow = if (-not [string]::IsNullOrWhiteSpace($campaignDurationDisplay)) {
        "        <tr><td $summaryTdLabel>Campaign Duration</td><td $summaryTdValue>$([System.Net.WebUtility]::HtmlEncode($campaignDurationDisplay))</td></tr>`n"
    } else { '' }

    $html = @"
<div$anchorAttr style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif;">

<h2 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-bottom:4px; font-size:20px;">$campaignName</h2>
<p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:12px; margin-top:2px;">Campaign ID: $campaignId</p>

"@

    # Executive Summary Dashboard (before Section 1)
    $html += Build-ExecutiveSummaryHtml -CampaignAudit $CampaignAudit

    $html += @"
<h3 $sectionHeadStyle>1. Campaign Summary</h3>
<table $tableStyle>
    <tbody>
        <tr><td $summaryTdLabel>Campaign Name</td><td $summaryTdValue>$campaignName</td></tr>
        <tr><td $summaryTdLabel>Status</td><td $summaryTdValue><span style="color:$statusColor; font-weight:bold;">$status</span></td></tr>
        <tr><td $summaryTdLabel>Created</td><td $summaryTdValue>$([System.Net.WebUtility]::HtmlEncode($created))</td></tr>
        <tr><td $summaryTdLabel>Completed</td><td $summaryTdValue>$([System.Net.WebUtility]::HtmlEncode($completed))</td></tr>
        <tr><td $summaryTdLabel>Total Certifications</td><td $summaryTdValue>$totalCerts</td></tr>
        $durationRow
    </tbody>
</table>

"@

    # --- Section 2: Reviewer Accountability ---
    $html += "<h3 $sectionHeadStyle>2. Reviewer Accountability</h3>`n"

    # Primary Reviewers
    $primaryRows = $reviewers['Primary']
    $primaryCount = if ($null -ne $primaryRows) { @($primaryRows).Count } else { 0 }
    $reassignedRows = $reviewers['Reassigned']
    $reassignedCount = if ($null -ne $reassignedRows) { @($reassignedRows).Count } else { 0 }

    if ($DetailLevel -eq 'Summary') {
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:6px;"">Primary Reviewers: $primaryCount | Reassigned Reviewers: $reassignedCount</p>`n"
    }
    else {
        $s2OpenAttr = if ($DetailLevel -eq 'Verbose') { ' open' } else { '' }

        # Primary Reviewers
        $html += "<details$s2OpenAttr>`n"
        $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; cursor:pointer;"">Primary Reviewers ($primaryCount)</summary>`n"
        $html += "<table $tableStyle>`n"
        $html += (Build-HtmlTableHeader -Headers @('Name', 'Email', 'Certs Assigned', 'Decisions Made', 'Sign-Off Date', 'Phase'))
        $html += "<tbody>`n"

        if ($primaryCount -eq 0) {
            $html += "<tr><td colspan=""6"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No primary reviewers found.</td></tr>`n"
        }
        else {
            $rowIdx = 0
            foreach ($r in $primaryRows) {
                $cells = @(
                    (ConvertTo-SafeHtml $r.Name),
                    (ConvertTo-SafeHtml $r.Email),
                    (ConvertTo-SafeHtml $r.CertsAssigned),
                    (ConvertTo-SafeHtml $r.DecisionsMade),
                    (ConvertTo-SafeHtml (Format-HtmlDate $r.SignOffDate)),
                    (ConvertTo-SafeHtml $r.Phase)
                )
                $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                $rowIdx++
            }
        }
        $html += "</tbody></table>`n"
        $html += "</details>`n"

        # Reassigned Reviewers
        $html += "<details$s2OpenAttr>`n"
        $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:12px; cursor:pointer;"">Reassigned Reviewers ($reassignedCount)</summary>`n"
        $html += "<table $tableStyle>`n"
        $html += (Build-HtmlTableHeader -Headers @('Name', 'Email', 'Reassigned From', 'Decisions Made', 'Sign-Off Date', 'Phase', 'Proof of Action'))
        $html += "<tbody>`n"

        if ($reassignedCount -eq 0) {
            $html += "<tr><td colspan=""7"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No reassignments recorded.</td></tr>`n"
        }
        else {
            $rowIdx = 0
            foreach ($r in $reassignedRows) {
                $proofLabel = if ($r.ProofOfAction) { '<span style="color:#339933; font-weight:bold;">Yes</span>' } else { '<span style="color:#CC3333;">No</span>' }
                $cells = @(
                    (ConvertTo-SafeHtml $r.Name),
                    (ConvertTo-SafeHtml $r.Email),
                    (ConvertTo-SafeHtml $r.ReassignedFrom),
                    (ConvertTo-SafeHtml $r.DecisionsMade),
                    (ConvertTo-SafeHtml (Format-HtmlDate $r.SignOffDate)),
                    (ConvertTo-SafeHtml $r.Phase),
                    $proofLabel
                )
                $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                $rowIdx++
            }
        }
        $html += "</tbody></table>`n"
        $html += "</details>`n"
    }

    # --- Section 3: Reviewer Performance ---
    $html += "<h3 $sectionHeadStyle>3. Reviewer Performance</h3>`n"

    if ($null -eq $reviewerMetrics) {
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-style:italic;"">Reviewer performance metrics not available (no certification timing data provided).</p>`n"
    }
    else {
        # Campaign-level summary table (always shown - it IS the summary)
        $campMinDisplay    = Format-HoursDisplay $reviewerMetrics['CampaignMinHours']
        $campMaxDisplay    = Format-HoursDisplay $reviewerMetrics['CampaignMaxHours']
        $campAvgDisplay    = Format-HoursDisplay $reviewerMetrics['CampaignAvgHours']
        $campMedianDisplay = Format-HoursDisplay $reviewerMetrics['CampaignMedianHours']

        $html += "<table $tableStyle>`n"
        $html += "    <tbody>`n"
        $html += "        <tr><td $summaryTdLabel>Fastest Response</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campMinDisplay)</td></tr>`n"
        $html += "        <tr><td $summaryTdLabel>Slowest Response</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campMaxDisplay)</td></tr>`n"
        $html += "        <tr><td $summaryTdLabel>Average Response</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campAvgDisplay)</td></tr>`n"
        $html += "        <tr><td $summaryTdLabel>Median Response</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campMedianDisplay)</td></tr>`n"
        $html += "    </tbody>`n"
        $html += "</table>`n"

        # Per-reviewer table (wrapped in <details> for Detailed/Verbose, omitted for Summary)
        $perReviewerRows = @($reviewerMetrics['ReviewerMetrics'])
        if ($DetailLevel -ne 'Summary') {
            $s3OpenAttr = if ($DetailLevel -eq 'Verbose') { ' open' } else { '' }
            $s3ReviewerCount = if ($null -ne $perReviewerRows) { @($perReviewerRows).Count } else { 0 }
            $html += "<details$s3OpenAttr>`n"
            $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:12px; cursor:pointer;"">Per-Reviewer Breakdown ($s3ReviewerCount reviewer(s))</summary>`n"
            $html += "<table $tableStyle>`n"
            $html += (Build-HtmlTableHeader -Headers @('Reviewer', 'Classification', 'Certs', 'Decisions', 'Min Time', 'Max Time', 'Avg Time'))
            $html += "<tbody>`n"

            if ($null -eq $perReviewerRows -or $perReviewerRows.Count -eq 0) {
                $html += "<tr><td colspan=""7"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No completed certifications with timing data.</td></tr>`n"
            }
            else {
                $rowIdx = 0
                foreach ($rm in $perReviewerRows) {
                    # Color-code the avg time cell based on threshold
                    $avgHours = $rm.AvgHours
                    $avgColor = if ($null -eq $avgHours) {
                        '#777777'
                    }
                    elseif ($avgHours -le 24) {
                        '#339933'
                    }
                    elseif ($avgHours -le 72) {
                        '#336699'
                    }
                    else {
                        '#FF8800'
                    }

                    $minDisplay = Format-HoursDisplay $rm.MinHours
                    $maxDisplay = Format-HoursDisplay $rm.MaxHours
                    $avgDisplay = Format-HoursDisplay $rm.AvgHours

                    $rowStyle   = if (($rowIdx % 2) -eq 1) { ' style="background:#f9f9f9;"' } else { '' }
                    $tdPadding  = 'style="padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;"'
                    $avgTdStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; color:$avgColor; font-weight:bold;"""

                    $html += "<tr$rowStyle>"
                    $html += "<td $tdPadding>$(ConvertTo-SafeHtml $rm.Name)</td>"
                    $html += "<td $tdPadding>$(ConvertTo-SafeHtml $rm.Classification)</td>"
                    $html += "<td $tdPadding>$(ConvertTo-SafeHtml $rm.CertsCompleted)</td>"
                    $html += "<td $tdPadding>$(ConvertTo-SafeHtml $rm.DecisionsMade)</td>"
                    $html += "<td $tdPadding>$(ConvertTo-SafeHtml $minDisplay)</td>"
                    $html += "<td $tdPadding>$(ConvertTo-SafeHtml $maxDisplay)</td>"
                    $html += "<td $avgTdStyle>$(ConvertTo-SafeHtml $avgDisplay)</td>"
                    $html += "</tr>`n"
                    $rowIdx++
                }
            }
            $html += "</tbody></table>`n"
            $html += "</details>`n"
        }
    }

    # --- Section 4: Decision Summary ---
    $html += "<h3 $sectionHeadStyle>4. Decision Summary</h3>`n"

    $decisionCategories = @(
        @{ Label = 'Approved'; Color = '#339933'; Items = $decisions['Approved'] },
        @{ Label = 'Revoked';  Color = '#CC3333'; Items = $decisions['Revoked']  },
        @{ Label = 'Pending';  Color = '#FF8800'; Items = $decisions['Pending']  }
    )

    foreach ($cat in $decisionCategories) {
        $catItems = @($cat['Items'])
        $catColor = $cat['Color']
        $catLabel = $cat['Label']

        $countLabel = "$($catItems.Count) item"
        if ($catItems.Count -ne 1) { $countLabel += 's' }

        if ($DetailLevel -eq 'Summary') {
            # Summary mode: aggregate counts only, no detail tables
            $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; color:${catColor}; margin-bottom:6px; margin-top:12px;"">${catLabel}: $countLabel</p>`n"
        }
        else {
            # Detailed/Verbose: wrap in <details>/<summary>
            # Detailed: revocations auto-expanded, others collapsed
            # Verbose: all expanded
            $openAttr = if ($DetailLevel -eq 'Verbose' -or $catLabel -eq 'Revoked') { ' open' } else { '' }
            $summaryStyle = "style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; color:${catColor}; margin-bottom:6px; margin-top:12px; cursor:pointer;"""

            $html += "<details$openAttr>`n"
            $html += "<summary $summaryStyle>$catLabel ($countLabel)</summary>`n"
            $html += "<table $tableStyle>`n"
            $html += (Build-HtmlTableHeader -Headers @('Identity', 'Account', 'Access Name', 'Type', 'Reviewer', 'Decision Date', 'Justification', 'Remediation'))
            $html += "<tbody>`n"

            if ($catItems.Count -eq 0) {
                $html += "<tr><td colspan=""8"" style=""padding:8px 10px; color:#777777; font-style:italic;"">None.</td></tr>`n"
            }
            else {
                $rowIdx = 0
                foreach ($item in $catItems) {
                    $riskBadges = ''
                    if ($null -ne $item.PSObject -and
                        $null -ne $item.PSObject.Properties['RiskFlags'] -and
                        $null -ne $item.RiskFlags -and @($item.RiskFlags).Count -gt 0) {
                        $riskBadges = Format-RiskFlagBadges -Flags @($item.RiskFlags)
                    }

                    # Justification display
                    $justDisplay = 'N/A'
                    if ($null -ne $item.PSObject.Properties['Justification'] -and
                        -not [string]::IsNullOrWhiteSpace($item.Justification)) {
                        $justDisplay = $item.Justification
                    }

                    # Remediation status display with color coding
                    $remStatus = 'N/A'
                    $remHtml   = '<span style="color:#777777;">N/A</span>'
                    if ($null -ne $item.PSObject.Properties['RemediationStatus'] -and
                        -not [string]::IsNullOrWhiteSpace($item.RemediationStatus)) {
                        $remStatus = $item.RemediationStatus
                    }
                    if ($remStatus -eq 'Provisioned') {
                        $remHtml = '<span style="color:#339933; font-weight:bold;">Provisioned</span>'
                    }
                    elseif ($remStatus -eq 'Pending') {
                        $remHtml = '<span style="color:#FF8800; font-weight:bold;">Pending</span>'
                    }

                    $cells = @(
                        ((ConvertTo-SafeHtml $item.IdentityName) + $riskBadges),
                        (ConvertTo-SafeHtml $item.AccountIdentifier),
                        (ConvertTo-SafeHtml $item.AccessName),
                        (ConvertTo-SafeHtml $item.AccessType),
                        (ConvertTo-SafeHtml $item.ReviewerName),
                        (ConvertTo-SafeHtml (Format-HtmlDate $item.DecisionDate)),
                        (ConvertTo-SafeHtml $justDisplay),
                        $remHtml
                    )
                    $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                    $rowIdx++
                }
            }
            $html += "</tbody></table>`n"
            $html += "</details>`n"
        }
    }

    # --- Section 5: Campaign Reports ---
    if ($DetailLevel -ne 'Summary') {
        $html += "<h3 $sectionHeadStyle>5. Campaign Reports</h3>`n"

        if (-not $rptAvailable -or $null -eq $campRpts) {
            $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-style:italic;"">Campaign reports not available for this campaign (API does not provide on-demand report data).</p>`n"
        }
        else {
            $s5OpenAttr = if ($DetailLevel -eq 'Verbose') { ' open' } else { '' }

            # Render each report type as a table wrapped in <details>
            foreach ($rptKey in $campRpts.Keys) {
                $rptData = @($campRpts[$rptKey])

                $html += "<details$s5OpenAttr>`n"
                $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; cursor:pointer;"">$([System.Net.WebUtility]::HtmlEncode($rptKey)) ($($rptData.Count) row(s))</summary>`n"

                if ($rptData.Count -eq 0) {
                    $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-style:italic;"">No records.</p>`n"
                }
                else {
                    # Derive headers from first row
                    $firstRow = $rptData[0]
                    $headers = @()
                    if ($firstRow -is [hashtable]) {
                        $headers = @($firstRow.Keys)
                    }
                    elseif ($null -ne $firstRow.PSObject) {
                        $headers = @($firstRow.PSObject.Properties.Name)
                    }

                    $html += "<table $tableStyle>`n"
                    $html += (Build-HtmlTableHeader -Headers $headers)
                    $html += "<tbody>`n"

                    $rowIdx = 0
                    foreach ($row in $rptData) {
                        $cells = @()
                        foreach ($h in $headers) {
                            $val = ''
                            if ($row -is [hashtable]) {
                                $val = if ($row.ContainsKey($h)) { [string]$row[$h] } else { '' }
                            }
                            else {
                                $prop = $row.PSObject.Properties[$h]
                                $val  = if ($null -ne $prop) { [string]$prop.Value } else { '' }
                            }
                            $cells += [System.Net.WebUtility]::HtmlEncode($val)
                        }
                        $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                        $rowIdx++
                    }
                    $html += "</tbody></table>`n"
                }
                $html += "</details>`n"
            }
        }
    }

    # --- Section 6: Remediation & Reassignment Proof ---
    $html += "<h3 $sectionHeadStyle>6. Remediation &amp; Reassignment Proof</h3>`n"

    if ($null -ne $remediationProof) {
        # Sub-section A: Remediation Summary (always shown - it IS the summary)
        $totalRevoked     = [int]$remediationProof['TotalRevoked']
        $completeCount    = [int]$remediationProof['RemediationCompleteCount']
        $pendingCount     = [int]$remediationProof['RemediationPendingCount']
        $completeColor    = '#339933'
        $pendingColor     = if ($pendingCount -gt 0) { '#FF8800' } else { '#339933' }

        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px;"">Remediation Summary</p>`n"
        $html += "<table $tableStyle>`n"
        $html += "    <tbody>`n"
        $html += "        <tr><td $summaryTdLabel>Total Revoked Items</td><td $summaryTdValue>$totalRevoked</td></tr>`n"
        $html += "        <tr><td $summaryTdLabel>Remediation Complete</td><td $summaryTdValue><span style=""color:$completeColor; font-weight:bold;"">$completeCount</span></td></tr>`n"
        $html += "        <tr><td $summaryTdLabel>Remediation Pending</td><td $summaryTdValue><span style=""color:$pendingColor; font-weight:bold;"">$pendingCount</span></td></tr>`n"
        $html += "    </tbody>`n"
        $html += "</table>`n"

        if ($DetailLevel -ne 'Summary') {
            # Sub-section B: Revoked Items - Remediation Status (wrapped in <details>)
            $revokedRows = @($remediationProof['RevokedItems'])
            # Revocations auto-expanded in both Detailed and Verbose
            $html += "<details open>`n"
            $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:16px; cursor:pointer;"">Revoked Items - Remediation Status ($($revokedRows.Count) item(s))</summary>`n"
            $html += "<table $tableStyle>`n"
            $html += (Build-HtmlTableHeader -Headers @('Identity', 'Account', 'Access Name', 'Type', 'Source', 'Reviewer', 'Decision Date', 'Remediation'))
            $html += "<tbody>`n"

            if ($revokedRows.Count -eq 0) {
                $html += "<tr><td colspan=""8"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No revoked items recorded.</td></tr>`n"
            }
            else {
                $rowIdx = 0
                foreach ($ri in $revokedRows) {
                    $remLabel = if ($ri.RemediationComplete) {
                        '<span style="color:#339933; font-weight:bold;">Complete</span>'
                    }
                    else {
                        '<span style="color:#FF8800; font-weight:bold;">Pending</span>'
                    }
                    $cells = @(
                        (ConvertTo-SafeHtml $ri.IdentityName),
                        (ConvertTo-SafeHtml $ri.AccountIdentifier),
                        (ConvertTo-SafeHtml $ri.AccessName),
                        (ConvertTo-SafeHtml $ri.AccessType),
                        (ConvertTo-SafeHtml $ri.SourceName),
                        (ConvertTo-SafeHtml $ri.ReviewerName),
                        (ConvertTo-SafeHtml (Format-HtmlDate $ri.DecisionDate)),
                        $remLabel
                    )
                    $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                    $rowIdx++
                }
            }
            $html += "</tbody></table>`n"
            $html += "</details>`n"

            # Sub-section C: Reassignment Chain
            $chainRows = @($remediationProof['ReassignmentChain'])
            $s6cOpenAttr = if ($DetailLevel -eq 'Verbose') { ' open' } else { '' }
            $html += "<details$s6cOpenAttr>`n"
            $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:16px; cursor:pointer;"">Reassignment Chain ($($chainRows.Count) record(s))</summary>`n"
            $html += "<table $tableStyle>`n"
            $html += (Build-HtmlTableHeader -Headers @('Certification', 'Reassigned From', 'Current Reviewer', 'Sign-Off Date', 'Phase'))
            $html += "<tbody>`n"

            if ($chainRows.Count -eq 0) {
                $html += "<tr><td colspan=""5"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No reassignments recorded.</td></tr>`n"
            }
            else {
                $rowIdx = 0
                foreach ($hop in $chainRows) {
                    $cells = @(
                        (ConvertTo-SafeHtml $hop.CertificationName),
                        (ConvertTo-SafeHtml $hop.ReassignedFrom),
                        (ConvertTo-SafeHtml $hop.CurrentReviewer),
                        (ConvertTo-SafeHtml (Format-HtmlDate $hop.SignOffDate)),
                        (ConvertTo-SafeHtml $hop.Phase)
                    )
                    $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                    $rowIdx++
                }
            }
            $html += "</tbody></table>`n"
            $html += "</details>`n"
        }
    }
    else {
        # Backward-compatible fallback: render old account-activities data when RemediationProof is absent
        $provCategories = @(
            @{ Label = 'Access Revoked Events'; Items = $events['Revoked'] },
            @{ Label = 'Access Granted Events'; Items = $events['Granted'] }
        )

        foreach ($pcat in $provCategories) {
            $pcatItems = @($pcat['Items'])

            if ($DetailLevel -eq 'Summary') {
                $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:6px; margin-top:12px;"">$($pcat['Label']): $($pcatItems.Count) event(s)</p>`n"
            }
            else {
                $s6fOpenAttr = if ($DetailLevel -eq 'Verbose' -or $pcat['Label'] -eq 'Access Revoked Events') { ' open' } else { '' }
                $html += "<details$s6fOpenAttr>`n"
                $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:12px; cursor:pointer;"">$($pcat['Label']) ($($pcatItems.Count))</summary>`n"
                $html += "<table $tableStyle>`n"
                $html += (Build-HtmlTableHeader -Headers @('Identity', 'Actor', 'Source', 'Operation', 'Date', 'Status'))
                $html += "<tbody>`n"

                if ($pcatItems.Count -eq 0) {
                    $html += "<tr><td colspan=""6"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No events recorded.</td></tr>`n"
                }
                else {
                    $rowIdx = 0
                    foreach ($ev in $pcatItems) {
                        $cells = @(
                            (ConvertTo-SafeHtml $ev.TargetName),
                            (ConvertTo-SafeHtml $ev.Actor),
                            (ConvertTo-SafeHtml $ev.SourceName),
                            (ConvertTo-SafeHtml $ev.Operation),
                            (ConvertTo-SafeHtml (Format-HtmlDate $ev.Date)),
                            (ConvertTo-SafeHtml $ev.Status)
                        )
                        $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                        $rowIdx++
                    }
                }
                $html += "</tbody></table>`n"
                $html += "</details>`n"
            }
        }
    }

    # --- Section 8: Anti-Rubber-Stamping Analytics ---
    # Only shown when at least one Medium or High risk reviewer exists
    if ($null -ne $rubberStampRisk -and $rubberStampRisk['HasMediumOrHighRisk']) {
        $riskRows = @($rubberStampRisk['ReviewerRisks'])
        $riskCount = @($riskRows | Where-Object { $_.Severity -eq 'Medium' -or $_.Severity -eq 'High' }).Count

        $html += "<h3 $sectionHeadStyle>8. Anti-Rubber-Stamping Analytics</h3>`n"
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; color:#CC3333; margin-bottom:12px;"">$riskCount reviewer(s) flagged for potential rubber-stamping patterns. Review recommended before accepting audit evidence.</p>`n"

        if ($DetailLevel -eq 'Summary') {
            $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:6px;"">Flagged Reviewers: $riskCount (expand to Detailed or Verbose mode for full breakdown)</p>`n"
        }
        else {
            $s8OpenAttr = if ($DetailLevel -eq 'Verbose') { ' open' } else { '' }
            # Always auto-expand when risk is present
            $html += "<details open>`n"
            $html += "<summary style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; cursor:pointer;"">Reviewer Risk Assessment ($($riskRows.Count) reviewer(s))</summary>`n"
            $html += "<table $tableStyle>`n"
            $html += (Build-HtmlTableHeader -Headers @('Reviewer', 'Items', 'Velocity (items/min)', 'Approval Rate', 'Bulk Clusters', 'Response Latency', 'Risk Level', 'Flags'))
            $html += "<tbody>`n"

            $rowIdx = 0
            foreach ($rr in $riskRows) {
                $riskColor = switch ($rr.Severity) {
                    'High'   { '#CC3333' }
                    'Medium' { '#FF8800' }
                    'Low'    { '#336699' }
                    default  { '#339933' }
                }

                $velocityDisplay = if ($rr.VelocityItemsPerMin -gt 0) { [string]$rr.VelocityItemsPerMin } else { 'N/A' }
                $approvalDisplay = '' + $rr.ApprovalRate + '%'
                $bulkDisplay = [string]$rr.BulkClusters
                $latencyDisplay = if ($null -ne $rr.ResponseLatencyMin) { '' + $rr.ResponseLatencyMin + ' min' } else { 'N/A' }
                $flagsDisplay = if ($rr.Flags.Count -gt 0) { $rr.Flags -join '; ' } else { '--' }

                $rowStyle  = if (($rowIdx % 2) -eq 1) { ' style="background:#f9f9f9;"' } else { '' }
                $tdPadding = 'style="padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;"'
                $riskTdStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; color:$riskColor; font-weight:bold;"""

                $html += "<tr$rowStyle>"
                $html += "<td $tdPadding>$(ConvertTo-SafeHtml $rr.ReviewerName)</td>"
                $html += "<td $tdPadding>$($rr.TotalItems)</td>"
                $html += "<td $tdPadding>$(ConvertTo-SafeHtml $velocityDisplay)</td>"
                $html += "<td $tdPadding>$(ConvertTo-SafeHtml $approvalDisplay)</td>"
                $html += "<td $tdPadding>$(ConvertTo-SafeHtml $bulkDisplay)</td>"
                $html += "<td $tdPadding>$(ConvertTo-SafeHtml $latencyDisplay)</td>"
                $html += "<td $riskTdStyle>$(ConvertTo-SafeHtml $rr.Severity)</td>"
                $html += "<td $tdPadding>$(ConvertTo-SafeHtml $flagsDisplay)</td>"
                $html += "</tr>`n"
                $rowIdx++
            }
            $html += "</tbody></table>`n"
            $html += "</details>`n"
        }
    }

    $html += "</div>`n"
    return $html
}


#endregion Campaign HTML Builder

#region Report Generation

function Export-SPAuditHtml {
    <#
    .SYNOPSIS
        Generates Word-compatible HTML audit reports for one or more campaigns.
    .DESCRIPTION
        Accepts an array of campaign audit hashtables and writes self-contained
        HTML files to OutputPath. All CSS is inline on elements so the document
        can be pasted into Microsoft Word without style loss. No flexbox, no
        grid, no external resources.

        When -Combined is specified a single HTML file containing all campaigns
        with a table of contents is also produced.

        Each CampaignAudit hashtable must have:
            CampaignName            - string
            CampaignId              - string
            Status                  - string (COMPLETED, ACTIVE, etc.)
            Created                 - ISO 8601 string
            Completed               - ISO 8601 string (may be empty)
            TotalCertifications     - int
            Decisions               - @{ Approved=@(...); Revoked=@(...); Pending=@(...) }
            Reviewers               - @{ Primary=@(...); Reassigned=@(...) }
            Events                  - @{ Revoked=@(...); Granted=@(...) }
            CampaignReports         - hashtable or $null
            CampaignReportsAvailable - bool
    .PARAMETER CampaignAudits
        One or more campaign audit hashtables.
    .PARAMETER OutputPath
        Directory in which to write the HTML files. Created if absent.
    .PARAMETER Combined
        When present, also writes a combined multi-campaign HTML file.
    .PARAMETER CorrelationID
        Correlation ID embedded in the metadata footer.
    .PARAMETER RunMetadata
        Hashtable of run metadata (filters, tenant, run timestamp, etc.).
    .OUTPUTS
        [string[]] Paths of all HTML files written.
    .EXAMPLE
        $paths = Export-SPAuditHtml -CampaignAudits $audits -OutputPath 'C:\toolkit\Reports' -Combined
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$CampaignAudits,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [switch]$Combined,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [hashtable]$RunMetadata,

        [Parameter()]
        [ValidateSet('Summary', 'Detailed', 'Verbose')]
        [string]$DetailLevel = 'Verbose'
    )

    $writtenFiles = [System.Collections.Generic.List[string]]::new()
    $timestamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Build metadata section HTML
    $metaRowsHtml = ''
    if ($null -ne $RunMetadata) {
        foreach ($key in $RunMetadata.Keys) {
            $metaRowsHtml += "<tr><td style=""padding:6px 10px; font-weight:bold; width:200px; background:#f4f4f4; border-bottom:1px solid #e0e0e0;"">$([System.Net.WebUtility]::HtmlEncode($key))</td><td style=""padding:6px 10px; border-bottom:1px solid #e0e0e0;"">$([System.Net.WebUtility]::HtmlEncode([string]$RunMetadata[$key]))</td></tr>`n"
        }
    }

    $metaSection = @"
<h3 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;">7. Audit Metadata</h3>
<table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:20px;">
    <tbody>
        <tr><td style="padding:6px 10px; font-weight:bold; width:200px; background:#f4f4f4; border-bottom:1px solid #e0e0e0;">Correlation ID</td><td style="padding:6px 10px; border-bottom:1px solid #e0e0e0;">$([System.Net.WebUtility]::HtmlEncode($CorrelationID))</td></tr>
        <tr><td style="padding:6px 10px; font-weight:bold; width:200px; background:#f4f4f4; border-bottom:1px solid #e0e0e0;">Report Generated</td><td style="padding:6px 10px; border-bottom:1px solid #e0e0e0;">$([System.Net.WebUtility]::HtmlEncode($generatedAt))</td></tr>
        $metaRowsHtml
    </tbody>
</table>
"@

    $footerHtml = @"
<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit v$($script:AuditReportVersion) &nbsp;|&nbsp; Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt)) &nbsp;|&nbsp; Correlation ID: $([System.Net.WebUtility]::HtmlEncode($CorrelationID))
</div>
"@

    $htmlOpen = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SailPoint Campaign Audit Report</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">
<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">
"@

    $htmlClose = @"
</div>
</body>
</html>
"@

    # Per-campaign files
    $combinedBody = ''
    $tocEntries   = [System.Collections.Generic.List[string]]::new()

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $campName  = if ($audit.ContainsKey('CampaignName')) { [string]$audit['CampaignName'] } else { 'UnknownCampaign' }
        $safeName  = $campName -replace '[\\/:*?"<>|\s]', '-'
        $fileName  = "campaign-audit-${safeName}-${timestamp}.html"
        $filePath  = Join-Path -Path $OutputPath -ChildPath $fileName

        $anchorId  = "campaign-$safeName"
        $bodyHtml  = Build-SingleCampaignHtml -CampaignAudit $audit -AnchorId $anchorId -DetailLevel $DetailLevel

        $perCampaignHtml = $htmlOpen + $bodyHtml + $metaSection + $footerHtml + $htmlClose
        $perCampaignHtml | Set-Content -Path $filePath -Encoding UTF8
        $writtenFiles.Add($filePath)

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Audit HTML written: $filePath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditHtml' `
                -CorrelationID $CorrelationID
        }

        # Accumulate for combined output
        if ($Combined) {
            $tocEntries.Add("<li style=""margin-bottom:4px;""><a href=""#$([System.Net.WebUtility]::HtmlEncode($anchorId))"" style=""color:#336699;"">$([System.Net.WebUtility]::HtmlEncode($campName))</a></li>")
            if ($combinedBody.Length -gt 0) {
                $combinedBody += "`n<div style=""page-break-before:always;""></div>`n"
            }
            $combinedBody += $bodyHtml
        }
    }

    # Combined file
    if ($Combined -and $combinedBody.Length -gt 0) {
        $totalApproved = 0
        $totalRevoked  = 0
        $totalPending  = 0

        foreach ($audit in $CampaignAudits) {
            if ($null -eq $audit) { continue }
            $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
            if ($null -ne $d) {
                $totalApproved += if ($null -ne $d['Approved']) { @($d['Approved']).Count } else { 0 }
                $totalRevoked  += if ($null -ne $d['Revoked'])  { @($d['Revoked']).Count  } else { 0 }
                $totalPending  += if ($null -ne $d['Pending'])  { @($d['Pending']).Count  } else { 0 }
            }
        }

        $tocHtml = "<ul style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:14px; line-height:1.8;"">`n" + ($tocEntries -join "`n") + "`n</ul>"

        $summaryHtml = @"
<h1 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; font-size:24px; margin-bottom:8px;">SailPoint Campaign Audit - Combined Report</h1>
<p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:12px; margin-bottom:20px;">Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt))</p>

<h2 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; font-size:18px;">Cross-Campaign Summary</h2>
<table style="width:auto; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:24px;">
    <thead>
        <tr>
            <th style="background:#34495e; color:#fff; padding:8px 20px; text-align:left;">Metric</th>
            <th style="background:#34495e; color:#fff; padding:8px 20px; text-align:right;">Count</th>
        </tr>
    </thead>
    <tbody>
        <tr><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0;">Campaigns</td><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0; text-align:right; font-weight:bold;">$($CampaignAudits.Count)</td></tr>
        <tr style="background:#f9f9f9;"><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0;">Total Approved</td><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0; text-align:right; color:#339933; font-weight:bold;">$totalApproved</td></tr>
        <tr><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0;">Total Revoked</td><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0; text-align:right; color:#CC3333; font-weight:bold;">$totalRevoked</td></tr>
        <tr style="background:#f9f9f9;"><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0;">Total Pending</td><td style="padding:7px 20px; border-bottom:1px solid #e0e0e0; text-align:right; color:#FF8800; font-weight:bold;">$totalPending</td></tr>
    </tbody>
</table>

<h2 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; font-size:18px;">Table of Contents</h2>
$tocHtml

<hr style="border:none; border-top:1px solid #dee2e6; margin:28px 0;" />
"@

        $combinedFilePath = Join-Path -Path $OutputPath -ChildPath "campaign-audit-combined-${timestamp}.html"
        $combinedFileHtml = $htmlOpen + $summaryHtml + $combinedBody + $metaSection + $footerHtml + $htmlClose
        $combinedFileHtml | Set-Content -Path $combinedFilePath -Encoding UTF8
        $writtenFiles.Add($combinedFilePath)

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Combined audit HTML written: $combinedFilePath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditHtml' `
                -CorrelationID $CorrelationID
        }
    }

    return $writtenFiles.ToArray()
}


function Export-SPAuditText {
    <#
    .SYNOPSIS
        Writes plain-text audit reports suitable for copy-paste or archiving.
    .DESCRIPTION
        Produces one text file per campaign in OutputPath. The format uses
        section headers and simple dash-separated tables readable in any editor
        and copy-pasteable into email or ticketing systems.
    .PARAMETER CampaignAudits
        One or more campaign audit hashtables (same schema as Export-SPAuditHtml).
    .PARAMETER OutputPath
        Directory in which to write the text files. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID embedded in the metadata footer.
    .PARAMETER RunMetadata
        Hashtable of run metadata (filters, tenant, run timestamp, etc.).
    .OUTPUTS
        [string[]] Paths of all text files written.
    .EXAMPLE
        $paths = Export-SPAuditText -CampaignAudits $audits -OutputPath 'C:\toolkit\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$CampaignAudits,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [hashtable]$RunMetadata
    )

    $writtenFiles = [System.Collections.Generic.List[string]]::new()
    $timestamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $campName  = if ($audit.ContainsKey('CampaignName')) { [string]$audit['CampaignName'] } else { 'UnknownCampaign' }
        $campId    = if ($audit.ContainsKey('CampaignId'))   { [string]$audit['CampaignId']   } else { '' }
        $status    = if ($audit.ContainsKey('Status'))       { [string]$audit['Status']        } else { '' }
        $created   = if ($audit.ContainsKey('Created'))      { [string]$audit['Created']       } else { '' }
        $completed = if ($audit.ContainsKey('Completed'))    { [string]$audit['Completed']     } else { '' }
        $totalCerts = if ($audit.ContainsKey('TotalCertifications')) { [int]$audit['TotalCertifications'] } else { 0 }

        $decisions  = if ($audit.ContainsKey('Decisions')  -and $null -ne $audit['Decisions'])  { $audit['Decisions']  } else { @{ Approved = @(); Revoked = @(); Pending = @() } }
        $reviewers  = if ($audit.ContainsKey('Reviewers')  -and $null -ne $audit['Reviewers'])  { $audit['Reviewers']  } else { @{ Primary = @(); Reassigned = @() } }
        $events     = if ($audit.ContainsKey('Events')     -and $null -ne $audit['Events'])      { $audit['Events']     } else { @{ Revoked = @(); Granted = @() } }

        $lines = [System.Collections.Generic.List[string]]::new()

        $lines.Add('========================================')
        $lines.Add('CAMPAIGN AUDIT REPORT')
        $lines.Add("Campaign: $campName")
        $lines.Add("Campaign ID: $campId")
        $lines.Add("Status: $status")
        $lines.Add("Created: $created")
        $lines.Add("Completed: $completed")
        $lines.Add("Total Certifications: $totalCerts")
        $lines.Add('========================================')
        $lines.Add('')

        # Reviewer Accountability
        $lines.Add('--- REVIEWER ACCOUNTABILITY ---')
        $lines.Add('')
        $lines.Add('Primary Reviewers:')
        $primaryRows = @($reviewers['Primary'])
        if ($primaryRows.Count -eq 0) {
            $lines.Add('  (none)')
        }
        else {
            foreach ($r in $primaryRows) {
                $signOff = if (-not [string]::IsNullOrWhiteSpace($r.SignOffDate)) { ", signed $($r.SignOffDate)" } else { '' }
                $lines.Add("  - $($r.Name) ($($r.Email)) -- $($r.DecisionsMade) decisions, $($r.CertsAssigned) cert(s)$signOff")
            }
        }

        $lines.Add('')
        $lines.Add('Reassigned Reviewers:')
        $reassignedRows = @($reviewers['Reassigned'])
        if ($reassignedRows.Count -eq 0) {
            $lines.Add('  (none)')
        }
        else {
            foreach ($r in $reassignedRows) {
                $proofText  = if ($r.ProofOfAction) { 'YES' } else { 'NO' }
                $signOff    = if (-not [string]::IsNullOrWhiteSpace($r.SignOffDate)) { ", signed $($r.SignOffDate)" } else { '' }
                $lines.Add("  - $($r.Name) ($($r.Email)) -- reassigned from $($r.ReassignedFrom)$signOff")
                $lines.Add("    Proof of action: $proofText ($($r.DecisionsMade) decisions, phase=$($r.Phase))")
            }
        }
        $lines.Add('')

        # Decision Categories
        $decisionCategories = @(
            @{ Label = 'APPROVED'; Items = $decisions['Approved'] },
            @{ Label = 'REVOKED';  Items = $decisions['Revoked']  },
            @{ Label = 'PENDING';  Items = $decisions['Pending']  }
        )

        foreach ($cat in $decisionCategories) {
            $catItems = @($cat['Items'])
            $lines.Add("--- $($cat['Label']) ($($catItems.Count)) ---")
            if ($catItems.Count -eq 0) {
                $lines.Add('  (none)')
            }
            else {
                foreach ($item in $catItems) {
                    $lines.Add("  - $($item.IdentityName): $($item.AccessName) ($($item.AccessType)) -- $($item.ReviewerName) on $($item.DecisionDate)")
                }
            }
            $lines.Add('')
        }

        # Provisioning Proof
        $lines.Add('--- PROVISIONING PROOF ---')
        $lines.Add('')

        $provCategories = @(
            @{ Label = 'Access Revoked'; Items = $events['Revoked'] },
            @{ Label = 'Access Granted'; Items = $events['Granted'] }
        )

        foreach ($pcat in $provCategories) {
            $pcatItems = @($pcat['Items'])
            $lines.Add("$($pcat['Label']) ($($pcatItems.Count)):")
            if ($pcatItems.Count -eq 0) {
                $lines.Add('  (none)')
            }
            else {
                foreach ($ev in $pcatItems) {
                    $lines.Add("  - Identity: $($ev.TargetName) | Actor: $($ev.Actor) | Source: $($ev.SourceName) | Op: $($ev.Operation) | Date: $($ev.Date) | Status: $($ev.Status)")
                }
            }
            $lines.Add('')
        }

        # Metadata
        $lines.Add('--- AUDIT METADATA ---')
        $lines.Add("Correlation ID: $CorrelationID")
        $lines.Add("Generated: $generatedAt")
        if ($null -ne $RunMetadata) {
            foreach ($key in $RunMetadata.Keys) {
                $lines.Add("${key}: $($RunMetadata[$key])")
            }
        }
        $lines.Add('')
        $lines.Add("SailPoint ISC Governance Toolkit v$($script:AuditReportVersion)")
        $lines.Add('')

        $safeName = $campName -replace '[\\/:*?"<>|\s]', '-'
        $fileName = "campaign-audit-${safeName}-${timestamp}.txt"
        $filePath = Join-Path -Path $OutputPath -ChildPath $fileName

        $content = $lines -join "`r`n"
        [System.IO.File]::WriteAllText($filePath, $content, [System.Text.Encoding]::UTF8)
        $writtenFiles.Add($filePath)

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Audit text report written: $filePath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditText' `
                -CorrelationID $CorrelationID
        }
    }

    return $writtenFiles.ToArray()
}


function Export-SPAuditJsonl {
    <#
    .SYNOPSIS
        Appends structured audit events to a JSONL file.
    .DESCRIPTION
        Serialises each event object to a single compressed JSON line and
        appends to the output file using UTF-8 without BOM encoding, matching
        the pattern used by SP.Evidence for consistent SIEM ingestion.

        Each line in the output file is a complete JSON object with at minimum:
            Timestamp, Action, CorrelationID, Data
    .PARAMETER OutputPath
        Directory in which to write the JSONL file. Created if absent.
    .PARAMETER FileName
        Filename to use. Defaults to audit-{yyyyMMdd-HHmmss}.jsonl.
    .PARAMETER Events
        Array of objects to serialise. Each should be a hashtable or
        PSCustomObject representing one audit event.
    .PARAMETER CorrelationID
        Correlation ID embedded in every written line.
    .OUTPUTS
        [string] Path to the JSONL file written.
    .EXAMPLE
        $path = Export-SPAuditJsonl -OutputPath 'C:\toolkit\Reports' `
                    -Events $auditEvents -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$FileName,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Events,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $ts       = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $FileName = "audit-${ts}.jsonl"
    }

    $filePath   = Join-Path -Path $OutputPath -ChildPath $FileName
    $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

    if ($null -eq $Events -or $Events.Count -eq 0) {
        # Write an empty-run marker so the file is created and traceable
        $marker = [ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'AuditExportStart'
            CorrelationID = $CorrelationID
            Data          = @{ EventCount = 0 }
        }
        $markerLine = $marker | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::AppendAllText($filePath, "$markerLine`n", $utf8NoBom)

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Audit JSONL written (0 events): $filePath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditJsonl' `
                -CorrelationID $CorrelationID
        }
        return $filePath
    }

    $linesWritten = 0
    foreach ($rawEvent in $Events) {
        try {
            # Determine action and data fields from the event object
            $action = 'AuditEvent'
            $data   = $rawEvent

            if ($rawEvent -is [hashtable]) {
                if ($rawEvent.ContainsKey('Action')) { $action = [string]$rawEvent['Action'] }
            }
            elseif ($null -ne $rawEvent.PSObject) {
                $actionProp = $rawEvent.PSObject.Properties['Action']
                if ($null -ne $actionProp) { $action = [string]$actionProp.Value }
            }

            $event = [ordered]@{
                Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                Action        = $action
                CorrelationID = $CorrelationID
                Data          = $data
            }

            $jsonLine = $event | ConvertTo-Json -Depth 5 -Compress
            [System.IO.File]::AppendAllText($filePath, "$jsonLine`n", $utf8NoBom)
            $linesWritten++
        }
        catch {
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message "Failed to write audit JSONL event: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.AuditReport' -Action 'Export-SPAuditJsonl' `
                    -CorrelationID $CorrelationID
            }
        }
    }

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message "Audit JSONL written ($linesWritten events): $filePath" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditJsonl' `
            -CorrelationID $CorrelationID
    }

    return $filePath
}


#endregion Report Generation

#region Leadership Executive Report

function Export-SPLeadershipExecutiveHtml {
    <#
    .SYNOPSIS
        Generates the leadership executive summary HTML report.
    .DESCRIPTION
        Produces a self-contained, Word-compatible HTML file that aggregates
        campaign audit results by leadership level. The report includes:
        - Campaign name and date range header
        - Overall metrics: total items, approval/revocation rates, completion %
        - SVG donut chart showing approve/revoke/pending distribution
        - Per-director summary table sorted by completion % ascending (worst first)
        - Color-coded completion column (green >= 95%, orange 80-95%, red < 80%)

        All CSS is inline on elements for Word copy-paste compatibility.
        No flexbox, no grid, no external resources.
    .PARAMETER LeadershipData
        Hashtable from Group-SPAuditByLeadership with Directors and Executive keys.
    .PARAMETER CampaignName
        Display name of the campaign (or combined campaign label).
    .PARAMETER DateRange
        Descriptive date range string for the report header (e.g. "2026-04-01 to 2026-04-30").
    .PARAMETER OutputPath
        Directory in which to write the HTML file. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID embedded in the report footer.
    .OUTPUTS
        [string] Path to the written executive-summary.html file.
    .EXAMPLE
        $path = Export-SPLeadershipExecutiveHtml -LeadershipData $leadership `
                    -CampaignName 'Q1 Access Review' -DateRange '2026-01-01 to 2026-03-31' `
                    -OutputPath 'C:\Reports\leadership'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$LeadershipData,

        [Parameter(Mandatory)]
        [string]$CampaignName,

        [Parameter()]
        [string]$DateRange = '',

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

    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $directors   = if ($LeadershipData.ContainsKey('Directors')) { $LeadershipData['Directors'] } else { @{} }
    $executive   = if ($LeadershipData.ContainsKey('Executive')) { $LeadershipData['Executive'] } else { @{} }

    # Use the dynamic label from the leadership data (e.g., "Vice President" instead of "Director")
    $directorLevelLabel = if ($LeadershipData.ContainsKey('DirectorLabel')) { $LeadershipData['DirectorLabel'] } else { 'Director' }

    # --- Aggregate overall totals across all directors ---
    $totalItems    = 0
    $totalApproved = 0
    $totalRevoked  = 0
    $totalPending  = 0

    foreach ($dirId in $directors.Keys) {
        $d = $directors[$dirId]
        $totalApproved += [int]$d.Approved
        $totalRevoked  += [int]$d.Revoked
        $totalPending  += [int]$d.Pending
    }
    $totalItems = $totalApproved + $totalRevoked + $totalPending

    $approvalRate   = if ($totalItems -gt 0) { [Math]::Round($totalApproved / $totalItems * 100, 1) } else { 0.0 }
    $revocationRate = if ($totalItems -gt 0) { [Math]::Round($totalRevoked  / $totalItems * 100, 1) } else { 0.0 }
    $completionPct  = if ($totalItems -gt 0) { [Math]::Round(($totalApproved + $totalRevoked) / $totalItems * 100, 1) } else { 0.0 }
    $pendingPct     = if ($totalItems -gt 0) { [Math]::Round($totalPending / $totalItems * 100, 1) } else { 0.0 }

    # Fix rounding drift so percentages sum to 100
    $sumPct = $approvalRate + $revocationRate + $pendingPct
    if ($sumPct -ne 100 -and $totalItems -gt 0) {
        $approvalRate = [Math]::Round(100 - $revocationRate - $pendingPct, 1)
    }

    # --- SVG donut chart (same pattern as Build-ExecutiveSummaryHtml) ---
    $seg1Offset = 25
    $seg2Offset = -($approvalRate - 25)
    $seg3Offset = -($approvalRate + $revocationRate - 25)

    $seg1Remain = [Math]::Round(100 - $approvalRate,   1)
    $seg2Remain = [Math]::Round(100 - $revocationRate, 1)
    $seg3Remain = [Math]::Round(100 - $pendingPct,     1)

    $donutSvg = @"
    <svg width="160" height="160" viewBox="0 0 42 42" style="display:block; margin:0 auto;">
        <circle cx="21" cy="21" r="15.9" fill="transparent" stroke="#e0e0e0" stroke-width="3.2"></circle>
        <circle cx="21" cy="21" r="15.9" fill="transparent"
                stroke="#339933" stroke-width="3.2"
                stroke-dasharray="$approvalRate $seg1Remain"
                stroke-dashoffset="$seg1Offset"
                stroke-linecap="butt"></circle>
        <circle cx="21" cy="21" r="15.9" fill="transparent"
                stroke="#CC3333" stroke-width="3.2"
                stroke-dasharray="$revocationRate $seg2Remain"
                stroke-dashoffset="$seg2Offset"
                stroke-linecap="butt"></circle>
        <circle cx="21" cy="21" r="15.9" fill="transparent"
                stroke="#FF8800" stroke-width="3.2"
                stroke-dasharray="$pendingPct $seg3Remain"
                stroke-dashoffset="$seg3Offset"
                stroke-linecap="butt"></circle>
        <text x="21" y="19.5" text-anchor="middle" style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:5px; font-weight:bold; fill:#2c3e50;">$totalItems</text>
        <text x="21" y="24" text-anchor="middle" style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:2.8px; fill:#777;">items</text>
    </svg>
"@

    # --- Summary cards HTML ---
    $safeCampaignName = ConvertTo-SafeHtml $CampaignName
    $safeDateRange    = ConvertTo-SafeHtml $DateRange
    $dateRangeHtml    = if (-not [string]::IsNullOrWhiteSpace($DateRange)) {
        "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:13px; margin:0 0 20px 0;"">$safeDateRange</p>"
    } else { '' }

    $completionColor = if ($completionPct -ge 95) { '#339933' } elseif ($completionPct -ge 80) { '#FF8800' } else { '#CC3333' }

    $summaryCardsHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<tr>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:32px; font-weight:bold; color:#2c3e50;">$totalItems</div>
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; color:#777;">Total Items</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:32px; font-weight:bold; color:#339933;">$($approvalRate)%</div>
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; color:#777;">Approval Rate</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:32px; font-weight:bold; color:#CC3333;">$($revocationRate)%</div>
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; color:#777;">Revocation Rate</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:32px; font-weight:bold; color:$completionColor;">$($completionPct)%</div>
        <div style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; color:#777;">Completion</div>
    </td>
</tr>
</table>
"@

    # --- Per-director table rows (sorted by completion % ascending = worst first) ---
    $directorRows = @()
    foreach ($dirId in $directors.Keys) {
        $d = $directors[$dirId]
        $directorRows += @{
            Id            = $dirId
            Name          = if ($null -ne $d.Name) { $d.Name } else { $dirId }
            TotalItems    = [int]$d.TotalItems
            Approved      = [int]$d.Approved
            Revoked       = [int]$d.Revoked
            Pending       = [int]$d.Pending
            CompletionPct = [double]$d.CompletionPct
            Managers      = $d.Managers
        }
    }
    $directorRows = @($directorRows | Sort-Object { $_.CompletionPct })

    $dirTableBody = ''
    $rowIndex = 0
    foreach ($dr in $directorRows) {
        $isAlt = ($rowIndex % 2 -eq 1)
        $rowBg = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }
        $tdStyle = 'style="padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px;"'

        # Color-code the completion cell
        $pctColor = if ($dr.CompletionPct -ge 95) { '#339933' } elseif ($dr.CompletionPct -ge 80) { '#FF8800' } else { '#CC3333' }
        $pctStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; font-weight:bold; color:$pctColor;"""

        # Calculate average response time across this director's managers
        $avgHoursDisplay = 'N/A'
        if ($null -ne $dr.Managers -and $dr.Managers.Count -gt 0) {
            $hoursValues = @()
            foreach ($mgrId in $dr.Managers.Keys) {
                $mgr = $dr.Managers[$mgrId]
                if ($null -ne $mgr.AvgHours) {
                    $hoursValues += [double]$mgr.AvgHours
                }
            }
            if ($hoursValues.Count -gt 0) {
                $avgHrs = ($hoursValues | Measure-Object -Average).Average
                $avgHoursDisplay = Format-HoursDisplay $avgHrs
            }
        }

        $safeName = ConvertTo-SafeHtml $dr.Name

        $dirTableBody += @"
<tr$rowBg>
    <td $tdStyle>$safeName</td>
    <td $tdStyle>$($dr.TotalItems)</td>
    <td ${tdStyle}>$($dr.Approved)</td>
    <td ${tdStyle}>$($dr.Revoked)</td>
    <td ${tdStyle}>$($dr.Pending)</td>
    <td $pctStyle>$($dr.CompletionPct)%</td>
    <td $tdStyle>$avgHoursDisplay</td>
</tr>
"@
        $rowIndex++
    }

    $thStyle = 'style="background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px;"'

    $directorTableHtml = @"
<h3 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;">$directorLevelLabel Summary</h3>
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<thead>
<tr>
    <th $thStyle>$directorLevelLabel</th>
    <th $thStyle>Total</th>
    <th $thStyle>Approved</th>
    <th $thStyle>Revoked</th>
    <th $thStyle>Pending</th>
    <th $thStyle>Completion %</th>
    <th $thStyle>Avg Response Time</th>
</tr>
</thead>
<tbody>
$dirTableBody
</tbody>
</table>
"@

    # --- Donut section with legend ---
    $donutSectionHtml = @"
<div style="background:#f8f9fa; border:1px solid #dee2e6; border-radius:8px; padding:24px 28px; margin:20px 0 28px 0; page-break-inside:avoid;">
<h3 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin:0 0 16px 0; font-size:16px; border-bottom:2px solid #336699; padding-bottom:6px;">Decision Distribution</h3>
<table style="width:100%; border-collapse:collapse;">
<tr>
<td style="width:50%; text-align:center; vertical-align:middle; padding:12px;">
    $donutSvg
    <table style="margin:12px auto 0 auto; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:12px; border-collapse:collapse;">
    <tr>
        <td style="padding:3px 6px;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="#339933"/></svg></td>
        <td style="padding:3px 6px; color:#555;">Approved: $totalApproved ($($approvalRate)%)</td>
    </tr>
    <tr>
        <td style="padding:3px 6px;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="#CC3333"/></svg></td>
        <td style="padding:3px 6px; color:#555;">Revoked: $totalRevoked ($($revocationRate)%)</td>
    </tr>
    <tr>
        <td style="padding:3px 6px;"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="#FF8800"/></svg></td>
        <td style="padding:3px 6px; color:#555;">Pending: $totalPending ($($pendingPct)%)</td>
    </tr>
    </table>
</td>
<td style="width:50%; vertical-align:middle; padding:12px;">
    $summaryCardsHtml
</td>
</tr>
</table>
</div>
"@

    # --- Executive rollup (top leaders) ---
    $execSectionHtml = ''
    if ($executive.Count -gt 0) {
        $execRows = ''
        $execIndex = 0
        foreach ($vpId in $executive.Keys) {
            $vp = $executive[$vpId]
            $isAlt    = ($execIndex % 2 -eq 1)
            $rowBg    = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }
            $vpName   = ConvertTo-SafeHtml $vp.Name
            $vpPct    = [double]$vp.CompletionPct
            $vpColor  = if ($vpPct -ge 95) { '#339933' } elseif ($vpPct -ge 80) { '#FF8800' } else { '#CC3333' }
            $vpPctStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; font-weight:bold; color:$vpColor;"""
            $dirCount = if ($null -ne $vp.Directors) { @($vp.Directors).Count } else { 0 }

            $execRows += @"
<tr$rowBg>
    <td $tdStyle>$vpName</td>
    <td $tdStyle>$dirCount</td>
    <td $tdStyle>$([int]$vp.TotalItems)</td>
    <td $tdStyle>$([int]$vp.Approved)</td>
    <td $tdStyle>$([int]$vp.Revoked)</td>
    <td $tdStyle>$([int]$vp.Pending)</td>
    <td $vpPctStyle>$($vpPct)%</td>
</tr>
"@
            $execIndex++
        }

        $execSectionHtml = @"
<h3 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;">Executive Rollup</h3>
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<thead>
<tr>
    <th $thStyle>Leader</th>
    <th $thStyle>${directorLevelLabel}s</th>
    <th $thStyle>Total</th>
    <th $thStyle>Approved</th>
    <th $thStyle>Revoked</th>
    <th $thStyle>Pending</th>
    <th $thStyle>Completion %</th>
</tr>
</thead>
<tbody>
$execRows
</tbody>
</table>
"@
    }

    # --- Footer ---
    $footerHtml = @"
<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit v$($script:AuditReportVersion) &nbsp;|&nbsp; Leadership Executive Summary &nbsp;|&nbsp; Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt)) &nbsp;|&nbsp; Correlation ID: $([System.Net.WebUtility]::HtmlEncode($CorrelationID))
</div>
"@

    # --- Assemble full HTML document ---
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Leadership Executive Summary - $safeCampaignName</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">
<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">

<h1 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; font-size:24px; margin-bottom:4px;">Leadership Executive Summary</h1>
<p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#555; font-size:14px; margin:0 0 4px 0;">$safeCampaignName</p>
$dateRangeHtml

$donutSectionHtml

$execSectionHtml

$directorTableHtml

$footerHtml

</div>
</body>
</html>
"@

    $filePath = Join-Path -Path $OutputPath -ChildPath 'executive-summary.html'
    $html | Set-Content -Path $filePath -Encoding UTF8

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message "Leadership executive summary written: $filePath" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPLeadershipExecutiveHtml' `
            -CorrelationID $CorrelationID
    }

    return $filePath
}


#endregion Leadership Executive Report

#region Leadership Director Reports

function Export-SPLeadershipDirectorHtml {
    <#
    .SYNOPSIS
        Generates per-director leadership HTML reports.
    .DESCRIPTION
        Produces one self-contained, Word-compatible HTML file per director. Each
        report includes:
        - Director name and campaign name header
        - Director-level metrics (total, approved, revoked, pending, completion %)
        - Per-manager summary table sorted by completion % ascending
        - Per-manager identity detail tables showing individual decisions
        - Navigation link back to executive-summary.html

        All CSS is inline on elements for Word copy-paste compatibility.
        No flexbox, no grid, no external resources.
    .PARAMETER LeadershipData
        Hashtable from Group-SPAuditByLeadership with Directors and Executive keys.
    .PARAMETER Decisions
        Hashtable from Group-SPAuditDecisions with Approved, Revoked, Pending arrays.
    .PARAMETER OrgTree
        Hashtable from Build-SPOrgTree .Data containing Nodes, TopLeaders, etc.
    .PARAMETER CampaignName
        Display name of the campaign (or combined campaign label).
    .PARAMETER DateRange
        Descriptive date range string for the report header.
    .PARAMETER OutputPath
        Directory in which to write the HTML files. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID embedded in each report footer.
    .OUTPUTS
        [string[]] Array of file paths written.
    .EXAMPLE
        $paths = Export-SPLeadershipDirectorHtml -LeadershipData $leadership `
                    -Decisions $grouped -OrgTree $tree.Data `
                    -CampaignName 'Q1 Access Review' -OutputPath 'C:\Reports\leadership'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$LeadershipData,

        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter(Mandatory)]
        [string]$CampaignName,

        [Parameter()]
        [string]$DateRange = '',

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [ValidateSet('Summary', 'Detailed', 'Verbose')]
        [string]$DetailLevel = 'Verbose'
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $directors   = if ($LeadershipData.ContainsKey('Directors')) { $LeadershipData['Directors'] } else { @{} }
    $nodes       = $OrgTree.Nodes

    # --- Build identity name -> leaf node ID -> manager ID lookup ---
    $nameToLeafId  = @{}
    $leafToManager = @{}
    foreach ($nodeId in $nodes.Keys) {
        $node = $nodes[$nodeId]
        if ($node.Level -eq 0) {
            if ($null -ne $node.Identity -and
                -not [string]::IsNullOrWhiteSpace($node.Identity.Name)) {
                $nameToLeafId[$node.Identity.Name] = $nodeId
            }
            $leafToManager[$nodeId] = $node.ManagerId
        }
    }

    # --- Build manager -> director lookup ---
    $managerToDirector = @{}
    foreach ($nodeId in $nodes.Keys) {
        $node = $nodes[$nodeId]
        if ($node.Level -eq 1) {
            $dirId = $node.ManagerId
            if (-not [string]::IsNullOrWhiteSpace($dirId) -and $nodes.ContainsKey($dirId)) {
                $managerToDirector[$nodeId] = $dirId
            } else {
                $managerToDirector[$nodeId] = ''
            }
        }
    }

    # --- Group decision items by director -> manager ---
    # Structure: directorId -> managerId -> [List of decision items]
    $dirMgrItems = @{}
    $unmanagedKey = '__unmanaged__'

    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
        $items = @()
        if ($Decisions.ContainsKey($category) -and $null -ne $Decisions[$category]) {
            $items = @($Decisions[$category])
        }

        foreach ($item in $items) {
            $identityName = if ($null -ne $item.IdentityName) { [string]$item.IdentityName } else { '' }

            $managerId  = $unmanagedKey
            $directorId = $unmanagedKey

            if (-not [string]::IsNullOrWhiteSpace($identityName) -and
                $nameToLeafId.ContainsKey($identityName)) {
                $leafId = $nameToLeafId[$identityName]

                if ($leafToManager.ContainsKey($leafId)) {
                    $mgr = $leafToManager[$leafId]
                    if (-not [string]::IsNullOrWhiteSpace($mgr) -and $nodes.ContainsKey($mgr)) {
                        $managerId = $mgr
                        if ($managerToDirector.ContainsKey($mgr) -and
                            -not [string]::IsNullOrWhiteSpace($managerToDirector[$mgr])) {
                            $directorId = $managerToDirector[$mgr]
                        }
                        # If manager is itself a director-level node (level >= 2)
                        if ($directorId -eq $unmanagedKey -and $nodes[$mgr].Level -ge 2) {
                            $directorId = $mgr
                        }
                    }
                }
            }

            if (-not $dirMgrItems.ContainsKey($directorId)) { $dirMgrItems[$directorId] = @{} }
            if (-not $dirMgrItems[$directorId].ContainsKey($managerId)) {
                $dirMgrItems[$directorId][$managerId] = [System.Collections.Generic.List[object]]::new()
            }

            # Carry forward RiskFlags from enriched decisions (if present)
            $dirItemRiskFlags = @()
            if ($null -ne $item.PSObject -and
                $null -ne $item.PSObject.Properties['RiskFlags'] -and
                $null -ne $item.RiskFlags) {
                $dirItemRiskFlags = @($item.RiskFlags)
            }

            $dirMgrItems[$directorId][$managerId].Add(@{
                IdentityName = $identityName
                AccountIdentifier = if ($null -ne $item.AccountIdentifier) { [string]$item.AccountIdentifier } else { '' }
                AccessName   = if ($null -ne $item.AccessName) { [string]$item.AccessName } else { '' }
                Decision     = $category
                ReviewerName = if ($null -ne $item.ReviewerName) { [string]$item.ReviewerName } else { '' }
                DecisionDate = if ($null -ne $item.DecisionDate) { [string]$item.DecisionDate } else { '' }
                RiskFlags    = $dirItemRiskFlags
            })
        }
    }

    # --- Style constants ---
    $fontFamily = "-apple-system,'Segoe UI',system-ui,sans-serif"
    $thStyle    = "style=""background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:$fontFamily; font-size:13px;"""
    $tdStyle    = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px;"""
    $safeCampaignName = ConvertTo-SafeHtml $CampaignName
    $safeDateRange    = ConvertTo-SafeHtml $DateRange

    # --- Generate one HTML file per director ---
    $outputPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($dirId in $directors.Keys) {
        $d = $directors[$dirId]
        $dirName = if ($null -ne $d.Name) { $d.Name } else { $dirId }

        # Sanitize name for filename: keep only alphanumeric, hyphen, underscore
        $safeName = ($dirName -replace '[^a-zA-Z0-9_-]', '').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $dirId -replace '[^a-zA-Z0-9_-]', '' }

        $safeDirName = ConvertTo-SafeHtml $dirName

        # --- Director-level metrics ---
        $totalItems    = [int]$d.TotalItems
        $totalApproved = [int]$d.Approved
        $totalRevoked  = [int]$d.Revoked
        $totalPending  = [int]$d.Pending
        $completionPct = [double]$d.CompletionPct

        $approvalRate   = if ($totalItems -gt 0) { [Math]::Round($totalApproved / $totalItems * 100, 1) } else { 0.0 }
        $revocationRate = if ($totalItems -gt 0) { [Math]::Round($totalRevoked  / $totalItems * 100, 1) } else { 0.0 }

        $completionColor = if ($completionPct -ge 95) { '#339933' } elseif ($completionPct -ge 80) { '#FF8800' } else { '#CC3333' }

        $dateRangeHtml = if (-not [string]::IsNullOrWhiteSpace($DateRange)) {
            "<p style=""font-family:$fontFamily; color:#777777; font-size:13px; margin:0 0 20px 0;"">$safeDateRange</p>"
        } else { '' }

        # --- Summary cards ---
        $summaryCardsHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<tr>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:#2c3e50;">$totalItems</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Total Items</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:#339933;">$($approvalRate)%</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Approval Rate</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:#CC3333;">$($revocationRate)%</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Revocation Rate</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:$completionColor;">$($completionPct)%</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Completion</div>
    </td>
</tr>
</table>
"@

        # --- Per-manager summary table ---
        $managerRows = @()
        $managersMap = if ($null -ne $d.Managers) { $d.Managers } else { @{} }

        foreach ($mgrId in $managersMap.Keys) {
            $mgr = $managersMap[$mgrId]
            $mgrApproved = [int]$mgr.Approved
            $mgrRevoked  = [int]$mgr.Revoked
            $mgrPending  = [int]$mgr.Pending
            $mgrTotal    = $mgrApproved + $mgrRevoked + $mgrPending
            $mgrPct      = if ($mgrTotal -gt 0) { [Math]::Round(($mgrApproved + $mgrRevoked) / $mgrTotal * 100, 1) } else { 0.0 }

            $managerRows += @{
                Id            = $mgrId
                Name          = if ($null -ne $mgr.Name) { $mgr.Name } else { $mgrId }
                TotalItems    = $mgrTotal
                Approved      = $mgrApproved
                Revoked       = $mgrRevoked
                Pending       = $mgrPending
                CompletionPct = $mgrPct
                AvgHours      = $mgr.AvgHours
            }
        }
        $managerRows = @($managerRows | Sort-Object { $_.CompletionPct })

        $mgrTableBody = ''
        $mgrIndex = 0
        foreach ($mr in $managerRows) {
            $isAlt = ($mgrIndex % 2 -eq 1)
            $rowBg = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }

            $mgrPctColor = if ($mr.CompletionPct -ge 95) { '#339933' } elseif ($mr.CompletionPct -ge 80) { '#FF8800' } else { '#CC3333' }
            $pctCellStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px; font-weight:bold; color:$mgrPctColor;"""
            $avgHoursDisplay = Format-HoursDisplay $mr.AvgHours
            $safeMgrName = ConvertTo-SafeHtml $mr.Name

            $mgrTableBody += @"
<tr$rowBg>
    <td $tdStyle>$safeMgrName</td>
    <td $tdStyle>$($mr.TotalItems)</td>
    <td $tdStyle>$($mr.Approved)</td>
    <td $tdStyle>$($mr.Revoked)</td>
    <td $tdStyle>$($mr.Pending)</td>
    <td $pctCellStyle>$($mr.CompletionPct)%</td>
    <td $tdStyle>$avgHoursDisplay</td>
</tr>
"@
            $mgrIndex++
        }

        $managerTableHtml = @"
<h3 style="font-family:$fontFamily; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;">Manager Summary</h3>
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<thead>
<tr>
    <th $thStyle>Manager</th>
    <th $thStyle>Total</th>
    <th $thStyle>Approved</th>
    <th $thStyle>Revoked</th>
    <th $thStyle>Pending</th>
    <th $thStyle>Completion %</th>
    <th $thStyle>Avg Response Time</th>
</tr>
</thead>
<tbody>
$mgrTableBody
</tbody>
</table>
"@

        # --- Per-manager identity detail sections (skipped in Summary mode) ---
        $detailSectionsHtml = ''
        if ($DetailLevel -ne 'Summary') {
            $mgrItemsForDir = if ($dirMgrItems.ContainsKey($dirId)) { $dirMgrItems[$dirId] } else { @{} }

            foreach ($mr in $managerRows) {
                $mgrId   = $mr.Id
                $mgrName = $mr.Name
                $safeMgrDetailName = ConvertTo-SafeHtml $mgrName

                $itemList = @()
                if ($mgrItemsForDir.ContainsKey($mgrId)) {
                    $itemList = @($mgrItemsForDir[$mgrId])
                }

                # Sort items: Pending first, then Revoked, then Approved (attention-worthy first)
                $sortOrder = @{ 'Pending' = 0; 'Revoked' = 1; 'Approved' = 2 }
                $itemList = @($itemList | Sort-Object {
                    $so = $sortOrder[$_.Decision]
                    if ($null -eq $so) { 3 } else { $so }
                }, { $_.IdentityName })

                $detailRows = ''
                $detailIndex = 0
                foreach ($di in $itemList) {
                    $isAlt = ($detailIndex % 2 -eq 1)
                    $rowBg = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }

                    $decisionColor = switch ($di.Decision) {
                        'Approved' { '#339933' }
                        'Revoked'  { '#CC3333' }
                        'Pending'  { '#FF8800' }
                        default    { '#333333' }
                    }
                    $decisionCellStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px; font-weight:bold; color:$decisionColor;"""

                    $diRiskBadges = ''
                    $diRiskFlags = if ($di -is [hashtable] -and $di.ContainsKey('RiskFlags')) { @($di['RiskFlags']) }
                                   elseif ($null -ne $di.PSObject -and $null -ne $di.PSObject.Properties['RiskFlags']) { @($di.RiskFlags) }
                                   else { @() }
                    if ($diRiskFlags.Count -gt 0) {
                        $diRiskBadges = Format-RiskFlagBadges -Flags $diRiskFlags
                    }

                    $safeIdentity = (ConvertTo-SafeHtml $di.IdentityName) + $diRiskBadges
                    $safeAccount  = ConvertTo-SafeHtml $di.AccountIdentifier
                    $safeAccess   = ConvertTo-SafeHtml $di.AccessName
                    $safeReviewer = ConvertTo-SafeHtml $di.ReviewerName
                    $safeDate     = Format-HtmlDate $di.DecisionDate

                    $detailRows += @"
<tr$rowBg>
    <td $tdStyle>$safeIdentity</td>
    <td $tdStyle>$safeAccount</td>
    <td $tdStyle>$safeAccess</td>
    <td $decisionCellStyle>$($di.Decision)</td>
    <td $tdStyle>$safeReviewer</td>
    <td $tdStyle>$safeDate</td>
</tr>
"@
                    $detailIndex++
                }

                $itemCountLabel = "$($itemList.Count) item"
                if ($itemList.Count -ne 1) { $itemCountLabel += 's' }

                # Wrap in <details>/<summary> for Detailed/Verbose modes
                $dirHasRevocations = @($itemList | Where-Object { $_.Decision -eq 'Revoked' }).Count -gt 0
                $dirMgrOpenAttr = if ($DetailLevel -eq 'Verbose' -or $dirHasRevocations) { ' open' } else { '' }

                $detailSectionsHtml += @"
<details$dirMgrOpenAttr>
<summary style="font-family:$fontFamily; color:#2c3e50; font-size:14px; margin-top:24px; margin-bottom:8px; padding-bottom:4px; border-bottom:1px solid #dee2e6; cursor:pointer;">$safeMgrDetailName <span style="font-weight:normal; color:#777; font-size:12px;">($itemCountLabel)</span></summary>
<div style="page-break-inside:avoid;">
<table style="width:100%; border-collapse:collapse; margin-bottom:16px;">
<thead>
<tr>
    <th $thStyle>Identity</th>
    <th $thStyle>Account (UPN)</th>
    <th $thStyle>Access</th>
    <th $thStyle>Decision</th>
    <th $thStyle>Reviewer</th>
    <th $thStyle>Date</th>
</tr>
</thead>
<tbody>
$detailRows
</tbody>
</table>
</div>
</details>
"@
            }
        }

        # --- Navigation link ---
        $navHtml = @"
<p style="margin-bottom:20px;"><a href="executive-summary.html" style="font-family:$fontFamily; font-size:13px; color:#336699; text-decoration:none;">&larr; Back to Executive Summary</a></p>
"@

        # --- Footer ---
        $footerHtml = @"
<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:$fontFamily; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit v$($script:AuditReportVersion) &nbsp;|&nbsp; Director Report: $safeDirName &nbsp;|&nbsp; Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt)) &nbsp;|&nbsp; Correlation ID: $([System.Net.WebUtility]::HtmlEncode($CorrelationID))
</div>
"@

        # --- Assemble full HTML document ---
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Director Report: $safeDirName - $safeCampaignName</title>
</head>
<body style="font-family:$fontFamily; margin:0; padding:24px; background:#f0f2f5; color:#333;">
<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">

$navHtml

<h1 style="font-family:$fontFamily; color:#2c3e50; font-size:24px; margin-bottom:4px;">Director Report: $safeDirName</h1>
<p style="font-family:$fontFamily; color:#555; font-size:14px; margin:0 0 4px 0;">$safeCampaignName</p>
$dateRangeHtml

$summaryCardsHtml

$managerTableHtml

$(if (-not [string]::IsNullOrWhiteSpace($detailSectionsHtml)) {
"<h3 style=""font-family:$fontFamily; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;"">Identity Decision Detail</h3>
$detailSectionsHtml"
})

$footerHtml

</div>
</body>
</html>
"@

        $fileName = "director-$safeName.html"
        $filePath = Join-Path -Path $OutputPath -ChildPath $fileName
        $html | Set-Content -Path $filePath -Encoding UTF8

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Director report written: $filePath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPLeadershipDirectorHtml' `
                -CorrelationID $CorrelationID
        }

        $outputPaths.Add($filePath)
    }

    return @($outputPaths.ToArray())
}


#endregion Leadership Director Reports

#region Leadership Level Reports

function Export-SPLeadershipLevelHtml {
    <#
    .SYNOPSIS
        Generates per-level leadership HTML reports dynamically for any org level.
    .DESCRIPTION
        Unified report generator that replaces the fixed executive/director approach.
        Produces one HTML file per leader at a given org level. Each report includes:
        - Level-appropriate header (e.g., "VP Report: Alice Johnson")
        - Summary cards: total items, approval rate, revocation rate, completion %
        - Subordinate table: next-level-down leaders with aggregate metrics
        - Navigation links: up to parent report, down to child reports
        - Identity decision detail at the lowest generated level

        All CSS is inline on elements for Word copy-paste compatibility.
        No flexbox, no grid, no external resources.
    .PARAMETER LeadershipData
        Hashtable from Group-SPAuditByLeadership with Levels and TopLevel keys.
    .PARAMETER Decisions
        Hashtable from Group-SPAuditDecisions with Approved, Revoked, Pending arrays.
    .PARAMETER OrgTree
        Hashtable from Build-SPOrgTree .Data containing Nodes, LevelLabels, etc.
    .PARAMETER Level
        The org level to generate reports for. Each leader at this level gets a report.
    .PARAMETER StartLevel
        The highest level being generated (controls executive summary logic).
    .PARAMETER LowestLevel
        The lowest level being generated (controls per-identity detail inclusion).
    .PARAMETER CampaignName
        Display name of the campaign (or combined campaign label).
    .PARAMETER DateRange
        Descriptive date range string for the report header.
    .PARAMETER OutputPath
        Directory in which to write the HTML files. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID embedded in each report footer.
    .OUTPUTS
        [string[]] Array of file paths written.
    .EXAMPLE
        $paths = Export-SPLeadershipLevelHtml -LeadershipData $leadership `
                    -Decisions $grouped -OrgTree $tree.Data -Level 3 `
                    -StartLevel 4 -LowestLevel 2 `
                    -CampaignName 'Q1 Review' -OutputPath 'C:\Reports\leadership'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$LeadershipData,

        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter(Mandatory)]
        [int]$Level,

        [Parameter(Mandatory)]
        [int]$StartLevel,

        [Parameter(Mandatory)]
        [int]$LowestLevel,

        [Parameter(Mandatory)]
        [string]$CampaignName,

        [Parameter()]
        [string]$DateRange = '',

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [ValidateSet('Summary', 'Detailed', 'Verbose')]
        [string]$DetailLevel = 'Verbose',

        [Parameter()]
        [hashtable]$BandData
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $nodes       = $OrgTree.Nodes
    $levels      = if ($LeadershipData.ContainsKey('Levels')) { $LeadershipData['Levels'] } else { @{} }

    # Determine level labels
    $levelLabels = if ($OrgTree.ContainsKey('LevelLabels')) { $OrgTree.LevelLabels } else {
        @{ 0 = 'Individual Contributors'; 1 = 'Managers'; 2 = 'Directors';
           3 = 'Vice Presidents'; 4 = 'Senior Vice Presidents'; 5 = 'Executive Leadership' }
    }

    $thisLevelLabel = if ($levelLabels.ContainsKey($Level)) { $levelLabels[$Level] } else { "Level $Level Leaders" }
    $lowerLevelLabel = if ($levelLabels.ContainsKey($Level - 1)) { $levelLabels[$Level - 1] } else { "Level $($Level - 1)" }

    # Get leaders at this level
    if (-not $levels.ContainsKey($Level)) {
        return @()
    }
    $thisLevelData = $levels[$Level]
    $leaders = $thisLevelData.Leaders
    if ($null -eq $leaders -or $leaders.Count -eq 0) {
        return @()
    }

    # Get lower-level leaders for subordinate detail
    $lowerLeaders = $null
    if ($levels.ContainsKey($Level - 1)) {
        $lowerLeaders = $levels[$Level - 1].Leaders
    }

    # Style constants
    $fontFamily = "-apple-system,'Segoe UI',system-ui,sans-serif"
    $thStyle    = "style=""background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:$fontFamily; font-size:13px;"""
    $tdStyle    = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px;"""
    $safeCampaignName = ConvertTo-SafeHtml $CampaignName
    $safeDateRange    = ConvertTo-SafeHtml $DateRange

    # File prefix from level label (lowercase, no spaces)
    $filePrefix = ($thisLevelLabel -replace '\s+', '-').ToLower()
    # Singular form for file naming (remove trailing 's' if present)
    $filePrefixSingular = if ($filePrefix.EndsWith('s') -and -not $filePrefix.EndsWith('ss')) {
        $filePrefix.Substring(0, $filePrefix.Length - 1)
    } else { $filePrefix }

    # Determine if this is the top generated level (executive summary)
    $isTopLevel = ($Level -eq $StartLevel)
    # Determine if this is the lowest generated level (include identity detail)
    $isLowestLevel = ($Level -eq $LowestLevel)

    # Build identity-to-manager lookup for detail tables (only at lowest level)
    $nameToLeafId  = @{}
    $leafToManager = @{}
    $managerToParent = @{}
    if ($isLowestLevel) {
        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            if ($node.Level -eq 0) {
                if ($null -ne $node.Identity -and
                    -not [string]::IsNullOrWhiteSpace($node.Identity.Name)) {
                    $nameToLeafId[$node.Identity.Name] = $nodeId
                }
                $leafToManager[$nodeId] = $node.ManagerId
            }
        }

        # Build chain from manager to this level's leaders
        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            if ($node.Level -ge 1 -and $node.Level -lt $Level) {
                $managerToParent[$nodeId] = $node.ManagerId
            }
        }
    }

    # --- Generate one HTML file per leader ---
    $outputPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($leaderId in $leaders.Keys) {
        if ($leaderId -eq '__unmanaged__') { continue }

        $leaderData = $leaders[$leaderId]
        $leaderName = if ($null -ne $leaderData.Name) { $leaderData.Name } else { $leaderId }

        # Sanitize name for filename
        $safeName = ($leaderName -replace '[^a-zA-Z0-9_-]', '').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $leaderId -replace '[^a-zA-Z0-9_-]', '' }

        $safeLeaderName = ConvertTo-SafeHtml $leaderName

        # --- Leader-level metrics ---
        $totalItems    = [int]$leaderData.TotalItems
        $totalApproved = [int]$leaderData.Approved
        $totalRevoked  = [int]$leaderData.Revoked
        $totalPending  = [int]$leaderData.Pending
        $completionPct = [double]$leaderData.CompletionPct

        $approvalRate   = if ($totalItems -gt 0) { [Math]::Round($totalApproved / $totalItems * 100, 1) } else { 0.0 }
        $revocationRate = if ($totalItems -gt 0) { [Math]::Round($totalRevoked  / $totalItems * 100, 1) } else { 0.0 }

        $completionColor = if ($completionPct -ge 95) { '#339933' } elseif ($completionPct -ge 80) { '#FF8800' } else { '#CC3333' }

        $dateRangeHtml = if (-not [string]::IsNullOrWhiteSpace($DateRange)) {
            "<p style=""font-family:$fontFamily; color:#777777; font-size:13px; margin:0 0 20px 0;"">$safeDateRange</p>"
        } else { '' }

        # --- Summary cards ---
        $summaryCardsHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<tr>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:#2c3e50;">$totalItems</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Total Items</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:#339933;">$($approvalRate)%</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Approval Rate</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:#CC3333;">$($revocationRate)%</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Revocation Rate</div>
    </td>
    <td style="width:25%; text-align:center; padding:16px 8px; vertical-align:top;">
        <div style="font-family:$fontFamily; font-size:32px; font-weight:bold; color:$completionColor;">$($completionPct)%</div>
        <div style="font-family:$fontFamily; font-size:12px; color:#777;">Completion</div>
    </td>
</tr>
</table>
"@

        # --- Subordinate table (next-level-down leaders under this leader) ---
        $subordinateTableHtml = ''
        $subordinateIds = @()
        if ($null -ne $leaderData.Subordinates) {
            $subordinateIds = @($leaderData.Subordinates)
        }
        elseif ($null -ne $leaderData.Managers) {
            # Level 2 (Directors) have Managers directly
            $subordinateIds = @($leaderData.Managers.Keys | Where-Object { $_ -ne '__unmanaged__' })
        }

        if ($subordinateIds.Count -gt 0 -and $null -ne $lowerLeaders) {
            $subRows = @()
            foreach ($subId in $subordinateIds) {
                if ($null -eq $lowerLeaders -or -not $lowerLeaders.ContainsKey($subId)) { continue }
                $sub = $lowerLeaders[$subId]
                $subTotal    = [int]$sub.TotalItems
                $subApproved = [int]$sub.Approved
                $subRevoked  = [int]$sub.Revoked
                $subPending  = [int]$sub.Pending
                $subPct      = [double]$sub.CompletionPct

                $subRows += @{
                    Id            = $subId
                    Name          = if ($null -ne $sub.Name) { $sub.Name } else { $subId }
                    TotalItems    = $subTotal
                    Approved      = $subApproved
                    Revoked       = $subRevoked
                    Pending       = $subPending
                    CompletionPct = $subPct
                }
            }
            $subRows = @($subRows | Sort-Object { $_.CompletionPct })

            if ($subRows.Count -gt 0) {
                $subTableBody = ''
                $subIndex = 0

                # Determine lower-level file prefix for links
                $lowerFilePrefix = ($lowerLevelLabel -replace '\s+', '-').ToLower()
                $lowerFilePrefixSingular = if ($lowerFilePrefix.EndsWith('s') -and -not $lowerFilePrefix.EndsWith('ss')) {
                    $lowerFilePrefix.Substring(0, $lowerFilePrefix.Length - 1)
                } else { $lowerFilePrefix }

                foreach ($sr in $subRows) {
                    $isAlt = ($subIndex % 2 -eq 1)
                    $rowBg = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }

                    $subPctColor = if ($sr.CompletionPct -ge 95) { '#339933' } elseif ($sr.CompletionPct -ge 80) { '#FF8800' } else { '#CC3333' }
                    $pctCellStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px; font-weight:bold; color:$subPctColor;"""

                    $safeSubName = ConvertTo-SafeHtml $sr.Name

                    # Generate link to subordinate report (only if not at lowest generated level)
                    $subFileName = ($sr.Name -replace '[^a-zA-Z0-9_-]', '').Trim()
                    if ([string]::IsNullOrWhiteSpace($subFileName)) { $subFileName = $sr.Id -replace '[^a-zA-Z0-9_-]', '' }
                    $subLink = "$lowerFilePrefixSingular-$subFileName.html"

                    $nameCell = if (($Level - 1) -ge $LowestLevel) {
                        "<a href=""$subLink"" style=""color:#336699; text-decoration:none;"">$safeSubName</a>"
                    } else { $safeSubName }

                    $subTableBody += @"
<tr$rowBg>
    <td $tdStyle>$nameCell</td>
    <td $tdStyle>$($sr.TotalItems)</td>
    <td $tdStyle>$($sr.Approved)</td>
    <td $tdStyle>$($sr.Revoked)</td>
    <td $tdStyle>$($sr.Pending)</td>
    <td $pctCellStyle>$($sr.CompletionPct)%</td>
</tr>
"@
                    $subIndex++
                }

                $subordinateTableHtml = @"
<h3 style="font-family:$fontFamily; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;">$([System.Net.WebUtility]::HtmlEncode($lowerLevelLabel)) Summary</h3>
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<thead>
<tr>
    <th $thStyle>$([System.Net.WebUtility]::HtmlEncode([string]($lowerLevelLabel -replace 's$', '')))</th>
    <th $thStyle>Total</th>
    <th $thStyle>Approved</th>
    <th $thStyle>Revoked</th>
    <th $thStyle>Pending</th>
    <th $thStyle>Completion %</th>
</tr>
</thead>
<tbody>
$subTableBody
</tbody>
</table>
"@
            }
        }
        elseif ($null -ne $leaderData.Managers -and $leaderData.Managers.Count -gt 0) {
            # This is a Level 2 leader (Directors level) with direct manager data
            $mgrRows = @()
            foreach ($mgrId in $leaderData.Managers.Keys) {
                if ($mgrId -eq '__unmanaged__') { continue }
                $mgr = $leaderData.Managers[$mgrId]
                $mgrApproved = [int]$mgr.Approved
                $mgrRevoked  = [int]$mgr.Revoked
                $mgrPending  = [int]$mgr.Pending
                $mgrTotal    = $mgrApproved + $mgrRevoked + $mgrPending
                $mgrPct      = if ($mgrTotal -gt 0) { [Math]::Round(($mgrApproved + $mgrRevoked) / $mgrTotal * 100, 1) } else { 0.0 }

                $mgrRows += @{
                    Id            = $mgrId
                    Name          = if ($null -ne $mgr.Name) { $mgr.Name } else { $mgrId }
                    TotalItems    = $mgrTotal
                    Approved      = $mgrApproved
                    Revoked       = $mgrRevoked
                    Pending       = $mgrPending
                    CompletionPct = $mgrPct
                    AvgHours      = $mgr.AvgHours
                }
            }
            $mgrRows = @($mgrRows | Sort-Object { $_.CompletionPct })

            if ($mgrRows.Count -gt 0) {
                $mgrTableBody = ''
                $mgrIndex = 0
                foreach ($mr in $mgrRows) {
                    $isAlt = ($mgrIndex % 2 -eq 1)
                    $rowBg = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }

                    $mgrPctColor = if ($mr.CompletionPct -ge 95) { '#339933' } elseif ($mr.CompletionPct -ge 80) { '#FF8800' } else { '#CC3333' }
                    $pctCellStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px; font-weight:bold; color:$mgrPctColor;"""
                    $avgHoursDisplay = Format-HoursDisplay $mr.AvgHours
                    $safeMgrName = ConvertTo-SafeHtml $mr.Name

                    $mgrTableBody += @"
<tr$rowBg>
    <td $tdStyle>$safeMgrName</td>
    <td $tdStyle>$($mr.TotalItems)</td>
    <td $tdStyle>$($mr.Approved)</td>
    <td $tdStyle>$($mr.Revoked)</td>
    <td $tdStyle>$($mr.Pending)</td>
    <td $pctCellStyle>$($mr.CompletionPct)%</td>
    <td $tdStyle>$avgHoursDisplay</td>
</tr>
"@
                    $mgrIndex++
                }

                $subordinateTableHtml = @"
<h3 style="font-family:$fontFamily; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;">Manager Summary</h3>
<table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
<thead>
<tr>
    <th $thStyle>Manager</th>
    <th $thStyle>Total</th>
    <th $thStyle>Approved</th>
    <th $thStyle>Revoked</th>
    <th $thStyle>Pending</th>
    <th $thStyle>Completion %</th>
    <th $thStyle>Avg Response Time</th>
</tr>
</thead>
<tbody>
$mgrTableBody
</tbody>
</table>
"@
            }
        }

        # --- Per-identity decision detail (only at lowest generated level, not in Summary mode) ---
        $detailSectionsHtml = ''
        if ($DetailLevel -ne 'Summary' -and $isLowestLevel -and $null -ne $leaderData.Managers -and $leaderData.Managers.Count -gt 0) {
            # Build decision items grouped by manager under this leader
            $mgrItemsForLeader = @{}

            foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                $items = @()
                if ($Decisions.ContainsKey($category) -and $null -ne $Decisions[$category]) {
                    $items = @($Decisions[$category])
                }

                foreach ($item in $items) {
                    $identityName = if ($null -ne $item.IdentityName) { [string]$item.IdentityName } else { '' }

                    if ([string]::IsNullOrWhiteSpace($identityName) -or
                        -not $nameToLeafId.ContainsKey($identityName)) { continue }

                    $leafId = $nameToLeafId[$identityName]
                    if (-not $leafToManager.ContainsKey($leafId)) { continue }
                    $mgrId = $leafToManager[$leafId]
                    if ([string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)) { continue }

                    # Walk up from manager to find if this leader owns it
                    $currentId = $mgrId
                    $belongsToLeader = $false
                    for ($walk = 0; $walk -lt 10; $walk++) {
                        if (-not $nodes.ContainsKey($currentId)) { break }
                        $currentNode = $nodes[$currentId]
                        if ($currentNode.Level -eq $Level -and $currentId -eq $leaderId) {
                            $belongsToLeader = $true
                            break
                        }
                        if ($currentNode.Level -ge $Level) { break }
                        $parentId = $currentNode.ManagerId
                        if ([string]::IsNullOrWhiteSpace($parentId)) { break }
                        $currentId = $parentId
                    }

                    if (-not $belongsToLeader) { continue }

                    if (-not $mgrItemsForLeader.ContainsKey($mgrId)) {
                        $mgrItemsForLeader[$mgrId] = [System.Collections.Generic.List[object]]::new()
                    }

                    # Carry forward RiskFlags from enriched decisions (if present)
                    $itemRiskFlags = @()
                    if ($null -ne $item.PSObject -and
                        $null -ne $item.PSObject.Properties['RiskFlags'] -and
                        $null -ne $item.RiskFlags) {
                        $itemRiskFlags = @($item.RiskFlags)
                    }

                    $mgrItemsForLeader[$mgrId].Add(@{
                        IdentityName      = $identityName
                        AccountIdentifier = if ($null -ne $item.AccountIdentifier) { [string]$item.AccountIdentifier } else { '' }
                        AccessName        = if ($null -ne $item.AccessName) { [string]$item.AccessName } else { '' }
                        Decision          = $category
                        ReviewerName      = if ($null -ne $item.ReviewerName) { [string]$item.ReviewerName } else { '' }
                        DecisionDate      = if ($null -ne $item.DecisionDate) { [string]$item.DecisionDate } else { '' }
                        RiskFlags         = $itemRiskFlags
                    })
                }
            }

            # Render detail per manager
            $managersMap = $leaderData.Managers
            $mgrDetailRows = @()
            foreach ($mgrId in $managersMap.Keys) {
                if ($mgrId -eq '__unmanaged__') { continue }
                $mgr = $managersMap[$mgrId]
                $mgrDetailRows += @{
                    Id   = $mgrId
                    Name = if ($null -ne $mgr.Name) { $mgr.Name } else { $mgrId }
                }
            }

            foreach ($mr in $mgrDetailRows) {
                $mgrId   = $mr.Id
                $mgrName = $mr.Name
                $safeMgrDetailName = ConvertTo-SafeHtml $mgrName

                $itemList = @()
                if ($mgrItemsForLeader.ContainsKey($mgrId)) {
                    $itemList = @($mgrItemsForLeader[$mgrId])
                }

                # Sort items: Pending first, then Revoked, then Approved
                $sortOrder = @{ 'Pending' = 0; 'Revoked' = 1; 'Approved' = 2 }
                $itemList = @($itemList | Sort-Object {
                    $so = $sortOrder[$_.Decision]
                    if ($null -eq $so) { 3 } else { $so }
                }, { $_.IdentityName })

                if ($itemList.Count -eq 0) { continue }

                $detailRows = ''
                $detailIndex = 0
                foreach ($di in $itemList) {
                    $isAlt = ($detailIndex % 2 -eq 1)
                    $rowBg = if ($isAlt) { ' style="background:#f9f9f9;"' } else { '' }

                    $decisionColor = switch ($di.Decision) {
                        'Approved' { '#339933' }
                        'Revoked'  { '#CC3333' }
                        'Pending'  { '#FF8800' }
                        default    { '#333333' }
                    }
                    $decisionCellStyle = "style=""padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-family:$fontFamily; font-size:13px; font-weight:bold; color:$decisionColor;"""

                    $diRiskBadges = ''
                    $diRiskFlags = if ($di -is [hashtable] -and $di.ContainsKey('RiskFlags')) { @($di['RiskFlags']) }
                                   elseif ($null -ne $di.PSObject -and $null -ne $di.PSObject.Properties['RiskFlags']) { @($di.RiskFlags) }
                                   else { @() }
                    if ($diRiskFlags.Count -gt 0) {
                        $diRiskBadges = Format-RiskFlagBadges -Flags $diRiskFlags
                    }

                    $safeIdentity = (ConvertTo-SafeHtml $di.IdentityName) + $diRiskBadges
                    $safeAccount  = ConvertTo-SafeHtml $di.AccountIdentifier
                    $safeAccess   = ConvertTo-SafeHtml $di.AccessName
                    $safeReviewer = ConvertTo-SafeHtml $di.ReviewerName
                    $safeDate     = Format-HtmlDate $di.DecisionDate

                    $detailRows += @"
<tr$rowBg>
    <td $tdStyle>$safeIdentity</td>
    <td $tdStyle>$safeAccount</td>
    <td $tdStyle>$safeAccess</td>
    <td $decisionCellStyle>$($di.Decision)</td>
    <td $tdStyle>$safeReviewer</td>
    <td $tdStyle>$safeDate</td>
</tr>
"@
                    $detailIndex++
                }

                $itemCountLabel = "$($itemList.Count) item"
                if ($itemList.Count -ne 1) { $itemCountLabel += 's' }

                # Determine <details> open attribute: Detailed = collapsed (except revocations), Verbose = all open
                $hasRevocations = @($itemList | Where-Object { $_.Decision -eq 'Revoked' }).Count -gt 0
                $mgrOpenAttr = if ($DetailLevel -eq 'Verbose' -or $hasRevocations) { ' open' } else { '' }

                $detailSectionsHtml += @"
<details$mgrOpenAttr>
<summary style="font-family:$fontFamily; color:#2c3e50; font-size:14px; margin-top:24px; margin-bottom:8px; padding-bottom:4px; border-bottom:1px solid #dee2e6; cursor:pointer;">$safeMgrDetailName <span style="font-weight:normal; color:#777; font-size:12px;">($itemCountLabel)</span></summary>
<div style="page-break-inside:avoid;">
<table style="width:100%; border-collapse:collapse; margin-bottom:16px;">
<thead>
<tr>
    <th $thStyle>Identity</th>
    <th $thStyle>Account (UPN)</th>
    <th $thStyle>Access</th>
    <th $thStyle>Decision</th>
    <th $thStyle>Reviewer</th>
    <th $thStyle>Date</th>
</tr>
</thead>
<tbody>
$detailRows
</tbody>
</table>
</div>
</details>
"@
            }

            if (-not [string]::IsNullOrWhiteSpace($detailSectionsHtml)) {
                $detailSectionsHtml = @"
<h3 style="font-family:$fontFamily; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:28px; margin-bottom:12px; font-size:16px;">Identity Decision Detail</h3>
$detailSectionsHtml
"@
            }
        }

        # --- Navigation links ---
        $navHtml = ''
        if (-not $isTopLevel) {
            # Link up to parent report
            $parentLevel = $Level + 1
            if ($nodes.ContainsKey($leaderId)) {
                $parentId = $nodes[$leaderId].ManagerId
                if (-not [string]::IsNullOrWhiteSpace($parentId) -and $nodes.ContainsKey($parentId)) {
                    $parentName = if ($null -ne $nodes[$parentId].Identity -and
                        -not [string]::IsNullOrWhiteSpace($nodes[$parentId].Identity.Name)) {
                        $nodes[$parentId].Identity.Name
                    } else { $parentId }
                    $parentSafeName = ($parentName -replace '[^a-zA-Z0-9_-]', '').Trim()
                    if ([string]::IsNullOrWhiteSpace($parentSafeName)) { $parentSafeName = $parentId -replace '[^a-zA-Z0-9_-]', '' }

                    $parentLevelLabel = if ($levelLabels.ContainsKey($parentLevel)) { $levelLabels[$parentLevel] } else { "Level $parentLevel" }
                    $parentFilePrefix = ($parentLevelLabel -replace '\s+', '-').ToLower()
                    $parentFilePrefixSingular = if ($parentFilePrefix.EndsWith('s') -and -not $parentFilePrefix.EndsWith('ss')) {
                        $parentFilePrefix.Substring(0, $parentFilePrefix.Length - 1)
                    } else { $parentFilePrefix }

                    # If parent is at StartLevel, link to executive-summary.html
                    if ($parentLevel -eq $StartLevel) {
                        $navHtml = "<p style=""margin-bottom:20px;""><a href=""executive-summary.html"" style=""font-family:$fontFamily; font-size:13px; color:#336699; text-decoration:none;"">&larr; Back to Executive Summary</a></p>"
                    } else {
                        $parentFile = "$parentFilePrefixSingular-$parentSafeName.html"
                        $navHtml = "<p style=""margin-bottom:20px;""><a href=""$parentFile"" style=""font-family:$fontFamily; font-size:13px; color:#336699; text-decoration:none;"">&larr; Back to $([System.Net.WebUtility]::HtmlEncode($parentName))</a></p>"
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($navHtml)) {
                $navHtml = "<p style=""margin-bottom:20px;""><a href=""executive-summary.html"" style=""font-family:$fontFamily; font-size:13px; color:#336699; text-decoration:none;"">&larr; Back to Executive Summary</a></p>"
            }
        }

        # --- Title (with optional band designation from BandData) ---
        $bandSuffix = ''
        if ($null -ne $BandData -and $null -ne $BandData.Bands -and
            $BandData.Bands.ContainsKey($leaderId)) {
            $bandSuffix = " (Band $($BandData.Bands[$leaderId]))"
        }

        $reportTitle = if ($isTopLevel) {
            "Executive Summary$bandSuffix"
        } else {
            "$($thisLevelLabel -replace 's$', '') Report${bandSuffix}: $safeLeaderName"
        }

        # --- Footer ---
        $footerHtml = @"
<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:$fontFamily; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit v$($script:AuditReportVersion) &nbsp;|&nbsp; $([System.Net.WebUtility]::HtmlEncode($reportTitle)) &nbsp;|&nbsp; Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt)) &nbsp;|&nbsp; Correlation ID: $([System.Net.WebUtility]::HtmlEncode($CorrelationID))
</div>
"@

        # --- Assemble full HTML document ---
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$([System.Net.WebUtility]::HtmlEncode($reportTitle)) - $safeCampaignName</title>
</head>
<body style="font-family:$fontFamily; margin:0; padding:24px; background:#f0f2f5; color:#333;">
<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">

$navHtml

<h1 style="font-family:$fontFamily; color:#2c3e50; font-size:24px; margin-bottom:4px;">$([System.Net.WebUtility]::HtmlEncode($reportTitle))</h1>
<p style="font-family:$fontFamily; color:#555; font-size:14px; margin:0 0 4px 0;">$safeCampaignName</p>
$dateRangeHtml

$summaryCardsHtml

$subordinateTableHtml

$detailSectionsHtml

$footerHtml

</div>
</body>
</html>
"@

        # Determine filename
        $fileName = if ($isTopLevel) {
            'executive-summary.html'
        } else {
            "$filePrefixSingular-$safeName.html"
        }

        $filePath = Join-Path -Path $OutputPath -ChildPath $fileName
        $html | Set-Content -Path $filePath -Encoding UTF8

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Level $Level report written: $filePath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPLeadershipLevelHtml' `
                -CorrelationID $CorrelationID
        }

        $outputPaths.Add($filePath)
    }

    return @($outputPaths.ToArray())
}


#endregion Leadership Level Reports

#region Leadership Band Reports

function Export-SPLeadershipBandHtml {
    <#
    .SYNOPSIS
        Generates per-band leadership HTML reports filtered by band classification.
    .DESCRIPTION
        Orchestrates band-aware report generation by filtering leadership data
        through band classifications from Resolve-SPIdentityBand. Produces reports
        only for leaders whose band matches the TargetBands / ExcludeBands criteria.

        Delegates actual HTML generation to Export-SPLeadershipLevelHtml with
        filtered leader sets and band-decorated headers.
    .PARAMETER LeadershipData
        Hashtable from Group-SPAuditByLeadership with Levels and TopLevel keys.
    .PARAMETER Decisions
        Hashtable from Group-SPAuditDecisions with Approved, Revoked, Pending arrays.
    .PARAMETER OrgTree
        Hashtable from Build-SPOrgTree .Data containing Nodes, LevelLabels, etc.
    .PARAMETER BandData
        Hashtable from Resolve-SPIdentityBand .Data containing Bands (id->letter),
        Sources, and Summary.
    .PARAMETER TargetBands
        Array of band letters to include (e.g. @('A','B','C')). When specified,
        only leaders with matching bands are included. Mutually exclusive logic
        with ExcludeBands -- if both are specified, TargetBands takes precedence.
    .PARAMETER ExcludeBands
        Array of band letters to exclude (e.g. @('D','E')). When specified,
        leaders with matching bands are skipped. Ignored if TargetBands is provided.
    .PARAMETER CampaignName
        Display name of the campaign (or combined campaign label).
    .PARAMETER DateRange
        Descriptive date range string for the report header.
    .PARAMETER OutputPath
        Directory in which to write the HTML files. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID embedded in each report footer.
    .PARAMETER DetailLevel
        Controls identity-level detail in reports: Summary, Detailed, or Verbose.
    .OUTPUTS
        [hashtable] @{
            Success       = [bool]
            Data          = @{
                Files         = [string[]]  array of generated file paths
                ReportCount   = [int]       total reports generated
                BandsIncluded = [string[]]  bands that had matching leaders
                LeadersSkipped = [int]      leaders filtered out by band
            }
            Error         = $null | [string]
        }
    .EXAMPLE
        $result = Export-SPLeadershipBandHtml -LeadershipData $leadership `
            -Decisions $grouped -OrgTree $tree.Data -BandData $bands.Data `
            -TargetBands @('A','B','C') -CampaignName 'Q1 Review' `
            -OutputPath 'C:\Reports\leadership'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$LeadershipData,

        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter(Mandatory)]
        [hashtable]$BandData,

        [Parameter()]
        [string[]]$TargetBands,

        [Parameter()]
        [string[]]$ExcludeBands,

        [Parameter(Mandatory)]
        [string]$CampaignName,

        [Parameter()]
        [string]$DateRange = '',

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [ValidateSet('Summary', 'Detailed', 'Verbose')]
        [string]$DetailLevel = 'Verbose'
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Export-SPLeadershipBandHtml'

    # --- Build the set of allowed bands ---
    $validBandLetters = @('A', 'B', 'C', 'D', 'E')
    $allowedBands = @{}

    if ($null -ne $TargetBands -and $TargetBands.Count -gt 0) {
        foreach ($b in $TargetBands) {
            $bu = $b.ToUpper()
            if ($bu -in $validBandLetters) { $allowedBands[$bu] = $true }
        }
    }
    elseif ($null -ne $ExcludeBands -and $ExcludeBands.Count -gt 0) {
        foreach ($b in $validBandLetters) { $allowedBands[$b] = $true }
        foreach ($b in $ExcludeBands) {
            $bu = $b.ToUpper()
            if ($allowedBands.ContainsKey($bu)) { $allowedBands.Remove($bu) }
        }
    }
    else {
        # No filtering -- all bands allowed
        foreach ($b in $validBandLetters) { $allowedBands[$b] = $true }
    }

    if ($allowedBands.Count -eq 0) {
        return @{
            Success = $false
            Data    = $null
            Error   = 'No valid bands in filter. TargetBands/ExcludeBands resolved to an empty set.'
        }
    }

    # --- Validate inputs ---
    $levels = if ($LeadershipData.ContainsKey('Levels')) { $LeadershipData['Levels'] } else { @{} }
    $bands  = if ($null -ne $BandData -and $null -ne $BandData.Bands) { $BandData.Bands } else { @{} }

    if ($levels.Count -eq 0) {
        return @{
            Success = $true
            Data    = @{ Files = @(); ReportCount = 0; BandsIncluded = @(); LeadersSkipped = 0 }
            Error   = $null
        }
    }

    # --- Determine level range ---
    $topLevel = if ($LeadershipData.ContainsKey('TopLevel')) { [int]$LeadershipData.TopLevel } else {
        ($levels.Keys | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
    }
    $lowestLevel = ($levels.Keys | ForEach-Object { [int]$_ } | Measure-Object -Minimum).Minimum

    # --- Build filtered leadership data per level ---
    $filteredLevels   = @{}
    $leadersSkipped   = 0
    $bandsIncludedSet = @{}

    foreach ($lvlKey in $levels.Keys) {
        $lvl = [int]$lvlKey
        $lvlData = $levels[$lvlKey]
        if ($null -eq $lvlData.Leaders -or $lvlData.Leaders.Count -eq 0) { continue }

        $filteredLeaders = @{}
        foreach ($leaderId in $lvlData.Leaders.Keys) {
            if ($leaderId -eq '__unmanaged__') {
                $filteredLeaders[$leaderId] = $lvlData.Leaders[$leaderId]
                continue
            }

            # Look up this leader's band
            $leaderBand = $null
            if ($bands.ContainsKey($leaderId)) {
                $leaderBand = $bands[$leaderId]
            }

            if ($null -ne $leaderBand -and $allowedBands.ContainsKey($leaderBand)) {
                $filteredLeaders[$leaderId] = $lvlData.Leaders[$leaderId]
                $bandsIncludedSet[$leaderBand] = $true
            }
            else {
                $leadersSkipped++
            }
        }

        # Only include level if it has non-unmanaged leaders after filtering
        $realLeaderCount = @($filteredLeaders.Keys | Where-Object { $_ -ne '__unmanaged__' }).Count
        if ($realLeaderCount -gt 0) {
            $filteredLevels[$lvl] = @{
                Label   = $lvlData.Label
                Leaders = $filteredLeaders
            }
        }
    }

    if ($filteredLevels.Count -eq 0) {
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Band filter produced no matching leaders (allowed: $($allowedBands.Keys -join ', '))" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
        }
        return @{
            Success = $true
            Data    = @{
                Files          = @()
                ReportCount    = 0
                BandsIncluded  = @()
                LeadersSkipped = $leadersSkipped
            }
            Error   = $null
        }
    }

    # Build filtered LeadershipData clone with filtered levels
    $filteredLeadershipData = @{}
    foreach ($key in $LeadershipData.Keys) {
        if ($key -eq 'Levels') { continue }
        $filteredLeadershipData[$key] = $LeadershipData[$key]
    }
    $filteredLeadershipData['Levels'] = $filteredLevels

    # Determine effective start/lowest levels from filtered data
    $filteredLevelNums = @($filteredLevels.Keys | ForEach-Object { [int]$_ })
    $effectiveStartLevel  = ($filteredLevelNums | Measure-Object -Maximum).Maximum
    $effectiveLowestLevel = ($filteredLevelNums | Measure-Object -Minimum).Minimum

    # --- Generate reports per level ---
    $allFiles = [System.Collections.Generic.List[string]]::new()

    for ($lvl = $effectiveStartLevel; $lvl -ge $effectiveLowestLevel; $lvl--) {
        if (-not $filteredLevels.ContainsKey($lvl)) { continue }

        $lvlPaths = Export-SPLeadershipLevelHtml `
            -LeadershipData $filteredLeadershipData `
            -Decisions $Decisions `
            -OrgTree $OrgTree `
            -Level $lvl `
            -StartLevel $effectiveStartLevel `
            -LowestLevel $effectiveLowestLevel `
            -CampaignName $CampaignName `
            -DateRange $DateRange `
            -OutputPath $OutputPath `
            -CorrelationID $CorrelationID `
            -DetailLevel $DetailLevel `
            -BandData $BandData

        foreach ($p in @($lvlPaths)) {
            $allFiles.Add($p)
        }
    }

    $bandsIncluded = @($bandsIncludedSet.Keys | Sort-Object)

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message "Band-filtered reports complete: $($allFiles.Count) files, bands=$($bandsIncluded -join ','), skipped=$leadersSkipped" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
    }

    return @{
        Success = $true
        Data    = @{
            Files          = @($allFiles.ToArray())
            ReportCount    = $allFiles.Count
            BandsIncluded  = $bandsIncluded
            LeadersSkipped = $leadersSkipped
        }
        Error   = $null
    }
}


#endregion Leadership Band Reports

#region Campaign Comparison Report

function Export-SPCampaignComparisonHtml {
    <#
    .SYNOPSIS
        Generates a Word-compatible HTML comparison report for campaign metrics.
    .DESCRIPTION
        Produces a column-per-campaign comparison table with delta highlighting.
        Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
        Called by Compare-SPCampaigns when OutputMode=HTML.
    .PARAMETER Metrics
        Array of per-campaign metric objects from Measure-SPCampaignMetrics.
    .PARAMETER MetricDefs
        Array of metric definition hashtables (Label, Prop, Format).
    .PARAMETER OutputPath
        Directory for HTML output.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Metrics,

        [Parameter(Mandatory)]
        [object[]]$MetricDefs,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "CampaignComparison-${timestamp}.html"

    # --- Build header columns ---
    $headerLabels = @('Metric')
    for ($i = 0; $i -lt $Metrics.Count; $i++) {
        $campName = ConvertTo-SafeHtml $Metrics[$i].CampaignName
        $headerLabels += $campName
    }
    if ($Metrics.Count -eq 2) {
        $headerLabels += 'Delta'
    }
    $theadHtml = Build-HtmlTableHeader -Headers $headerLabels

    # --- Build data rows ---
    $tbodyRows = [System.Collections.Generic.List[string]]::new()
    $rowIdx = 0
    foreach ($mdef in $MetricDefs) {
        $cells = [System.Collections.Generic.List[string]]::new()

        # Metric label
        $cells.Add((ConvertTo-SafeHtml $mdef.Label))

        # Per-campaign values
        $numericValues = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $Metrics.Count; $i++) {
            $rawVal = $Metrics[$i].PSObject.Properties[$mdef.Prop].Value
            $numericValues.Add($rawVal)
            $displayVal = Format-ComparisonCellValue -Value $rawVal -Format $mdef.Format
            $cells.Add($displayVal)
        }

        # Delta column (first two campaigns, numeric types)
        if ($Metrics.Count -eq 2 -and $mdef.Format -in @('int', 'pct', 'hours')) {
            $v1 = $numericValues[0]
            $v2 = $numericValues[1]
            if ($null -ne $v1 -and $null -ne $v2) {
                $delta = [Math]::Round(([double]$v2 - [double]$v1), 1)
                $sign = if ($delta -gt 0) { '+' } else { '' }
                $color = if ($delta -gt 0) { '#339933' } elseif ($delta -lt 0) { '#CC3333' } else { '#777777' }
                # For revocation rate, invert colors (lower is better)
                if ($mdef.Prop -eq 'RevocationRate') {
                    $color = if ($delta -gt 0) { '#CC3333' } elseif ($delta -lt 0) { '#339933' } else { '#777777' }
                }
                $cells.Add("<span style=""color:${color}; font-weight:bold;"">${sign}${delta}</span>")
            }
            else {
                $cells.Add('N/A')
            }
        }

        $isAlt = (($rowIdx % 2) -eq 1)
        $tbodyRows.Add((Build-HtmlTableRow -Cells $cells.ToArray() -IsAlternate $isAlt))
        $rowIdx++
    }

    $tbodyHtml = $tbodyRows -join "`n"

    # --- Campaign name list for title ---
    $campNames = ($Metrics | ForEach-Object { ConvertTo-SafeHtml $_.CampaignName }) -join ' vs '

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Campaign Comparison - $campNames</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; margin:24px; color:#2c3e50; background:#ffffff;">

<h1 style="font-size:22px; color:#2c3e50; border-bottom:3px solid #336699; padding-bottom:8px; margin-bottom:4px;">Campaign Comparison Report</h1>
<p style="font-size:13px; color:#777777; margin-top:0; margin-bottom:20px;">$campNames</p>

<h2 style="font-size:16px; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px;">Side-by-Side Metrics</h2>

<table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:20px;">
$theadHtml
<tbody>
$tbodyHtml
</tbody>
</table>

<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit v$($script:AuditReportVersion) &nbsp;|&nbsp; Campaign Comparison &nbsp;|&nbsp; Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt)) &nbsp;|&nbsp; Correlation ID: $([System.Net.WebUtility]::HtmlEncode($CorrelationID))
</div>

</body>
</html>
"@

    [System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)
    return $htmlFile
}


function Format-ComparisonCellValue {
    <#
    .SYNOPSIS
        Formats a metric value for display in comparison tables.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Value,

        [Parameter()]
        [string]$Format = 'string'
    )

    if ($null -eq $Value) { return (ConvertTo-SafeHtml 'N/A') }

    switch ($Format) {
        'string' { return (ConvertTo-SafeHtml ([string]$Value)) }
        'int'    { return (ConvertTo-SafeHtml ([string][int]$Value)) }
        'pct'    { return (ConvertTo-SafeHtml "$([Math]::Round([double]$Value, 1))%") }
        'hours'  { return (ConvertTo-SafeHtml (Format-HoursDisplay $Value)) }
        'date'   {
            if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
            return (ConvertTo-SafeHtml (Format-HtmlDate ([string]$Value)))
        }
        default  { return (ConvertTo-SafeHtml ([string]$Value)) }
    }
}


#endregion Campaign Comparison Report

#region Audit Trail HTML

function Export-SPAuditTrailHtml {
    <#
    .SYNOPSIS
        Generates a timeline HTML report from consolidated audit trail events.
    .DESCRIPTION
        Produces a Word-compatible HTML report with chronologically sorted events,
        color-coded event type badges, and CSS class filtering support.
        Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
    .PARAMETER Events
        Array of normalised audit trail events from Get-SPAuditTrail.
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    .EXAMPLE
        $trail = Get-SPAuditTrail -After (Get-Date).AddDays(-7)
        $path  = Export-SPAuditTrailHtml -Events $trail -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$Events,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "AuditTrail-${timestamp}.html"

    # Badge colors per event type
    $badgeColors = @{
        'CampaignAudit' = @{ Bg = '#336699'; Text = '#ffffff' }
        'DeltaCertRun'  = @{ Bg = '#339966'; Text = '#ffffff' }
        'Escalation'    = @{ Bg = '#CC6633'; Text = '#ffffff' }
    }

    # Build table rows
    $headers = @('Timestamp', 'Event Type', 'Action', 'Summary', 'Correlation ID', 'Source')
    $theadHtml = Build-HtmlTableHeader -Headers $headers

    $tbodyRows = [System.Collections.Generic.List[string]]::new()
    $rowIdx = 0
    foreach ($evt in $Events) {
        $tsDisplay = ''
        if ($null -ne $evt.Timestamp) {
            $tsDisplay = $evt.Timestamp.ToString('yyyy-MM-dd HH:mm:ss')
        }

        $evType  = ConvertTo-SafeHtml $evt.EventType
        $colors  = $badgeColors[$evt.EventType]
        if ($null -eq $colors) { $colors = @{ Bg = '#777777'; Text = '#ffffff' } }
        $badge   = "<span class=""evtype-$($evt.EventType)"" style=""display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; background:$($colors.Bg); color:$($colors.Text);"">$evType</span>"

        $action  = ConvertTo-SafeHtml $evt.Action
        $summary = ConvertTo-SafeHtml $evt.Summary
        $corrId  = ConvertTo-SafeHtml $evt.CorrelationID

        $sourceDisplay = ''
        if ($null -ne $evt.SourceIds -and $evt.SourceIds.Count -gt 0) {
            $sourceDisplay = ConvertTo-SafeHtml (($evt.SourceIds | ForEach-Object { [string]$_ }) -join ', ')
        }

        $cells = @($tsDisplay, $badge, $action, $summary, $corrId, $sourceDisplay)
        $isAlt = (($rowIdx % 2) -eq 1)
        $tbodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate $isAlt))
        $rowIdx++
    }

    $tbodyHtml = $tbodyRows -join "`n"

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Audit Trail Timeline</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; margin:24px; color:#2c3e50; background:#ffffff;">

<h1 style="font-size:22px; color:#2c3e50; border-bottom:3px solid #336699; padding-bottom:8px; margin-bottom:4px;">Audit Trail Timeline</h1>
<p style="font-size:13px; color:#777777; margin-top:0; margin-bottom:20px;">$($Events.Count) events consolidated from campaign audits, delta cert runs, and escalations</p>

<table style="width:100%; border-collapse:collapse; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:13px; margin-bottom:20px;">
$theadHtml
<tbody>
$tbodyHtml
</tbody>
</table>

<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit v$($script:AuditReportVersion) &nbsp;|&nbsp; Audit Trail Timeline &nbsp;|&nbsp; Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt)) &nbsp;|&nbsp; Correlation ID: $([System.Net.WebUtility]::HtmlEncode($CorrelationID))
</div>

</body>
</html>
"@

    [System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)

    Write-SPLog -Message "Audit trail HTML written ($($Events.Count) events): $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditTrailHtml' `
        -CorrelationID $CorrelationID

    return $htmlFile
}


#endregion Audit Trail HTML

#region CSV Export

function Export-SPAuditCsv {
    <#
    .SYNOPSIS
        Exports campaign audit data to CSV files for GRC/SIEM integration.
    .DESCRIPTION
        Produces one or more CSV files from campaign audit data, suitable for
        import into GRC tools (ServiceNow GRC, RSA Archer), SIEM platforms
        (Splunk, Sentinel), or SharePoint/Excel.

        Output files (one CSV per data type):
        - decisions-{correlationId}.csv  -- one row per access review decision
        - reviewers-{correlationId}.csv  -- one row per reviewer per campaign
        - campaigns-{correlationId}.csv  -- one row per campaign
        - remediation-{correlationId}.csv -- one row per revoked item

        Uses Export-Csv -NoTypeInformation for PS 5.1 compatibility.
        Date columns are ISO 8601 format. Risk flags are semicolon-delimited.
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables as produced by the campaign audit
        pipeline (Invoke-SPCampaignAudit). Each must contain: CampaignName,
        Decisions, ReviewerMetrics, RubberStampRisk, and campaign metadata.
    .PARAMETER OutputPath
        Directory in which to write CSV files. Created if absent.
    .PARAMETER Sheets
        Which CSV sheets to generate. Defaults to all four.
        Valid values: 'Decisions', 'Reviewers', 'Campaigns', 'Remediation'
    .PARAMETER CorrelationID
        Unique ID for tracing and file naming. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Files = @{ Decisions = 'path'; ... }; RowCounts = @{ ... } }
    .EXAMPLE
        Export-SPAuditCsv -CampaignAudits $audits -OutputPath 'C:\Reports'
    .EXAMPLE
        Export-SPAuditCsv -CampaignAudits $audits -OutputPath 'C:\Reports' -Sheets 'Decisions'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object[]]$CampaignAudits,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [ValidateSet('Decisions', 'Reviewers', 'Campaigns', 'Remediation')]
        [string[]]$Sheets = @('Decisions', 'Reviewers', 'Campaigns', 'Remediation'),

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Exporting audit CSV for $($CampaignAudits.Count) campaign(s), sheets: $($Sheets -join ', ')" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditCsv' `
        -CorrelationID $CorrelationID

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $files     = @{}
    $rowCounts = @{}

    # --- Helper: safe string extraction from hashtable or PSCustomObject ---
    function _Val ($obj, [string]$key, [string]$default = '') {
        if ($null -eq $obj) { return $default }
        if ($obj -is [hashtable]) {
            if ($obj.ContainsKey($key) -and $null -ne $obj[$key]) { return [string]$obj[$key] }
            return $default
        }
        if ($null -ne $obj.PSObject -and $null -ne $obj.PSObject.Properties[$key]) {
            $v = $obj.PSObject.Properties[$key].Value
            if ($null -ne $v) { return [string]$v }
        }
        return $default
    }

    # ================================================================
    # DECISIONS CSV
    # ================================================================
    if ($Sheets -contains 'Decisions') {
        $decisionRows = [System.Collections.Generic.List[object]]::new()

        foreach ($audit in $CampaignAudits) {
            $campName   = _Val $audit 'CampaignName'
            $campStatus = _Val $audit 'Status'
            $campStart  = _Val $audit 'Created'
            $campDue    = _Val $audit 'Deadline'

            # Determine campaign type from the audit data
            $campType = _Val $audit 'CampaignType'

            $decisions = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('Decisions')) {
                $decisions = $audit['Decisions']
            } elseif ($null -ne $audit.PSObject -and $null -ne $audit.PSObject.Properties['Decisions']) {
                $decisions = $audit.Decisions
            }
            if ($null -eq $decisions) { continue }

            foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                $items = @()
                if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                    $items = @($decisions[$category])
                } elseif ($null -ne $decisions.PSObject -and $null -ne $decisions.PSObject.Properties[$category]) {
                    $items = @($decisions.$category)
                }

                foreach ($item in $items) {
                    if ($null -eq $item) { continue }

                    # Risk flags: join as semicolons for CSV compatibility
                    $riskFlags = ''
                    $rf = $null
                    if ($null -ne $item.PSObject -and $null -ne $item.PSObject.Properties['RiskFlags']) {
                        $rf = $item.RiskFlags
                    }
                    if ($null -ne $rf -and $rf -is [array] -and $rf.Count -gt 0) {
                        $riskFlags = ($rf | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
                    } elseif ($null -ne $rf -and $rf -is [string] -and -not [string]::IsNullOrWhiteSpace($rf)) {
                        $riskFlags = $rf
                    }

                    $decisionRows.Add([PSCustomObject]@{
                        CampaignName      = $campName
                        CampaignType      = $campType
                        CampaignStatus    = $campStatus
                        IdentityName      = if ($null -ne $item.IdentityName)      { [string]$item.IdentityName }      else { '' }
                        IdentityId        = if ($null -ne $item.IdentityId)        { [string]$item.IdentityId }        else { '' }
                        AccountName       = if ($null -ne $item.AccountName)       { [string]$item.AccountName }       else { '' }
                        SourceName        = if ($null -ne $item.SourceName)        { [string]$item.SourceName }        else { '' }
                        EntitlementName   = if ($null -ne $item.AccessName)        { [string]$item.AccessName }        else { '' }
                        AccessType        = if ($null -ne $item.AccessType)        { [string]$item.AccessType }        else { '' }
                        Decision          = if ($null -ne $item.Decision)          { [string]$item.Decision }          else { $category }
                        DecisionDate      = if ($null -ne $item.DecisionDate)      { [string]$item.DecisionDate }      else { '' }
                        ReviewerName      = if ($null -ne $item.ReviewerName)      { [string]$item.ReviewerName }      else { '' }
                        ReviewerEmail     = if ($null -ne $item.ReviewerEmail)     { [string]$item.ReviewerEmail }     else { '' }
                        Justification     = if ($null -ne $item.Justification)     { [string]$item.Justification }     else { '' }
                        RemediationStatus = if ($null -ne $item.RemediationStatus) { [string]$item.RemediationStatus } else { '' }
                        RemediationDate   = if ($null -ne $item.RemediationDate)   { [string]$item.RemediationDate }   else { '' }
                        RiskFlags         = $riskFlags
                        CampaignStartDate = if ($null -ne $item.CampaignStartDate) { [string]$item.CampaignStartDate } else { $campStart }
                        CampaignDueDate   = if ($null -ne $item.CampaignDueDate)   { [string]$item.CampaignDueDate }   else { $campDue }
                        SystemTimestamp    = if ($null -ne $item.SystemTimestamp)   { [string]$item.SystemTimestamp }   else { '' }
                    })
                }
            }
        }

        $csvPath = Join-Path $OutputPath "decisions-${CorrelationID}.csv"
        if ($decisionRows.Count -gt 0) {
            $decisionRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        } else {
            # Write header-only CSV
            [PSCustomObject]@{
                CampaignName='';CampaignType='';CampaignStatus='';IdentityName='';IdentityId='';
                AccountName='';SourceName='';EntitlementName='';AccessType='';Decision='';
                DecisionDate='';ReviewerName='';ReviewerEmail='';Justification='';
                RemediationStatus='';RemediationDate='';RiskFlags='';CampaignStartDate='';
                CampaignDueDate='';SystemTimestamp=''
            } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            # Remove the empty data row, keep only headers
            $headerLine = (Get-Content -Path $csvPath -TotalCount 1)
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($csvPath, "$headerLine`n", $utf8NoBom)
        }

        $files['Decisions']     = $csvPath
        $rowCounts['Decisions'] = $decisionRows.Count

        Write-SPLog -Message "Decisions CSV written ($($decisionRows.Count) rows): $csvPath" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditCsv' `
            -CorrelationID $CorrelationID
    }

    # ================================================================
    # REVIEWERS CSV
    # ================================================================
    if ($Sheets -contains 'Reviewers') {
        $reviewerRows = [System.Collections.Generic.List[object]]::new()

        foreach ($audit in $CampaignAudits) {
            $campName = _Val $audit 'CampaignName'

            # Get reviewer metrics
            $reviewerMetrics = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('ReviewerMetrics')) {
                $reviewerMetrics = $audit['ReviewerMetrics']
            }

            # Get rubber stamp risk data
            $rubberStampRisk = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('RubberStampRisk')) {
                $rubberStampRisk = $audit['RubberStampRisk']
            }

            # Build rubber stamp risk lookup by reviewer name
            $riskLookup = @{}
            if ($null -ne $rubberStampRisk -and $rubberStampRisk -is [hashtable] -and
                $rubberStampRisk.ContainsKey('ReviewerRisks') -and $null -ne $rubberStampRisk['ReviewerRisks']) {
                foreach ($rr in @($rubberStampRisk['ReviewerRisks'])) {
                    $rrName = if ($null -ne $rr.Name) { [string]$rr.Name } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($rrName)) {
                        $riskLookup[$rrName] = if ($null -ne $rr.Severity) { [string]$rr.Severity } else { 'None' }
                    }
                }
            }

            # Get decisions for per-reviewer item counts
            $decisions = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('Decisions')) {
                $decisions = $audit['Decisions']
            }

            # Build per-reviewer decision counts from decision items
            $reviewerApproved = @{}
            $reviewerRevoked  = @{}
            $reviewerPending  = @{}

            if ($null -ne $decisions -and $decisions -is [hashtable]) {
                foreach ($cat in @('Approved', 'Revoked', 'Pending')) {
                    if (-not $decisions.ContainsKey($cat) -or $null -eq $decisions[$cat]) { continue }
                    foreach ($item in @($decisions[$cat])) {
                        $rn = if ($null -ne $item.ReviewerName) { [string]$item.ReviewerName } else { 'Unknown' }
                        switch ($cat) {
                            'Approved' {
                                if ($reviewerApproved.ContainsKey($rn)) { $reviewerApproved[$rn]++ } else { $reviewerApproved[$rn] = 1 }
                            }
                            'Revoked'  {
                                if ($reviewerRevoked.ContainsKey($rn))  { $reviewerRevoked[$rn]++ }  else { $reviewerRevoked[$rn] = 1 }
                            }
                            'Pending'  {
                                if ($reviewerPending.ContainsKey($rn))  { $reviewerPending[$rn]++ }  else { $reviewerPending[$rn] = 1 }
                            }
                        }
                    }
                }
            }

            if ($null -ne $reviewerMetrics -and $reviewerMetrics -is [hashtable] -and
                $reviewerMetrics.ContainsKey('ReviewerMetrics') -and $null -ne $reviewerMetrics['ReviewerMetrics']) {
                foreach ($rm in @($reviewerMetrics['ReviewerMetrics'])) {
                    $name  = if ($null -ne $rm.Name)  { [string]$rm.Name }  else { '' }
                    $email = if ($null -ne $rm.Email) { [string]$rm.Email } else { '' }

                    $approved = if ($reviewerApproved.ContainsKey($name)) { $reviewerApproved[$name] } else { 0 }
                    $revoked  = if ($reviewerRevoked.ContainsKey($name))  { $reviewerRevoked[$name] }  else { 0 }
                    $pending  = if ($reviewerPending.ContainsKey($name))  { $reviewerPending[$name] }  else { 0 }
                    $assigned = $approved + $revoked + $pending
                    $decided  = $approved + $revoked

                    $approvalRate  = if ($decided -gt 0) { [Math]::Round(($approved / $decided) * 100, 1) } else { 0.0 }
                    $revocationRate = if ($decided -gt 0) { [Math]::Round(($revoked / $decided) * 100, 1) } else { 0.0 }

                    $rubberStampSeverity = if ($riskLookup.ContainsKey($name)) { $riskLookup[$name] } else { 'None' }

                    $reviewerRows.Add([PSCustomObject]@{
                        CampaignName        = $campName
                        ReviewerName        = $name
                        ReviewerIdentityId  = ''
                        ItemsAssigned       = $assigned
                        ItemsDecided        = $decided
                        ItemsPending        = $pending
                        ApprovalRate        = $approvalRate
                        RevocationRate      = $revocationRate
                        AvgResponseHours    = if ($null -ne $rm.AvgHours)  { $rm.AvgHours }  else { '' }
                        FastestResponseHours = if ($null -ne $rm.MinHours) { $rm.MinHours } else { '' }
                        SlowestResponseHours = if ($null -ne $rm.MaxHours) { $rm.MaxHours } else { '' }
                        RubberStampRisk     = $rubberStampSeverity
                    })
                }
            }
        }

        $csvPath = Join-Path $OutputPath "reviewers-${CorrelationID}.csv"
        if ($reviewerRows.Count -gt 0) {
            $reviewerRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        } else {
            [PSCustomObject]@{
                CampaignName='';ReviewerName='';ReviewerIdentityId='';ItemsAssigned='';
                ItemsDecided='';ItemsPending='';ApprovalRate='';RevocationRate='';
                AvgResponseHours='';FastestResponseHours='';SlowestResponseHours='';
                RubberStampRisk=''
            } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            $headerLine = (Get-Content -Path $csvPath -TotalCount 1)
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($csvPath, "$headerLine`n", $utf8NoBom)
        }

        $files['Reviewers']     = $csvPath
        $rowCounts['Reviewers'] = $reviewerRows.Count

        Write-SPLog -Message "Reviewers CSV written ($($reviewerRows.Count) rows): $csvPath" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditCsv' `
            -CorrelationID $CorrelationID
    }

    # ================================================================
    # CAMPAIGNS CSV
    # ================================================================
    if ($Sheets -contains 'Campaigns') {
        $campaignRows = [System.Collections.Generic.List[object]]::new()

        foreach ($audit in $CampaignAudits) {
            $campName   = _Val $audit 'CampaignName'
            $campId     = _Val $audit 'CampaignId'
            $campType   = _Val $audit 'CampaignType'
            $campStatus = _Val $audit 'Status'
            $created    = _Val $audit 'Created'
            $deadline   = _Val $audit 'Deadline'
            $completed  = _Val $audit 'Completed'

            # Count items from decisions
            $decisions = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('Decisions')) {
                $decisions = $audit['Decisions']
            }

            $totalItems = 0; $approvedCt = 0; $revokedCt = 0; $pendingCt = 0
            if ($null -ne $decisions -and $decisions -is [hashtable]) {
                if ($decisions.ContainsKey('Approved') -and $null -ne $decisions['Approved']) {
                    $approvedCt = @($decisions['Approved']).Count
                }
                if ($decisions.ContainsKey('Revoked') -and $null -ne $decisions['Revoked']) {
                    $revokedCt = @($decisions['Revoked']).Count
                }
                if ($decisions.ContainsKey('Pending') -and $null -ne $decisions['Pending']) {
                    $pendingCt = @($decisions['Pending']).Count
                }
            }
            $totalItems = $approvedCt + $revokedCt + $pendingCt
            $completionPct = if ($totalItems -gt 0) { [Math]::Round((($approvedCt + $revokedCt) / $totalItems) * 100, 1) } else { 0.0 }

            # Reviewer count and response time from ReviewerMetrics
            $reviewerCount = 0
            $avgRespHours  = ''
            $medianRespHours = ''
            $reviewerMetrics = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('ReviewerMetrics')) {
                $reviewerMetrics = $audit['ReviewerMetrics']
            }
            if ($null -ne $reviewerMetrics -and $reviewerMetrics -is [hashtable]) {
                if ($reviewerMetrics.ContainsKey('ReviewerMetrics') -and $null -ne $reviewerMetrics['ReviewerMetrics']) {
                    $reviewerCount = @($reviewerMetrics['ReviewerMetrics']).Count
                }
                if ($reviewerMetrics.ContainsKey('CampaignAvgHours') -and $null -ne $reviewerMetrics['CampaignAvgHours']) {
                    $avgRespHours = $reviewerMetrics['CampaignAvgHours']
                }
                if ($reviewerMetrics.ContainsKey('CampaignMedianHours') -and $null -ne $reviewerMetrics['CampaignMedianHours']) {
                    $medianRespHours = $reviewerMetrics['CampaignMedianHours']
                }
            }

            $campaignRows.Add([PSCustomObject]@{
                CampaignId         = $campId
                CampaignName       = $campName
                CampaignType       = $campType
                Status             = $campStatus
                Created            = $created
                Deadline           = $deadline
                Completed          = $completed
                TotalItems         = $totalItems
                Approved           = $approvedCt
                Revoked            = $revokedCt
                Pending            = $pendingCt
                CompletionPct      = $completionPct
                ReviewerCount      = $reviewerCount
                AvgResponseHours   = $avgRespHours
                MedianResponseHours = $medianRespHours
            })
        }

        $csvPath = Join-Path $OutputPath "campaigns-${CorrelationID}.csv"
        if ($campaignRows.Count -gt 0) {
            $campaignRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        } else {
            [PSCustomObject]@{
                CampaignId='';CampaignName='';CampaignType='';Status='';Created='';
                Deadline='';Completed='';TotalItems='';Approved='';Revoked='';Pending='';
                CompletionPct='';ReviewerCount='';AvgResponseHours='';MedianResponseHours=''
            } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            $headerLine = (Get-Content -Path $csvPath -TotalCount 1)
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($csvPath, "$headerLine`n", $utf8NoBom)
        }

        $files['Campaigns']     = $csvPath
        $rowCounts['Campaigns'] = $campaignRows.Count

        Write-SPLog -Message "Campaigns CSV written ($($campaignRows.Count) rows): $csvPath" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditCsv' `
            -CorrelationID $CorrelationID
    }

    # ================================================================
    # REMEDIATION CSV
    # ================================================================
    if ($Sheets -contains 'Remediation') {
        $remediationRows = [System.Collections.Generic.List[object]]::new()

        foreach ($audit in $CampaignAudits) {
            $campName = _Val $audit 'CampaignName'

            $decisions = $null
            if ($audit -is [hashtable] -and $audit.ContainsKey('Decisions')) {
                $decisions = $audit['Decisions']
            }
            if ($null -eq $decisions) { continue }

            $revokedItems = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey('Revoked') -and $null -ne $decisions['Revoked']) {
                $revokedItems = @($decisions['Revoked'])
            }

            foreach ($item in $revokedItems) {
                if ($null -eq $item) { continue }

                # Calculate days to remediate
                $daysToRemediate = ''
                $decDateStr = if ($null -ne $item.DecisionDate)    { [string]$item.DecisionDate }    else { '' }
                $remDateStr = if ($null -ne $item.RemediationDate) { [string]$item.RemediationDate } else { '' }

                if (-not [string]::IsNullOrWhiteSpace($decDateStr) -and -not [string]::IsNullOrWhiteSpace($remDateStr)) {
                    try {
                        $dtDec = [datetime]::Parse($decDateStr, [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        $dtRem = [datetime]::Parse($remDateStr, [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        $daysToRemediate = [Math]::Round(($dtRem - $dtDec).TotalDays, 3)
                    } catch { }
                }

                $remediationRows.Add([PSCustomObject]@{
                    CampaignName        = $campName
                    IdentityName        = if ($null -ne $item.IdentityName)      { [string]$item.IdentityName }      else { '' }
                    AccountName         = if ($null -ne $item.AccountName)       { [string]$item.AccountName }       else { '' }
                    EntitlementRevoked  = if ($null -ne $item.AccessName)        { [string]$item.AccessName }        else { '' }
                    DecisionDate        = $decDateStr
                    RemediationStatus   = if ($null -ne $item.RemediationStatus) { [string]$item.RemediationStatus } else { '' }
                    RemediationDate     = $remDateStr
                    ProvisioningEventId = ''
                    DaysToRemediate     = $daysToRemediate
                })
            }
        }

        $csvPath = Join-Path $OutputPath "remediation-${CorrelationID}.csv"
        if ($remediationRows.Count -gt 0) {
            $remediationRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        } else {
            [PSCustomObject]@{
                CampaignName='';IdentityName='';AccountName='';EntitlementRevoked='';
                DecisionDate='';RemediationStatus='';RemediationDate='';
                ProvisioningEventId='';DaysToRemediate=''
            } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            $headerLine = (Get-Content -Path $csvPath -TotalCount 1)
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($csvPath, "$headerLine`n", $utf8NoBom)
        }

        $files['Remediation']     = $csvPath
        $rowCounts['Remediation'] = $remediationRows.Count

        Write-SPLog -Message "Remediation CSV written ($($remediationRows.Count) rows): $csvPath" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditCsv' `
            -CorrelationID $CorrelationID
    }

    Write-SPLog -Message "CSV export complete: $($files.Count) file(s), total rows: $(($rowCounts.Values | Measure-Object -Sum).Sum)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAuditCsv' `
        -CorrelationID $CorrelationID

    return @{
        Files     = $files
        RowCounts = $rowCounts
    }
}


#endregion CSV Export

#region Campaign Trend HTML

function Export-SPCampaignTrendHtml {
    <#
    .SYNOPSIS
        Generates an HTML trend report from campaign trend analysis data.
    .DESCRIPTION
        Produces a Word-compatible HTML report with period-over-period comparison table,
        color-coded deltas (green for improvement, red for degradation, gray for stable),
        and a summary section with overall governance posture assessment.
        Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
    .PARAMETER TrendData
        Hashtable output from Measure-SPCampaignTrends.
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    .EXAMPLE
        $trends = Measure-SPCampaignTrends -CampaignMetrics $metrics
        $path   = Export-SPCampaignTrendHtml -TrendData $trends -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$TrendData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "CampaignTrends-${timestamp}.html"

    # --- Delta formatting helper ---
    function _FormatDelta([double]$value, [bool]$invertColor) {
        # invertColor: true for metrics where negative = good (AvgResponseHrs)
        if ($value -eq 0) {
            return '<span style="color:#888888;">--</span>'
        }
        $sign = if ($value -gt 0) { '+' } else { '' }
        $isGood = if ($invertColor) { $value -lt 0 } else { $value -gt 0 }
        $color  = if ($isGood) { '#27ae60' } else { '#e74c3c' }
        $arrow  = if ($value -gt 0) { '&#9650;' } else { '&#9660;' }
        return "<span style=""color:${color}; font-weight:bold;"">${arrow} ${sign}$([Math]::Round($value, 1))</span>"
    }

    # --- Build period table rows ---
    $headerRow = @"
<tr style="background:#336699; color:#ffffff;">
<th style="padding:8px 12px; text-align:left; border:1px solid #dddddd;">Period</th>
<th style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">Campaigns</th>
<th style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">Items</th>
<th style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">Approval %</th>
<th style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">Revocation %</th>
<th style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">Completion %</th>
<th style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">Avg Response (hrs)</th>
</tr>
"@

    $bodyRows = [System.Collections.Generic.List[string]]::new()
    $rowIdx = 0
    foreach ($period in $TrendData.Periods) {
        $bgColor = if (($rowIdx % 2) -eq 0) { '#ffffff' } else { '#f8f9fa' }

        # Format deltas (empty for first period)
        $approvalDelta   = ''
        $revocationDelta = ''
        $completionDelta = ''
        $responseDelta   = ''

        if ($period['Deltas'].Count -gt 0) {
            if ($period['Deltas'].ContainsKey('ApprovalRate')) {
                $approvalDelta = ' ' + (_FormatDelta $period['Deltas']['ApprovalRate'] $false)
            }
            if ($period['Deltas'].ContainsKey('RevocationRate')) {
                $revocationDelta = ' ' + (_FormatDelta $period['Deltas']['RevocationRate'] $true)
            }
            if ($period['Deltas'].ContainsKey('CompletionRate')) {
                $completionDelta = ' ' + (_FormatDelta $period['Deltas']['CompletionRate'] $false)
            }
            if ($period['Deltas'].ContainsKey('AvgResponseHrs')) {
                $responseDelta = ' ' + (_FormatDelta $period['Deltas']['AvgResponseHrs'] $true)
            }
        }

        $row = @"
<tr style="background:${bgColor};">
<td style="padding:8px 12px; border:1px solid #dddddd; font-weight:bold;">$(ConvertTo-SafeHtml $period['Label'])</td>
<td style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">$($period['CampaignCount'])</td>
<td style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">$($period['TotalItems'])</td>
<td style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">$($period['ApprovalRate'])%${approvalDelta}</td>
<td style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">$($period['RevocationRate'])%${revocationDelta}</td>
<td style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">$($period['CompletionRate'])%${completionDelta}</td>
<td style="padding:8px 12px; text-align:center; border:1px solid #dddddd;">$($period['AvgResponseHrs'])h${responseDelta}</td>
</tr>
"@
        $bodyRows.Add($row)
        $rowIdx++
    }

    # --- Build trend summary section ---
    $trendRows = [System.Collections.Generic.List[string]]::new()
    $trendLabels = @{
        'ApprovalRate'   = 'Approval Rate'
        'RevocationRate' = 'Revocation Rate'
        'CompletionRate' = 'Completion Rate'
        'AvgResponseHrs' = 'Avg Response Time'
    }

    foreach ($key in @('ApprovalRate', 'RevocationRate', 'CompletionRate', 'AvgResponseHrs')) {
        $trendValue = $TrendData.Trends[$key]
        $trendColor = switch ($trendValue) {
            'Improving'         { '#27ae60' }
            'Degrading'         { '#e74c3c' }
            'Stable'            { '#888888' }
            'Insufficient Data' { '#cccccc' }
            default             { '#888888' }
        }

        $trendRows.Add(@"
<tr>
<td style="padding:6px 12px; border:1px solid #dddddd;">$($trendLabels[$key])</td>
<td style="padding:6px 12px; border:1px solid #dddddd; text-align:center;"><span style="display:inline-block; padding:2px 10px; border-radius:3px; font-size:12px; font-weight:bold; background:${trendColor}; color:#ffffff;">$(ConvertTo-SafeHtml $trendValue)</span></td>
</tr>
"@)
    }

    # Overall direction badge
    $overallDir   = $TrendData.Summary.OverallDirection
    $overallColor = switch ($overallDir) {
        'Improving'         { '#27ae60' }
        'Degrading'         { '#e74c3c' }
        'Stable'            { '#888888' }
        'Insufficient Data' { '#cccccc' }
        default             { '#888888' }
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Campaign Trend Analysis</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; margin:24px; color:#2c3e50; background:#ffffff;">

<h1 style="font-size:22px; color:#2c3e50; border-bottom:3px solid #336699; padding-bottom:8px; margin-bottom:4px;">Campaign Trend Analysis</h1>
<p style="font-size:13px; color:#777777; margin-top:0; margin-bottom:20px;">$($TrendData.Summary.TotalCampaigns) campaigns from $($TrendData.Summary.EarliestCampaign) to $($TrendData.Summary.LatestCampaign)</p>

<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:8px;">Overall Governance Posture</h2>
<p style="font-size:14px;"><span style="display:inline-block; padding:4px 16px; border-radius:4px; font-size:14px; font-weight:bold; background:${overallColor}; color:#ffffff;">$(ConvertTo-SafeHtml $overallDir)</span></p>

<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:8px;">Trend Indicators</h2>
<table style="border-collapse:collapse; font-size:13px; margin-bottom:20px;">
<tr style="background:#336699; color:#ffffff;">
<th style="padding:6px 12px; text-align:left; border:1px solid #dddddd;">Metric</th>
<th style="padding:6px 12px; text-align:center; border:1px solid #dddddd;">Trend</th>
</tr>
$($trendRows -join "`n")
</table>

<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:8px;">Period-over-Period Comparison</h2>
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
$($bodyRows -join "`n")
</table>

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Campaign trend HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCampaignTrendHtml' `
        -CorrelationID $CorrelationID

    return $htmlFile
}


#endregion Campaign Trend HTML

#region Inventory HTML Reports

function Export-SPEntitlementInventoryHtml {
    <#
    .SYNOPSIS
        Generates an HTML entitlement inventory report grouped by source.
    .DESCRIPTION
        Produces a Word-compatible HTML report with per-source entitlement tables.
        Privileged entitlements are highlighted in red, unreviewed entitlements
        in orange. Includes a summary card with total counts and coverage percentage.
        Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
    .PARAMETER InventoryData
        Hashtable output from Get-SPEntitlementInventory (the .Data property).
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    .EXAMPLE
        $inv = Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory
        $path = Export-SPEntitlementInventoryHtml -InventoryData $inv.Data -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InventoryData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "EntitlementInventory-${timestamp}.html"

    $summary = $InventoryData.Summary
    $sources = $InventoryData.Sources

    $hasReviewData = ($null -ne $summary.ReviewCoverage)
    $coverageDisplay = if ($hasReviewData) { "$($summary.ReviewCoverage)%" } else { 'N/A' }

    # --- Summary card ---
    $summaryHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Total Sources<br/><span style="font-size:22px;">$($summary.TotalSources)</span>
</td>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Total Entitlements<br/><span style="font-size:22px;">$($summary.TotalEntitlements)</span>
</td>
<td style="padding:12px 16px; background:#c0392b; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Privileged<br/><span style="font-size:22px;">$($summary.TotalPrivileged)</span>
</td>
<td style="padding:12px 16px; background:#27ae60; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Review Coverage<br/><span style="font-size:22px;">$coverageDisplay</span>
</td>
</tr>
</table>
"@

    # --- Per-source sections ---
    $sourceSections = [System.Collections.Generic.List[string]]::new()

    foreach ($srcId in ($sources.Keys | Sort-Object)) {
        $srcData = $sources[$srcId]
        $srcName = ConvertTo-SafeHtml $srcData.SourceName

        $sectionHeader = @"
<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:4px;">$srcName</h2>
<p style="font-size:12px; color:#666666; margin-top:0; margin-bottom:8px;">Source ID: $(ConvertTo-SafeHtml $srcId) | Entitlements: $($srcData.TotalEntitlements) | Privileged: $($srcData.Privileged)</p>
"@

        if ($srcData.TotalEntitlements -eq 0) {
            $sourceSections.Add("${sectionHeader}<p style=""font-style:italic; color:#999999;"">No entitlements found for this source.</p>")
            continue
        }

        # Build table headers
        $headers = @('Name', 'Display Name', 'Type', 'Privileged', 'Owner')
        if ($hasReviewData) {
            $headers += @('Reviewed', 'Last Review')
        }

        $thStyle = 'style="background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px; border:1px solid #dddddd;"'
        $headerRow = "<thead><tr>" + (($headers | ForEach-Object { "<th $thStyle>$_</th>" }) -join '') + "</tr></thead>"

        $bodyRows = [System.Collections.Generic.List[string]]::new()
        $rowIdx = 0

        foreach ($ent in $srcData.Entitlements) {
            $rowIdx++
            $bgColor = if (($rowIdx % 2) -eq 0) { '#f8f9fa' } else { '#ffffff' }
            $tdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-size:13px;"

            # Highlight privileged in red, unreviewed in orange
            $rowBg = $bgColor
            if ($ent.Privileged) {
                $rowBg = '#fce4e4'
            } elseif ($hasReviewData -and $ent.Reviewed -eq $false) {
                $rowBg = '#fff3e0'
            }

            $privDisplay = if ($ent.Privileged) { '<span style="color:#c0392b; font-weight:bold;">Yes</span>' } else { 'No' }

            $cells = @(
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ent.Name)</td>"
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ent.DisplayName)</td>"
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ent.Type)</td>"
                "<td style=""$tdStyle"">$privDisplay</td>"
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ent.OwnerName)</td>"
            )

            if ($hasReviewData) {
                $reviewDisplay = if ($ent.Reviewed) {
                    '<span style="color:#27ae60;">Yes</span>'
                } else {
                    '<span style="color:#e67e22; font-weight:bold;">No</span>'
                }
                $lastReview = if (-not [string]::IsNullOrWhiteSpace($ent.LastReviewDate)) {
                    ConvertTo-SafeHtml (Format-HtmlDate $ent.LastReviewDate)
                } else { '' }
                $cells += @(
                    "<td style=""$tdStyle"">$reviewDisplay</td>"
                    "<td style=""$tdStyle"">$lastReview</td>"
                )
            }

            $bodyRows.Add("<tr style=""background:$rowBg;"">$($cells -join '')</tr>")
        }

        $tableHtml = @"
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
<tbody>
$($bodyRows -join "`n")
</tbody>
</table>
"@

        $sourceSections.Add("${sectionHeader}${tableHtml}")
    }

    # --- Assemble full HTML ---
    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Entitlement Inventory Report</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Entitlement Inventory Report</h1>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${summaryHtml}

$($sourceSections -join "`n")

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Entitlement inventory HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPEntitlementInventoryHtml' `
        -CorrelationID $CorrelationID

    return $htmlFile
}


function Export-SPAccessProfileInventoryHtml {
    <#
    .SYNOPSIS
        Generates an HTML access profile inventory report grouped by source.
    .DESCRIPTION
        Produces a Word-compatible HTML report with per-source access profile tables.
        Access profiles containing privileged entitlements are highlighted in red,
        unreviewed access profiles in orange. Includes a summary card with total
        counts and coverage percentage. Uses inline CSS only for Word compatibility.
    .PARAMETER InventoryData
        Hashtable output from Get-SPAccessProfileInventory (the .Data property).
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [hashtable] @{ Success; Data = @{ ReportPath } }
    .EXAMPLE
        $inv = Get-SPAccessProfileInventory -SourceIds 'src-ad-001' -IncludeEntitlements
        Export-SPAccessProfileInventoryHtml -InventoryData $inv.Data -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InventoryData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "AccessProfileInventory-${timestamp}.html"

    $summary = $InventoryData.Summary
    $sources = $InventoryData.Sources

    $hasReviewData = ($null -ne $summary.ReviewCoverage)
    $coverageDisplay = if ($hasReviewData) { "$($summary.ReviewCoverage)%" } else { 'N/A' }

    # --- Summary card ---
    $summaryHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Total Sources<br/><span style="font-size:22px;">$($summary.TotalSources)</span>
</td>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Access Profiles<br/><span style="font-size:22px;">$($summary.TotalAccessProfiles)</span>
</td>
<td style="padding:12px 16px; background:#27ae60; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Enabled<br/><span style="font-size:22px;">$($summary.TotalEnabled)</span>
</td>
<td style="padding:12px 16px; background:#2980b9; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Requestable<br/><span style="font-size:22px;">$($summary.TotalRequestable)</span>
</td>
<td style="padding:12px 16px; background:#8e44ad; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Review Coverage<br/><span style="font-size:22px;">$coverageDisplay</span>
</td>
</tr>
</table>
"@

    # --- Per-source sections ---
    $sourceSections = [System.Collections.Generic.List[string]]::new()

    foreach ($srcId in ($sources.Keys | Sort-Object)) {
        $srcData = $sources[$srcId]
        $srcName = ConvertTo-SafeHtml $srcData.SourceName

        $sectionHeader = @"
<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:4px;">$srcName</h2>
<p style="font-size:12px; color:#666666; margin-top:0; margin-bottom:8px;">Source ID: $(ConvertTo-SafeHtml $srcId) | Access Profiles: $($srcData.TotalAccessProfiles) | Enabled: $($srcData.Enabled) | Requestable: $($srcData.Requestable)</p>
"@

        if ($srcData.TotalAccessProfiles -eq 0) {
            $sourceSections.Add("${sectionHeader}<p style=""font-style:italic; color:#999999;"">No access profiles found for this source.</p>")
            continue
        }

        # Build table headers
        $headers = @('Name', 'Description', 'Enabled', 'Requestable', 'Owner', 'Entitlements')
        if ($hasReviewData) {
            $headers += @('Reviewed', 'Last Review')
        }

        $thStyle = 'style="background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px; border:1px solid #dddddd;"'
        $headerRow = "<thead><tr>" + (($headers | ForEach-Object { "<th $thStyle>$_</th>" }) -join '') + "</tr></thead>"

        $bodyRows = [System.Collections.Generic.List[string]]::new()
        $rowIdx = 0

        foreach ($ap in $srcData.AccessProfiles) {
            $rowIdx++
            $bgColor = if (($rowIdx % 2) -eq 0) { '#f8f9fa' } else { '#ffffff' }
            $tdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-size:13px;"

            # Highlight: privileged in red, unreviewed in orange
            $rowBg = $bgColor
            if ($ap.HasPrivileged) {
                $rowBg = '#fce4e4'
            } elseif ($hasReviewData -and $ap.Reviewed -eq $false) {
                $rowBg = '#fff3e0'
            }

            $enabledDisplay = if ($ap.Enabled) { '<span style="color:#27ae60;">Yes</span>' } else { '<span style="color:#999999;">No</span>' }
            $requestableDisplay = if ($ap.Requestable) { '<span style="color:#2980b9;">Yes</span>' } else { 'No' }

            # Entitlement count display, with expandable detail if names are available
            $entDisplay = "$($ap.EntitlementCount)"
            if ($ap.HasPrivileged) {
                $entDisplay += ' <span style="color:#c0392b; font-weight:bold;">(privileged)</span>'
            }
            if ($null -ne $ap.Entitlements -and $ap.Entitlements.Count -gt 0) {
                $entList = ($ap.Entitlements | ForEach-Object { ConvertTo-SafeHtml $_ }) -join '<br/>'
                $entDisplay = "<details><summary>$($ap.EntitlementCount)"
                if ($ap.HasPrivileged) {
                    $entDisplay += ' <span style="color:#c0392b; font-weight:bold;">(privileged)</span>'
                }
                $entDisplay += "</summary><div style=""padding:4px 0; font-size:12px; color:#555555;"">$entList</div></details>"
            }

            $cells = @(
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ap.Name)</td>"
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ap.Description)</td>"
                "<td style=""$tdStyle"">$enabledDisplay</td>"
                "<td style=""$tdStyle"">$requestableDisplay</td>"
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $ap.OwnerName)</td>"
                "<td style=""$tdStyle"">$entDisplay</td>"
            )

            if ($hasReviewData) {
                $reviewDisplay = if ($ap.Reviewed) {
                    '<span style="color:#27ae60;">Yes</span>'
                } elseif ($ap.Reviewed -eq $false) {
                    '<span style="color:#e67e22; font-weight:bold;">No</span>'
                } else { 'N/A' }

                $lastReview = if (-not [string]::IsNullOrWhiteSpace($ap.LastReviewDate)) {
                    ConvertTo-SafeHtml (Format-HtmlDate $ap.LastReviewDate)
                } else { '' }
                $cells += @(
                    "<td style=""$tdStyle"">$reviewDisplay</td>"
                    "<td style=""$tdStyle"">$lastReview</td>"
                )
            }

            $bodyRows.Add("<tr style=""background:$rowBg;"">$($cells -join '')</tr>")
        }

        $tableHtml = @"
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
<tbody>
$($bodyRows -join "`n")
</tbody>
</table>
"@

        $sourceSections.Add("${sectionHeader}${tableHtml}")
    }

    # --- Assemble full HTML ---
    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Access Profile Inventory Report</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Access Profile Inventory Report</h1>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${summaryHtml}

$($sourceSections -join "`n")

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Access profile inventory HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPAccessProfileInventoryHtml' `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            ReportPath = $htmlFile
        }
    }
}


function Export-SPRoleInventoryHtml {
    <#
    .SYNOPSIS
        Generates an HTML role inventory report with health indicators.
    .DESCRIPTION
        Produces a Word-compatible HTML report with a role table showing access profile
        count, membership type, enabled/requestable badges, and health indicator
        sections highlighting empty, disabled, and ownerless roles. Includes expandable
        per-role access profile detail and a summary card with role sprawl indicators.
        Uses inline CSS only for Word compatibility.
    .PARAMETER InventoryData
        Hashtable output from Get-SPRoleInventory (the .Data property).
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [hashtable] @{ Success; Data = @{ ReportPath } }
    .EXAMPLE
        $inv = Get-SPRoleInventory -IncludeAccessProfiles -AccessProfileInventory $apData
        Export-SPRoleInventoryHtml -InventoryData $inv.Data -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InventoryData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "RoleInventory-${timestamp}.html"

    $summary          = $InventoryData.Summary
    $roles            = $InventoryData.Roles
    $healthIndicators = $InventoryData.HealthIndicators

    $hasTransitive = ($null -ne $roles -and $roles.Count -gt 0 -and $null -ne $roles[0].TransitiveEntitlements)

    # --- Summary card ---
    $summaryHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Total Roles<br/><span style="font-size:22px;">$($summary.TotalRoles)</span>
</td>
<td style="padding:12px 16px; background:#27ae60; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Enabled<br/><span style="font-size:22px;">$($summary.Enabled)</span>
</td>
<td style="padding:12px 16px; background:#e74c3c; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Disabled<br/><span style="font-size:22px;">$($summary.Disabled)</span>
</td>
<td style="padding:12px 16px; background:#2980b9; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Requestable<br/><span style="font-size:22px;">$($summary.Requestable)</span>
</td>
<td style="padding:12px 16px; background:#8e44ad; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Avg AP/Role<br/><span style="font-size:22px;">$($summary.AvgAccessProfilesPerRole)</span>
</td>
<td style="padding:12px 16px; background:#e67e22; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Empty Roles<br/><span style="font-size:22px;">$($summary.EmptyRoles)</span>
</td>
</tr>
</table>
"@

    # --- Membership breakdown ---
    $membershipHtml = @"
<table style="width:50%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:8px 12px; background:#f0f0f0; border:1px solid #dddddd; font-weight:bold;">STANDARD Membership</td>
<td style="padding:8px 12px; border:1px solid #dddddd; text-align:center;">$($summary.StandardMembership)</td>
<td style="padding:8px 12px; background:#f0f0f0; border:1px solid #dddddd; font-weight:bold;">IDENTITY_LIST Membership</td>
<td style="padding:8px 12px; border:1px solid #dddddd; text-align:center;">$($summary.IdentityListMembership)</td>
</tr>
</table>
"@

    # --- Health indicators section ---
    $healthSections = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $healthIndicators.EmptyRoles -and $healthIndicators.EmptyRoles.Count -gt 0) {
        $items = ($healthIndicators.EmptyRoles | ForEach-Object { "<li>$(ConvertTo-SafeHtml $_)</li>" }) -join ''
        $healthSections.Add(@"
<div style="margin-bottom:12px; padding:10px; background:#fff3e0; border-left:4px solid #e67e22;">
<strong style="color:#e67e22;">Empty Roles (0 Access Profiles): $($healthIndicators.EmptyRoles.Count)</strong>
<ul style="margin:4px 0 0 0; padding-left:20px;">$items</ul>
</div>
"@)
    }

    if ($null -ne $healthIndicators.DisabledRoles -and $healthIndicators.DisabledRoles.Count -gt 0) {
        $items = ($healthIndicators.DisabledRoles | ForEach-Object { "<li>$(ConvertTo-SafeHtml $_)</li>" }) -join ''
        $healthSections.Add(@"
<div style="margin-bottom:12px; padding:10px; background:#fce4e4; border-left:4px solid #e74c3c;">
<strong style="color:#e74c3c;">Disabled Roles: $($healthIndicators.DisabledRoles.Count)</strong>
<ul style="margin:4px 0 0 0; padding-left:20px;">$items</ul>
</div>
"@)
    }

    if ($null -ne $healthIndicators.OwnerlessRoles -and $healthIndicators.OwnerlessRoles.Count -gt 0) {
        $items = ($healthIndicators.OwnerlessRoles | ForEach-Object { "<li>$(ConvertTo-SafeHtml $_)</li>" }) -join ''
        $healthSections.Add(@"
<div style="margin-bottom:12px; padding:10px; background:#fce4e4; border-left:4px solid #c0392b;">
<strong style="color:#c0392b;">Ownerless Roles: $($healthIndicators.OwnerlessRoles.Count)</strong>
<ul style="margin:4px 0 0 0; padding-left:20px;">$items</ul>
</div>
"@)
    }

    if ($null -ne $healthIndicators.SingleProfileRoles -and $healthIndicators.SingleProfileRoles.Count -gt 0) {
        $items = ($healthIndicators.SingleProfileRoles | ForEach-Object { "<li>$(ConvertTo-SafeHtml $_)</li>" }) -join ''
        $healthSections.Add(@"
<div style="margin-bottom:12px; padding:10px; background:#fff8e1; border-left:4px solid #f9a825;">
<strong style="color:#f9a825;">Single-Profile Roles: $($healthIndicators.SingleProfileRoles.Count)</strong>
<ul style="margin:4px 0 0 0; padding-left:20px;">$items</ul>
</div>
"@)
    }

    $healthHtml = ''
    if ($healthSections.Count -gt 0) {
        $healthHtml = @"
<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:8px;">Health Indicators</h2>
$($healthSections -join "`n")
"@
    }

    # --- Role detail table ---
    $headers = @('Name', 'Enabled', 'Requestable', 'Membership', 'Owner', 'Access Profiles')
    if ($hasTransitive) {
        $headers += 'Transitive Entitlements'
    }

    $thStyle = 'style="background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px; border:1px solid #dddddd;"'
    $headerRow = "<thead><tr>" + (($headers | ForEach-Object { "<th $thStyle>$_</th>" }) -join '') + "</tr></thead>"

    $bodyRows = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $roles -and $roles.Count -gt 0) {
        $rowIdx = 0
        foreach ($role in $roles) {
            $rowIdx++
            $bgColor = if (($rowIdx % 2) -eq 0) { '#f8f9fa' } else { '#ffffff' }
            $tdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; font-size:13px;"

            # Highlight: disabled in red tint, empty in orange tint
            $rowBg = $bgColor
            if (-not $role.Enabled) {
                $rowBg = '#fce4e4'
            } elseif ($role.AccessProfileCount -eq 0) {
                $rowBg = '#fff3e0'
            }

            $enabledDisplay = if ($role.Enabled) { '<span style="color:#27ae60;">Yes</span>' } else { '<span style="color:#e74c3c;">No</span>' }
            $requestableDisplay = if ($role.Requestable) { '<span style="color:#2980b9;">Yes</span>' } else { 'No' }

            $membershipDisplay = if ($role.MembershipType -eq 'STANDARD') {
                '<span style="color:#27ae60;">STANDARD</span>'
            } else {
                '<span style="color:#e67e22;">IDENTITY_LIST</span>'
            }

            # Access profile display with expandable detail
            $apDisplay = "$($role.AccessProfileCount)"
            if ($null -ne $role.AccessProfileNames -and $role.AccessProfileNames.Count -gt 0) {
                $apList = ($role.AccessProfileNames | ForEach-Object { ConvertTo-SafeHtml $_ }) -join '<br/>'
                $apDisplay = "<details><summary>$($role.AccessProfileCount)</summary><div style=""padding:4px 0; font-size:12px; color:#555555;"">$apList</div></details>"
            }

            $cells = @(
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $role.Name)</td>"
                "<td style=""$tdStyle"">$enabledDisplay</td>"
                "<td style=""$tdStyle"">$requestableDisplay</td>"
                "<td style=""$tdStyle"">$membershipDisplay</td>"
                "<td style=""$tdStyle"">$(ConvertTo-SafeHtml $role.OwnerName)</td>"
                "<td style=""$tdStyle"">$apDisplay</td>"
            )

            if ($hasTransitive) {
                $teDisplay = if ($null -ne $role.TransitiveEntitlements) { $role.TransitiveEntitlements } else { 'N/A' }
                $cells += "<td style=""$tdStyle"">$teDisplay</td>"
            }

            $bodyRows.Add("<tr style=""background:$rowBg;"">$($cells -join '')</tr>")
        }
    } else {
        $colSpan = $headers.Count
        $bodyRows.Add("<tr><td colspan=""$colSpan"" style=""padding:12px; text-align:center; font-style:italic; color:#999999;"">No roles found.</td></tr>")
    }

    $tableHtml = @"
<h2 style="font-size:16px; color:#336699; margin-top:24px; margin-bottom:8px;">Role Detail</h2>
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
<tbody>
$($bodyRows -join "`n")
</tbody>
</table>
"@

    # --- Assemble full HTML ---
    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Role Inventory Report</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Role Inventory Report</h1>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${summaryHtml}

${membershipHtml}

${healthHtml}

${tableHtml}

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Role inventory HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPRoleInventoryHtml' `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            ReportPath = $htmlFile
        }
    }
}


#endregion Inventory HTML Reports

#region Risk and Governance HTML

function Export-SPIdentityRiskHtml {
    <#
    .SYNOPSIS
        Generates an HTML identity risk report from Measure-SPIdentityRisk output.
    .DESCRIPTION
        Produces a Word-compatible HTML report with identities sorted by risk score.
        Includes risk tier badges (red/orange/green), per-identity detail rows
        showing contributing risk factors, and a summary card with tier distribution.
        Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
    .PARAMETER RiskData
        Hashtable output from Measure-SPIdentityRisk.
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    .EXAMPLE
        $risk = Measure-SPIdentityRisk -CampaignAudits $audits
        $path = Export-SPIdentityRiskHtml -RiskData $risk -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$RiskData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "IdentityRisk-${timestamp}.html"

    $summary    = $RiskData['Summary']
    $identities = @($RiskData['Identities'])

    # --- Summary card ---
    $summaryHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Total Identities<br/><span style="font-size:22px;">$($summary['TotalIdentities'])</span>
</td>
<td style="padding:12px 16px; background:#c0392b; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
High Risk<br/><span style="font-size:22px;">$($summary['High'])</span>
</td>
<td style="padding:12px 16px; background:#e67e22; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Medium Risk<br/><span style="font-size:22px;">$($summary['Medium'])</span>
</td>
<td style="padding:12px 16px; background:#27ae60; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Low Risk<br/><span style="font-size:22px;">$($summary['Low'])</span>
</td>
<td style="padding:12px 16px; background:#34495e; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Avg Score<br/><span style="font-size:22px;">$($summary['AvgRiskScore'])</span>
</td>
</tr>
</table>
"@

    # --- Identity table ---
    $headerRow = Build-HtmlTableHeader -Headers @(
        'Identity', 'Score', 'Tier', 'Privileged', 'Stale',
        'Rubber-Stamp', 'Orphan', 'Overdue', 'Campaigns', 'Last Review', 'Top Risk Factors'
    )

    $bodyRows = [System.Collections.Generic.List[string]]::new()
    $rowIdx = 0

    foreach ($id in $identities) {
        $rowIdx++

        $tierColor = switch ($id['RiskTier']) {
            'High'   { 'color:#fff; background:#c0392b;' }
            'Medium' { 'color:#fff; background:#e67e22;' }
            'Low'    { 'color:#fff; background:#27ae60;' }
            default  { 'color:#fff; background:#777777;' }
        }
        $tierBadge = "<span style=""display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; $tierColor"">$($id['RiskTier'])</span>"

        $orphanDisplay = if ($id['OrphanAccountFlag']) {
            '<span style="color:#c0392b; font-weight:bold;">Yes</span>'
        } else { 'No' }

        $lastReview = if (-not [string]::IsNullOrWhiteSpace($id['LastReviewDate'])) {
            ConvertTo-SafeHtml $id['LastReviewDate']
        } else { 'Never' }

        $factors = @($id['TopRiskFactors'])
        $factorsDisplay = if ($factors.Count -gt 0) {
            ($factors | ForEach-Object { ConvertTo-SafeHtml $_ }) -join ', '
        } else { '-' }

        $cells = @(
            (ConvertTo-SafeHtml $id['IdentityName']),
            [string]$id['RiskScore'],
            $tierBadge,
            [string]$id['PrivilegedAccessCount'],
            [string]$id['StaleAccessCount'],
            [string]$id['RubberStampApprovals'],
            $orphanDisplay,
            [string]$id['OverdueRemediations'],
            [string]$id['CampaignsReviewed'],
            $lastReview,
            $factorsDisplay
        )

        $bodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 0)))
    }

    $tableHtml = @"
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
<tbody>
$($bodyRows -join "`n")
</tbody>
</table>
"@

    # --- Per-tier sections ---
    $tierSections = [System.Collections.Generic.List[string]]::new()
    foreach ($tierName in @('High', 'Medium', 'Low')) {
        $tierIds = @($identities | Where-Object { $_['RiskTier'] -eq $tierName })
        if ($tierIds.Count -eq 0) { continue }

        $tierHeaderColor = switch ($tierName) {
            'High'   { '#c0392b' }
            'Medium' { '#e67e22' }
            'Low'    { '#27ae60' }
        }

        $detailHtml = "<h2 style=""font-size:16px; color:${tierHeaderColor}; margin-top:24px; margin-bottom:8px;"">${tierName} Risk Identities ($($tierIds.Count))</h2>"

        foreach ($id in $tierIds) {
            $nameHtml = ConvertTo-SafeHtml $id['IdentityName']
            $detailHtml += @"
<div style="margin-bottom:12px; padding:8px 12px; border-left:4px solid ${tierHeaderColor}; background:#fafafa;">
<strong>${nameHtml}</strong> (Score: $($id['RiskScore']))<br/>
<span style="font-size:12px; color:#666666;">
Privileged: $($id['PrivilegedAccessCount']) | Stale: $($id['StaleAccessCount']) | Rubber-Stamp: $($id['RubberStampApprovals']) | Orphan: $($id['OrphanAccountFlag']) | Overdue: $($id['OverdueRemediations']) | Campaigns: $($id['CampaignsReviewed']) | Last Review: $(if ($id['LastReviewDate']) { $id['LastReviewDate'] } else { 'Never' })
</span>
</div>
"@
        }

        $tierSections.Add($detailHtml)
    }

    # --- Assemble full HTML ---
    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Identity Risk Report</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Identity Risk Report</h1>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${summaryHtml}

<h2 style="font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;">All Identities by Risk Score</h2>
${tableHtml}

$($tierSections -join "`n")

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Identity risk HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPIdentityRiskHtml' `
        -CorrelationID $CorrelationID

    return $htmlFile
}


function Export-SPSourceGovernanceHtml {
    <#
    .SYNOPSIS
        Generates an HTML source governance scorecard from Measure-SPSourceGovernance output.
    .DESCRIPTION
        Produces a Word-compatible HTML report with per-source governance cards showing
        grade badges (color-coded A-F), entitlement coverage bars, privileged entitlement
        highlights, review recency indicators, and a summary card with overall coverage.
        Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
    .PARAMETER GovernanceData
        Hashtable output from Measure-SPSourceGovernance.
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    .EXAMPLE
        $gov = Measure-SPSourceGovernance -CampaignAudits $audits -EntitlementInventory $inv.Data
        $path = Export-SPSourceGovernanceHtml -GovernanceData $gov -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$GovernanceData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "SourceGovernance-${timestamp}.html"

    $summary = $GovernanceData['Summary']
    $sources = @($GovernanceData['Sources'])

    # --- Summary card ---
    $gradeDist = $summary['GradeDistribution']
    $summaryHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Total Sources<br/><span style="font-size:22px;">$($summary['TotalSources'])</span>
</td>
<td style="padding:12px 16px; background:#27ae60; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:14%; text-align:center;">
Grade A<br/><span style="font-size:22px;">$($gradeDist['A'])</span>
</td>
<td style="padding:12px 16px; background:#2980b9; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:14%; text-align:center;">
Grade B<br/><span style="font-size:22px;">$($gradeDist['B'])</span>
</td>
<td style="padding:12px 16px; background:#e67e22; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:14%; text-align:center;">
Grade C<br/><span style="font-size:22px;">$($gradeDist['C'])</span>
</td>
<td style="padding:12px 16px; background:#e74c3c; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:14%; text-align:center;">
Grade D<br/><span style="font-size:22px;">$($gradeDist['D'])</span>
</td>
<td style="padding:12px 16px; background:#c0392b; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:14%; text-align:center;">
Grade F<br/><span style="font-size:22px;">$($gradeDist['F'])</span>
</td>
<td style="padding:12px 16px; background:#34495e; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:14%; text-align:center;">
Coverage<br/><span style="font-size:22px;">$($summary['OverallCoveragePct'])%</span>
</td>
</tr>
</table>
"@

    # --- Source table ---
    $headerRow = Build-HtmlTableHeader -Headers @(
        'Source', 'Grade', 'Score', 'Entitlements', 'Reviewed',
        'Coverage %', 'Privileged', 'Priv Reviewed %', 'Campaigns',
        'Last Review', 'Days Since'
    )

    $bodyRows = [System.Collections.Generic.List[string]]::new()
    $rowIdx = 0

    foreach ($src in $sources) {
        $rowIdx++

        $gradeColor = switch ($src['GovernanceGrade']) {
            'A' { 'color:#fff; background:#27ae60;' }
            'B' { 'color:#fff; background:#2980b9;' }
            'C' { 'color:#fff; background:#e67e22;' }
            'D' { 'color:#fff; background:#e74c3c;' }
            'F' { 'color:#fff; background:#c0392b;' }
            default { 'color:#fff; background:#777777;' }
        }
        $gradeBadge = "<span style=""display:inline-block; padding:2px 10px; border-radius:3px; font-size:14px; font-weight:bold; $gradeColor"">$($src['GovernanceGrade'])</span>"

        $coverageDisplay = if ($src['EntitlementCoveragePct'] -eq 'Unknown') { 'Unknown' } else { "$($src['EntitlementCoveragePct'])%" }
        $privDisplay = if ($src['PrivilegedReviewedPct'] -eq 'Unknown') { 'Unknown' } else { "$($src['PrivilegedReviewedPct'])%" }
        $lastReview = if (-not [string]::IsNullOrWhiteSpace($src['LastReviewDate'])) {
            ConvertTo-SafeHtml $src['LastReviewDate']
        } else { 'Never' }
        $daysSince = if ($null -ne $src['DaysSinceLastReview']) {
            $d = $src['DaysSinceLastReview']
            if ($d -gt 365) {
                "<span style=""color:#c0392b; font-weight:bold;"">$d</span>"
            } elseif ($d -gt 180) {
                "<span style=""color:#e67e22;"">$d</span>"
            } else {
                [string]$d
            }
        } else { 'N/A' }

        $totalEntDisplay = if ($src['TotalEntitlements'] -eq 'Unknown') { 'Unknown' } else { [string]$src['TotalEntitlements'] }

        # Coverage bar
        $coverageBarHtml = ''
        if ($src['EntitlementCoveragePct'] -ne 'Unknown') {
            $pct = [int]$src['EntitlementCoveragePct']
            $barColor = if ($pct -ge 90) { '#27ae60' } elseif ($pct -ge 60) { '#e67e22' } else { '#c0392b' }
            $coverageBarHtml = "<div style=""width:60px; height:8px; background:#eeeeee; display:inline-block; vertical-align:middle; margin-left:4px;""><div style=""width:${pct}%; height:8px; background:${barColor};""></div></div>"
            $coverageDisplay = "$($src['EntitlementCoveragePct'])% $coverageBarHtml"
        }

        $cells = @(
            (ConvertTo-SafeHtml $src['SourceName']),
            $gradeBadge,
            [string]$src['GovernanceScore'],
            $totalEntDisplay,
            [string]$src['ReviewedEntitlements'],
            $coverageDisplay,
            [string]$src['PrivilegedEntitlements'],
            $privDisplay,
            [string]$src['CampaignCount'],
            $lastReview,
            $daysSince
        )

        $bodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 0)))
    }

    $tableHtml = @"
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
<tbody>
$($bodyRows -join "`n")
</tbody>
</table>
"@

    # --- Per-source detail cards ---
    $detailCards = [System.Collections.Generic.List[string]]::new()
    foreach ($src in $sources) {
        $gradeCardColor = switch ($src['GovernanceGrade']) {
            'A' { '#27ae60' }
            'B' { '#2980b9' }
            'C' { '#e67e22' }
            'D' { '#e74c3c' }
            'F' { '#c0392b' }
            default { '#777777' }
        }

        $nameHtml = ConvertTo-SafeHtml $src['SourceName']
        $totalEntStr = if ($src['TotalEntitlements'] -eq 'Unknown') { 'Unknown' } else { [string]$src['TotalEntitlements'] }
        $covPctStr = if ($src['EntitlementCoveragePct'] -eq 'Unknown') { 'Unknown' } else { "$($src['EntitlementCoveragePct'])%" }
        $privPctStr = if ($src['PrivilegedReviewedPct'] -eq 'Unknown') { 'Unknown' } else { "$($src['PrivilegedReviewedPct'])%" }
        $lastReviewStr = if (-not [string]::IsNullOrWhiteSpace($src['LastReviewDate'])) { $src['LastReviewDate'] } else { 'Never' }
        $cycleDaysStr = if ($null -ne $src['AvgReviewCycleDays']) { "$($src['AvgReviewCycleDays']) days" } else { 'N/A' }

        $cardHtml = @"
<div style="margin-bottom:16px; padding:12px 16px; border-left:5px solid ${gradeCardColor}; background:#fafafa; border:1px solid #eeeeee;">
<table style="width:100%; border-collapse:collapse;">
<tr>
<td style="vertical-align:top; width:70%; padding:0;">
<strong style="font-size:15px;">${nameHtml}</strong>
<span style="display:inline-block; padding:2px 10px; border-radius:3px; font-size:14px; font-weight:bold; color:#fff; background:${gradeCardColor}; margin-left:8px;">$($src['GovernanceGrade'])</span>
<span style="font-size:13px; color:#666666; margin-left:8px;">Score: $($src['GovernanceScore'])</span>
</td>
</tr>
</table>
<table style="width:100%; border-collapse:collapse; font-size:12px; color:#555555; margin-top:8px;">
<tr>
<td style="padding:2px 8px;">Entitlements: ${totalEntStr}</td>
<td style="padding:2px 8px;">Reviewed: $($src['ReviewedEntitlements'])</td>
<td style="padding:2px 8px;">Coverage: ${covPctStr}</td>
<td style="padding:2px 8px;">Privileged: $($src['PrivilegedEntitlements'])</td>
</tr>
<tr>
<td style="padding:2px 8px;">Priv Reviewed: ${privPctStr}</td>
<td style="padding:2px 8px;">Campaigns: $($src['CampaignCount'])</td>
<td style="padding:2px 8px;">Last Review: ${lastReviewStr}</td>
<td style="padding:2px 8px;">Avg Cycle: ${cycleDaysStr}</td>
</tr>
</table>
</div>
"@
        $detailCards.Add($cardHtml)
    }

    # --- Assemble full HTML ---
    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Source Governance Scorecard</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1200px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Source Governance Scorecard</h1>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${summaryHtml}

<h2 style="font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;">All Sources by Governance Score</h2>
${tableHtml}

<h2 style="font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;">Source Detail Cards</h2>
$($detailCards -join "`n")

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Source governance HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPSourceGovernanceHtml' `
        -CorrelationID $CorrelationID

    return $htmlFile
}


function Export-SPStaleAccessHtml {
    <#
    .SYNOPSIS
        Generates an HTML report from Get-SPStaleAccess output.
    .DESCRIPTION
        Produces a Word-compatible HTML report with stale access items grouped by source,
        sorted by classification (NeverReviewed first). Privileged entitlements are
        highlighted in red. Includes a summary card with total stale count and source
        breakdown. Uses inline CSS only (no flexbox/grid) for Word paste compatibility.
    .PARAMETER StaleData
        Hashtable output from Get-SPStaleAccess.
    .PARAMETER OutputPath
        Directory for the HTML output file.
    .PARAMETER CorrelationID
        Correlation ID for the report footer.
    .OUTPUTS
        [string] Path to the written HTML file.
    .EXAMPLE
        $stale = Get-SPStaleAccess -CampaignAudits $audits -StaleDays 180
        $path = Export-SPStaleAccessHtml -StaleData $stale -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$StaleData,

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

    $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $htmlFile    = Join-Path $OutputPath "StaleAccess-${timestamp}.html"

    $summary    = $StaleData['Summary']
    $staleItems = @($StaleData['StaleItems'])

    # --- Summary card ---
    $summaryHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Total Stale<br/><span style="font-size:22px;">$($summary['TotalStaleItems'])</span>
</td>
<td style="padding:12px 16px; background:#c0392b; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Never Reviewed<br/><span style="font-size:22px;">$($summary['NeverReviewed'])</span>
</td>
<td style="padding:12px 16px; background:#e67e22; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Expired<br/><span style="font-size:22px;">$($summary['Expired'])</span>
</td>
<td style="padding:12px 16px; background:#f39c12; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Partial Coverage<br/><span style="font-size:22px;">$($summary['PartialCoverage'])</span>
</td>
<td style="padding:12px 16px; background:#8e44ad; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:16%; text-align:center;">
Privileged Stale<br/><span style="font-size:22px;">$($summary['PrivilegedStale'])</span>
</td>
</tr>
</table>
"@

    # --- Source breakdown ---
    $sourceBreakdown = $summary['SourceBreakdown']
    $breakdownRows = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $sourceBreakdown -and $sourceBreakdown.Count -gt 0) {
        $sbIdx = 0
        foreach ($sName in ($sourceBreakdown.Keys | Sort-Object)) {
            $sbIdx++
            $cells = @((ConvertTo-SafeHtml $sName), [string]$sourceBreakdown[$sName])
            $breakdownRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($sbIdx % 2) -eq 0)))
        }
    }

    $breakdownHtml = ''
    if ($breakdownRows.Count -gt 0) {
        $bHeader = Build-HtmlTableHeader -Headers @('Source', 'Stale Items')
        $breakdownHtml = @"
<h2 style="font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;">Source Breakdown</h2>
<table style="width:50%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${bHeader}
<tbody>
$($breakdownRows -join "`n")
</tbody>
</table>
"@
    }

    # --- Main table grouped by source ---
    $headerRow = Build-HtmlTableHeader -Headers @(
        'Source', 'Entitlement', 'Privileged', 'Classification',
        'Identity Count', 'Last Review', 'Days Since Review'
    )

    $bodyRows = [System.Collections.Generic.List[string]]::new()
    $rowIdx = 0

    foreach ($item in $staleItems) {
        $rowIdx++

        # Classification badge
        $classColor = switch ($item['Classification']) {
            'NeverReviewed'   { 'color:#fff; background:#c0392b;' }
            'Expired'         { 'color:#fff; background:#e67e22;' }
            'PartialCoverage' { 'color:#fff; background:#f39c12;' }
            default           { 'color:#fff; background:#777777;' }
        }
        $classBadge = "<span style=""display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; $classColor"">$($item['Classification'])</span>"

        # Privileged highlight
        $privDisplay = if ($item['Privileged']) {
            '<span style="color:#c0392b; font-weight:bold;">Yes</span>'
        } else { 'No' }

        # Last review date
        $lastReview = if (-not [string]::IsNullOrWhiteSpace($item['LastReviewDate'])) {
            ConvertTo-SafeHtml $item['LastReviewDate']
        } else { 'Never' }

        # Days since review with color coding
        $daysSince = if ($null -ne $item['DaysSinceReview']) {
            $days = [int]$item['DaysSinceReview']
            $dayColor = if ($days -ge 365) { '#c0392b' } elseif ($days -ge 180) { '#e67e22' } else { '#27ae60' }
            "<span style=""color:${dayColor}; font-weight:bold;"">$days</span>"
        } else { '-' }

        $identityCount = if ($null -ne $item['IdentityCount']) { [string]$item['IdentityCount'] } else { '-' }

        $cells = @(
            (ConvertTo-SafeHtml $item['SourceName']),
            (ConvertTo-SafeHtml $item['EntitlementName']),
            $privDisplay,
            $classBadge,
            $identityCount,
            $lastReview,
            $daysSince
        )

        $bodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 0)))
    }

    $tableHtml = @"
<table style="width:100%; border-collapse:collapse; font-size:13px; margin-bottom:20px;">
${headerRow}
<tbody>
$($bodyRows -join "`n")
</tbody>
</table>
"@

    # --- Per-source detail sections ---
    $sourceSections = [System.Collections.Generic.List[string]]::new()

    # Group items by source
    $sourceGroups = @{}
    foreach ($item in $staleItems) {
        $sName = $item['SourceName']
        if ([string]::IsNullOrWhiteSpace($sName)) { $sName = $item['SourceId'] }
        if (-not $sourceGroups.ContainsKey($sName)) {
            $sourceGroups[$sName] = [System.Collections.Generic.List[hashtable]]::new()
        }
        $sourceGroups[$sName].Add($item)
    }

    foreach ($sName in ($sourceGroups.Keys | Sort-Object)) {
        $groupItems = $sourceGroups[$sName]
        $sectionHtml = "<h2 style=""font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;"">$(ConvertTo-SafeHtml $sName) ($($groupItems.Count) stale)</h2>"

        foreach ($item in $groupItems) {
            $entHtml = ConvertTo-SafeHtml $item['EntitlementName']
            $classLabel = $item['Classification']
            $borderColor = switch ($classLabel) {
                'NeverReviewed'   { '#c0392b' }
                'Expired'         { '#e67e22' }
                'PartialCoverage' { '#f39c12' }
                default           { '#777777' }
            }

            $privTag = if ($item['Privileged']) { ' <span style="color:#c0392b; font-weight:bold;">[PRIVILEGED]</span>' } else { '' }

            $lastReviewDetail = if (-not [string]::IsNullOrWhiteSpace($item['LastReviewDate'])) {
                $item['LastReviewDate']
            } else { 'Never' }

            $daysDetail = if ($null -ne $item['DaysSinceReview']) { "$($item['DaysSinceReview']) days" } else { 'N/A' }

            $sectionHtml += @"
<div style="margin-bottom:8px; padding:6px 12px; border-left:4px solid ${borderColor}; background:#fafafa;">
<strong>${entHtml}</strong>${privTag} - <em>${classLabel}</em><br/>
<span style="font-size:12px; color:#666666;">
Identities: $($item['IdentityCount']) | Last Review: ${lastReviewDetail} | Days Since: ${daysDetail}
</span>
</div>
"@
        }

        $sourceSections.Add($sectionHtml)
    }

    # --- Assemble full HTML ---
    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Stale Access Report</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1200px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Stale Access Report</h1>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${summaryHtml}

${breakdownHtml}

<h2 style="font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;">All Stale Access Items</h2>
${tableHtml}

$($sourceSections -join "`n")

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

    Write-SPLog -Message "Stale access HTML written: $htmlFile" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPStaleAccessHtml' `
        -CorrelationID $CorrelationID

    return $htmlFile
}


function Export-SPCampaignCompletionReport {
    <#
    .SYNOPSIS
        Generates a per-campaign completion report HTML file with KPIs and reviewer scorecard.
    .DESCRIPTION
        Produces a focused single-campaign wrap-up report with six sections:
        1) Campaign header  2) KPI dashboard  3) Cycle-over-cycle comparison
        4) Reviewer scorecard  5) Remediation tracking  6) Risk summary

        Designed as the operational "how did this campaign go?" report for campaign
        owners. Also serves as an attachment for the notification dispatcher (P12-06).
        Uses the same inline-CSS-only pattern as Export-SPAuditHtml for Word compatibility.
    .PARAMETER CampaignAudit
        Single campaign audit hashtable (same structure as Build-SingleCampaignHtml):
        CampaignName, CampaignId, Status, Created, Completed, Deadline,
        Decisions, Reviewers, ReviewerMetrics, RubberStampRisk, etc.
    .PARAMETER PreviousCycleAudit
        Optional campaign audit hashtable from the previous cycle of the same campaign
        type. When provided, a cycle-over-cycle comparison section is generated.
    .PARAMETER RemediationStatus
        Optional hashtable from Get-SPRemediationStatus. When provided, a remediation
        tracking section is generated.
    .PARAMETER OutputPath
        Directory for the HTML output file. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID for log entries and report footer.
    .OUTPUTS
        [hashtable] @{ Success; Data = @{ ReportPath; CampaignName; KPIs } }
    .EXAMPLE
        $result = Export-SPCampaignCompletionReport -CampaignAudit $audit -OutputPath '.\Audit'
        Write-Host "Report: $($result.Data.ReportPath)"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CampaignAudit,

        [Parameter()]
        [hashtable]$PreviousCycleAudit,

        [Parameter()]
        [hashtable]$RemediationStatus,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Generating campaign completion report" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCampaignCompletionReport' `
        -CorrelationID $CorrelationID

    try {
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $dateStamp   = (Get-Date).ToString('yyyy-MM-dd')

        # --- Extract campaign fields ---
        $campaignName = if ($CampaignAudit.ContainsKey('CampaignName') -and $null -ne $CampaignAudit['CampaignName']) { [string]$CampaignAudit['CampaignName'] } else { 'Unknown' }
        $campaignId   = if ($CampaignAudit.ContainsKey('CampaignId')   -and $null -ne $CampaignAudit['CampaignId'])   { [string]$CampaignAudit['CampaignId']   } else { '' }
        $status       = if ($CampaignAudit.ContainsKey('Status')       -and $null -ne $CampaignAudit['Status'])       { [string]$CampaignAudit['Status']       } else { '' }
        $createdRaw   = if ($CampaignAudit.ContainsKey('Created')      -and $null -ne $CampaignAudit['Created'])      { [string]$CampaignAudit['Created']      } else { '' }
        $completedRaw = if ($CampaignAudit.ContainsKey('Completed')    -and $null -ne $CampaignAudit['Completed'])    { [string]$CampaignAudit['Completed']    } else { '' }
        $deadlineRaw  = if ($CampaignAudit.ContainsKey('Deadline')     -and $null -ne $CampaignAudit['Deadline'])     { [string]$CampaignAudit['Deadline']     }
                        elseif ($CampaignAudit.ContainsKey('deadline')  -and $null -ne $CampaignAudit['deadline'])     { [string]$CampaignAudit['deadline']     }
                        else { '' }
        $campaignType = if ($CampaignAudit.ContainsKey('CampaignType')  -and $null -ne $CampaignAudit['CampaignType'])  { [string]$CampaignAudit['CampaignType']  } else { '' }

        $decisions       = if ($CampaignAudit.ContainsKey('Decisions')       -and $null -ne $CampaignAudit['Decisions'])       { $CampaignAudit['Decisions']       } else { @{ Approved = @(); Revoked = @(); Pending = @() } }
        $reviewerMetrics = if ($CampaignAudit.ContainsKey('ReviewerMetrics') -and $null -ne $CampaignAudit['ReviewerMetrics']) { $CampaignAudit['ReviewerMetrics'] } else { $null }
        $rubberStampRisk = if ($CampaignAudit.ContainsKey('RubberStampRisk') -and $null -ne $CampaignAudit['RubberStampRisk']) { $CampaignAudit['RubberStampRisk'] } else { $null }
        $riskFlags       = if ($CampaignAudit.ContainsKey('RiskFlags')       -and $null -ne $CampaignAudit['RiskFlags'])       { $CampaignAudit['RiskFlags']       } else { $null }

        # --- Decision counts ---
        $approvedCount = if ($null -ne $decisions['Approved']) { @($decisions['Approved']).Count } else { 0 }
        $revokedCount  = if ($null -ne $decisions['Revoked'])  { @($decisions['Revoked']).Count  } else { 0 }
        $pendingCount  = if ($null -ne $decisions['Pending'])  { @($decisions['Pending']).Count  } else { 0 }
        $totalItems    = $approvedCount + $revokedCount + $pendingCount
        $decidedCount  = $approvedCount + $revokedCount

        # --- KPI calculations ---
        $completionRate  = if ($totalItems -gt 0) { [Math]::Round(($decidedCount / $totalItems) * 100, 1) } else { 0.0 }
        $approvalRate    = if ($totalItems -gt 0) { [Math]::Round(($approvedCount / $totalItems) * 100, 1) } else { 0.0 }
        $revocationRate  = if ($totalItems -gt 0) { [Math]::Round(($revokedCount / $totalItems) * 100, 1) } else { 0.0 }

        $avgResponseHours = 0.0
        if ($null -ne $reviewerMetrics -and $null -ne $reviewerMetrics['CampaignAvgHours']) {
            $avgResponseHours = [Math]::Round([double]$reviewerMetrics['CampaignAvgHours'], 1)
        }
        elseif ($null -ne $reviewerMetrics -and $null -ne $reviewerMetrics.CampaignAvgHours) {
            $avgResponseHours = [Math]::Round([double]$reviewerMetrics.CampaignAvgHours, 1)
        }

        # On-time completion
        $onTimeCompletion = $false
        $dtCreated   = $null
        $dtCompleted = $null
        $dtDeadline  = $null

        if (-not [string]::IsNullOrWhiteSpace($createdRaw)) {
            try { $dtCreated = [datetime]::Parse($createdRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($completedRaw)) {
            try { $dtCompleted = [datetime]::Parse($completedRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($deadlineRaw)) {
            try { $dtDeadline = [datetime]::Parse($deadlineRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
        }

        if ($null -ne $dtCompleted -and $null -ne $dtDeadline) {
            $onTimeCompletion = ($dtCompleted.ToUniversalTime() -le $dtDeadline.ToUniversalTime())
        }
        elseif ($null -ne $dtCompleted) {
            # No deadline -- treat as on-time
            $onTimeCompletion = $true
        }

        # Duration display
        $durationDisplay = 'N/A'
        if ($null -ne $dtCreated -and $null -ne $dtCompleted) {
            $durationHours = ($dtCompleted - $dtCreated).TotalHours
            if ($durationHours -lt 0) { $durationHours = 0 }
            $durationDisplay = Format-HoursDisplay $durationHours
        }

        # --- Inline styles ---
        $sectionHeadStyle = 'style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;"'
        $tableStyle       = 'style="width:100%; border-collapse:collapse; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px; margin-bottom:20px;"'
        $summaryTdLabel   = 'style="padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;"'
        $summaryTdValue   = 'style="padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;"'

        $statusColor = switch ($status.ToUpperInvariant()) {
            'COMPLETED' { '#339933' }
            'ACTIVE'    { '#336699' }
            'STAGED'    { '#FF8800' }
            default     { '#777777' }
        }
        $statusBadge = "<span style=""display:inline-block; padding:3px 10px; border-radius:3px; color:#ffffff; background:${statusColor}; font-size:12px; font-weight:bold;"">$(ConvertTo-SafeHtml $status)</span>"

        $onTimeDisplay = if ($onTimeCompletion) {
            '<span style="color:#339933; font-weight:bold;">Yes</span>'
        } else {
            '<span style="color:#CC3333; font-weight:bold;">No</span>'
        }

        # ===================================================================
        # SECTION 1: Campaign Header
        # ===================================================================
        $headerHtml = @"
<h2 style="font-size:16px; color:#2c3e50; margin-top:24px; margin-bottom:8px;">1. Campaign Overview</h2>
<table $tableStyle>
<tbody>
<tr><td $summaryTdLabel>Campaign Name</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campaignName)</td></tr>
<tr><td $summaryTdLabel>Campaign ID</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campaignId)</td></tr>
<tr><td $summaryTdLabel>Type</td><td $summaryTdValue>$(ConvertTo-SafeHtml $campaignType)</td></tr>
<tr><td $summaryTdLabel>Status</td><td $summaryTdValue>${statusBadge}</td></tr>
<tr><td $summaryTdLabel>Created</td><td $summaryTdValue>$(Format-HtmlDate $createdRaw)</td></tr>
<tr><td $summaryTdLabel>Completed</td><td $summaryTdValue>$(Format-HtmlDate $completedRaw)</td></tr>
<tr><td $summaryTdLabel>Deadline</td><td $summaryTdValue>$(Format-HtmlDate $deadlineRaw)</td></tr>
<tr><td $summaryTdLabel>Duration</td><td $summaryTdValue>$(ConvertTo-SafeHtml $durationDisplay)</td></tr>
</tbody>
</table>
"@

        # ===================================================================
        # SECTION 2: KPI Dashboard
        # ===================================================================
        $kpiHtml = @"
<h2 $sectionHeadStyle>2. KPI Dashboard</h2>
<table style="width:100%; border-collapse:collapse; margin-bottom:20px;">
<tr>
<td style="padding:12px 16px; background:#336699; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Completion<br/><span style="font-size:22px;">${completionRate}%</span>
</td>
<td style="padding:12px 16px; background:#339933; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Approval Rate<br/><span style="font-size:22px;">${approvalRate}%</span>
</td>
<td style="padding:12px 16px; background:#CC3333; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Revocation Rate<br/><span style="font-size:22px;">${revocationRate}%</span>
</td>
<td style="padding:12px 16px; background:#34495e; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
Avg Response<br/><span style="font-size:22px;">$(Format-HoursDisplay $avgResponseHours)</span>
</td>
<td style="padding:12px 16px; background:#34495e; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:20%; text-align:center;">
On-Time<br/><span style="font-size:22px;">${onTimeDisplay}</span>
</td>
</tr>
</table>
<table $tableStyle>
<tbody>
<tr><td $summaryTdLabel>Total Items</td><td $summaryTdValue>${totalItems}</td></tr>
<tr><td $summaryTdLabel>Approved</td><td $summaryTdValue>${approvedCount}</td></tr>
<tr><td $summaryTdLabel>Revoked</td><td $summaryTdValue>${revokedCount}</td></tr>
<tr><td $summaryTdLabel>Pending</td><td $summaryTdValue>${pendingCount}</td></tr>
</tbody>
</table>
"@

        # ===================================================================
        # SECTION 3: Cycle-over-Cycle Comparison
        # ===================================================================
        $comparisonHtml = ''
        if ($null -ne $PreviousCycleAudit) {
            $prevDecisions   = if ($PreviousCycleAudit.ContainsKey('Decisions') -and $null -ne $PreviousCycleAudit['Decisions']) { $PreviousCycleAudit['Decisions'] } else { @{ Approved = @(); Revoked = @(); Pending = @() } }
            $prevApproved    = if ($null -ne $prevDecisions['Approved']) { @($prevDecisions['Approved']).Count } else { 0 }
            $prevRevoked     = if ($null -ne $prevDecisions['Revoked'])  { @($prevDecisions['Revoked']).Count  } else { 0 }
            $prevPending     = if ($null -ne $prevDecisions['Pending'])  { @($prevDecisions['Pending']).Count  } else { 0 }
            $prevTotal       = $prevApproved + $prevRevoked + $prevPending
            $prevDecided     = $prevApproved + $prevRevoked

            $prevApprovalRate   = if ($prevTotal -gt 0) { [Math]::Round(($prevApproved / $prevTotal) * 100, 1) } else { 0.0 }
            $prevRevocationRate = if ($prevTotal -gt 0) { [Math]::Round(($prevRevoked / $prevTotal) * 100, 1) } else { 0.0 }
            $prevCompletionRate = if ($prevTotal -gt 0) { [Math]::Round(($prevDecided / $prevTotal) * 100, 1) } else { 0.0 }

            $prevAvgResponse = 0.0
            $prevReviewerMetrics = if ($PreviousCycleAudit.ContainsKey('ReviewerMetrics') -and $null -ne $PreviousCycleAudit['ReviewerMetrics']) { $PreviousCycleAudit['ReviewerMetrics'] } else { $null }
            if ($null -ne $prevReviewerMetrics -and $null -ne $prevReviewerMetrics['CampaignAvgHours']) {
                $prevAvgResponse = [Math]::Round([double]$prevReviewerMetrics['CampaignAvgHours'], 1)
            }
            elseif ($null -ne $prevReviewerMetrics -and $null -ne $prevReviewerMetrics.CampaignAvgHours) {
                $prevAvgResponse = [Math]::Round([double]$prevReviewerMetrics.CampaignAvgHours, 1)
            }

            $prevCampaignName = if ($PreviousCycleAudit.ContainsKey('CampaignName') -and $null -ne $PreviousCycleAudit['CampaignName']) { [string]$PreviousCycleAudit['CampaignName'] } else { 'Previous Cycle' }

            # Delta calculations with arrow indicators
            $deltaApproval   = [Math]::Round($approvalRate - $prevApprovalRate, 1)
            $deltaRevocation = [Math]::Round($revocationRate - $prevRevocationRate, 1)
            $deltaResponse   = [Math]::Round($avgResponseHours - $prevAvgResponse, 1)
            $deltaRevCount   = $revokedCount - $prevRevoked

            # Format delta cells with color coding
            # For approval rate: up is neutral, down is neutral (depends on context)
            # For response time: down (faster) is green, up (slower) is red
            $approvalDeltaColor = if ($deltaApproval -gt 0) { '#336699' } elseif ($deltaApproval -lt 0) { '#CC3333' } else { '#777777' }
            $approvalArrow = if ($deltaApproval -gt 0) { '&#9650;' } elseif ($deltaApproval -lt 0) { '&#9660;' } else { '&#9644;' }

            $responseDeltaColor = if ($deltaResponse -lt 0) { '#339933' } elseif ($deltaResponse -gt 0) { '#CC3333' } else { '#777777' }
            $responseArrow = if ($deltaResponse -lt 0) { '&#9660;' } elseif ($deltaResponse -gt 0) { '&#9650;' } else { '&#9644;' }

            $revCountDeltaColor = if ($deltaRevCount -gt 0) { '#CC3333' } elseif ($deltaRevCount -lt 0) { '#339933' } else { '#777777' }
            $revCountArrow = if ($deltaRevCount -gt 0) { '&#9650;' } elseif ($deltaRevCount -lt 0) { '&#9660;' } else { '&#9644;' }

            $comparisonHtml = @"
<h2 $sectionHeadStyle>3. Cycle-over-Cycle Comparison</h2>
<p style="font-size:13px; color:#666666; margin-bottom:8px;">Comparing with: $(ConvertTo-SafeHtml $prevCampaignName)</p>
<table $tableStyle>
$(Build-HtmlTableHeader -Headers @('Metric', 'Current', 'Previous', 'Delta'))
<tbody>
$(Build-HtmlTableRow -Cells @('Approval Rate', "${approvalRate}%", "${prevApprovalRate}%", "<span style=""color:${approvalDeltaColor}; font-weight:bold;"">${approvalArrow} ${deltaApproval}%</span>") -IsAlternate $false)
$(Build-HtmlTableRow -Cells @('Revocation Rate', "${revocationRate}%", "${prevRevocationRate}%", "<span style=""color:${revCountDeltaColor}; font-weight:bold;"">${revCountArrow} $([Math]::Round($revocationRate - $prevRevocationRate, 1))%</span>") -IsAlternate $true)
$(Build-HtmlTableRow -Cells @('Revocation Count', "${revokedCount}", "${prevRevoked}", "<span style=""color:${revCountDeltaColor}; font-weight:bold;"">${revCountArrow} ${deltaRevCount}</span>") -IsAlternate $false)
$(Build-HtmlTableRow -Cells @('Avg Response Time', "$(Format-HoursDisplay $avgResponseHours)", "$(Format-HoursDisplay $prevAvgResponse)", "<span style=""color:${responseDeltaColor}; font-weight:bold;"">${responseArrow} $(Format-HoursDisplay ([Math]::Abs($deltaResponse)))</span>") -IsAlternate $true)
$(Build-HtmlTableRow -Cells @('Total Items', "${totalItems}", "${prevTotal}", "$($totalItems - $prevTotal)") -IsAlternate $false)
</tbody>
</table>
"@
        }
        else {
            $comparisonHtml = @"
<h2 $sectionHeadStyle>3. Cycle-over-Cycle Comparison</h2>
<p style="font-size:13px; color:#888888; padding:12px; background:#f9f9f9; border-left:4px solid #dddddd;">No prior cycle data available for comparison.</p>
"@
        }

        # ===================================================================
        # SECTION 4: Reviewer Scorecard
        # ===================================================================
        $reviewerHtml = "<h2 $sectionHeadStyle>4. Reviewer Scorecard</h2>"

        $reviewerList = @()
        if ($null -ne $reviewerMetrics) {
            if ($null -ne $reviewerMetrics['ReviewerMetrics']) {
                $reviewerList = @($reviewerMetrics['ReviewerMetrics'])
            }
            elseif ($null -ne $reviewerMetrics.ReviewerMetrics) {
                $reviewerList = @($reviewerMetrics.ReviewerMetrics)
            }
        }

        # Build rubber-stamp lookup
        $rubberStampMap = @{}
        if ($null -ne $rubberStampRisk) {
            $rsReviewers = @()
            if ($null -ne $rubberStampRisk['ReviewerRisks']) {
                $rsReviewers = @($rubberStampRisk['ReviewerRisks'])
            }
            elseif ($null -ne $rubberStampRisk.ReviewerRisks) {
                $rsReviewers = @($rubberStampRisk.ReviewerRisks)
            }
            foreach ($rs in $rsReviewers) {
                $rsName = ''
                if ($null -ne $rs.Name) { $rsName = [string]$rs.Name }
                elseif ($null -ne $rs.ReviewerName) { $rsName = [string]$rs.ReviewerName }
                if (-not [string]::IsNullOrWhiteSpace($rsName)) {
                    $rsSeverity = ''
                    if ($null -ne $rs.Severity) { $rsSeverity = [string]$rs.Severity }
                    elseif ($null -ne $rs.RiskLevel) { $rsSeverity = [string]$rs.RiskLevel }
                    $rubberStampMap[$rsName] = $rsSeverity
                }
            }
        }

        if ($reviewerList.Count -gt 0) {
            $revHeaderRow = Build-HtmlTableHeader -Headers @('Reviewer', 'Items', 'Decisions', 'Pending', 'Avg Response', 'Rubber-Stamp Risk')
            $revBodyRows = [System.Collections.Generic.List[string]]::new()
            $revIdx = 0

            foreach ($rev in $reviewerList) {
                $revIdx++
                $revName       = if ($null -ne $rev.Name)          { ConvertTo-SafeHtml $rev.Name }          else { 'Unknown' }
                $revTotalItems = if ($null -ne $rev.TotalItems)    { [int]$rev.TotalItems }    else { 0 }
                $revDecisions  = if ($null -ne $rev.DecisionsMade) { [int]$rev.DecisionsMade } else { 0 }
                $revPending    = $revTotalItems - $revDecisions
                if ($revPending -lt 0) { $revPending = 0 }
                $revAvgHours   = if ($null -ne $rev.AvgHours)     { Format-HoursDisplay $rev.AvgHours }     else { 'N/A' }

                # Rubber-stamp flag
                $rsFlag = 'None'
                $rsFlagHtml = '<span style="color:#339933;">None</span>'
                $revNameRaw = if ($null -ne $rev.Name) { [string]$rev.Name } else { '' }
                if ($rubberStampMap.ContainsKey($revNameRaw)) {
                    $rsFlag = $rubberStampMap[$revNameRaw]
                    $rsFlagHtml = switch ($rsFlag.ToUpperInvariant()) {
                        'HIGH'   { '<span style="color:#CC3333; font-weight:bold;">High</span>' }
                        'MEDIUM' { '<span style="color:#FF8800; font-weight:bold;">Medium</span>' }
                        'LOW'    { '<span style="color:#336699;">Low</span>' }
                        default  { '<span style="color:#339933;">None</span>' }
                    }
                }

                $cells = @($revName, [string]$revTotalItems, [string]$revDecisions, [string]$revPending, $revAvgHours, $rsFlagHtml)
                $revBodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($revIdx % 2) -eq 0)))
            }

            $reviewerHtml += @"
<table $tableStyle>
${revHeaderRow}
<tbody>
$($revBodyRows -join "`n")
</tbody>
</table>
"@
        }
        else {
            $reviewerHtml += '<p style="font-size:13px; color:#888888; padding:12px; background:#f9f9f9; border-left:4px solid #dddddd;">No reviewer metrics available.</p>'
        }

        # ===================================================================
        # SECTION 5: Remediation Tracking
        # ===================================================================
        $remediationHtml = "<h2 $sectionHeadStyle>5. Remediation Tracking</h2>"

        if ($null -ne $RemediationStatus -and $null -ne $RemediationStatus['Data']) {
            $remData = $RemediationStatus['Data']
            $remItems = @()
            if ($null -ne $remData.Items) { $remItems = @($remData.Items) }
            elseif ($null -ne $remData['Items']) { $remItems = @($remData['Items']) }

            $remProvisionedCount = 0
            $remPendingCount     = 0
            $remOverdueCount     = 0
            $remFailedCount      = 0
            $remDaysList         = [System.Collections.Generic.List[double]]::new()

            foreach ($ri in $remItems) {
                $riStatus = ''
                if ($null -ne $ri.Status) { $riStatus = [string]$ri.Status }
                elseif ($null -ne $ri['Status']) { $riStatus = [string]$ri['Status'] }

                switch ($riStatus.ToUpperInvariant()) {
                    'PROVISIONED' { $remProvisionedCount++ }
                    'COMPLETED'   { $remProvisionedCount++ }
                    'PENDING'     { $remPendingCount++ }
                    'OVERDUE'     { $remOverdueCount++ }
                    'FAILED'      { $remFailedCount++ }
                    default       { $remPendingCount++ }
                }

                # Collect days to remediate for completed items
                $remDays = $null
                if ($null -ne $ri.DaysToRemediate) { $remDays = $ri.DaysToRemediate }
                elseif ($null -ne $ri['DaysToRemediate']) { $remDays = $ri['DaysToRemediate'] }
                if ($null -ne $remDays) {
                    try { $remDaysList.Add([double]$remDays) } catch { }
                }
            }

            $remTotal = $remProvisionedCount + $remPendingCount + $remOverdueCount + $remFailedCount
            $slaCompliancePct = if ($remTotal -gt 0) { [Math]::Round(($remProvisionedCount / $remTotal) * 100, 1) } else { 0.0 }
            $avgDaysToRemediate = if ($remDaysList.Count -gt 0) { [Math]::Round(($remDaysList | Measure-Object -Average).Average, 1) } else { 0.0 }

            $slaColor = if ($slaCompliancePct -ge 90) { '#339933' } elseif ($slaCompliancePct -ge 70) { '#FF8800' } else { '#CC3333' }

            $remediationHtml += @"
<table style="width:100%; border-collapse:collapse; margin-bottom:16px;">
<tr>
<td style="padding:12px 16px; background:${slaColor}; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
SLA Compliance<br/><span style="font-size:22px;">${slaCompliancePct}%</span>
</td>
<td style="padding:12px 16px; background:#34495e; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Avg Days to Remediate<br/><span style="font-size:22px;">${avgDaysToRemediate}</span>
</td>
<td style="padding:12px 16px; background:#34495e; color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Total Remediations<br/><span style="font-size:22px;">${remTotal}</span>
</td>
<td style="padding:12px 16px; background:$(if ($remOverdueCount -gt 0) { '#CC3333' } else { '#339933' }); color:#ffffff; font-weight:bold; border:1px solid #dddddd; width:25%; text-align:center;">
Overdue<br/><span style="font-size:22px;">${remOverdueCount}</span>
</td>
</tr>
</table>
<table $tableStyle>
$(Build-HtmlTableHeader -Headers @('Status', 'Count'))
<tbody>
$(Build-HtmlTableRow -Cells @('Provisioned / Completed', [string]$remProvisionedCount) -IsAlternate $false)
$(Build-HtmlTableRow -Cells @('Pending', [string]$remPendingCount) -IsAlternate $true)
$(Build-HtmlTableRow -Cells @('Overdue', "<span style=""color:#CC3333; font-weight:bold;"">${remOverdueCount}</span>") -IsAlternate $false)
$(Build-HtmlTableRow -Cells @('Failed', "<span style=""color:#CC3333; font-weight:bold;"">${remFailedCount}</span>") -IsAlternate $true)
</tbody>
</table>
"@
        }
        else {
            $remediationHtml += '<p style="font-size:13px; color:#888888; padding:12px; background:#f9f9f9; border-left:4px solid #dddddd;">Remediation data not available.</p>'
        }

        # ===================================================================
        # SECTION 6: Risk Summary
        # ===================================================================
        $riskHtml = "<h2 $sectionHeadStyle>6. Risk Summary</h2>"

        $riskSummary = $null
        if ($null -ne $riskFlags) {
            if ($null -ne $riskFlags['Summary']) { $riskSummary = $riskFlags['Summary'] }
            elseif ($null -ne $riskFlags.Summary) { $riskSummary = $riskFlags.Summary }
        }

        if ($null -ne $riskSummary) {
            $riskTotal   = if ($null -ne $riskSummary['Total'])   { [int]$riskSummary['Total'] }   elseif ($null -ne $riskSummary.Total)   { [int]$riskSummary.Total }   else { 0 }
            $riskFlagged = if ($null -ne $riskSummary['Flagged']) { [int]$riskSummary['Flagged'] } elseif ($null -ne $riskSummary.Flagged) { [int]$riskSummary.Flagged } else { 0 }

            $byFlag = $null
            if ($null -ne $riskSummary['ByFlag']) { $byFlag = $riskSummary['ByFlag'] }
            elseif ($null -ne $riskSummary.ByFlag) { $byFlag = $riskSummary.ByFlag }

            $riskHtml += @"
<table $tableStyle>
<tbody>
<tr><td $summaryTdLabel>Total Items Assessed</td><td $summaryTdValue>${riskTotal}</td></tr>
<tr><td $summaryTdLabel>Items with Risk Flags</td><td $summaryTdValue><span style="color:#CC3333; font-weight:bold;">${riskFlagged}</span></td></tr>
</tbody>
</table>
"@

            if ($null -ne $byFlag) {
                $flagHeaderRow = Build-HtmlTableHeader -Headers @('Risk Flag', 'Count')
                $flagBodyRows = [System.Collections.Generic.List[string]]::new()
                $flagIdx = 0

                $flagKeys = @()
                if ($byFlag -is [hashtable]) { $flagKeys = @($byFlag.Keys) }
                elseif ($null -ne $byFlag.PSObject.Properties) { $flagKeys = @($byFlag.PSObject.Properties.Name) }

                foreach ($flagName in ($flagKeys | Sort-Object)) {
                    $flagIdx++
                    $flagCount = 0
                    if ($byFlag -is [hashtable]) { $flagCount = [int]$byFlag[$flagName] }
                    else { $flagCount = [int]$byFlag.$flagName }

                    $flagColor = switch ($flagName.ToUpperInvariant()) {
                        'PRIVILEGED' { '#CC3333' }
                        'TERMINATED' { '#CC3333' }
                        'ORPHAN'     { '#CC3333' }
                        'STALE'      { '#FF8800' }
                        default      { '#777777' }
                    }

                    $cells = @(
                        "<span style=""color:${flagColor}; font-weight:bold;"">$(ConvertTo-SafeHtml $flagName)</span>",
                        [string]$flagCount
                    )
                    $flagBodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($flagIdx % 2) -eq 0)))
                }

                $riskHtml += @"
<table $tableStyle>
${flagHeaderRow}
<tbody>
$($flagBodyRows -join "`n")
</tbody>
</table>
"@
            }
        }
        else {
            # Fall back: count risk flags from decision items directly
            $allDecisionItems = @()
            foreach ($cat in @('Approved', 'Revoked', 'Pending')) {
                if ($null -ne $decisions[$cat]) { $allDecisionItems += @($decisions[$cat]) }
            }

            $flagCounts = @{}
            foreach ($item in $allDecisionItems) {
                $itemFlags = @()
                if ($null -ne $item.RiskFlags) { $itemFlags = @($item.RiskFlags) }
                elseif ($null -ne $item.PSObject -and $null -ne $item.PSObject.Properties['RiskFlags']) { $itemFlags = @($item.RiskFlags) }

                foreach ($f in $itemFlags) {
                    if ([string]::IsNullOrWhiteSpace($f)) { continue }
                    $fName = [string]$f
                    if ($flagCounts.ContainsKey($fName)) { $flagCounts[$fName]++ }
                    else { $flagCounts[$fName] = 1 }
                }
            }

            if ($flagCounts.Count -gt 0) {
                $flagHeaderRow = Build-HtmlTableHeader -Headers @('Risk Flag', 'Count')
                $flagBodyRows = [System.Collections.Generic.List[string]]::new()
                $flagIdx = 0

                foreach ($flagName in ($flagCounts.Keys | Sort-Object)) {
                    $flagIdx++
                    $flagColor = switch ($flagName.ToUpperInvariant()) {
                        'PRIVILEGED' { '#CC3333' }
                        'TERMINATED' { '#CC3333' }
                        'ORPHAN'     { '#CC3333' }
                        'STALE'      { '#FF8800' }
                        default      { '#777777' }
                    }
                    $cells = @(
                        "<span style=""color:${flagColor}; font-weight:bold;"">$(ConvertTo-SafeHtml $flagName)</span>",
                        [string]$flagCounts[$flagName]
                    )
                    $flagBodyRows.Add((Build-HtmlTableRow -Cells $cells -IsAlternate (($flagIdx % 2) -eq 0)))
                }

                $riskHtml += @"
<table $tableStyle>
${flagHeaderRow}
<tbody>
$($flagBodyRows -join "`n")
</tbody>
</table>
"@
            }
            else {
                $riskHtml += '<p style="font-size:13px; color:#888888; padding:12px; background:#f9f9f9; border-left:4px solid #dddddd;">No risk flags detected in this campaign.</p>'
            }
        }

        # ===================================================================
        # Assemble full HTML
        # ===================================================================
        $nameSlug = ($campaignName -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLower()
        if ([string]::IsNullOrWhiteSpace($nameSlug)) { $nameSlug = 'campaign' }
        $fileName = "completion-${nameSlug}-${dateStamp}.html"
        $htmlFile = Join-Path $OutputPath $fileName

        $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>Campaign Completion Report - $(ConvertTo-SafeHtml $campaignName)</title>
</head>
<body style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:20px; color:#333333;">

<h1 style="font-size:22px; color:#2c3e50; margin-bottom:4px;">Campaign Completion Report</h1>
<p style="font-size:15px; color:#336699; margin-top:0; margin-bottom:4px;">$(ConvertTo-SafeHtml $campaignName)</p>
<p style="font-size:13px; color:#888888; margin-top:0;">Generated: ${generatedAt}</p>

${headerHtml}
${kpiHtml}
${comparisonHtml}
${reviewerHtml}
${remediationHtml}
${riskHtml}

<hr style="border:none; border-top:1px solid #dddddd; margin:20px 0;" />
<p style="font-size:11px; color:#aaaaaa;">Generated: ${generatedAt} | Correlation: ${CorrelationID} | SailPoint Governance Toolkit</p>

</body>
</html>
"@

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

        Write-SPLog -Message "Campaign completion report written: $htmlFile" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCampaignCompletionReport' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data = @{
                ReportPath       = $htmlFile
                CampaignName     = $campaignName
                KPIs = @{
                    CompletionRate   = $completionRate
                    ApprovalRate     = $approvalRate
                    RevocationRate   = $revocationRate
                    AvgResponseHours = $avgResponseHours
                    OnTimeCompletion = $onTimeCompletion
                }
            }
        }
    }
    catch {
        $errMsg = "Export-SPCampaignCompletionReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditReport' `
            -Action 'Export-SPCampaignCompletionReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}


#endregion Risk and Governance HTML

#region Orchestrator and BI Export

function Export-SPOrchestratorHistoryHtml {
    <#
    .SYNOPSIS
        Generates an HTML dashboard of orchestrator run history.
    .DESCRIPTION
        Takes the output of Get-SPOrchestratorHistory and produces a self-contained
        HTML report with run timeline, metrics cards, step reliability bars, duration
        trend, and failure details.
    .PARAMETER HistoryData
        Output from Get-SPOrchestratorHistory.
    .PARAMETER OutputPath
        Directory to write the HTML file.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] Success flag and report path.
    .EXAMPLE
        $history = Get-SPOrchestratorHistory -DaysBack 30
        Export-SPOrchestratorHistoryHtml -HistoryData $history -OutputPath './Audit'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$HistoryData,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Generating orchestrator history HTML report" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPOrchestratorHistoryHtml' `
        -CorrelationID $CorrelationID

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $m = $HistoryData.Metrics
    $runs = $HistoryData.Runs
    $reportDate = (Get-Date).ToString('yyyy-MM-dd')
    $fileName = "orchestrator-history-$reportDate.html"
    $filePath = Join-Path $OutputPath $fileName

    # --- Exit code color helper ---
    function Get-ExitCodeColor {
        param([int]$Code)
        switch ($Code) {
            0 { return '#27ae60' }  # green
            1 { return '#f39c12' }  # yellow/orange
            4 { return '#e74c3c' }  # red
            5 { return '#c0392b' }  # dark red
            default { return '#e74c3c' }
        }
    }

    function Get-ExitCodeLabel {
        param([int]$Code)
        switch ($Code) {
            0 { return 'Success' }
            1 { return 'Warnings' }
            4 { return 'Config Error' }
            5 { return 'Critical' }
            default { return "Exit $Code" }
        }
    }

    # --- Build HTML ---
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8"/>')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1.0"/>')
    [void]$sb.AppendLine("<title>Orchestrator Run History - $reportDate</title>")
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body { font-family: -apple-system, "Segoe UI", system-ui, sans-serif; margin: 20px; background: #f5f6fa; color: #2c3e50; }')
    [void]$sb.AppendLine('h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }')
    [void]$sb.AppendLine('h2 { color: #34495e; margin-top: 30px; }')
    [void]$sb.AppendLine('.card-row { display: flex; flex-wrap: wrap; gap: 16px; margin: 16px 0; }')
    [void]$sb.AppendLine('.card { background: #fff; border-radius: 8px; padding: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); min-width: 180px; flex: 1; }')
    [void]$sb.AppendLine('.card .label { font-size: 12px; color: #7f8c8d; text-transform: uppercase; margin-bottom: 4px; }')
    [void]$sb.AppendLine('.card .value { font-size: 28px; font-weight: bold; }')
    [void]$sb.AppendLine('.card .sub { font-size: 12px; color: #95a5a6; margin-top: 4px; }')
    [void]$sb.AppendLine('table { border-collapse: collapse; width: 100%; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin: 16px 0; }')
    [void]$sb.AppendLine('.bar-container { background: #ecf0f1; border-radius: 4px; height: 20px; width: 100%; }')
    [void]$sb.AppendLine('.bar-fill { height: 20px; border-radius: 4px; text-align: center; color: #fff; font-size: 11px; line-height: 20px; }')
    [void]$sb.AppendLine('.badge { display: inline-block; padding: 2px 8px; border-radius: 4px; color: #fff; font-size: 12px; font-weight: bold; }')
    [void]$sb.AppendLine('.failure-detail { background: #fdf0ed; border-left: 4px solid #e74c3c; padding: 12px; margin: 8px 0; border-radius: 0 4px 4px 0; }')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head><body>')

    # Title
    [void]$sb.AppendLine("<h1>Orchestrator Run History</h1>")
    [void]$sb.AppendLine("<p>Generated: $(ConvertTo-SafeHtml (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | Runs analyzed: $(ConvertTo-SafeHtml $m.RunCount)</p>")

    # --- Metrics cards ---
    [void]$sb.AppendLine('<h2>Operational Metrics</h2>')
    [void]$sb.AppendLine('<div class="card-row">')

    # Success Rate card
    $srColor = if ($m.SuccessRate -ge 90) { '#27ae60' } elseif ($m.SuccessRate -ge 70) { '#f39c12' } else { '#e74c3c' }
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"label`">Success Rate</div><div class=`"value`" style=`"color:$srColor`">$(ConvertTo-SafeHtml $m.SuccessRate)%</div><div class=`"sub`">$($m.RunCount) total runs</div></div>")

    # Avg Duration card
    $durationMin = [math]::Round($m.AvgDurationSeconds / 60, 1)
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"label`">Avg Duration</div><div class=`"value`">$(ConvertTo-SafeHtml $durationMin)m</div><div class=`"sub`">Trend: $(ConvertTo-SafeHtml $m.DurationTrend)</div></div>")

    # Consecutive Failures card
    $cfColor = if ($m.ConsecutiveFailures -eq 0) { '#27ae60' } elseif ($m.ConsecutiveFailures -le 2) { '#f39c12' } else { '#e74c3c' }
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"label`">Consecutive Failures</div><div class=`"value`" style=`"color:$cfColor`">$(ConvertTo-SafeHtml $m.ConsecutiveFailures)</div><div class=`"sub`">Current streak</div></div>")

    # Last Success card
    $lsDisplay = if ($null -ne $m.LastSuccessfulRun) { ConvertTo-SafeHtml $m.LastSuccessfulRun } else { 'Never' }
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"label`">Last Successful Run</div><div class=`"value`" style=`"font-size:16px`">$lsDisplay</div></div>")

    [void]$sb.AppendLine('</div>')

    # --- Step Reliability Bars ---
    [void]$sb.AppendLine('<h2>Step Reliability</h2>')
    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine((Build-HtmlTableHeader -Headers @('Step', 'Reliability', '')))
    [void]$sb.AppendLine('<tbody>')
    $stepNames = @('Validation','Cleanup','DeltaCert','DeltaReport','Escalation','HealthCheck')
    $alt = $false
    foreach ($sn in $stepNames) {
        $pct = if ($m.StepReliability.ContainsKey($sn)) { $m.StepReliability[$sn] } else { 0.0 }
        $barColor = if ($pct -ge 90) { '#27ae60' } elseif ($pct -ge 70) { '#f39c12' } else { '#e74c3c' }
        $barHtml = "<div class=`"bar-container`"><div class=`"bar-fill`" style=`"width:${pct}%; background:$barColor`">$(ConvertTo-SafeHtml $pct)%</div></div>"
        [void]$sb.AppendLine((Build-HtmlTableRow -Cells @(
            (ConvertTo-SafeHtml $sn),
            $barHtml,
            "$(ConvertTo-SafeHtml $pct)%"
        ) -IsAlternate $alt))
        $alt = -not $alt
    }
    [void]$sb.AppendLine('</tbody></table>')

    # --- Run Timeline Table ---
    [void]$sb.AppendLine('<h2>Run Timeline</h2>')
    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine((Build-HtmlTableHeader -Headers @('Timestamp', 'Exit Code', 'Duration', 'Correlation ID')))
    [void]$sb.AppendLine('<tbody>')
    $alt = $false
    foreach ($r in $runs) {
        $ecColor = Get-ExitCodeColor -Code $r.ExitCode
        $ecLabel = Get-ExitCodeLabel -Code $r.ExitCode
        $badge = "<span class=`"badge`" style=`"background:$ecColor`">$(ConvertTo-SafeHtml $ecLabel)</span>"
        $durDisplay = "$([math]::Round($r.DurationSeconds, 1))s"
        [void]$sb.AppendLine((Build-HtmlTableRow -Cells @(
            (ConvertTo-SafeHtml $r.Timestamp),
            $badge,
            (ConvertTo-SafeHtml $durDisplay),
            (ConvertTo-SafeHtml $r.CorrelationID)
        ) -IsAlternate $alt))
        $alt = -not $alt
    }
    [void]$sb.AppendLine('</tbody></table>')

    # --- Failure Details ---
    $failedRuns = @($runs | Where-Object { $_.ExitCode -ne 0 })
    if ($failedRuns.Count -gt 0) {
        [void]$sb.AppendLine('<h2>Failure Details</h2>')
        foreach ($fr in $failedRuns) {
            $ecLabel = Get-ExitCodeLabel -Code $fr.ExitCode
            [void]$sb.AppendLine('<div class="failure-detail">')
            [void]$sb.AppendLine("<strong>$(ConvertTo-SafeHtml $fr.Timestamp)</strong> - $(ConvertTo-SafeHtml $ecLabel) (Exit Code $(ConvertTo-SafeHtml $fr.ExitCode))")
            [void]$sb.AppendLine('<br/>Correlation: ' + (ConvertTo-SafeHtml $fr.CorrelationID))
            if ($fr.Steps.Count -gt 0) {
                [void]$sb.AppendLine('<br/>Steps:')
                [void]$sb.AppendLine('<ul>')
                foreach ($sk in $fr.Steps.Keys) {
                    $sv = $fr.Steps[$sk]
                    $stepColor = if ($sv -like 'Success*') { '#27ae60' } elseif ($sv -eq 'Skipped') { '#95a5a6' } else { '#e74c3c' }
                    [void]$sb.AppendLine("<li style=`"color:$stepColor`">$(ConvertTo-SafeHtml $sk): $(ConvertTo-SafeHtml $sv)</li>")
                }
                [void]$sb.AppendLine('</ul>')
            }
            [void]$sb.AppendLine('</div>')
        }
    }

    # --- Duration Trend Table ---
    if ($runs.Count -ge 2) {
        [void]$sb.AppendLine('<h2>Duration Trend</h2>')
        [void]$sb.AppendLine('<table>')
        [void]$sb.AppendLine((Build-HtmlTableHeader -Headers @('Run Date', 'Duration (s)', 'Relative')))
        [void]$sb.AppendLine('<tbody>')
        $maxDur = ($runs | Measure-Object -Property DurationSeconds -Maximum).Maximum
        if ($maxDur -le 0) { $maxDur = 1 }
        $alt = $false
        # Show chronological order for trend (oldest first)
        $chronoRuns = @($runs | Sort-Object { $_.Timestamp })
        foreach ($r in $chronoRuns) {
            $relPct = [math]::Round(($r.DurationSeconds / $maxDur) * 100, 0)
            $barColor = Get-ExitCodeColor -Code $r.ExitCode
            $barHtml = "<div class=`"bar-container`"><div class=`"bar-fill`" style=`"width:${relPct}%; background:$barColor`">$([math]::Round($r.DurationSeconds, 1))s</div></div>"
            [void]$sb.AppendLine((Build-HtmlTableRow -Cells @(
                (ConvertTo-SafeHtml $r.Timestamp),
                (ConvertTo-SafeHtml ([math]::Round($r.DurationSeconds, 1))),
                $barHtml
            ) -IsAlternate $alt))
            $alt = -not $alt
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('</body></html>')

    # Write file
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $utf8NoBom)

    Write-SPLog -Message "Orchestrator history report written: $filePath" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPOrchestratorHistoryHtml' `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            ReportPath = $filePath
            RunCount   = $m.RunCount
        }
    }
}


function Export-SPGovernanceBIData {
    <#
    .SYNOPSIS
        Exports a flat, denormalized CSV optimized for Power BI / Tableau consumption.
    .DESCRIPTION
        Produces a single CSV file with one row per access review decision, enriched
        with campaign metadata, reviewer performance metrics, rubber stamp risk, and
        optional leadership org level data. All values are inlined (denormalized) so
        the output can be loaded directly into Power BI or Tableau without joins.

        Column set (40 columns):
        - Campaign: Id, Name, Type, Status, Created, Deadline, Completed,
          TotalItems, CompletionPct
        - Decision: IdentityName, IdentityId, AccountName, SourceName,
          EntitlementName, AccessType, Decision, DecisionDate, Justification,
          RemediationStatus, RemediationDate, DaysToRemediate, RiskFlags
        - Reviewer: ReviewerName, ReviewerEmail, ReviewerAvgResponseHours,
          ReviewerItemsDecided, ReviewerApprovalRate, ReviewerRubberStampRisk
        - Campaign Aggregate: CampaignApproved, CampaignRevoked, CampaignPending,
          CampaignReviewerCount, CampaignAvgResponseHours, CampaignMedianResponseHours
        - Leadership: OrgDirector, OrgExecutive, OrgLevel (populated when
          LeadershipData is provided)
        - Metadata: CampaignStartDate, CampaignDueDate, SystemTimestamp, ExportTimestamp

        Uses Export-Csv -NoTypeInformation for PS 5.1 compatibility.
        Date columns are ISO 8601. Risk flags are semicolon-delimited.
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables as produced by the campaign audit pipeline.
        Each must contain: CampaignName, Decisions, ReviewerMetrics, RubberStampRisk.
    .PARAMETER OutputPath
        Directory in which to write the CSV file. Created if absent.
    .PARAMETER LeadershipData
        Optional hashtable from Group-SPAuditByLeadership. When provided, each decision
        row is enriched with director and executive names from the org tree.
    .PARAMETER CorrelationID
        Unique ID for tracing and file naming. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Success = [bool]; Data = @{ File; RowCount; Columns }; Error = $null }
    .EXAMPLE
        $result = Export-SPGovernanceBIData -CampaignAudits $audits -OutputPath 'C:\BI'
        $result.Data.File  # => C:\BI\bi-governance-{correlationId}.csv
    .EXAMPLE
        $result = Export-SPGovernanceBIData -CampaignAudits $audits -OutputPath 'C:\BI' -LeadershipData $leadership
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object[]]$CampaignAudits,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [hashtable]$LeadershipData,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Exporting Power BI governance data for $($CampaignAudits.Count) campaign(s)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPGovernanceBIData' `
        -CorrelationID $CorrelationID

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # --- Helper: safe string extraction from hashtable or PSCustomObject ---
    function _BIVal ($obj, [string]$key, [string]$default = '') {
        if ($null -eq $obj) { return $default }
        if ($obj -is [hashtable]) {
            if ($obj.ContainsKey($key) -and $null -ne $obj[$key]) { return [string]$obj[$key] }
            return $default
        }
        if ($null -ne $obj.PSObject -and $null -ne $obj.PSObject.Properties[$key]) {
            $v = $obj.PSObject.Properties[$key].Value
            if ($null -ne $v) { return [string]$v }
        }
        return $default
    }

    # --- Build leadership lookup: identity name -> (Director, Executive) ---
    $leadershipLookup = @{}
    if ($null -ne $LeadershipData -and $LeadershipData -is [hashtable] -and
        $LeadershipData.ContainsKey('Directors')) {
        foreach ($dirKey in $LeadershipData['Directors'].Keys) {
            $dirEntry = $LeadershipData['Directors'][$dirKey]
            $dirName  = _BIVal $dirEntry 'Name'
            $execName = ''
            if ($null -ne $dirEntry -and $dirEntry -is [hashtable] -and
                $dirEntry.ContainsKey('ExecutiveName')) {
                $execName = [string]$dirEntry['ExecutiveName']
            }

            # Walk managers under this director
            $managers = $null
            if ($dirEntry -is [hashtable] -and $dirEntry.ContainsKey('Managers')) {
                $managers = $dirEntry['Managers']
            }
            if ($null -ne $managers -and $managers -is [hashtable]) {
                foreach ($mgrKey in $managers.Keys) {
                    $mgrEntry = $managers[$mgrKey]
                    $identities = $null
                    if ($mgrEntry -is [hashtable] -and $mgrEntry.ContainsKey('Identities')) {
                        $identities = $mgrEntry['Identities']
                    }
                    if ($null -ne $identities) {
                        foreach ($identity in @($identities)) {
                            $iName = ''
                            if ($null -ne $identity -and $null -ne $identity.IdentityName) {
                                $iName = [string]$identity.IdentityName
                            }
                            if (-not [string]::IsNullOrWhiteSpace($iName) -and
                                -not $leadershipLookup.ContainsKey($iName)) {
                                $leadershipLookup[$iName] = @{
                                    Director  = $dirName
                                    Executive = $execName
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    $hasLeadership = $leadershipLookup.Count -gt 0

    $exportTimestamp = (Get-Date).ToUniversalTime().ToString('o')
    $biRows = [System.Collections.Generic.List[object]]::new()

    foreach ($audit in $CampaignAudits) {
        $campName   = _BIVal $audit 'CampaignName'
        $campId     = _BIVal $audit 'CampaignId'
        $campType   = _BIVal $audit 'CampaignType'
        $campStatus = _BIVal $audit 'Status'
        $campCreated  = _BIVal $audit 'Created'
        $campDeadline = _BIVal $audit 'Deadline'
        $campCompleted = _BIVal $audit 'Completed'

        # --- Count items from decisions for campaign-level metrics ---
        $decisions = $null
        if ($audit -is [hashtable] -and $audit.ContainsKey('Decisions')) {
            $decisions = $audit['Decisions']
        } elseif ($null -ne $audit.PSObject -and $null -ne $audit.PSObject.Properties['Decisions']) {
            $decisions = $audit.Decisions
        }

        $approvedCt = 0; $revokedCt = 0; $pendingCt = 0
        if ($null -ne $decisions -and $decisions -is [hashtable]) {
            if ($decisions.ContainsKey('Approved') -and $null -ne $decisions['Approved']) {
                $approvedCt = @($decisions['Approved']).Count
            }
            if ($decisions.ContainsKey('Revoked') -and $null -ne $decisions['Revoked']) {
                $revokedCt = @($decisions['Revoked']).Count
            }
            if ($decisions.ContainsKey('Pending') -and $null -ne $decisions['Pending']) {
                $pendingCt = @($decisions['Pending']).Count
            }
        }
        $totalItems = $approvedCt + $revokedCt + $pendingCt
        $completionPct = if ($totalItems -gt 0) {
            [Math]::Round((($approvedCt + $revokedCt) / $totalItems) * 100, 1)
        } else { 0.0 }

        # --- Reviewer metrics: campaign-level aggregates ---
        $reviewerCount     = 0
        $campAvgHours      = ''
        $campMedianHours   = ''
        $reviewerMetrics   = $null
        if ($audit -is [hashtable] -and $audit.ContainsKey('ReviewerMetrics')) {
            $reviewerMetrics = $audit['ReviewerMetrics']
        }
        if ($null -ne $reviewerMetrics -and $reviewerMetrics -is [hashtable]) {
            if ($reviewerMetrics.ContainsKey('ReviewerMetrics') -and $null -ne $reviewerMetrics['ReviewerMetrics']) {
                $reviewerCount = @($reviewerMetrics['ReviewerMetrics']).Count
            }
            if ($reviewerMetrics.ContainsKey('CampaignAvgHours') -and $null -ne $reviewerMetrics['CampaignAvgHours']) {
                $campAvgHours = $reviewerMetrics['CampaignAvgHours']
            }
            if ($reviewerMetrics.ContainsKey('CampaignMedianHours') -and $null -ne $reviewerMetrics['CampaignMedianHours']) {
                $campMedianHours = $reviewerMetrics['CampaignMedianHours']
            }
        }

        # --- Per-reviewer lookup: name -> (AvgHours, ItemsDecided, ApprovalRate) ---
        $reviewerLookup = @{}
        if ($null -ne $reviewerMetrics -and $reviewerMetrics -is [hashtable] -and
            $reviewerMetrics.ContainsKey('ReviewerMetrics') -and $null -ne $reviewerMetrics['ReviewerMetrics']) {
            foreach ($rm in @($reviewerMetrics['ReviewerMetrics'])) {
                $rmName = if ($null -ne $rm.Name) { [string]$rm.Name } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($rmName)) {
                    $reviewerLookup[$rmName] = $rm
                }
            }
        }

        # --- Per-reviewer decision counts for approval rate ---
        $reviewerApprovedCt = @{}
        $reviewerRevokedCt  = @{}
        if ($null -ne $decisions -and $decisions -is [hashtable]) {
            foreach ($cat in @('Approved', 'Revoked')) {
                if (-not $decisions.ContainsKey($cat) -or $null -eq $decisions[$cat]) { continue }
                foreach ($item in @($decisions[$cat])) {
                    $rn = if ($null -ne $item.ReviewerName) { [string]$item.ReviewerName } else { 'Unknown' }
                    switch ($cat) {
                        'Approved' {
                            if ($reviewerApprovedCt.ContainsKey($rn)) { $reviewerApprovedCt[$rn]++ } else { $reviewerApprovedCt[$rn] = 1 }
                        }
                        'Revoked' {
                            if ($reviewerRevokedCt.ContainsKey($rn)) { $reviewerRevokedCt[$rn]++ } else { $reviewerRevokedCt[$rn] = 1 }
                        }
                    }
                }
            }
        }

        # --- Rubber stamp risk lookup ---
        $riskLookup = @{}
        $rubberStampRisk = $null
        if ($audit -is [hashtable] -and $audit.ContainsKey('RubberStampRisk')) {
            $rubberStampRisk = $audit['RubberStampRisk']
        }
        if ($null -ne $rubberStampRisk -and $rubberStampRisk -is [hashtable] -and
            $rubberStampRisk.ContainsKey('ReviewerRisks') -and $null -ne $rubberStampRisk['ReviewerRisks']) {
            foreach ($rr in @($rubberStampRisk['ReviewerRisks'])) {
                $rrName = if ($null -ne $rr.Name) { [string]$rr.Name } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($rrName)) {
                    $riskLookup[$rrName] = if ($null -ne $rr.Severity) { [string]$rr.Severity } else { 'None' }
                }
            }
        }

        # --- Iterate all decisions and produce one row per item ---
        if ($null -eq $decisions) { continue }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            } elseif ($null -ne $decisions.PSObject -and $null -ne $decisions.PSObject.Properties[$category]) {
                $items = @($decisions.$category)
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                # Risk flags
                $riskFlags = ''
                $rf = $null
                if ($null -ne $item.PSObject -and $null -ne $item.PSObject.Properties['RiskFlags']) {
                    $rf = $item.RiskFlags
                }
                if ($null -ne $rf -and $rf -is [array] -and $rf.Count -gt 0) {
                    $riskFlags = ($rf | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
                } elseif ($null -ne $rf -and $rf -is [string] -and -not [string]::IsNullOrWhiteSpace($rf)) {
                    $riskFlags = $rf
                }

                # Days to remediate (revoked items only)
                $daysToRemediate = ''
                $decDateStr = if ($null -ne $item.DecisionDate)    { [string]$item.DecisionDate }    else { '' }
                $remDateStr = if ($null -ne $item.RemediationDate) { [string]$item.RemediationDate } else { '' }
                if ($category -eq 'Revoked' -and
                    -not [string]::IsNullOrWhiteSpace($decDateStr) -and
                    -not [string]::IsNullOrWhiteSpace($remDateStr)) {
                    try {
                        $dtDec = [datetime]::Parse($decDateStr, [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        $dtRem = [datetime]::Parse($remDateStr, [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        $daysToRemediate = [Math]::Round(($dtRem - $dtDec).TotalDays, 3)
                    } catch { }
                }

                # Per-reviewer enrichment
                $revName = if ($null -ne $item.ReviewerName) { [string]$item.ReviewerName } else { '' }
                $revAvgHours    = ''
                $revItemsDecided = ''
                $revApprovalRate = ''
                if (-not [string]::IsNullOrWhiteSpace($revName) -and $reviewerLookup.ContainsKey($revName)) {
                    $rl = $reviewerLookup[$revName]
                    if ($null -ne $rl.AvgHours) { $revAvgHours = $rl.AvgHours }
                    if ($null -ne $rl.DecisionsMade) { $revItemsDecided = $rl.DecisionsMade }
                }
                # Compute reviewer approval rate from decision counts
                $revAppr = if ($reviewerApprovedCt.ContainsKey($revName)) { $reviewerApprovedCt[$revName] } else { 0 }
                $revRev  = if ($reviewerRevokedCt.ContainsKey($revName))  { $reviewerRevokedCt[$revName] }  else { 0 }
                $revTotal = $revAppr + $revRev
                if ($revTotal -gt 0) {
                    $revApprovalRate = [Math]::Round(($revAppr / $revTotal) * 100, 1)
                }

                $revRubberStamp = if ($riskLookup.ContainsKey($revName)) { $riskLookup[$revName] } else { 'None' }

                # Leadership enrichment
                $orgDirector  = ''
                $orgExecutive = ''
                $orgLevel     = ''
                $identityName = if ($null -ne $item.IdentityName) { [string]$item.IdentityName } else { '' }
                if ($hasLeadership -and -not [string]::IsNullOrWhiteSpace($identityName) -and
                    $leadershipLookup.ContainsKey($identityName)) {
                    $lk = $leadershipLookup[$identityName]
                    $orgDirector  = $lk['Director']
                    $orgExecutive = $lk['Executive']
                    if (-not [string]::IsNullOrWhiteSpace($orgExecutive)) { $orgLevel = 'Executive' }
                    elseif (-not [string]::IsNullOrWhiteSpace($orgDirector)) { $orgLevel = 'Director' }
                    else { $orgLevel = 'Unknown' }
                }

                $biRows.Add([PSCustomObject]@{
                    CampaignId                   = $campId
                    CampaignName                 = $campName
                    CampaignType                 = $campType
                    CampaignStatus               = $campStatus
                    CampaignCreated              = $campCreated
                    CampaignDeadline             = $campDeadline
                    CampaignCompleted            = $campCompleted
                    CampaignTotalItems           = $totalItems
                    CampaignCompletionPct        = $completionPct
                    IdentityName                 = $identityName
                    IdentityId                   = if ($null -ne $item.IdentityId)        { [string]$item.IdentityId }        else { '' }
                    AccountName                  = if ($null -ne $item.AccountName)       { [string]$item.AccountName }       else { '' }
                    SourceName                   = if ($null -ne $item.SourceName)        { [string]$item.SourceName }        else { '' }
                    EntitlementName              = if ($null -ne $item.AccessName)        { [string]$item.AccessName }        else { '' }
                    AccessType                   = if ($null -ne $item.AccessType)        { [string]$item.AccessType }        else { '' }
                    Decision                     = if ($null -ne $item.Decision)          { [string]$item.Decision }          else { $category }
                    DecisionDate                 = $decDateStr
                    Justification                = if ($null -ne $item.Justification)     { [string]$item.Justification }     else { '' }
                    RemediationStatus            = if ($null -ne $item.RemediationStatus) { [string]$item.RemediationStatus } else { '' }
                    RemediationDate              = $remDateStr
                    DaysToRemediate              = $daysToRemediate
                    RiskFlags                    = $riskFlags
                    ReviewerName                 = $revName
                    ReviewerEmail                = if ($null -ne $item.ReviewerEmail)     { [string]$item.ReviewerEmail }     else { '' }
                    ReviewerAvgResponseHours     = $revAvgHours
                    ReviewerItemsDecided         = $revItemsDecided
                    ReviewerApprovalRate         = $revApprovalRate
                    ReviewerRubberStampRisk      = $revRubberStamp
                    CampaignApproved             = $approvedCt
                    CampaignRevoked              = $revokedCt
                    CampaignPending              = $pendingCt
                    CampaignReviewerCount        = $reviewerCount
                    CampaignAvgResponseHours     = $campAvgHours
                    CampaignMedianResponseHours  = $campMedianHours
                    OrgDirector                  = $orgDirector
                    OrgExecutive                 = $orgExecutive
                    OrgLevel                     = $orgLevel
                    CampaignStartDate            = if ($null -ne $item.CampaignStartDate) { [string]$item.CampaignStartDate } else { $campCreated }
                    CampaignDueDate              = if ($null -ne $item.CampaignDueDate)   { [string]$item.CampaignDueDate }   else { $campDeadline }
                    SystemTimestamp              = if ($null -ne $item.SystemTimestamp)   { [string]$item.SystemTimestamp }   else { '' }
                    ExportTimestamp               = $exportTimestamp
                })
            }
        }
    }

    # --- Write CSV ---
    $csvPath = Join-Path $OutputPath "bi-governance-${CorrelationID}.csv"

    $columnNames = @(
        'CampaignId','CampaignName','CampaignType','CampaignStatus',
        'CampaignCreated','CampaignDeadline','CampaignCompleted',
        'CampaignTotalItems','CampaignCompletionPct',
        'IdentityName','IdentityId','AccountName','SourceName',
        'EntitlementName','AccessType','Decision','DecisionDate',
        'Justification','RemediationStatus','RemediationDate',
        'DaysToRemediate','RiskFlags',
        'ReviewerName','ReviewerEmail','ReviewerAvgResponseHours',
        'ReviewerItemsDecided','ReviewerApprovalRate','ReviewerRubberStampRisk',
        'CampaignApproved','CampaignRevoked','CampaignPending',
        'CampaignReviewerCount','CampaignAvgResponseHours','CampaignMedianResponseHours',
        'OrgDirector','OrgExecutive','OrgLevel',
        'CampaignStartDate','CampaignDueDate','SystemTimestamp','ExportTimestamp'
    )

    if ($biRows.Count -gt 0) {
        $biRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    } else {
        # Write header-only CSV
        $emptyRow = [ordered]@{}
        foreach ($col in $columnNames) { $emptyRow[$col] = '' }
        [PSCustomObject]$emptyRow | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        $headerLine = (Get-Content -Path $csvPath -TotalCount 1)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($csvPath, "$headerLine`n", $utf8NoBom)
    }

    Write-SPLog -Message "Power BI CSV written ($($biRows.Count) rows, $($columnNames.Count) columns): $csvPath" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPGovernanceBIData' `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            File     = $csvPath
            RowCount = $biRows.Count
            Columns  = $columnNames.Count
        }
        Error   = $null
    }
}


#endregion Orchestrator and BI Export

Export-ModuleMember -Function @(
    'Export-SPAuditHtml',
    'Export-SPAuditText',
    'Export-SPAuditJsonl',
    'Export-SPLeadershipExecutiveHtml',
    'Export-SPLeadershipDirectorHtml',
    'Export-SPLeadershipLevelHtml',
    'Export-SPLeadershipBandHtml',
    'Export-SPCampaignComparisonHtml',
    'Export-SPAuditTrailHtml',
    'Export-SPAuditCsv',
    'Export-SPCampaignTrendHtml',
    'Export-SPEntitlementInventoryHtml',
    'Export-SPAccessProfileInventoryHtml',
    'Export-SPRoleInventoryHtml',
    'Export-SPIdentityRiskHtml',
    'Export-SPSourceGovernanceHtml',
    'Export-SPStaleAccessHtml',
    'Export-SPCampaignCompletionReport',
    'Export-SPOrchestratorHistoryHtml',
    'Export-SPGovernanceBIData'
)
