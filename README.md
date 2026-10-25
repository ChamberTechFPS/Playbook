# Chamber Playbook

## 📺 Video Tutorial — How to Install

**New here? Watch the full installation walkthrough:** [**▶️ Chamber Playbook Install Tutorial**](https://youtu.be/jzM9MHyzCiI)

This video walks you through downloading the playbook, setting up AME Wizard, and running Chamber start to finish. Follow along with the [Installation](#installation) steps below.

---

**One-click competitive gaming optimization for Windows 11.**

Chamber Playbook is an [AME Wizard](https://ameliorated.io) playbook that turns a fresh Windows 11 install into a competition-ready gaming machine. It applies performance tweaks, strips out bloatware, locks down telemetry, and configures the system the way competitive players actually want it — all in one guided pass.

> ⚠️ **Anti-cheat safe:** Chamber Playbook keeps **Secure Boot ON** and is compatible with Vanguard, Easy Anti-Cheat, and BattlEye. See [Anti-Cheat Compatibility](#anti-cheat-compatibility).

> 🖥️ **Want it done for you?** ChamberTech offers a professional **PC optimization service** — head to [**chambertech.net**](https://chambertech.net) to get your system tuned by hand.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [What It Does](#what-it-does)
- [Post-Install Companion](#post-install-companion)
- [Windows App Removal (Debloat)](#windows-app-removal-debloat)
- [Anti-Cheat Compatibility](#anti-cheat-compatibility)
- [Transparency & Verifying Downloads](#transparency--verifying-downloads)
- [Community & Support](#community--support)
- [Disclaimer](#disclaimer)

---

## Features

- 🚀 **Performance-first** — hardware-aware power plan (Ultimate Performance on desktops, X3D- and laptop-safe), BCD boot tuning, service trimming, and registry latency tweaks
- 🧹 **Balanced debloat** — removes consumer inbox apps while preserving the Store, winget, and Windows Security
- 🔒 **Privacy hardening** — blocks telemetry at the registry, firewall, and hosts level
- 🎮 **Competitor-focused UI** — dark mode, clean taskbar, classic context menu, file extensions on
- 🛡️ **Anti-cheat friendly** — Secure Boot stays on; no changes that trip Vanguard, EAC, or BattlEye
- 🔧 **Post-install companion** — organized driver install folders and full system verification
- ✅ **Verifiable** — every tweak is checked against actual system state by the built-in verification tool
- ♻️ **Reversible** — removed apps reinstall from the Microsoft Store anytime
- 🪟 **Current Windows 11** — runs on 24H2 (26100), **25H2 (26200)** and **26H2 (26300)**
- 💿 **ISO injection** *(experimental)* — bake Chamber into a Windows 11 ISO with your browser cached inside it, and let it apply at first boot; AME Wizard writes the USB for you

---

## Requirements

| Requirement         | Details                                                          |
| ------------------- | ---------------------------------------------------------------- |
| **OS**              | Fresh Windows 11 install — 24H2 (26100), 25H2 (26200), or 26H2 (26300). 22H2/23H2: update Windows first |
| **Architecture**    | x64 only. On ARM64 the playbook stops before changing anything    |
| **Windows Updates** | Install all pending updates *before* running                     |
| **Antivirus**       | Uninstall any third-party AV first. Chamber leaves Microsoft Defender on |
| **Internet**        | Required for winget-based app installs                           |
| **AME Wizard**      | Download from [ameliorated.io](https://ameliorated.io)           |

> Supports Windows 11 through **25H2 (26200)** and **26H2 (26300)**. 25H2 is validated on live hardware and client systems, and fresh-install VM regression testing runs before each release. 26H2 support ships ahead of its general release — every tweak Chamber applies is build-agnostic registry, service, and BCD work, with no version-specific API — so run the post-install verifier after your first 26H2 install and report anything that fails.

---

## Installation

1. Download the latest `Chamber.apbx` from the [**Releases**](https://github.com/ChamberTechFPS/Playbook/releases) page.
2. Download and open **AME Wizard** from [ameliorated.io](https://ameliorated.io).
3. Drag `Chamber.apbx` into AME Wizard.
4. Follow the on-screen options and let it run.
5. After reboot, a **Driver Setup** page opens with the drivers to install. The **Driver Setup** shortcut on the Desktop brings it back. To check every tweak applied, run `C:\ChamberTech\PostInstall\START-HERE.bat` as administrator.

> 💡 Chamber Playbook is designed for a clean install. Running it on a heavily customized system may produce mixed results.

### ISO injection (experimental)

Chamber supports AME Wizard's ISO injection, which bakes the playbook into a Windows 11 ISO so it applies during a custom out-of-box experience at first boot instead of being run manually afterwards. Useful if you build more than one machine.

> ⚠️ **Experimental.** ISO injection has passed static validation but not the full build-and-boot matrix (26100, 26200, 26300 × Chrome / Brave / Skip, online and offline). Until it has, treat an injected install as something to test on a spare machine or a VM — not as the way you set up a PC you are handing to someone. The traditional drag-and-drop path is unchanged and fully supported.

> ⚠️ **Requires Chamber v1.3.0 or later.** ISO injection is declared in `playbook.conf`, so AME Wizard only offers it for builds that carry that declaration. Earlier releases — v1.2.6 and below — do not, and AME will simply not list Chamber on its injection playbook screen. If Chamber does not appear there, you are on an older `.apbx`; download the current one from [Releases](https://github.com/ChamberTechFPS/Playbook/releases).

**x64 only.** Chamber does not support ARM64 — the cached browser payloads are x64 builds, and the tweaks are untested there. AME may not stop you selecting an ARM64 ISO; do not. If you do, Chamber's first action detects ARM64 at first boot and halts before changing anything, so the result is an unmodified Windows install — how AME's OOBE screen presents that halt has not been tested.

**Two people, two moments.** Worth being clear about, because the options work differently here than in a normal run:

- The **ISO creator** picks the Windows ISO, the Chamber options, and the browser. Those choices are baked into the image and applied to **every PC installed from it**. They cannot be changed at first boot.
- The **first-boot user** — possibly someone else entirely, receiving a finished PC — sees Chamber's summary and watches it run. They do not get to edit what was embedded.

1. In AME Wizard, choose **ISO Injection** and supply a Windows 11 ISO (build 26100, 26200, or 26300).
2. Drag `Chamber.apbx` in when prompted, accept the terms, and pick your Chamber options and browser. Injection takes roughly 10–15 minutes, plus the browser download.
3. Write the ISO to a USB drive. **AME Wizard writes ISOs to USB itself**, so no separate tool is needed — pick the drive in AME and let it write. Ventoy and Rufus also work if you prefer them.
4. Chamber applies during OOBE. Pick your region and account as normal while it runs.
5. At the first sign-in, a **Driver Setup** page opens on its own: chipset driver first, restart, then GPU and network drivers. That is all the person who receives the PC sees - it doesn't mention Verify, undo, AME or the playbook. The page opens once per user, and the **Driver Setup** shortcut on the desktop brings it back. Verify, the support report and Restore stay in `C:\ChamberTech\PostInstall` for you or ChamberTech support, listed in a collapsed "For ChamberTech support" section at the bottom of the page.

Notes:

- **Let AME Wizard write the USB — do not extract the ISO and copy the files across.** AME saves the injected ISO to `C:\ProgramData\AME\Images\`, not next to the ISO you supplied, so check there if you cannot find it. Hand-copying extracted files produces media that will not boot the injected image: `install.wim` is well over 4 GB so FAT32 cannot hold it, and an NTFS stick will not UEFI-boot on most firmware. Windows installs, but from a stock image — you get Microsoft's normal setup and no Chamber.
- **Setup finishes at the first sign-in.** Chamber runs during OOBE, before your account exists. When you first sign in, Windows applies its own theme and visual defaults, and resets a few telemetry settings. So at each account's first sign-in, Chamber quietly re-applies its per-user settings (dark mode, visual effects, the search box, the classic right-click menu, windowed-game optimizations, OLED taskbar auto-hide). A one-time background task re-applies the system-wide ones. Both are driven by the same manifest Chamber Verify checks. Some settings take full effect after the restart the Driver Setup page asks for.
- **The browser is cached into the image, not downloaded at first boot.** Injection downloads the Chrome or Brave installer onto the ISO. At first boot Chamber checks the file is present and carries a valid signature from Google or Brave, then installs it silently. Nothing is downloaded during OOBE, and *Skip* caches and installs nothing.
- **An internet connection is still required during OOBE, for now.** The OOBE is set to require a connection while the offline path is being validated. It becomes optional once the offline rows of the test matrix pass; the browser itself already does not need it.
- **A bad browser payload is skipped, not run.** If the cached installer is missing, truncated, or signed by anyone other than the expected vendor, Chamber skips it and records why. Edge is still there, and you can install a browser normally afterwards. Setup is never blocked by it.
- **What ran is written down.** Chamber writes `C:\ChamberTech\deployment-receipt.json` recording the Chamber version, Windows build, whether this was an injected or manual install, which options were selected, and how the browser install went. Chamber Verify reads it, and the support report ships it — so "that option was never selected" and "that option was selected and failed" stop looking the same.
- **Automatic device encryption is turned off in the image.** Windows 11 24H2+ silently encrypts the system drive during setup and seals the key to the TPM, so a BIOS update, Secure Boot change, TPM clear or CMOS reset can strand the PC at a 48-digit recovery-key prompt. Chamber ISOs install unencrypted instead. **No anti-cheat requires an encrypted drive** — Secure Boot and TPM 2.0 both stay on, which is what Vanguard, EAC and BattlEye actually check. The trade is that the drive is readable if the PC is stolen or the disk is pulled; turn encryption on yourself from Settings afterwards if you want it, and you will own the recovery key. AME applies this through an `unattend.xml` in the ISO, and the same file also lifts Windows' own "you need the internet" setup block (`BypassNRO`) — AME couples the two. Chamber's OOBE still requires a connection, as noted above.
- **Hardware requirements are *not* bypassed.** Chamber targets titles whose anti-cheat needs Secure Boot and TPM 2.0 — Riot Vanguard will not start without them — so setup still enforces the normal Windows 11 checks.

---

## What It Does

| #  | Phase      | Description                                                                          |
| --- | ---------- | ------------------------------------------------------------------------------------ |
| 1  | Power Plan | Hardware-aware plan: Ultimate Performance on desktops, Balanced-based on dual-CCD X3D and laptops; USB suspend and PCIe ASPM off |
| 2  | BCD Tweaks | TSC sync policy, boot animation off, zero boot-menu timeout                          |
| 3  | Services   | Disables 15+ background services and 9 telemetry scheduled tasks                     |
| 4  | Registry   | MMCSS priority, Game Mode enforced on, windowed-game flip model, mouse accel off, visual effects |
| 5  | Privacy    | Blocks telemetry at registry + hosts level; no P2P update uploads, no background Store apps |
| 6  | Debloat    | Removes balanced inbox bloat (installed + provisioned AppX)                          |
| 7  | Security   | Optional VBS/HVCI off, Smart App Control off, update notify-only, BitLocker off      |
| 8  | UI Config  | Dark mode, transparency off, clean taskbar, Explorer to This PC, classic context menu, file extensions |
| 9  | Network    | Search/telemetry process priority demotions, TCP optimization                        |
| 10 | Finalize   | DirectX, C++ Redists, browser choice, and the Chamber deployment receipt             |

---

## Post-Install Companion

Chamber ships with a simple post-install folder. During the Finalize phase, the playbook copies it to `C:\ChamberTech\PostInstall`, adds a **Driver Setup** shortcut to the desktop of every account, and opens that page (`Welcome.html`) once at the next sign-in. The page lists drivers only; the folder holds the support tools, which users don't need to see:

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

Verification is read-only and checks **every tweak the playbook applies** — all registry values, service states, scheduled tasks, BCD flags, hosts entries, and debloat targets — against actual system state, plus Secure Boot, VBS, HAGS, and MSI mode. It also flags setup problems the playbook cannot fix for you: a monitor below its fastest refresh rate, NIC power saving, memory at JEDEC speed (XMP/EXPO off), and a missing AMD 3D V-Cache driver on dual-CCD X3D CPUs. The manifest is generated directly from the playbook source, so checks never drift from what the playbook actually does. Results save as JSON; option 2 creates a `ChamberReport` zip on the Desktop for support.

It also reads `C:\ChamberTech\deployment-receipt.json` when one exists. The receipt is written during the playbook run and records which options were actually selected — something the system state alone cannot tell you, since an option that was never chosen and an option that failed leave the machine looking identical. With it, the report distinguishes the two, and says whether the run finished. Machines set up before receipts existed simply report without one.

---

## Windows App Removal (Debloat)

The debloat phase removes both installed and provisioned copies of common consumer inbox apps where present:

> Outlook/Mail, Solitaire, Teams, Clipchamp, Copilot, Widgets, Phone Link, Bing/MSN apps, Feedback Hub/Get Help/Tips, media apps, Family/People/To Do, Power Automate, Whiteboard, Maps, Office hub, Power BI, Spotify, Dev Home, LinkedIn, Skype, Cortana, Mixed Reality Portal, Sticky Notes, Alarms & Clock, Quick Assist, and OneDrive (win32 uninstall).

- **Copilot** is also disabled at the policy level (`TurnOffWindowsCopilot`) so it cannot return through Windows updates.
- **Recall** and **Click to Do** are turned off by policy. They only exist on Copilot+ PCs; elsewhere the setting does nothing.
- **Start, Settings and lock screen suggestions** are turned off: Bing web results in Start search, Start recommendations and account prompts, suggested and silently installed apps, tips, and lock screen "fun facts".
- **Xbox** app, Game Pass app, overlays, and identity packages are removed **only** when *Remove Xbox apps and services* is selected in AME Wizard.
- Chamber Playbook **preserves**: Microsoft Store, App Installer/winget, Windows Security, Calculator, Notepad, Snipping Tool, Photos, Paint, and Xbox/Game Pass (unless Xbox removal is selected).

Removed apps can be reinstalled at any time from the Microsoft Store, which Chamber Playbook preserves.

---

## Anti-Cheat Compatibility

| Anti-Cheat                          | Status  | Notes                                          |
| ----------------------------------- | ------- | ---------------------------------------------- |
| **Vanguard** (Valorant)             | ✅ Works | Keep **Secure Boot ON** — Vanguard requires it |
| **Easy Anti-Cheat** (Fortnite, CoD) | ✅ Works | Compatible with all Chamber Playbook settings  |
| **BattlEye**                        | ✅ Works | No changes needed                              |

> ❗ **Do NOT disable Secure Boot.** Multiple anti-cheats now require it, and Chamber Playbook is built to keep it enabled.

### Does any game require BitLocker?

**No.** Anti-cheats check **Secure Boot** and **TPM 2.0** — never whether your drive is encrypted. BitLocker also uses the TPM, which is why the two get confused, but they are independent: you can turn BitLocker off and Vanguard, EAC and BattlEye are unaffected.

That matters because Windows 11 24H2+ enables device encryption on its own during setup, and the sealed key is tied to your firmware measurements. Update the BIOS, toggle Secure Boot, clear the TPM or reset CMOS, and the machine can boot to a 48-digit recovery-key prompt — with the key sitting in a Microsoft account the owner may not know exists.

Chamber handles this two ways:

- **ISO installs never start encrypting.** Nothing to decrypt, no recovery prompt, nothing to remember before a BIOS update.
- **Traditional runs** get the optional *Turn off BitLocker / device encryption* checkbox (off by default). It blocks future auto-encryption and starts decrypting the system drive if Windows already encrypted it. Decryption runs in the background — the PC stays usable and can be restarted normally.

> 💡 **If you only want to survive one BIOS update, don't decrypt — suspend.** Run `manage-bde -protectors -disable C: -RebootCount 2` as administrator, flash the firmware, and protection re-arms itself after the next two boots. You keep encryption and skip the recovery prompt. Decrypting is the right call when you don't want encryption at all.

---

## Transparency & Verifying Downloads

- An `.apbx` is a renamed 7z archive (password `malte` — an AME Wizard convention to avoid antivirus false flags, not a secret). Open it with 7-Zip and read every file: it's plain-text YAML and PowerShell.
- Every release is built by [GitHub Actions](.github/workflows/release.yml) directly from this repository — no hand-built binaries.
- Each release includes `SHA256SUMS.txt` with checksums for the `.apbx` and every bundled PowerShell and batch script. Verify with `Get-FileHash Chamber.apbx` in PowerShell.
- Playbook actions execute via AME Wizard's open-source [TrustedUninstaller](https://github.com/Ameliorated-LLC/trusted-uninstaller-cli) backend.

---

## Disclaimer

Chamber Playbook makes significant changes to Windows. Use it on a **fresh install** and at your own risk. Always understand what a tweak does before applying it to a system you depend on.

## Community & Support

- 💬 **Join the community** — hop into the Chamber Discord to ask questions, share results, and get help: [**discord.gg/TG4djSaZ2w**](https://discord.gg/TG4djSaZ2w)
- ⭐ **Support what I'm doing** — back the project to help keep it free and unlock **exclusive access** in the Discord: [**Support & Exclusive Access**](https://discord.com/servers/chambertech-758350757451399191)

---

## License

Chamber Playbook is licensed under [CC BY-NC-SA 4.0](LICENSE) — free to use, share, and adapt with attribution; commercial redistribution requires permission from ChamberTech LLC.

---

**Chamber Playbook — built for competitors.**
Part of the [ChamberTech](https://x.com/ChamberTech_) ecosystem · [YouTube](https://youtube.com/@ChamberTech) · [Discord](https://discord.gg/TG4djSaZ2w)
