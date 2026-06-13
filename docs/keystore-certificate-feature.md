# Implementing Unattended Automation via Windows Certificate Store

## 1. The Operational Problem

Automating SailPoint ISC tasks on Windows endpoints requires passing the `ClientId` and `ClientSecret` to the API.
Historically, administrators have faced a tradeoff:
1. **Plaintext Configuration:** Store the secret in `settings.json` (Insecure).
2. **Interactive Vault:** Encrypt the secret, but require a human to enter a passphrase via `Read-Host` (Breaks automation).
3. **DPAPI / Windows Credential Manager:** Securely encrypts data tied to the user account, but often triggers aggressive Endpoint Detection and Response (EDR) platforms like SentinelOne, which mistake background DPAPI calls for credential-dumping malware (e.g., Mimikatz).

## 2. The Solution: Windows Certificate Store

To achieve **zero-touch automation** without triggering EDR alerts or storing plaintext secrets, you can leverage the Windows Certificate Store (`Cert:\LocalMachine\My`).

**How it works:**
1. A certificate is installed on the server.
2. The SailPoint `ClientSecret` is encrypted using the certificate's **Public Key** and saved to disk as a Base64 string.
3. At runtime, the PowerShell script accesses the certificate's **Private Key** to decrypt the secret in memory.
4. **Security Boundary:** You use the Microsoft Management Console (MMC) to explicitly grant the Scheduled Task's Service Account `Read` permissions to the Private Key. No other user can decrypt the secret.

---

## 3. Implementation Guide

### Step 1: Generate & Install the Certificate
You can use an internal PKI certificate, or generate a self-signed certificate on the jumpbox/server. Run this as an Administrator:

```powershell
# Create a new certificate for authentication encryption
$certParams = @{
    Subject           = "CN=SailPointToolkitAuth"
    CertStoreLocation = "Cert:\LocalMachine\My"
    KeyExportPolicy   = "Exportable"
    KeySpec           = "KeyExchange"
    KeyLength         = 2048
    NotAfter          = (Get-Date).AddYears(5)
}
$cert = New-SelfSignedCertificate @certParams

Write-Host "Certificate generated with Thumbprint: $($cert.Thumbprint)"
```

### Step 2: Grant Permissions to the Service Account
This is the critical security step. The account running your Scheduled Task must have permission to read the Private Key.
1. Open `certlm.msc` (Local Machine Certificates).
2. Navigate to **Personal** > **Certificates**.
3. Right-click the `SailPointToolkitAuth` certificate > **All Tasks** > **Manage Private Keys...**
4. Add the Service Account (e.g., `DOMAIN\svc-sailpoint` or `SYSTEM`) and grant it **Read** access.

### Step 3: Encrypt the SailPoint Secret (One-Time Setup)
Run this block to encrypt your raw `ClientSecret`. You will take the resulting Base64 string and paste it into your `settings.json` (instead of the plaintext secret).

```powershell
$rawSecret = "YOUR_SAILPOINT_CLIENT_SECRET"
$cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -match "SailPointToolkitAuth" } | Select-Object -First 1

# Extract Public Key and Encrypt
$secretBytes = [System.Text.Encoding]::UTF8.GetBytes($rawSecret)
$rsaPublic = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
$encryptedBytes = $rsaPublic.Encrypt($secretBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
$encryptedBase64 = [Convert]::ToBase64String($encryptedBytes)

Write-Host "Encrypted Secret for settings.json:"
Write-Host $encryptedBase64
```

### Step 4: Decrypting at Runtime (Inside SP.Auth.psm1)
You will need to update the toolkit's authentication flow (likely adding a new `Mode` called `Certificate` to `Get-SPAuthToken` inside `SP.Auth.psm1`).

The background script will run this logic to retrieve the secret:

```powershell
# 1. Retrieve the Base64 string from settings.json
$encryptedBase64 = $Config.Authentication.ConfigFile.ClientSecret

# 2. Find the Certificate
$cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -match "SailPointToolkitAuth" } | Select-Object -First 1

if (-not $cert) {
    throw "Authentication Certificate 'SailPointToolkitAuth' not found in LocalMachine store."
}

# 3. Decrypt using the Private Key
try {
    $rsaPrivate = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $encryptedBytes = [Convert]::FromBase64String($encryptedBase64)
    $decryptedBytes = $rsaPrivate.Decrypt($encryptedBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    
    $clientSecret = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
    
    # $clientSecret is now securely in memory and can be passed to the OAuth token request
} catch {
    throw "Failed to decrypt secret. Ensure the executing account has Read access to the certificate's Private Key."
} finally {
    if ($null -ne $rsaPrivate) { $rsaPrivate.Dispose() }
}
```

## 4. Advantages of this Pattern
* **EDR Friendly:** Reading from the Certificate Store is a standard Windows operation used by IIS, SQL Server, and OS services. It does not look like Mimikatz or credential dumping.
* **No Plaintext on Disk:** The secret is fully encrypted at rest using AES/RSA standard cryptography.
* **Access Controlled:** Even if an administrator copies the encrypted string from `settings.json`, they cannot decrypt it unless they are logged in as the Service Account or export the Private Key.
* **Unattended Ready:** Requires zero interactive prompts, making it perfect for standard Windows Task Scheduler workflows.
