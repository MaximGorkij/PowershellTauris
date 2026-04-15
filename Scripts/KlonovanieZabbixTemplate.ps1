<#
.SYNOPSIS
    Hromadné klonovanie aktívnych Zabbix šablón s prefixom TG-
.DESCRIPTION
    Skript načíta konfiguráciu z .env, identifikuje použité šablóny,
    vytvorí potrebné template groups a naimportuje klonované šablóny.
    Opravuje názvy, UUID, skupiny aj trigger expression referencie.
.PARAMETER DryRun
    Ak $true, skript len vypíše plánované akcie bez skutočného klonovania.
.NOTES
    Verzia: 2.1
    Autor: Automatizácia
    Pozadovane moduly: LogHelper
    Datum vytvorenia: 13.03.2026
    Logovanie: C:\TaurisIT\Log\ZabbixInventory\template_cloning.log
    POZOR: EventSource "ZabbixClone" musí byť registrovaný jednorazovo ako Admin:
           New-EventLog -LogName "IntuneScript" -Source "ZabbixClone"
#>

param (
    [bool]$DryRun = $true
)

# --- Import LogHelper modulu ---
$ModulePath = "C:\Program Files\WindowsPowerShell\Modules\LogHelper\LogHelper.psm1"
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force
}
else {
    Write-Error "Modul LogHelper nebol nájdený."
    exit
}

# Konfigurácia logovania
$EventSource = "ZabbixClone"
$LogFileName = "template_cloning.log"
$LogDir = "C:\TaurisIT\Log\ZabbixInventory"

# Inicializácia log systému
$LogInit = Initialize-LogSystem -LogDirectory $LogDir `
    -EventSource $EventSource -EventLogName "IntuneScript"

if (-not $LogInit) {
    Write-Error "Nepodarilo sa inicializovať logovací systém."
    exit
}

# --- Načítanie .env súboru ---
$EnvFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '=' -and $_ -notmatch '^#' } | ForEach-Object {
        $Parts = $_.Split('=', 2)
        if ($Parts.Count -eq 2) {
            $Key = $Parts[0].Trim()
            $Value = $Parts[1].Trim()
            Set-Variable -Name $Key -Value $Value -Scope Script
        }
    }
}
else {
    Write-CustomLog -Message "Súbor .env nebol nájdený v adresári $PSScriptRoot" `
        -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
    exit
}

# Konfigurácia
$ZabbixUrl = $ZABBIX_URL
$ApiToken = $ZABBIX_API
$ClonePrefix = "TG-"
$TargetGroup = "TG"

if (-not $ZabbixUrl -or -not $ApiToken) {
    Write-CustomLog -Message "Chýbajúce údaje v .env súbore (ZABBIX_URL alebo ZABBIX_API)" `
        -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
    exit
}

# --- Funkcia pre volanie Zabbix API ---
function Invoke-ZabbixApi {
    param (
        [string]$Method,
        [hashtable]$Params
    )

    $Body = @{
        jsonrpc = "2.0"
        method  = $Method
        params  = $Params
        id      = 1
    } | ConvertTo-Json -Depth 10

    try {
        return Invoke-RestMethod -Uri $ZabbixUrl -Method Post `
            -Headers @{ Authorization = "Bearer $ApiToken" } `
            -ContentType "application/json" -Body $Body
    }
    catch {
        Write-CustomLog -Message "Chyba API volania ($Method): $($_.Exception.Message)" `
            -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
        return $null
    }
}

# --- Funkcia na zabezpečenie existencie Template Group ---
function Assert-ZabbixTemplateGroup {
    param ([string]$GroupName)

    $Check = Invoke-ZabbixApi -Method "templategroup.get" -Params @{
        filter = @{ name = @($GroupName) }
    }

    if ($null -eq $Check.result -or $Check.result.Count -eq 0) {
        Write-Host "Vytváram skupinu: $GroupName" -ForegroundColor Yellow
        $Create = Invoke-ZabbixApi -Method "templategroup.create" -Params @{
            name = $GroupName
        }
        return $null -ne $Create.result
    }
    return $true
}

# --- Funkcia pre premenovanie skupín v XML ---
function Update-XmlGroups {
    param (
        [System.Xml.XmlDocument]$XmlDoc,
        [string]$TargetGroup
    )

    function Get-NewGroupName {
        param([string]$OldName)
        if ($OldName -match "^Templates/(.+)$") { return "$TargetGroup/" + $Matches[1] }
        if ($OldName -eq "Templates") { return $TargetGroup }
        if ($OldName.StartsWith($TargetGroup)) { return $OldName }
        return "$TargetGroup/" + $OldName
    }

    # Statická kópia – zabraňuje preskočeniu nodov pri live kolekcii
    $HeaderNodes = @($XmlDoc.SelectNodes("//template_group/name"))
    foreach ($Node in $HeaderNodes) {
        $Node.InnerText = Get-NewGroupName -OldName $Node.InnerText
    }

    $TemplateNodes = @($XmlDoc.SelectNodes("//templates/template/groups/group/name"))
    foreach ($Node in $TemplateNodes) {
        $Node.InnerText = Get-NewGroupName -OldName $Node.InnerText
    }

    return $XmlDoc
}

# --- Štart procesu ---
$StatusMsg = if ($DryRun) { "VYKONÁVA SA LEN TEST (DryRun)" } else { "OSTRÝ REŽIM" }
Write-CustomLog -Message "Štart procesu klonovania. Režim: $StatusMsg" `
    -EventSource $EventSource -LogFileName $LogFileName -Type 'Information'

# Získanie šablón
$TemplatesRequest = Invoke-ZabbixApi -Method "template.get" -Params @{
    output      = @("templateid", "host", "name")
    selectHosts = "count"
}

if ($null -eq $TemplatesRequest) {
    Write-CustomLog -Message "Nepodarilo sa načítať šablóny zo Zabbix API." `
        -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
    exit
}

# Bezpečný prevod hosts na int + vylúč už existujúce TG- šablóny
$TemplatesToClone = $TemplatesRequest.result | Where-Object {
    $ParsedCount = 0
    [int]::TryParse($_.hosts, [ref]$ParsedCount) -and $ParsedCount -gt 0 -and
    -not $_.host.StartsWith($ClonePrefix)
}

$TotalToProcess = if ($null -eq $TemplatesToClone) { 0 } else { $TemplatesToClone.Count }
Write-Host "Nájdených šablón na klonovanie: $TotalToProcess" -ForegroundColor Cyan
Write-CustomLog -Message "Nájdených šablón na klonovanie: $TotalToProcess" `
    -EventSource $EventSource -LogFileName $LogFileName -Type 'Information'

$CountSuccess = 0
$CountError = 0
$CountSkipped = 0

# --- Cyklus klonovania ---
foreach ($OldTemplate in $TemplatesToClone) {
    $NewName = $ClonePrefix + $OldTemplate.name
    $NewHost = $ClonePrefix + $OldTemplate.host

    if ($DryRun) {
        Write-Host "[DryRun] Plánujem: $($OldTemplate.name) -> $NewName" -ForegroundColor Gray
        continue
    }

    # Kontrola existencie klonu
    $Existing = Invoke-ZabbixApi -Method "template.get" -Params @{
        filter = @{ host = $NewHost }
    }
    if ($null -ne $Existing.result -and $Existing.result.Count -gt 0) {
        Write-Host "[SKIP] $NewName už existuje." -ForegroundColor Yellow
        Write-CustomLog -Message "Klon $NewName už existuje, preskakujem." `
            -EventSource $EventSource -LogFileName $LogFileName -Type 'Warning'
        $CountSkipped++
        continue
    }

    # Export
    $Export = Invoke-ZabbixApi -Method "configuration.export" -Params @{
        options = @{ templates = @($OldTemplate.templateid) }
        format  = "xml"
    }

    if ($null -eq $Export -or $null -eq $Export.result) { $CountError++; continue }

    try {
        $XmlData = $Export.result

        # 1. String replace – názov, host a trigger expression referencie
        $XmlData = $XmlData.Replace(">$($OldTemplate.name)<", ">$NewName<")
        $XmlData = $XmlData.Replace(">$($OldTemplate.host)<", ">$NewHost<")
        # Trigger expressions: {OldHost:item.key} -> {NewHost:item.key}
        $XmlData = $XmlData.Replace("/$($OldTemplate.host)/", "/$NewHost/")

        # 2. XML parser – UUID regenerácia + skupiny
        [xml]$XmlDoc = $XmlData

        # Regeneruj všetky UUID – zabraňuje duplicite
        $AllUuids = @($XmlDoc.SelectNodes("//uuid"))
        foreach ($UuidNode in $AllUuids) {
            $UuidNode.InnerText = [guid]::NewGuid().ToString("n")
        }

        # 3. Aktualizácia skupín
        $XmlDoc = Update-XmlGroups -XmlDoc $XmlDoc -TargetGroup $TargetGroup

        # 4. Zabezpečenie existencie skupín v DB
        $GroupNameNodes = @($XmlDoc.SelectNodes("//template_group/name"))
        foreach ($GNode in $GroupNameNodes) {
            $null = Assert-ZabbixTemplateGroup -GroupName $GNode.InnerText
        }

        $XmlData = $XmlDoc.OuterXml
    }
    catch {
        Write-CustomLog -Message "XML Error ($($OldTemplate.name)): $($_.Exception.Message)" `
            -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
        $CountError++
        continue
    }

    # Import
    $Import = Invoke-ZabbixApi -Method "configuration.import" -Params @{
        format = "xml"
        source = $XmlData
        rules  = @{
            templates          = @{ createMissing = $true; updateExisting = $false }
            items              = @{ createMissing = $true }
            triggers           = @{ createMissing = $true }
            graphs             = @{ createMissing = $true }
            discoveryRules     = @{ createMissing = $true }
            templateLinkage    = @{ createMissing = $true }
            templateDashboards = @{ createMissing = $true }
            httptests          = @{ createMissing = $true }
            valueMaps          = @{ createMissing = $true; updateExisting = $false }
        }
    }

    if ($null -ne $Import -and $Import.result) {
        Write-Host "[OK] $NewName" -ForegroundColor Green
        Write-CustomLog -Message "Klon $NewName úspešne vytvorený." `
            -EventSource $EventSource -LogFileName $LogFileName -Type 'Information'
        $CountSuccess++
    }
    else {
        $Err = $Import.error | ConvertTo-Json -Compress
        Write-CustomLog -Message "Import Error $NewName - $Err" `
            -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
        Write-Host "[CHYBA] $NewName (viď log)" -ForegroundColor Red
        $CountError++
    }
}

# --- Overenie existencie naklonovaných šablón v DB ---
if (-not $DryRun) {
    Write-Host "`nOverujem existenciu klonov v DB..." -ForegroundColor Cyan
    $VerifiedCount = 0

    foreach ($OldTemplate in $TemplatesToClone) {
        $NewHost = $ClonePrefix + $OldTemplate.host

        $VerifyOne = Invoke-ZabbixApi -Method "template.get" -Params @{
            output = @("host", "name")
            filter = @{ host = $NewHost }
        }

        if ($VerifyOne.result.Count -gt 0) {
            Write-Host "[OK] $NewHost" -ForegroundColor Green
            $VerifiedCount++
        }
        else {
            Write-Host "[CHYBA] $NewHost nenájdený v DB!" -ForegroundColor Red
            Write-CustomLog -Message "Overenie: klon $NewHost neexistuje v DB!" `
                -EventSource $EventSource -LogFileName $LogFileName -Type 'Error'
        }
    }

    Write-CustomLog -Message "Overenie dokončené – nájdených $VerifiedCount z $TotalToProcess klonov." `
        -EventSource $EventSource -LogFileName $LogFileName -Type 'Information'
    Write-Host "Overených: $VerifiedCount / $TotalToProcess" -ForegroundColor Cyan
}

# Čistenie starých logov
Clear-OldLogs -LogDirectory $LogDir

# Záverečný súhrn
$Summary = "Dokončené – Úspešne: $CountSuccess | Preskočené: $CountSkipped | Chyby: $CountError"
Write-CustomLog -Message $Summary -EventSource $EventSource -LogFileName $LogFileName -Type 'Information'
Write-Host "`n$Summary" -ForegroundColor Cyan
Write-Host "Log: $LogDir\$LogFileName" -ForegroundColor Green