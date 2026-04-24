<#
.SYNOPSIS
    Detekcny skript pre Intune Log Parser Win32 app.
.DESCRIPTION
    Kontroluje, ci je parser nainstalovany a scheduled task zaregistrovany.
    Intune Win32 detection pravidla: ak skript vypise STDOUT a exit code je 0,
    aplikacia sa povazuje za nainstalovanu. Prazdny STDOUT alebo non-zero exit
    znamena, ze aplikacia nie je nainstalovana.
.NOTES
    Verzia: 1.0
    Autor: Marek F.
    Pozadovane moduly: ScheduledTasks (built-in Windows)
    Datum vytvorenia: 23.04.2026
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = 'C:\TaurisIT\Scripts\LogParser'
$ScriptPath = Join-Path $InstallRoot 'Parse-IntuneLogs.ps1'
$CsvPath = Join-Path $InstallRoot 'intune-apps.csv'
$TaskName = 'TaurisIT_IntuneLogParser'
$TaskFolder = '\TaurisIT\'

try {
    $scriptOk = Test-Path $ScriptPath
    $csvOk = Test-Path $CsvPath
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    $taskOk = [bool]$task

    if ($scriptOk -and $csvOk -and $taskOk) {
        Write-Output "Installed: Parse-IntuneLogs.ps1 + scheduled task $TaskName pritomne."
        exit 0
    }
    else {
        # Nic na STDOUT => Intune vyhodnoti ako NotInstalled
        exit 0
    }
}
catch {
    # Chyba pri detekcii - povazuj za nenainstalovane
    exit 0
}