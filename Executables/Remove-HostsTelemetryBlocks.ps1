#Requires -Version 5.1
<#
Chamber - hosts file cleanup (phase 5)

Chamber 1.2.x and 1.3.0 added the six lines below to the hosts file to
block telemetry servers. 1.4.0 stopped adding them, for two reasons:
  - Chamber leaves Microsoft Defender on, and Defender reports hosts entries
    that block Microsoft telemetry domains as SettingsModifier:Win32/HostsFileHijack
    and can strip them, so the block was not reliable and raised a threat alert.
  - The domains are mostly legacy endpoints. Telemetry is already stopped by the
    DiagTrack service, the AllowTelemetry policies and the IFEO blocks.

This script removes exactly those six lines on an in-place upgrade and leaves
every other hosts entry alone. On a machine that never had them it changes
nothing. tools/generate_verification_manifest.py reads the list from this file,
and Verify-Chamber.ps1 checks that none of them remain.

Exit codes: 0 done (or nothing to do); non-zero only if the file stayed locked.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

$retired = @(
    '0.0.0.0 vortex.data.microsoft.com',
    '0.0.0.0 settings-win.data.microsoft.com',
    '0.0.0.0 telemetry.microsoft.com',
    '0.0.0.0 watson.telemetry.microsoft.com',
    '0.0.0.0 statsfe2.ws.microsoft.com',
    '0.0.0.0 statsfe1.ws1.microsoft.com'
)

if (-not (Test-Path -LiteralPath $hostsPath)) {
    Write-Host 'No hosts file - nothing to clean up.'
    exit 0
}

$tempPath = $hostsPath + '.tmp'

# Defender or a DNS client can hold the file briefly; retry rather than fail.
for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        $lines = [System.IO.File]::ReadAllLines($hostsPath)
        $keep = @($lines | Where-Object { $retired -notcontains $_.Trim() })
        $removed = $lines.Count - $keep.Count
        if ($removed -eq 0) {
            Write-Host 'No Chamber hosts entries found - nothing to clean up.'
            break
        }
        # Write to temp first, then overwrite the hosts file explicitly.
        # File.Move cannot replace an existing destination on Windows.
        [System.IO.File]::WriteAllLines($tempPath, [string[]]$keep, [System.Text.Encoding]::ASCII)
        Copy-Item -LiteralPath $tempPath -Destination $hostsPath -Force
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $removed retired Chamber hosts entr$(if ($removed -eq 1) { 'y' } else { 'ies' })."
        break
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($attempt -eq 10) {
            throw
        }
        Start-Sleep -Milliseconds 500
    }
}
