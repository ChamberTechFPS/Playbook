#Requires -Version 5.1
<#
Chamber - deployment receipt writer.

Records what was actually selected and what actually happened, at
C:\ChamberTech\deployment-receipt.json. Verify-Chamber.ps1 reads it, and the
client support report ships it.

The problem it solves (PRD FR-034): the verifier can see that an optional
setting is not applied, but it cannot tell "the ISO creator never selected this"
apart from "it was selected and it failed". Those need different support
answers. AME does not expose the selected option set to the playbook - whether
it ever will is PRD open question 4 - so nothing here infers a selection from
system state. Each option is recorded because AME ran an action gated on that
option, which is the only trustworthy signal available.

Every invocation exits 0. This runs inside an unattended OOBE where a
non-zero exit either stalls on a dialog or marks the deployment failed; a
receipt is diagnostic data, and losing it must never cost the user a desktop.

Usage (one concern per call, so each can be gated on its own AME option):
    -Init -Mode ISO-OOBE|Traditional
    -AddOption <option-name>
    -SetBrowser <option-name> -Result Installed|Skipped|Failed [-Detail <text>]
    -Complete
#>
[CmdletBinding(DefaultParameterSetName = 'Init')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Init')]
    [switch]$Init,

    [Parameter(Mandatory, ParameterSetName = 'Init')]
    [ValidateSet('ISO-OOBE', 'Traditional')]
    [string]$Mode,

    [Parameter(Mandatory, ParameterSetName = 'AddOption')]
    [string]$AddOption,

    [Parameter(Mandatory, ParameterSetName = 'Browser')]
    [string]$SetBrowser,

    [Parameter(Mandatory, ParameterSetName = 'Browser')]
    [ValidateSet('Installed', 'Skipped', 'Failed')]
    [string]$Result,

    [Parameter(ParameterSetName = 'Browser')]
    [string]$Detail = '',

    [Parameter(Mandatory, ParameterSetName = 'Complete')]
    [switch]$Complete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Must equal <Version> in playbook.conf. tools/validate_playbook_conf.py fails
# the build if the two drift, because the receipt is the only record of which
# Chamber built a given machine and a stale number here is worse than none.
$ChamberVersion = '1.3.0'

$receiptDir  = 'C:\ChamberTech'
$receiptPath = Join-Path $receiptDir 'deployment-receipt.json'

function Get-Receipt {
    if (Test-Path -LiteralPath $receiptPath) {
        try {
            return Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        } catch {
            # Corrupt or truncated - a half-written receipt is worth less than a
            # fresh one, and the run that follows will repopulate it.
            Write-Host "[WARN] Receipt at $receiptPath is unreadable; starting a new one."
        }
    }
    return $null
}

function New-Receipt {
    param([string]$InstallMode)

    $ver = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    return [pscustomobject][ordered]@{
        schema          = 1
        chamberVersion  = $ChamberVersion
        installMode     = $InstallMode
        startedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        completedUtc    = $null
        computerName    = $env:COMPUTERNAME
        windows         = [pscustomobject][ordered]@{
            caption        = if ($os)  { $os.Caption } else { $null }
            build          = if ($ver) { "$($ver.CurrentBuildNumber).$($ver.UBR)" } else { $null }
            displayVersion = if ($ver) { $ver.DisplayVersion } else { $null }
        }
        selectedOptions = @()
        browser         = [pscustomobject][ordered]@{
            option = $null
            result = $null
            detail = ''
        }
    }
}

function Save-Receipt {
    param($Receipt)
    if (-not (Test-Path -LiteralPath $receiptDir)) {
        New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    }
    $Receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Init' {
            Save-Receipt (New-Receipt -InstallMode $Mode)
            Write-Host "Chamber deployment receipt started at $receiptPath (mode: $Mode)."
        }

        'AddOption' {
            # Init runs first in 10-finalize, but a receipt can be missing if a
            # partial run is resumed. Rebuilding beats dropping the record.
            $r = Get-Receipt
            if (-not $r) { $r = New-Receipt -InstallMode 'Unknown' }
            $existing = @($r.selectedOptions)
            if ($existing -notcontains $AddOption) {
                $r.selectedOptions = @($existing + $AddOption)
            }
            Save-Receipt $r
            Write-Host "Recorded selected option: $AddOption"
        }

        'Browser' {
            $r = Get-Receipt
            if (-not $r) { $r = New-Receipt -InstallMode 'Unknown' }
            $r.browser.option = $SetBrowser
            $r.browser.result = $Result
            $r.browser.detail = $Detail
            Save-Receipt $r
            Write-Host "Recorded browser outcome: $SetBrowser = $Result $Detail"
        }

        'Complete' {
            $r = Get-Receipt
            if (-not $r) { $r = New-Receipt -InstallMode 'Unknown' }
            $r.completedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-Receipt $r
            Write-Host "Chamber deployment receipt completed at $receiptPath."
        }
    }
} catch {
    Write-Host "[WARN] Could not update the Chamber deployment receipt: $($_.Exception.Message)"
}

exit 0
