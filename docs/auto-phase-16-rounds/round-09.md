# Round 09 -- P16-09: Invoke-SPGovernanceMetrics.ps1

## Item
P16-09 Invoke-SPGovernanceMetrics.ps1

## Files Created
- Scripts/Invoke-SPGovernanceMetrics.ps1

## What Was Done
Created CLI script that orchestrates governance metrics capture, trend analysis,
and campaign completion forecasting:

1. **Current Analytics (Step 1)**: Fetches campaigns via Get-SPAuditCampaigns,
   builds full campaign audit data (certifications + items + decisions), then
   computes all 7 analytics: Measure-SPIdentityRisk, Measure-SPSourceGovernance,
   Measure-SPCampaignMetrics, Measure-SPReviewerReputation, Get-SPStaleAccess,
   Measure-SPGovernanceMaturity, Get-SPOrchestratorHistory. Saves to JSONL
   time-series store via Save-SPGovernanceMetrics.

2. **Campaign Completion Forecast (Step 2)**: When -IncludeCompletionForecast,
   calls Get-SPCampaignCompletionForecast with campaign health data for
   deadline info. Reports on-track/at-risk/will-miss status per campaign.

3. **Trend Analysis (Step 3)**: Calls Get-SPGovernanceMetricsTrend with
   configurable DaysBack and Granularity. Computes improving/declining/stable
   direction per metric.

4. **Decline Detection (Step 4)**: When -AlertOnDecline, checks for metrics
   declining >5% over last 4 periods and sends notification via
   Send-SPNotification.

5. **Output (Step 5)**: Console output with directional indicators vs previous
   period, JSON structured output, and JSONL audit trail event.

Supports -CaptureOnly (save without trend), -TrendOnly (trend without API
calls), -WhatIf (dry run), and all standard auth/config patterns from the
existing CLI scripts.

## Patterns Followed
- Module loading chain from Invoke-SPDataQualityReport.ps1
- Campaign audit data building pattern from Invoke-SPWeeklyDigest.ps1
- Config/auth/output path resolution from Invoke-SPDataQualityReport.ps1
- Step tracking with Set-StepResult pattern
- JSONL audit trail with BOM-free UTF-8
- Exit code convention: 0=success, 1=declining, 2=param, 3=auth, 4=config, 5=critical

## Verification
- PowerShell AST parser: 0 syntax errors
