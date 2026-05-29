<#
.SYNOPSIS
    Vytvorenie WDAC policy pre blokovanie instalacie Google Chrome.
.DESCRIPTION
    Skript kombinuje dva pristupy blokovania:
    1. Deny podla nazvu suboru (ChromeSetup.exe, atd.)
    2. Deny podla Publisher certifikatu (Google LLC) - renameproof
    Pouziva native ConfigCI cmdlety (New-CIPolicy, Merge-CIPolicy) pre garantovanu
    spravnu strukturu XML. Generuje .bin subor pripraveny na nahratie do Intune.
    Instalator ChromeSetup.exe je nutne umiestnit do pracovneho adresara pred spustenim.
.NOTES
    Verzia: 3.0
    Autor: Ing. Marek Findrik
    Pozadovane moduly: ConfigCI (Windows)
    Datum vytvorenia: 29.05.2025
    Logovanie: C:\TaurisIT\Log\WDACChromeBlock
#>

Import-Module "$env:ProgramFiles\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1" -ErrorAction Stop

# --- Konfiguracia ---
$pracovnyAdresar   = "D:\findrik\PowerShell\WDAC"
$instalatorSubor   = Join-Path $pracovnyAdresar "ChromeSetup.exe"
$xmlFileName       = Join-Path $pracovnyAdresar "ChromeDenyFileName.xml"
$xmlPublisher      = Join-Path $pracovnyAdresar "ChromeDenyPublisher.xml"
$xmlFinal          = Join-Path $pracovnyAdresar "ChromeDenyCombined.xml"
$cipSubor          = Join-Path $pracovnyAdresar "ChromeDenyCombined.cip"
$binSubor          = Join-Path $pracovnyAdresar "ChromeDenyCombined.bin"
$base64Subor       = Join-Path $pracovnyAdresar "ChromeDenyCombined_base64.txt"

$logParams = @{
    EventSource  = "WDACChromeBlock"
    EventLogName = "Application"
    LogFileName  = "WDACChromeBlock"
}

# --- Funkcie ---
function Zapis-Log {
    param(
        [string] $sprava,
        [string] $typ = "Information"
    )
    Write-CustomLog -Message $sprava -Type $typ @logParams
    Write-Host $sprava
}

function Over-ConfigCI {
    foreach ($cmd in @("New-CIPolicy", "New-CIPolicyRule", "Merge-CIPolicy", "ConvertFrom-CIPolicy")) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Prikaz $cmd nebol najdeny. Skript je nutne spustit na Windows s modulom ConfigCI (Windows 10 1903+)."
        }
    }
}

function Generuj-FileNamePolicy {
    Zapis-Log "Generovanie Deny policy podla nazvu suboru..."

    # FileName policy piseme priamo v XML - New-CIPolicy -Rules ma problem s deserializaciou objektov
    # Struktura je kompatibilna s Merge-CIPolicy aj ConvertFrom-CIPolicy
    $xmlObsah = @"
<?xml version="1.0" encoding="utf-8"?>
<SiPolicy xmlns="urn:schemas-microsoft-com:sipolicy">
  <VersionEx>10.0.0.0</VersionEx>
  <PlatformID>{2E07F7E4-194C-4D20-B7C9-6F44A6C5A234}</PlatformID>
  <Rules>
    <Rule><Option>Enabled:Unsigned System Integrity Policy</Option></Rule>
    <Rule><Option>Enabled:Advanced Boot Options Menu</Option></Rule>
    <Rule><Option>Required:Enforce Store Applications</Option></Rule>
  </Rules>
  <EKUs />
  <FileRules>
    <Deny ID="ID_DENY_CHROME_1" FriendlyName="Chrome Offline Installer"    FileName="ChromeSetup.exe"                           MinimumFileVersion="0.0.0.0" />
    <Deny ID="ID_DENY_CHROME_2" FriendlyName="Chrome Online Installer"     FileName="ChromeInstaller.exe"                       MinimumFileVersion="0.0.0.0" />
    <Deny ID="ID_DENY_CHROME_3" FriendlyName="Chrome Standalone Installer" FileName="chrome_installer.exe"                      MinimumFileVersion="0.0.0.0" />
    <Deny ID="ID_DENY_CHROME_4" FriendlyName="Chrome Enterprise 64bit"     FileName="googlechromestandaloneenterprise64.exe"     MinimumFileVersion="0.0.0.0" />
    <Deny ID="ID_DENY_CHROME_5" FriendlyName="Chrome Enterprise 32bit"     FileName="googlechromestandaloneenterprise.exe"       MinimumFileVersion="0.0.0.0" />
  </FileRules>
  <Signers />
  <SigningScenarios>
    <SigningScenario Value="131" ID="ID_SIGNINGSCENARIO_DRIVERS" FriendlyName="Drivers">
      <ProductSigners />
    </SigningScenario>
    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS" FriendlyName="User Mode">
      <ProductSigners>
        <FileRulesRef>
          <FileRuleRef RuleID="ID_DENY_CHROME_1" />
          <FileRuleRef RuleID="ID_DENY_CHROME_2" />
          <FileRuleRef RuleID="ID_DENY_CHROME_3" />
          <FileRuleRef RuleID="ID_DENY_CHROME_4" />
          <FileRuleRef RuleID="ID_DENY_CHROME_5" />
        </FileRulesRef>
      </ProductSigners>
    </SigningScenario>
  </SigningScenarios>
  <UpdatePolicySigners />
  <CiSigners />
  <HvciOptions>0</HvciOptions>
  <PolicyTypeID>{A244370E-44C9-4C06-B551-F6016E563076}</PolicyTypeID>
</SiPolicy>
"@
    $xmlObsah | Out-File -FilePath $xmlFileName -Encoding UTF8 -Force
    Zapis-Log "FileName policy ulozena: $xmlFileName"
}

function Generuj-PublisherPolicy {
    Zapis-Log "Generovanie Deny policy podla Publisher certifikatu..."

    if (-not (Test-Path $instalatorSubor)) {
        Zapis-Log "UPOZORNENIE: $instalatorSubor neexistuje - preskakujem Publisher policy." -typ "Warning"
        return $false
    }

    $podpis = Get-AuthenticodeSignature -FilePath $instalatorSubor
    if ($podpis.Status -ne "Valid") {
        Zapis-Log "UPOZORNENIE: Instalator nema platny podpis (status: $($podpis.Status))." -typ "Warning"
        return $false
    }

    $cert = $podpis.SignerCertificate
    Zapis-Log "Najdeny podpis: $($cert.Subject)"
    Zapis-Log "Vydavatel    : $($cert.Issuer)"
    Zapis-Log "Thumbprint   : $($cert.Thumbprint)"

    # Generuj Allow policy na urovni Publisher a konvertuj Deny cez XML
    $xmlTemp = Join-Path $pracovnyAdresar "TempPublisher.xml"
    New-CIPolicy -DriverFiles $instalatorSubor -Level Publisher -FilePath $xmlTemp -ErrorAction Stop

    # Konverzia Allow->Deny v XML
    [xml] $xml = Get-Content $xmlTemp -Encoding UTF8
    $ns  = "urn:schemas-microsoft-com:sipolicy"
    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsm.AddNamespace("si", $ns)

    foreach ($node in @($xml.SelectNodes("//si:Allow", $nsm))) {
        $deny = $xml.CreateElement("Deny", $ns)
        foreach ($a in $node.Attributes) { $deny.SetAttribute($a.Name, $a.Value) }
        $node.ParentNode.ReplaceChild($deny, $node) | Out-Null
    }
    foreach ($node in @($xml.SelectNodes("//si:AllowedSigner", $nsm))) {
        $denied = $xml.CreateElement("DeniedSigner", $ns)
        foreach ($a in $node.Attributes) { $denied.SetAttribute($a.Name, $a.Value) }
        $node.ParentNode.ReplaceChild($denied, $node) | Out-Null
    }
    foreach ($node in @($xml.SelectNodes("//si:AllowedSigners", $nsm))) {
        $denied = $xml.CreateElement("DeniedSigners", $ns)
        foreach ($child in @($node.ChildNodes)) { $denied.AppendChild($child.Clone()) | Out-Null }
        $node.ParentNode.ReplaceChild($denied, $node) | Out-Null
    }

    $xml.Save($xmlPublisher)
    Remove-Item $xmlTemp -Force -ErrorAction SilentlyContinue
    Zapis-Log "Publisher Deny policy ulozena: $xmlPublisher"
    return $true
}

function Zluc-AKonvertuj {
    param([bool] $publisherDostupny)

    if ($publisherDostupny) {
        Zapis-Log "Zlucovanie FileName a Publisher policy cez Merge-CIPolicy..."
        Merge-CIPolicy -PolicyPaths $xmlFileName, $xmlPublisher `
                       -OutputFilePath $xmlFinal `
                       -ErrorAction Stop
        Zapis-Log "Kombinovana policy ulozena: $xmlFinal"
    } else {
        Zapis-Log "Publisher policy nie je dostupna - pouziva sa iba FileName policy."
        Copy-Item $xmlFileName $xmlFinal -Force
    }

    # Konverzia na Multiple Policy Format s vlastnym unikatnym GUID
    # ApplicationControl CSP vyzaduje tento format (legacy format cez CSP nefunguje)
    Zapis-Log "Nastavenie Multiple Policy Format a unikatneho PolicyID..."
    $novyGuid = "{" + [System.Guid]::NewGuid().ToString().ToUpper() + "}"
    Set-CIPolicyIdInfo -FilePath $xmlFinal `
                       -PolicyName "WDAC-Block-Chrome" `
                       -PolicyId $novyGuid `
                       -ResetPolicyID `
                       -ErrorAction Stop
    Zapis-Log "Novy PolicyID: $novyGuid"

    # Uloz GUID do suboru pre referenciu pri OMA-URI
    $novyGuid | Out-File (Join-Path $pracovnyAdresar "PolicyID.txt") -Encoding ASCII -Force

    Zapis-Log "Konverzia do binarneho formatu..."
    ConvertFrom-CIPolicy -XmlFilePath $xmlFinal -BinaryFilePath $cipSubor -ErrorAction Stop

    if (-not (Test-Path $cipSubor)) {
        throw "ConvertFrom-CIPolicy nevytvoril .cip subor - skontroluj obsah $xmlFinal"
    }
    Zapis-Log "Binarny .cip subor vytvoreny: $cipSubor"

    Copy-Item $cipSubor $binSubor -Force
    Zapis-Log "Intune .bin subor vytvoreny: $binSubor"

    $bytes  = [System.IO.File]::ReadAllBytes($cipSubor)
    $base64 = [Convert]::ToBase64String($bytes)
    $base64 | Out-File $base64Subor -Encoding ASCII -Force
    Zapis-Log "Base64 subor ulozeny: $base64Subor"
}

function Vypis-Instrukcie {
    param([bool] $publisherDostupny)

    # Ziskaj PolicyID z ulozeneho suboru (nastaveny cez Set-CIPolicyIdInfo)
    $policyIdSubor = Join-Path $pracovnyAdresar "PolicyID.txt"
    if (Test-Path $policyIdSubor) {
        $policyId = (Get-Content $policyIdSubor -Raw).Trim()
    } else {
        # Fallback - precitaj priamo z XML
        [xml] $xmlDoc = Get-Content $xmlFinal -Encoding UTF8
        $nsm2         = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsm2.AddNamespace("si", "urn:schemas-microsoft-com:sipolicy")
        $policyId     = $xmlDoc.SelectSingleNode("//si:PolicyID", $nsm2).'#text'
        if (-not $policyId) { $policyId = "SKONTROLUJ PolicyID.txt" }
    }

    $omaUri = "./Vendor/MSFT/ApplicationControl/Policies/$policyId/Policy"
    $rezim  = if ($publisherDostupny) { "FileName + Publisher (kombinovana)" } else { "FileName only" }

    Write-Host ""
    Write-Host "=== INSTRUKCIE PRE INTUNE ===" -ForegroundColor Cyan
    Write-Host "Devices > Configuration > Create > Windows 10 and later > Templates > Custom" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Rezim policy : $rezim"           -ForegroundColor $(if ($publisherDostupny) {"Green"} else {"Yellow"})
    Write-Host "OMA-URI      : $omaUri"           -ForegroundColor Green
    Write-Host "Data type    : Base64 (file)"     -ForegroundColor Green
    Write-Host "Nahrat subor : $binSubor"         -ForegroundColor Green
    Write-Host ""
    Write-Host "Generovane subory:" -ForegroundColor Cyan
    @($xmlFileName, $xmlPublisher, $xmlFinal, $cipSubor, $binSubor, $base64Subor) | ForEach-Object {
        if (Test-Path $_) { Write-Host "  [OK] $_" -ForegroundColor Green }
    }

    Zapis-Log "OMA-URI: $omaUri"
    Zapis-Log "Nahrat subor: $binSubor"
}

# --- Hlavna cast ---
try {
    Zapis-Log "Spustenie skriptu New-WDACChromeBlock v3.0"

    if (-not (Test-Path $pracovnyAdresar)) {
        New-Item -ItemType Directory -Path $pracovnyAdresar -Force | Out-Null
        Zapis-Log "Vytvoreny adresar: $pracovnyAdresar"
    }

    Over-ConfigCI
    Generuj-FileNamePolicy
    $publisherOk = Generuj-PublisherPolicy
    Zluc-AKonvertuj -publisherDostupny $publisherOk
    Vypis-Instrukcie -publisherDostupny $publisherOk

    Zapis-Log "Skript uspesne dokonceny."

} catch {
    Zapis-Log "CHYBA: $($_.Exception.Message)" -typ "Error"
    Write-Host "CHYBA: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}