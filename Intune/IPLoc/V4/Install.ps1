# Install.ps1 - Hlavný inštalačný skript pre Intune Win32 aplikáciu
# Určuje lokáciu podľa IP adresy z IPLocationMap.json, načíta citlivé údaje z .env súboru,
# zapisuje do Entra ID extensionAttribute1 cez Microsoft Graph.
# Logovanie cez LogHelper.psm1 (predpokladáme, že je nainštalovaný v C:\Program Files\WindowsPowerShell\Modules\LogHelper).
# Spúšťa sa v SYSTEM kontexte cez Intune.

<#
.SYNOPSIS
    Intune Win32 app - Nastaví lokáciu v Entra ID extensionAttribute1 podľa aktuálnej IP.
    Citlivé údaje (ClientId, TenantId, ClientSecret) sú v .env súbore.
.DESCRIPTION
    - Načíta .env pre autentifikáciu.
    - Načíta IPLocationMap.json pre mapovanie IP prefixov na lokácie.
    - Získa aktuálnu internú IP (10.x rozsah).
    - Určí lokáciu pomocou longest prefix match.
    - Pripojí sa k Microsoft Graph pomocou client credentials flow.
    - Aktualizuje extensionAttribute1 na device objekte.
    - Loguje celý proces do C:\TaurisIT\Log\IPcheck\IPcheck.log.
.NOTES
    - Vyžaduje Microsoft.Graph moduly (inštaluje sa automaticky ak chýbajú).
    - Permissions: App Registration s Device.ReadWrite.All (Application permission, admin consent).
    - Bezpečnosť: .env je plain text - nepoužívať v produkcii bez šifrovania!
    - Detection rule v Intune: File exists C:\TaurisIT\Log\IPcheck\IPcheck.log.
    - Install command: powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1
#>

# Funkcia na načítanie .env súboru (bez externých modulov)
function Import-DotEnv {
    param (
        [string]$Path = (Join-Path $PSScriptRoot ".env")
    )

    if (-not (Test-Path $Path)) {
        throw ".env súbor sa nenašiel na ceste: $Path. Skript nemôže pokračovať bez autentifikačných údajov."
    }

    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#') { return }  # Ignoruj komentáre
        if ($line -match '^\s*$') { return }  # Ignoruj prázdne riadky
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }  # Odstráň úvodzovky
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

# Nastavenia logovania
$LogDir = "C:\TaurisIT\Log\IPcheck"
$LogFile = "IPcheck.log"
$EventSource = "IPLocationWin32App"

# Import LogHelper modulu
Import-Module LogHelper -ErrorAction Stop

# Inicializácia log systému
$null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30

# Začiatok logovania
Write-IntuneLog -Message "Začiatok inštalácie Win32 app - určenie lokácie podľa IP." -Level INFO -LogFile $LogFile -EventSource $EventSource

try {
    # Načítaj .env
    Import-DotEnv
    $ClientId = $env:GRAPH_CLIENT_ID
    $TenantId = $env:GRAPH_TENANT_ID
    $ClientSecret = $env:GRAPH_CLIENT_SECRET

    if ([string]::IsNullOrEmpty($ClientId) -or [string]::IsNullOrEmpty($TenantId) -or [string]::IsNullOrEmpty($ClientSecret)) {
        throw "Chýbajúce údaje v .env: GRAPH_CLIENT_ID, GRAPH_TENANT_ID alebo GRAPH_CLIENT_SECRET."
    }
    Write-IntuneLog -Message ".env súbor načítaný úspešne." -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Načítaj IPLocationMap.json
    $JsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $JsonPath)) {
        throw "IPLocationMap.json sa nenašiel na ceste: $JsonPath."
    }
    # ConvertFrom-Json -AsHashtable nie je podporované v PS 5.1 (Intune default)
    $jsonContent = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }
    Write-IntuneLog -Message "IPLocationMap.json načítaný - počet prefixov: $($ipMap.Count)." -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Získaj aktuálnu IP (prvá aktívna v 10.x rozsahu)
    # InterfaceOperationalStatus nie je vlastnosť Get-NetIPAddress; používame AddressState
    $ipAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' })
    if ($ipAddresses.Count -eq 0) {
        throw "Nenašla sa žiadna aktívna IP adresa v rozsahu 10.x.x.x."
    }
    $currentIP = ($ipAddresses | Select-Object -First 1).IPAddress
    Write-IntuneLog -Message "Aktuálna IP adresa: $currentIP." -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Určenie lokácie - longest prefix match
    $location = $null
    $longestPrefix = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($currentIP.StartsWith($prefix) -and $prefix.Length -gt $longestPrefix.Length) {
            $longestPrefix = $prefix
            $location = $ipMap[$prefix]
        }
    }
    if ([string]::IsNullOrEmpty($location)) {
        throw "Pre IP $currentIP sa nenašla žiadna zodpovedajúca lokácia v mape."
    }
    Write-IntuneLog -Message "Určená lokácia: $location (prefix: $longestPrefix)." -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

    # Inštalácia len potrebných Graph modulov ak chýbajú
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

    # Autentifikácia k Microsoft Graph (client credentials flow)
    $authBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $accessToken = $tokenResponse.access_token

    # Graph SDK v2 vyžaduje SecureString pre -AccessToken
    $secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop

    # Získanie device objektu - Select-Object -First 1 pre prípad viacerých zariadení s rovnakým menom
    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) {
        throw "Zariadenie '$deviceName' sa nenašlo v Entra ID."
    }

    # Aktualizácia extensionAttribute1
    $updateBody = ConvertTo-Json -InputObject @{
        extensionAttribute1 = $location
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $updateBody -ContentType "application/json" -ErrorAction Stop

    Write-IntuneLog -Message "Lokácia '$location' úspešne zapísaná do extensionAttribute1 pre zariadenie '$deviceName'." -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

    # Čistenie starých logov
    Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir

    # Voliteľné: Nastavenie detekčného registry kľúča pre Intune (ak chceš registry detection rule)
    # New-Item -Path "HKLM:\SOFTWARE\TaurisIT\IPLocation" -Force | Out-Null
    # Set-ItemProperty -Path "HKLM:\SOFTWARE\TaurisIT\IPLocation" -Name "LastLocation" -Value $location -Type String

    exit 0  # Úspech - Intune označí ako Installed
}
catch {
    $errorMessage = $_.Exception.Message
    Write-IntuneLog -Message "Chyba počas spracovania: $errorMessage" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Send-IntuneAlert -Message "Chyba v IP lokácia app: $errorMessage" -Severity Error -EventSource $EventSource -LogFile $LogFile
    exit 1  # Chyba - Intune označí ako Failed
}
finally {
    # Odpojenie Graph
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
