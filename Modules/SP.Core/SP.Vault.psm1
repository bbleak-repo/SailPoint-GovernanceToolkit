#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit Vault Module
.DESCRIPTION
    Provides AES-256-CBC + HMAC-SHA256 encrypted credential storage.
    Compatible with PowerShell 5.1 on .NET 4.x (no AesGcm).

    Binary format per vault file:
        [32 bytes salt][16 bytes IV][32 bytes HMAC-SHA256][N bytes AES-CBC ciphertext]

    Key derivation: PBKDF2-SHA1 (Rfc2898DeriveBytes) producing 64 bytes:
        bytes  0-31 = AES-256 encryption key
        bytes 32-63 = HMAC-SHA256 authentication key

    Vault plaintext is a JSON dictionary, e.g.:
        {"sailpoint-isc": {"ClientId": "...", "ClientSecret": "..."}}
.NOTES
    Module: SP.Vault
    Version: 1.0.0
#>

#region Internal Cryptographic Helpers

function ConvertFrom-SPSecureString {
    <#
    .SYNOPSIS
        Converts a SecureString to a plain-text string in memory
    .PARAMETER SecureString
        The SecureString to convert
    .OUTPUTS
        [string] Plain-text value
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Security.SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-SPVaultEncrypt {
    <#
    .SYNOPSIS
        Encrypts plaintext bytes using AES-256-CBC + HMAC-SHA256
    .PARAMETER Plaintext
        Byte array of plaintext data
    .PARAMETER Passphrase
        The vault passphrase as a plain string
    .OUTPUTS
        [byte[]] Authenticated ciphertext: [32 salt][16 IV][32 HMAC][N ciphertext]
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Plaintext,

        [Parameter(Mandatory)]
        [string]$Passphrase
    )

    # Generate random salt and IV
    $salt = New-Object byte[] 32
    $iv   = New-Object byte[] 16
    $rng  = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
    $rng.Dispose()

    # Derive 64 bytes: 32 enc key + 32 HMAC key
    $passphraseBytes = [System.Text.Encoding]::UTF8.GetBytes($Passphrase)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($passphraseBytes, $salt, 600000)
    try {
        $derivedBytes = $kdf.GetBytes(64)
    }
    finally {
        $kdf.Dispose()
        # Zero out passphrase bytes
        for ($i = 0; $i -lt $passphraseBytes.Length; $i++) { $passphraseBytes[$i] = 0 }
    }

    $encKey  = $derivedBytes[0..31]
    $hmacKey = $derivedBytes[32..63]

    # Encrypt with AES-256-CBC
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $encKey
    $aes.IV      = $iv

    $encryptor  = $aes.CreateEncryptor()
    $ciphertext = $encryptor.TransformFinalBlock($Plaintext, 0, $Plaintext.Length)
    $encryptor.Dispose()
    $aes.Dispose()

    # Compute HMAC-SHA256 over (IV + ciphertext)
    $hmacData   = $iv + $ciphertext
    $hmac       = [System.Security.Cryptography.HMACSHA256]::new($hmacKey)
    $hmacResult = $hmac.ComputeHash($hmacData)
    $hmac.Dispose()

    # Assemble: [32 salt][16 IV][32 HMAC][N ciphertext]
    return $salt + $iv + $hmacResult + $ciphertext
}

function Invoke-SPVaultDecrypt {
    <#
    .SYNOPSIS
        Decrypts vault binary data using AES-256-CBC + HMAC-SHA256
    .PARAMETER Data
        The raw vault file bytes
    .PARAMETER Passphrase
        The vault passphrase as a plain string
    .OUTPUTS
        [byte[]] Decrypted plaintext bytes, or throws on HMAC mismatch
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Data,

        [Parameter(Mandatory)]
        [string]$Passphrase
    )

    $minLen = 32 + 16 + 32  # salt + IV + HMAC
    if ($Data.Length -le $minLen) {
        throw 'Vault file is too small or corrupted.'
    }

    $salt       = $Data[0..31]
    $iv         = $Data[32..47]
    $storedHmac = $Data[48..79]
    $ciphertext = $Data[80..($Data.Length - 1)]

    # Derive keys
    $passphraseBytes = [System.Text.Encoding]::UTF8.GetBytes($Passphrase)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($passphraseBytes, $salt, 600000)
    try {
        $derivedBytes = $kdf.GetBytes(64)
    }
    finally {
        $kdf.Dispose()
        for ($i = 0; $i -lt $passphraseBytes.Length; $i++) { $passphraseBytes[$i] = 0 }
    }

    $encKey  = $derivedBytes[0..31]
    $hmacKey = $derivedBytes[32..63]

    # Verify HMAC before decryption (authenticate-then-decrypt)
    $hmacData   = $iv + $ciphertext
    $hmac       = [System.Security.Cryptography.HMACSHA256]::new($hmacKey)
    $hmacResult = $hmac.ComputeHash($hmacData)
    $hmac.Dispose()

    # Constant-time comparison
    $mismatch = 0
    for ($i = 0; $i -lt 32; $i++) {
        $mismatch = $mismatch -bor ($storedHmac[$i] -bxor $hmacResult[$i])
    }
    if ($mismatch -ne 0) {
        throw 'HMAC verification failed. Wrong passphrase or corrupted vault file.'
    }

    # Decrypt
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $encKey
    $aes.IV      = $iv

    $decryptor = $aes.CreateDecryptor()
    $plaintext = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
    $decryptor.Dispose()
    $aes.Dispose()

    return $plaintext
}

function Read-SPVaultData {
    <#
    .SYNOPSIS
        Reads and decrypts vault file, returning the credential dictionary
    .PARAMETER VaultPath
        Path to the vault file
    .PARAMETER Passphrase
        Plain-text passphrase
    .OUTPUTS
        [hashtable] Credential dictionary
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath,

        [Parameter(Mandatory)]
        [string]$Passphrase
    )

    $rawBytes  = [System.IO.File]::ReadAllBytes($VaultPath)
    $plaintext = Invoke-SPVaultDecrypt -Data $rawBytes -Passphrase $Passphrase
    $json      = [System.Text.Encoding]::UTF8.GetString($plaintext)
    $obj       = $json | ConvertFrom-Json

    # Convert PSCustomObject to hashtable
    $dict = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $inner = @{}
        foreach ($innerProp in $prop.Value.PSObject.Properties) {
            $inner[$innerProp.Name] = $innerProp.Value
        }
        $dict[$prop.Name] = $inner
    }
    return $dict
}

function Write-SPVaultData {
    <#
    .SYNOPSIS
        Encrypts and writes credential dictionary to vault file
    .PARAMETER VaultPath
        Path to the vault file
    .PARAMETER Passphrase
        Plain-text passphrase
    .PARAMETER Data
        Credential dictionary to encrypt
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath,

        [Parameter(Mandatory)]
        [string]$Passphrase,

        [Parameter(Mandatory)]
        [hashtable]$Data
    )

    $json       = $Data | ConvertTo-Json -Depth 5 -Compress
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $encrypted  = Invoke-SPVaultEncrypt -Plaintext $plainBytes -Passphrase $Passphrase

    # Ensure parent directory exists
    $vaultDir = Split-Path -Path $VaultPath -Parent
    if ($vaultDir -and -not (Test-Path -Path $vaultDir)) {
        New-Item -Path $vaultDir -ItemType Directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllBytes($VaultPath, $encrypted)
}

#endregion

#region Public Functions

function Initialize-SPVault {
    <#
    .SYNOPSIS
        Creates a new empty encrypted vault file
    .DESCRIPTION
        Initializes a fresh vault at the given path. Fails if vault already exists
        (use -Force on your own code if you need to overwrite).
    .PARAMETER VaultPath
        File system path for the vault file
    .PARAMETER Passphrase
        Master passphrase for the vault as a SecureString
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=$null; Error=[string]}
    .EXAMPLE
        $passphrase = Read-Host 'Vault passphrase' -AsSecureString
        $result = Initialize-SPVault -VaultPath '.\Data\sp-vault.enc' -Passphrase $passphrase
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Passphrase
    )

    try {
        if (Test-Path -Path $VaultPath -PathType Leaf) {
            return @{ Success = $false; Data = $null; Error = "Vault already exists at: $VaultPath" }
        }

        $passPlain = ConvertFrom-SPSecureString -SecureString $Passphrase
        try {
            $emptyData = @{}
            Write-SPVaultData -VaultPath $VaultPath -Passphrase $passPlain -Data $emptyData
        }
        finally {
            $passPlain = $null
            [System.GC]::Collect()
        }

        return @{ Success = $true; Data = $null; Error = $null }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Set-SPVaultCredential {
    <#
    .SYNOPSIS
        Stores a credential (ClientId + ClientSecret) in the vault under a named key
    .PARAMETER VaultPath
        File system path for the vault file
    .PARAMETER Passphrase
        Master passphrase as a SecureString
    .PARAMETER Key
        Logical credential key (e.g., 'sailpoint-isc')
    .PARAMETER ClientId
        OAuth client ID to store
    .PARAMETER ClientSecret
        OAuth client secret to store
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=$null; Error=[string]}
    .EXAMPLE
        $result = Set-SPVaultCredential -VaultPath '.\Data\sp-vault.enc' `
            -Passphrase $pass -Key 'sailpoint-isc' `
            -ClientId 'abc123' -ClientSecret 'supersecret'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Passphrase,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$ClientSecret
    )

    try {
        if (-not (Test-Path -Path $VaultPath -PathType Leaf)) {
            return @{ Success = $false; Data = $null; Error = "Vault does not exist at: $VaultPath. Call Initialize-SPVault first." }
        }

        $passPlain = ConvertFrom-SPSecureString -SecureString $Passphrase
        try {
            $data = Read-SPVaultData -VaultPath $VaultPath -Passphrase $passPlain
            $data[$Key] = @{
                ClientId     = $ClientId
                ClientSecret = $ClientSecret
            }
            Write-SPVaultData -VaultPath $VaultPath -Passphrase $passPlain -Data $data
        }
        finally {
            $passPlain = $null
            [System.GC]::Collect()
        }

        return @{ Success = $true; Data = $null; Error = $null }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Get-SPVaultCredential {
    <#
    .SYNOPSIS
        Retrieves a credential from the vault by key
    .PARAMETER VaultPath
        File system path for the vault file
    .PARAMETER Passphrase
        Master passphrase as a SecureString
    .PARAMETER Key
        Logical credential key (e.g., 'sailpoint-isc')
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=@{ClientId=[string]; ClientSecret=[string]}; Error=[string]}
    .EXAMPLE
        $result = Get-SPVaultCredential -VaultPath '.\Data\sp-vault.enc' `
            -Passphrase $pass -Key 'sailpoint-isc'
        if ($result.Success) { $clientId = $result.Data.ClientId }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Passphrase,

        [Parameter(Mandatory)]
        [string]$Key
    )

    try {
        if (-not (Test-Path -Path $VaultPath -PathType Leaf)) {
            return @{ Success = $false; Data = $null; Error = "Vault does not exist at: $VaultPath" }
        }

        $passPlain = ConvertFrom-SPSecureString -SecureString $Passphrase
        $data      = $null
        try {
            $data = Read-SPVaultData -VaultPath $VaultPath -Passphrase $passPlain
        }
        finally {
            $passPlain = $null
            [System.GC]::Collect()
        }

        if (-not $data.ContainsKey($Key)) {
            return @{ Success = $false; Data = $null; Error = "Credential key '$Key' not found in vault." }
        }

        $cred = $data[$Key]
        return @{
            Success = $true
            Data    = @{
                ClientId     = $cred['ClientId']
                ClientSecret = $cred['ClientSecret']
            }
            Error   = $null
        }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Test-SPVaultExists {
    <#
    .SYNOPSIS
        Returns true if the vault file exists at the given path
    .PARAMETER VaultPath
        File system path for the vault file
    .OUTPUTS
        [bool]
    .EXAMPLE
        if (Test-SPVaultExists -VaultPath '.\Data\sp-vault.enc') { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath
    )

    return (Test-Path -Path $VaultPath -PathType Leaf)
}

function Remove-SPVaultCredential {
    <#
    .SYNOPSIS
        Removes a named credential from the vault
    .PARAMETER VaultPath
        File system path for the vault file
    .PARAMETER Passphrase
        Master passphrase as a SecureString
    .PARAMETER Key
        Logical credential key to remove
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=$null; Error=[string]}
    .EXAMPLE
        $result = Remove-SPVaultCredential -VaultPath '.\Data\sp-vault.enc' `
            -Passphrase $pass -Key 'sailpoint-isc'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultPath,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Passphrase,

        [Parameter(Mandatory)]
        [string]$Key
    )

    try {
        if (-not (Test-Path -Path $VaultPath -PathType Leaf)) {
            return @{ Success = $false; Data = $null; Error = "Vault does not exist at: $VaultPath" }
        }

        $passPlain = ConvertFrom-SPSecureString -SecureString $Passphrase
        try {
            $data = Read-SPVaultData -VaultPath $VaultPath -Passphrase $passPlain

            if (-not $data.ContainsKey($Key)) {
                return @{ Success = $false; Data = $null; Error = "Credential key '$Key' not found in vault." }
            }

            $data.Remove($Key)
            Write-SPVaultData -VaultPath $VaultPath -Passphrase $passPlain -Data $data
        }
        finally {
            $passPlain = $null
            [System.GC]::Collect()
        }

        return @{ Success = $true; Data = $null; Error = $null }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Initialize-SPVault',
    'Set-SPVaultCredential',
    'Get-SPVaultCredential',
    'Test-SPVaultExists',
    'Remove-SPVaultCredential'
)
