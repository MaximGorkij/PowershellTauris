<#
.SYNOPSIS
    Intune Win32 app V5 - Nastavi lokaciju v Entra ID extensionAttribute1 podla aktualnej IP.
.DESCRIPTION
    - Nacita .env pre autentifikaciu (ClientId, TenantId, ClientSecret).
    - Nacita IPLocationMap.json pre mapovanie IP prefixov na lokacije.
    - Ziskuje aktualnu internu IP (10.x rozsah).
    - Urci lokaciju pomocou longest prefix match.
    - Ziska Graph token cez client credentials (priamy REST - bez SDK).
    - Aktualizuje extensionAttribute1 na device objekte v Entra ID.
    - Zapisuje detection registry kluc HKLM:\SOFTWARE\TaurisIT\IPLocation\LastLocation.
    - Loguje cely proces cez LogHelper modul.
.NOTES
    Verzia: 5.1
    Autor: Marek F.
    Pozadovane moduly: LogHelper
    Datum vytvorenia: 25.06.2026
    Logovanie: C:\TaurisIT\Log\IPLoc
#>

# ============================================================================
# WoW64 FIX - restart ako 64-bit ak bezi v 32-bit PS
# ============================================================================
if ([System.Environment]::Is64BitProcess -eq $false) {
    $ps64 = "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $ps64)) {
        $ps64 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# Nazov pocitaca - nacitame z WMI, nie z env (SYSTEM kontext moze mat prazdne env)
$ComputerName = (Get-WmiObject Win32_ComputerSystem).Name

# ============================================================================
# LOGOVANIE
# ============================================================================
$LogFileName = "IPLoc\IPcheck.log"
$EventSource = "TaurisIT_IPLoc"
$EventLog    = "Application"

Import-Module LogHelper -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message, [string]$Type = 'Information')
    Write-CustomLog `
        -Message      $Message `
        -EventSource  $EventSource `
        -EventLogName $EventLog `
        -LogFileName  $LogFileName `
        -Type         $Type
}

# ============================================================================
# NACITANIE .env
# ============================================================================
function Import-DotEnv {
    param([string]$Path = (Join-Path $PSScriptRoot ".env"))
    if (-not (Test-Path $Path)) {
        throw ".env subor neexistuje: $Path"
    }
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -match '^\s*$') { return }
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim() -replace '^["\x27]|["\x27]$', ''
            [Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }
}

# ============================================================================
# HLAVNA LOGIKA
# ============================================================================
try {
    Write-Log "========== ZACIATOK INSTALACIE V5.1 ==========" 'Information'
    Write-Log "Kontext: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" 'Information'
    Write-Log "Pocitac: $ComputerName" 'Information'

    # .env
    Write-Log "Nacitavam .env..." 'Information'
    Import-DotEnv
    $ClientId     = $env:GRAPH_CLIENT_ID
    $TenantId     = $env:GRAPH_TENANT_ID
    $ClientSecret = $env:GRAPH_CLIENT_SECRET
    if ([string]::IsNullOrEmpty($ClientId))     { throw "GRAPH_CLIENT_ID chyba v .env" }
    if ([string]::IsNullOrEmpty($TenantId))     { throw "GRAPH_TENANT_ID chyba v .env" }
    if ([string]::IsNullOrEmpty($ClientSecret)) { throw "GRAPH_CLIENT_SECRET chyba v .env" }
    Write-Log ".env nacitany OK. ClientId: $($ClientId.Substring(0,8))****" 'Information'

    # IPLocationMap.json
    Write-Log "Nacitavam IPLocationMap.json..." 'Information'
    $JsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $JsonPath)) { throw "IPLocationMap.json neexistuje: $JsonPath" }
    $jsonContent = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }
    Write-Log "IPLocationMap.json OK - $($ipMap.Count) prefixov." 'Information'

    # Aktualna IP v rozsahu 10.x
    Write-Log "Hladam IP adresu 10.x.x.x..." 'Information'
    $ipAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' })
    if ($ipAddresses.Count -eq 0) { throw "Nenasla sa ziadna IP adresa v rozsahu 10.x.x.x." }
    $currentIP = ($ipAddresses | Select-Object -First 1).IPAddress
    Write-Log "Aktualna IP: $currentIP" 'Information'

    # Longest prefix match
    Write-Log "Urcujem lokaciu..." 'Information'
    $location = $null
    $longestPrefix = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($currentIP.StartsWith($prefix) -and $prefix.Length -gt $longestPrefix.Length) {
            $longestPrefix = $prefix
            $location = $ipMap[$prefix]
        }
    }
    if ([string]::IsNullOrEmpty($location)) { throw "Pre IP $currentIP sa nenasla lokacia v mape." }
    Write-Log "Lokacia: $location (prefix: $longestPrefix)" 'Information'

    # Graph token - priamy REST, bez SDK
    Write-Log "Ziskavam Graph token..." 'Information'
    $tokenUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $tokenBody = "grant_type=client_credentials&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default" +
                 "&client_id=$ClientId&client_secret=$([Uri]::EscapeDataString($ClientSecret))"
    $tokenResp = Invoke-RestMethod -Method Post -Uri $tokenUrl `
        -Body $tokenBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    $token = $tokenResp.access_token
    Write-Log "Graph token ziskany OK." 'Information'

    $headers = @{ Authorization = "Bearer $token" }

    # Ziskaj device ID z Entra ID
    Write-Log "Hladam zariadenie $ComputerName v Entra ID..." 'Information'
    $deviceUrl  = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$ComputerName'&`$select=id,displayName"
    $deviceResp = Invoke-RestMethod -Method Get -Uri $deviceUrl -Headers $headers -ErrorAction Stop
    $device     = $deviceResp.value | Select-Object -First 1
    if (-not $device) { throw "Zariadenie $ComputerName sa nenaslo v Entra ID." }
    Write-Log "Zariadenie najdene - ID: $($device.id)" 'Information'

    # Aktualizuj extensionAttribute1
    Write-Log "Aktualizujem extensionAttribute1 na hodnotu: $location" 'Information'
    $patchUrl  = "https://graph.microsoft.com/beta/devices/$($device.id)"
    $patchBody = '{"extensionAttributes":{"extensionAttribute1":"' + $location + '"}}'
    Invoke-RestMethod -Method Patch -Uri $patchUrl -Headers $headers `
        -Body $patchBody -ContentType 'application/json' -ErrorAction Stop
    Write-Log "extensionAttribute1 aktualizovany na '$location' pre $ComputerName." 'Information'

    # Detection registry kluc
    Write-Log "Zapisujem registry detection kluc..." 'Information'
    $regPath = "HKLM:\SOFTWARE\TaurisIT\IPLocation"
    New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $regPath -Name "LastLocation"  -Value $location                             -Type String -Force
    Set-ItemProperty -Path $regPath -Name "LastUpdated"   -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Type String -Force
    Set-ItemProperty -Path $regPath -Name "ComputerName"  -Value $ComputerName                         -Type String -Force
    Write-Log "Registry OK: $regPath\LastLocation = $location" 'Information'

    Write-Log "========== INSTALACIA USPESNE DOKONCENA ==========" 'Information'
    exit 0
}
catch {
    Write-Log "CHYBA: $($_.Exception.Message)" 'Error'
    Write-Log "Stack: $($_.ScriptStackTrace)" 'Error'
    exit 1
}
