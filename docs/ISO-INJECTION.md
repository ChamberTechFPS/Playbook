# Installing from a USB (ISO injection)

[← Back to the README](../README.md)

Useful if you set up more than one PC, or want a fresh Windows install that comes out of setup already configured.

AME Wizard can bake the ChamberTech Playbook into a Windows 11 ISO so it applies during a custom out-of-box experience at first boot instead of being run manually afterwards. Useful if you build more than one machine.

> ⚠️ **Requires v1.3.0 or later.** ISO injection is declared in `playbook.conf`, so AME Wizard only offers it for builds that carry that declaration. Earlier releases — v1.2.6 and below — do not, and AME will simply not list the playbook on its injection playbook screen. If the playbook does not appear there, you are on an older `.apbx`; download the current one from [Releases](https://github.com/ChamberTechFPS/Playbook/releases).

**x64 only.** The playbook does not support ARM64 — the cached browser payloads are x64 builds, and the tweaks are untested there. AME may not stop you selecting an ARM64 ISO; do not. If you do, the playbook's first action detects ARM64 at first boot and halts before changing anything, so the result is an unmodified Windows install — how AME's OOBE screen presents that halt has not been tested.

**Two people, two moments.** Worth being clear about, because the options work differently here than in a normal run:

- The **ISO creator** picks the Windows ISO, the playbook options, and the browser. Those choices are baked into the image and applied to **every PC installed from it**. They cannot be changed at first boot.
- The **first-boot user** — possibly someone else entirely, receiving a finished PC — sees the playbook's summary and watches it run. They do not get to edit what was embedded.

1. In AME Wizard, choose **ISO Injection** and supply a Windows 11 ISO (build 26100, 26200, or 26300).
2. Drag `Chamber.apbx` in when prompted, accept the terms, and pick your options and browser. Injection takes roughly 10–15 minutes, plus the browser download.
3. Write the ISO to a USB drive. **AME Wizard writes ISOs to USB itself**, so no separate tool is needed — pick the drive in AME and let it write. Ventoy and Rufus also work if you prefer them.
4. The playbook applies during OOBE. Pick your region and account as normal while it runs.
5. At the first sign-in, a **Driver Setup** page opens on its own: chipset driver first, restart, then GPU and network drivers. That is all the person who receives the PC sees - it doesn't mention Verify, undo, AME or the playbook. The page opens once per user, and the **Driver Setup** shortcut on the desktop brings it back. Verify, the support report and Restore stay in `C:\ChamberTech\PostInstall` for you or ChamberTech support, listed in a collapsed "For ChamberTech support" section at the bottom of the page.

Notes:

- **Let AME Wizard write the USB — do not extract the ISO and copy the files across.** AME saves the injected ISO to `C:\ProgramData\AME\Images\`, not next to the ISO you supplied, so check there if you cannot find it. Hand-copying extracted files produces media that will not boot the injected image: `install.wim` is well over 4 GB so FAT32 cannot hold it, and an NTFS stick will not UEFI-boot on most firmware. Windows installs, but from a stock image — you get Microsoft's normal setup and no playbook.
- **Setup finishes at the first sign-in.** The playbook runs during OOBE, before your account exists. When you first sign in, Windows applies its own theme and visual defaults, and resets a few telemetry settings. So at each account's first sign-in, the playbook quietly re-applies its per-user settings (dark mode, visual effects, the search box, the classic right-click menu, windowed-game optimizations, OLED taskbar auto-hide). A one-time background task re-applies the system-wide ones. Both are driven by the same manifest Verify checks. Some settings take full effect after the restart the Driver Setup page asks for.
- **The browser is cached into the image, not downloaded at first boot.** Injection downloads the Chrome or Brave installer onto the ISO. At first boot the playbook checks the file is present and carries a valid signature from Google or Brave, then installs it silently. Nothing is downloaded during OOBE, and *Skip* caches and installs nothing.
- **No internet connection is needed during setup.** The browser and the Visual C++ runtimes are already on the USB, so a PC whose Wi-Fi or Ethernet driver Windows doesn't include still finishes setup. Setup offers a connection if one is available; connect afterwards for Windows Update and your drivers.
- **A bad browser payload is skipped, not run.** If the cached installer is missing, truncated, or signed by anyone other than the expected vendor, the playbook skips it and records why. Edge is still there, and you can install a browser normally afterwards. Setup is never blocked by it.
- **What ran is written down.** The playbook writes `C:\ChamberTech\deployment-receipt.json` recording the playbook version, Windows build, whether this was an injected or manual install, which options were selected, and how the browser install went. Verify reads it, and the support report ships it — so "that option was never selected" and "that option was selected and failed" stop looking the same.
- **Automatic device encryption is turned off in the image.** Windows 11 24H2+ silently encrypts the system drive during setup and seals the key to the TPM, so a BIOS update, Secure Boot change, TPM clear or CMOS reset can strand the PC at a 48-digit recovery-key prompt. ISOs made with the playbook install unencrypted instead. **No anti-cheat requires an encrypted drive** — Secure Boot and TPM 2.0 both stay on, which is what Vanguard, EAC and BattlEye actually check. The trade is that the drive is readable if the PC is stolen or the disk is pulled; turn encryption on yourself from Settings afterwards if you want it, and you will own the recovery key. AME applies this through an `unattend.xml` in the ISO, and the same file also lifts Windows' own "you need the internet" setup block (`BypassNRO`) — AME couples the two.
- **Hardware requirements are *not* bypassed.** The playbook targets titles whose anti-cheat needs Secure Boot and TPM 2.0 — Riot Vanguard will not start without them — so setup still enforces the normal Windows 11 checks.
