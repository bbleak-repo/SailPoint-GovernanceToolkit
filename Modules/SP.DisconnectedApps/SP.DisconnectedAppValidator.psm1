#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App CSV Validator
.DESCRIPTION
    Provides validation functions that check CSV files against the disconnected
    application template schema before processing. Validates account files,
    entitlement files, and cross-references between the two.

    Functions:
        1. Test-SPDisconnectedAppAccountFile     - validates account CSV structure and data
        2. Test-SPDisconnectedAppEntitlementFile  - validates entitlement CSV structure and data
        3. Test-SPDisconnectedAppCrossReference   - cross-validates groups vs entitlements

.NOTES
    Module: SP.DisconnectedAppValidator
    Version: 1.0.0
#>

#region Constants

$script:RequiredAccountColumns = @('id', 'name', 'givenName', 'familyName', 'e-mail', 'groups', 'IIQDisabled')
$script:RequiredEntitlementColumns = @('id', 'name', 'displayName', 'description')
$script:MaxDescriptionLength = 2000
$script:MaxIdLength = 128

#endregion

#region Internal Functions

function Test-SPFileIsUtf8 {
    <#
    .SYNOPSIS
        Checks if a file is valid UTF-8 encoded (with or without BOM).
    .PARAMETER FilePath
        Path to the file to check.
    .OUTPUTS
        [bool] True if the file is valid UTF-8.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)

        # Check for UTF-8 BOM (EF BB BF) - valid UTF-8
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return $true
        }

        # Check for UTF-16 LE BOM (FF FE) - not UTF-8
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return $false
        }

        # Check for UTF-16 BE BOM (FE FF) - not UTF-8
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            return $false
        }

        # Try to decode as UTF-8 strictly
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $null = $utf8.GetString($bytes)
        return $true
    }
    catch {
        return $false
    }
}

function Get-SPCsvColumnsFromHeader {
    <#
    .SYNOPSIS
        Reads just the header row of a CSV and returns column names.
    .PARAMETER FilePath
        Path to the CSV file.
    .OUTPUTS
        [string[]] Array of column names.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $headerLine = Get-Content -Path $FilePath -TotalCount 1 -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        return @()
    }

    # Parse header using Import-Csv to handle quoted column names correctly
    $row = $headerLine | ConvertFrom-Csv
    if ($null -eq $row) {
        return @()
    }
    return @($row.PSObject.Properties.Name)
}

#endregion

#region Public Functions

function Test-SPDisconnectedAppAccountFile {
    <#
    .SYNOPSIS
        Validates a disconnected application account CSV file against the template schema.
    .DESCRIPTION
        Performs structural and data validation on an account CSV file:
        - File existence and UTF-8 encoding
        - Required columns present
        - No empty id values
        - No duplicate id values
        - id length within limit (128 chars)
        - IIQDisabled is 'true' or 'false'
        - e-mail contains '@'
        - File is sorted by id column
    .PARAMETER FilePath
        Path to the account CSV file to validate.
    .OUTPUTS
        [hashtable] @{Success; Data=@{RowCount; ValidRows; InvalidRows; Errors; Warnings}; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $validRows   = 0
    $invalidRows = 0

    # --- File existence ---
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        return @{
            Success = $false
            Data    = $null
            Error   = "Account file not found: $FilePath"
        }
    }

    # --- UTF-8 encoding ---
    if (-not (Test-SPFileIsUtf8 -FilePath $FilePath)) {
        $errors.Add("File is not UTF-8 encoded. Re-save with UTF-8 encoding.")
    }

    # --- Read CSV ---
    try {
        $rows = @(Import-Csv -Path $FilePath -Encoding UTF8)
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to parse CSV: $($_.Exception.Message)"
        }
    }

    if ($rows.Count -eq 0) {
        $errors.Add("Account file is empty (no data rows).")
        return @{
            Success = $false
            Data    = @{
                RowCount    = 0
                ValidRows   = 0
                InvalidRows = 0
                Errors      = $errors.ToArray()
                Warnings    = $warnings.ToArray()
            }
            Error   = $errors -join '; '
        }
    }

    # --- Required columns ---
    $actualColumns = @($rows[0].PSObject.Properties.Name)
    $missingColumns = @($script:RequiredAccountColumns | Where-Object { $_ -notin $actualColumns })
    if ($missingColumns.Count -gt 0) {
        $errors.Add("Missing required columns: $($missingColumns -join ', ')")
    }

    # If critical columns are missing, return early (can't validate rows)
    $hasId         = 'id' -in $actualColumns
    $hasEmail      = 'e-mail' -in $actualColumns
    $hasIIQDisabled = 'IIQDisabled' -in $actualColumns

    if (-not $hasId) {
        return @{
            Success = $false
            Data    = @{
                RowCount    = $rows.Count
                ValidRows   = 0
                InvalidRows = $rows.Count
                Errors      = $errors.ToArray()
                Warnings    = $warnings.ToArray()
            }
            Error   = $errors -join '; '
        }
    }

    # --- Row-level validation ---
    $seenIds   = @{}
    $previousId = $null

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $rowNum = $i + 2  # +2 for 1-based + header row
        $rowValid = $true

        # Empty id
        $id = $row.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $errors.Add("Row ${rowNum}: empty 'id' value.")
            $rowValid = $false
        }
        else {
            # Duplicate id
            if ($seenIds.ContainsKey($id)) {
                $errors.Add("Row ${rowNum}: duplicate 'id' value '$id' (first seen row $($seenIds[$id])).")
                $rowValid = $false
            }
            else {
                $seenIds[$id] = $rowNum
            }

            # Id length
            if ($id.Length -gt $script:MaxIdLength) {
                $errors.Add("Row ${rowNum}: 'id' value '$id' exceeds $($script:MaxIdLength) character limit.")
                $rowValid = $false
            }

            # Sort order check
            if ($null -ne $previousId -and [string]::Compare($id, $previousId, [System.StringComparison]::Ordinal) -lt 0) {
                $warnings.Add("Row ${rowNum}: file is not sorted by 'id' ('$id' comes after '$previousId').")
            }
            $previousId = $id
        }

        # IIQDisabled validation
        if ($hasIIQDisabled) {
            $disabled = $row.IIQDisabled
            if (-not [string]::IsNullOrWhiteSpace($disabled)) {
                $disabledLower = $disabled.Trim().ToLower()
                if ($disabledLower -ne 'true' -and $disabledLower -ne 'false') {
                    $errors.Add("Row ${rowNum}: 'IIQDisabled' must be 'true' or 'false', got '$disabled'.")
                    $rowValid = $false
                }
            }
            else {
                $errors.Add("Row ${rowNum}: 'IIQDisabled' is empty (must be 'true' or 'false').")
                $rowValid = $false
            }
        }

        # Email validation
        if ($hasEmail) {
            $email = $row.'e-mail'
            if (-not [string]::IsNullOrWhiteSpace($email)) {
                if ($email -notmatch '@') {
                    $errors.Add("Row ${rowNum}: 'e-mail' value '$email' does not contain '@'.")
                    $rowValid = $false
                }
            }
            else {
                $warnings.Add("Row ${rowNum}: 'e-mail' is empty.")
            }
        }

        if ($rowValid) { $validRows++ } else { $invalidRows++ }
    }

    $success = ($errors.Count -eq 0)
    return @{
        Success = $success
        Data    = @{
            RowCount    = $rows.Count
            ValidRows   = $validRows
            InvalidRows = $invalidRows
            Errors      = $errors.ToArray()
            Warnings    = $warnings.ToArray()
        }
        Error   = if ($success) { $null } else { $errors -join '; ' }
    }
}

function Test-SPDisconnectedAppEntitlementFile {
    <#
    .SYNOPSIS
        Validates a disconnected application entitlement CSV file against the template schema.
    .DESCRIPTION
        Performs structural and data validation on an entitlement CSV file:
        - File existence and UTF-8 encoding
        - Required columns present (id, name, displayName, description)
        - No duplicate id values
        - Description length within limit (2000 chars)
        - No emoji or '+' characters in name values
    .PARAMETER FilePath
        Path to the entitlement CSV file to validate.
    .OUTPUTS
        [hashtable] @{Success; Data=@{RowCount; ValidRows; InvalidRows; Errors; Warnings}; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $validRows   = 0
    $invalidRows = 0

    # --- File existence ---
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        return @{
            Success = $false
            Data    = $null
            Error   = "Entitlement file not found: $FilePath"
        }
    }

    # --- UTF-8 encoding ---
    if (-not (Test-SPFileIsUtf8 -FilePath $FilePath)) {
        $errors.Add("File is not UTF-8 encoded. Re-save with UTF-8 encoding.")
    }

    # --- Read CSV ---
    try {
        $rows = @(Import-Csv -Path $FilePath -Encoding UTF8)
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to parse CSV: $($_.Exception.Message)"
        }
    }

    if ($rows.Count -eq 0) {
        $errors.Add("Entitlement file is empty (no data rows).")
        return @{
            Success = $false
            Data    = @{
                RowCount    = 0
                ValidRows   = 0
                InvalidRows = 0
                Errors      = $errors.ToArray()
                Warnings    = $warnings.ToArray()
            }
            Error   = $errors -join '; '
        }
    }

    # --- Required columns ---
    $actualColumns = @($rows[0].PSObject.Properties.Name)
    $missingColumns = @($script:RequiredEntitlementColumns | Where-Object { $_ -notin $actualColumns })
    if ($missingColumns.Count -gt 0) {
        $errors.Add("Missing required columns: $($missingColumns -join ', ')")
    }

    $hasId          = 'id' -in $actualColumns
    $hasName        = 'name' -in $actualColumns
    $hasDescription = 'description' -in $actualColumns

    if (-not $hasId) {
        return @{
            Success = $false
            Data    = @{
                RowCount    = $rows.Count
                ValidRows   = 0
                InvalidRows = $rows.Count
                Errors      = $errors.ToArray()
                Warnings    = $warnings.ToArray()
            }
            Error   = $errors -join '; '
        }
    }

    # --- Row-level validation ---
    $seenIds = @{}

    # Emoji/special char detection: check for characters outside ASCII printable + common
    # Latin Extended range. Entitlement names should be alphanumeric with hyphens/underscores.
    # .NET regex: BMP emoji ranges (Dingbats, Misc Symbols, variation selectors)
    $emojiPattern = '[\u2600-\u27BF\uFE00-\uFE0F\u200D\u20E3]'

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $rowNum = $i + 2
        $rowValid = $true

        # Empty id
        $id = $row.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $errors.Add("Row ${rowNum}: empty 'id' value.")
            $rowValid = $false
        }
        else {
            # Duplicate id
            if ($seenIds.ContainsKey($id)) {
                $errors.Add("Row ${rowNum}: duplicate 'id' value '$id' (first seen row $($seenIds[$id])).")
                $rowValid = $false
            }
            else {
                $seenIds[$id] = $rowNum
            }
        }

        # Name validation: no '+' or emoji
        if ($hasName) {
            $nameVal = $row.name
            if (-not [string]::IsNullOrWhiteSpace($nameVal)) {
                if ($nameVal -match '\+') {
                    $errors.Add("Row ${rowNum}: 'name' value '$nameVal' contains '+' character.")
                    $rowValid = $false
                }
                if ($nameVal -match $emojiPattern) {
                    $errors.Add("Row ${rowNum}: 'name' value contains emoji or special Unicode characters.")
                    $rowValid = $false
                }
                # Check for astral plane characters (surrogate pairs - emoji above U+FFFF)
                foreach ($ch in $nameVal.ToCharArray()) {
                    if ([char]::IsHighSurrogate($ch)) {
                        $errors.Add("Row ${rowNum}: 'name' value contains emoji or special Unicode characters.")
                        $rowValid = $false
                        break
                    }
                }
            }
        }

        # Description length
        if ($hasDescription) {
            $desc = $row.description
            if (-not [string]::IsNullOrWhiteSpace($desc) -and $desc.Length -gt $script:MaxDescriptionLength) {
                $errors.Add("Row ${rowNum}: 'description' exceeds $($script:MaxDescriptionLength) character limit ($($desc.Length) chars).")
                $rowValid = $false
            }
        }

        if ($rowValid) { $validRows++ } else { $invalidRows++ }
    }

    $success = ($errors.Count -eq 0)
    return @{
        Success = $success
        Data    = @{
            RowCount    = $rows.Count
            ValidRows   = $validRows
            InvalidRows = $invalidRows
            Errors      = $errors.ToArray()
            Warnings    = $warnings.ToArray()
        }
        Error   = if ($success) { $null } else { $errors -join '; ' }
    }
}

function Test-SPDisconnectedAppCrossReference {
    <#
    .SYNOPSIS
        Cross-validates account groups against the entitlement file.
    .DESCRIPTION
        Checks that every entitlement ID referenced in the accounts 'groups' column
        exists in the entitlements file. Also flags orphaned entitlements (defined in
        the entitlement file but not referenced by any account).
    .PARAMETER AccountFilePath
        Path to the account CSV file.
    .PARAMETER EntitlementFilePath
        Path to the entitlement CSV file.
    .OUTPUTS
        [hashtable] @{Success; Data=@{UnmatchedGroups; OrphanedEntitlements}; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AccountFilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EntitlementFilePath
    )

    # --- File existence ---
    if (-not (Test-Path -Path $AccountFilePath -PathType Leaf)) {
        return @{
            Success = $false
            Data    = $null
            Error   = "Account file not found: $AccountFilePath"
        }
    }
    if (-not (Test-Path -Path $EntitlementFilePath -PathType Leaf)) {
        return @{
            Success = $false
            Data    = $null
            Error   = "Entitlement file not found: $EntitlementFilePath"
        }
    }

    # --- Read files ---
    try {
        $accounts     = @(Import-Csv -Path $AccountFilePath -Encoding UTF8)
        $entitlements = @(Import-Csv -Path $EntitlementFilePath -Encoding UTF8)
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to parse CSV files: $($_.Exception.Message)"
        }
    }

    # --- Build entitlement ID set ---
    $entitlementIds = @{}
    foreach ($ent in $entitlements) {
        if (-not [string]::IsNullOrWhiteSpace($ent.id)) {
            $entitlementIds[$ent.id.Trim()] = $true
        }
    }

    # --- Check account groups against entitlement IDs ---
    $unmatchedGroups       = [System.Collections.Generic.List[hashtable]]::new()
    $referencedEntitlements = @{}

    foreach ($acct in $accounts) {
        $groupsRaw = $acct.groups
        if ([string]::IsNullOrWhiteSpace($groupsRaw)) {
            continue
        }

        # Split comma-separated groups (Import-Csv already strips outer quotes)
        $groupList = @($groupsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

        foreach ($group in $groupList) {
            $referencedEntitlements[$group] = $true

            if (-not $entitlementIds.ContainsKey($group)) {
                $unmatchedGroups.Add(@{
                    AccountId     = $acct.id
                    EntitlementId = $group
                })
            }
        }
    }

    # --- Find orphaned entitlements ---
    $orphanedEntitlements = [System.Collections.Generic.List[string]]::new()
    foreach ($entId in $entitlementIds.Keys) {
        if (-not $referencedEntitlements.ContainsKey($entId)) {
            $orphanedEntitlements.Add($entId)
        }
    }

    $success = ($unmatchedGroups.Count -eq 0)
    return @{
        Success = $success
        Data    = @{
            UnmatchedGroups      = $unmatchedGroups.ToArray()
            OrphanedEntitlements = $orphanedEntitlements.ToArray()
        }
        Error   = if ($success) { $null } else { "$($unmatchedGroups.Count) group reference(s) have no matching entitlement definition" }
    }
}

#endregion
