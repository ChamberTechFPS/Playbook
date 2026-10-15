#Requires -Version 5.1
<#
Chamber - install a browser from the payload cached into the ISO.

Runs only during an injected OOBE. Tasks/0-iso-cache.yml downloads the selected
installer at ISO injection time into Executables\Browsers\; this installs it at
first boot, so no network is needed for the browser (PRD FR-020, FR-025).

Before running anything it checks the payload is present and carries a valid
Authenticode signature from the expected vendor. An installer that fails either
check is skipped, not executed - a tampered or truncated payload running with
elevation during setup is a far worse outcome than no browser (NFR-003).

The script always exits 0. A browser is optional; a stalled or failed OOBE is
not recoverable by the user standing in front of it (NFR-001). Every outcome -
installed, skipped, failed - is written to the Chamber deployment receipt, which
Verify-Chamber.ps1 surfaces and the client support report ships, so a failure is
recorded rather than silent (FR-036).

Usage:
    Install-CachedBrowser.ps1 -Browser Chrome
    Install-CachedBrowser.ps1 -Browser Brave
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Chrome', 'Brave')]
    [string]$Browser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Payload layout, signer expectations and post-install proof, per browser.
#
# SignerPatterns are matched as literal substrings of the certificate subject
# (the values are regex-escaped before use). More than one form is listed per
# vendor on purpose: pinning one exact string turns a routine certificate or
# legal-name change into a silent browser-missing bug on every ISO built after.
#
# Mind the quoting. A subject whose CN contains a comma is emitted quoted, so
# Brave appears as  CN="Brave Software, Inc."  - the pattern must allow for that
# opening quote. Verified 2026-09-08 against the real downloads:
#   Chrome : CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US, ...
#   Brave  : CN="Brave Software, Inc.", O="Brave Software, Inc.", L=San Francisco, ...
# Both issued by DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1.
#
# UNVERIFIED (PRD open question 2): the Chrome file name, its type and the exact
# signer subject must be confirmed against a real download before the offline
# milestone ships. If the enterprise MSI URL in 0-iso-cache.yml changes, change
# FileName here in the same commit - validate_playbook_conf.py fails the build
# when a download destination has no matching entry below.
$Catalog = @{
    Chrome = @{
        FileName       = 'GoogleChromeStandaloneEnterprise64.msi'
        SignerPatterns = @('CN=Google LLC', 'CN="Google LLC', 'CN=Google Inc')
        ProductName    = 'Google Chrome'
        InstalledPaths = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        )
    }
    Brave = @{
        FileName       = 'BraveBrowserStandaloneSilentSetup.exe'
        SignerPatterns = @('CN="Brave Software', 'CN=Brave Software')
        ProductName    = 'Brave'
        InstalledPaths = @(
            "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe"
        )
    }
}

$optionName   = "browser-$($Browser.ToLowerInvariant())"
$spec         = $Catalog[$Browser]
$payload      = Join-Path $PSScriptRoot (Join-Path 'Browsers' $spec.FileName)
$receiptScript = Join-Path $PSScriptRoot 'Write-ChamberReceipt.ps1'

# Long enough for a cold first-boot disk to unpack a browser, short enough that
# a hung installer does not leave the OOBE progress screen frozen (NFR-007).
$InstallTimeoutSeconds = 600

function Write-Receipt {
    param(
        [ValidateSet('Installed', 'Skipped', 'Failed')][string]$Result,
        [string]$Detail
    )
    if (-not (Test-Path -LiteralPath $receiptScript)) { return }
    try {
        & $receiptScript -SetBrowser $optionName -Result $Result -Detail $Detail | Out-Null
    } catch {
        Write-Host "[WARN] Could not record the browser outcome: $($_.Exception.Message)"
    }
}

function Stop-WithSkip {
    param([string]$Reason)
    Write-Host "[SKIP] $($spec.ProductName) was not installed: $Reason"
    Write-Host '       Microsoft Edge remains available; install the browser manually afterwards.'
    Write-Receipt -Result 'Skipped' -Detail $Reason
    exit 0
}

Write-Host "Installing $($spec.ProductName) from the cached ISO payload..."

# --- Presence -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $payload)) {
    Stop-WithSkip "cached installer not found at $payload"
}

$payloadSize = (Get-Item -LiteralPath $payload).Length
if ($payloadSize -lt 1MB) {
    # A few KB here is an error page or an interrupted download that happened to
    # land on disk, not an installer.
    Stop-WithSkip "cached installer at $payload is only $payloadSize bytes - truncated download"
}

# --- Signature ------------------------------------------------------------
try {
    $sig = Get-AuthenticodeSignature -LiteralPath $payload
} catch {
    Stop-WithSkip "could not read the Authenticode signature: $($_.Exception.Message)"
}

if ($sig.Status -ne 'Valid') {
    Stop-WithSkip "Authenticode signature is $($sig.Status), not Valid"
}

$subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
$trusted = @($spec.SignerPatterns | Where-Object { $subject -match [regex]::Escape($_) })
if ($trusted.Count -eq 0) {
    Stop-WithSkip "signed by an unexpected publisher: $subject"
}

Write-Host "  Signature verified: $subject"

# --- Install --------------------------------------------------------------
if ($payload -like '*.msi') {
    $exe  = "$env:SystemRoot\System32\msiexec.exe"
    # Start-Process quotes array elements that contain spaces, so the path is
    # passed raw rather than pre-quoted - pre-quoting would double it up.
    $installArgs = @('/i', $payload, '/qn', '/norestart')
} else {
    $exe  = $payload
    $installArgs = @('/silent', '/install')
}

try {
    $proc = Start-Process -FilePath $exe -ArgumentList $installArgs -PassThru
    if (-not $proc.WaitForExit($InstallTimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        Write-Host "[FAIL] $($spec.ProductName) installer did not finish within $InstallTimeoutSeconds seconds and was stopped."
        Write-Receipt -Result 'Failed' -Detail "installer timed out after $InstallTimeoutSeconds seconds"
        exit 0
    }
    $code = $proc.ExitCode
} catch {
    Write-Host "[FAIL] Could not start the $($spec.ProductName) installer: $($_.Exception.Message)"
    Write-Receipt -Result 'Failed' -Detail "could not start installer: $($_.Exception.Message)"
    exit 0
}

# 3010 is "success, reboot required" - AME restarts at the end of the OOBE
# anyway, so it is a success for our purposes.
if ($code -ne 0 -and $code -ne 3010) {
    Write-Host "[FAIL] $($spec.ProductName) installer exited with code $code."
    Write-Receipt -Result 'Failed' -Detail "installer exit code $code"
    exit 0
}

# --- Proof it actually landed (FR-026) ------------------------------------
$installed = @($spec.InstalledPaths | Where-Object { Test-Path -LiteralPath $_ })
if ($installed.Count -eq 0) {
    Write-Host "[FAIL] $($spec.ProductName) installer reported success but no executable is present."
    Write-Receipt -Result 'Failed' -Detail 'installer succeeded but the browser executable is missing'
    exit 0
}

Write-Host "$($spec.ProductName) installed: $($installed[0])"
Write-Receipt -Result 'Installed' -Detail $installed[0]
exit 0
