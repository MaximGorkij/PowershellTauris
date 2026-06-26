<#
.SYNOPSIS
    Kontrola dostupnosti RADIUS klientov registrovanych v NPS.
.DESCRIPTION
    Skript nacita vsetkych RADIUS klientov z lokalneho NPS (cez netsh),
    otestuje ich dostupnost cez ping a vypise HTML report aj sumarny vystup
    do konzoly. Urceny pre spustenie na DCKE30.
.NOTES
    Verzia: 1.0
    Autor: Ing. Marek Findrik
    Pozadovane moduly: ziaden (pouziva netsh a Test-Connection)
    Datum vytvorenia: 08.06.2025
    Logovanie: C:\TaurisIT\Log\NpsClientCheck
#>

#Requires -RunAsAdministrator

# --- Konfiguracia ---
$LogFileName  = 'NpsClientCheck\NpsClientCheck.log'
$ReportPath   = 'C:\TaurisIT\Log\NpsClientCheck\NpsClientCheck-Report.html'
$PingCount    = 1
$PingTimeout  = 1000  # ms

# --- LogHelper ---
$LogHelperPath = 'C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1'
if (Test-Path $LogHelperPath) {
    Import-Module $LogHelperPath -Force
    $useLog = $true
} else {
    $useLog = $false
    Write-Warning "LogHelper nebol najdeny, logovanie do suboru bude preskocene."
}

function Write-Log {
    param($Message, $Type = 'Information')
    if ($useLog) {
        Write-CustomLog -Message $Message -EventSource 'NpsClientCheck' `
            -EventLogName 'Application' -LogFileName $LogFileName -Type $Type
    }
    $color = switch ($Type) {
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'Cyan' }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $color
}

# --- Vytvorenie adresara pre report ---
$reportDir = Split-Path $ReportPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

# --- Nacitanie klientov z NPS cez netsh ---
Write-Log "Nacitavam RADIUS klientov z NPS..."

$netshOutput = netsh nps show client 2>&1
$clients = [System.Collections.Generic.List[PSCustomObject]]::new()

$currentName = $null
$currentIP   = $null
$currentStatus = $null

foreach ($line in $netshOutput) {
    if ($line -match '^\s*Name\s*=\s*(.+)') {
        $currentName = $Matches[1].Trim()
    }
    elseif ($line -match '^\s*Address\s*=\s*(.+)') {
        $currentIP = $Matches[1].Trim()
    }
    elseif ($line -match '^\s*State\s*=\s*(.+)') {
        $currentStatus = $Matches[1].Trim()
    }

    if ($currentName -and $currentIP -and $currentStatus) {
        $clients.Add([PSCustomObject]@{
            Name       = $currentName
            IP         = $currentIP
            NpsStatus  = $currentStatus
            Ping       = $null
        })
        $currentName = $null
        $currentIP   = $null
        $currentStatus = $null
    }
}

Write-Log "Najdenych klientov: $($clients.Count)"

# --- Ping test ---
Write-Log "Spustam ping testy (moze trvat chvilu)..."

$results = $clients | ForEach-Object {
    $client = $_
    $pingOk = Test-Connection -ComputerName $client.IP -Count $PingCount `
                              -TimeoutSeconds ($PingTimeout / 1000) -Quiet -ErrorAction SilentlyContinue
    $client.Ping = if ($pingOk) { 'OK' } else { 'NEDOSTUPNY' }
    $client
}

# --- Sumar do konzoly ---
$ok          = @($results | Where-Object { $_.Ping -eq 'OK' })
$nedostupny  = @($results | Where-Object { $_.Ping -eq 'NEDOSTUPNY' })
$disabled    = @($results | Where-Object { $_.NpsStatus -ne 'ENABLE' -and $_.NpsStatus -ne 'Enabled' })

Write-Log "=== VYSLEDKY ==="
Write-Log "Celkovo klientov : $($results.Count)"
Write-Log "Dostupnych (ping OK)  : $($ok.Count)"
Write-Log "Nedostupnych          : $($nedostupny.Count)"
Write-Log "Disabled v NPS        : $($disabled.Count)"

if ($nedostupny.Count -gt 0) {
    Write-Log "--- Nedostupni klienti ---" 'Warning'
    $nedostupny | ForEach-Object {
        Write-Log "  $($_.Name) ($($_.IP)) [NPS: $($_.NpsStatus)]" 'Warning'
    }
}

# --- HTML Report ---
$timestamp = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'
$rows = $results | Sort-Object Ping, Name | ForEach-Object {
    $pingClass = if ($_.Ping -eq 'OK') { 'ok' } else { 'fail' }
    $npsClass  = if ($_.NpsStatus -match 'Enabled|ENABLE') { '' } else { 'disabled' }
    "<tr class='$pingClass'>
        <td>$($_.Name)</td>
        <td>$($_.IP)</td>
        <td class='$npsClass'>$($_.NpsStatus)</td>
        <td class='ping-$pingClass'>$($_.Ping)</td>
    </tr>"
}

$html = @"
<!DOCTYPE html>
<html lang='sk'>
<head>
<meta charset='UTF-8'>
<title>NPS RADIUS Klienti - DCKE30</title>
<style>
  body { font-family: Segoe UI, sans-serif; background: #1e1e2e; color: #cdd6f4; margin: 20px; }
  h1 { color: #cba6f7; }
  .summary { display: flex; gap: 20px; margin-bottom: 20px; }
  .card { background: #313244; border-radius: 8px; padding: 16px 24px; min-width: 140px; text-align: center; }
  .card .num { font-size: 2em; font-weight: bold; }
  .card.ok   .num { color: #a6e3a1; }
  .card.fail .num { color: #f38ba8; }
  .card.warn .num { color: #fab387; }
  .card.total .num { color: #89b4fa; }
  table { border-collapse: collapse; width: 100%; background: #313244; border-radius: 8px; overflow: hidden; }
  th { background: #45475a; padding: 10px 14px; text-align: left; color: #cba6f7; }
  td { padding: 8px 14px; border-bottom: 1px solid #45475a; }
  tr.fail td { background: #2a1a1a; }
  .ping-ok   { color: #a6e3a1; font-weight: bold; }
  .ping-fail { color: #f38ba8; font-weight: bold; }
  .disabled  { color: #fab387; }
  .ts { color: #6c7086; font-size: 0.85em; margin-bottom: 10px; }
</style>
</head>
<body>
<h1>NPS RADIUS Klienti - DCKE30</h1>
<div class='ts'>Generovane: $timestamp</div>
<div class='summary'>
  <div class='card total'><div class='num'>$($results.Count)</div><div>Celkovo</div></div>
  <div class='card ok'>   <div class='num'>$($ok.Count)</div><div>Dostupnych</div></div>
  <div class='card fail'> <div class='num'>$($nedostupny.Count)</div><div>Nedostupnych</div></div>
  <div class='card warn'> <div class='num'>$($disabled.Count)</div><div>Disabled v NPS</div></div>
</div>
<table>
  <thead><tr><th>Nazov</th><th>IP adresa</th><th>Stav NPS</th><th>Ping</th></tr></thead>
  <tbody>
  $($rows -join "`n  ")
  </tbody>
</table>
</body>
</html>
"@

$html | Out-File -FilePath $ReportPath -Encoding UTF8
Write-Log "HTML report ulozeny: $ReportPath"
Write-Log "Hotovo."