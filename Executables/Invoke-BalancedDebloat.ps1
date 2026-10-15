#Requires -Version 5.1
param(
    [switch]$XboxOnly,
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:ProgramData 'ChamberPostInstall'
$LogDir = Join-Path $StateDir 'logs'
$LogPath = Join-Path $LogDir ("{0}-balanced-debloat.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Initialize-DebloatLog {
    foreach ($path in @($StateDir, $LogDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
    }
}

function Write-DebloatLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    Initialize-DebloatLog
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format o), $Level, $Message
    [System.IO.File]::AppendAllText($LogPath, "$line`r`n", [System.Text.Encoding]::UTF8)
    Write-Host $Message
}

function New-DebloatTarget {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string[]]$AppxNames
    )

    [pscustomobject]@{
        DisplayName = $DisplayName
        AppxNames   = $AppxNames
    }
}

$BalancedTargets = @(
    New-DebloatTarget -DisplayName 'Outlook for Windows' -AppxNames @('Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps')
    New-DebloatTarget -DisplayName 'Solitaire and casual games' -AppxNames @('Microsoft.MicrosoftSolitaireCollection')
    New-DebloatTarget -DisplayName 'Microsoft Teams consumer app' -AppxNames @('MSTeams', 'MicrosoftTeams', 'Microsoft.MicrosoftTeams')
    New-DebloatTarget -DisplayName 'Clipchamp' -AppxNames @('Clipchamp.Clipchamp')
    New-DebloatTarget -DisplayName 'Microsoft Copilot app' -AppxNames @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider')
    New-DebloatTarget -DisplayName 'Widgets and web experience' -AppxNames @('MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime')
    New-DebloatTarget -DisplayName 'Phone Link' -AppxNames @('Microsoft.YourPhone')
    New-DebloatTarget -DisplayName 'Bing and MSN apps' -AppxNames @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.BingFinance', 'Microsoft.BingSports')
    New-DebloatTarget -DisplayName 'Feedback Hub and Get Help' -AppxNames @('Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp', 'Microsoft.Getstarted')
    New-DebloatTarget -DisplayName 'Media apps' -AppxNames @('Microsoft.ZuneVideo', 'Microsoft.ZuneMusic', 'Microsoft.WindowsSoundRecorder')
    New-DebloatTarget -DisplayName 'Family, People, and To Do' -AppxNames @('MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.People', 'Microsoft.Todos')
    New-DebloatTarget -DisplayName 'Power Automate, Whiteboard, and Maps' -AppxNames @('Microsoft.PowerAutomateDesktop', 'Microsoft.Whiteboard', 'Microsoft.WindowsMaps')
    New-DebloatTarget -DisplayName 'Office hub and extra productivity apps' -AppxNames @('Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftPowerBIForWindows')
    New-DebloatTarget -DisplayName 'Spotify' -AppxNames @('SpotifyAB.SpotifyMusic')
    New-DebloatTarget -DisplayName 'Dev Home' -AppxNames @('Microsoft.Windows.DevHome', 'MicrosoftCorporationII.DevHome', 'Microsoft.DevHome')
    New-DebloatTarget -DisplayName 'LinkedIn and Skype' -AppxNames @('7EE7776C.LinkedInforWindows', 'Microsoft.LinkedIn', 'Microsoft.SkypeApp')
    New-DebloatTarget -DisplayName 'Cortana and Mixed Reality Portal' -AppxNames @('Microsoft.549981C3F5F10', 'Microsoft.MixedReality.Portal')
    New-DebloatTarget -DisplayName 'Sticky Notes' -AppxNames @('Microsoft.MicrosoftStickyNotes')
    New-DebloatTarget -DisplayName 'Alarms and Clock' -AppxNames @('Microsoft.WindowsAlarms')
    New-DebloatTarget -DisplayName 'Quick Assist' -AppxNames @('MicrosoftCorporationII.QuickAssist')
)

$XboxTargets = @(
    New-DebloatTarget -DisplayName 'Xbox app and Game Pass app' -AppxNames @('Microsoft.GamingApp', 'Microsoft.XboxApp')
    New-DebloatTarget -DisplayName 'Xbox overlays and identity providers' -AppxNames @('Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay')
)

$PreservedByDefault = @(
    'Microsoft Store',
    'App Installer / winget',
    'Windows Security',
    'Calculator',
    'Notepad',
    'Snipping Tool',
    'Photos',
    'Paint',
    'Xbox and Game Pass apps unless Remove Xbox Services is selected'
)

function Show-DebloatList {
    Write-Host ''
    Write-Host 'Balanced bloat removal targets:' -ForegroundColor Cyan
    foreach ($target in $BalancedTargets) {
        Write-Host "  - $($target.DisplayName)" -ForegroundColor White
    }
    Write-Host '  - OneDrive (win32 uninstall)' -ForegroundColor White
    Write-Host ''
    Write-Host 'Xbox removal targets, only if Remove Xbox Services is selected:' -ForegroundColor Cyan
    foreach ($target in $XboxTargets) {
        Write-Host "  - $($target.DisplayName)" -ForegroundColor White
    }
    Write-Host ''
    Write-Host 'Preserved by default:' -ForegroundColor Cyan
    foreach ($item in $PreservedByDefault) {
        Write-Host "  - $item" -ForegroundColor White
    }
    Write-Host ''
}

function Remove-AppxTarget {
    param([string]$Name)

    $removedSomething = $false

    try {
        $installed = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
    } catch {
        $installed = @()
        Write-DebloatLog "Could not query installed package $Name`: $($_.Exception.Message)" -Level WARN
    }

    foreach ($package in $installed) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            Write-DebloatLog "Removed installed package: $($package.Name) [$($package.PackageFullName)]"
            $removedSomething = $true
        } catch {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                Write-DebloatLog "Removed current-user package: $($package.Name) [$($package.PackageFullName)]"
                $removedSomething = $true
            } catch {
                Write-DebloatLog "Failed to remove installed package $($package.PackageFullName): $($_.Exception.Message)" -Level WARN
            }
        }
    }

    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
    } catch {
        $provisioned = @()
        Write-DebloatLog "Could not query provisioned package $Name`: $($_.Exception.Message)" -Level WARN
    }

    foreach ($package in $provisioned) {
        try {
            [void](Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop)
            Write-DebloatLog "Removed provisioned package: $($package.DisplayName) [$($package.PackageName)]"
            $removedSomething = $true
        } catch {
            Write-DebloatLog "Failed to remove provisioned package $($package.PackageName): $($_.Exception.Message)" -Level WARN
        }
    }

    if (-not $removedSomething) {
        Write-DebloatLog "Not present: $Name"
    }
}

function Remove-OneDrive {
    # OneDrive is a win32 app, not an appx package, so it needs its uninstaller.
    # Exit codes from the uninstallers are unreliable; success is judged by the
    # install disappearing.
    #
    # Two install locations: per user under LOCALAPPDATA (the usual case) and
    # machine-wide under Program Files (/allusers). During an injected OOBE this
    # runs as SYSTEM before any user exists, so the per-user path is SYSTEM's own
    # and is empty; 6-debloat.yml deletes the Default profile's OneDriveSetup Run
    # value so later accounts never install it.
    $perUserExe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
    $machineExe = Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'

    Write-DebloatLog 'Target group: OneDrive'

    $installs = @(
        @{ Exe = $perUserExe; Args = '/uninstall' }
        @{ Exe = $machineExe; Args = '/uninstall /allusers' }
    ) | Where-Object { Test-Path -LiteralPath $_.Exe }

    if (@($installs).Count -eq 0) {
        if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
            Write-DebloatLog 'Not present: OneDrive (running as SYSTEM - new accounts are kept from installing it by the Default profile Run value delete)'
        } else {
            Write-DebloatLog 'Not present: OneDrive'
        }
        return
    }

    Stop-Process -Name 'OneDrive' -Force -ErrorAction SilentlyContinue

    $setupExes = @(
        (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
        (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')
    )

    foreach ($install in $installs) {
        foreach ($exe in ($setupExes + $install.Exe)) {
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            try {
                $proc = Start-Process -FilePath $exe -ArgumentList $install.Args -PassThru -Wait -ErrorAction Stop
                Write-DebloatLog "Ran OneDrive uninstaller: $exe $($install.Args) (exit $($proc.ExitCode))"
            } catch {
                Write-DebloatLog "OneDrive uninstaller failed at $exe`: $($_.Exception.Message)" -Level WARN
                continue
            }
            if (-not (Test-Path -LiteralPath $install.Exe)) { break }
        }
    }

    if (@($installs | Where-Object { Test-Path -LiteralPath $_.Exe }).Count -eq 0) {
        Write-DebloatLog 'OneDrive removed.'
        return
    }

    Write-DebloatLog 'OneDrive still installed after uninstall attempts.' -Level WARN
}

Initialize-DebloatLog

if ($ListOnly) {
    Show-DebloatList
    return
}

$targets = if ($XboxOnly) { $XboxTargets } else { $BalancedTargets }
$scopeLabel = if ($XboxOnly) { 'Xbox optional cleanup' } else { 'balanced inbox bloat cleanup' }

Write-DebloatLog "Starting Chamber $scopeLabel."
Write-DebloatLog "Log path: $LogPath"
Write-DebloatLog 'Preserved by default: Store, App Installer/winget, Windows Security, Calculator, Notepad, Snipping Tool, Photos, Paint, and Xbox/Game Pass unless selected.'

foreach ($target in $targets) {
    Write-DebloatLog "Target group: $($target.DisplayName)"
    foreach ($name in $target.AppxNames) {
        Remove-AppxTarget -Name $name
    }
}

if (-not $XboxOnly) {
    Remove-OneDrive
}

Write-DebloatLog "Finished Chamber $scopeLabel."
