<#
.SYNOPSIS
    Synchronizacia Exchange Online Tenant Allow/Block List do SharePoint zoznamu.
.DESCRIPTION
    Skript nacita aktualny stav blokovacich/allow zoznamov z Exchange Online,
    porovna ho s predchadzajucim stavom v SharePoint zozname EvidenciaBlocklistu
    a zaznamena zmeny (Added/Removed) s casovou peciatkou.
.PARAMETER PfxHeslo
    Heslo pre PFX certifikat (SecureString). Ak nie je zadane, skript sa spyta interaktivne.
.NOTES
    Verzia: 1.1
    Autor: Automaticky report
    Pozadovane moduly: ExchangeOnlineManagement, Microsoft.Graph.Authentication, Microsoft.Graph.Sites
    Datum vytvorenia: 26.05.2026
    Logovanie: C:\TaurisIT\Log\EXOBlocklistSync\EXOBlocklistSync.log
#>
param(
    [SecureString]$PfxHeslo
)

Import-Module "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1" -ErrorAction Stop
Import-Module ExchangeOnlineManagement -RequiredVersion 3.7.1 -Force -ErrorAction Stop

# --- Konfiguracia ---
$TenantId        = "ebf9edb5-a5f7-4d70-9a59-501865f222ee"
$ClientId        = "1e25f59d-3aa4-4788-aa32-041881f947ad"
$PfxPath         = "C:\TaurisIT\TaurisGraphAPI_new.pfx"
$EXOOrganization = "tauris.sk"
$SPSiteUrl       = "https://tauris.sharepoint.com/sites/it_tauris"
$SPListName      = "EvidenciaBlocklistu"
$LogSource       = "EXOBlocklistSync"
$LogFile         = "EXOBlocklistSync\EXOBlocklistSync.log"

# --- Funkcia: Zapis do logu ---
function Log {
    param([string]$Msg, [string]$Type = "Information")
    Write-CustomLog -Message $Msg -EventSource $LogSource -EventLogName "Application" -LogFileName $LogFile -Type $Type
}

# --- Funkcia: Nacitaj certifikat z PFX ---
function Get-PfxCert {
    param([string]$PfxFile, [SecureString]$Heslo)
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $PfxFile,
        $Heslo,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
    )
    if (-not $cert.HasPrivateKey) {
        throw "Certifikat nema privatny kluc. Skontroluj PFX subor."
    }
    return $cert
}

# --- Funkcia: Pripojenie na Exchange Online ---
function Connect-EXO {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$X509Cert)
    Log "Pripajam sa na Exchange Online..."
    try {
        Connect-ExchangeOnline `
            -AppId $ClientId `
            -CertificateThumbprint $X509Cert.Thumbprint `
            -Organization $EXOOrganization `
            -ShowBanner:$false `
            -ErrorAction Stop
        Log "Pripojenie na Exchange Online uspesne."
    } catch {
        Log "Chyba pri pripojeni na Exchange Online: $($_.Exception.Message)" -Type "Error"
        throw
    }
}

# --- Funkcia: Pripojenie na Microsoft Graph (SharePoint) ---
function Connect-Graph {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$X509Cert)
    Log "Pripajam sa na Microsoft Graph..."
    try {
        Connect-MgGraph `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -CertificateThumbprint $X509Cert.Thumbprint `
            -NoWelcome `
            -ErrorAction Stop
        Log "Pripojenie na Microsoft Graph uspesne."
    } catch {
        Log "Chyba pri pripojeni na Microsoft Graph: $($_.Exception.Message)" -Type "Error"
        throw
    }
}

# --- Funkcia: Nacitaj aktualne polozky z EXO ---
function Get-EXOBlocklistItems {
    Log "Nacitavam polozky z Exchange Online Tenant Allow/Block List..."
    $items = @()
    try {
        $raw = Get-TenantAllowBlockListItems -ListType Sender -ErrorAction SilentlyContinue
        foreach ($i in $raw) {
            $items += [PSCustomObject]@{
                Value      = $i.Value
                TypZaznamu = if ($i.Value -match "@") { "EmailAddress" } else { "Domain" }
                Akcia      = if ($i.Action -eq "Block") { "Block" } else { "Allow" }
                Expiracia  = $i.ExpirationDate
                Poznamka   = $i.Notes
            }
        }
        $raw2 = Get-TenantAllowBlockListItems -ListType FileHash -ErrorAction SilentlyContinue
        foreach ($i in $raw2) {
            $items += [PSCustomObject]@{
                Value      = $i.Value
                TypZaznamu = "FileHash"
                Akcia      = if ($i.Action -eq "Block") { "Block" } else { "Allow" }
                Expiracia  = $i.ExpirationDate
                Poznamka   = $i.Notes
            }
        }
        $raw3 = Get-TenantAllowBlockListItems -ListType Url -ErrorAction SilentlyContinue
        foreach ($i in $raw3) {
            $items += [PSCustomObject]@{
                Value      = $i.Value
                TypZaznamu = "Url"
                Akcia      = if ($i.Action -eq "Block") { "Block" } else { "Allow" }
                Expiracia  = $i.ExpirationDate
                Poznamka   = $i.Notes
            }
        }
        Log "Nacitanych $($items.Count) poloziek z EXO."
    } catch {
        Log "Chyba pri nacitavani EXO blocklist: $($_.Exception.Message)" -Type "Error"
        throw
    }
    return $items
}

# --- Funkcia: Ziskaj Site ID zo SharePointu ---
function Get-SPSiteId {
    $hostname = ([System.Uri]$SPSiteUrl).Host
    $sitePath = ([System.Uri]$SPSiteUrl).AbsolutePath
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/sites/${hostname}:${sitePath}" `
        -ErrorAction Stop
    return $response.id
}

# --- Funkcia: Ziskaj List ID ---
function Get-SPListId {
    param([string]$SiteId)
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists?`$filter=displayName eq '$SPListName'" `
        -ErrorAction Stop
    if ($response.value.Count -eq 0) {
        throw "Zoznam '$SPListName' nebol najdeny na SharePoint stranke."
    }
    return $response.value[0].id
}

# --- Funkcia: Nacitaj existujuce zaznamy zo SharePointu ---
function Get-SPCurrentItems {
    param([string]$SiteId, [string]$ListId)
    Log "Nacitavam existujuce zaznamy zo SharePoint zoznamu..."
    $items = @{}
    $uri = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items?`$expand=fields&`$top=999"
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        foreach ($item in $response.value) {
            $f = $item.fields
            $key = "$($f.Title)|$($f.TypZaznamu)|$($f.Akcia)"
            $items[$key] = $true
        }
        $uri = $response.'@odata.nextLink'
    } while ($uri)
    Log "Nacitanych $($items.Count) zaznamov zo SharePointu."
    return $items
}

# --- Funkcia: Zapis zmenu do SharePointu ---
function Add-SPChangeRecord {
    param(
        [string]$SiteId,
        [string]$ListId,
        [string]$Value,
        [string]$TypZaznamu,
        [string]$Akcia,
        [string]$Zmena,
        [string]$Expiracia,
        [string]$Poznamka
    )
    $fields = @{
        Title        = $Value
        TypZaznamu   = $TypZaznamu
        Akcia        = $Akcia
        Zmena        = $Zmena
        DatumZmeny   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Poznamka     = if ($Poznamka) { $Poznamka } else { "" }
    }
    if ($Expiracia) { $fields["ExpiraciaEXO"] = $Expiracia }

    $body = @{ fields = $fields }
    Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items" `
        -Body ($body | ConvertTo-Json -Depth 5) `
        -ContentType "application/json" `
        -ErrorAction Stop | Out-Null
}

# ============================================================
# HLAVNY BEH
# ============================================================
try {
    Log "=== Spustenie synchronizacie EXO Blocklist ==="

    # Kontrola modulu ExchangeOnlineManagement
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Log "Modul ExchangeOnlineManagement nie je nainstalovany. Spustam instaláciu..." -Type "Warning"
        Install-Module ExchangeOnlineManagement -Scope AllUsers -Force -AllowClobber
    }

    # Kontrola modulov Microsoft.Graph
    foreach ($mod in @("Microsoft.Graph.Authentication", "Microsoft.Graph.Sites")) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Log "Modul $mod nie je nainstalovany. Spustam instaláciu..." -Type "Warning"
            Install-Module $mod -Scope AllUsers -Force -AllowClobber
        }
    }

    # Vyziadaj heslo ak nebolo zadane ako parameter
    if (-not $PfxHeslo) {
        $PfxHeslo = Read-Host -AsSecureString "Zadaj heslo pre PFX certifikat"
    }

    # Nacitaj certifikat
    Log "Nacitavam certifikat z $PfxPath..."
    $cert = Get-PfxCert -PfxFile $PfxPath -Heslo $PfxHeslo
    Log "Certifikat nacitany. Thumbprint: $($cert.Thumbprint)"

    # Skontroluj ci je certifikat v LocalMachine\My store, ak nie - nainštaluj ho
    $existujuci = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if (-not $existujuci) {
        Log "Certifikat nie je v LocalMachine\My store. Instalujem..."
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new("My", "LocalMachine")
        $store.Open("ReadWrite")
        $store.Add($cert)
        $store.Close()
        Log "Certifikat nainstalovany do LocalMachine\My."
    }

    # Pripojenie
    Connect-EXO $cert
    Connect-Graph $cert

    # Nacitaj aktualne EXO polozky
    $exoCmdlet = Get-Command "Get-TenantAllowBlockListItems" -ErrorAction SilentlyContinue
    if (-not $exoCmdlet) {
        Log "Get-TenantAllowBlockListItems nie je dostupny. Dostupne EXO cmdlety: $((Get-Command -Module tmp_* -ErrorAction SilentlyContinue | Select-Object -First 5 -ExpandProperty Name) -join ', ')" -Type "Warning"
    }
    $exoItems = Get-EXOBlocklistItems

    # Ziskaj SharePoint IDs
    $siteId = Get-SPSiteId
    $listId = Get-SPListId -SiteId $siteId

    # Nacitaj existujuce SP zaznamy
    $spItems = Get-SPCurrentItems -SiteId $siteId -ListId $listId

    # Zostav mnozinu aktualnych EXO klucov
    $exoKeys = @{}
    foreach ($item in $exoItems) {
        $key = "$($item.Value)|$($item.TypZaznamu)|$($item.Akcia)"
        $exoKeys[$key] = $item
    }

    $addedCount   = 0
    $removedCount = 0

    # Porovnaj - nove polozky (Added)
    foreach ($key in $exoKeys.Keys) {
        if (-not $spItems.ContainsKey($key)) {
            $i = $exoKeys[$key]
            Log "Pridana nova polozka: $($i.Value) [$($i.TypZaznamu)] [$($i.Akcia)]"
            Add-SPChangeRecord `
                -SiteId $siteId `
                -ListId $listId `
                -Value $i.Value `
                -TypZaznamu $i.TypZaznamu `
                -Akcia $i.Akcia `
                -Zmena "Added" `
                -Expiracia $i.Expiracia `
                -Poznamka $i.Poznamka
            $addedCount++
        }
    }

    # Porovnaj - odstranene polozky (Removed)
    foreach ($key in $spItems.Keys) {
        if (-not $exoKeys.ContainsKey($key)) {
            $parts = $key -split "\|"
            Log "Odstranena polozka: $($parts[0]) [$($parts[1])] [$($parts[2])]"
            Add-SPChangeRecord `
                -SiteId $siteId `
                -ListId $listId `
                -Value $parts[0] `
                -TypZaznamu $parts[1] `
                -Akcia $parts[2] `
                -Zmena "Removed" `
                -Expiracia $null `
                -Poznamka ""
            $removedCount++
        }
    }

    Log "Synchronizacia dokoncena. Pridane: $addedCount, Odstranene: $removedCount"

} catch {
    Log "Kriticka chyba: $($_.Exception.Message)" -Type "Error"
    exit 1
} finally {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}
    Log "=== Koniec synchronizacie ==="
}