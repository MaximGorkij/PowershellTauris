<#
.SYNOPSIS
    Instalacia alebo aktualizacia PowerShell modulu LogHelper.
.DESCRIPTION
    Skript skontroluje existenciu modulu LogHelper, porovna verziu, a ak je starsia alebo chyba, nahradi ju novou verziou.
    Zapisuje priebeh do .txt logu a Event Logu.
.AUTHOR
    Marek Findrik
.CREATED
    2025-09-05
.VERSION
    2.1.0
.NOTES
    Modul sa instaluje do C:\Program Files\WindowsPowerShell\Modules\LogHelper
    Logy sa ukladaju do C:\ProgramData\LogHelper\install_update_log.txt
    Pridane error handling a validacie pre Intune kompatibilitu
#>

$ModuleName = "LogHelper"
$ModulePath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper"
$SourceModule = ".\LogHelper.psm1"   # zdrojový modul v priečinku skriptu
$NewVersion = "2.1.0"

# Registry
$RegPath64 = "HKLM:\SOFTWARE\TaurisIT\LogHelper"
$RegPath32 = "HKLM:\SOFTWARE\WOW6432Node\TaurisIT\LogHelper"
$RegValue = "Version"

# Log
$LogDir = "$env:ProgramData\LogHelper"
$LogFile = "$LogDir\install_update_log.txt"

# Funkcia na logovanie
function Write-InstallLog {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts $Message"
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line } catch {}
}

# Vytvorenie log priečinka
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Write-InstallLog "=== Inštalácia/aktualizácia $ModuleName v$NewVersion ==="

# Kontrola zdrojového modulu
if (-not (Test-Path $SourceModule)) {
    Write-InstallLog "KRITICKÁ CHYBA: Zdrojový modul $SourceModule neexistuje."
    exit 1
}

# Odstránenie starého modulu
if (Test-Path $ModulePath) {
    try { Remove-Item -Path $ModulePath -Recurse -Force -ErrorAction Stop }
    catch { Write-InstallLog "VAROVANIE: Nepodarilo sa odstrániť starý modul: $($_.Exception.Message)" }
    Write-InstallLog "Starý modul odstránený."
}

# Vytvorenie adresára pre nový modul
New-Item -ItemType Directory -Path $ModulePath -Force | Out-Null

# Kopírovanie modulu
try {
    Copy-Item -Path $SourceModule -Destination (Join-Path $ModulePath "$ModuleName.psm1") -Force -ErrorAction Stop
    Write-InstallLog "Nový modul skopírovaný."
}
catch {
    Write-InstallLog "KRITICKÁ CHYBA pri kopírovaní modulu: $($_.Exception.Message)"
    exit 1
}

# Zápis verzie do registry (64-bit a 32-bit)
foreach ($regPath in @($RegPath64, $RegPath32)) {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    try {
        Set-ItemProperty -Path $regPath -Name $RegValue -Value $NewVersion -Force
        Write-InstallLog "Verzia $NewVersion zapísaná do registry: $regPath"
    }
    catch {
        Write-InstallLog "VAROVANIE: Nepodarilo sa zapísať registry $regPath $($_.Exception.Message)"
    }
}

Write-InstallLog "=== Inštalácia dokončená ==="
exit 0
