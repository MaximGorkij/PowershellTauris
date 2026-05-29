<#
.SYNOPSIS
    Export aplikacii a remediation skriptov z MS Intune do CSV pre log parser
.DESCRIPTION
    Exportuje Win32/MSI Windows aplikacie a Remediation skripty z Microsoft Intune
    pomocou Microsoft Graph API. Vystupny CSV subor je kompatibilny s Parse-IntuneLogs.ps1.
    Uzivatel si vyberie adresare cez dialogy. Na konci vypise hotovy prikaz pre parser.
.NOTES
    Verzia:             2.0
    Autor:              Tauris IT
    Pozadovane moduly:  Microsoft.Graph.Authentication
    Datum vytvorenia:   27.05.2026
    Logovanie:          C:\TaurisIT\Log\ExportIntuneAppMapping
#>

[CmdletBinding()]
param(
    # Ak zadane, preskoci dialog pre vyber adresara Intune logov na parsovanie
    [string]$IntunLogPath,

    # Ak zadane, preskoci dialog pre vyber adresara CSV exportu
    [string]$OutputPath,

    # Typ exportu: Apps, Remediations, All
    [ValidateSet('Apps', 'Remediations', 'All')]
    [string]$ExportType = 'All',

    # Tenant ID (volitelne - ak nie je zadane, pouzije sa aktualny prihlaseny tenant)
    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- interny log skriptu (fixna cesta) --------------------------------------

Add-Type -AssemblyName System.Windows.Forms

$ScriptLogDir = 'C:\TaurisIT\Log\ExportIntuneAppMapping'
if (-not (Test-Path $ScriptLogDir)) {
    New-Item -Path $ScriptLogDir -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $ScriptLogDir ("export-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'INFO'  { Write-Host $line -ForegroundColor Gray }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
    }
}

# ---- vyber adresara s Intune logmi na parsovanie -----------------------------

if (-not $IntunLogPath) {
    Write-Host "Vyberte adresar kde su ulozene Intune logy na parsovanie..." -ForegroundColor Cyan
    $intunBrowser = [System.Windows.Forms.FolderBrowserDialog]::new()
    $intunBrowser.Description       = "Vyberte adresar s Intune logmi na parsovanie (napr. C:\ProgramData\Microsoft\IntuneManagementExtension\Logs)"
    $intunBrowser.RootFolder        = [System.Environment+SpecialFolder]::MyComputer
    $intunBrowser.ShowNewFolderButton = $false

    $intunResult = $intunBrowser.ShowDialog()
    if ($intunResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "Dialog bol zruseny. Ukoncujem skript." -ForegroundColor Yellow
        exit 0
    }
    $IntunLogPath = $intunBrowser.SelectedPath
}

if (-not (Test-Path $IntunLogPath)) {
    Write-Host "Zadany adresar neexistuje: $IntunLogPath" -ForegroundColor Red
    exit 1
}

Write-Log "Adresar Intune logov: $IntunLogPath"

# ---- vyber vystupneho adresara pre CSV export --------------------------------

if (-not $OutputPath) {
    Write-Log "Otvarame dialog pre vyber adresara CSV exportu..."
    $csvBrowser = [System.Windows.Forms.FolderBrowserDialog]::new()
    $csvBrowser.Description         = "Vyberte adresar pre ulozenie CSV suboru s mapovanim aplikacii"
    $csvBrowser.RootFolder          = [System.Environment+SpecialFolder]::Desktop
    $csvBrowser.ShowNewFolderButton = $true

    $csvResult = $csvBrowser.ShowDialog()
    if ($csvResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log "Dialog bol zruseny. Ukoncujem skript." -Level WARN
        exit 0
    }
    $OutputPath = $csvBrowser.SelectedPath
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    Write-Log "Vytvoreny adresar: $OutputPath"
}

Write-Log "Cielovy adresar CSV: $OutputPath"

# ---- kontrola modulov --------------------------------------------------------

$requiredModules = @('Microsoft.Graph.Authentication')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Log "Chybajuci modul: $mod. Instalujem..." -Level WARN
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
}

# ---- pripojenie ku Graph API -------------------------------------------------

Write-Log "Prihlasovanie do Microsoft Graph..."
try {
    $connectParams = @{
        Scopes = @(
            'DeviceManagementApps.Read.All',
            'DeviceManagementScripts.Read.All'
        )
    }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    Connect-MgGraph @connectParams -NoWelcome
    Write-Log "Uspesne prihlaseny do Microsoft Graph."
}
catch {
    Write-Log "Chyba pri prihlasovani: $_" -Level ERROR
    exit 1
}

# ---- pomocna funkcia na Graph GET s pagingom ---------------------------------

function Invoke-GraphGetAll {
    param([string]$Uri)
    $all  = [System.Collections.Generic.List[PSObject]]::new()
    $page = $Uri
    while ($page) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $page
        if ($resp.value) {
            foreach ($item in $resp.value) { $all.Add($item) }
        }
        $nextLink = $null
        if ($resp -is [hashtable] -and $resp.ContainsKey('@odata.nextLink')) {
            $nextLink = $resp['@odata.nextLink']
        }
        elseif ($resp.PSObject.Properties['@odata.nextLink']) {
            $nextLink = $resp.'@odata.nextLink'
        }
        $page = $nextLink
    }
    return $all
}

# ---- export Windows aplikacii ------------------------------------------------

$appRows = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($ExportType -in 'Apps', 'All') {
    Write-Log "Stiahavam zoznam aplikacii z Intune..."

    # isof() filter nie je spolahlivy na v1.0 - stiahnem vsetky a odfiltrujem lokalne
    $windowsTypes = @(
        '#microsoft.graph.win32LobApp',
        '#microsoft.graph.windowsMobileMSI',
        '#microsoft.graph.windowsMicrosoftEdgeApp',
        '#microsoft.graph.windowsStoreApp',
        '#microsoft.graph.microsoftStoreForBusinessApp',
        '#microsoft.graph.officeSuiteApp'
    )

    $uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$select=id,displayName,publisher&`$top=999"

    try {
        $allApps = Invoke-GraphGetAll -Uri $uri
        Write-Log "Stiahnutych $($allApps.Count) aplikacii celkovo, filtrujem Windows typy..."

        $apps = $allApps | Where-Object { $windowsTypes -contains $_.'@odata.type' }
        Write-Log "Po filtrovaní: $($apps.Count) Windows aplikacii."

        foreach ($app in $apps) {
            $shortType = ($app.'@odata.type' -replace '^#microsoft\.graph\.', '')
            $appRows.Add([PSCustomObject]@{
                Name      = $app.displayName
                Id        = $app.id
                Type      = $shortType
                Publisher = if ($app.publisher) { $app.publisher } else { '' }
            })
        }
    }
    catch {
        Write-Log "Chyba pri stiahavani aplikacii: $_" -Level ERROR
    }
}

# ---- export Remediation skriptov ---------------------------------------------

$remRows = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($ExportType -in 'Remediations', 'All') {
    Write-Log "Stiahavam zoznam Remediation skriptov z Intune..."

    $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?`$select=id,displayName,publisher&`$top=999"

    try {
        $scripts = Invoke-GraphGetAll -Uri $uri
        Write-Log "Stiahnutych $($scripts.Count) remediation skriptov."

        foreach ($s in $scripts) {
            $remRows.Add([PSCustomObject]@{
                Name      = $s.displayName
                Id        = $s.id
                Type      = 'deviceHealthScript'
                Publisher = if ($s.publisher) { $s.publisher } else { '' }
            })
        }
    }
    catch {
        Write-Log "Chyba pri stiahavani remediation skriptov: $_" -Level ERROR
    }
}

# ---- zapis do CSV ------------------------------------------------------------

$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($r in $appRows) { $allRows.Add($r) }
foreach ($r in $remRows) { $allRows.Add($r) }

if ($allRows.Count -eq 0) {
    Write-Log "Ziadne zaznamy na export." -Level WARN
    Disconnect-MgGraph | Out-Null
    exit 0
}

$dateSuffix = Get-Date -Format 'yyyyMMdd'
$csvFile    = Join-Path $OutputPath "intune-apps-$dateSuffix.csv"

try {
    $allRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Log "CSV exportovany: $csvFile ($($allRows.Count) zaznamov: $($appRows.Count) aplikacii, $($remRows.Count) skriptov)"

    Write-Host ""
    Write-Host "Export uspesny: $csvFile" -ForegroundColor Green
    Write-Host "Celkovo zaznamov    : $($allRows.Count)" -ForegroundColor Cyan
    Write-Host "  Windows aplikacie : $($appRows.Count)" -ForegroundColor Cyan
    Write-Host "  Remediation skripty: $($remRows.Count)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pouzitie s log parserom:" -ForegroundColor DarkGray
    Write-Host "  .\Parse-IntuneLogs.ps1 -LogPath `"$IntunLogPath`" -Severity Error -Output HTML -AppMappingFile `"$csvFile`"" -ForegroundColor DarkGray
}
catch {
    Write-Log "Chyba pri zapise CSV: $_" -Level ERROR
}

# ---- odhlasenie --------------------------------------------------------------

Disconnect-MgGraph | Out-Null
Write-Log "Odhlaseny z Microsoft Graph."