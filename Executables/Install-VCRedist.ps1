#Requires -Version 5.1
<#
Chamber - install the Visual C++ 2015-2022 (v14) runtimes, x64 and x86.

Up to 1.3.0 the runtimes were only installed from Executables\vcredist_all.exe,
a file that is git-ignored and therefore never present in the release build.
Every install from a published .apbx skipped the step, and apps built against
the v14 runtime - the NVIDIA App among them - failed at launch looking for
VCRUNTIME140.dll, VCRUNTIME140_1.dll or MSVCP140.dll.

The installers are downloaded from Microsoft's permanent links at run time. A
traditional run has internet (it uses winget for the browser), and an injected
OOBE is gated on a connection by <Internet>Force</Internet>. They are not
cached at ISO injection: AME requires every cached !download to have a
<Software> tile, and 1.3.1's untiled VC++ downloads crashed its ISO page.

The installer must carry a valid Authenticode signature from Microsoft before
it runs - the same rule Install-CachedBrowser.ps1 applies to browser payloads
(NFR-003).

The script always exits 0. A missing runtime is fixable afterwards from
Microsoft's download page; a stalled OOBE is not (NFR-001).

Usage:
    Install-VCRedist.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# RegistryKeys is the installer's own "installed" marker. The bundle is 32-bit,
# so on x64 Windows both architectures land under WOW6432Node; the native path
# is checked too in case that ever changes.
$Catalog = [ordered]@{
    x64 = @{
        FileName     = 'VC_redist.x64.exe'
        Url          = 'https://aka.ms/vc14/vc_redist.x64.exe'
        RegistryKeys = @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
            'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
        )
    }
    x86 = @{
        FileName     = 'VC_redist.x86.exe'
        Url          = 'https://aka.ms/vc14/vc_redist.x86.exe'
        RegistryKeys = @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86',
            'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'
        )
    }
}

$SignerPatterns        = @('CN=Microsoft Corporation')
$InstallTimeoutSeconds = 600
$DownloadDir           = Join-Path $env:TEMP 'Chamber-VCRedist'

function Test-RuntimeInstalled {
    param([string[]]$Keys)
    foreach ($key in $Keys) {
        $value = Get-ItemProperty -LiteralPath $key -Name 'Installed' -ErrorAction SilentlyContinue
        if ($value -and $value.Installed -eq 1) { return $true }
    }
    return $false
}

function Test-TrustedPayload {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'not found' }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt 1MB) { return "only $size bytes - truncated download" }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
    } catch {
        return "could not read the Authenticode signature: $($_.Exception.Message)"
    }
    if ($sig.Status -ne 'Valid') { return "Authenticode signature is $($sig.Status), not Valid" }
    $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
    $trusted = @($SignerPatterns | Where-Object { $subject -match [regex]::Escape($_) })
    if ($trusted.Count -eq 0) { return "signed by an unexpected publisher: $subject" }
    return $null
}

function Get-RuntimePayload {
    param([string]$Arch, [hashtable]$Spec)

    $target = Join-Path $DownloadDir $Spec.FileName
    try {
        New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Spec.Url -OutFile $target -UseBasicParsing
    } catch {
        Write-Host "  [SKIP] Could not download the $Arch runtime: $($_.Exception.Message)"
        return $null
    }

    $problem = Test-TrustedPayload -Path $target
    if ($problem) {
        Write-Host "  [SKIP] Downloaded $Arch installer rejected: $problem"
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $target
}

$failed = @()
foreach ($arch in $Catalog.Keys) {
    $spec = $Catalog[$arch]
    Write-Host "Installing the Visual C++ 2015-2022 runtime ($arch)..."

    $payload = Get-RuntimePayload -Arch $arch -Spec $spec
    if (-not $payload) { $failed += $arch; continue }

    try {
        $proc = Start-Process -FilePath $payload -ArgumentList @('/install', '/quiet', '/norestart') -PassThru
        if (-not $proc.WaitForExit($InstallTimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            Write-Host "  [FAIL] Installer did not finish within $InstallTimeoutSeconds seconds and was stopped."
            $failed += $arch
            continue
        }
        $code = $proc.ExitCode
    } catch {
        Write-Host "  [FAIL] Could not start the installer: $($_.Exception.Message)"
        $failed += $arch
        continue
    }

    # 3010: success, reboot required (the run ends in a restart anyway).
    # 1638: a newer version of the same runtime is already installed.
    if ($code -ne 0 -and $code -ne 3010 -and $code -ne 1638) {
        Write-Host "  [FAIL] Installer exited with code $code."
        $failed += $arch
        continue
    }

    if (-not (Test-RuntimeInstalled -Keys $spec.RegistryKeys)) {
        Write-Host "  [FAIL] Installer exited with code $code but the runtime is not registered as installed."
        $failed += $arch
        continue
    }

    Write-Host "  Visual C++ runtime ($arch) installed (exit code $code)."
}

Remove-Item -LiteralPath $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failed.Count -gt 0) {
    Write-Host "[WARN] Visual C++ runtime not installed for: $($failed -join ', ')."
    Write-Host '       Install it later from https://aka.ms/vc14/vc_redist.x64.exe (and .x86.exe).'
}
exit 0
