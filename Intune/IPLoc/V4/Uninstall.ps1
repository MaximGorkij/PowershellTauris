<#
.SYNOPSIS
    Intune Win32 app V5.1 - Odinstalovanie IP Lokalizacia.
.DESCRIPTION
    - Vymaze extensionAttribute1 na device objekte v Entra ID (nastavi na null).
    - Odstrani detection registry kluc HKLM:\SOFTWARE\TaurisIT\IPLocation.
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
    if (-not (Test-Path $Path)) { throw ".env subor neexistuje: $Path" }
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
    Write-Log "========== ZACIATOK ODINSTALACIE V5.1 ==========" 'Information'
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
    Write-Log ".env nacitany OK." 'Information'

    # Graph token
    Write-Log "Ziskavam Graph token..." 'Information'
    $tokenUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $tokenBody = "grant_type=client_credentials&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default" +
                 "&client_id=$ClientId&client_secret=$([Uri]::EscapeDataString($ClientSecret))"
    $tokenResp = Invoke-RestMethod -Method Post -Uri $tokenUrl `
        -Body $tokenBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    $token   = $tokenResp.access_token
    $headers = @{ Authorization = "Bearer $token" }
    Write-Log "Graph token ziskany OK." 'Information'

    # Ziskaj device ID
    Write-Log "Hladam zariadenie $ComputerName v Entra ID..." 'Information'
    $deviceUrl  = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$ComputerName'&`$select=id,displayName"
    $deviceResp = Invoke-RestMethod -Method Get -Uri $deviceUrl -Headers $headers -ErrorAction Stop
    $device     = $deviceResp.value | Select-Object -First 1
    if (-not $device) { throw "Zariadenie $ComputerName sa nenaslo v Entra ID." }
    Write-Log "Zariadenie najdene - ID: $($device.id)" 'Information'

    # Vymaz extensionAttribute1 (nastav na null)
    Write-Log "Mazem extensionAttribute1..." 'Information'
    $patchUrl  = "https://graph.microsoft.com/beta/devices/$($device.id)"
    $patchBody = '{"extensionAttributes":{"extensionAttribute1":null}}'
    Invoke-RestMethod -Method Patch -Uri $patchUrl -Headers $headers `
        -Body $patchBody -ContentType 'application/json' -ErrorAction Stop
    Write-Log "extensionAttribute1 vymazany pre $ComputerName." 'Information'

    # Odstran registry kluc
    Write-Log "Odstranujem registry kluc..." 'Information'
    $regPath = "HKLM:\SOFTWARE\TaurisIT\IPLocation"
    if (Test-Path $regPath) {
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
        Write-Log "Registry kluc odstraneny: $regPath" 'Information'
    } else {
        Write-Log "Registry kluc neexistuje, preskakujem." 'Information'
    }

    Write-Log "========== ODINSTALOVANIE USPESNE DOKONCENE ==========" 'Information'
    exit 0
}
catch {
    Write-Log "CHYBA: $($_.Exception.Message)" 'Error'
    Write-Log "Stack: $($_.ScriptStackTrace)" 'Error'
    exit 1
}
