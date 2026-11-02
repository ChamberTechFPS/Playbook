# ChamberTech Playbook

ChamberTech Playbook is an [AME Wizard](https://ameliorated.io) playbook I built to set up a fresh Windows 11 install for competitive gaming. You load it, pick your options, and it does the rest in one pass.

Watch the install walkthrough: [ChamberTech Playbook install tutorial](https://youtu.be/jzM9MHyzCiI)

## What it does

- Sets a power plan based on your hardware, and tunes boot settings and background services.
- Applies registry tweaks for latency and input.
- Blocks telemetry and removes the consumer apps you don't need. The Store, winget and Windows Security stay.
- Cleans up the UI: dark mode, classic right-click menu, file extensions on.
- Leaves Secure Boot on, so it works with Vanguard, Easy Anti-Cheat and BattlEye.
- Opens a Driver Setup page after install so you know what to install and in what order.

## Install

1. Download the latest `Chamber.apbx` from [Releases](https://github.com/ChamberTechFPS/Playbook/releases).
2. Download and open AME Wizard from [ameliorated.io](https://ameliorated.io).
3. Drag `Chamber.apbx` into AME Wizard and follow the prompts.
4. Restart when it's done and follow the Driver Setup page.

Before you start:

- Windows 11 24H2, 25H2 or 26H2, x64 only. I recommend a fresh install.
- Install all Windows updates first.
- You need an internet connection.

ISO injection is supported too. Here's the guide: [ISO injection guide](https://youtu.be/uGvz4M7Lj4Q)

## Check it worked

Run `C:\ChamberTech\PostInstall\START-HERE.bat` as administrator. It checks the tweaks against your actual system and can build a report to send me if something looks off.

## Read it yourself

Everything in ChamberTech Playbook is plain-text YAML and PowerShell. An `.apbx` is a renamed 7z archive (password `malte`, which is an AME convention, not a secret), so you can open it and read every file. Releases are built by GitHub Actions straight from this repo, and each one ships with `SHA256SUMS.txt`.

## Use at your own risk

ChamberTech Playbook makes big changes to Windows. Use it at your own risk.

## Help and links

- Discord: [discord.gg/TG4djSaZ2w](https://discord.gg/TG4djSaZ2w)
- Want it done for you? I tune PCs by hand: [chambertech.net](https://chambertech.net)
- X: [＠chambertech_](https://x.com/ChamberTech_)
- YouTube: [youtube.com/@ChamberTech](https://youtube.com/@ChamberTech)

## License

[CC BY-NC-SA 4.0](LICENSE). Commercial redistribution needs permission from ChamberTech LLC.
