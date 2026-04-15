<#
.SYNOPSIS
    Detekcia modulu LogHelper
.DESCRIPTION
    Overi, ci je modul LogHelper uz nacitany. Ak nie, importuje ho z pevnej cesty.
.AUTHOR
    Marek Findrik
.CREATED
    2025-09-04
.VERSION
    2.1.0
.NOTES
    Modul sa importuje len ak este nie je nacitany.
    Pridane robustnejsie kontroly a detailne ladice logy pre version.txt.
#>

$ExpectedVersion = "2.1.0"
$RegPath64 = "HKLM:\SOFTWARE\TaurisIT\LogHelper"
$RegPath32 = "HKLM:\SOFTWARE\WOW6432Node\TaurisIT\LogHelper"

function Get-LogHelperVersion {
    param([string]$Path)
    try {
        if (Test-Path $Path) {
            $prop = Get-ItemProperty -Path $Path -Name "Version" -ErrorAction Stop
            $v = $prop.Version
            if ([string]::IsNullOrWhiteSpace($v)) { return $null }
            return $v.Trim()
        }
        return $null
    }
    catch { return $null }
}

# Skúšame 64-bit vetvu
$InstalledVersion = Get-LogHelperVersion -Path $RegPath64

# Ak nenájdené, skúšame 32-bit vetvu
if (-not $InstalledVersion) {
    $InstalledVersion = Get-LogHelperVersion -Path $RegPath32
}

if ($InstalledVersion -eq $ExpectedVersion) {
    Write-Output "USPECH: Verzia $InstalledVersion je správna."
    exit 0
}
elseif ($InstalledVersion) {
    Write-Output "CHYBA: Nesprávna verzia: $InstalledVersion, očakávaná: $ExpectedVersion"
    exit 1
}
else {
    Write-Output "CHYBA: Modul LogHelper nie je nainštalovaný alebo verzia nie je v registry."
    exit 1
}
