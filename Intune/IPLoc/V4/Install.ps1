# Install.ps1 - Hlavny instalacny skript pre Intune Win32 aplikaciu
# Urcuje lokaciju podla IP adresy z IPLocationMap.json, nacita citlive udaje z .env suboru,
# zapisuje do Entra ID extensionAttribute1 cez Microsoft Graph.
# Logovanie cez LogHelper.psm1 (predpokladame, ze je nainstalovany v C:\Program Files\WindowsPowerShell\Modules\LogHelper).
# Spusta sa v SYSTEM kontexte cez Intune.

<#
.SYNOPSIS
    Intune Win32 app - Nastavi lokaciju v Entra ID extensionAttribute1 podla aktualnej IP.
    Citlive udaje (ClientId, TenantId, ClientSecret) su v .env subore.
.DESCRIPTION
    - Nacita .env pre autentifikaciu.
    - Nacita IPLocationMap.json pre mapovanie IP prefixov na lokacje.
    - Ziskuje aktualnu internu IP (10.x rozsah).
    - Urci lokaciju pomocou longest prefix match.
    - Pripoji sa k Microsoft Graph pomocou client credentials flow.
    - Aktualizuje extensionAttribute1 na device objekte.
    - Loguje cely proces do C:\TaurisIT\Log\IPcheck\IPcheck.log.
.NOTES
    - Vyzaduje Microsoft.Graph moduly (instaluje sa automaticky ak chybaju).
    - Permissions: App Registration s Device.ReadWrite.All (Application permission, admin consent).
    - Bezpecnost: .env je plain text - nepouzivat v produkcii bez sifrovania!
    - Detection rule v Intune: File exists C:\TaurisIT\Log\IPcheck\IPcheck.log.
    - Install command: powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1
#>

# Wrapper na Write-IntuneLog - kombinuje LogHelper modul s Write-Host
# LogHelper: https://github.com/YOUR_ORG/LogHelper
function Write-ProcessLog {
    param (
        [string]$Message,
        [string]$Level = "INFO",
        [string]$LogFile,
        [string]$EventSource
    )
    
    # 1. Zapis do LogFile a Event Log cez LogHelper modul
    if (Get-Command Write-IntuneLog -ErrorAction SilentlyContinue) {
        Write-IntuneLog -Message $Message -Level $Level -LogFile $LogFile -EventSource $EventSource
    }
    
    # 2. Write-Host s farbou a casovou peciatkou (Intune ho automaticky zachytava)
    $color = switch ($Level) {
        "INFO" { "Cyan" }
        "OK" { "Green" }
        "SUCCESS" { "Yellow" }
        "DEBUG" { "DarkCyan" }
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        default { "White" }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Funkcia na nacitanie .env suboru (bez externych modulov)
function Import-DotEnv {
    param (
        [string]$Path = (Join-Path $PSScriptRoot ".env")
    )

    if (-not (Test-Path $Path)) {
        throw ".env subor sa nenasiel na ceste: $Path. Skript nemoze pokracovat bez autentifikacsnych udajov."
    }

    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#') { return }  # Ignoruj komentare
        if ($line -match '^\s*$') { return }  # Ignoruj prazde riadky
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -match '^["`"](.*)[\"`"]$') { $value = $matches[1] }  # Odstran uvodzovky
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

# Nastavenia logovania
$LogDir = "C:\TaurisIT\Log\IPLoc"
$LogFile = Join-Path $LogDir "IPcheck.log"
$EventSource = "IntuneAppInstall"  # Pre inštaláciu; pre detection/remediation by bolo "IntuneScript"

# Test a vytvorenie cesty k logom ak neexistuje
try {
    if (-not (Test-Path -Path $LogDir)) {
        Write-ProcessLog -Message "Cesta $LogDir neexistuje. Vytvaram..." -Level INFO -LogFile $LogFile -EventSource $EventSource
        $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction Stop
        Write-ProcessLog -Message "Cesta $LogDir vytvorena uspesne." -Level OK -LogFile $LogFile -EventSource $EventSource
    }
    else {
        Write-ProcessLog -Message "Cesta $LogDir uz existuje." -Level OK -LogFile $LogFile -EventSource $EventSource
    }
}
catch {
    $errorMsg = $_.Exception.Message
    Write-ProcessLog -Message "Chyba pri vytvarani cesty $LogDir : $errorMsg" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    exit 1
}

# Import LogHelper modulu
try {
    Write-ProcessLog -Message "Nacitavam modul LogHelper..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    Import-Module LogHelper -ErrorAction Stop
    Write-ProcessLog -Message "Modul LogHelper nacitany uspesne." -Level OK -LogFile $LogFile -EventSource $EventSource
}
catch {
    $errorMsg = $_.Exception.Message
    Write-ProcessLog -Message "Chyba pri nacitavani modulu LogHelper: $errorMsg" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    exit 1
}

# Inicializacia log systemu
try {
    Write-ProcessLog -Message "Inicializujem log system..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
    Write-ProcessLog -Message "Log system inicializovany." -Level OK -LogFile $LogFile -EventSource $EventSource
}
catch {
    $errorMsg = $_.Exception.Message
    Write-ProcessLog -Message "Chyba pri inicializacii log systemu: $errorMsg" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    exit 1
}

# Zaciatok logovania
Write-ProcessLog -Message "========== ZACIATOK INSTALACIE WIN32 APP ==========" -Level SUCCESS -LogFile $LogFile -EventSource $EventSource
Write-ProcessLog -Message "Urcenie lokacie podla IP adresy." -Level INFO -LogFile $LogFile -EventSource $EventSource
Write-ProcessLog -Message "Cesta k logom: $LogDir" -Level INFO -LogFile $LogFile -EventSource $EventSource
Write-ProcessLog -Message "Skripty spusteny v kontexte: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level INFO -LogFile $LogFile -EventSource $EventSource

try {
    # Nacitaj .env
    Write-ProcessLog -Message "Nacitavam .env subor..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    Import-DotEnv
    $ClientId = $env:GRAPH_CLIENT_ID
    $TenantId = $env:GRAPH_TENANT_ID
    $ClientSecret = $env:GRAPH_CLIENT_SECRET

    if ([string]::IsNullOrEmpty($ClientId)) {
        throw "GRAPH_CLIENT_ID v .env je prazdny alebo chyba."
    }
    if ([string]::IsNullOrEmpty($TenantId)) {
        throw "GRAPH_TENANT_ID v .env je prazdny alebo chyba."
    }
    if ([string]::IsNullOrEmpty($ClientSecret)) {
        throw "GRAPH_CLIENT_SECRET v .env je prazdny alebo chyba."
    }
    Write-ProcessLog -Message ".env subor nacitany uspesne. ClientId: $([string]::Concat($ClientId.Substring(0, [Math]::Min(4, $ClientId.Length)), '****'))" -Level OK -LogFile $LogFile -EventSource $EventSource

    # Nacitaj IPLocationMap.json
    Write-ProcessLog -Message "Nacitavam IPLocationMap.json..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $JsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $JsonPath)) {
        throw "IPLocationMap.json sa nenasiel na ceste: $JsonPath."
    }
    # ConvertFrom-Json -AsHashtable nie je podporovane v PS 5.1 (Intune default)
    $jsonContent = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }
    Write-ProcessLog -Message "IPLocationMap.json nacitany - pocet prefixov: $($ipMap.Count). Prefixvy: $($ipMap.Keys -join ', ')." -Level OK -LogFile $LogFile -EventSource $EventSource

    # Ziskaj aktualnu IP (prva aktivna v 10.x rozsahu)
    Write-ProcessLog -Message "Vyhladavam aktualnu IP adresu v rozsahu 10.x.x.x..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $ipAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' })
    if ($ipAddresses.Count -eq 0) {
        throw "Nenasla sa ziadna aktivna IP adresa v rozsahu 10.x.x.x."
    }
    $currentIP = ($ipAddresses | Select-Object -First 1).IPAddress
    Write-ProcessLog -Message "Aktualna IP adresa: $currentIP." -Level OK -LogFile $LogFile -EventSource $EventSource

    # Urcenie lokacije - longest prefix match
    Write-ProcessLog -Message "Urcujem lokaciju pomocou longest prefix match..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $location = $null
    $longestPrefix = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($currentIP.StartsWith($prefix) -and $prefix.Length -gt $longestPrefix.Length) {
            $longestPrefix = $prefix
            $location = $ipMap[$prefix]
            Write-ProcessLog -Message "  -> Prefix match: $prefix => lokacia: $location" -Level DEBUG -LogFile $LogFile -EventSource $EventSource
        }
    }
    if ([string]::IsNullOrEmpty($location)) {
        throw "Pre IP $currentIP sa nenasla ziadna zodpovedajuca lokacia v mape."
    }
    Write-ProcessLog -Message "VYSLEDOK: Lokacia '$location' (prefix: '$longestPrefix' pre IP: $currentIP)" -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

    # Instalacija len potrebnych Graph modulov ak chybaju
    Write-ProcessLog -Message "Kontrolujem dostupnost Microsoft.Graph modulov..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Write-ProcessLog -Message "Microsoft.Graph moduly nie su nainstalovane, instalujem..." -Level INFO -LogFile $LogFile -EventSource $EventSource
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
        Write-ProcessLog -Message "Microsoft.Graph moduly uspesne nainstalovane." -Level OK -LogFile $LogFile -EventSource $EventSource
    }
    else {
        Write-ProcessLog -Message "Microsoft.Graph moduly su uz nainstalovane." -Level OK -LogFile $LogFile -EventSource $EventSource
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Write-ProcessLog -Message "Microsoft.Graph moduly nacitane do session." -Level OK -LogFile $LogFile -EventSource $EventSource

    # Autentifikacia k Microsoft Graph (client credentials flow)
    Write-ProcessLog -Message "Autentifikujem sa k Microsoft Graph..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $authBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $accessToken = $tokenResponse.access_token
    Write-ProcessLog -Message "Access token ziskany uspesne." -Level OK -LogFile $LogFile -EventSource $EventSource

    # Graph SDK v2 vyzaduje SecureString pre -AccessToken
    Write-ProcessLog -Message "Pripajam sa k Microsoft Graph SDK..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    Write-ProcessLog -Message "Uspesne pripojene k Microsoft Graph." -Level OK -LogFile $LogFile -EventSource $EventSource

    # Ziskenie device objektu - Select-Object -First 1 pre pripad viacerych zariadeni s rovnakym menom
    Write-ProcessLog -Message "Vyhladavam zariadenie v Entra ID..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $deviceName = $env:COMPUTERNAME
    Write-ProcessLog -Message "Meno zariadenia: $deviceName" -Level INFO -LogFile $LogFile -EventSource $EventSource
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id, displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) {
        throw "Zariadenie '$deviceName' sa nenaslo v Entra ID."
    }
    Write-ProcessLog -Message "Zariadenie najdene - ID: $($device.id)" -Level OK -LogFile $LogFile -EventSource $EventSource

    # Aktualizacia extensionAttribute1
    Write-ProcessLog -Message "Aktualizujem extensionAttribute1 na hodnotu: $location" -Level INFO -LogFile $LogFile -EventSource $EventSource
    $updateBody = ConvertTo-Json -InputObject @{
        extensionAttribute1 = $location
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $updateBody -ContentType "application/json" -ErrorAction Stop

    Write-ProcessLog -Message "Lokacia '$location' zapisana do extensionAttribute1 pre zariadenie '$deviceName'." -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

    # Cistenie starych logov
    Write-ProcessLog -Message "Cisim stare logy (retention: 30 dni)..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir
    Write-ProcessLog -Message "Cistenie logov uspesne dokoncene." -Level OK -LogFile $LogFile -EventSource $EventSource
    Write-ProcessLog -Message "========== INSTALACIA USPESNE DOKONCENA ==========" -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

    # Volitelne: Nastavenie detekczesneho registry kluca pre Intune (ak chces registry detection rule)
    # New-Item -Path "HKLM:\SOFTWARE\TaurisIT\IPLocation" -Force | Out-Null
    # Set-ItemProperty -Path "HKLM:\SOFTWARE\TaurisIT\IPLocation" -Name "LastLocation" -Value $location -Type String

    exit 0  # uspech - Intune oznaci ako Installed
}
catch {
    $errorMessage = $_.Exception.Message
    $errorStackTrace = $_.ScriptStackTrace
    Write-ProcessLog -Message "========== CHYBA POCAS SPRACOVANIA ==========" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Write-ProcessLog -Message "Chyba: $errorMessage" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Write-ProcessLog -Message "Stack trace: $errorStackTrace" -Level DEBUG -LogFile $LogFile -EventSource $EventSource
    Write-IntuneLog -Message "[CHYBA] Chyba pocas spracovania: $errorMessage" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Write-IntuneLog -Message "[DEBUG] Stack trace: $errorStackTrace" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Send-IntuneAlert -Message "Chyba v IP lokacia app: $errorMessage" -Severity Error -EventSource $EventSource -LogFile $LogFile
    exit 1  # Chyba - Intune oznaci ako Failed
}
finally {
    # Odpojenie Graph
    Write-ProcessLog -Message "Odpajam sa od Microsoft Graph..." -Level INFO -LogFile $LogFile -EventSource $EventSource
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
    Write-ProcessLog -Message "Skript ukonceny." -Level INFO -LogFile $LogFile -EventSource $EventSource
}



