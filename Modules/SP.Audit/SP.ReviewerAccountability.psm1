#Requires -Version 5.1
<#
.SYNOPSIS
    SP.ReviewerAccountability -- cross-campaign, cross-day reviewer stalling detection.
.DESCRIPTION
    Identifies reviewers who are persistently non-responsive across multiple campaigns
    and/or multiple consecutive days. A reviewer who is late in ONE campaign for ONE
    day is normal escalation. A reviewer who has made ZERO progress across ALL their
    campaigns for 3+ consecutive days is a systemic issue (PTO, departure, reassignment
    needed).

    Consumes per-campaign trend JSONL (with reviewer summaries) to detect patterns
    without additional API calls.

    Functions:
        Get-SPStalledReviewers  - Detect reviewers stalled across campaigns/days
        Export-SPStalledReviewerHtml - Render a stalled-reviewer accountability report

    Read-only. Never mutates ISC.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

# Ensure SP.Shared is loaded.
$_spSharedPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'SP.Shared\SP.Shared.psd1'
if ((Test-Path $_spSharedPsd1) -and -not (Get-Command ConvertTo-SPHtmlSafe -ErrorAction Ignore)) {
    Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking
}

#region Internal helpers

function _RA_SafeVal {
    param([object]$Object, [string]$Name, $Default = $null)
    return (Get-SPObjectProperty -Object $Object -Name $Name -Default $Default)
}

function _RA_GetTrendDir {
    $dir = $null
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Metrics']) {
            if ($null -ne $cfg.Metrics.PSObject.Properties['CampaignTrendPath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Metrics.CampaignTrendPath)) {
                $dir = [string]$cfg.Metrics.CampaignTrendPath
            }
            elseif ($null -ne $cfg.Metrics.PSObject.Properties['Path'] -and
                    -not [string]::IsNullOrWhiteSpace($cfg.Metrics.Path)) {
                $dir = Join-Path ([string]$cfg.Metrics.Path) 'campaign-trend'
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.\Audit\metrics\campaign-trend' }
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $dir = [System.IO.Path]::GetFullPath((Join-Path $root $dir))
    }
    return $dir
}

#endregion

#region Public: Get-SPStalledReviewers

function Get-SPStalledReviewers {
    <#
    .SYNOPSIS
        Detects reviewers who are persistently non-responsive across campaigns and days.
    .DESCRIPTION
        Reads per-campaign trend JSONL files (which contain per-reviewer summaries added
        by Save-SPCampaignTrendPoint) and identifies reviewers whose completion percentage
        has NOT increased over ConsecutiveDays consecutive daily captures. A reviewer
        stalled in MULTIPLE campaigns simultaneously is flagged with higher severity.

        This catches the scenario where a manager is on PTO, has left the organization,
        or is ignoring their certification queue -- and the campaign has not been properly
        reassigned.
    .PARAMETER ConsecutiveDays
        Minimum number of consecutive days with zero progress to flag a reviewer.
        Default: 3.
    .PARAMETER DaysBack
        How far back to look in the trend data. Default: 14.
    .PARAMETER MinCompletionGap
        Minimum completion percentage gap to consider "stalled". If a reviewer's
        completion moved by less than this between the first and last capture, they
        are stalled. Default: 1.0 (percent).
    .PARAMETER TrendDir
        Override the campaign trend directory. Default: resolved from config.
    .PARAMETER CorrelationID
        Unique ID for tracing.
    .OUTPUTS
        [hashtable] @{
            Success = $true
            Data = @{
                StalledReviewers = @(...)  # sorted by severity (multi-campaign first)
                Summary = @{ Total; MultiCampaign; SingleCampaign; MaxConsecutiveDays }
            }
            Error = $null
        }
    .EXAMPLE
        $result = Get-SPStalledReviewers -ConsecutiveDays 3
        $result.Data.StalledReviewers | Format-Table Reviewer, CampaignCount, StalledDays, Severity
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [int]$ConsecutiveDays = 3,
        [Parameter()] [int]$DaysBack = 14,
        [Parameter()] [double]$MinCompletionGap = 1.0,
        [Parameter()] [string]$TrendDir,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) { $CorrelationID = [guid]::NewGuid().ToString() }

    try {
        if ([string]::IsNullOrWhiteSpace($TrendDir)) { $TrendDir = _RA_GetTrendDir }
        if (-not (Test-Path $TrendDir)) {
            return @{ Success = $true; Data = @{ StalledReviewers = @(); Summary = @{ Total = 0; MultiCampaign = 0; SingleCampaign = 0; MaxConsecutiveDays = 0 } }; Error = $null }
        }

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $cutoff = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
        $now = (Get-Date).ToUniversalTime()

        # Read all campaign trend files and extract per-reviewer data
        # Structure: reviewerName -> @{ CampaignName -> @{ DailyCaptures = @( @{Date; Completion} ) } }
        $reviewerHistory = @{}

        $searchDirs = @($TrendDir)
        try { Get-ChildItem -Path $TrendDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $searchDirs += $_.FullName } } catch { }

        foreach ($dir in $searchDirs) {
            foreach ($f in Get-ChildItem -Path $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) {
                try {
                    foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, $utf8)) {
                        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                        try {
                            $rec = $ln | ConvertFrom-Json
                            $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime()
                            if ($ts -lt $cutoff) { continue }

                            # Only look at ACTIVE campaigns
                            $status = _RA_SafeVal $rec 'status' ''
                            if ($status -notin @('ACTIVE', 'ACTIVATING')) { continue }

                            $campName = _RA_SafeVal $rec 'campaignName' 'Unknown'
                            $campId   = _RA_SafeVal $rec 'campaignId' ''
                            $reviewers = _RA_SafeVal $rec 'reviewers' @()

                            if ($null -eq $reviewers -or $reviewers.Count -eq 0) { continue }

                            $dateKey = $ts.ToString('yyyy-MM-dd')

                            foreach ($rv in $reviewers) {
                                $rvName = _RA_SafeVal $rv 'reviewer' ''
                                if ([string]::IsNullOrWhiteSpace($rvName)) { continue }

                                $completion = [double](_RA_SafeVal $rv 'completion' 0)

                                if (-not $reviewerHistory.ContainsKey($rvName)) {
                                    $reviewerHistory[$rvName] = @{}
                                }
                                if (-not $reviewerHistory[$rvName].ContainsKey($campId)) {
                                    $reviewerHistory[$rvName][$campId] = @{
                                        CampaignName = $campName
                                        Captures = [System.Collections.Generic.List[object]]::new()
                                    }
                                }

                                # Keep the latest capture per day per campaign
                                $existing = $reviewerHistory[$rvName][$campId].Captures | Where-Object { $_.Date -eq $dateKey }
                                if ($null -eq $existing) {
                                    $reviewerHistory[$rvName][$campId].Captures.Add(@{
                                        Date       = $dateKey
                                        Timestamp  = $ts
                                        Completion = $completion
                                    })
                                }
                                elseif ($ts -gt $existing.Timestamp) {
                                    $existing.Completion = $completion
                                    $existing.Timestamp  = $ts
                                }
                            }
                        } catch { }
                    }
                } catch { }
            }
        }

        # Analyze each reviewer for stalling patterns
        $stalledList = [System.Collections.Generic.List[object]]::new()

        foreach ($rvName in $reviewerHistory.Keys) {
            $campaigns = $reviewerHistory[$rvName]
            $stalledCampaigns = [System.Collections.Generic.List[object]]::new()

            foreach ($campId in $campaigns.Keys) {
                $campData = $campaigns[$campId]
                $captures = @($campData.Captures | Sort-Object { $_.Timestamp })

                if ($captures.Count -lt $ConsecutiveDays) { continue }

                # Check for consecutive days with zero progress
                # Look at the LAST N captures
                $recentCaptures = @($captures | Select-Object -Last ([math]::Max($ConsecutiveDays + 2, $captures.Count)))

                $maxStalled = 0
                $currentStalled = 0
                $stallStart = $null
                $lastCompletion = -1

                for ($i = 0; $i -lt $recentCaptures.Count; $i++) {
                    $cap = $recentCaptures[$i]
                    $delta = if ($lastCompletion -ge 0) { $cap.Completion - $lastCompletion } else { 999 }

                    if ($delta -lt $MinCompletionGap -and $lastCompletion -ge 0) {
                        $currentStalled++
                        if ($null -eq $stallStart) { $stallStart = $recentCaptures[[math]::Max(0, $i - 1)].Date }
                    }
                    else {
                        if ($currentStalled -gt $maxStalled) { $maxStalled = $currentStalled }
                        $currentStalled = 0
                        $stallStart = $null
                    }
                    $lastCompletion = $cap.Completion
                }
                if ($currentStalled -gt $maxStalled) { $maxStalled = $currentStalled }

                if ($maxStalled -ge $ConsecutiveDays) {
                    $latestCapture = $captures[$captures.Count - 1]
                    $stalledCampaigns.Add(@{
                        CampaignName   = $campData.CampaignName
                        CampaignId     = $campId
                        StalledDays    = $maxStalled
                        Completion     = $latestCapture.Completion
                        LastCapture    = $latestCapture.Date
                        StallStartDate = $stallStart
                    })
                }
            }

            if ($stalledCampaigns.Count -gt 0) {
                $maxDays = ($stalledCampaigns | ForEach-Object { $_.StalledDays } | Measure-Object -Maximum).Maximum
                $severity = if ($stalledCampaigns.Count -gt 1) { 'Red' } else { 'Amber' }

                $stalledList.Add(@{
                    Reviewer       = $rvName
                    CampaignCount  = $stalledCampaigns.Count
                    StalledDays    = $maxDays
                    Severity       = $severity
                    Campaigns      = @($stalledCampaigns)
                    Recommendation = if ($stalledCampaigns.Count -gt 1) {
                        "Reviewer stalled in $($stalledCampaigns.Count) campaigns for $maxDays+ days -- likely OOO/departed. Consider reassignment."
                    } else {
                        "Reviewer stalled in $($stalledCampaigns[0].CampaignName) for $maxDays+ days. Follow up or reassign."
                    }
                })
            }
        }

        # Sort: multi-campaign first, then by stalled days descending
        $sorted = @($stalledList | Sort-Object { $_.CampaignCount } -Descending | Sort-Object { $_.StalledDays } -Descending)

        $multiCamp = @($sorted | Where-Object { $_.CampaignCount -gt 1 }).Count
        $singleCamp = @($sorted | Where-Object { $_.CampaignCount -eq 1 }).Count
        $maxDays = if ($sorted.Count -gt 0) { ($sorted | ForEach-Object { $_.StalledDays } | Measure-Object -Maximum).Maximum } else { 0 }

        return @{
            Success = $true
            Data = @{
                StalledReviewers = $sorted
                Summary = @{
                    Total              = $sorted.Count
                    MultiCampaign      = $multiCamp
                    SingleCampaign     = $singleCamp
                    MaxConsecutiveDays = $maxDays
                }
            }
            Error = $null
        }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = "Get-SPStalledReviewers failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Public: Export-SPStalledReviewerHtml

function Export-SPStalledReviewerHtml {
    <#
    .SYNOPSIS
        Renders an HTML report of persistently stalled reviewers.
    .PARAMETER StalledData
        Output from Get-SPStalledReviewers (.Data).
    .PARAMETER OutputPath
        File path or directory for the HTML output.
    .PARAMETER CorrelationID
        Unique ID for tracing.
    .OUTPUTS
        [hashtable] @{ Success; Data=<filepath>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$StalledData,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter()] [string]$CorrelationID
    )

    try {
        if ($OutputPath -notmatch '\.html?$') {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
            $OutputPath = Join-Path $OutputPath "stalled-reviewers-$((Get-Date).ToString('yyyyMMdd-HHmmss')).html"
        }

        $sb = New-SPHtmlDocument -Title 'Stalled Reviewer Accountability Report'
        $colors = Get-SPHtmlColorPalette
        $genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')

        [void]$sb.AppendLine("<h1>Stalled Reviewer Accountability Report</h1>")
        [void]$sb.AppendLine("<p class='meta'>Generated: $genDate</p>")

        $summary = $StalledData.Summary
        $reviewers = @($StalledData.StalledReviewers)

        if ($reviewers.Count -eq 0) {
            [void]$sb.AppendLine("<div style='border:1px solid $($colors.Green);background:#e8f5e9;border-radius:6px;padding:12px 16px;margin:16px 0;color:#1b5e20;'>")
            [void]$sb.AppendLine("<strong>All reviewers are making progress.</strong> No persistent stalling detected.</div>")
        }
        else {
            # Summary KPIs
            [void]$sb.AppendLine("<div style='margin:16px 0;'>")
            $kpiStyle = "display:inline-block;min-width:140px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid $($colors.Border);border-radius:6px;background:$($colors.LightGrayBg);text-align:center;"
            $numStyle = "font-size:22px;font-weight:700;color:$($colors.Dark);display:block;"
            $lblStyle = "font-size:11px;color:$($colors.Gray);text-transform:uppercase;letter-spacing:.04em;"

            [void]$sb.AppendLine("<span style='$kpiStyle'><span style='$numStyle'>$($summary.Total)</span><span style='$lblStyle'>Stalled Reviewers</span></span>")
            [void]$sb.AppendLine("<span style='$kpiStyle'><span style='${numStyle}color:$($colors.Red);'>$($summary.MultiCampaign)</span><span style='$lblStyle'>Multi-Campaign</span></span>")
            [void]$sb.AppendLine("<span style='$kpiStyle'><span style='${numStyle}color:$($colors.Amber);'>$($summary.SingleCampaign)</span><span style='$lblStyle'>Single-Campaign</span></span>")
            [void]$sb.AppendLine("<span style='$kpiStyle'><span style='$numStyle'>$($summary.MaxConsecutiveDays)</span><span style='$lblStyle'>Max Stalled Days</span></span>")
            [void]$sb.AppendLine("</div>")

            # Multi-campaign stalls (RED)
            $redReviewers = @($reviewers | Where-Object { $_.Severity -eq 'Red' })
            if ($redReviewers.Count -gt 0) {
                [void]$sb.AppendLine("<h2 style='color:$($colors.Red);'>Multi-Campaign Stalls (Likely OOO/Departed)</h2>")
                [void]$sb.AppendLine("<p class='note'>These reviewers have made zero progress in multiple campaigns simultaneously. This typically indicates absence (PTO, leave, departure) or a reassignment failure.</p>")

                foreach ($rv in $redReviewers) {
                    $rvName = ConvertTo-SPHtmlSafe $rv.Reviewer
                    [void]$sb.AppendLine("<div style='border:1px solid $($colors.Red);background:$($colors.LightRedBg);border-radius:6px;padding:12px 16px;margin:12px 0;'>")
                    [void]$sb.AppendLine("<h3 style='margin:0 0 8px 0;color:$($colors.DarkRedText);'>$rvName -- stalled $($rv.StalledDays)+ days across $($rv.CampaignCount) campaigns</h3>")
                    [void]$sb.AppendLine("<p style='font-size:12px;color:$($colors.DarkRedText);margin:4px 0;'><strong>Recommendation:</strong> $(ConvertTo-SPHtmlSafe $rv.Recommendation)</p>")
                    [void]$sb.AppendLine("<table><thead><tr><th>Campaign</th><th>Stalled Since</th><th>Days Stalled</th><th>Completion %</th><th>Last Capture</th></tr></thead><tbody>")
                    foreach ($c in $rv.Campaigns) {
                        $cn = ConvertTo-SPHtmlSafe $c.CampaignName
                        [void]$sb.AppendLine("<tr><td>$cn</td><td>$($c.StallStartDate)</td><td style='color:$($colors.Red);font-weight:600;'>$($c.StalledDays)</td><td>$($c.Completion)%</td><td>$($c.LastCapture)</td></tr>")
                    }
                    [void]$sb.AppendLine("</tbody></table></div>")
                }
            }

            # Single-campaign stalls (AMBER)
            $amberReviewers = @($reviewers | Where-Object { $_.Severity -eq 'Amber' })
            if ($amberReviewers.Count -gt 0) {
                [void]$sb.AppendLine("<h2 style='color:$($colors.Amber);'>Single-Campaign Stalls</h2>")
                [void]$sb.AppendLine("<p class='note'>These reviewers are stalled in one campaign. May be a lower priority or workload issue.</p>")
                [void]$sb.AppendLine("<table><thead><tr><th>Reviewer</th><th>Campaign</th><th>Days Stalled</th><th>Completion %</th><th>Stalled Since</th><th>Recommendation</th></tr></thead><tbody>")
                $idx = 0
                foreach ($rv in $amberReviewers) {
                    $bg = if ($idx % 2 -eq 1) { " style='background:$($colors.LightGrayBg);'" } else { '' }
                    $rvName = ConvertTo-SPHtmlSafe $rv.Reviewer
                    $c = $rv.Campaigns[0]
                    $cn = ConvertTo-SPHtmlSafe $c.CampaignName
                    $rec = ConvertTo-SPHtmlSafe $rv.Recommendation
                    [void]$sb.AppendLine("<tr$bg><td>$rvName</td><td>$cn</td><td style='color:$($colors.Amber);font-weight:600;'>$($c.StalledDays)</td><td>$($c.Completion)%</td><td>$($c.StallStartDate)</td><td style='font-size:11px;'>$rec</td></tr>")
                    $idx++
                }
                [void]$sb.AppendLine("</tbody></table>")
            }
        }

        [void]$sb.AppendLine("<p class='note' style='margin-top:24px;'>Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
        [void]$sb.AppendLine('</body></html>')

        Write-SPHtmlFile -Path $OutputPath -Content $sb.ToString()
        return @{ Success = $true; Data = $OutputPath; Error = $null }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = "Export-SPStalledReviewerHtml failed: $($_.Exception.Message)" }
    }
}

#endregion
