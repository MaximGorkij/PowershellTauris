# Install.ps1 - Hlavny instalacny skript pre Intune Win32 aplikaciu
# Urcuje lokaciju podla IP adresy z IPLocationMap.json, nacita citlive udaje z .env suboru,
# zapisuje do Entra ID extensionAttribute1 cez Microsoft Graph.
# Logovanie cez LogHelper.psm1 (nainstalovany v C:\Program Files\WindowsPowerShell\Modules\LogHelper).
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
    - Loguje cely proces do C:\TaurisIT\Log\IPLoc\IPcheck.log cez LogHelper modul.
.NOTES
    - Vyzaduje Microsoft.Graph moduly (instaluje sa automaticky ak chybaju).
    - Vyzaduje LogHelper modul (C:\Program Files\WindowsPowerShell\Modules\LogHelper).
    - Permissions: App Registration s Device.ReadWrite.All (Application permission, admin consent).
    - Bezpecnost: .env je plain text - nepouzivat v produkcii bez sifrovania!
    - Detection rule v Intune: File exists C:\TaurisIT\Log\IPLoc\IPcheck.log.
    - Install command: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1
#>

# ============================================================================
# AUTOMATICKA DETEKCIA 32-BIT A RESTART AKO 64-BIT (WoW64 FIX)
# ============================================================================
# Intune casto spusta skripty v 32-bit PowerShell (WoW64 redirection)
# To spôsobuje problémy s modulmi a Event Log zdrojmi. Prinutime 64-bit spustenie.
if ([System.Environment]::Is64BitProcess -eq $false) {
    # Aktualne sme v 32-bit PowerShell, restartuj ako 64-bit
    $ps64bit = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $ps64bit) {
        $scriptPath = $PSCommandPath
        $invokeArgs = @(
            "-NoProfile"
            "-ExecutionPolicy", "Bypass"
            "-File", $scriptPath
        )
        & $ps64bit @invokeArgs
        exit $LASTEXITCODE
    }
}
# Ak sme sem dosli, sme v 64-bit PowerShell - pokracuj normalne.

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
$EventSource = "IntuneAppInstall"

# Test a vytvorenie cesty k logom ak neexistuje
if (-not (Test-Path -Path $LogDir)) {
    $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# VYTVORENIE EVENT LOG ZDROJA BEZNE (bez závislosti na LogHelper)
# ============================================================================
# Toto sa spúšťa vždy, aby sa zaistilo, že Event Log zdroj existuje
# Ak zlyhá (napr. z bezpečnostných dôvodov), pokračujeme s fallback loganím
function Ensure-EventLogSource {
    param (
        [string]$Source,
        [string]$LogName = "Application"
    )
    
    try {
        if (-not ([System.Diagnostics.EventLog]::SourceExists($Source))) {
            New-EventLog -LogName $LogName -Source $Source -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Ignoruj chyby - pokračuj s fallback loganím
    }
}

Ensure-EventLogSource -Source $EventSource

# Import LogHelper modulu
$logHelperPath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper"
if (Test-Path $logHelperPath) {
    try {
        Import-Module LogHelper -ErrorAction Stop
        $logHelperAvailable = $true
    }
    catch {
        Write-Host "Upozornenie: LogHelper modul sa nepodarilo importovať. Používam fallback logging." -ForegroundColor Yellow
        $logHelperAvailable = $false
    }
}
else {
    Write-Host "Upozornenie: LogHelper modul sa nenasiel na $logHelperPath. Používam fallback logging." -ForegroundColor Yellow
    $logHelperAvailable = $false
}

# ============================================================================
# FALLBACK LOGGING FUNKCIA (ak LogHelper nie je dostupný)
# ============================================================================
# Táto funkcia sa používa v prípade, že LogHelper modul nie je dostupný
if (-not (Get-Command Write-IntuneLog -ErrorAction SilentlyContinue)) {
    function Write-IntuneLog {
        param (
            [string]$Message,
            [string]$Level = "INFO",
            [string]$LogFile,
            [string]$EventSource
        )
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        
        # Zapíš do textového logu
        try {
            Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch { }
        
        # Zapíš do Event Logu ak je zdroj dostupný
        if (-not [string]::IsNullOrEmpty($EventSource)) {
            try {
                if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                    $eventLog = New-Object System.Diagnostics.EventLog("Application")
                    $eventLog.Source = $EventSource
                    $eventType = switch ($Level) {
                        "ERROR" { "Error" }
                        "WARNING" { "Warning" }
                        "SUCCESS" { "Information" }
                        "OK" { "Information" }
                        "INFO" { "Information" }
                        "DEBUG" { "Information" }
                        default { "Information" }
                    }
                    $eventLog.WriteEntry($Message, $eventType, 1000)
                }
            }
            catch { }
        }
        
        # Výstup do konzoly
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            "OK" { "Green" }
            default { "Gray" }
        }
        Write-Host $logEntry -ForegroundColor $color -ErrorAction SilentlyContinue
    }
}

# Inicializacia log systemu cez LogHelper
if ($logHelperAvailable) {
    try {
        Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30 -ErrorAction SilentlyContinue
    }
    catch {
        # Pokracuj aj ak inicializacia zlyhá
    }
}

# Zaciatok logovania
try {
    Write-IntuneLog -Message "========== ZACIATOK INSTALACIE WIN32 APP ==========" -Level "SUCCESS" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "Urcenie lokacie podla IP adresy." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "Cesta k logom: $LogDir" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "Skripty spusteny v kontexte: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
}
catch {
    Write-Host "Logovacie info: $_ - pokracujem s fallback loganim" -ForegroundColor Yellow
}

try {
    # Nacitaj .env
    Write-IntuneLog -Message "Nacitavam .env subor..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
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
    Write-IntuneLog -Message ".env subor nacitany uspesne. ClientId: $([string]::Concat($ClientId.Substring(0, [Math]::Min(4, $ClientId.Length)), '****'))" -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Nacitaj IPLocationMap.json
    Write-IntuneLog -Message "Nacitavam IPLocationMap.json..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $JsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $JsonPath)) {
        throw "IPLocationMap.json sa nenasiel na ceste: $JsonPath."
    }
    $jsonContent = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }
    Write-IntuneLog -Message "IPLocationMap.json nacitany - pocet prefixov: $($ipMap.Count). Prefixvy: $($ipMap.Keys -join ', ')." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Ziskaj aktualnu IP (prva aktivna v 10.x rozsahu)
    Write-IntuneLog -Message "Vyhladavam aktualnu IP adresu v rozsahu 10.x.x.x..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $ipAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' })
    if ($ipAddresses.Count -eq 0) {
        throw "Nenasla sa ziadna aktivna IP adresa v rozsahu 10.x.x.x."
    }
    $currentIP = ($ipAddresses | Select-Object -First 1).IPAddress
    Write-IntuneLog -Message "Aktualna IP adresa: $currentIP." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Urcenie lokacije - longest prefix match
    Write-IntuneLog -Message "Urcujem lokaciu pomocou longest prefix match..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $location = $null
    $longestPrefix = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($currentIP.StartsWith($prefix) -and $prefix.Length -gt $longestPrefix.Length) {
            $longestPrefix = $prefix
            $location = $ipMap[$prefix]
            Write-IntuneLog -Message "  -> Prefix match: $prefix => lokacia: $location" -Level "DEBUG" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
        }
    }
    if ([string]::IsNullOrEmpty($location)) {
        throw "Pre IP $currentIP sa nenasla ziadna zodpovedajuca lokacia v mape."
    }
    Write-IntuneLog -Message "VYSLEDOK: Lokacia '$location' (prefix: '$longestPrefix' pre IP: $currentIP)" -Level "SUCCESS" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Instalacija len potrebnych Graph modulov ak chybaju
    Write-IntuneLog -Message "Kontrolujem dostupnost Microsoft.Graph modulov..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Write-IntuneLog -Message "Microsoft.Graph moduly nie su nainstalovane, instalujem..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
        Write-IntuneLog -Message "Microsoft.Graph moduly uspesne nainstalovane." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    }
    else {
        Write-IntuneLog -Message "Microsoft.Graph moduly su uz nainstalovane." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Write-IntuneLog -Message "Microsoft.Graph moduly nacitane do session." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Autentifikacia k Microsoft Graph (client credentials flow)
    Write-IntuneLog -Message "Autentifikujem sa k Microsoft Graph..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $authBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $accessToken = $tokenResponse.access_token
    Write-IntuneLog -Message "Access token ziskany uspesne." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Graph SDK v2 vyzaduje SecureString pre -AccessToken
    Write-IntuneLog -Message "Pripajam sa k Microsoft Graph SDK..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    Write-IntuneLog -Message "Uspesne pripojene k Microsoft Graph." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Ziskenie device objektu - Select-Object -First 1 pre pripad viacerych zariadeni s rovnakym menom
    Write-IntuneLog -Message "Vyhladavam zariadenie v Entra ID..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $deviceName = $env:COMPUTERNAME
    Write-IntuneLog -Message "Meno zariadenia: $deviceName" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id, displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) {
        throw "Zariadenie '$deviceName' sa nenaslo v Entra ID."
    }
    Write-IntuneLog -Message "Zariadenie najdene - ID: $($device.id)" -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Aktualizacia extensionAttribute1
    Write-IntuneLog -Message "Aktualizujem extensionAttribute1 na hodnotu: $location" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $updateBody = ConvertTo-Json -InputObject @{
        extensionAttribute1 = $location
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $updateBody -ContentType "application/json" -ErrorAction Stop

    Write-IntuneLog -Message "Lokacia '$location' zapisana do extensionAttribute1 pre zariadenie '$deviceName'." -Level "SUCCESS" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Cistenie starych logov
    Write-IntuneLog -Message "Cistim stare logy (retention: 30 dni)..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    if (Get-Command Clear-OldLogs -ErrorAction SilentlyContinue) {
        Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir
    }
    Write-IntuneLog -Message "Cistenie logov uspesne dokoncene." -Level "OK" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "========== INSTALACIA USPESNE DOKONCENA ==========" -Level "SUCCESS" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    # Volitelne: Nastavenie detekcneho registry kluca pre Intune (ak chces registry detection rule)
    New-Item -Path "HKLM:\SOFTWARE\TaurisIT\IPLocation" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\TaurisIT\IPLocation" -Name "LastLocation" -Value $location -Type String

    exit 0  # uspech - Intune oznaci ako Installed
}
catch {
    $errorMessage = $_.Exception.Message
    $errorStackTrace = $_.ScriptStackTrace
    Write-IntuneLog -Message "========== CHYBA POCAS SPRACOVANIA ==========" -Level "ERROR" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "Chyba: $errorMessage" -Level "ERROR" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "Stack trace: $errorStackTrace" -Level "DEBUG" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    if (Get-Command Send-IntuneAlert -ErrorAction SilentlyContinue) {
        Send-IntuneAlert -Message "Chyba v IP lokacia app: $errorMessage" -Severity Error -EventSource $EventSource -LogFile $LogFile
    }
    exit 1  # Chyba - Intune oznaci ako Failed
}
finally {
    # Odpojenie Graph
    Write-IntuneLog -Message "Odpajam sa od Microsoft Graph..." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
    Write-IntuneLog -Message "Skript ukonceny." -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
}
