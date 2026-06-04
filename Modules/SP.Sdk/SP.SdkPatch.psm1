#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - JSON Patch (RFC 6902) Utilities
.DESCRIPTION
    Builder functions for constructing JSON Patch operation arrays
    used by ISC PATCH endpoints (campaign templates, workflows).
    SailPoint ISC requires application/json-patch+json content type
    with an array of patch operations per RFC 6902.
.NOTES
    Module: SP.SdkPatch
    Version: 1.0.0
#>

function New-SPSdkPatchOp {
    <#
    .SYNOPSIS
        Creates a single RFC 6902 JSON Patch operation.
    .PARAMETER Op
        The patch operation: add, remove, replace, move, copy, test.
    .PARAMETER Path
        JSON Pointer path (e.g. '/name', '/description').
    .PARAMETER Value
        The value for the operation. Not required for 'remove'.
    .PARAMETER From
        Source path for 'move' and 'copy' operations.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] A single patch operation.
    .EXAMPLE
        New-SPSdkPatchOp -Op replace -Path '/name' -Value 'New Name'
    .EXAMPLE
        New-SPSdkPatchOp -Op remove -Path '/description'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('add', 'remove', 'replace', 'move', 'copy', 'test')]
        [string]$Op,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        $Value,

        [Parameter()]
        [string]$From,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Ensure path starts with /
    if (-not $Path.StartsWith('/')) {
        $Path = '/' + $Path
    }

    $operation = @{
        op   = $Op
        path = $Path
    }

    # Value is required for add, replace, test; optional for others
    if ($Op -in @('add', 'replace', 'test')) {
        if ($null -eq $Value -and $Op -ne 'test') {
            Write-Warning "New-SPSdkPatchOp: '$Op' operation on '$Path' has null value."
        }
        $operation['value'] = $Value
    }
    elseif ($PSBoundParameters.ContainsKey('Value')) {
        $operation['value'] = $Value
    }

    # From is required for move, copy
    if ($Op -in @('move', 'copy')) {
        if ([string]::IsNullOrWhiteSpace($From)) {
            throw "New-SPSdkPatchOp: '$Op' operation requires -From parameter."
        }
        if (-not $From.StartsWith('/')) {
            $From = '/' + $From
        }
        $operation['from'] = $From
    }

    Write-SPLog -Message "Built patch op: $Op $Path" `
        -Severity DEBUG -Component 'SP.SdkPatch' -Action 'New-SPSdkPatchOp' `
        -CorrelationID $CorrelationID

    return $operation
}

function New-SPSdkPatchReplace {
    <#
    .SYNOPSIS
        Shorthand for creating a JSON Patch 'replace' operation.
    .DESCRIPTION
        The most common patch operation. Equivalent to:
        New-SPSdkPatchOp -Op replace -Path $Path -Value $Value
    .PARAMETER Path
        JSON Pointer path (e.g. '/name', '/description').
    .PARAMETER Value
        The new value.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] A replace patch operation.
    .EXAMPLE
        New-SPSdkPatchReplace -Path '/name' -Value 'Updated Campaign Template'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        $Value,

        [Parameter()]
        [string]$CorrelationID
    )

    return New-SPSdkPatchOp -Op replace -Path $Path -Value $Value -CorrelationID $CorrelationID
}

function ConvertTo-SPSdkPatchBody {
    <#
    .SYNOPSIS
        Validates and wraps patch operations into an array suitable for API submission.
    .DESCRIPTION
        Ensures the operations are wrapped in @() to prevent PS 5.1 from unwrapping
        a single-element array. Validates each operation has required fields.
    .PARAMETER Operations
        One or more patch operation hashtables (from New-SPSdkPatchOp or New-SPSdkPatchReplace).
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [array] Array of patch operations ready for Invoke-SPApiRequest -Body.
    .EXAMPLE
        $ops = @(
            New-SPSdkPatchReplace -Path '/name' -Value 'New Name'
            New-SPSdkPatchReplace -Path '/description' -Value 'New Desc'
        )
        $body = ConvertTo-SPSdkPatchBody -Operations $ops
        Invoke-SPApiRequest -Method PATCH -Endpoint '/workflows/abc' -Body $body -ContentType 'application/json-patch+json'
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Operations,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Force array wrap
    $ops = @($Operations)

    if ($ops.Count -eq 0) {
        throw 'ConvertTo-SPSdkPatchBody: At least one patch operation is required.'
    }

    foreach ($op in $ops) {
        if ($null -eq $op) {
            throw 'ConvertTo-SPSdkPatchBody: Null operation in patch array.'
        }
        if (-not ($op -is [hashtable])) {
            throw "ConvertTo-SPSdkPatchBody: Operation must be a hashtable, got $($op.GetType().Name)."
        }
        if (-not $op.ContainsKey('op')) {
            throw 'ConvertTo-SPSdkPatchBody: Operation missing required "op" field.'
        }
        if (-not $op.ContainsKey('path')) {
            throw 'ConvertTo-SPSdkPatchBody: Operation missing required "path" field.'
        }
    }

    Write-SPLog -Message "Validated $($ops.Count) patch operation(s)" `
        -Severity DEBUG -Component 'SP.SdkPatch' -Action 'ConvertTo-SPSdkPatchBody' `
        -CorrelationID $CorrelationID

    # Return as array -- the comma operator prevents PS 5.1 from unwrapping
    # a single-element array when returned from a function.
    return ,$ops
}

Export-ModuleMember -Function @(
    'New-SPSdkPatchOp',
    'New-SPSdkPatchReplace',
    'ConvertTo-SPSdkPatchBody'
)
