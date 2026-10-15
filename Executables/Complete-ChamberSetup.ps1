#Requires -Version 5.1
<#
Chamber - finish setup after the first sign-in.

Why this exists. On an injected install, Chamber runs during the OOBE, before
the person who will use the PC has an account. Three things go wrong there,
all seen on the first real ISO test (26300, 2026-10-07):

  1. AME writes HKCU values into the Default profile, and Windows then applies
     its own theme, visual-effects and taskbar defaults at the first sign-in -
     overwriting dark mode, UserPreferencesMask, MinAnimate and the search box.
  2. `runas: currentUserElevated` resolves to SYSTEM during the OOBE, so the
     scripts that write HKCU themselves (windowed-game optimizations, the
     classic context menu) configured SYSTEM, not the user.
  3. Windows re-enables some HKLM telemetry settings (Diagtrack-Listener) and
     scheduled tasks (PcaPatchDbTask) after the OOBE run.

Everything re-applied here comes from PostInstall\Verify\verification-manifest.json,
the same file Verify and Restore read, filtered by the options recorded in the
deployment receipt. This script carries no list of its own, so it cannot drift
from what the task files set.

Modes:
  -Mode User      Per user, not elevated. Run once per user per Chamber run by
                  C:\ChamberTech\Show-ChamberWelcome.cmd (All Users Startup),
                  before the welcome page opens. Re-applies HKCU values, the
                  windowed-game and classic-menu settings, and OLED taskbar
                  auto-hide when that option was selected.
  -Mode Machine   Elevated, as SYSTEM, from the one-shot "Chamber Setup
                  Completion" scheduled task. Re-applies HKLM values and
                  scheduled-task states, then deletes its own task.
  -Mode Schedule  Registers that task. Called from 10-finalize, `oobe: only`.

-WhatIf lists what would change and writes nothing.

Always exits 0: this is a repair pass, and a failure must never block sign-in.
Every action and failure is logged.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('User', 'Machine', 'Schedule')]
    [string]$Mode,
    [string]$ManifestPath = 'C:\ChamberTech\PostInstall\Verify\verification-manifest.json',
    [string]$ReceiptPath  = 'C:\ChamberTech\deployment-receipt.json',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SetupDir = 'C:\ChamberTech\Setup'
$TaskName = 'Chamber Setup Completion'
$ClassicMenuKey = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'

$logDir = if ($Mode -eq 'User') { Join-Path $env:LOCALAPPDATA 'ChamberTech' } else { Join-Path $env:ProgramData 'ChamberPostInstall\logs' }
$logFile = Join-Path $logDir "setup-completion-$($Mode.ToLowerInvariant()).log"
$counts = @{ Applied = 0; Unchanged = 0; Failed = 0 }

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format o)] $Message"
    Write-Host $line
    if ($WhatIf) { return }
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

# --- Manifest and selected options ------------------------------------------

function Get-SelectedOptions {
    if (-not (Test-Path -LiteralPath $ReceiptPath)) {
        Write-Log "No receipt at $ReceiptPath - applying only values that no option gates."
        return @()
    }
    try {
        $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
        if ($receipt.PSObject.Properties['selectedOptions'] -and $receipt.selectedOptions) {
            return @($receipt.selectedOptions)
        }
    } catch {
        Write-Log "Could not read the receipt: $($_.Exception.Message)"
    }
    return @()
}

function Test-Applies {
    param($Entry, [string[]]$Selected)
    $opt = if ($Entry.PSObject.Properties['option']) { [string]$Entry.option } else { '' }
    return ([string]::IsNullOrEmpty($opt) -or $Selected -contains $opt)
}

# --- Registry -----------------------------------------------------------------
# .NET rather than the registry provider: it handles the unnamed default value
# and REG_BINARY without special cases, and SetValue is a no-op-safe overwrite.

function Split-RegPath {
    param([string]$Path)
    if ($Path -match '^(HKCU|HKEY_CURRENT_USER)\\(.+)$') { return [Microsoft.Win32.Registry]::CurrentUser, $Matches[2] }
    if ($Path -match '^(HKLM|HKEY_LOCAL_MACHINE)\\(.+)$') { return [Microsoft.Win32.Registry]::LocalMachine, $Matches[2] }
    return $null, $null
}

function ConvertTo-RegData {
    param([string]$Type, [string]$Data)
    switch -Regex ($Type) {
        '^REG_DWORD$' {
            $n = if ($Data -match '^0x') { [Convert]::ToUInt32($Data.Substring(2), 16) } else { [uint32]$Data }
            # SetValue wants Int32 for DWORD; reinterpret so values above 2^31 survive.
            return @{ Data = [BitConverter]::ToInt32([BitConverter]::GetBytes($n), 0); Kind = 'DWord' }
        }
        '^REG_QWORD$' { return @{ Data = [int64]$Data; Kind = 'QWord' } }
        '^REG_BINARY$' {
            # Hex string, as AME's YAML and the manifest carry it - the same form
            # Restore-Chamber.ps1's ConvertFrom-HexString reads.
            $bytes = New-Object byte[] ($Data.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Data.Substring($i * 2, 2), 16) }
            return @{ Data = $bytes; Kind = 'Binary' }
        }
        '^REG_EXPAND_SZ$' { return @{ Data = $Data; Kind = 'ExpandString' } }
        default { return @{ Data = $Data; Kind = 'String' } }
    }
}

function Test-SameData {
    param($Current, $Wanted)
    if ($Current -is [byte[]] -and $Wanted -is [byte[]]) { return (($Current -join ',') -eq ($Wanted -join ',')) }
    return ([string]$Current -eq [string]$Wanted)
}

function Set-ManifestValue {
    param($Entry)
    $label = "$($Entry.path)\$($Entry.value)"
    try {
        $hive, $sub = Split-RegPath $Entry.path
        if ($null -eq $hive) { Write-Log "SKIP   $label (unsupported hive)"; return }
        $converted = ConvertTo-RegData -Type $Entry.type -Data ([string]$Entry.data)
        $data = $converted.Data
        $kind = [Microsoft.Win32.RegistryValueKind]$converted.Kind

        $key = $hive.OpenSubKey($sub, $false)
        $current = if ($key) { $key.GetValue($Entry.value, $null, 'DoNotExpandEnvironmentNames') } else { $null }
        if ($key) { $key.Close() }
        if ($null -ne $current -and (Test-SameData $current $data)) { $counts.Unchanged++; return }

        if ($WhatIf) { Write-Log "WOULD SET $label = $($Entry.data)"; $counts.Applied++; return }
        $key = $hive.CreateSubKey($sub)
        $key.SetValue([string]$Entry.value, $data, $kind)
        $key.Close()
        Write-Log "SET    $label = $($Entry.data)"
        $counts.Applied++
    } catch {
        Write-Log "FAILED $label : $($_.Exception.Message)"
        $counts.Failed++
    }
}

function Remove-ManifestValue {
    param($Entry)
    $label = "$($Entry.path)\$($Entry.value)"
    try {
        $hive, $sub = Split-RegPath $Entry.path
        if ($null -eq $hive) { return }
        $key = $hive.OpenSubKey($sub, (-not $WhatIf))
        if ($null -eq $key) { return }
        try {
            if ($null -eq $key.GetValue($Entry.value)) { return }
            if ($WhatIf) { Write-Log "WOULD DELETE $label"; $counts.Applied++; return }
            $key.DeleteValue([string]$Entry.value, $false)
            Write-Log "DELETE $label"
            $counts.Applied++
        } finally { $key.Close() }
    } catch {
        Write-Log "FAILED delete $label : $($_.Exception.Message)"
        $counts.Failed++
    }
}

function Invoke-RegistryPass {
    param($Manifest, [string[]]$Selected, [string]$HivePrefix)
    foreach ($e in @($Manifest.registryValues)) {
        if ($e.path -like "$HivePrefix\*" -and (Test-Applies $e $Selected)) { Set-ManifestValue $e }
    }
    foreach ($e in @($Manifest.registryDeletes)) {
        if ($e.path -like "$HivePrefix\*") { Remove-ManifestValue $e }
    }
}

# --- Mode: Schedule ---------------------------------------------------------

if ($Mode -eq 'Schedule') {
    try {
        $script = Join-Path $SetupDir 'Complete-ChamberSetup.ps1'
        if (-not (Test-Path -LiteralPath $script)) { throw "$script is missing - Install-PostInstallCompanion.ps1 must run first." }
        if ($WhatIf) { Write-Log "WOULD REGISTER scheduled task '$TaskName' -> $script -Mode Machine"; exit 0 }
        $action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode Machine"
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'Re-applies Chamber settings Windows resets after setup, once, then removes itself.' -Force | Out-Null
        Write-Log "Registered scheduled task '$TaskName'."
    } catch {
        Write-Log "FAILED to register '$TaskName': $($_.Exception.Message)"
    }
    exit 0
}

# --- Modes: User / Machine ----------------------------------------------------

Write-Log "Chamber setup completion ($Mode) started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)$(if ($WhatIf) { ' [WhatIf]' })."

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Log "Manifest not found at $ManifestPath - nothing to re-apply."
    exit 0
}
try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
} catch {
    Write-Log "Could not read the manifest: $($_.Exception.Message)"
    exit 0
}
$selected = Get-SelectedOptions
Write-Log "Selected options: $(if ($selected) { $selected -join ', ' } else { '(none recorded)' })"

if ($Mode -eq 'User') {
    Invoke-RegistryPass -Manifest $manifest -Selected $selected -HivePrefix 'HKCU'

    # Classic context menu - an empty default value on this CLSID key. Set by a
    # reg.exe !cmd in 8-configure-windows, which the manifest does not model.
    Set-ManifestValue ([pscustomobject]@{ path = "HKCU\$ClassicMenuKey"; value = ''; type = 'REG_SZ'; data = '' })

    foreach ($helper in @(
        @{ File = 'Enable-WindowedGameOptimizations.ps1'; Option = '' }
        @{ File = 'Enable-OledSafety.ps1';                Option = 'oled-safety' }
    )) {
        if ($helper.Option -and $selected -notcontains $helper.Option) { continue }
        $path = Join-Path $SetupDir $helper.File
        if (-not (Test-Path -LiteralPath $path)) { Write-Log "SKIP   $($helper.File) (not found in $SetupDir)"; continue }
        if ($WhatIf) { Write-Log "WOULD RUN $($helper.File)"; continue }
        # The OLED helper needs the taskbar window; at Startup-folder time
        # Explorer can still be settling, so give it a few tries.
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $path | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Start-Sleep -Seconds 5 }
        }
        if ($ok) { Write-Log "RAN    $($helper.File)"; $counts.Applied++ }
        else { Write-Log "FAILED $($helper.File) (exit $LASTEXITCODE)"; $counts.Failed++ }
    }

    if (-not $WhatIf) {
        # Apply what can be applied without signing out: Control Panel\Desktop
        # (visual effects) and the light/dark theme. The rest lands at the next
        # restart, which the welcome page's first step asks for anyway.
        try {
            & "$env:SystemRoot\System32\rundll32.exe" user32.dll,UpdatePerUserSystemParameters 1, True
            Add-Type -Namespace ChamberSetup -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
            $result = [UIntPtr]::Zero
            foreach ($area in @('ImmersiveColorSet', 'WindowsThemeElement')) {
                [void][ChamberSetup.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, $area, 2, 2000, [ref]$result)
            }
        } catch {
            Write-Log "Could not broadcast the settings change: $($_.Exception.Message)"
        }
    }
}

if ($Mode -eq 'Machine') {
    Invoke-RegistryPass -Manifest $manifest -Selected $selected -HivePrefix 'HKLM'

    foreach ($t in @($manifest.scheduledTasks)) {
        if (-not (Test-Applies $t $selected)) { continue }
        $taskPath = ($t.path -replace '[^\\]+$', '')
        $name     = ($t.path -replace '^.*\\', '')
        try {
            $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction SilentlyContinue
            if ($null -eq $task) { continue }
            $wantDisabled = ($t.state -eq 'disable')
            $isDisabled   = ($task.State -eq 'Disabled')
            if ($wantDisabled -eq $isDisabled) { $counts.Unchanged++; continue }
            if ($WhatIf) { Write-Log "WOULD $($t.state.ToUpperInvariant()) task $($t.path)"; $counts.Applied++; continue }
            if ($wantDisabled) { Disable-ScheduledTask -TaskPath $taskPath -TaskName $name | Out-Null }
            else { Enable-ScheduledTask -TaskPath $taskPath -TaskName $name | Out-Null }
            Write-Log "TASK   $($t.path) -> $($t.state)"
            $counts.Applied++
        } catch {
            Write-Log "FAILED task $($t.path): $($_.Exception.Message)"
            $counts.Failed++
        }
    }

    if (-not $WhatIf) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed scheduled task '$TaskName'."
        } catch {
            Write-Log "Could not remove scheduled task '$TaskName': $($_.Exception.Message)"
        }
    }
}

Write-Log "Done: $($counts.Applied) applied, $($counts.Unchanged) already correct, $($counts.Failed) failed."
exit 0
