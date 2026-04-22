param(
    [Parameter(Mandatory)]
    [string]$ExtractedPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\intunewin_extracted"
)

function Get-EncryptionInfo {
    param([string]$XmlPath)
    [xml]$xml = Get-Content $XmlPath -Encoding UTF8
    $info = $xml.ApplicationInfo.EncryptionInfo
    return @{
        Key  = [Convert]::FromBase64String($info.EncryptionKey)
        IV   = [Convert]::FromBase64String($info.InitializationVector)
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
    $aes = [System.Security.Cryptography.Aes]::Create()
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

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$detectionXml = Join-Path $ExtractedPath "IntuneWinPackage\Metadata\Detection.xml"
$encryptedPkg = Join-Path $ExtractedPath "IntuneWinPackage\Contents\IntunePackage.intunewin"

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

#Invoke-AesDecrypt -InputFile $encryptedPkg -OutputFile $decryptedZip -Key $encInfo.Key -IV $encInfo.IV
Invoke-AesDecrypt -InputFile $encryptedPkg -OutputFile $decryptedZip -Key $encInfo.Key

Write-Host ">> Rozbalujem obsah do: $OutputPath" -ForegroundColor Cyan
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($decryptedZip, $OutputPath)

Remove-Item $decryptedZip -Force

Write-Host ""
Write-Host "Hotovo! Obsah balicka:" -ForegroundColor Green
Get-ChildItem $OutputPath -Recurse | Select-Object FullName


