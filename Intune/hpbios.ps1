<#
.SYNOPSIS
    Audit verzie BIOS pre Intune zariadenia s prefixom MOP a porovnanie s najnovsou dostupnou verziou.
.DESCRIPTION
    Skript sa pripoji na Microsoft Graph API (beta endpoint) pomocou Invoke-MgGraphRequest,
    najde vsetky zariadenia s nazvom zacinajucim na 'MOP' (HP ProDesk 405 G4 DM) a pre kazde
    zisti aktualnu verziu BIOS z hardwareInformation. Vysledok porovnava s najnovsou dostupnou
    verziou BIOS a exportuje prehlad do CSV suboru.
    Najnovsie dostupne: R24 ver. 02.24.00 (sp155510, 25.10.2024)
.NOTES
    Verzia: 1.1
    Autor: Marek
    Pozadovane moduly: Microsoft.Graph.Authentication
    Datum vytvorenia: 19.05.2026
    Logovanie: C:\TaurisIT\Log\BiosAudit
#>

[CmdletBinding()]
param(
    [string] $PrefixZariadenia = 'MOP',
    [string] $AktualnaVerziaBios = '02.24.00',
    [string] $CsvVystup = "C:\TaurisIT\Log\BiosAudit\MOP_BIOS_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
)

Import-Module LogHelper -ErrorAction Stop

$LogParams = @{
    EventSource  = 'BiosAudit'
    EventLogName = 'Application'
    LogFileName  = 'BiosAudit\BiosAudit.log'
}

# --- Pripojenie na Graph ---
Write-CustomLog @LogParams -Message 'Pripajanie na Microsoft Graph...' -Type Information
try {
    Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' -NoWelcome -ErrorAction Stop
    Write-CustomLog @LogParams -Message 'Uspesne pripojenie na Microsoft Graph.' -Type Information
}
catch {
    Write-CustomLog @LogParams -Message "Chyba pri pripajani na Graph: $($_.Exception.Message)" -Type Error
    exit 1
}

# --- Pomocna funkcia pre strankovanie Graph API ---
function Invoke-GraphGetAll {
    param([string] $Uri)
    $Vysledok = [System.Collections.Generic.List[PSObject]]::new()
    $DalsiUri = $Uri
    do {
        $Odpoved = Invoke-MgGraphRequest -Method GET -Uri $DalsiUri
        foreach ($Polozka in $Odpoved.value) { $Vysledok.Add($Polozka) }
        $DalsiUri = $Odpoved.'@odata.nextLink'
    } while ($DalsiUri)
    return $Vysledok
}

# --- Nacitanie zariadeni ---
Write-CustomLog @LogParams -Message "Nacitavam zariadenia s prefixom '$PrefixZariadenia'..." -Type Information
try {
    $UriZariadenia = "https://graph.microsoft.com/beta/deviceManagement/managedDevices" +
    "?`$filter=startswith(deviceName,'$PrefixZariadenia')" +
    "&`$select=id,deviceName,manufacturer,model,operatingSystem,osVersion,lastSyncDateTime"

    $Zariadenia = Invoke-GraphGetAll -Uri $UriZariadenia
    Write-CustomLog @LogParams -Message "Najdenych zariadeni: $($Zariadenia.Count)" -Type Information
}
catch {
    Write-CustomLog @LogParams -Message "Chyba pri nacitavani zariadeni: $($_.Exception.Message)" -Type Error
    Disconnect-MgGraph | Out-Null
    exit 1
}

if ($Zariadenia.Count -eq 0) {
    Write-CustomLog @LogParams -Message 'Ziadne zariadenia neboli najdene.' -Type Warning
    Disconnect-MgGraph | Out-Null
    exit 0
}

# --- Nacitanie HW info pre kazde zariadenie ---
$Vysledky = [System.Collections.Generic.List[PSObject]]::new()
$Poradie = 0

foreach ($Zariadenie in $Zariadenia) {
    $Poradie++
    Write-Progress -Activity 'Nacitavam HW informacie' `
        -Status "$Poradie / $($Zariadenia.Count): $($Zariadenie.deviceName)" `
        -PercentComplete (($Poradie / $Zariadenia.Count) * 100)

    Write-CustomLog @LogParams -Message "[$Poradie/$($Zariadenia.Count)] Spracuvavam: $($Zariadenie.deviceName)" -Type Information

    try {
        $UriHw = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($Zariadenie.id)" +
        "?`$select=hardwareInformation"

        $HwOdpoved = Invoke-MgGraphRequest -Method GET -Uri $UriHw
        $HwInfo = $HwOdpoved.hardwareInformation

        $BiosVerzia = $HwInfo.systemManagementBiosVersion

        if ([string]::IsNullOrEmpty($BiosVerzia)) {
            $BiosVerzia = 'N/A'
            $StavBios = 'Nezistene (zariadenie este neodoslalo HW info)'
        }
        elseif ($BiosVerzia -like "*$AktualnaVerziaBios*") {
            $StavBios = 'OK - aktualne'
        }
        else {
            $StavBios = "ZASTARALE - dostupne $AktualnaVerziaBios"
        }

        $Vysledky.Add([PSCustomObject]@{
                Nazov        = $Zariadenie.deviceName
                Vyrobca      = $Zariadenie.manufacturer
                Model        = $Zariadenie.model
                OS           = $Zariadenie.operatingSystem
                VerziOS      = $Zariadenie.osVersion
                SerioveCislo = $HwInfo.serialNumber
                VerziaBIOS   = $BiosVerzia
                NajnovsiBIOS = $AktualnaVerziaBios
                StavBIOS     = $StavBios
                PoslednaSync = $Zariadenie.lastSyncDateTime
            })
    }
    catch {
        Write-CustomLog @LogParams -Message "Chyba pri zistovani HW info pre $($Zariadenie.deviceName): $($_.Exception.Message)" -Type Error
        $Vysledky.Add([PSCustomObject]@{
                Nazov        = $Zariadenie.deviceName
                Vyrobca      = $Zariadenie.manufacturer
                Model        = $Zariadenie.model
                OS           = $Zariadenie.operatingSystem
                VerziOS      = $Zariadenie.osVersion
                SerioveCislo = ''
                VerziaBIOS   = 'CHYBA'
                NajnovsiBIOS = $AktualnaVerziaBios
                StavBIOS     = 'CHYBA pri nacitani'
                PoslednaSync = $Zariadenie.lastSyncDateTime
            })
    }
}

Write-Progress -Activity 'Nacitavam HW informacie' -Completed

# --- Export do CSV ---
$LogDir = Split-Path $CsvVystup -Parent
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$Vysledky | Export-Csv -Path $CsvVystup -NoTypeInformation -Encoding UTF8 -Delimiter ';'
Write-CustomLog @LogParams -Message "CSV exportovane do: $CsvVystup" -Type Information

# --- Sumarizacia ---
$PocetOk = ($Vysledky | Where-Object { $_.StavBIOS -eq 'OK - aktualne' }).Count
$PocetZastaraly = ($Vysledky | Where-Object { $_.StavBIOS -like 'ZASTARALE*' }).Count
$PocetNezistene = ($Vysledky | Where-Object { $_.StavBIOS -like 'Nezistene*' }).Count
$PocetChyba = ($Vysledky | Where-Object { $_.StavBIOS -like 'CHYBA*' }).Count

Write-Host "`n=== SUMAR BIOS AUDITU ===" -ForegroundColor Cyan
Write-Host "Celkovo zariadeni : $($Zariadenia.Count)"
Write-Host "Aktualne          : $PocetOk"        -ForegroundColor Green
Write-Host "Zastarale         : $PocetZastaraly" -ForegroundColor Yellow
Write-Host "Nezistene         : $PocetNezistene" -ForegroundColor Gray
Write-Host "Chyba             : $PocetChyba"     -ForegroundColor Red
Write-Host "CSV export        : $CsvVystup"

$Vysledky | Format-Table Nazov, VerziaBIOS, StavBIOS, PoslednaSync -AutoSize

Disconnect-MgGraph | Out-Null
Write-CustomLog @LogParams -Message "Audit dokonceny. Aktualne: $PocetOk, Zastarale: $PocetZastaraly, Nezistene: $PocetNezistene, Chyba: $PocetChyba" -Type Information