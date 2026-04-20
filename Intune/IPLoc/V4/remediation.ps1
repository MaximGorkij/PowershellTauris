<#
.SYNOPSIS
    Remediation: Zapise spravu lokaciju do extensionAttribute1 podla aktualnej IP
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

# Import LogHelper modulu
Import-Module LogHelper -ErrorAction SilentlyContinue

$LogDir = "C:\TaurisIT\Log\IPLoc"
$LogFile = Join-Path $LogDir "IPcheck.log"
$EventSource = "IntuneScript"

# Inicializacia log systemu
if (Test-Path "C:\Program Files\WindowsPowerShell\Modules\LogHelper") {
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
}

try {
    # Nacitaj JSON mapu
    $jsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $jsonPath)) { throw "IPLocationMap.json nenajdeny" }

    $jsonContent = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }

    # Ziskaj aktualnu IP (10.x rozsah)
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' } |
    Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $ip) { throw "Ziadna interna 10.x IP nenajdena" }
    Write-ProcessLog -Message "Aktualna IP adresa: $ip" -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Najdlhsi prefix match
    $location = $null
    $longest = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($ip.StartsWith($prefix) -and $prefix.Length -gt $longest.Length) {
            $longest = $prefix
            $location = $ipMap[$prefix]
        }
    }

    if (-not $location) { throw "Ziadna lokacija pre IP $ip" }
    Write-ProcessLog -Message "Urcena lokacija: $location (prefix: $longest)" -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Nacitaj credentials z .env
    Import-DotEnv
    $clientId = $env:GRAPH_CLIENT_ID
    $tenantId = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET

    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientSecret)) {
        throw "Chybajuce udaje v .env"
    }

    # Instalacija modulov ak chybaju
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Write-ProcessLog -Message "Microsoft.Graph moduly nacitane" -Level INFO -LogFile $LogFile -EventSource $EventSource

    $authBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $clientId
        client_secret = $clientSecret
    }

    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $token = $tokenResponse.access_token

    # Graph SDK v2 vyzaduje SecureString pre -AccessToken
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    Write-ProcessLog -Message "Pripojenie k Graph OK" -Level INFO -LogFile $LogFile -EventSource $EventSource

    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" `
        -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) { throw "Zariadenie $deviceName nenajdene v Entra ID" }
    Write-ProcessLog -Message "Zariadenie najdene: $deviceName" -Level INFO -LogFile $LogFile -EventSource $EventSource

    # Aktualizacia extensionAttribute1
    $patchBody = ConvertTo-Json -InputObject @{
        extensionAttribute1 = $location
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
        -Body $patchBody -ContentType "application/json" -ErrorAction Stop

    Write-ProcessLog -Message "SUCCESS - extensionAttribute1 nastavene na $location (IP: $ip)" -Level SUCCESS -LogFile $LogFile -EventSource $EventSource
    
    # Cistenie starych logov
    Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir
    
    Write-Output "Opravene – nastavene $location"
    exit 0

}
catch {
    $errorMessage = $_.Exception.Message
    Write-ProcessLog -Message "Remediation CHYBA: $errorMessage" -Level ERROR -LogFile $LogFile -EventSource $EventSource
    Send-IntuneAlert -Message "Nepodarilo sa nastavit lokaciju: $errorMessage" -Severity Error -EventSource $EventSource -LogFile $LogFile
    Write-Output "Chyba pri zapise: $errorMessage"
    exit 1
}
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}



