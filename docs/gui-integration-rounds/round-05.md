# Round 5
**Started:** 2026-05-31 14:34:55

**GU-05 done.** Pushed to `feature/gui-integration` (fe618ec).

### What was implemented

**AuditQueryDialog.xaml**
- Added `CboType` ComboBox (All / MANAGER / SOURCE_OWNER / SEARCH / ROLE_COMPOSITION) below the Status/Timespan row
- Added `TxtCreatedAfter` and `TxtCreatedBefore` date text fields (YYYY-MM-DD) side-by-side

**SP.GuiBridge.psm1 -- `Get-SPGuiAuditCampaigns`**
- Added `CampaignType`, `CreatedAfter`, `CreatedBefore` parameters
- `CampaignType` passed directly to `Get-SPAuditCampaigns` when not `(All)`
- Date strings parsed via `[DateTime]::TryParse` before forwarding as typed `DateTime` params (matching what `Get-SPAuditCampaigns` expects)

**SP.MainWindow.psm1**
- `BtnConfigure` handler and `Invoke-AuditCampaignQuery`: `ControlNames` array extended with the 3 new control names
- `Invoke-AuditCampaignQuery`: extracts and forwards `CampaignType`, `CreatedAfter`, `CreatedBefore` into `$queryParams`
- `Get-AuditQueryDialogDefaults`: seeds `CboType='(All)'`, `TxtCreatedAfter=''`, `TxtCreatedBefore=''` so last-used params survive between opens
- `Update-AuditSummaryLabel`: includes `Type: MANAGER` in the summary when a type is selected

