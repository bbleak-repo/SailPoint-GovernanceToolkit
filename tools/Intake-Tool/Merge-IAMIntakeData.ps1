#Requires -Version 5.1
<#
.SYNOPSIS
    Adaptively parses IAM onboarding questionnaires (.xlsx and .docx) and
    consolidates them into one entry per application, exported as CSVs, a
    single XLSX workbook, canonical JSON and an interactive HTML app browser.

.DESCRIPTION
    Reads onboarding questionnaires regardless of their layout: structured
    questionnaire sheets (banner rows, Item/Description/Responses blocks,
    contacts tables, account tables), tabular inventories, key-value and
    multi-section sheets, roles/groups list sheets, and Word documents
    (entitlement schema and key-value tables).

    Uses header-vocabulary detection and fuzzy word-overlap scoring to map
    questions to canonical fields, then merges records by application name --
    files named "<AppName>_<Template>.xlsx" merge on the filename-derived app
    name. Cross-source disagreements are preserved as conflicts for review.

    Outputs (always): consolidated + per-product CSVs, a canonical JSON
    (IAM-Intake-Data.json), a single multi-sheet XLSX workbook, and a
    self-contained HTML app browser with an application dropdown.

    Requires the ImportExcel module (Install-Module ImportExcel -Scope CurrentUser).
    No Excel or Word installation is needed.

.PARAMETER Path
    Path to a directory containing .xlsx/.docx files, or a single file.

.PARAMETER OutputPath
    Directory for output files. Created if it does not exist.
    Defaults to .\IAM-Intake-Consolidated.

.PARAMETER Product
    Filter by product: All (default), SailPoint, or CyberArk.

.PARAMETER IncludeHtml
    Deprecated -- the HTML app browser is now always generated. The switch is
    accepted so existing invocations keep working.

.PARAMETER ShowUnmapped
    Include unmapped fields in the output and HTML report.

.PARAMETER SchemaPath
    Path to a previously saved schema JSON file. Skips auto-detection
    and applies the learned column mapping directly.

.PARAMETER SaveSchema
    Save the detected column mapping as a schema JSON file for reuse.

.PARAMETER DryRun
    Analyze files and display detection results without writing output.

.EXAMPLE
    .\Merge-IAMIntakeData.ps1 -Path \\server\share\IAM-Questionnaires -IncludeHtml

.EXAMPLE
    .\Merge-IAMIntakeData.ps1 -Path .\questionnaires -SaveSchema -DryRun

.EXAMPLE
    .\Merge-IAMIntakeData.ps1 -Path .\questionnaires -SchemaPath .\learned-schema.json

.NOTES
    Version: 1.0.0
    Requires: ImportExcel module
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$Path,

    [string]$OutputPath = '.\IAM-Intake-Consolidated',

    [ValidateSet('All', 'SailPoint', 'CyberArk', 'OktaEntra')]
    [string]$Product = 'All',

    [switch]$IncludeHtml,

    [switch]$ShowUnmapped,

    [string]$SchemaPath,

    [switch]$SaveSchema,

    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region Dependency Check
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Error @"
The ImportExcel module is required but not installed.
Install it with: Install-Module ImportExcel -Scope CurrentUser
This module does NOT require Microsoft Excel to be installed.
"@
    return
}
Import-Module ImportExcel -ErrorAction Stop
#endregion

#region Configuration

$script:DateStamp = Get-Date -Format 'yyyy-MM-dd'
$script:ProcessingLog = [System.Collections.Generic.List[PSCustomObject]]::new()

# Canonical field definitions with alias lists for fuzzy matching
# Each entry: canonical name -> array of known aliases (lowercased, words extracted for overlap)
$script:CanonicalFields = @{
    # Shared fields
    appName            = @('application name', 'app name', 'application', 'system name', 'name of application', 'name of system', 'app', 'name')
    appUrl             = @('application url', 'app url', 'url', 'web address', 'endpoint', 'application endpoint', 'site url', 'web url', 'address')
    vendor             = @('vendor', 'publisher', 'vendor name', 'software vendor', 'provider', 'manufacturer')
    deploymentType     = @('deployment type', 'deployment', 'hosting', 'hosting model', 'deployment model', 'saas on-prem', 'cloud or on-prem', 'infrastructure',
                           'where is the application hosted', 'application hosted')
    estimatedUsers     = @('estimated users', 'user count', 'number of users', 'total users', 'estimated user count', 'how many users', 'approximate users',
                           'how many user accounts exist in the application', 'user accounts exist in the application')
    appOwnerName       = @('application owner', 'app owner', 'owner', 'business owner', 'product owner', 'owner name', 'responsible party',
                           'application business owner name', 'business owner name')
    appOwnerEmail      = @('owner email', 'app owner email', 'application owner email', 'contact email', 'owner contact',
                           'application business owner email', 'business owner email')
    authMethod         = @('authentication method', 'auth method', 'auth type', 'authentication type', 'sign-on method', 'login method',
                           'how do users authenticate', 'how users log in', 'how do users log in', 'authentication', 'sso method',
                           'authentication platform', 'where does the application authenticate')
    hasMfa             = @('mfa', 'multi-factor', 'multi factor authentication', 'mfa required', 'has mfa', 'two-factor', '2fa',
                           'does the app require mfa', 'is mfa enabled', 'multi-factor authentication')
    mfaType            = @('mfa type', 'mfa method', 'type of mfa', 'multi-factor type', '2fa type', 'mfa details')
    hasApi             = @('has api', 'api available', 'api', 'does the app have an api', 'rest api', 'api access', 'api capability',
                           'apis available to get users/accounts and entitlement data', 'apis available')
    adIntegration      = @('ad integration', 'active directory', 'ldap', 'ad connected', 'active directory integration',
                           'does the app connect to ad', 'ad ldap', 'directory integration', 'is the application ad integrated', 'ad integrated')
    description        = @('description', 'brief description', 'app description', 'application description', 'purpose', 'what does the application do')

    # SailPoint fields
    sp_integrationPattern  = @('integration pattern', 'sailpoint pattern', 'connector pattern', 'isc pattern', 'governance pattern')
    sp_connectorType       = @('connector type', 'sailpoint connector', 'isc connector', 'native connector', 'connector')
    sp_canExportCsv        = @('can export csv', 'csv export', 'export users', 'can export user list', 'data export capability',
                               'can the app export a list of users', 'exporting a flat file', 'flat file with user entitlements')
    sp_csvDeliveryMethod   = @('csv delivery method', 'export method', 'how is the export done', 'data delivery method')
    sp_fileDeliveryMethod  = @('file delivery', 'file transfer method', 'sftp', 'delivery method', 'how are files delivered',
                               'automated delivery', 'can files be delivered automatically')
    sp_rbacRoles           = @('roles', 'rbac roles', 'permission roles', 'role list', 'entitlements', 'access roles',
                               'what roles exist', 'list the roles', 'role names')
    sp_roleCount           = @('role count', 'number of roles', 'how many roles', 'total roles')
    sp_apiType             = @('api type', 'api protocol', 'rest soap graphql', 'type of api')
    sp_apiSupportsWrite    = @('api supports write', 'api create update', 'api write access', 'can api modify users',
                               'can the api create update delete user accounts')
    sp_v2AccountType       = @('account type field', 'can provide account type', 'v2 account type')
    sp_v2LastLogin         = @('last login field', 'can provide last login', 'v2 last login', 'last login date available')
    sp_v2RiskLevel         = @('risk level field', 'entitlement risk level', 'v2 risk level', 'can provide risk level')

    # CyberArk fields
    ca_hlaPriority         = @('hla priority', 'priority', 'security priority', 'risk priority', 'p0 p1 p2 p3')
    ca_tier                = @('tier', 'hla tier', 'security tier', 'tier 0 1 2 3', 'account tier')
    ca_accountTypes        = @('admin account types', 'privileged account types', 'account types', 'types of admin accounts',
                               'human admin service account api')
    ca_adminCount          = @('admin count', 'number of admin accounts', 'privileged account count', 'how many admin accounts',
                               'number of privileged accounts', 'approximate number of privileged accounts')
    ca_adminAuthMethod     = @('admin authentication', 'admin auth method', 'how admins authenticate',
                               'admin login method', 'privileged authentication method')
    ca_adminAccessMethod   = @('admin access method', 'how admins access', 'admin access', 'browser rdp ssh',
                               'how do admins access the app', 'privileged access method')
    ca_canChangePasswordViaApi = @('api password change', 'can change password via api', 'password change api',
                                   'can admin password be changed via api', 'automated password rotation')
    ca_adminMfaType        = @('admin mfa type', 'admin mfa', 'admin multi-factor', 'privileged mfa',
                               'mfa for admin accounts', 'admin mfa method')
    ca_cpmApproach         = @('cpm approach', 'password management', 'rotation approach', 'credential rotation',
                               'cpm method', 'password rotation')
    ca_psmApproach         = @('psm approach', 'session management', 'session recording', 'psm method',
                               'privileged session', 'session isolation')
    ca_marketplace         = @('marketplace', 'cyberark marketplace', 'marketplace connector', 'pre-built connector',
                               'is this app on the cyberark marketplace')
    ca_platformCategory    = @('platform category', 'platform type', 'platform', 'system category',
                               'web windows unix database cloud')
    ca_modifySecurity      = @('modify security settings', 'can modify security', 'modify audit logs',
                               'can this account modify security settings')
    ca_manageUsers         = @('manage users', 'create delete users', 'user management',
                               'can this account create delete or modify other users')
    ca_sensitiveData       = @('sensitive data', 'pii financial health', 'access to sensitive data',
                               'does this account have access to sensitive data')
    ca_impactScope         = @('impact scope', 'blast radius', 'affect more than 100 users',
                               'could compromise affect more than 100 users', 'impact over 100 users',
                               'impact 100 users', 'impact users', 'affect users')
    ca_managesInfra        = @('manages infrastructure', 'infrastructure management', 'servers databases cloud',
                               'does this account manage infrastructure')

    # Okta / Entra ID fields
    okta_currentIdp        = @('current idp', 'identity provider', 'current identity provider', 'idp', 'sso provider')
    okta_signOnMode        = @('sign-on mode', 'sso type', 'okta sign on', 'sign on method', 'okta app type',
                               'sign on mode', 'authentication protocol', 'saml oidc swa')
    okta_hasScimProvisioning = @('scim', 'scim provisioning', 'auto provisioning', 'user provisioning',
                                 'automated provisioning', 'is scim configured')
    okta_appLabel          = @('okta app label', 'okta app name', 'okta label', 'app label in okta')
    okta_migrationTarget   = @('migration target', 'migration plan', 'move to entra', 'target idp',
                               'migration destination', 'staying or moving')
    okta_entraEquivalent   = @('entra equivalent', 'entra config', 'entra id configuration',
                               'azure ad equivalent', 'entra app type')
    okta_knownGaps         = @('known gaps', 'migration gaps', 'gaps identified', 'gap analysis')
    okta_migrationWave     = @('migration wave', 'wave', 'migration phase', 'wave assignment')
    okta_conditionalAccess = @('conditional access', 'access policy', 'sign-on policy', 'conditional access policy')
    okta_groupAssignments  = @('group assignments', 'okta groups', 'assigned groups', 'group membership')
    okta_mfaPolicy         = @('mfa policy', 'okta mfa policy', 'authentication policy', 'sign-on policy mfa')

    # -- General questionnaire template (structured intake sheets) --
    sox                    = @('is this a sox application', 'sox application', 'sox')
    dataClassification     = @('contains any cci', 'pii / phi data', 'cci (customer)/ pii / phi', 'data classification', 'pii phi data')
    isWebBased             = @('is this a web based application', 'web based application')
    privilegedAccessPortal = @('privileged access portal', 'existing application privileged access portal')
    isFinancial            = @('transactional / financial application', 'financial application', 'is this a transactional')
    accessCertRequired     = @('is access certification required', 'access certification required')
    over100Users           = @('more than 100 users', 'have more than 100 users')
    businessCriticality    = @('business criticality', 'criticality')
    alreadyInSailPoint     = @('already setup in sailpoint', 'access certification already setup', 'already in sailpoint')
    userPopulation         = @('end users internal, external or both', 'internal, external or both', 'user population')
    appStatus              = @('application status', 'app status')
    accessVectors          = @('how is the application accessed', 'access vectors', 'vectors of access')
    appPlatform            = @('application platform/type', 'application platform', 'platform/type')
    appLevel               = @('application level', 'appliacation level')
    appNameInPlatform      = @('application name in the platform', 'name in the platform', 'application name to be configured in sailpoint')
    vendorEmail            = @('vendor email', 'vendor contact email')
    environments           = @('environments exist for this application', 'list application environments', 'application environments')
    multipleAccounts       = @('more than one account in the application', 'more than one account')
    adGroupsForEntitlements = @('leverage active directory groups only', 'active directory groups only to manage entitlements', 'ad groups only')
    sqlExtract             = @('stored in a sql database', 'extracted using sql', 'sql queries/views/procedures', 'sql database')
    uniqueIdentifier       = @('unique identifier/account id', 'unique identifier', 'account id in the application')
    serviceAccounts        = @('does your application have service accounts', 'service accounts, if so how are they identified', 'has service accounts')
    serverOwners           = @('server owner', 'server owners', 'server owner(s)')

    # -- Contacts blocks (Part 2) --
    itaoName               = @('it application owner name', 'itao name', 'it application owner (itao) name')
    itaoEmail              = @('it application owner email', 'itao email', 'it application owner (itao) email')
    appAdminNames          = @('application administrator name', 'application administrators name', 'application administrator(s) name')
    appAdminEmails         = @('application administrator email', 'application administrators email', 'application administrator(s) email')
    onboardingAnalyst      = @('application onboarding business analyst name', 'onboarding business analyst', 'onboarding analyst')

    # -- CyberArk questionnaire accounts table (aggregated) --
    ca_accountNames        = @('privileged account list', 'account list', 'privileged accounts list')
    ca_serviceAccountCount = @('service account count', 'number of service accounts')
    ca_interactiveAccountCount = @('interactive account count', 'number of interactive accounts')
    ca_accountListMaintained = @('list of accounts utlized', 'list of accounts utilized', 'accounts utilized by this application')

    # -- AD groups (also populated by list sheets and docx entitlement schemas) --
    adGroups               = @('ad groups', 'ad group list', 'group that handles the access', 'assigned ad groups')
    adGroupCount           = @('ad group count', 'number of ad groups')
}

# Detection thresholds
$script:Config = @{
    MinMappingScore       = 0.40   # Minimum score to consider a match
    HighConfidenceScore   = 0.75   # Score threshold for "high confidence"
    MaxScanRows           = 30     # Rows to scan for format detection
    QuestionPatterns      = @('^\s*(what|how|does|is|can|are|do|which|where|when|will|would|should)', '[\?:]\s*$')
    # (?-i) keeps the ALL-CAPS heading pattern case-sensitive -- PowerShell's
    # -match is case-insensitive, which would otherwise swallow every plain
    # text key ("Application Name") as a section header and discard its value
    SectionPatterns       = @('^\s*={2,}', '^\s*-{3,}', '^\s*#{1,3}\s', '^(?-i)[A-Z][A-Z\s&]{4,}$')
    # Sheets whose NAME matches these are lists belonging to the workbook's app
    # (one row per role/group/etc.) -- not one app per row
    ListSheetPatterns     = @('role', 'rbac', 'group', 'entitlement', 'permission', 'membership')
    KeyValueMinRatio      = 0.6    # Min ratio of col A filled to col B filled for KV detection

    # Rows matching these (when they are the only populated cell) separate
    # blocks in structured questionnaire sheets
    BannerPatterns        = @('^part\b', '^introduction', '^instruction', 'reserved for', '^for the list', '^section\b', '^tab \d')
}

# Structured questionnaire sheets: maps a normalized header-cell caption to the
# ROLE that column plays in the block beneath it. Extend this table to teach
# the parser new template vocabularies -- everything else is layout-agnostic.
# Cell captions are normalized before lookup: lowercased, text before the first
# '(' kept, '?'/':' stripped, whitespace collapsed ("Name(s)" -> "name").
$script:StructuredHeaderRoles = @{
    '#'                     = 'num'
    'no'                    = 'num'
    'item'                  = 'key'
    'question'              = 'key'
    'field'                 = 'key'
    'application information' = 'key'
    'responses'             = 'value'
    'response'              = 'value'
    'answer'                = 'value'
    'answers'               = 'value'
    'value'                 = 'value'
    'description'           = 'guidance'
    'options'               = 'guidance'
    'instructions'          = 'guidance'
    'comments'              = 'detail'
    'notes'                 = 'detail'
    'additional details'    = 'detail'
    'name'                  = 'name'
    'names'                 = 'name'
    'contact'               = 'name'
    'email'                 = 'email'
    'emails'                = 'email'
    'account name'          = 'acctName'
    'account type'          = 'acctType'
    'interactive/service account' = 'acctClass'
    'password dependencies' = 'acctPwd'
    'users with access today' = 'acctUsers'
}

# Display grouping for canonical fields -- the single source of truth for the
# Master sheet column order, the JSON payload field order, and the HTML
# browser's sections. Canonical fields NOT listed here are auto-appended to a
# trailing "Other" group at export time so new fields are never invisible.
$script:FieldGroups = [ordered]@{
    'Application Overview' = @('appName', 'appNameInPlatform', 'vendor', 'vendorEmail', 'description',
        'appPlatform', 'appLevel', 'deploymentType', 'environments', 'appStatus', 'appUrl', 'isWebBased',
        'accessVectors', 'estimatedUsers', 'over100Users', 'userPopulation', 'businessCriticality',
        'multipleAccounts', 'uniqueIdentifier', 'serviceAccounts')
    'Risk & Compliance' = @('sox', 'isFinancial', 'dataClassification', 'accessCertRequired', 'privilegedAccessPortal')
    'Contacts' = @('appOwnerName', 'appOwnerEmail', 'itaoName', 'itaoEmail', 'appAdminNames', 'appAdminEmails',
        'serverOwners', 'onboardingAnalyst')
    'Authentication & Directory' = @('authMethod', 'hasMfa', 'mfaType', 'adIntegration', 'adGroupsForEntitlements',
        'adGroups', 'adGroupCount')
    'SailPoint' = @('sp_integrationPattern', 'sp_connectorType', 'alreadyInSailPoint', 'hasApi', 'sp_apiType',
        'sp_apiSupportsWrite', 'sqlExtract', 'sp_canExportCsv', 'sp_csvDeliveryMethod', 'sp_fileDeliveryMethod',
        'sp_rbacRoles', 'sp_roleCount', 'sp_v2AccountType', 'sp_v2LastLogin', 'sp_v2RiskLevel')
    'CyberArk' = @('ca_hlaPriority', 'ca_tier', 'ca_accountTypes', 'ca_adminCount', 'ca_adminAuthMethod',
        'ca_adminAccessMethod', 'ca_adminMfaType', 'ca_canChangePasswordViaApi', 'ca_accountNames',
        'ca_serviceAccountCount', 'ca_interactiveAccountCount', 'ca_accountListMaintained', 'ca_cpmApproach',
        'ca_psmApproach', 'ca_marketplace', 'ca_platformCategory', 'ca_modifySecurity', 'ca_manageUsers',
        'ca_sensitiveData', 'ca_impactScope', 'ca_managesInfra')
    'Okta / Entra' = @('okta_currentIdp', 'okta_signOnMode', 'okta_hasScimProvisioning', 'okta_appLabel',
        'okta_migrationTarget', 'okta_entraEquivalent', 'okta_knownGaps', 'okta_migrationWave',
        'okta_conditionalAccess', 'okta_groupAssignments', 'okta_mfaPolicy')
}

function Get-EffectiveFieldGroups {
    <# Returns $script:FieldGroups plus a trailing "Other" group holding any
       canonical field not explicitly listed -- new fields never disappear. #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $script:FieldGroups.Keys) {
        foreach ($f in $script:FieldGroups[$g]) { [void]$listed.Add($f) }
    }
    $other = @($script:CanonicalFields.Keys | Where-Object { -not $listed.Contains($_) } | Sort-Object)
    $groups = [ordered]@{}
    foreach ($g in $script:FieldGroups.Keys) { $groups[$g] = $script:FieldGroups[$g] }
    if ($other.Count -gt 0) { $groups['Other'] = $other }
    return $groups
}
#endregion

#region Format Detection

function Get-SheetFingerprint {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [object[]]$RawData,
        [string]$SheetName
    )

    $totalRows = [Math]::Min($RawData.Count, $script:Config.MaxScanRows)
    if ($totalRows -eq 0) {
        return [PSCustomObject]@{
            SheetName = $SheetName; Format = 'Empty'; Score = 0
            TabularScore = 0; KeyValueScore = 0; MultiSectionScore = 0
            ColumnCount = 0; DataRows = 0
        }
    }

    # Get column names from the imported data
    $columns = @()
    if ($RawData[0]) {
        $columns = @($RawData[0].PSObject.Properties.Name)
    }
    $colCount = $columns.Count

    # Analyze column fill rates
    $colFillCounts = @{}
    foreach ($col in $columns) { $colFillCounts[$col] = 0 }
    $nonEmptyRows = 0
    $emptyRowPositions = @()

    for ($i = 0; $i -lt $totalRows; $i++) {
        $row = $RawData[$i]
        $rowHasData = $false
        foreach ($col in $columns) {
            $val = $row.$col
            if ($null -ne $val -and "$val".Trim() -ne '') {
                $colFillCounts[$col]++
                $rowHasData = $true
            }
        }
        if ($rowHasData) { $nonEmptyRows++ }
        else { $emptyRowPositions += $i }
    }

    # Score: Tabular
    # Tabular sheets have: many columns (>3) with similar fill rates, short header-like first row
    $tabularScore = 0.0
    if ($colCount -ge 3) { $tabularScore += 0.3 }
    if ($colCount -ge 5) { $tabularScore += 0.2 }
    # Check if fill rates are roughly uniform (tabular pattern)
    $fillRates = $colFillCounts.Values | ForEach-Object { if ($totalRows -gt 0) { $_ / $totalRows } else { 0 } }
    $avgFillRate = ($fillRates | Measure-Object -Average).Average
    if ($avgFillRate -gt 0.5) { $tabularScore += 0.3 }
    # Multiple data rows suggest tabular
    if ($nonEmptyRows -gt 3) { $tabularScore += 0.2 }

    # Score: Key-Value
    # Key-Value sheets have: 2 main columns, col A longer text, col B shorter answers
    $kvScore = 0.0
    if ($colCount -le 3) { $kvScore += 0.3 }
    if ($colCount -eq 2) { $kvScore += 0.2 }
    # Check for question-like patterns in column A
    $firstColName = if ($columns.Count -gt 0) { $columns[0] } else { '' }
    $questionCount = 0
    for ($i = 0; $i -lt $totalRows; $i++) {
        $cellA = "$($RawData[$i].$firstColName)"
        foreach ($pat in $script:Config.QuestionPatterns) {
            if ($cellA -match $pat) { $questionCount++; break }
        }
    }
    if ($totalRows -gt 0 -and ($questionCount / $totalRows) -gt 0.3) { $kvScore += 0.3 }
    if ($totalRows -gt 0 -and ($questionCount / $totalRows) -gt 0.5) { $kvScore += 0.2 }

    # Score: Multi-Section
    # Has section separators (empty rows, all-caps headers, === lines)
    $msScore = 0.0
    $sectionBreaks = 0
    for ($i = 0; $i -lt $totalRows; $i++) {
        $cellA = "$($RawData[$i].$firstColName)"
        foreach ($pat in $script:Config.SectionPatterns) {
            if ($cellA -match $pat) { $sectionBreaks++; break }
        }
    }
    if ($sectionBreaks -ge 2) { $msScore += 0.4 }
    if ($emptyRowPositions.Count -ge 2 -and $colCount -le 3) { $msScore += 0.3 }
    # Multi-section is a variant of KV, so inherit some KV signal
    if ($kvScore -gt 0.4 -and $sectionBreaks -ge 1) { $msScore += 0.2 }

    # Determine winner
    $maxScore = [Math]::Max([Math]::Max($tabularScore, $kvScore), $msScore)
    $format = 'Unknown'
    if ($maxScore -eq $tabularScore -and $tabularScore -gt 0.3) { $format = 'Tabular' }
    elseif ($maxScore -eq $msScore -and $msScore -gt 0.3) { $format = 'MultiSection' }
    elseif ($maxScore -eq $kvScore -and $kvScore -gt 0.3) { $format = 'KeyValue' }
    elseif ($tabularScore -ge $kvScore) { $format = 'Tabular' }
    else { $format = 'KeyValue' }

    return [PSCustomObject]@{
        SheetName        = $SheetName
        Format           = $format
        Score            = [Math]::Round($maxScore, 2)
        TabularScore     = [Math]::Round($tabularScore, 2)
        KeyValueScore    = [Math]::Round($kvScore, 2)
        MultiSectionScore = [Math]::Round($msScore, 2)
        ColumnCount      = $colCount
        DataRows         = $nonEmptyRows
    }
}
#endregion

#region Data Extraction

function Import-TabularSheet {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)] [object[]]$RawData,
        [string]$SourceFile,
        [string]$SheetName
    )

    # ImportExcel already treats row 1 as headers
    # Each row becomes one app record
    $records = @()
    foreach ($row in $RawData) {
        $record = [ordered]@{ _sourceFile = $SourceFile; _sheetName = $SheetName; _format = 'Tabular' }
        $hasData = $false
        foreach ($prop in $row.PSObject.Properties) {
            $val = "$($prop.Value)".Trim()
            if ($val -ne '') {
                $record[$prop.Name] = $val
                $hasData = $true
            }
        }
        if ($hasData) { $records += [PSCustomObject]$record }
    }
    return $records
}

function Import-KeyValueSheet {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [object[]]$RawData,
        [string]$SourceFile,
        [string]$SheetName
    )

    $columns = @($RawData[0].PSObject.Properties.Name)
    $keyCol = if ($columns.Count -gt 0) { $columns[0] } else { return $null }
    $valCol = if ($columns.Count -gt 1) { $columns[1] } else { return $null }

    $record = [ordered]@{ _sourceFile = $SourceFile; _sheetName = $SheetName; _format = 'KeyValue' }

    # The header row from ImportExcel becomes column names.
    # Skip generic header names that aren't actual data.
    $genericHeaders = @('question', 'answer', 'field', 'value', 'item', 'response',
                        'column1', 'column2', 'col1', 'col2', 'key', 'data', 'detail')
    $headerKey = "$keyCol".Trim()
    $headerVal = "$valCol".Trim()
    $isGenericHeader = $genericHeaders -contains $headerKey.ToLower() -or $genericHeaders -contains $headerVal.ToLower()
    if ($headerKey -ne '' -and $headerVal -ne '' -and -not $isGenericHeader) {
        $record[$headerKey] = $headerVal
    }

    foreach ($row in $RawData) {
        $key = "$($row.$keyCol)".Trim()
        $val = "$($row.$valCol)".Trim()
        if ($key -ne '' -and $val -ne '') {
            $record[$key] = $val
        }
        elseif ($key -ne '' -and $columns.Count -gt 2) {
            # Check additional columns for the value
            for ($c = 2; $c -lt $columns.Count; $c++) {
                $altVal = "$($row.($columns[$c]))".Trim()
                if ($altVal -ne '') { $record[$key] = $altVal; break }
            }
        }
    }

    if ($record.Count -le 3) { return $null }
    return [PSCustomObject]$record
}

function Import-MultiSectionSheet {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [object[]]$RawData,
        [string]$SourceFile,
        [string]$SheetName
    )

    $columns = @($RawData[0].PSObject.Properties.Name)
    $keyCol = if ($columns.Count -gt 0) { $columns[0] } else { return $null }
    $valCol = if ($columns.Count -gt 1) { $columns[1] } else { return $null }

    $record = [ordered]@{ _sourceFile = $SourceFile; _sheetName = $SheetName; _format = 'MultiSection' }
    $currentSection = ''

    foreach ($row in $RawData) {
        $cellA = "$($row.$keyCol)".Trim()
        $cellB = if ($valCol) { "$($row.$valCol)".Trim() } else { '' }

        # Detect section headers -- a row that carries a VALUE is data, never a
        # section header, regardless of how its key is formatted
        $isSection = $false
        if ($cellB -eq '') {
            foreach ($pat in $script:Config.SectionPatterns) {
                if ($cellA -match $pat) { $isSection = $true; break }
            }
        }

        if ($isSection) {
            $currentSection = ($cellA -replace '[=\-#\s]+', ' ').Trim()
            continue
        }

        if ($cellA -ne '' -and $cellB -ne '') {
            $fullKey = if ($currentSection) { "$currentSection.$cellA" } else { $cellA }
            $record[$fullKey] = $cellB
        }
    }

    if ($record.Count -le 3) { return $null }
    return [PSCustomObject]$record
}

function Import-ListSheet {
    <#
        A list sheet (RBAC roles, AD groups, entitlements) holds one item per
        row belonging to a single application -- NOT one application per row.
        Rows are aggregated into multi-value fields; the full row detail is
        preserved as compact JSON in a per-sheet _detail_* column.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [object[]]$RawData,
        [string]$SourceFile,
        [string]$SheetName
    )

    $columns = @($RawData[0].PSObject.Properties.Name)
    if ($columns.Count -eq 0) { return $null }
    $nameCol = $columns[0]

    $items = @()
    $detail = [System.Collections.ArrayList]::new()
    foreach ($row in $RawData) {
        $primary = "$($row.$nameCol)".Trim()
        if ($primary -eq '') { continue }
        $items += $primary
        $rowData = [ordered]@{}
        foreach ($c in $columns) {
            $v = "$($row.$c)".Trim()
            if ($v -ne '') { $rowData[$c] = $v }
        }
        [void]$detail.Add($rowData)
    }
    if ($items.Count -eq 0) { return $null }

    $record = [ordered]@{ _sourceFile = $SourceFile; _sheetName = $SheetName; _format = 'List' }
    $isGroups = ($SheetName -match '(?i)group|membership') -or ($nameCol -match '(?i)group')
    if ($isGroups) {
        $record['adGroups'] = $items -join '; '
        $record['adGroupCount'] = $items.Count
    }
    else {
        $record['sp_rbacRoles'] = $items -join '; '
        $record['sp_roleCount'] = $items.Count
    }
    $detailKey = '_detail_' + ($SheetName -replace '[^A-Za-z0-9]', '_')
    $record[$detailKey] = ConvertTo-Json -InputObject @($detail) -Compress -Depth 3
    $record['_mappingConfidence'] = 1

    return [PSCustomObject]$record
}

function ConvertTo-CellArray {
    <# Converts an Import-Excel -NoHeader row (P1..Pn) into a trimmed string array. #>
    [OutputType([string[]])]
    param($Row)
    return @($Row.PSObject.Properties | ForEach-Object { "$($_.Value)".Trim() })
}

function Get-NormalizedHeaderCell {
    <# Normalizes a header caption for role lookup: "Name(s)" -> "name",
       "Account Type (Application, ...)" -> "account type". #>
    [OutputType([string])]
    param([string]$Text)
    $t = $Text.ToLower().Trim()
    $i = $t.IndexOf('(')
    if ($i -gt 0) { $t = $t.Substring(0, $i) }
    $t = ($t -replace '[\?:]', '').Trim() -replace '\s+', ' '
    return $t
}

function Get-StructuredHeaderRoles {
    <# Returns @{ roleName = columnIndex } for a row, or $null if the row is
       not a recognizable block header (needs 2+ vocabulary hits). #>
    param([string[]]$Cells)
    $roles = @{}
    $hits = 0
    for ($i = 0; $i -lt $Cells.Count; $i++) {
        if ($Cells[$i] -eq '') { continue }
        $norm = Get-NormalizedHeaderCell -Text $Cells[$i]
        if ($script:StructuredHeaderRoles.ContainsKey($norm)) {
            $role = $script:StructuredHeaderRoles[$norm]
            if (-not $roles.ContainsKey($role)) { $roles[$role] = $i }
            $hits++
        }
    }
    if ($hits -ge 2) { return $roles }
    return $null
}

function Test-StructuredSheet {
    <# A sheet is "structured" when any row is a recognizable block header
       carrying a key or account-name column. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] [object[]]$RawData)
    foreach ($row in $RawData) {
        $roles = Get-StructuredHeaderRoles -Cells (ConvertTo-CellArray $row)
        if ($roles -and ($roles.ContainsKey('key') -or $roles.ContainsKey('acctName'))) { return $true }
    }
    return $false
}

function Import-StructuredSheet {
    <#
        Parses a questionnaire sheet laid out as a SEQUENCE OF BLOCKS:
        banner rows, block header rows (Item/Description/Responses,
        Question/Options/Answer, contacts with Name(s)/Email(s), account
        tables, ...) and data rows. The layout is discovered from the header
        vocabulary ($script:StructuredHeaderRoles), not hard-coded positions,
        so new templates adapt as long as their headers use similar captions.

        Guidance columns (Description/Options) are IGNORED as values -- the
        answer is taken from the Responses/Answer column only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [object[]]$RawData,
        [string]$SourceFile,
        [string]$SheetName
    )

    $record = [ordered]@{ _sourceFile = $SourceFile; _sheetName = $SheetName; _format = 'Structured' }
    $mode = 'none'
    $ci = @{}
    $accounts = [System.Collections.ArrayList]::new()
    $tableRows = [System.Collections.ArrayList]::new()
    $tableCaptions = @()
    $lastBanner = ''
    $tableIdx = 0

    $flushTable = {
        if ($tableRows.Count -gt 0) {
            $label = if ($lastBanner) { $lastBanner } else { "Table$tableIdx" }
            $detailKey = '_detail_' + (($SheetName + '_' + $label) -replace '[^A-Za-z0-9]', '_') -replace '_{2,}', '_'
            $record[$detailKey] = ConvertTo-Json -InputObject @($tableRows) -Compress -Depth 3
            $tableRows.Clear()
        }
    }

    foreach ($row in $RawData) {
        $cells = ConvertTo-CellArray $row
        $nonEmptyIdx = @(0..($cells.Count - 1) | Where-Object { $cells[$_] -ne '' })
        if ($nonEmptyIdx.Count -eq 0) { continue }

        # --- Block header? ---
        $roles = Get-StructuredHeaderRoles -Cells $cells
        if ($roles) {
            & $flushTable
            $tableIdx++
            $ci = $roles
            if ($roles.ContainsKey('acctName')) { $mode = 'accounts' }
            elseif ($roles.ContainsKey('name') -or $roles.ContainsKey('email')) { $mode = 'contacts' }
            elseif ($roles.ContainsKey('key')) { $mode = 'qa' }
            else { $mode = 'table'; $tableCaptions = $cells }
            continue
        }

        # --- Banner row (single populated cell)? Resets block context ---
        if ($nonEmptyIdx.Count -eq 1) {
            $text = $cells[$nonEmptyIdx[0]]
            foreach ($pat in $script:Config.BannerPatterns) {
                if ($text -match $pat) {
                    & $flushTable
                    $mode = 'none'
                    $lastBanner = $text -replace '[\[\]]', ''
                    break
                }
            }
            # Single-cell rows that are not banners (unanswered questions,
            # free text) carry no key/value pair -- skip either way
            continue
        }

        # --- Data row, interpreted by current block mode ---
        switch ($mode) {
            'qa' {
                $key = if ($ci.ContainsKey('key')) { $cells[$ci.key] } else { '' }
                if ($key -eq '') { continue }
                $val = ''
                if ($ci.ContainsKey('value') -and $ci.value -lt $cells.Count) { $val = $cells[$ci.value] }
                elseif (-not $ci.ContainsKey('value')) {
                    # No dedicated answer column in this template: fall back to
                    # the last populated non-key, non-guidance, non-num cell
                    foreach ($idx in $nonEmptyIdx) {
                        if ($idx -eq $ci.key) { continue }
                        if ($ci.ContainsKey('num') -and $idx -eq $ci.num) { continue }
                        if ($ci.ContainsKey('guidance') -and $idx -eq $ci.guidance) { continue }
                        $val = $cells[$idx]
                    }
                }
                if ($ci.ContainsKey('detail') -and $ci.detail -lt $cells.Count -and $cells[$ci.detail] -ne '') {
                    $val = if ($val -ne '') { "$val | $($cells[$ci.detail])" } else { $cells[$ci.detail] }
                }
                if ($val -ne '') { $record[$key] = $val }
            }
            'contacts' {
                $key = if ($ci.ContainsKey('key')) { $cells[$ci.key] } else { '' }
                if ($key -eq '') { continue }
                if ($ci.ContainsKey('name') -and $ci.name -lt $cells.Count -and $cells[$ci.name] -ne '') {
                    $record["$key name"] = $cells[$ci.name]
                }
                if ($ci.ContainsKey('email') -and $ci.email -lt $cells.Count -and $cells[$ci.email] -ne '') {
                    $record["$key email"] = $cells[$ci.email]
                }
            }
            'accounts' {
                $acctName = if ($ci.acctName -lt $cells.Count) { $cells[$ci.acctName] } else { '' }
                if ($acctName -eq '' -or $acctName -match '(?i)example entry') { continue }
                $acct = [ordered]@{ AccountName = $acctName }
                foreach ($role in @('acctType', 'acctClass', 'acctPwd', 'acctUsers')) {
                    if ($ci.ContainsKey($role) -and $ci[$role] -lt $cells.Count -and $cells[$ci[$role]] -ne '') {
                        $acct[$role -replace '^acct', ''] = $cells[$ci[$role]]
                    }
                }
                [void]$accounts.Add([PSCustomObject]$acct)
            }
            'table' {
                # Unrecognized sub-table: preserve every populated cell keyed
                # by its column caption so no data is silently dropped
                $rowData = [ordered]@{}
                foreach ($idx in $nonEmptyIdx) {
                    $caption = if ($idx -lt $tableCaptions.Count -and $tableCaptions[$idx] -ne '') { $tableCaptions[$idx] } else { "Col$idx" }
                    $rowData[$caption] = $cells[$idx]
                }
                if ($rowData.Count -gt 0) { [void]$tableRows.Add($rowData) }
            }
            'none' {
                # Multi-cell row outside any recognized block: generic key/value
                # (first populated cell = key, last populated cell = value)
                $key = $cells[$nonEmptyIdx[0]]
                $val = $cells[$nonEmptyIdx[-1]]
                if ($key -ne '' -and $val -ne '' -and $nonEmptyIdx.Count -ge 2) {
                    $record[$key] = $val
                }
            }
        }
    }
    & $flushTable

    # Aggregate the accounts table into app-level fields
    if ($accounts.Count -gt 0) {
        $record['privileged account list'] = (@($accounts | ForEach-Object { $_.AccountName }) -join '; ')
        $record['privileged account count'] = $accounts.Count
        $svc = @($accounts | Where-Object { $_.PSObject.Properties['Class'] -and $_.Class -match '(?i)service' })
        $int = @($accounts | Where-Object { $_.PSObject.Properties['Class'] -and $_.Class -match '(?i)interactive' })
        if ($svc.Count -gt 0) { $record['service account count'] = $svc.Count }
        if ($int.Count -gt 0) { $record['interactive account count'] = $int.Count }
        $detailKey = '_detail_' + (($SheetName + '_Accounts') -replace '[^A-Za-z0-9]', '_')
        $record[$detailKey] = ConvertTo-Json -InputObject @($accounts) -Compress -Depth 3
    }

    if ($record.Count -le 3) { return $null }
    return [PSCustomObject]$record
}

function Import-DocxFile {
    <#
        Extracts data from a Word (.docx) onboarding document by reading
        word/document.xml straight out of the zip container -- no Word
        installation required. Walks body elements in order, tracking the
        last numbered/styled heading, and interprets tables:
          - "Entitlement Schema" tables -> roles/groups aggregation
          - 2-column tables            -> key/value pairs (mapped normally)
          - anything else              -> preserved as _detail_* JSON
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string]$SourceFile
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry('word/document.xml')
        if (-not $entry) { return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        $xmlText = $reader.ReadToEnd()
        $reader.Close()
    }
    finally { $zip.Dispose() }

    [xml]$xml = $xmlText
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $body = $xml.SelectSingleNode('/w:document/w:body', $ns)
    if (-not $body) { return $null }

    $record = [ordered]@{ _sourceFile = $SourceFile; _sheetName = '(docx)'; _format = 'Docx' }
    $groups = @(); $roles = @(); $groupDetail = [System.Collections.ArrayList]::new()
    $lastHeading = ''
    $tableIdx = 0

    foreach ($node in $body.ChildNodes) {
        if ($node.LocalName -eq 'p') {
            $text = "$($node.InnerText)".Trim()
            if ($text -eq '') { continue }
            $styleNode = $node.SelectSingleNode('w:pPr/w:pStyle/@w:val', $ns)
            $isHeading = ($text -match '^\d+[\.\)]\s+\S') -or ($styleNode -and "$($styleNode.Value)" -match '^Heading')
            if ($isHeading) { $lastHeading = $text -replace '^\d+[\.\)]\s*', '' }
        }
        elseif ($node.LocalName -eq 'tbl') {
            $tableIdx++
            $rows = @()
            foreach ($tr in $node.SelectNodes('w:tr', $ns)) {
                $cells = @()
                foreach ($tc in $tr.SelectNodes('w:tc', $ns)) { $cells += "$($tc.InnerText)".Trim() }
                $rows += , $cells
            }
            if ($rows.Count -eq 0) { continue }
            $headerJoined = ($rows[0] -join ' ').ToLower()

            if ($headerJoined -match 'entitlement type') {
                # Entitlement Schema table: Type | Name | Display Name | ...
                foreach ($r in ($rows | Select-Object -Skip 1)) {
                    if ($r.Count -lt 2 -or $r[1] -eq '') { continue }
                    $rowObj = [ordered]@{}
                    for ($c = 0; $c -lt [Math]::Min($r.Count, $rows[0].Count); $c++) {
                        if ($r[$c] -ne '') { $rowObj[$rows[0][$c]] = $r[$c] }
                    }
                    [void]$groupDetail.Add($rowObj)
                    if ($r[0] -match '(?i)group') { $groups += $r[1] }
                    elseif ($r[0] -match '(?i)role') { $roles += $r[1] }
                }
            }
            elseif (@($rows | Where-Object { $_.Count -eq 2 }).Count -ge ($rows.Count * 0.8)) {
                # Two-column table: treat as key/value pairs
                foreach ($r in $rows) {
                    if ($r.Count -ge 2 -and $r[0] -ne '' -and $r[1] -ne '') { $record[$r[0]] = $r[1] }
                }
            }
            else {
                # Unknown table: preserve every row keyed by its header caption
                $detailRows = [System.Collections.ArrayList]::new()
                foreach ($r in ($rows | Select-Object -Skip 1)) {
                    $rowObj = [ordered]@{}
                    for ($c = 0; $c -lt $r.Count; $c++) {
                        if ($r[$c] -eq '') { continue }
                        $caption = if ($c -lt $rows[0].Count -and $rows[0][$c] -ne '') { $rows[0][$c] } else { "Col$c" }
                        $rowObj[$caption] = $r[$c]
                    }
                    if ($rowObj.Count -gt 0) { [void]$detailRows.Add($rowObj) }
                }
                if ($detailRows.Count -gt 0) {
                    $label = if ($lastHeading) { $lastHeading } else { "Table$tableIdx" }
                    $detailKey = '_detail_' + ($label -replace '[^A-Za-z0-9]', '_') -replace '_{2,}', '_'
                    $record[$detailKey] = ConvertTo-Json -InputObject @($detailRows) -Compress -Depth 3
                }
            }
        }
    }

    if ($groups.Count -gt 0) {
        $record['ad groups'] = ($groups -join '; ')
        $record['ad group count'] = $groups.Count
    }
    if ($roles.Count -gt 0) {
        $record['roles'] = ($roles -join '; ')
        $record['role count'] = $roles.Count
    }
    if ($groupDetail.Count -gt 0) {
        $record['_detail_Entitlement_Schema'] = ConvertTo-Json -InputObject @($groupDetail) -Compress -Depth 3
    }

    if ($record.Count -le 3) { return $null }
    return [PSCustomObject]$record
}
#endregion

#region Canonical Mapping

function Measure-WordOverlap {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [string]$Source,
        [string]$Target
    )

    # Extract meaningful words (3+ chars), lowercase
    $sourceWords = @(($Source.ToLower() -replace '[^a-z0-9\s]', ' ' -split '\s+') | Where-Object { $_.Length -ge 2 } | Sort-Object -Unique)
    $targetWords = @(($Target.ToLower() -replace '[^a-z0-9\s]', ' ' -split '\s+') | Where-Object { $_.Length -ge 2 } | Sort-Object -Unique)

    if ($sourceWords.Count -eq 0 -or $targetWords.Count -eq 0) { return 0.0 }

    # Count overlapping words
    $overlap = 0
    foreach ($sw in $sourceWords) {
        foreach ($tw in $targetWords) {
            if ($sw -eq $tw) { $overlap++; break }
            # Partial match for substrings (e.g., "auth" matches "authentication")
            if ($sw.Length -ge 3 -and $tw.Length -ge 3) {
                if ($tw.StartsWith($sw) -or $sw.StartsWith($tw)) { $overlap += 0.7; break }
            }
        }
    }

    $union = @($sourceWords + $targetWords | Sort-Object -Unique).Count
    if ($union -eq 0) { return 0.0 }

    return [Math]::Round($overlap / $union, 3)
}

function Get-CanonicalMapping {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string[]]$SourceKeys,
        [hashtable]$LearnedSchema
    )

    $mapping = @{}      # source key -> canonical name
    $scores = @{}       # source key -> match score
    $unmapped = @()

    foreach ($srcKey in $SourceKeys) {
        # Skip metadata keys
        if ($srcKey.StartsWith('_')) { continue }

        $srcClean = $srcKey.Trim()
        $srcLower = ($srcClean.ToLower() -replace '\s+', ' ')

        # Check learned schema first
        if ($LearnedSchema -and $LearnedSchema.ContainsKey($srcClean)) {
            $mapping[$srcClean] = $LearnedSchema[$srcClean]
            $scores[$srcClean] = 1.0
            continue
        }

        $bestMatch = $null
        $bestScore = 0.0

        # MultiSection keys arrive as "SECTION.Question" -- also try the bare
        # question so section prefixes do not defeat the alias matching
        $candidates = @($srcLower)
        if ($srcLower.Contains('.')) {
            $suffix = @($srcLower -split '\.')[-1].Trim()
            if ($suffix -ne '' -and $suffix -ne $srcLower) { $candidates += $suffix }
        }

        foreach ($cand in $candidates) {
            foreach ($canonical in $script:CanonicalFields.Keys) {
                $aliases = $script:CanonicalFields[$canonical]

                # Check exact alias match first
                foreach ($alias in $aliases) {
                    if ($cand -eq $alias) {
                        $bestMatch = $canonical
                        $bestScore = 1.0
                        break
                    }
                }
                if ($bestScore -ge 1.0) { break }

                # Check alias containment -- coverage-weighted so a long,
                # specific alias ("does your application have service accounts")
                # outranks a generic word ("owner") inside the same source key
                foreach ($alias in $aliases) {
                    if ($cand.Contains($alias) -or $alias.Contains($cand)) {
                        $coverage = [Math]::Min($cand.Length, $alias.Length) / [Math]::Max($cand.Length, $alias.Length)
                        $score = [Math]::Round(0.72 + (0.26 * $coverage), 3)
                        if ($score -gt $bestScore) {
                            $bestMatch = $canonical
                            $bestScore = $score
                        }
                    }
                }

                # Fuzzy word overlap against all aliases
                foreach ($alias in $aliases) {
                    $score = Measure-WordOverlap -Source $cand -Target $alias
                    # Boost score slightly based on word order similarity
                    if ($score -gt $bestScore) {
                        $bestMatch = $canonical
                        $bestScore = $score
                    }
                }
            }
            if ($bestScore -ge 1.0) { break }
        }

        if ($bestScore -ge $script:Config.MinMappingScore -and $bestMatch) {
            $mapping[$srcClean] = $bestMatch
            $scores[$srcClean] = [Math]::Round($bestScore, 2)
        }
        else {
            $unmapped += $srcClean
        }
    }

    return @{
        Mapping  = $mapping
        Scores   = $scores
        Unmapped = $unmapped
    }
}

function ConvertTo-CanonicalRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Record,
        [Parameter(Mandatory)] [hashtable]$MappingResult
    )

    $canonical = [ordered]@{}
    $unmappedData = [ordered]@{}
    $mapping = $MappingResult.Mapping
    $scores = $MappingResult.Scores

    foreach ($prop in $Record.PSObject.Properties) {
        $key = $prop.Name
        if ($key.StartsWith('_')) {
            $canonical[$key] = $prop.Value
            continue
        }
        if ($mapping.ContainsKey($key)) {
            $canonicalName = $mapping[$key]
            # First mapped source key wins when several map to the same
            # canonical field; later values are preserved as unmapped data
            if (-not $canonical.Contains($canonicalName) -or "$($canonical[$canonicalName])".Trim() -eq '') {
                $canonical[$canonicalName] = $prop.Value
            }
            else {
                $unmappedData[$key] = $prop.Value
            }
        }
        else {
            $unmappedData[$key] = $prop.Value
        }
    }

    # Calculate average mapping confidence
    $confScores = @($scores.Values)
    $avgConf = if ($confScores.Count -gt 0) { [Math]::Round(($confScores | Measure-Object -Average).Average, 2) } else { 0 }
    $canonical['_mappingConfidence'] = $avgConf
    $canonical['_unmappedCount'] = $unmappedData.Count
    if ($unmappedData.Count -gt 0) {
        $canonical['_unmappedFields'] = ($unmappedData.Keys -join '; ')
        $canonical['_unmappedValues'] = ($unmappedData.Values -join '; ')
        # Structured pairs: the joined strings above misalign when answers
        # themselves contain '; ' -- exports use this instead
        $canonical['_unmappedData'] = @($unmappedData.Keys | ForEach-Object {
            [PSCustomObject]@{ question = $_; answer = "$($unmappedData[$_])" }
        })
    }

    return [PSCustomObject]$canonical
}
#endregion

#region Value Normalization

$script:BooleanFields = @(
    'hasMfa', 'hasApi', 'adIntegration',
    'sp_canExportCsv', 'sp_apiSupportsWrite', 'sp_v2AccountType', 'sp_v2LastLogin', 'sp_v2RiskLevel',
    'ca_canChangePasswordViaApi', 'ca_marketplace', 'ca_modifySecurity', 'ca_manageUsers',
    'ca_sensitiveData', 'ca_impactScope', 'ca_managesInfra',
    'okta_hasScimProvisioning'
)

$script:NormalizationRules = @{
    boolean = @{
        yes     = @('yes', 'y', 'true', '1', 'yep', 'enabled')
        no      = @('no', 'n', 'false', '0', 'nope', 'none', 'disabled')
        unknown = @('unknown', 'unsure', 'n/a', 'tbd', '?')
    }
    deploymentType = @{
        'SaaS'     = @('saas', 'cloud', 'hosted', 'cloud-hosted', 'cloud hosted', 'software as a service')
        'On-Prem'  = @('on-prem', 'on prem', 'onprem', 'on-premises', 'on premises', 'self-hosted', 'self hosted', 'internal')
        'Hybrid'   = @('hybrid', 'mixed', 'both', 'cloud and on-prem', 'on-prem and cloud')
    }
    authMethod = @{
        'SAML'     = @('saml', 'saml 2.0', 'saml2')
        'OIDC'     = @('oidc', 'openid', 'openid connect', 'oauth oidc')
        'OAuth'    = @('oauth', 'oauth 2.0', 'oauth2')
        'LDAP'     = @('ldap', 'ldaps', 'active directory ldap')
        'Password' = @('password', 'local password', 'username password', 'form-based', 'form based')
        'Kerberos' = @('kerberos', 'windows auth', 'integrated windows authentication', 'iwa')
        'SSO'      = @('sso', 'single sign-on', 'single sign on', 'federated sso')
        'MFA'      = @('mfa', 'multi-factor', 'multifactor')
    }
    mfaType = @{
        'Authenticator App' = @('authenticator app', 'totp', 'google authenticator', 'microsoft authenticator', 'authy', 'app-based mfa')
        'SMS'               = @('sms', 'text message', 'text', 'sms otp')
        'Email OTP'         = @('email otp', 'email code', 'email one-time password')
        'Hardware Token'    = @('hardware token', 'yubikey', 'fido', 'fido2', 'security key', 'hard token')
        'Push'              = @('push', 'push notification', 'okta verify push', 'duo push')
        'Biometric'         = @('biometric', 'fingerprint', 'face id', 'touch id', 'windows hello')
    }
    ca_adminMfaType = @{
        'Authenticator App' = @('authenticator app', 'totp', 'google authenticator', 'microsoft authenticator', 'authy')
        'SMS'               = @('sms', 'text message', 'text', 'sms otp')
        'Email OTP'         = @('email otp', 'email code', 'email one-time password')
        'Hardware Token'    = @('hardware token', 'yubikey', 'fido', 'fido2', 'security key', 'hard token')
        'Push'              = @('push', 'push notification', 'okta verify push', 'duo push')
        'Biometric'         = @('biometric', 'fingerprint', 'face id', 'touch id', 'windows hello')
    }
    ca_hlaPriority = @{
        'P0' = @('p0', 'priority 0', 'critical', 'tier 0')
        'P1' = @('p1', 'priority 1', 'high', 'tier 1')
        'P2' = @('p2', 'priority 2', 'medium', 'tier 2')
        'P3' = @('p3', 'priority 3', 'low', 'tier 3')
    }
    okta_signOnMode = @{
        'SAML 2.0'         = @('saml', 'saml 2.0', 'saml2')
        'OIDC'             = @('oidc', 'openid connect', 'openid')
        'SWA'              = @('swa', 'secure web authentication', 'form-based sso', 'form based sso')
        'WS-Federation'    = @('ws-fed', 'ws-federation', 'wsfed')
        'Bookmark'         = @('bookmark', 'link', 'no sso', 'bookmark app')
        'Auto Login'       = @('auto login', 'autologin', 'plugin')
    }
}

function Normalize-FieldValue {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Record
    )

    $out = [ordered]@{}
    foreach ($prop in $Record.PSObject.Properties) {
        $key = $prop.Name
        $val = $prop.Value

        if ($null -eq $val -or "$val".Trim() -eq '') {
            $out[$key] = $val
            continue
        }

        $strVal = "$val".Trim()
        $lower  = $strVal.ToLower()

        # Boolean normalization
        if ($script:BooleanFields -contains $key) {
            if ($script:NormalizationRules.boolean.yes -contains $lower) {
                $out[$key] = 'Yes'
            }
            elseif ($script:NormalizationRules.boolean.no -contains $lower) {
                $out[$key] = 'No'
            }
            elseif ($script:NormalizationRules.boolean.unknown -contains $lower) {
                $out[$key] = 'Unknown'
            }
            else {
                $out[$key] = $strVal
            }
            continue
        }

        # Named-map normalization for specific fields
        $ruleKey = $null
        switch ($key) {
            'deploymentType'  { $ruleKey = 'deploymentType' }
            'authMethod'      { $ruleKey = 'authMethod' }
            'mfaType'         { $ruleKey = 'mfaType' }
            'ca_adminMfaType' { $ruleKey = 'ca_adminMfaType' }
            'ca_hlaPriority'  { $ruleKey = 'ca_hlaPriority' }
            'okta_signOnMode' { $ruleKey = 'okta_signOnMode' }
        }

        if ($ruleKey -and $script:NormalizationRules.ContainsKey($ruleKey)) {
            $matched = $false
            foreach ($canonical in $script:NormalizationRules[$ruleKey].Keys) {
                $aliases = $script:NormalizationRules[$ruleKey][$canonical]
                foreach ($alias in $aliases) {
                    if ($lower -eq $alias -or $lower.Contains($alias)) {
                        $out[$key] = $canonical
                        $matched = $true
                        break
                    }
                }
                if ($matched) { break }
            }
            if (-not $matched) { $out[$key] = $strVal }
            continue
        }

        $out[$key] = $strVal
    }

    return [PSCustomObject]$out
}
#endregion

#region Merge & Consolidate

function Get-FileAppName {
    <#
        Extracts the app name from template-convention file names like
        "Versify_Application Team General Questionaire v1.1.xlsx" or
        "Versify_CyberArk Questionnaire.xlsx". Returns $null when the file
        name does not follow a recognizable "<AppName>_<Template>" pattern.
    #>
    [OutputType([string])]
    param([string]$FileName)

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($stem -match '^(?<app>.+?)[ _-]+(application\b|general question|question\w*aire|cyberark|sailpoint|okta|intake|onboarding)') {
        $app = $Matches['app'].Trim(' _-'.ToCharArray())
        # Reject product/template words masquerading as the app name
        if ($app -ne '' -and $app -notmatch '^(?i)(sailpoint|cyberark|okta|entra|iam|general|application|app)$') {
            return $app
        }
    }
    return $null
}

function Get-NormalizedAppKey {
    <#
        Collapses vendor-style app name variants to one merge key:
        "Salesforce.com", "Salesforce" -> salesforce
        "ServiceNow (SNOW)", "Service Now" -> servicenow
    #>
    [OutputType([string])]
    param([string]$Name)

    $n = $Name.ToLower().Trim()
    $n = $n -replace '\([^)]*\)', ' '                       # parentheticals: "(SNOW)"
    $n = $n -replace '\.(com|net|org|io|cloud|app)\b', ' '  # domain suffixes: ".com"
    $n = $n -replace '\b(inc|llc|corp|ltd)\b', ' '          # company suffixes
    $n = $n -replace '[^a-z0-9]', ''                        # punctuation / whitespace
    return $n
}

function Merge-AppRecords {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]]$Records
    )

    # Group by normalized app name so name variants land in the same bucket
    $groups = @{}
    foreach ($rec in $Records) {
        $rawName = if ($rec.PSObject.Properties['appName']) { "$($rec.appName)".Trim() } else { '' }
        if ($rawName -eq '') {
            # Try to derive app name from filename
            $rawName = if ($rec.PSObject.Properties['_sourceFile']) {
                [System.IO.Path]::GetFileNameWithoutExtension($rec._sourceFile)
            } else { "unknown_$([guid]::NewGuid().ToString().Substring(0,8))" }
        }
        # The filename-derived app name (when present) is the strongest merge
        # anchor -- in-sheet names often hold DB/instance names instead
        $fileApp = if ($rec.PSObject.Properties['_fileAppName']) { "$($rec._fileAppName)".Trim() } else { '' }
        $keyBasis = if ($fileApp -ne '') { $fileApp } else { $rawName }
        $key = Get-NormalizedAppKey -Name $keyBasis
        if ($key -eq '') { $key = $keyBasis.ToLower() }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += [PSCustomObject]@{ Raw = $rawName; Rec = $rec }
    }

    # Merge records within each group
    $merged = @()
    foreach ($name in $groups.Keys | Sort-Object) {
        $entries = $groups[$name]
        $rawNames = @($entries | ForEach-Object { $_.Raw })

        # Display name: prefer a variant that matches the merge key (e.g. the
        # filename-derived name), then fall back to the most frequent variant
        $keyMatched = @($rawNames | Where-Object { (Get-NormalizedAppKey -Name $_) -eq $name })
        $displayName = if ($keyMatched.Count -gt 0) {
            @($keyMatched | Group-Object | Sort-Object Count -Descending)[0].Name
        } else {
            @($rawNames | Group-Object | Sort-Object Count -Descending)[0].Name
        }
        $variants = @($rawNames | Sort-Object -Unique)

        $mergedRecord = [ordered]@{}
        $sourceFiles = @()
        $conflicts = [System.Collections.ArrayList]::new()
        $unmappedAll = [System.Collections.ArrayList]::new()

        foreach ($entry in $entries) {
            $rec = $entry.Rec
            $recSource = if ($rec.PSObject.Properties['_sourceFile']) { "$($rec._sourceFile)" } else { '?' }
            foreach ($prop in $rec.PSObject.Properties) {
                $key = $prop.Name

                # Structured (non-scalar) properties must not be stringified --
                # accumulate them across the group's records instead
                if ($key -eq '_unmappedData') {
                    if ($prop.Value) { $unmappedAll.AddRange(@($prop.Value)) }
                    continue
                }

                $val = "$($prop.Value)".Trim()

                if ($key -eq '_sourceFile') { $sourceFiles += $val; continue }
                if ($key -eq '_sheetName' -or $key -eq '_format') { continue }
                if ($val -eq '') { continue }

                # Non-empty value wins; first value wins ties
                if (-not $mergedRecord.Contains($key) -or "$($mergedRecord[$key])".Trim() -eq '') {
                    $mergedRecord[$key] = $val
                }
                elseif (-not $key.StartsWith('_') -and $key -ne 'appName' -and
                        "$($mergedRecord[$key])".Trim() -ne $val) {
                    # Different sources disagree: first value is kept, but the
                    # disagreement is preserved (structured) so an SME can review it
                    [void]$conflicts.Add([PSCustomObject]@{
                        field   = $key
                        kept    = "$($mergedRecord[$key])"
                        ignored = $val
                        source  = $recSource
                    })
                }
            }
        }

        $mergedRecord['appName'] = $displayName
        if ($variants.Count -gt 1) { $mergedRecord['_nameVariants'] = $variants -join '; ' }
        if ($conflicts.Count -gt 0) {
            $mergedRecord['_conflictCount'] = $conflicts.Count
            # Display string is DERIVED from the structured data, never parsed back
            $mergedRecord['_conflicts'] = (@($conflicts | ForEach-Object {
                "$($_.field): kept '$($_.kept)', ignored '$($_.ignored)' (from $($_.source))"
            }) -join ' | ')
            $mergedRecord['_conflictsData'] = @($conflicts)
        }
        if ($unmappedAll.Count -gt 0) { $mergedRecord['_unmappedData'] = @($unmappedAll) }
        $mergedRecord['_sourceFiles'] = ($sourceFiles | Sort-Object -Unique) -join '; '
        $mergedRecord['_recordCount'] = $entries.Count
        $merged += [PSCustomObject]$mergedRecord
    }

    return $merged
}
#endregion

#region Output

function ConvertTo-AppExport {
    <#
        Converts a merged app record into the canonical export object used by
        the JSON payload, the XLSX workbook and the HTML browser:
        fields (group-ordered), details (rehydrated _detail_* JSON), conflicts,
        unmapped pairs, provenance and a completeness score.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Record
    )

    $groups = Get-EffectiveFieldGroups
    $props = $Record.PSObject.Properties

    # Canonical fields in display-group order + completeness
    $fields = [ordered]@{}
    $totalFields = 0
    $populated = 0
    foreach ($g in $groups.Keys) {
        foreach ($f in $groups[$g]) {
            $totalFields++
            if ($props[$f] -and "$($Record.$f)".Trim() -ne '') {
                $fields[$f] = "$($Record.$f)"
                $populated++
            }
        }
    }

    # Rehydrate detail blobs (roles/groups/accounts/entitlement tables)
    $details = [ordered]@{}
    foreach ($p in @($props | Where-Object { $_.Name -like '_detail_*' })) {
        $suffix = $p.Name.Substring('_detail_'.Length)
        try { $details[$suffix] = @("$($p.Value)" | ConvertFrom-Json) }
        catch { $details[$suffix] = @() }
    }

    $conflicts = if ($props['_conflictsData']) { @($Record._conflictsData) } else { @() }
    $unmapped = if ($props['_unmappedData']) { @($Record._unmappedData) } else { @() }
    $variants = if ($props['_nameVariants']) { @("$($Record._nameVariants)" -split ';\s*') } else { @("$($Record.appName)") }
    $sources = if ($props['_sourceFiles']) { @("$($Record._sourceFiles)" -split ';\s*') } else { @() }

    return [PSCustomObject][ordered]@{
        appName           = "$($Record.appName)"
        appKey            = (Get-NormalizedAppKey -Name "$($Record.appName)")
        nameVariants      = $variants
        sourceFiles       = $sources
        recordCount       = $(if ($props['_recordCount']) { [int]$Record._recordCount } else { 1 })
        mappingConfidence = $(if ($props['_mappingConfidence']) { [double]$Record._mappingConfidence } else { $null })
        completeness      = $(if ($totalFields -gt 0) { [Math]::Round($populated / $totalFields, 2) } else { 0 })
        fields            = $fields
        details           = $details
        conflicts         = $conflicts
        unmapped          = $unmapped
    }
}

function Export-ConsolidatedJson {
    <#
        Writes the canonical JSON payload: a date-stamped file plus a
        stable-named alias (IAM-Intake-Data.json) so downstream consumers --
        including the future intake-tool import -- have a predictable name.
        Returns the JSON text for reuse (the HTML browser embeds it verbatim).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]]$Apps,
        [Parameter(Mandatory)] [string]$OutputDirectory,
        [string]$SourcePath,
        [int]$FilesProcessed,
        [int]$RecordsExtracted
    )

    $payload = [ordered]@{
        schemaVersion = '1.0'
        generated     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        generator     = 'Merge-IAMIntakeData.ps1'
        sourcePath    = $SourcePath
        stats         = [ordered]@{
            filesProcessed   = $FilesProcessed
            recordsExtracted = $RecordsExtracted
            apps             = $Apps.Count
        }
        fieldGroups   = (Get-EffectiveFieldGroups)
        apps          = @($Apps)
    }

    # Default -Depth (2) silently truncates nested details -- 10 is enough for
    # fields/details/conflicts and cheap
    $json = ConvertTo-Json -InputObject $payload -Depth 10

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $datedPath = Join-Path $OutputDirectory "IAM-Intake-$script:DateStamp.json"
    [System.IO.File]::WriteAllText($datedPath, $json, $utf8NoBom)
    Write-Host "  Exported: $datedPath" -ForegroundColor Green

    $aliasPath = Join-Path $OutputDirectory 'IAM-Intake-Data.json'
    [System.IO.File]::WriteAllText($aliasPath, $json, $utf8NoBom)
    Write-Host "  Exported: $aliasPath (stable alias)" -ForegroundColor Green

    return $json
}

function Protect-CellValue {
    <# Excel treats a leading '=' as a formula and swallows the value on
       import -- prefix with an apostrophe so the text survives verbatim. #>
    [OutputType([string])]
    param([string]$Value)
    if ($Value -and $Value.StartsWith('=')) { return "'" + $Value }
    return $Value
}

function Export-ConsolidatedXlsx {
    <#
        Writes the single consolidated workbook:
        Master / per-product sheets / RolesGroups / Accounts / Conflicts /
        Unmapped / Log. Each sheet is an Excel table (filterable) with a
        frozen, bold header row. Sheets with no rows are skipped.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]]$Records,
        [Parameter(Mandatory)] [PSCustomObject[]]$Apps,
        [Parameter(Mandatory)] [string]$FilePath,
        [System.Collections.IDictionary]$ProductColumns,
        [PSCustomObject[]]$ProcessingLog
    )

    # Regenerate cleanly -- Export-Excel appends into existing workbooks
    if (Test-Path -LiteralPath $FilePath) { Remove-Item -LiteralPath $FilePath -Force -Confirm:$false }

    $xlCommon = @{ Path = $FilePath; FreezeTopRow = $true; BoldTopRow = $true; AutoSize = $true }

    $newSheetRow = {
        param($rec, [string[]]$cols)
        $row = [ordered]@{}
        $props = $rec.PSObject.Properties
        foreach ($c in $cols) {
            $v = if ($props[$c]) { "$($rec.$c)" } else { '' }
            $row[$c] = Protect-CellValue $v
        }
        return [PSCustomObject]$row
    }

    # --- Master: canonical fields in display-group order + provenance ---
    $groups = Get-EffectiveFieldGroups
    $masterCols = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $groups.Keys) {
        foreach ($f in $groups[$g]) { if (-not $masterCols.Contains($f)) { $masterCols.Add($f) } }
    }
    foreach ($m in @('_nameVariants', '_conflictCount', '_conflicts', '_unmappedCount',
                     '_mappingConfidence', '_recordCount', '_sourceFiles')) { $masterCols.Add($m) }
    $masterRows = @($Records | ForEach-Object { & $newSheetRow $_ $masterCols })
    if ($masterRows.Count -gt 0) {
        $masterRows | Export-Excel @xlCommon -WorksheetName 'Master' -TableName 'Master'
    }

    # --- Per-product sheets (same column sets as the per-product CSVs) ---
    if ($ProductColumns) {
        foreach ($sheetName in $ProductColumns.Keys) {
            $rows = @($Records | ForEach-Object { & $newSheetRow $_ @($ProductColumns[$sheetName]) })
            if ($rows.Count -gt 0) {
                $rows | Export-Excel @xlCommon -WorksheetName $sheetName -TableName $sheetName
            }
        }
    }

    # --- RolesGroups: flattened detail rows (fixed columns; detail schemas
    #     are heterogeneous, so remaining captions collapse into Extra) ---
    $rgRows = @()
    $acctRows = @()
    foreach ($app in $Apps) {
        foreach ($detailKey in @($app.details.Keys)) {
            $rows = @($app.details[$detailKey])
            if ($detailKey -match '(?i)account') {
                foreach ($r in $rows) {
                    $p = $r.PSObject.Properties
                    $acctRows += [PSCustomObject]@{
                        App                  = $app.appName
                        AccountName          = if ($p['AccountName']) { "$($r.AccountName)" } else { "$(@($p)[0].Value)" }
                        Type                 = if ($p['Type']) { "$($r.Type)" } else { '' }
                        Class                = if ($p['Class']) { "$($r.Class)" } else { '' }
                        PasswordDependencies = if ($p['Pwd']) { "$($r.Pwd)" } else { '' }
                        UsersWithAccess      = if ($p['Users']) { "$($r.Users)" } else { '' }
                    }
                }
                continue
            }
            foreach ($r in $rows) {
                $p = @($r.PSObject.Properties)
                if ($p.Count -eq 0) { continue }
                # Prefer a column whose caption ends in "name" ("Name",
                # "Display Name", "Role Name"); first column otherwise. In
                # entitlement schemas the FIRST column is the type, not the name.
                $nameProp = $p | Where-Object { $_.Name -match '(?i)name$' } | Select-Object -First 1
                if (-not $nameProp) { $nameProp = $p[0] }
                $name = "$($nameProp.Value)"
                $descProp = $p | Where-Object { $_.Name -match '(?i)desc' } | Select-Object -First 1
                $type = if ("$($p[0].Value) $($p[0].Name) $detailKey" -match '(?i)group') { 'Group' }
                        elseif ("$($p[0].Value) $($p[0].Name) $detailKey" -match '(?i)role') { 'Role' }
                        else { 'Item' }
                $extra = @($p | Where-Object { $_ -ne $nameProp -and $_ -ne $descProp -and "$($_.Value)" -ne '' } |
                    ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
                $rgRows += [PSCustomObject]@{
                    App         = $app.appName
                    Source      = $detailKey
                    Type        = $type
                    Name        = Protect-CellValue $name
                    Description = if ($descProp) { Protect-CellValue "$($descProp.Value)" } else { '' }
                    Extra       = Protect-CellValue $extra
                }
            }
        }
    }
    if ($rgRows.Count -gt 0) {
        $rgRows | Export-Excel @xlCommon -WorksheetName 'RolesGroups' -TableName 'RolesGroups'
    }
    if ($acctRows.Count -gt 0) {
        $acctRows | Export-Excel @xlCommon -WorksheetName 'Accounts' -TableName 'Accounts'
    }

    # --- Conflicts: one row per disagreement (the SME review queue) ---
    $conflictRows = @()
    foreach ($app in $Apps) {
        foreach ($c in @($app.conflicts)) {
            $conflictRows += [PSCustomObject]@{
                App     = $app.appName
                Field   = $c.field
                Kept    = Protect-CellValue "$($c.kept)"
                Ignored = Protect-CellValue "$($c.ignored)"
                Source  = $c.source
            }
        }
    }
    if ($conflictRows.Count -gt 0) {
        $conflictRows | Export-Excel @xlCommon -WorksheetName 'Conflicts' -TableName 'Conflicts'
    }

    # --- Unmapped: questions the canonical mapping did not recognize ---
    $unmappedRows = @()
    foreach ($app in $Apps) {
        foreach ($u in @($app.unmapped)) {
            $unmappedRows += [PSCustomObject]@{
                App      = $app.appName
                Question = Protect-CellValue "$($u.question)"
                Answer   = Protect-CellValue "$($u.answer)"
            }
        }
    }
    if ($unmappedRows.Count -gt 0) {
        $unmappedRows | Export-Excel @xlCommon -WorksheetName 'Unmapped' -TableName 'Unmapped'
    }

    # --- Log: per-sheet processing results ---
    if ($ProcessingLog -and @($ProcessingLog).Count -gt 0) {
        @($ProcessingLog) | Export-Excel @xlCommon -WorksheetName 'Log' -TableName 'Log'
    }

    Write-Host "  Exported: $FilePath" -ForegroundColor Green
}

function Export-ConsolidatedCsv {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]]$Records,
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ColumnFilter
    )

    if ($Records.Count -eq 0) {
        Write-Warning "No records to export to $FilePath"
        return
    }

    # Structured (non-scalar) properties are for JSON/XLSX exports only --
    # rendering them into CSV cells would emit "System.Object[]"
    $nonScalarProps = @('_conflictsData', '_unmappedData')

    # Merged records may have differing property sets (fields present on one app
    # but not another), so column decisions must consider ALL records -- not just
    # the first -- or later-sorted apps silently lose fields.
    $allProps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rec in $Records) {
        foreach ($p in $rec.PSObject.Properties.Name) {
            if ($p -in $nonScalarProps) { continue }
            [void]$allProps.Add($p)
        }
    }

    $filtered = if ($ColumnFilter) {
        $Records | Select-Object -Property ($ColumnFilter | Where-Object {
            $allProps.Contains($_)
        })
    } else {
        $Records
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $sb = New-Object System.Text.StringBuilder 8192

    # Headers -- union of all record properties, preserving first-seen order
    $headers = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rec in $filtered) {
        foreach ($p in $rec.PSObject.Properties.Name) {
            if ($p -in $nonScalarProps) { continue }
            if ($seen.Add($p)) { $headers.Add($p) }
        }
    }
    [void]$sb.AppendLine(($headers | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')

    # Data rows
    foreach ($rec in $filtered) {
        $row = @()
        foreach ($h in $headers) {
            $val = if ($rec.PSObject.Properties[$h]) { "$($rec.$h)" } else { '' }
            $row += ConvertTo-CsvField $val
        }
        [void]$sb.AppendLine($row -join ',')
    }

    $dir = Split-Path $FilePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($FilePath, $sb.ToString(), $utf8NoBom)
    Write-Host "  Exported: $FilePath ($($filtered.Count) records)" -ForegroundColor Green
}

function ConvertTo-CsvField {
    [OutputType([string])]
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -match '[,"\r\n]') { return '"' + ($Value -replace '"', '""') + '"' }
    return $Value
}

function Export-AppBrowserHtml {
    <#
        Writes the self-contained interactive app browser. The canonical JSON
        payload is embedded in an inert <script type="application/json"> block
        and rendered client-side with vanilla JS.

        SECURITY NOTE (inverts this repo's usual "HtmlEncode in PowerShell"
        convention): the JSON block only needs '</' escaped to '<\/' so the
        payload cannot break out of its script tag. Encoding happens at RENDER
        time instead -- the JS below only ever assigns dynamic values (field
        values, detail-table captions, app names) via textContent/createElement,
        never innerHTML, so spreadsheet-sourced content cannot inject markup.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [string]$Json,
        [Parameter(Mandatory)] [string]$FilePath
    )

    $safeJson = $Json -replace '</', '<\/'

    $template = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>IAM Intake App Browser</title>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, 'Segoe UI', system-ui, Roboto, Helvetica, Arial, sans-serif; color: #1a1a2e; background: #f4f6fa; line-height: 1.6; }
.hero { background: linear-gradient(135deg, #1b2a4a 0%, #2d5a8a 60%, #3a7bc8 100%); color: #fff; padding: 28px 32px; }
.hero h1 { font-size: 1.5rem; }
.hero .meta { color: #b8d4f0; font-size: .85rem; margin-top: 4px; }
.container { max-width: 1200px; margin: 0 auto; padding: 24px; }
.stats { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 20px; }
.stat-card { background: #fff; border-radius: 8px; padding: 14px 20px; box-shadow: 0 2px 6px rgba(0,0,0,.06); flex: 1; min-width: 160px; }
.stat-card .stat-value { font-size: 1.7rem; font-weight: 700; color: #1b2a4a; }
.stat-card .stat-label { font-size: .78rem; color: #666; }
.controls { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; align-items: center; }
.controls select, .controls input { padding: 9px 12px; border: 1px solid #c6cede; border-radius: 8px; font-size: .95rem; background: #fff; min-width: 260px; }
.controls select:focus, .controls input:focus { outline: 2px solid #2d5a8a; }
.card { background: #fff; border-radius: 10px; box-shadow: 0 2px 8px rgba(0,0,0,.06); margin-bottom: 20px; overflow: hidden; }
.card-header { padding: 14px 20px; border-bottom: 1px solid #dde2ea; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; }
.card-header h2 { font-size: 1.1rem; color: #1b2a4a; }
.card-body { padding: 14px 20px; }
table { width: 100%; border-collapse: collapse; font-size: .85rem; }
th { text-align: left; padding: 8px 10px; background: #eef1f6; color: #1b2a4a; font-size: .75rem; text-transform: uppercase; letter-spacing: .03em; }
td { padding: 7px 10px; border-bottom: 1px solid #f0f2f5; vertical-align: top; }
tr:hover td { background: #f6f9fd; }
#overviewTable tbody tr { cursor: pointer; }
.section-label { font-size: .75rem; font-weight: 700; color: #fff; padding: 4px 12px; border-radius: 4px; margin: 14px 0 6px; display: inline-block; background: #2d5a8a; }
.sl-sp { background: #0033a0; } .sl-ca { background: #d4213d; } .sl-okta { background: #007dc1; }
.field-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 24px; }
.field-row { display: flex; justify-content: space-between; gap: 12px; padding: 6px 10px; border-bottom: 1px solid #f0f2f5; font-size: .85rem; }
.field-row:nth-child(odd) { background: #fafbfc; }
.field-row .fl { color: #666; min-width: 150px; }
.field-row .fv { font-weight: 500; text-align: right; overflow-wrap: anywhere; }
.badge { display: inline-block; font-size: .7rem; font-weight: 600; padding: 2px 8px; border-radius: 10px; }
.b-high { background: #d4edda; color: #1b5e30; } .b-med { background: #fff3cd; color: #7a5e00; } .b-low { background: #fde4e1; color: #9b2c2c; }
.conflicts { background: #fff8e6; border: 1px solid #f0d48a; border-radius: 10px; margin-bottom: 20px; overflow: hidden; }
.conflicts .card-header { background: #fdf3d7; border-bottom: 1px solid #f0d48a; }
.conflicts .card-header h2 { color: #7a5e00; }
.meter { background: #e6eaf1; border-radius: 6px; height: 10px; width: 110px; overflow: hidden; display: inline-block; vertical-align: middle; }
.meter > span { display: block; height: 100%; background: #00897b; }
.prov { font-size: .82rem; color: #555; }
.prov b { color: #1b2a4a; }
.muted { color: #888; font-style: italic; }
.tbl-wrap { overflow-x: auto; }
@media (max-width: 768px) {
  .field-grid { grid-template-columns: 1fr; }
  .controls select, .controls input { min-width: 100%; }
}
@media print {
  .controls, #overviewCard { display: none; }
  .card, .conflicts { box-shadow: none; border: 1px solid #ccc; }
  body { background: #fff; }
}
</style>
</head>
<body>
<div class="hero">
  <h1>IAM Intake App Browser</h1>
  <div class="meta" id="heroMeta"></div>
</div>
<div class="container">
  <div class="stats" id="stats"></div>
  <div class="controls">
    <select id="appSelect" aria-label="Select application"></select>
    <input id="search" type="search" placeholder="Filter applications..." aria-label="Filter applications">
  </div>
  <div class="card" id="overviewCard">
    <div class="card-header"><h2>All Applications</h2></div>
    <div class="card-body tbl-wrap">
      <table id="overviewTable">
        <thead><tr><th>Application</th><th>Owner</th><th>Deployment</th><th>Authentication</th><th>Confidence</th><th>Completeness</th><th>Conflicts</th></tr></thead>
        <tbody></tbody>
      </table>
    </div>
  </div>
  <div id="appView"></div>
</div>
<script id="data" type="application/json">__JSON__</script>
<script>
(function() {
'use strict';
var DATA = JSON.parse(document.getElementById('data').textContent);

/* PowerShell's ConvertTo-Json can unwrap single-element arrays to scalars --
   normalize every array-ish value before use. */
function arr(x) {
  if (x === undefined || x === null) { return []; }
  return Array.isArray(x) ? x : [x];
}

var APPS = arr(DATA.apps);
var GROUPS = DATA.fieldGroups || {};

/* All dynamic values are rendered via textContent/createElement -- never
   innerHTML -- so questionnaire content cannot inject markup. */
function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) { n.className = cls; }
  if (text !== undefined && text !== null) { n.textContent = String(text); }
  return n;
}

function fieldLabel(name) {
  var label = name.replace(/^(sp|ca|okta)_/, '');
  label = label.replace(/([a-z0-9])([A-Z])/g, '$1 $2');
  return label.charAt(0).toUpperCase() + label.slice(1);
}

function confBadge(v) {
  var b = el('span', 'badge', v === null || v === undefined ? 'n/a' : v);
  var n = Number(v);
  b.className += (n >= 0.75) ? ' b-high' : (n >= 0.5) ? ' b-med' : ' b-low';
  return b;
}

function meter(frac) {
  var wrap = el('span', 'meter');
  var bar = el('span');
  bar.style.width = Math.round((Number(frac) || 0) * 100) + '%';
  wrap.appendChild(bar);
  var holder = el('span');
  holder.appendChild(wrap);
  holder.appendChild(document.createTextNode(' ' + Math.round((Number(frac) || 0) * 100) + '%'));
  return holder;
}

function renderHero() {
  var m = document.getElementById('heroMeta');
  m.textContent = 'Generated ' + (DATA.generated || '') + ' from ' +
    (DATA.stats ? DATA.stats.filesProcessed : '?') + ' source file(s) -- ' + (DATA.sourcePath || '');
}

function renderStats() {
  var host = document.getElementById('stats');
  host.textContent = '';
  var conflictTotal = 0, complSum = 0;
  APPS.forEach(function(a) { conflictTotal += arr(a.conflicts).length; complSum += Number(a.completeness) || 0; });
  var cards = [
    [APPS.length, 'Applications'],
    [DATA.stats ? DATA.stats.filesProcessed : 0, 'Source Files'],
    [conflictTotal, 'Open Conflicts'],
    [(APPS.length ? Math.round(complSum / APPS.length * 100) : 0) + '%', 'Avg Completeness']
  ];
  cards.forEach(function(c) {
    var card = el('div', 'stat-card');
    card.appendChild(el('div', 'stat-value', c[0]));
    card.appendChild(el('div', 'stat-label', c[1]));
    host.appendChild(card);
  });
}

function appMatches(app, q) {
  if (!q) { return true; }
  q = q.toLowerCase();
  if (app.appName.toLowerCase().indexOf(q) >= 0) { return true; }
  return arr(app.nameVariants).some(function(v) { return String(v).toLowerCase().indexOf(q) >= 0; });
}

function renderSelect(filter) {
  var sel = document.getElementById('appSelect');
  var current = sel.value;
  sel.textContent = '';
  sel.appendChild(new Option('-- All applications --', ''));
  APPS.forEach(function(a, i) {
    if (appMatches(a, filter)) { sel.appendChild(new Option(a.appName, String(i))); }
  });
  sel.value = current;
  if (sel.selectedIndex < 0) { sel.value = ''; }
}

function renderOverview(filter) {
  var tbody = document.querySelector('#overviewTable tbody');
  tbody.textContent = '';
  APPS.forEach(function(a, i) {
    if (!appMatches(a, filter)) { return; }
    var tr = document.createElement('tr');
    tr.appendChild(el('td', null, a.appName));
    tr.appendChild(el('td', null, (a.fields && a.fields.appOwnerName) || ''));
    tr.appendChild(el('td', null, (a.fields && a.fields.deploymentType) || ''));
    tr.appendChild(el('td', null, (a.fields && a.fields.authMethod) || ''));
    var tdConf = el('td'); tdConf.appendChild(confBadge(a.mappingConfidence)); tr.appendChild(tdConf);
    var tdCompl = el('td'); tdCompl.appendChild(meter(a.completeness)); tr.appendChild(tdCompl);
    tr.appendChild(el('td', null, arr(a.conflicts).length || ''));
    tr.addEventListener('click', function() {
      document.getElementById('appSelect').value = String(i);
      renderApp(i);
    });
    tbody.appendChild(tr);
  });
}

function detailTable(rows) {
  var cols = [];
  rows.forEach(function(r) {
    Object.keys(r || {}).forEach(function(k) { if (cols.indexOf(k) < 0) { cols.push(k); } });
  });
  var wrap = el('div', 'tbl-wrap');
  var table = document.createElement('table');
  var thead = document.createElement('thead');
  var trh = document.createElement('tr');
  cols.forEach(function(c) { trh.appendChild(el('th', null, c)); });
  thead.appendChild(trh);
  table.appendChild(thead);
  var tbody = document.createElement('tbody');
  rows.forEach(function(r) {
    var tr = document.createElement('tr');
    cols.forEach(function(c) { tr.appendChild(el('td', null, (r && r[c] !== undefined && r[c] !== null) ? r[c] : '')); });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  wrap.appendChild(table);
  return wrap;
}

function sectionClass(groupName) {
  if (groupName === 'SailPoint') { return 'section-label sl-sp'; }
  if (groupName === 'CyberArk') { return 'section-label sl-ca'; }
  if (groupName.indexOf('Okta') === 0) { return 'section-label sl-okta'; }
  return 'section-label';
}

function renderApp(idx) {
  var host = document.getElementById('appView');
  host.textContent = '';
  if (idx === '' || idx === null || idx === undefined) { return; }
  var app = APPS[Number(idx)];
  if (!app) { return; }

  // Provenance card
  var prov = el('div', 'card');
  var ph = el('div', 'card-header');
  ph.appendChild(el('h2', null, app.appName));
  ph.appendChild(confBadge(app.mappingConfidence));
  prov.appendChild(ph);
  var pb = el('div', 'card-body prov');
  var provLines = [
    ['Source files', arr(app.sourceFiles).join('; ')],
    ['Name variants', arr(app.nameVariants).join('; ')],
    ['Merged records', app.recordCount],
    ['Completeness', Math.round((Number(app.completeness) || 0) * 100) + '%']
  ];
  provLines.forEach(function(l) {
    var d = el('div');
    var b = el('b', null, l[0] + ': ');
    d.appendChild(b);
    d.appendChild(document.createTextNode(l[1] === undefined ? '' : l[1]));
    pb.appendChild(d);
  });
  prov.appendChild(pb);
  host.appendChild(prov);

  // Conflicts panel (only when present)
  var conflicts = arr(app.conflicts);
  if (conflicts.length > 0) {
    var cwrap = el('div', 'conflicts');
    var chead = el('div', 'card-header');
    chead.appendChild(el('h2', null, 'Conflicts to review (' + conflicts.length + ')'));
    cwrap.appendChild(chead);
    var cbody = el('div', 'card-body');
    cbody.appendChild(detailTable(conflicts.map(function(c) {
      return { Field: fieldLabel(c.field || ''), Kept: c.kept, Ignored: c.ignored, Source: c.source };
    })));
    cwrap.appendChild(cbody);
    host.appendChild(cwrap);
  }

  // Field sections per group
  var fieldsCard = el('div', 'card');
  var fbody = el('div', 'card-body');
  Object.keys(GROUPS).forEach(function(g) {
    var present = arr(GROUPS[g]).filter(function(f) {
      return app.fields && app.fields[f] !== undefined && String(app.fields[f]).trim() !== '';
    });
    if (present.length === 0) { return; }
    fbody.appendChild(el('span', sectionClass(g), g));
    var grid = el('div', 'field-grid');
    present.forEach(function(f) {
      var row = el('div', 'field-row');
      row.appendChild(el('span', 'fl', fieldLabel(f)));
      row.appendChild(el('span', 'fv', app.fields[f]));
      grid.appendChild(row);
    });
    fbody.appendChild(grid);
  });
  fieldsCard.appendChild(fbody);
  host.appendChild(fieldsCard);

  // Detail tables (roles, groups, accounts, entitlement schemas)
  var details = app.details || {};
  Object.keys(details).forEach(function(key) {
    var rows = arr(details[key]);
    if (rows.length === 0) { return; }
    var card = el('div', 'card');
    var h = el('div', 'card-header');
    h.appendChild(el('h2', null, key.replace(/_/g, ' ')));
    card.appendChild(h);
    var b = el('div', 'card-body');
    b.appendChild(detailTable(rows));
    card.appendChild(b);
    host.appendChild(card);
  });

  // Unmapped answers
  var unmapped = arr(app.unmapped);
  if (unmapped.length > 0) {
    var ucard = el('div', 'card');
    var uh = el('div', 'card-header');
    uh.appendChild(el('h2', null, 'Unmapped answers (' + unmapped.length + ')'));
    ucard.appendChild(uh);
    var ub = el('div', 'card-body');
    ub.appendChild(detailTable(unmapped.map(function(u) { return { Question: u.question, Answer: u.answer }; })));
    ucard.appendChild(ub);
    host.appendChild(ucard);
  }
}

document.getElementById('appSelect').addEventListener('change', function() { renderApp(this.value); });
document.getElementById('search').addEventListener('input', function() {
  renderSelect(this.value);
  renderOverview(this.value);
});

renderHero();
renderStats();
renderSelect('');
renderOverview('');
if (APPS.length === 1) { document.getElementById('appSelect').value = '0'; renderApp(0); }
})();
</script>
</body>
</html>
'@

    $html = $template.Replace('__JSON__', $safeJson)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path $FilePath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($FilePath, $html, $utf8NoBom)
    Write-Host "  Exported: $FilePath" -ForegroundColor Green
}
#endregion

#region Schema Save/Load

function Save-DetectedSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable[]]$MappingResults,
        [Parameter(Mandatory)] [string]$FilePath
    )

    $combined = @{}
    $allUnmapped = @()
    foreach ($mr in $MappingResults) {
        foreach ($key in $mr.Mapping.Keys) {
            if (-not $combined.ContainsKey($key)) {
                $combined[$key] = $mr.Mapping[$key]
            }
        }
        $allUnmapped += $mr.Unmapped
    }

    $schema = [ordered]@{
        version   = '1.0'
        created   = (Get-Date -Format 'yyyy-MM-dd')
        mappings  = $combined
        unmapped  = @($allUnmapped | Sort-Object -Unique)
    }

    $schema | ConvertTo-Json -Depth 4 | Set-Content -Path $FilePath -Encoding UTF8
    Write-Host "  Schema saved: $FilePath" -ForegroundColor Green
}

function Import-LearnedSchema {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$FilePath
    )

    $json = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
    $mapping = @{}
    foreach ($prop in $json.mappings.PSObject.Properties) {
        $mapping[$prop.Name] = $prop.Value
    }
    Write-Host "  Loaded schema: $FilePath ($($mapping.Count) mappings)" -ForegroundColor Cyan
    return $mapping
}
#endregion

#region Main

Write-Host ""
Write-Host "IAM Intake Data Consolidator" -ForegroundColor Cyan
Write-Host "----------------------------" -ForegroundColor DarkGray
Write-Host ""

# Resolve input path
$inputPath = Resolve-Path $Path
$excelFiles = @()

if (Test-Path $inputPath -PathType Leaf) {
    if ($inputPath -match '\.(xlsx?|docx)$') { $excelFiles = @(Get-Item $inputPath) }
}
else {
    $excelFiles = @(Get-ChildItem -Path $inputPath -Include '*.xlsx', '*.docx' -Recurse -File |
        Where-Object { $_.Name -notlike '~$*' } | Sort-Object Name)
}

if ($excelFiles.Count -eq 0) {
    Write-Warning "No .xlsx or .docx files found in: $inputPath"
    return
}

Write-Host "Found $($excelFiles.Count) file(s) in: $inputPath" -ForegroundColor White

# Load learned schema if provided
$learnedSchema = $null
if ($SchemaPath -and (Test-Path $SchemaPath)) {
    $learnedSchema = Import-LearnedSchema -FilePath $SchemaPath
}

# Process each file
$allRecords = @()
$allMappingResults = @()

foreach ($file in $excelFiles) {
    Write-Host ""
    Write-Host "Processing: $($file.Name)" -ForegroundColor Yellow

    $fileCanonical = @()   # all canonical records from this workbook

    # --- Word documents: parse tables/headings from the docx XML ---
    if ($file.Extension -match '^(?i)\.docx$') {
        $docRec = $null
        try { $docRec = Import-DocxFile -Path $file.FullName -SourceFile $file.Name }
        catch { Write-Warning "  Could not parse Word document: $($_.Exception.Message)" }
        if ($docRec) {
            Write-Host "    Format: Word document (docx tables)" -ForegroundColor DarkCyan
            $script:ProcessingLog.Add([PSCustomObject]@{
                File = $file.Name; Sheet = '(docx)'; Format = 'Docx'; Score = 1; Columns = 0; Records = 1
            })
            $sourceKeys = @($docRec.PSObject.Properties.Name)
            $mappingResult = Get-CanonicalMapping -SourceKeys $sourceKeys -LearnedSchema $learnedSchema
            $allMappingResults += $mappingResult
            Write-Host "    Mapped: $($mappingResult.Mapping.Count) fields, Unmapped: $($mappingResult.Unmapped.Count)" -ForegroundColor DarkCyan
            $canonicalRec = ConvertTo-CanonicalRecord -Record $docRec -MappingResult $mappingResult
            $canonicalRec = Normalize-FieldValue -Record $canonicalRec
            $fileCanonical += $canonicalRec
        }
        else {
            Write-Host "    (no extractable content)" -ForegroundColor DarkGray
        }
        $sheetNames = @()
    }
    else {
        try {
            $sheetNames = Get-ExcelSheetInfo -Path $file.FullName | Select-Object -ExpandProperty Name
        }
        catch {
            Write-Warning "  Could not read: $($file.Name) -- $($_.Exception.Message)"
            continue
        }
    }

    foreach ($sheet in $sheetNames) {
        Write-Host "  Sheet: $sheet" -ForegroundColor DarkGray

        try {
            $rawData = @(Import-Excel -Path $file.FullName -WorksheetName $sheet -ErrorAction Stop)
        }
        catch {
            Write-Warning "    Could not read sheet '$sheet': $($_.Exception.Message)"
            continue
        }

        if ($rawData.Count -eq 0) {
            Write-Host "    (empty sheet -- skipped)" -ForegroundColor DarkGray
            continue
        }

        # Structured questionnaire sheets (banners + block headers + guidance
        # columns) are parsed headerless -- Excel row 1 is NOT a header row
        $rawGrid = $null
        try { $rawGrid = @(Import-Excel -Path $file.FullName -WorksheetName $sheet -NoHeader -ErrorAction Stop) } catch { $rawGrid = $null }
        $extracted = @()
        if ($rawGrid -and (Test-StructuredSheet -RawData $rawGrid)) {
            Write-Host "    Format: Structured questionnaire (headerless block parse)" -ForegroundColor DarkCyan
            $script:ProcessingLog.Add([PSCustomObject]@{
                File    = $file.Name
                Sheet   = $sheet
                Format  = 'Structured'
                Score   = 1
                Columns = 0
                Records = 0
            })
            $structRec = Import-StructuredSheet -RawData $rawGrid -SourceFile $file.Name -SheetName $sheet
            if ($structRec) { $extracted = @($structRec) }
        }
        else {

        # Phase 1: Fingerprint
        $fingerprint = Get-SheetFingerprint -RawData $rawData -SheetName $sheet
        Write-Host "    Format: $($fingerprint.Format) (score: $($fingerprint.Score), cols: $($fingerprint.ColumnCount), rows: $($fingerprint.DataRows))" -ForegroundColor DarkCyan

        $script:ProcessingLog.Add([PSCustomObject]@{
            File    = $file.Name
            Sheet   = $sheet
            Format  = $fingerprint.Format
            Score   = $fingerprint.Score
            Columns = $fingerprint.ColumnCount
            Records = 0
        })

        if ($fingerprint.Format -eq 'Empty') { continue }

        # List sheets (roles/groups/entitlements) aggregate into the workbook's
        # app record instead of producing one bogus "app" per row
        $isListSheet = $false
        foreach ($pat in $script:Config.ListSheetPatterns) {
            if ($sheet -match $pat) { $isListSheet = $true; break }
        }
        if ($isListSheet) {
            $listRec = Import-ListSheet -RawData $rawData -SourceFile $file.Name -SheetName $sheet
            if ($listRec) {
                Write-Host "    List sheet: aggregated $($rawData.Count) row(s) into app-level fields" -ForegroundColor DarkCyan
                $script:ProcessingLog[-1].Format = 'List'
                $script:ProcessingLog[-1].Records = 1
                $fileCanonical += $listRec
            }
            else {
                Write-Host "    List sheet: no usable rows -- skipped" -ForegroundColor DarkGray
            }
            continue
        }

        # Phase 2: Extract
        $extracted = @()
        switch ($fingerprint.Format) {
            'Tabular' {
                $extracted = @(Import-TabularSheet -RawData $rawData -SourceFile $file.Name -SheetName $sheet)
            }
            'KeyValue' {
                $kv = Import-KeyValueSheet -RawData $rawData -SourceFile $file.Name -SheetName $sheet
                if ($kv) { $extracted = @($kv) }
            }
            'MultiSection' {
                $ms = Import-MultiSectionSheet -RawData $rawData -SourceFile $file.Name -SheetName $sheet
                if ($ms) { $extracted = @($ms) }
            }
            default {
                # Fallback: try tabular first, then KV
                $extracted = @(Import-TabularSheet -RawData $rawData -SourceFile $file.Name -SheetName $sheet)
                if ($extracted.Count -eq 0) {
                    $kv = Import-KeyValueSheet -RawData $rawData -SourceFile $file.Name -SheetName $sheet
                    if ($kv) { $extracted = @($kv) }
                }
            }
        }

        } # end legacy (non-structured) extraction path

        Write-Host "    Extracted: $($extracted.Count) record(s)" -ForegroundColor DarkCyan
        $script:ProcessingLog[-1].Records = $extracted.Count

        # Phase 3: Map to canonical
        foreach ($rec in $extracted) {
            $sourceKeys = @($rec.PSObject.Properties.Name)
            $mappingResult = Get-CanonicalMapping -SourceKeys $sourceKeys -LearnedSchema $learnedSchema
            $allMappingResults += $mappingResult

            $mapped = $mappingResult.Mapping.Count
            $unmapped = $mappingResult.Unmapped.Count
            $avgScore = if ($mappingResult.Scores.Count -gt 0) {
                [Math]::Round(($mappingResult.Scores.Values | Measure-Object -Average).Average, 2)
            } else { 0 }

            Write-Host "    Mapped: $mapped fields (avg score: $avgScore), Unmapped: $unmapped" -ForegroundColor $(if ($avgScore -ge 0.7) { 'Green' } elseif ($avgScore -ge 0.5) { 'Yellow' } else { 'Red' })

            if ($unmapped -gt 0 -and $ShowUnmapped) {
                Write-Host "    Unmapped fields: $($mappingResult.Unmapped -join ', ')" -ForegroundColor DarkYellow
            }

            $canonicalRec = ConvertTo-CanonicalRecord -Record $rec -MappingResult $mappingResult
            $canonicalRec = Normalize-FieldValue -Record $canonicalRec
            $fileCanonical += $canonicalRec
        }
    }

    # --- Workbook-level app identity ---
    # Sheets that carry no app name (roles/groups lists, secondary sheets)
    # inherit the single app name found elsewhere in the same workbook; if the
    # whole workbook is nameless, fall back to the filename. Files holding
    # MULTIPLE named apps (inventory trackers) are left untouched.
    $named = @($fileCanonical | Where-Object {
        $_.PSObject.Properties['appName'] -and "$($_.appName)".Trim() -ne ''
    })
    $distinctNames = @($named | ForEach-Object { "$($_.appName)".Trim() } | Sort-Object -Unique)
    $fileApp = Get-FileAppName -FileName $file.Name
    $fillName = $null
    if ($distinctNames.Count -eq 1) { $fillName = $distinctNames[0] }
    elseif ($distinctNames.Count -eq 0 -and $fileCanonical.Count -gt 0) {
        $fillName = if ($fileApp) { $fileApp } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
    }
    if ($fillName) {
        foreach ($rec in $fileCanonical) {
            if (-not $rec.PSObject.Properties['appName'] -or "$($rec.appName)".Trim() -eq '') {
                Add-Member -InputObject $rec -NotePropertyName 'appName' -NotePropertyValue $fillName -Force
            }
        }
    }

    # Files following the "<AppName>_<Template>" naming convention carry the
    # app identity in the FILENAME -- more reliable than in-sheet names, which
    # often hold DB/instance names instead. Tag single-app files so the merge
    # can key on it.
    if ($fileApp -and $distinctNames.Count -le 1) {
        foreach ($rec in $fileCanonical) {
            Add-Member -InputObject $rec -NotePropertyName '_fileAppName' -NotePropertyValue $fileApp -Force
        }
    }

    $allRecords += $fileCanonical
}

Write-Host ""
Write-Host "----------------------------" -ForegroundColor DarkGray
Write-Host "Total records extracted: $($allRecords.Count)" -ForegroundColor White

if ($allRecords.Count -eq 0) {
    Write-Warning "No data was extracted from any files."
    return
}

# Merge by app name
$merged = Merge-AppRecords -Records $allRecords
Write-Host "After merge by app name: $($merged.Count) unique application(s)" -ForegroundColor Cyan

# DryRun -- just show results
if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN -- No files written." -ForegroundColor Yellow
    Write-Host ""
    foreach ($rec in $merged) {
        $name = if ($rec.PSObject.Properties['appName']) { $rec.appName } else { '(unknown)' }
        $conf = if ($rec.PSObject.Properties['_mappingConfidence']) { "$($rec._mappingConfidence)" } else { 'N/A' }
        $extra = ''
        if ($rec.PSObject.Properties['_nameVariants']) { $extra += "  [variants: $($rec._nameVariants)]" }
        if ($rec.PSObject.Properties['_conflictCount']) { $extra += "  [conflicts: $($rec._conflictCount)]" }
        Write-Host "  $name  [confidence: $conf]$extra" -ForegroundColor White
    }
    return
}

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host ""
Write-Host "Exporting..." -ForegroundColor Cyan

# Export consolidated CSV
$consolidatedPath = Join-Path $OutputPath "IAM-Intake-Consolidated-$script:DateStamp.csv"
Export-ConsolidatedCsv -Records $merged -FilePath $consolidatedPath

# Export per-product CSVs (column sets shared with the XLSX product sheets)
$sharedCols = @('appName','appUrl','vendor','deploymentType','estimatedUsers','appOwnerName','appOwnerEmail',
                'authMethod','hasMfa','mfaType','hasApi','adIntegration','description','adGroups','adGroupCount')

$productColumns = [ordered]@{}
if ($Product -eq 'All' -or $Product -eq 'SailPoint') {
    $productColumns['SailPoint'] = $sharedCols + @('sp_integrationPattern','sp_connectorType','sp_canExportCsv','sp_csvDeliveryMethod',
        'sp_fileDeliveryMethod','sp_rbacRoles','sp_roleCount','sp_apiType','sp_apiSupportsWrite',
        'sp_v2AccountType','sp_v2LastLogin','sp_v2RiskLevel','_sourceFiles','_mappingConfidence','_conflicts')
}
if ($Product -eq 'All' -or $Product -eq 'CyberArk') {
    $productColumns['CyberArk'] = $sharedCols + @('ca_hlaPriority','ca_tier','ca_accountTypes','ca_adminCount','ca_adminAuthMethod',
        'ca_adminAccessMethod','ca_canChangePasswordViaApi','ca_adminMfaType','ca_cpmApproach','ca_psmApproach',
        'ca_marketplace','ca_platformCategory','ca_modifySecurity','ca_manageUsers','ca_sensitiveData',
        'ca_impactScope','ca_managesInfra','ca_accountNames','ca_serviceAccountCount','ca_interactiveAccountCount',
        '_sourceFiles','_mappingConfidence','_conflicts')
}
if ($Product -eq 'All' -or $Product -eq 'OktaEntra') {
    $productColumns['OktaEntra'] = $sharedCols + @('okta_currentIdp','okta_signOnMode','okta_hasScimProvisioning',
        'okta_appLabel','okta_migrationTarget','okta_entraEquivalent','okta_knownGaps',
        'okta_migrationWave','okta_conditionalAccess','okta_groupAssignments','okta_mfaPolicy',
        '_sourceFiles','_mappingConfidence','_conflicts')
}

foreach ($productName in $productColumns.Keys) {
    $productPath = Join-Path $OutputPath "IAM-Intake-$productName-$script:DateStamp.csv"
    Export-ConsolidatedCsv -Records $merged -FilePath $productPath -ColumnFilter @($productColumns[$productName])
}

# --- Unified outputs: canonical JSON, single XLSX workbook, HTML app browser ---
$appExports = @($merged | ForEach-Object { ConvertTo-AppExport -Record $_ })

$jsonText = Export-ConsolidatedJson -Apps $appExports -OutputDirectory $OutputPath `
    -SourcePath "$inputPath" -FilesProcessed $excelFiles.Count -RecordsExtracted $allRecords.Count

$xlsxPath = Join-Path $OutputPath "IAM-Intake-Consolidated-$script:DateStamp.xlsx"
Export-ConsolidatedXlsx -Records $merged -Apps $appExports -FilePath $xlsxPath `
    -ProductColumns $productColumns -ProcessingLog @($script:ProcessingLog)

$browserPath = Join-Path $OutputPath "IAM-Intake-Browser-$script:DateStamp.html"
Export-AppBrowserHtml -Json $jsonText -FilePath $browserPath

if ($IncludeHtml) {
    Write-Verbose 'The -IncludeHtml switch is deprecated: the HTML app browser is now always generated.'
}

# Export mapping log
$mappingLogPath = Join-Path $OutputPath "IAM-Intake-Mapping-$script:DateStamp.json"
$mappingLog = [ordered]@{
    generated    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    inputPath    = "$inputPath"
    filesProcessed = $excelFiles.Count
    totalExtracted = $allRecords.Count
    mergedApps   = $merged.Count
    processingLog = @($script:ProcessingLog)
}
$mappingLog | ConvertTo-Json -Depth 4 | Set-Content -Path $mappingLogPath -Encoding UTF8
Write-Host "  Exported: $mappingLogPath" -ForegroundColor Green

# Save schema
if ($SaveSchema) {
    $schemaPath = Join-Path $OutputPath "IAM-Intake-Schema-$script:DateStamp.json"
    Save-DetectedSchema -MappingResults $allMappingResults -FilePath $schemaPath
}

Write-Host ""
Write-Host "Done. Output directory: $OutputPath" -ForegroundColor Green
Write-Host ""
#endregion
