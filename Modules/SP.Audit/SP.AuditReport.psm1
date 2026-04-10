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

function Group-SPAuditRemediationProof {
    <#
    .SYNOPSIS
        Builds item-level remediation proof and reassignment chain from existing audit data.
    .DESCRIPTION
        Extracts remediation status from the 'completed' boolean field on each revoked
        access review item, and builds a reassignment chain from certification objects
        where ReviewerClassification = 'Reassigned'.

        No additional API calls are made -- all data comes from objects already retrieved
        by Get-SPAuditCertificationItems and Get-SPAuditCertifications. This approach
        operates entirely within idn:campaign:read scope.
    .PARAMETER Items
        Array of enriched item hashtables (same format as Group-SPAuditDecisions receives).
        Each element must be a hashtable with keys:
            Item              - Raw API item object from Get-SPAuditCertificationItems
            CertificationId   - String ID of the parent certification
            CertificationName - Display name of the parent certification
            CampaignName      - Display name of the parent campaign
    .PARAMETER Certifications
        Array of certification objects as returned by Get-SPAuditCertifications.
        Each must have: ReviewerClassification, reviewer.name, reassignment.from.name
        (or reassignedFrom.name), name, signed/completed, phase.
    .OUTPUTS
        [hashtable] @{
            RevokedItems              = @( [PSCustomObject] per revoked item )
            ReassignmentChain         = @( [PSCustomObject] per reassignment hop )
            TotalRevoked              = [int]
            RemediationCompleteCount  = [int]
            RemediationPendingCount   = [int]
        }
    .EXAMPLE
        $proof = Group-SPAuditRemediationProof -Items $wrappedItems -Certifications $certs
        Write-Host "Remediation complete: $($proof.RemediationCompleteCount)/$($proof.TotalRevoked)"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Certifications
    )

    $revokedItems    = [System.Collections.Generic.List[object]]::new()
    $reassignChain   = [System.Collections.Generic.List[object]]::new()

    # --- Build revoked item list with remediation status ---
    foreach ($wrapper in $Items) {
        $rawItem      = $null
        $certName     = ''
        $campaignName = ''

        if ($wrapper -is [hashtable]) {
            $rawItem      = $wrapper['Item']
            $certName     = if ($wrapper.ContainsKey('CertificationName')) { $wrapper['CertificationName'] } else { '' }
            $campaignName = if ($wrapper.ContainsKey('CampaignName'))      { $wrapper['CampaignName']      } else { '' }
        }
        else {
            $rawItem      = $wrapper.Item
            $certName     = if ($null -ne $wrapper.CertificationName) { $wrapper.CertificationName } else { '' }
            $campaignName = if ($null -ne $wrapper.CampaignName)      { $wrapper.CampaignName }      else { '' }
        }

        if ($null -eq $rawItem) { continue }

        $decision = if ($null -ne $rawItem.decision) { [string]$rawItem.decision } else { '' }
        if ($decision.ToUpperInvariant() -ne 'REVOKE') { continue }

        # Extract fields
        $identityName = ''
        if ($null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.name) {
            $identityName = [string]$rawItem.identitySummary.name
        }

        $accessName = ''
        $accessType = ''
        $sourceName = ''
        if ($null -ne $rawItem.access) {
            if ($null -ne $rawItem.access.name) { $accessName = [string]$rawItem.access.name }
            if ($null -ne $rawItem.access.type) { $accessType = [string]$rawItem.access.type }
            # Source name: may be nested under access.source.name
            if ($null -ne $rawItem.access.PSObject.Properties['source'] -and
                $null -ne $rawItem.access.source -and
                $null -ne $rawItem.access.source.PSObject.Properties['name'] -and
                $null -ne $rawItem.access.source.name) {
                $sourceName = [string]$rawItem.access.source.name
            }
        }

        $reviewerName = 'N/A'
        if ($null -ne $rawItem.reviewedBy -and -not [string]::IsNullOrWhiteSpace($rawItem.reviewedBy.name)) {
            $reviewerName = [string]$rawItem.reviewedBy.name
        }

        $decisionDate = if ($null -ne $rawItem.decisionDate) { [string]$rawItem.decisionDate } else { '' }

        # completed field: boolean indicating whether remediation provisioning finished
        $remediationComplete = $false
        if ($null -ne $rawItem.PSObject.Properties['completed'] -and $null -ne $rawItem.completed) {
            try { $remediationComplete = [bool]$rawItem.completed } catch { $remediationComplete = $false }
        }

        $revokedItems.Add([PSCustomObject]@{
            IdentityName          = $identityName
            AccessName            = $accessName
            AccessType            = $accessType
            SourceName            = $sourceName
            ReviewerName          = $reviewerName
            DecisionDate          = $decisionDate
            RemediationComplete   = $remediationComplete
            CertificationName     = $certName
            CampaignName          = $campaignName
        })
    }

    # --- Build reassignment chain from certifications ---
    foreach ($cert in $Certifications) {
        $classification = ''
        if ($null -ne $cert.ReviewerClassification) {
            $classification = [string]$cert.ReviewerClassification
        }
        if ($classification -ne 'Reassigned') { continue }

        $currentReviewer = ''
        if ($null -ne $cert.reviewer -and $null -ne $cert.reviewer.name) {
            $currentReviewer = [string]$cert.reviewer.name
        }

        # Reassigned-from: try cert.reassignment.from.name first, then cert.reassignedFrom.name
        $reassignedFrom = ''
        if ($null -ne $cert.PSObject.Properties['reassignment'] -and
            $null -ne $cert.reassignment) {
            # Try .from.name
            if ($null -ne $cert.reassignment.PSObject.Properties['from'] -and
                $null -ne $cert.reassignment.from -and
                $null -ne $cert.reassignment.from.PSObject.Properties['name'] -and
                $null -ne $cert.reassignment.from.name) {
                $reassignedFrom = [string]$cert.reassignment.from.name
            }
            # Try .from directly if it has a name property at cert level
        }
        if ([string]::IsNullOrWhiteSpace($reassignedFrom) -and
            $null -ne $cert.PSObject.Properties['reassignedFrom'] -and
            $null -ne $cert.reassignedFrom -and
            $null -ne $cert.reassignedFrom.PSObject.Properties['name'] -and
            $null -ne $cert.reassignedFrom.name) {
            $reassignedFrom = [string]$cert.reassignedFrom.name
        }

        $certName = if ($null -ne $cert.name) { [string]$cert.name } else { '' }

        $signOffDate = ''
        if ($null -ne $cert.signed -and -not [string]::IsNullOrWhiteSpace([string]$cert.signed)) {
            $signOffDate = [string]$cert.signed
        }
        elseif ($null -ne $cert.completed -and -not [string]::IsNullOrWhiteSpace([string]$cert.completed)) {
            $signOffDate = [string]$cert.completed
        }

        $phase = if ($null -ne $cert.phase) { [string]$cert.phase } else { '' }

        $reassignChain.Add([PSCustomObject]@{
            CertificationName = $certName
            ReassignedFrom    = $reassignedFrom
            CurrentReviewer   = $currentReviewer
            SignOffDate       = $signOffDate
            Phase             = $phase
        })
    }

    $totalRevoked   = $revokedItems.Count
    $completeCount  = @($revokedItems | Where-Object { $_.RemediationComplete -eq $true }).Count
    $pendingCount   = $totalRevoked - $completeCount

    return @{
        RevokedItems             = $revokedItems.ToArray()
        ReassignmentChain        = $reassignChain.ToArray()
        TotalRevoked             = $totalRevoked
        RemediationCompleteCount = $completeCount
        RemediationPendingCount  = $pendingCount
    }
}

function Measure-SPAuditReviewerMetrics {
    <#
    .SYNOPSIS
        Calculates time-to-decision metrics per reviewer from certification data.
    .DESCRIPTION
        For each completed certification (those with a signed or completed
        timestamp), calculates the elapsed time in hours between assignment
        (created) and sign-off. Aggregates per reviewer and across the
        campaign to produce min, max, average, and median values.

        Certifications without a signed or completed timestamp are excluded
        from time calculations (still in progress).
    .PARAMETER Certifications
        Array of certification objects as returned by Get-SPAuditCertifications.
        Each must have: created, signed or completed, reviewer.name,
        reviewer.email, decisionsMade, ReviewerClassification, totalItems.
    .OUTPUTS
        [hashtable] @{
            ReviewerMetrics     = @( [PSCustomObject] per reviewer )
            CampaignMinHours    = [double] fastest cert completion
            CampaignMaxHours    = [double] slowest cert completion
            CampaignAvgHours    = [double] campaign average hours
            CampaignMedianHours = [double] median across all certs
        }
    .EXAMPLE
        $metrics = Measure-SPAuditReviewerMetrics -Certifications $certifications
        Write-Host "Campaign average: $($metrics.CampaignAvgHours) hours"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Certifications
    )

    # Per-reviewer accumulator keyed by name
    $reviewerMap   = [ordered]@{}
    # All completed cert durations (hours) for campaign-level stats
    $allHours      = [System.Collections.Generic.List[double]]::new()

    foreach ($cert in $Certifications) {
        # --- Extract created date ---
        $createdStr = ''
        if ($null -ne $cert.created -and -not [string]::IsNullOrWhiteSpace([string]$cert.created)) {
            $createdStr = [string]$cert.created
        }

        # --- Extract signed/completed date (prefer signed) ---
        $signedStr = ''
        if ($null -ne $cert.signed -and -not [string]::IsNullOrWhiteSpace([string]$cert.signed)) {
            $signedStr = [string]$cert.signed
        }
        elseif ($null -ne $cert.completed -and -not [string]::IsNullOrWhiteSpace([string]$cert.completed)) {
            $signedStr = [string]$cert.completed
        }

        # Skip certs with no sign-off (still in progress)
        if ([string]::IsNullOrWhiteSpace($createdStr) -or [string]::IsNullOrWhiteSpace($signedStr)) {
            continue
        }

        # --- Parse dates ---
        $dtCreated = $null
        $dtSigned  = $null
        try {
            $dtCreated = [datetime]::Parse($createdStr, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
            $dtSigned  = [datetime]::Parse($signedStr,  [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch {
            # Unparseable timestamp; skip this cert
            continue
        }

        $elapsedHours = ($dtSigned - $dtCreated).TotalHours
        # Guard against clock skew yielding negative values
        if ($elapsedHours -lt 0) { $elapsedHours = 0 }

        $allHours.Add($elapsedHours)

        # --- Extract reviewer fields ---
        $reviewerName   = ''
        $reviewerEmail  = ''
        if ($null -ne $cert.reviewer) {
            $reviewerName  = if ($null -ne $cert.reviewer.name)  { [string]$cert.reviewer.name }  else { '' }
            $reviewerEmail = if ($null -ne $cert.reviewer.email) { [string]$cert.reviewer.email } else { '' }
        }

        $classification = if ($null -ne $cert.ReviewerClassification) { [string]$cert.ReviewerClassification } else { 'Primary' }

        $decisionsMade = 0
        if ($null -ne $cert.decisionsMade) {
            try { $decisionsMade = [int]$cert.decisionsMade } catch { }
        }

        $totalItems = 0
        if ($null -ne $cert.totalItems) {
            try { $totalItems = [int]$cert.totalItems } catch { }
        }

        # --- Accumulate per reviewer ---
        $key = $reviewerName
        if (-not $reviewerMap.Contains($key)) {
            $reviewerMap[$key] = @{
                Name           = $reviewerName
                Email          = $reviewerEmail
                Classification = $classification
                CertsCompleted = 0
                DecisionsMade  = 0
                TotalItems     = 0
                Hours          = [System.Collections.Generic.List[double]]::new()
            }
        }

        $entry = $reviewerMap[$key]
        $entry['CertsCompleted'] = $entry['CertsCompleted'] + 1
        $entry['DecisionsMade']  = $entry['DecisionsMade']  + $decisionsMade
        $entry['TotalItems']     = $entry['TotalItems']     + $totalItems
        $entry['Hours'].Add($elapsedHours)
    }

    # --- Build per-reviewer output objects ---
    $reviewerMetrics = [System.Collections.Generic.List[object]]::new()

    foreach ($key in $reviewerMap.Keys) {
        $entry  = $reviewerMap[$key]
        $hours  = @($entry['Hours'])

        $minH = if ($hours.Count -gt 0) { [Math]::Round(($hours | Measure-Object -Minimum).Minimum, 1) } else { $null }
        $maxH = if ($hours.Count -gt 0) { [Math]::Round(($hours | Measure-Object -Maximum).Maximum, 1) } else { $null }
        $avgH = if ($hours.Count -gt 0) { [Math]::Round(($hours | Measure-Object -Average).Average, 1) } else { $null }

        $reviewerMetrics.Add([PSCustomObject]@{
            Name           = $entry['Name']
            Email          = $entry['Email']
            Classification = $entry['Classification']
            CertsCompleted = $entry['CertsCompleted']
            DecisionsMade  = $entry['DecisionsMade']
            MinHours       = $minH
            MaxHours       = $maxH
            AvgHours       = $avgH
            TotalItems     = $entry['TotalItems']
        })
    }

    # --- Campaign-level stats ---
    $campMin    = $null
    $campMax    = $null
    $campAvg    = $null
    $campMedian = $null

    if ($allHours.Count -gt 0) {
        $campMin = [Math]::Round(($allHours | Measure-Object -Minimum).Minimum, 1)
        $campMax = [Math]::Round(($allHours | Measure-Object -Maximum).Maximum, 1)
        $campAvg = [Math]::Round(($allHours | Measure-Object -Average).Average, 1)

        # Median: sort and pick middle
        $sorted = $allHours | Sort-Object
        $n      = $sorted.Count
        if ($n % 2 -eq 1) {
            $campMedian = [Math]::Round($sorted[($n - 1) / 2], 1)
        }
        else {
            $campMedian = [Math]::Round(($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2, 1)
        }
    }

    return @{
        ReviewerMetrics     = $reviewerMetrics.ToArray()
        CampaignMinHours    = $campMin
        CampaignMaxHours    = $campMax
        CampaignAvgHours    = $campAvg
        CampaignMedianHours = $campMedian
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
        [string]$AnchorId = ''
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

    # --- Section 3: Reviewer Performance ---
    $html += "<h3 $sectionHeadStyle>3. Reviewer Performance</h3>`n"

    if ($null -eq $reviewerMetrics) {
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#777777; font-style:italic;"">Reviewer performance metrics not available (no certification timing data provided).</p>`n"
    }
    else {
        # Campaign-level summary table
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

        # Per-reviewer table
        $perReviewerRows = @($reviewerMetrics['ReviewerMetrics'])
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

    # --- Section 5: Campaign Reports ---
    $html += "<h3 $sectionHeadStyle>5. Campaign Reports</h3>`n"

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

    # --- Section 6: Remediation & Reassignment Proof ---
    $html += "<h3 $sectionHeadStyle>6. Remediation &amp; Reassignment Proof</h3>`n"

    if ($null -ne $remediationProof) {
        # Sub-section A: Remediation Summary
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

        # Sub-section B: Revoked Items - Remediation Status
        $revokedRows = @($remediationProof['RevokedItems'])
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:16px;"">Revoked Items - Remediation Status</p>`n"
        $html += "<table $tableStyle>`n"
        $html += (Build-HtmlTableHeader -Headers @('Identity', 'Access Name', 'Type', 'Source', 'Reviewer', 'Decision Date', 'Remediation'))
        $html += "<tbody>`n"

        if ($revokedRows.Count -eq 0) {
            $html += "<tr><td colspan=""7"" style=""padding:8px 10px; color:#777777; font-style:italic;"">No revoked items recorded.</td></tr>`n"
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

        # Sub-section C: Reassignment Chain
        $chainRows = @($remediationProof['ReassignmentChain'])
        $html += "<p style=""font-family:-apple-system,'Segoe UI',system-ui,sans-serif; font-weight:bold; font-size:13px; margin-bottom:6px; margin-top:16px;"">Reassignment Chain</p>`n"
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
    }
    else {
        # Backward-compatible fallback: render old account-activities data when RemediationProof is absent
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
    'Group-SPAuditRemediationProof',
    'Measure-SPAuditReviewerMetrics',
    'Export-SPAuditHtml',
    'Export-SPAuditText',
    'Export-SPAuditJsonl'
)
