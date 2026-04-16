<#
.SYNOPSIS
    Remediation: Zapíše správnu lokáciu do extensionAttribute1 podľa aktuálnej IP
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

# Import LogHelper modulu
Import-Module LogHelper -ErrorAction SilentlyContinue

$LogDir = "C:\TaurisIT\Log\IPcheck"
$LogFile = "IPcheck.log"
$LogFilePath = Join-Path $LogDir $LogFile
$EventSource = "IPLocationRemediation"

# Inicializácia log systému
if (Test-Path "C:\Program Files\WindowsPowerShell\Modules\LogHelper") {
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
}

try {
    # Načítaj JSON mapu
    $jsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $jsonPath)) { throw "IPLocationMap.json nenájdený" }

    $jsonContent = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }

    # Získaj aktuálnu IP (10.x rozsah)
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' } |
    Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $ip) { throw "Žiadna interná 10.x IP nenájdená" }
    Write-IntuneLog -Message "Aktuálna IP adresa: $ip" -Level INFO -LogFile $LogFile -EventSource $EventSource

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
    Write-IntuneLog -Message "Určená lokácia: $location (prefix: $longest)" -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Načítaj credentials z .env
    Import-DotEnv
    $clientId = $env:GRAPH_CLIENT_ID
    $tenantId = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET

    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientSecret)) {
        throw "Chýbajúce údaje v .env"
    }

    # Inštalácia modulov ak chýbajú
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Write-IntuneLog -Message "Microsoft.Graph moduly načítané" -Level INFO -LogFile $LogFile -EventSource $EventSource

    $authBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $clientId
        client_secret = $clientSecret
    }

    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $token = $tokenResponse.access_token

    # Graph SDK v2 vyžaduje SecureString pre -AccessToken
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    Write-IntuneLog -Message "Pripojenie k Graph OK" -Level INFO -LogFile $LogFile -EventSource $EventSource

    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) { throw "Zariadenie $deviceName nenájdené v Entra ID" }
    Write-IntuneLog -Message "Zariadenie nájdené: $deviceName" -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Aktualizácia extensionAttribute1
    $patchBody = ConvertTo-Json -InputObject @{
        extensionAttribute1 = $location
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $patchBody -ContentType "application/json" -ErrorAction Stop

    Write-IntuneLog -Message "SUCCESS – extensionAttribute1 nastavené na $location (IP: $ip)" -Level SUCCESS -LogFile $LogFile -EventSource $EventSource
    
    # Čistenie starých logov
    Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir
    
    Write-Output "Opravené – nastavené $location"
    exit 0

}
catch {
    $errorMessage = $_.Exception.Message
    Write-IntuneLog -Message "Remediation CHYBA: $errorMessage" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Send-IntuneAlert -Message "Nepodarilo sa nastaviť lokáciu: $errorMessage" -Severity Error -EventSource $EventSource -LogFile $LogFile
    Write-Output "Chyba pri zápise: $errorMessage"
    exit 1
}
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
