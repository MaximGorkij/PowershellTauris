<#
.SYNOPSIS
    Nasadenie Intune Log Parser - instalacny skript pre Win32 app v Microsoft Intune.
.DESCRIPTION
    Skopiruje Parse-IntuneLogs.ps1 a intune-apps.csv do C:\TaurisIT\Scripts\LogParser,
    vytvori vystupnu zlozku C:\TaurisIT\Export\LogParser a zaregistruje scheduled task
    "TaurisIT_IntuneLogParser", ktory kazdy den o 07:00 spusti parser ako SYSTEM
    a vytvori error-log-YYYYMMDD.log (plus .csv a .html) s errormi z Intune Management
    Extension logov za aktualny stav.
.NOTES
    Verzia: 1.0
    Autor: Marek F.
    Pozadovane moduly: ScheduledTasks (built-in Windows)
    Datum vytvorenia: 23.04.2026
    Logovanie: STDOUT -> IntuneManagementExtension.log + C:\TaurisIT\Export\LogParser\install.log
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- konfiguracia -----------------------------------------------------------

$InstallRoot = 'C:\TaurisIT\Scripts\LogParser'
$ExportRoot = 'C:\TaurisIT\Export\LogParser'
$InstallLog = Join-Path $ExportRoot 'install.log'
$TaskName = 'TaurisIT_IntuneLogParser'
$TaskFolder = '\TaurisIT\'
$ScriptFile = 'Parse-IntuneLogs.ps1'
$MappingFile = 'intune-apps.csv'

# ---- helper logovanie -------------------------------------------------------

function Write-InstallLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (Test-Path (Split-Path $InstallLog -Parent)) {
            Add-Content -Path $InstallLog -Value $line -Encoding UTF8
        }
    }
    catch {
        # fallback - ignoruj ak log nejde zapisat
    }
}

# ---- start ------------------------------------------------------------------

try {
    Write-InstallLog "=== Instalacia Intune Log Parser zacala ===" 'INFO'
    Write-InstallLog "PSScriptRoot: $PSScriptRoot" 'INFO'
    Write-InstallLog "Bezi ako: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" 'INFO'

    # 1. Vytvorenie cielovych zloziek
    foreach ($dir in @($InstallRoot, $ExportRoot)) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Write-InstallLog "Vytvorena zlozka: $dir" 'INFO'
        }
        else {
            Write-InstallLog "Zlozka uz existuje: $dir" 'INFO'
        }
    }

    # 2. Kopirovanie suborov z balicka
    $sourceScript = Join-Path $PSScriptRoot $ScriptFile
    $sourceMapping = Join-Path $PSScriptRoot $MappingFile

    if (-not (Test-Path $sourceScript)) {
        throw "Zdrojovy skript neexistuje: $sourceScript"
    }
    if (-not (Test-Path $sourceMapping)) {
        throw "Zdrojovy CSV neexistuje: $sourceMapping"
    }

    Copy-Item -Path $sourceScript  -Destination $InstallRoot -Force
    Copy-Item -Path $sourceMapping -Destination $InstallRoot -Force
    Write-InstallLog "Skopirovane subory do: $InstallRoot" 'INFO'

    # 3. Vytvorenie scheduled task
    $targetScript = Join-Path $InstallRoot $ScriptFile
    $targetCsv = Join-Path $InstallRoot $MappingFile

    $taskArgs = @(
        '-ExecutionPolicy Bypass'
        '-NonInteractive'
        '-NoProfile'
        "-File `"$targetScript`""
        '-Severity Error'
        '-Output All'
        "-AppMappingFile `"$targetCsv`""
        "-OutputPath `"$ExportRoot`""
    ) -join ' '

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -Daily -At '07:00'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -MultipleInstances IgnoreNew

    # Odstrani existujucu instanciu tasku ak bol update
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Confirm:$false
        Write-InstallLog "Existujuci scheduled task odstraneny (pred znovu-registraciou)." 'INFO'
    }

    Register-ScheduledTask `
        -TaskName  $TaskName `
        -TaskPath  $TaskFolder `
        -Action    $action `
        -Trigger   $trigger `
        -Principal $principal `
        -Settings  $settings `
        -Description 'TaurisIT: denne parsovanie Intune Management Extension logov (Parse-IntuneLogs.ps1)' | Out-Null

    Write-InstallLog "Scheduled task zaregistrovany: ${TaskFolder}${TaskName} (denne 07:00)" 'INFO'

    # 4. Prve spustenie hned po instalacii (nepovinne - aby bol log okamzite k dispozicii)
    try {
        Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder
        Write-InstallLog "Task spusteny okamzite po instalacii." 'INFO'
    }
    catch {
        Write-InstallLog "Okamzite spustenie tasku zlyhalo (nekriticke): $_" 'WARN'
    }

    Write-InstallLog "=== Instalacia dokoncena uspesne ===" 'INFO'
    exit 0
}
catch {
    Write-InstallLog "CHYBA pocas instalacie: $_" 'ERROR'
    Write-InstallLog "Stack: $($_.ScriptStackTrace)" 'ERROR'
    exit 1
}