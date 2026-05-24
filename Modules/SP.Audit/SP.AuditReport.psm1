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
        ReviewerName, CertificationId, CertificationName, CampaignName, DecisionDate,
        plus compliance fields: Justification, RemediationStatus, SystemTimestamp,
        CampaignStartDate, CampaignDueDate, ReviewerEmail, Decision, SourceName,
        CampaignCompletionDate.
    .PARAMETER CampaignMetadata
        Optional hashtable with campaign-level dates for compliance output:
            StartDate      - Campaign creation date (ISO 8601 string)
            DueDate        - Campaign deadline (ISO 8601 string)
            CompletionDate - Campaign completion date (ISO 8601 string)
    .PARAMETER CertReviewerEmailMap
        Optional hashtable mapping CertificationId to reviewer email address.
        Used as fallback when the item-level reviewedBy object lacks an email.
    .EXAMPLE
        $grouped = Group-SPAuditDecisions -Items $enrichedItems
        Write-Host "Revoked: $($grouped.Revoked.Count)"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter()]
        [hashtable]$AccountMap = $null,

        [Parameter()]
        [hashtable]$CampaignMetadata = $null,

        [Parameter()]
        [hashtable]$CertReviewerEmailMap = $null
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

        # Resolve identity ID for account lookup
        $identityId = ''
        if ($null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.identityId) {
            $identityId = [string]$rawItem.identitySummary.identityId
        }
        if ([string]::IsNullOrWhiteSpace($identityId) -and
            $null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.id) {
            $identityId = [string]$rawItem.identitySummary.id
        }

        # Look up account details from AccountMap
        $accountName       = ''
        $accountIdentifier = ''
        if ($null -ne $AccountMap -and -not [string]::IsNullOrWhiteSpace($identityId) -and $AccountMap.ContainsKey($identityId)) {
            $acct = $AccountMap[$identityId]
            $accountName = if (-not [string]::IsNullOrWhiteSpace($acct.SamAccountName)) { $acct.SamAccountName } else { '' }
            $accountIdentifier = if (-not [string]::IsNullOrWhiteSpace($acct.UserPrincipalName)) { $acct.UserPrincipalName }
                                 elseif (-not [string]::IsNullOrWhiteSpace($acct.SamAccountName)) { $acct.SamAccountName }
                                 elseif (-not [string]::IsNullOrWhiteSpace($acct.NativeIdentity)) { $acct.NativeIdentity }
                                 else { '' }
        }

        # Extract compliance fields
        $justification = ''
        if ($null -ne $rawItem.PSObject -and $null -ne $rawItem.PSObject.Properties['comment'] -and
            $null -ne $rawItem.comment -and -not [string]::IsNullOrWhiteSpace([string]$rawItem.comment)) {
            $justification = [string]$rawItem.comment
        }

        $systemTimestamp = ''
        if ($null -ne $rawItem.PSObject -and $null -ne $rawItem.PSObject.Properties['modified'] -and
            $null -ne $rawItem.modified) {
            $systemTimestamp = [string]$rawItem.modified
        }
        elseif ($null -ne $rawItem.PSObject -and $null -ne $rawItem.PSObject.Properties['created'] -and
                $null -ne $rawItem.created) {
            $systemTimestamp = [string]$rawItem.created
        }

        # Reviewer email: try item-level reviewedBy.email, fall back to cert-level map
        $reviewerEmail = ''
        if ($null -ne $rawItem.reviewedBy -and
            $null -ne $rawItem.reviewedBy.PSObject.Properties['email'] -and
            -not [string]::IsNullOrWhiteSpace([string]$rawItem.reviewedBy.email)) {
            $reviewerEmail = [string]$rawItem.reviewedBy.email
        }
        elseif ($null -ne $CertReviewerEmailMap -and -not [string]::IsNullOrWhiteSpace($certId) -and
                $CertReviewerEmailMap.ContainsKey($certId)) {
            $reviewerEmail = [string]$CertReviewerEmailMap[$certId]
        }

        # Source/Application name
        $sourceName = ''
        if ($null -ne $rawItem.access -and
            $null -ne $rawItem.access.PSObject.Properties['source'] -and
            $null -ne $rawItem.access.source -and
            $null -ne $rawItem.access.source.PSObject.Properties['name'] -and
            $null -ne $rawItem.access.source.name) {
            $sourceName = [string]$rawItem.access.source.name
        }

        # Campaign metadata fields
        $campaignStartDate      = ''
        $campaignDueDate        = ''
        $campaignCompletionDate = ''
        if ($null -ne $CampaignMetadata) {
            if ($CampaignMetadata.ContainsKey('StartDate'))      { $campaignStartDate      = [string]$CampaignMetadata['StartDate'] }
            if ($CampaignMetadata.ContainsKey('DueDate'))        { $campaignDueDate        = [string]$CampaignMetadata['DueDate'] }
            if ($CampaignMetadata.ContainsKey('CompletionDate')) { $campaignCompletionDate = [string]$CampaignMetadata['CompletionDate'] }
        }

        # Decision and remediation status
        $decision = if ($null -ne $rawItem.decision) { [string]$rawItem.decision } else { '' }
        $remediationStatus = 'N/A'
        $remediationDate   = ''
        if ($decision.ToUpperInvariant() -eq 'REVOKE') {
            $isCompleted = $false
            if ($null -ne $rawItem.PSObject -and $null -ne $rawItem.PSObject.Properties['completed'] -and
                $null -ne $rawItem.completed) {
                try { $isCompleted = [bool]$rawItem.completed } catch { $isCompleted = $false }
            }
            if ($isCompleted) {
                $remediationStatus = 'Provisioned'
                # Use modified timestamp as best available remediation date
                $remediationDate = $systemTimestamp
            }
            else {
                $remediationStatus = 'Pending'
            }
        }

        # Build normalized output object
        $out = [PSCustomObject]@{
            IdentityId             = $identityId
            IdentityName           = if ($null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.name) { $rawItem.identitySummary.name } else { '' }
            AccountName            = $accountName
            AccountIdentifier      = $accountIdentifier
            AccessName             = if ($null -ne $rawItem.access -and $null -ne $rawItem.access.name)                   { $rawItem.access.name }           else { '' }
            AccessType             = if ($null -ne $rawItem.access -and $null -ne $rawItem.access.type)                   { $rawItem.access.type }           else { '' }
            SourceName             = $sourceName
            ReviewerName           = $reviewerName
            ReviewerEmail          = $reviewerEmail
            Decision               = $decision
            CertificationId        = $certId
            CertificationName      = $certName
            CampaignName           = $campaignName
            DecisionDate           = if ($null -ne $rawItem.decisionDate) { $rawItem.decisionDate } else { '' }
            Justification          = $justification
            RemediationStatus      = $remediationStatus
            RemediationDate        = $remediationDate
            SystemTimestamp        = $systemTimestamp
            CampaignStartDate      = $campaignStartDate
            CampaignDueDate        = $campaignDueDate
            CampaignCompletionDate = $campaignCompletionDate
        }

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
        [object[]]$Certifications,

        [Parameter()]
        [hashtable]$AccountMap = $null
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

        # Resolve identity ID for account lookup
        $identityId = ''
        if ($null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.identityId) {
            $identityId = [string]$rawItem.identitySummary.identityId
        }
        if ([string]::IsNullOrWhiteSpace($identityId) -and
            $null -ne $rawItem.identitySummary -and $null -ne $rawItem.identitySummary.id) {
            $identityId = [string]$rawItem.identitySummary.id
        }

        # Look up account identifier from AccountMap
        $accountIdentifier = ''
        if ($null -ne $AccountMap -and -not [string]::IsNullOrWhiteSpace($identityId) -and $AccountMap.ContainsKey($identityId)) {
            $acct = $AccountMap[$identityId]
            $accountIdentifier = if (-not [string]::IsNullOrWhiteSpace($acct.UserPrincipalName)) { $acct.UserPrincipalName }
                                 elseif (-not [string]::IsNullOrWhiteSpace($acct.SamAccountName)) { $acct.SamAccountName }
                                 elseif (-not [string]::IsNullOrWhiteSpace($acct.NativeIdentity)) { $acct.NativeIdentity }
                                 else { '' }
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
            AccountIdentifier     = $accountIdentifier
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

function Measure-SPAuditRubberStampRisk {
    <#
    .SYNOPSIS
        Detects potential rubber-stamping patterns in certification review decisions.
    .DESCRIPTION
        Analyzes per-reviewer decision behavior to flag potential rubber-stamping.
        Based on SOX/SOC2 auditor red flags:

        1. Decision velocity: items decided per minute. Flagged if >50 items in <60 seconds.
        2. Approval-only rate: % of decisions that are APPROVE. Flagged if 100% across >10 items.
        3. Bulk decision detection: clusters of identical decisions within 30-second windows.
        4. Response latency: time from campaign creation to first decision. Flagged if <1 minute.

        Each reviewer receives a severity: None, Low, Medium, or High.
        High = multiple red flags present.
    .PARAMETER Decisions
        Hashtable with Approved, Revoked, Pending arrays (output of Group-SPAuditDecisions).
        Each item must have ReviewerName and DecisionDate properties.
    .PARAMETER Certifications
        Array of certification objects (for campaign creation timestamps).
    .OUTPUTS
        [hashtable] @{
            ReviewerRisks = @( [PSCustomObject] per reviewer )
            HasMediumOrHighRisk = [bool]
        }
    .EXAMPLE
        $risk = Measure-SPAuditRubberStampRisk -Decisions $decisions -Certifications $certs
        if ($risk.HasMediumOrHighRisk) { Write-Host "Rubber-stamping detected" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Certifications
    )

    # Build a map of reviewer -> list of (decision, datetime) tuples
    $reviewerDecisions = @{}

    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
        if (-not $Decisions.ContainsKey($category) -or $null -eq $Decisions[$category]) { continue }
        $decisionLabel = $category  # Approved, Revoked, Pending
        foreach ($item in @($Decisions[$category])) {
            $reviewer = if ($null -ne $item.ReviewerName -and -not [string]::IsNullOrWhiteSpace($item.ReviewerName)) {
                $item.ReviewerName
            } else { 'Unknown' }

            $dt = $null
            $rawDate = if ($null -ne $item.DecisionDate -and -not [string]::IsNullOrWhiteSpace([string]$item.DecisionDate)) {
                [string]$item.DecisionDate
            } else { '' }

            if (-not [string]::IsNullOrWhiteSpace($rawDate)) {
                try {
                    $dt = [datetime]::Parse($rawDate, [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
                }
                catch { $dt = $null }
            }

            if (-not $reviewerDecisions.ContainsKey($reviewer)) {
                $reviewerDecisions[$reviewer] = [System.Collections.Generic.List[object]]::new()
            }
            $reviewerDecisions[$reviewer].Add(@{
                Decision = $decisionLabel
                DateTime = $dt
            })
        }
    }

    # Build campaign creation timestamp map (earliest cert created per reviewer)
    $campaignCreatedMap = @{}
    foreach ($cert in $Certifications) {
        $reviewerName = ''
        if ($null -ne $cert.reviewer -and $null -ne $cert.reviewer.name) {
            $reviewerName = [string]$cert.reviewer.name
        }
        if ([string]::IsNullOrWhiteSpace($reviewerName)) { continue }

        $createdStr = ''
        if ($null -ne $cert.created -and -not [string]::IsNullOrWhiteSpace([string]$cert.created)) {
            $createdStr = [string]$cert.created
        }
        if ([string]::IsNullOrWhiteSpace($createdStr)) { continue }

        try {
            $dtCreated = [datetime]::Parse($createdStr, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
            if (-not $campaignCreatedMap.ContainsKey($reviewerName) -or $dtCreated -lt $campaignCreatedMap[$reviewerName]) {
                $campaignCreatedMap[$reviewerName] = $dtCreated
            }
        }
        catch { }
    }

    # Analyze each reviewer
    $reviewerRisks = [System.Collections.Generic.List[object]]::new()
    $hasMediumOrHigh = $false

    foreach ($reviewer in $reviewerDecisions.Keys) {
        $items = @($reviewerDecisions[$reviewer])
        $totalItems = $items.Count
        $flags = [System.Collections.Generic.List[string]]::new()

        # --- Metric 1: Approval-only rate ---
        $approveCount = @($items | Where-Object { $_['Decision'] -eq 'Approved' }).Count
        $revokeCount  = @($items | Where-Object { $_['Decision'] -eq 'Revoked' }).Count
        $approvalRate = if ($totalItems -gt 0) { [Math]::Round(($approveCount / $totalItems) * 100, 1) } else { 0 }
        $approvalOnlyFlag = ($approvalRate -eq 100 -and $totalItems -gt 10)
        if ($approvalOnlyFlag) {
            $flags.Add('100% approval rate across ' + $totalItems + ' items')
        }

        # --- Get items with valid timestamps for velocity analysis ---
        $timedItems = @($items | Where-Object { $null -ne $_['DateTime'] } | Sort-Object { $_['DateTime'] })

        # --- Metric 2: Decision velocity (items per minute) ---
        $velocityItemsPerMin = 0
        $velocityFlag = $false
        if ($timedItems.Count -ge 2) {
            $firstDt = $timedItems[0]['DateTime']
            $lastDt  = $timedItems[$timedItems.Count - 1]['DateTime']
            $spanMinutes = ($lastDt - $firstDt).TotalMinutes
            if ($spanMinutes -gt 0) {
                $velocityItemsPerMin = [Math]::Round($timedItems.Count / $spanMinutes, 1)
            }
            else {
                # All decisions at the same timestamp
                $velocityItemsPerMin = $timedItems.Count
            }
            # Flag: >50 items in <60 seconds
            $spanSeconds = ($lastDt - $firstDt).TotalSeconds
            if ($timedItems.Count -gt 50 -and $spanSeconds -lt 60) {
                $velocityFlag = $true
                $flags.Add('' + $timedItems.Count + ' items in ' + [Math]::Round($spanSeconds, 0) + ' seconds')
            }
        }

        # --- Metric 3: Bulk decision clusters (>5 identical decisions within 30-second windows) ---
        $bulkClusters = 0
        if ($timedItems.Count -ge 2) {
            $windowStart = 0
            while ($windowStart -lt $timedItems.Count) {
                $windowEnd = $windowStart
                $windowDecision = $timedItems[$windowStart]['Decision']
                $windowStartDt = $timedItems[$windowStart]['DateTime']

                # Extend window while within 30 seconds and same decision
                while ($windowEnd + 1 -lt $timedItems.Count) {
                    $nextDt = $timedItems[$windowEnd + 1]['DateTime']
                    $nextDecision = $timedItems[$windowEnd + 1]['Decision']
                    if ($nextDecision -eq $windowDecision -and ($nextDt - $windowStartDt).TotalSeconds -le 30) {
                        $windowEnd++
                    }
                    else {
                        break
                    }
                }

                $clusterSize = $windowEnd - $windowStart + 1
                if ($clusterSize -gt 5) {
                    $bulkClusters++
                }
                $windowStart = $windowEnd + 1
            }
        }
        if ($bulkClusters -gt 0) {
            $flags.Add('' + $bulkClusters + ' bulk decision cluster(s) (>5 identical in 30s)')
        }

        # --- Metric 4: Response latency ---
        $responseLatencyMinutes = $null
        $latencyFlag = $false
        if ($timedItems.Count -gt 0 -and $campaignCreatedMap.ContainsKey($reviewer)) {
            $certCreated = $campaignCreatedMap[$reviewer]
            $firstDecision = $timedItems[0]['DateTime']
            $responseLatencyMinutes = [Math]::Round(($firstDecision - $certCreated).TotalMinutes, 1)
            if ($responseLatencyMinutes -lt 0) { $responseLatencyMinutes = 0 }
            if ($responseLatencyMinutes -lt 1 -and $totalItems -gt 5) {
                $latencyFlag = $true
                $flags.Add('First decision <1 min after assignment (' + $responseLatencyMinutes + ' min)')
            }
        }

        # --- Determine severity ---
        $flagCount = $flags.Count
        $severity = if ($flagCount -ge 2) { 'High' }
                    elseif ($flagCount -eq 1 -and ($velocityFlag -or $approvalOnlyFlag)) { 'Medium' }
                    elseif ($flagCount -eq 1) { 'Low' }
                    else { 'None' }

        if ($severity -eq 'Medium' -or $severity -eq 'High') {
            $hasMediumOrHigh = $true
        }

        $reviewerRisks.Add([PSCustomObject]@{
            ReviewerName          = $reviewer
            TotalItems            = $totalItems
            ApprovalRate          = $approvalRate
            VelocityItemsPerMin   = $velocityItemsPerMin
            BulkClusters          = $bulkClusters
            ResponseLatencyMin    = $responseLatencyMinutes
            Severity              = $severity
            Flags                 = @($flags)
        })
    }

    return @{
        ReviewerRisks       = $reviewerRisks.ToArray()
        HasMediumOrHighRisk = $hasMediumOrHigh
    }
}

function Get-SPAuditRiskFlags {
    <#
    .SYNOPSIS
        Evaluates per-identity risk flags for access review decision items.
    .DESCRIPTION
        Analyzes each decision item and assigns zero or more risk flags based
        on identity attributes, entitlement patterns, and lifecycle state.

        Risk flags:
        - STALE (orange): Identity last login >N days ago (default 90).
        - PRIVILEGED (red): Entitlement name matches admin/elevated patterns.
        - ORPHAN (red): Identity has no manager.
        - TERMINATED (red): Identity lifecycle state is terminated but still has access.
        - SVC-ACCOUNT (gray): Identity matches service account naming patterns.

        Patterns are configurable via the RiskIndicators parameter (sourced
        from settings.json Audit.RiskIndicators).
    .PARAMETER Decisions
        Hashtable from Group-SPAuditDecisions with Approved, Revoked, Pending arrays.
    .PARAMETER Identities
        Optional hashtable mapping identity ID to identity attribute objects.
        Each value should have properties: lifecycleState, manager (or managerRef),
        lastLogin (or attributes.lastLogin). When absent, only entitlement-based
        flags (PRIVILEGED, SVC-ACCOUNT) are evaluated.
    .PARAMETER RiskIndicators
        Hashtable with configurable thresholds and patterns:
            StaleAccessDays       - int, days since last login to flag as stale (default 90)
            PrivilegedPatterns    - string[], entitlement name patterns (default @('Admin','Root','DBA','Domain Admins'))
            ServiceAccountPatterns - string[], identity name regex patterns (default @('^SVC-','^svc-'))
    .OUTPUTS
        [hashtable] @{
            Decisions = @{ Approved = @(...); Revoked = @(...); Pending = @(...) }
            Summary   = @{ Total = int; Flagged = int; ByFlag = @{...} }
        }
        Each decision item in the returned Decisions gets a RiskFlags string[] property added.
    .EXAMPLE
        $flagged = Get-SPAuditRiskFlags -Decisions $decisions -RiskIndicators $config.Audit.RiskIndicators
        $flagged.Summary.Flagged  # count of items with at least one flag
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter()]
        [hashtable]$Identities = $null,

        [Parameter()]
        [hashtable]$RiskIndicators = $null
    )

    # --- Parse configuration with defaults ---
    $staleAccessDays = 90
    $privilegedPatterns = @('Admin', 'Root', 'DBA', 'Domain Admins')
    $serviceAccountPatterns = @('^SVC-', '^svc-')

    if ($null -ne $RiskIndicators) {
        if ($RiskIndicators.ContainsKey('StaleAccessDays') -and $null -ne $RiskIndicators['StaleAccessDays']) {
            $staleAccessDays = [int]$RiskIndicators['StaleAccessDays']
        }
        if ($RiskIndicators.ContainsKey('PrivilegedPatterns') -and $null -ne $RiskIndicators['PrivilegedPatterns']) {
            $privilegedPatterns = @($RiskIndicators['PrivilegedPatterns'])
        }
        if ($RiskIndicators.ContainsKey('ServiceAccountPatterns') -and $null -ne $RiskIndicators['ServiceAccountPatterns']) {
            $serviceAccountPatterns = @($RiskIndicators['ServiceAccountPatterns'])
        }
    }

    # If all patterns are empty, return decisions unmodified (backwards compatible)
    $hasPrivileged = ($privilegedPatterns.Count -gt 0)
    $hasSvcPatterns = ($serviceAccountPatterns.Count -gt 0)
    $hasIdentities = ($null -ne $Identities -and $Identities.Count -gt 0)

    # Tracking counters
    $totalItems = 0
    $flaggedCount = 0
    $flagCounts = @{
        STALE         = 0
        PRIVILEGED    = 0
        ORPHAN        = 0
        TERMINATED    = 0
        'SVC-ACCOUNT' = 0
    }

    $now = Get-Date
    $staleCutoff = $now.AddDays(-$staleAccessDays)

    # --- Process each decision category ---
    $resultDecisions = @{}

    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
        $items = @()
        if ($Decisions.ContainsKey($category) -and $null -ne $Decisions[$category]) {
            $items = @($Decisions[$category])
        }

        $outputItems = [System.Collections.Generic.List[object]]::new()

        foreach ($item in $items) {
            $totalItems++
            $flags = [System.Collections.Generic.List[string]]::new()

            $identityName = ''
            $identityId   = ''
            $accessName   = ''

            if ($null -ne $item) {
                $identityName = if ($null -ne $item.IdentityName) { [string]$item.IdentityName } else { '' }
                $identityId   = if ($null -ne $item.IdentityId)   { [string]$item.IdentityId }   else { '' }
                $accessName   = if ($null -ne $item.AccessName)   { [string]$item.AccessName }   else { '' }
            }

            # --- Flag: PRIVILEGED (entitlement name pattern match) ---
            if ($hasPrivileged -and -not [string]::IsNullOrWhiteSpace($accessName)) {
                foreach ($pattern in $privilegedPatterns) {
                    if ($accessName -match [regex]::Escape($pattern)) {
                        $flags.Add('PRIVILEGED')
                        break
                    }
                }
            }

            # --- Flag: SVC-ACCOUNT (identity name regex match) ---
            if ($hasSvcPatterns -and -not [string]::IsNullOrWhiteSpace($identityName)) {
                foreach ($pattern in $serviceAccountPatterns) {
                    if ($identityName -match $pattern) {
                        $flags.Add('SVC-ACCOUNT')
                        break
                    }
                }
            }

            # --- Identity-dependent flags (require Identities map) ---
            if ($hasIdentities -and -not [string]::IsNullOrWhiteSpace($identityId) -and $Identities.ContainsKey($identityId)) {
                $identity = $Identities[$identityId]

                # --- Flag: TERMINATED ---
                $lifecycleState = ''
                if ($null -ne $identity) {
                    if ($identity -is [hashtable]) {
                        if ($identity.ContainsKey('lifecycleState')) { $lifecycleState = [string]$identity['lifecycleState'] }
                    }
                    elseif ($null -ne $identity.PSObject) {
                        $lsProp = $identity.PSObject.Properties['lifecycleState']
                        if ($null -ne $lsProp -and $null -ne $lsProp.Value) { $lifecycleState = [string]$lsProp.Value }
                    }
                }
                if ($lifecycleState -eq 'terminated') {
                    $flags.Add('TERMINATED')
                }

                # --- Flag: ORPHAN (no manager) ---
                $hasManager = $false
                if ($null -ne $identity) {
                    if ($identity -is [hashtable]) {
                        $hasManager = ($identity.ContainsKey('manager') -and
                            $null -ne $identity['manager'] -and
                            -not [string]::IsNullOrWhiteSpace([string]$identity['manager']))
                        if (-not $hasManager) {
                            $hasManager = ($identity.ContainsKey('managerRef') -and $null -ne $identity['managerRef'])
                        }
                    }
                    else {
                        $mgrProp = $identity.PSObject.Properties['manager']
                        $hasManager = ($null -ne $mgrProp -and $null -ne $mgrProp.Value -and
                            -not [string]::IsNullOrWhiteSpace([string]$mgrProp.Value))
                        if (-not $hasManager) {
                            $mgrRefProp = $identity.PSObject.Properties['managerRef']
                            $hasManager = ($null -ne $mgrRefProp -and $null -ne $mgrRefProp.Value)
                        }
                    }
                }
                if (-not $hasManager) {
                    $flags.Add('ORPHAN')
                }

                # --- Flag: STALE (last login > N days ago) ---
                $lastLoginStr = ''
                if ($null -ne $identity) {
                    if ($identity -is [hashtable]) {
                        if ($identity.ContainsKey('lastLogin')) {
                            $lastLoginStr = [string]$identity['lastLogin']
                        }
                        elseif ($identity.ContainsKey('attributes') -and $null -ne $identity['attributes']) {
                            $attrs = $identity['attributes']
                            if ($attrs -is [hashtable] -and $attrs.ContainsKey('lastLogin')) {
                                $lastLoginStr = [string]$attrs['lastLogin']
                            }
                            elseif ($null -ne $attrs.PSObject) {
                                $llProp = $attrs.PSObject.Properties['lastLogin']
                                if ($null -ne $llProp -and $null -ne $llProp.Value) {
                                    $lastLoginStr = [string]$llProp.Value
                                }
                            }
                        }
                    }
                    else {
                        $llProp = $identity.PSObject.Properties['lastLogin']
                        if ($null -ne $llProp -and $null -ne $llProp.Value) {
                            $lastLoginStr = [string]$llProp.Value
                        }
                        elseif ($null -ne $identity.PSObject.Properties['attributes']) {
                            $attrs = $identity.attributes
                            if ($null -ne $attrs) {
                                $llAttr = $attrs.PSObject.Properties['lastLogin']
                                if ($null -ne $llAttr -and $null -ne $llAttr.Value) {
                                    $lastLoginStr = [string]$llAttr.Value
                                }
                            }
                        }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($lastLoginStr)) {
                    try {
                        $lastLoginDt = [datetime]::Parse($lastLoginStr,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($lastLoginDt -lt $staleCutoff) {
                            $flags.Add('STALE')
                        }
                    }
                    catch { }
                }
            }

            # --- Attach flags to item ---
            $flagsArray = @($flags)

            # Create new object with RiskFlags property added
            $props = [ordered]@{}
            if ($null -ne $item -and $null -ne $item.PSObject) {
                foreach ($p in $item.PSObject.Properties) {
                    $props[$p.Name] = $p.Value
                }
            }
            $props['RiskFlags'] = $flagsArray
            $enrichedItem = [PSCustomObject]$props

            if ($flagsArray.Count -gt 0) {
                $flaggedCount++
                foreach ($f in $flagsArray) {
                    if ($flagCounts.ContainsKey($f)) {
                        $flagCounts[$f]++
                    }
                }
            }

            $outputItems.Add($enrichedItem)
        }

        $resultDecisions[$category] = $outputItems.ToArray()
    }

    return @{
        Decisions = $resultDecisions
        Summary   = @{
            Total   = $totalItems
            Flagged = $flaggedCount
            ByFlag  = $flagCounts
        }
    }
}

function Group-SPAuditByLeadership {
    <#
    .SYNOPSIS
        Groups audit decisions by leadership level using the org tree.
    .DESCRIPTION
        Takes the categorised decisions from Group-SPAuditDecisions and the
        org tree from Build-SPOrgTree and produces per-director and per-executive
        rollup summaries. Each director rollup contains per-manager aggregates.
        Each executive rollup references its directors.

        Identities whose name cannot be matched to a leaf node in the org tree,
        or whose manager chain does not reach a director-level node, are grouped
        under an 'Unmanaged' bucket.
    .PARAMETER Decisions
        Hashtable with Approved, Revoked, Pending arrays as returned by
        Group-SPAuditDecisions. Each element has IdentityName, ReviewerName, etc.
    .PARAMETER OrgTree
        Hashtable from Build-SPOrgTree .Data containing Nodes, TopLeaders,
        Directors, Managers, LeafCount, MaxDepthHit.
    .PARAMETER ReviewerMetrics
        Optional hashtable from Measure-SPAuditReviewerMetrics. When provided,
        AvgHours per reviewer name is mapped to the corresponding manager entry.
    .OUTPUTS
        [hashtable] @{ Directors = @{...}; Executive = @{...} }
    .EXAMPLE
        $leadership = Group-SPAuditByLeadership -Decisions $grouped -OrgTree $tree.Data
        $leadership.Directors.Keys | ForEach-Object { "$_: $($leadership.Directors[$_].Name)" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter()]
        [hashtable]$ReviewerMetrics
    )

    $nodes = $OrgTree.Nodes

    # --- Build identity name -> leaf node ID reverse lookup ---
    # Leaf nodes (level 0) represent the reviewed identities whose names
    # appear in the Decisions output from Group-SPAuditDecisions.
    $nameToLeafId = @{}
    foreach ($nodeId in $nodes.Keys) {
        $node = $nodes[$nodeId]
        if ($node.Level -eq 0 -and $null -ne $node.Identity -and
            -not [string]::IsNullOrWhiteSpace($node.Identity.Name)) {
            $nameToLeafId[$node.Identity.Name] = $nodeId
        }
    }

    # --- Build reviewer name -> AvgHours lookup from ReviewerMetrics ---
    # In ISC manager campaigns, the reviewer IS the manager, so reviewer
    # names map directly to manager node names in the org tree.
    $reviewerAvgHours = @{}
    if ($null -ne $ReviewerMetrics -and $null -ne $ReviewerMetrics['ReviewerMetrics']) {
        foreach ($rm in @($ReviewerMetrics['ReviewerMetrics'])) {
            if ($null -ne $rm -and -not [string]::IsNullOrWhiteSpace($rm.Name)) {
                $reviewerAvgHours[$rm.Name] = $rm.AvgHours
            }
        }
    }

    # --- For each leaf node, determine its manager and director ---
    # leafToManager: leafId -> managerId (level 1 node, or '' if missing)
    # managerToDirector: managerId -> directorId (level 2+ node, or '' if missing)
    $leafToManager     = @{}
    $managerToDirector = @{}

    foreach ($nodeId in $nodes.Keys) {
        $node = $nodes[$nodeId]
        if ($node.Level -ne 0) { continue }

        $managerId = $node.ManagerId
        if (-not [string]::IsNullOrWhiteSpace($managerId) -and $nodes.ContainsKey($managerId)) {
            $leafToManager[$nodeId] = $managerId
        }
        else {
            $leafToManager[$nodeId] = ''
        }
    }

    # Determine director for each unique manager
    foreach ($managerId in @($leafToManager.Values | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($managerId)) { continue }
        if ($managerToDirector.ContainsKey($managerId)) { continue }

        if (-not $nodes.ContainsKey($managerId)) {
            $managerToDirector[$managerId] = ''
            continue
        }

        $mgrNode = $nodes[$managerId]

        # If the manager node itself is at level 2+, it IS the director
        if ($mgrNode.Level -ge 2) {
            $managerToDirector[$managerId] = $managerId
            continue
        }

        # Walk one level up to find the director
        $dirId = $mgrNode.ManagerId
        if (-not [string]::IsNullOrWhiteSpace($dirId) -and $nodes.ContainsKey($dirId)) {
            $managerToDirector[$managerId] = $dirId
        }
        else {
            $managerToDirector[$managerId] = ''
        }
    }

    # --- Count decisions per manager per director ---
    $unmanagedKey = '__unmanaged__'
    # Accumulator: directorId -> managerId -> @{ Approved; Revoked; Pending }
    $buckets = @{}

    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
        $items = @()
        if ($Decisions.ContainsKey($category) -and $null -ne $Decisions[$category]) {
            $items = @($Decisions[$category])
        }

        foreach ($item in $items) {
            $identityName = if ($null -ne $item.IdentityName) { [string]$item.IdentityName } else { '' }

            # Resolve: identity name -> leaf node -> manager -> director
            $managerId  = $unmanagedKey
            $directorId = $unmanagedKey

            if (-not [string]::IsNullOrWhiteSpace($identityName) -and
                $nameToLeafId.ContainsKey($identityName)) {
                $leafId = $nameToLeafId[$identityName]

                if ($leafToManager.ContainsKey($leafId)) {
                    $mgr = $leafToManager[$leafId]
                    if (-not [string]::IsNullOrWhiteSpace($mgr)) {
                        $managerId = $mgr
                        if ($managerToDirector.ContainsKey($mgr) -and
                            -not [string]::IsNullOrWhiteSpace($managerToDirector[$mgr])) {
                            $directorId = $managerToDirector[$mgr]
                        }
                    }
                }
            }

            if (-not $buckets.ContainsKey($directorId)) { $buckets[$directorId] = @{} }
            if (-not $buckets[$directorId].ContainsKey($managerId)) {
                $buckets[$directorId][$managerId] = @{ Approved = 0; Revoked = 0; Pending = 0 }
            }

            $buckets[$directorId][$managerId][$category]++
        }
    }

    # --- Build Directors rollup ---
    $directors = @{}

    foreach ($dirId in $buckets.Keys) {
        $managerBuckets = $buckets[$dirId]

        # Director identity info
        $dirName  = 'Unmanaged'
        $dirEmail = ''
        if ($dirId -ne $unmanagedKey -and $nodes.ContainsKey($dirId)) {
            $dirNode = $nodes[$dirId]
            $dirName = if ($null -ne $dirNode.Identity -and
                -not [string]::IsNullOrWhiteSpace($dirNode.Identity.Name)) {
                $dirNode.Identity.Name
            } else { $dirId }
        }

        $totalApproved = 0
        $totalRevoked  = 0
        $totalPending  = 0
        $managersMap   = @{}

        foreach ($mgrId in $managerBuckets.Keys) {
            $c = $managerBuckets[$mgrId]
            $totalApproved += $c.Approved
            $totalRevoked  += $c.Revoked
            $totalPending  += $c.Pending

            # Manager name and average hours from reviewer metrics
            $mgrName = 'Unmanaged'
            if ($mgrId -ne $unmanagedKey -and $nodes.ContainsKey($mgrId)) {
                $mgrNode = $nodes[$mgrId]
                $mgrName = if ($null -ne $mgrNode.Identity -and
                    -not [string]::IsNullOrWhiteSpace($mgrNode.Identity.Name)) {
                    $mgrNode.Identity.Name
                } else { $mgrId }
            }

            $avgHours = $null
            if ($reviewerAvgHours.ContainsKey($mgrName)) {
                $avgHours = $reviewerAvgHours[$mgrName]
            }

            $managersMap[$mgrId] = @{
                Name     = $mgrName
                Approved = $c.Approved
                Revoked  = $c.Revoked
                Pending  = $c.Pending
                AvgHours = $avgHours
            }
        }

        $totalItems    = $totalApproved + $totalRevoked + $totalPending
        $completionPct = if ($totalItems -gt 0) {
            [Math]::Round(($totalApproved + $totalRevoked) / $totalItems * 100, 1)
        } else { 0.0 }

        $directors[$dirId] = @{
            Name          = $dirName
            Email         = $dirEmail
            TotalItems    = $totalItems
            Approved      = $totalApproved
            Revoked       = $totalRevoked
            Pending       = $totalPending
            CompletionPct = $completionPct
            Managers      = $managersMap
        }
    }

    # --- Build per-level Levels structure ---

    $discoveredTopLevel = 0
    foreach ($nodeId in $nodes.Keys) {
        $lvl = $nodes[$nodeId].Level
        if ($lvl -gt $discoveredTopLevel) { $discoveredTopLevel = $lvl }
    }

    # Labels assigned by position FROM THE TOP (not from leaves).
    # Position 0 = top leader, 1 = one below, 2 = two below, etc.
    $topDownLabelList = @(
        'Executive Leadership'    # 0: top
        'Vice Presidents'         # 1: one below top
        'Directors'               # 2: two below top
        'Managers'                # 3: three below top
        'Team Leads'              # 4
        'Individual Contributors' # 5+
    )
    $levelLabels = @{}
    for ($lvl = 0; $lvl -le [Math]::Max($discoveredTopLevel, 5); $lvl++) {
        $posFromTop = $discoveredTopLevel - $lvl
        if ($posFromTop -lt 0) { $posFromTop = $topDownLabelList.Count - 1 }
        if ($posFromTop -ge $topDownLabelList.Count) { $posFromTop = 0 }
        $levelLabels[$lvl] = $topDownLabelList[$posFromTop]
    }

    $levels = @{}

    # Level 2 = Directors (from existing $directors computation above)
    if ($directors.Count -gt 0) {
        $label2 = if ($levelLabels.ContainsKey(2)) { $levelLabels[2] } else { 'Directors' }
        $levels[2] = @{ Label = $label2; Leaders = $directors }
    }

    # Level 3+: each leader at level N aggregates subordinates from level N-1
    for ($lvl = 3; $lvl -le $discoveredTopLevel; $lvl++) {
        $lowerLevel = $lvl - 1
        if (-not $levels.ContainsKey($lowerLevel)) { continue }
        $lowerLeaders = $levels[$lowerLevel].Leaders
        if ($null -eq $lowerLeaders -or $lowerLeaders.Count -eq 0) { continue }

        $thisLevelLeaders = @{}

        foreach ($subId in @($lowerLeaders.Keys)) {
            if ($subId -eq $unmanagedKey) { continue }

            # Find parent at this level
            $parentId = $unmanagedKey
            if ($nodes.ContainsKey($subId)) {
                $subParent = $nodes[$subId].ManagerId
                if (-not [string]::IsNullOrWhiteSpace($subParent) -and
                    $nodes.ContainsKey($subParent) -and
                    $nodes[$subParent].Level -eq $lvl) {
                    $parentId = $subParent
                }
            }

            if (-not $thisLevelLeaders.ContainsKey($parentId)) {
                $parentName = 'Unmanaged'
                if ($parentId -ne $unmanagedKey -and $nodes.ContainsKey($parentId)) {
                    $pNode = $nodes[$parentId]
                    $parentName = if ($null -ne $pNode.Identity -and
                        -not [string]::IsNullOrWhiteSpace($pNode.Identity.Name)) {
                        $pNode.Identity.Name
                    } else { $parentId }
                }
                $thisLevelLeaders[$parentId] = @{
                    Name          = $parentName
                    TotalItems    = 0
                    Approved      = 0
                    Revoked       = 0
                    Pending       = 0
                    CompletionPct = 0.0
                    Subordinates  = [System.Collections.Generic.List[string]]::new()
                }
            }

            $thisLevelLeaders[$parentId].Subordinates.Add($subId)
            $subData = $lowerLeaders[$subId]
            $thisLevelLeaders[$parentId].TotalItems += $subData.TotalItems
            $thisLevelLeaders[$parentId].Approved   += $subData.Approved
            $thisLevelLeaders[$parentId].Revoked    += $subData.Revoked
            $thisLevelLeaders[$parentId].Pending    += $subData.Pending
        }

        # Calculate completion pct and convert subordinate lists to arrays
        foreach ($leaderId in @($thisLevelLeaders.Keys)) {
            $leader = $thisLevelLeaders[$leaderId]
            $leader.CompletionPct = if ($leader.TotalItems -gt 0) {
                [Math]::Round(($leader.Approved + $leader.Revoked) / $leader.TotalItems * 100, 1)
            } else { 0.0 }
            if ($leader.Subordinates -is [System.Collections.Generic.List[string]]) {
                $leader.Subordinates = @($leader.Subordinates.ToArray())
            }
        }

        if ($thisLevelLeaders.Count -gt 0) {
            $label = if ($levelLabels.ContainsKey($lvl)) { $levelLabels[$lvl] } else { 'Executive Leadership' }
            $levels[$lvl] = @{ Label = $label; Leaders = $thisLevelLeaders }
        }
    }

    # --- Backward-compatible Executive rollup ---
    $executive  = @{}
    $topLeaders = @($OrgTree.TopLeaders)

    if ($discoveredTopLevel -ge 3) {
        # Build Executive from the highest level in Levels
        $execLevel = $discoveredTopLevel
        while ($execLevel -ge 3 -and -not $levels.ContainsKey($execLevel)) {
            $execLevel--
        }
        if ($levels.ContainsKey($execLevel)) {
            foreach ($leaderId in $levels[$execLevel].Leaders.Keys) {
                $leaderData = $levels[$execLevel].Leaders[$leaderId]
                $executive[$leaderId] = @{
                    Name          = $leaderData.Name
                    TotalItems    = $leaderData.TotalItems
                    Approved      = $leaderData.Approved
                    Revoked       = $leaderData.Revoked
                    Pending       = $leaderData.Pending
                    CompletionPct = $leaderData.CompletionPct
                    Directors     = if ($null -ne $leaderData.Subordinates) { $leaderData.Subordinates } else { @() }
                }
            }
        }
    }
    else {
        # Fallback: existing TopLeaders-based logic for 2-level orgs
        foreach ($vpId in $topLeaders) {
            if (-not $nodes.ContainsKey($vpId)) { continue }
            $vpNode = $nodes[$vpId]
            $vpName = if ($null -ne $vpNode.Identity -and
                -not [string]::IsNullOrWhiteSpace($vpNode.Identity.Name)) {
                $vpNode.Identity.Name
            } else { $vpId }

            $vpDirectorIds = [System.Collections.Generic.List[string]]::new()
            foreach ($dirId in $directors.Keys) {
                if ($dirId -eq $unmanagedKey) { continue }
                if ($nodes.ContainsKey($dirId) -and $nodes[$dirId].ManagerId -eq $vpId) {
                    $vpDirectorIds.Add($dirId)
                }
            }
            if ($vpDirectorIds.Count -eq 0 -and $directors.ContainsKey($vpId)) {
                $vpDirectorIds.Add($vpId)
            }

            $vpTotal = 0; $vpApproved = 0; $vpRevoked = 0; $vpPending = 0
            foreach ($dirId in $vpDirectorIds) {
                if ($directors.ContainsKey($dirId)) {
                    $d = $directors[$dirId]
                    $vpTotal    += $d.TotalItems
                    $vpApproved += $d.Approved
                    $vpRevoked  += $d.Revoked
                    $vpPending  += $d.Pending
                }
            }
            $vpCompletionPct = if ($vpTotal -gt 0) {
                [Math]::Round(($vpApproved + $vpRevoked) / $vpTotal * 100, 1)
            } else { 0.0 }

            $executive[$vpId] = @{
                Name          = $vpName
                TotalItems    = $vpTotal
                Approved      = $vpApproved
                Revoked       = $vpRevoked
                Pending       = $vpPending
                CompletionPct = $vpCompletionPct
                Directors     = @($vpDirectorIds.ToArray())
            }
        }
    }

    # Determine the label for the "Directors" bucket. Level numbers are relative to
    # leaves (0=IC, counting up). To find the right label, calculate distance from
    # top: the Directors bucket is always one level below the top leader. In the
    # label table, that corresponds to the label at position (topLevel - directorLevel)
    # counting from the top: position 1 = one below top.
    #
    # Label mapping (position from top):
    #   0 = Executive/President, 1 = VP, 2 = Director, 3 = Manager, 4+ = Team Lead
    $directorLabel = 'Director'
    $topDownLabels = @(
        'Executive Leadership'  # 0: top
        'Vice President'        # 1: one below top
        'Director'              # 2: two below top
        'Manager'               # 3: three below top
        'Team Lead'             # 4: four below top
    )
    # The Directors bucket is at the level just below the top leader
    $posFromTop = 1  # Directors are always 1 level below TopLeaders
    if ($posFromTop -lt $topDownLabels.Count) {
        $directorLabel = $topDownLabels[$posFromTop]
    }

    return @{
        Directors      = $directors
        DirectorLabel  = $directorLabel
        Executive      = $executive
        Levels         = $levels
        TopLevel       = $discoveredTopLevel
        LevelLabels    = $levelLabels
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
        [string]$DetailLevel = 'Verbose'
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

        # --- Title ---
        $reportTitle = if ($isTopLevel) {
            "Executive Summary"
        } else {
            "$($thisLevelLabel -replace 's$', '') Report: $safeLeaderName"
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

function Send-SPReport {
    <#
    .SYNOPSIS
        Logs the intent to send a leadership report to a recipient via email.
    .DESCRIPTION
        Stub function for future SMTP email distribution. Resolves the recipient
        email, checks the SMTP configuration, and logs the intended send action.
        Does NOT make any SMTP calls -- logs only.

        When Audit.Smtp.Enabled is false, logs at DEBUG level.
        When Audit.Smtp.Enabled is true, logs at INFO level (future: actual send).
    .PARAMETER ReportPath
        Full path to the HTML report file to send.
    .PARAMETER RecipientEmail
        Email address of the recipient.
    .PARAMETER RecipientName
        Display name of the recipient (for log messages and future Subject line).
    .PARAMETER Subject
        Optional email subject. Defaults to "{SubjectPrefix} Report for {RecipientName}".
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Action; Recipient; File; Subject}; Error}
    .EXAMPLE
        Send-SPReport -ReportPath 'C:\Audit\leadership\executive-summary.html' `
            -RecipientEmail 'vp@corp.com' -RecipientName 'VP Smith'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RecipientEmail,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RecipientName,

        [Parameter()]
        [string]$Subject,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Load SMTP config
    $smtpConfig = $null
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'Audit' -and
            $config.Audit.PSObject.Properties.Name -contains 'Smtp') {
            $smtpConfig = $config.Audit.Smtp
        }
    }
    catch {
        # Config unavailable -- treat as disabled
    }

    $smtpEnabled = $false
    if ($null -ne $smtpConfig -and
        $smtpConfig.PSObject.Properties.Name -contains 'Enabled') {
        $smtpEnabled = $smtpConfig.Enabled -eq $true
    }

    # Build subject line
    $subjectPrefix = '[SailPoint Audit]'
    if ($null -ne $smtpConfig -and
        $smtpConfig.PSObject.Properties.Name -contains 'SubjectPrefix' -and
        -not [string]::IsNullOrWhiteSpace($smtpConfig.SubjectPrefix)) {
        $subjectPrefix = $smtpConfig.SubjectPrefix
    }
    if ([string]::IsNullOrWhiteSpace($Subject)) {
        $Subject = "$subjectPrefix Report for $RecipientName"
    }

    $fileName = Split-Path -Path $ReportPath -Leaf

    if (-not $smtpEnabled) {
        # SMTP disabled -- log at DEBUG and return
        $logMsg = "SMTP disabled -- would send '$fileName' to $RecipientEmail ($RecipientName)"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $logMsg `
                -Severity DEBUG -Component 'SP.AuditReport' -Action 'Send-SPReport' `
                -CorrelationID $CorrelationID `
                -AdditionalFields @{
                    Recipient = $RecipientEmail
                    File      = $ReportPath
                    Subject   = $Subject
                    SmtpState = 'Disabled'
                }
        }
        Write-Verbose $logMsg

        return @{
            Success = $true
            Data    = @{
                Action    = 'Logged'
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
            }
            Error   = $null
        }
    }

    # SMTP enabled but this is a stub -- log at INFO, no actual send
    $logMsg = "SMTP stub -- would send '$fileName' to $RecipientEmail ($RecipientName) with subject '$Subject'"
    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message $logMsg `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPReport' `
            -CorrelationID $CorrelationID `
            -AdditionalFields @{
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
                SmtpState = 'Stub'
                Server    = if ($null -ne $smtpConfig -and $smtpConfig.PSObject.Properties.Name -contains 'Server') { $smtpConfig.Server } else { '' }
                Port      = if ($null -ne $smtpConfig -and $smtpConfig.PSObject.Properties.Name -contains 'Port') { $smtpConfig.Port } else { 587 }
            }
    }
    Write-Verbose $logMsg

    return @{
        Success = $true
        Data    = @{
            Action    = 'Logged'
            Recipient = $RecipientEmail
            File      = $ReportPath
            Subject   = $Subject
        }
        Error   = $null
    }
}

function Measure-SPCampaignMetrics {
    <#
    .SYNOPSIS
        Calculates comprehensive KPIs for one or more campaigns.
    .DESCRIPTION
        For each supplied campaign, retrieves certifications and access review items,
        then computes per-campaign metrics:

          - Approval rate (%)
          - Revocation rate (%)
          - Completion rate (%)
          - Average reviewer response time (hours)
          - Fastest / slowest reviewer (by avg response time)
          - Reviewer count
          - Reassignment count
          - Items per reviewer (distribution)
          - Deadline compliance (on-time vs overdue)

        Designed to be composable with Measure-SPAuditReviewerMetrics for deeper
        per-reviewer analysis, and consumable by Compare-SPCampaigns (S-08) for
        side-by-side comparison.

        All DateTime comparisons use .ToUniversalTime() to avoid Kind mismatch.
    .PARAMETER Campaigns
        Array of campaign objects as returned by Get-SPAuditCampaigns. Each must
        have at minimum: id, name, status, type. Optional: created, deadline.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @([PSCustomObject] per-campaign metrics)
            Error   = $string
        }

        Each metrics object contains:
            CampaignId, CampaignName, CampaignType, CampaignStatus,
            TotalItems, ApprovedCount, RevokedCount, PendingCount,
            ApprovalRate, RevocationRate, CompletionRate,
            ReviewerCount, ReassignmentCount,
            AvgResponseTimeHours, MinResponseTimeHours, MaxResponseTimeHours,
            MedianResponseTimeHours,
            FastestReviewer, SlowestReviewer,
            ItemsPerReviewer (hashtable: reviewer -> count),
            DeadlineStatus (OnTime/Overdue/NoDeadline/Active),
            CampaignCreated, CampaignDeadline
    .EXAMPLE
        $camps = (Get-SPAuditCampaigns -Status 'COMPLETED' -DaysBack 90).Data
        $result = Measure-SPCampaignMetrics -Campaigns $camps
        $result.Data | Format-Table CampaignName, ApprovalRate, CompletionRate
    .EXAMPLE
        $result = Measure-SPCampaignMetrics -Campaigns @($singleCampaign)
        $result.Data[0].FastestReviewer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Campaigns,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measuring campaign metrics for $($Campaigns.Count) campaign(s)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignMetrics' `
        -CorrelationID $CorrelationID

    try {
        $metricsResults = [System.Collections.Generic.List[object]]::new()

        foreach ($campaign in $Campaigns) {
            if ($null -eq $campaign) { continue }

            $campId     = $campaign.id
            $campName   = $campaign.name
            $campType   = if ($null -ne $campaign.type) { [string]$campaign.type } else { '' }
            $campStatus = if ($null -ne $campaign.status) { [string]$campaign.status } else { '' }

            Write-SPLog -Message "Computing metrics for campaign '$campName' ($campId)" `
                -Severity DEBUG -Component 'SP.AuditReport' -Action 'Measure-SPCampaignMetrics' `
                -CorrelationID $CorrelationID

            # --- Extract campaign dates ---
            $campCreated  = ''
            $campDeadline = ''
            if ($null -ne $campaign.created) {
                $campCreated = [string]$campaign.created
            }
            if ($null -ne $campaign.PSObject.Properties['deadline'] -and $null -ne $campaign.deadline) {
                $campDeadline = [string]$campaign.deadline
            }

            # --- Get certifications ---
            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId): $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditReport' -Action 'Measure-SPCampaignMetrics' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)

            # --- Reviewer-level time metrics via existing function ---
            $reviewerMetrics = Measure-SPAuditReviewerMetrics -Certifications $certs

            # --- Collect all access review items across certs ---
            $totalItems    = 0
            $approvedCount = 0
            $revokedCount  = 0
            $pendingCount  = 0
            $reassignmentCount = 0
            $reviewerItemCounts = @{}

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                # Count reassignments
                if ($null -ne $cert.ReviewerClassification -and
                    $cert.ReviewerClassification -eq 'Reassigned') {
                    $reassignmentCount++
                }

                # Get effective reviewer name for item distribution
                $effReviewerName = 'Unknown'
                if ($null -ne $cert.EffectiveReviewer -and
                    $null -ne $cert.EffectiveReviewer.PSObject.Properties['displayName'] -and
                    -not [string]::IsNullOrWhiteSpace($cert.EffectiveReviewer.displayName)) {
                    $effReviewerName = $cert.EffectiveReviewer.displayName
                }
                elseif ($null -ne $cert.EffectiveReviewer -and
                        $null -ne $cert.EffectiveReviewer.PSObject.Properties['name'] -and
                        -not [string]::IsNullOrWhiteSpace($cert.EffectiveReviewer.name)) {
                    $effReviewerName = $cert.EffectiveReviewer.name
                }

                $certId = $cert.id
                $itemResult = Get-SPAuditCertificationItems -CertificationId $certId `
                    -CorrelationID $CorrelationID

                if (-not $itemResult.Success) {
                    Write-SPLog -Message "Skipping cert '$certId' in campaign '$campName': $($itemResult.Error)" `
                        -Severity WARN -Component 'SP.AuditReport' -Action 'Measure-SPCampaignMetrics' `
                        -CorrelationID $CorrelationID
                    continue
                }

                $items = @($itemResult.Data)
                $certItemCount = 0

                foreach ($item in $items) {
                    if ($null -eq $item) { continue }
                    $totalItems++
                    $certItemCount++

                    $decision = ''
                    if ($null -ne $item.PSObject.Properties['decision'] -and
                        -not [string]::IsNullOrWhiteSpace($item.decision)) {
                        $decision = [string]$item.decision
                    }

                    switch ($decision.ToUpper()) {
                        'APPROVE'  { $approvedCount++ }
                        'APPROVED' { $approvedCount++ }
                        'REVOKE'   { $revokedCount++ }
                        'REVOKED'  { $revokedCount++ }
                        default    { $pendingCount++ }
                    }
                }

                # Accumulate items per reviewer
                if ($reviewerItemCounts.ContainsKey($effReviewerName)) {
                    $reviewerItemCounts[$effReviewerName] += $certItemCount
                }
                else {
                    $reviewerItemCounts[$effReviewerName] = $certItemCount
                }
            }

            # --- Calculate rates (guard against divide-by-zero) ---
            $approvalRate   = if ($totalItems -gt 0) { [Math]::Round(($approvedCount / $totalItems) * 100, 1) } else { 0.0 }
            $revocationRate = if ($totalItems -gt 0) { [Math]::Round(($revokedCount / $totalItems) * 100, 1) } else { 0.0 }
            $decidedCount   = $approvedCount + $revokedCount
            $completionRate = if ($totalItems -gt 0) { [Math]::Round(($decidedCount / $totalItems) * 100, 1) } else { 0.0 }

            # --- Identify fastest / slowest reviewer ---
            $fastestReviewer = ''
            $slowestReviewer = ''
            $reviewerCount   = 0

            if ($null -ne $reviewerMetrics.ReviewerMetrics -and $reviewerMetrics.ReviewerMetrics.Count -gt 0) {
                $reviewerCount = $reviewerMetrics.ReviewerMetrics.Count

                $sorted = @($reviewerMetrics.ReviewerMetrics |
                    Where-Object { $null -ne $_.AvgHours } |
                    Sort-Object -Property AvgHours)

                if ($sorted.Count -gt 0) {
                    $fastestReviewer = $sorted[0].Name
                    $slowestReviewer = $sorted[$sorted.Count - 1].Name
                }
            }

            # --- Deadline compliance ---
            $deadlineStatus = 'NoDeadline'
            if (-not [string]::IsNullOrWhiteSpace($campDeadline)) {
                $dtDeadline = $null
                try {
                    if ($campaign.deadline -is [datetime]) {
                        $dtDeadline = ([datetime]$campaign.deadline).ToUniversalTime()
                    }
                    else {
                        $parsedDl = [datetime]::MinValue
                        if ([datetime]::TryParse($campDeadline, [ref]$parsedDl)) {
                            $dtDeadline = $parsedDl.ToUniversalTime()
                        }
                    }
                }
                catch { }

                if ($null -ne $dtDeadline) {
                    $nowUtc = (Get-Date).ToUniversalTime()
                    if ($campStatus -eq 'COMPLETED') {
                        # Check if completed before deadline
                        $completedDate = $null
                        if ($null -ne $campaign.PSObject.Properties['completed'] -and
                            $null -ne $campaign.completed) {
                            try {
                                if ($campaign.completed -is [datetime]) {
                                    $completedDate = ([datetime]$campaign.completed).ToUniversalTime()
                                }
                                else {
                                    $parsedComp = [datetime]::MinValue
                                    if ([datetime]::TryParse([string]$campaign.completed, [ref]$parsedComp)) {
                                        $completedDate = $parsedComp.ToUniversalTime()
                                    }
                                }
                            }
                            catch { }
                        }

                        if ($null -ne $completedDate -and $completedDate -le $dtDeadline) {
                            $deadlineStatus = 'OnTime'
                        }
                        elseif ($null -ne $completedDate) {
                            $deadlineStatus = 'Overdue'
                        }
                        else {
                            # No completed date but COMPLETED status -- assume on-time
                            $deadlineStatus = 'OnTime'
                        }
                    }
                    elseif ($campStatus -eq 'ACTIVE' -or $campStatus -eq 'ACTIVATING') {
                        if ($dtDeadline -lt $nowUtc) {
                            $deadlineStatus = 'Overdue'
                        }
                        else {
                            $deadlineStatus = 'Active'
                        }
                    }
                    else {
                        $deadlineStatus = 'Active'
                    }
                }
            }

            # --- Build metrics object ---
            $metricsObj = [PSCustomObject]@{
                CampaignId              = $campId
                CampaignName            = $campName
                CampaignType            = $campType
                CampaignStatus          = $campStatus
                CampaignCreated         = $campCreated
                CampaignDeadline        = $campDeadline
                TotalItems              = $totalItems
                ApprovedCount           = $approvedCount
                RevokedCount            = $revokedCount
                PendingCount            = $pendingCount
                ApprovalRate            = $approvalRate
                RevocationRate          = $revocationRate
                CompletionRate          = $completionRate
                ReviewerCount           = $reviewerCount
                ReassignmentCount       = $reassignmentCount
                AvgResponseTimeHours    = $reviewerMetrics.CampaignAvgHours
                MinResponseTimeHours    = $reviewerMetrics.CampaignMinHours
                MaxResponseTimeHours    = $reviewerMetrics.CampaignMaxHours
                MedianResponseTimeHours = $reviewerMetrics.CampaignMedianHours
                FastestReviewer         = $fastestReviewer
                SlowestReviewer         = $slowestReviewer
                ItemsPerReviewer        = $reviewerItemCounts
                DeadlineStatus          = $deadlineStatus
            }

            $metricsResults.Add($metricsObj)

            Write-SPLog -Message "Campaign '$campName': $totalItems items, $approvalRate% approved, $revocationRate% revoked, $completionRate% complete, $reviewerCount reviewers, deadline=$deadlineStatus" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignMetrics' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Campaign metrics complete: $($metricsResults.Count) campaign(s) measured" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignMetrics' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = $metricsResults.ToArray()
            Error   = $null
        }
    }
    catch {
        $errMsg = "Measure-SPCampaignMetrics failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditReport' `
            -Action 'Measure-SPCampaignMetrics' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Compare-SPCampaigns {
    <#
    .SYNOPSIS
        Side-by-side comparison of metrics for two or more campaigns.
    .DESCRIPTION
        Accepts campaign IDs (resolved via API) or pre-fetched campaign objects,
        runs Measure-SPCampaignMetrics on each, then returns a comparison table
        with per-metric delta highlighting.

        Output options:
          - PSCustomObject comparison table (default)
          - HTML comparison report via Export-SPCampaignComparisonHtml
          - CSV export via Export-Csv pipeline

        All DateTime comparisons use .ToUniversalTime() to avoid Kind mismatch.
    .PARAMETER CampaignIds
        Two or more campaign IDs to compare. Campaigns are fetched from the API.
    .PARAMETER Campaigns
        Pre-fetched campaign objects (as from Get-SPAuditCampaigns). Use instead
        of CampaignIds to avoid redundant API calls.
    .PARAMETER OutputMode
        Console (default), HTML, or CSV.
    .PARAMETER OutputPath
        Directory for HTML/CSV output. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Success; Data; Error }
        Data contains: Metrics (array of per-campaign metric objects),
                       ComparisonTable (array of row objects for display),
                       HtmlPath (if OutputMode=HTML)
    .EXAMPLE
        $result = Compare-SPCampaigns -CampaignIds 'camp-001','camp-002'
        $result.Data.ComparisonTable | Format-Table
    .EXAMPLE
        Compare-SPCampaigns -CampaignIds 'camp-001','camp-002' -OutputMode HTML -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateCount(2, 20)]
        [string[]]$CampaignIds,

        [Parameter(Mandatory, ParameterSetName = 'ByObject')]
        [ValidateCount(2, 20)]
        [object[]]$Campaigns,

        [Parameter()]
        [ValidateSet('Console', 'HTML', 'CSV')]
        [string]$OutputMode = 'Console',

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Compare-SPCampaigns: starting comparison" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
        -CorrelationID $CorrelationID

    try {
        # --- Resolve campaigns ---
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            # Fetch each campaign by searching all campaigns and filtering
            $allCampsResult = Get-SPAuditCampaigns -Status @('STAGED','ACTIVATING','ACTIVE','COMPLETING','COMPLETED') `
                -DaysBack 3650 -CorrelationID $CorrelationID
            if (-not $allCampsResult.Success) {
                return @{ Success = $false; Data = $null; Error = "Failed to fetch campaigns: $($allCampsResult.Error)" }
            }

            $campObjects = [System.Collections.Generic.List[object]]::new()
            foreach ($cid in $CampaignIds) {
                $match = $allCampsResult.Data | Where-Object { $_.id -eq $cid }
                if ($null -eq $match) {
                    return @{ Success = $false; Data = $null; Error = "Campaign not found: $cid" }
                }
                $campObjects.Add($match)
            }
            $Campaigns = $campObjects.ToArray()
        }

        # --- Compute metrics via Measure-SPCampaignMetrics ---
        $metricsResult = Measure-SPCampaignMetrics -Campaigns $Campaigns -CorrelationID $CorrelationID
        if (-not $metricsResult.Success) {
            return @{ Success = $false; Data = $null; Error = "Metrics calculation failed: $($metricsResult.Error)" }
        }

        $metrics = @($metricsResult.Data)
        if ($metrics.Count -lt 2) {
            return @{ Success = $false; Data = $null; Error = "Need metrics for at least 2 campaigns, got $($metrics.Count)" }
        }

        # --- Build comparison table (metric-per-row, campaign-per-column) ---
        $metricDefs = @(
            @{ Label = 'Campaign Name';       Prop = 'CampaignName';            Format = 'string' }
            @{ Label = 'Type';                 Prop = 'CampaignType';            Format = 'string' }
            @{ Label = 'Status';               Prop = 'CampaignStatus';          Format = 'string' }
            @{ Label = 'Created';              Prop = 'CampaignCreated';         Format = 'date' }
            @{ Label = 'Deadline';             Prop = 'CampaignDeadline';        Format = 'date' }
            @{ Label = 'Total Items';          Prop = 'TotalItems';              Format = 'int' }
            @{ Label = 'Approved';             Prop = 'ApprovedCount';           Format = 'int' }
            @{ Label = 'Revoked';              Prop = 'RevokedCount';            Format = 'int' }
            @{ Label = 'Pending';              Prop = 'PendingCount';            Format = 'int' }
            @{ Label = 'Approval Rate (%)';    Prop = 'ApprovalRate';            Format = 'pct' }
            @{ Label = 'Revocation Rate (%)';  Prop = 'RevocationRate';          Format = 'pct' }
            @{ Label = 'Completion Rate (%)';  Prop = 'CompletionRate';          Format = 'pct' }
            @{ Label = 'Reviewer Count';       Prop = 'ReviewerCount';           Format = 'int' }
            @{ Label = 'Reassignment Count';   Prop = 'ReassignmentCount';       Format = 'int' }
            @{ Label = 'Avg Response (hours)'; Prop = 'AvgResponseTimeHours';    Format = 'hours' }
            @{ Label = 'Fastest Reviewer';     Prop = 'FastestReviewer';         Format = 'string' }
            @{ Label = 'Slowest Reviewer';     Prop = 'SlowestReviewer';         Format = 'string' }
            @{ Label = 'Deadline Status';      Prop = 'DeadlineStatus';          Format = 'string' }
        )

        $comparisonRows = [System.Collections.Generic.List[object]]::new()
        foreach ($mdef in $metricDefs) {
            $row = [ordered]@{ Metric = $mdef.Label }
            for ($i = 0; $i -lt $metrics.Count; $i++) {
                $val = $metrics[$i].PSObject.Properties[$mdef.Prop].Value
                $colName = "Campaign_$($i + 1)"
                $row[$colName] = $val
            }

            # Delta column (first two campaigns only, numeric types)
            if ($metrics.Count -ge 2 -and $mdef.Format -in @('int', 'pct', 'hours')) {
                $v1 = $metrics[0].PSObject.Properties[$mdef.Prop].Value
                $v2 = $metrics[1].PSObject.Properties[$mdef.Prop].Value
                if ($null -ne $v1 -and $null -ne $v2) {
                    $delta = [Math]::Round(([double]$v2 - [double]$v1), 1)
                    $sign = if ($delta -gt 0) { '+' } else { '' }
                    $row['Delta_1v2'] = "${sign}${delta}"
                }
                else {
                    $row['Delta_1v2'] = 'N/A'
                }
            }

            $comparisonRows.Add([PSCustomObject]$row)
        }

        $resultData = @{
            Metrics         = $metrics
            ComparisonTable = $comparisonRows.ToArray()
            HtmlPath        = $null
            CsvPath         = $null
        }

        # --- Output mode handling ---
        if ($OutputMode -eq 'HTML') {
            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = (Get-Location).Path
            }
            $htmlPath = Export-SPCampaignComparisonHtml -Metrics $metrics `
                -MetricDefs $metricDefs -OutputPath $OutputPath -CorrelationID $CorrelationID
            $resultData.HtmlPath = $htmlPath
            Write-SPLog -Message "HTML comparison report written: $htmlPath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
                -CorrelationID $CorrelationID
        }
        elseif ($OutputMode -eq 'CSV') {
            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = (Get-Location).Path
            }
            if (-not (Test-Path -Path $OutputPath -PathType Container)) {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            }
            $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $csvPath = Join-Path $OutputPath "CampaignComparison-${timestamp}.csv"
            $comparisonRows.ToArray() | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            $resultData.CsvPath = $csvPath
            Write-SPLog -Message "CSV comparison written: $csvPath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Compare-SPCampaigns: compared $($metrics.Count) campaigns" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = $resultData
            Error   = $null
        }
    }
    catch {
        $errMsg = "Compare-SPCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditReport' `
            -Action 'Compare-SPCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

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

#endregion

#region Audit Trail Consolidator (P11-02)

function Get-SPAuditTrail {
    <#
    .SYNOPSIS
        Reads all JSONL audit files and produces a unified, chronologically sorted timeline.
    .DESCRIPTION
        Consolidates events from three JSONL sources:
          - {Audit.OutputPath}/audit-*.jsonl   (campaign audit events)
          - {DeltaCert.OutputPath}/deltacert-audit.jsonl  (delta cert run events)
          - {DeltaCert.OutputPath}/deltacert-escalation.jsonl  (escalation events)

        Each event is normalised to a common schema: Timestamp, EventType, Action,
        CorrelationID, SourceIds, Summary, Details, FilePath.

        Supports filtering by date range, correlation ID, event type, and source ID.
        Returns newest-first, capped at MaxEvents.
    .PARAMETER After
        Only include events after this datetime.
    .PARAMETER Before
        Only include events before this datetime.
    .PARAMETER CorrelationID
        Filter to events matching this correlation ID.
    .PARAMETER EventType
        Filter to specific event types: 'CampaignAudit', 'DeltaCertRun', 'Escalation'.
    .PARAMETER SourceId
        Filter to events involving this source ID.
    .PARAMETER AuditOutputPath
        Directory containing campaign audit JSONL files. Resolved from config if omitted.
    .PARAMETER DeltaCertOutputPath
        Directory containing delta cert JSONL files. Resolved from config if omitted.
    .PARAMETER MaxEvents
        Maximum number of events to return. Default: 500.
    .OUTPUTS
        [PSCustomObject[]] Array of normalised audit trail events.
    .EXAMPLE
        $trail = Get-SPAuditTrail -After (Get-Date).AddDays(-7) -EventType 'Escalation'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()][DateTime]$After,
        [Parameter()][DateTime]$Before,
        [Parameter()][string]$CorrelationID,
        [Parameter()][string[]]$EventType,
        [Parameter()][string]$SourceId,
        [Parameter()][string]$AuditOutputPath,
        [Parameter()][string]$DeltaCertOutputPath,
        [Parameter()][int]$MaxEvents = 500
    )

    $logCorrelation = if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        [guid]::NewGuid().ToString()
    } else { $CorrelationID }

    Write-SPLog -Message "Get-SPAuditTrail: starting consolidation" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
        -CorrelationID $logCorrelation

    # Resolve paths from config if not provided
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -or
        [string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) {
        try {
            $config = Get-SPConfig
            if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'Audit' -and
                $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
                $AuditOutputPath = $config.Audit.OutputPath
            }
            if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'DeltaCert' -and
                $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
                $DeltaCertOutputPath = $config.DeltaCert.OutputPath
            }
        }
        catch {
            Write-SPLog -Message "Could not load config for path resolution: $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
                -CorrelationID $logCorrelation
        }
    }
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath))     { $AuditOutputPath     = '.\Audit' }
    if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) { $DeltaCertOutputPath = '.\DeltaCert' }

    $allEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Collect JSONL files and their event type mappings
    $fileMappings = [System.Collections.Generic.List[hashtable]]::new()

    # Campaign audit files: audit-*.jsonl
    if (Test-Path -Path $AuditOutputPath -PathType Container) {
        $auditFiles = Get-ChildItem -Path $AuditOutputPath -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue
        foreach ($f in $auditFiles) {
            $fileMappings.Add(@{ Path = $f.FullName; DefaultEventType = 'CampaignAudit' })
        }
    }

    # Delta cert audit file
    if (Test-Path -Path $DeltaCertOutputPath -PathType Container) {
        $dcAuditPath = Join-Path $DeltaCertOutputPath 'deltacert-audit.jsonl'
        if (Test-Path -Path $dcAuditPath -PathType Leaf) {
            $fileMappings.Add(@{ Path = $dcAuditPath; DefaultEventType = 'DeltaCertRun' })
        }

        $dcEscPath = Join-Path $DeltaCertOutputPath 'deltacert-escalation.jsonl'
        if (Test-Path -Path $dcEscPath -PathType Leaf) {
            $fileMappings.Add(@{ Path = $dcEscPath; DefaultEventType = 'Escalation' })
        }
    }

    # Read and normalise each file
    foreach ($mapping in $fileMappings) {
        $filePath      = $mapping.Path
        $defaultEvType = $mapping.DefaultEventType

        try {
            $lines = [System.IO.File]::ReadAllLines($filePath)
        }
        catch {
            Write-SPLog -Message "Failed to read JSONL file '$filePath': $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
                -CorrelationID $logCorrelation
            continue
        }

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $parsed = $line | ConvertFrom-Json
            }
            catch {
                Write-SPLog -Message "Malformed JSONL line in '$filePath': $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
                    -CorrelationID $logCorrelation
                continue
            }

            # Extract timestamp
            $tsString = $null
            if ($null -ne $parsed.Timestamp) { $tsString = [string]$parsed.Timestamp }
            $ts = $null
            if (-not [string]::IsNullOrWhiteSpace($tsString)) {
                try { $ts = [datetime]::Parse($tsString).ToUniversalTime() } catch { $ts = $null }
            }

            # Extract correlation ID from event
            $eventCorrId = ''
            if ($null -ne $parsed.CorrelationID) { $eventCorrId = [string]$parsed.CorrelationID }

            # Extract action
            $action = ''
            if ($null -ne $parsed.Action) { $action = [string]$parsed.Action }

            # Extract source IDs
            $sourceIds = @()
            if ($null -ne $parsed.SourceIds) {
                $sourceIds = @($parsed.SourceIds)
            }
            elseif ($null -ne $parsed.Data -and $null -ne $parsed.Data.SourceIds) {
                $sourceIds = @($parsed.Data.SourceIds)
            }

            # Build summary based on event type
            $summary = ''
            switch ($defaultEvType) {
                'CampaignAudit' {
                    $summary = $action
                }
                'DeltaCertRun' {
                    $campCount = 0
                    $idCount   = 0
                    if ($null -ne $parsed.CampaignsCreated) { $campCount = [int]$parsed.CampaignsCreated }
                    if ($null -ne $parsed.IdentitiesProcessed) { $idCount = [int]$parsed.IdentitiesProcessed }
                    $summary = "Created $campCount campaigns for $idCount identities"
                }
                'Escalation' {
                    $escCount = 0
                    if ($null -ne $parsed.Escalated) { $escCount = [int]$parsed.Escalated }
                    $summary = "Escalated $escCount certifications"
                }
            }

            $normalized = [PSCustomObject]@{
                Timestamp     = $ts
                EventType     = $defaultEvType
                Action        = $action
                CorrelationID = $eventCorrId
                SourceIds     = $sourceIds
                Summary       = $summary
                Details       = $parsed
                FilePath      = $filePath
            }

            # Apply filters
            if ($PSBoundParameters.ContainsKey('After') -and $null -ne $ts -and $ts -lt $After.ToUniversalTime()) { continue }
            if ($PSBoundParameters.ContainsKey('Before') -and $null -ne $ts -and $ts -gt $Before.ToUniversalTime()) { continue }
            if (-not [string]::IsNullOrWhiteSpace($CorrelationID) -and $eventCorrId -ne $CorrelationID) { continue }
            if ($null -ne $EventType -and $EventType.Count -gt 0 -and $defaultEvType -notin $EventType) { continue }
            if (-not [string]::IsNullOrWhiteSpace($SourceId) -and $SourceId -notin $sourceIds) { continue }

            $allEvents.Add($normalized)
        }
    }

    # Sort by Timestamp descending (newest first), nulls last
    $sorted = $allEvents | Sort-Object -Property {
        if ($null -ne $_.Timestamp) { $_.Timestamp } else { [datetime]::MinValue }
    } -Descending

    # Cap at MaxEvents
    $result = @($sorted | Select-Object -First $MaxEvents)

    Write-SPLog -Message "Get-SPAuditTrail: returning $($result.Count) events from $($fileMappings.Count) files" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
        -CorrelationID $logCorrelation

    return $result
}

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

#endregion

#region CSV Export (P11-03)

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

#endregion

#region ===== P11-06: Campaign Trend Analytics =====

function Measure-SPCampaignTrends {
    <#
    .SYNOPSIS
        Compares metrics across multiple campaign cycles to identify governance trends.
    .DESCRIPTION
        Groups campaign metrics by time period (Week, Month, Quarter, Year), aggregates
        KPIs per period, calculates deltas between consecutive periods, and classifies
        multi-period trends as Improving, Degrading, or Stable.

        Answers: "Are approval rates going up? Are reviewers getting faster?"

        Input is the Data array from Measure-SPCampaignMetrics (array of PSCustomObject
        with CampaignCreated, ApprovalRate, RevocationRate, CompletionRate,
        AvgResponseTimeHours, ReviewerCount, TotalItems, etc.).
    .PARAMETER CampaignMetrics
        Array of campaign metric objects from Measure-SPCampaignMetrics.Data.
    .PARAMETER GroupBy
        Time period for grouping: Week, Month, Quarter, Year. Default: Month.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Periods = @(...)   # per-period aggregates with deltas
            Trends  = @{...}   # multi-period trend classification
            Summary = @{...}   # overall summary
        }
    .EXAMPLE
        $camps = (Get-SPAuditCampaigns -Status 'COMPLETED' -DaysBack 365).Data
        $metrics = (Measure-SPCampaignMetrics -Campaigns $camps).Data
        $trends = Measure-SPCampaignTrends -CampaignMetrics $metrics -GroupBy 'Quarter'
        $trends.Trends
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CampaignMetrics,

        [Parameter()]
        [ValidateSet('Week','Month','Quarter','Year')]
        [string]$GroupBy = 'Month',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measuring campaign trends for $($CampaignMetrics.Count) metric(s), grouped by $GroupBy" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignTrends' `
        -CorrelationID $CorrelationID

    # --- Helper: parse a date string to DateTime (UTC) ---
    function _ParseDateUtc([string]$dateStr) {
        if ([string]::IsNullOrWhiteSpace($dateStr)) { return $null }
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($dateStr, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) {
            return $dt.ToUniversalTime()
        }
        return $null
    }

    # --- Helper: assign a period label based on a DateTime ---
    function _PeriodLabel([datetime]$dt, [string]$group) {
        switch ($group) {
            'Week' {
                # ISO week: year-Www
                $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
                $weekNum = $cal.GetWeekOfYear($dt,
                    [System.Globalization.CalendarWeekRule]::FirstFourDayWeek,
                    [System.DayOfWeek]::Monday)
                return '{0}-W{1:D2}' -f $dt.Year, $weekNum
            }
            'Month'   { return '{0}-{1:D2}' -f $dt.Year, $dt.Month }
            'Quarter' {
                $q = [Math]::Ceiling($dt.Month / 3)
                return '{0}-Q{1}' -f $dt.Year, $q
            }
            'Year'    { return [string]$dt.Year }
        }
    }

    # --- Helper: sort key for period labels ---
    function _PeriodSortKey([string]$label) {
        # All label formats sort lexicographically except Quarter vs Month;
        # they all start with YYYY so standard string sort works.
        return $label
    }

    # --- Parse dates and group by period ---
    $periodBuckets = @{}
    $earliestDate  = $null
    $latestDate    = $null

    foreach ($m in $CampaignMetrics) {
        if ($null -eq $m) { continue }

        $created = $null
        if ($null -ne $m.PSObject.Properties['CampaignCreated'] -and
            -not [string]::IsNullOrWhiteSpace($m.CampaignCreated)) {
            $created = _ParseDateUtc $m.CampaignCreated
        }
        if ($null -eq $created) {
            Write-SPLog -Message "Skipping campaign '$($m.CampaignName)' -- no CampaignCreated date" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Measure-SPCampaignTrends' `
                -CorrelationID $CorrelationID
            continue
        }

        if ($null -eq $earliestDate -or $created -lt $earliestDate) { $earliestDate = $created }
        if ($null -eq $latestDate   -or $created -gt $latestDate)   { $latestDate   = $created }

        $label = _PeriodLabel $created $GroupBy
        if (-not $periodBuckets.ContainsKey($label)) {
            $periodBuckets[$label] = [System.Collections.Generic.List[object]]::new()
        }
        $periodBuckets[$label].Add($m)
    }

    # --- Sort period labels chronologically ---
    $sortedLabels = @($periodBuckets.Keys | Sort-Object)

    # --- Aggregate metrics per period ---
    $periods = [System.Collections.Generic.List[object]]::new()

    foreach ($label in $sortedLabels) {
        $bucket = $periodBuckets[$label]

        $totalItems    = 0
        $totalApproved = 0
        $totalRevoked  = 0
        $totalDecided  = 0
        $totalTotal    = 0
        $responseHrSum = 0.0
        $responseHrCt  = 0
        $reviewerTotal = 0

        foreach ($m in $bucket) {
            $ti = if ($null -ne $m.TotalItems) { [int]$m.TotalItems } else { 0 }
            $totalTotal += $ti

            $app = if ($null -ne $m.ApprovedCount) { [int]$m.ApprovedCount } else { 0 }
            $rev = if ($null -ne $m.RevokedCount)  { [int]$m.RevokedCount }  else { 0 }
            $totalApproved += $app
            $totalRevoked  += $rev
            $totalDecided  += ($app + $rev)

            if ($null -ne $m.AvgResponseTimeHours -and $m.AvgResponseTimeHours -gt 0) {
                $responseHrSum += [double]$m.AvgResponseTimeHours
                $responseHrCt++
            }

            $rc = if ($null -ne $m.ReviewerCount) { [int]$m.ReviewerCount } else { 0 }
            $reviewerTotal += $rc
        }

        $approvalRate   = if ($totalTotal -gt 0) { [Math]::Round(($totalApproved / $totalTotal) * 100, 1) } else { 0.0 }
        $revocationRate = if ($totalTotal -gt 0) { [Math]::Round(($totalRevoked  / $totalTotal) * 100, 1) } else { 0.0 }
        $completionRate = if ($totalTotal -gt 0) { [Math]::Round(($totalDecided  / $totalTotal) * 100, 1) } else { 0.0 }
        $avgRespHrs     = if ($responseHrCt -gt 0) { [Math]::Round($responseHrSum / $responseHrCt, 1) } else { 0.0 }

        $periods.Add(@{
            Label          = $label
            CampaignCount  = $bucket.Count
            TotalItems     = $totalTotal
            ApprovalRate   = $approvalRate
            RevocationRate = $revocationRate
            CompletionRate = $completionRate
            AvgResponseHrs = $avgRespHrs
            ReviewerCount  = $reviewerTotal
            Deltas         = @{}
        })
    }

    # --- Calculate deltas between consecutive periods ---
    for ($i = 1; $i -lt $periods.Count; $i++) {
        $prev = $periods[$i - 1]
        $curr = $periods[$i]
        $curr['Deltas'] = @{
            ApprovalRate   = [Math]::Round($curr['ApprovalRate']   - $prev['ApprovalRate'],   1)
            RevocationRate = [Math]::Round($curr['RevocationRate'] - $prev['RevocationRate'], 1)
            CompletionRate = [Math]::Round($curr['CompletionRate'] - $prev['CompletionRate'], 1)
            AvgResponseHrs = [Math]::Round($curr['AvgResponseHrs'] - $prev['AvgResponseHrs'], 1)
        }
    }

    # --- Classify trends (need 3+ periods) ---
    $trendMetrics = @('ApprovalRate', 'RevocationRate', 'CompletionRate', 'AvgResponseHrs')
    $trends = @{}

    if ($periods.Count -lt 3) {
        foreach ($metric in $trendMetrics) {
            $trends[$metric] = 'Insufficient Data'
        }
    }
    else {
        foreach ($metric in $trendMetrics) {
            # Collect deltas from period index 1 onward
            $deltas = @()
            for ($i = 1; $i -lt $periods.Count; $i++) {
                $d = $periods[$i]['Deltas'][$metric]
                if ($null -ne $d) { $deltas += $d }
            }

            # For AvgResponseHrs, "improving" means decreasing (faster)
            $improvingCount = 0
            $degradingCount = 0
            $stableCount    = 0
            $threshold      = 2.0

            foreach ($d in $deltas) {
                if ($metric -eq 'AvgResponseHrs') {
                    # Negative delta = faster = improving
                    if ($d -lt (-$threshold))     { $improvingCount++ }
                    elseif ($d -gt $threshold)    { $degradingCount++ }
                    else                          { $stableCount++ }
                }
                elseif ($metric -eq 'RevocationRate') {
                    # For revocation rate, direction is context-dependent;
                    # treat decreasing as improving (fewer access removals needed)
                    if ($d -lt (-$threshold))     { $improvingCount++ }
                    elseif ($d -gt $threshold)    { $degradingCount++ }
                    else                          { $stableCount++ }
                }
                else {
                    # ApprovalRate, CompletionRate: higher = better
                    if ($d -gt $threshold)        { $improvingCount++ }
                    elseif ($d -lt (-$threshold)) { $degradingCount++ }
                    else                          { $stableCount++ }
                }
            }

            # Majority-based classification
            if ($improvingCount -gt $degradingCount -and $improvingCount -gt $stableCount) {
                $trends[$metric] = 'Improving'
            }
            elseif ($degradingCount -gt $improvingCount -and $degradingCount -gt $stableCount) {
                $trends[$metric] = 'Degrading'
            }
            else {
                $trends[$metric] = 'Stable'
            }
        }
    }

    # --- Overall direction: majority of trends ---
    $improvingTrends = @($trends.Values | Where-Object { $_ -eq 'Improving' }).Count
    $degradingTrends = @($trends.Values | Where-Object { $_ -eq 'Degrading' }).Count
    if ($periods.Count -lt 3) {
        $overallDirection = 'Insufficient Data'
    }
    elseif ($improvingTrends -gt $degradingTrends) {
        $overallDirection = 'Improving'
    }
    elseif ($degradingTrends -gt $improvingTrends) {
        $overallDirection = 'Degrading'
    }
    else {
        $overallDirection = 'Stable'
    }

    $earliestStr = if ($null -ne $earliestDate) { $earliestDate.ToString('yyyy-MM-dd') } else { '' }
    $latestStr   = if ($null -ne $latestDate)   { $latestDate.ToString('yyyy-MM-dd') }   else { '' }

    $result = @{
        Periods = $periods.ToArray()
        Trends  = $trends
        Summary = @{
            EarliestCampaign = $earliestStr
            LatestCampaign   = $latestStr
            TotalCampaigns   = ($CampaignMetrics | Where-Object { $null -ne $_ }).Count
            OverallDirection = $overallDirection
        }
    }

    Write-SPLog -Message "Campaign trends: $($periods.Count) period(s), overall=$overallDirection" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignTrends' `
        -CorrelationID $CorrelationID

    return $result
}

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

#endregion

#region Cross-Campaign Reviewer Analysis (P11-08)

function Measure-SPReviewerReputation {
    <#
    .SYNOPSIS
        Aggregates reviewer performance across multiple campaigns to build reputation profiles.
    .DESCRIPTION
        Takes an array of campaign audit data (same structure produced by Invoke-SPCampaignAudit)
        and builds a per-reviewer reputation profile spanning all campaigns. Identifies systemic
        issues (consistently slow reviewers, chronic rubber-stampers) vs one-time anomalies.

        Each reviewer receives a ReputationScore (0-100) based on weighted factors:
          - Response time (30%): Faster = higher score
          - Completion rate (25%): Higher = better
          - Decision diversity (20%): Mix of approve/revoke = higher (100% approve = lower)
          - Consistency (15%): Low variance across campaigns = higher
          - Escalation history (10%): Fewer escalations = higher

        Reviewers with fewer campaigns than MinCampaigns are excluded (insufficient data).
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables, each containing: CampaignName, Created, Decisions
        (from Group-SPAuditDecisions), ReviewerMetrics (from Measure-SPAuditReviewerMetrics),
        RubberStampRisk (from Measure-SPAuditRubberStampRisk).
    .PARAMETER MinCampaigns
        Minimum number of campaigns a reviewer must have participated in to be included.
        Default: 2.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Reviewers = @( ... )   # sorted by ReputationScore ascending (worst first)
            Summary   = @{ TotalReviewers; Excellent; Good; NeedsAttention; AtRisk }
        }
    .EXAMPLE
        $rep = Measure-SPReviewerReputation -CampaignAudits $allCampaignAudits -MinCampaigns 2
        $rep.Reviewers | Where-Object { $_.ReputationTier -eq 'At Risk' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [int]$MinCampaigns = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measuring reviewer reputation across $($CampaignAudits.Count) campaign(s), MinCampaigns=$MinCampaigns" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPReviewerReputation' `
        -CorrelationID $CorrelationID

    # --- Accumulator per reviewer keyed by name ---
    # Each entry tracks cross-campaign totals and per-campaign snapshots
    $reviewerMap = @{}

    foreach ($audit in $CampaignAudits) {
        $campaignName = if ($audit.ContainsKey('CampaignName')) { $audit['CampaignName'] } else { '' }

        # Parse campaign creation date for chronological ordering
        $campaignCreated = $null
        $createdStr = if ($audit.ContainsKey('Created')) { $audit['Created'] } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($createdStr)) {
            try {
                $campaignCreated = [datetime]::Parse($createdStr,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
            }
            catch { $campaignCreated = $null }
        }

        # --- Extract reviewer metrics from this campaign ---
        $metricsData = $null
        if ($audit.ContainsKey('ReviewerMetrics') -and $null -ne $audit['ReviewerMetrics']) {
            $rm = $audit['ReviewerMetrics']
            if ($rm -is [hashtable] -and $rm.ContainsKey('ReviewerMetrics')) {
                $metricsData = @($rm['ReviewerMetrics'])
            }
        }

        # --- Extract rubber-stamp risk from this campaign ---
        $riskData = $null
        if ($audit.ContainsKey('RubberStampRisk') -and $null -ne $audit['RubberStampRisk']) {
            $rs = $audit['RubberStampRisk']
            if ($rs -is [hashtable] -and $rs.ContainsKey('ReviewerRisks')) {
                $riskData = @($rs['ReviewerRisks'])
            }
        }

        # --- Extract per-reviewer decision counts from Decisions ---
        $decisionsByReviewer = @{}
        if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $decisions = $audit['Decisions']
            foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                if (-not $decisions.ContainsKey($category) -or $null -eq $decisions[$category]) { continue }
                foreach ($item in @($decisions[$category])) {
                    $rName = ''
                    if ($null -ne $item.ReviewerName -and -not [string]::IsNullOrWhiteSpace($item.ReviewerName)) {
                        $rName = $item.ReviewerName
                    }
                    if ([string]::IsNullOrWhiteSpace($rName)) { continue }

                    if (-not $decisionsByReviewer.ContainsKey($rName)) {
                        $decisionsByReviewer[$rName] = @{ Approved = 0; Revoked = 0; Pending = 0 }
                    }
                    $decisionsByReviewer[$rName][$category]++
                }
            }
        }

        # --- Build per-reviewer lookup for metrics and risk ---
        $metricsLookup = @{}
        if ($null -ne $metricsData) {
            foreach ($m in $metricsData) {
                $mName = if ($null -ne $m.Name) { $m.Name } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($mName)) {
                    $metricsLookup[$mName] = $m
                }
            }
        }

        $riskLookup = @{}
        if ($null -ne $riskData) {
            foreach ($r in $riskData) {
                $rName = if ($null -ne $r.ReviewerName) { $r.ReviewerName } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($rName)) {
                    $riskLookup[$rName] = $r
                }
            }
        }

        # --- Collect all reviewer names seen in this campaign ---
        $allReviewerNames = @{}
        foreach ($k in $decisionsByReviewer.Keys) { $allReviewerNames[$k] = $true }
        foreach ($k in $metricsLookup.Keys)       { $allReviewerNames[$k] = $true }

        # --- Accumulate per reviewer ---
        foreach ($reviewerName in $allReviewerNames.Keys) {
            if (-not $reviewerMap.ContainsKey($reviewerName)) {
                $reviewerMap[$reviewerName] = @{
                    Name               = $reviewerName
                    IdentityId         = ''
                    CampaignsParticipated = 0
                    TotalApproved      = 0
                    TotalRevoked       = 0
                    TotalPending       = 0
                    AvgHoursPerCampaign = [System.Collections.Generic.List[double]]::new()
                    RubberStampCount   = 0
                    EscalationCount    = 0
                    CampaignSnapshots  = [System.Collections.Generic.List[object]]::new()
                    CompletionRates    = [System.Collections.Generic.List[double]]::new()
                }
            }

            $entry = $reviewerMap[$reviewerName]
            $entry['CampaignsParticipated']++

            # Decisions
            if ($decisionsByReviewer.ContainsKey($reviewerName)) {
                $d = $decisionsByReviewer[$reviewerName]
                $entry['TotalApproved'] += $d['Approved']
                $entry['TotalRevoked']  += $d['Revoked']
                $entry['TotalPending']  += $d['Pending']

                $campTotal = $d['Approved'] + $d['Revoked'] + $d['Pending']
                $campDecided = $d['Approved'] + $d['Revoked']
                if ($campTotal -gt 0) {
                    $entry['CompletionRates'].Add([Math]::Round(($campDecided / $campTotal) * 100, 1))
                }
            }

            # Response time
            if ($metricsLookup.ContainsKey($reviewerName)) {
                $met = $metricsLookup[$reviewerName]
                if ($null -ne $met.AvgHours) {
                    $entry['AvgHoursPerCampaign'].Add([double]$met.AvgHours)
                }
            }

            # Rubber-stamp risk
            if ($riskLookup.ContainsKey($reviewerName)) {
                $rsk = $riskLookup[$reviewerName]
                $sev = if ($null -ne $rsk.Severity) { $rsk.Severity } else { 'None' }
                if ($sev -eq 'Medium' -or $sev -eq 'High') {
                    $entry['RubberStampCount']++
                }
            }

            # Campaign snapshot for trend analysis
            $campApprovalRate = 0
            if ($decisionsByReviewer.ContainsKey($reviewerName)) {
                $d = $decisionsByReviewer[$reviewerName]
                $decided = $d['Approved'] + $d['Revoked']
                if ($decided -gt 0) {
                    $campApprovalRate = [Math]::Round(($d['Approved'] / $decided) * 100, 1)
                }
            }

            $campAvgHours = $null
            if ($metricsLookup.ContainsKey($reviewerName) -and $null -ne $metricsLookup[$reviewerName].AvgHours) {
                $campAvgHours = [double]$metricsLookup[$reviewerName].AvgHours
            }

            $entry['CampaignSnapshots'].Add(@{
                CampaignName  = $campaignName
                Created       = $campaignCreated
                ApprovalRate  = $campApprovalRate
                AvgHours      = $campAvgHours
            })
        }
    }

    # --- Score and filter reviewers ---
    $reviewerResults = [System.Collections.Generic.List[object]]::new()

    foreach ($reviewerName in $reviewerMap.Keys) {
        $entry = $reviewerMap[$reviewerName]

        # Skip reviewers with insufficient campaigns
        if ($entry['CampaignsParticipated'] -lt $MinCampaigns) {
            continue
        }

        $totalItems   = $entry['TotalApproved'] + $entry['TotalRevoked'] + $entry['TotalPending']
        $totalDecided = $entry['TotalApproved'] + $entry['TotalRevoked']

        # --- Lifetime approval rate ---
        $lifetimeApprovalRate = 0
        if ($totalDecided -gt 0) {
            $lifetimeApprovalRate = [Math]::Round(($entry['TotalApproved'] / $totalDecided) * 100, 1)
        }

        # --- Average response hours (weighted across campaigns) ---
        $avgResponseHours = 0
        $hoursList = @($entry['AvgHoursPerCampaign'])
        if ($hoursList.Count -gt 0) {
            $avgResponseHours = [Math]::Round(($hoursList | Measure-Object -Average).Average, 1)
        }

        # --- Response trend (improving = getting faster) ---
        $responseTrend = 'Stable'
        $snapshots = @($entry['CampaignSnapshots'] | Where-Object { $null -ne $_['Created'] } | Sort-Object { $_['Created'] })
        $hoursOverTime = @($snapshots | Where-Object { $null -ne $_['AvgHours'] } | ForEach-Object { $_['AvgHours'] })
        if ($hoursOverTime.Count -ge 3) {
            $improving = 0
            $degrading = 0
            for ($i = 1; $i -lt $hoursOverTime.Count; $i++) {
                $delta = $hoursOverTime[$i] - $hoursOverTime[$i - 1]
                if ($delta -lt -0.5) { $improving++ }
                elseif ($delta -gt 0.5) { $degrading++ }
            }
            if ($improving -gt $degrading -and $improving -ge 2) { $responseTrend = 'Improving' }
            elseif ($degrading -gt $improving -and $degrading -ge 2) { $responseTrend = 'Degrading' }
        }

        # ===== REPUTATION SCORE (0-100) =====

        # Component 1: Response time score (30%) -- faster is better
        # Baseline: 24h = 50 points, 0h = 100 points, 72h+ = 0 points
        $responseScore = 0
        if ($hoursList.Count -gt 0) {
            $clampedHours = [Math]::Min([Math]::Max($avgResponseHours, 0), 72)
            $responseScore = [Math]::Round((1 - ($clampedHours / 72)) * 100, 1)
        }
        else {
            $responseScore = 50  # no data -> neutral
        }

        # Component 2: Completion rate score (25%) -- higher is better
        $completionScore = 0
        $completionRates = @($entry['CompletionRates'])
        if ($completionRates.Count -gt 0) {
            $completionScore = [Math]::Round(($completionRates | Measure-Object -Average).Average, 1)
        }
        else {
            $completionScore = 50  # no data -> neutral
        }

        # Component 3: Decision diversity score (20%) -- mix of approve/revoke is healthier
        # 100% approval = low diversity = score 20; 50/50 = max diversity = score 100
        $diversityScore = 50
        if ($totalDecided -gt 0) {
            $revocationRate = $entry['TotalRevoked'] / $totalDecided
            # Optimal revocation rate is around 10-30%. Score peaks at 20% and drops toward 0% and 100%.
            # Use a simple bell-curve approximation centered at 0.2
            $deviation = [Math]::Abs($revocationRate - 0.2)
            # max deviation from 0.2 is 0.8 (at 100% revocation); scale to 0-100
            $diversityScore = [Math]::Round((1 - [Math]::Min($deviation / 0.8, 1)) * 100, 1)
        }

        # Component 4: Consistency score (15%) -- low variance in approval rate across campaigns
        $consistencyScore = 50
        $campApprovalRates = @($snapshots | ForEach-Object { $_['ApprovalRate'] })
        if ($campApprovalRates.Count -ge 2) {
            $mean = ($campApprovalRates | Measure-Object -Average).Average
            $sumSqDiff = 0
            foreach ($rate in $campApprovalRates) {
                $sumSqDiff += ($rate - $mean) * ($rate - $mean)
            }
            $stdDev = [Math]::Sqrt($sumSqDiff / $campApprovalRates.Count)
            # stdDev of 0 = perfect consistency (100), stdDev of 50 = terrible (0)
            $consistencyScore = [Math]::Round([Math]::Max(0, (1 - ($stdDev / 50)) * 100), 1)
        }

        # Component 5: Escalation history score (10%) -- fewer escalations is better
        $escalationScore = 100
        $escCount = $entry['EscalationCount']
        $campCount = $entry['CampaignsParticipated']
        if ($campCount -gt 0 -and $escCount -gt 0) {
            $escRatio = $escCount / $campCount
            $escalationScore = [Math]::Round([Math]::Max(0, (1 - $escRatio) * 100), 1)
        }

        # Weighted composite
        $reputationScore = [Math]::Round(
            ($responseScore    * 0.30) +
            ($completionScore  * 0.25) +
            ($diversityScore   * 0.20) +
            ($consistencyScore * 0.15) +
            ($escalationScore  * 0.10),
            0
        )
        # Clamp to 0-100
        $reputationScore = [Math]::Min(100, [Math]::Max(0, $reputationScore))

        # Tier classification
        $reputationTier = if ($reputationScore -ge 80) { 'Excellent' }
                          elseif ($reputationScore -ge 60) { 'Good' }
                          elseif ($reputationScore -ge 40) { 'Needs Attention' }
                          else { 'At Risk' }

        $reviewerResults.Add([PSCustomObject]@{
            ReviewerName          = $reviewerName
            ReviewerIdentityId    = $entry['IdentityId']
            CampaignsParticipated = $entry['CampaignsParticipated']
            TotalItemsReviewed    = $totalItems
            AvgResponseHours      = $avgResponseHours
            ResponseTrend         = $responseTrend
            LifetimeApprovalRate  = $lifetimeApprovalRate
            RubberStampCount      = $entry['RubberStampCount']
            EscalationCount       = $entry['EscalationCount']
            ReputationScore       = $reputationScore
            ReputationTier        = $reputationTier
        })
    }

    # Sort by ReputationScore ascending (worst first for actionability)
    $sorted = @($reviewerResults | Sort-Object ReputationScore)

    # Build summary
    $excellent      = @($sorted | Where-Object { $_.ReputationTier -eq 'Excellent' }).Count
    $good           = @($sorted | Where-Object { $_.ReputationTier -eq 'Good' }).Count
    $needsAttention = @($sorted | Where-Object { $_.ReputationTier -eq 'Needs Attention' }).Count
    $atRisk         = @($sorted | Where-Object { $_.ReputationTier -eq 'At Risk' }).Count

    Write-SPLog -Message "Reviewer reputation: $($sorted.Count) reviewers scored -- Excellent=$excellent, Good=$good, NeedsAttention=$needsAttention, AtRisk=$atRisk" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPReviewerReputation' `
        -CorrelationID $CorrelationID

    return @{
        Reviewers = $sorted
        Summary   = @{
            TotalReviewers = $sorted.Count
            Excellent      = $excellent
            Good           = $good
            NeedsAttention = $needsAttention
            AtRisk         = $atRisk
        }
    }
}

#endregion

#region Entitlement Inventory HTML (P11-07)

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

#endregion

#region Compliance Evidence Package (P12-01)

function Export-SPCompliancePackage {
    <#
    .SYNOPSIS
        Bundles audit artifacts from a date range into a single ZIP evidence package.
    .DESCRIPTION
        Scans Audit and DeltaCert output directories for HTML, CSV, JSONL, and TXT
        artifacts, then packages them into a single ZIP file with a JSON manifest
        containing SHA256 hashes per artifact. Designed for SOX 404, SOC 2, and
        ISO 27001 evidence delivery.
    .PARAMETER After
        Include artifacts modified after this datetime.
    .PARAMETER Before
        Include artifacts modified before this datetime.
    .PARAMETER AuditOutputPath
        Audit output directory. Resolved from config if omitted.
    .PARAMETER DeltaCertOutputPath
        DeltaCert output directory. Resolved from config if omitted.
    .PARAMETER OutputPath
        Directory for the output ZIP. Defaults to current directory.
    .PARAMETER PackageName
        Custom ZIP file name (without extension). Auto-generated from date range if omitted.
    .PARAMETER Scope
        Which directories to include: Full (both), AuditOnly, or DeltaCertOnly.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] Package result with path, artifact count, and category breakdown.
    .EXAMPLE
        Export-SPCompliancePackage -After (Get-Date).AddDays(-90) -Before (Get-Date)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][DateTime]$After,
        [Parameter()][DateTime]$Before,
        [Parameter()][string]$AuditOutputPath,
        [Parameter()][string]$DeltaCertOutputPath,
        [Parameter()][string]$OutputPath = '.',
        [Parameter()][string]$PackageName,
        [Parameter()][ValidateSet('Full','AuditOnly','DeltaCertOnly')]
        [string]$Scope = 'Full',
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Export-SPCompliancePackage: starting (Scope=$Scope)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
        -CorrelationID $CorrelationID

    # Resolve paths from config if not provided
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -or
        [string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) {
        try {
            $config = Get-SPConfig
            if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'Audit' -and
                $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
                $AuditOutputPath = $config.Audit.OutputPath
            }
            if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'DeltaCert' -and
                $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
                $DeltaCertOutputPath = $config.DeltaCert.OutputPath
            }
        }
        catch {
            Write-SPLog -Message "Could not load config for path resolution: $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
                -CorrelationID $CorrelationID
        }
    }
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath))     { $AuditOutputPath     = '.\Audit' }
    if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) { $DeltaCertOutputPath = '.\DeltaCert' }

    # Resolve toolkit version
    $toolkitVersion = 'Unknown'
    try {
        $cfgCheck = Get-SPConfig
        if ($null -ne $cfgCheck -and
            $cfgCheck.PSObject.Properties.Name -contains 'Global' -and
            $cfgCheck.Global.PSObject.Properties.Name -contains 'ToolkitVersion') {
            $toolkitVersion = $cfgCheck.Global.ToolkitVersion
        }
    } catch { }

    # Ensure output directory exists
    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # Supported artifact extensions
    $supportedExtensions = @('.html', '.csv', '.jsonl', '.txt', '.json', '.log')

    # Collect artifacts
    $artifacts = [System.Collections.Generic.List[hashtable]]::new()

    # Helper: scan a directory for matching files
    function _ScanDirectory {
        param(
            [string]$Path,
            [string]$Category,
            [string]$ZipSubfolder
        )
        if (-not (Test-Path -Path $Path -PathType Container)) { return }
        $files = Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Extension -notin $supportedExtensions) { continue }
            # Date range filter by last write time
            if ($PSBoundParameters.ContainsKey('After') -or $After -ne $null) {
                # Use the outer scope After/Before
            }
            if ($null -ne $script:filterAfter -and $f.LastWriteTime -lt $script:filterAfter) { continue }
            if ($null -ne $script:filterBefore -and $f.LastWriteTime -gt $script:filterBefore) { continue }

            # Determine sub-category
            $subCategory = $Category
            if ($f.Extension -eq '.csv') { $subCategory = 'CsvExports' }
            elseif ($f.Extension -eq '.jsonl') { $subCategory = 'AuditTrails' }
            elseif ($f.Extension -eq '.txt') { $subCategory = 'RemediationProof' }

            # Determine zip subfolder for CSVs
            $targetFolder = $ZipSubfolder
            if ($f.Extension -eq '.csv') { $targetFolder = 'csv' }

            $artifacts.Add(@{
                FullPath     = $f.FullName
                FileName     = $f.Name
                Category     = $subCategory
                ZipFolder    = $targetFolder
                SizeBytes    = $f.Length
                LastModified = $f.LastWriteTime
            })
        }
    }

    # Store filter dates in script scope for the helper
    $script:filterAfter  = if ($PSBoundParameters.ContainsKey('After'))  { $After }  else { $null }
    $script:filterBefore = if ($PSBoundParameters.ContainsKey('Before')) { $Before } else { $null }

    # Scan directories based on scope
    if ($Scope -ne 'DeltaCertOnly') {
        _ScanDirectory -Path $AuditOutputPath -Category 'AuditReports' -ZipSubfolder 'audit'
        # Scan leadership subdirectory
        $leadershipPath = Join-Path -Path $AuditOutputPath -ChildPath 'leadership'
        if (Test-Path -Path $leadershipPath -PathType Container) {
            $leaderFiles = Get-ChildItem -Path $leadershipPath -File -ErrorAction SilentlyContinue
            foreach ($f in $leaderFiles) {
                if ($f.Extension -notin $supportedExtensions) { continue }
                if ($null -ne $script:filterAfter -and $f.LastWriteTime -lt $script:filterAfter) { continue }
                if ($null -ne $script:filterBefore -and $f.LastWriteTime -gt $script:filterBefore) { continue }
                $artifacts.Add(@{
                    FullPath     = $f.FullName
                    FileName     = $f.Name
                    Category     = 'LeadershipReports'
                    ZipFolder    = 'leadership'
                    SizeBytes    = $f.Length
                    LastModified = $f.LastWriteTime
                })
            }
        }
    }

    if ($Scope -ne 'AuditOnly') {
        _ScanDirectory -Path $DeltaCertOutputPath -Category 'DeltaCertReports' -ZipSubfolder 'deltacert'
    }

    Write-SPLog -Message "Export-SPCompliancePackage: found $($artifacts.Count) artifacts" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
        -CorrelationID $CorrelationID

    # Build package name
    if ([string]::IsNullOrWhiteSpace($PackageName)) {
        $afterStr  = if ($null -ne $script:filterAfter)  { $script:filterAfter.ToString('yyyy-MM-dd') }  else { 'all' }
        $beforeStr = if ($null -ne $script:filterBefore) { $script:filterBefore.ToString('yyyy-MM-dd') } else { 'now' }
        $PackageName = "compliance-evidence-${afterStr}-to-${beforeStr}"
    }
    $zipFileName = "${PackageName}.zip"
    $zipFilePath = Join-Path -Path $OutputPath -ChildPath $zipFileName

    # Remove existing ZIP if present (overwrite)
    if (Test-Path -Path $zipFilePath) {
        Remove-Item -Path $zipFilePath -Force
    }

    # Build manifest and create ZIP
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $packageId    = [guid]::NewGuid().ToString()
    $generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
    $manifestArts = [System.Collections.Generic.List[hashtable]]::new()

    # Compute SHA256 for each artifact
    foreach ($art in $artifacts) {
        $sha256 = ''
        try {
            $hashResult = Get-FileHash -Path $art.FullPath -Algorithm SHA256
            $sha256 = $hashResult.Hash
        } catch {
            Write-SPLog -Message "Could not hash file $($art.FileName): $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
                -CorrelationID $CorrelationID
        }

        $manifestArts.Add(@{
            FileName     = $art.FileName
            OriginalPath = $art.FullPath
            Type         = $art.ZipFolder
            Category     = $art.Category
            SizeBytes    = $art.SizeBytes
            SHA256       = $sha256
        })
    }

    # Build category counts
    $categories = @{
        AuditReports      = 0
        CsvExports        = 0
        AuditTrails       = 0
        LeadershipReports = 0
        DeltaCertReports  = 0
        RemediationProof  = 0
    }
    foreach ($art in $artifacts) {
        if ($categories.ContainsKey($art.Category)) {
            $categories[$art.Category]++
        }
    }

    $totalSizeBytes = 0
    foreach ($art in $artifacts) { $totalSizeBytes += $art.SizeBytes }

    $dateRange = @{
        After  = if ($null -ne $script:filterAfter)  { $script:filterAfter.ToString('o') }  else { $null }
        Before = if ($null -ne $script:filterBefore) { $script:filterBefore.ToString('o') } else { $null }
    }

    $manifest = @{
        PackageId      = $packageId
        GeneratedAt    = $generatedAt
        DateRange      = $dateRange
        ToolkitVersion = $toolkitVersion
        Artifacts      = @($manifestArts)
        Summary        = @{
            TotalArtifacts = $artifacts.Count
            TotalSizeBytes = $totalSizeBytes
            Categories     = $categories
        }
    }

    # Create ZIP archive
    try {
        $zipStream  = [System.IO.File]::Create($zipFilePath)
        $zipArchive = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)

        # Add manifest.json at root
        $manifestJson = $manifest | ConvertTo-Json -Depth 10
        $manifestEntry = $zipArchive.CreateEntry('manifest.json')
        $manifestWriter = [System.IO.StreamWriter]::new($manifestEntry.Open())
        $manifestWriter.Write($manifestJson)
        $manifestWriter.Close()

        # Add each artifact to its subfolder
        foreach ($art in $artifacts) {
            $entryName = "$($art.ZipFolder)/$($art.FileName)"
            $entry = $zipArchive.CreateEntry($entryName)
            $entryStream = $entry.Open()
            try {
                $fileBytes = [System.IO.File]::ReadAllBytes($art.FullPath)
                $entryStream.Write($fileBytes, 0, $fileBytes.Length)
            } finally {
                $entryStream.Close()
            }
        }

        $zipArchive.Dispose()
        $zipStream.Close()
    }
    catch {
        Write-SPLog -Message "Failed to create ZIP: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
            -CorrelationID $CorrelationID
        return @{
            Success = $false
            Error   = "Failed to create ZIP: $($_.Exception.Message)"
        }
    }

    $resolvedZipPath = (Resolve-Path -Path $zipFilePath).Path

    Write-SPLog -Message "Export-SPCompliancePackage: created $resolvedZipPath ($($artifacts.Count) artifacts, $totalSizeBytes bytes)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            PackagePath    = $resolvedZipPath
            PackageId      = $packageId
            ArtifactCount  = $artifacts.Count
            TotalSizeBytes = $totalSizeBytes
            Categories     = $categories
        }
    }
}

#endregion

#region Identity Risk Scoring (P12-02)

function Measure-SPIdentityRisk {
    <#
    .SYNOPSIS
        Aggregates risk signals per identity across all audited campaigns.
    .DESCRIPTION
        Consumes an array of campaign audit hashtables (same structure used by
        Export-SPAuditCsv) and produces a composite risk score (0-100) per identity.
        Answers: "Which identities should we prioritize for access review?"

        Risk signals accumulated per identity across campaigns:
        - StaleAccessCount: Items flagged STALE (>90 days unreviewed)
        - PrivilegedAccessCount: Entitlements matching privileged patterns
        - RubberStampApprovals: Items approved by reviewers flagged for rubber-stamping
        - OrphanAccountFlag: Identity has orphan accounts
        - OverdueRemediations: Revocations past SLA not provisioned
        - ApprovalOnlyHistory: Never had access revoked across all campaigns
        - CampaignsReviewed: How many campaigns included this identity
        - LastReviewDate: Most recent campaign decision date
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions, RubberStampRisk, etc.
    .PARAMETER HighRiskThreshold
        Score at or above which an identity is classified High risk. Default 70.
    .PARAMETER MediumRiskThreshold
        Score at or above which an identity is classified Medium risk. Default 40.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Identities = @(...); Summary = @{...} }
    .EXAMPLE
        $risk = Measure-SPIdentityRisk -CampaignAudits $audits
        $risk.Identities | Where-Object { $_.RiskTier -eq 'High' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [int]$HighRiskThreshold = 70,

        [Parameter()]
        [int]$MediumRiskThreshold = 40,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measure-SPIdentityRisk: starting with $($CampaignAudits.Count) campaign(s)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPIdentityRisk' `
        -CorrelationID $CorrelationID

    # Return empty result for empty input
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            Identities = @()
            Summary    = @{
                TotalIdentities = 0
                High            = 0
                Medium          = 0
                Low             = 0
                AvgRiskScore    = 0
            }
        }
    }

    # Per-identity accumulator: keyed by IdentityId
    $identityMap = @{}

    # Build rubber-stamp reviewer set per campaign
    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        # Identify rubber-stamp reviewers (Medium or High severity)
        $rubberStampReviewers = @{}
        if ($audit.ContainsKey('RubberStampRisk') -and $null -ne $audit['RubberStampRisk']) {
            $rsRisk = $audit['RubberStampRisk']
            $reviewerRisks = if ($rsRisk.ContainsKey('ReviewerRisks') -and $null -ne $rsRisk['ReviewerRisks']) {
                @($rsRisk['ReviewerRisks'])
            } else { @() }
            foreach ($rr in $reviewerRisks) {
                if ($null -eq $rr) { continue }
                $sev = ''
                if ($rr -is [hashtable]) {
                    $sev = if ($rr.ContainsKey('Severity')) { [string]$rr['Severity'] } else { '' }
                } else {
                    $sevProp = $rr.PSObject.Properties['Severity']
                    $sev = if ($null -ne $sevProp) { [string]$sevProp.Value } else { '' }
                }
                if ($sev -eq 'Medium' -or $sev -eq 'High') {
                    $name = ''
                    if ($rr -is [hashtable]) {
                        $name = if ($rr.ContainsKey('ReviewerName')) { [string]$rr['ReviewerName'] } else { '' }
                    } else {
                        $nameProp = $rr.PSObject.Properties['ReviewerName']
                        $name = if ($null -ne $nameProp) { [string]$nameProp.Value } else { '' }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $rubberStampReviewers[$name] = $true
                    }
                }
            }
        }

        # Process all decision categories
        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                # Extract identity info
                $identityId = ''
                $identityName = ''
                $accessName = ''
                $reviewerName = ''
                $decisionDate = ''
                $riskFlags = @()

                if ($item -is [hashtable]) {
                    $identityId   = if ($item.ContainsKey('IdentityId'))   { [string]$item['IdentityId'] }   else { '' }
                    $identityName = if ($item.ContainsKey('IdentityName')) { [string]$item['IdentityName'] } else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $reviewerName = if ($item.ContainsKey('ReviewerName')) { [string]$item['ReviewerName'] } else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                    $riskFlags    = if ($item.ContainsKey('RiskFlags') -and $null -ne $item['RiskFlags']) { @($item['RiskFlags']) } else { @() }
                } else {
                    $idProp = $item.PSObject.Properties['IdentityId']
                    $identityId = if ($null -ne $idProp -and $null -ne $idProp.Value) { [string]$idProp.Value } else { '' }
                    $nmProp = $item.PSObject.Properties['IdentityName']
                    $identityName = if ($null -ne $nmProp -and $null -ne $nmProp.Value) { [string]$nmProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $rnProp = $item.PSObject.Properties['ReviewerName']
                    $reviewerName = if ($null -ne $rnProp -and $null -ne $rnProp.Value) { [string]$rnProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                    $rfProp = $item.PSObject.Properties['RiskFlags']
                    $riskFlags = if ($null -ne $rfProp -and $null -ne $rfProp.Value) { @($rfProp.Value) } else { @() }
                }

                if ([string]::IsNullOrWhiteSpace($identityId)) { continue }

                # Initialize identity record if not seen
                if (-not $identityMap.ContainsKey($identityId)) {
                    $identityMap[$identityId] = @{
                        IdentityId            = $identityId
                        IdentityName          = $identityName
                        StaleAccessCount      = 0
                        PrivilegedAccessCount = 0
                        RubberStampApprovals  = 0
                        OrphanAccountFlag     = $false
                        OverdueRemediations   = 0
                        HasRevocation         = $false
                        CampaignSet           = @{}
                        LastReviewDate        = $null
                    }
                }

                $idRec = $identityMap[$identityId]

                # Update identity name if we have a better one
                if (-not [string]::IsNullOrWhiteSpace($identityName)) {
                    $idRec['IdentityName'] = $identityName
                }

                # Track campaign participation
                $campaignName = ''
                if ($audit.ContainsKey('CampaignName')) { $campaignName = [string]$audit['CampaignName'] }
                if ($audit.ContainsKey('CampaignId'))   { $campaignName = [string]$audit['CampaignId'] }
                if (-not [string]::IsNullOrWhiteSpace($campaignName)) {
                    $idRec['CampaignSet'][$campaignName] = $true
                }

                # Track last review date
                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $idRec['LastReviewDate'] -or $dt -gt $idRec['LastReviewDate']) {
                            $idRec['LastReviewDate'] = $dt
                        }
                    } catch { }
                }

                # Accumulate risk flags
                foreach ($flag in $riskFlags) {
                    switch ($flag) {
                        'STALE'      { $idRec['StaleAccessCount']++ }
                        'PRIVILEGED' { $idRec['PrivilegedAccessCount']++ }
                        'ORPHAN'     { $idRec['OrphanAccountFlag'] = $true }
                    }
                }

                # Track revocations
                if ($category -eq 'Revoked') {
                    $idRec['HasRevocation'] = $true
                }

                # Track rubber-stamp approvals
                if ($category -eq 'Approved' -and
                    -not [string]::IsNullOrWhiteSpace($reviewerName) -and
                    $rubberStampReviewers.ContainsKey($reviewerName)) {
                    $idRec['RubberStampApprovals']++
                }

                # Track overdue remediations (revoked items with overdue remediation)
                if ($category -eq 'Revoked') {
                    $remStatus = ''
                    if ($item -is [hashtable] -and $item.ContainsKey('RemediationStatus')) {
                        $remStatus = [string]$item['RemediationStatus']
                    } elseif ($item -isnot [hashtable]) {
                        $rsProp = $item.PSObject.Properties['RemediationStatus']
                        if ($null -ne $rsProp -and $null -ne $rsProp.Value) {
                            $remStatus = [string]$rsProp.Value
                        }
                    }
                    if ($remStatus -eq 'Overdue' -or $remStatus -eq 'overdue') {
                        $idRec['OverdueRemediations']++
                    }
                }
            }
        }
    }

    # Calculate risk scores
    $now = Get-Date
    $identityResults = [System.Collections.Generic.List[hashtable]]::new()
    $highCount = 0
    $mediumCount = 0
    $lowCount = 0
    $totalScore = 0.0

    foreach ($idKey in $identityMap.Keys) {
        $idRec = $identityMap[$idKey]

        $score = 0

        # Privileged access: +15 per privileged entitlement (max 30)
        $privScore = [Math]::Min($idRec['PrivilegedAccessCount'] * 15, 30)
        $score += $privScore

        # Stale access: +10 per stale item (max 20)
        $staleScore = [Math]::Min($idRec['StaleAccessCount'] * 10, 20)
        $score += $staleScore

        # Rubber-stamp approvals: +10 per rubber-stamp approval (max 20)
        $rsScore = [Math]::Min($idRec['RubberStampApprovals'] * 10, 20)
        $score += $rsScore

        # Orphan account: +15 (flat)
        if ($idRec['OrphanAccountFlag']) { $score += 15 }

        # Overdue remediation: +15 per overdue item (max 15)
        $overdueScore = [Math]::Min($idRec['OverdueRemediations'] * 15, 15)
        $score += $overdueScore

        # Approval-only history with 3+ campaigns: +10
        $campaignsReviewed = $idRec['CampaignSet'].Count
        $approvalOnly = (-not $idRec['HasRevocation']) -and ($campaignsReviewed -ge 3)
        if ($approvalOnly) { $score += 10 }

        # Not reviewed in 180+ days: +10
        $daysSinceReview = $null
        if ($null -ne $idRec['LastReviewDate']) {
            $daysSinceReview = [int]($now - $idRec['LastReviewDate']).TotalDays
            if ($daysSinceReview -ge 180) { $score += 10 }
        }

        # Clamp to 0-100
        $score = [Math]::Max(0, [Math]::Min(100, $score))

        # Determine risk tier
        $tier = if ($score -ge $HighRiskThreshold) { 'High' }
                elseif ($score -ge $MediumRiskThreshold) { 'Medium' }
                else { 'Low' }

        # Build top risk factors list
        $topFactors = [System.Collections.Generic.List[string]]::new()
        if ($idRec['PrivilegedAccessCount'] -gt 0) { $topFactors.Add('Privileged Access') }
        if ($idRec['StaleAccessCount'] -gt 0)      { $topFactors.Add('Stale Access') }
        if ($idRec['RubberStampApprovals'] -gt 0)   { $topFactors.Add('Rubber-Stamp Approvals') }
        if ($idRec['OrphanAccountFlag'])            { $topFactors.Add('Orphan Account') }
        if ($idRec['OverdueRemediations'] -gt 0)    { $topFactors.Add('Overdue Remediation') }
        if ($approvalOnly)                          { $topFactors.Add('Approval-Only History') }
        if ($null -ne $daysSinceReview -and $daysSinceReview -ge 180) { $topFactors.Add('Not Recently Reviewed') }

        $lastReviewStr = if ($null -ne $idRec['LastReviewDate']) {
            $idRec['LastReviewDate'].ToString('yyyy-MM-dd')
        } else { $null }

        $identityResults.Add(@{
            IdentityId            = $idRec['IdentityId']
            IdentityName          = $idRec['IdentityName']
            RiskScore             = $score
            RiskTier              = $tier
            StaleAccessCount      = $idRec['StaleAccessCount']
            PrivilegedAccessCount = $idRec['PrivilegedAccessCount']
            RubberStampApprovals  = $idRec['RubberStampApprovals']
            OrphanAccountFlag     = $idRec['OrphanAccountFlag']
            OverdueRemediations   = $idRec['OverdueRemediations']
            ApprovalOnlyHistory   = $approvalOnly
            CampaignsReviewed     = $campaignsReviewed
            LastReviewDate        = $lastReviewStr
            TopRiskFactors        = @($topFactors)
        })

        $totalScore += $score
        switch ($tier) {
            'High'   { $highCount++ }
            'Medium' { $mediumCount++ }
            'Low'    { $lowCount++ }
        }
    }

    # Sort by risk score descending
    $sorted = @($identityResults | Sort-Object { $_['RiskScore'] } -Descending)

    $totalIdentities = $sorted.Count
    $avgScore = if ($totalIdentities -gt 0) {
        [Math]::Round($totalScore / $totalIdentities, 1)
    } else { 0 }

    Write-SPLog -Message "Measure-SPIdentityRisk: scored $totalIdentities identities (High=$highCount, Medium=$mediumCount, Low=$lowCount)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPIdentityRisk' `
        -CorrelationID $CorrelationID

    return @{
        Identities = $sorted
        Summary    = @{
            TotalIdentities = $totalIdentities
            High            = $highCount
            Medium          = $mediumCount
            Low             = $lowCount
            AvgRiskScore    = $avgScore
        }
    }
}

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

#endregion

#region P12-03: Source Governance Scorecard

function Measure-SPSourceGovernance {
    <#
    .SYNOPSIS
        Calculates a governance coverage score per configured source.
    .DESCRIPTION
        Combines entitlement inventory data with campaign review history to produce
        a per-source governance grade (A-F). Answers: "How well is each source
        being governed? Where are the blind spots?"

        Grade calculation (weighted):
        - Entitlement coverage (40%): Higher coverage = better grade
        - Privileged coverage (25%): Privileged entitlements reviewed more strictly
        - Review recency (20%): Recent review within window = better
        - Campaign frequency (15%): Multiple campaigns = better
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions, RubberStampRisk, etc.
    .PARAMETER EntitlementInventory
        Hashtable from Get-SPEntitlementInventory .Data output containing Sources
        and Summary. Optional -- if not provided, grades based on campaign data only.
    .PARAMETER ReviewWindowDays
        Number of days within which a review is considered recent. Default 365.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Sources = @(...); Summary = @{...} }
    .EXAMPLE
        $inv = Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory
        $audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object { Get-SPAuditCampaignReport -CampaignId $_.id }
        $result = Measure-SPSourceGovernance -CampaignAudits $audits -EntitlementInventory $inv.Data
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [hashtable]$EntitlementInventory,

        [Parameter()]
        [int]$ReviewWindowDays = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measure-SPSourceGovernance: starting with $($CampaignAudits.Count) campaign(s), ReviewWindowDays=$ReviewWindowDays" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPSourceGovernance' `
        -CorrelationID $CorrelationID

    # Return empty result for empty input
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            Sources = @()
            Summary = @{
                TotalSources       = 0
                GradeDistribution  = @{ A = 0; B = 0; C = 0; D = 0; F = 0 }
                OverallCoveragePct = 0
                AvgGovernanceScore = 0
            }
        }
    }

    $now = Get-Date

    # -------------------------------------------------------------------
    # Step 1: Build per-source review data from campaign decision items
    # -------------------------------------------------------------------
    # sourceMap: SourceName -> @{ ReviewedEntitlements (set); PrivilegedReviewed (set);
    #   CampaignSet (set); LastReviewDate; DecisionDates (list) }
    $sourceMap = @{}

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        $campaignName = ''
        if ($audit.ContainsKey('CampaignName')) { $campaignName = [string]$audit['CampaignName'] }
        if ([string]::IsNullOrWhiteSpace($campaignName) -and $audit.ContainsKey('CampaignId')) {
            $campaignName = [string]$audit['CampaignId']
        }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                # Extract fields -- support both hashtable and PSObject
                $sourceName = ''
                $accessName = ''
                $decisionDate = ''
                $riskFlags = @()

                if ($item -is [hashtable]) {
                    $sourceName   = if ($item.ContainsKey('SourceName'))   { [string]$item['SourceName'] }   else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                    $riskFlags    = if ($item.ContainsKey('RiskFlags') -and $null -ne $item['RiskFlags']) { @($item['RiskFlags']) } else { @() }
                } else {
                    $snProp = $item.PSObject.Properties['SourceName']
                    $sourceName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                    $rfProp = $item.PSObject.Properties['RiskFlags']
                    $riskFlags = if ($null -ne $rfProp -and $null -ne $rfProp.Value) { @($rfProp.Value) } else { @() }
                }

                if ([string]::IsNullOrWhiteSpace($sourceName)) { continue }

                # Initialize source record
                if (-not $sourceMap.ContainsKey($sourceName)) {
                    $sourceMap[$sourceName] = @{
                        SourceId             = ''
                        ReviewedEntitlements = @{}
                        PrivilegedReviewed   = @{}
                        CampaignSet          = @{}
                        LastReviewDate       = $null
                        DecisionDates        = [System.Collections.Generic.List[datetime]]::new()
                    }
                }

                $srcRec = $sourceMap[$sourceName]

                # Track reviewed entitlements
                if (-not [string]::IsNullOrWhiteSpace($accessName)) {
                    $srcRec['ReviewedEntitlements'][$accessName] = $true

                    # Check if privileged
                    $isPrivileged = $false
                    foreach ($flag in $riskFlags) {
                        if ($flag -eq 'PRIVILEGED') { $isPrivileged = $true; break }
                    }
                    if ($isPrivileged) {
                        $srcRec['PrivilegedReviewed'][$accessName] = $true
                    }
                }

                # Track campaign participation
                if (-not [string]::IsNullOrWhiteSpace($campaignName)) {
                    $srcRec['CampaignSet'][$campaignName] = $true
                }

                # Track review dates
                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $srcRec['LastReviewDate'] -or $dt -gt $srcRec['LastReviewDate']) {
                            $srcRec['LastReviewDate'] = $dt
                        }
                        $srcRec['DecisionDates'].Add($dt)
                    } catch { }
                }
            }
        }
    }

    # -------------------------------------------------------------------
    # Step 2: Cross-reference with entitlement inventory if provided
    # -------------------------------------------------------------------
    # Build inventory lookup: SourceName -> @{ TotalEntitlements; PrivilegedCount; SourceId }
    $inventoryLookup = @{}
    if ($null -ne $EntitlementInventory -and $EntitlementInventory.ContainsKey('Sources')) {
        $invSources = $EntitlementInventory['Sources']
        foreach ($srcId in $invSources.Keys) {
            $srcData = $invSources[$srcId]
            $srcName = ''
            if ($srcData -is [hashtable]) {
                $srcName = if ($srcData.ContainsKey('SourceName')) { [string]$srcData['SourceName'] } else { '' }
            } else {
                $snProp = $srcData.PSObject.Properties['SourceName']
                $srcName = if ($null -ne $snProp) { [string]$snProp.Value } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($srcName)) { continue }

            $totalEnt = 0
            $privCount = 0
            if ($srcData -is [hashtable]) {
                $totalEnt  = if ($srcData.ContainsKey('TotalEntitlements')) { [int]$srcData['TotalEntitlements'] } else { 0 }
                $privCount = if ($srcData.ContainsKey('Privileged'))       { [int]$srcData['Privileged'] }       else { 0 }
            } else {
                $teProp = $srcData.PSObject.Properties['TotalEntitlements']
                $totalEnt = if ($null -ne $teProp) { [int]$teProp.Value } else { 0 }
                $ppProp = $srcData.PSObject.Properties['Privileged']
                $privCount = if ($null -ne $ppProp) { [int]$ppProp.Value } else { 0 }
            }

            $inventoryLookup[$srcName] = @{
                TotalEntitlements    = $totalEnt
                PrivilegedEntitlements = $privCount
                SourceId             = [string]$srcId
            }

            # Ensure this source appears in sourceMap even if no campaign data
            if (-not $sourceMap.ContainsKey($srcName)) {
                $sourceMap[$srcName] = @{
                    SourceId             = [string]$srcId
                    ReviewedEntitlements = @{}
                    PrivilegedReviewed   = @{}
                    CampaignSet          = @{}
                    LastReviewDate       = $null
                    DecisionDates        = [System.Collections.Generic.List[datetime]]::new()
                }
            }
            if ([string]::IsNullOrWhiteSpace($sourceMap[$srcName]['SourceId'])) {
                $sourceMap[$srcName]['SourceId'] = [string]$srcId
            }
        }
    }

    # -------------------------------------------------------------------
    # Step 3: Calculate per-source governance grade
    # -------------------------------------------------------------------
    $sourceResults = [System.Collections.Generic.List[hashtable]]::new()
    $gradeDistribution = @{ A = 0; B = 0; C = 0; D = 0; F = 0 }
    $totalCoverage = 0.0
    $totalGovernanceScore = 0.0
    $sourcesWithCoverage = 0

    foreach ($srcName in $sourceMap.Keys) {
        $srcRec = $sourceMap[$srcName]
        $invData = if ($inventoryLookup.ContainsKey($srcName)) { $inventoryLookup[$srcName] } else { $null }

        $sourceId = $srcRec['SourceId']
        $reviewedCount = $srcRec['ReviewedEntitlements'].Count
        $privReviewedCount = $srcRec['PrivilegedReviewed'].Count
        $campaignCount = $srcRec['CampaignSet'].Count
        $lastReviewDate = $srcRec['LastReviewDate']

        # Total entitlements and privileged from inventory
        $totalEntitlements = $null
        $privilegedEntitlements = 0
        if ($null -ne $invData) {
            $totalEntitlements = $invData['TotalEntitlements']
            $privilegedEntitlements = $invData['PrivilegedEntitlements']
            if ([string]::IsNullOrWhiteSpace($sourceId)) {
                $sourceId = $invData['SourceId']
            }
        }

        # Entitlement coverage percentage
        $entCoveragePct = $null
        if ($null -ne $totalEntitlements -and $totalEntitlements -gt 0) {
            $entCoveragePct = [Math]::Round(($reviewedCount / $totalEntitlements) * 100, 1)
            if ($entCoveragePct -gt 100) { $entCoveragePct = 100.0 }
        }

        # Privileged reviewed percentage
        $privReviewedPct = $null
        if ($privilegedEntitlements -gt 0) {
            $privReviewedPct = [Math]::Round(($privReviewedCount / $privilegedEntitlements) * 100, 1)
            if ($privReviewedPct -gt 100) { $privReviewedPct = 100.0 }
        } elseif ($null -ne $invData) {
            # Source is in inventory but has 0 privileged -- full privileged coverage by default
            $privReviewedPct = 100.0
        }

        # Days since last review
        $daysSinceLastReview = $null
        $lastReviewStr = $null
        if ($null -ne $lastReviewDate) {
            $daysSinceLastReview = [int]($now - $lastReviewDate).TotalDays
            $lastReviewStr = $lastReviewDate.ToString('yyyy-MM-dd')
        }

        # Average review cycle days
        $avgReviewCycleDays = $null
        $decisionDates = $srcRec['DecisionDates']
        if ($decisionDates.Count -ge 2) {
            $sortedDates = @($decisionDates | Sort-Object)
            $totalGap = ($sortedDates[-1] - $sortedDates[0]).TotalDays
            $avgReviewCycleDays = [int][Math]::Round($totalGap / ($sortedDates.Count - 1))
        }

        # --- Governance score calculation (0-100 weighted) ---
        $entCoverageScore = 0.0
        $privCoverageScore = 0.0
        $recencyScore = 0.0
        $frequencyScore = 0.0

        # Entitlement coverage (40% weight)
        if ($null -ne $entCoveragePct) {
            $entCoverageScore = $entCoveragePct
        } elseif ($campaignCount -gt 0) {
            # No inventory data but has campaign reviews -- assume partial coverage
            $entCoverageScore = 50.0
        }
        # else: 0 (no inventory, no campaigns)

        # Privileged coverage (25% weight)
        if ($null -ne $privReviewedPct) {
            $privCoverageScore = $privReviewedPct
        } elseif ($campaignCount -gt 0) {
            # No inventory data but has campaigns -- assume moderate
            $privCoverageScore = 50.0
        }

        # Review recency (20% weight)
        if ($null -ne $daysSinceLastReview) {
            if ($daysSinceLastReview -le 0) {
                $recencyScore = 100.0
            } elseif ($daysSinceLastReview -le $ReviewWindowDays) {
                $recencyScore = [Math]::Round((1 - ($daysSinceLastReview / $ReviewWindowDays)) * 100, 1)
                if ($recencyScore -lt 0) { $recencyScore = 0.0 }
            }
            # else: beyond window -> 0
        }

        # Campaign frequency (15% weight)
        if ($campaignCount -ge 4) {
            $frequencyScore = 100.0
        } elseif ($campaignCount -ge 3) {
            $frequencyScore = 80.0
        } elseif ($campaignCount -ge 2) {
            $frequencyScore = 60.0
        } elseif ($campaignCount -ge 1) {
            $frequencyScore = 40.0
        }

        $governanceScore = [Math]::Round(
            ($entCoverageScore * 0.40) +
            ($privCoverageScore * 0.25) +
            ($recencyScore * 0.20) +
            ($frequencyScore * 0.15),
            1
        )

        # Grade assignment
        $grade = if     ($governanceScore -ge 90) { 'A' }
                 elseif ($governanceScore -ge 75) { 'B' }
                 elseif ($governanceScore -ge 60) { 'C' }
                 elseif ($governanceScore -ge 40) { 'D' }
                 else                             { 'F' }

        $gradeDistribution[$grade]++
        $totalGovernanceScore += $governanceScore

        if ($null -ne $entCoveragePct) {
            $totalCoverage += $entCoveragePct
            $sourcesWithCoverage++
        }

        $sourceResults.Add(@{
            SourceId               = $sourceId
            SourceName             = $srcName
            TotalEntitlements      = if ($null -ne $totalEntitlements) { $totalEntitlements } else { 'Unknown' }
            ReviewedEntitlements   = $reviewedCount
            EntitlementCoveragePct = if ($null -ne $entCoveragePct) { $entCoveragePct } else { 'Unknown' }
            PrivilegedEntitlements = $privilegedEntitlements
            PrivilegedReviewedPct  = if ($null -ne $privReviewedPct) { $privReviewedPct } else { 'Unknown' }
            CampaignCount          = $campaignCount
            LastReviewDate         = $lastReviewStr
            DaysSinceLastReview    = $daysSinceLastReview
            AvgReviewCycleDays     = $avgReviewCycleDays
            GovernanceGrade        = $grade
            GovernanceScore        = $governanceScore
        })
    }

    # Sort by governance score ascending (worst first for attention)
    $sorted = @($sourceResults | Sort-Object { $_['GovernanceScore'] })

    $totalSources = $sorted.Count
    $avgGovScore = if ($totalSources -gt 0) {
        [Math]::Round($totalGovernanceScore / $totalSources, 1)
    } else { 0 }
    $overallCoverage = if ($sourcesWithCoverage -gt 0) {
        [Math]::Round($totalCoverage / $sourcesWithCoverage, 1)
    } else { 0 }

    Write-SPLog -Message "Measure-SPSourceGovernance: scored $totalSources source(s) (A=$($gradeDistribution['A']), B=$($gradeDistribution['B']), C=$($gradeDistribution['C']), D=$($gradeDistribution['D']), F=$($gradeDistribution['F']))" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPSourceGovernance' `
        -CorrelationID $CorrelationID

    return @{
        Sources = $sorted
        Summary = @{
            TotalSources       = $totalSources
            GradeDistribution  = $gradeDistribution
            OverallCoveragePct = $overallCoverage
            AvgGovernanceScore = $avgGovScore
        }
    }
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

#endregion

#region P12-04: Stale Access Detector HTML Report

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

#endregion

#region P12-05: Campaign Completion Summary

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

function Send-SPWebhook {
    <#
    .SYNOPSIS
        Sends a JSON payload to an HTTP webhook endpoint.
    .DESCRIPTION
        Converts the payload hashtable to JSON and sends it via Invoke-RestMethod.
        Returns a result hashtable with Success, StatusCode, Response, and Error fields.
    .PARAMETER Url
        The webhook endpoint URL.
    .PARAMETER Payload
        Hashtable to serialize as the JSON request body.
    .PARAMETER Method
        HTTP method. Defaults to POST.
    .PARAMETER Headers
        Optional hashtable of additional HTTP headers.
    .PARAMETER TimeoutSeconds
        Request timeout in seconds. Defaults to 30.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Success; StatusCode; Response; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory)]
        [hashtable]$Payload,

        [Parameter()]
        [string]$Method = 'POST',

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [int]$TimeoutSeconds = 30,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress

        $restParams = @{
            Method      = $Method
            Uri         = $Url
            Body        = $json
            ContentType = 'application/json'
            TimeoutSec  = $TimeoutSeconds
            ErrorAction = 'Stop'
        }
        if ($null -ne $Headers -and $Headers.Count -gt 0) {
            $restParams['Headers'] = $Headers
        }

        $response = Invoke-RestMethod @restParams

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Webhook sent to $Url ($Method)" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPWebhook' `
                -CorrelationID $CorrelationID
        }

        return @{
            Success    = $true
            StatusCode = 200
            Response   = $response
            Error      = $null
        }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and
            $null -ne $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }

        $errMsg = "Webhook call to $Url failed: $($_.Exception.Message)"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $errMsg `
                -Severity ERROR -Component 'SP.AuditReport' -Action 'Send-SPWebhook' `
                -CorrelationID $CorrelationID
        }

        return @{
            Success    = $false
            StatusCode = $statusCode
            Response   = $null
            Error      = $errMsg
        }
    }
}

function Send-SPNotification {
    <#
    .SYNOPSIS
        Dispatches notifications via configured backends (Log, Smtp, Webhook).
    .DESCRIPTION
        Reads the Notification config section and delivers the message through
        each active backend. The Log backend always runs. Smtp sends email via
        Send-MailMessage. Webhook sends a JSON POST via Send-SPWebhook.

        Missing or incomplete backend configuration produces a WARN log and
        skips that backend (does not throw).
    .PARAMETER Subject
        Notification subject line.
    .PARAMETER Body
        Notification body content. For SMTP this is sent as HTML.
    .PARAMETER Severity
        Severity level: Info, Warning, or Critical. Maps to log severity and
        is included in webhook payloads.
    .PARAMETER Category
        Notification category (e.g. HealthAlert, Escalation, Completion, Digest).
    .PARAMETER Recipients
        Email addresses for the SMTP backend.
    .PARAMETER Attachments
        File paths to attach (SMTP only). Non-existent files are skipped with WARN.
    .PARAMETER Metadata
        Extra fields included in the webhook JSON payload.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Backends=@(...) } }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Body,

        [Parameter()]
        [ValidateSet('Info','Warning','Critical')]
        [string]$Severity = 'Info',

        [Parameter()]
        [string]$Category,

        [Parameter()]
        [string[]]$Recipients,

        [Parameter()]
        [string[]]$Attachments,

        [Parameter()]
        [hashtable]$Metadata,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Load notification config
    $notifConfig = $null
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'Notification') {
            $notifConfig = $config.Notification
        }
    }
    catch {
        # Config unavailable -- fall back to Log only
    }

    # Determine active backends
    $backends = @('Log')
    if ($null -ne $notifConfig -and
        $notifConfig.PSObject.Properties.Name -contains 'Backends') {
        $configuredBackends = @($notifConfig.Backends)
        if ($configuredBackends.Count -gt 0) {
            $backends = $configuredBackends
        }
    }

    # Ensure Log is always present
    if ('Log' -notin $backends) {
        $backends = @('Log') + $backends
    }

    $backendResults = [System.Collections.Generic.List[hashtable]]::new()

    # Map severity to Write-SPLog severity
    $logSeverity = switch ($Severity) {
        'Critical' { 'ERROR' }
        'Warning'  { 'WARN'  }
        default    { 'INFO'  }
    }

    # --- Log backend (always) ---
    $logMsg = "[$Severity] $Subject -- $Body"
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $logMsg = "[$Severity][$Category] $Subject -- $Body"
    }
    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message $logMsg `
            -Severity $logSeverity -Component 'SP.AuditReport' -Action 'Send-SPNotification' `
            -CorrelationID $CorrelationID
    }
    $backendResults.Add(@{ Backend = 'Log'; Status = 'Sent' })

    # --- SMTP backend ---
    if ('Smtp' -in $backends) {
        $smtpResult = @{ Backend = 'Smtp'; Status = 'Skipped' }

        # Read SMTP settings from Notification.Smtp config
        $smtpConf = $null
        if ($null -ne $notifConfig -and
            $notifConfig.PSObject.Properties.Name -contains 'Smtp') {
            $smtpConf = $notifConfig.Smtp
        }

        $smtpServer = ''
        $smtpPort   = 587
        $smtpFrom   = ''
        $smtpUseSsl = $true

        if ($null -ne $smtpConf) {
            if ($smtpConf.PSObject.Properties.Name -contains 'Server') { $smtpServer = $smtpConf.Server }
            if ($smtpConf.PSObject.Properties.Name -contains 'Port')   { $smtpPort   = $smtpConf.Port }
            if ($smtpConf.PSObject.Properties.Name -contains 'From')   { $smtpFrom   = $smtpConf.From }
            if ($smtpConf.PSObject.Properties.Name -contains 'UseSsl') { $smtpUseSsl = $smtpConf.UseSsl -eq $true }
        }

        if ([string]::IsNullOrWhiteSpace($smtpServer) -or [string]::IsNullOrWhiteSpace($smtpFrom)) {
            $warnMsg = 'SMTP backend configured but Server or From is empty -- skipping SMTP delivery'
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                    -Action 'Send-SPNotification' -CorrelationID $CorrelationID
            }
        }
        elseif ($null -eq $Recipients -or $Recipients.Count -eq 0) {
            $warnMsg = 'SMTP backend configured but no Recipients provided -- skipping SMTP delivery'
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                    -Action 'Send-SPNotification' -CorrelationID $CorrelationID
            }
        }
        else {
            # Validate attachments
            $validAttachments = @()
            if ($null -ne $Attachments -and $Attachments.Count -gt 0) {
                foreach ($att in $Attachments) {
                    if (Test-Path -Path $att -PathType Leaf) {
                        $validAttachments += $att
                    }
                    else {
                        $attWarn = "Attachment not found, skipping: $att"
                        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                            Write-SPLog -Message $attWarn -Severity WARN -Component 'SP.AuditReport' `
                                -Action 'Send-SPNotification' -CorrelationID $CorrelationID
                        }
                    }
                }
            }

            try {
                $mailParams = @{
                    SmtpServer = $smtpServer
                    Port       = $smtpPort
                    From       = $smtpFrom
                    To         = $Recipients
                    Subject    = $Subject
                    Body       = $Body
                    BodyAsHtml = $true
                    UseSsl     = $smtpUseSsl
                    ErrorAction = 'Stop'
                    WarningAction = 'SilentlyContinue'
                }
                if ($validAttachments.Count -gt 0) {
                    $mailParams['Attachments'] = $validAttachments
                }

                Send-MailMessage @mailParams
                $smtpResult['Status'] = 'Sent'

                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message "SMTP notification sent to $($Recipients -join ', ')" `
                        -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPNotification' `
                        -CorrelationID $CorrelationID
                }
            }
            catch {
                $smtpResult['Status'] = 'Failed'
                $smtpResult['Error']  = $_.Exception.Message
                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message "SMTP send failed: $($_.Exception.Message)" `
                        -Severity ERROR -Component 'SP.AuditReport' -Action 'Send-SPNotification' `
                        -CorrelationID $CorrelationID
                }
            }
        }

        $backendResults.Add($smtpResult)
    }

    # --- Webhook backend ---
    if ('Webhook' -in $backends) {
        $webhookResult = @{ Backend = 'Webhook'; Status = 'Skipped' }

        $webhookConf = $null
        if ($null -ne $notifConfig -and
            $notifConfig.PSObject.Properties.Name -contains 'Webhook') {
            $webhookConf = $notifConfig.Webhook
        }

        $webhookUrl     = ''
        $webhookMethod  = 'POST'
        $webhookHeaders = @{}
        $includePayload = $true

        if ($null -ne $webhookConf) {
            if ($webhookConf.PSObject.Properties.Name -contains 'Url')            { $webhookUrl     = $webhookConf.Url }
            if ($webhookConf.PSObject.Properties.Name -contains 'Method')         { $webhookMethod  = $webhookConf.Method }
            if ($webhookConf.PSObject.Properties.Name -contains 'IncludePayload') { $includePayload = $webhookConf.IncludePayload -eq $true }
            if ($webhookConf.PSObject.Properties.Name -contains 'Headers' -and
                $null -ne $webhookConf.Headers) {
                # Convert PSCustomObject headers to hashtable
                $webhookHeaders = @{}
                foreach ($prop in $webhookConf.Headers.PSObject.Properties) {
                    $webhookHeaders[$prop.Name] = $prop.Value
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
            $warnMsg = 'Webhook backend configured but Url is empty -- skipping webhook delivery'
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                    -Action 'Send-SPNotification' -CorrelationID $CorrelationID
            }
        }
        else {
            $payload = @{
                timestamp = (Get-Date).ToUniversalTime().ToString('o')
                severity  = $Severity
                subject   = $Subject
            }
            if (-not [string]::IsNullOrWhiteSpace($Category)) {
                $payload['category'] = $Category
            }
            if ($includePayload) {
                $payload['body'] = $Body
            }
            if ($null -ne $Metadata -and $Metadata.Count -gt 0) {
                $payload['metadata'] = $Metadata
            }

            $whResult = Send-SPWebhook -Url $webhookUrl -Payload $payload `
                -Method $webhookMethod -Headers $webhookHeaders -CorrelationID $CorrelationID

            $webhookResult['Status']     = if ($whResult.Success) { 'Sent' } else { 'Failed' }
            $webhookResult['StatusCode'] = $whResult.StatusCode
            if (-not $whResult.Success) {
                $webhookResult['Error'] = $whResult.Error
            }
        }

        $backendResults.Add($webhookResult)
    }

    # Determine overall success -- true if at least one backend sent successfully
    $overallSuccess = ($backendResults | Where-Object { $_.Status -eq 'Sent' }).Count -gt 0

    return @{
        Success = $overallSuccess
        Data    = @{
            Backends = @($backendResults)
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Group-SPAuditDecisions',
    'Group-SPReviewerActions',
    'Group-SPAuditIdentityEvents',
    'Group-SPAuditRemediationProof',
    'Measure-SPAuditReviewerMetrics',
    'Measure-SPAuditRubberStampRisk',
    'Measure-SPCampaignMetrics',
    'Get-SPAuditRiskFlags',
    'Group-SPAuditByLeadership',
    'Export-SPAuditHtml',
    'Export-SPAuditText',
    'Export-SPAuditJsonl',
    'Export-SPLeadershipExecutiveHtml',
    'Export-SPLeadershipDirectorHtml',
    'Export-SPLeadershipLevelHtml',
    'Send-SPReport',
    'Compare-SPCampaigns',
    'Export-SPCampaignComparisonHtml',
    'Get-SPAuditTrail',
    'Export-SPAuditTrailHtml',
    'Export-SPAuditCsv',
    'Measure-SPCampaignTrends',
    'Export-SPCampaignTrendHtml',
    'Export-SPEntitlementInventoryHtml',
    'Measure-SPReviewerReputation',
    'Export-SPCompliancePackage',
    'Measure-SPIdentityRisk',
    'Export-SPIdentityRiskHtml',
    'Measure-SPSourceGovernance',
    'Export-SPSourceGovernanceHtml',
    'Export-SPStaleAccessHtml',
    'Export-SPCampaignCompletionReport',
    'Send-SPNotification',
    'Send-SPWebhook'
)
