#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - AD Delta Certification Campaign Runner
.DESCRIPTION
    Orchestrates the full AD delta certification workflow:
        1. Enumerate AD GRANT_ACCESS events in a configurable time window
        2. Resolve affected active identities and their managers
        3. Group identities by manager
        4. Create one SEARCH-type certification campaign per manager group
        5. Activate each campaign

    Each campaign is scoped to only the identities under that manager who received
    new AD access. Each manager reviews only their changed direct reports.

    Campaign naming convention: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
    Campaign type:              SEARCH (certifier = manager identity ID)

    Empty-run guard: if no GRANT_ACCESS events are found, the function returns
    successfully with CampaignsCreated=0 and Reason='NoChanges'. No write API
    calls are made.

.NOTES
    Module: SP.DeltaCertRunner
    Version: 1.0.0
#>

#region Internal Functions

function Build-SPDeltaSearchFilter {
    <#
    .SYNOPSIS
        Builds an ISC SEARCH campaign identity filter query from identity IDs.
    .DESCRIPTION
        Produces a Lucene-style query string for use in a SEARCH campaign's
        filter.query.query field.

        Single identity:  id:"identity-id-1"
        Multiple:         id:"id-1" OR id:"id-2" OR id:"id-3"

        Double-quotes and backslashes in identity IDs are escaped.
    .PARAMETER IdentityIds
        Array of identity ID strings.
    .OUTPUTS
        [string] ISC search filter query string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$IdentityIds
    )

    $escaped = $IdentityIds | ForEach-Object {
        $id = $_ -replace '\\', '\\' -replace '"', '\"'
        "id:`"$id`""
    }
    return ($escaped -join ' OR ')
}

function Write-SPDeltaCertAuditEvent {
    <#
    .SYNOPSIS
        Appends a JSONL audit event for a delta cert run.
    .DESCRIPTION
        Writes a single JSON line to {OutputPath}/deltacert-audit.jsonl following
        the Export-SPAuditJsonl pattern (UTF-8 no BOM, AppendAllText).

        The optional -RunMode parameter distinguishes DELTA runs (the default
        account-activity-driven mode) from FULL runs (quarterly baseline mode
        created by Invoke-SPDeltaCertFullRun). Existing consumers of the JSONL
        file see a new RunMode field; ConvertFrom-Json ignores unknown keys so
        this is backward-compatible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CorrelationID,
        [Parameter(Mandatory)][string[]]$SourceIds,
        [Parameter(Mandatory)][int]$HoursBack,
        [Parameter(Mandatory)][int]$GrantEventsFound,
        [Parameter(Mandatory)][int]$IdentitiesProcessed,
        [Parameter(Mandatory)][int]$ManagerGroups,
        [Parameter(Mandatory)][int]$CampaignsCreated,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CampaignIds,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Errors,
        [Parameter(Mandatory)][double]$DurationSeconds,
        # 'Delta' (default) or 'Full' -- used to distinguish run types in the audit trail.
        [Parameter()][string]$RunMode = 'Delta'
    )

    try {
        $config = Get-SPConfig
        $outputPath = '.\DeltaCert'
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'DeltaCert' -and
            $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
            -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
            $outputPath = $config.DeltaCert.OutputPath
        }

        if (-not (Test-Path -Path $outputPath -PathType Container)) {
            New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
        }

        $event = [ordered]@{
            Timestamp           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            CorrelationID       = $CorrelationID
            RunMode             = $RunMode
            Action              = 'DeltaCertRun'
            SourceIds           = $SourceIds
            HoursBack           = $HoursBack
            GrantEventsFound    = $GrantEventsFound
            IdentitiesProcessed = $IdentitiesProcessed
            ManagerGroups       = $ManagerGroups
            CampaignsCreated    = $CampaignsCreated
            CampaignIds         = $CampaignIds
            Reason              = $Reason
            Errors              = $Errors
            DurationSeconds     = [math]::Round($DurationSeconds, 2)
        }

        $jsonLine = $event | ConvertTo-Json -Depth 5 -Compress
        $filePath = Join-Path -Path $outputPath -ChildPath 'deltacert-audit.jsonl'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($filePath, "$jsonLine`n", $utf8NoBom)

        Write-SPLog -Message "Audit event written to $filePath (RunMode=$RunMode)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Write-SPDeltaCertAuditEvent' `
            -CorrelationID $CorrelationID
    }
    catch {
        Write-SPLog -Message "Failed to write audit JSONL event: $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Write-SPDeltaCertAuditEvent' `
            -CorrelationID $CorrelationID
    }
}

function Test-SPDeltaCertBaselineExists {
    <#
    .SYNOPSIS
        Returns $true if the deltacert-audit.jsonl file exists at the configured output path.
    .DESCRIPTION
        Used by Invoke-SPADDeltaCert.ps1 to detect whether this is a first-ever run
        against this output directory. If the file is absent AND -FullCert is not
        specified, the script emits an advisory warning recommending a full-cert
        baseline run before starting daily delta runs.

        The audit JSONL file is written by Write-SPDeltaCertAuditEvent on every
        successful run. Its absence is the lightest-weight first-run signal available
        without a dedicated state file or ISC API call.

        Reads DeltaCert.OutputPath from config; falls back to '.\DeltaCert' if config
        is unavailable.
    .OUTPUTS
        [bool] $true if the audit file exists; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $config     = Get-SPConfig
        $outputPath = '.\DeltaCert'
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'DeltaCert' -and
            $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
            -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
            $outputPath = $config.DeltaCert.OutputPath
        }
        $filePath = Join-Path -Path $outputPath -ChildPath 'deltacert-audit.jsonl'
        return (Test-Path -Path $filePath -PathType Leaf)
    }
    catch {
        # If config load fails, assume baseline does not exist (safest advisory posture)
        return $false
    }
}

#endregion

#region Public Functions

function Invoke-SPDeltaCertRun {
    <#
    .SYNOPSIS
        Runs the full AD delta certification workflow for a given time window.
    .DESCRIPTION
        Calls the SP.DeltaCertQueries pipeline to find identities who received
        new AD access, groups them by manager, then creates and activates one
        SEARCH-type certification campaign per manager group.

        If no AD GRANT_ACCESS events are found in the time window:
          - Returns Success=$true with CampaignsCreated=0, Reason='NoChanges'
          - No write API calls are made

        Safety guard: aborts before creating any campaigns if the number of
        manager groups exceeds MaxCampaignsPerRun. Prevents runaway campaign
        creation from misconfigured source IDs or unexpectedly large change sets.

    .PARAMETER SourceIds
        Array of SailPoint ISC source IDs to monitor for AD group add operations.
    .PARAMETER HoursBack
        Look-back window in hours for grant events. Default: 24.
    .PARAMETER DeadlineDays
        Days from today until the campaign deadline. Default: 2.
    .PARAMETER CampaignNamePrefix
        Prefix for campaign names. Default: 'AD Delta Cert'.
        Full name format: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
        Escalation and cleanup scripts inherit this prefix unless
        DeltaCert.Escalation.CampaignNamePrefix is explicitly set.
    .PARAMETER FallbackManagerId
        Identity ID used as reviewer for identities who have no manager in ISC.
        If omitted, manager-less identities are skipped.
    .PARAMETER ReviewerMode
        Determines how campaigns are created and who reviews them.
        Manager (default): One SEARCH campaign per manager group. Each manager
            reviews only their direct reports who received new AD access.
        SourceOwner: One SOURCE_OWNER campaign per source ID. ISC automatically
            routes certification items to whoever owns each source. Skips
            identity resolution and manager grouping (faster, fewer API calls).
    .PARAMETER MaxCampaignsPerRun
        Abort before creating any campaigns if manager group count exceeds this.
        Default: 50.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                CampaignsCreated = [int]
                CampaignIds      = [string[]]
                IdentityCount    = [int]
                ManagerGroups    = [int]
                Reason           = [string]    # NoChanges | NoPrivilegedGrants |
                                               # NoActiveIdentities | NoManagerGroups |
                                               # DuplicatesExist | WhatIf | Created
                Errors           = [string[]]  # per-campaign errors (partial failure)
                WhatIfGroups     = [hashtable] # only present when WhatIf=true
            }
            Error   = $string
        }
    .EXAMPLE
        $result = Invoke-SPDeltaCertRun -SourceIds @('src-abc123') -HoursBack 24
        if ($result.Success) {
            "Created $($result.Data.CampaignsCreated) campaign(s)"
        }
    .EXAMPLE
        Invoke-SPDeltaCertRun -SourceIds @('src-abc','src-def') -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [int]$DeadlineDays = 2,

        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [string]$FallbackManagerId,

        [Parameter()]
        [ValidateSet('Manager', 'SourceOwner')]
        [string]$ReviewerMode = 'Manager',

        [Parameter()]
        [int]$MaxCampaignsPerRun = 50,

        [Parameter()]
        [string]$CorrelationID,

        # When set, only creates campaigns for identities who received a GRANT_ACCESS
        # event where the specific entitlement is marked privileged:true in ISC.
        # Falls back to Audit.RiskIndicators.PrivilegedPatterns pattern matching for
        # entitlements not yet tagged in ISC (un-aggregated or unmanaged groups).
        [Parameter()]
        [switch]$PrivilegedOnly,

        # Optional override for the pattern fallback list. When omitted and PrivilegedOnly
        # is set, patterns are read from Audit.RiskIndicators.PrivilegedPatterns in config.
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$PrivilegedPatterns = @(),

        [Parameter()]
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $runStartTime = [System.Diagnostics.Stopwatch]::StartNew()

    Write-SPLog -Message "Invoke-SPDeltaCertRun: Sources='$($SourceIds -join ',')' HoursBack=$HoursBack DeadlineDays=$DeadlineDays PrivilegedOnly=$($PrivilegedOnly.IsPresent) WhatIf=$(($WhatIfPreference -eq $true))" `
        -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Grant events
        Write-SPLog -Message "Step 1: Querying GRANT_ACCESS events (last $HoursBack hours)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $eventsResult = Get-SPDeltaGrantEvents -SourceIds $SourceIds -HoursBack $HoursBack `
            -CorrelationID $CorrelationID

        if (-not $eventsResult.Success) {
            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound 0 -IdentitiesProcessed 0 `
                -ManagerGroups 0 -CampaignsCreated 0 -CampaignIds @() `
                -Reason 'Error' -Errors @("Grant event query failed: $($eventsResult.Error)") `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $false
                Data    = $null
                Error   = "Grant event query failed: $($eventsResult.Error)"
            }
        }

        $grantEvents = @($eventsResult.Data)

        # Step 1b: Privileged-only filter (optional)
        # When -PrivilegedOnly is set, discard grant events for non-privileged entitlements
        # before identity resolution. Only identities who received a privileged AD group
        # will end up in a campaign. This is the primary workload-reduction lever for
        # organisations where daily provisioning is high-volume but most grants are
        # non-sensitive (e.g., distribution lists, project groups).
        if ($PrivilegedOnly) {
            $effectivePatterns = $PrivilegedPatterns
            if ($effectivePatterns.Count -eq 0) {
                try {
                    $cfg = Get-SPConfig
                    if ($null -ne $cfg -and
                        $null -ne $cfg.PSObject.Properties['Audit'] -and
                        $null -ne $cfg.Audit -and
                        $null -ne $cfg.Audit.PSObject.Properties['RiskIndicators'] -and
                        $null -ne $cfg.Audit.RiskIndicators -and
                        $null -ne $cfg.Audit.RiskIndicators.PSObject.Properties['PrivilegedPatterns']) {
                        $effectivePatterns = @($cfg.Audit.RiskIndicators.PrivilegedPatterns)
                    }
                } catch { }
            }

            Write-SPLog -Message "Step 1b: Filtering $($grantEvents.Count) event(s) to privileged entitlements only (patterns=$($effectivePatterns.Count))" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $grantEvents = @(Select-SPPrivilegedGrantEvents `
                -GrantEvents $grantEvents `
                -PrivilegedPatterns $effectivePatterns `
                -CorrelationID $CorrelationID)

            Write-SPLog -Message "Step 1b: $($grantEvents.Count) privileged grant event(s) remain after filter" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
        }

        if ($grantEvents.Count -eq 0) {
            $noChangesReason = if ($PrivilegedOnly) { 'NoPrivilegedGrants' } else { 'NoChanges' }
            Write-SPLog -Message "No AD GRANT_ACCESS events found in the last $HoursBack hours -- no campaigns created" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound 0 -IdentitiesProcessed 0 `
                -ManagerGroups 0 -CampaignsCreated 0 -CampaignIds @() `
                -Reason $noChangesReason -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    Reason           = $noChangesReason
                    Errors           = @()
                }
                Error   = $null
            }
        }

        $dateStamp = Get-Date -Format 'yyyy-MM-dd'

        # Duplicate campaign guard (applies to both modes)
        if (-not $Force) {
            Write-SPLog -Message "Checking for existing campaigns matching '$CampaignNamePrefix $dateStamp'" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $searchResult = Search-SPCampaigns -Keyword "$CampaignNamePrefix $dateStamp" `
                -CorrelationID $CorrelationID

            if ($searchResult.Success -and @($searchResult.Data).Count -gt 0) {
                $existingCount = @($searchResult.Data).Count
                Write-SPLog -Message "Duplicate guard: Found $existingCount existing campaign(s) matching '$CampaignNamePrefix $dateStamp'. Use -Force to bypass." `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                    -CorrelationID $CorrelationID

                $runStartTime.Stop()
                Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                    -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                    -IdentitiesProcessed 0 -ManagerGroups 0 `
                    -CampaignsCreated 0 -CampaignIds @() -Reason 'DuplicatesExist' `
                    -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds

                return @{
                    Success = $true
                    Data    = @{
                        CampaignsCreated = 0
                        CampaignIds      = @()
                        IdentityCount    = 0
                        ManagerGroups    = 0
                        Reason           = 'DuplicatesExist'
                        Errors           = @()
                    }
                    Error   = $null
                }
            }
        }

        # ---------------------------------------------------------------
        # SourceOwner mode: one SOURCE_OWNER campaign per unique source ID
        # ---------------------------------------------------------------
        if ($ReviewerMode -eq 'SourceOwner') {
            Write-SPLog -Message "SourceOwner mode: creating one SOURCE_OWNER campaign per source (skipping identity/manager resolution)" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $uniqueSourceIds = @($grantEvents | Select-Object -ExpandProperty SourceId | Sort-Object -Unique)

            # Safety guard
            if ($uniqueSourceIds.Count -gt $MaxCampaignsPerRun) {
                $errMsg = "Source count ($($uniqueSourceIds.Count)) exceeds MaxCampaignsPerRun ($MaxCampaignsPerRun). " +
                          "Increase DeltaCert.MaxCampaignsPerRun in settings.json if expected."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID

                $runStartTime.Stop()
                Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                    -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                    -IdentitiesProcessed 0 -ManagerGroups 0 `
                    -CampaignsCreated 0 -CampaignIds @() -Reason 'Error' -Errors @($errMsg) `
                    -DurationSeconds $runStartTime.Elapsed.TotalSeconds

                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # WhatIf
            if (($WhatIfPreference -eq $true)) {
                $whatIfGroups = @{}
                foreach ($srcId in $uniqueSourceIds) {
                    $whatIfGroups[$srcId] = @{
                        SourceId     = $srcId
                        CampaignName = "$CampaignNamePrefix $dateStamp - Source $srcId"
                        Deadline     = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-dd')
                    }
                }

                Write-SPLog -Message "WhatIf: Would create $($uniqueSourceIds.Count) SOURCE_OWNER campaign(s)" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                    -CorrelationID $CorrelationID

                $runStartTime.Stop()
                Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                    -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                    -IdentitiesProcessed 0 -ManagerGroups 0 `
                    -CampaignsCreated 0 -CampaignIds @() -Reason 'WhatIf' `
                    -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds

                return @{
                    Success = $true
                    Data    = @{
                        CampaignsCreated = 0
                        CampaignIds      = @()
                        IdentityCount    = 0
                        ManagerGroups    = 0
                        Reason           = 'WhatIf'
                        Errors           = @()
                        WhatIfGroups     = $whatIfGroups
                    }
                    Error   = $null
                }
            }

            # Create and activate SOURCE_OWNER campaigns
            $campaignIds    = [System.Collections.Generic.List[string]]::new()
            $campaignErrors = [System.Collections.Generic.List[string]]::new()
            $deadlineStr    = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

            foreach ($srcId in $uniqueSourceIds) {
                $campaignName = "$CampaignNamePrefix $dateStamp - Source $srcId"

                Write-SPLog -Message "Creating SOURCE_OWNER campaign '$campaignName' (source='$srcId')" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                    -CorrelationID $CorrelationID

                $createResult = New-SPCampaign `
                    -Name        $campaignName `
                    -Type        'SOURCE_OWNER' `
                    -SourceId    $srcId `
                    -Description "Daily AD delta certification: SOURCE_OWNER review for source $srcId, $dateStamp." `
                    -Deadline    $deadlineStr `
                    -CorrelationID $CorrelationID

                if (-not $createResult.Success) {
                    $errMsg = "Campaign '$campaignName' create failed: $($createResult.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                        -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
                    $campaignErrors.Add($errMsg)
                    continue
                }

                $campaignId = $createResult.Data.id

                $activateResult = Start-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

                if (-not $activateResult.Success) {
                    $errMsg = "Campaign '$campaignName' ($campaignId) created but activation failed: $($activateResult.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                        -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
                    $campaignErrors.Add($errMsg)
                    $campaignIds.Add($campaignId)
                    continue
                }

                Write-SPLog -Message "Campaign '$campaignName' ($campaignId) created and activation requested" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                    -CorrelationID $CorrelationID
                $campaignIds.Add($campaignId)
            }

            $overallSuccess = ($campaignErrors.Count -eq 0)

            if ($campaignErrors.Count -gt 0) {
                Write-SPLog -Message "$($campaignErrors.Count) campaign(s) had creation/activation errors" `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                    -CorrelationID $CorrelationID
            }

            Write-SPLog -Message "Invoke-SPDeltaCertRun (SourceOwner) complete: $($campaignIds.Count) campaign(s) for $($uniqueSourceIds.Count) source(s)" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                -IdentitiesProcessed 0 -ManagerGroups 0 `
                -CampaignsCreated $campaignIds.Count -CampaignIds $campaignIds.ToArray() `
                -Reason 'Created' -Errors $campaignErrors.ToArray() `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $overallSuccess
                Data    = @{
                    CampaignsCreated = $campaignIds.Count
                    CampaignIds      = $campaignIds.ToArray()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    Reason           = 'Created'
                    Errors           = $campaignErrors.ToArray()
                }
                Error   = if ($campaignErrors.Count -gt 0) { $campaignErrors -join '; ' } else { $null }
            }
        }

        # ---------------------------------------------------------------
        # Manager mode (default): SEARCH campaign per manager group
        # ---------------------------------------------------------------

        # Step 2: Resolve active identities with managers
        Write-SPLog -Message "Step 2: Resolving $($grantEvents.Count) event(s) to active identities" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $identResult = Get-SPDeltaAffectedIdentities -GrantEvents $grantEvents `
            -FallbackManagerId $FallbackManagerId -CorrelationID $CorrelationID

        if (-not $identResult.Success) {
            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count -IdentitiesProcessed 0 `
                -ManagerGroups 0 -CampaignsCreated 0 -CampaignIds @() `
                -Reason 'Error' -Errors @("Identity resolution failed: $($identResult.Error)") `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $false
                Data    = $null
                Error   = "Identity resolution failed: $($identResult.Error)"
            }
        }

        $affectedIdentities = @($identResult.Data)

        if ($affectedIdentities.Count -eq 0) {
            Write-SPLog -Message "No active identities with managers after filtering -- no campaigns created" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count -IdentitiesProcessed 0 `
                -ManagerGroups 0 -CampaignsCreated 0 -CampaignIds @() `
                -Reason 'NoActiveIdentities' -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    Reason           = 'NoActiveIdentities'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Step 3: Group by manager
        Write-SPLog -Message "Step 3: Grouping $($affectedIdentities.Count) identit(ies) by manager" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $groupResult = Group-SPDeltaByManager -AffectedIdentities $affectedIdentities `
            -CorrelationID $CorrelationID

        if (-not $groupResult.Success) {
            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                -IdentitiesProcessed $affectedIdentities.Count -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() `
                -Reason 'Error' -Errors @("Manager grouping failed: $($groupResult.Error)") `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $false
                Data    = $null
                Error   = "Manager grouping failed: $($groupResult.Error)"
            }
        }

        $managerGroups = $groupResult.Data

        if ($managerGroups.Count -eq 0) {
            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                -IdentitiesProcessed $affectedIdentities.Count -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'NoManagerGroups' `
                -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $affectedIdentities.Count
                    ManagerGroups    = 0
                    Reason           = 'NoManagerGroups'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Safety guard
        if ($managerGroups.Count -gt $MaxCampaignsPerRun) {
            $errMsg = "Manager group count ($($managerGroups.Count)) exceeds MaxCampaignsPerRun ($MaxCampaignsPerRun). " +
                      "Increase DeltaCert.MaxCampaignsPerRun in settings.json if expected."
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                -IdentitiesProcessed $affectedIdentities.Count -ManagerGroups $managerGroups.Count `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'Error' -Errors @($errMsg) `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # WhatIf: describe without writing
        if (($WhatIfPreference -eq $true)) {
            $whatIfGroups = @{}
            foreach ($managerId in $managerGroups.Keys) {
                $identities  = $managerGroups[$managerId]
                $managerName = if ($identities.Count -gt 0 -and
                                   -not [string]::IsNullOrWhiteSpace($identities[0].ManagerName)) {
                                   $identities[0].ManagerName
                               } else { $managerId }
                $whatIfGroups[$managerId] = @{
                    ManagerName   = $managerName
                    IdentityCount = $identities.Count
                    IdentityIds   = @($identities | Select-Object -ExpandProperty IdentityId)
                    CampaignName  = "$CampaignNamePrefix $dateStamp - $managerName"
                    Deadline      = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-dd')
                }
            }

            Write-SPLog -Message "WhatIf: Would create $($managerGroups.Count) campaign(s) for $($affectedIdentities.Count) identit(ies)" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
                -IdentitiesProcessed $affectedIdentities.Count -ManagerGroups $managerGroups.Count `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'WhatIf' `
                -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $affectedIdentities.Count
                    ManagerGroups    = $managerGroups.Count
                    Reason           = 'WhatIf'
                    Errors           = @()
                    WhatIfGroups     = $whatIfGroups
                }
                Error   = $null
            }
        }

        # Step 4: Create and activate one SEARCH campaign per manager group
        Write-SPLog -Message "Step 4: Creating $($managerGroups.Count) campaign(s) (deadline +$DeadlineDays day(s))" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $campaignIds    = [System.Collections.Generic.List[string]]::new()
        $campaignErrors = [System.Collections.Generic.List[string]]::new()
        $deadlineStr    = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

        foreach ($managerId in $managerGroups.Keys) {
            $identities  = $managerGroups[$managerId]
            $managerName = if ($identities.Count -gt 0 -and
                               -not [string]::IsNullOrWhiteSpace($identities[0].ManagerName)) {
                               $identities[0].ManagerName
                           } else { $managerId }

            $campaignName = "$CampaignNamePrefix $dateStamp - $managerName"
            $identityIds  = @($identities | Select-Object -ExpandProperty IdentityId)
            $searchFilter = Build-SPDeltaSearchFilter -IdentityIds $identityIds

            Write-SPLog -Message "Creating campaign '$campaignName' ($($identityIds.Count) identit(ies), manager='$managerId')" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $createResult = New-SPCampaign `
                -Name                $campaignName `
                -Type                'SEARCH' `
                -SearchFilter        $searchFilter `
                -CertifierIdentityId $managerId `
                -Description         "Daily AD delta certification: $($identityIds.Count) identit(ies) with new AD access assigned $dateStamp." `
                -Deadline            $deadlineStr `
                -CorrelationID       $CorrelationID

            if (-not $createResult.Success) {
                $errMsg = "Campaign '$campaignName' create failed: $($createResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                continue
            }

            $campaignId = $createResult.Data.id

            $activateResult = Start-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

            if (-not $activateResult.Success) {
                $errMsg = "Campaign '$campaignName' ($campaignId) created but activation failed: $($activateResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                $campaignIds.Add($campaignId)  # track even if activation failed
                continue
            }

            Write-SPLog -Message "Campaign '$campaignName' ($campaignId) created and activation requested" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
            $campaignIds.Add($campaignId)
        }

        $overallSuccess = ($campaignErrors.Count -eq 0)

        if ($campaignErrors.Count -gt 0) {
            Write-SPLog -Message "$($campaignErrors.Count) campaign(s) had creation/activation errors" `
                -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Invoke-SPDeltaCertRun complete: $($campaignIds.Count) campaign(s) for $($affectedIdentities.Count) identit(ies) across $($managerGroups.Count) manager group(s)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $runStartTime.Stop()
        Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
            -HoursBack $HoursBack -GrantEventsFound $grantEvents.Count `
            -IdentitiesProcessed $affectedIdentities.Count -ManagerGroups $managerGroups.Count `
            -CampaignsCreated $campaignIds.Count -CampaignIds $campaignIds.ToArray() `
            -Reason 'Created' -Errors $campaignErrors.ToArray() `
            -DurationSeconds $runStartTime.Elapsed.TotalSeconds

        return @{
            Success = $overallSuccess
            Data    = @{
                CampaignsCreated = $campaignIds.Count
                CampaignIds      = $campaignIds.ToArray()
                IdentityCount    = $affectedIdentities.Count
                ManagerGroups    = $managerGroups.Count
                Reason           = 'Created'
                Errors           = $campaignErrors.ToArray()
            }
            Error   = if ($campaignErrors.Count -gt 0) { $campaignErrors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDeltaCertRun failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
            -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID

        $runStartTime.Stop()
        Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
            -HoursBack $HoursBack -GrantEventsFound 0 -IdentitiesProcessed 0 `
            -ManagerGroups 0 -CampaignsCreated 0 -CampaignIds @() `
            -Reason 'Error' -Errors @($errMsg) `
            -DurationSeconds $runStartTime.Elapsed.TotalSeconds

        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Invoke-SPDeltaCertEscalate {
    <#
    .SYNOPSIS
        Escalates stale delta cert certifications by reassigning them up the org tree.
    .DESCRIPTION
        Takes stale certifications (from Get-SPDeltaCertStaleCertifications) and
        reassigns them to the current reviewer's manager. For certifications that
        have already been reassigned once (ReviewerClassification = 'Reassigned'),
        one escalation level is consumed, leaving fewer remaining levels.

        MaxEscalationLevels controls the total number of escalation hops allowed
        across multiple runs. A 'Primary' cert has all levels available; a
        'Reassigned' cert has one level already consumed.

        ISC constraint: Invoke-SPReassign max 50 items per call. If a certification
        has more than 50 review items, Invoke-SPReassignAsync is used automatically.

        ISC constraint: Reassignment does NOT work for Governance Group certifications.
        These are detected and skipped with a WARN log.
    .PARAMETER StaleCertifications
        Array of stale certification objects as returned by Get-SPDeltaCertStaleCertifications.
        Each object must have: CertificationId, CampaignId, CampaignName,
        ReviewerIdentityId, ReviewerName, HoursOpen, ReviewerClassification.
    .PARAMETER MaxEscalationLevels
        Maximum number of escalation hops allowed from the original reviewer.
        Default: 2. A 'Reassigned' certification has already consumed one level.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                Escalated = [string[]]  # certification IDs reassigned
                Skipped   = [string[]]  # certification IDs that could not be escalated
                Errors    = [string[]]  # per-certification error messages
            }
            Error   = $string
        }
    .EXAMPLE
        $stale = (Get-SPDeltaCertStaleCertifications -StaleHours 24).Data
        $result = Invoke-SPDeltaCertEscalate -StaleCertifications $stale
        "Escalated $($result.Data.Escalated.Count), Skipped $($result.Data.Skipped.Count)"
    .EXAMPLE
        $stale = (Get-SPDeltaCertStaleCertifications -StaleHours 24).Data
        Invoke-SPDeltaCertEscalate -StaleCertifications $stale -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$StaleCertifications,

        [Parameter()]
        [int]$MaxEscalationLevels = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Invoke-SPDeltaCertEscalate: Processing $($StaleCertifications.Count) stale certification(s), MaxEscalationLevels=$MaxEscalationLevels" `
        -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
        -CorrelationID $CorrelationID

    try {
        $escalated = [System.Collections.Generic.List[string]]::new()
        $skipped   = [System.Collections.Generic.List[string]]::new()
        $errors    = [System.Collections.Generic.List[string]]::new()

        if ($StaleCertifications.Count -eq 0) {
            Write-SPLog -Message "No stale certifications to escalate" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    Escalated = @()
                    Skipped   = @()
                    Errors    = @()
                }
                Error   = $null
            }
        }

        foreach ($staleCert in $StaleCertifications) {
            $certId         = $staleCert.CertificationId
            $campaignName   = $staleCert.CampaignName
            $reviewerId     = $staleCert.ReviewerIdentityId
            $hoursOpen      = $staleCert.HoursOpen
            $classification = $staleCert.ReviewerClassification

            Write-SPLog -Message "Evaluating stale cert '$certId' (reviewer='$reviewerId', campaign='$campaignName', hours=$hoursOpen, classification='$classification')" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                -CorrelationID $CorrelationID

            # MaxEscalationLevels guard: Reassigned certs have consumed one level
            $levelsConsumed = if ($classification -eq 'Reassigned') { 1 } else { 0 }
            $levelsRemaining = $MaxEscalationLevels - $levelsConsumed

            if ($levelsRemaining -le 0) {
                Write-SPLog -Message "Cert '$certId' has reached MaxEscalationLevels ($MaxEscalationLevels) -- skipping" `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $skipped.Add($certId)
                continue
            }

            if ([string]::IsNullOrWhiteSpace($reviewerId)) {
                Write-SPLog -Message "Cert '$certId' has no ReviewerIdentityId (campaign='$campaignName') -- cannot escalate, skipping" `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $skipped.Add($certId)
                continue
            }

            # Resolve current reviewer's manager
            $reviewerDetail = Get-SPDeltaIdentityDetail -IdentityId $reviewerId -CorrelationID $CorrelationID

            if (-not $reviewerDetail.Found) {
                Write-SPLog -Message "Reviewer '$reviewerId' not found in ISC -- cannot escalate cert '$certId'" `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $skipped.Add($certId)
                continue
            }

            if ([string]::IsNullOrWhiteSpace($reviewerDetail.ManagerId)) {
                Write-SPLog -Message "Reviewer '$reviewerId' ($($reviewerDetail.DisplayName)) has no manager -- cannot escalate cert '$certId'" `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $skipped.Add($certId)
                continue
            }

            $escalationTarget = $reviewerDetail.ManagerId

            # Get review items for this certification
            $itemsResult = Get-SPAuditCertificationItems -CertificationId $certId `
                -CorrelationID $CorrelationID

            if (-not $itemsResult.Success) {
                $errMsg = "Failed to get review items for cert '$certId': $($itemsResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertEscalate' -CorrelationID $CorrelationID
                $errors.Add($errMsg)
                continue
            }

            $reviewItems = @($itemsResult.Data)
            if ($reviewItems.Count -eq 0) {
                Write-SPLog -Message "Cert '$certId' has no review items -- skipping" `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $skipped.Add($certId)
                continue
            }

            $reviewItemIds = @($reviewItems | ForEach-Object { [string]$_.id })
            $reason = "SLA escalation: $hoursOpen hours without action"

            # WhatIf: show full reviewer→skip-level chain, no write API calls
            if (($WhatIfPreference -eq $true)) {
                $skipLevelDetail  = Get-SPDeltaIdentityDetail -IdentityId $escalationTarget -CorrelationID $CorrelationID
                $skipLevelName    = if ($skipLevelDetail.Found) { $skipLevelDetail.DisplayName } else { "UNRESOLVED ($escalationTarget)" }
                $reviewerDisplay  = if (-not [string]::IsNullOrWhiteSpace($staleCert.ReviewerName)) { $staleCert.ReviewerName } else { $reviewerId }
                $deadlineDisplay  = if ($null -ne $staleCert.HoursUntilDeadline) { "$($staleCert.HoursUntilDeadline)h until deadline" } else { 'no deadline' }
                $reasonDisplay    = if (-not [string]::IsNullOrWhiteSpace($staleCert.EscalationReason) -and $staleCert.EscalationReason -ne 'AuditAll') { "[$($staleCert.EscalationReason)]" } else { '[org-audit]' }

                Write-Host "    $($staleCert.CampaignName)" -ForegroundColor DarkGray
                Write-Host "      Reviewer:    $reviewerDisplay" -ForegroundColor White
                Write-Host "      Skip-level:  $skipLevelName" -ForegroundColor $(if ($skipLevelDetail.Found) { 'Green' } else { 'Red' })
                Write-Host "      Items:       $($reviewItemIds.Count)   $deadlineDisplay   $reasonDisplay" -ForegroundColor DarkGray
                Write-Host ''

                Write-SPLog -Message "WhatIf: Would reassign cert '$certId' ($($reviewItemIds.Count) items) from '$reviewerDisplay' to '$skipLevelName' ($escalationTarget)" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $escalated.Add($certId)
                continue
            }

            # Reassign: sync if <=50 items, async if >50 (ISC constraint)
            if ($reviewItemIds.Count -le 50) {
                Write-SPLog -Message "Reassigning cert '$certId' ($($reviewItemIds.Count) items) to '$escalationTarget' (sync)" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID

                $reassignResult = Invoke-SPReassign `
                    -CertificationId $certId `
                    -NewCertifierIdentityId $escalationTarget `
                    -ReviewItemIds $reviewItemIds `
                    -Reason $reason `
                    -CorrelationID $CorrelationID
            }
            else {
                Write-SPLog -Message "Reassigning cert '$certId' ($($reviewItemIds.Count) items) to '$escalationTarget' (async, >50 items)" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID

                $reassignResult = Invoke-SPReassignAsync `
                    -CertificationId $certId `
                    -NewCertifierIdentityId $escalationTarget `
                    -ReviewItemIds $reviewItemIds `
                    -Reason $reason `
                    -CorrelationID $CorrelationID
            }

            if ($reassignResult.Success) {
                Write-SPLog -Message "Cert '$certId' escalated from '$reviewerId' to '$escalationTarget'" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
                    -CorrelationID $CorrelationID
                $escalated.Add($certId)
            }
            else {
                $errMsg = "Reassignment failed for cert '$certId': $($reassignResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertEscalate' -CorrelationID $CorrelationID
                $errors.Add($errMsg)
            }
        }

        Write-SPLog -Message "Invoke-SPDeltaCertEscalate complete: Escalated=$($escalated.Count) Skipped=$($skipped.Count) Errors=$($errors.Count)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertEscalate' `
            -CorrelationID $CorrelationID

        return @{
            Success = ($errors.Count -eq 0)
            Data    = @{
                Escalated = $escalated.ToArray()
                Skipped   = $skipped.ToArray()
                Errors    = $errors.ToArray()
            }
            Error   = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDeltaCertEscalate failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
            -Action 'Invoke-SPDeltaCertEscalate' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Invoke-SPDeltaCertCleanup {
    <#
    .SYNOPSIS
        Finds past-due delta cert campaigns and completes them.
    .DESCRIPTION
        Intended to run daily before creating new campaigns, preventing campaign
        pile-up from managers who never action their reviews.

        Flow:
        1. Search for active campaigns matching the name prefix
        2. For each campaign, check if deadline has passed or if created date
           is older than DaysStale
        3. Complete past-due campaigns via Complete-SPCampaign
        4. Return summary of completed, still-active, and errored campaigns

        Guarded by Safety.AllowCompleteCampaign (default false). If this setting
        is false, cleanup returns an error without making any API calls.
    .PARAMETER CampaignNamePrefix
        Prefix used to find delta cert campaigns. Default: 'AD Delta Cert'.
        Callers should resolve from DeltaCert.CampaignNamePrefix in config.
        DeltaCert.Escalation.CampaignNamePrefix, when set, overrides this
        for escalation workflows only.
    .PARAMETER DaysStale
        Number of days after which a campaign without a deadline is considered
        stale based on its created date. Default: 3.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                Completed   = [string[]]  # campaign IDs completed
                StillActive = [string[]]  # campaign IDs not yet stale
                Errors      = [string[]]  # per-campaign error messages
            }
            Error   = $string
        }
    .EXAMPLE
        Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3
    .EXAMPLE
        Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [int]$DaysStale = 3,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Invoke-SPDeltaCertCleanup: Prefix='$CampaignNamePrefix' DaysStale=$DaysStale WhatIf=$(($WhatIfPreference -eq $true))" `
        -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
        -CorrelationID $CorrelationID

    try {
        # Safety guard: check AllowCompleteCampaign before any API calls
        $config = Get-SPConfig
        $allowComplete = $false
        if ($null -ne $config -and
            $null -ne $config.PSObject.Properties['Safety'] -and
            $null -ne $config.Safety -and
            $config.Safety.PSObject.Properties.Name -contains 'AllowCompleteCampaign') {
            $allowComplete = [bool]$config.Safety.AllowCompleteCampaign
        }
        if (-not $allowComplete) {
            $errMsg = "Invoke-SPDeltaCertCleanup blocked: Safety.AllowCompleteCampaign is set to false in settings.json. " +
                      "Campaign completion requires this setting to be true."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.DeltaCertRunner' `
                -Action 'Invoke-SPDeltaCertCleanup' -CorrelationID $CorrelationID
            return @{
                Success = $false
                Data    = $null
                Error   = $errMsg
            }
        }

        # Step 1: Find active delta cert campaigns
        Write-SPLog -Message "Searching for active campaigns matching '$CampaignNamePrefix'" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
            -CorrelationID $CorrelationID

        $searchResult = Search-SPCampaigns -Keyword $CampaignNamePrefix -Status @('ACTIVE') `
            -CorrelationID $CorrelationID

        if (-not $searchResult.Success) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Campaign search failed: $($searchResult.Error)"
            }
        }

        $activeCampaigns = @($searchResult.Data)

        if ($activeCampaigns.Count -eq 0) {
            Write-SPLog -Message "No active campaigns found matching '$CampaignNamePrefix'" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    Completed   = @()
                    StillActive = @()
                    Errors      = @()
                }
                Error   = $null
            }
        }

        # Step 2: Evaluate staleness and complete past-due campaigns
        $nowUtc         = (Get-Date).ToUniversalTime()
        $staleThreshold = $nowUtc.AddDays(-$DaysStale)
        $completed      = [System.Collections.Generic.List[string]]::new()
        $stillActive    = [System.Collections.Generic.List[string]]::new()
        $errors         = [System.Collections.Generic.List[string]]::new()

        foreach ($campaign in $activeCampaigns) {
            $campaignId   = $campaign.id
            $campaignName = $campaign.name
            $isStale      = $false

            # Check if deadline has passed
            $deadlineStr = $null
            if ($campaign -is [PSCustomObject] -and $campaign.PSObject.Properties.Name -contains 'deadline') {
                $deadlineStr = $campaign.deadline
            }
            elseif ($campaign -is [hashtable] -and $campaign.ContainsKey('deadline')) {
                $deadlineStr = $campaign['deadline']
            }

            if (-not [string]::IsNullOrWhiteSpace($deadlineStr)) {
                try {
                    $deadline = [datetime]::Parse([string]$deadlineStr).ToUniversalTime()
                    if ($deadline -lt $nowUtc) {
                        $isStale = $true
                    }
                }
                catch {
                    Write-SPLog -Message "Failed to parse deadline for campaign '$campaignName': $($_.Exception.Message)" `
                        -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
                        -CorrelationID $CorrelationID
                }
            }

            # Fallback: check if created date is older than DaysStale
            if (-not $isStale) {
                $createdStr = $null
                if ($campaign -is [PSCustomObject] -and $campaign.PSObject.Properties.Name -contains 'created') {
                    $createdStr = $campaign.created
                }
                elseif ($campaign -is [hashtable] -and $campaign.ContainsKey('created')) {
                    $createdStr = $campaign['created']
                }

                if (-not [string]::IsNullOrWhiteSpace($createdStr)) {
                    try {
                        $created = [datetime]::Parse([string]$createdStr).ToUniversalTime()
                        if ($created -lt $staleThreshold) {
                            $isStale = $true
                        }
                    }
                    catch {
                        Write-SPLog -Message "Failed to parse created date for campaign '$campaignName': $($_.Exception.Message)" `
                            -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
                            -CorrelationID $CorrelationID
                    }
                }
            }

            if (-not $isStale) {
                $stillActive.Add($campaignId)
                continue
            }

            # WhatIf: describe without completing
            if (($WhatIfPreference -eq $true)) {
                Write-SPLog -Message "WhatIf: Would complete stale campaign '$campaignName' ($campaignId)" `
                    -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
                    -CorrelationID $CorrelationID
                $completed.Add($campaignId)
                continue
            }

            # Step 3: Complete the stale campaign
            Write-SPLog -Message "Completing stale campaign '$campaignName' ($campaignId)" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
                -CorrelationID $CorrelationID

            $completeResult = Complete-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

            if ($completeResult.Success) {
                $completed.Add($campaignId)
            }
            else {
                $errMsg = "Failed to complete campaign '$campaignName' ($campaignId): $($completeResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertCleanup' -CorrelationID $CorrelationID
                $errors.Add($errMsg)
            }
        }

        Write-SPLog -Message "Invoke-SPDeltaCertCleanup complete: Completed=$($completed.Count) StillActive=$($stillActive.Count) Errors=$($errors.Count)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertCleanup' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Completed   = $completed.ToArray()
                StillActive = $stillActive.ToArray()
                Errors      = $errors.ToArray()
            }
            Error   = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDeltaCertCleanup failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
            -Action 'Invoke-SPDeltaCertCleanup' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Invoke-SPDeltaCertFullRun {
    <#
    .SYNOPSIS
        Creates quarterly full-certification campaigns for all managers who have
        staff on the monitored AD sources.
    .DESCRIPTION
        FULL mode establishes a baseline certification covering ALL current
        entitlements for every active identity with an account on the monitored
        source IDs. It does not query account-activities and is not bounded by
        a time window.

        One MANAGER-type campaign is created per unique manager found by
        Get-SPDeltaManagersForSources. ISC's MANAGER campaign type automatically
        scopes the review to all direct reports of the certifier identity,
        presenting their full entitlement set. No identity list or Lucene search
        filter is required.

        IMPORTANT -- ISC API scope:
          The ISC /v3/campaigns API does not support entitlement-level SEARCH
          filters. A MANAGER campaign covers ALL entitlements for all direct
          reports, not just entitlements on the monitored AD sources. This is
          correct for a quarterly full baseline: the goal is a complete review
          of each manager's direct reports, not a narrow window view.
          See the DELTA mode (Invoke-SPDeltaCertRun) for time-window-scoped
          reviews limited to identities who received new AD access.

        Campaign naming: "{FullCertPrefix} {YYYY-MM-DD} - {ManagerName}"
          The prefix defaults to DeltaCert.FullCert.CampaignNamePrefix in
          settings.json (fallback: 'AD Full Cert'). The separate prefix ensures
          the duplicate guard does not collide with same-day DELTA campaigns.

        Safety guards, WhatIf, and the audit JSONL trail work identically to
        Invoke-SPDeltaCertRun. The return envelope shape is identical so the
        Invoke-SPADDeltaCert.ps1 output section does not require branching.

    .PARAMETER SourceIds
        Array of SailPoint ISC source IDs to use when resolving which managers
        have staff on the monitored AD sources.
    .PARAMETER DeadlineDays
        Days from today until the campaign deadline.
        Reads DeltaCert.FullCert.DeadlineDays from settings.json; defaults to 14
        (two weeks, appropriate for quarterly review cadence).
    .PARAMETER CampaignNamePrefix
        Prefix for full-cert campaign names.
        Reads DeltaCert.FullCert.CampaignNamePrefix from settings.json; defaults
        to 'AD Full Cert'.
    .PARAMETER FallbackManagerId
        Identity ID used as campaign certifier for managers who are not found in
        ISC. If omitted, unresolved managers are skipped.
    .PARAMETER MaxCampaignsPerRun
        Abort before creating any campaigns if the number of managers exceeds this.
        Default: 50. Operators running -FullCert on large orgs should temporarily
        raise DeltaCert.MaxCampaignsPerRun in settings.json.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                CampaignsCreated = [int]
                CampaignIds      = [string[]]
                IdentityCount    = [int]       # 0 for MANAGER type (scope is implicit)
                ManagerGroups    = [int]
                Reason           = [string]    # NoManagers | WhatIf | Created | DuplicatesExist
                Errors           = [string[]]
                WhatIfGroups     = [hashtable] # only present when WhatIf=true
            }
            Error   = $string
        }
    .EXAMPLE
        $result = Invoke-SPDeltaCertFullRun -SourceIds @('src-abc123')
        "Created $($result.Data.CampaignsCreated) full-cert campaign(s)"
    .EXAMPLE
        Invoke-SPDeltaCertFullRun -SourceIds @('src-abc123') -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$DeadlineDays = 14,

        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Full Cert',

        [Parameter()]
        [string]$FallbackManagerId,

        [Parameter()]
        [int]$MaxCampaignsPerRun = 50,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $runStartTime = [System.Diagnostics.Stopwatch]::StartNew()

    Write-SPLog -Message "Invoke-SPDeltaCertFullRun: Sources='$($SourceIds -join ',')' DeadlineDays=$DeadlineDays WhatIf=$(($WhatIfPreference -eq $true))" `
        -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
        -CorrelationID $CorrelationID

    try {
        $dateStamp = Get-Date -Format 'yyyy-MM-dd'

        # Duplicate campaign guard (Full campaigns use their own prefix)
        if (-not $Force) {
            Write-SPLog -Message "Checking for existing full-cert campaigns matching '$CampaignNamePrefix $dateStamp'" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                -CorrelationID $CorrelationID

            $searchResult = Search-SPCampaigns -Keyword "$CampaignNamePrefix $dateStamp" `
                -CorrelationID $CorrelationID

            if ($searchResult.Success -and @($searchResult.Data).Count -gt 0) {
                $existingCount = @($searchResult.Data).Count
                Write-SPLog -Message "Duplicate guard: Found $existingCount existing full-cert campaign(s) matching '$CampaignNamePrefix $dateStamp'. Use -Force to bypass." `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                    -CorrelationID $CorrelationID

                $runStartTime.Stop()
                Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                    -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 -ManagerGroups 0 `
                    -CampaignsCreated 0 -CampaignIds @() -Reason 'DuplicatesExist' `
                    -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

                return @{
                    Success = $true
                    Data    = @{
                        CampaignsCreated = 0
                        CampaignIds      = @()
                        IdentityCount    = 0
                        ManagerGroups    = 0
                        Reason           = 'DuplicatesExist'
                        Errors           = @()
                    }
                    Error   = $null
                }
            }
        }

        # Step 1: Resolve all managers who have staff on the monitored sources
        Write-SPLog -Message "Step 1: Resolving managers with staff on monitored sources" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
            -CorrelationID $CorrelationID

        $mgrResult = Get-SPDeltaManagersForSources -SourceIds $SourceIds -CorrelationID $CorrelationID

        if (-not $mgrResult.Success) {
            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'Error' `
                -Errors @("Manager resolution failed: $($mgrResult.Error)") `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

            return @{
                Success = $false
                Data    = $null
                Error   = "Manager resolution failed: $($mgrResult.Error)"
            }
        }

        $managerMap = $mgrResult.Data  # hashtable: managerId -> ManagerName

        if ($managerMap.Count -eq 0) {
            Write-SPLog -Message "No managers found with staff on monitored sources -- no campaigns created" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'NoManagers' `
                -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    Reason           = 'NoManagers'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Safety guard: abort before writing if manager count exceeds limit
        if ($managerMap.Count -gt $MaxCampaignsPerRun) {
            $errMsg = "Manager count ($($managerMap.Count)) exceeds MaxCampaignsPerRun ($MaxCampaignsPerRun). " +
                      "Increase DeltaCert.MaxCampaignsPerRun in settings.json or use -MaxCampaignsPerRun."
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                -Action 'Invoke-SPDeltaCertFullRun' -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 -ManagerGroups $managerMap.Count `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'Error' -Errors @($errMsg) `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # WhatIf: describe without creating
        if (($WhatIfPreference -eq $true)) {
            $whatIfGroups = @{}
            foreach ($managerId in $managerMap.Keys) {
                $managerName = $managerMap[$managerId]
                if ([string]::IsNullOrWhiteSpace($managerName)) { $managerName = $managerId }
                $whatIfGroups[$managerId] = @{
                    ManagerName  = $managerName
                    CampaignName = "$CampaignNamePrefix $dateStamp - $managerName"
                    Deadline     = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-dd')
                    CampaignType = 'MANAGER'
                }
            }

            Write-SPLog -Message "WhatIf: Would create $($managerMap.Count) MANAGER campaign(s) for full cert" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
                -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 -ManagerGroups $managerMap.Count `
                -CampaignsCreated 0 -CampaignIds @() -Reason 'WhatIf' `
                -Errors @() -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = $managerMap.Count
                    Reason           = 'WhatIf'
                    Errors           = @()
                    WhatIfGroups     = $whatIfGroups
                }
                Error   = $null
            }
        }

        # Step 2: Create and activate one MANAGER campaign per manager
        Write-SPLog -Message "Step 2: Creating $($managerMap.Count) MANAGER campaign(s) (deadline +$DeadlineDays day(s))" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
            -CorrelationID $CorrelationID

        $campaignIds    = [System.Collections.Generic.List[string]]::new()
        $campaignErrors = [System.Collections.Generic.List[string]]::new()
        $deadlineStr    = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

        foreach ($managerId in $managerMap.Keys) {
            $managerName = $managerMap[$managerId]
            if ([string]::IsNullOrWhiteSpace($managerName)) { $managerName = $managerId }

            $campaignName = "$CampaignNamePrefix $dateStamp - $managerName"

            Write-SPLog -Message "Creating MANAGER campaign '$campaignName' (certifier='$managerId')" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                -CorrelationID $CorrelationID

            $createResult = New-SPCampaign `
                -Name                $campaignName `
                -Type                'MANAGER' `
                -CertifierIdentityId $managerId `
                -Description         "Quarterly AD full certification: all direct reports of $managerName as of $dateStamp." `
                -Deadline            $deadlineStr `
                -CorrelationID       $CorrelationID

            if (-not $createResult.Success) {
                $errMsg = "Campaign '$campaignName' create failed: $($createResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertFullRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                continue
            }

            $campaignId = $createResult.Data.id

            $activateResult = Start-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

            if (-not $activateResult.Success) {
                $errMsg = "Campaign '$campaignName' ($campaignId) created but activation failed: $($activateResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertFullRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                $campaignIds.Add($campaignId)
                continue
            }

            Write-SPLog -Message "Campaign '$campaignName' ($campaignId) created and activation requested" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                -CorrelationID $CorrelationID
            $campaignIds.Add($campaignId)
        }

        $overallSuccess = ($campaignErrors.Count -eq 0)

        if ($campaignErrors.Count -gt 0) {
            Write-SPLog -Message "$($campaignErrors.Count) full-cert campaign(s) had creation/activation errors" `
                -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Invoke-SPDeltaCertFullRun complete: $($campaignIds.Count) MANAGER campaign(s) for $($managerMap.Count) manager(s)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertFullRun' `
            -CorrelationID $CorrelationID

        $runStartTime.Stop()
        Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
            -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 -ManagerGroups $managerMap.Count `
            -CampaignsCreated $campaignIds.Count -CampaignIds $campaignIds.ToArray() `
            -Reason 'Created' -Errors $campaignErrors.ToArray() `
            -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

        return @{
            Success = $overallSuccess
            Data    = @{
                CampaignsCreated = $campaignIds.Count
                CampaignIds      = $campaignIds.ToArray()
                IdentityCount    = 0   # MANAGER campaigns scope to all direct reports implicitly
                ManagerGroups    = $managerMap.Count
                Reason           = 'Created'
                Errors           = $campaignErrors.ToArray()
            }
            Error   = if ($campaignErrors.Count -gt 0) { $campaignErrors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDeltaCertFullRun failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
            -Action 'Invoke-SPDeltaCertFullRun' -CorrelationID $CorrelationID

        $runStartTime.Stop()
        Write-SPDeltaCertAuditEvent -CorrelationID $CorrelationID -SourceIds $SourceIds `
            -HoursBack 0 -GrantEventsFound 0 -IdentitiesProcessed 0 `
            -ManagerGroups 0 -CampaignsCreated 0 -CampaignIds @() `
            -Reason 'Error' -Errors @($errMsg) `
            -DurationSeconds $runStartTime.Elapsed.TotalSeconds -RunMode 'Full'

        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPDeltaCertRun',
    'Invoke-SPDeltaCertFullRun',
    'Invoke-SPDeltaCertCleanup',
    'Invoke-SPDeltaCertEscalate',
    'Test-SPDeltaCertBaselineExists'
)
