# Shared module importer for the toolkit's Pester test suite.
#
# WHY THIS EXISTS
# ---------------
# The toolkit ships each module family as a .psd1 manifest with a
# NestedModules list of .psm1 files (e.g. SP.Core.psd1 nests SP.Config.psm1,
# SP.Logging.psm1, SP.Vault.psm1, SP.Auth.psm1). When production code imports
# the .psd1, the nested .psm1 files become *nested* module scopes.
#
# On Pester 5.x running under Windows PowerShell 5.1 Desktop, Mock calls that
# target a nested module by name (e.g. `Mock Invoke-RestMethod -ModuleName
# SP.Auth { ... }`) do NOT reliably reach the nested scope. The mock is
# registered but the real function is what actually runs at the call site,
# causing 56 of 207 tests to fail with symptoms like DNS lookups of
# 'change_me.api.identitynow.com' leaking out of what should be a fully
# mocked test.
#
# Fix: import the .psm1 files *directly* (bypassing the .psd1 aggregator).
# Each becomes a top-level module whose scope Pester's -ModuleName argument
# can target correctly.
#
# See bugs.md Bug 1 for the full history.

function Import-SPTestModules {
    <#
    .SYNOPSIS
        Imports toolkit modules as flat top-level modules for testing.
    .DESCRIPTION
        Switch-flagged loader. Each flag imports the corresponding
        family's nested .psm1 files in dependency order. Pester mocks
        with -ModuleName <psm1-base-name> will reach the call sites
        correctly because the modules are top-level, not nested.
    .PARAMETER Shared
        Imports SP.HtmlHelpers (HTML encoding, date formatting, property
        access, file writing), SP.CacheService (generic TTL cache), and
        SP.IdentityService (identity resolution and caching). HtmlHelpers
        and CacheService have no dependencies; IdentityService depends on
        SP.Core + SP.Api at runtime but is safe to import standalone.
    .PARAMETER Core
        Imports SP.Config, SP.Logging, SP.Vault, SP.Auth.
    .PARAMETER Api
        Imports SP.ApiClient, SP.Campaigns, SP.Certifications, SP.Decisions.
    .PARAMETER Audit
        Imports SP.AuditQueries, SP.AuditReportCore, SP.AuditAnalytics,
        SP.AuditReportHtml, SP.AuditOperations.
    .PARAMETER Testing
        Imports SP.TestLoader, SP.Assertions, SP.Evidence, SP.BatchRunner.
    .PARAMETER DeltaCert
        Imports SP.DeltaCertQueries, SP.DeltaCertRunner.
    .PARAMETER DisconnectedApps
        Imports SP.DisconnectedAppValidator, SP.DisconnectedAppSnapshot,
        SP.DisconnectedAppDelta, SP.DisconnectedAppRunner,
        SP.DisconnectedAppAnalytics, SP.DisconnectedAppReports.
    .PARAMETER Sdk
        Imports SP.SdkCommon, SP.SdkPatch, SP.SdkCampaignTemplates,
        SP.SdkCertSummaries, SP.SdkApprovals, SP.SdkWorkItems, SP.SdkWorkflows,
        SP.SdkCampaignFilters.
    .PARAMETER Reconciliation
        Imports SP.IscReconciliation (the ISC-side reconciliation operand builder/exporter).
        The pure builder has no toolkit dependency; combine with -Core when exercising the
        config-resolved export directory path.
    .PARAMETER SdkBridge
        Imports SP.SdkBridge flat (the .psm1 directly, NOT via SP.Gui.psd1) so
        Pester's `Mock -ModuleName SP.SdkBridge` reaches the call sites under
        Windows PowerShell 5.1 / Pester 5.x (Bug-1 flat-import rule). Intended to
        be combined with -Core -Api -Sdk: the bridge calls Get-SPConfig (SP.Core)
        and Get/Invoke/New/Set/Remove/Update/Test-SPSdk* (SP.Sdk family), which
        must exist in-session for `Mock -ModuleName SP.SdkBridge` to resolve the
        command name.
    #>
    [CmdletBinding()]
    param(
        [switch]$Shared,
        [switch]$Core,
        [switch]$Api,
        [switch]$Audit,
        [switch]$Testing,
        [switch]$DeltaCert,
        [switch]$DisconnectedApps,
        [switch]$Sdk,
        [switch]$SdkBridge,
        [switch]$Reconciliation
    )

    $modulesRoot = Join-Path $PSScriptRoot '..\Modules'

    if ($Shared) {
        Import-Module (Join-Path $modulesRoot 'SP.Shared\SP.HtmlHelpers.psm1')     -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Shared\SP.CacheService.psm1')    -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Shared\SP.IdentityService.psm1') -Force -DisableNameChecking
    }
    if ($Core) {
        Import-Module (Join-Path $modulesRoot 'SP.Core\SP.Config.psm1')  -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Core\SP.Logging.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Core\SP.Vault.psm1')   -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Core\SP.Auth.psm1')    -Force -DisableNameChecking
    }
    if ($Api) {
        Import-Module (Join-Path $modulesRoot 'SP.Api\SP.ApiClient.psm1')      -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Api\SP.Campaigns.psm1')      -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Api\SP.Certifications.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Api\SP.Decisions.psm1')      -Force -DisableNameChecking
    }
    if ($Audit) {
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.AuditQueries.psm1')    -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.AuditReportCore.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.AuditAnalytics.psm1')  -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.AuditReportHtml.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.AuditOperations.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.CampaignDelta.psm1')   -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.CampaignDiff.psm1')    -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.CampaignTrend.psm1')          -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.GovernanceTrendQuery.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.CampaignVelocity.psm1')    -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.CertTracker.psm1')      -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.ReviewerAccountability.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.CampaignSeries.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.EntitlementState.psm1')     -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.ReviewerState.psm1')        -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.StateOrchestrator.psm1')    -Force -DisableNameChecking
    }
    if ($Testing) {
        Import-Module (Join-Path $modulesRoot 'SP.Testing\SP.TestLoader.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Testing\SP.Assertions.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Testing\SP.Evidence.psm1')   -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Testing\SP.BatchRunner.psm1')-Force -DisableNameChecking
    }
    if ($DeltaCert) {
        Import-Module (Join-Path $modulesRoot 'SP.DeltaCert\SP.DeltaCertQueries.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DeltaCert\SP.DeltaCertRunner.psm1')  -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DeltaCert\SP.DeltaCertReport.psm1')  -Force -DisableNameChecking
    }
    if ($DisconnectedApps) {
        Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedAppValidator.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedAppSnapshot.psm1')  -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedAppDelta.psm1')     -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedAppRunner.psm1')    -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedAppAnalytics.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedAppReports.psm1')   -Force -DisableNameChecking
    }
    if ($Sdk) {
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkCommon.psm1')             -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkPatch.psm1')              -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkCampaignTemplates.psm1')  -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkCertSummaries.psm1')      -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkApprovals.psm1')          -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkWorkItems.psm1')          -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkWorkflows.psm1')          -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Sdk\SP.SdkCampaignFilters.psm1')   -Force -DisableNameChecking
    }
    if ($SdkBridge) {
        Import-Module (Join-Path $modulesRoot 'SP.Gui\SP.SdkBridge.psm1') -Force -DisableNameChecking
    }
    if ($Reconciliation) {
        Import-Module (Join-Path $modulesRoot 'SP.Reconciliation\SP.IscReconciliation.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $modulesRoot 'SP.Reconciliation\SP.IscReconciliationSource.psm1') -Force -DisableNameChecking
    }
}
