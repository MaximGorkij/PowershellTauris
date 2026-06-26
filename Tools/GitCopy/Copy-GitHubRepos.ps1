<#
.SYNOPSIS
    Kopirovanie vsetkych repozitarov z jedneho GitHub uctu do druheho.
.DESCRIPTION
    Script stiahne vsetky repozitare zo zdrojoveho GitHub uctu (ittauris)
    pomocou GitHub API a pushne ich ako mirror na cielovy ucet (MaximGorkij).
    Nepotrebuje gh CLI - vyzaduje iba git a dva Personal Access Tokeny.
.NOTES
    Verzia: 2.3
    Autor: Marek Findrik
    Pozadovane nastroje: git
    Datum vytvorenia: 26.06.2025
    Logovanie: C:\TaurisIT\Log\GitCopy
#>

param(
    [string]$SourceUser   = "ittauris",
    [string]$TargetUser   = "MaximGorkij",
    [Parameter(Mandatory)][string]$SourceToken,   # PAT pre ittauris (scope: repo)
    [Parameter(Mandatory)][string]$TargetToken,   # PAT pre MaximGorkij (scope: repo)
    [string]$TempDir      = "$env:TEMP\GitCopy"
)

# --- Logovanie ---
Import-Module "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1" -ErrorAction SilentlyContinue
$LogFile   = "GitCopy\GitCopy.log"
$LogSource = "GitCopy"
$LogName   = "Application"

function Write-Log {
    param([string]$Message, [string]$Type = "Information")
    Write-Host "[$Type] $Message"
    try {
        Write-CustomLog -Message $Message -EventSource $LogSource -EventLogName $LogName -LogFileName $LogFile -Type $Type
    } catch {}
}

# --- Kontrola git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Log "git nie je nainstalovany alebo nie je v PATH." "Error"
    exit 1
}

# --- Priprava temp adresara ---
if (Test-Path $TempDir) {
    Remove-Item $TempDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TempDir | Out-Null
Write-Log "Docasny adresar: $TempDir"

# --- Funkcia na volanie GitHub API so strankovanim ---
function Get-GitHubRepos {
    param([string]$User, [string]$Token)

    $Headers = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
    }

    $AllRepos = @()
    $Page     = 1

    do {
        $Url      = "https://api.github.com/users/$User/repos?per_page=100&page=$Page&type=owner"
        $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -ErrorAction Stop
        $AllRepos += $Response
        $Page++
    } while ($Response.Count -eq 100)

    return $AllRepos
}

# --- Ziskanie zoznamu repozitarov ---
Write-Log "Nacitavam zoznam repozitarov zo zdrojoveho uctu: $SourceUser..."

try {
    $Repos = Get-GitHubRepos -User $SourceUser -Token $SourceToken
} catch {
    Write-Log "Nepodarilo sa nacitat zoznam repozitarov: $_" "Error"
    exit 1
}

Write-Log "Najdenych repozitarov: $($Repos.Count)"

if ($Repos.Count -eq 0) {
    Write-Log "Ziadne repozitare na spracovanie." "Warning"
    exit 0
}

# --- Hlavna slucka ---
$Success = 0
$Failed  = 0

foreach ($Repo in $Repos) {
    $RepoName  = $Repo.name
    $IsPrivate = $Repo.private
    $LocalPath = "$TempDir\$RepoName.git"
    $SourceUrl = "https://$SourceToken@github.com/$SourceUser/$RepoName.git"
    $TargetUrl = "https://$TargetToken@github.com/$TargetUser/$RepoName.git"

    Write-Log "==> Spracovavam: $RepoName $(if ($IsPrivate) { '[PRIVATE]' } else { '[PUBLIC]' })"

    # Klonovanie mirror
    Write-Log "    Klonujem..."
    $CloneOutput = git clone --mirror $SourceUrl $LocalPath 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "    CHYBA: Klonovanie zlyhalo pre $RepoName" "Error"
        Write-Log "    Detail: $($CloneOutput -join ' | ')" "Error"
        $Failed++
        if (Test-Path $LocalPath) { Remove-Item $LocalPath -Recurse -Force }
        continue
    }

    # Vytvorenie repozitara na cielovom ucte
    Write-Log "    Vytvariam repozitar na cielovom ucte..."
    $Body = @{ name = $RepoName; private = $IsPrivate } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post `
            -Uri "https://api.github.com/user/repos" `
            -Headers @{
                Authorization = "token $TargetToken"
                Accept        = "application/vnd.github+json"
            } `
            -Body $Body `
            -ContentType "application/json" `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "    Repozitar uz existuje alebo chyba pri vytvarani: $_" "Warning"
    }

    # Push mirror
    Write-Log "    Pushujem..."
    Push-Location $LocalPath
    git remote set-url origin $TargetUrl 2>&1 | Out-Null
    $PushOutput = git push --mirror 2>&1
    $PushResult = $LASTEXITCODE
    Pop-Location

    if ($PushResult -ne 0) {
        Write-Log "    CHYBA: Push zlyhal pre $RepoName" "Error"
        Write-Log "    Detail: $($PushOutput -join ' | ')" "Error"
        $Failed++
    } else {
        Write-Log "    OK: $RepoName uspesne skopirovany"
        $Success++
    }

    # Upratanie
    if (Test-Path $LocalPath) { Remove-Item $LocalPath -Recurse -Force }
}

# --- Zhrnutie ---
Write-Log "=============================="
Write-Log "Hotovo. Uspesne: $Success | Chyby: $Failed"
Write-Log "=============================="

if ($Failed -gt 0) { exit 1 } else { exit 0 }
