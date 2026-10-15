#Requires -Version 5.1
<#
Copies the PostInstall companion folder to C:\ChamberTech\PostInstall, puts a
"Driver Setup" shortcut on the desktop, and arranges for each user's next
sign-in to finish setup (Complete-ChamberSetup.ps1 -Mode User) and then open the
ChamberTech welcome page (PostInstall\Welcome.html), once.

The completion step and the two per-user helpers it calls are copied to
C:\ChamberTech\Setup. On an injected install they are what actually applies
Chamber's per-user settings - see Complete-ChamberSetup.ps1 for why.

Machine-wide on purpose. During an injected OOBE this runs before the person who
will use the PC has ever signed in, so their own Desktop and HKCU may not exist
yet - a per-user shortcut written then can land in the wrong profile or nowhere.
The Public Desktop and the All Users Startup folder exist from the moment
Windows is installed and every account sees them, so the same code is correct
for an injected OOBE and for a traditional run.

The welcome page opens once per user per Chamber run, not on every sign-in:
  - this script writes a fresh run id to C:\ChamberTech\welcome-id.txt
  - Show-ChamberWelcome.cmd (in All Users Startup) compares it with the id that
    user last saw, under HKCU\Software\ChamberTech, and opens the page only when
    they differ. Re-running Chamber therefore shows it again once, which is what
    someone re-applying after an update wants.
The launcher is cmd rather than PowerShell or VBScript: it costs nothing at
sign-in, and VBScript is a removable feature on 24H2+.

Always exits 0. The companion is a convenience; missing it must not fail setup.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir   = Join-Path $PSScriptRoot '..\PostInstall'
$chamberRoot = 'C:\ChamberTech'
$destDir     = Join-Path $chamberRoot 'PostInstall'
$welcomePage = Join-Path $destDir 'Welcome.html'
$runIdFile   = Join-Path $chamberRoot 'welcome-id.txt'
# Outside the /MIR target, so robocopy never deletes it on a re-run.
$launcher    = Join-Path $chamberRoot 'Show-ChamberWelcome.cmd'
$setupDir    = Join-Path $chamberRoot 'Setup'
$completion  = Join-Path $setupDir 'Complete-ChamberSetup.ps1'
$setupFiles  = @('Complete-ChamberSetup.ps1', 'Enable-WindowedGameOptimizations.ps1', 'Enable-OledSafety.ps1')
# The desktop shortcut opens the driver page, not the PostInstall folder. Whoever
# uses the PC only needs drivers; Verify, Restore and START-HERE.bat stay in
# C:\ChamberTech\PostInstall for ChamberTech support, out of the way.
$shortcutName = 'Driver Setup.lnk'
# Names earlier versions used. Removed so an upgrade doesn't leave two icons.
$legacyShortcutNames = @('Chamber Post-Install.lnk')

if (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-Host "[WARN] PostInstall source not found at $sourceDir - skipping install."
    exit 0
}

# A folder made under C:\ inherits Modify for Authenticated Users, but a SYSTEM
# task runs Setup\Complete-ChamberSetup.ps1 from here and every user's sign-in
# runs Show-ChamberWelcome.cmd. Read/execute for users, full control for SYSTEM
# and Administrators only. SIDs rather than names so it works on any language.
try {
    New-Item -ItemType Directory -Path $chamberRoot -Force | Out-Null
    $icaclsOut = & icacls.exe $chamberRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] Could not restrict $chamberRoot (exit $LASTEXITCODE): $($icaclsOut -join ' ')" }
} catch {
    Write-Host "[WARN] Could not restrict ${chamberRoot}: $($_.Exception.Message)"
}

robocopy $sourceDir $destDir /MIR /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Host "[WARN] robocopy failed (exit $LASTEXITCODE) copying PostInstall to $destDir"
    exit 0
}

# The Drivers READMEs ask the user to drop installers here, so users may write
# to Drivers - except Nvidia Settings, whose .bat files get run as administrator
# and therefore stay read-only like the rest of C:\ChamberTech.
$driversDir = Join-Path $destDir 'Drivers'
$nvidiaSettingsDir = Join-Path $driversDir 'NVIDIA\Nvidia Settings'
try {
    if (Test-Path -LiteralPath $driversDir) {
        $icaclsOut = & icacls.exe $driversDir /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] Could not let users add drivers to $driversDir (exit $LASTEXITCODE): $($icaclsOut -join ' ')" }
    }
    if (Test-Path -LiteralPath $nvidiaSettingsDir) {
        $icaclsOut = & icacls.exe $nvidiaSettingsDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] Could not restrict $nvidiaSettingsDir (exit $LASTEXITCODE): $($icaclsOut -join ' ')" }
    }
} catch {
    Write-Host "[WARN] Could not set Drivers folder permissions: $($_.Exception.Message)"
}

$shell = New-Object -ComObject WScript.Shell

# --- Desktop shortcut -----------------------------------------------------
try {
    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $lnk = $shell.CreateShortcut((Join-Path $publicDesktop $shortcutName))
    $lnk.TargetPath       = $welcomePage
    $lnk.WorkingDirectory = $destDir
    # 12 is shell32's chip icon, so it reads as hardware rather than a web link.
    $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,12"
    $lnk.Description      = 'The drivers this PC needs, with download links'
    $lnk.Save()
    Write-Host "Desktop shortcut added for all users: $publicDesktop\$shortcutName"
} catch {
    Write-Host "[WARN] Could not create the desktop shortcut: $($_.Exception.Message)"
}

# Chamber 1.2.x wrote its shortcut to the running user's own Desktop, and 1.3.0
# test builds used another name on the Public Desktop. Both go on an upgrade.
foreach ($desktop in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
    foreach ($name in $legacyShortcutNames) {
        try {
            $legacy = Join-Path $desktop $name
            if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force }
        } catch { }
    }
}

# --- Setup completion files ----------------------------------------------
try {
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
    foreach ($file in $setupFiles) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $setupDir -Force
    }
} catch {
    Write-Host "[WARN] Could not copy the setup completion files: $($_.Exception.Message)"
}

# --- First sign-in: finish setup, then the welcome page -------------------
if (-not (Test-Path -LiteralPath $welcomePage)) {
    Write-Host "[WARN] $welcomePage is missing - setup will still finish at sign-in, but no page opens."
}

try {
    [guid]::NewGuid().ToString('N') | Set-Content -LiteralPath $runIdFile -Encoding ASCII

    # `set /p` reads the first line of the id file; `for /f` pulls the REG_SZ
    # data (third token) out of reg query's output. Doubled % because this is a
    # batch file, not an interactive prompt. reg.exe and find.exe are called by
    # full path so a `find` earlier on PATH (Git's, for one) cannot shadow it.
    $cmd = @(
        '@echo off'
        'rem Chamber: once per user per Chamber run, finishes setup for this user and'
        'rem opens the ChamberTech welcome page.'
        'rem Written by Executables\Install-PostInstallCompanion.ps1. Safe to delete.'
        "if not exist `"$runIdFile`" exit /b 0"
        "set /p RUNID=<`"$runIdFile`""
        'set SEEN='
        'for /f "tokens=3" %%a in (''%SystemRoot%\System32\reg.exe query "HKCU\Software\ChamberTech" /v WelcomeSeen 2^>nul ^| %SystemRoot%\System32\find.exe "WelcomeSeen"'') do set SEEN=%%a'
        'if "%SEEN%"=="%RUNID%" exit /b 0'
        '%SystemRoot%\System32\reg.exe add "HKCU\Software\ChamberTech" /v WelcomeSeen /t REG_SZ /d "%RUNID%" /f >nul'
        "if exist `"$completion`" `"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$completion`" -Mode User"
        "if exist `"$welcomePage`" start `"`" `"$welcomePage`""
    )
    $cmd | Set-Content -LiteralPath $launcher -Encoding ASCII

    $startup = [Environment]::GetFolderPath('CommonStartup')
    $lnk = $shell.CreateShortcut((Join-Path $startup 'Chamber Welcome.lnk'))
    $lnk.TargetPath       = $launcher
    $lnk.WorkingDirectory = $chamberRoot
    # 7 = minimised, so the console never flashes over the desktop.
    $lnk.WindowStyle      = 7
    $lnk.Description      = 'Finishes Chamber setup and opens the welcome page, once per user'
    $lnk.Save()
    Write-Host 'Setup will finish and the welcome page will open at the next sign-in.'
} catch {
    Write-Host "[WARN] Could not schedule the welcome page: $($_.Exception.Message)"
}

Write-Host "Post-Install companion copied to $destDir."
exit 0
