# HTML Intake Tool -- User Guide

## Overview

The IAM Application Integration Intake tool (`iam-intake-tool.html`) is a browser-based wizard that guides application owners through a structured questionnaire. It collects the information needed for SailPoint governance, CyberArk privileged access management, and Okta/Entra ID identity federation -- all without requiring the app owner to know anything about these IAM products.

The tool translates plain-language answers ("When I log in, I get redirected to another page") into IAM-actionable data ("SAML SSO via federated IdP").

## 1. Opening the Tool

Open `iam-intake-tool.html` in any modern web browser. No internet connection is required.

The interface has three main areas:

- **Header bar** -- Title, Known App Catalog button, Add Application button, Reset button
- **Wizard panel** (left) -- Step-by-step questionnaire with navigation pills at the top
- **Summary panel** (right) -- Live integration map that updates as you answer questions

## 2. Starting a New Application

### Option A: Select from Known App Catalog

1. Click **Known App Catalog** in the header
2. Search or browse the 15 pre-loaded applications
3. Click an application, then click **Apply Selection**
4. Fields across all wizard steps are pre-populated with known answers
5. Review and adjust any values that differ for your specific environment

### Option B: Manual Entry

Simply start typing in Step 1. Every field is editable.

> **Tip:** Even if your app is not in the catalog, starting with a similar app and modifying values can save time.

## 3. Wizard Step 1: Application Identity

Provide basic information about your application:

| Field | Required | Example |
|-------|----------|---------|
| Application Name | Yes | ServiceNow, PEP+, Custom HR Portal |
| Application URL | Yes | https://acme.service-now.com |
| Vendor / Publisher | No | ServiceNow, Fiserv, In-house |
| Deployment Type | Yes | SaaS, On-premises, IaaS-hosted, Hybrid |
| Estimated User Count | No | Under 50, 50-500, 500-5000, 5000+ |
| Application Owner (Name) | No | Jane Smith |
| Application Owner (Email) | No | jane.smith@company.com |
| Brief Description | No | Free-form description of the app's purpose |

> **Note:** The application name is used as the merge key when combining data from multiple sources. Use the same name consistently.

## 4. Wizard Step 2: How Users Log In

This step determines the authentication method without requiring you to know protocols like SAML or OIDC.

**Primary question:** "When a user goes to log into your app, what happens?"

| Answer | What it means (behind the scenes) |
|--------|-----------------------------------|
| Direct login page | Local authentication -- the app manages its own passwords |
| Redirected to company login | SSO/federated -- a separate identity provider handles login |
| Automatic sign-in from desktop | Integrated Windows Authentication (IWA/Kerberos) |
| Multiple methods | Mixed authentication -- both local and SSO may be available |
| Not sure | Triggers a simpler follow-up question (see below) |

### "Not Sure" Follow-Up

If you select "Not sure," the tool rephrases the question:

> "When you go to your app's website, what do you see first?"
> - A username and password form on the app's own page
> - I get sent to a different website to sign in
> - I am already logged in when I open the page

### Identity Provider Detection

If SSO is detected, the tool asks which provider handles the login (Okta, Microsoft Entra ID, Other, Not sure).

### Login Page Analysis (Optional)

Click **Analyze Login Page** to open the analysis modal. Two methods:

**Bookmarklet method:**
1. Drag the "IAM Login Analyzer" button to your browser's bookmark bar
2. Navigate to your application's login page
3. Click the bookmarklet -- a panel appears with captured JSON
4. Copy the JSON and paste it into the tool
5. Click **Parse Bookmarklet Data**

**Paste Source method:**
1. Navigate to your application's login page
2. Right-click, select "View Page Source"
3. Select all (Ctrl+A / Cmd+A), copy
4. Paste into the "Paste page source code" area
5. Click **Analyze Source Code**

Both methods detect:
- Form field names and types (username, password, OTP fields)
- SAML indicators (SAMLRequest parameters, RelayState)
- OIDC indicators (client_id, response_type parameters)
- Identity provider (Okta, Entra ID, Auth0, Ping hostname patterns)
- MFA indicators (TOTP input fields, authenticator links)

Click **Apply to Wizard** to auto-populate authentication fields.

> **Note:** Some sites block bookmarklets via Content Security Policy (CSP). Use the paste-source method as a fallback.

### MFA Configuration

If MFA is enabled, select all applicable types:
- One-time code from an app (Google/Microsoft Authenticator)
- Push notification
- SMS text message
- Hardware token (YubiKey, RSA)
- Email code
- Certificate / smart card

## 5. Wizard Step 3: Access & Permissions

### Roles

If the app has different roles, add them using the dynamic list:

| Field | Purpose |
|-------|---------|
| Role name | The technical or common name (e.g., "admin", "itil", "ReadOnly") |
| Description | What this role allows (optional but helpful) |
| Risk level | Low, Medium, High, Critical -- your best assessment |

Click **+ Add Role** to add more. Click the X to remove.

> **Tip:** If you selected a known app, default roles are pre-populated. Modify or remove any that don't apply to your instance.

### Admin / Privileged Accounts

The "Not sure" response triggers a simpler question:

> "Is there at least one account that can create other users, change security settings, or view all data?"

If yes, specify:
- How many admin accounts exist
- Account types (human admin, service account, API/integration, shared)
- How admins access the app (browser, RDP, SSH, thick client)

> **Important:** This section determines whether CyberArk Step 5 appears. If you answer "No" or skip this, the CyberArk section is hidden.

## 6. Wizard Step 4: SailPoint Governance

This step determines how SailPoint will connect to your application.

### API Questions

"Does the app have an API?" -- If unsure, the tool rephrases:

> "Does your app have developer documentation or a way to manage users programmatically?"

If yes, follow-up questions ask about the API type (REST, SOAP, GraphQL) and whether it supports creating/updating/deleting users.

### CSV Export Questions

"Can the app export a list of all users and their roles?" -- If unsure:

> "Can an admin go to a user management page and download a list of all users?"

If yes, the tool asks about the export method (built-in button, database query, manual copy) and whether automatic file delivery is possible (SFTP, network share, API, manual only).

### v2 Template Fields

A checklist asks whether your app can provide enhanced data fields:
- Account Type (standard, admin, service, shared)
- Creation Date
- Last Login
- Entitlement Owner
- Entitlement Type (role, group, permission, license)
- Entitlement Risk Level (low, medium, high, critical)

These are optional enhancements for SailPoint v2 CSV templates. Check what your app can provide.

### Auto-Derived Result

After answering, the tool displays the recommended SailPoint integration pattern and file delivery method with a confidence level (high/medium/low).

## 7. Wizard Step 5: CyberArk Privileged Access

This step appears only if admin/privileged accounts were identified in Step 3.

### HLA Checklist (6 Questions)

Click Yes or No for each:

| Question | Scoring Impact |
|----------|---------------|
| Can this account modify security settings or audit logs? | +1 toward higher priority |
| Can this account create, delete, or modify other users? | +1 |
| Does this account have access to sensitive data? | +1 |
| Is this a service account for system-to-system integration? | +1 |
| Could compromise affect more than 100 users? | +1 |
| Does this account manage infrastructure? | +1, auto-promotes to P0 |

### Admin Authentication

Select how admins authenticate: local password, API token, OAuth, certificate, SSH key, AD/domain account, or SSO pass-through.

### Password Change via API

"Can the admin password be changed via API?" -- If unsure:

> "Is there a way to reset the admin password without logging into the app's UI manually?"

This determines whether CyberArk CPM (Central Policy Manager) can automate password rotation.

### Auto-Derived Result

The tool displays:
- **HLA Priority** (P0-P3) and **Tier** (0-3) with color-coded badge
- **HLA Score** (0-6)
- **CPM Approach** (Built-in Marketplace, REST API Framework, Manual, Vault-Only)
- **PSM Approach** (Built-in RDP/SSH, WebFormFields, AutoIt custom, N/A)
- **Estimated Effort** (days)
- **Marketplace Connector** indicator (if known app)

## 8. Wizard Step 6: Okta / Entra ID

This step appears only if SSO was detected in Step 2 or if an identity provider was identified.

### Okta-Specific Questions

If the current IdP is Okta:
- **Sign-On Mode**: SAML, OIDC, SWA, Bookmark, or Not sure
- **SCIM Provisioning**: Whether automated user provisioning is configured
- **Okta App Label**: The display name in Okta (optional)

If "Not sure" on sign-on mode, the tool asks:

> "When you click the app in your Okta dashboard, what happens?"
> - I'm automatically signed into the app (SAML/OIDC)
> - Okta fills in a username and password for me (SWA)
> - It just opens a web link (Bookmark)

### Migration Target

Select the planned direction: Staying in Okta, Moving to Entra ID, Both (dual IdP), or Not decided.

### Auto-Derived Gaps

If migrating to Entra ID, the tool displays known migration gaps as amber callout boxes. These are informational -- the IAM team will handle the technical migration.

## 9. Wizard Step 7: Review & Export

The final step shows:

1. **Validation messages** -- Missing required fields (red) and incomplete optional sections (amber)
2. **Full summary** -- All entered data organized by section
3. **Additional notes** -- Free-form textarea for anything else the IAM team should know

### Export Options

| Button | Output |
|--------|--------|
| SailPoint CSV | `sailpoint-onboarding-YYYY-MM-DD.csv` |
| CyberArk CSV | `cyberark-onboarding-YYYY-MM-DD.csv` |
| Okta/Entra CSV | `okta-entra-migration-YYYY-MM-DD.csv` |
| Login Analysis CSV | `login-analysis-YYYY-MM-DD.csv` |
| Master CSV | `app-inventory-master-YYYY-MM-DD.csv` (all data combined) |
| Export JSON | `iam-intake-data-YYYY-MM-DD.json` (full data model) |
| Export All | Downloads all 5 CSVs + JSON simultaneously |
| Print | Browser print dialog (optimized print stylesheet) |

## 10. Portfolio Mode (Multiple Applications)

App owners who manage multiple applications can add them all in a single session:

1. Complete the first application through the wizard
2. Click **+ Add Application** in the header (or on the Review step)
3. A new blank application is created with its own tab in the summary panel
4. Switch between applications by clicking tabs
5. All applications are included in CSV exports (one row per app)

To remove an application, click the X on its tab and confirm.

> **Important:** All applications share a single localStorage session. Exporting downloads data for ALL applications in the current session.

## 11. Session Recovery

If you close the browser or navigate away, your data is preserved in localStorage. When you reopen the file, the tool restores:

- All application data
- Current wizard step position
- Summary panel state

Auto-save runs every 30 seconds and on every step transition.

> **Warning:** Using "Reset" in the header permanently erases all stored data. Always export first.

## 12. Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Bookmarklet does not work | Site blocks bookmarklets via CSP | Use the paste-source method instead |
| Data not saved after refresh | Private/incognito mode | Use a normal browser window; private mode disables localStorage |
| CSV opens as single column in Excel | Excel defaulting to non-comma delimiter | Use "Data > From Text/CSV" import with comma delimiter, or change regional settings |
| No CyberArk step appears | "Privileged accounts" not answered Yes in Step 3 | Go back to Step 3, answer "Yes" to the admin accounts question |
| No Okta step appears | Login method not detected as SSO | Go to Step 2, select "Redirected to company login" or use the login analyzer |
| Page loads slowly | 50+ applications in localStorage | Export data, then reset to start fresh |
