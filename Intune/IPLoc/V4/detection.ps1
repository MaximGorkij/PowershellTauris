<#
.SYNOPSIS
    Detection: Skontroluje, či extensionAttribute1 obsahuje správnu lokáciu podľa aktuálnej IP
#>

function Import-DotEnv {
    param (
        [string]$Path = (Join-Path $PSScriptRoot ".env")
    )
    if (-not (Test-Path $Path)) {
        throw ".env súbor sa nenašiel na ceste: $Path."
    }
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#') { return }
        if ($line -match '^\s*$') { return }
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

Import-Module LogHelper -ErrorAction SilentlyContinue

$LogDir = "C:\TaurisIT\Log\IPcheck"
$LogFile = "IPcheck.log"
$EventSource = "IPLocationDetection"

if (Test-Path "C:\Program Files\WindowsPowerShell\Modules\LogHelper") {
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
    $null = Write-IntuneLog -Message "Detection script spustený" -Level INFO -LogFile $LogFile
}

try {
    # Načítaj JSON mapu
    $jsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $jsonPath)) { throw "IPLocationMap.json nenájdený" }

    # ConvertFrom-Json -AsHashtable nie je podporované v PS 5.1
    $jsonContent = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }

    # Získaj aktuálnu IP (10.x rozsah)
    # InterfaceOperationalStatus nie je vlastnosť Get-NetIPAddress; používame AddressState
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' } |
        Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $ip) { throw "Žiadna interná 10.x IP nenájdená" }

    # Najdlhší prefix match
    $location = $null
    $longest = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($ip.StartsWith($prefix) -and $prefix.Length -gt $longest.Length) {
            $longest = $prefix
            $location = $ipMap[$prefix]
        }
    }

    if (-not $location) { throw "Žiadna lokácia pre IP $ip" }

    # Načítaj credentials z .env
    Import-DotEnv
    $clientId     = $env:GRAPH_CLIENT_ID
    $tenantId     = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET

    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientSecret)) {
        throw "Chýbajúce údaje v .env: GRAPH_CLIENT_ID, GRAPH_TENANT_ID alebo GRAPH_CLIENT_SECRET."
    }

    # Inštalácia len potrebných Graph modulov ak chýbajú
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

    $body = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $clientId
        client_secret = $clientSecret
    }

    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $token = $tokenResponse.access_token

    # Graph SDK v2 vyžaduje SecureString pre -AccessToken
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop

    $deviceName = $env:COMPUTERNAME
    # Select-Object -First 1 pre prípad viacerých zariadení s rovnakým menom
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName,extensionAttributes" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) { throw "Zariadenie $deviceName nenájdené v Entra ID" }

    $currentExt = $device.extensionAttributes.extensionAttribute1

    if ($currentExt -eq $location) {
        $null = Write-IntuneLog -Message "OK – extensionAttribute1 = $location (IP: $ip)" -Level INFO -LogFile $LogFile
        Write-Output "Compliant – lokácia už nastavená"
        exit 0
    }
    else {
        $null = Write-IntuneLog -Message "Nesprávna hodnota: $currentExt | Malo by byť: $location (IP: $ip)" -Level WARN -LogFile $LogFile
        Write-Output "Non-compliant – extensionAttribute1 = $currentExt, malo by byť $location"
        exit 1
    }

}
catch {
    $null = Write-IntuneLog -Message "Detection chyba: $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    Write-Output "Chyba: $($_.Exception.Message)"
    exit 1
}
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
