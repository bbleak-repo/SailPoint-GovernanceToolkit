# SharePoint On-Prem Sync Tool -- Reference Guide

## Overview

`Sync-SharePointSite.ps1` is a bidirectional file sync tool for SharePoint Server on-premises (2013, 2016, 2019). It uses the SharePoint REST API -- no external modules, no DLLs, no farm admin access required. Works with standard reader or contributor permissions.

Primary use case: downloading deep folder structures (e.g., `IT/Apps/IAM/AppsToMigrate/App1`) containing Office documents, HTML files, images, and other artifacts to a local drive. Also supports uploading local changes back to SharePoint with conflict resolution.

## 1. Quick Start

```powershell
# Download a folder tree from SharePoint to local disk
.\Sync-SharePointSite.ps1 -SiteUrl https://sharepoint.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps/IAM/AppsToMigrate" `
    -LocalPath C:\sync\AppsToMigrate

# Preview what would be downloaded (no files transferred)
.\Sync-SharePointSite.ps1 -SiteUrl https://sharepoint.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath C:\sync\IAM -WhatIf

# Upload local changes back to SharePoint
.\Sync-SharePointSite.ps1 -SiteUrl https://sharepoint.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath C:\sync\IAM -Direction Upload -WhatIf

# Bidirectional sync (newer file wins)
.\Sync-SharePointSite.ps1 -SiteUrl https://sharepoint.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath C:\sync\IAM -Direction Sync
```

## 2. Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-SiteUrl` | string | Yes | -- | Full URL to the SharePoint site (e.g., `https://sp.corp.com/sites/IT`) |
| `-RemotePath` | string | No | `/` | Server-relative path within the site (e.g., `/Shared Documents/Apps/IAM`) |
| `-LocalPath` | string | Yes | -- | Local directory to sync to/from |
| `-Direction` | string | No | `Download` | `Download`, `Upload`, or `Sync` (bidirectional) |
| `-Credential` | PSCredential | No | -- | Explicit credentials; omit to use current Windows session |
| `-Include` | string[] | No | -- | File patterns to include: `*.xlsx`, `*.docx`, `*.html`, `*.png` |
| `-Exclude` | string[] | No | -- | File patterns to exclude: `~$*`, `*.tmp` |
| `-ConflictResolution` | string | No | `NewerWins` | `NewerWins`, `LocalWins`, `RemoteWins`, or `ReportOnly` |
| `-MaxDepth` | int | No | `50` | Maximum folder recursion depth (safety limit) |
| `-RetryCount` | int | No | `3` | Retry attempts for transient HTTP errors |
| `-LogPath` | string | No | -- | Path for JSON Lines operation log |
| `-ConfirmReplace` | switch | No | -- | Prompt Yes/YesToAll/No/NoToAll before each file overwrite |
| `-Force` | switch | No | -- | Skip confirmation prompts for upload operations |
| `-WhatIf` | switch | No | -- | Show planned actions without executing them |

## 3. Authentication

The tool uses a three-layer authentication strategy, trying each in order:

### Layer 1: Explicit Credential

```powershell
$cred = Get-Credential -Message "SharePoint credentials"
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/" -LocalPath C:\sync -Credential $cred
```

### Layer 2: Default Windows Credentials

If no `-Credential` is provided and you're running on a domain-joined Windows machine, the script uses your current Kerberos/NTLM session automatically.

```powershell
# Just works on a domain-joined Windows machine
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/" -LocalPath C:\sync
```

### Layer 3: Interactive Prompt

If default credentials fail (401), the script prompts:

```
Enter credentials for sharepoint.corp.com
```

The prompted credential is cached for the duration of the script execution.

### PowerShell 7 Compatibility

On PowerShell 7+ (Core), the script automatically uses `-Authentication Negotiate` instead of `-UseDefaultCredentials`, which does not work the same way on non-Windows platforms.

> **Tip:** If you get 401 errors with default credentials, try providing explicit credentials with `-Credential (Get-Credential)`.

## 4. Direction Modes

### Download (Default)

Downloads remote files to local disk. Does not modify SharePoint.

| Remote State | Local State | Action |
|-------------|-------------|--------|
| File exists | Missing | Download |
| File exists | Exists, remote newer | Download (overwrite) |
| File exists | Exists, local newer | Skip |
| File exists | Exists, same time | Skip (in sync) |

### Upload

Uploads local files to SharePoint. Does not modify local files.

| Local State | Remote State | Action |
|------------|-------------|--------|
| File exists | Missing | Upload (create) |
| File exists | Exists, local newer | Upload (overwrite) |
| File exists | Exists, remote newer | Skip |

> **Important:** Upload operations prompt for confirmation showing the count of files that will be modified on SharePoint. Use `-Force` to skip the prompt, or `-WhatIf` to preview without executing.

### Interactive Overwrite Approval (`-ConfirmReplace`)

Add `-ConfirmReplace` to get a per-file prompt before each overwrite (new files and unchanged files are never prompted):

```powershell
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath C:\sync\IAM -Direction Sync -ConfirmReplace
```

The prompt offers four choices:
- **Yes** -- overwrite this file
- **Yes to All** -- overwrite this and all remaining files (stops prompting)
- **No** -- skip this file
- **No to All** -- skip this and all remaining overwrites

This is useful when syncing a large library and you want to review each changed file before committing.

### Sync (Bidirectional)

Syncs in both directions based on the `-ConflictResolution` setting.

| Remote State | Local State | NewerWins | LocalWins | RemoteWins | ReportOnly |
|-------------|-------------|-----------|-----------|------------|------------|
| Remote only | -- | Download | Download | Download | Download |
| -- | Local only | Upload | Upload | Upload | Upload |
| Newer remote | Older local | Download | Upload | Download | Conflict |
| Older remote | Newer local | Upload | Upload | Download | Conflict |
| Same time | Same time | Skip | Skip | Skip | Skip |

## 5. Path Handling

### Remote Path Resolution

The `-RemotePath` parameter is resolved against the site's document libraries:

```powershell
# Full server-relative path (most explicit)
-RemotePath "/sites/IT/Shared Documents/Apps/IAM"

# Path within a library (auto-resolved)
-RemotePath "/Shared Documents/Apps/IAM"

# Short path (resolved against default library)
-RemotePath "/Apps/IAM"
```

The script queries `_api/web/lists?$filter=BaseTemplate eq 101` to find document libraries, then matches the path against them. If no library matches, it tries "Shared Documents" as the default.

### Deep Folder Paths

Deep paths like `IT/Apps/IAM/AppsToMigrate/App1/Questionnaires` are fully supported. The local directory structure mirrors the remote structure:

```
Remote: /sites/IT/Shared Documents/Apps/IAM/AppsToMigrate/App1/data.xlsx
Local:  C:\sync\Apps\IAM\AppsToMigrate\App1\data.xlsx
```

> **Warning:** Windows has a 260-character path length limit (MAX_PATH). The script warns when local paths approach this limit. Consider using a shorter `-LocalPath` for deep folder structures.

## 6. File Filtering

### Include Patterns

Download only specific file types:

```powershell
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps" `
    -LocalPath C:\sync\Apps `
    -Include "*.xlsx","*.docx","*.html","*.png","*.jpg","*.pdf"
```

### Exclude Patterns

Skip unwanted files:

```powershell
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/Shared Documents" `
    -LocalPath C:\sync `
    -Exclude "~$*","*.tmp","Thumbs.db"
```

### Automatic Exclusions

The script always skips:
- **System folders**: Forms, _catalogs, _private, _vti_cnf, _vti_pvt, _cts, _layouts
- **Temp files**: Files starting with `~$`, `.tmp` files, `Thumbs.db`, `.DS_Store`

## 7. WhatIf Mode

Use `-WhatIf` to see exactly what the script would do without touching any files:

```powershell
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath C:\sync\IAM -WhatIf
```

The output shows the complete sync manifest -- every file, its status, and the planned action. This works for Download, Upload, and Sync directions.

> **Tip:** Always run with `-WhatIf` first on a new site to understand the scope before executing.

## 8. Logging

Enable detailed logging with `-LogPath`:

```powershell
.\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
    -RemotePath "/Shared Documents" -LocalPath C:\sync `
    -LogPath C:\logs\sp-sync.jsonl
```

Each operation generates a JSON Lines entry:

```json
{"timestamp":"2026-06-27T14:30:00","action":"Download","path":"Apps/IAM/App1/report.xlsx","size":45056,"status":"OK","duration_ms":234}
{"timestamp":"2026-06-27T14:30:01","action":"Download","path":"Apps/IAM/App2/data.csv","size":12288,"status":"OK","duration_ms":156}
```

## 9. Error Handling

### Retry Logic

Transient HTTP errors (500 Server Error, 503 Service Unavailable, 429 Too Many Requests) are retried automatically with exponential backoff:
- Attempt 1: wait 1 second
- Attempt 2: wait 3 seconds
- Attempt 3: wait 9 seconds

The `-RetryCount` parameter controls the maximum number of retries (default: 3).

### Partial Failure

If a single file fails to download or upload, the script:
1. Logs the error
2. Continues with the remaining files
3. Includes the failure in the summary count
4. Lists all failed files at the end

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| 401 Unauthorized | Credentials invalid or expired | Provide `-Credential` or check domain trust |
| 403 Forbidden | Insufficient permissions on site/library | Request at least Read permission from site admin |
| 404 Not Found | Site URL or path is wrong | Verify URL in browser first |
| File locked (423) | File checked out by another user | Wait for check-in, or download gets last checked-in version |
| Path too long | Local path exceeds 260 characters | Use a shorter `-LocalPath` root |
| Connection refused | SharePoint server unreachable | Check VPN, firewall, DNS resolution |

## 10. Examples

### Archive a SharePoint Site Locally

```powershell
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IAMTeam" `
    -RemotePath "/Shared Documents" `
    -LocalPath "C:\Archives\IAMTeam" `
    -LogPath "C:\Archives\IAMTeam\sync-log.jsonl"
```

### Download Only Excel and Word Files

```powershell
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM/AppsToMigrate" `
    -LocalPath "C:\IAM\Questionnaires" `
    -Include "*.xlsx","*.xls","*.docx","*.doc"
```

### Upload Changed Files Back

```powershell
# Preview first
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM/AppsToMigrate" `
    -LocalPath "C:\IAM\Questionnaires" `
    -Direction Upload -WhatIf

# Execute (with confirmation prompt)
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM/AppsToMigrate" `
    -LocalPath "C:\IAM\Questionnaires" `
    -Direction Upload
```

### Bidirectional Sync with Conflict Reporting

```powershell
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath "C:\sync\IAM" `
    -Direction Sync `
    -ConflictResolution ReportOnly `
    -LogPath "C:\sync\IAM\sync-log.jsonl"
```

### Using Explicit Credentials

```powershell
$cred = Get-Credential -Message "Enter DOMAIN\username for SharePoint"
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents" `
    -LocalPath "C:\sync" `
    -Credential $cred
```

## 11. Workflow: SharePoint to Consolidator Pipeline

A common workflow combines the SharePoint sync tool with the IAM intake consolidator:

```powershell
# Step 1: Download questionnaires from SharePoint
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IAM" `
    -RemotePath "/Shared Documents/App Questionnaires" `
    -LocalPath "C:\IAM\Questionnaires" `
    -Include "*.xlsx"

# Step 2: Consolidate downloaded Excel files
.\Merge-IAMIntakeData.ps1 `
    -Path "C:\IAM\Questionnaires" `
    -OutputPath "C:\IAM\Consolidated" `
    -SaveSchema

# Step 3: Upload consolidated reports back to SharePoint
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IAM" `
    -RemotePath "/Shared Documents/Consolidated Reports" `
    -LocalPath "C:\IAM\Consolidated" `
    -Direction Upload -Force
```

## 12. Technical Notes

### REST API Compatibility

| SharePoint Version | REST API | Tested |
|-------------------|----------|--------|
| SharePoint 2013 | Available (limited `$expand`) | Designed for |
| SharePoint 2016 | Full support | Designed for |
| SharePoint 2019 | Full support | Designed for |
| SharePoint SE | Full support | Designed for |
| SharePoint Online | NOT supported | Use PnP.PowerShell instead |

### File Size Limits

- Downloads: No practical size limit (streamed to disk)
- Uploads: Direct upload up to 250 MB (SP 2013) or 2 GB (SP 2016+). Files over 10 MB trigger a warning about potential timeout.

### Timestamp Handling

- File modified timestamps are preserved on download (set via `[System.IO.File]::SetLastWriteTime`)
- A 2-second tolerance is used for timestamp comparison (accounts for filesystem rounding)
- Remote timestamps (`TimeLastModified`) are parsed with `AssumeUniversal | AdjustToUniversal` to stay UTC
- Local files use `LastWriteTimeUtc` for comparison -- never local time
- This prevents false positives from timezone differences between the SharePoint server and the client machine

### Authentication Notes

- `-Authentication Negotiate` is NOT used -- it is not a valid value for `Invoke-WebRequest` on PS 7+. Plain `-Credential` handles the NTLM/Negotiate challenge on both PowerShell editions.
- `-UseDefaultCredentials` works on both Windows PowerShell 5.1 and PowerShell 7+ (contrary to some documentation)
