# Parse-IntuneLogs.ps1
# Parsuje CMTrace formát logov z Microsoft Intune Management Extension
# Pouzitie: .\Parse-IntuneLogs.ps1 -Severity Error -Last 50
#           .\Parse-IntuneLogs.ps1 -Filter "Win32App" -Output HTML -AppMappingFile "intune-apps.csv"
#           .\Parse-IntuneLogs.ps1 -LogFile AppWorkload,AgentExecutor -From (Get-Date).AddDays(-1)

[CmdletBinding()]
param(
    [string]$LogPath = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs',

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

    # Cielova zlozka exportu - nazvy suborov sa generuju automaticky (error-log-YYYYMMDD.{log|csv|html})
    [string]$OutputPath = 'C:\TaurisIT\Export\LogParser',

    # Zobraz len poslednych N zaznamov (po filtrovani)
    [int]$Last = 0,

    # Parsuj len zaznamy za poslednych N hodin (pouzije sa len ak -From nie je zadane)
    [int]$LastHours = 0,

    # Rozpoznaj a zahrn aj uspesne operacie (Severity='Success'). Pracuje v kombinacii
    # s -Severity Error (vtedy sa zobrazuju Errory + Success). Pri -Severity All
    # uz su vsetky zaznamy zahrnute, ale tie co matchuju success vzor budu
    # pretagovane z Info na Success pre prehladnejsi vystup.
    [switch]$IncludeSuccessfulInstalls,

    # Mapovací súbor (CSV alebo JSON) s GUID → DisplayName mapovaním
    # CSV format: Id,DisplayName
    # JSON format: [{"id": "...", "displayName": "..."}] alebo {"id": "displayName"}
    [string]$AppMappingFile,

    # Zobraz len suhrn (bez jednotlivych zaznamov)
    [switch]$SummaryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- nacitanie app mappingu ---------------------------------------------------

$appNameMap = @{}  # GUID -> DisplayName

if ($AppMappingFile) {
    if (-not (Test-Path $AppMappingFile)) {
        Write-Warning "Mapovací súbor neexistuje: $AppMappingFile"
    }
    else {
        try {
            if ($AppMappingFile -match '\.csv$') {
                # CSV: Name,Id,Type,Publisher alebo DisplayName,Id alebo Id,DisplayName
                $csv = Import-Csv -Path $AppMappingFile -Encoding UTF8
                foreach ($row in $csv) {
                    # Skúsi viacero variantov stĺpcov (Name prvý, lebo to je tvoj format)
                    $id = if ($row.Id) { $row.Id } elseif ($row.id) { $row.id } elseif ($row.AppId) { $row.AppId } else { $row.appId }
                    $name = if ($row.Name) { $row.Name } elseif ($row.name) { $row.name } elseif ($row.DisplayName) { $row.DisplayName } else { $row.displayName }
                    if ($id -and $name) {
                        $appNameMap[$id] = $name
                    }
                }
            }
            elseif ($AppMappingFile -match '\.json$') {
                # JSON: array alebo object
                $json = Get-Content -Path $AppMappingFile -Raw -Encoding UTF8 | ConvertFrom-Json
                
                if ($json -is [System.Collections.Generic.List`1[System.Object]] -or $json.Count) {
                    # Array
                    foreach ($item in $json) {
                        $id = if ($item.id) { $item.id } elseif ($item.Id) { $item.Id } else { $item.appId }
                        $name = if ($item.displayName) { $item.displayName } elseif ($item.DisplayName) { $item.DisplayName } elseif ($item.name) { $item.name } else { $item.Name }
                        if ($id -and $name) {
                            $appNameMap[$id] = $name
                        }
                    }
                }
                else {
                    # Object - priame mapovanie {guid: name}
                    foreach ($key in $json.PSObject.Properties.Name) {
                        $appNameMap[$key] = $json.$key
                    }
                }
            }
            Write-Host "Nacitanych $($appNameMap.Count) mapovani aplikácií." -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Chyba pri načítaní mapovacieho súboru: $_"
        }
    }
}

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
        'Error' { 'Red' }
        'Warning' { 'Yellow' }
        'Success' { 'Green' }
        default { 'Gray' }
    }
}

function ConvertFrom-CmTraceLog {
    param([string]$FilePath, [hashtable]$AppIdMap = @{})

    $component = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    # Odstrihni datum z nazvu (napr. AppWorkload-20260422-051815 -> AppWorkload)
    $component = $component -replace '-\d{8}-\d{6}$', ''

    $pattern = '<!\[LOG\[([\s\S]*?)\]LOG\]!><time="(\d+:\d+:\d+\.\d+)" date="(\d+-\d+-\d+)" component="([^"]*)" context="[^"]*" type="(\d)" thread="(\d+)" file="[^"]*">'

    $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
    $logMatches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    # Predprocesovanie: Extrahovať AppId z GRS záznamov a policy ID-čiek
    foreach ($m in $logMatches) {
        $message = $m.Groups[1].Value.Trim()
        
        # Extrahovať ApplicationId z GRS cesty (napr. "...\ key 4e80cda0.../69084241-5dab-41e8-a946-c47ee1a6f577.")
        if ($message -match 'at key [^\\]+\\GRS\\[^\\]+\\([a-f0-9\-]{36})\.' -or 
            $message -match 'at key [^\\]+\\GRS\\[^\\]+\\([a-f0-9\-]{36})$') {
            $grsAppId = $matches[1]
            if (-not $AppIdMap.ContainsKey($grsAppId)) {
                $AppIdMap[$grsAppId] = @{ LastSeen = (Get-Date); Count = 1 }
            }
            else {
                $AppIdMap[$grsAppId].Count += 1
            }
        }
    }

    # Druhý prechod: Extrahovať AppId a priradiť z kontextu
    $lastAppIdByThread = @{}
    
    foreach ($m in $logMatches) {
        $message = $m.Groups[1].Value.Trim()
        $timeStr = $m.Groups[2].Value
        $dateStr = $m.Groups[3].Value
        $comp = if ($m.Groups[4].Value) { $m.Groups[4].Value } else { $component }
        $typeNum = [int]$m.Groups[5].Value
        $thread = $m.Groups[6].Value

        # Parsovanie datumu/casu  (format: M-D-YYYY, HH:MM:SS.fffffff)
        $ts = $null
        try {
            $dp = $dateStr -split '-'   # [month, day, year]
            $hms = ($timeStr -split '\.')[0]
            $ts = [datetime]"$($dp[2])-$($dp[0].PadLeft(2,'0'))-$($dp[1].PadLeft(2,'0')) $hms"
        }
        catch { $ts = $null }

        # Extrahovanie ApplicationId - viacero možností
        $appId = $null
        
        # 1. Z JSON ReportingState
        if ($message -match '"ApplicationId"\s*:\s*"([a-f0-9\-]{36})') {
            $appId = $matches[1]
        }
        # 2. Z policy ID v správe
        elseif ($message -match 'policy with id:\s*([a-f0-9\-]{36})') {
            $appId = $matches[1]
        }
        # 3. Z GRS cesty
        elseif ($message -match '\\([a-f0-9\-]{36})\.$') {
            $appId = $matches[1]
        }
        
        # Ak nie je ApplicationId v správe, použi posledný z toho istého thread-u
        if (-not $appId -and $lastAppIdByThread[$thread]) {
            $appId = $lastAppIdByThread[$thread]
        }
        
        # Uprav aktuálny ApplicationId pre thread
        if ($appId) {
            $lastAppIdByThread[$thread] = $appId
        }

        [PSCustomObject]@{
            Timestamp     = $ts
            Severity      = Get-SeverityLabel $typeNum
            SeverityNum   = $typeNum
            Component     = $comp
            Message       = $message
            SourceFile    = [System.IO.Path]::GetFileName($FilePath)
            ApplicationId = $appId
        }
    }
}

# ---- zber log suborov -------------------------------------------------------

if (-not (Test-Path $LogPath)) {
    Write-Error "Log priecinok neexistuje: $LogPath"
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

# ---- detekcia uspesnych operacii (Success) ----------------------------------

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
    '\bWin32App.*detection.*state.*installed\b'
)

if ($IncludeSuccessfulInstalls) {
    $successRegex = ($successPatterns -join '|')
    $successCount = 0
    foreach ($entry in $allEntries) {
        if ($entry.Message -match $successRegex) {
            $entry.Severity = 'Success'
            $entry.SeverityNum = 0
            $successCount++
        }
    }
    Write-Host "Rozpoznane uspesne operacie: $successCount" -ForegroundColor Green
}

# ---- priprava casoveho okna -------------------------------------------------

if ($LastHours -gt 0 -and -not $From) {
    $From = (Get-Date).AddHours(-$LastHours)
    Write-Host "Casove okno: od $($From.ToString('yyyy-MM-dd HH:mm:ss')) (-LastHours $LastHours)" -ForegroundColor DarkGray
}

# ---- filtrovanie ------------------------------------------------------------

$filtered = $allEntries | Where-Object { $_.Timestamp -ne $null }

if ($Severity -ne 'All') {
    $allowedSev = @($Severity)
    if ($IncludeSuccessfulInstalls) { $allowedSev += 'Success' }
    $filtered = $filtered | Where-Object { $_.Severity -in $allowedSev }
}

if ($From) {
    $filtered = $filtered | Where-Object { $_.Timestamp -ge $From }
}

if ($To) {
    $filtered = $filtered | Where-Object { $_.Timestamp -le $To }
}

if ($Filter) {
    $filtered = $filtered | Where-Object { $_.Message -match $Filter }
}

# Zoradi podla casu
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

# Suhrn aplikacii s errormi
$appErrors = $filtered | Where-Object { $_.Severity -eq 'Error' -and $_.ApplicationId } | 
Group-Object ApplicationId | 
Sort-Object Count -Descending

if ($appErrors) {
    Write-Host '=== APLIKACIE S ERRORMI (podľa ApplicationId) ===' -ForegroundColor Red
    foreach ($app in $appErrors) {
        $displayName = $appNameMap[$app.Name]
        if ($displayName) {
            Write-Host "  $displayName ($($app.Name)) - $($app.Count) error(ov)" -ForegroundColor Red
        }
        else {
            Write-Host "  ApplicationId: $($app.Name) - $($app.Count) error(ov)" -ForegroundColor Red
        }
    }
    Write-Host ''
}

# Suhrn uspesne spracovanych aplikacii
$appSuccess = $filtered | Where-Object { $_.Severity -eq 'Success' -and $_.ApplicationId } |
Group-Object ApplicationId |
Sort-Object Count -Descending

if ($appSuccess) {
    Write-Host '=== USPESNE NASADENE/SPRACOVANE APLIKACIE (podľa ApplicationId) ===' -ForegroundColor Green
    foreach ($app in $appSuccess) {
        $displayName = $appNameMap[$app.Name]
        if ($displayName) {
            Write-Host "  $displayName ($($app.Name)) - $($app.Count) uspesnych operacii" -ForegroundColor Green
        }
        else {
            Write-Host "  ApplicationId: $($app.Name) - $($app.Count) uspesnych operacii" -ForegroundColor Green
        }
    }
    Write-Host ''
}

$totalErrors = @($filtered | Where-Object Severity -eq 'Error').Count
$totalWarnings = @($filtered | Where-Object Severity -eq 'Warning').Count
$totalSuccess = @($filtered | Where-Object Severity -eq 'Success').Count
Write-Host "Celkovo: $($filtered.Count) zaznamov  |  Chyby: " -NoNewline
Write-Host "$totalErrors" -ForegroundColor Red -NoNewline
Write-Host "  |  Varovania: " -NoNewline
Write-Host "$totalWarnings" -ForegroundColor Yellow -NoNewline
Write-Host "  |  Uspechy: " -NoNewline
Write-Host "$totalSuccess" -ForegroundColor Green

if ($SummaryOnly) { exit 0 }

Write-Host ''

# ---- vystup na konzolu ------------------------------------------------------

if ($Output -in 'Console', 'All') {
    foreach ($entry in $filtered) {
        $ts = if ($entry.Timestamp) { $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '????-??-?? ??:??:??' }
        $color = Get-SeverityColor $entry.Severity
        $sev = $entry.Severity.PadRight(7)
        $comp = $entry.Component.PadRight(30)

        Write-Host "$ts " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$sev] " -NoNewline -ForegroundColor $color
        Write-Host "$comp " -NoNewline -ForegroundColor DarkCyan
        
        # Ak je ERROR alebo SUCCESS a existuje ApplicationId, zobraz ho
        if (($entry.Severity -eq 'Error' -or $entry.Severity -eq 'Success') -and $entry.ApplicationId) {
            $displayName = $appNameMap[$entry.ApplicationId]
            if ($displayName) {
                Write-Host "[$displayName] " -NoNewline -ForegroundColor $color
            }
            else {
                Write-Host "[AppID: $($entry.ApplicationId)] " -NoNewline -ForegroundColor $color
            }
        }
        
        Write-Host $entry.Message -ForegroundColor $color
    }
}

# ---- priprava vystupnej zlozky a nazvov suborov -----------------------------

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
    $outputBase = Join-Path -Path $OutputPath -ChildPath "error-log-$reportDate"
}

# ---- Log export (textovy .log subor s errormi/varovaniami) ------------------

if ($Output -in 'Log', 'All') {
    $logOut = "$outputBase.log"
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $hostName = $env:COMPUTERNAME

    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("===== Intune Log Parser Report =====")
    $logLines.Add("Generovane: $generatedAt")
    $logLines.Add("Pocitac   : $hostName")
    $logLines.Add("LogPath   : $LogPath")
    $logLines.Add("Severity  : $Severity")
    if ($From) { $logLines.Add("From      : $($From.ToString('yyyy-MM-dd HH:mm:ss'))") }
    if ($To) { $logLines.Add("To        : $($To.ToString('yyyy-MM-dd HH:mm:ss'))") }
    $logLines.Add("Zaznamov  : $($filtered.Count)  (Errory: $totalErrors, Varovania: $totalWarnings, Uspechy: $totalSuccess)")
    $logLines.Add("")
    $logLines.Add("----- SUHRN PER KOMPONENT -----")
    foreach ($s in $summary) {
        $logLines.Add(("{0,-35} Total={1,-6} Info={2,-5} Warn={3,-5} Err={4,-5} Success={5}" -f $s.Component, $s.Total, $s.Info, $s.Warning, $s.Error, $s.Success))
    }

    if ($appErrors) {
        $logLines.Add("")
        $logLines.Add("----- APLIKACIE S ERRORMI -----")
        foreach ($app in $appErrors) {
            $displayName = $appNameMap[$app.Name]
            if ($displayName) {
                $logLines.Add(("  {0} ({1}) - {2} error(ov)" -f $displayName, $app.Name, $app.Count))
            }
            else {
                $logLines.Add(("  ApplicationId: {0} - {1} error(ov)" -f $app.Name, $app.Count))
            }
        }
    }

    if ($appSuccess) {
        $logLines.Add("")
        $logLines.Add("----- USPESNE NASADENE/SPRACOVANE APLIKACIE -----")
        foreach ($app in $appSuccess) {
            $displayName = $appNameMap[$app.Name]
            if ($displayName) {
                $logLines.Add(("  {0} ({1}) - {2} uspesnych operacii" -f $displayName, $app.Name, $app.Count))
            }
            else {
                $logLines.Add(("  ApplicationId: {0} - {1} uspesnych operacii" -f $app.Name, $app.Count))
            }
        }
    }

    $logLines.Add("")
    $logLines.Add("----- ZAZNAMY -----")
    foreach ($entry in $filtered) {
        $ts = if ($entry.Timestamp) { $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '????-??-?? ??:??:??' }
        $sev = $entry.Severity.PadRight(7)
        $comp = $entry.Component.PadRight(30)
        $appInfo = ''
        if ($entry.ApplicationId) {
            $displayName = $appNameMap[$entry.ApplicationId]
            if ($displayName) {
                $appInfo = "[$displayName] "
            }
            else {
                $appInfo = "[AppID: $($entry.ApplicationId)] "
            }
        }
        $msgOneLine = ($entry.Message -replace "\s+", ' ').Trim()
        $logLines.Add("$ts [$sev] $comp $appInfo$msgOneLine")
    }

    [System.IO.File]::WriteAllLines($logOut, $logLines, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Log ulozeny: $logOut" -ForegroundColor Green
}

# ---- CSV export -------------------------------------------------------------

if ($Output -in 'CSV', 'All') {
    $csvOut = "$outputBase.csv"
    $filtered | Select-Object Timestamp, Severity, Component, ApplicationId, Message, SourceFile |
    Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
    Write-Host "CSV ulozeny: $csvOut" -ForegroundColor Green
}

# ---- HTML export ------------------------------------------------------------

if ($Output -in 'HTML', 'All') {
    $htmlOut = "$outputBase.html"

    $rowsHtml = foreach ($entry in $filtered) {
        $ts = if ($entry.Timestamp) { $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        $rowClass = switch ($entry.Severity) {
            'Error' { 'row-error' }
            'Warning' { 'row-warning' }
            'Success' { 'row-success' }
            default { 'row-info' }
        }
        $msgEsc = [System.Net.WebUtility]::HtmlEncode($entry.Message) -replace "`n", '<br>'
        
        # Zobraz display name alebo GUID
        $appIdCol = if ($entry.ApplicationId) {
            $displayName = $appNameMap[$entry.ApplicationId]
            if ($displayName) {
                "<code title='$($entry.ApplicationId)'>$displayName</code>"
            }
            else {
                "<code>$($entry.ApplicationId)</code>"
            }
        }
        else {
            '-'
        }
        
        "<tr class='$rowClass'><td>$ts</td><td>$($entry.Severity)</td><td>$($entry.Component)</td><td>$appIdCol</td><td>$msgEsc</td><td>$($entry.SourceFile)</td></tr>"
    }

    $summaryRowsHtml = foreach ($s in $summary) {
        "<tr><td>$($s.Component)</td><td>$($s.Total)</td><td>$($s.Info)</td><td class='warn'>$($s.Warning)</td><td class='err'>$($s.Error)</td><td class='succ'>$($s.Success)</td></tr>"
    }

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
  .summary-box { display:flex; gap:20px; margin-bottom:20px; }
  .stat { background:#252526; border:1px solid #3c3c3c; padding:10px 20px; border-radius:4px; }
  .stat .num { font-size:28px; font-weight:bold; }
  .stat .lbl { font-size:11px; color:#888; }
  code { background:#252526; padding:2px 4px; border-radius:2px; font-size:11px; color:#ce9178; }
  code[title] { cursor: help; border-bottom: 1px dotted #888; }
</style>
</head>
<body>
<h1>Intune Log Report</h1>
<p style="color:#888">Generovane: $generatedAt | Log priecinok: $LogPath</p>
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
<tr><th>Cas</th><th>Zavaznost</th><th>Komponent</th><th>ApplicationId</th><th>Sprava</th><th>Subor</th></tr>
$($rowsHtml -join "`n")
</table>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($htmlOut, $html, [System.Text.Encoding]::UTF8)
    Write-Host "HTML report ulozeny: $htmlOut" -ForegroundColor Green
}