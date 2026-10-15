#Requires -Version 5.1
<#
Chamber - Restore System

Undoes what the playbook applied, driven by the same
Verify\verification-manifest.json that Verify-Chamber.ps1 reads. The manifest is
generated from the playbook YAML, so this script can never fall out of sync with
what Chamber actually changes - add a tweak to a task file, regenerate, and it
becomes revertible for free.

The manifest records the state Chamber *sets*, not the state it found. There are
two ways to get the original values back:

  1. A snapshot taken before the playbook ran. Exact, and the preferred path.
     Phase 0 of the playbook captures one automatically to
         C:\ProgramData\ChamberPostInstall\logs\chamber-snapshot-preinstall.json
     and restore picks that up on its own - no arguments needed. To capture one
     by hand:
         Restore-Chamber.ps1 -Snapshot
  2. The Windows defaults table in this script. Best effort, used when there is
     no snapshot.

Anything with no snapshot entry and no known default is reported and left alone.
This script never guesses at a value.

Preview is the default. Nothing is written until you pass -Apply.

Params:
  -Snapshot             Capture current state to JSON and exit. Makes no changes.
  -PreInstall           With -Snapshot, write to the canonical pre-install path
                        so restore finds it unaided. This is what phase 0 passes.
  -OutFile <path>       With -Snapshot, write somewhere specific. Defaults to a
                        timestamped file in the log directory.
  -FromSnapshot <path>  Restore captured values instead of the defaults table.
                        Omit to auto-detect the phase 0 pre-install snapshot.
  -NoAutoSnapshot       Ignore the pre-install snapshot; use the defaults table
  -Scope <name>         all (default), services, registry, tasks, bcd, power,
                        hosts, network, debloat, companion
  -Apply                Actually make the changes
  -Force                Skip the confirmation prompt (implies -Apply)
  -NoRestorePoint       Skip creating a System Restore point
  -IncludeHags          Also revert HwSchMode - off by default, see notes below
  -IncludeXbox          Also restore Xbox services and packages

Notes:
  HwSchMode (HAGS) is left alone unless -IncludeHags. 2 is the Windows default on
  current builds, and turning it off disables DLSS 3/4 Frame Generation on RTX
  40/50 cards. Reverting it is almost never what someone wants.

  HKCU values are written to the hive of the user running this script. Run it as
  the same account that ran the playbook.

  The companion scope removes what runs at sign-in (the Startup launcher, the
  setup completion task and scripts) and the Driver Setup shortcut. It leaves
  C:\ChamberTech\PostInstall, which this script runs from, and the deployment
  receipt; delete C:\ChamberTech by hand once you no longer need them.
#>
[CmdletBinding()]
param(
    [switch]$Snapshot,
    [switch]$PreInstall,
    [string]$OutFile,
    [string]$FromSnapshot,
    [switch]$NoAutoSnapshot,
    [ValidateSet('all', 'services', 'registry', 'tasks', 'bcd', 'power', 'hosts', 'network', 'debloat', 'companion')]
    [string]$Scope = 'all',
    [switch]$Apply,
    [switch]$Force,
    [switch]$NoRestorePoint,
    [switch]$IncludeHags,
    [switch]$IncludeXbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Force) { $Apply = $true }

# --- Admin gate (same check Verify-Chamber uses) -----------------------------
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
        'RESTORED' { 'Green' }
        'PLANNED'  { 'Cyan' }
        'FAILED'   { 'Red' }
        'SKIPPED'  { 'DarkGray' }
        'UNKNOWN'  { 'Yellow' }
        'MANUAL'   { 'Yellow' }
        default    { 'White' }
    }
    Write-Host ("  [{0,-8}] {1}" -f $Status, $Label) -ForegroundColor $color
    if ($Detail) { Write-Host ("             {0}" -f $Detail) -ForegroundColor DarkGray }
}

$actions = [System.Collections.Generic.List[hashtable]]::new()
function Add-Action {
    param([string]$Status, [string]$Category, [string]$Label, [string]$Detail = '')
    $actions.Add(@{ Status = $Status; Category = $Category; Label = $Label; Detail = $Detail })
    Write-Result -Status $Status -Label $Label -Detail $Detail
}

# Windows PowerShell 5.1 turns anything a native tool writes to stderr into a
# terminating error under 'Stop' - a missing key in reg export, an unsupported
# bcdedit value - and some tools (bcdedit) report failure on stdout with no
# throw at all. Run them with Continue and judge them by exit code only.
function Invoke-NativeTool {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $ErrorActionPreference = 'Continue'
    $out = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join ' ') }
}

# Records RESTORED or FAILED for a native tool call from its exit code.
function Invoke-RestoreTool {
    param([string]$Category, [string]$Label, [string]$Detail, [string]$FilePath, [string[]]$Arguments)
    $r = Invoke-NativeTool -FilePath $FilePath -Arguments $Arguments
    if ($r.ExitCode -eq 0) { Add-Action 'RESTORED' $Category $Label $Detail }
    else { Add-Action 'FAILED' $Category $Label "exit $($r.ExitCode): $($r.Output)" }
}

function ConvertTo-PsRegPath {
    param([string]$AmePath)
    return ($AmePath -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' `
                     -replace '^HKCR\\', 'Registry::HKEY_CLASSES_ROOT\' -replace '^HKU\\', 'Registry::HKEY_USERS\')
}

# REG_BINARY values (UserPreferencesMask) travel as hex strings - the form AME's
# YAML uses - so a snapshot round-trips them instead of writing back the
# space-separated decimal that [string] makes of a byte array.
function ConvertTo-RegText {
    param($Raw)
    if ($Raw -is [byte[]]) { return (($Raw | ForEach-Object { '{0:X2}' -f $_ }) -join '') }
    return [string]$Raw
}

function ConvertFrom-HexString {
    param([string]$Hex)
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$bytes
}

function Get-RegType {
    param([string]$AmeType)
    switch -Regex ($AmeType) {
        'REG_DWORD|REG_QWORD' { return 'DWord' }
        'REG_BINARY'          { return 'Binary' }
        default               { return 'String' }
    }
}

# =============================================================================
# Windows defaults
#
# Used only when there is no snapshot. Two kinds of entry:
#   Set    - Windows ships a specific value; write it back
#   Delete - the value does not exist on a clean install; removing it restores
#            default behaviour, which is safer than asserting a number that
#            varies by build
#
# Cosmetic HKCU values are deliberately Delete rather than Set: Explorer
# recreates them from its own build-specific defaults, so deleting is both safer
# and more accurate than hardcoding what 24H2 happened to ship.
# =============================================================================

$ServiceDefaults = @{
    'DiagTrack'                                = @{ Start = 2 }
    'WerSvc'                                   = @{ Start = 3 }
    'DiagnosticsHub.StandardCollector.Service' = @{ Start = 3 }
    'dmwappushservice'                         = @{ Start = 3 }
    'wisvc'                                    = @{ Start = 3 }
    'WSearch'                                  = @{ Start = 2; DelayedAutoStart = 1 }
    'SysMain'                                  = @{ Start = 2 }
    'WMPNetworkSvc'                            = @{ Start = 3 }
    'TabletInputService'                       = @{ Start = 3 }
    'MapsBroker'                               = @{ Start = 3 }
    'PcaSvc'                                   = @{ Start = 2 }
    'RemoteRegistry'                           = @{ Start = 4; Note = 'disabled by default on Windows 11 - no change' }
    'TapiSrv'                                  = @{ Start = 3 }
    'Fax'                                      = @{ Start = 3 }
    'RetailDemo'                               = @{ Start = 3 }
    'XblAuthManager'                           = @{ Start = 3 }
    'XblGameSave'                              = @{ Start = 3 }
    'XboxNetApiSvc'                            = @{ Start = 3 }
    'XboxGipSvc'                               = @{ Start = 3 }
    'GamingServices'                           = @{ Start = 3 }
}

# Keyed on "<path>|<value>", matching the manifest exactly.
$RegistryDefaults = @{
    # --- 1-power.yml ---------------------------------------------------------
    'HKLM\SYSTEM\CurrentControlSet\Services\USB|DisableSelectiveSuspend' = @{ Action = 'Delete' }
    'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling|PowerThrottlingOff' = @{ Action = 'Delete' }

    # --- 4-registry.yml ------------------------------------------------------
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|SystemResponsiveness' = @{ Action = 'Set'; Data = 20; Type = 'DWord' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games|Priority' = @{ Action = 'Set'; Data = 2; Type = 'DWord' }
    'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel|GlobalTimerResolutionRequests' = @{ Action = 'Delete' }
    # Hex, like the manifest. Stock Windows 11 visual effects.
    'HKCU\Control Panel\Desktop|UserPreferencesMask' = @{ Action = 'Set'; Data = '9E1E078012000000'; Type = 'Binary' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games|Scheduling Category' = @{ Action = 'Set'; Data = 'Medium'; Type = 'String' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games|SFIO Priority' = @{ Action = 'Set'; Data = 'Normal'; Type = 'String' }
    'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl|Win32PrioritySeparation' = @{ Action = 'Set'; Data = 2; Type = 'DWord' }
    'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management|LargeSystemCache' = @{ Action = 'Set'; Data = 0; Type = 'DWord'; Note = 'already the Windows default' }
    'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers|HwSchMode' = @{ Action = 'Skip'; Note = 'HAGS - 2 is the current Windows default and disabling it breaks DLSS Frame Generation. Use -IncludeHags to force.'; HagsGated = $true; Data = 1; Type = 'DWord' }
    'HKCU\Control Panel\Mouse|MouseSpeed'      = @{ Action = 'Set'; Data = '1';  Type = 'String' }
    'HKCU\Control Panel\Mouse|MouseThreshold1' = @{ Action = 'Set'; Data = '6';  Type = 'String' }
    'HKCU\Control Panel\Mouse|MouseThreshold2' = @{ Action = 'Set'; Data = '10'; Type = 'String' }
    'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem|NtfsDisableLastAccessUpdate' = @{ Action = 'Fsutil'; Note = 'restored via fsutil behavior set disablelastaccess 2 (system-managed)' }
    'HKLM\SYSTEM\CurrentControlSet\Control|WaitToKillServiceTimeout' = @{ Action = 'Set'; Data = '5000'; Type = 'String' }
    'HKCU\Control Panel\Desktop|HungAppTimeout'      = @{ Action = 'Delete' }
    'HKCU\Control Panel\Desktop|WaitToKillAppTimeout'= @{ Action = 'Set'; Data = '20000'; Type = 'String' }
    'HKCU\Control Panel\Desktop|AutoEndTasks'        = @{ Action = 'Set'; Data = '0'; Type = 'String' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|NetworkThrottlingIndex' = @{ Action = 'Set'; Data = 10; Type = 'DWord' }
    'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters|TcpNoDelay'   = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Microsoft\MSMQ\Parameters|TCPNoDelay'                   = @{ Action = 'Delete' }
    'HKLM\SYSTEM\CurrentControlSet\Services\AFD\Parameters|DefaultSendWindow'    = @{ Action = 'Delete' }
    'HKLM\SYSTEM\CurrentControlSet\Services\AFD\Parameters|DefaultReceiveWindow' = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects|VisualFXSetting' = @{ Action = 'Set'; Data = 0; Type = 'DWord' }
    'HKCU\Control Panel\Desktop|MenuShowDelay'               = @{ Action = 'Set'; Data = '400'; Type = 'String' }
    'HKCU\Control Panel\Desktop\WindowMetrics|MinAnimate'    = @{ Action = 'Set'; Data = '1'; Type = 'String' }
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching|SearchOrderConfig' = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance|MaintenanceDisabled' = @{ Action = 'Delete' }
    'HKCU\System\GameConfigStore|GameDVR_Enabled'                     = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR|AllowGameDVR'   = @{ Action = 'Delete' }
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR|AppCaptureEnabled'   = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKCU\SOFTWARE\Microsoft\GameBar|UseNexusForGameBarEnabled'       = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKCU\SOFTWARE\Microsoft\GameBar|AllowAutoGameMode'   = @{ Action = 'Set'; Data = 1; Type = 'DWord'; Note = 'already the Windows default' }
    'HKCU\SOFTWARE\Microsoft\GameBar|AutoGameModeEnabled' = @{ Action = 'Set'; Data = 1; Type = 'DWord'; Note = 'already the Windows default' }

    # --- 5-privacy.yml -------------------------------------------------------
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry'                = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection|AllowTelemetry' = @{ Action = 'Delete' }
    'HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener|Start' = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\SQMLogger|Start'          = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled'        = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_TrackProgs' = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\System|EnableActivityFeed'      = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\System|PublishUserActivities'   = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot' = @{ Action = 'Delete' }
    'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot' = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableAIDataAnalysis'      = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableClickToDo'           = @{ Action = 'Delete' }
    'HKCU\Software\Policies\Microsoft\Windows\Explorer|DisableSearchBoxSuggestions' = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_IrisRecommendations'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_AccountNotifications' = @{ Action = 'Delete' }
    # ContentDeliveryManager: an absent value means Windows' default (on), so delete
    # rather than assert a number.
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SystemPaneSuggestionsEnabled'     = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338388Enabled'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SilentInstalledAppsEnabled'       = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SoftLandingEnabled'               = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338389Enabled'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-310093Enabled'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338393Enabled'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-353694Enabled'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-353696Enabled'  = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|RotatingLockScreenOverlayEnabled' = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338387Enabled'  = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe|Debugger'  = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AggregatorHost.exe|Debugger'   = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe|Debugger'     = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization|DODownloadMode' = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy|LetAppsRunInBackground'   = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Edge|StartupBoostEnabled'                     = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Edge|BackgroundModeEnabled'                   = @{ Action = 'Delete' }

    # --- 7-security.yml ------------------------------------------------------
    'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard|EnableVirtualizationBasedSecurity' = @{ Action = 'Set'; Data = 1; Type = 'DWord'; Note = 're-enables VBS - requires reboot' }
    'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard|RequirePlatformSecurityFeatures'   = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity|Enabled' = @{ Action = 'Set'; Data = 1; Type = 'DWord'; Note = 're-enables Memory Integrity - requires reboot' }
    'HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy|VerifiedAndReputablePolicyState' = @{ Action = 'Delete'; Note = 'Smart App Control returns to evaluation mode; Windows may not re-arm it without a reinstall' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender|DisableAntiSpyware' = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection|DisableRealtimeMonitoring' = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU|NoAutoUpdate' = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU|AUOptions'    = @{ Action = 'Delete' }

    # Deleting this only lets Windows consider device encryption again; it does
    # NOT re-encrypt the drive. Turn encryption back on from Settings > Privacy &
    # security > Device encryption, which also puts the recovery key somewhere
    # the owner controls rather than wherever setup happened to file it.
    'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker|PreventDeviceEncryption' = @{ Action = 'Delete'; Note = 'allows automatic device encryption again; does not re-encrypt a drive that is already decrypted' }

    # --- 8-configure-windows.yml (cosmetic - delete and let Explorer rebuild) -
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarAl'          = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowTaskViewButton' = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Search|SearchboxTaskbarMode'          = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarDa'          = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarMn'          = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'        = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Hidden'             = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'           = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|SnapAssist'         = @{ Action = 'Delete' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowCopilotButton'  = @{ Action = 'Delete' }
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization|NoLockScreen'               = @{ Action = 'Delete' }
    'HKCU\Control Panel\Accessibility\StickyKeys|Flags'        = @{ Action = 'Set'; Data = '510'; Type = 'String' }
    'HKCU\Control Panel\Accessibility\ToggleKeys|Flags'        = @{ Action = 'Set'; Data = '62';  Type = 'String' }
    'HKCU\Control Panel\Accessibility\Keyboard Response|Flags' = @{ Action = 'Set'; Data = '126'; Type = 'String' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|AppsUseLightTheme'   = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|SystemUsesLightTheme'= @{ Action = 'Set'; Data = 1; Type = 'DWord' }
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|EnableTransparency'  = @{ Action = 'Set'; Data = 1; Type = 'DWord' }
}

# The IFEO PerfOptions demotions in 9-network.yml are all "delete the value"; the
# whole PerfOptions subkey is absent on a clean install. Generated rather than
# listed so adding a process to 9-network.yml only needs a manifest regen. This
# deliberately produces a superset - the restore loop iterates the manifest, so
# entries for values the playbook doesn't currently set are simply never read.
foreach ($exe in @('SearchIndexer.exe', 'SearchProtocolHost.exe', 'SearchFilterHost.exe',
                   'sihost.exe', 'RuntimeBroker.exe', 'CompatTelRunner.exe', 'WerFault.exe')) {
    foreach ($val in @('CpuPriorityClass', 'IoPriority')) {
        $k = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions|$val"
        $RegistryDefaults[$k] = @{ Action = 'Delete' }
    }
}

# Chamber's duplicated power scheme is deleted wholesale in the power scope, so
# the two ValueMin/ValueMax writes under its GUID need no individual handling.
$ChamberSchemeGuid = '11111111-1111-1111-1111-111111111111'
foreach ($v in @('ValueMax', 'ValueMin')) {
    $k = "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583\DefaultPowerSchemeValues\$ChamberSchemeGuid|$v"
    $RegistryDefaults[$k] = @{ Action = 'Skip'; Note = "lives under Chamber's power scheme; removed with the scheme itself" }
}

Write-Host ''
Write-Host ('=' * 66) -ForegroundColor DarkMagenta
Write-Host '  CHAMBER - SYSTEM RESTORE' -ForegroundColor Magenta
Write-Host ('=' * 66) -ForegroundColor DarkMagenta

# --- Load manifest -----------------------------------------------------------
$manifestPath = Join-Path $PSScriptRoot 'verification-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host ''
    Write-Host '  verification-manifest.json not found next to this script. Cannot continue.' -ForegroundColor Red
    Write-Host ''
    exit 3
}
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} catch {
    Write-Host ''
    Write-Host "  Could not parse the manifest: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 3
}
Write-Host "  Manifest generated: $($manifest.generatedUtc)" -ForegroundColor DarkGray

$logDir = Join-Path $env:ProgramData 'ChamberPostInstall\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Phase 0 writes here, deliberately without a timestamp: restore needs one
# unambiguous "state before Chamber was applied" file to fall back on. A
# timestamped snapshot taken after the playbook ran would restore the machine to
# its already-tweaked state, which is worse than useless, so auto-detection only
# ever looks at this exact name.
$PreInstallSnapshot = Join-Path $logDir 'chamber-snapshot-preinstall.json'

# =============================================================================
# Snapshot mode - capture and exit
# =============================================================================
if ($Snapshot) {
    Write-Host '  Mode: SNAPSHOT (capturing current state, no changes)' -ForegroundColor Cyan
    Write-Host ''

    # The pre-install snapshot is "the state before Chamber". A re-run or an
    # upgrade would otherwise replace it with an already-tweaked one, so the
    # first capture is kept. Delete the file to take a fresh one.
    if ($PreInstall -and (Test-Path -LiteralPath $PreInstallSnapshot)) {
        Write-Host "  Pre-install snapshot already exists - keeping it: $PreInstallSnapshot" -ForegroundColor Green
        Write-Host ''
        exit 0
    }

    # During an injected OOBE phase 0 runs as SYSTEM, before the real user
    # exists, so HKCU here is SYSTEM's own hive. Recording it would make restore
    # delete the user's values as "not present before Chamber". Leave HKCU out
    # and let restore use the defaults table for it instead.
    $asSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    if ($asSystem) {
        Write-Host '  Running as SYSTEM: per-user (HKCU) values are not captured.' -ForegroundColor Yellow
    }

    $snapReg = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in $manifest.registryValues) {
        if ($asSystem -and $entry.path -like 'HKCU\*') { continue }
        $psPath = ConvertTo-PsRegPath $entry.path
        $present = $false
        $actual = $null
        try {
            $item = Get-ItemProperty -LiteralPath $psPath -Name $entry.value -ErrorAction Stop
            $actual = ConvertTo-RegText $item.($entry.value)
            $present = $true
        } catch { }
        $snapReg.Add(@{ path = $entry.path; value = $entry.value; type = $entry.type; present = $present; data = $actual })
    }

    $snapSvc = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($svc in $manifest.services) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.name)"
        $start = $null; $delayed = $null
        if (Test-Path -LiteralPath $key) {
            $p = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties.Name -contains 'Start') { $start = $p.Start }
            if ($p -and $p.PSObject.Properties.Name -contains 'DelayedAutoStart') { $delayed = $p.DelayedAutoStart }
        }
        $snapSvc.Add(@{ name = $svc.name; present = ($null -ne $start); start = $start; delayedAutoStart = $delayed })
    }

    $activeScheme = ''
    try { $activeScheme = (& powercfg /getactivescheme 2>&1) -join ' ' } catch { }
    $bcdDump = ''
    try { $bcdDump = (& bcdedit /enum '{current}' 2>&1) -join "`n" } catch { }

    $installedAppx = @()
    try {
        $allTargets = @($manifest.debloat.balanced) + @($manifest.debloat.xbox)
        $installedAppx = @($allTargets | Where-Object {
            @(Get-AppxPackage -AllUsers -Name $_ -ErrorAction SilentlyContinue).Count -gt 0
        })
    } catch { }

    $snapshotObj = [ordered]@{
        schema               = 1
        capturedUtc          = (Get-Date).ToUniversalTime().ToString('o')
        computerName         = $env:COMPUTERNAME
        userName             = $env:USERNAME
        capturedAsSystem     = $asSystem
        manifestGeneratedUtc = $manifest.generatedUtc
        registryValues       = $snapReg
        services             = $snapSvc
        activePowerScheme    = $activeScheme
        bcdCurrent           = $bcdDump
        appxPresent          = $installedAppx
    }

    if ($PreInstall) {
        # Resolved inside the script rather than passed in, so phase 0 does not
        # depend on the shell expanding %ProgramData% before PowerShell sees it.
        $snapPath = $PreInstallSnapshot
    } elseif ($OutFile) {
        $snapPath = $OutFile
        $parent = Split-Path -Parent $snapPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    } else {
        $snapPath = Join-Path $logDir "chamber-snapshot-$stamp.json"
    }
    $snapshotObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snapPath -Encoding UTF8

    Write-Host "  Captured $($snapReg.Count) registry values, $($snapSvc.Count) services, $($installedAppx.Count) AppX packages." -ForegroundColor Green
    Write-Host ''
    Write-Host "  Snapshot: $snapPath" -ForegroundColor White
    if ($snapPath -eq $PreInstallSnapshot) {
        Write-Host '  This is the canonical pre-install snapshot. Restore-Chamber will find it' -ForegroundColor DarkGray
        Write-Host '  automatically - no arguments needed:' -ForegroundColor DarkGray
        Write-Host '    .\Restore-Chamber.ps1 -Apply' -ForegroundColor DarkGray
    } else {
        Write-Host '  Keep this file. Restore with:' -ForegroundColor DarkGray
        Write-Host "    .\Restore-Chamber.ps1 -FromSnapshot `"$snapPath`" -Apply" -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
}

# =============================================================================
# Restore mode
# =============================================================================
$snap = $null

# An explicit -FromSnapshot wins. Otherwise fall back to the phase 0 pre-install
# snapshot if one exists, since that is an exact restore and the defaults table
# is only ever an approximation.
if (-not $FromSnapshot -and -not $NoAutoSnapshot -and (Test-Path -LiteralPath $PreInstallSnapshot)) {
    $FromSnapshot = $PreInstallSnapshot
    Write-Host '  Found the pre-install snapshot captured by phase 0.' -ForegroundColor Green
}

if ($FromSnapshot) {
    if (-not (Test-Path -LiteralPath $FromSnapshot)) {
        Write-Host ''
        Write-Host "  Snapshot not found: $FromSnapshot" -ForegroundColor Red
        Write-Host ''
        exit 3
    }
    $snap = Get-Content -LiteralPath $FromSnapshot -Raw | ConvertFrom-Json
    Write-Host "  Source: snapshot captured $($snap.capturedUtc)" -ForegroundColor Cyan
    $snapManifestUtc = $null
    if ($snap.PSObject.Properties.Name -contains 'manifestGeneratedUtc') { $snapManifestUtc = $snap.manifestGeneratedUtc }
    if ($snapManifestUtc -ne $manifest.generatedUtc) {
        Write-Host '  NOTE: the snapshot was taken against a different manifest revision.' -ForegroundColor Yellow
        Write-Host '        Tweaks added since then fall back to the defaults table.' -ForegroundColor Yellow
    }
} elseif ($NoAutoSnapshot) {
    Write-Host '  Source: Windows defaults table (-NoAutoSnapshot)' -ForegroundColor Yellow
} else {
    Write-Host '  Source: Windows defaults table (no pre-install snapshot found)' -ForegroundColor Yellow
}
Write-Host "  Scope:  $Scope" -ForegroundColor DarkGray
if ($Apply) { Write-Host '  Mode:   APPLY - changes will be written' -ForegroundColor Yellow }
else        { Write-Host '  Mode:   PREVIEW - nothing will change. Add -Apply to execute.' -ForegroundColor Cyan }
Write-Host ''

function Test-Scope { param([string]$Name) return ($Scope -eq 'all' -or $Scope -eq $Name) }

# Build a lookup from the snapshot so restore can prefer captured values.
$snapRegLookup = @{}
$snapSvcLookup = @{}
if ($snap) {
    # A snapshot taken as SYSTEM holds SYSTEM's HKCU, not the user's. 1.3.0
    # snapshots leave HKCU out and say so; earlier ones only reveal it through
    # the computer account (NAME$) as the user name.
    $snapAsSystem = ($snap.PSObject.Properties.Name -contains 'capturedAsSystem' -and $snap.capturedAsSystem) -or
                    ([string]$snap.userName -match '\$$|^SYSTEM$')
    if ($snapAsSystem) {
        Write-Host '  NOTE: the snapshot was taken as SYSTEM (injected install). Per-user values' -ForegroundColor Yellow
        Write-Host '        come from the Windows defaults table instead.' -ForegroundColor Yellow
    }
    foreach ($r in $snap.registryValues) {
        if ($snapAsSystem -and $r.path -like 'HKCU\*') { continue }
        $snapRegLookup["$($r.path)|$($r.value)"] = $r
    }
    foreach ($s in $snap.services)       { $snapSvcLookup[$s.name] = $s }
}

# --- Confirmation + safety net -----------------------------------------------
if ($Apply -and -not $Force) {
    Write-Host '  This will modify system settings, services, and the registry.' -ForegroundColor Yellow
    $answer = Read-Host '  Type RESTORE to continue'
    if ($answer -ne 'RESTORE') {
        Write-Host ''
        Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
    Write-Host ''
}

$backupDir = Join-Path $logDir "restore-backup-$stamp"
if ($Apply) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    if (-not $NoRestorePoint) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            Checkpoint-Computer -Description "Before Chamber Restore" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            Add-Action 'RESTORED' 'Safety' 'System Restore point' 'created'
        } catch {
            Add-Action 'SKIPPED' 'Safety' 'System Restore point' "could not create: $($_.Exception.Message)"
        }
    }

    # Registry backup of every key the manifest touches. Exported at full key
    # depth on purpose - truncating to the hive root would mean dumping things
    # like HKLM\SOFTWARE\Microsoft, which is enormous and slow.
    $keys = @($manifest.registryValues | ForEach-Object { $_.path }) | Sort-Object -Unique
    $exported = 0
    foreach ($k in $keys) {
        $safe = ($k -replace '[\\:\s]', '_')
        $out = Join-Path $backupDir "$safe.reg"
        # A key that does not exist (an option that was not selected) simply
        # has nothing to back up.
        if ((Invoke-NativeTool -FilePath 'reg.exe' -Arguments @('export', $k, $out, '/y')).ExitCode -eq 0) { $exported++ }
    }
    Add-Action 'RESTORED' 'Safety' 'Registry backup' "$exported/$($keys.Count) keys exported to $backupDir"
    Write-Host ''
}

# --- Registry ----------------------------------------------------------------
if (Test-Scope 'registry') {
    Write-Host '  --- Registry ---' -ForegroundColor DarkMagenta
    $unknown = 0

    foreach ($entry in $manifest.registryValues) {
        $key = "$($entry.path)|$($entry.value)"
        $label = "$($entry.path)\$($entry.value)"
        $psPath = ConvertTo-PsRegPath $entry.path

        # Prefer the snapshot; fall back to the defaults table.
        $plan = $null
        if ($snapRegLookup.ContainsKey($key)) {
            $s = $snapRegLookup[$key]
            if ($s.present) {
                $plan = @{ Action = 'Set'; Data = $s.data; Type = (Get-RegType $entry.type); Note = 'from snapshot' }
            } else {
                $plan = @{ Action = 'Delete'; Note = 'not present when snapshot was taken' }
            }
        } elseif ($RegistryDefaults.ContainsKey($key)) {
            $plan = $RegistryDefaults[$key]
        }

        if ($null -eq $plan) {
            $unknown++
            Add-Action 'UNKNOWN' 'Registry' $label 'no snapshot entry and no known default - left unchanged'
            continue
        }

        $note = ''
        if ($plan.ContainsKey('Note')) { $note = $plan.Note }

        # HAGS is opt-in.
        if ($plan.Action -eq 'Skip' -and $plan.ContainsKey('HagsGated') -and $IncludeHags) {
            $plan = @{ Action = 'Set'; Data = $plan.Data; Type = $plan.Type }
            $note = 'reverted because -IncludeHags was passed'
        }

        switch ($plan.Action) {
            'Skip' {
                Add-Action 'SKIPPED' 'Registry' $label $note
            }
            'Fsutil' {
                if ($Apply) {
                    Invoke-RestoreTool 'Registry' $label $note 'fsutil.exe' @('behavior', 'set', 'disablelastaccess', '2')
                } else {
                    Add-Action 'PLANNED' 'Registry' $label $note
                }
            }
            'Delete' {
                $exists = $false
                try { Get-ItemProperty -LiteralPath $psPath -Name $entry.value -ErrorAction Stop | Out-Null; $exists = $true } catch { }
                if (-not $exists) {
                    Add-Action 'SKIPPED' 'Registry' $label 'already absent'
                } elseif ($Apply) {
                    try {
                        Remove-ItemProperty -LiteralPath $psPath -Name $entry.value -Force -ErrorAction Stop
                        Add-Action 'RESTORED' 'Registry' $label (('deleted. ' + $note).Trim())
                    } catch { Add-Action 'FAILED' 'Registry' $label $_.Exception.Message }
                } else {
                    Add-Action 'PLANNED' 'Registry' $label (('delete value. ' + $note).Trim())
                }
            }
            'Set' {
                $current = '<not set>'
                try {
                    $item = Get-ItemProperty -LiteralPath $psPath -Name $entry.value -ErrorAction Stop
                    $current = ConvertTo-RegText $item.($entry.value)
                } catch { }
                if ($current -eq [string]$plan.Data) {
                    Add-Action 'SKIPPED' 'Registry' $label "already $($plan.Data)"
                } elseif ($Apply) {
                    try {
                        if (-not (Test-Path -LiteralPath $psPath)) { New-Item -Path $psPath -Force | Out-Null }
                        $value = if ($plan.Type -eq 'Binary') { ConvertFrom-HexString ([string]$plan.Data) } else { $plan.Data }
                        Set-ItemProperty -LiteralPath $psPath -Name $entry.value -Value $value -Type $plan.Type -Force -ErrorAction Stop
                        Add-Action 'RESTORED' 'Registry' $label (("$current -> $($plan.Data). " + $note).Trim())
                    } catch { Add-Action 'FAILED' 'Registry' $label $_.Exception.Message }
                } else {
                    Add-Action 'PLANNED' 'Registry' $label (("$current -> $($plan.Data). " + $note).Trim())
                }
            }
        }
    }

    # Optimizations for windowed games. Set by Enable-WindowedGameOptimizations.ps1
    # inside a shared string, so it is not a manifest value: drop just that key
    # and leave the user's Auto HDR / VRR keys alone.
    $dxPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dxLabel = 'DirectX\UserGpuPreferences\SwapEffectUpgradeEnable'
    $dx = [string](Get-ItemProperty -LiteralPath $dxPath -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
    if ($dx -notmatch 'SwapEffectUpgradeEnable=') {
        Add-Action 'SKIPPED' 'Registry' $dxLabel 'already absent'
    } elseif ($Apply) {
        try {
            $kept = @($dx -split ';' | Where-Object { $_ -and $_ -notmatch '^SwapEffectUpgradeEnable=' })
            if ($kept.Count -eq 0) { Remove-ItemProperty -LiteralPath $dxPath -Name 'DirectXUserGlobalSettings' -ErrorAction Stop }
            else { Set-ItemProperty -LiteralPath $dxPath -Name 'DirectXUserGlobalSettings' -Value (($kept -join ';') + ';') -Type String -ErrorAction Stop }
            Add-Action 'RESTORED' 'Registry' $dxLabel 'removed - Windows default applies'
        } catch { Add-Action 'FAILED' 'Registry' $dxLabel $_.Exception.Message }
    } else {
        Add-Action 'PLANNED' 'Registry' $dxLabel 'remove key - Windows default applies'
    }

    if ($unknown -gt 0) {
        Write-Host ''
        Write-Host "  $unknown value(s) had no known default. Add them to `$RegistryDefaults or restore from a snapshot." -ForegroundColor Yellow
    }
    Write-Host ''
}

# --- Scheduled tasks ---------------------------------------------------------
# Every telemetry task Chamber disables is enabled on a clean install, so the
# restore is simply the opposite operation. Tasks missing on this build are
# skipped.
if ((Test-Scope 'tasks') -and ($manifest.PSObject.Properties.Name -contains 'scheduledTasks')) {
    Write-Host '  --- Scheduled tasks ---' -ForegroundColor DarkMagenta
    foreach ($t in $manifest.scheduledTasks) {
        $folder = (Split-Path -Path $t.path -Parent).TrimEnd('\') + '\'
        $leaf = Split-Path -Path $t.path -Leaf
        $task = Get-ScheduledTask -TaskPath $folder -TaskName $leaf -ErrorAction SilentlyContinue
        if (-not $task) { Add-Action 'SKIPPED' 'Tasks' $t.path 'not present on this build'; continue }
        $wantEnabled = ($t.state -eq 'disable')
        $isEnabled = ($task.State -ne 'Disabled')
        if ($wantEnabled -eq $isEnabled) {
            Add-Action 'SKIPPED' 'Tasks' $t.path "already $($task.State)"
        } elseif ($Apply) {
            try {
                if ($wantEnabled) { Enable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null }
                else { Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null }
                Add-Action 'RESTORED' 'Tasks' $t.path $(if ($wantEnabled) { 'enabled' } else { 'disabled' })
            } catch { Add-Action 'FAILED' 'Tasks' $t.path $_.Exception.Message }
        } else {
            Add-Action 'PLANNED' 'Tasks' $t.path $(if ($wantEnabled) { 'enable' } else { 'disable' })
        }
    }
    Write-Host ''
}

# --- Services ----------------------------------------------------------------
if (Test-Scope 'services') {
    Write-Host '  --- Services ---' -ForegroundColor DarkMagenta
    foreach ($svc in $manifest.services) {
        $isXbox = ($svc.PSObject.Properties.Name -contains 'option' -and $svc.option -eq 'remove-xbox')
        if ($isXbox -and -not $IncludeXbox) {
            Add-Action 'SKIPPED' 'Services' $svc.name 'Xbox service - use -IncludeXbox to restore'
            continue
        }

        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.name)"
        if (-not (Test-Path -LiteralPath $key)) {
            Add-Action 'SKIPPED' 'Services' $svc.name 'not present on this build'
            continue
        }

        $target = $null; $delayed = $null; $note = ''
        if ($snapSvcLookup.ContainsKey($svc.name) -and $snapSvcLookup[$svc.name].present) {
            $target = [int]$snapSvcLookup[$svc.name].start
            if ($null -ne $snapSvcLookup[$svc.name].delayedAutoStart) { $delayed = [int]$snapSvcLookup[$svc.name].delayedAutoStart }
            $note = 'from snapshot'
        } elseif ($ServiceDefaults.ContainsKey($svc.name)) {
            $d = $ServiceDefaults[$svc.name]
            $target = $d.Start
            if ($d.ContainsKey('DelayedAutoStart')) { $delayed = $d.DelayedAutoStart }
            if ($d.ContainsKey('Note')) { $note = $d.Note }
        }

        if ($null -eq $target) {
            Add-Action 'UNKNOWN' 'Services' $svc.name 'no snapshot entry and no known default - left unchanged'
            continue
        }

        $current = (Get-ItemProperty -LiteralPath $key -Name 'Start' -ErrorAction SilentlyContinue).Start
        if ($current -eq $target) {
            Add-Action 'SKIPPED' 'Services' $svc.name (("already Start=$target. " + $note).Trim())
        } elseif ($Apply) {
            try {
                Set-ItemProperty -LiteralPath $key -Name 'Start' -Value $target -Type DWord -Force -ErrorAction Stop
                if ($null -ne $delayed) {
                    Set-ItemProperty -LiteralPath $key -Name 'DelayedAutoStart' -Value $delayed -Type DWord -Force -ErrorAction SilentlyContinue
                }
                Add-Action 'RESTORED' 'Services' $svc.name (("Start $current -> $target. " + $note).Trim())
            } catch { Add-Action 'FAILED' 'Services' $svc.name $_.Exception.Message }
        } else {
            Add-Action 'PLANNED' 'Services' $svc.name (("Start $current -> $target. " + $note).Trim())
        }
    }
    Write-Host ''
}

# --- BCD ---------------------------------------------------------------------
if (Test-Scope 'bcd') {
    Write-Host '  --- Boot configuration ---' -ForegroundColor DarkMagenta
    foreach ($flag in $manifest.bcd.flags) {
        if ($Apply) {
            Invoke-RestoreTool 'BCD' $flag.flag 'deleted - Windows default restored' 'bcdedit.exe' @('/deletevalue', $flag.flag)
        } else {
            Add-Action 'PLANNED' 'BCD' $flag.flag 'bcdedit /deletevalue'
        }
    }
    if ($null -ne $manifest.bcd.timeout) {
        if ($Apply) {
            Invoke-RestoreTool 'BCD' 'Boot timeout' "$($manifest.bcd.timeout) -> 30" 'bcdedit.exe' @('/timeout', '30')
        } else {
            Add-Action 'PLANNED' 'BCD' 'Boot timeout' "$($manifest.bcd.timeout) -> 30"
        }
    }
    Write-Host ''
}

# --- Power -------------------------------------------------------------------
if (Test-Scope 'power') {
    Write-Host '  --- Power ---' -ForegroundColor DarkMagenta
    if ($Apply) {
        Invoke-RestoreTool 'Power' 'Default power schemes' 'powercfg -restoredefaultschemes (Balanced is now active)' 'powercfg.exe' @('-restoredefaultschemes')
        # -restoredefaultschemes normally removes the Chamber scheme already.
        if ((Invoke-NativeTool -FilePath 'powercfg.exe' -Arguments @('-delete', $ChamberSchemeGuid)).ExitCode -eq 0) {
            Add-Action 'RESTORED' 'Power' 'Chamber power scheme' 'deleted'
        } else {
            Add-Action 'SKIPPED' 'Power' 'Chamber power scheme' 'already gone'
        }
        Invoke-RestoreTool 'Power' 'Hibernation' 're-enabled' 'powercfg.exe' @('-h', 'on')
        # Set-ChamberPowerPlan.ps1 turns Fast Startup off directly on laptops
        # (desktops lose it with the hiberfile). 1 is the Windows default.
        try {
            Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 1 -Type DWord -ErrorAction Stop
            Add-Action 'RESTORED' 'Power' 'Fast Startup' 're-enabled'
        } catch { Add-Action 'FAILED' 'Power' 'Fast Startup' $_.Exception.Message }
        foreach ($pair in @(@('monitor-timeout-ac', 10), @('standby-timeout-ac', 30), @('disk-timeout-ac', 20), @('disk-timeout-dc', 10))) {
            Invoke-RestoreTool 'Power' "Idle timeout: $($pair[0])" "$($pair[1]) min (Windows default)" 'powercfg.exe' @('-change', "-$($pair[0])", "$($pair[1])")
        }
    } else {
        Add-Action 'PLANNED' 'Power' 'Default power schemes' 'powercfg -restoredefaultschemes'
        Add-Action 'PLANNED' 'Power' 'Chamber power scheme' "powercfg -delete $ChamberSchemeGuid"
        Add-Action 'PLANNED' 'Power' 'Hibernation' 'powercfg -h on'
        Add-Action 'PLANNED' 'Power' 'Fast Startup' 'HiberbootEnabled = 1'
        Add-Action 'PLANNED' 'Power' 'Idle timeouts' 'monitor/standby/disk returned to Windows defaults'
    }
    Write-Host ''
}

# --- Network -----------------------------------------------------------------
if (Test-Scope 'network') {
    Write-Host '  --- Network ---' -ForegroundColor DarkMagenta
    if ($Apply) {
        Invoke-RestoreTool 'Network' 'TCP ECN capability' 'back to default' 'netsh.exe' @('int', 'tcp', 'set', 'global', 'ecncapability=default')
        Invoke-RestoreTool 'Network' 'TCP autotuning' 'normal' 'netsh.exe' @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal')
    } else {
        Add-Action 'PLANNED' 'Network' 'TCP global settings' 'ecncapability=default, autotuninglevel=normal'
    }
    Write-Host ''
}

# --- Hosts -------------------------------------------------------------------
if (Test-Scope 'hosts') {
    Write-Host '  --- Hosts file ---' -ForegroundColor DarkMagenta
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    try {
        $lines = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
        $entries = @($manifest.hostsEntries)
        $keep = @($lines | Where-Object {
            $line = $_
            -not ($entries | Where-Object { $line -match [regex]::Escape($_) })
        })
        $removed = $lines.Count - $keep.Count
        if ($removed -eq 0) {
            Add-Action 'SKIPPED' 'Hosts' 'Telemetry blocks' 'no Chamber entries found'
        } elseif ($Apply) {
            Copy-Item -LiteralPath $hostsPath -Destination (Join-Path $backupDir 'hosts.bak') -Force -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $hostsPath -Value $keep -Encoding ASCII -Force
            Add-Action 'RESTORED' 'Hosts' 'Telemetry blocks' "$removed line(s) removed"
        } else {
            Add-Action 'PLANNED' 'Hosts' 'Telemetry blocks' "$removed line(s) would be removed"
        }
    } catch {
        Add-Action 'FAILED' 'Hosts' 'Telemetry blocks' $_.Exception.Message
    }
    Write-Host ''
}

# --- Debloat -----------------------------------------------------------------
if (Test-Scope 'debloat') {
    Write-Host '  --- AppX packages ---' -ForegroundColor DarkMagenta
    $targets = @($manifest.debloat.balanced)
    if ($IncludeXbox) { $targets += @($manifest.debloat.xbox) }

    $needStore = [System.Collections.Generic.List[string]]::new()
    $reRegistered = 0
    foreach ($name in $targets) {
        $onDisk = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
        $forUser = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
        if ($forUser.Count -gt 0) { continue }   # already installed for this user

        if ($onDisk.Count -gt 0) {
            # Still staged for another account - re-register without needing media.
            if ($Apply) {
                try {
                    foreach ($pkg in $onDisk) {
                        $mf = Join-Path $pkg.InstallLocation 'AppXManifest.xml'
                        if (Test-Path -LiteralPath $mf) {
                            Add-AppxPackage -DisableDevelopmentMode -Register $mf -ErrorAction Stop
                        }
                    }
                    $reRegistered++
                    Add-Action 'RESTORED' 'Debloat' $name 're-registered from staged files'
                } catch {
                    $needStore.Add($name)
                    Add-Action 'MANUAL' 'Debloat' $name "re-register failed: $($_.Exception.Message)"
                }
            } else {
                Add-Action 'PLANNED' 'Debloat' $name 're-register from staged files'
            }
        } else {
            $needStore.Add($name)
        }
    }

    if ($needStore.Count -gt 0) {
        Add-Action 'MANUAL' 'Debloat' 'Fully removed packages' `
            "$($needStore.Count) package(s) were deprovisioned and cannot be restored without install media. Reinstall from the Microsoft Store."
        foreach ($n in $needStore) { Write-Host "               - $n" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

# --- Chamber companion ---------------------------------------------------------
# What Install-PostInstallCompanion.ps1 and Complete-ChamberSetup.ps1 leave
# behind. The Startup launcher matters most: left in place, it re-runs
# Complete-ChamberSetup at sign-in after any later Chamber run and puts the
# settings straight back. C:\ChamberTech\PostInstall stays - this script runs
# from it - and so does the deployment receipt.
if (Test-Scope 'companion') {
    Write-Host '  --- Chamber companion ---' -ForegroundColor DarkMagenta
    $chamberRoot = 'C:\ChamberTech'
    $companionItems = @(
        @{ Label = 'Sign-in launcher';           Path = Join-Path ([Environment]::GetFolderPath('CommonStartup')) 'Chamber Welcome.lnk' }
        @{ Label = 'Driver Setup shortcut';      Path = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Driver Setup.lnk' }
        @{ Label = 'Show-ChamberWelcome.cmd';    Path = Join-Path $chamberRoot 'Show-ChamberWelcome.cmd' }
        @{ Label = 'Welcome run id';             Path = Join-Path $chamberRoot 'welcome-id.txt' }
        @{ Label = 'Setup completion scripts';   Path = Join-Path $chamberRoot 'Setup' }
        @{ Label = 'Classic context menu';       Path = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' }
        @{ Label = 'Welcome page seen marker';   Path = 'HKCU:\Software\ChamberTech' }
    )
    foreach ($item in $companionItems) {
        if (-not (Test-Path -LiteralPath $item.Path)) {
            Add-Action 'SKIPPED' 'Companion' $item.Label 'already absent'
        } elseif ($Apply) {
            try {
                Remove-Item -LiteralPath $item.Path -Recurse -Force -ErrorAction Stop
                Add-Action 'RESTORED' 'Companion' $item.Label "deleted $($item.Path)"
            } catch { Add-Action 'FAILED' 'Companion' $item.Label $_.Exception.Message }
        } else {
            Add-Action 'PLANNED' 'Companion' $item.Label "delete $($item.Path)"
        }
    }

    # Normally deletes itself after its one run; still here means it never ran.
    $completionTask = 'Chamber Setup Completion'
    if ($null -eq (Get-ScheduledTask -TaskName $completionTask -ErrorAction SilentlyContinue)) {
        Add-Action 'SKIPPED' 'Companion' $completionTask 'already absent'
    } elseif ($Apply) {
        try {
            Unregister-ScheduledTask -TaskName $completionTask -Confirm:$false -ErrorAction Stop
            Add-Action 'RESTORED' 'Companion' $completionTask 'scheduled task deleted'
        } catch { Add-Action 'FAILED' 'Companion' $completionTask $_.Exception.Message }
    } else {
        Add-Action 'PLANNED' 'Companion' $completionTask 'delete scheduled task'
    }

    # Taskbar auto-hide is shell state (SHAppBarMessage), not a value to put back.
    $receiptPath = Join-Path $chamberRoot 'deployment-receipt.json'
    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($receipt.PSObject.Properties.Name -contains 'selectedOptions' -and @($receipt.selectedOptions) -contains 'oled-safety') {
            Add-Action 'MANUAL' 'Companion' 'Taskbar auto-hide' 'turned on for OLED safety - turn it off in Settings > Personalization > Taskbar > Taskbar behaviors'
        }
    } catch { }
    Write-Host ''
}

# --- Summary ------------------------------------------------------------------
$restored = @($actions | Where-Object { $_.Status -eq 'RESTORED' }).Count
$planned  = @($actions | Where-Object { $_.Status -eq 'PLANNED'  }).Count
$failed   = @($actions | Where-Object { $_.Status -eq 'FAILED'   }).Count
$unknownN = @($actions | Where-Object { $_.Status -eq 'UNKNOWN'  }).Count
$manual   = @($actions | Where-Object { $_.Status -eq 'MANUAL'   }).Count

Write-Host ('=' * 66) -ForegroundColor DarkMagenta
if ($Apply) {
    Write-Host "  Restored: $restored   Failed: $failed   Unknown: $unknownN   Manual: $manual" `
        -ForegroundColor $(if ($failed -gt 0) { 'Red' } elseif ($unknownN -gt 0) { 'Yellow' } else { 'Green' })
} else {
    Write-Host "  Would change: $planned   Unknown: $unknownN   Manual: $manual" -ForegroundColor Cyan
    Write-Host '  Re-run with -Apply to execute.' -ForegroundColor White
}
Write-Host ('=' * 66) -ForegroundColor DarkMagenta

# --- Log ----------------------------------------------------------------------
try {
    $logPath = Join-Path $logDir "restore-$stamp.json"
    $report = [ordered]@{
        timestamp            = (Get-Date).ToString('o')
        computerName         = $env:COMPUTERNAME
        mode                 = $(if ($Apply) { 'apply' } else { 'preview' })
        scope                = $Scope
        source               = $(if ($snap) { "snapshot:$FromSnapshot" } else { 'defaults-table' })
        manifestGeneratedUtc = $manifest.generatedUtc
        backupDir            = $(if ($Apply) { $backupDir } else { $null })
        summary              = [ordered]@{ restored = $restored; planned = $planned; failed = $failed; unknown = $unknownN; manual = $manual }
        actions              = $actions
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8
    Write-Host "  Log: $logPath" -ForegroundColor DarkGray
} catch {
    Write-Host "  WARN: could not write log: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($Apply) {
    Write-Host ''
    Write-Host '  Reboot to finish. Explorer settings, VBS, and BCD changes need one.' -ForegroundColor White
}
Write-Host ''
