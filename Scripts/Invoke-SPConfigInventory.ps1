#Requires -Version 5.1
<#
.SYNOPSIS
    Full SailPoint ISC configuration inventory: documents sources, campaigns, roles,
    access profiles, entitlements, identity profiles, governance groups, SoD policies,
    transforms, workflows, VA clusters, and platform settings into a self-contained
    HTML document plus a machine-readable JSON export.

.DESCRIPTION
    READ-ONLY discovery: every call is an HTTP GET (plus one optional read-only search
    POST for the identity count). Nothing in ISC is created, changed, or deleted.

    The script walks a fixed catalog of ISC API collections (v3 and beta), pages each
    one, and renders:
      - an HTML configuration document (KPI tiles, per-object-type tables, and a
        permission matrix showing the HTTP result per endpoint from THIS run)
      - a JSON export with the full raw objects per section (entitlements sampled
        unless -IncludeEntitlements)
      - a console summary

    Endpoints the token cannot read (403) or that do not exist on the tenant's API
    version (404) are recorded per section and reported honestly -- the run continues.

    PERMISSIONS -- what the token needs:
      ISC personal access tokens (client_credentials) inherit the OWNING USER's
      permissions, optionally narrowed by PAT scopes.
      - Simplest full coverage: a PAT owned by an ORG_ADMIN user with scope
        sp:scopes:all. Every section of this inventory is readable.
      - Least privilege by section (user levels; the tenant's own answer is
        authoritative -- see -PermissionCheck):
          Sources / schemas ............ ORG_ADMIN or SOURCE_ADMIN / SOURCE_SUBADMIN
          Identity profiles ............ ORG_ADMIN
          Campaigns / templates ........ ORG_ADMIN or CERT_ADMIN
          Roles ........................ ORG_ADMIN or ROLE_ADMIN / ROLE_SUBADMIN
          Access profiles .............. ORG_ADMIN, ROLE_SUBADMIN or SOURCE_SUBADMIN
          Entitlements (beta) .......... ORG_ADMIN or SOURCE_ADMIN
          Governance groups ............ ORG_ADMIN
          SoD policies ................. ORG_ADMIN or SOD_ADMIN
          Transforms ................... ORG_ADMIN
          Workflows (beta) ............. ORG_ADMIN
          VA clusters (beta) ........... ORG_ADMIN
          Service desk integrations .... ORG_ADMIN or SDIM_ADMIN
          Password policies (beta) ..... ORG_ADMIN
          Branding / platform config ... ORG_ADMIN
          Segments (beta) .............. ORG_ADMIN
          Connector rules (beta) ....... ORG_ADMIN
          Identity count (search) ...... any user level; search visibility applies
      - Granular PAT scopes (idn:*) exist per collection but their names drift
        between platform releases; the reliable procedure is:
          1. create the PAT with sp:scopes:all (or your candidate scope set)
          2. run  .\Invoke-SPConfigInventory.ps1 -PermissionCheck
          3. read the matrix: every row shows HTTP 200 (readable), 403 (permission
             missing), or 404 (endpoint absent on this tenant/API version)
        That matrix IS the exact permission statement for your tenant.

.PARAMETER BaseUrl
    Tenant API root, with or without a version segment
    (e.g. 'https://tenant.api.identitynow.com' or '.../v3'). When omitted, the
    toolkit's settings.json Api.BaseUrl is used (version segment stripped).

.PARAMETER Token
    Bearer token (PAT-exchanged access token or browser token). When omitted, the
    toolkit's SP.Core Get-SPAuthToken flow is used (settings.json Authentication).

.PARAMETER ConfigPath
    Path to settings.json for the config/auth fallback. Auto-resolved if omitted.

.PARAMETER OutputPath
    Directory for the HTML + JSON outputs. Default: .\Audit\config-inventory.

.PARAMETER OutputMode
    Console | HTML | JSON | All (default All).

.PARAMETER PermissionCheck
    Probe mode: hit every catalog endpoint with limit=1, print/render ONLY the
    permission matrix (endpoint, purpose, required level, HTTP status), and exit.
    Run this first with a new token.

.PARAMETER IncludeEntitlements
    Pull the FULL entitlement list into the JSON export (can be tens of thousands
    of objects). Default: entitlement count plus a sample of -EntitlementSampleSize.

.PARAMETER IncludeCsv
    Also write one CSV per section (Config-Inventory-<stamp>-<section>.csv) using
    each section's display columns over the FULL retrieved data -- auditor-friendly
    flat exports alongside the HTML/JSON.

.PARAMETER EntitlementSampleSize
    Sample size for the entitlement section when -IncludeEntitlements is not set.
    Default 100.

.PARAMETER Top
    Rows per section in the HTML tables (full data always goes to JSON). Default 50.

.PARAMETER MaxItemsPerSection
    Safety cap per paged collection. Default 10000.

.PARAMETER Help
    Show detailed help.

.EXAMPLE
    .\Invoke-SPConfigInventory.ps1 -PermissionCheck
    # First run: verify exactly what this token can read.

.EXAMPLE
    .\Invoke-SPConfigInventory.ps1
    # Full inventory using the toolkit's configured auth.

.EXAMPLE
    .\Invoke-SPConfigInventory.ps1 -BaseUrl 'https://acme.api.identitynow.com' -Token $jwt -IncludeEntitlements

.NOTES
    Script:  Invoke-SPConfigInventory.ps1
    Version: 1.0.0
    READ-ONLY. Exit codes: 0 normal, 2 parameter error, 3 auth failure, 4 config error.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$BaseUrl,
    [Parameter()][string]$Token,
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$OutputPath = '.\Audit\config-inventory',
    [Parameter()][ValidateSet('Console', 'HTML', 'JSON', 'All')][string]$OutputMode = 'All',
    [Parameter()][switch]$PermissionCheck,
    [Parameter()][switch]$IncludeEntitlements,
    [Parameter()][switch]$IncludeCsv,
    [Parameter()][int]$EntitlementSampleSize = 100,
    [Parameter()][int]$Top = 50,
    [Parameter()][int]$MaxItemsPerSection = 10000,
    [Parameter()][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

# ---------------------------------------------------------------------------
# Auth + API root resolution
# ---------------------------------------------------------------------------
$script:ApiRoot = ''
$script:Headers = $null

function Resolve-InvApiRoot {
    param([string]$Candidate)
    $u = $Candidate.TrimEnd('/')
    # Strip a trailing version segment so the catalog can address /v3 and /beta explicitly.
    $lastSeg = ($u -split '/')[-1]
    if ($lastSeg -match '^(v\d+|beta)$') { $u = $u.Substring(0, $u.Length - $lastSeg.Length - 1) }
    return $u
}

if ($BaseUrl) {
    $script:ApiRoot = Resolve-InvApiRoot -Candidate $BaseUrl
}
if ($Token) {
    $script:Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
}

if (-not $script:ApiRoot -or -not $script:Headers) {
    # Fall back to the toolkit's config + auth stack.
    try {
        $corePsd1 = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        Import-Module $corePsd1 -Force -DisableNameChecking -ErrorAction Stop
        if ($ConfigPath) { $null = Get-SPConfig -ConfigPath $ConfigPath }
        $cfg = Get-SPConfig
        if (-not $script:ApiRoot) {
            if ($null -eq $cfg.Api -or [string]::IsNullOrWhiteSpace([string]$cfg.Api.BaseUrl)) {
                Write-Host 'ERROR: no -BaseUrl given and settings.json Api.BaseUrl is empty.' -ForegroundColor Red; exit 4
            }
            $script:ApiRoot = Resolve-InvApiRoot -Candidate ([string]$cfg.Api.BaseUrl)
        }
        if (-not $script:Headers) {
            $auth = Get-SPAuthToken
            if (-not $auth.Success) { Write-Host "ERROR: auth failed: $($auth.Error)" -ForegroundColor Red; exit 3 }
            $script:Headers = $auth.Data.Headers
        }
    }
    catch {
        Write-Host "ERROR: could not resolve auth/config: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Pass -BaseUrl and -Token explicitly to run without the toolkit config.' -ForegroundColor Yellow
        exit 3
    }
}

# ---------------------------------------------------------------------------
# Minimal REST helpers (PS 5.1-compatible; light retry on 429/5xx)
# ---------------------------------------------------------------------------
function Invoke-InvRequest {
    # GET (or read-only POST for /search) with 3-attempt retry on 429/5xx.
    # Returns @{ Success; Data; StatusCode; Error }.
    param(
        [Parameter(Mandatory)][string]$Path,          # absolute from API root, e.g. '/v3/sources'
        [Parameter()][hashtable]$Query,
        [Parameter()][ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [Parameter()]$Body
    )
    $qs = ''
    if ($Query -and $Query.Count -gt 0) {
        $pairs = foreach ($k in $Query.Keys) { '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k]) }
        $qs = '?' + ($pairs -join '&')
    }
    $url = $script:ApiRoot + $Path + $qs
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $splat = @{ Method = $Method; Uri = $url; Headers = $script:Headers; TimeoutSec = 120; ErrorAction = 'Stop' }
            if ($Method -eq 'POST') {
                $splat['Body'] = ($Body | ConvertTo-Json -Depth 6)
                $splat['ContentType'] = 'application/json'
            }
            $data = Invoke-RestMethod @splat
            return @{ Success = $true; Data = $data; StatusCode = 200; Error = '' }
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -eq 0) { try { $status = [int]$_.Exception.Response.StatusCode.value__ } catch { } }
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 3) {
                Start-Sleep -Seconds ([math]::Min(30, 5 * $attempt))
                continue
            }
            return @{ Success = $false; Data = $null; StatusCode = $status; Error = $_.Exception.Message }
        }
    }
}

function Get-InvPaged {
    # Standard ISC offset/limit paging. Loops until a short page or the cap.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][hashtable]$Query,
        [Parameter()][int]$MaxItems = 10000,
        [Parameter()][int]$PageSize = 250
    )
    $all = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        # Never request more than the remaining budget: with MaxItems=100 a fixed
        # 250-item page overshot the cap and returned 250 "sampled" items.
        $want = [math]::Min($PageSize, $MaxItems - $all.Count)
        if ($want -le 0) { return @{ Success = $true; Items = @($all.ToArray()); StatusCode = 200; Error = ''; Truncated = $true } }
        $q = @{}
        if ($Query) { foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] } }
        $q['limit'] = $want
        $q['offset'] = $offset
        $r = Invoke-InvRequest -Path $Path -Query $q
        # .ToArray() before @(): wrapping a Generic.List directly in @() throws
        # "Argument types do not match" (same quirk documented in SP.AuditQueries).
        if (-not $r.Success) { return @{ Success = $false; Items = @($all.ToArray()); StatusCode = $r.StatusCode; Error = $r.Error; Truncated = $false } }
        $page = @($r.Data)
        foreach ($it in $page) { if ($null -ne $it) { [void]$all.Add($it) } }
        if ($page.Count -lt $want) { break }
        $offset += $page.Count
    }
    return @{ Success = $true; Items = @($all.ToArray()); StatusCode = 200; Error = ''; Truncated = $false }
}

function Get-DotProp {
    # Resolve 'owner.name'-style dot paths against API objects; '' when absent.
    param($Object, [string]$DotPath)
    $cur = $Object
    foreach ($seg in $DotPath -split '\.') {
        if ($null -eq $cur) { return '' }
        if ($cur -is [System.Collections.IDictionary]) { $cur = $cur[$seg] }
        else {
            $p = $null
            try { $p = $cur.PSObject.Properties[$seg] } catch { }
            if ($null -eq $p) { return '' }
            $cur = $p.Value
        }
    }
    if ($null -eq $cur) { return '' }
    if ($cur -is [System.Array]) { return (@($cur | ForEach-Object { [string]$_ }) -join ', ') }
    return [string]$cur
}

function ConvertTo-Safe { param([string]$s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

# ---------------------------------------------------------------------------
# The catalog: every collection this inventory documents.
#   Key / Title / Path (absolute from API root) / Columns (label=dotpath) /
#   Level (least-privilege user-level hint) / Optional (404 is expected on
#   some tenants, do not alarm)
# ---------------------------------------------------------------------------
$catalog = @(
    @{ Key = 'sources';           Title = 'Sources';                    Path = '/v3/sources';                    Level = 'ORG_ADMIN or SOURCE_ADMIN/SOURCE_SUBADMIN';
       Columns = [ordered]@{ Name = 'name'; Type = 'type'; Connector = 'connectorName'; Owner = 'owner.name'; Authoritative = 'authoritative'; Healthy = 'healthy'; Status = 'status'; Created = 'created' } }
    @{ Key = 'identityProfiles';  Title = 'Identity Profiles';          Path = '/v3/identity-profiles';          Level = 'ORG_ADMIN';
       Columns = [ordered]@{ Name = 'name'; AuthoritativeSource = 'authoritativeSource.name'; Priority = 'priority'; IdentityCount = 'identityCount'; Enabled = 'hasTimeBasedAttr' } }
    @{ Key = 'campaigns';         Title = 'Certification Campaigns';    Path = '/v3/campaigns';                  Level = 'ORG_ADMIN or CERT_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Type = 'type'; Status = 'status'; Created = 'created'; Deadline = 'deadline'; TotalCerts = 'totalCertifications'; Completed = 'completedCertifications' } }
    @{ Key = 'campaignTemplates'; Title = 'Campaign Templates';         Path = '/v3/campaign-templates';         Level = 'ORG_ADMIN or CERT_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Created = 'created'; Modified = 'modified'; Scheduled = 'scheduled'; OwnerName = 'ownerRef.name' } }
    @{ Key = 'roles';             Title = 'Roles';                      Path = '/v3/roles';                      Level = 'ORG_ADMIN or ROLE_ADMIN/ROLE_SUBADMIN';
       Columns = [ordered]@{ Name = 'name'; Owner = 'owner.name'; Enabled = 'enabled'; Requestable = 'requestable'; Created = 'created' } }
    @{ Key = 'accessProfiles';    Title = 'Access Profiles';            Path = '/v3/access-profiles';            Level = 'ORG_ADMIN, ROLE_SUBADMIN or SOURCE_SUBADMIN';
       Columns = [ordered]@{ Name = 'name'; Source = 'source.name'; Owner = 'owner.name'; Enabled = 'enabled'; Requestable = 'requestable'; Created = 'created' } }
    @{ Key = 'entitlements';      Title = 'Entitlements';               Path = '/beta/entitlements';             Level = 'ORG_ADMIN or SOURCE_ADMIN'; Sampled = $true;
       Columns = [ordered]@{ Name = 'name'; Source = 'source.name'; Attribute = 'attribute'; Privileged = 'privileged'; Requestable = 'requestable'; Created = 'created' } }
    @{ Key = 'governanceGroups';  Title = 'Governance Groups';          Path = '/beta/workgroups';               Level = 'ORG_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Description = 'description'; Owner = 'owner.name'; Members = 'memberCount'; Connections = 'connectionCount' } }
    @{ Key = 'sodPolicies';       Title = 'SoD Policies';               Path = '/v3/sod-policies';               Level = 'ORG_ADMIN or SOD_ADMIN';
       Columns = [ordered]@{ Name = 'name'; State = 'state'; Type = 'type'; Owner = 'ownerRef.name'; ViolationOwner = 'violationOwnerAssignmentConfig.assignmentRule'; Created = 'created' } }
    @{ Key = 'identityAttributes'; Title = 'Identity Attributes';       Path = '/beta/identity-attributes';      Level = 'ORG_ADMIN';
       Columns = [ordered]@{ Name = 'name'; DisplayName = 'displayName'; Type = 'type'; Multi = 'multi'; Searchable = 'searchable'; System = 'system' } }
    @{ Key = 'transforms';        Title = 'Transforms';                 Path = '/v3/transforms';                 Level = 'ORG_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Type = 'type'; Internal = 'internal' } }
    @{ Key = 'workflows';         Title = 'Workflows';                  Path = '/beta/workflows';                Level = 'ORG_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Enabled = 'enabled'; Owner = 'owner.name'; Created = 'created'; ExecCount = 'executionCount'; FailCount = 'failureCount' } }
    @{ Key = 'vaClusters';        Title = 'VA Clusters';                Path = '/beta/managed-clusters';         Level = 'ORG_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Type = 'type'; Status = 'operationalStatus'; Description = 'description'; ClientsCount = 'clientIds' } }
    @{ Key = 'serviceDesk';       Title = 'Service Desk Integrations';  Path = '/beta/service-desk-integrations'; Level = 'ORG_ADMIN or SDIM_ADMIN';
       Columns = [ordered]@{ Name = 'name'; Type = 'type'; Description = 'description'; Cluster = 'clusterRef.name' } }
    @{ Key = 'passwordPolicies';  Title = 'Password Policies';          Path = '/beta/password-policies';        Level = 'ORG_ADMIN'; Optional = $true;
       Columns = [ordered]@{ Name = 'name'; Description = 'description'; MinLength = 'minLength'; FirstExpiration = 'firstExpirationReminder' } }
    @{ Key = 'segments';          Title = 'Segments';                   Path = '/beta/segments';                 Level = 'ORG_ADMIN'; Optional = $true;
       Columns = [ordered]@{ Name = 'name'; Description = 'description'; Active = 'active'; Created = 'created' } }
    @{ Key = 'connectorRules';    Title = 'Connector Rules';            Path = '/beta/connector-rules';          Level = 'ORG_ADMIN'; Optional = $true;
       Columns = [ordered]@{ Name = 'name'; Type = 'type'; Description = 'description'; Created = 'created' } }
    @{ Key = 'brandings';         Title = 'Branding';                   Path = '/v3/brandings';                  Level = 'ORG_ADMIN'; Optional = $true;
       Columns = [ordered]@{ Name = 'name'; ProductName = 'productName'; ActionButtonColor = 'actionButtonColor' } }
    @{ Key = 'publicIdentitiesConfig'; Title = 'Public Identities Config'; Path = '/v3/public-identities-config'; Level = 'ORG_ADMIN'; Single = $true;
       Columns = [ordered]@{ Attributes = 'attributes'; Modified = 'modified'; ModifiedBy = 'modifiedBy.name' } }
)

# ---------------------------------------------------------------------------
# Permission-check mode: probe every endpoint with limit=1, print the matrix.
# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $toolkitRoot ($OutputPath -replace '^\.\\', '') }
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

function Get-InvProbeStatus {
    param($Entry)
    $q = if ($Entry.ContainsKey('Single') -and $Entry.Single) { @{} } else { @{ limit = 1 } }
    $r = Invoke-InvRequest -Path $Entry.Path -Query $q
    return $r.StatusCode
}

if ($PermissionCheck) {
    Write-Host ''
    Write-Host "Permission check against $script:ApiRoot" -ForegroundColor Cyan
    Write-Host '  (200 = readable; 403 = token/user lacks permission; 404 = endpoint absent on this tenant)' -ForegroundColor DarkGray
    Write-Host ''
    $matrix = foreach ($e in $catalog) {
        $code = Get-InvProbeStatus -Entry $e
        $verdict = switch ($code) { 200 { 'OK' } 403 { 'PERMISSION MISSING' } 404 { if ($e.ContainsKey('Optional') -and $e.Optional) { 'absent (optional)' } else { 'NOT FOUND' } } default { "HTTP $code" } }
        $color = switch ($code) { 200 { 'Green' } 403 { 'Red' } default { 'Yellow' } }
        Write-Host ("  {0,-28} {1,-38} {2,4}  {3}" -f $e.Title, $e.Path, $code, $verdict) -ForegroundColor $color
        [pscustomobject]@{ Section = $e.Title; Endpoint = $e.Path; RequiredLevel = $e.Level; HttpStatus = $code; Verdict = $verdict }
    }
    $denied = @($matrix | Where-Object { $_.HttpStatus -eq 403 })
    Write-Host ''
    if ($denied.Count -eq 0) { Write-Host '  All catalog endpoints readable with this token.' -ForegroundColor Green }
    else {
        Write-Host "  $($denied.Count) endpoint(s) denied. Grant the listed user level (or widen PAT scopes) and re-run:" -ForegroundColor Yellow
        foreach ($d in $denied) { Write-Host "    - $($d.Section): needs $($d.RequiredLevel)" -ForegroundColor Yellow }
    }
    $jsonOut = Join-Path $OutputPath "Config-Inventory-PermissionCheck-$stamp.json"
    $matrix | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jsonOut -Encoding UTF8
    Write-Host ''
    Write-Host "Matrix written: $jsonOut" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Full inventory
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "SailPoint ISC Configuration Inventory -- $script:ApiRoot" -ForegroundColor Cyan
$results = [ordered]@{}

foreach ($e in $catalog) {
    $title = [string]$e.Title
    Write-Host ("  Fetching {0} ..." -f $title) -ForegroundColor DarkGray -NoNewline
    if ($e.ContainsKey('Single') -and $e.Single) {
        $r = Invoke-InvRequest -Path $e.Path
        if ($r.Success) {
            $items = @($r.Data)
            Write-Host " ok (singleton)" -ForegroundColor Green
            $results[$e.Key] = @{ Entry = $e; Items = $items; Count = $items.Count; StatusCode = 200; Truncated = $false }
        }
        else {
            Write-Host " HTTP $($r.StatusCode)" -ForegroundColor Yellow
            $results[$e.Key] = @{ Entry = $e; Items = @(); Count = -1; StatusCode = $r.StatusCode; Truncated = $false }
        }
        continue
    }
    $isEnt = ($e.Key -eq 'entitlements')
    $cap = if ($isEnt -and -not $IncludeEntitlements) { [math]::Max(1, $EntitlementSampleSize) } else { $MaxItemsPerSection }
    $r = Get-InvPaged -Path $e.Path -MaxItems $cap
    if ($r.Success) {
        $note = if ($r.Truncated) { " (capped at $cap)" } else { '' }
        Write-Host (" {0} item(s){1}" -f $r.Items.Count, $note) -ForegroundColor Green
        $results[$e.Key] = @{ Entry = $e; Items = $r.Items; Count = $r.Items.Count; StatusCode = 200; Truncated = $r.Truncated }
    }
    else {
        Write-Host " HTTP $($r.StatusCode)" -ForegroundColor Yellow
        $results[$e.Key] = @{ Entry = $e; Items = @(); Count = -1; StatusCode = $r.StatusCode; Truncated = $false }
    }
}

# Identity count via the read-only search API. Invoke-WebRequest (not Invoke-RestMethod)
# because the count comes back in the X-Total-Count response header, which
# Invoke-RestMethod discards on PS 5.1. Optional: failures leave the count at -1.
$identityCount = -1
try {
    $cntUrl  = $script:ApiRoot + '/v3/search?limit=1&count=true'
    $cntBody = @{ indices = @('identities'); query = @{ query = '*' }; sort = @('name') } | ConvertTo-Json -Depth 4
    $resp = Invoke-WebRequest -Method POST -Uri $cntUrl -Headers $script:Headers -Body $cntBody -ContentType 'application/json' -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
    $hdr = $resp.Headers['X-Total-Count']
    if ($hdr -is [array]) { $hdr = $hdr[0] }
    $n = 0
    if ([int]::TryParse([string]$hdr, [ref]$n)) { $identityCount = $n }
}
catch { }
if ($identityCount -ge 0) { Write-Host ("  Identities (search count): {0:N0}" -f $identityCount) -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Governance posture findings -- turns the inventory into an assessment. Computed
# only from sections the token could read; absent/denied sections are skipped
# silently (their absence already shows in the permission matrix). Entitlement
# findings carry a sample caveat unless -IncludeEntitlements was used.
# ---------------------------------------------------------------------------
$findings = New-Object System.Collections.Generic.List[object]
function Add-InvFinding {
    param([string]$Severity, [string]$Section, [string]$Finding, [string]$ObjectName)
    $findings.Add([pscustomobject]@{ Severity = $Severity; Section = $Section; Finding = $Finding; Object = $ObjectName })
}
$nowRef = Get-Date
if ($results.Contains('sources') -and $results['sources'].Count -ge 0) {
    foreach ($s in $results['sources'].Items) {
        $nm = Get-DotProp $s 'name'
        $healthy = (Get-DotProp $s 'healthy')
        if ($healthy -and $healthy.ToLower() -eq 'false') { Add-InvFinding 'High' 'Sources' 'Source reports unhealthy' $nm }
        if ([string]::IsNullOrWhiteSpace((Get-DotProp $s 'owner.name'))) { Add-InvFinding 'Medium' 'Sources' 'Source has no owner' $nm }
    }
}
if ($results.Contains('campaigns') -and $results['campaigns'].Count -ge 0) {
    foreach ($c in $results['campaigns'].Items) {
        $nm = Get-DotProp $c 'name'
        if ((Get-DotProp $c 'status') -eq 'ACTIVE') {
            $dl = Get-DotProp $c 'deadline'
            $dt = $null
            if ($dl) { try { $dt = [datetime]$dl } catch { } }
            if ($null -ne $dt -and $dt -lt $nowRef) { Add-InvFinding 'Medium' 'Campaigns' 'ACTIVE campaign past its deadline' $nm }
        }
    }
}
if ($results.Contains('roles') -and $results['roles'].Count -ge 0) {
    foreach ($r in $results['roles'].Items) {
        if ([string]::IsNullOrWhiteSpace((Get-DotProp $r 'owner.name'))) { Add-InvFinding 'Medium' 'Roles' 'Role has no owner' (Get-DotProp $r 'name') }
    }
}
if ($results.Contains('accessProfiles') -and $results['accessProfiles'].Count -ge 0) {
    foreach ($ap in $results['accessProfiles'].Items) {
        if ([string]::IsNullOrWhiteSpace((Get-DotProp $ap 'owner.name'))) { Add-InvFinding 'Medium' 'Access Profiles' 'Access profile has no owner' (Get-DotProp $ap 'name') }
    }
}
if ($results.Contains('entitlements') -and $results['entitlements'].Count -ge 0) {
    $entCaveat = if (-not $IncludeEntitlements) { ' [from sample -- rerun with -IncludeEntitlements for full coverage]' } else { '' }
    foreach ($en in $results['entitlements'].Items) {
        if (((Get-DotProp $en 'privileged').ToLower() -eq 'true') -and ((Get-DotProp $en 'requestable').ToLower() -eq 'true')) {
            Add-InvFinding 'High' 'Entitlements' ('Privileged entitlement is requestable' + $entCaveat) (Get-DotProp $en 'name')
        }
    }
}
if ($results.Contains('workflows') -and $results['workflows'].Count -ge 0) {
    foreach ($w in $results['workflows'].Items) {
        $fails = 0; [void][int]::TryParse((Get-DotProp $w 'failureCount'), [ref]$fails)
        if ($fails -gt 0) { Add-InvFinding 'Medium' 'Workflows' "Workflow has $fails recorded failure(s)" (Get-DotProp $w 'name') }
    }
}
if ($results.Contains('sodPolicies') -and $results['sodPolicies'].Count -ge 0) {
    foreach ($sp in $results['sodPolicies'].Items) {
        $st = (Get-DotProp $sp 'state')
        if ($st -and $st -notmatch '(?i)enforc') { Add-InvFinding 'High' 'SoD Policies' "SoD policy state is $st (not enforced)" (Get-DotProp $sp 'name') }
    }
}
if ($results.Contains('vaClusters') -and $results['vaClusters'].Count -ge 0) {
    foreach ($vc in $results['vaClusters'].Items) {
        $st = (Get-DotProp $vc 'operationalStatus')
        if ($st -and $st -notmatch '(?i)ok|active|normal|up') { Add-InvFinding 'High' 'VA Clusters' "Cluster operational status: $st" (Get-DotProp $vc 'name') }
    }
}
$findings = @($findings | Sort-Object -Property @{Expression={ switch ($_.Severity) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }}, 'Section', 'Object')

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Inventory summary:' -ForegroundColor Cyan
foreach ($k in $results.Keys) {
    $s = $results[$k]
    $lbl = if ($s.Count -ge 0) { "$($s.Count)$(if ($s.Truncated) { '+' })" } else { "HTTP $($s.StatusCode)" }
    Write-Host ("  {0,-28} {1}" -f $s.Entry.Title, $lbl)
}
if (@($findings).Count -gt 0) {
    $hi = @($findings | Where-Object { $_.Severity -eq 'High' }).Count
    Write-Host ''
    Write-Host "Governance findings: $(@($findings).Count) ($hi high severity)" -ForegroundColor Yellow
    foreach ($f in @($findings | Select-Object -First 10)) { Write-Host ("  [{0}] {1}: {2} -- {3}" -f $f.Severity, $f.Section, $f.Finding, $f.Object) -ForegroundColor DarkGray }
    if (@($findings).Count -gt 10) { Write-Host ("  ... and {0} more (full list in HTML/JSON)" -f (@($findings).Count - 10)) -ForegroundColor DarkGray }
}
else { Write-Host ''; Write-Host 'Governance findings: none detected across readable sections.' -ForegroundColor Green }

# ---------------------------------------------------------------------------
# JSON export
# ---------------------------------------------------------------------------
$outBase = Join-Path $OutputPath "Config-Inventory-$stamp"
if ($OutputMode -in @('JSON', 'All')) {
    $export = [ordered]@{
        Meta = [ordered]@{
            ApiRoot = $script:ApiRoot; Generated = (Get-Date -Format 'o'); Script = 'Invoke-SPConfigInventory 1.0.0'
            EntitlementsSampled = (-not $IncludeEntitlements)
            IdentityCount = $identityCount   # -1 = search unavailable/denied
        }
        Findings = @($findings)
        Sections = [ordered]@{}
    }
    foreach ($k in $results.Keys) {
        $s = $results[$k]
        $export.Sections[$k] = [ordered]@{
            Title = $s.Entry.Title; Endpoint = $s.Entry.Path; RequiredLevel = $s.Entry.Level
            HttpStatus = $s.StatusCode; Count = $s.Count; Truncated = [bool]$s.Truncated
            Items = @($s.Items)
        }
    }
    $jsonFile = "$outBase.json"
    $export | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonFile -Encoding UTF8
    Write-Host ''
    Write-Host "JSON export: $jsonFile" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# CSV exports (opt-in): one flat file per readable section over the FULL data,
# using the section's display columns; plus the findings list.
# ---------------------------------------------------------------------------
if ($IncludeCsv) {
    $csvCount = 0
    foreach ($k in $results.Keys) {
        $s = $results[$k]
        if ($s.Count -le 0) { continue }
        $cols = $s.Entry.Columns
        $rows = foreach ($it in $s.Items) {
            $o = [ordered]@{}
            foreach ($c in $cols.Keys) { $o[$c] = Get-DotProp -Object $it -DotPath $cols[$c] }
            [pscustomobject]$o
        }
        $csvFile = "$outBase-$k.csv"
        @($rows) | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
        $csvCount++
    }
    if (@($findings).Count -gt 0) {
        @($findings) | Export-Csv -LiteralPath "$outBase-findings.csv" -NoTypeInformation -Encoding UTF8
        $csvCount++
    }
    Write-Host "CSV exports: $csvCount file(s) at $outBase-<section>.csv" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# HTML document
# ---------------------------------------------------------------------------
if ($OutputMode -in @('HTML', 'All')) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>ISC Configuration Inventory</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;color:#222;margin:18px;background:#fff}')
    [void]$sb.AppendLine('h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}')
    [void]$sb.AppendLine('.meta{color:#555;font-size:12px;margin-bottom:6px} .note{color:#777;font-size:11px;margin-top:4px}')
    [void]$sb.AppendLine('table.report{border-collapse:collapse;font-size:12px;margin-top:6px}')
    [void]$sb.AppendLine('table.report th,table.report td{border:1px solid #e1e4e8;padding:4px 8px}')
    [void]$sb.AppendLine('table.report th{background:#f6f8fa;text-align:left}')
    [void]$sb.AppendLine('.kpi-row{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0}')
    [void]$sb.AppendLine('.kpi{border:1px solid #e1e4e8;border-radius:6px;padding:10px 16px;min-width:110px;text-align:center}')
    [void]$sb.AppendLine('.kpi .value{font-size:24px;font-weight:700} .kpi .label{font-size:11px;color:#555;margin-top:3px}')
    [void]$sb.AppendLine('.s-red{color:#c0392b;font-weight:600} .s-green{color:#27ae60;font-weight:600} .s-amber{color:#9a6700;font-weight:600}')
    [void]$sb.AppendLine('summary{cursor:pointer;font-weight:600;padding:4px 0}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>SailPoint ISC Configuration Inventory</h1>')
    [void]$sb.AppendLine("<div class='meta'>Tenant API: $(ConvertTo-Safe $script:ApiRoot) &nbsp;|&nbsp; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;|&nbsp; read-only discovery</div>")

    # KPI tiles
    [void]$sb.AppendLine("<div class='kpi-row'>")
    if (@($findings).Count -gt 0) {
        [void]$sb.AppendLine("<div class='kpi'><div class='value' style='color:#c0392b'>$(@($findings).Count)</div><div class='label'>Governance Findings</div></div>")
    }
    if ($identityCount -ge 0) {
        [void]$sb.AppendLine("<div class='kpi'><div class='value'>$('{0:N0}' -f $identityCount)</div><div class='label'>Identities</div></div>")
    }
    foreach ($k in $results.Keys) {
        $s = $results[$k]
        if ($s.Count -lt 0) { continue }
        $v = "$($s.Count)$(if ($s.Truncated) { '+' })"
        [void]$sb.AppendLine("<div class='kpi'><div class='value'>$v</div><div class='label'>$(ConvertTo-Safe $s.Entry.Title)</div></div>")
    }
    [void]$sb.AppendLine('</div>')

    # Governance posture findings
    [void]$sb.AppendLine('<h2>Governance Posture Findings</h2>')
    if (@($findings).Count -eq 0) {
        [void]$sb.AppendLine("<p class='s-green'>No findings detected across the readable sections.</p>")
    }
    else {
        [void]$sb.AppendLine("<div class='note'>Computed from the readable sections only (denied/absent sections cannot contribute -- see the permission matrix). Entitlement findings from a sampled run carry a sample caveat.</div>")
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Severity</th><th>Section</th><th>Finding</th><th>Object</th></tr></thead><tbody>')
        foreach ($f in $findings) {
            $cls = switch ($f.Severity) { 'High' { 's-red' } 'Medium' { 's-amber' } default { '' } }
            [void]$sb.AppendLine("<tr><td class='$cls'>$(ConvertTo-Safe $f.Severity)</td><td>$(ConvertTo-Safe $f.Section)</td><td>$(ConvertTo-Safe $f.Finding)</td><td>$(ConvertTo-Safe $f.Object)</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    # Permission matrix (from THIS run -- the tenant-truth answer to "what do I need")
    [void]$sb.AppendLine('<h2>Access &amp; Permission Matrix</h2>')
    [void]$sb.AppendLine("<div class='note'>HTTP result per endpoint from this run. 200 = token can read it; 403 = the owning user lacks the listed level (or the PAT scopes exclude it); 404 = endpoint absent on this tenant/API version. PATs inherit the owning user's permissions -- sp:scopes:all on an ORG_ADMIN-owned PAT reads everything below.</div>")
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Section</th><th>Endpoint</th><th>Least-privilege user level</th><th>HTTP</th><th>Verdict</th></tr></thead><tbody>')
    foreach ($k in $results.Keys) {
        $s = $results[$k]
        $code = $s.StatusCode
        $cls = switch ($code) { 200 { 's-green' } 403 { 's-red' } default { 's-amber' } }
        $verdict = switch ($code) { 200 { 'readable' } 403 { 'permission missing' } 404 { 'absent on tenant' } default { "HTTP $code" } }
        [void]$sb.AppendLine("<tr><td>$(ConvertTo-Safe $s.Entry.Title)</td><td>$(ConvertTo-Safe $s.Entry.Path)</td><td>$(ConvertTo-Safe $s.Entry.Level)</td><td class='$cls'>$code</td><td class='$cls'>$verdict</td></tr>")
    }
    [void]$sb.AppendLine('</tbody></table>')

    # Per-section tables
    foreach ($k in $results.Keys) {
        $s = $results[$k]
        $e = $s.Entry
        [void]$sb.AppendLine("<h2>$(ConvertTo-Safe $e.Title)</h2>")
        if ($s.Count -lt 0) {
            [void]$sb.AppendLine("<p class='s-amber'>Not retrieved (HTTP $($s.StatusCode)). Least-privilege level: $(ConvertTo-Safe $e.Level).</p>")
            continue
        }
        $capNote = ''
        if ($e.Key -eq 'entitlements' -and -not $IncludeEntitlements) { $capNote = " -- SAMPLE of $EntitlementSampleSize (rerun with -IncludeEntitlements for the full list)" }
        elseif ($s.Truncated) { $capNote = " -- capped at $MaxItemsPerSection" }
        [void]$sb.AppendLine("<div class='note'>$($s.Count) item(s)$capNote. Endpoint: $(ConvertTo-Safe $e.Path). Full objects in the JSON export.</div>")
        if ($s.Count -eq 0) { [void]$sb.AppendLine("<p class='note'>None configured.</p>"); continue }
        $shown = @($s.Items | Select-Object -First $Top)
        $cols = $e.Columns
        [void]$sb.AppendLine("<details$(if ($s.Count -le 15) { ' open' })><summary>$(ConvertTo-Safe $e.Title) ($($shown.Count) of $($s.Count) shown)</summary>")
        [void]$sb.AppendLine('<table class="report"><thead><tr>' + ((@($cols.Keys) | ForEach-Object { "<th>$(ConvertTo-Safe $_)</th>" }) -join '') + '</tr></thead><tbody>')
        foreach ($it in $shown) {
            $cells = foreach ($c in $cols.Keys) { "<td>$(ConvertTo-Safe (Get-DotProp -Object $it -DotPath $cols[$c]))</td>" }
            [void]$sb.AppendLine('<tr>' + ($cells -join '') + '</tr>')
        }
        [void]$sb.AppendLine('</tbody></table></details>')
    }

    [void]$sb.AppendLine("<div style='text-align:center;color:#999;font-size:11px;padding:16px;margin-top:24px;border-top:1px solid #eee'>ISC Configuration Inventory | read-only | SailPoint ISC Governance Toolkit</div>")
    [void]$sb.AppendLine('</body></html>')

    $htmlFile = "$outBase.html"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFile, $sb.ToString(), $utf8NoBom)
    Write-Host "HTML report:  $htmlFile" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done (read-only -- nothing in ISC was modified).' -ForegroundColor Cyan
exit 0
