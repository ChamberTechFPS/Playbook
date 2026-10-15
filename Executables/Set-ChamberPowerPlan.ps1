#Requires -Version 5.1
<#
Chamber - power plan (phase 1)

Builds the Chamber scheme (11111111-1111-1111-1111-111111111111) and makes it
active. The base scheme and the values written on top of it depend on the
hardware, because one plan cannot be right for all of it:

  Desktop               Ultimate Performance base. Core parking off, processor
                        min/max 100%, USB selective suspend and PCIe ASPM off on
                        AC and DC (a desktop has no DC).

  Dual-CCD Ryzen X3D    Balanced base, processor and core-parking values left at
  (7900X3D / 7950X3D /  Balanced's own. AMD's 3D V-Cache driver steers games to
  9900X3D / 9950X3D)    the cache CCD by *parking* the other one, and it only
                        works on Balanced. Ultimate Performance, or forcing core
                        parking to 100%, keeps both CCDs awake and lets game
                        threads land on the CCD without the cache - the exact
                        opposite of what these parts are bought for. USB and PCIe
                        latency values still apply; they do not touch parking.

  Laptop                Balanced base, the desktop performance values on AC only.
                        DC (battery) keeps Balanced's own values, so battery life
                        and thermals on the move are what Windows ships.

Every value goes through powercfg /setacvalueindex and /setdcvalueindex against
the Chamber scheme itself. The previous version wrote DefaultPowerSchemeValues
in the registry, which Windows only reads when a scheme is created or the
defaults are restored, so those writes never reached the active plan.

Re-runnable: an existing Chamber scheme is deleted and rebuilt, so an in-place
upgrade picks up the correct base for the hardware rather than keeping whatever
an earlier Chamber version created. Restore-Chamber.ps1 removes the scheme by
the same GUID.

Exit codes: 0 applied; 1 no base scheme could be duplicated (nothing changed).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ChamberGuid     = '11111111-1111-1111-1111-111111111111'
$UltimateGuid    = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGuid    = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BalancedGuid    = '381b4222-f694-41f0-9685-ff5bb260df2e'

$SubProcessor    = '54533251-82be-4824-96c1-47b60b740d00'
$ProcMinState    = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$ProcMaxState    = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$CoreParkMin     = '0cc5b647-c1df-4637-891a-dec35c318583'
$SubUsb          = '2a737441-1930-4402-8d77-b2bebba308a3'
$UsbSuspend      = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$SubPcie         = '501a4d13-42af-4429-9fd1-a8218c268e20'
$PcieAspm        = 'ee12f906-d277-404b-b6da-e5fa1a576df5'

function Write-Step {
    param([string]$Message)
    Write-Host "[Chamber power] $Message"
}

function Invoke-PowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Windows PowerShell 5.1 turns a native tool's stderr into a terminating
    # error under 'Stop', which would bypass the exit-code check below with a
    # raw NativeCommandError. Judge powercfg by its exit code instead.
    $ErrorActionPreference = 'Continue'
    $out = @(& powercfg.exe @Arguments 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed ($LASTEXITCODE): $($out -join ' ')"
    }
    return $out
}

function Test-IsLaptop {
    # PCSystemType 2 = Mobile. Chassis types cover machines whose firmware leaves
    # PCSystemType generic. A battery on its own is not enough - a USB UPS can
    # show up as Win32_Battery on a desktop.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.PCSystemType -eq 2) { return $true }
    $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $chassis = @(Get-CimInstance -ClassName Win32_SystemEnclosure | ForEach-Object { $_.ChassisTypes })
    return [bool]($chassis | Where-Object { $portable -contains [int]$_ })
}

function Test-IsDualCcdX3d {
    # Every dual-CCD X3D part to date has more than 8 cores; every single-CCD one
    # (5800X3D, 7800X3D, 9800X3D, 5700X3D) has 8 or fewer, and does not need
    # parking to steer games.
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    return ($cpu.Name -match 'X3D' -and $cpu.NumberOfCores -gt 8)
}

function Set-SchemeValue {
    param(
        [string]$SubGroup,
        [string]$Setting,
        [int]$Value,
        [switch]$AcOnly
    )
    Invoke-PowerCfg @('/setacvalueindex', $ChamberGuid, $SubGroup, $Setting, "$Value") | Out-Null
    if (-not $AcOnly) {
        Invoke-PowerCfg @('/setdcvalueindex', $ChamberGuid, $SubGroup, $Setting, "$Value") | Out-Null
    }
}

$isLaptop = Test-IsLaptop
$isX3d    = Test-IsDualCcdX3d
$hwProfile  = if ($isX3d) { 'dual-CCD X3D' } elseif ($isLaptop) { 'laptop' } else { 'desktop' }
Write-Step "Hardware profile: $hwProfile"

# Base order. Ultimate Performance is hidden on some OEM and Modern Standby
# images, so desktops fall back to High Performance, then Balanced. The fallback
# is logged, not silent.
$bases = if ($isX3d -or $isLaptop) { @($BalancedGuid) } else { @($UltimateGuid, $HighPerfGuid, $BalancedGuid) }

# Rebuild from scratch. The active scheme cannot be deleted, so step off it first.
$existing = (& powercfg.exe /list 2>&1) -join "`n"
if ($existing -match [regex]::Escape($ChamberGuid)) {
    Invoke-PowerCfg @('/setactive', $BalancedGuid) | Out-Null
    Invoke-PowerCfg @('-delete', $ChamberGuid) | Out-Null
    Write-Step 'Removed the previous Chamber scheme'
}

$base = $null
foreach ($candidate in $bases) {
    try {
        Invoke-PowerCfg @('-duplicatescheme', $candidate, $ChamberGuid) | Out-Null
        $base = $candidate
        break
    } catch {
        Write-Step "Base scheme $candidate is not available here - trying the next one"
    }
}
if (-not $base) {
    Write-Step 'ERROR: no base power scheme could be duplicated. Power plan left unchanged.'
    exit 1
}

$baseName = switch ($base) {
    $UltimateGuid { 'Ultimate Performance' }
    $HighPerfGuid { 'High Performance' }
    default       { 'Balanced' }
}
Invoke-PowerCfg @('-changename', $ChamberGuid, 'Chamber', "Chamber gaming plan ($hwProfile, based on $baseName)") | Out-Null

# Latency values every profile gets. A USB device waking from selective suspend
# (mouse, keyboard, headset DAC) and a PCIe link climbing out of ASPM L1 both add
# wake latency to the input and render path.
Set-SchemeValue -SubGroup $SubUsb  -Setting $UsbSuspend -Value 0 -AcOnly:$isLaptop
Set-SchemeValue -SubGroup $SubPcie -Setting $PcieAspm   -Value 0 -AcOnly:$isLaptop

# Processor values. Skipped on dual-CCD X3D so Balanced's parking stays intact.
if (-not $isX3d) {
    Set-SchemeValue -SubGroup $SubProcessor -Setting $ProcMinState -Value 100 -AcOnly:$isLaptop
    Set-SchemeValue -SubGroup $SubProcessor -Setting $ProcMaxState -Value 100 -AcOnly:$isLaptop
    Set-SchemeValue -SubGroup $SubProcessor -Setting $CoreParkMin  -Value 100 -AcOnly:$isLaptop
}

Invoke-PowerCfg @('/setactive', $ChamberGuid) | Out-Null

# Idle timeouts. Plugged in, nothing sleeps or spins down mid-session. On
# battery a laptop keeps Balanced's timeouts.
Invoke-PowerCfg @('-change', '-monitor-timeout-ac', '0') | Out-Null
Invoke-PowerCfg @('-change', '-standby-timeout-ac', '0') | Out-Null
Invoke-PowerCfg @('-change', '-disk-timeout-ac', '0') | Out-Null
if (-not $isLaptop) {
    Invoke-PowerCfg @('-change', '-disk-timeout-dc', '0') | Out-Null
}

# Hibernation. Off on desktops, which also ends Fast Startup and its half-booted
# driver state. Laptops keep the hiberfile because the critical-battery action
# is hibernate - without it a flat battery is a hard power-off - so on a laptop
# only Fast Startup is turned off.
if ($isLaptop) {
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name 'HiberbootEnabled' -Value 0 -Type DWord
    Write-Step 'Laptop: hibernation kept for critical battery; Fast Startup turned off'
} else {
    # Some desktops have no hibernate support at all; the plan is already active
    # by now, so report it rather than failing the whole step.
    try {
        Invoke-PowerCfg @('-h', 'off') | Out-Null
    } catch {
        Write-Step "Hibernation could not be turned off: $($_.Exception.Message)"
    }
}

Write-Step "Chamber scheme active ($hwProfile, based on $baseName)"
exit 0
