# Development Guide

Architecture, conventions, and how to extend the toolkit.

## Repository Structure

```
Sailpoint-CyberArk-Okta/
  iam-intake-tool.html           # Browser-based wizard (self-contained HTML)
  Merge-IAMIntakeData.ps1        # Adaptive Excel consolidator
  Sync-SharePointSite.ps1        # SharePoint on-prem sync tool
  README.md                      # Project overview
  QUICKSTART.md                  # 5-minute setup guide
  DEVELOPMENT.md                 # This file
  docs/
    USER-GUIDE.html              # Generated playbook (do not edit directly)
    playbook/
      playbook.json              # Playbook configuration
      generate-playbook.py       # Playbook generator (config-driven)
      _framework.css             # Playbook theme (light)
      00-foundations.md           # Foundations section source
      01-html-intake-tool.md     # HTML tool section source
      02-powershell-consolidator.md  # Consolidator section source
      03-sharepoint-sync.md      # SharePoint sync section source
```

## Conventions

### PowerShell Scripts

All PowerShell scripts in this project follow these conventions (consistent with the SailPoint, CyberArk, and EntraID sibling projects):

- `#Requires -Version 5.1` header
- Full comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`)
- `[CmdletBinding(SupportsShouldProcess)]` with `ConfirmImpact` where appropriate
- `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'`
- `$script:DateStamp = Get-Date -Format 'yyyy-MM-dd'` for output file naming
- Parameters use `[ValidateSet()]`, `[ValidateScript()]`, `[ValidateNotNullOrEmpty()]`
- HTML reports use `System.Text.StringBuilder` with `[void]$sb.AppendLine()`
- File writes use `[System.IO.File]::WriteAllText()` with `UTF8Encoding($false)` (no BOM)
- User-supplied values in HTML are always escaped via `[System.Net.WebUtility]::HtmlEncode()`
- No emoji or unicode characters in scripts

### HTML Files

- Self-contained: all CSS and JavaScript inline, zero external dependencies
- Font stack: `-apple-system, 'Segoe UI', system-ui, Roboto, Helvetica, Arial, sans-serif`
- Color palette: `--primary: #1b2a4a`, `--primary-mid: #2d5a8a`, `--accent: #00897b`
- Hero gradient: `linear-gradient(135deg, #1b2a4a 0%, #2d5a8a 60%, #3a7bc8 100%)`
- Cards: `border-radius: 10px; box-shadow: 0 2px 8px rgba(0,0,0,.06)`
- No emoji in the interface
- Print-friendly (`@media print` stylesheet)
- Mobile-responsive (`@media (max-width: 768px)`)

### Playbook

The playbook (`docs/USER-GUIDE.html`) is generated from Markdown source files. **Do not edit the HTML directly** -- edit the `.md` files in `docs/playbook/` and regenerate:

```bash
python3 docs/playbook/generate-playbook.py --config docs/playbook/playbook.json
```

## Architecture: HTML Intake Tool

### Data Flow

```
User input -> AppDataModel (JS object) -> Decision engines -> Summary panel
                    |                            |
                    v                            v
              localStorage              Derived values (_derived)
                    |
                    v
              CSV/JSON export
```

### Key Components

| Component | Location in File | Purpose |
|-----------|-----------------|---------|
| `KNOWN_APPS` | Top of `<script>` | Catalog of 15 pre-configured apps |
| `STEPS` | After KNOWN_APPS | Step definitions (id, label, title, visibility) |
| `createApp()` | Data Model section | Factory for new app records |
| `STATE` | After createApp | Global state: apps array, activeIndex |
| `deriveSailPoint()` | Decision Engines | Pattern 1-4 classification |
| `deriveFileDelivery()` | Decision Engines | Pattern A-F for CSV delivery |
| `deriveCyberArk()` | Decision Engines | HLA priority/tier + CPM/PSM approach |
| `deriveOktaMigration()` | Decision Engines | Entra equivalent + gap detection |
| `renderStep1-7()` | Render section | Step-specific HTML generation |
| `renderSummary()` | After steps | Live summary panel |
| `exportSailPoint/CyberArk/etc()` | CSV Export Engine | Per-product CSV generation |
| `analyzeLoginData()` | Login Analysis | Bookmarklet/paste-source parser |

### Adding a New Known App

Add an entry to the `KNOWN_APPS` object:

```javascript
"AppName": {
    vendor: "Vendor", deploymentType: "saas",
    sp: { nativeConnector: true/false, pattern: 1-4, scim: true/false, note: "" },
    ca: { marketplace: true/false, psm: true/false, cpm: true/false,
          category: "Web", authMethod: "localPassword", access: "browser" },
    okta: { oin: true/false, signOnMode: "saml", scim: true/false },
    roles: ["Role1", "Role2"]
}
```

### Adding a New Wizard Question

1. Add the field to `createApp()` in the data model
2. Add the question rendering in the appropriate `renderStepN()` function
3. If it maps to a product recommendation, update the relevant `derive*()` function
4. If it should appear in CSV exports, add the column to the appropriate `export*()` function

## Architecture: Excel Consolidator

### Processing Pipeline

```
.xlsx / .docx files -> Format detection -> Data extraction -> Canonical mapping
                                                                  |
                                                                  v
                                                          Value normalization
                                                                  |
                                                                  v
                                              Merge by app name (filename anchor first)
                                                                  |
                                                                  v
                                                      CSV + HTML + JSON output
```

### Sheet Formats

| Format | Detected by | Extraction |
|--------|-------------|------------|
| Structured | Any row whose cells match the block-header vocabulary (`$script:StructuredHeaderRoles`) | Headerless block walk: banners, Q&A blocks (answer taken from Responses/Answer column, guidance columns ignored), contacts blocks (Name(s)/Email(s)), account tables (EXAMPLE ENTRY rows skipped), unknown sub-tables preserved as `_detail_*` JSON |
| List | Sheet NAME matches `ListSheetPatterns` (roles/groups/...) | Rows aggregate into app-level fields (`sp_rbacRoles`, `adGroups`, counts) + `_detail_*` JSON |
| Tabular | Many uniformly-filled columns | One app record per row |
| KeyValue | 2-3 columns, question-like col A | One record per sheet |
| MultiSection | KV plus section markers | Section-prefixed keys (bare question also tried during mapping) |
| Docx | `.docx` extension | Tables from word/document.xml: entitlement-schema tables -> groups/roles, 2-column tables -> key/value, others -> `_detail_*` JSON |

### Adaptivity

The structured parser is layout-agnostic: it discovers each block's column
roles from header captions, not fixed positions. To teach it a new template
vocabulary, extend `$script:StructuredHeaderRoles` (caption -> role) and, for
new questions, add aliases to `$script:CanonicalFields`. Fuzzy matching uses
exact alias > coverage-weighted containment > word overlap, so longer, more
specific aliases always win over generic words.

### App Identity & Merge

Records merge by normalized app name ("Salesforce.com", "ServiceNow (SNOW)"
and "Service Now" collapse to one key). Files named
`<AppName>_<Template>.xlsx` (e.g. `Versify_CyberArk Questionnaire.xlsx`)
carry the app identity in the filename -- that anchor wins over in-sheet
names, which often hold DB/instance names. Disagreements between sources are
kept in `_conflicts`; name variants in `_nameVariants`.

### Key Extension Points

**Adding a canonical field:**

1. Add to `$script:CanonicalFields` with aliases:
```powershell
newField = @('alias1', 'alias2', 'alias three', 'longer question text')
```

2. If it's a boolean field, add to `$script:BooleanFields`
3. If it needs custom normalization, add a rule to `$script:NormalizationRules`
4. Add to the appropriate per-product column list in the output section
5. Add to the HTML report's field array in `Export-ConsolidatedHtml`

**Adding a normalization rule:**

Add to `$script:NormalizationRules` with canonical value -> aliases array:
```powershell
'fieldName' = @{
    'Normalized Value' = @('raw1', 'raw2', 'raw variation 3')
}
```

Then add a case to the `switch ($key)` block in `Normalize-FieldValue`.

**Adding a new product dimension:**

Follow the pattern used for OktaEntra:
1. Add canonical fields with `prefix_` naming
2. Add to `ValidateSet` on the `-Product` parameter
3. Add per-product CSV export block
4. Add rendering section in `Export-ConsolidatedHtml`

### Schema Files

The `-SaveSchema` flag outputs a JSON file mapping source column names to canonical fields:

```json
{
    "version": "1.0",
    "created": "2026-07-15",
    "mappings": { "Application Name": "appName", ... },
    "unmapped": ["Internal Notes"]
}
```

Edit this file to fix incorrect mappings, then reuse with `-SchemaPath`.

## Architecture: SharePoint Sync

### API Strategy

Uses SharePoint REST API (`/_api/`) exclusively -- no CSOM DLLs, no ASMX web services, no WebDAV. This provides the broadest compatibility (SP 2013+) with zero dependencies.

### Key REST Endpoints

| Endpoint | Purpose |
|----------|---------|
| `_api/web?$select=Title,Url` | Connection test |
| `_api/contextinfo` | Form digest for write operations |
| `_api/web/lists?$filter=BaseTemplate eq 101` | Enumerate document libraries |
| `_api/web/GetFolderByServerRelativeUrl('{path}')/Folders` | List subfolders |
| `_api/web/GetFolderByServerRelativeUrl('{path}')/Files` | List files |
| `_api/web/GetFileByServerRelativeUrl('{path}')/$value` | Download file |
| `_api/web/GetFolderByServerRelativeUrl('{path}')/Files/add(url='{name}',overwrite=true)` | Upload file |
| `_api/web/folders/add('{path}')` | Create folder |

### Authentication Flow

```
Credential provided? --yes--> -Credential (NTLM/Negotiate via 401 challenge)
         |
         no
         |
         v
Try -UseDefaultCredentials
(works on Windows PowerShell 5.1 AND PS 7+)
         |
   Success? --yes--> Proceed
         |
        no
         |
         v
Prompt Get-Credential
         |
         v
   Test _api/web
   401 -> "Access denied"
   403 -> "Insufficient permissions"
   404 -> "Site not found"
   200 -> Display site title, proceed
```

Note: `-Authentication Negotiate` is NOT passed to `Invoke-WebRequest` -- it is not a
valid value on PS 7+ (only None/Basic/Bearer/OAuth). Plain `-Credential` handles the
NTLM/Negotiate challenge on both editions.

Remote timestamps (`TimeLastModified`) are parsed with `AssumeUniversal | AdjustToUniversal`
so they stay UTC (Kind=Utc) and compare correctly against local `LastWriteTimeUtc` --
never use a bare `[datetime]::Parse()` on SharePoint timestamps.

### Sync Manifest

The manifest is a list of `[PSCustomObject]` entries, one per file, with fields:

| Field | Description |
|-------|-------------|
| `RelativePath` | Path relative to the sync root |
| `Action` | DownloadNew, DownloadUpdate, UploadNew, UploadUpdate, SkipInSync, Conflict |
| `Size` | File size in bytes |
| `ServerRelativeUrl` | Full server-relative URL for REST API calls |
| `RemoteModified` | SharePoint modified timestamp |
| `LocalModified` | Local file modified timestamp |

### Adding File Type Handling

The tool is file-type agnostic -- it downloads/uploads raw bytes. No special handling is needed for new file types. To filter by type, use `-Include`:

```powershell
-Include "*.xlsx","*.docx","*.pptx","*.pdf","*.html","*.png","*.jpg"
```

## Regenerating the Playbook

After editing any `.md` file in `docs/playbook/`:

```bash
python3 docs/playbook/generate-playbook.py --config docs/playbook/playbook.json
```

To add a new section:
1. Create `docs/playbook/04-new-section.md`
2. Add to `playbook.json`:
```json
{"file": "04-new-section.md", "group": "New Section Name"}
```
3. Regenerate

## Testing

### Consolidator

```powershell
# Create test Excel files
# (see test-data creation example in the original development session)

# Run with DryRun to verify detection without output
.\Merge-IAMIntakeData.ps1 -Path .\test-data -DryRun -ShowUnmapped

# Full run with HTML
.\Merge-IAMIntakeData.ps1 -Path .\test-data -SaveSchema
```

### SharePoint Sync

```powershell
# Always start with WhatIf
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/Shared Documents" -LocalPath C:\test-sync -WhatIf

# Test credential handling
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/" -LocalPath C:\test-sync `
    -Credential (Get-Credential) -WhatIf
```

### HTML Intake Tool

Open `iam-intake-tool.html` in a browser and verify:
1. Known app catalog pre-populates fields
2. "Not sure" triggers fallback questions
3. Summary panel updates live
4. CSV exports open correctly in Excel
5. localStorage persists across page refreshes

## Related Projects

| Project | Path | Relationship |
|---------|------|-------------|
| SailPoint GovernanceToolkit | `../SailPoint/tools/SailPoint-GovernanceToolkit/` | Consumes `sailpoint-onboarding.csv`; provides v1/v2 CSV templates |
| CyberArk CPM-PSM TestKit | `../CyberArk-CPM-PSM-TestKit/` | Consumes `cyberark-onboarding.csv`; provides HLA classification framework |
| Okta App Migration | `../Okta/okta-app-migration/` | Consumes `okta-entra-migration.csv`; provides gap analysis taxonomy |
| EntraID Group Enumerator | `../EntraID/Group-Enumerator/` | SailPoint ISC reconciliation expansion uses correlation keys |
