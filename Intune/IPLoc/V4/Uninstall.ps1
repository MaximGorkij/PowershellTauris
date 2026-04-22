# Uninstall.ps1 - Intune Win32 app uninstall script
$logHelperPath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper"
if (Test-Path $logHelperPath) {
    try { Import-Module LogHelper -ErrorAction Stop; $logHelperAvailable = $true } 
    catch { $logHelperAvailable = $false }
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
    } 
    catch { } 
}

function Import-DotEnv {
    param ([string]$Path = (Join-Path $PSScriptRoot ".env"))
    if (-not (Test-Path $Path)) { throw ".env nenajdeny" }
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
    Write-IntuneLog -Message "Uninstall zaciatok" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    
    Import-DotEnv
    $clientId = $env:GRAPH_CLIENT_ID
    $tenantId = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

    $authBody = @{
        grant_type = "client_credentials"
        scope = "https://graph.microsoft.com/.default"
        client_id = $clientId
        client_secret = $clientSecret
    }
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $secureToken = ConvertTo-SecureString $tokenResponse.access_token -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop

    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) { throw "Device nenajdeny" }

    $clearBody = ConvertTo-Json -InputObject @{extensionAttribute1 = $null}
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" -Body $clearBody -ContentType "application/json" -ErrorAction Stop

    Write-IntuneLog -Message "Uninstall uspesne" -Level "SUCCESS" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    if (Test-Path $LogDir) { Remove-Item -Path $LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
} 
catch {
    Write-IntuneLog -Message "ERROR: $($_.Exception.Message)" -Level "ERROR" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    exit 1
} 
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
