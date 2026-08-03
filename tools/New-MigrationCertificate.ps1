#Requires -Version 7.0
<#
.SYNOPSIS
    Create a self-signed certificate for Entra app-only auth — cross-platform.
.DESCRIPTION
    Uses System.Security.Cryptography.X509Certificates directly rather than
    New-SelfSignedCertificate (which is Windows-only), so this works on Linux,
    macOS and Windows PowerShell 7. Emits:

        * a .pfx (private key, password-protected) — keep this secret
        * a .cer (public key) — upload to the Entra app registration

    and prints the thumbprint to paste into .env / the wizard.
.PARAMETER Subject
    Certificate subject/common name.
.PARAMETER OutputDirectory
    Where to write the .pfx and .cer.
.PARAMETER ValidYears
    Validity period.
.EXAMPLE
    ./tools/New-MigrationCertificate.ps1 -Subject 'SPOMigrate' -OutputDirectory ./certs
#>
[CmdletBinding()]
param(
    [string] $Subject = 'CN=SPOMigrate',
    [string] $OutputDirectory = './certs',
    [int]    $ValidYears = 2,
    [securestring] $PfxPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Subject.StartsWith('CN=')) { $Subject = "CN=$Subject" }

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}

if (-not $PfxPassword) {
    $PfxPassword = Read-Host -AsSecureString -Prompt 'PFX export password'
}

Write-Host "Generating RSA 2048 key pair..." -ForegroundColor Cyan
$rsa = [System.Security.Cryptography.RSA]::Create(2048)

$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    $Subject,
    $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

# Basic constraints: not a CA.
$request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false)
)
# Key usage: digital signature.
$request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $false)
)
# Subject key identifier.
$request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false)
)

$notBefore = [System.DateTimeOffset]::UtcNow.AddMinutes(-5)
$notAfter  = $notBefore.AddYears($ValidYears)
$cert = $request.CreateSelfSigned($notBefore, $notAfter)

$stamp   = Get-Date -Format 'yyyyMMdd'
$pfxPath = Join-Path $OutputDirectory ("SPOMigrate_{0}.pfx" -f $stamp)
$cerPath = Join-Path $OutputDirectory ("SPOMigrate_{0}.cer" -f $stamp)

# Export PFX (private key) — password-protected.
$pfxBytes = $cert.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
    $PfxPassword)
[System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

# Export CER (public key) — base64 .cer for Entra upload.
$cerBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$b64 = [System.Convert]::ToBase64String($cerBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
$pem = "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----`n"
[System.IO.File]::WriteAllText($cerPath, $pem)

Write-Host ''
Write-Host "PFX (keep secret) : $pfxPath" -ForegroundColor Green
Write-Host "CER (upload)      : $cerPath" -ForegroundColor Green
Write-Host "Thumbprint        : $($cert.Thumbprint)" -ForegroundColor Yellow
Write-Host ''
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Upload $cerPath to your Entra app registration (Certificates & secrets)."
Write-Host "  2. Put the thumbprint in .env as SPO_CERT_THUMBPRINT (or run ./migration.ps1 -Setup)."
Write-Host "  3. On Windows, import the .pfx into CurrentUser\My so PnP can find it by thumbprint."

$rsa.Dispose()
$cert.Dispose()
