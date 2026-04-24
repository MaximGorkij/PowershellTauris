<#
.SYNOPSIS
    Remediation: Zapise spravu lokaciju do extensionAttribute1 podla aktualnej IP
#>

# ============================================================================
# AUTOMATICKA DETEKCIA 32-BIT A RESTART AKO 64-BIT (WoW64 FIX)
# ============================================================================
if ([System.Environment]::Is64BitProcess -eq $false) {
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

$LogDir = "C:\TaurisIT\Log\IPLoc"
$LogFile = Join-Path $LogDir "IPcheck.log"
$EventSource = "IntuneScript"

if (-not (Test-Path -Path $LogDir)) { $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue }

# ============================================================================
# VYTVORENIE EVENT LOG ZDROJA BEZNE (bez závislosti na LogHelper)
# ============================================================================
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
    catch { }
}

Ensure-EventLogSource -Source $EventSource

$logHelperPath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper"
if (Test-Path $logHelperPath) {
    try { Import-Module LogHelper -ErrorAction Stop; $logHelperAvailable = $true } 
    catch { $logHelperAvailable = $false }
} else { $logHelperAvailable = $false }

if ($logHelperAvailable) { try { $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30 -ErrorAction SilentlyContinue } catch { } }

# ============================================================================
# FALLBACK LOGGING FUNKCIA (ak LogHelper nie je dostupný)
# ============================================================================
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
        
        try {
            Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
        
        if (-not [string]::IsNullOrEmpty($EventSource)) {
            try {
                if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                    $eventLog = New-Object System.Diagnostics.EventLog("Application")
                    $eventLog.Source = $EventSource
                    $eventType = switch ($Level) {
                        "ERROR" { "Error" }
                        "WARNING" { "Warning" }
                        default { "Information" }
                    }
                    $eventLog.WriteEntry($Message, $eventType, 1000)
                }
            } catch { }
        }
        
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            default { "Gray" }
        }
        Write-Host $logEntry -ForegroundColor $color -ErrorAction SilentlyContinue
    }
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
    Write-IntuneLog -Message "Remediation zaciatok" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    
    $jsonPath = Join-Path $PSScriptRoot "IPLocationMap.json"
    if (-not (Test-Path $jsonPath)) { throw "IPLocationMap.json nenajdeny" }

    $jsonContent = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ipMap = @{}
    $jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }

    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $ip) { throw "Ziadna interna IP" }
    Write-IntuneLog -Message "IP: $ip" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $location = $null
    $longest = ""
    foreach ($prefix in $ipMap.Keys) {
        if ($ip.StartsWith($prefix) -and $prefix.Length -gt $longest.Length) { $longest = $prefix; $location = $ipMap[$prefix] }
    }
    if (-not $location) { throw "Lokacia nenajdena pre IP $ip" }
    Write-IntuneLog -Message "Lokacia: $location" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    Import-DotEnv
    $clientId = $env:GRAPH_CLIENT_ID
    $tenantId = $env:GRAPH_TENANT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET
    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientSecret)) { throw "Chybajuce credentials" }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

    $authBody = @{grant_type="client_credentials"; scope="https://graph.microsoft.com/.default"; client_id=$clientId; client_secret=$clientSecret}
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $authBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $secureToken = ConvertTo-SecureString $tokenResponse.access_token -AsPlainText -Force
    $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    Write-IntuneLog -Message "Graph connected" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue

    $deviceName = $env:COMPUTERNAME
    $response = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'&`$select=id,displayName" -ErrorAction Stop
    $device = $response.value | Select-Object -First 1
    if (-not $device) { throw "Device nenajdeny" }

    $patchBody = ConvertTo-Json -InputObject @{extensionAttribute1 = $location}
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" -Body $patchBody -ContentType "application/json" -ErrorAction Stop

    Write-IntuneLog -Message "Remediation uspesne: $location" -Level "SUCCESS" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    if (Get-Command Clear-OldLogs -ErrorAction SilentlyContinue) { Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir }
    Write-Output "Remediation completed"
    exit 0
} catch {
    Write-IntuneLog -Message "ERROR: $($_.Exception.Message)" -Level "ERROR" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
    exit 1
} finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
