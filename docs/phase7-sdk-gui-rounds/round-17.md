# Round 17
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-17 -- OutputMode/Both consistency for CampaignSearch

**Read:**
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract, headless toolbox, round template)
- `docs/phase7-sdk-gui-backlog.md` (SDK-17 Problem/Fix/Files/Accept + table row)
- `Scripts/Invoke-SPCampaignSearch.ps1` (param block line 143, console gate line 578,
  JSON gate line 738, CSV gate line 751, comment-based help lines 19-20 / 56-57)
- `Tests/SP.CliScripts.Tests.ps1` (CLI-004 case "All scripts with OutputMode use
  ValidateSet Console/JSON/Both", lines 270-294)

**Did:** Made `Invoke-SPCampaignSearch.ps1` consistent with the universal CLI OutputMode
convention. (1) Added `Both` to the `OutputMode` ValidateSet
(`'Console','JSON','CSV','HTML','Both'`), keeping the existing richer CSV/HTML taxonomy.
(2) Retargeted the console output gate from `if ($OutputMode -eq 'Console' -or $OutputMode -eq 'JSON')`
to `if ($OutputMode -in @('Console', 'Both'))`, which both makes JSON mode pure JSON
(previously it wastefully rendered the full tabular console view too) and defines
`Both` = console + JSON. (3) Changed the JSON output gate from `if ($OutputMode -eq 'JSON')`
to `if ($OutputMode -in @('JSON', 'Both'))` so `Both` emits the JSON block after the
console view. Also updated comment-based help (.DESCRIPTION "Output modes:" and the
`-OutputMode` .PARAMETER) to mention `Both` (Console+JSON). CSV/HTML branches
(`-eq 'CSV'` / `-eq 'HTML'`) and the WhatIf preview (prints `$OutputMode` verbatim)
were unaffected and unchanged.

**Scope decision:** CHOSEN -- add `Both` + implement the Console/JSON gate split,
rather than relaxing CLI-004. Rationale: preserves the cross-script Console/JSON/Both
invariant enforced over all 20+ OutputMode scripts (consistency is the entire point
of the item), keeps CampaignSearch's CSV/HTML taxonomy, and fixes the latent
JSON-also-dumps-console bug. The alternative (relax CLI-004 to require only
Console+JSON universally) weakens a passing cross-script invariant for one script and
is the worse choice for convention/safety -- flagged for human ratification per
protocol, but the implementation path was unambiguous so no blocking escalation.

**WPF/GUI applicability:** SDK-17 touches no `Gui/*.xaml` or `Modules/SP.Gui` code --
it is the one backlog item outside the GUI surface. Per the work spec, the plan's
"WPF Framework Notes 1-6" and "GUI Testing Methods" (module-scope handler closures,
background STA runspace, Show-SPGuiDialog modals, tooltip rules, XamlReader parse)
do NOT apply. Verification used the protocol's CLI-only headless toolbox:
`[Parser]::ParseFile` AST check + `Invoke-Pester` on the affected test file.

**Files:**
- `Scripts/Invoke-SPCampaignSearch.ps1` (MODIFIED: ValidateSet, console gate, JSON gate, help)
- `docs/phase7-sdk-gui-rounds/round-17.md` (CREATED: this file)
- `docs/phase7-sdk-gui-backlog.md` (MODIFIED: SDK-17 -> DONE, decision recorded)

**Verification:**
  - Pester (`Tests/SP.CliScripts.Tests.ps1`, New-PesterConfiguration): P=71 F=0 Total=71 --
    the CLI-004 case "All scripts with OutputMode use ValidateSet Console/JSON/Both" now PASSES;
    no other case (CLI-001 AST, CLI-003 SupportsShouldProcess) regressed.
  - AST parse: `[Parser]::ParseFile` on `Invoke-SPCampaignSearch.ps1` => ParseErrors=0.
  - AST ValidateSet assertion: OutputMode ValidateSet = `Console,JSON,CSV,HTML,Both`
    (contains Console + JSON + Both, still CSV + HTML).
  - XAML parse: n/a (no XAML touched).
  - Manifest/import: n/a (no module/manifest touched).

**Review:** PASS (pending independent code-review gate).

**Backlog update:** SDK-17 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS
