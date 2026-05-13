<# 
.SYNOPSIS
    Instalacia aplikacie pomocou automatickej detekcie EXE suboru
.DESCRIPTION
    Skript automaticky najde EXE subor v aktualnom priecinku a spusti ho s parametrom /S.
    Tiez zaisti kopirovanie konfiguracie config.model.xml do cielovej aplikacie.
.NOTES
    Verzia:   2.3
    Autor:    Marek Findrik / TaurisIT
    Pozadovane moduly: LogHelper
    Datum vytvorenia: 23.02.2026
    Logovanie: C:\TaurisIT\Log\AppInstallation
#>

# Import logovacieho modulu
Import-Module "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1" -ErrorAction SilentlyContinue

# Nastavenie ciest
# FIX: LogFileName je relativna cesta voci C:\TaurisIT\Log (konvencia LogHelper)
# Write-CustomLog si adresar vytvori sama - manualna tvorba adresara nie je potrebna
$logFileName = "AppInstallation\Install_$env:COMPUTERNAME.log"
$sourceName = "App Installer"
$logName = "Application"
$currentDir = $PSScriptRoot

# Cielovy adresar pre kopirovanie config.model.xml
# UPRAVIT podla konkretnej aplikacie pred nasadenim
$configTargetPath = "$env:ProgramFiles\Notepad++\config.model.xml"

# --- AUTOMATICKA DETEKCIA EXE SUBORU ---
# Hladame prvy EXE subor v priecinku (ignorujeme ine typy suborov)
$installer = Get-ChildItem -Path $currentDir -Filter "*.exe" | Select-Object -First 1

if ($null -ne $installer) {
    $installerName = $installer.Name
    $fullInstallerPath = $installer.FullName
    $arguments = "/S"

    Write-CustomLog -Message "Najdeny instalator: $installerName. Spustam instalaciu..." `
        -EventSource $sourceName -EventLogName $logName -LogFileName $logFileName -Type 'Information'
    
    # Spustenie instalacie
    $process = Start-Process -FilePath $fullInstallerPath -ArgumentList $arguments -Wait -PassThru
    
    if ($process.ExitCode -eq 0) {
        Write-CustomLog -Message "Instalacia $installerName prebehla uspesne." `
            -EventSource $sourceName -EventLogName $logName -LogFileName $logFileName -Type 'Information'
        
        # Kopirovanie konfiguracie, ak existuje
        $configSource = Join-Path $currentDir "config.model.xml"

        if (Test-Path $configSource) {
            $targetDir = Split-Path $configTargetPath -Parent

            if (Test-Path $targetDir) {
                Copy-Item -Path $configSource -Destination $configTargetPath -Force
                Write-CustomLog -Message "Konfiguracia bola uspesne skopirovana do: $configTargetPath" `
                    -EventSource $sourceName -EventLogName $logName -LogFileName $logFileName -Type 'Information'
            }
            else {
                Write-CustomLog -Message "Cielovy adresar pre konfiguraciu neexistuje: $targetDir" `
                    -EventSource $sourceName -EventLogName $logName -LogFileName $logFileName -Type 'Warning'
            }
        }
    }
    else {
        Write-CustomLog -Message "Instalacia skoncila s chybou. ExitCode: $($process.ExitCode)" `
            -EventSource $sourceName -EventLogName $logName -LogFileName $logFileName -Type 'Error'
    }

    exit $process.ExitCode
}
else {
    $errorMsg = "V priecinku $currentDir sa nenasiel ziaden EXE instalator."
    Write-CustomLog -Message $errorMsg `
        -EventSource $sourceName -EventLogName $logName -LogFileName $logFileName -Type 'Error'
    exit 1
}