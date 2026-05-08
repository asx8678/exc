# scripts/sign-windows.ps1 - Authenticode-sign a Windows Burrito binary
#
# Prerequisites:
#   - Windows SDK (provides signtool.exe)
#   - A code-signing PFX certificate (OV or EV)
#
# Usage:
#   .\scripts\sign-windows.ps1 -ExePath .\burrito_out\code_puppy_control_windows_x86_64.exe
#   .\scripts\sign-windows.ps1 -ExePath .\burrito_out\code_puppy_control_windows_x86_64.exe -PfxPath .\codesign.pfx
#
# The PFX password is read from the CODESIGN_PASSWORD environment variable,
# or prompted interactively if not set.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $false)]
    [string]$PfxPath,

    [Parameter(Mandatory = $false)]
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

# ── Validate inputs ──────────────────────────────────────────────────────

if (-not (Test-Path $ExePath)) {
    Write-Error "ExePath not found: $ExePath"
    exit 1
}

# Resolve PFX path: explicit > env var > prompt
if (-not $PfxPath) {
    $PfxPath = $env:CODESIGN_PFX_PATH
    if (-not $PfxPath) {
        $PfxPath = Read-Host 'Enter path to PFX certificate file'
    }
}

if (-not (Test-Path $PfxPath)) {
    Write-Error "PFX file not found: $PfxPath"
    exit 1
}

# Resolve password: env var > prompt
$Password = $env:CODESIGN_PASSWORD
if (-not $Password) {
    $SecurePwd = Read-Host 'Enter PFX password' -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
    )
}

# ── Locate signtool.exe ──────────────────────────────────────────────────

Write-Host 'Locating signtool.exe ...'
$Signtool = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin' `
    -Recurse -Filter signtool.exe |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $Signtool) {
    Write-Error 'signtool.exe not found — is Windows SDK installed?'
    exit 1
}
Write-Host "Using signtool: $Signtool"

# ── Import certificate ──────────────────────────────────────────────────

$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Cert = Import-PfxCertificate -FilePath $PfxPath `
    -CertStoreLocation Cert:\CurrentUser\My `
    -Password $SecurePassword -Exportable

$Thumbprint = $Cert.Thumbprint
Write-Host "Certificate thumbprint: $Thumbprint"

try {
    # ── Sign ──────────────────────────────────────────────────────────

    Write-Host "Signing: $ExePath"
    & $Signtool sign /sha1 $Thumbprint `
        /fd SHA256 `
        /tr $TimestampServer `
        /td SHA256 `
        /a `
        $ExePath

    if ($LASTEXITCODE -ne 0) {
        Write-Error "signtool sign exited with code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    Write-Host 'Signing succeeded.'

    # ── Verify ────────────────────────────────────────────────────────

    Write-Host 'Verifying signature ...'
    & $Signtool verify /pa $ExePath

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Signature verification failed (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
    Write-Host 'Signature verification passed.'
}
finally {
    # ── Cleanup ────────────────────────────────────────────────────────
    Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Thumbprint -eq $Thumbprint } |
        Remove-Item
    Write-Host 'Certificate removed from store.'
}
