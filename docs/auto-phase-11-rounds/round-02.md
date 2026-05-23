# Round 2
**Started:** 2026-05-23 18:56:26

**P11-02 complete.** Added two functions to `SP.AuditReport.psm1`:

- **`Get-SPAuditTrail`** -- Reads `audit-*.jsonl`, `deltacert-audit.jsonl`, and `deltacert-escalation.jsonl`, normalizes events to a common schema (Timestamp, EventType, Action, CorrelationID, SourceIds, Summary, Details, FilePath), applies filters (date range, correlation ID, event type, source ID), sorts newest-first, caps at MaxEvents.

- **`Export-SPAuditTrailHtml`** -- Generates a Word-compatible HTML timeline with color-coded badges (blue=CampaignAudit, green=DeltaCertRun, orange=Escalation), uses existing `Build-HtmlTableHeader`/`Build-HtmlTableRow`/`ConvertTo-SafeHtml` helpers.

Both exported in `SP.Audit.psd1`. Syntax validated. Committed and pushed as `e2aec39`.

**Completed:** 2026-05-23 18:59:56
