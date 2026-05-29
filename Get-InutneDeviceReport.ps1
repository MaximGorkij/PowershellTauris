<#
.SYNOPSIS
    Report zariadeni z Intune na zaklade zoznamu serial numbers.
.DESCRIPTION
    Skript nacita serial numbers zo suboru TXT (jeden riadok = jeden SN),
    vyhladava zariadenia v Intune cez Microsoft Graph API a exportuje
    report do Excel suboru pomocou modulu ImportExcel.
    Autentifikacia prebieha interaktivne cez webovy prehliadac.
.NOTES
    Verzia: 1.2
    Autor: Ing. Marek Findrik
    Pozadovane moduly: LogHelper, Microsoft.Graph.Authentication, ImportExcel
    Datum vytvorenia: 29.05.2025
    Logovanie: C:\TaurisIT\Log\IntuneDeviceReport
#>

#Requires -Modules Microsoft.Graph.Authentication, ImportExcel

Import-Module LogHelper

# --- Konfiguracia ---
$konfig = @{
    VstupnySubor  = "C:\TaurisIT\Data\serial_numbers.txt"
    VystupnySubor = "C:\TaurisIT\Reports\IntuneDeviceReport_$(Get-Date -Format 'yyyyMMdd_HHmm').xlsx"
    LogDir        = "C:\TaurisIT\Log\IntuneDeviceReport"
    LogSubor      = "IntuneDeviceReport_$(Get-Date -Format 'yyyyMMdd').log"
    EventSource   = "IntuneDeviceReport"
    EventLog      = "Application"
}

# Skratka pre Write-CustomLog
function Log {
    param(
        [string]$Sprava,
        [ValidateSet('Information','Warning','Error')]
        [string]$Typ = 'Information'
    )
    Write-CustomLog `
        -Message      $Sprava `
        -EventSource  $konfig.EventSource `
        -EventLogName $konfig.EventLog `
        -LogFileName  $konfig.LogSubor `
        -Type         $Typ
}

# --- Funkcia: Pripojenie ku Graph API (interaktivne) ---
function Connect-GraphInteraktivne {
    Log "Pripajam sa ku Microsoft Graph (interaktivne prihlasenie)..."

    Connect-MgGraph `
        -Scopes @('DeviceManagementManagedDevices.Read.All') `
        -NoWelcome

    $kontext = Get-MgContext
    Log "Prihlaseny ako: $($kontext.Account) | Tenant: $($kontext.TenantId)"
}

# --- Funkcia: Ziskanie dat zariadenia podla SN ---
function Get-ZariadeniePodlaSN {
    param([string]$SerialNumber)

    $url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
           "?`$filter=serialNumber eq '$SerialNumber'" +
           "&`$select=id,deviceName,serialNumber,manufacturer,model,operatingSystem," +
           "osVersion,complianceState,lastSyncDateTime,enrolledDateTime," +
           "joinType,userPrincipalName,managedDeviceOwnerType"

    try {
        $odpoved = Invoke-MgGraphRequest -Method GET -Uri $url
        return $odpoved.value
    }
    catch {
        Log "Chyba pri vyhladavani SN '$SerialNumber': $($_.Exception.Message)" -Typ 'Warning'
        return $null
    }
}

# --- Hlavny blok ---
try {
    # Vytvorenie adresarov ako prvy krok
    $reportDir = Split-Path $konfig.VystupnySubor -Parent
    foreach ($dir in @($konfig.LogDir, $reportDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    Log "=== Zaciatok spracovania reportu ==="

    # Nacitanie vstupneho suboru
    if (-not (Test-Path $konfig.VstupnySubor)) {
        throw "Vstupny subor nebol najdeny: $($konfig.VstupnySubor)"
    }

    $zoznamSN = Get-Content $konfig.VstupnySubor |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() }

    if ($null -eq $zoznamSN -or @($zoznamSN).Count -eq 0) {
        throw "Vstupny subor neobsahuje ziadne platne serial numbers."
    }

    $pocetSN = @($zoznamSN).Count
    Log "Nacitanych serial numbers: $pocetSN"

    # Pripojenie ku Graph - otvorenie prehliadaca
    Connect-GraphInteraktivne

    # Spracovanie zariadeni
    $vysledky  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pocitadlo = 0

    foreach ($sn in $zoznamSN) {
        $pocitadlo++
        Write-Progress -Activity "Vyhladavam zariadenia v Intune" `
            -Status "[$pocitadlo/$pocetSN] SN: $sn" `
            -PercentComplete (($pocitadlo / $pocetSN) * 100)

        $zariadenia = Get-ZariadeniePodlaSN -SerialNumber $sn

        if ($null -eq $zariadenia -or @($zariadenia).Count -eq 0) {
            Log "SN '$sn' - zariadenie nenajdene v Intune." -Typ 'Warning'

            $vysledky.Add([PSCustomObject]@{
                SerialNumber     = $sn
                DeviceName       = 'NENAJDENE'
                PrimaryUser      = ''
                OS               = ''
                OSVersion        = ''
                ComplianceState  = ''
                LastSyncDateTime = $null
                EnrolledDateTime = $null
                JoinType         = ''
                Manufacturer     = ''
                Model            = ''
                OwnerType        = ''
            })
            continue
        }

        foreach ($zariadenie in @($zariadenia)) {
            Log "SN '$sn' - najdene: $($zariadenie.deviceName)"

            $lastSync = $null
            $enrolled = $null

            if (-not [string]::IsNullOrWhiteSpace($zariadenie.lastSyncDateTime)) {
                $lastSync = [datetime]$zariadenie.lastSyncDateTime
            }
            if (-not [string]::IsNullOrWhiteSpace($zariadenie.enrolledDateTime)) {
                $enrolled = [datetime]$zariadenie.enrolledDateTime
            }

            $vysledky.Add([PSCustomObject]@{
                SerialNumber     = "$($zariadenie.serialNumber)"
                DeviceName       = "$($zariadenie.deviceName)"
                PrimaryUser      = "$($zariadenie.userPrincipalName)"
                OS               = "$($zariadenie.operatingSystem)"
                OSVersion        = "$($zariadenie.osVersion)"
                ComplianceState  = "$($zariadenie.complianceState)"
                LastSyncDateTime = $lastSync
                EnrolledDateTime = $enrolled
                JoinType         = "$($zariadenie.joinType)"
                Manufacturer     = "$($zariadenie.manufacturer)"
                Model            = "$($zariadenie.model)"
                OwnerType        = "$($zariadenie.managedDeviceOwnerType)"
            })
        }
    }

    Write-Progress -Activity "Vyhladavam zariadenia v Intune" -Completed

    # Export do Excel
    Log "Exportujem report do: $($konfig.VystupnySubor)"

    $podmienkaCompliant = New-ConditionalText -Text 'compliant'    -BackgroundColor LightGreen  -ConditionalTextColor DarkGreen
    $podmienkaNCom      = New-ConditionalText -Text 'noncompliant' -BackgroundColor LightYellow -ConditionalTextColor OrangeRed
    $podmienkaNenajdene = New-ConditionalText -Text 'NENAJDENE'    -BackgroundColor LightCoral  -ConditionalTextColor DarkRed

    $vysledky | Export-Excel `
        -Path            $konfig.VystupnySubor `
        -WorksheetName   'IntuneReport' `
        -AutoSize `
        -AutoFilter `
        -FreezeTopRow `
        -BoldTopRow `
        -TableName       'IntuneDeviceReport' `
        -TableStyle      'Medium2' `
        -ConditionalText $podmienkaCompliant, $podmienkaNCom, $podmienkaNenajdene

    $najdene   = @($vysledky | Where-Object { $_.DeviceName -ne 'NENAJDENE' }).Count
    $nenajdene = @($vysledky | Where-Object { $_.DeviceName -eq 'NENAJDENE' }).Count

    Log "Report dokonceny. Najdenych: $najdene | Nenajdenych: $nenajdene | Subor: $($konfig.VystupnySubor)"

    Write-Host "`nReport dokonceny." -ForegroundColor Green
    Write-Host "  Spracovanych SN : $pocetSN"
    Write-Host "  Najdenych       : $najdene"
    Write-Host "  Nenajdenych     : $nenajdene"
    Write-Host "  Vystupny subor  : $($konfig.VystupnySubor)"
}
catch {
    Write-Host "CHYBA DETAIL : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "STACK        : $($_.ScriptStackTrace)"  -ForegroundColor Yellow

    if (Test-Path $konfig.LogDir) {
        Log "Kriticka chyba: $($_.Exception.Message)" -Typ 'Error'
    }

    Write-Error "Kriticka chyba: $($_.Exception.Message)"
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}