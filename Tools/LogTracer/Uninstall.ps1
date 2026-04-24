<#
.SYNOPSIS
    Odinstalacia Intune Log Parser - uninstall skript pre Win32 app v Microsoft Intune.
.DESCRIPTION
    Zrusi scheduled task "TaurisIT_IntuneLogParser" a odstrani zlozku
    C:\TaurisIT\Scripts\LogParser. Vygenerovane logy v C:\TaurisIT\Export\LogParser
    NEODSTRANUJE (user si ich moze archivovat/pozriet).
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
    catch { }
}

# ---- start ------------------------------------------------------------------

try {
    Write-InstallLog "=== Odinstalacia Intune Log Parser zacala ===" 'INFO'

    # 1. Zrusenie scheduled task
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Confirm:$false
        Write-InstallLog "Scheduled task ${TaskFolder}${TaskName} odstraneny." 'INFO'
    }
    else {
        Write-InstallLog "Scheduled task ${TaskFolder}${TaskName} neexistuje - preskakujem." 'INFO'
    }

    # 2. Odstranenie zlozky skriptov
    if (Test-Path $InstallRoot) {
        Remove-Item -Path $InstallRoot -Recurse -Force
        Write-InstallLog "Zlozka odstranena: $InstallRoot" 'INFO'
    }
    else {
        Write-InstallLog "Zlozka neexistuje: $InstallRoot - preskakujem." 'INFO'
    }

    # 3. Vystupne logy v C:\TaurisIT\Export\LogParser NEODSTRANUJEME
    Write-InstallLog "Vystupne logy v $ExportRoot ponechane (manualne vycistenie podla potreby)." 'INFO'

    Write-InstallLog "=== Odinstalacia dokoncena uspesne ===" 'INFO'
    exit 0
}
catch {
    Write-InstallLog "CHYBA pocas odinstalacie: $_" 'ERROR'
    exit 1
}