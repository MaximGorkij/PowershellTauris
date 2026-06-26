<#
.SYNOPSIS
    Vytvorenie a push lokalneho PowerShell adresara ako GitHub repo.
.DESCRIPTION
    Inicializuje git repo v D:\findrik\PowerShell, vytvori repozitar
    PowershellTauris na GitHub ucte MaximGorkij a pushne vsetok obsah.
.NOTES
    Verzia: 1.0
    Autor: Marek Findrik
    Pozadovane nastroje: git
    Datum vytvorenia: 26.06.2025
    Logovanie: C:\TaurisIT\Log\GitCopy
#>

param(
    [Parameter(Mandatory)][string]$TargetToken,   # PAT pre MaximGorkij (scope: repo)
    [string]$TargetUser = "MaximGorkij",
    [string]$RepoName   = "PowershellTauris",
    [string]$SourceDir  = "D:\findrik\PowerShell"
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

# --- Kontrola zdrojoveho adresara ---
if (-not (Test-Path $SourceDir)) {
    Write-Log "Zdrojovy adresar neexistuje: $SourceDir" "Error"
    exit 1
}

Write-Log "Zdrojovy adresar: $SourceDir"
Write-Log "Cielove repo: $TargetUser/$RepoName"

# --- Inicializacia git repo ---
Push-Location $SourceDir

if (-not (Test-Path "$SourceDir\.git")) {
    Write-Log "Inicializujem git repo..."
    git init 2>&1 | Out-Null
    git branch -M main 2>&1 | Out-Null
} else {
    Write-Log "Git repo uz existuje, pokracujem..."
}

# --- Pridanie vsetkych suborov ---
Write-Log "Pridavam subory (git add)..."
$AddOutput = git add . 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "CHYBA pri git add: $($AddOutput -join ' | ')" "Error"
    Pop-Location
    exit 1
}

# --- Commit ---
Write-Log "Vytvariam commit..."
$CommitOutput = git commit -m "Initial commit - PowerShell scripts TAURIS" 2>&1
if ($LASTEXITCODE -ne 0) {
    # Ak nie su ziadne zmeny na commit
    if ($CommitOutput -match "nothing to commit") {
        Write-Log "Ziadne zmeny na commit, pokracujem s pushom..." "Warning"
    } else {
        Write-Log "CHYBA pri git commit: $($CommitOutput -join ' | ')" "Error"
        Pop-Location
        exit 1
    }
}

# --- Vytvorenie repo na GitHub ---
Write-Log "Vytvariam repozitar $RepoName na GitHub..."
$Body = @{ name = $RepoName; private = $false } | ConvertTo-Json
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
    Write-Log "Repozitar uspesne vytvoreny."
} catch {
    Write-Log "Repozitar uz existuje alebo chyba pri vytvarani: $_" "Warning"
}

# --- Nastavenie remote ---
$RemoteUrl = "https://$TargetToken@github.com/$TargetUser/$RepoName.git"
$ExistingRemote = git remote 2>&1
if ($ExistingRemote -contains "origin") {
    Write-Log "Aktualizujem remote origin..."
    git remote set-url origin $RemoteUrl 2>&1 | Out-Null
} else {
    Write-Log "Pridavam remote origin..."
    git remote add origin $RemoteUrl 2>&1 | Out-Null
}

# --- Push ---
Write-Log "Pushujem na $TargetUser/$RepoName..."
$PushOutput = git push -u origin main 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "CHYBA pri push: $($PushOutput -join ' | ')" "Error"
    Pop-Location
    exit 1
}

Write-Log "=============================="
Write-Log "Hotovo. Repo dostupne na: https://github.com/$TargetUser/$RepoName"
Write-Log "=============================="

Pop-Location
exit 0
