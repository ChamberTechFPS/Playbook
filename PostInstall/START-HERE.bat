@echo off
title Chamber - Post-Install
:menu
cls
echo.
echo   ============================================
echo     CHAMBER - POST-INSTALL
echo   ============================================
echo.
echo    [1]  Verify system (checks every tweak)
echo    [2]  Verify + create support report zip
echo    [3]  Open Drivers folder
echo    [4]  Read the guide
echo    [W]  Open the driver setup page
echo.
echo    --- Undo -----------------------------------
echo    [5]  Preview restore (shows changes, changes nothing)
echo    [6]  Restore system (undoes the playbook)
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
echo     CHAMBER - RESTORE SYSTEM
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
echo    [1]  Restore now
echo    [2]  Restore, including HAGS and Xbox
echo    [B]  Back to menu
echo.
set /p rchoice="   Select: "
if /i "%rchoice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Restore-Chamber.ps1" -Apply & pause & goto menu
if /i "%rchoice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Restore-Chamber.ps1" -Apply -IncludeHags -IncludeXbox & pause & goto menu
if /i "%rchoice%"=="B" goto menu
goto restore
