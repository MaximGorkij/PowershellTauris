<#
.SYNOPSIS
    Zalohovanie pouzivatelskeho profilu na sietovy disk.
.DESCRIPTION
    Skript zalohuje vybrane priecinky aktualneho pouzivatela vratane profilu
    Google Chrome na sietove umiestnenie \\nas03\BACKUP. Pouziva Robocopy
    s loggovanim do suboru.
    Skript korektne detekuje interaktivne prihlaseneho pouzivatela aj pri spusteni ako admin.
.NOTES
    Verzia: 1.5
    Autor: Ing. Marek Findrik
    Pozadovane moduly: -
    Datum vytvorenia: 29.05.2026
    Logovanie: C:\Temp
#>

# --- Konfiguracia ---
$nazovUlohy    = "ZalohaProfiluPouzivatela"
$cieloveUmiest = "\\nas03\BACKUP"
$logDir        = "C:\Temp"
$datumZalohy   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$logSubor      = Join-Path $logDir "${nazovUlohy}_${datumZalohy}.log"

# --- Funkcia logovania ---
function Write-Log {
    param(
        [string]$Sprava,
        [ValidateSet('INFO','WARNING','ERROR')]
        [string]$Typ = 'INFO'
    )
    $riadok = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Typ, $Sprava
    $riadok | Tee-Object -FilePath $logSubor -Append | Write-Host
}

# --- Vytvorenie log priecinku ak neexistuje ---
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# --- Zistenie interaktivne prihlaseneho pouzivatela ---
$wmiPouzivatel = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

if (-not $wmiPouzivatel) {
    Write-Log "Nepodarilo sa zistit interaktivne prihlaseneho pouzivatela." -Typ 'ERROR'
    exit 1
}

$aktualnyPouzivatel = $wmiPouzivatel -replace '.*\\'
$profilCesta        = "C:\Users\$aktualnyPouzivatel"

Write-Log "Interaktivne prihlaseny pouzivatel: $aktualnyPouzivatel (WMI: $wmiPouzivatel)"
Write-Log "Cesta profilu: $profilCesta"

# --- Priecinky na zalohovanie ---
$priecinky = @(
    "Desktop",
    "Documents",
    "Favorites",
    "Music",
    "Pictures",
    "Videos",
    "AppData\Local\Google\Chrome\User Data\Default"
)

# --- Cielovy priecinok ---
$cielZalohy = Join-Path $cieloveUmiest "$env:COMPUTERNAME\$aktualnyPouzivatel\$datumZalohy"

Write-Log "Zaciatok zalohy profilu pouzivatela: $aktualnyPouzivatel"
Write-Log "Cielove umiestnenie: $cielZalohy"

# --- Overenie dostupnosti sietoveho disku ---
if (-not (Test-Path $cieloveUmiest)) {
    Write-Log "Sietove umiestnenie $cieloveUmiest nie je dostupne." -Typ 'ERROR'
    exit 1
}

# --- Overenie existencie profilu ---
if (-not (Test-Path $profilCesta)) {
    Write-Log "Cesta profilu neexistuje: $profilCesta" -Typ 'ERROR'
    exit 1
}

# --- Vytvorenie cieloveho priecinku ---
try {
    New-Item -ItemType Directory -Path $cielZalohy -Force | Out-Null
    Write-Log "Vytvoreny cielovy priecinok: $cielZalohy"
} catch {
    Write-Log "Chyba pri vytvarani cieloveho priecinku: $_" -Typ 'ERROR'
    exit 1
}

# --- Zalohovanie jednotlivych priecinkov ---
$celkovyVysledok = $true

foreach ($priecinok in $priecinky) {

    $zdrojCesta = Join-Path $profilCesta $priecinok
    $cielCesta  = Join-Path $cielZalohy $priecinok

    if (-not (Test-Path $zdrojCesta)) {
        Write-Log "Priecinok neexistuje, preskakujem: $zdrojCesta" -Typ 'WARNING'
        continue
    }

    Write-Log "Zalohujem: $zdrojCesta -> $cielCesta"

    $robocopyLog = Join-Path $logDir ("robocopy_" + ($priecinok -replace '\\|\ ','_') + "_${datumZalohy}.log")

    & robocopy.exe "$zdrojCesta" "$cielCesta" /E /COPY:DAT /R:2 /W:5 /NFL /NDL /NP /LOG:"$robocopyLog" | Out-Null
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        Write-Log "Chyba pri zalohovani $priecinok (ExitCode: $exitCode). Detail: $robocopyLog" -Typ 'ERROR'
        $celkovyVysledok = $false
    } else {
        Write-Log "Priecinok $priecinok zalohovan uspesne (ExitCode: $exitCode)."
    }
}

# --- Zaver ---
if ($celkovyVysledok) {
    Write-Log "Zaloha profilu $aktualnyPouzivatel dokoncena uspesne. Ciel: $cielZalohy"
} else {
    Write-Log "Zaloha profilu $aktualnyPouzivatel dokoncena S CHYBAMI. Skontroluj logy v $logDir" -Typ 'WARNING'
    exit 1
}