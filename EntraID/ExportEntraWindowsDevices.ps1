<#
.SYNOPSIS
    Export zariadeni z Entra ID - Windows, aktivne za poslednych 30 dni
.DESCRIPTION
    Skript sa pripoji na Microsoft Graph cez interaktivne webove prihlasenie,
    nacita vsetky Windows zariadenia ktore mali sign-in za poslednych 30 dni
    a exportuje ich do CSV suboru.
    Pozadovane opravnenia (Delegated): Device.Read.All
.NOTES
    Verzia: 1.1
    Autor: Ing. Marek Findrik
    Pozadovane moduly: Microsoft.Graph.Authentication
    Datum vytvorenia: 03.06.2025
    Logovanie: C:\TaurisIT\Log\ExportEntraDevices\
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement

# -------------------------
# KONFIGURACIA
# -------------------------
$LogDir     = "C:\TaurisIT\Log\ExportEntraDevices"
$ExportDir  = "C:\TaurisIT\Export"
$DateStamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$ExportFile = Join-Path $ExportDir "EntraWindowsDevices_$DateStamp.csv"

# -------------------------
# LOGOVANIE
# -------------------------
Import-Module "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1" -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

if (-not (Test-Path $LogDir))   { New-Item -ItemType Directory -Path $LogDir   -Force | Out-Null }
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

$LogParams = @{
    EventSource  = "ExportEntraDevices"
    EventLogName = "Application"
    LogFileName  = "ExportEntraDevices\ExportEntraDevices_$DateStamp.log"
}

Write-CustomLog @LogParams -Message "Skript spusteny" -Type Information

# -------------------------
# PRIHLASENIE NA GRAPH
# -------------------------
try {
    Connect-MgGraph -Scopes "Device.Read.All" -UseDeviceCode -NoWelcome -ErrorAction Stop
    Write-CustomLog @LogParams -Message "Prihlasenie na Microsoft Graph uspesne" -Type Information
}
catch {
    Write-CustomLog @LogParams -Message "Chyba pri prihlaseni na Graph: $($_.Exception.Message)" -Type Error
    exit 1
}

# -------------------------
# NACITANIE ZARIADENI
# -------------------------
try {
    $CutoffDate = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-CustomLog @LogParams -Message "Nacitavam Windows zariadenia aktivne od $CutoffDate" -Type Information

    $Filter = "operatingSystem eq 'Windows' and approximateLastSignInDateTime ge $CutoffDate"

    $SelectFields = @(
        "id",
        "displayName",
        "operatingSystem",
        "operatingSystemVersion",
        "deviceId",
        "accountEnabled",
        "approximateLastSignInDateTime",
        "registrationDateTime",
        "trustType",
        "enrollmentType",
        "managementType",
        "isCompliant",
        "manufacturer",
        "model",
        "profileType"
    ) -join ","

    $Devices = Get-MgDevice -Filter $Filter -Select $SelectFields -All -ErrorAction Stop

    Write-CustomLog @LogParams -Message "Nacitanych zariadeni: $($Devices.Count)" -Type Information
}
catch {
    Write-CustomLog @LogParams -Message "Chyba pri nacitani zariadeni: $($_.Exception.Message)" -Type Error
    Disconnect-MgGraph | Out-Null
    exit 1
}

# -------------------------
# PRIPRAVA A EXPORT DO CSV
# -------------------------
try {
    $ExportData = $Devices | ForEach-Object {
        [PSCustomObject]@{
            "Nazov zariadenia"   = $_.DisplayName
            "OS"                 = $_.OperatingSystem
            "Verzia OS"          = $_.OperatingSystemVersion
            "Device ID"          = $_.DeviceId
            "Entra Object ID"    = $_.Id
            "Posledny sign-in"   = if ($_.ApproximateLastSignInDateTime) {
                                       ([datetime]$_.ApproximateLastSignInDateTime).ToString("dd.MM.yyyy HH:mm")
                                   } else { "" }
            "Datum registracie"  = if ($_.RegistrationDateTime) {
                                       ([datetime]$_.RegistrationDateTime).ToString("dd.MM.yyyy HH:mm")
                                   } else { "" }
            "Typ pripojenia"     = $_.TrustType
            "Typ enrollmentu"    = $_.EnrollmentType
            "Typ spravy"         = $_.ManagementType
            "Zariadenie zapnute" = $_.AccountEnabled
            "Compliant"          = $_.IsCompliant
            "Vyrobca"            = $_.Manufacturer
            "Model"              = $_.Model
            "Profil zariadenia"  = $_.ProfileType
        }
    }

    $ExportData | Export-Csv -Path $ExportFile -NoTypeInformation -Encoding UTF8 -Delimiter ";"

    Write-CustomLog @LogParams -Message "Export uspesny: $ExportFile ($($ExportData.Count) zaznamov)" -Type Information
    Write-Host "`nExport dokonceny: $ExportFile" -ForegroundColor Green
    Write-Host "Pocet zariadeni:  $($ExportData.Count)" -ForegroundColor Cyan
}
catch {
    Write-CustomLog @LogParams -Message "Chyba pri exporte do CSV: $($_.Exception.Message)" -Type Error
    Disconnect-MgGraph | Out-Null
    exit 1
}

# -------------------------
# ODHLASENIE
# -------------------------
Disconnect-MgGraph | Out-Null
Write-CustomLog @LogParams -Message "Skript dokonceny" -Type Information