<p align="center"><img src="playbook.png" width="96" alt="ChamberTech logo"></p>

<h1 align="center">ChamberTech Playbook</h1>

<p align="center"><strong>Windows 11, set up for competitive gaming in one run.</strong></p>

<p align="center">
  <a href="https://github.com/ChamberTechFPS/Playbook/releases/latest"><img src="https://img.shields.io/github/v/release/ChamberTechFPS/Playbook?label=release" alt="Latest release"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/Windows%2011-24H2%20%7C%2025H2%20%7C%2026H2-0078D4" alt="Windows 11 24H2, 25H2, 26H2"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-lightgrey" alt="License: CC BY-NC-SA 4.0"></a>
  <a href="https://discord.gg/TG4djSaZ2w"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

The ChamberTech Playbook is an [AME Wizard](https://ameliorated.io) playbook. You drag one file into AME Wizard, pick a few options, and it sets Windows up the way competitive players actually run it: a power plan matched to your hardware, background noise trimmed, ads and clutter gone. Secure Boot and anti-cheat stay intact, and every change can be checked and undone.

**▶️ New here? Watch the [install walkthrough](https://youtu.be/jzM9MHyzCiI)** — downloading, setting up AME Wizard, and running the playbook start to finish.

> 🖥️ **Rather have it done for you?** I tune PCs by hand as a service at [**chambertech.net**](https://chambertech.net).

---

## Contents

- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Install](#install)
- [Your options](#your-options)
- [FAQ](#faq)
- [Anti-cheat](#anti-cheat)
- [Transparency](#transparency)
- [Community and support](#community-and-support)

Deeper reading: [How it works](docs/HOW-IT-WORKS.md) · [Installing from a USB](docs/ISO-INJECTION.md) · [Changelog](CHANGELOG.md)

---

## What you get

- 🚀 **A power plan that fits your PC.** Ultimate Performance on desktops; a Balanced-based plan on laptops and dual-CCD Ryzen X3D chips, which need it to keep games on the V-Cache cores.
- 🎮 **Games first.** Game Mode always on, Windows' low-latency presentation for borderless games, mouse acceleration off, and Fault Tolerant Heap off so a game that crashed a few times doesn't keep Windows' crash workarounds forever.
- 🧹 **Less running in the background.** Telemetry services, scheduled data collection and preinstalled apps removed. Search stays on but pauses while you play.
- 🔒 **Privacy.** Telemetry, ads, suggestions, web results in search, Copilot and Recall turned off. No uploading Windows updates to other PCs.
- 🎧 **Small things that matter.** Game audio no longer drops during Discord calls, *End task* on the taskbar right-click menu, Windows' Dynamic Lighting kept out of your RGB software, classic right-click menu, dark mode.
- 📌 **Stays put.** Security updates keep coming, but Windows doesn't jump to the next yearly release and undo your setup.
- ✅ **Checkable and undoable.** A post-install tool checks every setting against your PC, and a restore option puts Windows back.

The full list, phase by phase, is in [How it works](docs/HOW-IT-WORKS.md).

---

## Requirements

| Requirement | Details |
| --- | --- |
| **Windows** | Windows 11 24H2 (26100), 25H2 (26200) or 26H2 (26300). On 22H2/23H2, update Windows first |
| **CPU** | x64 (Intel or AMD). ARM64 is not supported; the playbook stops before changing anything |
| **Updates** | Install all pending Windows updates first |
| **Antivirus** | Uninstall any third-party antivirus first. Microsoft Defender stays on |
| **Power** | Laptops must be plugged in. AME Wizard won't start on battery |
| **Internet** | Needed to install your browser |
| **AME Wizard** | Download from [ameliorated.io](https://ameliorated.io) |

25H2 and 26H2 are tested on real hardware and client PCs.

---

## Install

1. Download `Chamber.apbx` from the [**latest release**](https://github.com/ChamberTechFPS/Playbook/releases/latest).
2. Open **AME Wizard** and drag `Chamber.apbx` into it.
3. Pick your options (see below) and let it run. It takes a few minutes and restarts the PC.
4. After the restart, a **Driver Setup** page opens with the drivers to install: chipset first, restart, then graphics. The **Driver Setup** shortcut on your desktop brings it back.

> 💡 Works best on a fresh Windows install. A PC that's already heavily tweaked can give mixed results.

**Setting up more than one PC?** You can bake the playbook into a Windows USB so it applies during setup. See [Installing from a USB](docs/ISO-INJECTION.md) (experimental).

---

## Your options

AME Wizard asks these before it starts. If you're not sure, leave the defaults.

| Option | Default | What it does | What it costs |
| --- | --- | --- | --- |
| Browser | Chrome | Installs Chrome or Brave, or keeps Edge | Nothing |
| Remove Xbox apps and services | Off | Removes the Xbox app, Game Bar and Xbox sign-in | Breaks Game Pass, Xbox sign-in in games, and Xbox controller updates |
| Turn off Game Bar overlay and recording | On | Turns off Win+G and background recording. Game Mode stays on | Use your GPU's own recorder instead |
| OLED burn-in protection | Off | Screen off after 5 idle minutes, taskbar auto-hides | Only worth it on an OLED |
| Turn off BitLocker / device encryption | Off | Stops automatic encryption and decrypts the drive if it already started | The drive is readable if the PC is stolen |
| Turn off VBS and Memory Integrity | Off | Can help in some CPU-bound games; it depends on your hardware | Breaks WSL2, Windows Sandbox and Docker Desktop. Some anti-cheat can require it |
| Pause Windows Updates | Off | Pauses updates until 2038. Click *Resume* in Settings > Windows Update any time | You miss security fixes while paused |
| Turn off Smart App Control | Off | Lets unsigned game installers, mod tools and overclocking utilities run | One less layer of protection against unknown apps |
| Stop Windows Update installing drivers | Off | Windows Update can't replace your GPU driver with an older one | Chipset, Wi-Fi and network drivers stop coming from Windows Update. On a USB install, Wi-Fi may not work until you install its driver |

---

## FAQ

**Will this get me banned?**
The playbook changes Windows settings, not games. Secure Boot and TPM 2.0 stay on, it doesn't touch game files or anti-cheat drivers, and Vanguard, Easy Anti-Cheat and BattlEye run normally. The one option to think about is *Turn off VBS*: some anti-cheat, such as Riot Vanguard, can require it.

**How much FPS will I gain?**
It depends on your PC, and I won't quote a number I haven't measured on yours. The difference shows up most in CPU-limited games at competitive settings (1080p, low). To see it on your own PC, record a before and after with CapFrameX (linked in the post-install tools) and compare 1% lows, not just average FPS.

**Can I undo it?**
Yes. Right-click `C:\ChamberTech\PostInstall\START-HERE.bat`, choose **Run as administrator**, and pick **Undo**. It makes a System Restore point first, then puts back the registry settings, services, boot settings and power plan. Removed apps can be reinstalled from the Microsoft Store.

**Do I need to reinstall Windows first?**
It's built for a fresh install, which gives the most predictable result. It also runs on a PC you already use, but if that PC has years of other tweaks on it, results can be mixed.

**Will Windows Update undo it?**
Monthly updates install as normal and don't undo it. The playbook keeps Windows on its current yearly release (25H2, for example), because the big yearly upgrades are what reset settings and bring removed apps back. A PC on 24H2 moves to 25H2 once, because 24H2 no longer gets security updates.

**Do Game Pass and Xbox still work?**
Yes, unless you tick *Remove Xbox apps and services*.

**Does it work on a laptop?**
Yes. The power plan only goes all-out when you're plugged in; on battery it keeps Windows' own settings. Plug in before you run it.

**Will it delete my files?**
No. It removes preinstalled apps and uninstalls OneDrive. Files OneDrive already synced to your PC stay in your OneDrive folder, and anything stored only in the cloud stays at onedrive.com.

**My antivirus or browser warned me about the file. Is it safe?**
An `.apbx` is a password-protected 7-Zip archive (the password is `malte`, an AME Wizard convention so antivirus doesn't flag the scripts inside). Open it with 7-Zip and read every file; it's plain YAML and PowerShell. Each release also lists checksums. See [Transparency](#transparency).

**Something isn't working.**
Run `START-HERE.bat` as administrator and pick **Check my PC + make a support report**. It saves a zip to your Desktop. Bring it to the [Discord](https://discord.gg/TG4djSaZ2w).

---

## Anti-cheat

| Anti-cheat | Status | Notes |
| --- | --- | --- |
| **Vanguard** (Valorant) | ✅ Works | Keep Secure Boot on. Vanguard requires it |
| **Easy Anti-Cheat** (Fortnite, CoD) | ✅ Works | Works with every playbook setting |
| **BattlEye** | ✅ Works | Nothing to change |

> ❗ **Don't turn off Secure Boot.** Several anti-cheats require it, and the playbook is built to keep it on. No game requires BitLocker; [here's why](docs/HOW-IT-WORKS.md#does-any-game-require-bitlocker).

---

## Transparency

- Every release is built by [GitHub Actions](.github/workflows/release.yml) straight from this repository. Nothing is built by hand.
- Each release includes `SHA256SUMS.txt` with checksums for `Chamber.apbx` and every bundled script. Check yours with `Get-FileHash Chamber.apbx` in PowerShell.
- AME Wizard runs the playbook through its open-source [TrustedUninstaller](https://github.com/Ameliorated-LLC/trusted-uninstaller-cli) backend.
- What the playbook changes, and what it deliberately leaves alone, is listed in [How it works](docs/HOW-IT-WORKS.md).

---

## Community and support

- 💬 **Discord** — questions, results and help: [**discord.gg/TG4djSaZ2w**](https://discord.gg/TG4djSaZ2w)
- ⭐ **Support the project** — help keep it free and get **exclusive access** in the Discord: [**Support & Exclusive Access**](https://discord.com/servers/chambertech-758350757451399191)

## Disclaimer

The playbook makes significant changes to Windows. Use it on a **fresh install**, at your own risk, and understand what an option does before you tick it on a PC you depend on.

## License

The ChamberTech Playbook is licensed under [CC BY-NC-SA 4.0](LICENSE): free to use, share and adapt with attribution. Commercial redistribution needs permission from ChamberTech LLC.

---

<p align="center"><strong>ChamberTech Playbook — built for competitors.</strong><br>
<a href="https://chambertech.net">chambertech.net</a> · <a href="https://x.com/ChamberTech_">X</a> · <a href="https://youtube.com/@ChamberTech">YouTube</a> · <a href="https://discord.gg/TG4djSaZ2w">Discord</a></p>
