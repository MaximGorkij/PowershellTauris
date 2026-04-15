<# 
.SYNOPSIS
    Klonovanie AD uctu s logovanim + TEST/WHATIF rezim
.DESCRIPTION
    Vyhlada vzoroveho pouzivatela a vytvori presnu kopiu.
    - Orezanie zdrojova OU osetrena cez regex.
    - Pridany volitelny titul do DisplayName ("Priezvisko Meno, Titul").
    - EmployeeID: 5 alebo 7 miest (musi zacinat 0).
    - Email domena dynamicky podla vzoru.
    - Automaticke prevzatie alebo zmena telefonneho cisla.
    - Doplnkova sluzba: Auto-Enable.
    - Rezim behu sa zadava ako parameter pri spusteni skriptu.
.NOTES
    Verzia: 3.16 (Cleanup "True" outputs + Window Title)
    Autor: Automaticky report
    Pozadovane moduly: ActiveDirectory, LogHelper, ScheduledTasks
    Datum vytvorenia: 16.03.2026
    Logovanie: C:\TaurisIT\Log\UserClone
#>

param (
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("prod", "test")]
    [string]$Mode = "prod"
)

# Nastavenie nazvu okna konzoly
$Host.UI.RawUI.WindowTitle = "AD User Clone Tool v3.16"

# ---------------------------------------------------------------------------
# 1. OVERENIE ADMINISTRATORSKYCH PRAV
# ---------------------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "CHYBA: Skript vyzaduje spustenie ako ADMINISTRATOR!" -ForegroundColor Red
    Write-Host "Prosim, spustite skript cez ikonu (Spustit ako spravca)." -ForegroundColor Yellow
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Pause
    exit
}

# ---------------------------------------------------------------------------
# 2. POMOCNE FUNKCIE
# ---------------------------------------------------------------------------

function Remove-Diacritics {
    param ([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($char in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($char) }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

# ---------------------------------------------------------------------------
# 3. NASTAVENIA A INICIALIZACIA LOGOVANIA
# ---------------------------------------------------------------------------
$TestMode = ($Mode -eq "test")
$UseWhatIf = $TestMode

$LogHelperPath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1"
$LogDir = "C:\TaurisIT\Log\UserClone"
$EventSource = "ADUserCloneApp"
$Timestamp = Get-Date -Format 'yyyyMMddHHmm'
$LogFile = "$Timestamp-UserClone.log"

if (-not (Test-Path $LogDir)) {
    try { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null } 
    catch { Write-Warning "Nepodarilo sa vytvorit adresar logov: $_" }
}

$LogModuleLoaded = $false
if (Test-Path $LogHelperPath) {
    try {
        Import-Module $LogHelperPath -Force -ErrorAction Stop | Out-Null
        if (Get-Command "Initialize-LogSystem" -ErrorAction SilentlyContinue) {
            Initialize-LogSystem -LogDirectory $LogDir -EventSource $EventSource -RetentionDays 60 | Out-Null
        }
        $LogModuleLoaded = $true
    } catch { Write-Warning "LogHelper sa nepodarilo plne inicializovat: $_" }
}

function Write-IntuneLog {
    param($Message, $Level, $LogFile)
    $LogType = switch($Level) { "INFO" {"Information"} "WARN" {"Warning"} "ERROR" {"Error"} default {"Information"} }
    
    if ($LogModuleLoaded) {
        Write-CustomLog -Message $Message -Type $LogType -EventSource $EventSource -LogFileName $LogFile
    } else {
        Write-Host "[$Level] $Message" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 4. KONTROLA MODULOV
# ---------------------------------------------------------------------------
if (!(Get-Module -ListAvailable ActiveDirectory)) {
    Write-IntuneLog -Message "Modul ActiveDirectory chyba." -Level ERROR -LogFile $LogFile
    return
}
Import-Module ActiveDirectory -ErrorAction Stop | Out-Null

if ($TestMode) {
    Write-Host "`n=== TESTOVACI REZIM (WHATIF) ===" -ForegroundColor Yellow -BackgroundColor DarkRed
    Write-Host "Ziadne zmeny v AD sa nevykonaju (Simulacia)!`n" -ForegroundColor Yellow
}

$modeMsg = if ($TestMode) { "TEST/WHATIF" } else { "PROD" }
Write-IntuneLog -Message "Start aplikacie [$modeMsg] v3.16. LogFile: $LogFile" -Level INFO -LogFile $LogFile

# ---------------------------------------------------------------------------
# 5. VYHLADANIE PREDLOHY
# ---------------------------------------------------------------------------
$searchName = Read-Host "Zadaj priezvisko vzoroveho pouzivatela"
Write-IntuneLog -Message "Hladam: $searchName" -Level INFO -LogFile $LogFile

$users = @(Get-ADUser -Filter "Surname -like '*$searchName*'" -Properties DisplayName, UserPrincipalName, EmailAddress)

if ($users.Count -eq 0) {
    Write-Host "Nenaslo sa nic." -ForegroundColor Red
    Write-IntuneLog -Message "Ziadny vysledok pre: $searchName" -Level WARN -LogFile $LogFile
    return
}

Write-Host "`nNajdene:" -ForegroundColor Cyan
for ($i = 0; $i -lt $users.Count; $i++) {
    Write-Host "[$i] $($users[$i].DisplayName) ($($users[$i].UserPrincipalName))"
}

$validSelection = $false
$selectedIndex = -1
do {
    $choice = Read-Host "`nVyberte cislo (0 - $(($users.Count) - 1))"
    if ($choice -match '^\d+$') {
        $selectedIndex = [int]$choice
        if ($selectedIndex -ge 0 -and $selectedIndex -lt $users.Count) { $validSelection = $true }
        else { Write-Host "CHYBA: Cislo je mimo rozsahu!" -ForegroundColor Red }
    } else { Write-Host "CHYBA: Musite zadat cislo!" -ForegroundColor Red }
} until ($validSelection)

$template = $users[$selectedIndex]
$propsToLoad = @("MemberOf", "Description", "Title", "Department", "Company", "StreetAddress", "City", "PostalCode", "State", "Country", "Manager", "PhysicalDeliveryOfficeName", "OfficePhone")
$templateFull = Get-ADUser $template.DistinguishedName -Properties $propsToLoad

# ---------------------------------------------------------------------------
# 6. ZADANIE UDAJOV
# ---------------------------------------------------------------------------
Write-Host "`nZadaj udaje noveho uctu:" -ForegroundColor Cyan
$newTitle   = Read-Host "Titul pred menom (napr. Ing., Mgr., Bc. - ak nema, stlacte Enter)"
$newName    = Read-Host "Meno"
$newSurname = Read-Host "Priezvisko"

$displayName = if ([string]::IsNullOrWhiteSpace($newTitle)) { "$newSurname $newName" } else { "$newSurname $newName, $newTitle" }

$dupUsers = Get-ADUser -Filter "GivenName -eq '$newName' -and Surname -eq '$newSurname'" -Properties DisplayName, SamAccountName, Enabled
if ($dupUsers) {
    Write-Host "`n!!! POZOR: V AD UZ EXISTUJE UZIVATEL S TYMTO MENOM !!!" -ForegroundColor Red -BackgroundColor Yellow
    foreach ($u in $dupUsers) { Write-Host " -> $($u.DisplayName) (Login: $($u.SamAccountName))" -ForegroundColor Red }
    if ((Read-Host "`nChcete napriek tomu pokracovat? (A/N)") -ne "A") { return }
}

$sourceEmail = if ($templateFull.UserPrincipalName) { $templateFull.UserPrincipalName } else { $templateFull.EmailAddress }
$domainPart = if ($sourceEmail -match "@masiarstvoubyka.sk") { "@masiarstvoubyka.sk" } else { "@tauris.sk" }
$emailPrefixInput = Read-Host "Email (pred $domainPart)"
$newEmail = "$($emailPrefixInput.Split('@')[0])$domainPart"

do {
    $empIDInput = Read-Host "Employee ID (5 alebo 7 miest, musi zacinat 0)"
    $empIDValid = $empIDInput -match "^(0\d{4}|0\d{6})$"
    if (-not $empIDValid) { Write-Host "CHYBA: ID musi mat 5 alebo 7 cislic a zacinat nulou." -ForegroundColor Red }
} until ($empIDValid)

$cleanSurname = Remove-Diacritics $newSurname
$baseSam = $cleanSurname.ToLower().Replace(" ", "")
$candidateSam = $baseSam
$counter = 1
while (Get-ADUser -Filter "SamAccountName -eq '$candidateSam'" -ErrorAction SilentlyContinue) {
    $candidateSam = "$baseSam$counter"
    $counter++
}
$newSamInput = Read-Host "SAM login [$candidateSam]"
$newSam = if ([string]::IsNullOrWhiteSpace($newSamInput)) { $candidateSam } else { $newSamInput }

do {
    $templatePhone = $templateFull.OfficePhone
    $prompt = if ($templatePhone) { "Telefon (09XXXXXXXX alebo Enter pre vzor: $templatePhone)" } else { "Telefon (09XXXXXXXX)" }
    $phoneInput = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($phoneInput) -and $templatePhone) {
        $newPhone = $templatePhone; $phoneValid = $true
    } elseif ($phoneInput -match "^09\d{8}$") {
        $newPhone = "+421" + $phoneInput.Substring(1); $phoneValid = $true
    } else {
        Write-Host "CHYBA: Nespravny format." -ForegroundColor Red; $phoneValid = $false
    }
} until ($phoneValid)

$password = "Tauris$(Get-Date -Format yyyy)"
$passwordSecure = ConvertTo-SecureString $password -AsPlainText -Force

# ---------------------------------------------------------------------------
# 7. TECHNICKA KONTROLA A CIELOVA OU
# ---------------------------------------------------------------------------
if (Get-ADUser -Filter "SamAccountName -eq '$newSam'" -ErrorAction SilentlyContinue) { Write-Host "CHYBA: Login existuje!" -ForegroundColor Red; return }
$targetOU = $templateFull.DistinguishedName -replace '^CN=.+?,(?=OU=|CN=)', ''

# ---------------------------------------------------------------------------
# 8. SUHRN A POTVRDENIE
# ---------------------------------------------------------------------------
Clear-Host
Write-Host "================ SUHRN ================" -ForegroundColor Cyan
Write-Host "Meno: $displayName`nEmail: $newEmail`nLogin: $newSam`nOU: $targetOU"
Write-Host "=======================================" -ForegroundColor Cyan
if ((Read-Host "Suhlasite s vytvorenim? (A/N)") -ne "A") { return }

# ---------------------------------------------------------------------------
# 9. EXECUTION
# ---------------------------------------------------------------------------
try {
    $userParams = @{
        Name = $displayName; DisplayName = $displayName; GivenName = $newName; Surname = $newSurname
        EmailAddress = $newEmail; OfficePhone = $newPhone; EmployeeID = $empIDInput
        SamAccountName = $newSam; UserPrincipalName = $newEmail; Path = $targetOU
        Description = $templateFull.Description; Title = $templateFull.Title
        Department = $templateFull.Department; Company = $templateFull.Company
        Manager = $templateFull.Manager; Office = $templateFull.PhysicalDeliveryOfficeName
        StreetAddress = $templateFull.StreetAddress; City = $templateFull.City
        PostalCode = $templateFull.PostalCode; State = $templateFull.State; Country = $templateFull.Country
        AccountPassword = $passwordSecure; Enabled = $false; ChangePasswordAtLogon = $false; ErrorAction = "Stop"
    }

    New-ADUser @userParams -WhatIf:$UseWhatIf
    Write-IntuneLog -Message "Ucet $newSam vytvoreny (WhatIf=$UseWhatIf)" -Level INFO -LogFile $LogFile

    foreach ($group in $templateFull.MemberOf) {
        if ($TestMode) { Write-Host "[WHATIF] Pridanie do: $group" } 
        else { Add-ADGroupMember -Identity $group -Members $newSam -ErrorAction SilentlyContinue }
    }

    if ((Read-Host "`nNaplanovat automaticke zapnutie? (A/N)") -eq "A") {
        $dateStr = Read-Host "Datum aktivacie (dd.MM.yyyy)"
        try {
            $autoDate = [DateTime]::ParseExact($dateStr, "dd.MM.yyyy", $null).Date.AddHours(6)
            if ($autoDate -gt (Get-Date)) {
                $taskName = "Enable-ADUser-$newSam"
                $taskCmd = "Import-Module ActiveDirectory; Set-ADUser -Identity '$newSam' -Enabled `$true"
                $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-Command `"$taskCmd`""
                $trigger = New-ScheduledTaskTrigger -Once -At $autoDate
                Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -WhatIf:$UseWhatIf | Out-Null
                Write-Host "Uloha naplanovana na $autoDate" -ForegroundColor Green
            }
        } catch { Write-Warning "Ulohu sa nepodarilo vytvorit." }
    }
}
catch {
    Write-IntuneLog -Message "Kriticka chyba: $_" -Level ERROR -LogFile $LogFile
    Write-Host "CHYBA: $_" -ForegroundColor Red
}

Write-IntuneLog -Message "Koniec aplikacie" -Level INFO -LogFile $LogFile

