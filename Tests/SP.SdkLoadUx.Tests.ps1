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

    # ---- Round-05 fix assertions -------------------------------------------

    It 'Set-SdkSubTabButtonsEnabled snapshots prior IsEnabled instead of forcing $true' {
        $body = & $script:GetFnText 'Set-SdkSubTabButtonsEnabled'
        $body | Should -Not -BeNullOrEmpty

        # Snapshots the prior state on disable and restores it on re-enable
        # (so design-disabled controls like BtnSdkRefreshSummaries stay disabled).
        $body | Should -Match 'SdkButtonEnabledSnapshot'
        $body | Should -Match 'RuntimeHelpers\]::GetHashCode'
        $body | Should -Match '\$prior'
        # No unconditional `$btn.IsEnabled = $Enabled` blanket assignment anymore.
        $body | Should -Not -Match '\$btn\.IsEnabled = \$Enabled'
    }

    It 'Set-SdkSubTabButtonsEnabled nested disable does not overwrite the original snapshot' {
        $body = & $script:GetFnText 'Set-SdkSubTabButtonsEnabled'
        # Re-entrancy guard: only writes a snapshot when none already exists for the key.
        $body | Should -Match 'ReferenceEquals\(\$existing\.Control'
    }

    It 'Invoke-SdkActionRun finally skips re-enable when a chained refresh took ownership' {
        $body = & $script:GetFnText 'Invoke-SdkActionRun'
        $body | Should -Not -BeNullOrEmpty

        $body | Should -Match '\$chainedRefreshOwnsState'
        # The finally block guards the re-enable / guard-clear with the ownership flag.
        $body | Should -Match 'if \(-not \$chainedRefreshOwnsState\)'
        # Ownership is inferred from the guard being re-taken by the chained refresh.
        $body | Should -Match 'if \(\$script:IsSdkRunning\) \{ \$chainedRefreshOwnsState = \$true \}'
    }

    It 'Set-SdkSubTabButtonsEnabled actually keeps a design-disabled button disabled after a load cycle' -Skip:(-not $IsWindows) {
        # Functional (non-AST) proof: import the module, build a tiny in-memory WPF
        # tree with one enabled button + one design-disabled button, run a full
        # disable->re-enable cycle, and assert the design-disabled one stays off.
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

        $psd1 = Join-Path $PSScriptRoot '..\Modules\SP.Gui\SP.Gui.psd1'
        Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop

        InModuleScope SP.MainWindow {
            # Build a tree with a real NameScope so Find-Control's FindName resolves
            # (mirrors how the loaded XAML registers x:Name controls).
            $panel = [System.Windows.Controls.StackPanel]::new()
            [System.Windows.NameScope]::SetNameScope($panel, [System.Windows.NameScope]::new())

            $enabledBtn = [System.Windows.Controls.Button]::new()
            $enabledBtn.IsEnabled = $true
            $panel.Children.Add($enabledBtn) | Out-Null
            $panel.RegisterName('BtnSdkRefreshTemplates', $enabledBtn)

            $designDisabled = [System.Windows.Controls.Button]::new()
            $designDisabled.IsEnabled = $false               # IsEnabled="False" by design (SDK-18)
            $panel.Children.Add($designDisabled) | Out-Null
            $panel.RegisterName('BtnSdkRefreshSummaries', $designDisabled)

            # Fresh snapshot map for an isolated cycle.
            $script:SdkButtonEnabledSnapshot = $null

            Set-SdkSubTabButtonsEnabled -TabContent $panel -Enabled $false
            $enabledBtn.IsEnabled     | Should -BeFalse
            $designDisabled.IsEnabled | Should -BeFalse

            Set-SdkSubTabButtonsEnabled -TabContent $panel -Enabled $true
            # The enabled button comes back on; the design-disabled one stays OFF.
            $enabledBtn.IsEnabled     | Should -BeTrue
            $designDisabled.IsEnabled | Should -BeFalse
        }
    }

    It 'Set-SdkSubTabButtonsEnabled nested disable/enable preserves original enabled state' -Skip:(-not $IsWindows) {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        $psd1 = Join-Path $PSScriptRoot '..\Modules\SP.Gui\SP.Gui.psd1'
        Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop

        InModuleScope SP.MainWindow {
            $panel = [System.Windows.Controls.StackPanel]::new()
            [System.Windows.NameScope]::SetNameScope($panel, [System.Windows.NameScope]::new())
            $btn = [System.Windows.Controls.Button]::new()
            $btn.IsEnabled = $true
            $panel.Children.Add($btn) | Out-Null
            $panel.RegisterName('BtnSdkRefreshTemplates', $btn)

            $script:SdkButtonEnabledSnapshot = $null

            # Outer disable (action), then a NESTED disable (chained refresh) before re-enable.
            Set-SdkSubTabButtonsEnabled -TabContent $panel -Enabled $false
            Set-SdkSubTabButtonsEnabled -TabContent $panel -Enabled $false
            $btn.IsEnabled | Should -BeFalse

            # Single re-enable (chained refresh owns release) restores the ORIGINAL $true.
            Set-SdkSubTabButtonsEnabled -TabContent $panel -Enabled $true
            $btn.IsEnabled | Should -BeTrue
        }
    }
}
