# V4 IPLoc Scripts - LogHelper Integration ✅ DONE

**Dátum:** 21.4.2026 10:00  
**Status:** ✅ **VŠETKY SKRIPTY AKTUALIZOVANÉ NA LOGHELPER**

---

## 📝 Zmeny Aplikované

### 1. **Install.ps1** ✅
- ✅ Importuje LogHelper modul z `C:\Program Files\WindowsPowerShell\Modules\LogHelper`
- ✅ Fallback na natívne logging ak LogHelper chýba
- ✅ Volá `Write-IntuneLog` namiesto custom Write-ProcessLog
- ✅ Volá `Initialize-LogSystem` pre inicializáciu logu
- ✅ Volá `Clear-OldLogs` pre čistenie starých logov
- ✅ Volá `Send-IntuneAlert` pre upozornenia
- ✅ Robustný error handling

### 2. **detection.ps1** ✅
- ✅ Importuje LogHelper modul
- ✅ Všetky `Write-ProcessLog` → `Write-IntuneLog`
- ✅ Inicializácia log systému cez LogHelper
- ✅ Fallback handling ak modul chýba
- ✅ Finally blok na odpojenie z Graph

### 3. **remediation.ps1** ✅
- ✅ Importuje LogHelper modul
- ✅ Všetky Write-ProcessLog → Write-IntuneLog
- ✅ Inicializácia log systému cez LogHelper
- ✅ Fallback handling ak modul chýba
- ✅ Finally blok na odpojenie z Graph

### 4. **Uninstall.ps1** ✅
- ✅ Importuje LogHelper modul
- ✅ Všetky Write-ProcessLog → Write-IntuneLog
- ✅ Inicializácia log systému cez LogHelper
- ✅ Fallback handling ak modul chýba
- ✅ Finally blok na odpojenie z Graph

---

## 🔧 Detaily Implementácie

### LogHelper Import
```powershell
$logHelperPath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper"
if (Test-Path $logHelperPath) {
    try { 
        Import-Module LogHelper -ErrorAction Stop; 
        $logHelperAvailable = $true 
    } 
    catch { 
        $logHelperAvailable = $false 
    }
} else { 
    $logHelperAvailable = $false 
}
```

### LogHelper Inicializácia
```powershell
if ($logHelperAvailable) {
    try {
        $null = Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 30 -ErrorAction SilentlyContinue
    } catch { }
}
```

### LogHelper Logging
```powershell
Write-IntuneLog -Message "Správa" -Level "INFO" -LogFile $LogFile -EventSource $EventSource -ErrorAction SilentlyContinue
```

---

## 📊 Logovací Úroveň

Všetky skripty logujú nasledovné udalosti:

| Úroveň | Príklady |
|--------|---------|
| **INFO** | Inicializácia, načítavanie konfigurácie, pripojovanie |
| **OK** | Úspešné fázy (modul nainštalovaný, zariadenie nájdené) |
| **SUCCESS** | Úspešné dokončenie skriptu |
| **WARNING** | Non-compliant stav, varovania |
| **ERROR** | Chyby, výnimky |
| **DEBUG** | Detailné informácie (prefix matching) |

---

## 🎯 Event Log vs Text Log

Všetky skripty píšu do:

1. **Event Log (Application)** - cez LogHelper
   - Source: `IntuneAppInstall` (Install) / `IntuneScript` (Detection/Remediation)
   - Dostupné v Event Viewer → Applications
   
2. **Text Log File**
   - Cesta: `C:\TaurisIT\Log\IPLoc\IPcheck.log`
   - Formát: `[YYYY-MM-DD HH:mm:ss] [LEVEL] MESSAGE`
   - Retencia: 30 dní (automaticky čistené)

---

## ✅ Validácia

### PowerShell 5.1 Kompatibilita
- ✅ Všetky príkazy sú kompatibilné
- ✅ Regex syntax opravené (backticks na backticks v stringoch)
- ✅ ConvertFrom-Json bez `-AsHashtable`
- ✅ Microsoft.Graph SDK 2.0

### Logování
- ✅ Všetky skripty logujú do Event Log
- ✅ Text log v C:\TaurisIT\Log\IPLoc\IPcheck.log
- ✅ Fallback ak LogHelper chýba

### Error Handling
- ✅ Try-catch-finally na všetkých skriptoch
- ✅ Finally blok odpája Graph
- ✅ -ErrorAction SilentlyContinue na nedôležitých operáciách

---

## 🚀 Nasadenie

### Predpoklady
1. LogHelper modul nainštalovaný na `C:\Program Files\WindowsPowerShell\Modules\LogHelper`
2. Microsoft.Graph moduly (instalujú sa automaticky ak chýbajú)
3. PowerShell 5.1+ (Windows PowerShell)

### Test
```powershell
# Test Install.ps1
powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1

# Test Detection.ps1
powershell.exe -ExecutionPolicy Bypass -File .\detection.ps1

# Check Event Log
Get-EventLog -LogName Application -Source IntuneAppInstall -Newest 10
```

---

## 📋 Súhrnný Zoznam Súborov

| Súbor | Stav | Event Log | Text Log |
|-------|------|-----------|----------|
| Install.ps1 | ✅ Updated | ✅ IntuneAppInstall | ✅ IPcheck.log |
| detection.ps1 | ✅ Updated | ✅ IntuneScript | ✅ IPcheck.log |
| remediation.ps1 | ✅ Updated | ✅ IntuneScript | ✅ IPcheck.log |
| Uninstall.ps1 | ✅ Updated | ✅ IntuneScript | ✅ IPcheck.log |

---

## 🎯 Záver

**Všetky 4 Intune Win32 skripty sú teraz:**
- ✅ Kompatibilné s PowerShell 5.1
- ✅ Integrované s LogHelper modul
- ✅ Logujú do Event Viewer Application Log
- ✅ Logujú do textového logu v C:\TaurisIT\Log\IPLoc\
- ✅ Majú robustný fallback ak LogHelper chýba
- ✅ Pripravené na produkčný deployment na Intune

**Event Log sa teraz zobrazí v:** 
- Windows Event Viewer → Applications → Source: `IntuneAppInstall` alebo `IntuneScript`
