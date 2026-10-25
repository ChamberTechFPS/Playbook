# Changelog

All notable changes to Chamber Playbook are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [1.3.1] - 2026-10-25

### Fixed
- **The Visual C++ runtimes were never installed.** Phase 10 only ran `Executables/vcredist_all.exe`, which is git-ignored, so the released `.apbx` never contained it and the step skipped on every install. Apps built on the v14 runtime then failed at launch — the NVIDIA App reported `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll` and `MSVCP140.dll` missing. The new `Executables/Install-VCRedist.ps1` installs the Visual C++ 2015-2022 runtimes (x64 and x86) on every run. An injected install uses the copies `0-iso-cache.yml` now caches into the image; otherwise it downloads them from Microsoft. Either way it requires a valid Microsoft signature before running them, and it always exits 0. `vcredist_all.exe` is still run first when present, for the 2005-2013 runtimes.
- `validate_playbook_conf.py` now accepts unconditional ISO downloads (no `option:`) and `aka.ms` as a vendor host. A download backing a `<Software>` tile must still be gated on that tile's option.
- Rollback: uninstall "Microsoft Visual C++ 2015-2022 Redistributable" (x64 and x86) from Installed apps. Other software may depend on it.

## [1.3.0] - 2026-10-14

Minor bump rather than a patch: ISO injection and system restore are both new capability, not fixes.

### Fixed (first real ISO test: 9800X3D, 26H2 build 26300, offline, 2026-10-07)
The offline Chrome install from the cached payload worked. Verify still reported 9 failures and 1 warning. They had three causes, all specific to running during OOBE:
- **Windows reset per-user settings at the first sign-in.** AME writes HKCU values into the Default profile during OOBE. At the first sign-in Windows then applies its own theme, visual-effects and taskbar defaults, which overwrote `AppsUseLightTheme`, `SystemUsesLightTheme`, `UserPreferencesMask`, `MinAnimate` and `SearchboxTaskbarMode`.
- **Per-user scripts configured SYSTEM.** During OOBE, `runas: currentUserElevated` resolves to SYSTEM; the pre-install snapshot's `userName` was the computer account. Windowed-game optimizations and the classic right-click menu were therefore written to SYSTEM's settings. OLED taskbar auto-hide failed outright, because there is no taskbar during OOBE.
- **Windows re-enabled telemetry after the run.** It set `Diagtrack-Listener\Start` back to 1 and re-enabled `PcaPatchDbTask`.

The fix is the new `Executables/Complete-ChamberSetup.ps1`. It re-applies only what the verification manifest lists, filtered by the options in the deployment receipt, so it has no value list of its own to drift.
- `-Mode User` runs at each account's first sign-in, from the existing Startup launcher, before the Driver Setup page opens. It re-applies HKCU values, the classic menu, windowed-game optimizations and OLED auto-hide, then broadcasts the change so dark mode applies immediately.
- `-Mode Machine` runs once as SYSTEM from the "Chamber Setup Completion" task, which deletes itself. It re-applies HKLM values and scheduled-task states. `10-finalize.yml` registers that task with `oobe: only`.
- The three in-OOBE per-user `!cmd` actions are now `oobe: false`; a traditional run still applies them live.
- Rollback: delete `C:\ChamberTech\Setup`. If the task never ran, also run `schtasks /delete /tn "Chamber Setup Completion" /f`.

### Fixed (release review, 2026-10-14)
- **Restore could stop before restoring anything.** `-Apply` backs up every key the manifest names, and an option that was not selected leaves its key missing. Windows PowerShell 5.1 turned `reg export`'s "unable to find" message into a terminating error, so the run ended right after the user typed RESTORE. Native tools (`reg`, `fsutil`, `bcdedit`, `powercfg`, `netsh`) now run through one helper and are judged by exit code; Restore no longer reports a failed `bcdedit` as RESTORED.
- **Restore did not undo 1.3.0's own additions.** A new `companion` scope (part of `all`) deletes the Startup launcher, the Driver Setup shortcut, `Show-ChamberWelcome.cmd`, `welcome-id.txt`, `C:\ChamberTech\Setup`, a leftover "Chamber Setup Completion" task, the classic context-menu key and `HKCU\Software\ChamberTech`. Without it, the launcher would re-apply Chamber at the next sign-in after a re-run. It reminds you to turn taskbar auto-hide off when OLED protection was selected, and leaves `C:\ChamberTech\PostInstall` and the receipt in place.
- **The pre-install snapshot was wrong on injected installs.** Phase 0 runs as SYSTEM during the OOBE, so it recorded SYSTEM's HKCU, and Restore would have *deleted* the user's mouse, theme and visual-effects values as "not present before Chamber". The snapshot now leaves HKCU out when taken as SYSTEM and says so (`capturedAsSystem`). Restore ignores HKCU in such snapshots, including older ones recognised by a computer-account user name, and uses the defaults table instead. `-Snapshot -PreInstall` also no longer overwrites an existing pre-install snapshot, so a re-run or upgrade keeps the true pre-Chamber state.
- **The power plan never fell back.** If Ultimate Performance could not be duplicated, `powercfg`'s error stopped `Set-ChamberPowerPlan.ps1` instead of trying High Performance and Balanced. A desktop without hibernate support no longer fails the step either.
- **OneDrive stayed on injected installs.** Debloat runs as SYSTEM during the OOBE, so it found no per-user OneDrive and logged "Not present". `6-debloat.yml` now deletes the Default profile's `OneDriveSetup` Run value so new accounts never install it, and the script also uninstalls a machine-wide (`/allusers`) copy. Rollback: OneDrive installs from the Microsoft Store or onedrive.com.
- **Unattended runs could wait on a dialog.** Debloat, DirectX, VC++ and classic-menu actions used `errorAction: Notify`, and eleven `!cmd` actions (bcdedit, fsutil, powercfg, netsh, the hosts script, DisablePagingExecutive) set none. All now use `Log`.
- **`C:\ChamberTech` was writable by every signed-in user** (inherited from `C:\`), while a SYSTEM task runs a script from it. `Install-PostInstallCompanion.ps1` now gives SYSTEM and Administrators full control and Users read/execute only. `PostInstall\Drivers` stays writable by users, since its READMEs ask them to drop installers there, except `Nvidia Settings`, whose `.bat` files get run as administrator. Rollback: `icacls C:\ChamberTech /reset /T`.
- **NVIDIA profile import `.bat` files** used bare relative paths, so *Run as administrator* (which starts in System32) could not find the profile inspector. They now resolve paths from their own folder.

### Fixed (smaller, from the ISO test)
- **Verify windowed-game check:** a missing `DirectXUserGlobalSettings` reported WARN "could not read registry" (a StrictMode throw caught by the catch-all). It now reports FAIL "never set for this user".
- **Verify refresh-rate check:** before the GPU driver is installed, it reported "64 Hz (fastest available)" as PASS on Microsoft Basic Display Adapter. It now reports INFO asking for the GPU driver first.
- **Debloat log:** it said Quick Assist was "preserved by default" while removing it. Quick Assist is removed by design; the log line no longer claims otherwise.

### Removed
- **`GlobalTimerResolutionRequests` = 1** (phase 4), added earlier in this cycle behind a benchmark gate. No CS2 / Fortnite results per `docs/BENCHMARKING.md` were recorded to show a 1% low or frametime win, so it does not ship. Re-add it only with those numbers. Restore no longer carries a default for it.
- **"Turn off Microsoft Defender" (`remove-defender`).** Tamper Protection is on after every fresh install, and Windows ignores Defender's policy and service changes while it is. On the ISO test the option was selected and Defender kept running. Rather than ship an option that silently does nothing, Defender stays on.
  - Its in-game cost is small: the measurable effect is on load times and installs, and Verify already suggests game-folder exclusions for that.
  - `7-security.yml` now deletes `DisableAntiSpyware`, `DisableRealtimeMonitoring` and `DisableAntiVirus`, so an in-place upgrade from an older Chamber also stops Windows Security showing "managed by your organization".
  - The validator rejects the option if it ever returns.
  - Receipts from older runs that list `remove-defender` still read fine.

### Added
- **Driver Setup page at first sign-in.** `ProgressText` already told the first-boot user a page would open when they reached the desktop, but nothing opened one. They reached a bare desktop with a folder shortcut and no instructions. `PostInstall/Welcome.html` is now a self-contained, offline page listing the drivers to install: chipset first, then restart, then GPU, then network if needed. It doesn't mention Verify, undo or the playbook. The support tools (Verify, support report, Restore, the receipt path) are in a collapsed "For ChamberTech support" section at the bottom.
  - `Install-PostInstallCompanion.ps1` schedules the page from the All Users Startup folder through `C:\ChamberTech\Show-ChamberWelcome.cmd`. It opens once per user for each Chamber run: a run id in `C:\ChamberTech\welcome-id.txt` is compared with `HKCU\Software\ChamberTech\WelcomeSeen`.
  - The validator fails if the page is missing, loads anything external, or is no longer scheduled. CI checks that it ships in the `.apbx`.
- **A "Driver Setup" shortcut on the Public Desktop replaces "Chamber Post-Install".** It opens the Driver Setup page instead of the PostInstall folder, so users see drivers, not the support tools. `START-HERE.bat`, Verify and Restore still install to `C:\ChamberTech\PostInstall`. The shortcut goes on the Public Desktop because, during an injected OOBE, the running user's own profile may not exist yet. On upgrade, the old `Chamber Post-Install.lnk` is removed from both the Public Desktop and the running user's Desktop, so you don't get two icons. Rollback: delete `Driver Setup.lnk` from `C:\Users\Public\Desktop`, `Chamber Welcome.lnk` from `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp`, and `C:\ChamberTech`.
- **ARM64 guard.** Chamber is x64 only, and AME has no architecture requirement it can enforce, so an ARM64 machine on a supported build would have run all ten phases untested. The first action in `main.yml` now reads the native `PROCESSOR_ARCHITECTURE` from the Session Manager environment key and halts the run on ARM64 before the snapshot or any phase touches the system — on a normal run and at first boot of an injected ISO. The test lives in the command rather than a `cpuArch:` filter so the guard carries no filters at all; AME's `cpuArch` would also resolve natively. `tools/validate_playbook_conf.py` fails the build if the guard is missing, not first, gated, staged, or not set to halt. `playbook.conf`'s description and the README requirements now say x64 only. How AME's OOBE presents a halt is untested.
- **Playbook metadata AME was defaulting.** `ProgressText` now describes what Chamber is doing instead of AME's generic "Deploying the selected Playbook configuration onto the system." — it shows on the progress screen during a normal run *and* during an injected OOBE. `EstimatedMinutes` set to 5 (was defaulting to 25). `Git` points at the repository, which enables AME's update check and the source-code link. `UpgradableFrom` is `any`, so AME upgrades in place from any earlier Chamber version rather than demanding a fresh install. No `DonateLink` by choice; `Website` is omitted because AME only surfaces it for verified playbooks.
- **Windows 11 26H2 (build 26300) added to `SupportedBuilds`.** Declared ahead of general availability so AME does not refuse to run the playbook the day 26H2 ships. Nothing in Chamber is version-specific — every phase is registry, service, BCD, AppX and `powercfg` work with no 26H2-only API — so the expectation is that it applies cleanly, but **26H2 is unvalidated** until a fresh 26300 install has been run and checked with `Verify-Chamber.ps1`. The README requirements table says so explicitly rather than implying it is tested. `tools/validate_playbook_conf.py` now also rejects malformed or duplicated `SupportedBuilds` entries, since a typo there fails silently by just excluding that release.
- **ISO injection support.** `playbook.conf` now declares `SupportsISO`, an `OOBE` block with the three bullet points AME renders during the injected out-of-box experience, and a `Software` block naming the browser payloads cached into the image. Chamber can be baked into a Windows 11 ISO and applied at first boot instead of run by hand. See [Installation → ISO injection](README.md#iso-injection-experimental).
  - `<Internet>Force</Internet>` — the compatibility-milestone value. It stays until the offline rows of the ISO test matrix pass on a real VM, then becomes `Request` so AME can offer connectivity without blocking progress. The browser itself no longer needs a connection; the connectivity probe and the traditional winget path still do, and this is not a setting to flip on static evidence.
  - `DisableHardwareRequirements` is not set. Chamber does not bypass Windows 11's hardware checks — it targets titles whose anti-cheat requires Secure Boot and TPM 2.0, so a machine that skipped those checks could not run the games the playbook exists for. (`DisableBitLocker` was initially left out too; that was reversed later in 1.3.0 — see the BitLocker entry below.)
  - `iso:` is set on exactly two things: the `!task:` include for `Tasks/0-iso-cache.yml` in `main.yml`, and the `!download` actions inside it — both `iso: only`. It may not spread further. Most actions default to `iso: false` (`!task`, `!download` and `!software` default to `true`), and AME runs its `IsISOCompatible()` gate on every action set to anything else — `!cmd`, `!run`, `!powerShell`, `!taskKill`, `!appx` and `!systemPackage` all reject it outright, and `!service` does outside delete/change, aborting playbook parsing rather than degrading gracefully. The other `!task:` includes are left unannotated: that action type defaults to `iso`/`oobe` both true, so AME walks into every phase file and applies its actions at the OOBE stage, which is exactly what Chamber wants.
  - **Validator:** `tools/validate_playbook_conf.py` re-implements AME's own load-time checks (required fields, version format, exactly three OOBE bullet points with distinct `Rocket`/`Privacy`/`Lock` icons, and the `iso:` gate above) and runs in CI before packaging, so a config AME would reject — or would silently leave out of its injection picker — fails the build instead of a user's install.
- **`Restore-Chamber.ps1`** in `PostInstall/Verify/`. Reverts what the playbook applied, driven by the same `verification-manifest.json` the verifier reads, so it cannot drift from what Chamber actually changes. Preview is the default; nothing is written without `-Apply`.
  - `-Snapshot` captures pre-playbook state to JSON for an exact restore; without one, a documented Windows defaults table covers all 82 registry values and all 20 services.
- **Phase 0 (`Configuration/Tasks/0-snapshot.yml`)** runs before every other phase and captures the machine as Windows shipped it, via `Restore-Chamber.ps1 -Snapshot -PreInstall`. Written to a canonical un-timestamped path so `Restore-Chamber.ps1 -Apply` later finds it with no arguments and performs an exact restore rather than falling back to the defaults table. Uses `errorAction: Log` — a failed snapshot costs an exact restore but is not a reason to abort provisioning.
- **Restore entries in `PostInstall/START-HERE.bat`** — option 5 previews a restore, option 6 opens a confirmation screen explaining what will and won't be reverted, with a second entry for including HAGS and Xbox.
  - Creates a System Restore point and exports every affected registry key before making changes.
  - Scoped reverts via `-Scope`, and `-IncludeHags` / `-IncludeXbox` for the two opt-outs. HAGS is skipped by default because disabling it breaks DLSS Frame Generation on RTX 40/50 cards.
  - Deprovisioned AppX packages cannot be restored without install media; they are reported for Microsoft Store reinstall rather than silently skipped.
- **Offline browser delivery for injected ISOs.** `Configuration/Tasks/0-iso-cache.yml` is a new injection-stage task — the only one — that has AME download the selected Chrome or Brave installer into the image while the ISO is being built. At first boot, `Executables/Install-CachedBrowser.ps1` installs it from that cached copy. The browser no longer depends on winget, the Store, or a network connection during OOBE. *Skip* caches and installs nothing.
  - The cached file is checked for presence, plausible size, and a valid Authenticode signature from the expected vendor before anything runs. A payload that fails any of those is **skipped, not executed** — a tampered installer running elevated during Windows setup is a worse outcome than no browser, and Edge is always there.
  - The script always exits 0 and records the outcome instead. A browser is optional; a stalled or failed OOBE is not something the person in front of the machine can recover from.
  - `<Software>` entries in `playbook.conf` give each browser an OOBE tile. Each entry's name matches its download's `package:` string, as AME's docs recommend (the validator enforces it). The list is display-only in the OOBE today; installation is done by phase 10. Icons live in the new `Images/` folder and ship inside the `.apbx`.
- **Deployment receipt at `C:\ChamberTech\deployment-receipt.json`**, written by `Executables/Write-ChamberReceipt.ps1` during phase 10. Records the Chamber version, Windows build, whether the install was injected or manual, which options were actually selected, and how the browser install went.
  - This closes a real gap in support: an optional setting that is not applied looks identical whether it was never selected or was selected and failed, and the two need opposite answers. AME does not hand the playbook its own option set, so each option is recorded by an action gated on that option — the selection is evidenced, never inferred from a failed setting check.
  - `Verify-Chamber.ps1` reads it, reports install mode and selected options, flags a run that never finished, and confirms the recorded browser against what is actually on disk. The client report ships the receipt as its own file. Machines set up before receipts existed report exactly as they did before.
- **Coverage for the 24H2–26H2 feature set.** 26H2 (build 26300) is an enablement package on the same servicing branch as 24H2 and 25H2: it switches on features Microsoft already shipped in monthly updates rather than adding new ones. Phase 5 now covers those newer surfaces on all three releases:
  - Recall snapshots and Click to Do are turned off by policy (`WindowsAI\DisableAIDataAnalysis`, `DisableClickToDo`). Both exist only on Copilot+ PCs; elsewhere the policies are inert.
  - Bing web results are removed from Start search (`DisableSearchBoxSuggestions`). Side effect: File Explorer's search box no longer lists recent searches.
  - Start recommendations (`Start_IrisRecommendations`) and Microsoft account prompts in Start (`Start_AccountNotifications`) are off.
  - `ContentDeliveryManager` suggestions are off: suggested apps in Start, silent installs of promoted apps, tips and welcome prompts, suggested content in Settings, and lock screen "fun facts".
  - Registry values go from 82 to 98. Verification and restore pick them up from the regenerated manifest; `Restore-Chamber.ps1` deletes each value so Windows falls back to its own default.
  - Checked for 26H2's removal of WMIC: no Chamber script or task calls it.

- **FPS and latency pass.** An audit of every phase against the playbook's goal (highest FPS, lowest latency, anti-cheat intact). Additions:
  - **Optimizations for windowed games** (phase 4) — flip-model presentation for DX10/11 games in windowed and borderless mode, so they get lower present latency, independent flip, and working VRR / Auto HDR. Set by `Executables/Enable-WindowedGameOptimizations.ps1`, which merges only `SwapEffectUpgradeEnable=1` into `DirectXUserGlobalSettings` and keeps the user's other DirectX keys.
  - **MMCSS Games `Priority` = 6** (phase 4). The old comment said 6 was already the Windows default. It is 2 — a Chamber-applied 25H2 machine still read 2.
  - **`UserPreferencesMask` = `9012038010000000`** (phase 4), the "Adjust for best performance" mask. `VisualFXSetting=2` on its own only moves the radio button; the same machine still had the stock `9E1E078012000000`, so menu and tooltip fades and the cursor shadow had stayed on.
  - **Nine telemetry scheduled tasks disabled** (phase 3): Compatibility Appraiser, ProgramDataUpdater, PcaPatchDbTask, MareBackup, CEIP Consolidator and UsbCeip, DiskDiagnosticDataCollector, and both Feedback\Siuf tasks. They fire on timers and idle triggers and land in 1% / 0.1% lows.
  - **Delivery Optimization set to HTTP only** (`DODownloadMode=0`), **Store apps denied background execution** (`LetAppsRunInBackground=2`), and **Edge Startup Boost and background mode off** (phase 5). Side effects: closed Store apps such as Mail and Phone Link stop syncing, and Edge shows "managed by your organization".
  - The manifest gains `scheduledTasks` and `registryDeletes`. Verify checks both, and Restore has a new `tasks` scope. Restore and snapshot now round-trip `REG_BINARY` as hex instead of writing back a decimal string.
  - **Verify reports setup problems the playbook cannot fix**: a monitor below its fastest refresh rate, wired NIC power saving (EEE / Green Ethernet / Gigabit Lite), DDR4/DDR5 at JEDEC speed (XMP/EXPO off), a missing AMD 3D V-Cache Performance Optimizer on dual-CCD X3D, and no Defender exclusions when Defender is on. These are reported with the fix, never applied.

### Fixed
- **Dual-CCD Ryzen X3D lost its V-Cache steering.** The 7900X3D, 7950X3D, 9900X3D and 9950X3D rely on AMD's driver *parking* the non-cache CCD so games run on the cache CCD, and that only works on the Balanced plan. Chamber forced Ultimate Performance with core parking at 100%, which kept both CCDs awake. The new `Executables/Set-ChamberPowerPlan.ps1` builds the Chamber scheme (same GUID) on Balanced for these parts and leaves processor and parking values alone.
- **Power-scheme values never reached the active plan.** Core parking was written to `DefaultPowerSchemeValues`, which Windows only reads when creating schemes or restoring defaults. `Services\USB\DisableSelectiveSuspend` is not read by current Windows at all. Every value is now set with `powercfg /setacvalueindex` / `/setdcvalueindex`, and USB selective suspend and PCIe ASPM are explicitly off.
- **Laptops ran at full power on battery.** The Chamber scheme is now Balanced-based on laptops: the performance values apply on AC only, battery behaviour stays as Windows ships it, and the hiberfile is kept so a critical battery hibernates instead of powering off. Fast Startup is still turned off.
- **OOBE bullet points exceeded the length AME allows.** The ISO Compatibility spec states the `Title` and `Description` lengths "must roughly match the lengths in the examples", which run 8–16 and 92–106 characters; Chamber's were 17–26 and 144–156, roughly 50% over. These render on the OOBE summary page, so the overrun risked being clipped on screen during an injected install. Rewritten to 12–14 and 95–99, and `tools/validate_playbook_conf.py` now enforces the band.
- **ISO injection crashed on the browser feature page.** The Browser Choice `RadioPage` marked its options with `IsChecked`, which is not a real attribute — only `CheckboxOption` has `IsChecked`; `RadioOption` inherits a base class that does not. A radio page carries its selection solely in the page-level `DefaultOption` attribute, and Chamber set neither that nor `IsRequired`, so the page resolved to no selection at all. The GUI hides this because the user clicks a radio button; injection cannot, and AME died with `[NullReferenceException] Fatal error` in `IsoProgressDialog.Begin` while baking the selections into the image. Now `IsRequired="true" DefaultOption="browser-chrome"`, matching what Atlas and ReviOS set on every radio page. `tools/validate_playbook_conf.py` gained checks for this, for `DefaultOption` naming a real option, and for the per-page option-count limits AME enforces.
- **ISO injection was declared but never shipped.** The newest tagged release is v1.2.6, built without this work; its `playbook.conf` has no `SupportsISO`, so AME Wizard does not list Chamber on the ISO injection screen at all. Injection only becomes available once v1.3.0 is tagged and released. The README's ISO section now says so explicitly, so anyone hitting this knows they are on an older `.apbx` rather than a broken feature.
- **The released v1.2.5 `.apbx` declares `<Version>1.2.4</Version>`** — the version was never bumped for that tag. Tag builds now fail unless `playbook.conf`'s version matches the tag.
- **A comment in `playbook.conf` recommended a change that would break the playbook.** It described phases 4, 5 and 9 as "pure `!registryValue`" and suggested moving them to `iso: true` to shorten the OOBE. All three also shell out (`fsutil` in 4, the hosts-file script in 5, `netsh` in 9), so doing that would hard-fail parsing and stop the playbook loading. The comment now records the real rule instead.
- **The browser install no longer stalls an injected OOBE.** The two winget `!run` actions in phase 10 used `errorAction: Notify`, which halts on a dialog and waits for a click. winget ships as App Installer, a Store-provisioned package that is not reliably registered that early in setup, so an unattended OOBE could sit waiting on a failure nobody was there to dismiss. They now use `errorAction: Log`: the failure is recorded and provisioning finishes.

### Changed
- **Option menu wording rewritten** for accuracy and length. Option names (`disable-vbs` and so on) are unchanged, so tasks, receipts and verification are unaffected. The Defender option was relabelled during this work and then removed entirely; see *Removed*.
  - The VBS option no longer claims "Recovers 5-10% FPS", a figure Chamber has not measured (see `docs/BENCHMARKING.md`). It now says the gain depends on hardware and warns that some anti-cheat, such as Riot Vanguard, can require VBS.
  - *Remove Xbox apps and services* now says it also disables the Xbox accessory service that controllers use for updates, and that it breaks Game Pass and Xbox sign-in in games.
  - The Game Bar option no longer claims to "cut GPU overhead".
  - Page descriptions are shortened toward AME's 50-85 character guidance. The security page keeps its note that ISO choices apply to every PC.
  - Browser choices read *Google Chrome*, *Brave (built-in ad blocking)* and *None - keep Microsoft Edge*.
- The Finalize-phase reboot in `Configuration/Tasks/10-finalize.yml` now carries `oobe: false`. On a normal run it still restarts to apply BCD, service, and VBS changes; during an injected OOBE, AME owns the restart sequence and our own `shutdown` would cut it short.
- **Phase 10 splits the browser install by stage.** The two winget `!run` actions are now `oobe: false`, so they only run on a traditional drag-and-drop run; the cached-payload installs are `oobe: only`. Nothing races for the same browser at first boot, and the injected path has no network dependency. The winget path is otherwise unchanged.
- **Progress text is numbered "Step N of 8"** in `Configuration/main.yml` and each task file — power and boot, background services, gaming settings, privacy, removing clutter, your security choices, Windows look and network, installing your apps — instead of naming ten internal phase numbers. Steps only count up, so the progress screen always says how much is left. The ten task files and their order are untouched.
- **OOBE bullet point copy rewritten** to Anti-cheat ready / Balanced privacy / Competition tuned, in `Lock`, `Privacy`, `Rocket` order. The previous copy implied the machine was already verified; nothing is, until the run finishes and `Verify-Chamber.ps1` says so.
- **Smart App Control now defaults to off (unchecked).** Every security-reducing option ships unselected. During ISO injection these choices are baked into the image and applied to every PC installed from it, with no chance to revisit them at first boot, so each one should be a deliberate opt-in. The feature-page descriptions now say that outright.
- **`tools/validate_playbook_conf.py` gained the ISO-readiness gates** the PRD asks for: `!task:` paths resolve, every task file has a `title` and `actions`, each `<Software>` package has a matching `!download` and a real option behind it, cached downloads are HTTPS from a vendor-owned host with an option, package, destination and `cpuArch: X64`, every cached payload is one `Install-CachedBrowser.ps1` knows how to install, winget and `shutdown.exe` actions are `oobe: false`, `!powerShell` is never staged to injection, and the receipt script's version matches `playbook.conf`.
- **BitLocker / device encryption can now be turned off**, in two places because Windows turns it on at two different moments.
  - `<DisableBitLocker>true</DisableBitLocker>` is back in the `ISO` block, so a Chamber ISO installs unencrypted. Windows 11 24H2+ starts encrypting during setup, before any playbook action exists to stop it, and AME's injection-time switch is the only thing that gets there first. This is unconditional: AME reads it while building the image, so it cannot be gated on a feature option.
  - New **Turn off BitLocker / device encryption** option (off by default) on its own feature page, for traditional drag-and-drop runs. It writes `PreventDeviceEncryption` so Windows does not start later, and runs `Executables/Disable-BitLockerEncryption.ps1` to decrypt the system drive if encryption already began. Decryption is started, not waited on - `manage-bde` returns immediately and Windows finishes in the background, so a multi-gigabyte volume never stalls a run or an unattended OOBE. Other encrypted volumes are reported and left alone.
  - **No anti-cheat requires an encrypted drive.** Vanguard, EAC and BattlEye require Secure Boot and TPM 2.0; both stay on and both are still verified. BitLocker uses the TPM, which is where the confusion comes from, but nothing measures it. What it does cost is availability: the key is sealed against firmware measurements, so a BIOS update, Secure Boot toggle, TPM clear or CMOS reset can strand the machine at a 48-digit recovery prompt whose key is in a Microsoft account the owner may never have seen.
  - `Verify-Chamber.ps1` reports the drive's encryption state next to Secure Boot, with the consequence spelled out either way. It is INFO, never a failure - whether the drive should be encrypted is the owner's call, not the playbook's.
  - Registry values go from 81 to 82; the value is optional, so an unselected machine is classified rather than failed. `Restore-Chamber.ps1` can delete the policy, which lets Windows consider encryption again but deliberately does not re-encrypt anything.
  - This reverses the FR-005 decision taken earlier in 1.3.0, at the project owner's direction. The PRD's reasoning was about not silently changing a security posture; the counter-argument is that an unbootable PC after a routine BIOS flash is the worse failure, and the README now states the trade openly instead of burying it.
- **CI packages `Images/` into the `.apbx` and verifies the archive structure** before release — AME throws while building the OOBE software list if a named icon is missing, which is not something to discover on a user's first boot.
- **Transparency effects are now off by default.** Phase 8 writes `EnableTransparency` = `0` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, alongside the existing dark-mode values. The acrylic/Mica blur behind menus, the taskbar and Settings is DWM compositor work on every redraw of those surfaces, and it is the one Personalize value phase 4's `VisualFXSetting` does not cover. Registry values go from 80 to 81; verification and restore pick it up from the regenerated manifest, and the Windows default (`1`) is in the restore defaults table. Re-enable it under Settings → Personalization → Colors → Transparency effects.

### Removed
Each of these is now an `operation: delete`, so an in-place upgrade from an earlier Chamber removes the old value. Verify warns if one is still present.
- `Tcpip\Parameters\TcpNoDelay` (not read at that level), `MSMQ\Parameters\TCPNoDelay` (MSMQ only), and AFD `DefaultSendWindow` / `DefaultReceiveWindow` (pins socket buffers to 64 KB). Game netcode is UDP, so none of these affected in-game latency.
- Idle-priority IFEO demotion of `sihost.exe` and `RuntimeBroker.exe`. Both are on the shell and input path, and starving them under game load causes overlay and desktop hitching.
- `MaintenanceDisabled=1`. It also stopped scheduled SSD retrim and component cleanup, while maintenance already waits for idle. The tasks that actually spike mid-session are disabled individually instead.
- `LargeSystemCache=0`, which is the Windows default. Removed rather than counted as a tweak.

### Rollback notes (FPS and latency pass)
- Power: `Restore-Chamber.ps1 -Scope power` deletes the Chamber scheme, restores the default schemes, turns hibernation back on and sets `HiberbootEnabled=1`.
- Registry: the new values are in the defaults table (`Priority` 2, `UserPreferencesMask` stock, policies deleted). Restore also removes `SwapEffectUpgradeEnable` from `DirectXUserGlobalSettings` and keeps the user's other keys.
- Scheduled tasks: `-Scope tasks` re-enables all nine.
- Retired values need no rollback, because deleting them restores Windows defaults.

## [1.2.6] - 2026-10-05

This release is about which Windows versions Chamber runs on, and how you get onto it. It does not change a single tweak, so performance is the same as 1.2.4. I did not measure anything new here.

### Added
- **Windows 11 26H2 (build 26300) is supported.** Nothing in Chamber depends on the build, so I expect it to work. I have not run it on a fresh 26300 install yet, so treat 26H2 as untested until I say otherwise.
- **You can upgrade in place.** Run 1.2.6 over any earlier Chamber version and AME applies it on top. You do not need a fresh install. An upgrade re-runs every phase.
- **Update checks and a source code link.** `playbook.conf` now points at this repository, so AME can tell you when a new version is out and link you to the source.

### Removed
- **Windows 11 22H2 and 23H2 (builds 22621 and 22631) are no longer supported.** Chamber now needs 24H2 or newer. If you are on 22H2 or 23H2, update Windows first. Windows 10 was never supported.

### Upgrade notes
- Upgrading re-applies the playbook. It does not undo anything an older version set that a newer one stopped setting. The fixes for those are in the 1.2.4 and 1.2.3 notes below.

## [1.2.4] - 2026-08-04

Housekeeping release. Every change is performance-neutral by construction, so v1.2.4 can serve as a frozen build for benchmarking against stock Windows — see [docs/BENCHMARKING.md](docs/BENCHMARKING.md).

### Changed
- The stock **Balanced**, **High Performance**, and **Power Saver** power schemes are no longer deleted. Chamber's Ultimate Performance duplicate is still created and set active — the only difference is that the stock schemes survive, so a user can fall back or A/B against Balanced without `powercfg -restoredefaultschemes`. Deleted schemes were inactive and cost nothing; removing them only took away the user's escape hatch.

### Removed
- MMCSS `Games\GPU Priority` (`8`) and `Games\Priority` (`6`) are no longer written. Both are already the Windows defaults for the Games task, so these writes changed no system state — they only inflated the tweak count reported by verification. Registry values drop from 82 to 80.

### Upgrade notes
- This release stops *deleting* the stock power schemes; it does not restore ones already deleted. On a machine provisioned by v1.2.3 or earlier, run this from an elevated prompt to get them back:

  ```
  powercfg -restoredefaultschemes
  ```

  Note that this also resets the active plan, so re-select Chamber's Ultimate Performance afterward if you want it.

## [1.2.3] - 2026-08-04

### Changed
- **Windows Game Mode is now enforced on, unconditionally.** `AllowAutoGameMode` and `AutoGameModeEnabled` are written as `1` with no `option:` gate, and they are written *after* the Game Bar block so no feature-page selection can turn Game Mode back off. Previously the `disable-gamebar` checkbox — which ships **checked by default** — set both to `0`, silently disabling Game Mode on every install that accepted the defaults.
- `disable-gamebar` now does only what its name says: disables the Xbox Game Bar overlay and background DVR recording. Game Mode is no longer bundled into it.
- Dropped the "Not Recommended on Dual CCD CPUs" warning from the `disable-gamebar` label. That caveat existed only because the option used to disable Auto Game Mode; with Game Mode always on, the overlay/DVR toggle is safe on every CPU.

### Added
- Verification hard-fails when Game Mode is off. Since the two values carry no `option:`, `Verify-Chamber.ps1` reports them as `FAIL` rather than an informational optional-skip, so drift gets caught by the post-install check.

## [1.2.2] - 2026-08-04

### Removed
- `bcdedit /set useplatformtick yes` and `bcdedit /set disabledynamictick yes` from the Boot Performance phase (`Configuration/Tasks/2-bcd.yml`). Together these force Windows onto a fixed periodic timer tick instead of letting the kernel use the tickless/dynamic-tick path, which adds timer interrupt overhead on modern hardware without giving games any timer resolution they don't already get by default. The rest of phase 2 (`tscsyncpolicy Enhanced`, `bootux disabled`, `timeout 0`) is unchanged.
- Verification no longer checks these two BCD flags — `verification-manifest.json` was regenerated from the playbook source, so phase 2 now reports 2 BCD flags instead of 4.

### Upgrade notes
- This release only stops *setting* the flags; it does not undo them. On a machine already provisioned by v1.2.1 or earlier, clear them from an elevated Command Prompt and reboot:

  ```
  bcdedit /deletevalue useplatformtick
  bcdedit /deletevalue disabledynamictick
  ```

## [1.2.1] - 2026-07-08

### Fixed
- MMCSS `SystemResponsiveness` was set to `0`, which Windows clamps back up to `20` (per Microsoft's MMCSS docs, values below 10 are clamped to 20) — reserving 20% of CPU for background work, the opposite of the intent. Now set to `10`, the true minimum, for maximum foreground/gaming responsiveness.
- MMCSS `NetworkThrottlingIndex` (0xFFFFFFFF, disables the ~10 packets/ms multimedia throttle) was written under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`, where MMCSS never reads it, so it had no effect. Moved to `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile`.
- Verification no longer reports a false failure for `NtfsDisableLastAccessUpdate` when Windows stamps the value system-managed (`0x80000001`) on large SSD volumes. Last-access updates are disabled in both the user-managed (`1`) and system-managed (`0x80000001`) states, so the verifier now compares only the enable/disable bit and ignores the Windows-owned system-managed flag.

## [1.1.1] - 2026-07-06

### Changed
- NTFS last-access updates are now disabled via `fsutil behavior set disablelastaccess 1` instead of a raw `NtfsDisableLastAccessUpdate` registry write, so NTFS picks it up immediately and the setting is stamped user-managed (Windows won't revert it to the system-managed default). Verification still checks the same registry value; the manifest generator derives it from the fsutil command.

## [1.1.0] - 2026-07-02

### Added
- Finalize phase now copies the Post-Install Companion to `C:\ChamberTech\PostInstall` and creates a "Chamber Post-Install" Desktop shortcut, so it's easy to find after reboot regardless of where the playbook was originally run from
- Windows 11 25H2 (build 26200) listed as supported in README (already supported in `playbook.conf`)
- Manifest-driven system verification: `tools/generate_verification_manifest.py` generates `PostInstall/Verify/verification-manifest.json` from the playbook YAML; Step 4 verification now checks all 80 registry tweaks, 20 services, BCD flags, hosts entries, and debloat targets against actual system state
- `-ClientReport` switch on verification: bundles results, logs, and system info into a Desktop zip for support
- JSON verification results saved to `C:\ProgramData\ChamberPostInstall\logs`
- GitHub Actions release pipeline: packages `Chamber.apbx` on tag push with SHA256 checksums
- Issue templates, contributing guide, license

### Changed
- Verification treats conditional tweaks (Xbox removal, VBS, Game Bar) as informational rather than failures, since option selections vary per install
- Post-Install simplified to Verify + Drivers only; the old guided launcher (DDU cleanup, MSI mode, repair/revert, optional apps flow) is retired in favor of manual driver installation plus the manifest-driven verifier. The retired scripts remain available on the `full-postinstall` branch.

### Fixed
- Release workflow's manifest-staleness check compared the full JSON including a `generatedUtc` timestamp that changes on every regeneration, so it would fail even when the manifest content was current. Now diffs with that field excluded.

### Known issues
- This release was packaged and archive-verified locally but has not completed a fresh-VM install + Post-Install verification pass before tagging.

## [1.0.0] - 2026-07-02

### Added
- Initial release: 10-phase optimization (power, BCD, services, registry, privacy, debloat, security, UI, network, finalize)
- Post-Install companion (`PostInstall/START-HERE.bat`): guided DDU driver cleanup, MSI mode, verification, repair/revert, optional apps, diagnostics
- Feature pages: security options, Xbox/gaming services, OLED safety, browser choice
- Anti-cheat safe: Secure Boot stays enabled; Vanguard/EAC/BattlEye compatible

### Upgrade path
- v1.0.0 is designed for fresh installs of Windows 11 22H2–25H2. No in-place upgrade path from other playbooks.
