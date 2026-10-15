#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Read-only. Run on a PC installed from a Chamber ISO when AME's OOBE did not run.
Saves findings next to this script (copy it to the install USB first), in
ChamberIsoDiag-<timestamp>. Changes nothing on the system.

  powershell -ExecutionPolicy Bypass -File E:\Collect-ChamberIsoDiag.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$out = Join-Path $PSScriptRoot ('ChamberIsoDiag-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$ameRoot = Join-Path $env:ProgramData 'AME'

function Write-Section {
    param([string]$Name, [scriptblock]$Collect)
    $path = Join-Path $out ($Name + '.txt')
    try { & $Collect 2>&1 | Out-String -Width 400 | Set-Content -LiteralPath $path -Encoding UTF8 }
    catch { "ERROR: $($_.Exception.Message)" | Set-Content -LiteralPath $path -Encoding UTF8 }
}

function Copy-IfPresent {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Source) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Section 'summary' {
    $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    "Windows: $($os.DisplayVersion) build $($os.CurrentBuildNumber).$($os.UBR) $($os.EditionID)"
    "Installed: $([DateTimeOffset]::FromUnixTimeSeconds($os.InstallDate).LocalDateTime)"
    ''
    # Injection writes AME's OOBE client as OOBE\OOBE.exe (registered as the
    # `ameoobe` service with --service), plus oobe.conf, playbook.apbx and the
    # extracted Playbook folder the first-boot run executes from.
    foreach ($path in @($ameRoot, "$ameRoot\OOBE", "$ameRoot\OOBE\OOBE.exe", "$ameRoot\OOBE\oobe.conf", "$ameRoot\OOBE\playbook.apbx", "$ameRoot\OOBE\Playbook", "$ameRoot\OOBE\Playbook\Executables\Browsers", 'C:\ChamberTech', 'C:\ChamberTech\deployment-receipt.json')) {
        '{0,-70} {1}' -f $path, (Test-Path -LiteralPath $path)
    }
    ''
    # Injection swaps msoobe.exe for AME's shim and keeps Microsoft's original
    # as msoobeext.exe; the shim hands off to AME's OOBE and can fall back to
    # msoobeext.exe. Shim present = AME was bypassed at runtime; shim gone =
    # something replaced it before first boot. 59904 bytes is the shim size in
    # the AME build this was written against; other builds may differ.
    foreach ($name in @('msoobe.exe', 'msoobeext.exe')) {
        $file = Get-Item -LiteralPath "$env:SystemRoot\System32\oobe\$name" -ErrorAction SilentlyContinue
        if ($null -eq $file) { "${name}: absent"; continue }
        "${name}: size $($file.Length), modified $($file.LastWriteTime), version $($file.VersionInfo.FileVersion), company $($file.VersionInfo.CompanyName), signature $((Get-AuthenticodeSignature -LiteralPath $file.FullName).Status)"
    }
    "msoobe.exe AME shim size in the image: 59904"
}
Write-Section 'ame-hooks' {
    "== ameoobe service"
    $service = 'HKLM:\SYSTEM\CurrentControlSet\Services\ameoobe'
    if (Test-Path -LiteralPath $service) { Get-ItemProperty -LiteralPath $service | Format-List } else { 'absent' }
    "== Winlogon shell"
    (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').Shell
    "== Setup state"
    Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' | Select-Object OOBEInProgress, SetupType, SystemSetupInProgress, OOBEInProgressDriverUpdatesPostponed, CmdLine | Format-List
    "== OOBE policy"
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
    if (Test-Path -LiteralPath $policy) { Get-ItemProperty -LiteralPath $policy | Format-List } else { 'absent' }
}
Write-Section 'ame-tree' {
    if (Test-Path -LiteralPath $ameRoot) {
        Get-ChildItem -LiteralPath $ameRoot -Recurse -Force |
            Where-Object { $_.FullName -notmatch '\\OOBE\\(Playbook|Drivers)\\' } |
            Format-Table FullName, Length, LastWriteTime -AutoSize
    } else { "$ameRoot absent" }
}
Write-Section 'updates' { Get-HotFix | Sort-Object InstalledOn | Format-Table HotFixID, Description, InstalledOn -AutoSize }
Write-Section 'oobe-registry' {
    foreach ($key in @('HKLM:\SYSTEM\Setup', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE')) {
        "== $key"
        if (Test-Path -LiteralPath $key) { Get-ItemProperty -LiteralPath $key | Format-List } else { 'absent' }
    }
}
Write-Section 'events-app-errors' {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = (Get-Date).AddDays(-3) } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match '\.NET Runtime|Application Error' -or $_.Message -match 'AME|msoobe|oobe_shim|TrustedUninstaller' } |
        Select-Object -First 50 | Format-List TimeCreated, ProviderName, Id, Message
}
Write-Section 'events-setup' { Get-WinEvent -LogName Setup -MaxEvents 100 -ErrorAction SilentlyContinue | Format-List TimeCreated, Id, Message }

# AME's own small files (logs, configs), skipping the playbook and driver payloads.
if (Test-Path -LiteralPath $ameRoot) {
    Get-ChildItem -LiteralPath $ameRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.log', '.txt', '.json', '.conf', '.xml' -and $_.Length -lt 20MB -and $_.FullName -notmatch '\\OOBE\\(Playbook|Drivers)\\' } |
        ForEach-Object { Copy-IfPresent $_.FullName (Join-Path $out ('AME' + $_.DirectoryName.Substring($ameRoot.Length))) }
}
foreach ($item in @('setupact.log', 'setuperr.log', 'unattend.xml', 'UnattendGC')) {
    Copy-IfPresent (Join-Path "$env:SystemRoot\Panther" $item) (Join-Path $out 'Panther')
}
Copy-IfPresent "$env:SystemRoot\System32\Sysprep\Panther\setupact.log" (Join-Path $out 'Sysprep-Panther')
Get-ChildItem -LiteralPath "$env:SystemRoot\Temp" -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'AME|oobe|Playbook' -and $_.Length -lt 20MB } |
    ForEach-Object { Copy-IfPresent $_.FullName (Join-Path $out 'WindowsTemp') }

Write-Output "Saved to $out"
