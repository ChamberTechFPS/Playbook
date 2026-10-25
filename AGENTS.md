# Repository Guidelines

## Project Structure & Module Organization
`Configuration/main.yml` is entry point for AME Wizard and runs numbered phase files in `Configuration/Tasks/`. Keep task files ordered and named with numeric prefixes such as `1-power.yml` and `10-finalize.yml`. Store optional bundled installers and helper scripts in `Executables/`; `Executables/Browsers/` is where AME caches the selected browser installer during ISO injection and is git-ignored. `Images/` holds the OOBE software tile icons AME resolves from `playbook.conf`'s `<Software>` block, and must ship inside the `.apbx`. Root files `playbook.conf` and `Chamber.apbx` are packaging artifacts.

`Configuration/Tasks/0-iso-cache.yml` is the only task that runs at ISO-injection time, and it contains nothing but `!download` actions. Everything else runs live - during the OOBE for an injected install, or on the running system for a traditional one. Do not stage an existing phase to injection: `!cmd`, `!run`, `!powerShell`, `!taskKill`, `!appx` and `!systemPackage` fail AME's `IsISOCompatible()` outright (and `!service` does for anything but delete/change), aborting playbook parsing, and moving a script offline needs its own proof and rollback plan. Within a task, `oobe: false` means traditional-run-only, `oobe: only` means injected-OOBE-only, and no annotation means both.

## Build, Test, and Development Commands
Package from the repository root with `7z a -p"malte" -mhe=on -mx=9 "Chamber.apbx" playbook.conf playbook.png Configuration Executables Images PostInstall "-xr!Browsers" "-xr!Runtimes"`, the same explicit list `.github/workflows/release.yml` uses; never archive the whole folder, which would sweep in `tools/`, docs and local test logs. Excluding `Browsers` and `Runtimes` matters: AME skips an ISO-injection download whose destination already exists, so a locally cached installer that slipped into the archive would be baked into every ISO instead of a fresh one. End-to-end validation happens by loading `Chamber.apbx` into AME Wizard on a fresh Windows 11 install.

## Coding Style & Naming Conventions
YAML uses two-space indentation and one action per block. Keep status labels short and phase-specific. Preserve numeric ordering when adding new tasks. PowerShell should match existing scripts: `#Requires -Version 5.1`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, and approved Verb-Noun function names such as `Get-GpuVendor` or `Write-Header`. Prefer explicit paths and fail-fast behavior over silent recovery.

## Testing Guidelines
No automated test suite is checked in. Validate changes in an isolated VM or sacrificial fresh Windows 11 install. For task YAML, test only affected phase first, then full playbook run. For PowerShell, run elevated and verify both success path and skip/fallback path. Changes under `10-finalize.yml` must be tested with and without internet, `winget`, and optional `Executables/DirectX` or `vcredist_all.exe` payloads.

## Commit & Pull Request Guidelines
Local workspace has no `.git` metadata, so no commit history is available to mirror. Use short imperative subjects like `Add winget connectivity warning` or `Split OLED safety script`. PRs should list touched phases/scripts, Windows version tested (`24H2`, `25H2`, or `26H2`), VM vs. bare-metal coverage, and any user-visible menu or installer changes. Include rollback notes for registry, BCD, service, privacy, or security edits.

## Safety & Configuration Notes
This repository changes boot settings, services, registry, telemetry blocks, and optional security features. Test on non-production machines first. Do not add third-party installers to source control unless redistribution is allowed; place them in `Executables/` only for packaging and local release builds.
