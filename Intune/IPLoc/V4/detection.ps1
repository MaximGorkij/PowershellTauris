<#
.SYNOPSIS
    Detection: Skontroluje, ci extensionAttribute1 obsahuje spravnu lokaciju podla aktualnej IP
#>

# Import LogHelper modulu
$logHelperPath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper"
if (Test-Path $logHelperPath) {
    try {
        Import-Module LogHelper -ErrorAction Stop
        $logHelperAvailable = $true
    } catch {
        $logHelperAvailable = $false
    }
} else {
    $logHelperAvailable = $false
}

$LogDir = "C:\TaurisIT\Log\IPLoc"
$LogFile = Join-Path $LogDir "IPcheck.log"
$EventSource = "IntuneScript"

if (-not (Test-Path -Path $LogDir)) {
    $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue
}

if ($logHelperAvailable) {
    try {
        $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30 -ErrorAction SilentlyContinue
    } catch { }
}

function Import-DotEnv {
    param ([string]$Path = (Join-Path $PSScriptRoot ".env"))
    if (-not (Test-Path $Path)) { throw ".env subor nenajdeny" }
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -match '^\s*$') { return }
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -match '^["`"](.*)[\"`"]$') { $value = $matches[1] }
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

try {
    Write-IntuneLog -Message "Detection script zacel" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    
    $jsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $jsonPath)) { throw "IPLocationMap.json nenajdeny" }

    $jsonContent = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }
    Write-IntuneLog -Message "IPLocationMap.json nacitany - $($ipMap.Count) prefixov" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $ip) { throw "Ziadna interna 10.x IP nenajdena" }
    Write-IntuneLog -Message "Aktualna IP adresa: $ip" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $location = $null
    $longest = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($ip.StartsWith($prefix) -and $prefix.Length -gt $longest.Length) {
            $longest = $prefix
            $location = $ipMap[$prefix]
        }
    }
    if (-not $location) { throw "Ziadna lokacija pre IP $ip" }
    Write-IntuneLog -Message "Urcena lokacija: $location (prefix: $longest)" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    Import-DotEnv
    $clientId = $env:GRAPH_CLIENT_ID
    $tenantId = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET
    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientSecret)) {
        throw "Chybajuce udaje v .env"
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Write-IntuneLog -Message "Microsoft.Graph moduly nacitane" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $authBody = @{
        grant_type = "client_credentials"
        scope = "https://graph.microsoft.com/.default"
        client_id = $clientId
        client_secret = $clientSecret
    }
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $token = $tokenResponse.access_token
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    Write-IntuneLog -Message "Pripojenie k Graph OK" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?\`$filter=displayName eq '$deviceName'&\`$select=id,displayName,extensionAttributes" -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) { throw "Zariadenie $deviceName nenajdene" }
    Write-IntuneLog -Message "Zariadenie najdene: $deviceName" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $currentExt = $device.extensionAttributes.extensionAttribute1
    if ($currentExt -eq $location) {
        Write-IntuneLog -Message "OK - extensionAttribute1 = $location (IP: $ip)" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
        Write-Output "Compliant"
        exit 0
    } else {
        Write-IntuneLog -Message "Non-compliant: $currentExt, malo by byt: $location (IP: $ip)" -Level "WARNING" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
        Write-Output "Non-compliant"
        exit 1
    }
} catch {
    Write-IntuneLog -Message "Detection chyba: $($_.Exception.Message)" -Level "ERROR" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    Write-Output "Non-compliant"
    exit 1
} finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
