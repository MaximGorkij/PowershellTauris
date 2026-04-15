# Uninstall.ps1 - Odinštalačný skript pre Intune Win32 aplikáciu
# Vymaže extensionAttribute1 zo zariadenia v Entra ID a odstráni lokálne logy.
# Spúšťa sa v SYSTEM kontexte cez Intune.

<#
.SYNOPSIS
    Intune Win32 app - Vymaže lokáciu z extensionAttribute1 v Entra ID.
.NOTES
    - Uninstall command: powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1
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
$EventSource = "IPLocationUninstall"

if (Test-Path "C:\Program Files\WindowsPowerShell\Modules\LogHelper") {
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
    $null = Write-IntuneLog -Message "Uninstall script spustený" -Level INFO -LogFile $LogFile
}

try {
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

    # Autentifikácia k Microsoft Graph
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

    # Získanie device objektu
    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) {
        throw "Zariadenie '$deviceName' sa nenašlo v Entra ID."
    }

    # Vymazanie extensionAttribute1 (nastavenie na null)
    $clearBody = @{
        extensionAttributes = @{
            extensionAttribute1 = $null
        }
    } | ConvertTo-Json -Depth 3

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $clearBody -ContentType "application/json" -ErrorAction Stop

    $null = Write-IntuneLog -Message "extensionAttribute1 vymazaný pre zariadenie '$deviceName'." -Level SUCCESS -LogFile $LogFile

    # Odstránenie lokálneho log adresára
    if (Test-Path $LogDir) {
        Remove-Item -Path $LogDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    exit 0
}
catch {
    $errorMessage = $_.Exception.Message
    $null = Write-IntuneLog -Message "Uninstall chyba: $errorMessage" -Level ERROR -LogFile $LogFile
    Write-Output "Chyba: $errorMessage"
    exit 1
}
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
