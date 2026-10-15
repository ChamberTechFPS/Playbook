#Requires -Version 5.1
<#
Chamber - turn on "Optimizations for windowed games" (phase 4)

Settings > System > Display > Graphics > Optimizations for windowed games.
Moves DirectX 10/11 games running windowed or borderless from the legacy blt
presentation model to flip model: lower present latency, independent flip so
DWM stops compositing the game, and VRR / Auto HDR work in borderless. DX12
games already use flip model and are unaffected.

All of DirectX's per-user graphics toggles share one string value -
"SwapEffectUpgradeEnable=1;AutoHDREnable=1;VRROptimizeEnable=0;" and so on - so
a plain registry write would wipe whatever Auto HDR or VRR choice the user
already made. This script merges only the SwapEffectUpgradeEnable key and keeps
every other key as it was.

Writes the hive of the user it runs as, which is why the task runs it with
runas: currentUserElevated.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$KeyPath   = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$ValueName = 'DirectXUserGlobalSettings'

function Get-DirectXSettings {
    $current = ''
    if (Test-Path -LiteralPath $KeyPath) {
        $item = Get-ItemProperty -LiteralPath $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($item) { $current = [string]$item.$ValueName }
    }
    # Ordered so the rewritten string keeps the user's key order.
    $pairs = [ordered]@{}
    foreach ($part in ($current -split ';')) {
        $kv = $part.Trim()
        if ($kv -match '^([^=]+)=(.*)$') { $pairs[$Matches[1]] = $Matches[2] }
    }
    return $pairs
}

$settings = Get-DirectXSettings
$settings['SwapEffectUpgradeEnable'] = '1'

$joined = (($settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') + ';'

if (-not (Test-Path -LiteralPath $KeyPath)) { New-Item -Path $KeyPath -Force | Out-Null }
Set-ItemProperty -LiteralPath $KeyPath -Name $ValueName -Value $joined -Type String

Write-Host "[Chamber] Optimizations for windowed games on ($ValueName = $joined)"
exit 0
