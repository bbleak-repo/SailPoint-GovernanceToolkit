#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Campaign Template Management
.DESCRIPTION
    Wraps the ISC V3 campaign-templates and campaign-templates/{id}/schedule
    endpoints. Provides CRUD for campaign templates and schedule management.
    Parity with PSSailpoint SDK CertificationCampaignsApi campaign template functions.

    All HTTP calls are delegated to Invoke-SPApiRequest (SP.Api).
    PATCH operations use application/json-patch+json per RFC 6902.
.NOTES
    Module: SP.SdkCampaignTemplates
    Version: 1.0.0
    SDK Source: PSSailpoint/v3/src/PSSailpoint.V3/Api/CertificationCampaignsApi.ps1
#>

function Get-SPSdkCampaignTemplates {
    <#
    .SYNOPSIS
        Lists campaign templates with optional filtering and sorting.
    .DESCRIPTION
        GETs /campaign-templates with standard collection parameters.
        Supports filters on name and id fields.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression (e.g. 'name co "quarterly"').
    .PARAMETER Sorters
        Sort expression. Supported fields: name, created, modified.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$Sorters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit'  = $Limit.ToString()
        'offset' = $Offset.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }
    if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
        $queryParams['sorters'] = $Sorters
    }

    Write-SPLog -Message "Listing campaign templates: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkCampaignTemplates' -Action 'Get-SPSdkCampaignTemplates' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaign-templates' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) campaign templates" `
        -Severity DEBUG -Component 'SP.SdkCampaignTemplates' -Action 'Get-SPSdkCampaignTemplates' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkCampaignTemplate {
    <#
    .SYNOPSIS
        Gets a single campaign template by ID.
    .PARAMETER TemplateId
        The campaign template ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting campaign template: $TemplateId" `
        -Severity DEBUG -Component 'SP.SdkCampaignTemplates' -Action 'Get-SPSdkCampaignTemplate' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/campaign-templates/$TemplateId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function New-SPSdkCampaignTemplate {
    <#
    .SYNOPSIS
        Creates a new campaign template.
    .DESCRIPTION
        POSTs to /campaign-templates. The template body must include at minimum:
        name (string), description (string), campaign (hashtable with campaign definition).
        Optional: ownerRef, deadlineDuration (ISO-8601 e.g. 'P14D').
    .PARAMETER Template
        Hashtable with template properties. Required keys: name, description, campaign.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    .EXAMPLE
        $tmpl = @{
            name = 'Quarterly Manager Review'
            description = 'Standard quarterly manager certification'
            deadlineDuration = 'P14D'
            campaign = @{ type = 'MANAGER'; ... }
        }
        New-SPSdkCampaignTemplate -Template $tmpl
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Template,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $templateName = if ($Template.ContainsKey('name')) { $Template['name'] } else { '(unnamed)' }

    if (-not $PSCmdlet.ShouldProcess("Campaign template '$templateName'", 'Create')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Creating campaign template: '$templateName'" `
        -Severity INFO -Component 'SP.SdkCampaignTemplates' -Action 'New-SPSdkCampaignTemplate' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST -Endpoint '/campaign-templates' `
        -Body $Template -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Created campaign template: id=$($result.Data.id)" `
        -Severity INFO -Component 'SP.SdkCampaignTemplates' -Action 'New-SPSdkCampaignTemplate' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Update-SPSdkCampaignTemplate {
    <#
    .SYNOPSIS
        Updates a campaign template via JSON Patch (RFC 6902).
    .DESCRIPTION
        PATCHes /campaign-templates/{id} with application/json-patch+json.
        Patchable fields: name, description, deadlineDuration, campaign.
    .PARAMETER TemplateId
        The campaign template ID to update.
    .PARAMETER PatchOperations
        Array of patch operations (from New-SPSdkPatchOp or New-SPSdkPatchReplace).
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    .EXAMPLE
        $ops = @(New-SPSdkPatchReplace -Path '/name' -Value 'Updated Name')
        Update-SPSdkCampaignTemplate -TemplateId 'tmpl-123' -PatchOperations $ops
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateId,

        [Parameter(Mandatory)]
        $PatchOperations,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Campaign template '$TemplateId'", 'Patch')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    $body = ConvertTo-SPSdkPatchBody -Operations $PatchOperations

    Write-SPLog -Message "Patching campaign template '$TemplateId' ($($body.Count) operations)" `
        -Severity INFO -Component 'SP.SdkCampaignTemplates' -Action 'Update-SPSdkCampaignTemplate' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method PATCH -Endpoint "/campaign-templates/$TemplateId" `
        -Body $body -ContentType 'application/json-patch+json' -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Remove-SPSdkCampaignTemplate {
    <#
    .SYNOPSIS
        Deletes a campaign template.
    .PARAMETER TemplateId
        The campaign template ID to delete.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Campaign template '$TemplateId'", 'Delete')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Deleting campaign template: $TemplateId" `
        -Severity WARN -Component 'SP.SdkCampaignTemplates' -Action 'Remove-SPSdkCampaignTemplate' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method DELETE -Endpoint "/campaign-templates/$TemplateId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $null; Error = $null }
}

function Get-SPSdkTemplateSchedule {
    <#
    .SYNOPSIS
        Gets the schedule for a campaign template.
    .DESCRIPTION
        GETs /campaign-templates/{id}/schedule. Returns 404 if no schedule is set.
    .PARAMETER TemplateId
        The campaign template ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting schedule for template: $TemplateId" `
        -Severity DEBUG -Component 'SP.SdkCampaignTemplates' -Action 'Get-SPSdkTemplateSchedule' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/campaign-templates/$TemplateId/schedule" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        # 404 is expected when no schedule exists -- report as success with null data
        if ($result.StatusCode -eq 404) {
            return @{ Success = $true; Data = $null; Error = $null }
        }
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Set-SPSdkTemplateSchedule {
    <#
    .SYNOPSIS
        Sets (creates or overwrites) the schedule for a campaign template.
    .DESCRIPTION
        PUTs to /campaign-templates/{id}/schedule. Overwrites any existing schedule.
        Schedule type: WEEKLY, MONTHLY, ANNUALLY, or CALENDAR.
    .PARAMETER TemplateId
        The campaign template ID.
    .PARAMETER Schedule
        Schedule hashtable. Required keys: type, hours.
        Optional: months, days, expiration, timeZoneId.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    .EXAMPLE
        $schedule = @{
            type = 'MONTHLY'
            hours = @{ type = 'LIST'; values = @('9') }
            days  = @{ type = 'LIST'; values = @('1') }
        }
        Set-SPSdkTemplateSchedule -TemplateId 'tmpl-123' -Schedule $schedule
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateId,

        [Parameter(Mandatory)]
        [hashtable]$Schedule,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $schedType = if ($Schedule.ContainsKey('type')) { $Schedule['type'] } else { '(unspecified)' }

    if (-not $PSCmdlet.ShouldProcess("Schedule for template '$TemplateId' (type=$schedType)", 'Set')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Setting schedule for template '$TemplateId': type=$schedType" `
        -Severity INFO -Component 'SP.SdkCampaignTemplates' -Action 'Set-SPSdkTemplateSchedule' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method PUT -Endpoint "/campaign-templates/$TemplateId/schedule" `
        -Body $Schedule -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $null; Error = $null }
}

function Remove-SPSdkTemplateSchedule {
    <#
    .SYNOPSIS
        Removes the schedule from a campaign template.
    .PARAMETER TemplateId
        The campaign template ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Schedule for template '$TemplateId'", 'Remove')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Removing schedule for template: $TemplateId" `
        -Severity WARN -Component 'SP.SdkCampaignTemplates' -Action 'Remove-SPSdkTemplateSchedule' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method DELETE -Endpoint "/campaign-templates/$TemplateId/schedule" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        if ($result.StatusCode -eq 404) {
            return @{ Success = $true; Data = $null; Error = $null }
        }
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $null; Error = $null }
}

Export-ModuleMember -Function @(
    'Get-SPSdkCampaignTemplates',
    'Get-SPSdkCampaignTemplate',
    'New-SPSdkCampaignTemplate',
    'Update-SPSdkCampaignTemplate',
    'Remove-SPSdkCampaignTemplate',
    'Get-SPSdkTemplateSchedule',
    'Set-SPSdkTemplateSchedule',
    'Remove-SPSdkTemplateSchedule'
)
