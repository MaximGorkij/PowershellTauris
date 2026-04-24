<#
.SYNOPSIS
    Export zoznamu publikovanych Intune aplikacii do JSON a CSV
.DESCRIPTION
    Skript sa pripoji na Microsoft Graph, ziska publikovane mobilne aplikacie
    z Intune a exportuje ich zoznam (Name + GUID + Type + Publisher) do JSON
    a CSV suboru pre dalsie pouzitie. Pred zapisom overi a v pripade potreby
    vytvori vsetky potrebne adresare (log + vystup).
.NOTES
    Verzia: 1.1
    Autor: Marek Findrik
    Pozadovane moduly: Microsoft.Graph.Devices.CorporateManagement, Microsoft.Graph.Authentication, LogHelper
    Datum vytvorenia: $(Get-Date -Format 'dd.MM.yyyy')
    Logovanie: C:\TaurisIT\Log\IntuneAppsExport
#>

param(
    [string]$OutputDir = "C:\TaurisIT\Export\IntuneApps"
)

# --- Premenne ---
$taskName = "IntuneAppsExport"
$logDir = "C:\TaurisIT\Log\$taskName"
$logFile = "$taskName\$taskName.log"   # relativna cesta pre LogHelper (bazovy priecinok C:\TaurisIT\Log)

# --- Helper: overenie a vytvorenie adresara ---
function Confirm-Directory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Popis = "adresar"
    )
    if (Test-Path -Path $Path -PathType Container) {
        Write-Host "[OK]     $Popis existuje: $Path" -ForegroundColor DarkGray
        return
    }
    try {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        Write-Host "[CREATE] $Popis vytvoreny: $Path" -ForegroundColor Yellow
    }
    catch {
        Write-Host "[ERROR]  Nepodarilo sa vytvorit $($Popis): $Path" -ForegroundColor Red
        throw
    }
}

# --- Priprava adresarov (musi prebehnut pred prvym logovanim) ---
Confirm-Directory -Path $logDir    -Popis "Log adresar"
Confirm-Directory -Path $OutputDir -Popis "Export adresar"

Import-Module LogHelper -ErrorAction SilentlyContinue

try {
    Write-CustomLog -Message "Start exportu Intune aplikacii" -EventSource $taskName -EventLogName "Application" -LogFileName $logFile -Type "Information"

    # --- Pripojenie na Graph ---
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome | Out-Null
    }

    # --- Ziskanie aplikacii ---
    $apps = Get-MgDeviceAppManagementMobileApp -All |
    Where-Object { $_.PublishingState -eq "published" }

    $list = foreach ($app in $apps) {
        [PSCustomObject]@{
            Name      = $app.DisplayName
            Id        = $app.Id
            Type      = ($app.AdditionalProperties['@odata.type']) -replace '#microsoft.graph.', ''
            Publisher = $app.Publisher
        }
    }
    $list = $list | Sort-Object Name

    # --- Export ---
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonPath = Join-Path $OutputDir "IntuneApps_$stamp.json"
    $csvPath = Join-Path $OutputDir "IntuneApps_$stamp.csv"

    $list | ConvertTo-Json -Depth 3 | Out-File -FilePath $jsonPath -Encoding UTF8
    $list | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $count = ($list | Measure-Object).Count
    Write-CustomLog -Message "Exportovanych $count aplikacii -> $jsonPath, $csvPath" -EventSource $taskName -EventLogName "Application" -LogFileName $logFile -Type "Information"
    Write-Host ""
    Write-Host "Exportovanych $count aplikacii:" -ForegroundColor Green
    Write-Host "  JSON: $jsonPath"
    Write-Host "  CSV : $csvPath"
}
catch {
    Write-CustomLog -Message "Chyba: $($_.Exception.Message)" -EventSource $taskName -EventLogName "Application" -LogFileName $logFile -Type "Error"
    throw
}