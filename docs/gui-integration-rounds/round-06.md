# Round 6
**Started:** 2026-05-31 14:38:23

GU-06 done and pushed. Here's what was implemented:

**MainWindow.xaml** - Added Row 5 to the Delta Cert tab grid: a dark `#2D2D44` border containing:
- `DcAppStatusLabel` -- shows "N registered, N delivered, N missing" 
- `BtnRunDisconnectedBatch` -- launches `Scripts\Invoke-SPDisconnectedAppBatch.ps1` in a new PS window
- `BtnCheckDelivery` -- refreshes the status label
- `BtnViewSla` -- shows 30-day SLA summary (compliant/non-compliant/avg delivery rate) in the status bar
- `BtnRefreshDcAppStatus` -- also refreshes the status label

**SP.GuiBridge.psm1** - `Get-SPGuiDisconnectedAppStatus`: wraps `Get-SPDisconnectedAppDeliveryStatus`, gracefully handles missing DisconnectedApps config or module, returns `@{Registered; Delivered; Stale; Missing; Disabled; SummaryText}`.

**SP.Gui.psd1** - Exported the new bridge function.

**SP.MainWindow.psm1** - Wired all 4 new controls in `Initialize-DeltaCertTab`; added `Load-DisconnectedAppStatus`, `Invoke-GuiDisconnectedAppBatch` (Start-Process approach to avoid duplicating the 8-step pipeline in the GUI), and `Invoke-GuiViewDisconnectedAppSla`.

