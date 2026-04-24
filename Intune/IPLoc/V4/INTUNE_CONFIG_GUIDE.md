# Intune Win32 App Configuration Guide - IP Location Detection

## Overview
This guide describes how to configure the IP Location Detection Win32 app in Microsoft Intune after the WoW64 fix has been applied to all scripts.

## What Changed

### Problem (Before)
- Intune runs PowerShell in 32-bit mode (WoW64) by default
- This caused:
  - ❌ "Failed to create installer process. Error code = 2"
  - ❌ "LogonUser failed with error code : 1008"
  - ❌ Event Viewer logs remained empty
  - ❌ Installation failures without visible error messages

### Solution (After)
- All 4 scripts now include automatic 64-bit process detection and restart
- Event Log sources are created directly without LogHelper dependency
- Fallback logging ensures visibility even if modules fail
- Scripts now work correctly in SYSTEM context

---

## Intune Configuration Steps

### 1. Package the App
Use **Microsoft Intune Win32 Content Prep Tool**:
```powershell
New-IntuneWin32AppPackage -SourceFolder "D:\findrik\PowerShell\Intune\IPLoc\V4" `
    -OutputFolder "D:\findrik\PowerShell\Intune\IPLoc\Package" `
    -IntuneWinFilename "IPLocation.intunewin"
```

**Files to include in package:**
- Install.ps1
- detection.ps1
- remediation.ps1
- Uninstall.ps1
- IPLocationMap.json
- .env (with Graph credentials - handle securely!)

---

### 2. Create Win32 App in Intune

#### **App Properties**
| Field | Value |
|-------|-------|
| **Name** | IP Location Detection |
| **Description** | Sets Entra ID extensionAttribute1 based on device IP location |
| **Publisher** | TaurisIT |
| **Owner** | [Your Name] |
| **Category** | Business Apps |

#### **App Information**
- Upload `IPLocation.intunewin` package

---

### 3. **CRITICAL: Install Command Configuration**

**⚠️ THIS IS THE KEY FIX - Use explicit 64-bit PowerShell path:**

```
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

**NOT:**
```
powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1  ❌ WRONG - will run 32-bit
```

---

### 4. Uninstall Command

```
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

---

### 5. Detection Rule (Compliance Check)

| Setting | Value |
|---------|-------|
| **Rule Type** | File |
| **Path** | `C:\TaurisIT\Log\IPLoc` |
| **File or Folder** | `IPcheck.log` |
| **Detection Method** | File Exists |
| **Associated with 32-bit app on 64-bit clients** | No |

**Alternative: Run Detection Script**
- Use `detection.ps1` as compliance detection script
- Use same 64-bit PowerShell path

---

### 6. Requirements

| Setting | Value |
|---------|-------|
| **OS Architecture** | 64-bit |
| **Minimum OS** | Windows 10 1909 |
| **Device Owner Type** | Company |

---

### 7. Remediation Settings

**For Compliance Remediation:**
- Use `remediation.ps1`
- Command: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\remediation.ps1`

---

## Testing Before Production

### On Test Device:

1. **Verify Install Command Works:**
```powershell
# Run as SYSTEM via PsExec (or in Intune test)
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"
```

2. **Check Event Log:**
```powershell
Get-EventLog -LogName Application -Source "IntuneAppInstall" -Newest 10
```
**Should see entries like:**
- "========== ZACIATOK INSTALACIE WIN32 APP =========="
- "Aktualna IP adresa: 10.x.x.x"
- "VYSLEDOK: Lokacia 'RS' ..."

3. **Check Text Log:**
```powershell
Get-Content "C:\TaurisIT\Log\IPLoc\IPcheck.log" | Select-Object -Last 20
```
**Should see timestamped entries**

4. **Verify Entra ID Update:**
```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Directory.Read.All"
$device = Get-MgDevice -Filter "displayName eq '$env:COMPUTERNAME'"
$device | Select-Object DisplayName, @{N='Location';E={$_.AdditionalProperties.extensionAttribute1}}
```
**Should show correct location (e.g., "RS", "TC", "KE")**

---

## Troubleshooting

### Still Getting Error Code 2?
**Cause:** PowerShell path in Install command is wrong
**Fix:** 
- Verify 64-bit path is used: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
- NOT `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` (32-bit)

### Event Log Still Empty?
**Cause:** Event Log source not created
**Check:**
```powershell
# On device where app was deployed:
[System.Diagnostics.EventLog]::SourceExists("IntuneAppInstall")
[System.Diagnostics.EventLog]::SourceExists("IntuneScript")
```

**Manual fix if needed:**
```powershell
# Run as Administrator:
New-EventLog -LogName Application -Source "IntuneAppInstall" -ErrorAction SilentlyContinue
New-EventLog -LogName Application -Source "IntuneScript" -ErrorAction SilentlyContinue
```

### Graph Authentication Fails?
- Verify `.env` file has correct credentials
- Check App Registration has `Device.ReadWrite.All` permission (Application type, not Delegated)
- Verify Admin Consent is granted

### Device Not Found in Entra ID?
- Verify device is Azure AD joined
- Check device display name matches `$env:COMPUTERNAME`
- Wait a few minutes for device sync to complete

---

## Expected Results

After successful deployment:

✅ Install completes without errors  
✅ Event Viewer shows entries in Application log  
✅ Text log at `C:\TaurisIT\Log\IPLoc\IPcheck.log` contains timestamps and messages  
✅ Device extensionAttribute1 updated in Entra ID with location  
✅ Compliance detection reports "Compliant" when locations match  
✅ Remediation script fixes non-compliant states  

---

## Log Locations

| Log Type | Location |
|----------|----------|
| **Event Log** | Application → Sources: "IntuneAppInstall", "IntuneScript" |
| **Text Log** | `C:\TaurisIT\Log\IPLoc\IPcheck.log` |
| **Format** | `[YYYY-MM-DD HH:mm:ss] [LEVEL] MESSAGE` |
| **Retention** | Auto-cleaned after 30 days |

---

## Files in V4 Directory

```
d:\findrik\PowerShell\Intune\IPLoc\V4\
├── Install.ps1                    ✅ 64-bit ready, WoW64 fix
├── detection.ps1                  ✅ 64-bit ready, WoW64 fix
├── remediation.ps1                ✅ 64-bit ready, WoW64 fix
├── Uninstall.ps1                  ✅ 64-bit ready, WoW64 fix
├── IPLocationMap.json              (IP prefix mapping)
├── .env                            (NOT in repo - credentials)
├── Expand-IntuneWin.ps1           (utility - unchanged)
├── INTUNE_CONFIG_GUIDE.md          (this file)
└── [other documentation files]
```

---

## Summary of Key Changes

| Before | After |
|--------|-------|
| `powershell.exe` in Install command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| 32-bit process execution | Automatic 64-bit restart if 32-bit detected |
| Manual Event Log source creation | Automatic source creation with fallback |
| Hard LogHelper dependency | Fallback logging if module unavailable |
| Silent failures | Visible logs in Event Viewer + text file |

---

## Next Steps

1. ✅ Update all 4 scripts with WoW64 fix (DONE)
2. ⏭️ Package Win32 app with Intune Content Prep Tool
3. ⏭️ Create Win32 App in Intune with 64-bit PowerShell path
4. ⏭️ Test on pilot devices
5. ⏭️ Deploy to production device group

---

**Last Updated:** 2026-04-22  
**Status:** Ready for Production Deployment
