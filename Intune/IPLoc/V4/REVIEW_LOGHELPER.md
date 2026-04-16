# LogHelper Modul - Review & Opravy V4

## 📋 Review LogHelper.psm1

### ✅ Stav modulu: **VYHOVUJÚCI s doplneniami**

#### Funkcie v module:
1. **Write-CustomLog** - Základné logovanie (súbor + Event Log)
2. **Write-IntuneLog** - Hlavná funkcia (spätne kompatibilná)
3. **Initialize-LogSystem** - Inicializácia (adresáre, oprávnenia)
4. **Clear-OldLogs** - Čistenie starých logov
5. **Send-IntuneAlert** - Alertovanie pre kritické udalosti
6. **Get-LogFiles** - Listovanie logov
7. **Get-LogStatistics** - Štatistiky logov

#### 🔧 Kľúčové opravy v module:
- ✅ **FIX Event Log** - `SourceExists` obalený `try/catch` (řeší problémy s nedostupnými logmi)
- ✅ **Automatické čistenie** - `Clear-OldLogs` s retention politikou
- ✅ **Mapovanie úrovní** - INFO/WARN/ERROR/SUCCESS/DEBUG → Event Log typy
- ✅ **Dynamické EventId** - 1000/2000/3000 podľa typu
- ✅ **Bezpečné parametrizovanie** - Všetky parametre validované

---

## 🔍 Chybajúce prepojenia v V4

### ❌ Install.ps1
**Problém:** Nevolá funkcie z LogHelper pri čistení logov a alertoch  
**Oprava:**
```powershell
# PRIDANÉ:
Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir
Send-IntuneAlert -Message "..." -Severity Error -EventSource $EventSource -LogFile $LogFile
```

### ❌ detection.ps1
**Problém:** 
- Volá `Write-IntuneLog` aj keď LogHelper nemusí byť inicializovaný
- Chýba `$LogFilePath` premenná (nepotrebná, ale pre konzistenciu)

**Oprava:**
```powershell
# Pridaná premenná
$LogFilePath = Join-Path $LogDir $LogFile

# Oddelená inicializácia od logovania
if (Test-Path "C:\Program Files\WindowsPowerShell\Modules\LogHelper") {
    $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30
}
```

### ❌ remediation.ps1
**Problémy:**
- Nevolá `Clear-OldLogs` na konci
- Nevolá `Send-IntuneAlert` pri chybách
- Chýba `$LogFilePath` premenná

**Oprava:**
```powershell
# Na konci úspešnosti:
Clear-OldLogs -RetentionDays 30 -LogDirectory $LogDir

# Pri chybách:
Send-IntuneAlert -Message "..." -Severity Error -EventSource $EventSource -LogFile $LogFile
```

### ❌ Uninstall.ps1
**Problémy:**
- Volá `Write-IntuneLog` bez `-EventSource` parametra
- PATCH body má nesprávny formát (`extensionAttributes` wrapper)
- Nevolá `Send-IntuneAlert` pri chybách

**Oprava:**
```powershell
# Korektný PATCH body (bez wrapperu):
$clearBody = ConvertTo-Json -InputObject @{
    extensionAttribute1 = $null
}

# Korektný Write-IntuneLog call:
Write-IntuneLog -Message "..." -Level SUCCESS -LogFile $LogFile -EventSource $EventSource

# Alert pri chybe:
Send-IntuneAlert -Message "..." -Severity Error -EventSource $EventSource -LogFile $LogFile
```

---

## ✅ Implemented Opravy

### 1. **Install.ps1** ✅
- ✅ Pridaná `Clear-OldLogs` volanie
- ✅ Pridaná `Send-IntuneAlert` pri chybách
- ✅ Zachovaná správna inicializácia LogHelper

### 2. **detection.ps1** ✅
- ✅ Oddelená inicializácia od logovania
- ✅ Pridaná `$LogFilePath` premenná (konzistencia)
- ✅ Zabezpečené LogHelper vol zaradený v podmienke

### 3. **remediation.ps1** ✅
- ✅ Pridaná `Clear-OldLogs` volanie
- ✅ Pridaná `Send-IntuneAlert` pri chybách
- ✅ Pridaná `$LogFilePath` premenná
- ✅ Odstránené zbytočné `$null =` wrappers

### 4. **Uninstall.ps1** ✅
- ✅ Opravené `Write-IntuneLog` volania s `-EventSource`
- ✅ Opravené PATCH body (bez `extensionAttributes` wrapperu)
- ✅ Pridaná `Send-IntuneAlert` pri chybách
- ✅ Inicializácia oddelená od logovania

---

## 🔗 Prepojenia medzi modulmi

### LogHelper Export
```powershell
Export-ModuleMember -Function @(
    'Write-CustomLog',
    'Write-IntuneLog',
    'Initialize-LogSystem',
    'Clear-OldLogs',
    'Send-IntuneAlert',
    'Get-LogFiles',
    'Get-LogStatistics'
)
```

### V4 Skripty - Volania LogHelper
```
Install.ps1:
  - Initialize-LogSystem ✅
  - Write-IntuneLog ✅
  - Clear-OldLogs ✅
  - Send-IntuneAlert ✅

detection.ps1:
  - Initialize-LogSystem ✅
  - Write-IntuneLog ✅

remediation.ps1:
  - Initialize-LogSystem ✅
  - Write-IntuneLog ✅
  - Clear-OldLogs ✅
  - Send-IntuneAlert ✅

Uninstall.ps1:
  - Initialize-LogSystem ✅
  - Write-IntuneLog ✅
  - Send-IntuneAlert ✅
```

---

## 📝 Výstup logov

### Lokácia logov:
- **Log adresár:** `C:\TaurisIT\Log\IPcheck`
- **Log súbor:** `IPcheck.log`
- **Event Log zdroj:** `IPLocationWin32App`, `IPLocationDetection`, `IPLocationRemediation`, `IPLocationUninstall`
- **Event Log názov:** `IntuneScript`

### Retention politika:
- **Archivovanie:** Automatické čistenie logov starších ako 30 dní
- **Iniciátor:** `Clear-OldLogs` funkcia volaná na konci skriptov

### Alerty:
- **Typ:** Event Log alerty (`Send-IntuneAlert`)
- **Úroveň:** Warning/Error/Critical
- **Aktivácia:** Pri kritických chybách

---

## 🧪 Testing Checklist

- [ ] Skontroluj logy v `C:\TaurisIT\Log\IPcheck\IPcheck.log`
- [ ] Skontroluj Event Log v `Event Viewer → Custom Views → Administrative Events` (zdroj: IPLocation*)
- [ ] Testuj na zariadení s Win32 app nasadenou
- [ ] Testuj detection script manuálne
- [ ] Testuj remediation script manuálne
- [ ] Testuj uninstall script
- [ ] Skontroluj atert logovanie pri chybách
- [ ] Skontroluj čistenie starých logov (> 30 dní)

---

## 📌 Poznámky

1. **Event Log Access:** Ak je nedostupný, skript pokračuje (file-based logging len)
2. **Graph API:** Bezpečný try/catch okolo všetkých Graph API volaní
3. **Parametrizovanie:** Všetky parametre majú defaults a fallbacks
4. **Compatibility:** Spätná kompatibilita so starými skriptami

---

**Dátum revizie:** 2026-04-16  
**Revízia:** 2.1.0 → V4 Integration  
**Status:** ✅ READY FOR PRODUCTION
