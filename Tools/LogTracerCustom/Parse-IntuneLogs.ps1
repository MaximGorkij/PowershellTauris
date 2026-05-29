<#
.SYNOPSIS
    Parsovanie CMTrace logov z Microsoft Intune Management Extension
.DESCRIPTION
    Parsuje logy z IntuneManagementExtension vcetane Win32 aplikacii a Remediation skriptov.
    Podporuje filtrovanie podla zavaznosti, casu, komponentu a textu.
    Pouzitie AppMappingFile (CSV z Export-IntuneAppMapping.ps1) zobrazi nazvy aplikacii
    a skriptov namiesto GUID identifikatorov.
.NOTES
    Verzia:             2.0
    Autor:              Tauris IT
    Datum vytvorenia:   27.05.2026
    Logovanie:          ziadne - vystup iba na konzolu a do exportnych suborov
#>

# Pouzitie:
#   .\Parse-IntuneLogs.ps1 -Severity Error -Last 50
#   .\Parse-IntuneLogs.ps1 -Filter "Win32App" -Output HTML -AppMappingFile "intune-apps.csv"
#   .\Parse-IntuneLogs.ps1 -LogFile AppWorkload,AgentExecutor -From (Get-Date).AddDays(-1)

[CmdletBinding()]
param(
    # Adresar s Intune logmi - ak nezadane, zobrazi sa dialog
    [string]$LogPath,

    # Nazvy log suborov bez pripony (napr. "IntuneManagementExtension", "AppWorkload")
    # Ak nezadane, pouziju sa vsetky *.log subory
    [string[]]$LogFile,

    [ValidateSet('Info', 'Warning', 'Error', 'All')]
    [string]$Severity = 'All',

    [datetime]$From,
    [datetime]$To,

    # Textovy filter (regex)
    [string]$Filter,

    [ValidateSet('Console', 'CSV', 'HTML', 'Log', 'All')]
    [string]$Output = 'Console',

    # Cielova zlozka exportu - nazvy suborov sa generuju automaticky (intune-log-YYYYMMDD.{log|csv|html})
    # Ak nezadane a Output != Console, zobrazi sa dialog
    [string]$OutputPath,

    # Zobraz len poslednych N zaznamov (po filtrovani)
    [int]$Last = 0,

    # Parsuj len zaznamy za poslednych N hodin (pouzije sa len ak -From nie je zadane)
    [int]$LastHours = 0,

    # Rozpoznaj a zahrn aj uspesne operacie (Severity='Success'). Pracuje v kombinacii
    # s -Severity Error (vtedy sa zobrazuju Errory + Success). Pri -Severity All
    # uz su vsetky zaznamy zahrnute, ale tie co matchuju success vzor budu
    # pretagovane z Info na Success pre prehladnejsi vystup.
    [switch]$IncludeSuccessfulInstalls,

    # Mapovaci subor CSV z Export-IntuneAppMapping.ps1
    # Format: Name,Id,Type,Publisher
    # Ak nezadane, zobrazi sa dialog s moznostou preskocenia
    [string]$AppMappingFile,

    # Zobraz len suhrn (bez jednotlivych zaznamov)
    [switch]$SummaryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- dialogy pre chybajuce parametre ----------------------------------------

Add-Type -AssemblyName System.Windows.Forms

# Dialog pre LogPath
if (-not $LogPath) {
    Write-Host "Vyberte adresar s Intune logmi na parsovanie..." -ForegroundColor Cyan
    $logBrowser = [System.Windows.Forms.FolderBrowserDialog]::new()
    $logBrowser.Description         = "Vyberte adresar s Intune logmi (napr. C:\ProgramData\Microsoft\IntuneManagementExtension\Logs)"
    $logBrowser.RootFolder          = [System.Environment+SpecialFolder]::MyComputer
    $logBrowser.ShowNewFolderButton = $false

    $logResult = $logBrowser.ShowDialog()
    if ($logResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "Dialog bol zruseny. Ukoncujem skript." -ForegroundColor Yellow
        exit 0
    }
    $LogPath = $logBrowser.SelectedPath
}

# Dialog pre AppMappingFile
if (-not $AppMappingFile) {
    Write-Host "Vyberte CSV subor s mapovanim aplikacii (z Export-IntuneAppMapping.ps1)..." -ForegroundColor Cyan
    Write-Host "Stlacte Zrusit pre preskocenie mapovania." -ForegroundColor DarkGray

    $openDialog = [System.Windows.Forms.OpenFileDialog]::new()
    $openDialog.Title            = "Vyberte CSV subor s mapovanim aplikacii (alebo Zrusit pre preskocenie)"
    $openDialog.Filter           = "CSV subory (*.csv)|*.csv|Vsetky subory (*.*)|*.*"
    $openDialog.InitialDirectory = [System.Environment]::GetFolderPath('Desktop')

    $openResult = $openDialog.ShowDialog()
    if ($openResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $AppMappingFile = $openDialog.FileName
    }
    else {
        Write-Host "Mapovaci subor preskoceny - GUID-y budu zobrazene bez nazvov." -ForegroundColor DarkGray
    }
}

# Dialog pre OutputPath (len ak treba export)
if ($Output -notin 'Console' -and -not $OutputPath) {
    Write-Host "Vyberte adresar pre ulozenie exportu..." -ForegroundColor Cyan
    $outBrowser = [System.Windows.Forms.FolderBrowserDialog]::new()
    $outBrowser.Description         = "Vyberte adresar pre ulozenie exportnych suborov"
    $outBrowser.RootFolder          = [System.Environment+SpecialFolder]::Desktop
    $outBrowser.ShowNewFolderButton = $true

    $outResult = $outBrowser.ShowDialog()
    if ($outResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "Dialog bol zruseny. Ukoncujem skript." -ForegroundColor Yellow
        exit 0
    }
    $OutputPath = $outBrowser.SelectedPath
}

# ---- nacitanie app mappingu --------------------------------------------------
# Dve mapy: Id->Name a Id->Type (pre rozlisenie Win32App vs Remediation v suhrne)

$appNameMap = @{}   # GUID -> DisplayName
$appTypeMap = @{}   # GUID -> Type (win32LobApp, windowsMobileMSI, deviceHealthScript ...)

if ($AppMappingFile) {
    if (-not (Test-Path $AppMappingFile)) {
        Write-Warning "Mapovaci subor neexistuje: $AppMappingFile"
    }
    elseif ($AppMappingFile -notmatch '\.(csv|json)$') {
        Write-Warning "Nepodporovany format mapovacieho suboru: $AppMappingFile (ocakava sa .csv alebo .json)"
    }
    else {
        try {
            if ($AppMappingFile -match '\.csv$') {
                # Format z Export-IntuneAppMapping.ps1: Name,Id,Type,Publisher
                $csvData = Import-Csv -Path $AppMappingFile -Encoding UTF8
                foreach ($row in $csvData) {
                    $id   = $row.Id
                    $name = $row.Name
                    if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($name)) {
                        $appNameMap[$id] = $name
                        if (-not [string]::IsNullOrWhiteSpace($row.Type)) {
                            $appTypeMap[$id] = $row.Type
                        }
                    }
                }
            }
            elseif ($AppMappingFile -match '\.json$') {
                $json = Get-Content -Path $AppMappingFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($json -is [System.Array] -or ($json | Get-Member -Name Count -ErrorAction SilentlyContinue)) {
                    foreach ($item in $json) {
                        $id   = if ($item.id)          { $item.id }          else { $item.Id }
                        $name = if ($item.displayName) { $item.displayName } elseif ($item.name) { $item.name } else { $item.Name }
                        if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($name)) {
                            $appNameMap[$id] = $name
                        }
                    }
                }
                else {
                    foreach ($key in $json.PSObject.Properties.Name) {
                        $appNameMap[$key] = $json.$key
                    }
                }
            }
            Write-Host "Nacitanych $($appNameMap.Count) mapovani aplikacii/skriptov." -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Chyba pri nacitani mapovacieho suboru: $_"
        }
    }
}

# ---- pomocne funkcie ---------------------------------------------------------

function Get-SeverityLabel {
    param([int]$Type)
    switch ($Type) {
        1 { 'Info' }
        2 { 'Warning' }
        3 { 'Error' }
        default { 'Unknown' }
    }
}

function Get-SeverityColor {
    param([string]$Label)
    switch ($Label) {
        'Error'   { 'Red' }
        'Warning' { 'Yellow' }
        'Success' { 'Green' }
        default   { 'Gray' }
    }
}

function Get-AppLabel {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $name = $appNameMap[$Id]
    $type = $appTypeMap[$Id]
    if ($name) {
        if ($type) { return "$name [$type]" }
        return $name
    }
    return $null
}

function ConvertFrom-CmTraceLog {
    param([string]$FilePath)

    $component  = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $component  = $component -replace '-\d{8}-\d{6}$', ''

    $pattern    = '<!\[LOG\[([\s\S]*?)\]LOG\]!><time="(\d+:\d+:\d+\.\d+)" date="(\d+-\d+-\d+)" component="([^"]*)" context="[^"]*" type="(\d)" thread="(\d+)" file="[^"]*">'
    $content    = Get-Content -Path $FilePath -Raw -Encoding UTF8
    $logMatches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $lastIdByThread = @{}   # thread -> posledny zisteny ID

    foreach ($m in $logMatches) {
        $message = $m.Groups[1].Value.Trim()
        $timeStr = $m.Groups[2].Value
        $dateStr = $m.Groups[3].Value
        $comp    = if ($m.Groups[4].Value) { $m.Groups[4].Value } else { $component }
        $typeNum = [int]$m.Groups[5].Value
        $thread  = $m.Groups[6].Value

        # Parsovanie datumu/casu (format: M-D-YYYY, HH:MM:SS.fffffff)
        $ts = $null
        try {
            $dp  = $dateStr -split '-'
            $hms = ($timeStr -split '\.')[0]
            $ts  = [datetime]"$($dp[2])-$($dp[0].PadLeft(2,'0'))-$($dp[1].PadLeft(2,'0')) $hms"
        }
        catch { $ts = $null }

        # Extrahovanie ID entity - Win32App aj Remediation skript
        $entityId = $null

        # 1. ApplicationId z JSON ReportingState (Win32App)
        if ($message -match '"ApplicationId"\s*:\s*"([a-f0-9\-]{36})') {
            $entityId = $matches[1]
        }
        # 2. PolicyId - Win32App aj Remediation skripty
        elseif ($message -match 'policy(?:Id)?\s*(?:with\s+id\s*)?[=:]\s*"?([a-f0-9\-]{36})"?' ) {
            $entityId = $matches[1]
        }
        # 3. ScriptId - Remediation skripty
        elseif ($message -match 'script(?:Id)?\s*[=:]\s*"?([a-f0-9\-]{36})"?') {
            $entityId = $matches[1]
        }
        # 4. DeviceHealthScriptId
        elseif ($message -match 'deviceHealthScript(?:Id)?\s*[=:]\s*"?([a-f0-9\-]{36})"?') {
            $entityId = $matches[1]
        }
        # 5. Z GRS registry cesty (Win32App)
        elseif ($message -match '\\([a-f0-9\-]{36})\.$') {
            $entityId = $matches[1]
        }
        # 6. Volny GUID v sprave - ako posledna moznost
        elseif ($message -match '\b([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\b') {
            $candidate = $matches[1]
            # Pouzij len ak je v mapping subore - zamedzuje false positives
            if ($appNameMap.ContainsKey($candidate)) {
                $entityId = $candidate
            }
        }

        # Ak ID nezistene zo spravy, pouzij posledny z toho isteho threadu
        if (-not $entityId -and $lastIdByThread[$thread]) {
            $entityId = $lastIdByThread[$thread]
        }

        if ($entityId) { $lastIdByThread[$thread] = $entityId }

        [PSCustomObject]@{
            Timestamp     = $ts
            Severity      = Get-SeverityLabel $typeNum
            SeverityNum   = $typeNum
            Component     = $comp
            Message       = $message
            SourceFile    = [System.IO.Path]::GetFileName($FilePath)
            ApplicationId = $entityId
        }
    }
}

# ---- zber log suborov -------------------------------------------------------

if (-not (Test-Path $LogPath)) {
    Write-Error "Log adresar neexistuje: $LogPath"
    exit 1
}

$allLogFiles = Get-ChildItem -Path $LogPath -Filter '*.log' | Sort-Object Name

if ($LogFile) {
    $allLogFiles = $allLogFiles | Where-Object {
        $baseName = $_.BaseName -replace '-\d{8}-\d{6}$', ''
        $LogFile -contains $baseName
    }
}

if (-not $allLogFiles) {
    Write-Warning 'Nenasli sa ziadne log subory pre zadane parametre.'
    exit 0
}

Write-Host "Parsovanie $($allLogFiles.Count) log subor(ov)..." -ForegroundColor Cyan

# ---- parsovanie -------------------------------------------------------------

$allEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($lf in $allLogFiles) {
    try {
        $entries = ConvertFrom-CmTraceLog -FilePath $lf.FullName
        foreach ($e in $entries) { $allEntries.Add($e) }
    }
    catch {
        Write-Warning "Chyba pri parsovani $($lf.Name): $_"
    }
}

Write-Host "Nacitanych $($allEntries.Count) zaznamov celkovo." -ForegroundColor Cyan

# ---- detekcia uspesnych operacii (Success) -----------------------------------

$successPatterns = @(
    '\bApp with id:\s*[a-f0-9\-]+.*is\s+Installed\b',
    '\bSuccessfully\s+(installed|uninstalled|applied|enforced|downloaded|executed|processed|completed|detected)\b',
    '\bInstallation\s+(is\s+)?(finished|completed)\s+(with\s+)?success',
    '\bExecution\s+(is\s+)?success',
    '"EnforcementState"\s*:\s*1000\b',
    '"Applicability"\s*:\s*0\b.*"ComplianceState"\s*:\s*1\b',
    '\bApplicationResult\s*[:=]\s*"?Success"?',
    '\bprocess\s+completed\s+with\s+exit\s+code\s+0\b',
    '\bOperation\s+completed\s+success',
    '\bDetection\s+state:\s*1\b',
    '\bWin32App.*detection.*state.*installed\b',
    # Remediation skripty
    '\bRemediation\s+script.*success',
    '\bDetection\s+script.*success',
    '"remediationScriptError"\s*:\s*""',
    '"detectionScriptError"\s*:\s*""'
)

if ($IncludeSuccessfulInstalls) {
    $successRegex = ($successPatterns -join '|')
    $successCount = 0
    foreach ($entry in $allEntries) {
        if ($entry.Message -match $successRegex) {
            $entry.Severity    = 'Success'
            $entry.SeverityNum = 0
            $successCount++
        }
    }
    Write-Host "Rozpoznane uspesne operacie: $successCount" -ForegroundColor Green
}

# ---- priprava casoveho okna --------------------------------------------------

if ($LastHours -gt 0 -and -not $From) {
    $From = (Get-Date).AddHours(-$LastHours)
    Write-Host "Casove okno: od $($From.ToString('yyyy-MM-dd HH:mm:ss')) (-LastHours $LastHours)" -ForegroundColor DarkGray
}

# ---- filtrovanie -------------------------------------------------------------

$filtered = $allEntries | Where-Object { $_.Timestamp -ne $null }

if ($Severity -ne 'All') {
    $allowedSev = @($Severity)
    if ($IncludeSuccessfulInstalls) { $allowedSev += 'Success' }
    $filtered = $filtered | Where-Object { $_.Severity -in $allowedSev }
}

if ($From) { $filtered = $filtered | Where-Object { $_.Timestamp -ge $From } }
if ($To)   { $filtered = $filtered | Where-Object { $_.Timestamp -le $To   } }
if ($Filter) { $filtered = $filtered | Where-Object { $_.Message -match $Filter } }

$filtered = @($filtered | Sort-Object Timestamp)

if ($Last -gt 0 -and @($filtered).Count -gt $Last) {
    $filtered = $filtered | Select-Object -Last $Last
}

Write-Host "Po filtrovani: $($filtered.Count) zaznamov." -ForegroundColor Cyan

# ---- suhrn ------------------------------------------------------------------

$summary = $filtered | Group-Object Component | Sort-Object Count -Descending | ForEach-Object {
    $grp = $_.Group
    [PSCustomObject]@{
        Component = $_.Name
        Total     = $_.Count
        Info      = @($grp | Where-Object Severity -eq 'Info').Count
        Warning   = @($grp | Where-Object Severity -eq 'Warning').Count
        Error     = @($grp | Where-Object Severity -eq 'Error').Count
        Success   = @($grp | Where-Object Severity -eq 'Success').Count
    }
}

Write-Host ''
Write-Host '=== SUHRN PER KOMPONENT ===' -ForegroundColor Cyan
$summary | Format-Table -AutoSize | Out-Host

# Suhrn aplikacii/skriptov s errormi
$appErrors = $filtered |
    Where-Object { $_.Severity -eq 'Error' -and $_.ApplicationId } |
    Group-Object ApplicationId |
    Sort-Object Count -Descending

if ($appErrors) {
    Write-Host '=== ENTITY S ERRORMI ===' -ForegroundColor Red
    foreach ($app in $appErrors) {
        $label = Get-AppLabel $app.Name
        if ($label) {
            Write-Host "  $label ($($app.Name)) - $($app.Count) error(ov)" -ForegroundColor Red
        }
        else {
            Write-Host "  ID: $($app.Name) - $($app.Count) error(ov)" -ForegroundColor Red
        }
    }
    Write-Host ''
}

# Suhrn uspesne spracovanych aplikacii/skriptov
$appSuccess = $filtered |
    Where-Object { $_.Severity -eq 'Success' -and $_.ApplicationId } |
    Group-Object ApplicationId |
    Sort-Object Count -Descending

if ($appSuccess) {
    Write-Host '=== USPESNE SPRACOVANE ENTITY ===' -ForegroundColor Green
    foreach ($app in $appSuccess) {
        $label = Get-AppLabel $app.Name
        if ($label) {
            Write-Host "  $label ($($app.Name)) - $($app.Count) uspesnych operacii" -ForegroundColor Green
        }
        else {
            Write-Host "  ID: $($app.Name) - $($app.Count) uspesnych operacii" -ForegroundColor Green
        }
    }
    Write-Host ''
}

$totalErrors   = @($filtered | Where-Object Severity -eq 'Error').Count
$totalWarnings = @($filtered | Where-Object Severity -eq 'Warning').Count
$totalSuccess  = @($filtered | Where-Object Severity -eq 'Success').Count

Write-Host "Celkovo: $($filtered.Count) zaznamov  |  Chyby: " -NoNewline
Write-Host "$totalErrors"   -ForegroundColor Red    -NoNewline
Write-Host "  |  Varovania: " -NoNewline
Write-Host "$totalWarnings" -ForegroundColor Yellow -NoNewline
Write-Host "  |  Uspechy: "  -NoNewline
Write-Host "$totalSuccess"  -ForegroundColor Green

if ($SummaryOnly) { exit 0 }

Write-Host ''

# ---- vystup na konzolu -------------------------------------------------------

if ($Output -in 'Console', 'All') {
    foreach ($entry in $filtered) {
        $ts    = if ($entry.Timestamp) { $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '????-??-?? ??:??:??' }
        $color = Get-SeverityColor $entry.Severity
        $sev   = $entry.Severity.PadRight(7)
        $comp  = $entry.Component.PadRight(30)

        Write-Host "$ts "  -NoNewline -ForegroundColor DarkGray
        Write-Host "[$sev] " -NoNewline -ForegroundColor $color
        Write-Host "$comp "  -NoNewline -ForegroundColor DarkCyan

        if ($entry.ApplicationId) {
            $label = Get-AppLabel $entry.ApplicationId
            if ($label) {
                Write-Host "[$label] " -NoNewline -ForegroundColor $color
            }
            else {
                Write-Host "[ID: $($entry.ApplicationId)] " -NoNewline -ForegroundColor DarkGray
            }
        }

        Write-Host $entry.Message -ForegroundColor $color
    }
}

# ---- priprava vystupnej zlozky a nazvov suborov ------------------------------

if ($Output -in 'CSV', 'HTML', 'Log', 'All') {
    if (-not (Test-Path -Path $OutputPath)) {
        try {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            Write-Host "Vytvorena vystupna zlozka: $OutputPath" -ForegroundColor DarkGray
        }
        catch {
            Write-Error "Nepodarilo sa vytvorit vystupnu zlozku $($OutputPath): $_"
            exit 1
        }
    }

    $reportDate = Get-Date -Format 'yyyyMMdd'
    $outputBase = Join-Path -Path $OutputPath -ChildPath "intune-log-$reportDate"
}

# ---- Log export --------------------------------------------------------------

if ($Output -in 'Log', 'All') {
    $logOut       = "$outputBase.log"
    $generatedAt  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $hostName     = $env:COMPUTERNAME

    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("===== Intune Log Parser Report =====")
    $logLines.Add("Generovane : $generatedAt")
    $logLines.Add("Pocitac    : $hostName")
    $logLines.Add("LogPath    : $LogPath")
    $logLines.Add("Severity   : $Severity")
    if ($AppMappingFile) { $logLines.Add("Mapping    : $AppMappingFile  ($($appNameMap.Count) zaznamov)") }
    if ($From) { $logLines.Add("From       : $($From.ToString('yyyy-MM-dd HH:mm:ss'))") }
    if ($To)   { $logLines.Add("To         : $($To.ToString('yyyy-MM-dd HH:mm:ss'))") }
    $logLines.Add("Zaznamov   : $($filtered.Count)  (Errory: $totalErrors, Varovania: $totalWarnings, Uspechy: $totalSuccess)")
    $logLines.Add("")
    $logLines.Add("----- SUHRN PER KOMPONENT -----")
    foreach ($s in $summary) {
        $logLines.Add(("{0,-35} Total={1,-6} Info={2,-5} Warn={3,-5} Err={4,-5} Success={5}" -f $s.Component, $s.Total, $s.Info, $s.Warning, $s.Error, $s.Success))
    }

    if ($appErrors) {
        $logLines.Add("")
        $logLines.Add("----- ENTITY S ERRORMI -----")
        foreach ($app in $appErrors) {
            $label = Get-AppLabel $app.Name
            if ($label) {
                $logLines.Add(("  {0} ({1}) - {2} error(ov)" -f $label, $app.Name, $app.Count))
            }
            else {
                $logLines.Add(("  ID: {0} - {1} error(ov)" -f $app.Name, $app.Count))
            }
        }
    }

    if ($appSuccess) {
        $logLines.Add("")
        $logLines.Add("----- USPESNE SPRACOVANE ENTITY -----")
        foreach ($app in $appSuccess) {
            $label = Get-AppLabel $app.Name
            if ($label) {
                $logLines.Add(("  {0} ({1}) - {2} uspesnych operacii" -f $label, $app.Name, $app.Count))
            }
            else {
                $logLines.Add(("  ID: {0} - {1} uspesnych operacii" -f $app.Name, $app.Count))
            }
        }
    }

    $logLines.Add("")
    $logLines.Add("----- ZAZNAMY -----")
    foreach ($entry in $filtered) {
        $ts    = if ($entry.Timestamp) { $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '????-??-?? ??:??:??' }
        $sev   = $entry.Severity.PadRight(7)
        $comp  = $entry.Component.PadRight(30)
        $label = if ($entry.ApplicationId) { Get-AppLabel $entry.ApplicationId } else { $null }
        $appInfo = if ($label) {
            "[$label] "
        } elseif ($entry.ApplicationId) {
            "[ID: $($entry.ApplicationId)] "
        } else { '' }
        $msgOneLine = ($entry.Message -replace "\s+", ' ').Trim()
        $logLines.Add("$ts [$sev] $comp $appInfo$msgOneLine")
    }

    [System.IO.File]::WriteAllLines($logOut, $logLines, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Log ulozeny: $logOut" -ForegroundColor Green
}

# ---- CSV export --------------------------------------------------------------

if ($Output -in 'CSV', 'All') {
    $csvOut = "$outputBase.csv"

    # Pridaj AppName stlpec pre lepsiu citatelnost
    $csvData = $filtered | ForEach-Object {
        $label = if ($_.ApplicationId) { Get-AppLabel $_.ApplicationId } else { '' }
        [PSCustomObject]@{
            Timestamp     = $_.Timestamp
            Severity      = $_.Severity
            Component     = $_.Component
            ApplicationId = $_.ApplicationId
            AppName       = $label
            Message       = $_.Message
            SourceFile    = $_.SourceFile
        }
    }

    $csvData | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
    Write-Host "CSV ulozeny: $csvOut" -ForegroundColor Green
}

# ---- HTML export -------------------------------------------------------------

if ($Output -in 'HTML', 'All') {
    $htmlOut = "$outputBase.html"

    $rowsHtml = foreach ($entry in $filtered) {
        $ts       = if ($entry.Timestamp) { $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        $rowClass = switch ($entry.Severity) {
            'Error'   { 'row-error' }
            'Warning' { 'row-warning' }
            'Success' { 'row-success' }
            default   { 'row-info' }
        }
        $msgEsc = [System.Net.WebUtility]::HtmlEncode($entry.Message) -replace "`n", '<br>'

        $appIdCol = if ($entry.ApplicationId) {
            $label = Get-AppLabel $entry.ApplicationId
            if ($label) {
                $escapedLabel = [System.Net.WebUtility]::HtmlEncode($label)
                "<code title='$($entry.ApplicationId)'>$escapedLabel</code>"
            }
            else {
                "<code>$($entry.ApplicationId)</code>"
            }
        }
        else { '-' }

        "<tr class='$rowClass'><td>$ts</td><td>$($entry.Severity)</td><td>$($entry.Component)</td><td>$appIdCol</td><td>$msgEsc</td><td>$($entry.SourceFile)</td></tr>"
    }

    $summaryRowsHtml = foreach ($s in $summary) {
        "<tr><td>$($s.Component)</td><td>$($s.Total)</td><td>$($s.Info)</td><td class='warn'>$($s.Warning)</td><td class='err'>$($s.Error)</td><td class='succ'>$($s.Success)</td></tr>"
    }

    $mappingInfo = if ($AppMappingFile) { " | Mapping: $([System.IO.Path]::GetFileName($AppMappingFile)) ($($appNameMap.Count) zaznamov)" } else { '' }
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $html = @"
<!DOCTYPE html>
<html lang="sk">
<head>
<meta charset="UTF-8">
<title>Intune Log Report</title>
<style>
  body { font-family: Consolas, monospace; font-size: 12px; background:#1e1e1e; color:#d4d4d4; margin:20px; }
  h1,h2 { color:#569cd6; }
  table { border-collapse:collapse; width:100%; margin-bottom:30px; }
  th { background:#264f78; color:#fff; padding:6px 10px; text-align:left; }
  td { padding:4px 10px; border-bottom:1px solid #333; vertical-align:top; }
  .row-error   td { color:#f44747; }
  .row-warning td { color:#dcdcaa; }
  .row-success td { color:#6a9955; }
  .row-info    td { color:#9cdcfe; }
  .warn { color:#dcdcaa !important; }
  .err  { color:#f44747 !important; }
  .succ { color:#6a9955 !important; }
  .summary-box { display:flex; gap:20px; margin-bottom:20px; flex-wrap:wrap; }
  .stat { background:#252526; border:1px solid #3c3c3c; padding:10px 20px; border-radius:4px; }
  .stat .num { font-size:28px; font-weight:bold; }
  .stat .lbl { font-size:11px; color:#888; }
  code { background:#252526; padding:2px 4px; border-radius:2px; font-size:11px; color:#ce9178; }
  code[title] { cursor:help; border-bottom:1px dotted #888; }
</style>
</head>
<body>
<h1>Intune Log Report</h1>
<p style="color:#888">Generovane: $generatedAt | Log adresar: $LogPath$mappingInfo</p>
<div class="summary-box">
  <div class="stat"><div class="num">$($filtered.Count)</div><div class="lbl">Celkovo</div></div>
  <div class="stat" style="border-color:#f44747"><div class="num" style="color:#f44747">$totalErrors</div><div class="lbl">Chyby</div></div>
  <div class="stat" style="border-color:#dcdcaa"><div class="num" style="color:#dcdcaa">$totalWarnings</div><div class="lbl">Varovania</div></div>
  <div class="stat" style="border-color:#6a9955"><div class="num" style="color:#6a9955">$totalSuccess</div><div class="lbl">Uspechy</div></div>
</div>
<h2>Suhrn per komponent</h2>
<table>
<tr><th>Komponent</th><th>Celkovo</th><th>Info</th><th>Varovania</th><th>Chyby</th><th>Uspechy</th></tr>
$($summaryRowsHtml -join "`n")
</table>
<h2>Zaznamy ($($filtered.Count))</h2>
<table>
<tr><th>Cas</th><th>Zavaznost</th><th>Komponent</th><th>Aplikacia / Skript</th><th>Sprava</th><th>Subor</th></tr>
$($rowsHtml -join "`n")
</table>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($htmlOut, $html, [System.Text.Encoding]::UTF8)
    Write-Host "HTML report ulozeny: $htmlOut" -ForegroundColor Green
}