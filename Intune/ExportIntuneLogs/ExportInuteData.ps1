<#
.SYNOPSIS
  Export dat z Intune Data Warehouse do JSON a Graylog formatu - OPRAVENA VERZIA
.DESCRIPTION
  Plna verzia s paginaciou, retry logikou, internym paralelizmom pre spracovanie poloziek,
  automatickym backupom starych JSON suborov a ich komprimaciou.
  Graylog export ostava volitelny; ak je vypnuty, export sa stale povazuje za uspesny.
  Vyžaduje PowerShell 7+ (ForEach-Object -Parallel).
.AUTHOR
  Marek Findrik (upraveny + opraveny)
.VERSION
  2.2.0
#>

param(
    [ValidateScript({ Test-Path $_ -PathType Container -IsValid })]
    [string]$ExportPath = "C:\TaurisIT\log\Intune",
    
    [ValidateScript({ Test-Path $_ -PathType Container -IsValid })]
    [string]$BackupRoot = "C:\TaurisIT\Backup\Intune",
    
    [ValidateScript({ Test-Path $_ -PathType Container -IsValid })]
    [string]$ScriptsPath = "C:\TaurisIT\skripty\IntuneExport",
    
    [ValidateSet("beta", "v1.0")]
    [string]$ApiVersion = "beta",
    
    [bool]$GraylogOutput = $true,
    [string]$GraylogLogFile = "graylog_output.log",
    
    [ValidateRange(1, 20)]
    [int]$JsonDepth = 10,
    
    [bool]$SimplifyJson = $true,
    
    [ValidateRange(1, 100)]
    [int]$MaxFileSizeMB = 10,
    
    [ValidateRange(1, 365)]
    [int]$KeepFilesDays = 7,
    
    [bool]$CompressOldFiles = $true,
    
    [ValidateRange(1, 1000)]
    [int]$BatchSize = 50,
    
    [bool]$UseBatching = $true,
    [switch]$DebugMode,
    
    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,
    
    [bool]$EnablePagination = $true,
    [switch]$SendSummaryEmail,
    [string]$EmailFrom = "",
    [string]$EmailTo = "",
    [bool]$CleanOldFiles = $true,
    [bool]$ValidateJson = $true,
    
    [ValidateRange(1, 64)]
    [int]$MaxThreads = [Math]::Min([Environment]::ProcessorCount, 16),
    
    [switch]$ForcePS7
)

# -------------------------
# Pre-flight checks
# -------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not $ForcePS7) {
        Write-Error "PowerShell 7+ is required for internal parallelism (ForEach-Object -Parallel). Current: $($PSVersionTable.PSVersion). Rerun with PS7 or set -ForcePS7 to bypass (not recommended)."
        exit 2
    }
    else {
        Write-Warning "Running on PowerShell <7 with -ForcePS7. Parallel features may fail."
    }
}

# Normalize and validate paths
try {
    $ExportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExportPath)
    $BackupRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupRoot)
    $ScriptsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ScriptsPath)
}
catch {
    Write-Error "Chyba pri normalizacii ciest: $($_.Exception.Message)"
    exit 1
}

# Ensure reasonable MaxThreads
$MaxThreads = [Math]::Max(1, [Math]::Min($MaxThreads, 32))

# Script-wide script-scope vars
$script:MaxRetries = $MaxRetries
$script:JsonDepth = $JsonDepth
$script:ExportPath = $ExportPath
$script:MaxThreads = $MaxThreads
$script:GraylogMutex = $null

# -------------------------
# Logging
# -------------------------
$script:LogFilePath = Join-Path $ExportPath "IntuneExport_$(Get-Date -Format 'yyyyMMdd').log"
$script:LogMutex = New-Object System.Threading.Mutex($false, "IntuneExportLogMutex")

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $line = "[$Level] [T:$threadId] $Message"
    $out = "$timestamp $line"
    Write-Output $out

    try {
        $script:LogMutex.WaitOne() | Out-Null
        try {
            $out | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8 -ErrorAction Stop
        }
        finally {
            $script:LogMutex.ReleaseMutex()
        }
    }
    catch {
        Write-Output "CRITICAL: Unable to write to log file: $($_.Exception.Message)"
    }
}

function Write-DebugLog { 
    param([string]$Message) 
    if ($DebugMode) { Write-Log $Message "DEBUG" } 
}

function Initialize-Logging {
    try {
        if (-not (Test-Path $ExportPath)) {
            New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
        }
        if (-not (Test-Path $ScriptsPath)) {
            New-Item -ItemType Directory -Path $ScriptsPath -Force | Out-Null
        }

        $header = @"
=== Intune Export Script Started ===
Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer: $env:COMPUTERNAME
User: $env:USERNAME
Version: 2.2.0 (Fixed + Optimized)
PowerShell: $($PSVersionTable.PSVersion)
Max Threads: $MaxThreads
"@
        $header | Out-File -FilePath $script:LogFilePath -Encoding UTF8 -ErrorAction Stop

        Write-Output "Logovanie inicializovane: $script:LogFilePath"
        return $true
    }
    catch {
        Write-Output "CRITICAL: Cannot initialize logging: $($_.Exception.Message)"
        return $false
    }
}

# -------------------------
# Backup old JSON files
# -------------------------
function Backup-OldJsons {
    param(
        [string]$SourceDir,
        [string]$BackupRootDir
    )

    try {
        if (-not (Test-Path $SourceDir)) {
            Write-DebugLog "Backup skip: SourceDir does not exist: $SourceDir"
            return $null
        }

        $jsonFiles = Get-ChildItem -Path $SourceDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
            Write-DebugLog "No JSON files to backup in $SourceDir"
            return $null
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupDir = Join-Path $BackupRootDir $timestamp

        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        foreach ($f in $jsonFiles) {
            $dest = Join-Path $backupDir ($f.Name)
            Move-Item -Path $f.FullName -Destination $dest -Force -ErrorAction Stop
        }

        Write-Log "Presunute $($jsonFiles.Count) JSON suborov do backup adresara: $backupDir" "SUCCESS"
        return $backupDir
    }
    catch {
        Write-Log "Chyba pri backupovani JSON suborov: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Compress-BackupFolder {
    param([string]$FolderPath)
    try {
        if (-not (Test-Path $FolderPath)) { return $null }
        $zipTarget = "$FolderPath.zip"
        if (Test-Path $zipTarget) { Remove-Item $zipTarget -Force -ErrorAction SilentlyContinue }
        Compress-Archive -Path $FolderPath -DestinationPath $zipTarget -CompressionLevel Optimal -ErrorAction Stop
        Write-Log "Backup adresar skomprimovany: $zipTarget" "SUCCESS"
        if ($CompressOldFiles) {
            Remove-Item -Path $FolderPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $zipTarget
    }
    catch {
        Write-Log "Nepodarilo sa skomprimovat backup: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# -------------------------
# File rotation & cleanup
# -------------------------
function Invoke-FileRotationIfTooLarge {
    param([string]$FilePath, [int]$MaxMB)
    try {
        if (-not (Test-Path $FilePath)) { return $false }
        $file = Get-Item $FilePath
        $sizeMB = [math]::Round($file.Length / 1MB, 2)
        if ($sizeMB -ge $MaxMB) {
            $ts = Get-Date -Format "yyyyMMdd_HHmmss"
            $newName = $file.BaseName + "_$ts" + $file.Extension
            $newPath = Join-Path $file.DirectoryName $newName
            Move-Item -Path $file.FullName -Destination $newPath -ErrorAction Stop
            Write-Log "Rotacia suboru: $FilePath -> $newPath" "INFO"
            if ($CompressOldFiles) {
                try {
                    Compress-Archive -Path $newPath -DestinationPath "$newPath.zip" -CompressionLevel Optimal
                    Remove-Item -Path $newPath -Force -ErrorAction SilentlyContinue
                    Write-Log "Komprimovany rotovany subor: $newPath.zip" "SUCCESS"
                }
                catch {
                    Write-Log "Nepodarilo sa komprimovat rotovany subor: $($_.Exception.Message)" "WARN"
                }
            }
            return $true
        }
        return $false
    }
    catch {
        Write-Log "Chyba pri rotate: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# -------------------------
# Graylog helper
# -------------------------
function Write-GraylogBatch {
    param(
        [array]$BatchData,
        [string]$DataType,
        [string]$Level = "6"
    )

    if (-not $GraylogOutput -or -not $BatchData -or $BatchData.Count -eq 0) {
        Write-DebugLog "Graylog disabled or empty batch for $DataType"
        return 0
    }

    $graylogFile = Join-Path $ExportPath $GraylogLogFile
    $messageCount = 0

    try {
        Invoke-FileRotationIfTooLarge -FilePath $graylogFile -MaxMB $MaxFileSizeMB
        Write-DebugLog "Zapisujem Graylog batch ($($BatchData.Count)) pre $DataType"

        # Use mutex for thread-safe file writing
        $script:GraylogMutex.WaitOne() | Out-Null
        try {
            foreach ($item in $BatchData) {
                try {
                    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $messageText = $item | ConvertTo-Json -Depth $script:JsonDepth -Compress -ErrorAction Stop

                    $graylogMessage = @{
                        timestamp = $timestamp
                        message   = $messageText
                        log_type  = "intune"
                        data_type = $DataType
                        source    = "intune_graph_api"
                        host      = $env:COMPUTERNAME
                        level     = $Level
                    }

                    $graylogOutput = $graylogMessage | ConvertTo-Json -Depth 5 -Compress -ErrorAction Stop
                    $graylogOutput | Out-File -FilePath $graylogFile -Append -Encoding UTF8 -ErrorAction Stop
                    $messageCount++
                }
                catch {
                    Write-Log "Chyba pri zapise Graylog spravy pre $DataType : $($_.Exception.Message)" "WARN"
                    try {
                        $simpleMessage = @{
                            timestamp = $timestamp
                            message   = "Simplified: $($item.id) - $($item.displayName)"
                            log_type  = "intune"
                            data_type = $DataType
                            source    = "intune_graph_api"
                            host      = $env:COMPUTERNAME
                            level     = $Level
                        }
                        ($simpleMessage | ConvertTo-Json -Compress) | Out-File -FilePath $graylogFile -Append -Encoding UTF8
                        $messageCount++
                    }
                    catch {
                        Write-Log "Fallback Graylog zapis aj zlyhal: $($_.Exception.Message)" "ERROR"
                    }
                }
            }
        }
        finally {
            $script:GraylogMutex.ReleaseMutex()
        }

        Write-DebugLog "Uspesne zapisanych $messageCount/$($BatchData.Count) sprav pre $DataType"
    }
    catch {
        Write-Log "Chyba pri Graylog batch: $($_.Exception.Message)" "ERROR"
    }

    return $messageCount
}

function Test-GraylogFile {
    param([string]$FilePath)
    try {
        $testMessage = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            message   = "Test message"
            log_type  = "test"
            source    = "intune_graph_api"
            host      = $env:COMPUTERNAME
            level     = 6
        }
        $testOutput = $testMessage | ConvertTo-Json -Depth $script:JsonDepth -Compress
        $testOutput | Out-File -FilePath $FilePath -Append -Encoding UTF8 -ErrorAction Stop
        Write-DebugLog "Graylog file test uspesny: $FilePath"
        return $true
    }
    catch {
        Write-Log "Graylog file test FAILED: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------
# Graph API helpers
# -------------------------
function Invoke-GraphWithRetry {
    param(
        [string]$Uri,
        [int]$MaxRetries = $script:MaxRetries
    )

    $retryCount = 0
    $lastError = $null

    do {
        try {
            Write-DebugLog "API volanie: $Uri (pokus $($retryCount + 1)/$MaxRetries)"
            $result = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
            return $result
        }
        catch {
            $lastError = $_
            $retryCount++
            if ($retryCount -ge $MaxRetries) {
                Write-Log "API volanie zlyhalo po $MaxRetries pokusoch: $Uri" "ERROR"
                throw $lastError
            }
            $msg = $_.Exception.Message
            if ($msg -match "429" -or $msg -match "throttl") {
                $waitTime = [math]::Pow(2, $retryCount) * 5
                Write-Log "API throttling detekovany, cakam $waitTime sekund..." "WARN"
            }
            else {
                $waitTime = [math]::Pow(2, $retryCount)
                Write-Log "API chyba, retry $retryCount/$MaxRetries po $waitTime sekundach..." "WARN"
            }
            Start-Sleep -Seconds $waitTime
        }
    } while ($retryCount -lt $MaxRetries)

    throw $lastError
}

function Get-GraphDataWithPagination {
    param(
        [string]$Uri
    )

    $allData = [System.Collections.Generic.List[object]]::new()
    $pageCount = 0
    $currentUri = $Uri

    try {
        do {
            $pageCount++
            Write-DebugLog "Nacitavam stranku $pageCount z API..."
            $response = Invoke-GraphWithRetry -Uri $currentUri

            if ($null -ne $response -and $response.value) {
                $allData.AddRange($response.value)
                Write-DebugLog "Stranka $pageCount pridaná: $($response.value.Count) zaznamov (Celkovo: $($allData.Count))"
            }

            $next = $null
            if ($response -and $response.PSObject.Properties.Name -contains '@odata.nextLink') {
                $next = $response.'@odata.nextLink'
            }
            $currentUri = $next

            if ($currentUri -and -not $EnablePagination) {
                Write-Log "Pagination detekovana ale je vypnuta, koncim po prvej stranke" "WARN"
                break
            }
        } while ($currentUri)
    }
    catch {
        Write-Log "Chyba pri paginacii: $($_.Exception.Message)" "ERROR"
    }

    Write-DebugLog "Celkovo nacitanych stranok: $pageCount, zaznamov: $($allData.Count)"
    return $allData.ToArray()
}

function Remove-OldFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Days
    )

    try {
        if (-not (Test-Path $Path)) {
            Write-Log "Adresar $Path neexistuje, preskakujem cistenie." "WARN"
            return
        }

        $limit = (Get-Date).AddDays(-$Days)
        $files = Get-ChildItem -Path $Path -Recurse -File | Where-Object { $_.LastWriteTime -lt $limit }

        foreach ($file in $files) {
            try {
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                Write-Log "Odstranen stary subor: $($file.FullName)" "INFO"
            }
            catch {
                Write-Log "Nepodarilo sa odstranit subor: $($file.FullName) - $($_.Exception.Message)" "WARN"
            }
        }

        if ($files.Count -eq 0) {
            Write-Log "Ziadne subory starsie ako $Days dni neboli najdene v $Path" "INFO"
        }
        else {
            Write-Log "Dokoncene cistenie starych suborov v $Path ($($files.Count) poloziek odstranenych)" "INFO"
        }
    }
    catch {
        Write-Log "Chyba v Remove-OldFiles: $($_.Exception.Message)" "ERROR"
    }
}

# -------------------------
# Export function with internal parallelism - FIXED
# -------------------------
function Export-IntuneData {
    param(
        [string]$Resource,
        [string]$FileName,
        [string]$Filter = "",
        [array]$SelectFields = @(),
        [string]$TargetDirectory
    )

    $success = $false
    $recordCount = 0
    $graylogCount = 0

    try {
        Write-Log "Exportujem $Resource..." "INFO"

        # Ensure target dir exists
        if (-not (Test-Path $TargetDirectory)) {
            try {
                New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
                Write-DebugLog "Vytvoreny targetDir: $TargetDirectory"
            }
            catch {
                Write-Log "Nepodarilo sa vytvorit target dir $TargetDirectory : $($_.Exception.Message)" "ERROR"
                return @{ Success = $false; RecordCount = 0; GraylogCount = 0 }
            }
        }

        # Construct URL
        $url = "https://graph.microsoft.com/$ApiVersion/deviceManagement/$Resource"
        $queryParams = @()
        if ($Filter) { $queryParams += "`$filter=$Filter" }
        if ($SelectFields.Count -gt 0) { $queryParams += "`$select=" + ($SelectFields -join ",") }
        if ($queryParams.Count -gt 0) { $url += "?" + ($queryParams -join "&") }

        Write-DebugLog "API URL: $url"

        # Get data (pages)
        $data = Get-GraphDataWithPagination -Uri $url
        if ($null -eq $data) { $data = @() }

        $recordCount = $data.Count
        Write-DebugLog "Ziskanych $recordCount zaznamov z API pre $Resource"

        $success = $true

        if ($data -and $data.Count -gt 0) {

            # FIXED: Internal parallelism with proper error handling
            Write-DebugLog "Spustam paralelne spracovanie $($data.Count) poloziek (MaxThreads=$script:MaxThreads)"

            $simpleData = $data | ForEach-Object -ThrottleLimit $script:MaxThreads -Parallel {
                $item = $_
                $ResourceParam = $using:Resource
                $Depth = $using:script:JsonDepth

                $ErrorActionPreference = 'Stop'
                try {
                    $simple = [ordered]@{
                        id           = $item.id
                        displayName  = $item.displayName
                        lastModified = $item.lastModifiedDateTime
                        created      = $item.createdDateTime
                    }

                    switch ($ResourceParam) {
                        "managedDevices" {
                            $simple.deviceName = $item.deviceName
                            $simple.operatingSystem = $item.operatingSystem
                            $simple.osVersion = $item.osVersion
                            $simple.complianceState = $item.complianceState
                            $simple.enrolledDateTime = $item.enrolledDateTime
                            $simple.lastSyncDateTime = $item.lastSyncDateTime
                            $simple.managementAgent = $item.managementAgent
                            $simple.userPrincipalName = $item.userPrincipalName
                        }
                        "mobileApps" {
                            $simple.publisher = $item.publisher
                            $simple.appType = $item.'@odata.type'
                            $simple.isAssigned = $item.isAssigned
                        }
                        "deviceCompliancePolicies" {
                            $simple.policyType = $item.'@odata.type'
                            $simple.version = $item.version
                        }
                        "deviceConfigurations" {
                            $simple.configurationType = $item.'@odata.type'
                            $simple.version = $item.version
                        }
                        "managedAppPolicies" {
                            $simple.policyType = $item.'@odata.type'
                            $simple.version = $item.version
                        }
                        "deviceEnrollmentConfigurations" {
                            $simple.configurationType = $item.'@odata.type'
                            $simple.version = $item.version
                        }

                        [PSCustomObject]@ { 
                            Success = $true
                            Data = $simple 
                        }
                    }
                    catch {
                        [PSCustomObject]@{ 
                            Success = $false
                            Error   = "ID: $($item.id) - $($_.Exception.Message)"
                            Data    = $null
                        }
                    }
                }

                # Filter successful results
                $successfulResults = $simpleData | Where-Object { $_.Success }
                $failedResults = $simpleData | Where-Object { -not $_.Success }

                if ($failedResults) {
                    Write-Log "Niekoľko poloziek zlyhalo pri paralelnom spracovani ($($failedResults.Count)/$($data.Count))" "WARN"
                    foreach ($failed in $failedResults | Select-Object -First 5) {
                        Write-DebugLog "Failed item: $($failed.Error)"
                    }
                }

                $processedData = $successfulResults | ForEach-Object { $_.Data }

                # JSON export
                try {
                    $jsonFile = Join-Path $TargetDirectory "$FileName.json"
                    $jsonString = $processedData | ConvertTo-Json -Depth $script:JsonDepth -ErrorAction Stop

                    if ($ValidateJson) {
                        try {
                            $null = $jsonString | ConvertFrom-Json
                            Write-DebugLog "JSON validacia uspesna pre $FileName"
                        }
                        catch {
                            Write-Log "JSON validacia zlyhala pre $FileName, ale pokracujem v zapise: $($_.Exception.Message)" "WARN"
                        }
                    }

                    $jsonString | Out-File -FilePath $jsonFile -Encoding UTF8 -ErrorAction Stop
                    Write-DebugLog "JSON export uspesny: $jsonFile"
                }
                catch {
                    Write-Log "Chyba pri JSON exporte $FileName : $($_.Exception.Message)" "WARN"
                    try {
                        $jsonString = $processedData | ConvertTo-Json -Depth 3 -Compress
                        $jsonString | Out-File -FilePath (Join-Path $TargetDirectory "$FileName.json") -Encoding UTF8 -ErrorAction Stop
                        Write-Log "Fallback JSON export uspesny pre $FileName" "SUCCESS"
                    }
                    catch {
                        Write-Log "Fallback JSON export tiez zlyhal: $($_.Exception.Message)" "ERROR"
                        $success = $false
                    }
                }

                # CSV export
                try {
                    $csvFile = Join-Path $TargetDirectory "$FileName.csv"
                    $processedData | ForEach-Object { [PSCustomObject]$_ } | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                    Write-DebugLog "CSV export uspesny: $csvFile"
                }
                catch {
                    Write-Log "Chyba pri CSV exporte $FileName : $($_.Exception.Message)" "WARN"
                }

                # Graylog export (sequential to avoid file contention)
                if ($GraylogOutput) {
                    Write-DebugLog "Zaciatok Graylog exportu pre $FileName"

                    $batches = @()
                    if ($UseBatching) {
                        $current = @()
                        foreach ($i in $processedData) {
                            $current += $i
                            if ($current.Count -ge $BatchSize) {
                                $batches += , @($current)
                                $current = @()
                            }
                        }
                        if ($current.Count -gt 0) { $batches += , @($current) }
                    }
                    else {
                        foreach ($i in $processedData) { $batches += , @($i) }
                    }

                    foreach ($batch in $batches) {
                        $graylogCount += Write-GraylogBatch -BatchData $batch -DataType $FileName.ToLower()
                    }

                    Write-DebugLog "Graylog export dokonceny: $graylogCount sprav"
                }

                Write-Log "Udaje $FileName exportovane ($recordCount zaznamov, $graylogCount Graylog sprav)" "SUCCESS"
            }
            else {
                Write-Log "Ziadne udaje pre $FileName" "WARN"
                try {
                    $jsonFile = Join-Path $TargetDirectory "$FileName.json"
                    "[]" | Out-File -FilePath $jsonFile -Encoding UTF8 -ErrorAction Stop
                    $csvFile = Join-Path $TargetDirectory "$FileName.csv"
                    "" | Out-File -FilePath $csvFile -Encoding UTF8 -ErrorAction Stop
                    Write-DebugLog "Prazdne subory vytvorene pre $FileName"
                }
                catch {
                    Write-Log "Chyba pri vytvarani prazdnych suborov pre $FileName $($_.Exception.Message)" "WARN"
                }
            }
        }
        catch {
            Write-Log "Chyba pri exporte $FileName : $($_.Exception.Message)" "ERROR"
            Write-DebugLog "Detail chyby: $($_.Exception | Format-List * -Force | Out-String)"
            $success = $false
        }

        Write-DebugLog "Export $FileName - Success: $success, Records: $recordCount, Graylog: $graylogCount"

        return @{
            Success      = $success
            RecordCount  = $recordCount
            GraylogCount = $graylogCount
        }
    }

    # -------------------------
    # MS Graph email
    # -------------------------
    function Send-GraphEmail {
        param([array]$Results, [timespan]$Duration)

        if (-not $SendSummaryEmail -or -not $EmailFrom -or -not $EmailTo) {
            Write-DebugLog "Email notifikacia vypnuta alebo chybaju povinne parametre"
            return
        }

        try {
            $successCount = ($Results | Where-Object { $_.Success }).Count
            $totalCount = $Results.Count
            $totalRecords = ($Results | Measure-Object -Property RecordCount -Sum).Sum
            $totalGraylog = ($Results | Measure-Object -Property GraylogCount -Sum).Sum

            $subject = "Intune Export Summary - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

            $htmlBody = @"
<html><body>
<h2>📊 Intune Data Export Summary</h2>
<p><strong>Overall Status:</strong> $successCount/$totalCount exports successful</p>
<p><strong>Total Records:</strong> $totalRecords</p>
<p><strong>Total Graylog Messages:</strong> $totalGraylog</p>
<p><strong>Duration:</strong> $($Duration.ToString('hh\:mm\:ss'))</p>
<p><strong>Timestamp:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
<p><strong>Host:</strong> $env:COMPUTERNAME</p>
<hr>
<table border='1' cellpadding='4' style='border-collapse: collapse;'>
<tr><th>Resource</th><th>Status</th><th>Records</th><th>Graylog</th></tr>
"@

            foreach ($r in $Results) {
                $statusText = if ($r.Success) { "✅ SUCCESS" } else { "❌ FAILED" }
                $htmlBody += "<tr><td>$($r.FileName)</td><td>$statusText</td><td>$($r.RecordCount)</td><td>$($r.GraylogCount)</td></tr>"
            }

            $htmlBody += "</table><p style='font-size:12px;color:gray;'>Generated by Intune Export Script v2.2.0 (Fixed)</p></body></html>"

            $emailMessage = @{
                message = @{
                    subject      = $subject
                    body         = @{
                        contentType = "HTML"
                        content     = $htmlBody
                    }
                    toRecipients = @(
                        @{
                            emailAddress = @{ address = $EmailTo }
                        }
                    )
                }
            }

            $emailJson = $emailMessage | ConvertTo-Json -Depth 5

            Write-Log "Odosielam email summary cez MS Graph..." "INFO"
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$EmailFrom/sendMail" -Body $emailJson -ErrorAction Stop
            Write-Log "Email summary uspesne odoslany cez MS Graph" "SUCCESS"
        }
        catch {
            Write-Log "Chyba pri odosielani emailu cez MS Graph: $($_.Exception.Message)" "ERROR"
            Write-DebugLog "Detail chyby: $($_.Exception | Format-List * -Force | Out-String)"
        }
    }

    # -------------------------
    # Main execution
    # -------------------------
    Write-Output "=========================================="
    Write-Output "INTUNE DATA EXPORT - OPRAVENA VERZIA (v2.2.0)"
    Write-Output "=========================================="

    if (-not (Initialize-Logging)) {
        Write-Output "CRITICAL: Nepodarilo sa inicializovat logovanie. Koncim."
        exit 1
    }

    Write-Log "==========================================" "INFO"
    Write-Log "INTUNE DATA EXPORT - OPRAVENA VERZIA (v2.2.0)" "INFO"
    Write-Log "==========================================" "INFO"

    # Initialize mutexes for thread safety
    try {
        $script:GraylogMutex = New-Object System.Threading.Mutex($false, "IntuneGraylogMutex")
        Write-DebugLog "Graylog mutex inicializovany"
    }
    catch {
        Write-Log "Nepodarilo sa vytvorit Graylog mutex: $($_.Exception.Message)" "WARN"
        $GraylogOutput = $false
    }

    # Prepare directories
    $today = Get-Date -Format "yyyyMMdd"
    $targetDir = Join-Path $ExportPath $today

    try {
        if (-not (Test-Path $ExportPath)) { 
            New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
            Write-Log "Hlavny adresar vytvoreny: $ExportPath" "SUCCESS" 
        }
        if (-not (Test-Path $targetDir)) { 
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            Write-Log "Denny adresar vytvoreny: $targetDir" "SUCCESS" 
        }
        if (-not (Test-Path $BackupRoot)) { 
            New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
            Write-Log "Backup root vytvoreny: $BackupRoot" "SUCCESS" 
        }
    }
    catch {
        Write-Log "Nepodarilo sa vytvorit potrebne adresare: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    # Backup existing JSONs in today's folder (if any)
    $backupDir = Backup-OldJsons -SourceDir $targetDir -BackupRootDir $BackupRoot
    if ($backupDir) {
        $zip = Compress-BackupFolder -FolderPath $backupDir
        if ($zip) { Write-Log "Zaloha JSON suborov dokoncená: $zip" "INFO" }
    }

    # Clean old backups & logs
    if ($CleanOldFiles) {
        Write-Log "Cistenie starych suborov starsich ako $KeepFilesDays dni..." "INFO"
        Remove-OldFiles -Path $ExportPath -Days $KeepFilesDays
        Remove-OldFiles -Path $BackupRoot -Days $KeepFilesDays
    }

    # Prepare Graylog file if enabled
    if ($GraylogOutput) {
        $graylogFilePath = Join-Path $ExportPath $GraylogLogFile
        try {
            "" | Out-File -FilePath $graylogFilePath -Encoding UTF8 -ErrorAction Stop
            Write-Log "Graylog output file pripraveny: $graylogFilePath" "SUCCESS"

            if (-not (Test-GraylogFile -FilePath $graylogFilePath)) {
                Write-Log "Graylog file nie je zapisovatelny, vypinam Graylog output" "ERROR"
                $GraylogOutput = $false
            }
        }
        catch {
            Write-Log "Nepodarilo sa vytvorit Graylog output file: $($_.Exception.Message)" "ERROR"
            $GraylogOutput = $false
        }
    }

    # Connect to Graph
    try {
        Write-Log "Prihlasujem sa do MS Graph..." "INFO"

        $scopes = @(
            "DeviceManagementApps.Read.All",
            "DeviceManagementConfiguration.Read.All",
            "DeviceManagementManagedDevices.Read.All",
            "DeviceManagementRBAC.Read.All",
            "DeviceManagementServiceConfig.Read.All",
            "Reports.Read.All",
            "Mail.Send"
        )

        Connect-MgGraph -Scopes $scopes -ErrorAction Stop

        $context = Get-MgContext
        Write-Log "Uspesne prihlaseny ako: $($context.Account)" "SUCCESS"
        Write-DebugLog "Tenant ID: $($context.TenantId)"
        Write-DebugLog "Scopes: $($context.Scopes -join ', ')"

        if ($GraylogOutput) {
            Write-GraylogBatch -BatchData @(@{
                    account   = $context.Account
                    tenant_id = $context.TenantId
                    scopes    = ($context.Scopes -join ",")
                    message   = "Authentication successful"
                }) -DataType "authentication" -Level "6"
        }
    }
    catch {
        Write-Log "Chyba pri prihlasovani: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    # -------------------------
    # Execute exports
    # -------------------------
    $exportResults = @()
    $startTime = Get-Date
    Write-Log "Zacinam export dat z Intune..." "INFO"

    # Devices
    Write-Log "=== EXPORT ZARIADENI ===" "INFO"
    $devicesResult = Export-IntuneData -Resource "managedDevices" -FileName "Devices" -TargetDirectory $targetDir
    $exportResults += [PSCustomObject]@{
        Resource     = "managedDevices"
        FileName     = "Devices"
        Success      = $devicesResult.Success
        RecordCount  = $devicesResult.RecordCount
        GraylogCount = $devicesResult.GraylogCount
    }

    # Apps
    Write-Log "=== EXPORT APLIKACII ===" "INFO"
    $appsResult = Export-IntuneData -Resource "mobileApps" -FileName "MobileApps" -TargetDirectory $targetDir
    $exportResults += [PSCustomObject]@{
        Resource     = "mobileApps"
        FileName     = "MobileApps"
        Success      = $appsResult.Success
        RecordCount  = $appsResult.RecordCount
        GraylogCount = $appsResult.GraylogCount
    }

    # Compliance policies
    Write-Log "=== EXPORT COMPLIANCE POLICIES ===" "INFO"
    $complianceResult = Export-IntuneData -Resource "deviceCompliancePolicies" -FileName "CompliancePolicies" -TargetDirectory $targetDir
    $exportResults += [PSCustomObject]@{
        Resource     = "deviceCompliancePolicies"
        FileName     = "CompliancePolicies"
        Success      = $complianceResult.Success
        RecordCount  = $complianceResult.RecordCount
        GraylogCount = $complianceResult.GraylogCount
    }

    # Device configurations
    Write-Log "=== EXPORT KONFIGURACNYCH PROFILOV ===" "INFO"
    $configsResult = Export-IntuneData -Resource "deviceConfigurations" -FileName "DeviceConfigurations" -TargetDirectory $targetDir
    $exportResults += [PSCustomObject]@{
        Resource     = "deviceConfigurations"
        FileName     = "DeviceConfigurations"
        Success      = $configsResult.Success
        RecordCount  = $configsResult.RecordCount
        GraylogCount = $configsResult.GraylogCount
    }

    # App protection policies
    Write-Log "=== EXPORT APP PROTECTION POLICIES ===" "INFO"
    $appProtectionResult = Export-IntuneData -Resource "managedAppPolicies" -FileName "AppProtectionPolicies" -TargetDirectory $targetDir
    $exportResults += [PSCustomObject]@{
        Resource     = "managedAppPolicies"
        FileName     = "AppProtectionPolicies"
        Success      = $appProtectionResult.Success
        RecordCount  = $appProtectionResult.RecordCount
        GraylogCount = $appProtectionResult.GraylogCount
    }

    # Enrollment configurations
    Write-Log "=== EXPORT ENROLLMENT CONFIGURATIONS ===" "INFO"
    $enrollmentResult = Export-IntuneData -Resource "deviceEnrollmentConfigurations" -FileName "EnrollmentConfigurations" -TargetDirectory $targetDir
    $exportResults += [PSCustomObject]@{
        Resource     = "deviceEnrollmentConfigurations"
        FileName     = "EnrollmentConfigurations"
        Success      = $enrollmentResult.Success
        RecordCount  = $enrollmentResult.RecordCount
        GraylogCount = $enrollmentResult.GraylogCount
    }

    # -------------------------
    # Summary
    # -------------------------
    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Log ("=" * 70) "INFO"
    Write-Log "EXPORT DOKONCENY - VYSLEDKY" "INFO"
    Write-Log ("=" * 70) "INFO"

    $successCount = 0
    $totalCount = $exportResults.Count
    $totalRecords = ($exportResults | Measure-Object -Property RecordCount -Sum).Sum
    $totalGraylog = ($exportResults | Measure-Object -Property GraylogCount -Sum).Sum

    foreach ($result in $exportResults) {
        if ($result.Success) {
            $status = "[OK]   "
            Write-Log "$status | $($result.FileName.PadRight(30)) | $($result.RecordCount.ToString().PadLeft(5)) zaznamov | $($result.GraylogCount.ToString().PadLeft(5)) Graylog sprav" "SUCCESS"
            $successCount++
        }
        else {
            $status = "[CHYBA]"
            Write-Log "$status | $($result.FileName.PadRight(30)) | $($result.RecordCount.ToString().PadLeft(5)) zaznamov | $($result.GraylogCount.ToString().PadLeft(5)) Graylog sprav" "ERROR"
        }
    }

    Write-Log ("-" * 70) "INFO"
    Write-Log "Celkovo uspesnych: $successCount/$totalCount" "INFO"
    Write-Log "Celkovy pocet zaznamov: $totalRecords" "INFO"
    Write-Log "Celkovy pocet Graylog sprav: $totalGraylog" "INFO"
    Write-Log "Trvanie: $($duration.ToString('hh\:mm\:ss'))" "INFO"
    Write-Log "Data ulozene v: $targetDir" "INFO"

    if ($GraylogOutput) {
        $graylogFile = Join-Path $ExportPath $GraylogLogFile
        if (Test-Path $graylogFile) {
            $fileSize = [math]::Round((Get-Item $graylogFile).Length / 1KB, 2)
            Write-Log "Graylog output: $graylogFile ($fileSize KB)" "INFO"
        }
    }

    Write-Log ("=" * 70) "INFO"

    # Send email via Graph if requested
    if ($SendSummaryEmail) {
        Write-Log "Odosielam email summary cez MS Graph..." "INFO"
        Send-GraphEmail -Results $exportResults -Duration $duration
    }

    # Disconnect
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Write-Log "Odhlasene z Microsoft Graph." "INFO"
    }
    catch {
        Write-Log "Poznamka: Nepodarilo sa odhlasit z Graph: $($_.Exception.Message)" "WARN"
    }

    # Determine exit code and log final status
    $exitCode = 0
    if ($successCount -eq 0) {
        Write-Log "VSETKY EXPORTY ZLYHALI!" "ERROR"
        $exitCode = 1
    }
    elseif ($successCount -lt $totalCount) {
        Write-Log "Niektore exporty zlyhali" "WARN"
        $exitCode = 2
    }
    else {
        Write-Log "Vsetky exporty uspesne dokoncene" "SUCCESS"
        $exitCode = 0
    }

    # Cleanup mutexes AFTER all logging is done
    try {
        if ($null -ne $script:GraylogMutex) {
            $script:GraylogMutex.Close()
            $script:GraylogMutex.Dispose()
        }
        if ($null -ne $script:LogMutex) {
            $script:LogMutex.Close()
            $script:LogMutex.Dispose()
        }
    }
    catch {
        # Don't use Write-Log here as mutex might be disposed
        Write-Output "Poznámka: Chyba pri cleanup mutexov: $($_.Exception.Message)"
    }

    exit $exitCode