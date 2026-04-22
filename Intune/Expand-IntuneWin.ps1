<#
.SYNOPSIS
    Desifruje a rozbalí obsah .intunewin balicka.

.DESCRIPTION
    Skript podporuje dva rezimy:
    - Prima cesta k .intunewin suboru (rozbalenie outer ZIP + desifrovanie)
    - Cesta k uz rozbalenemu adresaru (len desifrovanie)
    Struktura suboru: 32B HMAC-SHA256 + 16B IV + AES-256-CBC sifrovany ZIP.

.NOTES
    Verzia:              1.0
    Autor:               Marek Findrik
    Datum vytvorenia:    2026-04-16
    Pozadovane moduly:   -
    Logovanie:           nie

.RUN
Z .intunewin suboru
.\Expand-IntuneWin.ps1 -Path "D:\balicky\appname.intunewin"

Z uz rozbaleneho adresara
.\Expand-IntuneWin.ps1 -Path "D:\findrik\PowerShell\Intune\IPLoc\V4"

S vlastnym vystupnym adresarom
.\Expand-IntuneWin.ps1 -Path "D:\balicky\appname.intunewin" -OutputPath "D:\obsah\appname"
#>

param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Funkcie ---

function Expand-OuterZip {
    param([string]$ZipPath, [string]$Destination)
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Get-EncryptionInfo {
    param([string]$XmlPath)
    [xml]$xml = Get-Content $XmlPath -Encoding UTF8
    $info = $xml.ApplicationInfo.EncryptionInfo
    return @{
        Key  = [Convert]::FromBase64String($info.EncryptionKey)
        Name = $xml.ApplicationInfo.Name
        Ver  = $xml.ApplicationInfo.MsiInformation.ProductVersion
    }
}

function Invoke-AesDecrypt {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [byte[]]$Key
    )
    $aes         = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $Key

    $fsIn = [System.IO.File]::OpenRead($InputFile)

    # Preskoc HMAC-SHA256 (32 bajtov)
    $fsIn.Seek(32, [System.IO.SeekOrigin]::Begin) | Out-Null

    # Nacitaj IV (16 bajtov)
    $iv = New-Object byte[] 16
    $fsIn.Read($iv, 0, 16) | Out-Null
    $aes.IV = $iv

    $decryptor    = $aes.CreateDecryptor()
    $fsOut        = [System.IO.File]::Create($OutputFile)
    $cryptoStream = New-Object System.Security.Cryptography.CryptoStream(
        $fsIn, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Read
    )

    try {
        $cryptoStream.CopyTo($fsOut)
    } finally {
        $cryptoStream.Close()
        $fsIn.Close()
        $fsOut.Close()
        $aes.Dispose()
    }
}

# --- Hlavna logika ---

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$resolvedPath = Resolve-Path $Path | Select-Object -ExpandProperty Path
$tempDir      = $null

# Zistenie rezimu — subor .intunewin alebo uz rozbaleny adresar
if (Test-Path $resolvedPath -PathType Leaf) {
    if ([System.IO.Path]::GetExtension($resolvedPath) -ne ".intunewin") {
        Write-Error "Subor nie je .intunewin balicek."
    }
    Write-Host ">> Rezim: .intunewin subor" -ForegroundColor Cyan
    $tempDir = Join-Path $env:TEMP "intunewin_outer_$(Get-Random)"
    Write-Host ">> Rozbalujem outer ZIP..." -ForegroundColor Cyan
    Expand-OuterZip -ZipPath $resolvedPath -Destination $tempDir
    $workDir = $tempDir

    # Nastav OutputPath vedla suboru ak nie je zadany
    if (-not $OutputPath) {
        $OutputPath = Join-Path (Split-Path $resolvedPath) ([System.IO.Path]::GetFileNameWithoutExtension($resolvedPath) + "_obsah")
    }
} elseif (Test-Path $resolvedPath -PathType Container) {
    Write-Host ">> Rezim: rozbaleny adresar" -ForegroundColor Cyan
    $workDir = $resolvedPath

    # Nastav OutputPath vedla adresara ak nie je zadany
    if (-not $OutputPath) {
        $OutputPath = Join-Path (Split-Path $resolvedPath) ((Split-Path $resolvedPath -Leaf) + "_obsah")
    }
} else {
    Write-Error "Zadana cesta neexistuje: $resolvedPath"
}

# Overi strukturu
$detectionXml = Join-Path $workDir "IntuneWinPackage\Metadata\Detection.xml"
$encryptedPkg = Join-Path $workDir "IntuneWinPackage\Contents\IntunePackage.intunewin"

if (-not (Test-Path $detectionXml) -or -not (Test-Path $encryptedPkg)) {
    Write-Error "Neplatna struktura — nenasiel sa Detection.xml alebo IntunePackage.intunewin."
}

Write-Host ">> Nacitavam sifrovaci kluc z Detection.xml..." -ForegroundColor Cyan
$encInfo = Get-EncryptionInfo -XmlPath $detectionXml

Write-Host "   Nazov aplikacie : $($encInfo.Name)" -ForegroundColor Gray
if ($encInfo.Ver) {
    Write-Host "   Verzia          : $($encInfo.Ver)" -ForegroundColor Gray
}

$decryptedZip = Join-Path $env:TEMP "intunewin_decrypted_$(Get-Random).zip"

Write-Host ">> Desifrujem IntunePackage.intunewin (AES-256-CBC)..." -ForegroundColor Cyan
Invoke-AesDecrypt -InputFile $encryptedPkg -OutputFile $decryptedZip -Key $encInfo.Key

Write-Host ">> Rozbalujem obsah do: $OutputPath" -ForegroundColor Cyan
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($decryptedZip, $OutputPath)

# Upratanie
Remove-Item $decryptedZip -Force
if ($tempDir -and (Test-Path $tempDir)) { Remove-Item $tempDir -Recurse -Force }

Write-Host ""
Write-Host "Hotovo! Obsah balicka:" -ForegroundColor Green
Get-ChildItem $OutputPath -Recurse | Select-Object FullName