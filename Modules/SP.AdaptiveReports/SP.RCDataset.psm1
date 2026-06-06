#Requires -Version 5.1
<#
.SYNOPSIS
    SP.RCDataset -- maps SailPoint ISC campaign-audit data into the RC report
    engine's GroupResults shape (see Modules/SP.ReportComponents + AR-03/AR-05 in
    docs/adaptive-reports-backlog.md).

.DESCRIPTION
    The RC components (SP.ReportComponents) are data-source-agnostic: they render a
    generic "groups containing members" shape:

        GroupResults[i] = @{ Data = @{ Domain; GroupName; MemberCount; IsNested;
            Skipped; Members = @( @{ DisplayName; SamAccountName; Email; Enabled } ) } }

    This module is the ONLY net-new logic in the adaptive-reports port: a PURE
    transform from the toolkit's existing campaign-audit objects (the same shape
    Get-SPIdentityAccessSpread consumes -- per-campaign hashtables with a
    .Decisions = @{ Approved; Revoked; Pending } bag, each item carrying
    IdentityId / IdentityName / SourceName / AccessName / Decision / RiskFlags)
    into GroupResults, pivoted by one of two human-ratified anchors:

      * Entitlement (primary): group = an entitlement/access (AccessName) on a
        source; members = the identities reviewed holding it. Yields entitlement
        inventory / top-N / privileged review / governance summary views.
      * Campaign (secondary): group = a certification campaign; members = the
        identities under it.

    Pure transform by design -- it takes pre-built audits (so it is fully unit-
    testable and uses only the campaign/cert/ARI endpoints already proven against
    the mock). Data acquisition (building the audits from the live API) is the
    caller's job (CLI/GUI), reusing the existing audit pipeline. A live entitlement
    *catalog* enrichment via Get-SPEntitlementInventory (/v3/entitlements) is a
    future add once the mock serves that endpoint (AR-07).
#>

# --- private: StrictMode-safe field accessor (hashtable OR PSCustomObject) ------
function script:Get-RCDField {
    param([object]$Obj, [string]$Name, [object]$Default = '')
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function script:Write-RCDLog {
    param([string]$Message, [string]$Severity = 'INFO', [string]$CorrelationID)
    # Log through SP.Core when present; stay silent/standalone for tests.
    if (Get-Command Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message $Message -Severity $Severity -Component 'SP.RCDataset' `
            -Action 'Build-SPRCDataset' -CorrelationID $CorrelationID
    }
}

# --- private: flatten audits -> decision records --------------------------------
function script:Get-RCDDecisionRecords {
    param([hashtable[]]$CampaignAudits)
    $records = New-Object System.Collections.Generic.List[hashtable]
    foreach ($audit in @($CampaignAudits)) {
        if ($null -eq $audit) { continue }
        $campaignName = [string](Get-RCDField $audit 'CampaignName' '')
        if ([string]::IsNullOrWhiteSpace($campaignName)) { $campaignName = [string](Get-RCDField $audit 'CampaignId' 'Campaign') }
        $decisions = Get-RCDField $audit 'Decisions' $null
        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @(Get-RCDField $decisions $category @())
            foreach ($item in $items) {
                if ($null -eq $item) { continue }
                $identityId = [string](Get-RCDField $item 'IdentityId' '')
                if ([string]::IsNullOrWhiteSpace($identityId)) { continue }
                $riskFlags = @(Get-RCDField $item 'RiskFlags' @())
                $isPriv = $false; $isDisabled = $false
                foreach ($f in $riskFlags) {
                    switch ([string]$f) {
                        'PRIVILEGED' { $isPriv = $true }
                        'DISABLED'   { $isDisabled = $true }
                        'INACTIVE'   { $isDisabled = $true }
                    }
                }
                $records.Add(@{
                    IdentityId   = $identityId
                    IdentityName = [string](Get-RCDField $item 'IdentityName' $identityId)
                    Email        = [string](Get-RCDField $item 'IdentityEmail' '')
                    SourceName   = [string](Get-RCDField $item 'SourceName' '')
                    AccessName   = [string](Get-RCDField $item 'AccessName' '')
                    CampaignName = $campaignName
                    Privileged   = $isPriv
                    Enabled      = (-not $isDisabled)
                })
            }
        }
    }
    return $records
}

# --- private: build one GroupResults entry from a set of records ----------------
function script:New-RCDGroup {
    param([string]$Domain, [string]$GroupName, [hashtable[]]$Records, [bool]$IsNested = $false)
    $seen = @{}
    $members = New-Object System.Collections.Generic.List[hashtable]
    foreach ($r in $Records) {
        $id = [string]$r['IdentityId']
        if ($seen.ContainsKey($id)) {
            # keep the strictest Enabled (disabled wins) if seen again
            if (-not $r['Enabled']) { ($members | Where-Object { $_['SamAccountName'] -eq $id })[0]['Enabled'] = $false }
            continue
        }
        $seen[$id] = $true
        $members.Add(@{
            DisplayName    = $r['IdentityName']
            SamAccountName = $id
            Email          = $r['Email']
            Enabled        = [bool]$r['Enabled']
        })
    }
    return @{
        Data = @{
            Domain      = $Domain
            GroupName   = $GroupName
            MemberCount = $members.Count
            IsNested    = $IsNested
            Skipped     = $false
            Members     = @($members)
        }
    }
}

function Build-SPRCDataset {
    <#
    .SYNOPSIS
        Pivots campaign-audit data into the RC GroupResults shape.
    .PARAMETER CampaignAudits
        Per-campaign audit hashtables (the Get-SPIdentityAccessSpread input shape:
        each with a .Decisions = @{ Approved; Revoked; Pending } bag of items
        carrying IdentityId/IdentityName/SourceName/AccessName/Decision/RiskFlags).
    .PARAMETER Anchor
        'Entitlement' (default) -> group = entitlement (AccessName) per source.
        'Campaign'              -> group = certification campaign.
    .PARAMETER CorrelationID
        Optional trace id (logged via SP.Core when available).
    .OUTPUTS
        [hashtable] @{ Success; Data = @{ GroupResults=@(...); StaleResults=@{Disabled;Stale} }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$CampaignAudits,
        [Parameter()][ValidateSet('Entitlement', 'Campaign')][string]$Anchor = 'Entitlement',
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) { $CorrelationID = [guid]::NewGuid().ToString() }

    try {
        $records = script:Get-RCDDecisionRecords -CampaignAudits $CampaignAudits
        script:Write-RCDLog -Message "Build-SPRCDataset: anchor=$Anchor, $($records.Count) decision record(s)" -CorrelationID $CorrelationID

        $groupResults = New-Object System.Collections.Generic.List[hashtable]
        $disabled = New-Object System.Collections.Generic.List[hashtable]

        if ($Anchor -eq 'Entitlement') {
            # Key by AccessName + SourceName (same entitlement name can exist per source).
            $buckets = [ordered]@{}
            foreach ($r in $records) {
                $access = [string]$r['AccessName']
                if ([string]::IsNullOrWhiteSpace($access)) { $access = '(unnamed access)' }
                $src = [string]$r['SourceName']; if ([string]::IsNullOrWhiteSpace($src)) { $src = '(unknown source)' }
                $key = $access + [char]0 + $src
                if (-not $buckets.Contains($key)) { $buckets[$key] = @{ Access = $access; Source = $src; Recs = (New-Object System.Collections.Generic.List[hashtable]) } }
                $buckets[$key].Recs.Add($r)
                if (-not $r['Enabled']) { $disabled.Add(@{ SamAccountName = $r['IdentityId']; DisplayName = $r['IdentityName'] }) }
            }
            foreach ($k in $buckets.Keys) {
                $b = $buckets[$k]
                $groupResults.Add((script:New-RCDGroup -Domain $b.Source -GroupName $b.Access -Records (@($b.Recs)) -IsNested:$false))
            }
        }
        else {
            # Campaign anchor: group = campaign; single synthetic domain.
            $buckets = [ordered]@{}
            foreach ($r in $records) {
                $camp = [string]$r['CampaignName']; if ([string]::IsNullOrWhiteSpace($camp)) { $camp = '(unnamed campaign)' }
                if (-not $buckets.Contains($camp)) { $buckets[$camp] = (New-Object System.Collections.Generic.List[hashtable]) }
                $buckets[$camp].Add($r)
                if (-not $r['Enabled']) { $disabled.Add(@{ SamAccountName = $r['IdentityId']; DisplayName = $r['IdentityName'] }) }
            }
            foreach ($camp in $buckets.Keys) {
                $groupResults.Add((script:New-RCDGroup -Domain 'ISC Campaigns' -GroupName $camp -Records (@($buckets[$camp])) -IsNested:$false))
            }
        }

        return @{
            Success = $true
            Data    = @{
                GroupResults = @($groupResults)
                StaleResults = @{ Disabled = @($disabled); Stale = @() }
            }
            Error   = $null
        }
    }
    catch {
        script:Write-RCDLog -Message "Build-SPRCDataset failed: $($_.Exception.Message)" -Severity ERROR -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @{ GroupResults = @(); StaleResults = @{ Disabled = @(); Stale = @() } }; Error = "Build-SPRCDataset failed: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function @('Build-SPRCDataset')
