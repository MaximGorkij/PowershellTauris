# PowerShell 5.1 Kompatibilita Review - Adresár V4

**Dátum revizie:** 21.4.2026  
**Cieľ:** Skontrolovať kompatibilitu všetkých skriptov s PowerShell 5.1 (Windows PowerShell desktop edition)

---

## 📊 Súhrn Zistení

| Skript | Status | Kritické Problémy | Váha |
|--------|--------|-------------------|------|
| **Install.ps1** | ⚠️ PROBLÉM | Regex s quotes; závislosti modulov | VYSOKÁ |
| **detection.ps1** | ❌ KRITICKÉ | Regex syntax chyba (quotes); chýba error handling | VYSOKÁ |
| **remediation.ps1** | ❌ KRITICKÉ | Regex syntax chyba (quotes); chýba error handling | VYSOKÁ |
| **Uninstall.ps1** | ❌ KRITICKÉ | Regex syntax chyba (quotes) | VYSOKÁ |
| **Expand-IntuneWin.ps1** | ✅ OK | Bez problémov | NÍZKA |

---

## 🔴 KRITICKÉ PROBLÉMY

### 1. **REGEX SYNTAX CHYBA v `Import-DotEnv` funkcii** ⚠️ VŠETKY SKRIPTY

#### Problem:
```powershell
# ❌ PROBLEMATICKÉ (v detection.ps1, remediation.ps1, Uninstall.ps1)
if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }
```

**Dôvod:** Single quotes (apostrofy) v regex pattern sú slabo escapované. V PS 5.1 môže to spôsobiť:
- Syntax warnings
- Neočakávané chování s UTF-8 kódovaním
- Možný parser error

#### ✅ SPRÁVNA SYNTAX (ako je v Install.ps1):
```powershell
if ($value -match '^["`"](.*)[\"`"]$') { $value = $matches[1] }
```

**Súbory s CHYBOU:**
- `detection.ps1` - riadok ~11
- `remediation.ps1` - riadok ~11  
- `Uninstall.ps1` - riadok ~11

---

### 2. **NEÚPLNÝ ERROR HANDLING** ⚠️ detection.ps1 & remediation.ps1

#### Problem:
V detection a remediation skriptoch chýba `finally` blok na odpojenie z Graph:

```powershell
# ❌ CHÝBA:
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
```

Ak script padne, connection by mal ostať otvorený.

---

### 3. **ZÁVISLOSŤ NA EXTERNÝCH MODULOCH** 📦

#### Microsoft.Graph Moduly:
```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement
```

**Status:** 
- ✅ Podporované v PS 5.1
- ⚠️ **NUTNOSŤ:** Intune zariadenia musia mať internet prístup pre `Install-Module`
- ⚠️ **RIZIKO:** Ak `Install-Module` zlyhá, celý skript zlyhá

#### LogHelper Modul:
```powershell
Import-Module LogHelper -ErrorAction Stop
```

**Očakávaná lokácia:**
```
C:\Program Files\WindowsPowerShell\Modules\LogHelper
```

**Status:**
- Musí byť nainštalovaný VOR spustením skriptov
- Ak chýba, skript zlyhá s `exit 1`

---

## ⚠️ VAROVANIA - KOMPATIBILITA

### 4. **`ConvertFrom-Json` bez `-AsHashtable`** ✅ OK

```powershell
# ✅ SPRÁVNE v PS 5.1 (neberie -AsHashtable parameter)
$jsonContent = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ipMap = @{}
$jsonContent.PSObject.Properties | ForEach-Object { $ipMap[$_.Name] = $_.Value }
```

**Status:** Implementácia je správna - PS 5.1 nezvláda `-AsHashtable`, ale PSObject konverzia funguje.

---

### 5. **`Get-NetIPAddress`** ✅ OK

```powershell
$ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
    Where-Object { $_.IPAddress -match '^10\.' -and $_.AddressState -eq 'Preferred' }
```

**Status:** 
- ✅ Dostupné v PS 5.1
- ✅ Net.IPAddress typ je kompatibilný

---

### 6. **`System.IO.Compression.FileSystem` (Expand-IntuneWin.ps1)** ✅ OK

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($decryptedZip, $OutputPath)
```

**Status:** ✅ Plne podporované v PS 5.1

---

### 7. **`System.Security.Cryptography` (Expand-IntuneWin.ps1)** ✅ OK

```powershell
$aes = [System.Security.Cryptography.Aes]::Create()
```

**Status:** ✅ Plne podporované v PS 5.1

---

### 8. **`ConvertTo-Json -InputObject`** ✅ OK

```powershell
$patchBody = ConvertTo-Json -InputObject @{
    extensionAttribute1 = $location
}
```

**Status:** ✅ Plne podporované v PS 5.1

---

## 🔧 OPRAVY POTREBNÉ

### Fix 1: Oprava Regex v detection.ps1

**Čas:** ~5 minút  
**Riadok:** ~11

```powershell
# ❌ PRED:
if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }

# ✅ PO:
if ($value -match '^["`"](.*)[\"`"]$') { $value = $matches[1] }
```

---

### Fix 2: Oprava Regex v remediation.ps1

**Čas:** ~5 minút  
**Riadok:** ~11

```powershell
# ❌ PRED:
if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }

# ✅ PO:
if ($value -match '^["`"](.*)[\"`"]$') { $value = $matches[1] }
```

---

### Fix 3: Oprava Regex v Uninstall.ps1

**Čas:** ~5 minút  
**Riadok:** ~11

```powershell
# ❌ PRED:
if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }

# ✅ PO:
if ($value -match '^["`"](.*)[\"`"]$') { $value = $matches[1] }
```

---

### Fix 4: Pridaj `finally` blok do detection.ps1

**Čas:** ~5 minút  
**Lokácia:** Koniec bloku `try-catch`

```powershell
# ✅ PRIDAŤ NA KONIEC:
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
```

---

### Fix 5: Pridaj `finally` blok do remediation.ps1

**Čas:** ~5 minút  
**Lokácia:** Koniec bloku `try-catch`

```powershell
# ✅ PRIDAŤ NA KONIEC:
finally {
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
```

---

## 📋 TESTOVACÍ PLÁN

### Pre PS 5.1 validáciu:

1. **Syntax Check:**
   ```powershell
   $files = Get-ChildItem "d:\findrik\PowerShell\Intune\IPLoc\V4\*.ps1"
   foreach ($file in $files) {
       [System.Management.Automation.PSParser]::Tokenize((Get-Content $file.FullName), [ref]$null)
       Write-Host "$($file.Name): OK"
   }
   ```

2. **Modul Check:**
   ```powershell
   Get-Module -ListAvailable Microsoft.Graph.Authentication
   Get-Module -ListAvailable LogHelper
   ```

3. **Unit Test:**
   ```powershell
   # Pred spustením na Intune zariadení, test v PS 5.1:
   powershell.exe -Version 5.1 -File .\Install.ps1
   ```

---

## ✅ KOMPATIBILITA - FINÁLNY VERDIKT

| Komponent | PS 5.1 | Poznámka |
|-----------|--------|----------|
| Syntax | ⚠️ PROBLÉM | Regex chyby - NUTNÉ FIX |
| Príkazy | ✅ OK | Všetky príkazy sú v PS 5.1 |
| Moduly | ✅ OK | Microsoft.Graph + LogHelper sú kompatibilné |
| Encoding | ✅ OK | UTF8 je podporované |
| Kryptografia | ✅ OK | System.Security.Cryptography je OK |
| .NET Features | ✅ OK | Žiadne PS 7+ features |

---

## 🎯 ZÁVER

**Status:** ⚠️ **BEDINEČNE KOMPATIBILNÍ S MENŠÍMI OPRAVAMI**

### Čo je potrebné:
1. ✅ Opraviť regex syntax v 3 súboroch (detection, remediation, uninstall)
2. ✅ Pridať `finally` blok do 2 súborov (detection, remediation)
3. ✅ Testovať na PS 5.1 zariadení pred deploymentom na Intune

### Čo je OK:
- ✅ Všetky príkazy sú kompatibilné
- ✅ Kryptografia, JSON, Network - všetko OK
- ✅ Install-Module funguje v PS 5.1
- ✅ Modul LogHelper je konzistentne použitý

---

**Odporúčanie:** Aplikuj opravy a thorough test na PS 5.1 systémoch pred produkčným deploymentom.
