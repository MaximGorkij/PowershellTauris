==========================================================================
  TaurisIT Intune Log Parser - nasadenie cez Microsoft Intune (Win32 app)
==========================================================================

OBSAH BALICKA
--------------------------------------------------------------------------
  Parse-IntuneLogs.ps1    hlavny parser (upraveny - default output
                          do C:\TaurisIT\Export\LogParser,
                          nazvy error-log-YYYYMMDD.{log|csv|html})
  intune-apps.csv         mapovanie GUID -> DisplayName
  Install.ps1             instalacny skript (kopiruje subory +
                          vytvara scheduled task)
  Uninstall.ps1           odinstalacny skript
  Detect.ps1              detekcny skript pre Intune

CIELOVY STAV NA ZARIADENI
--------------------------------------------------------------------------
  C:\TaurisIT\Scripts\LogParser\Parse-IntuneLogs.ps1
  C:\TaurisIT\Scripts\LogParser\intune-apps.csv
  C:\TaurisIT\Export\LogParser\error-log-YYYYMMDD.log  (+ .csv, .html)
  C:\TaurisIT\Export\LogParser\install.log             (audit log)

  Scheduled task: \TaurisIT\TaurisIT_IntuneLogParser
    - Spusta sa kazdy den o 07:00 ako SYSTEM
    - Argumenty: -Severity Error -Output All
                 -AppMappingFile ...\intune-apps.csv
                 -OutputPath C:\TaurisIT\Export\LogParser
    - ExecutionTimeLimit: 30 min

ZABALENIE DO .INTUNEWIN
--------------------------------------------------------------------------
  1. Stiahni Microsoft Win32 Content Prep Tool:
       https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

  2. Vsetky 4 subory (Parse-IntuneLogs.ps1, intune-apps.csv,
     Install.ps1, Uninstall.ps1) daj do jednej zlozky, napr.:
       C:\Temp\IntuneLogParser\

  3. Spusti IntuneWinAppUtil.exe:
       IntuneWinAppUtil.exe -c C:\Temp\IntuneLogParser ^
                            -s Install.ps1 ^
                            -o C:\Temp\Output

  4. Vysledok: C:\Temp\Output\Install.intunewin

KONFIGURACIA V INTUNE PORTALI
--------------------------------------------------------------------------
  Apps > Windows > Add > Windows app (Win32)
  Nahraj Install.intunewin

  App information:
    Name:       TaurisIT Intune Log Parser
    Publisher:  TAURIS IT
    Category:   Computer management

  Program:
    Install command:
      powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1
    Uninstall command:
      powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1
    Install behavior: System
    Device restart behavior: No specific action

  Requirements:
    Operating system architecture: x64
    Minimum OS: Windows 10 1809 (alebo vyssia)

  Detection rules:
    Rules format: Use a custom detection script
    Script file:  Detect.ps1
    Run script as 32-bit: No
    Enforce script signature check: No

  Assignments:
    Required -> skupiny zariadeni ktore maju byt monitorovane

DEBUG/KONTROLA NA ZARIADENI
--------------------------------------------------------------------------
  # overit ci bezi task a kedy naposledy
  Get-ScheduledTask -TaskName TaurisIT_IntuneLogParser -TaskPath \TaurisIT\ |
      Get-ScheduledTaskInfo

  # manualne spustit task
  Start-ScheduledTask -TaskName TaurisIT_IntuneLogParser -TaskPath \TaurisIT\

  # pozriet najnovsi log
  Get-ChildItem C:\TaurisIT\Export\LogParser\error-log-*.log |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
      Get-Content | Select-Object -First 80

  # audit log instalacie
  Get-Content C:\TaurisIT\Export\LogParser\install.log -Tail 40

  # Intune Management Extension log (vystup Install.ps1 z Intune)
  Get-Content C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log -Tail 100

UPDATE NA NOVU VERZIU PARSERA
--------------------------------------------------------------------------
  Aktualizuj Parse-IntuneLogs.ps1 v balicku, znova vytvor .intunewin,
  vo Intune "Replace" existujuci package. Install.ps1 existujuci task
  odregistruje a znova zaregistruje (Register-ScheduledTask s Unregister
  pred tym).