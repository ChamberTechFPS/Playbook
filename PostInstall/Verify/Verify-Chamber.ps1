#Requires -Version 5.1
<#
Chamber - Verify System (standalone, read-only)

Checks every tweak the playbook applies against actual system state, using
Verify\verification-manifest.json (generated from the playbook YAML by
tools/generate_verification_manifest.py), plus hardware checks the playbook
can't control (Secure Boot, VBS, HAGS, MSI mode), plus the Chamber deployment
receipt at C:\ChamberTech\deployment-receipt.json when one exists - that is what
separates "this option was never selected" from "it was selected and failed".

Makes zero changes. Params:
  -Detailed      Show every individual check, not just problems
  -ClientReport  Zip results + system info onto the Desktop for support
#>
[CmdletBinding()]
param(
    [switch]$Detailed,
    [switch]$ClientReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Inline helpers (no dependencies) --------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '  This script needs Administrator. Right-click START-HERE.bat > Run as administrator.' -ForegroundColor Red
    Write-Host ''
    exit 2
}

function Write-Result {
    param([string]$Status, [string]$Label, [string]$Detail = '')
    $color = switch ($Status) {
        'PASS'     { 'Green' }
        'FAIL'     { 'Red' }
        'WARN'     { 'Yellow' }
        'DISABLED' { 'DarkGray' }
        default    { 'Cyan' }
    }
    Write-Host ("  [{0,-8}] {1}" -f $Status, $Label) -ForegroundColor $color
    if ($Detail) { Write-Host ("             {0}" -f $Detail) -ForegroundColor DarkGray }
}

$checks = [System.Collections.Generic.List[hashtable]]::new()
function Add-Check {
    param([string]$Status, [string]$Category, [string]$Label, [string]$Detail = '')
    $checks.Add(@{ Status = $Status; Category = $Category; Label = $Label; Detail = $Detail })
}

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkMagenta
Write-Host '  CHAMBERTECH PLAYBOOK - CHECK YOUR PC' -ForegroundColor Magenta
Write-Host ('=' * 60) -ForegroundColor DarkMagenta
Write-Host '  Read-only. No changes will be made.' -ForegroundColor DarkGray
Write-Host ''

# --- Load manifest ----------------------------------------------------------
$manifestPath = Join-Path $PSScriptRoot 'verification-manifest.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Write-Host "  Manifest generated: $($manifest.generatedUtc)" -ForegroundColor DarkGray
        Write-Host ''
    } catch {
        Add-Check 'WARN' 'Manifest' 'Manifest load' "Could not parse manifest: $($_.Exception.Message)"
    }
} else {
    Add-Check 'WARN' 'Manifest' 'Manifest load' 'verification-manifest.json missing - hardware checks only'
}

function ConvertTo-PsRegPath {
    param([string]$AmePath)
    return ($AmePath -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' `
                     -replace '^HKCR\\', 'Registry::HKEY_CLASSES_ROOT\' -replace '^HKU\\', 'Registry::HKEY_USERS\')
}

# --- Registry ---------------------------------------------------------------
if ($manifest) {
    $regFail = 0; $regPass = 0; $optSkipped = 0
    foreach ($entry in $manifest.registryValues) {
        $isOptional = [bool]($entry.PSObject.Properties.Name -contains 'option')
        $psPath = ConvertTo-PsRegPath $entry.path
        $actual = '<not set>'
        $match = $false
        try {
            $item = Get-ItemProperty -LiteralPath $psPath -Name $entry.value -ErrorAction Stop
            $raw = $item.($entry.value)
            $actual = if ($raw -is [byte[]]) { ($raw | ForEach-Object { '{0:X2}' -f $_ }) -join '' } else { [string]$raw }
            if ($entry.type -eq 'REG_BINARY') {
                # The manifest carries AME's hex string; compare hex to hex.
                $match = ($actual -ieq [string]$entry.data)
            } elseif ($entry.type -match 'REG_DWORD|REG_QWORD') {
                $match = ($actual -eq [string]([int64]$entry.data))
                # NtfsDisableLastAccessUpdate is a bitmask: bit 0 = last-access
                # disabled, bit 31 (0x80000000) = system-managed. Windows owns the
                # managed bit and stamps large-volume SSDs system-managed (0x80000001)
                # even after 'fsutil ... disablelastaccess 1'. Only the low bit is our
                # goal, so compare that and ignore the managed flag.
                if (-not $match -and $entry.value -eq 'NtfsDisableLastAccessUpdate') {
                    $match = (([int64]$actual -band 1) -eq ([int64]$entry.data -band 1))
                }
            } else {
                $match = ($actual -eq [string]$entry.data)
            }
        } catch { }
        $label = "$($entry.path)\$($entry.value)"
        if ($match) {
            $regPass++
            if ($Detailed) { Add-Check 'PASS' 'Registry' $label "= $($entry.data)" }
        } elseif ($isOptional) {
            $optSkipped++
            if ($Detailed) { Add-Check 'INFO' 'Registry' $label "optional [$($entry.option)] not applied (actual: $actual)" }
        } else {
            $regFail++
            Add-Check 'FAIL' 'Registry' $label "expected $($entry.data) [$($entry.type)], actual: $actual (from $($entry.source))"
        }
    }
    Add-Check ($(if ($regFail -eq 0) { 'PASS' } else { 'FAIL' })) 'Registry' 'Registry tweaks' `
        "$regPass/$(@($manifest.registryValues).Count) applied, $regFail failed, $optSkipped optional not applied"

    # --- Retired values -----------------------------------------------------
    # Tweaks an earlier Chamber set and this version deletes. Still present means
    # the upgrade cleanup did not run. WARN, not FAIL: the machine works, it just
    # carries a value that is either inert or (sihost/RuntimeBroker at Idle
    # priority) worth removing.
    if ($manifest.PSObject.Properties.Name -contains 'registryDeletes') {
        $lingering = @($manifest.registryDeletes | Where-Object {
            $null -ne (Get-ItemProperty -LiteralPath (ConvertTo-PsRegPath $_.path) -Name $_.value -ErrorAction SilentlyContinue)
        })
        if ($lingering.Count -eq 0) {
            if ($Detailed) { Add-Check 'PASS' 'Registry' 'Retired tweaks' "all $(@($manifest.registryDeletes).Count) removed" }
        } else {
            Add-Check 'WARN' 'Registry' 'Retired tweaks' `
                "$($lingering.Count) left from an earlier Chamber: $(@($lingering | ForEach-Object { $_.value }) -join ', '). Re-run the playbook to clean up."
        }
    }

    # --- Scheduled tasks ----------------------------------------------------
    if ($manifest.PSObject.Properties.Name -contains 'scheduledTasks') {
        $taskFail = 0; $taskPass = 0; $taskAbsent = 0
        foreach ($t in $manifest.scheduledTasks) {
            $folder = (Split-Path -Path $t.path -Parent).TrimEnd('\') + '\'
            $leaf = Split-Path -Path $t.path -Leaf
            $task = Get-ScheduledTask -TaskPath $folder -TaskName $leaf -ErrorAction SilentlyContinue
            if (-not $task) {
                $taskAbsent++
                if ($Detailed) { Add-Check 'INFO' 'Tasks' $t.path 'not present on this build (not a failure)' }
                continue
            }
            $isDisabled = ($task.State -eq 'Disabled')
            if (($t.state -eq 'disable') -eq $isDisabled) {
                $taskPass++
                if ($Detailed) { Add-Check 'PASS' 'Tasks' $t.path "state = $($task.State)" }
            } else {
                $taskFail++
                Add-Check 'FAIL' 'Tasks' $t.path "expected $($t.state)d, actual $($task.State) (from $($t.source))"
            }
        }
        Add-Check ($(if ($taskFail -eq 0) { 'PASS' } else { 'FAIL' })) 'Tasks' 'Telemetry scheduled tasks' `
            "$taskPass as configured, $taskFail mismatched, $taskAbsent not present on this build"
    }

    # --- Services -----------------------------------------------------------
    $svcFail = 0; $svcPass = 0; $svcOpt = 0
    foreach ($svc in $manifest.services) {
        $isOptional = [bool]($svc.PSObject.Properties.Name -contains 'option')
        $startKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.name)"
        $actual = $null
        if (Test-Path -LiteralPath $startKey) {
            $actual = (Get-ItemProperty -LiteralPath $startKey -Name 'Start' -ErrorAction SilentlyContinue).Start
        }
        if ($null -eq $actual) {
            if ($isOptional) { $svcOpt++; if ($Detailed) { Add-Check 'INFO' 'Services' $svc.name "optional [$($svc.option)] - service not present" } }
            else { Add-Check 'INFO' 'Services' $svc.name 'service not present on this build (not a failure)' }
        } elseif ($actual -eq $svc.startup) {
            $svcPass++
            if ($Detailed) { Add-Check 'PASS' 'Services' $svc.name "startup = $actual" }
        } elseif ($isOptional) {
            $svcOpt++
            if ($Detailed) { Add-Check 'INFO' 'Services' $svc.name "optional [$($svc.option)] not applied (startup = $actual)" }
        } else {
            $svcFail++
            Add-Check 'FAIL' 'Services' $svc.name "expected startup $($svc.startup), actual $actual (from $($svc.source))"
        }
    }
    Add-Check ($(if ($svcFail -eq 0) { 'PASS' } else { 'FAIL' })) 'Services' 'Service startup types' `
        "$svcPass/$(@($manifest.services).Count) as configured, $svcFail mismatched, $svcOpt optional"

    # --- BCD ------------------------------------------------------------
    try {
        $bcdOut = (& bcdedit /enum '{current}' 2>&1) -join "`n"
        foreach ($flag in $manifest.bcd.flags) {
            $pattern = "(?im)^\s*$([regex]::Escape($flag.flag))\s+(\S+)"
            if ($bcdOut -match $pattern) {
                $actual = $Matches[1]
                if ($actual -ieq $flag.expected) { Add-Check 'PASS' 'BCD' $flag.flag "= $actual" }
                else { Add-Check ($(if ($flag.tolerant) { 'WARN' } else { 'FAIL' })) 'BCD' $flag.flag "expected $($flag.expected), actual $actual" }
            } else {
                Add-Check ($(if ($flag.tolerant) { 'WARN' } else { 'FAIL' })) 'BCD' $flag.flag 'not present (unsupported on this hardware?)'
            }
        }
        if ($null -ne $manifest.bcd.timeout) {
            $bootMgr = (& bcdedit /enum '{bootmgr}' 2>&1) -join "`n"
            if ($bootMgr -match '(?im)^\s*timeout\s+(\d+)') {
                $t = [int]$Matches[1]
                Add-Check ($(if ($t -eq $manifest.bcd.timeout) { 'PASS' } else { 'WARN' })) 'BCD' 'Boot timeout' "= $t (expected $($manifest.bcd.timeout))"
            }
        }
    } catch {
        Add-Check 'WARN' 'BCD' 'BCD flags' "Could not run bcdedit: $($_.Exception.Message)"
    }

    # --- Retired hosts entries -----------------------------------------------
    # Older Chamber versions blocked telemetry in the hosts file. 1.4.0 removes
    # those lines (Defender flags them as HostsFileHijack), so they should be gone.
    try {
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $hostsLines = if (Test-Path -LiteralPath $hostsPath) { @(Get-Content -LiteralPath $hostsPath | ForEach-Object { $_.Trim() }) } else { @() }
        $leftover = @($manifest.hostsRetired | Where-Object { $hostsLines -contains $_ })
        if ($leftover.Count -eq 0) { Add-Check 'PASS' 'Privacy' 'Old hosts telemetry blocks' 'none left over from earlier Chamber versions' }
        else { Add-Check 'WARN' 'Privacy' 'Old hosts telemetry blocks' "$($leftover.Count) still present - re-run Chamber or Restore-Chamber.ps1 -Scope hosts -Apply" }
    } catch {
        Add-Check 'WARN' 'Privacy' 'Old hosts telemetry blocks' 'Could not read hosts file'
    }

    # --- Debloat --------------------------------------------------------------
    try {
        $provisionedNames = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
        $leftovers = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $manifest.debloat.balanced) {
            $installed = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
            if ($installed.Count -gt 0 -or ($provisionedNames -contains $name)) { $leftovers.Add($name) }
        }
        if ($leftovers.Count -eq 0) {
            Add-Check 'PASS' 'Debloat' 'Balanced debloat' "all $(@($manifest.debloat.balanced).Count) target packages absent"
        } else {
            $sample = @($leftovers | Select-Object -First 6) -join ', '
            $suffix = if ($leftovers.Count -gt 6) { ", +$($leftovers.Count - 6) more" } else { '' }
            Add-Check 'WARN' 'Debloat' 'Balanced debloat' "$($leftovers.Count) still present: $sample$suffix"
        }
        $xboxPresent = @($manifest.debloat.xbox | Where-Object {
            @(Get-AppxPackage -AllUsers -Name $_ -ErrorAction SilentlyContinue).Count -gt 0
        })
        if ($xboxPresent.Count -gt 0) { Add-Check 'INFO' 'Debloat' 'Xbox packages' "present - expected unless 'Remove Xbox Services' was selected" }
        else { Add-Check 'INFO' 'Debloat' 'Xbox packages' 'removed (Remove Xbox Services was selected)' }
    } catch {
        Add-Check 'WARN' 'Debloat' 'AppX state' 'Could not query AppX package state'
    }
}


# --- Deployment receipt -------------------------------------------------------
# Written by Executables\Write-ChamberReceipt.ps1 during the playbook run. It is
# the only place the *selected* options are recorded.
#
# Why that matters: everything below this point compares the system against what
# the playbook would have done, and an optional setting that is not applied looks
# identical whether the ISO creator never selected it or it was selected and
# failed. Those need opposite answers from support. AME does not hand the
# playbook its own option set, so the receipt is the record.
#
# It is absent on any machine set up before receipts existed, and on a run that
# died before Phase 10. Missing is INFO, never FAIL - the rest of the report is
# still valid without it (FR-035).
$receipt = $null
$receiptPath = 'C:\ChamberTech\deployment-receipt.json'
if (Test-Path -LiteralPath $receiptPath) {
    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    } catch {
        Add-Check 'WARN' 'Deployment' 'Deployment receipt' "Present but unreadable: $($_.Exception.Message)"
    }
} else {
    Add-Check 'INFO' 'Deployment' 'Deployment receipt' 'Not present - options below are reported as applied/not-applied only'
}

if ($receipt) {
    $mode = if ($receipt.installMode) { $receipt.installMode } else { 'Unknown' }
    Add-Check 'INFO' 'Deployment' 'Install mode' $mode
    Add-Check 'INFO' 'Deployment' 'Chamber version' "$($receipt.chamberVersion) (recorded at setup)"

    if ($receipt.completedUtc) {
        Add-Check 'PASS' 'Deployment' 'Chamber run completed' $receipt.completedUtc
    } else {
        # The receipt is opened early in Phase 10 and closed at its end, so an
        # open one means the run stopped partway - the single most useful fact
        # a support report can carry.
        Add-Check 'FAIL' 'Deployment' 'Chamber run completed' 'Receipt was never closed - the playbook did not finish Phase 10'
    }

    $selected = @($receipt.selectedOptions)
    if ($selected.Count -gt 0) {
        Add-Check 'INFO' 'Deployment' 'Selected options' ($selected -join ', ')
    } else {
        Add-Check 'INFO' 'Deployment' 'Selected options' 'none - all optional changes were left off'
    }

    # Browser outcome. 'Installed' from the injected path means a script watched
    # the installer exit and then found the executable; from the winget path it
    # means winget was asked. Confirm against the disk either way rather than
    # taking the receipt's word for it.
    $browserOption = $receipt.browser.option
    $browserResult = $receipt.browser.result
    if (-not $browserResult) {
        Add-Check 'INFO' 'Deployment' 'Browser' 'No browser outcome recorded'
    } else {
        $browserExes = @{
            'browser-chrome' = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                                 "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
            'browser-brave'  = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
                                 "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe")
        }
        $detail = "$browserOption = $browserResult"
        if ($receipt.browser.detail) { $detail += " ($($receipt.browser.detail))" }

        if ($browserResult -eq 'Skipped') {
            Add-Check 'INFO' 'Deployment' 'Browser' $detail
        } elseif ($browserResult -eq 'Failed') {
            Add-Check 'FAIL' 'Deployment' 'Browser' "$detail - Edge is still available"
        } elseif ($browserExes.ContainsKey($browserOption)) {
            $found = @($browserExes[$browserOption] | Where-Object { Test-Path -LiteralPath $_ })
            if ($found.Count -gt 0) { Add-Check 'PASS' 'Deployment' 'Browser' "$detail - $($found[0])" }
            else { Add-Check 'FAIL' 'Deployment' 'Browser' "$detail, but the executable is not on disk" }
        } else {
            Add-Check 'INFO' 'Deployment' 'Browser' $detail
        }
    }
}
# --- Hardware checks ---------------------------------------------------------
try {
    $vbs = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
    switch ($vbs.VirtualizationBasedSecurityStatus) {
        0 { Add-Check 'DISABLED' 'Hardware' 'VBS' 'Disabled - good for performance' }
        1 { Add-Check 'WARN' 'Hardware' 'VBS' 'Enabled but not running - reboot may activate it' }
        default { Add-Check 'INFO' 'Hardware' 'VBS' 'Running - expected unless "Disable VBS/HVCI" was selected' }
    }
} catch { Add-Check 'WARN' 'Hardware' 'VBS' 'Could not query DeviceGuard' }

try {
    if (Confirm-SecureBootUEFI) { Add-Check 'PASS' 'Hardware' 'Secure Boot' 'Enabled - Vanguard/Valorant compatible' }
    else { Add-Check 'WARN' 'Hardware' 'Secure Boot' 'Disabled - Riot Vanguard (Valorant) will NOT work' }
} catch { Add-Check 'INFO' 'Hardware' 'Secure Boot' 'Could not determine (non-UEFI system?)' }

# Reported, never failed. Whether the drive should be encrypted is the owner's
# call, so this states the facts and the consequence rather than grading it. It
# is deliberately next to Secure Boot, because that pairing is the thing people
# get wrong: BitLocker uses the TPM, so it looks anti-cheat-adjacent, and it is
# not. No anti-cheat requires an encrypted drive.
try {
    $sysDrive = $env:SystemDrive
    $mbde = Join-Path $env:SystemRoot 'System32\manage-bde.exe'
    if (Test-Path -LiteralPath $mbde) {
        $bdeOut = (& $mbde -status $sysDrive 2>&1) -join "`n"
        if ($bdeOut -match 'Protection Status:\s*Protection On') {
            Add-Check 'INFO' 'Hardware' 'Drive encryption' `
                "$sysDrive is BitLocker-encrypted. Back up the recovery key before a BIOS update, Secure Boot change or TPM clear - any of those can trigger the 48-digit prompt at boot."
        } elseif ($bdeOut -match 'Conversion Status:\s*(Encryption|Decryption) in Progress') {
            Add-Check 'WARN' 'Hardware' 'Drive encryption' `
                "$sysDrive is mid-conversion. Let it finish before a firmware update or a TPM change."
        } else {
            Add-Check 'INFO' 'Hardware' 'Drive encryption' `
                "$sysDrive is not encrypted - no recovery-key prompt after a BIOS update. Data is readable if the disk is removed."
        }
    }
} catch { Add-Check 'INFO' 'Hardware' 'Drive encryption' 'Could not determine encryption state' }

try {
    $hagsVal = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode
    if ($hagsVal -eq 2) { Add-Check 'PASS' 'Hardware' 'HAGS' 'Enabled (HwSchMode = 2)' }
    elseif ($null -eq $hagsVal) { Add-Check 'WARN' 'Hardware' 'HAGS' 'Key not found - install GPU driver first' }
    else { Add-Check 'FAIL' 'Hardware' 'HAGS' "Not enabled (HwSchMode = $hagsVal)" }
} catch { Add-Check 'WARN' 'Hardware' 'HAGS' 'Could not read registry' }

$msiPropsRelPath = 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
$msiDevices = @()
$msiDevices += @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                 Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'Microsoft|Virtual|Parsec|Remote|IDD' })
$msiDevices += @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
                 Where-Object {
                     $_.Status -eq 'OK' -and
                     $_.FriendlyName -notmatch 'Virtual|WAN|Loopback|Bluetooth|Wi-Fi Direct|Miniport|VPN|TAP|Kernel Debug'
                 })
foreach ($dev in $msiDevices) {
    try {
        $msiKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\$msiPropsRelPath"
        $val = (Get-ItemProperty -LiteralPath $msiKey -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
        if ($val -eq 1) { Add-Check 'PASS' 'Hardware' "MSI [$($dev.FriendlyName)]" 'Enabled' }
        else { Add-Check 'INFO' 'Hardware' "MSI [$($dev.FriendlyName)]" 'Not in MSI mode' }
    } catch { Add-Check 'WARN' 'Hardware' "MSI [$($dev.FriendlyName)]" 'Could not read registry' }
}

try {
    $powerOutput = & powercfg /getactivescheme 2>&1
    if ($powerOutput -match '11111111-1111-1111-1111-111111111111') {
        # Set-ChamberPowerPlan.ps1 builds the scheme on Ultimate Performance for
        # desktops and on Balanced for laptops and dual-CCD X3D parts; either is
        # correct for the hardware. The scheme name says which.
        $planName = if ($powerOutput -match '\((.+)\)') { $Matches[1] } else { 'Chamber' }
        Add-Check 'PASS' 'Power' 'Power Plan' "Chamber plan active ($planName)"
    }
    elseif ($powerOutput -match 'e9a42b02') { Add-Check 'PASS' 'Power' 'Power Plan' 'Ultimate Performance active' }
    else {
        $planName = if ($powerOutput -match '\((.+)\)') { $Matches[1] } else { [string]$powerOutput }
        Add-Check 'WARN' 'Power' 'Power Plan' "Active plan: $planName"
    }
} catch { Add-Check 'WARN' 'Power' 'Power Plan' 'Could not query active scheme' }

try {
    $defenderService = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    if (-not $defenderService) { Add-Check 'DISABLED' 'Security' 'Defender' 'WinDefend service not present' }
    elseif ($defenderService.Status -ne 'Running') { Add-Check 'DISABLED' 'Security' 'Defender' "Service status: $($defenderService.Status)" }
    else { Add-Check 'INFO' 'Security' 'Defender' 'Running' }
} catch { Add-Check 'WARN' 'Security' 'Defender' 'Could not query Defender state' }

# --- Setup checks the playbook cannot make for you ---------------------------
# Hardware- and firmware-specific, so these are reported with the fix rather
# than applied. Each is a common reason a tuned PC still loses frames or latency.

# Monitor running below its fastest mode - the single most common lost-refresh
# problem (a 240 Hz panel left at 60 Hz after a driver install or cable swap).
try {
    Add-Type -Namespace ChamberVerify -Name Display -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
}
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE displayDevice, uint flags);
'@ -ErrorAction Stop
    $ENUM_CURRENT = -1
    $ATTACHED = 0x1
    for ($i = 0; ; $i++) {
        # [NullString]::Value, not $null: PowerShell passes $null to a string
        # parameter as "", and EnumDisplayDevices("") enumerates nothing.
        $dd = New-Object ChamberVerify.Display+DISPLAY_DEVICE
        $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
        if (-not [ChamberVerify.Display]::EnumDisplayDevices([NullString]::Value, [uint32]$i, [ref]$dd, 0)) { break }
        if (($dd.StateFlags -band $ATTACHED) -eq 0) { continue }
        $cur = New-Object ChamberVerify.Display+DEVMODE
        $cur.dmSize = [int16][Runtime.InteropServices.Marshal]::SizeOf($cur)
        if (-not [ChamberVerify.Display]::EnumDisplaySettings($dd.DeviceName, $ENUM_CURRENT, [ref]$cur)) { continue }
        # Fastest mode the panel offers at the resolution it is running now.
        $max = 0
        for ($m = 0; ; $m++) {
            $mode = New-Object ChamberVerify.Display+DEVMODE
            $mode.dmSize = $cur.dmSize
            if (-not [ChamberVerify.Display]::EnumDisplaySettings($dd.DeviceName, $m, [ref]$mode)) { break }
            if ($mode.dmPelsWidth -eq $cur.dmPelsWidth -and $mode.dmPelsHeight -eq $cur.dmPelsHeight -and
                $mode.dmDisplayFrequency -gt $max) { $max = $mode.dmDisplayFrequency }
        }
        $label = "Refresh rate [$($dd.DeviceString) $($cur.dmPelsWidth)x$($cur.dmPelsHeight)]"
        # Windows' fallback driver only offers ~60 Hz modes, so "fastest
        # available" is meaningless until the GPU driver is in.
        if ($dd.DeviceString -match 'Microsoft Basic Display') {
            Add-Check 'INFO' 'Setup' $label `
                "$($cur.dmDisplayFrequency) Hz on Windows' fallback display driver. Install your GPU driver (Drivers folder), then run Verify again to check the refresh rate."
        }
        # 1 Hz of slack: 143.98 / 144 and 59.94 / 60 report as neighbours.
        elseif ($max -gt 0 -and $cur.dmDisplayFrequency -lt ($max - 1)) {
            Add-Check 'WARN' 'Setup' $label `
                "Running $($cur.dmDisplayFrequency) Hz, panel supports $max Hz. Settings > System > Display > Advanced display > Choose a refresh rate."
        } else {
            Add-Check 'PASS' 'Setup' $label "$($cur.dmDisplayFrequency) Hz (fastest available)"
        }
    }
} catch { Add-Check 'INFO' 'Setup' 'Refresh rate' "Could not read display modes: $($_.Exception.Message)" }

# Wired NIC power saving. Energy-Efficient Ethernet and its vendor variants put
# the link to sleep between packets, adding wake latency to every burst - which
# is what game traffic is.
try {
    $eeePattern = 'Energy[- ]Efficient Ethernet|Green Ethernet|Advanced EEE|Power Saving Mode|Gigabit Lite'
    $wired = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' })
    foreach ($nic in $wired) {
        $on = @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -match $eeePattern -and $_.DisplayValue -match '^(On|Enabled)$'
        })
        if ($on.Count -gt 0) {
            $names = @($on | ForEach-Object { $_.DisplayName }) -join ', '
            Add-Check 'WARN' 'Setup' "NIC power saving [$($nic.InterfaceDescription)]" `
                "On: $names. Device Manager > Network adapters > $($nic.InterfaceDescription) > Advanced - set each to Disabled."
        } else {
            Add-Check 'PASS' 'Setup' "NIC power saving [$($nic.InterfaceDescription)]" 'Energy-saving features off'
        }
    }
} catch { Add-Check 'INFO' 'Setup' 'NIC power saving' 'Could not query network adapters' }

# Memory at JEDEC fallback speed - XMP / EXPO not enabled in the BIOS. On
# CPU-bound esports titles this is routinely worth more than every OS tweak here
# combined. ConfiguredClockSpeed is the running MT/s; Speed is the module's rated
# JEDEC speed, which XMP/EXPO kits exceed, so only the common JEDEC ceilings are
# flagged rather than guessing a kit's rating.
try {
    $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
    $running = @($dimms | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $smbiosType = @($dimms | ForEach-Object { [int]$_.SMBIOSMemoryType }) | Select-Object -First 1
    $jedecCeiling = switch ($smbiosType) { 26 { 3200 } 34 { 5600 } default { 0 } }   # 26 = DDR4, 34 = DDR5
    if ($running.Count -gt 0 -and $jedecCeiling -gt 0) {
        $speed = $running[-1]
        $ddr = if ($smbiosType -eq 34) { 'DDR5' } else { 'DDR4' }
        if ($speed -le $jedecCeiling) {
            Add-Check 'WARN' 'Setup' 'Memory speed' `
                "$ddr running at $speed MT/s - JEDEC default. If the kit is rated faster, enable XMP / EXPO in the BIOS."
        } else {
            Add-Check 'PASS' 'Setup' 'Memory speed' "$ddr running at $speed MT/s (XMP / EXPO profile active)"
        }
    }
} catch { Add-Check 'INFO' 'Setup' 'Memory speed' 'Could not read memory modules' }

# Dual-CCD Ryzen X3D: game-to-cache-CCD steering needs AMD's chipset driver (the
# 3D V-Cache Performance Optimizer) as well as Game Mode and the Balanced-based
# Chamber plan. Without the driver, Windows schedules games across both CCDs.
try {
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    if ($cpu.Name -match 'X3D' -and $cpu.NumberOfCores -gt 8) {
        $vcache = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            $_.FriendlyName -match '3D V-Cache Performance Optimizer' -and $_.Status -eq 'OK'
        })
        if ($vcache.Count -gt 0) {
            Add-Check 'PASS' 'Setup' 'AMD 3D V-Cache driver' 'Installed - games are steered to the cache CCD'
        } else {
            Add-Check 'WARN' 'Setup' 'AMD 3D V-Cache driver' `
                'Not found. Install the latest AMD chipset driver (PostInstall\Drivers\Chipset) so games run on the cache CCD.'
        }
    }
} catch { }

# Defender left on is the right default. Exclusions for game libraries and
# shader caches take scanning off the load path without turning protection off.
try {
    $defenderOn = (Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue).Status -eq 'Running'
    if ($defenderOn) {
        $excl = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ })
        if ($excl.Count -eq 0) {
            Add-Check 'INFO' 'Setup' 'Defender game exclusions' `
                'None set. Adding your game library and shader cache folders (Windows Security > Virus & threat protection > Exclusions) cuts load-time scanning without turning Defender off.'
        } else {
            Add-Check 'INFO' 'Setup' 'Defender game exclusions' "$($excl.Count) folder exclusion(s) set"
        }
    }
} catch { }

# Optimizations for windowed games (flip model for DX10/11 borderless).
try {
    # Null-safe on purpose: under StrictMode, reading a property off a missing
    # key throws, which used to land in the catch below and report "could not
    # read" for what is simply "never set for this user".
    $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue
    $dx = if ($item) { [string]$item.DirectXUserGlobalSettings } else { '' }
    if ($dx -match 'SwapEffectUpgradeEnable=1') { Add-Check 'PASS' 'Gaming' 'Windowed game optimizations' 'On (flip model for DX10/11 borderless)' }
    elseif ($dx) { Add-Check 'FAIL' 'Gaming' 'Windowed game optimizations' "Off for this user (DirectXUserGlobalSettings = '$dx')" }
    else { Add-Check 'FAIL' 'Gaming' 'Windowed game optimizations' 'Never set for this user. Sign out and back in to let Chamber finish setup, or turn it on in Settings > System > Display > Graphics.' }
} catch { Add-Check 'WARN' 'Gaming' 'Windowed game optimizations' 'Could not read registry' }

try { Add-Check 'INFO' 'Stats' 'Process Count' "$(@(Get-Process).Count) running processes" } catch { }

# --- Output -------------------------------------------------------------------
Write-Host ''
foreach ($c in $checks) { Write-Result -Status $c.Status -Label $c.Label -Detail $c.Detail }

$failCount = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
Write-Host "  Summary: $(@($checks).Count) checks - $failCount failed, $warnCount warnings" `
    -ForegroundColor $(if ($failCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' })

# --- JSON export + optional client report -------------------------------------
try {
    $logDir = Join-Path $env:ProgramData 'ChamberPostInstall\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $logDir "verify-$stamp.json"

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ver = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $report = [ordered]@{
        timestamp    = (Get-Date).ToString('o')
        computerName = $env:COMPUTERNAME
        os           = [ordered]@{
            caption        = if ($os) { $os.Caption } else { $null }
            build          = if ($ver) { "$($ver.CurrentBuildNumber).$($ver.UBR)" } else { $null }
            displayVersion = if ($ver) { $ver.DisplayVersion } else { $null }
        }
        cpu          = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name)
        gpu          = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        manifestGeneratedUtc = if ($manifest) { $manifest.generatedUtc } else { $null }
        deploymentReceipt    = $receipt
        summary      = [ordered]@{ total = @($checks).Count; failed = $failCount; warnings = $warnCount }
        checks       = $checks
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Host "  Results saved: $jsonPath" -ForegroundColor DarkGray

    if ($ClientReport) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $bundleDir = Join-Path $env:TEMP "ChamberReport-$stamp"
        New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
        Copy-Item -LiteralPath $jsonPath -Destination $bundleDir
        Get-ChildItem -LiteralPath $logDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
            Copy-Item -Destination $bundleDir -ErrorAction SilentlyContinue
        # The receipt is already embedded in the verify JSON above, but it ships
        # as its own file too: it is the first thing support reads, and it should
        # not need digging out of a report with 300 checks in it (FR-035).
        if (Test-Path -LiteralPath $receiptPath) {
            Copy-Item -LiteralPath $receiptPath -Destination $bundleDir -ErrorAction SilentlyContinue
        }
        $zipPath = Join-Path $desktop "ChamberReport-$stamp.zip"
        Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zipPath -Force
        Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host "  Client report created: $zipPath" -ForegroundColor Green
        Write-Host '  Send this zip to ChamberTech support.' -ForegroundColor White
    }
} catch {
    Write-Host "  WARN: Could not write results: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
