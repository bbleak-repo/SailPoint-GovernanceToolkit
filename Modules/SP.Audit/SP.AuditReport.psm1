#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Campaign Audit Report Generation
.DESCRIPTION
    Provides categorization and export functions for campaign audit data.
    Consumes structured output from SP.AuditQueries and produces HTML,
    plain-text, and JSONL audit trail files suitable for compliance evidence.

    HTML output uses inline CSS only and table-based layout for Word
    copy-paste compatibility. No flexbox, no grid, no external stylesheets.
.NOTES
    Module: SP.Audit / SP.AuditReport
    Version: 1.0.0
    Component: Audit Reporting

    Color taxonomy:
        Green  #339933 - Approved / success
        Red    #CC3333 - Revoked / error
        Orange #FF8800 - Pending / warn
        Blue   #336699 - Info / neutral
        Gray   #777777 - N/A / footer
#>

$script:AuditReportVersion = '1.0.0'

#region Categorization Functions

function Group-SPAuditDecisions {
    <#
    .SYNOPSIS
        Groups access review items by decision outcome.
    .DESCRIPTION
        Takes an array of enriched item hashtables (each containing the raw API
        item plus context fields) and returns a hashtable with three arrays:
        Approved, Revoked, and Pending.

        Each input element must be a hashtable with keys:
            Item            - The raw API item object from Get-SPAuditCertificationItems
            CertificationId - String ID of the parent certification
            CertificationName - Display name of the parent certification
            CampaignName    - Display name of the parent campaign
    .PARAMETER Items
        Array of enriched item hashtables produced by the caller after
        iterating Get-SPAuditCertifications and Get-SPAuditCertificationItems.
    .OUTPUTS
        [hashtable] @{ Approved = @(...); Revoked = @(...); Pending = @(...) }
        Each element is a PSCustomObject with: IdentityName, AccessName, AccessType,
        ReviewerName, CertificationId, CertificationName, CampaignName, DecisionDate.
    .EXAMPLE
        $grouped = Group-SPAuditDecisions -Items $enrichedItems
        Write-Host "Revoked: $($grouped.Revoked.Count)"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    $approved = [System.Collections.Generic.List[object]]::new()
    $revoked  = [System.Collections.Generic.List[object]]::new()
    $pending  = [System.Collections.Generic.List[object]]::new()

    foreach ($wrapper in $Items) {
        # Support both hashtable and PSCustomObject wrappers
        $rawItem          = $null
        $certId           = ''
        $certName         = ''
        $campaignName     = ''

        if ($wrapper -is [hashtable]) {
            $rawItem      = $wrapper['Item']
            $certId       = if ($wrapper.ContainsKey('CertificationId'))   { $wrapper['CertificationId']   } else { '' }
            $certName     = if ($wrapper.ContainsKey('CertificationName')) { $wrapper['CertificationName'] } else { '' }
            $campaignName = if ($wrapper.ContainsKey('CampaignName'))      { $wrapper['CampaignName']      } else { '' }
        }
        else {
            $rawItem      = $wrapper.Item
            $certId       = if ($null -ne $wrapper.CertificationId)   { $wrapper.CertificationId }   else { '' }
            $certName     = if ($null -ne $wrapper.CertificationName) { $wrapper.CertificationName } else { '' }
            $campaignName = if ($null -ne $wrapper.CampaignName)      { $wrapper.CampaignName }      else { '' }
        }

        if ($null -eq $rawItem) { continue }

        # Extract reviewer name safely
        $reviewerName = 'N/A'
        if ($null -ne $rawItem.reviewedBy -and -not [string]::IsNullOrWhiteSpace($rawItem.reviewedBy.name)) {
            $reviewerName = $rawItem.reviewedBy.name
        }

        # Build normalized output object
        $out = [PSCustomObject]@{
            IdentityName      = if ($null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.name) { $rawItem.identitySummary.name } else { '' }
            AccessName        = if ($null -ne $rawItem.access -and $null -ne $rawItem.access.name)                   { $rawItem.access.name }           else { '' }
            AccessType        = if ($null -ne $rawItem.access -and $null -ne $rawItem.access.type)                   { $rawItem.access.type }           else { '' }
            ReviewerName      = $reviewerName
            CertificationId   = $certId
            CertificationName = $certName
            CampaignName      = $campaignName
            DecisionDate      = if ($null -ne $rawItem.decisionDate) { $rawItem.decisionDate } else { '' }
        }

        $decision = if ($null -ne $rawItem.decision) { [string]$rawItem.decision } else { '' }

        switch ($decision.ToUpperInvariant()) {
            'APPROVE' { $approved.Add($out) }
            'REVOKE'  { $revoked.Add($out)  }
            default   { $pending.Add($out)  }
        }
    }

    return @{
        Approved = $approved.ToArray()
        Revoked  = $revoked.ToArray()
        Pending  = $pending.ToArray()
    }
}

function Group-SPReviewerActions {
    <#
    .SYNOPSIS
        Produces reviewer accountability groups from certification objects.
    .DESCRIPTION
        Accepts an array of certification objects as returned by
        Get-SPAuditCertifications (which adds a ReviewerClassification
        field: Primary or Reassigned). Groups them into two lists and
        produces a structured PSCustomObject per reviewer entry.
    .PARAMETER Certifications
        Array of certification objects. Each must have:
            reviewer            - object with name, email
            ReviewerClassification - 'Primary' or 'Reassigned'
            decisionsMade       - int
            reassignedFrom      - object with name (Reassigned certs only)
            phase               - string (ACTIVE, SIGNED, etc.)
            signed              - datetime string (sign-off date, may be null)
    .OUTPUTS
        [hashtable] @{
            Primary    = @( [PSCustomObject]@{ Name; Email; CertsAssigned; DecisionsMade; SignOffDate; Phase } )
            Reassigned = @( [PSCustomObject]@{ Name; Email; ReassignedFrom; DecisionsMade; SignOffDate; Phase; ProofOfAction } )
        }
    .EXAMPLE
        $reviewers = Group-SPReviewerActions -Certifications $certs
        $reviewers.Primary | ForEach-Object { Write-Host "$($_.Name): $($_.DecisionsMade) decisions" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Certifications
    )

    # Aggregate primary reviewers keyed by name to sum cert counts
    $primaryMap    = [ordered]@{}
    $reassignedList = [System.Collections.Generic.List[object]]::new()

    foreach ($cert in $Certifications) {
        $classification = ''
        $reviewerName   = ''
        $reviewerEmail  = ''
        $decisionsMade  = 0
        $signOffDate    = ''
        $phase          = ''

        # Pull scalar fields safely
        if ($null -ne $cert.reviewer) {
            $reviewerName  = if ($null -ne $cert.reviewer.name)  { [string]$cert.reviewer.name }  else { '' }
            $reviewerEmail = if ($null -ne $cert.reviewer.email) { [string]$cert.reviewer.email } else { '' }
        }

        if ($null -ne $cert.ReviewerClassification) {
            $classification = [string]$cert.ReviewerClassification
        }

        if ($null -ne $cert.decisionsMade) {
            try { $decisionsMade = [int]$cert.decisionsMade } catch { $decisionsMade = 0 }
        }

        if ($null -ne $cert.signed -and -not [string]::IsNullOrWhiteSpace([string]$cert.signed)) {
            $signOffDate = [string]$cert.signed
        }
        elseif ($null -ne $cert.completed -and -not [string]::IsNullOrWhiteSpace([string]$cert.completed)) {
            $signOffDate = [string]$cert.completed
        }

        if ($null -ne $cert.phase) {
            $phase = [string]$cert.phase
        }

        if ($classification -eq 'Reassigned') {
            $reassignedFromName = ''
            if ($null -ne $cert.reassignedFrom -and $null -ne $cert.reassignedFrom.name) {
                $reassignedFromName = [string]$cert.reassignedFrom.name
            }

            # Proof of action: reviewer made decisions AND signed
            $proofOfAction = ($decisionsMade -gt 0 -and $phase -eq 'SIGNED')

            $reassignedList.Add([PSCustomObject]@{
                Name            = $reviewerName
                Email           = $reviewerEmail
                ReassignedFrom  = $reassignedFromName
                DecisionsMade   = $decisionsMade
                SignOffDate     = $signOffDate
                Phase           = $phase
                ProofOfAction   = $proofOfAction
            })
        }
        else {
            # Primary: aggregate by reviewer name to get CertsAssigned count
            if (-not $primaryMap.Contains($reviewerName)) {
                $primaryMap[$reviewerName] = [PSCustomObject]@{
                    Name          = $reviewerName
                    Email         = $reviewerEmail
                    CertsAssigned = 0
                    DecisionsMade = 0
                    SignOffDate   = $signOffDate
                    Phase         = $phase
                }
            }

            $entry = $primaryMap[$reviewerName]
            $entry.CertsAssigned = $entry.CertsAssigned + 1
            $entry.DecisionsMade = $entry.DecisionsMade + $decisionsMade

            # Use most recent sign-off date
            if ([string]::IsNullOrWhiteSpace($entry.SignOffDate) -and -not [string]::IsNullOrWhiteSpace($signOffDate)) {
                $entry.SignOffDate = $signOffDate
            }
        }
    }

    return @{
        Primary    = @($primaryMap.Values)
        Reassigned = $reassignedList.ToArray()
    }
}

function Group-SPAuditIdentityEvents {
    <#
    .SYNOPSIS
        Groups raw identity provisioning events by operation type.
    .DESCRIPTION
        Accepts an array of event objects returned by Get-SPAuditIdentityEvents
        and splits them into Revoked (removal/disable operations) and Granted
        (addition/enable operations). Unknown operations are discarded.
    .PARAMETER Events
        Array of event objects from Get-SPAuditIdentityEvents. Each event must
        have: targetIdentitySummary.name, requesterIdentitySummary.name,
        sourceName, operation, completed, completionStatus.
    .OUTPUTS
        [hashtable] @{
            Revoked = @( [PSCustomObject]@{ TargetName; Actor; SourceName; Operation; Date; Status } )
            Granted = @( [PSCustomObject]@{ TargetName; Actor; SourceName; Operation; Date; Status } )
        }
    .EXAMPLE
        $events = Group-SPAuditIdentityEvents -Events $rawEvents
        Write-Host "Access revoked for $($events.Revoked.Count) identities"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Events
    )

    $revokeOps = @('REMOVE', 'DELETE', 'DISABLE', 'Remove', 'Delete', 'Disable')
    $grantOps  = @('ADD', 'CREATE', 'ENABLE', 'Add', 'Create', 'Enable')

    $revoked = [System.Collections.Generic.List[object]]::new()
    $granted = [System.Collections.Generic.List[object]]::new()

    foreach ($event in $Events) {
        $targetName = ''
        $actorName  = ''
        $sourceName = ''
        $operation  = ''
        $date       = ''
        $status     = ''

        if ($null -ne $event.targetIdentitySummary -and $null -ne $event.targetIdentitySummary.name) {
            $targetName = [string]$event.targetIdentitySummary.name
        }
        if ($null -ne $event.requesterIdentitySummary -and $null -ne $event.requesterIdentitySummary.name) {
            $actorName = [string]$event.requesterIdentitySummary.name
        }
        if ($null -ne $event.sourceName) {
            $sourceName = [string]$event.sourceName
        }
        if ($null -ne $event.operation) {
            $operation = [string]$event.operation
        }
        if ($null -ne $event.completed) {
            $date = [string]$event.completed
        }
        if ($null -ne $event.completionStatus) {
            $status = [string]$event.completionStatus
        }

        $out = [PSCustomObject]@{
            TargetName  = $targetName
            Actor       = $actorName
            SourceName  = $sourceName
            Operation   = $operation
            Date        = $date
            Status      = $status
        }

        if ($revokeOps -contains $operation) {
            $revoked.Add($out)
        }
        elseif ($grantOps -contains $operation) {
            $granted.Add($out)
        }
        # Unknown operations are intentionally omitted
    }

    return @{
        Revoked = $revoked.ToArray()
        Granted = $granted.ToArray()
    }
}

#endregion

#region Internal HTML Helpers

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
        [string]$AnchorId = ''
    )

    $campaignName   = ConvertTo-SafeHtml ($CampaignAudit['CampaignName'])
    $campaignId     = ConvertTo-SafeHtml ($CampaignAudit['CampaignId'])
    $status         = ConvertTo-SafeHtml ($CampaignAudit['Status'])
    $created        = Format-HtmlDate   ($CampaignAudit['Created'])
    $completed      = Format-HtmlDate   ($CampaignAudit['Completed'])
    $totalCerts     = if ($CampaignAudit.ContainsKey('TotalCertifications')) { [int]$CampaignAudit['TotalCertifications'] } else { 0 }

    $decisions  = if ($CampaignAudit.ContainsKey('Decisions')  -and $null -ne $CampaignAudit['Decisions'])  { $CampaignAudit['Decisions']  } else { @{ Approved = @(); Revoked = @(); Pending = @() } }
    $reviewers  = if ($CampaignAudit.ContainsKey('Reviewers')  -and $null -ne $CampaignAudit['Reviewers'])  { $CampaignAudit['Reviewers']  } else { @{ Primary = @(); Reassigned = @() } }
    $events     = if ($CampaignAudit.ContainsKey('Events')     -and $null -ne $CampaignAudit['Events'])      { $CampaignAudit['Events']     } else { @{ Revoked = @(); Granted = @() } }
    $campRpts   = if ($CampaignAudit.ContainsKey('CampaignReports') -and $null -ne $CampaignAudit['CampaignReports']) { $CampaignAudit['CampaignReports'] } else { $null }
    $rptAvailable = if ($CampaignAudit.ContainsKey('CampaignReportsAvailable')) { [bool]$CampaignAudit['CampaignReportsAvailable'] } else { $false }

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

    $html = @"
<div$anchorAttr style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif;">

<h2 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-bottom:4px; font-size:20px;">$campaignName</h2>
<p style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-size:12px; margin-top:2px;">Campaign ID: $campaignId</p>

<h3 $sectionHeadStyle>1. Campaign Summary</h3>
<table $tableStyle>
    <tbody>
        <tr><td $summaryTdLabel>Campaign Name</td><td $summaryTdValue>$campaignName</td></tr>
        <tr><td $summaryTdLabel>Status</td><td $summaryTdValue><span style="color:$statusColor; font-weight:bold;">$status</span></td></tr>
        <tr><td $summaryTdLabel>Created</td><td $summaryTdValue>$([System.Net.WebUtility]::HtmlEncode($created))</td></tr>
        <tr><td $summaryTdLabel>Completed</td><td $summaryTdValue>$([System.Net.WebUtility]::HtmlEncode($completed))</td></tr>
        <tr><td $summaryTdLabel>Total Certifications</td><td $summaryTdValue>$totalCerts</td></tr>
    </tbody>
</table>

"@

    # --- Section 2: Reviewer Accountability ---
    $html += "<h3 $sectionHeadStyle>2. Reviewer Accountability</h3>`n"

    # Primary Reviewers
    $primaryRows = $reviewers['Primary']
    $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px;"">Primary Reviewers</p>`n"
    $html += "<table $tableStyle>`n"
    $html += (Build-HtmlTableHeader -Headers @('Name', 'Email', 'Certs Assigned', 'Decisions Made', 'Sign-Off Date', 'Phase'))
    $html += "<tbody>`n"

    if ($null -eq $primaryRows -or $primaryRows.Count -eq 0) {
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

    # Reassigned Reviewers
    $reassignedRows = $reviewers['Reassigned']
    $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:12px;"">Reassigned Reviewers</p>`n"
    $html += "<table $tableStyle>`n"
    $html += (Build-HtmlTableHeader -Headers @('Name', 'Email', 'Reassigned From', 'Decisions Made', 'Sign-Off Date', 'Phase', 'Proof of Action'))
    $html += "<tbody>`n"

    if ($null -eq $reassignedRows -or $reassignedRows.Count -eq 0) {
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

    # --- Section 3: Decision Summary ---
    $html += "<h3 $sectionHeadStyle>3. Decision Summary</h3>`n"

    $decisionCategories = @(
        @{ Label = 'Approved'; Color = '#339933'; Items = $decisions['Approved'] },
        @{ Label = 'Revoked';  Color = '#CC3333'; Items = $decisions['Revoked']  },
        @{ Label = 'Pending';  Color = '#FF8800'; Items = $decisions['Pending']  }
    )

    foreach ($cat in $decisionCategories) {
        $catItems = @($cat['Items'])
        $catColor = $cat['Color']
        $catLabel = $cat['Label']

        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; color:$catColor; margin-bottom:6px; margin-top:12px;"">$catLabel ($($catItems.Count))</p>`n"
        $html += "<table $tableStyle>`n"
        $html += (Build-HtmlTableHeader -Headers @('Identity', 'Access Name', 'Type', 'Reviewer', 'Decision Date'))
        $html += "<tbody>`n"

        if ($catItems.Count -eq 0) {
            $html += "<tr><td colspan=""5"" style=""padding:8px 10px; color:#777777; font-style:italic;"">None.</td></tr>`n"
        }
        else {
            $rowIdx = 0
            foreach ($item in $catItems) {
                $cells = @(
                    (ConvertTo-SafeHtml $item.IdentityName),
                    (ConvertTo-SafeHtml $item.AccessName),
                    (ConvertTo-SafeHtml $item.AccessType),
                    (ConvertTo-SafeHtml $item.ReviewerName),
                    (ConvertTo-SafeHtml (Format-HtmlDate $item.DecisionDate))
                )
                $html += (Build-HtmlTableRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)) + "`n"
                $rowIdx++
            }
        }
        $html += "</tbody></table>`n"
    }

    # --- Section 4: Campaign Reports ---
    $html += "<h3 $sectionHeadStyle>4. Campaign Reports</h3>`n"

    if (-not $rptAvailable -or $null -eq $campRpts) {
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-style:italic;"">Campaign reports not available for this campaign (API does not provide on-demand report data).</p>`n"
    }
    else {
        # Render each report type as a table
        foreach ($rptKey in $campRpts.Keys) {
            $rptData = @($campRpts[$rptKey])
            $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px;"">$([System.Net.WebUtility]::HtmlEncode($rptKey))</p>`n"

            if ($rptData.Count -eq 0) {
                $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-style:italic;"">No records.</p>`n"
                continue
            }

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
    }

    # --- Section 5: Provisioning Proof ---
    $html += "<h3 $sectionHeadStyle>5. Provisioning Proof</h3>`n"

    $provCategories = @(
        @{ Label = 'Access Revoked Events'; Items = $events['Revoked'] },
        @{ Label = 'Access Granted Events'; Items = $events['Granted'] }
    )

    foreach ($pcat in $provCategories) {
        $pcatItems = @($pcat['Items'])
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:12px;"">$($pcat['Label']) ($($pcatItems.Count))</p>`n"
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
    }

    $html += "</div>`n"
    return $html
}

#endregion

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

    # Build metadata section HTML
    $metaRowsHtml = ''
    if ($null -ne $RunMetadata) {
        foreach ($key in $RunMetadata.Keys) {
            $metaRowsHtml += "<tr><td style=""padding:6px 10px; font-weight:bold; width:200px; background:#f4f4f4; border-bottom:1px solid #e0e0e0;"">$([System.Net.WebUtility]::HtmlEncode($key))</td><td style=""padding:6px 10px; border-bottom:1px solid #e0e0e0;"">$([System.Net.WebUtility]::HtmlEncode([string]$RunMetadata[$key]))</td></tr>`n"
        }
    }

    $metaSection = @"
<h3 style="font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;">6. Audit Metadata</h3>
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
        $bodyHtml  = Build-SingleCampaignHtml -CampaignAudit $audit -AnchorId $anchorId

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

#endregion

Export-ModuleMember -Function @(
    'Group-SPAuditDecisions',
    'Group-SPReviewerActions',
    'Group-SPAuditIdentityEvents',
    'Export-SPAuditHtml',
    'Export-SPAuditText',
    'Export-SPAuditJsonl'
)
