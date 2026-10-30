@echo off
title ChamberTech Playbook - Tools

rem Verify reads, and Restore writes, system settings. Both need an elevated
rem prompt, so stop here with instructions rather than fail halfway through.
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   This needs administrator rights.
    echo   Close this window, right-click START-HERE.bat and choose
    echo   "Run as administrator".
    echo.
    pause
    exit /b 1
)

:menu
cls
echo.
echo   ============================================
echo     CHAMBERTECH PLAYBOOK - TOOLS
echo   ============================================
echo.
echo    [W]  Driver setup page (start here after install)
echo    [3]  Open the Drivers folder
echo    [4]  Read the guide
echo.
echo    --- Check -----------------------------------
echo    [1]  Check my PC (every playbook setting)
echo    [2]  Check my PC + make a support report
echo.
echo    --- Undo ------------------------------------
echo    [5]  Preview undo (shows what would change)
echo    [6]  Undo the playbook
echo.
echo    [Q]  Quit
echo.
set /p choice="   Select: "
if /i "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Verify-Chamber.ps1" & pause & goto menu
if /i "%choice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Verify-Chamber.ps1" -ClientReport & pause & goto menu
if /i "%choice%"=="3" explorer "%~dp0Drivers" & goto menu
if /i "%choice%"=="4" notepad "%~dp0README.txt" & goto menu
if /i "%choice%"=="W" start "" "%~dp0Welcome.html" & goto menu
if /i "%choice%"=="5" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Restore-Chamber.ps1" & pause & goto menu
if /i "%choice%"=="6" goto restore
if /i "%choice%"=="Q" exit /b
goto menu

:restore
cls
echo.
echo   ============================================
echo     CHAMBERTECH PLAYBOOK - UNDO
echo   ============================================
echo.
echo    This undoes what the playbook applied: registry tweaks, service
echo    startup types, boot flags, the power plan, and hosts entries.
echo.
echo    Before changing anything it creates a System Restore point and
echo    backs up every registry key it touches.
echo.
echo    Two things are left alone unless you ask for them:
echo      - HAGS, because turning it off breaks DLSS Frame Generation
echo      - Xbox services, which are only removed if you chose that option
echo.
echo    Apps removed during debloat cannot be brought back automatically.
echo    They are listed at the end for reinstall from the Microsoft Store.
echo.
echo    Option [5] on the main menu previews all of this without changing
echo    a thing. Run that first if you have not already.
echo.
echo    --------------------------------------------
echo    [1]  Undo now
echo    [2]  Undo, including HAGS and Xbox
echo    [B]  Back to menu
echo.
set /p rchoice="   Select: "
if /i "%rchoice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Restore-Chamber.ps1" -Apply & pause & goto menu
if /i "%rchoice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Restore-Chamber.ps1" -Apply -IncludeHags -IncludeXbox & pause & goto menu
if /i "%rchoice%"=="B" goto menu
goto restore
