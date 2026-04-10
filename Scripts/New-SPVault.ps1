#Requires -Version 5.1
<#
.SYNOPSIS
    One-time interactive setup for the encrypted credential vault.
.DESCRIPTION
    Initializes the SailPoint ISC credential vault (AES-256-CBC + PBKDF2) and
    stores the ISC OAuth client credentials. Run once before using the toolkit
    with Vault authentication mode. Credentials are never written to disk in
    plain text.

    Steps performed:
      1. Load settings.json to determine the default vault path
      2. Prompt for vault passphrase (confirmed twice)
      3. Warn and confirm if vault file already exists (destructive)
      4. Initialize the encrypted vault file
      5. Prompt for ClientId and ClientSecret (or use -ClientId / -ClientSecret)
      6. Store credentials under the configured key (default: sailpoint-isc)
      7. Verify by reading credentials back from the vault
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json.
.PARAMETER VaultPath
    Override the vault file path from settings.json. Optional.
.PARAMETER ClientId
    OAuth client ID. If omitted, prompted interactively.
.PARAMETER ClientSecret
    OAuth client secret. If omitted, prompted interactively as SecureString.
.EXAMPLE
    .\New-SPVault.ps1
    # Fully interactive setup using settings.json defaults
.EXAMPLE
    .\New-SPVault.ps1 -ClientId 'abc123'
    # Pre-supply ClientId; ClientSecret will be prompted
.EXAMPLE
    .\New-SPVault.ps1 -WhatIf
    # Show what would happen without creating any files
.NOTES
    Script:  New-SPVault.ps1
    Version: 1.0.0
    Security: Passphrase is never logged or written to disk. Vault uses
              AES-256-CBC with PBKDF2 key derivation (600,000 iterations by
              default). Store the passphrase in a password manager.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
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
    Import-Module $coreModulePath -Force -ErrorAction Stop
}
else {
    $moduleDir = Join-Path $toolkitRoot 'Modules\SP.Core'
    $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
    if ($psm1Files) {
        foreach ($psm1 in $psm1Files) {
            Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
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

# Resolve config path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $toolkitRoot 'Config\settings.json'
}

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit - Vault Setup' -ForegroundColor Cyan
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
    Write-Host "ERROR: First-run configuration detected. Populate settings.json before creating vault." -ForegroundColor Red
    exit 1
}

# Initialize logging
try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
}
catch { }

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
Write-Host "  Environment   : $($config.Global.EnvironmentName)" -ForegroundColor White
Write-Host ''

#endregion

#region WhatIf Guard

if ($WhatIfPreference) {
    Write-Host '  [WhatIf] The following actions would be performed:' -ForegroundColor Yellow
    Write-Host "    1. Initialize vault at: $VaultPath" -ForegroundColor Yellow
    Write-Host "    2. Store credentials under key: $credentialKey" -ForegroundColor Yellow
    Write-Host "    3. Verify credentials are readable" -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

#endregion

#region Vault Initialization

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

#endregion

#region Credential Storage

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

#endregion

#region Verification

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

exit 0

#endregion
