<# 
.SYNOPSIS
    Export uzivatelov a ich licencii s Assignment Path (názvy skupín) do CSV.
.DESCRIPTION
    Skript prelozi SPE_F1 na Microsoft 365 F3 a SPE_E3 na Microsoft 365 E3.
    Zobrazuje presnu cestu priradenia (Direct/Inherited) s vyuzitim cache pre rychlost.
.NOTES
    Verzia: 4.6
    Autor: Automaticky report
    Pozadovane moduly: Microsoft.Graph.Users, Microsoft.Graph.Authentication, Microsoft.Graph.Groups, LogHelper
    Datum vytvorenia: 31.03.2026
    Logovanie: C:\TaurisIT\Log\EntraLicencieReport
#>

# Import modulov
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Groups
Import-Module "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1"

# Definicia ciest
$TaskName = "EntraLicencieReport"
$ExportDir = "C:\TaurisIT\Export"
$ConfigPath = Join-Path $PSScriptRoot "GraphAuth.xml"
$OutputFile = "$ExportDir\Report_Licencie_$(Get-Date -Format 'yyyyMMdd').csv"
$RelativeLogPath = "$TaskName\ExecutionLog"

if (-not (Test-Path $ExportDir)) { New-Item -Path $ExportDir -ItemType Directory -Force | Out-Null }

try {
    if (-not (Test-Path $ConfigPath)) { throw "Konfiguracny subor GraphAuth.xml nebol najdeny." }
    
    [xml]$Config = Get-Content -Path $ConfigPath
    $TenantId = $Config.GraphAuth.TenantId
    $ClientId = $Config.GraphAuth.ClientId
    $ClientSecret = $Config.GraphAuth.ClientSecret

    Write-CustomLog -Message "Startujem export (oprava komplexneho filtra)." -EventSource "EntraScript" -LogFileName $RelativeLogPath -Type "Information"

    # Autentifikacia
    $SecretSecure = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecretSecure)
    Connect-MgGraph -TenantId $TenantId -Credential $Credential | Out-Null

    # 1. Mapovanie SkuId (Preklady nazvov)
    $SkuMap = @{}
    Get-MgSubscribedSku | ForEach-Object {
        $Name = $_.SkuPartNumber
        if ($Name -eq "SPE_F1") { $Name = "Microsoft 365 F3" }
        if ($Name -eq "SPE_E3") { $Name = "Microsoft 365 E3" }
        $SkuMap[$_.SkuId.ToString()] = $Name
    }

    # 2. Cache pre názvy skupín
    $GroupNameCache = @{}

    # 3. Ziskanie vsetkych uzivatelov (bez problematickeho filtra)
    $Users = Get-MgUser -All -Property "Id", "DisplayName", "UserPrincipalName", "AssignedLicenses"
    
    $ReportData = New-Object System.Collections.Generic.List[PSObject]
    $ExcludedLicense = "IDENTITY_THREAT_PROTECTION"

    foreach ($User in $Users) {
        # Spracujeme len uzivatelov, ktori maju aspon jednu licenciu
        if ($User.AssignedLicenses -and $User.AssignedLicenses.Count -gt 0) {
            
            # Ziskanie detailov o licencii (kvoli Assignment Path)
            $Details = Get-MgUserLicenseDetail -UserId $User.Id

            foreach ($License in $Details) {
                $SkuId = $License.SkuId.ToString()
                $LicenseName = if ($SkuMap.ContainsKey($SkuId)) { $SkuMap[$SkuId] } else { $SkuId }

                if ($LicenseName -eq $ExcludedLicense) { continue }

                # Ziskanie Assignment Path
                $PathInfo = "Direct"
                if ($License.AssignmentMethod -ne "Direct") {
                    # Ak je to zdedene, pole AssignmentMethod obsahuje ID objektu (skupiny)
                    $GroupId = $License.AssignmentMethod
                    
                    if ($GroupId -match "^[0-9a-fA-F-]{36}$") { 
                        if (-not $GroupNameCache.ContainsKey($GroupId)) {
                            try {
                                $Group = Get-MgGroup -GroupId $GroupId -Property "DisplayName"
                                $GroupNameCache[$GroupId] = $Group.DisplayName
                            }
                            catch {
                                $GroupNameCache[$GroupId] = "Inherited (Neznama skupina: $GroupId)"
                            }
                        }
                        $PathInfo = "Inherited ($($GroupNameCache[$GroupId]))"
                    }
                    else {
                        $PathInfo = "Inherited"
                    }
                }

                $Row = [PSCustomObject]@{
                    Meno           = $User.DisplayName
                    Email          = $User.UserPrincipalName
                    Licencia       = $LicenseName
                    AssignmentPath = $PathInfo
                }
                $ReportData.Add($Row)
            }
        }
    }

    # Export do CSV
    $ReportData | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8 -Delimiter ","
    
    Write-CustomLog -Message "Report uspesne vygenerovany: $OutputFile" -EventSource "EntraScript" -LogFileName $RelativeLogPath -Type "Information"
    Disconnect-MgGraph | Out-Null
    Write-Host "Hotovo. Report najdete v: $OutputFile" -ForegroundColor Cyan

}
catch {
    $ErrorDetails = $_.Exception.Message
    Write-CustomLog -Message "Chyba v skripte: $ErrorDetails" -EventSource "EntraScript" -LogFileName $RelativeLogPath -Type "Error"
    Write-Error "Chyba: $ErrorDetails"
}