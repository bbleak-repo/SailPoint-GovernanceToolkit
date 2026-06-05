# Round 9
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-09 -- 3 modal dialog XAMLs (Schedule/Workflow/Approval)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-09 row + section)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract, round template, headless toolbox)
- `Gui/DeltaCertRunDialog.xaml` and `Gui/AuditQueryDialog.xaml` (theme + header + button conventions, date-as-TextBox precedent)
- `Modules/SP.Gui/SP.MainWindow.psm1:149-264` (`Show-SPGuiDialog` -- confirmed it only reads/pre-populates TextBox, ComboBox, CheckBox; XamlReader::Load via XmlNodeReader path)
- `Modules/SP.Sdk/SP.SdkCampaignTemplates.psm1:336,348` (schedule type values WEEKLY/MONTHLY/ANNUALLY/CALENDAR; default MONTHLY)

**Did:** Created exactly 3 new code-behind-free modal dialog XAMLs under `Gui/`, each a
`<Window>` (no `x:Class`) copying the dark `#1E1E2E` theme, `Window.Resources` styles
(FieldLabel/FieldBox/PrimaryButton/SecondaryButton), and header attributes
(CenterOwner, NoResize, SizeToContent, MinWidth=450) verbatim from `DeltaCertRunDialog.xaml`.
Each has a `BtnOK` (PrimaryButton, IsDefault=True) and `BtnCancel` (SecondaryButton, IsCancel=True),
all Btn* with non-empty ToolTips. Control x:Names are the canonical contract SDK-12 will
pass to `-ControlNames`, chosen to be read-compatible with `Show-SPGuiDialog`. No `.psm1`
edits, no tests wired, no handler code (SDK-10/12 scope).

Per-dialog inventory:
- `SdkTemplateScheduleDialog.xaml` (Title "Set Template Schedule"): CboScheduleType
  (MONTHLY default / WEEKLY / ANNUALLY / CALENDAR), TxtScheduleHours (Text="9"),
  TxtScheduleDays, CboScheduleTimeZone (7 IANA TZ ids, America/New_York default),
  TxtScheduleExpiration. BtnOK="Save Schedule".
- `SdkWorkflowDialog.xaml` (Title "Test Workflow"): LblWorkflowName (TextBlock, set by handler),
  TxtTestInput (multiline, Consolas, AcceptsReturn), LblWorkflowStatus (TextBlock). BtnOK="Run Test".
- `SdkApprovalActionDialog.xaml` (Title "Approval Action"): LblApprovalAction (TextBlock, set by handler),
  TxtComment (multiline, AcceptsReturn), TxtForwardTo. BtnOK="OK".

**Deviation from plan (resolved by trusting code):** plan line 457 specifies a DatePicker
for the schedule expiration. `Show-SPGuiDialog` (SP.MainWindow.psm1:214-256) only reads
TextBox/ComboBox/CheckBox, so a DatePicker would silently return `$null` on OK. Used a
TextBox labelled "(YYYY-MM-DD, optional)" instead, matching the existing AuditQueryDialog
date-input precedent (lines 165-173). No DatePicker present in any of the 3 files.

**Files:**
- `Gui/SdkTemplateScheduleDialog.xaml` (CREATE)
- `Gui/SdkWorkflowDialog.xaml` (CREATE)
- `Gui/SdkApprovalActionDialog.xaml` (CREATE)
- `docs/phase7-sdk-gui-backlog.md` (SDK-09 -> DONE, table row + section)
- `docs/phase7-sdk-gui-rounds/round-09.md` (this file)

**Verification:**
  - Pester: n/a -- no GUI/XAML test file exists yet (SDK-15/W-08 will add the structural
    test). XAML-only change touches no existing test module; full suite intentionally not
    run per loop instructions (headless-fast only).
  - XAML parse: ok -- ran headless in `powershell -STA` with PresentationFramework/
    PresentationCore/WindowsBase loaded, using the same
    `XamlReader::Load(XmlNodeReader over [xml])` path as `Show-SPGuiDialog`. All 3 load with
    no exception; each root is `[System.Windows.Window]`; no `x:Class`. Every declared x:Name
    resolves to the expected type: schedule {CboScheduleType=ComboBox, TxtScheduleHours=TextBox,
    TxtScheduleDays=TextBox, CboScheduleTimeZone=ComboBox, TxtScheduleExpiration=TextBox};
    workflow {LblWorkflowName=TextBlock, TxtTestInput=TextBox, LblWorkflowStatus=TextBlock};
    approval {LblApprovalAction=TextBlock, TxtComment=TextBox, TxtForwardTo=TextBox}.
    BtnOK/BtnCancel non-null Buttons; BtnOK.IsDefault=True, BtnCancel.IsCancel=True in all 3.
    CboScheduleType items = MONTHLY,WEEKLY,ANNUALLY,CALENDAR. TxtTestInput.AcceptsReturn=True;
    TxtComment.AcceptsReturn=True. Every -ControlNames control is TextBox/ComboBox/CheckBox.
  - Manifest/import: n/a -- no module or manifest touched.

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-09 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS
