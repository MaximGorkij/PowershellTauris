<#
.SYNOPSIS
    Kompletny LogHelper modul pre Intune remediation skripty
.DESCRIPTION
    Modul zabezpecuje komplexne logovanie do suborov, Event Logu a spravu logov.
    Obsahuje vsetky funkcie potrebne pre remediation skripty.
.AUTHOR
    Marek Findrik / TaurisIT
.CREATED
    2025-09-05
.VERSION
    2.2.0 - Opravena chyba SourceExists pri nedostatocnych pravach (Security, State log)
          - Opravena neprehladna logika switch v Send-IntuneAlert (oddelene EventId a EventType)
          - Opravena konvencia parametra LogFileName - vzdy relativna cesta voci LogDirectory
          - Join-Path spravanie s absolutnou cestou je teraz explicitne osetre
.NOTES
    - Logy sa ukladaju do: C:\TaurisIT\Log
    - Event Log pouziva nazov: "IntuneScript"
    - Automaticke cistenie starych logov (>30 dni)
    - Spatne kompatibilny s existujucimi skriptami
    - LogFileName MUSI byt relativna cesta (napr. "TaskName\TaskName.log"),
      NIE absolutna cesta. Write-CustomLog ju spoji s LogDirectory.
#>

# Globalne premenne modulu
$script:LogDirectory = "C:\TaurisIT\Log"
$script:EventLogName = "IntuneScript"
$script:RetentionDays = 30

#region Core Logging Functions

function Write-CustomLog {
    <#
    .SYNOPSIS
        Zakladna funkcia pre logovanie do suboru a Event Logu
    .NOTES
        LogFileName musi byt relativna cesta voci C:\TaurisIT\Log
        Priklad: "AppInstallation\Install_HOSTNAME.log"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$EventSource,

        [string]$EventLogName = "IntuneScript",

        [Parameter(Mandatory = $true)]
        [string]$LogFileName,

        [ValidateSet("Information", "Warning", "Error")]
        [string]$Type = "Information"
    )

    # Pouzij globalny adresar, ak je nastaveny
    $LogDirectory = if ($script:LogDirectory) { $script:LogDirectory } else { "C:\TaurisIT\Log" }

    # Vytvor adresar, ak neexistuje
    if (-not (Test-Path $LogDirectory)) {
        try {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Warning "Cannot create log directory: $_"
            return
        }
    }

    # Cesta k log suboru - LogFileName musi byt relativna cesta
    # Ak by niekto omylom poslal absolutnu cestu, pouzijeme ju priamo
    if ([System.IO.Path]::IsPathRooted($LogFileName)) {
        $LogFilePath = $LogFileName
        Write-Warning "Write-CustomLog: LogFileName je absolutna cesta ('$LogFileName'). Pouzivaj relativnu cestu voci LogDirectory."
    }
    else {
        $LogFilePath = Join-Path $LogDirectory $LogFileName
    }

    # Vytvor podadresar log suboru ak neexistuje
    $LogFileDir = Split-Path $LogFilePath -Parent
    if (-not (Test-Path $LogFileDir)) {
        try {
            New-Item -Path $LogFileDir -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Warning "Cannot create log subdirectory: $_"
            return
        }
    }

    # Casova peciatka
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Zapis do suboru
    try {
        "$Timestamp [$Type] $Message" | Out-File -FilePath $LogFilePath -Append -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Cannot write to log file: $_"
    }

    # FIX: SourceExists obaleny try/catch - chyba pri nedostupnych logoch (Security, State)
    $SourceExists = $false
    try { $SourceExists = [System.Diagnostics.EventLog]::SourceExists($EventSource) } catch {}

    if (-not $SourceExists) {
        try {
            New-EventLog -LogName $EventLogName -Source $EventSource -ErrorAction Stop
        }
        catch {
            "$Timestamp [WARNING] Cannot create Event Source '$EventSource': $_" |
            Out-File -FilePath $LogFilePath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }

    # Dynamicke EventId podla typu
    $EventId = switch ($Type) {
        "Information" { 1000 }
        "Warning" { 2000 }
        "Error" { 3000 }
        default { 9999 }
    }

    # Zapis do Event Logu
    try {
        Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType $Type -EventId $EventId -Message $Message -ErrorAction Stop
    }
    catch {
        "$Timestamp [WARNING] Cannot write to Event Log: $_" |
        Out-File -FilePath $LogFilePath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Write-IntuneLog {
    <#
    .SYNOPSIS
        Hlavna funkcia pre logovanie v Intune skriptoch (spatne kompatibilna)
    .DESCRIPTION
        Podporuje rozne urovne logovania (INFO, WARN, ERROR, SUCCESS, DEBUG)
        a automaticky mapuje na spravne typy Event Logu
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogFile = "IntuneScripts.log",

        [string]$EventSource = "IntuneScripts"
    )

    # Mapovanie urovni na Event Log typy
    $Type = switch ($Level) {
        'INFO' { 'Information' }
        'WARN' { 'Warning' }
        'ERROR' { 'Error' }
        'SUCCESS' { 'Information' }
        'DEBUG' { 'Information' }
        default { 'Information' }
    }

    $FormattedMessage = "[$Level] $Message"

    Write-CustomLog -Message $FormattedMessage -EventSource $EventSource -LogFileName $LogFile -Type $Type
}

#endregion

#region Log Management Functions

function Initialize-LogSystem {
    <#
    .SYNOPSIS
        Inicializuje logovy system - vytvara adresare a nastavuje konfiguraciu
    .DESCRIPTION
        Tato funkcia sa vola na zaciatku kazdeho remediation skriptu.
        Vytvara potrebne adresare a overuje zapisove opravnenia.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [string]$EventSource,

        [string]$EventLogName = "IntuneScript",

        [int]$RetentionDays = 30
    )

    try {
        # Nastav globalne premenne modulu
        $script:LogDirectory = $LogDirectory
        $script:EventLogName = $EventLogName
        $script:RetentionDays = $RetentionDays

        # Vytvor log adresar, ak neexistuje
        if (-not (Test-Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created log directory: $LogDirectory"
        }

        # Otestuj zapisove opravnenia
        $TestFile = Join-Path $LogDirectory "init_test_$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
        try {
            "Test" | Out-File -FilePath $TestFile -ErrorAction Stop
            Remove-Item $TestFile -Force -ErrorAction SilentlyContinue
        }
        catch {
            throw "No write permissions to log directory: $_"
        }

        # FIX: SourceExists obaleny try/catch - chyba pri nedostupnych logoch (Security, State)
        $SourceExists = $false
        try { $SourceExists = [System.Diagnostics.EventLog]::SourceExists($EventSource) } catch {}

        if (-not $SourceExists) {
            try {
                New-EventLog -LogName $EventLogName -Source $EventSource -ErrorAction Stop
                Write-Verbose "Created Event Source: $EventSource"
            }
            catch {
                Write-Warning "Could not create Event Source: $_"
                # Pokracujeme aj bez Event Logu
            }
        }

        Write-IntuneLog -Message "Log system initialized - Directory: $LogDirectory, Source: $EventSource" `
            -Level INFO -EventSource $EventSource -LogFile "system.log"

        return $true
    }
    catch {
        Write-Error "Failed to initialize log system: $_"
        return $false
    }
}

function Clear-OldLogs {
    <#
    .SYNOPSIS
        Cisti stare log subory na zaklade retention politiky
    .DESCRIPTION
        Odstrani vsetky .log a .txt subory starsie ako zadany pocet dni.
    #>
    [CmdletBinding()]
    param(
        [int]$RetentionDays = 30,
        [string]$LogDirectory
    )

    try {
        if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
            $LogDirectory = $script:LogDirectory
            if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
                $LogDirectory = "C:\TaurisIT\Log"
            }
        }

        if (-not (Test-Path $LogDirectory)) {
            Write-Verbose "Log directory does not exist: $LogDirectory"
            return
        }

        $CutoffDate = (Get-Date).AddDays(-$RetentionDays)

        $OldFiles = Get-ChildItem -Path $LogDirectory -Include "*.log", "*.txt" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $CutoffDate }

        if ($OldFiles) {
            $RemovedCount = 0
            $TotalSize = 0

            foreach ($File in $OldFiles) {
                try {
                    $Size = $File.Length
                    Remove-Item -Path $File.FullName -Force -ErrorAction Stop
                    $RemovedCount++
                    $TotalSize += $Size
                    Write-Verbose "Removed old log: $($File.Name) ($('{0:N2}' -f ($Size/1KB)) KB)"
                }
                catch {
                    Write-Warning "Could not remove $($File.Name): $_"
                }
            }

            $CleanMsg = "Cleaned $RemovedCount old log files ($('{0:N2}' -f ($TotalSize/1MB)) MB) older than $RetentionDays days"
            Write-Verbose $CleanMsg
            Write-IntuneLog -Message $CleanMsg -Level INFO -EventSource "LogMaintenance" -LogFile "maintenance.log"
        }
        else {
            Write-Verbose "No old log files found to clean"
        }
    }
    catch {
        Write-Warning "Error during log cleanup: $_"
    }
}

#endregion

#region Alert Functions

function Send-IntuneAlert {
    <#
    .SYNOPSIS
        Posiela alerty pre kriticke udalosti
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Information', 'Warning', 'Error', 'Critical')]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [string]$EventSource,

        [string]$LogFile = "alerts.log"
    )

    try {
        # FIX: EventId a EventType su teraz explicitne oddelene - predchadzajuca
        # implementacia pouzivala switch s vedlajsimi efektmi, co bolo neprehladne
        $EventId = switch ($Severity) {
            'Information' { 5000 }
            'Warning' { 5001 }
            'Error' { 5002 }
            'Critical' { 5003 }
            default { 5999 }
        }

        $EventType = switch ($Severity) {
            'Information' { 'Information' }
            'Warning' { 'Warning' }
            'Error' { 'Error' }
            'Critical' { 'Error' }
            default { 'Warning' }
        }

        $Level = switch ($Severity) {
            'Information' { 'INFO' }
            'Warning' { 'WARN' }
            'Error' { 'ERROR' }
            'Critical' { 'ERROR' }
            default { 'WARN' }
        }

        $AlertMessage = "[ALERT - $Severity] $Message"

        Write-IntuneLog -Message $AlertMessage -Level $Level -EventSource $EventSource -LogFile $LogFile

        # FIX: SourceExists obaleny try/catch
        $SourceExists = $false
        try { $SourceExists = [System.Diagnostics.EventLog]::SourceExists($EventSource) } catch {}

        if ($SourceExists) {
            Write-EventLog -LogName $script:EventLogName -Source $EventSource `
                -EntryType $EventType -EventId $EventId -Message $AlertMessage -ErrorAction SilentlyContinue
        }

        Write-Verbose "Alert sent: [$Severity] $Message"
    }
    catch {
        Write-Warning "Failed to send alert: $_"
    }
}

#endregion

#region Utility Functions

function Get-LogFiles {
    <#
    .SYNOPSIS
        Vrati zoznam vsetkych log suborov v log adresari
    #>
    [CmdletBinding()]
    param(
        [string]$LogDirectory,
        [string]$Filter = "*.log"
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = $script:LogDirectory
        if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
            $LogDirectory = "C:\TaurisIT\Log"
        }
    }

    if (Test-Path $LogDirectory) {
        Get-ChildItem -Path $LogDirectory -Filter $Filter -Recurse -File |
        Select-Object Name, Length, LastWriteTime, FullName
    }
}

function Get-LogStatistics {
    <#
    .SYNOPSIS
        Vrati statistiky o log suboroch
    #>
    [CmdletBinding()]
    param([string]$LogDirectory)

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = $script:LogDirectory
        if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
            $LogDirectory = "C:\TaurisIT\Log"
        }
    }

    if (-not (Test-Path $LogDirectory)) { return $null }

    $Files = Get-ChildItem -Path $LogDirectory -Include "*.log", "*.txt" -Recurse -File

    [PSCustomObject]@{
        TotalFiles   = $Files.Count
        TotalSizeMB  = [math]::Round(($Files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
        OldestLog    = ($Files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
        NewestLog    = ($Files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        LogDirectory = $LogDirectory
    }
}

#endregion

# Export vsetkych funkcii
Export-ModuleMember -Function @(
    'Write-CustomLog',
    'Write-IntuneLog',
    'Initialize-LogSystem',
    'Clear-OldLogs',
    'Send-IntuneAlert',
    'Get-LogFiles',
    'Get-LogStatistics'
)