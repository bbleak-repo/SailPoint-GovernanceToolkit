#Requires -Version 5.1
<#
.SYNOPSIS
    One-time interactive setup for the encrypted credential vault.
.DESCRIPTION
    Initializes the SailPoint ISC credential vault (AES-256-CBC + PBKDF2) and
    stores the ISC OAuth client credentials. Run once before using the toolkit
    with Vault authentication mode. Credentials are never written to disk in
    plain text.

    Supports three setup modes via the -Mode parameter:

    Vault (default):
      1. Load settings.json to determine the default vault path
      2. Prompt for vault passphrase (confirmed twice)
      3. Warn and confirm if vault file already exists (destructive)
      4. Initialize the encrypted vault file
      5. Prompt for ClientId and ClientSecret (or use -ClientId / -ClientSecret)
      6. Store credentials under the configured key (default: sailpoint-isc)
      7. Verify by reading credentials back from the vault

    DpapiCredential:
      Uses Windows DPAPI via Export-CliXml to store a PSCredential object
      encrypted to the current user + machine. Suitable for scheduled tasks
      running under a specific service account on Windows.

      Security: DPAPI-protected credentials may trigger EDR/Mimikatz alerts
      in some environments. The credential file can only be decrypted by the
      same user on the same machine that created it.

    ScheduledVault:
      Uses the toolkit's own AES-256-CBC encryption to encrypt the vault passphrase
      with a machine-derived key (SHA-256 of machine + user + domain + static salt +
      a per-install DPAPI-protected random secret). The secret makes the key
      non-derivable and prevents off-box offline decryption of an exfiltrated key file.
      For the simplest secure unattended mode, prefer DpapiCredential.

      Requires the regular Vault to be set up first. This mode automates the
      passphrase entry for unattended scheduled task execution.

.PARAMETER Mode
    Setup mode. Valid values: Vault, DpapiCredential, ScheduledVault.
    Default: Vault.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json.
.PARAMETER VaultPath
    Override the vault file path from settings.json. Optional.
.PARAMETER ClientId
    OAuth client ID. If omitted, prompted interactively. Used by Vault and
    DpapiCredential modes.
.PARAMETER ClientSecret
    OAuth client secret. If omitted, prompted interactively as SecureString.
    Used by Vault and DpapiCredential modes.
.EXAMPLE
    .\New-SPVault.ps1
    # Fully interactive Vault setup using settings.json defaults
.EXAMPLE
    .\New-SPVault.ps1 -Mode DpapiCredential
    # Set up DPAPI-encrypted credential file for scheduled tasks
.EXAMPLE
    .\New-SPVault.ps1 -Mode ScheduledVault
    # Set up machine-derived key for unattended vault access
.EXAMPLE
    .\New-SPVault.ps1 -ClientId 'abc123'
    # Pre-supply ClientId; ClientSecret will be prompted
.EXAMPLE
    .\New-SPVault.ps1 -WhatIf
    # Show what would happen without creating any files
.NOTES
    Script:  New-SPVault.ps1
    Version: 2.0.0
    Security: Passphrase is never logged or written to disk. Vault uses
              AES-256-CBC with PBKDF2 key derivation (600,000 iterations by
              default). Store the passphrase in a password manager.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateSet('Vault', 'DpapiCredential', 'ScheduledVault')]
    [string]$Mode = 'Vault',

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$VaultPath,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$ClientSecret,

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$toolkitRoot = Split-Path -Parent $scriptRoot

$coreModulePath = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'

if (Test-Path $coreModulePath) {
    Import-Module $coreModulePath -Force -ErrorAction Stop -DisableNameChecking
}
else {
    $moduleDir = Join-Path $toolkitRoot 'Modules\SP.Core'
    $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
    if ($psm1Files) {
        foreach ($psm1 in $psm1Files) {
            Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
        }
    }
    else {
        Write-Host "ERROR: SP.Core module not found at: $coreModulePath" -ForegroundColor Red
        exit 1
    }
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

# Resolve config path (honors settings.local.json override)
if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit - Credential Setup' -ForegroundColor Cyan
Write-Host "  Mode: $Mode" -ForegroundColor Cyan
Write-Host "  $('=' * 50)" -ForegroundColor DarkGray
Write-Host ''

# Load configuration
$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (Test-SPConfigFirstRun -Config $config) {
    # Informational only -- do NOT block. The vault is precisely where the
    # ClientSecret belongs, so creating it before settings.json is fully
    # populated is the expected flow. Blocking here was a chicken-and-egg:
    # you could not store the secret in the vault until it was already in
    # settings.json, which defeats the vault.
    Write-Host "  Note: settings.json still contains placeholder (CHANGE_ME) values." -ForegroundColor DarkYellow
    Write-Host "  That's fine -- store the OAuth ClientSecret in the vault now, then" -ForegroundColor DarkYellow
    Write-Host "  fill in TenantUrl / ClientId / Api.BaseUrl in settings.json afterward." -ForegroundColor DarkYellow
    Write-Host ''
}

# Initialize logging
try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
}
catch { }

Write-Host "  Environment: $($config.Global.EnvironmentName)" -ForegroundColor White
Write-Host ''

#endregion

# ---------------------------------------------------------------------------
# Mode dispatch: Vault | DpapiCredential | ScheduledVault
# ---------------------------------------------------------------------------

if ($Mode -eq 'Vault') {

    #region Vault Mode (existing behavior)

    # Resolve vault path
    if (-not $VaultPath) {
        $VaultPath = $config.Authentication.Vault.VaultPath
    }
    if (-not [System.IO.Path]::IsPathRooted($VaultPath)) {
        $VaultPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $VaultPath.TrimStart('.\').TrimStart('./')))
    }

    $credentialKey = $config.Authentication.Vault.CredentialKey
    if (-not $credentialKey) {
        $credentialKey = 'sailpoint-isc'
    }

    Write-Host "  Vault path    : $VaultPath" -ForegroundColor White
    Write-Host "  Credential key: $credentialKey" -ForegroundColor White
    Write-Host ''

    # WhatIf guard
    if ($WhatIfPreference) {
        Write-Host '  [WhatIf] The following actions would be performed:' -ForegroundColor Yellow
        Write-Host "    1. Initialize vault at: $VaultPath" -ForegroundColor Yellow
        Write-Host "    2. Store credentials under key: $credentialKey" -ForegroundColor Yellow
        Write-Host "    3. Verify credentials are readable" -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    # Check if vault already exists
    $vaultExists = Test-SPVaultExists -VaultPath $VaultPath

    if ($vaultExists) {
        Write-Host "  WARNING: A vault file already exists at:" -ForegroundColor Yellow
        Write-Host "  $VaultPath" -ForegroundColor Yellow
        Write-Host ''

        $target  = "Vault file at $VaultPath"
        $action  = "Overwrite existing vault (all stored credentials will be permanently deleted)"
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            Write-Host "  Vault setup cancelled. Existing vault preserved." -ForegroundColor Green
            exit 0
        }
        Write-Host ''
    }

    # Prompt for passphrase
    Write-Host '  Enter vault passphrase (minimum 12 characters):' -ForegroundColor White
    $passphrase1 = Read-Host -AsSecureString 'Passphrase'

    Write-Host '  Confirm vault passphrase:' -ForegroundColor White
    $passphrase2 = Read-Host -AsSecureString 'Confirm passphrase'

    # Compare passphrases by converting to plain text temporarily for comparison
    $ptr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passphrase1)
    $ptr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passphrase2)
    try {
        $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
        $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
        $passphraseMatch = ($plain1 -eq $plain2)
        $passphraseLength = $plain1.Length
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2)
        Remove-Variable plain1, plain2 -ErrorAction SilentlyContinue
    }

    if (-not $passphraseMatch) {
        Write-Host ''
        Write-Host "  ERROR: Passphrases do not match. Vault not created." -ForegroundColor Red
        exit 1
    }

    if ($passphraseLength -lt 12) {
        Write-Host ''
        Write-Host "  ERROR: Passphrase must be at least 12 characters. Vault not created." -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host "  Initializing vault..." -ForegroundColor Cyan

    $initResult = Initialize-SPVault -VaultPath $VaultPath -Passphrase $passphrase1
    if (-not $initResult.Success) {
        Write-Host "  ERROR: Failed to initialize vault: $($initResult.Error)" -ForegroundColor Red
        Write-SPLog -Message "Vault initialization failed: $($initResult.Error)" `
            -Severity ERROR -Component 'New-SPVault' -Action 'InitVault' -CorrelationID $correlationID
        exit 1
    }
    Write-Host "  Vault initialized successfully." -ForegroundColor Green

    # Credential Storage
    Write-Host ''
    Write-Host '  Enter SailPoint ISC OAuth credentials:' -ForegroundColor White

    # Collect ClientId
    if (-not $ClientId) {
        $ClientId = Read-Host 'ClientId'
    }
    else {
        Write-Host "  Using provided ClientId: $ClientId" -ForegroundColor DarkGray
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        Write-Host "  ERROR: ClientId cannot be empty." -ForegroundColor Red
        exit 1
    }

    # Collect ClientSecret
    $clientSecretSecure = $null
    if ($ClientSecret) {
        # Convert plain text param to SecureString
        $clientSecretSecure = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        Write-Host "  Using provided ClientSecret (from parameter)." -ForegroundColor DarkGray
    }
    else {
        $clientSecretSecure = Read-Host -AsSecureString 'ClientSecret'
    }

    # Verify secret is not empty
    $secretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecretSecure)
    try {
        $secretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)
        $secretEmpty = [string]::IsNullOrWhiteSpace($secretPlain)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)
        Remove-Variable secretPlain -ErrorAction SilentlyContinue
    }

    if ($secretEmpty) {
        Write-Host "  ERROR: ClientSecret cannot be empty." -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host "  Storing credentials under key '$credentialKey'..." -ForegroundColor Cyan

    # Convert SecureString to plain text for vault storage
    $secretPtr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecretSecure)
    try {
        $clientSecretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr2)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr2)
    }

    $storeResult = Set-SPVaultCredential `
        -VaultPath  $VaultPath `
        -Passphrase $passphrase1 `
        -Key        $credentialKey `
        -ClientId   $ClientId `
        -ClientSecret $clientSecretPlain

    # Zero plain text after use
    $clientSecretPlain = $null
    Remove-Variable clientSecretPlain -ErrorAction SilentlyContinue

    if (-not $storeResult.Success) {
        Write-Host "  ERROR: Failed to store credentials: $($storeResult.Error)" -ForegroundColor Red
        Write-SPLog -Message "Vault credential storage failed: $($storeResult.Error)" `
            -Severity ERROR -Component 'New-SPVault' -Action 'StoreCredential' -CorrelationID $correlationID
        exit 1
    }
    Write-Host "  Credentials stored successfully." -ForegroundColor Green

    # Verification
    Write-Host ''
    Write-Host "  Verifying stored credentials..." -ForegroundColor Cyan

    $verifyResult = Get-SPVaultCredential `
        -VaultPath  $VaultPath `
        -Passphrase $passphrase1 `
        -Key        $credentialKey

    if (-not $verifyResult.Success) {
        Write-Host "  ERROR: Verification failed - could not read credentials back: $($verifyResult.Error)" -ForegroundColor Red
        Write-SPLog -Message "Vault verification failed: $($verifyResult.Error)" `
            -Severity ERROR -Component 'New-SPVault' -Action 'VerifyCredential' -CorrelationID $correlationID
        exit 1
    }

    $storedClientId = $verifyResult.Data.ClientId
    if ($storedClientId -ne $ClientId) {
        Write-Host "  ERROR: Verification mismatch. Stored ClientId does not match input." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Verification passed. ClientId matches stored value." -ForegroundColor Green
    Write-Host ''
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray
    Write-Host '  Vault setup complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor White
    Write-Host "    1. Set Authentication.Mode = 'Vault' in settings.json" -ForegroundColor White
    Write-Host "    2. Confirm Authentication.Vault.VaultPath = '$VaultPath'" -ForegroundColor White
    Write-Host "    3. Run Test-SPConnectivity.ps1 to confirm OAuth works" -ForegroundColor White
    Write-Host ''

    Write-SPLog -Message "Vault setup completed successfully. Key: $credentialKey | VaultPath: $VaultPath" `
        -Severity INFO -Component 'New-SPVault' -Action 'Complete' -CorrelationID $correlationID

    #endregion

}
elseif ($Mode -eq 'DpapiCredential') {

    #region DpapiCredential Mode

    # Resolve credential file path
    $credPath = $config.Authentication.DpapiCredential.Path
    if ([string]::IsNullOrWhiteSpace($credPath)) {
        $credPath = '.\Data\sp-dpapi-credential.xml'
    }
    if (-not [System.IO.Path]::IsPathRooted($credPath)) {
        $credPath = [System.IO.Path]::GetFullPath(
            (Join-Path $toolkitRoot ($credPath.TrimStart('.\').TrimStart('./')))
        )
    }

    Write-Host "  DPAPI credential path: $credPath" -ForegroundColor White
    Write-Host ''

    # WhatIf guard
    if ($WhatIfPreference) {
        Write-Host '  [WhatIf] The following actions would be performed:' -ForegroundColor Yellow
        Write-Host "    1. Prompt for Client ID and Client Secret" -ForegroundColor Yellow
        Write-Host "    2. Export PSCredential via Export-CliXml to: $credPath" -ForegroundColor Yellow
        Write-Host "    3. Verify by reading the credential back" -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    # Check if credential file already exists
    if (Test-Path -LiteralPath $credPath -PathType Leaf) {
        Write-Host "  WARNING: A DPAPI credential file already exists at:" -ForegroundColor Yellow
        Write-Host "  $credPath" -ForegroundColor Yellow
        Write-Host ''

        $target = "DPAPI credential file at $credPath"
        $action = "Overwrite existing DPAPI credential file"
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            Write-Host "  DPAPI credential setup cancelled. Existing file preserved." -ForegroundColor Green
            exit 0
        }
        Write-Host ''
    }

    # Collect ClientId
    Write-Host '  Enter SailPoint ISC OAuth credentials:' -ForegroundColor White
    if (-not $ClientId) {
        $ClientId = Read-Host 'ClientId'
    }
    else {
        Write-Host "  Using provided ClientId: $ClientId" -ForegroundColor DarkGray
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        Write-Host "  ERROR: ClientId cannot be empty." -ForegroundColor Red
        exit 1
    }

    # Collect ClientSecret
    $clientSecretSecure = $null
    if ($ClientSecret) {
        $clientSecretSecure = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        Write-Host "  Using provided ClientSecret (from parameter)." -ForegroundColor DarkGray
    }
    else {
        $clientSecretSecure = Read-Host -AsSecureString 'ClientSecret'
    }

    # Verify secret is not empty
    $secretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecretSecure)
    try {
        $secretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)
        $secretEmpty = [string]::IsNullOrWhiteSpace($secretPlain)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)
        Remove-Variable secretPlain -ErrorAction SilentlyContinue
    }

    if ($secretEmpty) {
        Write-Host "  ERROR: ClientSecret cannot be empty." -ForegroundColor Red
        exit 1
    }

    # Build PSCredential object (ClientId as UserName, ClientSecret as Password)
    $credential = [System.Management.Automation.PSCredential]::new($ClientId, $clientSecretSecure)

    # Ensure output directory exists
    $credDir = Split-Path -Path $credPath -Parent
    if ($credDir -and -not (Test-Path -Path $credDir)) {
        New-Item -Path $credDir -ItemType Directory -Force | Out-Null
    }

    Write-Host ''
    Write-Host "  Exporting DPAPI-encrypted credential..." -ForegroundColor Cyan

    # Export the credential using Windows DPAPI encryption
    $credential | Export-Clixml -Path $credPath -Force

    # Verify by reading it back
    Write-Host "  Verifying DPAPI credential..." -ForegroundColor Cyan
    $readBack = Import-Clixml -Path $credPath

    if ($null -eq $readBack -or $readBack -isnot [System.Management.Automation.PSCredential]) {
        Write-Host "  ERROR: Verification failed - could not read credential back from file." -ForegroundColor Red
        exit 1
    }

    if ($readBack.UserName -ne $ClientId) {
        Write-Host "  ERROR: Verification mismatch. Stored ClientId does not match input." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Verification passed. ClientId matches stored value." -ForegroundColor Green
    Write-Host ''
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray
    Write-Host '  DPAPI credential setup complete.' -ForegroundColor Green
    Write-Host ''

    $currentUser = [Environment]::UserName
    $currentMachine = [Environment]::MachineName
    Write-Host "  WARNING: This credential is encrypted with Windows DPAPI and bound to" -ForegroundColor Yellow
    Write-Host "  user '$currentUser' on machine '$currentMachine'." -ForegroundColor Yellow
    Write-Host "  It can only be decrypted by this user on this machine." -ForegroundColor Yellow
    Write-Host "  NOTE: DPAPI-protected credentials may trigger EDR/Mimikatz alerts" -ForegroundColor Yellow
    Write-Host "  in some environments." -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor White
    Write-Host "    1. Set Authentication.Mode = 'DpapiCredential' in settings.json" -ForegroundColor White
    Write-Host "    2. Confirm Authentication.DpapiCredential.Path = '$credPath'" -ForegroundColor White
    Write-Host "    3. Run Test-SPConnectivity.ps1 to confirm OAuth works" -ForegroundColor White
    Write-Host ''

    Write-SPLog -Message "DPAPI credential setup completed. Path: $credPath | User: $currentUser | Machine: $currentMachine" `
        -Severity INFO -Component 'New-SPVault' -Action 'Complete' -CorrelationID $correlationID

    #endregion

}
elseif ($Mode -eq 'ScheduledVault') {

    #region ScheduledVault Mode

    # Resolve vault path (the regular vault must exist)
    if (-not $VaultPath) {
        $VaultPath = $config.Authentication.Vault.VaultPath
    }
    if ([string]::IsNullOrWhiteSpace($VaultPath)) {
        Write-Host "  ERROR: Authentication.Vault.VaultPath is not configured in settings.json." -ForegroundColor Red
        Write-Host "  The regular vault must be set up first. Run: .\New-SPVault.ps1 -Mode Vault" -ForegroundColor Red
        exit 1
    }
    if (-not [System.IO.Path]::IsPathRooted($VaultPath)) {
        $VaultPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $VaultPath.TrimStart('.\').TrimStart('./')))
    }

    if (-not (Test-Path -LiteralPath $VaultPath -PathType Leaf)) {
        Write-Host "  ERROR: Vault file not found at: $VaultPath" -ForegroundColor Red
        Write-Host "  The regular vault must exist before setting up ScheduledVault mode." -ForegroundColor Red
        Write-Host "  Run: .\New-SPVault.ps1 -Mode Vault" -ForegroundColor Red
        exit 1
    }

    # Resolve key path
    $keyPath = $config.Authentication.ScheduledVault.KeyPath
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $keyPath = '.\Data\sp-scheduled-key.enc'
    }
    if (-not [System.IO.Path]::IsPathRooted($keyPath)) {
        $keyPath = [System.IO.Path]::GetFullPath(
            (Join-Path $toolkitRoot ($keyPath.TrimStart('.\').TrimStart('./')))
        )
    }

    $credentialKey = $config.Authentication.Vault.CredentialKey
    if (-not $credentialKey) {
        $credentialKey = 'sailpoint-isc'
    }

    Write-Host "  Vault path        : $VaultPath" -ForegroundColor White
    Write-Host "  Scheduled key path: $keyPath" -ForegroundColor White
    Write-Host "  Credential key    : $credentialKey" -ForegroundColor White
    Write-Host ''

    # WhatIf guard
    if ($WhatIfPreference) {
        Write-Host '  [WhatIf] The following actions would be performed:' -ForegroundColor Yellow
        Write-Host "    1. Verify vault passphrase against existing vault" -ForegroundColor Yellow
        Write-Host "    2. Generate machine-derived key" -ForegroundColor Yellow
        Write-Host "    3. Encrypt vault passphrase with machine-derived key" -ForegroundColor Yellow
        Write-Host "    4. Write encrypted passphrase to: $keyPath" -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    # Check if key file already exists
    if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
        Write-Host "  WARNING: A scheduled vault key file already exists at:" -ForegroundColor Yellow
        Write-Host "  $keyPath" -ForegroundColor Yellow
        Write-Host ''

        $target = "Scheduled vault key file at $keyPath"
        $action = "Overwrite existing scheduled vault key file"
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            Write-Host "  ScheduledVault setup cancelled. Existing key preserved." -ForegroundColor Green
            exit 0
        }
        Write-Host ''
    }

    # Prompt for the vault passphrase (to verify they know it)
    Write-Host '  Enter the vault passphrase (to verify access):' -ForegroundColor White
    $vaultPassphraseSecure = Read-Host -AsSecureString 'Vault passphrase'

    # Convert SecureString to plain text for vault operations
    $vaultPassphrasePlain = $null
    $vaultPassphrasePtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vaultPassphraseSecure)
    try {
        $vaultPassphrasePlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($vaultPassphrasePtr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($vaultPassphrasePtr)
    }

    if ([string]::IsNullOrWhiteSpace($vaultPassphrasePlain)) {
        Write-Host "  ERROR: Vault passphrase cannot be empty." -ForegroundColor Red
        exit 1
    }

    # Verify the passphrase opens the vault by reading its contents
    Write-Host ''
    Write-Host "  Verifying vault passphrase..." -ForegroundColor Cyan

    $verifyResult = Get-SPVaultCredential `
        -VaultPath  $VaultPath `
        -Passphrase $vaultPassphraseSecure `
        -Key        $credentialKey

    if (-not $verifyResult.Success) {
        Write-Host "  ERROR: Could not open vault with the provided passphrase: $($verifyResult.Error)" -ForegroundColor Red
        $vaultPassphrasePlain = $null
        exit 1
    }

    Write-Host "  Vault passphrase verified. Credential key '$credentialKey' found." -ForegroundColor Green

    # Generate the machine-derived passphrase
    Write-Host "  Generating machine-derived key..." -ForegroundColor Cyan

    # Machine-derived passphrase -- delegated to the single shared implementation in SP.Auth so
    # setup and runtime (Get-SPCredentialsFromScheduledVault) stay in lockstep, INCLUDING the
    # per-install DPAPI-protected secret that makes the key non-derivable. (This was previously
    # inlined here as a weak SHA-256 of public machine/user/domain values.)
    $machineName = [Environment]::MachineName
    $userName    = [Environment]::UserName
    $machinePassphrase = Get-SPMachineDerivedPassphrase

    # Encrypt the vault passphrase using the machine-derived passphrase
    Write-Host "  Encrypting vault passphrase with machine-derived key..." -ForegroundColor Cyan

    $passphraseBytes = [System.Text.Encoding]::UTF8.GetBytes($vaultPassphrasePlain)
    $encryptedBytes = Invoke-SPVaultEncrypt -Plaintext $passphraseBytes -Passphrase $machinePassphrase

    # Zero sensitive data immediately
    for ($i = 0; $i -lt $passphraseBytes.Length; $i++) { $passphraseBytes[$i] = 0 }
    $vaultPassphrasePlain = $null

    # Ensure output directory exists
    $keyDir = Split-Path -Path $keyPath -Parent
    if ($keyDir -and -not (Test-Path -Path $keyDir)) {
        New-Item -Path $keyDir -ItemType Directory -Force | Out-Null
    }

    # Write the encrypted passphrase to the key file
    [System.IO.File]::WriteAllBytes($keyPath, $encryptedBytes)

    # Verify by decrypting and re-opening the vault
    Write-Host "  Verifying scheduled vault key..." -ForegroundColor Cyan

    $readBackBytes = [System.IO.File]::ReadAllBytes($keyPath)
    $decryptedBytes = Invoke-SPVaultDecrypt -Data $readBackBytes -Passphrase $machinePassphrase
    $decryptedPassphrase = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)

    # Use the decrypted passphrase as a SecureString to verify vault access
    $decryptedSecure = ConvertTo-SecureString $decryptedPassphrase -AsPlainText -Force
    $reVerify = Get-SPVaultCredential `
        -VaultPath  $VaultPath `
        -Passphrase $decryptedSecure `
        -Key        $credentialKey

    # Zero verification data
    for ($i = 0; $i -lt $decryptedBytes.Length; $i++) { $decryptedBytes[$i] = 0 }
    $decryptedPassphrase = $null
    $machinePassphrase = $null

    if (-not $reVerify.Success) {
        Write-Host "  ERROR: Verification failed - could not open vault with decrypted passphrase: $($reVerify.Error)" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Verification passed. Scheduled vault key successfully opens the vault." -ForegroundColor Green
    Write-Host ''
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray
    Write-Host '  Scheduled vault key setup complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Scheduled vault key created at $keyPath." -ForegroundColor White
    Write-Host "  This key is derived from machine '$machineName' + user '$userName'" -ForegroundColor White
    Write-Host "  and can only be used by this account on this machine." -ForegroundColor White
    Write-Host "  AES-256 + a per-install DPAPI-protected secret (Data\.sv-secret) -- not decryptable off-box." -ForegroundColor White
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor White
    Write-Host "    1. Set Authentication.Mode = 'ScheduledVault' in settings.json" -ForegroundColor White
    Write-Host "    2. Confirm Authentication.ScheduledVault.KeyPath = '$keyPath'" -ForegroundColor White
    Write-Host "    3. Confirm Authentication.Vault.VaultPath = '$VaultPath'" -ForegroundColor White
    Write-Host "    4. Run Test-SPConnectivity.ps1 to confirm OAuth works" -ForegroundColor White
    Write-Host ''

    Write-SPLog -Message "ScheduledVault setup completed. KeyPath: $keyPath | Machine: $machineName | User: $userName" `
        -Severity INFO -Component 'New-SPVault' -Action 'Complete' -CorrelationID $correlationID

    #endregion

}

exit 0
