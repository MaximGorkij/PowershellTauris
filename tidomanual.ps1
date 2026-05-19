<#
.SYNOPSIS
    Manualné stiahnutie dochadzky z TiDo API za den spred 8 dni do CSV suboru.
.DESCRIPTION
    Skript sa prihlasi do TiDo API pomocou API klienta, ziska autentifikacny hash
    a nasledne stiahne data o odpracovanych hodinach za den spred 8 dni (manualna
    korekcia / oneskoreny export). Vystupny CSV subor je ulozeny do /mnt/tido-data/
    s datumom v nazve.
.NOTES
    Verzia:    1.1
    Autor:     Marek Findrik
    Pozadovane moduly: -
    Datum vytvorenia: 13.05.2026
    Logovanie: /mnt/tido-data/log
#>

# --- Konfiguracia ---
$apiUrl      = 'https://api.tido.sk/api'
$apiKlient   = 'tauris.tido.sk'
$apiHeslo    = 'TiDo_Tauris_MIS_2022'
$vystupnyAdr = '/mnt/tido-data'
$posunDni    = -8

# --- Prihlasenie do API ---
$hlavickyLogin = @{
    'Content-Type' = 'application/json'
}

$teloLogin = @{
    api_client_name = $apiKlient
    api_client_pass = $apiHeslo
} | ConvertTo-Json

try {
    $odpLogin = Invoke-RestMethod "$apiUrl/api-client/login/" -Method POST -Headers $hlavickyLogin -Body $teloLogin -ErrorAction Stop
} catch {
    Write-Error "Chyba pri prihlaseni do TiDo API: $_"
    exit 1
}

$hash = $odpLogin.data.hash

if (-not $hash) {
    Write-Error "Prihlasenie zlyhalo - hash nebol ziskany."
    exit 1
}

# --- Stiahnutie dat za cielovy datum ---
$datum = (Get-Date).AddDays($posunDni).ToString('yyyy-MM-dd')

$hlavickyData = @{
    'Content-Type'     = 'text/plain; charset=UTF-8'
    'Content-language' = 'sk'
}

$urlData   = "$apiUrl/odpracovane/?date=$datum&hash=$hash"
$vystupSub = "$vystupnyAdr\${datum}_tido.csv"

try {
    $odpData = Invoke-RestMethod $urlData -Method GET -Headers $hlavickyData -ErrorAction Stop
} catch {
    Write-Error "Chyba pri stahovani dat z TiDo API: $_"
    exit 1
}

# --- Export do CSV ---
if ($null -eq $odpData.data) {
    Write-Warning "API nevratilo ziadne data pre datum $datum."
    exit 0
}

try {
    $odpData.data | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $vystupSub -Encoding utf8 -ErrorAction Stop
    Write-Host "OK: Data ulozene do $vystupSub"
} catch {
    Write-Error "Chyba pri zapise CSV suboru: $_"
    exit 1
}