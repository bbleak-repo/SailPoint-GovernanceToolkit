# Round 4
**Started:** 2026-05-31 14:33:11

**GU-04 done.** `Gui/GovernanceRunDialog.xaml` created and pushed.

- 5 checkboxes: Campaign Audit + Leadership Rollup pre-checked, Policy/DataQuality/DashboardExport unchecked
- Status ComboBox (COMPLETED default) + Days Back TextBox (90 default)
- BtnOK (`IsDefault=True`) / BtnCancel (`IsCancel=True`)
- All 7 control names match the `ControlNames` array in `Invoke-GuiGovernanceReport` exactly
- XML validates; dark theme consistent with existing 3 dialogs

Next pending is **GU-05** (Enhanced AuditQueryDialog).

