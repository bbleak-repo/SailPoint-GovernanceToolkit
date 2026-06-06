#Requires -Modules Pester

<#
.SYNOPSIS
    T-01 -- SDK load-wait UX: verifies the single-load guard ($script:IsSdkRunning)
    DISABLES the per-sub-tab SDK Refresh/action buttons during a load and
    RE-ENABLES them on completion, so a click is never a silent no-op.

    Pure-AST / text assertions only -- NO Show-SPDashboard, NO FlaUI, NO W-08b.
    Mirrors the ParseFile idiom from SP.ProductionReadiness.Tests.ps1.
#>

Describe 'T-01: SDK load-wait UX -- Set-SdkSubTabButtonsEnabled disable/re-enable' {

    BeforeAll {
        $script:ModulePath = Join-Path $PSScriptRoot '..\Modules\SP.Gui\SP.MainWindow.psm1'

        $script:tokens      = $null
        $script:parseErrors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ModulePath, [ref]$script:tokens, [ref]$script:parseErrors
        )

        $script:rawText = Get-Content -Path $script:ModulePath -Raw

        # Helper: resolve a named FunctionDefinitionAst's body text.
        $script:GetFnText = {
            param($Name)
            $fn = $script:ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
            }, $true)
            if ($fn) { return $fn[0].Body.Extent.Text }
            return $null
        }
    }

    It 'Module exists' {
        $script:ModulePath | Should -Exist
    }

    It 'parses with zero errors' {
        $script:parseErrors | Should -BeNullOrEmpty
    }

    It 'imports clean' {
        $psd1 = Join-Path $PSScriptRoot '..\Modules\SP.Gui\SP.Gui.psd1'
        { Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop } | Should -Not -Throw
    }

    It 'defines Set-SdkSubTabButtonsEnabled toggling IsEnabled on SDK buttons' {
        $fn = $script:ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-SdkSubTabButtonsEnabled'
        }, $true)

        $fn | Should -HaveCount 1

        $body = $fn[0].Body.Extent.Text
        $body | Should -Match 'IsEnabled'
        $body | Should -Match 'BtnSdkRefreshTemplates'
        $body | Should -Match 'BtnSdkRefreshApprovals'
    }

    It 'Invoke-SdkGridRefresh disables buttons after setting IsSdkRunning=$true' {
        $body = & $script:GetFnText 'Invoke-SdkGridRefresh'
        $body | Should -Not -BeNullOrEmpty

        $body | Should -Match '\$script:IsSdkRunning = \$true'
        $body | Should -Match 'Set-SdkSubTabButtonsEnabled'
        $body | Should -Match '-Enabled \$false'

        $idxGuard   = $body.IndexOf('$script:IsSdkRunning = $true')
        $idxDisable = $body.IndexOf('Set-SdkSubTabButtonsEnabled -TabContent $TabContent -Enabled $false')
        $idxGuard   | Should -BeGreaterThan -1
        $idxDisable | Should -BeGreaterThan $idxGuard
    }

    It 'Invoke-SdkActionRun disables buttons after setting IsSdkRunning=$true' {
        $body = & $script:GetFnText 'Invoke-SdkActionRun'
        $body | Should -Not -BeNullOrEmpty

        $body | Should -Match '\$script:IsSdkRunning = \$true'
        $body | Should -Match 'Set-SdkSubTabButtonsEnabled'
        $body | Should -Match '-Enabled \$false'

        $idxGuard   = $body.IndexOf('$script:IsSdkRunning = $true')
        $idxDisable = $body.IndexOf('Set-SdkSubTabButtonsEnabled -TabContent $TabContent -Enabled $false')
        $idxGuard   | Should -BeGreaterThan -1
        $idxDisable | Should -BeGreaterThan $idxGuard
    }

    It 'Invoke-SdkGridRefresh re-enables buttons in completion Tick' {
        $body = & $script:GetFnText 'Invoke-SdkGridRefresh'
        $body | Should -Match 'Set-SdkSubTabButtonsEnabled -TabContent \$tab -Enabled \$true'
    }

    It 'Invoke-SdkActionRun re-enables buttons in completion Tick' {
        $body = & $script:GetFnText 'Invoke-SdkActionRun'
        $body | Should -Match 'Set-SdkSubTabButtonsEnabled -TabContent \$tab -Enabled \$true'
    }

    It 'keeps the existing "already in progress" single-load message intact' {
        $script:rawText | Should -Match 'An SDK data load is already in progress'
        $script:rawText | Should -Match 'An SDK operation is already in progress'
    }
}
