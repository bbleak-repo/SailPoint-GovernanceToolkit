#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit Authentication Module
.DESCRIPTION
    Provides authentication for SailPoint ISC. Supports five modes:
      - ConfigFile:      ClientId/ClientSecret read directly from settings.json
      - Vault:           ClientId/ClientSecret retrieved from encrypted SP.Vault
      - BrowserToken:    Pre-obtained JWT pasted from browser dev tools (no OAuth flow)
      - DpapiCredential: PSCredential encrypted via Windows DPAPI (Export-CliXml).
                         Bound to the current Windows user + machine. If the credential
                         file is copied to another machine or user context, decryption
                         fails. Risk: Mimikatz / credential-dumping tools can extract
                         DPAPI master keys. EDR systems may flag DPAPI operations in
                         non-interactive sessions.
      - ScheduledVault:  Uses the toolkit's own AES-256-CBC + PBKDF2 encryption (same
                         crypto as SP.Vault) to store the vault passphrase encrypted
                         with a machine-derived key (SHA-256 of machine name + username
                         + domain + static salt). No DPAPI involvement -- no Mimikatz
                         or EDR concerns. Requires the regular Vault to be set up first;
                         this mode automates the passphrase entry for unattended execution.

    OAuth modes use client_credentials grant. Token is cached with a 5-minute
    expiry buffer.

    Browser token mode is useful for quick one-off queries when you are already
    logged into the ISC admin console. Open browser dev tools (F12), go to the
    Network tab, copy the Authorization header value from any API call, and pass
    the JWT to Set-SPBrowserToken. ISC browser tokens are typically valid for
    ~12 minutes (720 seconds).
.NOTES
    Module: SP.Auth
    Version: 1.2.0
#>

# --- Ensure modern TLS for the OAuth token call to ISC ---
# Windows PowerShell 5.1 / .NET can negotiate TLS 1.0 by default, which modern
# SailPoint ISC tenants reject. The token request is the first real-tenant call,
# so enable TLS 1.2 (and 1.3 when supported) here without downgrading anything.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
    }
} catch { }

# Script-scoped variables (module-scope cache -- cleared on each fresh module import)
$script:CurrentToken = $null
$script:TokenExpiry  = $null

# AppDomain-wide static token cache -- survives background STA runspace imports.
# In the same powershell.exe process every runspace shares the AppDomain, so a
# static .NET type defined here is accessible from all runspaces. This is the only
# reliable way to share an acquired vault token with background runspaces: they
# cannot call Read-Host (no interactive host), so they read the pre-acquired token
# from this cache instead of re-prompting for the vault passphrase.
# The try/catch handles re-imports in background runspaces where the type already
# exists in the AppDomain -- Add-Type throws on duplicate, but the existing instance
# (and its stored token) is exactly what we want to reuse.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
public static class SPAuthRunspaceCache {
    public static readonly ConcurrentDictionary<string, object> Store =
        new ConcurrentDictionary<string, object>(StringComparer.Ordinal);
}
'@
} catch { }  # Type already defined in this AppDomain -- reuse the existing instance.

# ---------------------------------------------------------------------------
# SPApiRateLimiter: AppDomain-static cross-runspace rate limiter.
#
# Problem: SP.ApiClient's $script:RequestTimestamps is per-scope, so each GUI
# background STA runspace has an independent counter.  When several operations
# run simultaneously (e.g. Hierarchical Report + Delta Cert Escalation + Health
# Check) their individual counters never exceed 95/10s, but ISC sees the
# aggregate traffic and returns 429.
#
# Fix: a thread-safe sliding-window queue shared across ALL runspaces in the
# same powershell.exe process (AppDomain). SP.ApiClient calls WaitForSlot()
# before every ISC request. The existing per-scope limiter remains as a
# belt-and-suspenders guard for single-runspace CLI scenarios.
#
# Architecture note: separate from SPAuthRunspaceCache by design -- different
# access semantics (token = rarely-changing singleton; rate limit = updated on
# every API call with time-based eviction). Mixing them would obscure intent.
#
# The try/catch handles the common case of a background runspace reimporting
# this module after the type is already compiled in the AppDomain.
# ---------------------------------------------------------------------------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Threading;

public static class SPApiRateLimiter {

    private static readonly Queue<long> _timestamps = new Queue<long>();
    private static readonly object      _lock       = new object();
    private static int  _maxRequests = 95;
    private static int  _windowMs    = 10000;
    private static bool _enabled     = true;

    // Called once by SP.ApiClient at first use, using RateLimitRequestsPerWindow
    // and RateLimitWindowSeconds from settings.json.
    public static void Configure(int maxRequests, int windowSeconds, bool enabled) {
        lock (_lock) {
            if (maxRequests > 0)   _maxRequests = maxRequests;
            if (windowSeconds > 0) _windowMs    = windowSeconds * 1000;
            _enabled = enabled;
        }
    }

    // Called before every Invoke-RestMethod in Invoke-SPApiRequest.
    // Blocks the calling runspace thread until a slot is available in the
    // current window, then records the call timestamp and returns.
    // Thread-safe: the lock is held only for the check; sleeping happens outside.
    public static void WaitForSlot() {
        if (!_enabled) return;

        while (true) {
            long sleepMs = 0;
            lock (_lock) {
                long nowMs       = DateTime.UtcNow.Ticks / 10000L;
                long windowStart = nowMs - _windowMs;

                // Evict timestamps older than the window
                while (_timestamps.Count > 0 && _timestamps.Peek() < windowStart) {
                    _timestamps.Dequeue();
                }

                if (_timestamps.Count < _maxRequests) {
                    _timestamps.Enqueue(nowMs);
                    return; // slot acquired -- proceed with the API call
                }

                // Window saturated: calculate sleep duration and release the lock
                long oldestMs = _timestamps.Peek();
                sleepMs = (_windowMs - (nowMs - oldestMs)) + 5L; // +5ms buffer
                if (sleepMs < 1L) sleepMs = 1L;
            }
            // Sleep outside the lock so other runspaces can check while we wait
            Thread.Sleep((int)sleepMs);
        }
    }

    // Reset visible to tests and admin/reset tooling.
    public static void Reset() {
        lock (_lock) { _timestamps.Clear(); }
    }
}
'@
} catch { }  # Type already defined -- reuse the existing instance.

#region Internal Functions

function Get-SPCredentialsFromConfig {
    <#
    .SYNOPSIS
        Reads ClientId and ClientSecret from the ConfigFile authentication section
    .OUTPUTS
        [hashtable] @{ClientId=[string]; ClientSecret=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    $config     = Get-SPConfig
    $cfgSection = $config.Authentication.ConfigFile

    if ([string]::IsNullOrWhiteSpace($cfgSection.ClientId)) {
        throw 'Authentication.ConfigFile.ClientId is not configured in settings.json'
    }
    if ([string]::IsNullOrWhiteSpace($cfgSection.ClientSecret)) {
        throw 'Authentication.ConfigFile.ClientSecret is not configured in settings.json'
    }

    Write-SPLog -Message 'Read credentials from ConfigFile mode' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    return @{
        ClientId      = $cfgSection.ClientId
        ClientSecret  = $cfgSection.ClientSecret
        OAuthTokenUrl = $cfgSection.OAuthTokenUrl
    }
}

function Get-SPCredentialsFromVault {
    <#
    .SYNOPSIS
        Retrieves ClientId and ClientSecret from the encrypted vault
    .OUTPUTS
        [hashtable] @{ClientId=[string]; ClientSecret=[string]; OAuthTokenUrl=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    $config       = Get-SPConfig
    $vaultSection = $config.Authentication.Vault
    $cfgSection   = $config.Authentication.ConfigFile

    if ([string]::IsNullOrWhiteSpace($vaultSection.VaultPath)) {
        throw 'Authentication.Vault.VaultPath is not configured in settings.json'
    }

    # Resolve VaultPath to an absolute path anchored at the toolkit root.
    # The raw config value is often a relative path (e.g. ".\Data\sp-vault.enc").
    # [System.IO.File]::ReadAllBytes() resolves relative paths from the .NET
    # process working directory (Environment.CurrentDirectory), which is
    # C:\Windows\System32 when PowerShell is launched from a system context --
    # not the toolkit root. Using PSScriptRoot (Modules\SP.Core\) + two levels
    # up gives the toolkit root regardless of how or where PowerShell was started.
    $vaultPath = [string]$vaultSection.VaultPath
    if (-not [System.IO.Path]::IsPathRooted($vaultPath)) {
        $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $vaultPath   = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot (($vaultPath -replace '^\.[\\/]', ''))))
    }

    if (-not (Test-Path -LiteralPath $vaultPath -PathType Leaf)) {
        throw ("Vault file not found at '$vaultPath'. " +
               "Run New-SPVault.ps1 to create it, or set Authentication.Vault.VaultPath " +
               "to an absolute path in Config\settings.local.json.")
    }

    # Prompt for vault passphrase at runtime.
    # In a background STA runspace Read-Host throws "host does not support user
    # interaction." If this happens it means the cross-runspace static cache was
    # empty (token not yet acquired or already expired). The pre-warm block in
    # Show-SPDashboard.ps1 prevents this on startup; a session expiry during a
    # long run requires clicking any action to re-authenticate.
    $passphrase = $null
    try {
        $passphrase = Read-Host -Prompt 'Enter vault passphrase' -AsSecureString
    } catch {
        throw ("Vault passphrase cannot be collected in this context (background runspace). " +
               "This usually means the session token has expired. " +
               "Click any action button in the dashboard to re-authenticate, or restart the dashboard.")
    }

    Write-SPLog -Message 'Retrieving credentials from vault' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    $result = Get-SPVaultCredential `
        -VaultPath    $vaultPath `
        -Passphrase   $passphrase `
        -Key          $vaultSection.CredentialKey

    $passphrase.Dispose()

    if (-not $result.Success) {
        throw "Failed to retrieve credentials from vault: $($result.Error)"
    }

    return @{
        ClientId      = $result.Data.ClientId
        ClientSecret  = $result.Data.ClientSecret
        OAuthTokenUrl = $cfgSection.OAuthTokenUrl
    }
}

function Get-SPCredentialsFromDpapi {
    <#
    .SYNOPSIS
        Retrieves ClientId and ClientSecret from a DPAPI-encrypted PSCredential file
    .DESCRIPTION
        Reads a PSCredential object from an Export-CliXml file encrypted with Windows
        DPAPI. The credential is bound to the Windows user and machine that created it.
        If the file is copied to another machine or user context, Import-CliXml will
        fail with a cryptographic exception.

        Security notes:
        - Uses Windows DPAPI via Export-CliXml / Import-CliXml
        - Encrypted to: current Windows user + current machine
        - Risk: Mimikatz / credential-dumping tools can extract DPAPI master keys
        - EDR systems may flag DPAPI operations in non-interactive sessions
    .OUTPUTS
        [hashtable] @{ClientId=[string]; ClientSecret=[string]; OAuthTokenUrl=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    $config = Get-SPConfig
    $credPath = $config.Authentication.DpapiCredential.Path

    if ([string]::IsNullOrWhiteSpace($credPath)) {
        throw 'Authentication.DpapiCredential.Path is not configured in settings.json'
    }

    # Resolve relative paths to toolkit root
    if (-not [System.IO.Path]::IsPathRooted($credPath)) {
        $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $credPath = [System.IO.Path]::GetFullPath(
            (Join-Path $toolkitRoot (($credPath -replace '^\.[\\/]', '')))
        )
    }

    if (-not (Test-Path -LiteralPath $credPath -PathType Leaf)) {
        throw "DPAPI credential file not found: $credPath. Run New-SPVault.ps1 -Mode DpapiCredential to create it."
    }

    $cred = Import-Clixml -Path $credPath

    if ($null -eq $cred -or $cred -isnot [System.Management.Automation.PSCredential]) {
        throw "DPAPI credential file at '$credPath' does not contain a valid PSCredential object."
    }

    $oauthUrl = $config.Authentication.ConfigFile.OAuthTokenUrl

    Write-SPLog -Message 'Read credentials from DpapiCredential mode' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    return @{
        ClientId      = $cred.UserName
        ClientSecret  = $cred.GetNetworkCredential().Password
        OAuthTokenUrl = $oauthUrl
    }
}

function Get-SPScheduledVaultSecret {
    <#
    .SYNOPSIS
        Returns the per-install random secret (base64) that strengthens the ScheduledVault
        machine-derived passphrase so it is NOT derivable from public machine/user/domain values.
    .DESCRIPTION
        On first use this generates a 256-bit cryptographically-random secret and persists it under
        one of two protection modes. The secret FILE is self-describing (a 5-byte header: 'SVK1' +
        a mode byte), so read-back never depends on config matching the file. The file is ACL-locked
        to the current user in BOTH modes. Subsequent calls read it back.

          Dpapi   (recommended) -- the random secret is DPAPI-protected (CurrentUser). It cannot be
                  decrypted off the originating box/user even if every file is copied. Strongest; the
                  ProtectedData calls may be visible to EDR/SOC.
          AclFile (EDR-quiet)   -- the random secret is stored as a raw blob in an NTFS-ACL-locked
                  file (NO DPAPI). Removes the "derivable from public/repo values" weakness, but an
                  attacker who can READ the secret file could decrypt off-box. No EDR noise.

        Both are far stronger than the legacy public-only derivation. Prefer Dpapi unless an EDR/SOC
        constraint requires AclFile. Deleting the secret invalidates any existing ScheduledVault key
        (re-run New-SPVault.ps1 -Mode ScheduledVault). In Dpapi mode a different user/machine cannot read it.
    .PARAMETER SecretPath
        Override the secret file location (testing). Defaults to Data\.sv-secret.
    .PARAMETER KeyProtection
        Protection mode used WHEN CREATING the secret: 'Dpapi' (default) or 'AclFile'. Ignored when
        the secret already exists (the file is self-describing). When omitted, reads
        Authentication.ScheduledVault.KeyProtection from config, falling back to 'Dpapi'.
    .OUTPUTS
        [string] base64-encoded 256-bit secret.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$SecretPath,

        [Parameter()]
        [ValidateSet('Dpapi', 'AclFile')]
        [string]$KeyProtection
    )

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($SecretPath)) {
        $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $SecretPath  = Join-Path (Join-Path $toolkitRoot 'Data') '.sv-secret'
    }
    $dataDir = Split-Path -Parent $SecretPath
    $scope   = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    $magic   = [byte[]](0x53, 0x56, 0x4B, 0x31)   # 'SVK1'

    # ---- READ (self-describing): the file knows how it was protected. ----
    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllBytes($SecretPath)
            if ($raw.Length -ge 5 -and $raw[0] -eq $magic[0] -and $raw[1] -eq $magic[1] -and
                $raw[2] -eq $magic[2] -and $raw[3] -eq $magic[3]) {
                $mode    = [char]$raw[4]
                $payload = New-Object byte[] ($raw.Length - 5)
                [Array]::Copy($raw, 5, $payload, 0, $payload.Length)
                if ($mode -eq 'D') {
                    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($payload, $null, $scope)
                    return [Convert]::ToBase64String($plain)
                }
                elseif ($mode -eq 'A') {
                    return [Convert]::ToBase64String($payload)   # raw secret; protected at rest by the file ACL
                }
                else { throw "Unknown ScheduledVault secret mode '$mode'." }
            }
            # Legacy (pre-format) file: the whole file is a DPAPI blob.
            $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($raw, $null, $scope)
            return [Convert]::ToBase64String($plain)
        }
        catch {
            throw ("Failed to read the ScheduledVault per-install secret ($SecretPath). For DPAPI mode " +
                   "it can only be decrypted by the user/machine that created it. Re-run " +
                   "New-SPVault.ps1 -Mode ScheduledVault as the scheduled-task account. Error: $($_.Exception.Message)")
        }
    }

    # ---- CREATE: resolve the protection mode (param -> config -> Dpapi). ----
    if ([string]::IsNullOrWhiteSpace($KeyProtection)) {
        $KeyProtection = 'Dpapi'
        try {
            $cfg = Get-SPConfig
            if ($null -ne $cfg.PSObject.Properties['Authentication'] -and
                $null -ne $cfg.Authentication.PSObject.Properties['ScheduledVault'] -and
                $null -ne $cfg.Authentication.ScheduledVault.PSObject.Properties['KeyProtection']) {
                $cand = [string]$cfg.Authentication.ScheduledVault.KeyProtection
                if ($cand -in @('Dpapi', 'AclFile')) { $KeyProtection = $cand }
            }
        } catch { }
    }

    if (-not (Test-Path -LiteralPath $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force -WhatIf:$false | Out-Null
    }
    $bytes = New-Object byte[] 32
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    if ($KeyProtection -eq 'AclFile') {
        $modeByte = [byte][char]'A'
        $payload  = $bytes
    }
    else {
        $modeByte = [byte][char]'D'
        $payload  = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
    }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.AddRange($magic); $out.Add($modeByte); $out.AddRange($payload)
    [System.IO.File]::WriteAllBytes($SecretPath, $out.ToArray())

    # ACL-lock to the current user (primary protection for AclFile; defense-in-depth for Dpapi).
    try {
        $acl = Get-Acl -LiteralPath $SecretPath
        $acl.SetAccessRuleProtection($true, $false)
        $me  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $SecretPath -AclObject $acl
    } catch { }

    return [Convert]::ToBase64String($bytes)
}

function Get-SPMachineDerivedPassphrase {
    <#
    .SYNOPSIS
        Generates a passphrase from machine identifiers + a per-install DPAPI-protected secret
    .DESCRIPTION
        Combines the machine name, username, domain name, a static salt, AND a per-install random
        secret (see Get-SPScheduledVaultSecret), then computes SHA-256 to produce a 64-character
        hex string used to encrypt/decrypt the vault passphrase in ScheduledVault mode.

        SECURITY: the per-install secret is what makes this key non-derivable. It is a 256-bit
        random value stored DPAPI-protected (CurrentUser), so the passphrase CANNOT be
        reconstructed from the (public) machine/user/domain values alone, and CANNOT be decrypted
        off the originating box/user even if every key/vault/secret file is exfiltrated. Without
        the secret-mixing the key would be fully derivable from public information -- do not remove it.

        The passphrase is bound to the machine + user that created the secret; moving the files to
        another machine or running as a different user causes decryption to fail (by design). For
        the simplest secure unattended mode, prefer DpapiCredential.
    .OUTPUTS
        [string] 64-character lowercase hex string
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Override the per-install secret file location (testing). Defaults to Data\.sv-secret.
        [Parameter()]
        [string]$SecretPath,

        # Protection mode used when the secret is first created: 'Dpapi' (default) or 'AclFile'.
        [Parameter()]
        [ValidateSet('Dpapi', 'AclFile')]
        [string]$KeyProtection
    )

    $machineName   = [Environment]::MachineName
    $userName      = [Environment]::UserName
    $domainName    = [Environment]::UserDomainName
    $staticSalt    = 'SailPoint-GovernanceToolkit-ScheduledVault-v1'
    # Per-install, DPAPI-protected random secret -- this is what makes the derived key
    # non-derivable from the (public) machine/user/domain values. Do not remove.
    $svArgs = @{}
    if (-not [string]::IsNullOrWhiteSpace($SecretPath))    { $svArgs['SecretPath']    = $SecretPath }
    if (-not [string]::IsNullOrWhiteSpace($KeyProtection)) { $svArgs['KeyProtection'] = $KeyProtection }
    $installSecret = Get-SPScheduledVaultSecret @svArgs

    $combined = "$machineName|$userName|$domainName|$staticSalt|$installSecret"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined))
    }
    finally {
        $sha.Dispose()
    }

    # Return as hex string (64 chars) -- this becomes the passphrase for Invoke-SPVaultEncrypt
    return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-SPCredentialsFromScheduledVault {
    <#
    .SYNOPSIS
        Retrieves ClientId and ClientSecret from the vault using a machine-derived key
    .DESCRIPTION
        Reads an AES-encrypted vault passphrase from the ScheduledVault key file,
        decrypts it using a machine-derived passphrase (SHA-256 of machine + user +
        domain + static salt), then opens the regular vault with that passphrase to
        retrieve the stored credentials.

        This mode is designed for unattended scheduled task execution where no
        interactive passphrase prompt is possible.

        Security notes:
        - Uses the toolkit's own AES-256-CBC + PBKDF2 (same crypto as SP.Vault)
        - Key derived from: machine + user + domain + static salt + a per-install
          DPAPI-protected random secret (SHA-256). The secret is what makes the key
          non-derivable and prevents off-box offline decryption of an exfiltrated key file.
        - If the key/secret files are copied to another machine/user: decryption fails
        - Requires the regular vault to be set up first
        - For the simplest secure unattended mode, prefer DpapiCredential
    .OUTPUTS
        [hashtable] @{ClientId=[string]; ClientSecret=[string]; OAuthTokenUrl=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    $config = Get-SPConfig
    $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

    # --- Read the encrypted passphrase file ---
    $keyPath = $config.Authentication.ScheduledVault.KeyPath
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        throw 'Authentication.ScheduledVault.KeyPath is not configured in settings.json'
    }
    if (-not [System.IO.Path]::IsPathRooted($keyPath)) {
        $keyPath = [System.IO.Path]::GetFullPath(
            (Join-Path $toolkitRoot (($keyPath -replace '^\.[\\/]', '')))
        )
    }
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        throw "ScheduledVault key file not found: $keyPath. Run New-SPVault.ps1 -Mode ScheduledVault to create it."
    }

    $encBytes = [System.IO.File]::ReadAllBytes($keyPath)

    # --- Reconstruct the machine-derived passphrase ---
    $machinePassphrase = Get-SPMachineDerivedPassphrase

    # --- Decrypt the vault passphrase ---
    $passphraseBytes = $null
    $vaultPassphrase = $null
    try {
        $passphraseBytes = Invoke-SPVaultDecrypt -Data $encBytes -Passphrase $machinePassphrase
        $vaultPassphrase = [System.Text.Encoding]::UTF8.GetString($passphraseBytes)
    }
    catch {
        throw ("Failed to decrypt ScheduledVault key file. This usually means the file " +
               "was created on a different machine or by a different user. Error: $($_.Exception.Message)")
    }

    # --- Open the regular vault with the decrypted passphrase ---
    $vaultPath = $config.Authentication.Vault.VaultPath
    if ([string]::IsNullOrWhiteSpace($vaultPath)) {
        throw 'Authentication.Vault.VaultPath is not configured in settings.json (required by ScheduledVault mode)'
    }
    if (-not [System.IO.Path]::IsPathRooted($vaultPath)) {
        $vaultPath = [System.IO.Path]::GetFullPath(
            (Join-Path $toolkitRoot (($vaultPath -replace '^\.[\\/]', '')))
        )
    }
    if (-not (Test-Path -LiteralPath $vaultPath -PathType Leaf)) {
        throw "Vault file not found at '$vaultPath'. The regular vault must exist for ScheduledVault mode."
    }

    $vaultBytes = [System.IO.File]::ReadAllBytes($vaultPath)
    $plainBytes = $null
    try {
        $plainBytes = Invoke-SPVaultDecrypt -Data $vaultBytes -Passphrase $vaultPassphrase
    }
    catch {
        throw ("Failed to decrypt vault with the stored passphrase. The vault may have been " +
               "re-keyed since the ScheduledVault key was created. Run New-SPVault.ps1 " +
               "-Mode ScheduledVault again to update the key. Error: $($_.Exception.Message)")
    }

    $json  = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    $store = $json | ConvertFrom-Json

    $credKey = $config.Authentication.Vault.CredentialKey
    if (-not $credKey) { $credKey = 'sailpoint-isc' }

    $entry = $store.$credKey
    if ($null -eq $entry) {
        throw "Credential key '$credKey' not found in vault."
    }

    $oauthUrl = $config.Authentication.ConfigFile.OAuthTokenUrl

    # Zero sensitive data
    if ($null -ne $passphraseBytes) {
        for ($i = 0; $i -lt $passphraseBytes.Length; $i++) { $passphraseBytes[$i] = 0 }
    }
    $vaultPassphrase = $null
    $machinePassphrase = $null

    Write-SPLog -Message 'Read credentials from ScheduledVault mode' -Severity 'DEBUG' `
        -Component 'SP.Auth' -Action 'GetCredentials' -CorrelationID $CorrelationID

    return @{
        ClientId      = $entry.ClientId
        ClientSecret  = $entry.ClientSecret
        OAuthTokenUrl = $oauthUrl
    }
}

#endregion

#region Public Functions

function Get-SPAuthToken {
    <#
    .SYNOPSIS
        Acquires an OAuth 2.0 bearer token for SailPoint ISC API calls
    .DESCRIPTION
        Authenticates using client_credentials grant. Credential source is
        determined by Authentication.Mode in settings.json:
          - 'ConfigFile'      reads from Authentication.ConfigFile
          - 'Vault'           reads from SP.Vault using Authentication.Vault settings
          - 'DpapiCredential' reads from a DPAPI-encrypted PSCredential file (Windows only)
          - 'ScheduledVault'  reads from the vault using a machine-derived key (no DPAPI)
        Token is cached and reused until expiry minus 5-minute buffer.
        Returns a hashtable with Mode, Token, Headers, and ExpiresAt.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if not provided.
    .PARAMETER Force
        Force re-authentication even if a cached token is still valid.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=@{Mode; Token; Headers; ExpiresAt}; Error=[string]}
    .EXAMPLE
        $auth = Get-SPAuthToken
        if ($auth.Success) { Invoke-RestMethod -Headers $auth.Data.Headers -Uri $url }
    .EXAMPLE
        $auth = Get-SPAuthToken -Force -CorrelationID 'RUN-001'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$Force
    )

    try {
        # Generate correlation ID if not provided
        if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
            $CorrelationID = [guid]::NewGuid().ToString()
        }

        # 1. Check AppDomain-wide static cache first.
        #    Background STA runspaces cannot call Read-Host (no interactive host), so
        #    they must reuse a token acquired by the UI thread. The static cache is the
        #    only mechanism that crosses runspace module-scope boundaries within one
        #    powershell.exe process.
        #
        #    TENANT ISOLATION GUARD: The cache is keyed on 'TenantUrl'. If this
        #    toolkit instance is configured for a different ISC tenant than the
        #    cached token, the cache is cleared before re-authentication. This
        #    prevents silent credential bleed-over when two toolkit installations
        #    (e.g. prod and non-prod) are run from the same powershell.exe session.
        #    Separate processes (separate AppDomains) are always fully isolated;
        #    this guard covers the same-process corner case.
        if (-not $Force) {
            try {
                # Determine the configured tenant URL for this toolkit instance.
                # The config must be loaded HERE: the main `$config = Get-SPConfig`
                # assignment happens further down, AFTER the cache checks. This block
                # previously read the not-yet-assigned $config, so $configTenantUrl was
                # always '' -- the mismatch eviction below could never fire and
                # TenantUrl was never stored with the token (the guard was dead code).
                # (MERGE NOTE: the mac-validation branch fixed the same defect by
                # assigning $config early; this guard-local $guardConfig variant is
                # kept because it also repopulates TenantUrl on -Force acquisitions.)
                $configTenantUrl = ''
                $guardConfig = $null
                try { $guardConfig = Get-SPConfig } catch { }
                if ($null -ne $guardConfig -and
                    $null -ne $guardConfig.PSObject.Properties['Authentication'] -and
                    $null -ne $guardConfig.Authentication.PSObject.Properties['ConfigFile'] -and
                    $null -ne $guardConfig.Authentication.ConfigFile.PSObject.Properties['TenantUrl']) {
                    $configTenantUrl = [string]$guardConfig.Authentication.ConfigFile.TenantUrl
                }

                # If a cached token exists for a DIFFERENT tenant, evict it now
                $cachedTenantUrl = [SPAuthRunspaceCache]::Store['TenantUrl'] -as [string]
                if (-not [string]::IsNullOrWhiteSpace($cachedTenantUrl) -and
                    -not [string]::IsNullOrWhiteSpace($configTenantUrl) -and
                    $cachedTenantUrl -ne $configTenantUrl) {
                    Write-SPLog -Message "Tenant URL mismatch in auth cache (cached='$cachedTenantUrl' config='$configTenantUrl'). Clearing stale token to prevent cross-environment bleed." `
                        -Severity 'WARN' -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID
                    [SPAuthRunspaceCache]::Store.Clear()
                    $script:CurrentToken = $null
                    $script:TokenExpiry  = $null
                }
                else {
                    $xToken  = [SPAuthRunspaceCache]::Store['Token']     -as [string]
                    $xExpiry = [SPAuthRunspaceCache]::Store['ExpiresAt'] -as [datetime]
                    if (-not [string]::IsNullOrWhiteSpace($xToken) -and
                        $null -ne $xExpiry -and
                        $xExpiry -gt (Get-Date).AddMinutes(5)) {
                        $xMode = [string][SPAuthRunspaceCache]::Store['Mode']
                        $xData = @{
                            Mode      = $xMode
                            Token     = $xToken
                            Headers   = @{ 'Authorization' = "Bearer $xToken"; 'Content-Type' = 'application/json' }
                            ExpiresAt = $xExpiry
                        }
                        # Also warm the module-scope cache so repeated calls in this
                        # runspace don't re-hit the static dictionary.
                        $script:CurrentToken = $xData
                        $script:TokenExpiry  = $xExpiry
                        Write-SPLog -Message 'Using cross-runspace cached authentication token' -Severity 'DEBUG' `
                            -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID
                        return @{ Success = $true; Data = $xData; Error = $null }
                    }
                }
            } catch { }
        }

        # 2. Check module-scope cache (same runspace / session).
        if (-not $Force -and $null -ne $script:CurrentToken -and $null -ne $script:TokenExpiry) {
            if ($script:TokenExpiry -gt (Get-Date).AddMinutes(5)) {
                Write-SPLog -Message 'Using cached authentication token' -Severity 'DEBUG' `
                    -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID
                return @{ Success = $true; Data = $script:CurrentToken; Error = $null }
            }
        }

        Write-SPLog -Message 'Acquiring new OAuth 2.0 token' -Severity 'INFO' `
            -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID

        if ($null -eq $config) { $config = Get-SPConfig }
        $mode   = $config.Authentication.Mode

        # (Re)compute the tenant URL for the cache-store step at the bottom -- the
        # guard-scope value above is not populated on -Force calls, and storing
        # TenantUrl alongside the token is what arms the isolation guard.
        $configTenantUrl = ''
        if ($null -ne $config.PSObject.Properties['Authentication'] -and
            $null -ne $config.Authentication.PSObject.Properties['ConfigFile'] -and
            $null -ne $config.Authentication.ConfigFile.PSObject.Properties['TenantUrl']) {
            $configTenantUrl = [string]$config.Authentication.ConfigFile.TenantUrl
        }

        # Resolve credentials based on mode
        $creds = $null
        if ($mode -eq 'ConfigFile') {
            $creds = Get-SPCredentialsFromConfig -CorrelationID $CorrelationID
        }
        elseif ($mode -eq 'Vault') {
            $creds = Get-SPCredentialsFromVault -CorrelationID $CorrelationID
        }
        elseif ($mode -eq 'DpapiCredential') {
            $creds = Get-SPCredentialsFromDpapi -CorrelationID $CorrelationID
        }
        elseif ($mode -eq 'ScheduledVault') {
            $creds = Get-SPCredentialsFromScheduledVault -CorrelationID $CorrelationID
        }
        else {
            throw "Unknown Authentication.Mode '$mode'. Valid values: ConfigFile, Vault, DpapiCredential, ScheduledVault"
        }

        if ([string]::IsNullOrWhiteSpace($creds.OAuthTokenUrl)) {
            throw 'Authentication.ConfigFile.OAuthTokenUrl is not configured in settings.json'
        }

        # Build form body for client_credentials grant
        $body = 'grant_type=client_credentials' +
                '&client_id=' + [uri]::EscapeDataString($creds.ClientId) +
                '&client_secret=' + [uri]::EscapeDataString($creds.ClientSecret)

        $timeoutSeconds = 60
        if ($config.Api.TimeoutSeconds) { $timeoutSeconds = $config.Api.TimeoutSeconds }

        $response = Invoke-RestMethod `
            -Uri         $creds.OAuthTokenUrl `
            -Method      Post `
            -Body        $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -TimeoutSec  $timeoutSeconds `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($response.access_token)) {
            throw 'ISC OAuth response did not contain access_token'
        }

        $expiresIn = if ($response.expires_in) { [int]$response.expires_in } else { 749 }
        $expiresAt = (Get-Date).AddSeconds($expiresIn)

        $tokenData = @{
            Mode      = $mode
            Token     = $response.access_token
            Headers   = @{
                'Authorization' = "Bearer $($response.access_token)"
                'Content-Type'  = 'application/json'
            }
            ExpiresAt = $expiresAt
        }

        # Cache the token -- both module-scope (this runspace) and AppDomain-static
        # (all other runspaces in this process).
        # TenantUrl is stored alongside the token so the isolation guard (above)
        # can evict stale entries when the toolkit is switched to a different ISC
        # tenant within the same powershell.exe session.
        $script:CurrentToken = $tokenData
        $script:TokenExpiry  = $expiresAt
        try {
            [SPAuthRunspaceCache]::Store['Token']     = $response.access_token
            [SPAuthRunspaceCache]::Store['ExpiresAt'] = $expiresAt
            [SPAuthRunspaceCache]::Store['Mode']      = $mode
            if (-not [string]::IsNullOrWhiteSpace($configTenantUrl)) {
                [SPAuthRunspaceCache]::Store['TenantUrl'] = $configTenantUrl
            }
        } catch { }

        Write-SPLog -Message "OAuth 2.0 token acquired (mode: $mode, expires: $($expiresAt.ToString('yyyy-MM-ddTHH:mm:ssZ')))" `
            -Severity 'INFO' -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $tokenData; Error = $null }
    }
    catch {
        Write-SPLog -Message "Authentication failed: $($_.Exception.Message)" `
            -Severity 'ERROR' -Component 'SP.Auth' -Action 'GetAuthToken' -CorrelationID $CorrelationID

        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Set-SPBrowserToken {
    <#
    .SYNOPSIS
        Injects a pre-obtained browser JWT as the active authentication token.
    .DESCRIPTION
        Accepts a bearer token obtained from the ISC admin console browser session
        (via dev tools Network tab) and caches it as the active authentication token.
        Subsequent calls to Get-SPAuthToken will return this token until it expires
        or is cleared.

        ISC browser tokens are typically valid for ~12 minutes (720 seconds).
        The function sets a conservative default expiry of 10 minutes from injection
        to account for time elapsed between copying the token and pasting it.

        To obtain a token from the browser:
        1. Log into SailPoint ISC admin console
        2. Open browser dev tools (F12) > Network tab
        3. Click any action that triggers an API call
        4. Find the request, copy the Authorization header value
        5. Strip the "Bearer " prefix if present, paste the JWT
    .PARAMETER Token
        The JWT bearer token string. The "Bearer " prefix is stripped automatically
        if present.
    .PARAMETER ExpiryMinutes
        Minutes until the token is considered expired. Default: 10.
        Set higher if you just obtained a fresh token; lower if some time has passed.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=@{Mode; ExpiresAt}; Error=[string]}
    .EXAMPLE
        Set-SPBrowserToken -Token 'eyJhbGciOiJSUzI1NiIs...'
    .EXAMPLE
        Set-SPBrowserToken -Token 'Bearer eyJhbGciOiJSUzI1NiIs...' -ExpiryMinutes 5
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$ExpiryMinutes = 10,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # Strip "Bearer " prefix if present
        $jwt = $Token.Trim()
        if ($jwt.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) {
            $jwt = $jwt.Substring(7).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($jwt)) {
            throw 'Token is empty after stripping Bearer prefix.'
        }

        # Basic JWT structure validation (3 dot-separated segments)
        $segments = $jwt.Split('.')
        if ($segments.Count -ne 3) {
            throw "Token does not appear to be a valid JWT (expected 3 segments, got $($segments.Count))."
        }

        $expiresAt = (Get-Date).AddMinutes($ExpiryMinutes)

        $tokenData = @{
            Mode      = 'BrowserToken'
            Token     = $jwt
            Headers   = @{
                'Authorization' = "Bearer $jwt"
                'Content-Type'  = 'application/json'
            }
            ExpiresAt = $expiresAt
        }

        # Cache the token -- both module-scope and AppDomain-static.
        # Extract the ISC tenant URL from the JWT 'iss' claim so the isolation
        # guard can evict this entry when switching to a different tenant.
        $browserTenantUrl = ''
        try {
            # JWT segments are base64URL-encoded: map the URL-safe alphabet back to
            # standard base64 before padding, or FromBase64String throws on any
            # payload containing '-' / '_' (i.e. most real tokens).
            $payloadB64 = $segments[1].Replace('-', '+').Replace('_', '/')
            $payloadB64 = $payloadB64.PadRight((($payloadB64.Length + 3) -band -bnot 3), '=')
            $payloadJson = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String($payloadB64))
            $payloadObj  = $payloadJson | ConvertFrom-Json
            if ($null -ne $payloadObj.PSObject.Properties['iss']) {
                $browserTenantUrl = [string]$payloadObj.iss -replace '/oauth/token.*$','' -replace '/v3.*$',''
            }
        } catch { }

        $script:CurrentToken = $tokenData
        $script:TokenExpiry  = $expiresAt
        try {
            [SPAuthRunspaceCache]::Store['Token']     = $jwt
            [SPAuthRunspaceCache]::Store['ExpiresAt'] = $expiresAt
            [SPAuthRunspaceCache]::Store['Mode']      = 'BrowserToken'
            if (-not [string]::IsNullOrWhiteSpace($browserTenantUrl)) {
                [SPAuthRunspaceCache]::Store['TenantUrl'] = $browserTenantUrl
            }
        } catch { }

        Write-SPLog -Message "Browser token injected (expires: $($expiresAt.ToString('yyyy-MM-ddTHH:mm:ssZ')), segments: $($segments.Count))" `
            -Severity 'INFO' -Component 'SP.Auth' -Action 'SetBrowserToken' -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{ Mode = 'BrowserToken'; ExpiresAt = $expiresAt }
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Set-SPBrowserToken failed: $($_.Exception.Message)" `
            -Severity 'ERROR' -Component 'SP.Auth' -Action 'SetBrowserToken' -CorrelationID $CorrelationID

        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Clear-SPAuthToken {
    <#
    .SYNOPSIS
        Clears the cached authentication token from memory
    .DESCRIPTION
        Removes the cached token and expiry from script scope.
        Call when finished with API operations or on script exit.
    .EXAMPLE
        Clear-SPAuthToken
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:CurrentToken) {
        $script:CurrentToken.Token   = $null
        $script:CurrentToken.Headers = $null
        $script:CurrentToken         = $null
    }
    $script:TokenExpiry = $null

    # Also clear the AppDomain-static cross-runspace cache so background runspaces
    # don't serve a stale token after a 401 / explicit clear.
    # Note: after clearing, the NEXT Get-SPAuthToken call on the UI thread will
    # re-prompt for the vault passphrase and repopulate both caches.
    try {
        [SPAuthRunspaceCache]::Store.TryRemove('Token',     [ref]$null) | Out-Null
        [SPAuthRunspaceCache]::Store.TryRemove('ExpiresAt', [ref]$null) | Out-Null
        [SPAuthRunspaceCache]::Store.TryRemove('Mode',      [ref]$null) | Out-Null
        [SPAuthRunspaceCache]::Store.TryRemove('TenantUrl', [ref]$null) | Out-Null
    } catch { }

    [System.GC]::Collect()

    Write-SPLog -Message 'Cached auth token cleared from memory (module-scope + cross-runspace)' `
        -Severity 'DEBUG' -Component 'SP.Auth' -Action 'ClearToken'
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-SPAuthToken',
    'Set-SPBrowserToken',
    'Clear-SPAuthToken',
    'Get-SPMachineDerivedPassphrase',
    'Get-SPScheduledVaultSecret'
)
