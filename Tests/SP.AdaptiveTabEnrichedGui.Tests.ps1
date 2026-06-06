#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    T-05 -- Adaptive Reports tab "Enriched Reports" surface (GUI, headless).

    Asserts the new ChkArEnriched* checkboxes and their handler wiring exist:
      * XAML-STA   -- (skipped off-STA) XamlReader-loads MainWindow.xaml, resolves
                      each of the four ChkArEnriched controls under the Adaptive
                      Reports TabItem content and asserts each has a non-empty ToolTip.
      * Source wiring (always) -- reads SP.MainWindow.psm1 raw and asserts the four
                      ChkArEnriched names, the enrichedMap/enriched gather, the
                      SetVariable for Enriched, and that the empty-selection guard
                      now references enriched; regression-asserts the legacy
                      ChkArBasePrivileged, BtnArGenerate, Initialize-SPAdaptiveTab.
      * XAML source (always)   -- reads MainWindow.xaml raw and asserts the four new
                      names + the "Enriched Reports" header exist and the legacy
                      "Baseline Reports" header + AdaptiveReportsTabContent still exist.

    Pure XAML-parse + text assertions. NO Show-SPDashboard, NO FlaUI, NO live mock.
#>

Describe 'T-05: Adaptive Reports Enriched Reports surface' {

    BeforeAll {
        $script:XamlPath   = Join-Path $PSScriptRoot '..\Gui\MainWindow.xaml'
        $script:ModulePath = Join-Path $PSScriptRoot '..\Modules\SP.Gui\SP.MainWindow.psm1'

        $script:XamlRaw = Get-Content -Path $script:XamlPath   -Raw
        $script:PsmRaw  = Get-Content -Path $script:ModulePath -Raw

        $script:EnrichedNames = @(
            'ChkArEnrichedPrivilegedAttestation',
            'ChkArEnrichedAccountability',
            'ChkArEnrichedTrend',
            'ChkArEnrichedDisconnected'
        )

        $script:IsSta = [System.Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'
    }

    Context 'XAML-STA (loaded WPF tree)' -Skip:(([System.Threading.Thread]::CurrentThread.ApartmentState) -ne 'STA') {

        BeforeAll {
            Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml -ErrorAction SilentlyContinue

            $reader = [System.Xml.XmlReader]::Create($script:XamlPath)
            try { $script:Window = [System.Windows.Markup.XamlReader]::Load($reader) }
            finally { $reader.Close() }

            $script:GetNamed = {
                param($Root, [string]$Name)
                if ($Root -is [System.Windows.FrameworkElement]) {
                    $hit = $Root.FindName($Name)
                    if ($null -ne $hit) { return $hit }
                }
                $stack = New-Object System.Collections.Stack
                $stack.Push($Root)
                while ($stack.Count -gt 0) {
                    $cur = $stack.Pop()
                    try {
                        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($cur)) {
                            if ($c -is [System.Windows.FrameworkElement] -and $c.Name -eq $Name) { return $c }
                            if ($c -is [System.Windows.DependencyObject]) { $stack.Push($c) }
                        }
                    } catch { }
                }
                return $null
            }

            $tabControl = & $script:GetNamed $script:Window 'MainTabControl'
            $script:AdaptiveContent = $null
            if ($tabControl) {
                for ($i = 0; $i -lt $tabControl.Items.Count; $i++) {
                    if ($tabControl.Items[$i].Header -eq 'Adaptive Reports') {
                        $script:AdaptiveContent = $tabControl.Items[$i].Content
                    }
                }
            }
        }

        It 'loads MainWindow.xaml and finds the Adaptive Reports tab content' {
            $script:AdaptiveContent | Should -Not -BeNullOrEmpty
        }

        It 'resolves each ChkArEnriched control with a non-empty ToolTip' {
            foreach ($n in $script:EnrichedNames) {
                $ctl = & $script:GetNamed $script:AdaptiveContent $n
                $ctl | Should -Not -BeNullOrEmpty -Because "$n must resolve in the loaded XAML"
                $tt = $ctl.ToolTip
                $ttText = if ($tt -is [string]) { $tt } elseif ($null -ne $tt) { [string]$tt } else { $null }
                [string]::IsNullOrWhiteSpace($ttText) | Should -BeFalse -Because "$n must carry a non-empty ToolTip"
            }
        }
    }

    Context 'Source wiring (SP.MainWindow.psm1)' {

        It 'references all four ChkArEnriched control names' {
            foreach ($n in $script:EnrichedNames) {
                $script:PsmRaw | Should -Match ([regex]::Escape($n))
            }
        }

        It 'defines an enrichedMap and gathers into an enriched list' {
            $script:PsmRaw | Should -Match 'enrichedMap'
            $script:PsmRaw | Should -Match '\$enriched'
        }

        It 'sets the Enriched runspace variable' {
            $script:PsmRaw | Should -Match "SetVariable\('Enriched'"
        }

        It 'widens the empty-selection guard to reference enriched' {
            $script:PsmRaw | Should -Match '\$enriched\.Count -eq 0'
        }

        It 'still defines the legacy ChkArBasePrivileged / BtnArGenerate / Initialize-SPAdaptiveTab (regression)' {
            $script:PsmRaw | Should -Match 'ChkArBasePrivileged'
            $script:PsmRaw | Should -Match 'BtnArGenerate'
            $script:PsmRaw | Should -Match 'Initialize-SPAdaptiveTab'
        }
    }

    Context 'XAML source (MainWindow.xaml)' {

        It 'contains the four new ChkArEnriched names' {
            foreach ($n in $script:EnrichedNames) {
                $script:XamlRaw | Should -Match ([regex]::Escape($n))
            }
        }

        It 'contains the Enriched Reports section header' {
            $script:XamlRaw | Should -Match 'Enriched Reports'
        }

        It 'still contains the legacy Baseline Reports header + AdaptiveReportsTabContent (regression)' {
            $script:XamlRaw | Should -Match 'Baseline Reports'
            $script:XamlRaw | Should -Match 'AdaptiveReportsTabContent'
        }
    }
}
