# How the ChamberTech Playbook works

[← Back to the README](../README.md)

The details behind the one-click run: what each phase changes, what I deliberately leave out, which apps are removed, and how Verify and Restore work.

## The ten phases

| #  | Phase      | Description                                                                          |
| --- | ---------- | ------------------------------------------------------------------------------------ |
| 1  | Power Plan | Hardware-aware plan: Ultimate Performance on desktops, Balanced-based on dual-CCD X3D and laptops; USB suspend and PCIe ASPM off |
| 2  | BCD Tweaks | TSC sync policy, boot animation off, 15-second boot menu (only dual-boot PCs ever see it) |
| 3  | Services   | Disables telemetry and unused services and 9 telemetry scheduled tasks. Search, SysMain and typing services stay on |
| 4  | Registry   | MMCSS priority, Game Mode enforced on, windowed-game flip model, Fault Tolerant Heap off, mouse accel off, visual effects |
| 5  | Privacy    | Telemetry policies and loggers off, telemetry programs blocked, no web results or highlights in search, indexing pauses during games, no P2P update uploads, no background Store apps |
| 6  | Debloat    | Removes balanced inbox bloat (installed + provisioned AppX) and stops Outlook and Dev Home reinstalling |
| 7  | Security   | Pins your current Windows 11 release. Optional: VBS/HVCI off, Smart App Control off, pause updates, no drivers from Windows Update, BitLocker off |
| 8  | UI Config  | Dark mode, transparency off, clean taskbar, Explorer to This PC, classic context menu, file extensions, no audio ducking, taskbar *End task*, Dynamic Lighting off |
| 9  | Network    | Search/telemetry process priority demotions, TCP optimization                        |
| 10 | Finalize   | DirectX, C++ Redists, browser choice, and the deployment receipt             |

## What the playbook leaves alone, and why

Some tweaks are popular in other playbooks and guides. I either tried them or looked at the evidence, and I'm not shipping them:

| Tweak | Why it's not in the playbook |
| --- | --- |
| Turning off Windows Search | File search in Start and File Explorer gets slow, and Outlook search stops working. The playbook keeps it on and has it pause while Game Mode is active |
| Turning off SysMain | No measured gain, and it can lengthen game and app load times |
| `NetworkThrottlingIndex = 0xFFFFFFFF` | Published testing found no latency benefit. 1.4.0 puts back the Windows default of 10 |
| Hosts-file telemetry blocks | Microsoft Defender flags them as a threat (`HostsFileHijack`) and can remove them. The services and policies already stop telemetry, so 1.4.0 removes the lines older versions added |
| Turning off Defender | Tamper Protection makes Windows ignore it on every fresh install |
| Closing apps at shutdown without asking (`AutoEndTasks`) | You lose unsaved work. 1.4.0 removes it |
| Disabling devices like HPET or System Timer | It can break hardware, and I haven't seen a measured gain |
| Turning off Store app auto-updates | Gaming Services and Game Pass stop updating and break |
| Deleting Windows Update or Defender | Updates, the Store and security stop working |

## Windows app removal (debloat)

The debloat phase removes both installed and provisioned copies of common consumer inbox apps where present:

> Outlook/Mail, Solitaire, Teams, Clipchamp, Copilot, Widgets, Phone Link, Bing/MSN apps, Feedback Hub/Get Help/Tips, media apps, Family/People/To Do, Power Automate, Whiteboard, Maps, Office hub, Power BI, Spotify, Dev Home, LinkedIn, Skype, Cortana, Mixed Reality Portal, Sticky Notes, Alarms & Clock, Quick Assist, and OneDrive (win32 uninstall).

- **Copilot** is also disabled at the policy level (`TurnOffWindowsCopilot`) so it cannot return through Windows updates.
- **Recall** and **Click to Do** are turned off by policy. They only exist on Copilot+ PCs; elsewhere the setting does nothing.
- **Start, Settings and lock screen suggestions** are turned off: Bing web results in Start search, Start recommendations and account prompts, suggested and silently installed apps, tips, and lock screen "fun facts".
- **Outlook and Dev Home** are kept from reinstalling themselves. Windows Update otherwise brings them back after removal.
- **Xbox** app, Game Pass app, overlays, and identity packages are removed **only** when *Remove Xbox apps and services* is selected in AME Wizard.
- ChamberTech Playbook **preserves**: Microsoft Store, App Installer/winget, Windows Security, Calculator, Notepad, Snipping Tool, Photos, Paint, and Xbox/Game Pass (unless Xbox removal is selected).

Removed apps can be reinstalled at any time from the Microsoft Store, which ChamberTech Playbook preserves.

## Post-install tools, Verify and Restore

The playbook ships with a simple post-install folder. During the Finalize phase, the playbook copies it to `C:\ChamberTech\PostInstall`, adds a **Driver Setup** shortcut to the desktop of every account, and opens that page (`Welcome.html`) once at the next sign-in. The page lists drivers only; the folder holds the support tools, which users don't need to see:

```
PostInstall/
├── START-HERE.bat       Support menu: verify, support report, undo (run as admin)
├── Welcome.html         Driver Setup page: opened once at first sign-in, and by the desktop shortcut
├── Drivers/
│   ├── Chipset/         Install FIRST (AMD/Intel links inside), then reboot
│   ├── NVIDIA/          Drop your driver here — NVCleanstall recommended
│   └── AMD/             Driver-only install recommended
├── tools/               DDU, HWiNFO, CapFrameX download links
└── Verify/              Manifest-driven verification
```

Verification is read-only and checks **every tweak the playbook applies** — all registry values, service states, scheduled tasks, BCD flags, leftover hosts entries from older versions, and debloat targets — against actual system state, plus Secure Boot, VBS, HAGS, and MSI mode. It also flags setup problems the playbook cannot fix for you: a monitor below its fastest refresh rate, NIC power saving, memory at JEDEC speed (XMP/EXPO off), and a missing AMD 3D V-Cache driver on dual-CCD X3D CPUs. The manifest is generated directly from the playbook source, so checks never drift from what the playbook actually does. Results save as JSON; option 2 creates a `ChamberReport` zip on the Desktop for support.

It also reads `C:\ChamberTech\deployment-receipt.json` when one exists. The receipt is written during the playbook run and records which options were actually selected — something the system state alone cannot tell you, since an option that was never chosen and an option that failed leave the machine looking identical. With it, the report distinguishes the two, and says whether the run finished. Machines set up before receipts existed simply report without one.

## Does any game require BitLocker?

**No.** Anti-cheats check **Secure Boot** and **TPM 2.0** — never whether your drive is encrypted. BitLocker also uses the TPM, which is why the two get confused, but they are independent: you can turn BitLocker off and Vanguard, EAC and BattlEye are unaffected.

That matters because Windows 11 24H2+ enables device encryption on its own during setup, and the sealed key is tied to your firmware measurements. Update the BIOS, toggle Secure Boot, clear the TPM or reset CMOS, and the machine can boot to a 48-digit recovery-key prompt — with the key sitting in a Microsoft account the owner may not know exists.

The playbook handles this two ways:

- **ISO installs never start encrypting.** Nothing to decrypt, no recovery prompt, nothing to remember before a BIOS update.
- **Traditional runs** get the optional *Turn off BitLocker / device encryption* checkbox (off by default). It blocks future auto-encryption and starts decrypting the system drive if Windows already encrypted it. Decryption runs in the background — the PC stays usable and can be restarted normally.

> 💡 **If you only want to survive one BIOS update, don't decrypt — suspend.** Run `manage-bde -protectors -disable C: -RebootCount 2` as administrator, flash the firmware, and protection re-arms itself after the next two boots. You keep encryption and skip the recovery prompt. Decrypting is the right call when you don't want encryption at all.
