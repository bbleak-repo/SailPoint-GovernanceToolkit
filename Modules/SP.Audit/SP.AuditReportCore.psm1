#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Core Categorization and Metrics
.DESCRIPTION
    Provides core grouping, decision categorization, and reviewer metric
    functions for campaign audit data. These are pure data-transform functions
    that consume structured output from SP.AuditQueries and produce enriched
    data structures suitable for downstream reporting or comparison.

    No output files are produced by this module. All functions return
    hashtables or PSCustomObject arrays.
.NOTES
    Module: SP.Audit / SP.AuditReportCore
    Version: 1.0.0
    Component: Core Categorization and Metrics

    Color taxonomy:
        Green  #339933 - Approved / success
        Red    #CC3333 - Revoked / error
        Orange #FF8800 - Pending / warn
        Blue   #336699 - Info / neutral
        Gray   #777777 - N/A / footer
#>

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

        # Source/Application name + id
        $sourceName = ''
        $sourceId   = ''
        if ($null -ne $rawItem.access -and
            $null -ne $rawItem.access.PSObject.Properties['source'] -and
            $null -ne $rawItem.access.source) {
            if ($null -ne $rawItem.access.source.PSObject.Properties['name'] -and $null -ne $rawItem.access.source.name) { $sourceName = [string]$rawItem.access.source.name }
            if ($null -ne $rawItem.access.source.PSObject.Properties['id']   -and $null -ne $rawItem.access.source.id)   { $sourceId   = [string]$rawItem.access.source.id }
        }
        # Access (entitlement/role/access-profile) id -- stable key component
        $accessId = ''
        if ($null -ne $rawItem.access -and $null -ne $rawItem.access.PSObject.Properties['id'] -and $null -ne $rawItem.access.id) {
            $accessId = [string]$rawItem.access.id
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

        # Decision and remediation status.
        # ISC returns 'decision' as a flat string ('APPROVE'/'REVOKE') on standard tenants.
        # Some ISC versions/tenants return past-tense ('APPROVED'/'REVOKED'), the value
        # 'CERTIFY' instead of 'APPROVE', or a nested object like {value:'APPROVE'}.
        # For ACTIVE certifications where the reviewer has not yet signed off, 'decision'
        # is null even if the manager clicked approve in the UI -- ISC only commits
        # item-level decisions to the API after the reviewer submits/signs the cert.
        $decision = ''
        if ($null -ne $rawItem.PSObject.Properties['decision'] -and $null -ne $rawItem.decision) {
            $rawDecision = $rawItem.decision
            if ($rawDecision -is [string]) {
                $decision = $rawDecision
            }
            else {
                # Nested object: try common property names for the decision value
                foreach ($prop in @('value', 'decision', 'type', 'name')) {
                    if ($null -ne $rawDecision.PSObject.Properties[$prop] -and
                        -not [string]::IsNullOrWhiteSpace([string]$rawDecision.$prop)) {
                        $decision = [string]$rawDecision.$prop
                        break
                    }
                }
            }
        }
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
            AccessId               = $accessId
            AccessType             = if ($null -ne $rawItem.access -and $null -ne $rawItem.access.type)                   { $rawItem.access.type }           else { '' }
            Privileged             = if ($null -ne $rawItem.access -and $null -ne $rawItem.access.privileged)             { [bool]$rawItem.access.privileged } else { $false }
            SourceName             = $sourceName
            SourceId               = $sourceId
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

        # Normalise decision variants to the three canonical buckets.
        # APPROVE / APPROVED / CERTIFY  → Approved  (CERTIFY used by some ISC versions)
        # REVOKE  / REVOKED  / DENY / REJECT / EXCEPTION → Revoked
        # anything else (null/empty)    → Pending
        switch ($decision.ToUpperInvariant()) {
            'APPROVE'   { $approved.Add($out) }
            'APPROVED'  { $approved.Add($out) }
            'CERTIFY'   { $approved.Add($out) }
            'REVOKE'    { $revoked.Add($out)  }
            'REVOKED'   { $revoked.Add($out)  }
            'DENY'      { $revoked.Add($out)  }
            'REJECT'    { $revoked.Add($out)  }
            'EXCEPTION' { $revoked.Add($out)  }
            default     { $pending.Add($out)  }
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

    # Labels assigned by ABSOLUTE level (distance up from individual contributors
    # at level 0), matching Build-SPOrgTree's canonical org-tree labels so the same
    # tree is labeled identically wherever it is rendered. Levels above the known
    # set fall back to the top label.
    $absoluteLabels = @{
        0 = 'Individual Contributors'
        1 = 'Managers'
        2 = 'Directors'
        3 = 'Vice Presidents'
        4 = 'Senior Vice Presidents'
        5 = 'Executive Leadership'
    }
    $levelLabels = @{}
    for ($lvl = 0; $lvl -le [Math]::Max($discoveredTopLevel, 5); $lvl++) {
        $levelLabels[$lvl] = if ($absoluteLabels.ContainsKey($lvl)) { $absoluteLabels[$lvl] } else { 'Executive Leadership' }
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

#region Campaign Metrics

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

            # Reviewer COUNT is always the number of certifications (one per reviewer),
            # regardless of whether any have signed off. Measure-SPAuditReviewerMetrics
            # only includes certs with a sign-off timestamp -- so for ACTIVE campaigns
            # (zero completions) it returns an empty set, which previously made
            # ReviewerCount = 0 even though reviewers ARE assigned.
            $reviewerCount = @($certs | Where-Object { $null -ne $_ }).Count

            if ($null -ne $reviewerMetrics.ReviewerMetrics -and $reviewerMetrics.ReviewerMetrics.Count -gt 0) {

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

#endregion

#region Hierarchical Leadership Rollup (P17-01)
# ---------------------------------------------------------------------------
# Module-scope recursive helper — not exported.
# Builds a HierarchyNode PSCustomObject bottom-up so each node carries
# aggregate decision counts from its entire descendant subtree.
# ---------------------------------------------------------------------------

function _Build-SPHierarchyNodeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]   $NodeId,
        [Parameter(Mandatory)][hashtable]$OrgNodes,      # OrgTree.Nodes dict
        [Parameter(Mandatory)][hashtable]$DecisionIndex  # reviewerId->reviewedId->entry
    )

    $treeNode = $OrgNodes[$NodeId]
    if ($null -eq $treeNode) { return $null }

    $identity = $treeNode.Identity
    $childIds  = @($treeNode.Children)

    # Recurse children first (bottom-up so aggregation flows upward)
    $childNodes = [System.Collections.Generic.List[object]]::new()
    foreach ($cid in $childIds) {
        $cn = _Build-SPHierarchyNodeInternal -NodeId $cid `
                  -OrgNodes $OrgNodes -DecisionIndex $DecisionIndex
        if ($null -ne $cn) { $childNodes.Add($cn) }
    }

    # Aggregate from child subtrees
    $agg = @{ Approved=0; Revoked=0; Pending=0; Total=0; Identities=0 }
    foreach ($child in $childNodes) {
        $agg.Approved   += $child.Agg.Approved
        $agg.Revoked    += $child.Agg.Revoked
        $agg.Pending    += $child.Agg.Pending
        $agg.Total      += $child.Agg.Total
        $agg.Identities += $child.Agg.Identities
    }

    # Direct decisions where THIS node was the certifier (reviewer)
    $certifiedIdentities = @()
    if ($DecisionIndex.ContainsKey($NodeId)) {
        $certMap  = $DecisionIndex[$NodeId]
        $certList = [System.Collections.Generic.List[object]]::new()
        foreach ($reviewedId in @($certMap.Keys)) {
            $entry = $certMap[$reviewedId]
            $agg.Approved   += $entry.Approved
            $agg.Revoked    += $entry.Revoked
            $agg.Pending    += $entry.Pending
            $agg.Total      += ($entry.Approved + $entry.Revoked + $entry.Pending)
            $agg.Identities += 1
            $certList.Add([PSCustomObject]@{
                IdentityId = $reviewedId
                Name       = $entry.Name
                Approved   = $entry.Approved
                Revoked    = $entry.Revoked
                Pending    = $entry.Pending
                Items      = @($entry.Items)
            })
        }
        # Sort by name for consistent output
        $certifiedIdentities = @($certList | Sort-Object Name)
    }

    # Prefer the resolved name whenever we have one -- even if the identity's own lookup
    # was not "Found". A name propagated from a child's manager.name (Build-SPOrgTree) still
    # beats a raw identity GUID for a leadership node's display/filename.
    $displayName = if ($null -ne $identity -and -not [string]::IsNullOrWhiteSpace($identity.Name)) {
        $identity.Name
    }
    else { $NodeId }

    return [PSCustomObject]@{
        NodeId              = $NodeId
        DisplayName         = $displayName
        Level               = [int]$treeNode.Level
        Children            = $childNodes.ToArray()
        CertifiedIdentities = $certifiedIdentities
        IsCertifier         = ($certifiedIdentities.Count -gt 0)
        Agg                 = $agg
    }
}

function Build-SPLeadershipHierarchy {
    <#
    .SYNOPSIS
        Builds a hierarchical org-tree enriched with certification decision statistics.
    .DESCRIPTION
        Joins certification decision data (from Group-SPAuditDecisions) to the org tree
        (from Build-SPOrgTree) to produce a recursive tree structure where each node
        carries aggregated decision counts (Approved, Revoked, Pending) from its entire
        descendant subtree.

        The join uses CertReviewerIdMap to go from CertificationId (present in every
        decision item) → reviewer identity ID → org tree node.  Build this map from
        Get-SPAuditCertifications output:

            $certReviewerIdMap = @{}
            foreach ($cert in $allCerts) {
                if ($cert.certifier -and $cert.certifier.id) {
                    $certReviewerIdMap[[string]$cert.id] = [string]$cert.certifier.id
                }
            }

        The resulting HierarchyNode tree is consumed by Export-SPHierarchicalLeadershipHtml
        to produce per-leader HTML reports with collapsible drill-down.

    .PARAMETER Decisions
        Output of Group-SPAuditDecisions: @{Approved=@(...); Revoked=@(...); Pending=@(...)}
        Each item must have CertificationId, IdentityId, IdentityName fields.
    .PARAMETER OrgTree
        The .Data property from Build-SPOrgTree output.
        Must have: Nodes (hashtable), TopLeaders (string[]).
    .PARAMETER CertReviewerIdMap
        Hashtable mapping certificationId (string) → reviewerIdentityId (string).
        Built from Get-SPAuditCertifications output (cert.id → cert.certifier.id).
        Without this, decisions cannot be attributed to specific org tree nodes.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                TopNodes  = [PSCustomObject[]]  # one per TopLeader in OrgTree
                NodeCount = [int]
            }
            Error   = $string
        }
        Each HierarchyNode (PSCustomObject): NodeId, DisplayName, Level,
        Children (nested HierarchyNodes), CertifiedIdentities (only for leaf certifiers),
        IsCertifier ($bool), Agg (@{Approved;Revoked;Pending;Total;Identities}).
    .EXAMPLE
        # Step 1: collect raw data
        $certs = @($campaigns | ForEach-Object { (Get-SPAuditCertifications -CampaignId $_.id).Data })
        $items = @($certs | ForEach-Object { (Get-SPAuditCertificationItems -CertificationId $_.id).Data })

        # Step 2: build reviewer ID map (certId -> reviewerIdentityId)
        $certReviewerIdMap = @{}
        foreach ($cert in $certs) {
            if ($cert.certifier -and $cert.certifier.id) {
                $certReviewerIdMap[[string]$cert.id] = [string]$cert.certifier.id
            }
        }

        # Step 3: group decisions and build org tree
        $decisions = Group-SPAuditDecisions -Items $items
        $certifierIds = @($certReviewerIdMap.Values | Select-Object -Unique)
        $orgTree = (Build-SPOrgTree -IdentityIds $certifierIds -MaxDepth 5).Data

        # Step 4: build hierarchy
        $hierarchy = Build-SPLeadershipHierarchy -Decisions $decisions `
            -OrgTree $orgTree -CertReviewerIdMap $certReviewerIdMap

        # Step 5: generate HTML
        Export-SPHierarchicalLeadershipHtml -HierarchyData $hierarchy.Data `
            -OutputPath '.\Reports' -ReportTitle 'Q1 Access Review Rollup'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Decisions,

        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter()]
        [hashtable]$CertReviewerIdMap = @{},

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Build-SPLeadershipHierarchy: building decision index" `
        -Severity INFO -Component 'SP.AuditReportCore' -Action 'Build-SPLeadershipHierarchy' `
        -CorrelationID $CorrelationID

    try {
        # -----------------------------------------------------------------------
        # Step 1: Index decisions by reviewer identity ID
        #   Join path: decision.CertificationId
        #              → CertReviewerIdMap[certId] = reviewerIdentityId
        #              → DecisionIndex[reviewerIdentityId][reviewedIdentityId]
        # -----------------------------------------------------------------------
        $decisionIndex = @{}   # reviewerId → reviewedId → @{Name;Items;Approved;Revoked;Pending}

        $allBuckets = @(
            @{ Items = @($Decisions.Approved); Bucket = 'Approved' }
            @{ Items = @($Decisions.Revoked);  Bucket = 'Revoked'  }
            @{ Items = @($Decisions.Pending);  Bucket = 'Pending'  }
        )

        foreach ($bucket in $allBuckets) {
            $bucketName = $bucket.Bucket
            foreach ($item in $bucket.Items) {
                if ($null -eq $item) { continue }

                $certId = if ($null -ne $item.PSObject.Properties['CertificationId']) {
                    [string]$item.CertificationId
                } else { '' }

                if ([string]::IsNullOrWhiteSpace($certId)) { continue }

                $reviewerId = ''
                if ($CertReviewerIdMap.ContainsKey($certId)) {
                    $reviewerId = [string]$CertReviewerIdMap[$certId]
                }
                if ([string]::IsNullOrWhiteSpace($reviewerId)) { continue }

                $reviewedId   = [string]$item.IdentityId
                $reviewedName = [string]$item.IdentityName

                if (-not $decisionIndex.ContainsKey($reviewerId)) {
                    $decisionIndex[$reviewerId] = @{}
                }
                if (-not $decisionIndex[$reviewerId].ContainsKey($reviewedId)) {
                    $decisionIndex[$reviewerId][$reviewedId] = @{
                        Name     = $reviewedName
                        Items    = [System.Collections.Generic.List[object]]::new()
                        Approved = 0
                        Revoked  = 0
                        Pending  = 0
                    }
                }

                $entry = $decisionIndex[$reviewerId][$reviewedId]
                $entry.Items.Add($item)
                switch ($bucketName) {
                    'Approved' { $entry.Approved++ }
                    'Revoked'  { $entry.Revoked++  }
                    'Pending'  { $entry.Pending++  }
                }
            }
        }

        $indexedReviewers  = $decisionIndex.Keys.Count
        $indexedDecisions  = ($decisionIndex.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        Write-SPLog -Message "Build-SPLeadershipHierarchy: indexed $indexedDecisions reviewed identities under $indexedReviewers reviewers" `
            -Severity INFO -Component 'SP.AuditReportCore' -Action 'Build-SPLeadershipHierarchy' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------------------
        # Step 2: Walk org tree top-down, building HierarchyNodes with bottom-up
        #         aggregation (children computed before parents via recursion)
        # -----------------------------------------------------------------------
        $orgNodes = $OrgTree.Nodes
        $topLeaders = @($OrgTree.TopLeaders)

        $topNodes = [System.Collections.Generic.List[object]]::new()
        foreach ($topId in $topLeaders) {
            $node = _Build-SPHierarchyNodeInternal -NodeId $topId `
                        -OrgNodes $orgNodes -DecisionIndex $decisionIndex
            if ($null -ne $node) { $topNodes.Add($node) }
        }

        Write-SPLog -Message "Build-SPLeadershipHierarchy: built hierarchy with $($topNodes.Count) top-level node(s)" `
            -Severity INFO -Component 'SP.AuditReportCore' -Action 'Build-SPLeadershipHierarchy' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                TopNodes  = $topNodes.ToArray()
                NodeCount = $orgNodes.Count
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Build-SPLeadershipHierarchy failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditReportCore' `
            -Action 'Build-SPLeadershipHierarchy' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion Hierarchical Leadership Rollup

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
    'Build-SPLeadershipHierarchy'
)
