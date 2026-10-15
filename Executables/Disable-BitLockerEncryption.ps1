#Requires -Version 5.1
<#
Chamber - turn off BitLocker / device encryption on the system drive.

Runs only when "Turn off BitLocker / device encryption" is selected. The paired
registry value (PreventDeviceEncryption, in 7-security.yml) stops Windows
starting encryption later; this handles a drive where it already started.

Why this exists: Windows 11 24H2+ switches on automatic device encryption during
setup. The TPM seals the key against firmware measurements, so a BIOS update, a
Secure Boot toggle, a TPM clear or a CMOS reset can leave the machine at a
48-digit recovery-key prompt that the owner often cannot answer - the key is in
a Microsoft account they may not know about. On a gaming build that reads as a
dead PC.

No anti-cheat requires an encrypted drive. Vanguard, EAC and BattlEye require
Secure Boot and TPM 2.0; both stay on, and Verify-Chamber checks them.

Uses manage-bde.exe rather than the BitLocker PowerShell module, which is not
present on every Windows 11 edition. Decryption is started, not waited on -
manage-bde returns immediately and Windows decrypts in the background, so this
never stalls a playbook run or an unattended OOBE on a multi-gigabyte volume.

Only the system drive is touched. Other encrypted volumes are reported and left
alone: they may hold data the owner deliberately encrypted, and silently
decrypting someone's data drive is not a decision a gaming playbook should make.

Always exits 0. A drive that stays encrypted is a working PC.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manageBde = Join-Path $env:SystemRoot 'System32\manage-bde.exe'
$systemDrive = $env:SystemDrive   # normally 'C:'

if (-not (Test-Path -LiteralPath $manageBde)) {
    Write-Host "[SKIP] manage-bde.exe not found - this edition has no BitLocker tooling. Nothing to do."
    exit 0
}

function Get-VolumeStatus {
    param([string]$Drive)
    try {
        $raw = & $manageBde -status $Drive 2>&1 | Out-String
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return $raw
}

# --- System drive ---------------------------------------------------------
$status = Get-VolumeStatus -Drive $systemDrive
if (-not $status) {
    Write-Host "[SKIP] Could not read BitLocker status for $systemDrive - nothing to do."
    exit 0
}

# Both matter: 'Protection On' is a finished encryption, and a conversion still
# running is the more urgent case - that is a drive mid-encrypt, which is
# exactly the state a firmware update must not interrupt.
$protectionOn = $status -match 'Protection Status:\s*Protection On'
$converting   = $status -match 'Conversion Status:\s*(Encryption in Progress|Used Space Only Encrypted|Fully Encrypted)'

if (-not $protectionOn -and -not $converting) {
    Write-Host "$systemDrive is not encrypted - nothing to decrypt."
    Write-Host 'Automatic device encryption is prevented by the Chamber registry policy.'
} else {
    Write-Host "Turning off BitLocker on $systemDrive ..."
    try {
        $out = & $manageBde -off $systemDrive 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Decryption started on $systemDrive. Windows continues in the background;"
            Write-Host 'the PC is usable throughout and can be restarted normally.'
            Write-Host "Check progress any time with:  manage-bde -status $systemDrive"
        } else {
            Write-Host "[WARN] manage-bde -off returned $LASTEXITCODE. The drive is still encrypted."
            Write-Host ($out.Trim())
            Write-Host 'Turn it off manually under Settings > Privacy & security > Device encryption.'
        }
    } catch {
        Write-Host "[WARN] Could not start decryption: $($_.Exception.Message)"
    }
}

# --- Other volumes, reported only -----------------------------------------
try {
    $others = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
        Where-Object { $_.DeviceID -ne $systemDrive }
    foreach ($vol in $others) {
        $s = Get-VolumeStatus -Drive $vol.DeviceID
        if ($s -and $s -match 'Protection Status:\s*Protection On') {
            Write-Host "[INFO] $($vol.DeviceID) is also encrypted and was left alone."
            Write-Host "       Decrypt it yourself if you want to:  manage-bde -off $($vol.DeviceID)"
        }
    }
} catch {
    # Reporting only - never worth failing the run over.
}

exit 0
