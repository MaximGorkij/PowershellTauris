# Uninstall.ps1 - Odinstalavacny skript pre Intune Win32 aplikaciu
# Vymaze extensionAttribute1 zo zariadenia v Entra ID a odstrani lokalne logy.
# Spusta sa v SYSTEM kontexte cez Intune.

<#
.SYNOPSIS
    Intune Win32 app - Vymaze lokaciju z extensionAttribute1 v Entra ID.
.NOTES
    - Uninstall command: powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1
#>

function Import-DotEnv {
    param (
        [string]$Path = (Join-Path $PSScriptRoot ".env")
    )
    if (-not (Test-Path $Path)) {
        throw ".env subor sa nenasiel na ceste: $Path."
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

# Wrapper na Write-IntuneLog - kombinuje LogHelper modul s Write-Host
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
        "INFO"    { "Cyan" }
        "OK"      { "Green" }
        "SUCCESS" { "Yellow" }
        "DEBUG"   { "DarkCyan" }
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        default   { "White" }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

Import-Module LogHelper -ErrorAction SilentlyContinue

$LogDir = "C:\TaurisIT\Log\IPLoc"
$LogFile = Join-Path $LogDir "IPcheck.log"
$EventSource = "IntuneScript"

# Inicializacia log systemu
if (Test-Path "C:\Program Files\WindowsPowerShell\Modules\LogHelper") {
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
}

try {
    # Nacitaj credentials z .env
    Import-DotEnv
    $clientId = $env:GRAPH_CLIENT_ID
    $tenantId = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET

    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientSecret)) {
        throw "Chybajuce udaje v .env: GRAPH_CLIENT_ID, GRAPH_TENANT_ID alebo GRAPH_CLIENT_SECRET."
    }

    # Instalacija len potrebnych Graph modulov ak chybaju
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

    # Autentifikacia k Microsoft Graph
    $authBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $clientId
        client_secret = $clientSecret
    }
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $accessToken = $tokenResponse.access_token

    $secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop

    # Ziskanie device objektu
    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) {
        throw "Zariadenie '$deviceName' sa nenaslo v Entra ID."
    }

    # Vymazanie extensionAttribute1 (nastavenie na null)
    $clearBody = ConvertTo-Json -InputObject @{
        extensionAttribute1 = $null
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $clearBody -ContentType "application/json" -ErrorAction Stop

    Write-ProcessLog -Message "extensionAttribute1 vymazany pre zariadenie '$deviceName'." -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

    # Odstranenie lokalneho log adresara
    if (Test-Path $LogDir) {
        Remove-Item -Path $LogDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    exit 0
}
catch {
    $errorMessage = $_.Exception.Message
    Write-ProcessLog -Message "Uninstall chyba: $errorMessage" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Send-IntuneAlert -Message "Uninstall chyba: $errorMessage" -Severity Error -EventSource $EventSource -LogFile $LogFile
    Write-Output "Chyba: $errorMessage"
    exit 1
}
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}



