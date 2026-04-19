# SailPoint ISC Sandbox -- API Client Setup for Governance Toolkit

**Date:** 2026-04-09
**Purpose:** Step-by-step guide to create the OAuth 2.0 API client (Personal Access Token / API credentials) in a SailPoint ISC sandbox tenant for use with the Governance Toolkit.

---

## Prerequisites

- Admin access to your SailPoint ISC sandbox tenant (e.g., `https://acme-sb.identitynow.com`)
- The tenant must have at least one source configured with identities aggregated (the toolkit queries campaigns, certifications, and sources)
- You need the **ORG_ADMIN** or **CERT_ADMIN** role to create API clients with sufficient scope

---

## Step 1: Choose the Right API Client Type

ISC offers two types of API credentials. The toolkit requires **Client Credentials (OAuth 2.0)**:

| Type | Grant Flow | Use Case | Toolkit Needs This? |
|------|-----------|----------|---------------------|
| **Personal Access Token (PAT)** | Client Credentials (`client_credentials`) | Service accounts, automation, scripts. Token is tied to the creating user's identity and permissions. | **YES -- use this one** |
| **Authorization Code (PKCE)** | Authorization Code + PKCE | Interactive browser-based apps where a user logs in. Requires redirect URI and user interaction. | No -- the toolkit authenticates non-interactively |

**The toolkit uses the `client_credentials` grant type.** In ISC, this is created as a **Personal Access Token (PAT)**, which generates a Client ID + Client Secret pair. Despite the name "Personal Access Token," this is the standard OAuth 2.0 client_credentials flow -- SailPoint just labels it as a PAT in the admin UI.

---

## Step 2: Create the API Client (PAT)

1. Log into your ISC sandbox admin console: `https://<tenant>-sb.identitynow.com`
2. Navigate to: **Admin** > **Preferences** > **Personal Access Tokens**
   - Alternative path (if you have ORG_ADMIN): **Admin** > **Global** > **Security Settings** > **API Management**
3. Click **Create Token** (or **New**)
4. Fill in the fields below

### Recommended API Client Name

```
svc-governance-toolkit-sandbox
```

Naming convention rationale:
- `svc-` prefix identifies it as a service/automation credential (not a human user)
- `governance-toolkit` matches the tool name
- `-sandbox` clarifies the environment (swap to `-prod` for production)

### Client Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| **Name** | `svc-governance-toolkit-sandbox` | Descriptive, environment-tagged |
| **Description** | `OAuth client for SailPoint Governance Toolkit - campaign testing, audit reporting, and certification management` | |
| **Owner** | Your admin identity | The PAT inherits this identity's permissions. Must have CERT_ADMIN or ORG_ADMIN role. |
| **Scope** | See Step 3 below | |

### Important: PAT Permissions

The PAT inherits the **permissions of the identity that creates it**. This means:
- If you create the PAT while logged in as an ORG_ADMIN, the token can do anything
- If you create it as a CERT_ADMIN, the token can manage campaigns and certifications (which is all the toolkit needs)
- The scope field further restricts what the token can access within those permissions

---

## Step 3: Required API Scopes

The Governance Toolkit uses these ISC v3 API endpoints:

### API Endpoint Inventory

| Module | Method | Endpoint | Purpose |
|--------|--------|----------|---------|
| SP.Campaigns | POST | `/v3/campaigns` | Create certification campaigns |
| SP.Campaigns | POST | `/v3/campaigns/{id}/activate` | Activate staged campaigns |
| SP.Campaigns | GET | `/v3/campaigns/{id}` | Get campaign by ID (+ status polling) |
| SP.Campaigns | GET | `/v3/campaigns` | List/search campaigns (with filters) |
| SP.Campaigns | POST | `/v3/campaigns/{id}/complete` | Complete past-due campaigns (safety-guarded) |
| SP.Certifications | GET | `/v3/certifications` | List certifications by campaign |
| SP.Certifications | GET | `/v3/certifications/{id}/access-review-items` | Get review items per certification |
| SP.Decisions | POST | `/v3/certifications/{id}/decide` | Submit bulk approve/revoke decisions |
| SP.Decisions | POST | `/v3/certifications/{id}/reassign` | Reassign review items (sync) |
| SP.Decisions | POST | `/v3/certifications/{id}/reassign-async` | Reassign review items (async) |
| SP.Decisions | POST | `/v3/certifications/{id}/sign-off` | Sign off completed certification |
| SP.AuditQueries | GET | `/v3/campaigns/{id}/reports` | List available campaign reports |
| SP.AuditQueries | GET | `/v3/reports/{id}` | Download campaign report CSV |
| SP.AuditQueries | GET | `/v3/sources/{id}` | Resolve source ID to display name |
| Legacy fallback | GET | `/cc/api/report/get/{id}?format=csv` | Legacy report download (if v3 fails) |

### Endpoint-to-Scope Mapping

ISC PAT scopes use granular strings (not role names). Here is the exact mapping for every endpoint the toolkit calls:

**Campaigns & Certifications (`idn:` namespace):**

| Endpoint | Method | Required Scope |
|----------|--------|----------------|
| `/v3/campaigns` | GET | `idn:campaign:read` or `idn:campaign:manage` |
| `/v3/campaigns/{id}` | GET | `idn:campaign:read` or `idn:campaign:manage` |
| `/v3/campaigns` | POST | `idn:campaign:manage` |
| `/v3/campaigns/{id}/activate` | POST | `idn:campaign:manage` |
| `/v3/campaigns/{id}/complete` | POST | `idn:campaign:manage` |
| `/v3/campaigns/{id}/reports` | GET | `idn:campaign-report:read` or `idn:campaign-report:manage` |
| `/v3/certifications` | GET | `idn:campaign:read` |
| `/v3/certifications/{id}/access-review-items` | GET | `idn:campaign:read` |
| `/v3/certifications/{id}/decide` | POST | `idn:campaign:manage` |
| `/v3/certifications/{id}/reassign` | POST | `idn:campaign:manage` |
| `/v3/certifications/{id}/reassign-async` | POST | `idn:campaign:manage` |
| `/v3/certifications/{id}/sign-off` | POST | `idn:campaign:manage` |

**Reports (`sp:` namespace):**

| Endpoint | Method | Required Scope |
|----------|--------|----------------|
| `/v3/reports/{id}` | GET | `sp:report:read` or `sp:report:manage` |

**Sources (`idn:` namespace):**

| Endpoint | Method | Required Scope |
|----------|--------|----------------|
| `/v3/sources/{id}` | GET | `idn:sources:read` or `idn:sources:manage` |

**Legacy (uses bearer token, no separate scope):**

| Endpoint | Method | Notes |
|----------|--------|-------|
| `/cc/api/report/get/{id}?format=csv` | GET | Fallback only; uses same bearer token |

### Recommended Scope: Sandbox (Full Toolkit)

Select these 4 scopes when creating the PAT. This covers all toolkit operations (read + write):

```
idn:campaign:manage
idn:campaign-report:manage
sp:report:manage
idn:sources:read
```

Note: `idn:campaign:manage` is a superset of `idn:campaign:read` -- you do not need both.

### Recommended Scope: Read-Only Audit (No Campaign Creation)

If you only need to query and audit existing campaigns (no create/activate/decide):

```
idn:campaign:read
idn:campaign-report:read
sp:report:read
idn:sources:read
```

### Catch-All (Quick and Dirty)

For a sandbox where you don't care about least-privilege:

```
sp:scopes:all
```

This grants full API access within the creating user's permission level. Fine for sandbox, not recommended for production.

---

## Step 4: Record the Credentials

After creating the API client, ISC displays the **Client ID** and **Client Secret** once. Copy both immediately.

```
Client ID:     <copy this -- looks like a UUID>
Client Secret: <copy this -- shown only once, cannot be retrieved later>
```

If you lose the secret, you must delete the API client and create a new one.

---

## Step 5: Identify Your Tenant URLs

For a sandbox tenant named `acme-sb`, the URLs are:

| Setting | URL Pattern | Example |
|---------|-------------|---------|
| **Tenant URL** | `https://<tenant>.api.identitynow.com` | `https://acme-sb.api.identitynow.com` |
| **OAuth Token URL** | `https://<tenant>.api.identitynow.com/oauth/token` | `https://acme-sb.api.identitynow.com/oauth/token` |
| **API Base URL** | `https://<tenant>.api.identitynow.com/v3` | `https://acme-sb.api.identitynow.com/v3` |
| **Admin Console** | `https://<tenant>.identitynow.com` | `https://acme-sb.identitynow.com` |

**Note:** The token URL, API base URL, and tenant URL all use `api.identitynow.com`. Only the admin console UI uses `identitynow.com` without the `api.` prefix.

---

## Step 6: Configure the Governance Toolkit

### Option A: Direct Configuration (Quick Start)

Edit `Config\settings.json`:

```json
{
    "Global": {
        "EnvironmentName": "Sandbox",
        "DebugMode": false,
        "ToolkitVersion": "1.0.0"
    },
    "Authentication": {
        "Mode": "ConfigFile",
        "ConfigFile": {
            "TenantUrl": "https://acme-sb.api.identitynow.com",
            "OAuthTokenUrl": "https://acme-sb.api.identitynow.com/oauth/token",
            "ClientId": "<your-client-id>",
            "ClientSecret": "<your-client-secret>"
        }
    },
    "Api": {
        "BaseUrl": "https://acme-sb.api.identitynow.com/v3",
        "TimeoutSeconds": 60,
        "RetryCount": 3,
        "RetryDelaySeconds": 5,
        "RateLimitRequestsPerWindow": 95,
        "RateLimitWindowSeconds": 10
    }
}
```

### Option B: Encrypted Vault (Recommended for Shared Environments)

```powershell
# 1. Create the vault
.\Scripts\New-SPVault.ps1 -ClientId '<your-client-id>'
# Prompts for: vault passphrase, client secret

# 2. Update settings.json
# Set Authentication.Mode = "Vault"
```

### Option C: Browser Token (No API Client Needed)

If you just want to run a quick audit without creating an API client:

```powershell
# 1. Log into ISC sandbox admin console in your browser
# 2. Open dev tools (F12) > Network tab
# 3. Click any action, copy the Authorization header value
# 4. Run:
.\Scripts\Invoke-SPCampaignAudit.ps1 -Token 'eyJhbGciOiJSUzI1NiIs...' -Status COMPLETED -DaysBack 7
```

This uses your existing browser session. Token expires in ~12 minutes.

---

## Step 7: Verify Connectivity

```powershell
.\Scripts\Test-SPConnectivity.ps1
```

Expected output (3 PASS steps):

```
Step 1: Load and validate settings.json ............. PASS
Step 2: Acquire OAuth 2.0 bearer token .............. PASS
Step 3: GET /v3/campaigns?limit=1 (live API) ........ PASS

Connected to Sandbox - All checks passed
```

If Step 2 fails: verify your Client ID, Client Secret, and OAuth Token URL.
If Step 3 fails: verify your API Base URL (must include `/v3`).

---

## Step 8: Run a Smoke Test

```powershell
# Dry run (no API calls, validates CSV data only)
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf

# Quick audit query (read-only, safe to run in any environment)
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30
```

---

## Security Reminders

| Control | Setting | Notes |
|---------|---------|-------|
| **Never commit secrets** | `settings.json` is in `.gitignore` | Client secret is plaintext in ConfigFile mode |
| **Use Vault for shared envs** | `Authentication.Mode = "Vault"` | AES-256-CBC encrypted, passphrase never on disk |
| **Safety guards are ON** | `Safety.AllowCompleteCampaign = false` | Prevents accidental campaign completion |
| **WhatIf on prod** | `Safety.RequireWhatIfOnProd = true` | Forces confirmation before running against production |
| **No DELETE operations** | N/A | The toolkit never calls DELETE endpoints |
| **Rate limiting built in** | 95 req/10s with automatic backoff | Matches ISC's documented rate limit |

---

## API Client Lifecycle

| Action | When |
|--------|------|
| **Rotate secret** | Every 90 days or per your org's policy. Delete and recreate the API client. |
| **Revoke access** | When testing is complete and the sandbox is being decommissioned. Delete the API client from Security Settings. |
| **Promote to prod** | Create a separate API client (`svc-governance-toolkit-prod`) in the production tenant. Never reuse sandbox credentials. |

---

## Naming Convention for Multiple Environments

| Environment | API Client Name |
|-------------|-----------------|
| Sandbox | `svc-governance-toolkit-sandbox` |
| Development | `svc-governance-toolkit-dev` |
| UAT | `svc-governance-toolkit-uat` |
| Production | `svc-governance-toolkit-prod` |
