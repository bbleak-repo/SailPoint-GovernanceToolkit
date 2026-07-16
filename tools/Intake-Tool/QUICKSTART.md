# Quick Start Guide

Get up and running in 5 minutes.

## 1. HTML Intake Tool (No Setup Required)

Open `iam-intake-tool.html` in your browser. That's it.

**For app owners:**
1. Open the file
2. Click **Known App Catalog** if your app is listed (ServiceNow, Salesforce, etc.)
3. Walk through the 7 steps -- answer what you know, skip what you don't
4. On Step 7, click **Export All** to download CSVs

**For IAM team distributing to app owners:**
- Email the HTML file as an attachment
- Or place it on a shared drive / SharePoint site
- No server, no installation, no internet required

## 2. Excel Consolidator Setup

### One-Time: Install ImportExcel Module

```powershell
Install-Module ImportExcel -Scope CurrentUser
```

This installs a pure .NET library -- no Microsoft Excel installation needed.

### Run It

```powershell
# Point at a folder of Excel questionnaires
.\Merge-IAMIntakeData.ps1 -Path C:\path\to\questionnaires

# Preview what it finds without writing files
.\Merge-IAMIntakeData.ps1 -Path C:\path\to\questionnaires -DryRun

# Save the column mapping for faster future runs
.\Merge-IAMIntakeData.ps1 -Path C:\path\to\questionnaires -SaveSchema
```

Output lands in `.\IAM-Intake-Consolidated\` (or specify `-OutputPath`).

## 3. SharePoint Sync Setup

No modules to install -- uses built-in PowerShell commands.

### Download from SharePoint

```powershell
# Preview first (always a good idea)
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath "C:\sync\IAM" `
    -WhatIf

# Execute the download
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath "C:\sync\IAM"
```

If running on a domain-joined machine, authentication is automatic. Otherwise you'll be prompted for credentials.

### Upload Back to SharePoint

```powershell
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Consolidated Reports" `
    -LocalPath ".\IAM-Intake-Consolidated" `
    -Direction Upload -WhatIf
```

### Approve Each Replacement Interactively

Add `-ConfirmReplace` to get a Yes / Yes to All / No / No to All prompt before
each file that would be overwritten (new and unchanged files never prompt):

```powershell
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IT" `
    -RemotePath "/Shared Documents/Apps/IAM" `
    -LocalPath "C:\sync\IAM" `
    -Direction Sync -ConfirmReplace
```

## 4. End-to-End Pipeline

```powershell
# Step 1: Download questionnaires from SharePoint
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IAM" `
    -RemotePath "/Shared Documents/App Questionnaires" `
    -LocalPath "C:\IAM\Questionnaires" `
    -Include "*.xlsx"

# Step 2: Consolidate everything
.\Merge-IAMIntakeData.ps1 `
    -Path "C:\IAM\Questionnaires" `
    -SaveSchema

# Step 3: Upload reports back
.\Sync-SharePointSite.ps1 `
    -SiteUrl "https://sharepoint.corp.com/sites/IAM" `
    -RemotePath "/Shared Documents/Consolidated" `
    -LocalPath ".\IAM-Intake-Consolidated" `
    -Direction Upload

# Step 4: Open the HTML app browser
Invoke-Item ".\IAM-Intake-Consolidated\IAM-Intake-Browser-*.html"
```

## 5. Full Documentation

Open `docs/USER-GUIDE.html` in your browser for the complete playbook with 51 navigable sections covering every parameter, decision tree, and troubleshooting scenario.

## Common Issues

| Issue | Fix |
|-------|-----|
| `ImportExcel module not installed` | `Install-Module ImportExcel -Scope CurrentUser` |
| SharePoint 401 Unauthorized | Try `-Credential (Get-Credential)` with domain\username |
| HTML tool data lost after browser clear | Always export before clearing browser data |
| CSV opens as single column in Excel | Use Data > From Text/CSV import with comma delimiter |
| PowerShell execution policy error | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
