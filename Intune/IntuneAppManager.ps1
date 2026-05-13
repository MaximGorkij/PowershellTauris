<#
.SYNOPSIS
    Export Intune mobilnych aplikacii (metadata) do JSON backup-u s diff detekciou.
.DESCRIPTION
    Pripoji sa na Microsoft Graph a pre kazdu mobilnu aplikaciu v tenante ulozi
    jej metadata ako JSON subor v strukture <BackupRoot>\<AppType>\<AppId>.json.

    Pri kazdom behu detekuje:
      - NOVE aplikacie (bez existujuceho JSON suboru)
      - ZMENENE aplikacie (existuje subor, ale kanonicky obsah sa lisi)

    Backup subor sa prepisuje LEN ak sa naslo meaningful diff - volatile properties
    (lastModifiedDateTime, uploadState, publishingState, derived counts) sa ignoruju.
    Vdaka tomu mtime suboru odraza poslednu realnu zmenu konfiguracie.

    Pri zmenenych apkach sa vypise aj zoznam top-level properties ktore sa zmenili.

    Pokryva vsetky typy aplikacii (winGetApp, win32LobApp, iosStoreApp,
    androidManagedStoreApp, webApp, officeSuiteApp atd.). Pri Win32/LOB apkach
    zaloha obsahuje LEN metadata - binarny obsah a encryption keys sa neexportuju.

    Vyzaduje scope: DeviceManagementApps.Read.All
.PARAMETER BackupRoot
    UNC alebo lokalna cesta pre ulozenie backup-u.
    Default: \\nas03\LOG\BackupIntune
.EXAMPLE
    .\Export-IntuneApps.ps1

    Spusti export s defaultnym backup root-om.
.EXAMPLE
    $result = .\Export-IntuneApps.ps1 -Verbose
    $result.NewApps | Format-Table
    $result.ModifiedApps | Format-Table Type, DisplayName, @{n='Changed';e={$_.ChangedProperties -join ', '}}

    Spusti export a zobrazi zmeny v tabulkovom formate.
.NOTES
    Verzia: 2.0
    Autor: Marek
    Pozadovane moduly: Microsoft.Graph.Authentication, LogHelper
    Datum vytvorenia: 24.04.2026
    Logovanie: LogHelper -> IntuneAppExport
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BackupRoot = '\\nas03\LOG\BackupIntune'
)

$ErrorActionPreference = 'Stop'

# --- Import pozadovanych modulov ---
try {
    Import-Module LogHelper -ErrorAction Stop
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
}
catch {
    Write-Error "Chyba nacitania modulov: $_"
    exit 1
}

# --- Konstanty pre logovanie ---
$script:LogParams = @{
    EventSource  = 'IntuneAppExport'
    EventLogName = 'Application'
    LogFileName  = 'IntuneAppExport'
}

# --- Volatile properties - ignoruju sa pri diff detekcii ---
# Menia sa bez zasahu admina (backend recalc, state transitions, derived counts)
$script:VolatileProps = @(
    'lastModifiedDateTime',
    'uploadState',
    'publishingState',
    'dependentAppCount',
    'supersedingAppCount',
    'supersededAppCount',
    'usedLicenseCount',
    'totalLicenseCount'
)

#region Helper funkcie pre diff detekciu

function ConvertTo-CanonicalObject {
    <#
    .SYNOPSIS
        Rekurzivne normalizuje objekt pre stabilne porovnanie.
    .DESCRIPTION
        Zoradi kluce abecedne a odstrani volatile properties definovane v $script:VolatileProps.
        Vystup je vhodny pre JSON serializaciu a string compare bez false positives.
    #>
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    # Arrays (IList ale nie string)
    if (($InputObject -is [array]) -or
        (($InputObject -is [System.Collections.IList]) -and ($InputObject -isnot [string]))) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $list.Add((ConvertTo-CanonicalObject -InputObject $item))
        }
        return $list.ToArray()
    }

    # Hashtables a IDictionary
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($k in ($InputObject.Keys | Sort-Object)) {
            if ($k -in $script:VolatileProps) { continue }
            $result[$k] = ConvertTo-CanonicalObject -InputObject $InputObject[$k]
        }
        return $result
    }

    # PSCustomObject
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($prop in ($InputObject.PSObject.Properties | Sort-Object Name)) {
            if ($prop.Name -in $script:VolatileProps) { continue }
            $result[$prop.Name] = ConvertTo-CanonicalObject -InputObject $prop.Value
        }
        return $result
    }

    # Scalar (string, number, bool, DateTime, ...)
    return $InputObject
}

function Get-ChangedTopLevelProps {
    <#
    .SYNOPSIS
        Vrati zoznam top-level properties ktore sa lisia medzi dvoma kanonickymi objektami.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$OldCanonical,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$NewCanonical
    )

    $changed = [System.Collections.Generic.List[string]]::new()
    $allKeys = @($OldCanonical.Keys) + @($NewCanonical.Keys) | Select-Object -Unique

    foreach ($key in $allKeys) {
        $hasOld = $OldCanonical.Contains($key)
        $hasNew = $NewCanonical.Contains($key)

        # Property pribudla alebo zmizla
        if ($hasOld -xor $hasNew) {
            $changed.Add($key)
            continue
        }

        # Obe existuju - porovnaj hodnoty cez serializaciu
        $oldJson = $OldCanonical[$key] | ConvertTo-Json -Depth 20 -Compress
        $newJson = $NewCanonical[$key] | ConvertTo-Json -Depth 20 -Compress

        if ($oldJson -ne $newJson) {
            $changed.Add($key)
        }
    }

    return $changed.ToArray()
}

#endregion

# --- Start ---
Write-CustomLog @script:LogParams `
    -Message "=== Start exportu Intune aplikacii. BackupRoot: $BackupRoot ===" `
    -Type Information

# --- Pripojenie na Microsoft Graph ---
$requiredScopes = @('DeviceManagementApps.Read.All')
try {
    $ctx = Get-MgContext
    $missingScopes = $requiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }

    if (-not $ctx -or $missingScopes) {
        Write-CustomLog @script:LogParams `
            -Message 'Graph session nenajdeny alebo chybajuce scopes, spustam Connect-MgGraph' `
            -Type Information
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome | Out-Null
        $ctx = Get-MgContext
    }

    Write-CustomLog @script:LogParams `
        -Message "Pripojene na Graph ako $($ctx.Account), tenant $($ctx.TenantId)" `
        -Type Information
}
catch {
    Write-CustomLog @script:LogParams -Message "Graph connect zlyhal: $_" -Type Error
    throw
}

# --- Overenie backup root adresara ---
if (-not (Test-Path $BackupRoot)) {
    try {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        Write-CustomLog @script:LogParams `
            -Message "Vytvoreny backup root: $BackupRoot" `
            -Type Information
    }
    catch {
        Write-CustomLog @script:LogParams `
            -Message "Backup root nie je dostupny: $BackupRoot. $_" `
            -Type Error
        throw
    }
}

# --- Stiahnutie vsetkych mobilnych aplikacii s paginaciou ---
$allApps = [System.Collections.Generic.List[object]]::new()
$uri = 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps'

try {
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        foreach ($item in $response.value) {
            $allApps.Add($item)
        }
        $uri = $response.'@odata.nextLink'
    } while ($uri)

    Write-CustomLog @script:LogParams `
        -Message "Stiahnutych $($allApps.Count) aplikacii z Graph API" `
        -Type Information
}
catch {
    Write-CustomLog @script:LogParams -Message "Chyba pri citani mobileApps: $_" -Type Error
    throw
}

# --- Export s diff detekciou ---
$new = [System.Collections.Generic.List[object]]::new()
$modified = [System.Collections.Generic.List[object]]::new()
$unchanged = 0
$skipped = 0
$errors = 0

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($app in $allApps) {
    try {
        $id = $app.id
        $odataRaw = $app.'@odata.type'

        if ([string]::IsNullOrWhiteSpace($odataRaw)) {
            Write-CustomLog @script:LogParams `
                -Message "App $id ($($app.displayName)) nema @odata.type, preskakujem" `
                -Type Warning
            $skipped++
            continue
        }

        $type = $odataRaw -replace '^#microsoft\.graph\.', ''
        $folder = Join-Path -Path $BackupRoot -ChildPath $type

        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }

        $filePath = Join-Path -Path $folder -ChildPath "$id.json"

        # --- Pripad 1: Nova aplikacia ---
        if (-not (Test-Path $filePath)) {
            $json = $app | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)

            $new.Add([pscustomobject]@{
                    Id          = $id
                    DisplayName = $app.displayName
                    Type        = $type
                    Publisher   = $app.publisher
                })

            Write-CustomLog @script:LogParams `
                -Message "NOVA: [$type] $($app.displayName) (Publisher: $($app.publisher))" `
                -Type Information

            Write-Verbose "NEW: [$type] $($app.displayName)"
            continue
        }

        # --- Pripad 2: Existujuca - porovnaj ---
        $oldRawJson = [System.IO.File]::ReadAllText($filePath, $utf8NoBom)
        $oldApp = $oldRawJson | ConvertFrom-Json
        $oldCanonical = ConvertTo-CanonicalObject -InputObject $oldApp
        $newCanonical = ConvertTo-CanonicalObject -InputObject $app

        $oldCanonicalJson = $oldCanonical | ConvertTo-Json -Depth 20 -Compress
        $newCanonicalJson = $newCanonical | ConvertTo-Json -Depth 20 -Compress

        if ($oldCanonicalJson -eq $newCanonicalJson) {
            # Bez meaningful zmeny - subor nechavam tak ako je (zachovava mtime)
            $unchanged++
            Write-Verbose "UNCHANGED: [$type] $($app.displayName)"
            continue
        }

        # --- Pripad 3: Zmenena ---
        $changedProps = Get-ChangedTopLevelProps `
            -OldCanonical $oldCanonical -NewCanonical $newCanonical

        $json = $app | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)

        $modified.Add([pscustomobject]@{
                Id                = $id
                DisplayName       = $app.displayName
                Type              = $type
                ChangedProperties = $changedProps
            })

        Write-CustomLog @script:LogParams `
            -Message "ZMENENA: [$type] $($app.displayName) | zmenene: $($changedProps -join ', ')" `
            -Type Information

        Write-Verbose "MODIFIED: [$type] $($app.displayName) - $($changedProps -join ', ')"
    }
    catch {
        Write-CustomLog @script:LogParams `
            -Message "Chyba pri spracovani app $($app.id) ($($app.displayName)): $_" `
            -Type Error
        $errors++
    }
}

# --- Sumar ---
$summary = "=== Koniec exportu === Total: $($allApps.Count), Nove: $($new.Count), Zmenene: $($modified.Count), Nezmenene: $unchanged, Preskakane: $skipped, Chyby: $errors"
Write-CustomLog @script:LogParams -Message $summary -Type Information

[pscustomobject]@{
    BackupRoot   = $BackupRoot
    Tenant       = $ctx.TenantId
    Total        = $allApps.Count
    New          = $new.Count
    Modified     = $modified.Count
    Unchanged    = $unchanged
    Skipped      = $skipped
    Errors       = $errors
    NewApps      = $new.ToArray()
    ModifiedApps = $modified.ToArray()
    CompletedAt  = Get-Date
}