# Contributing to Chamber Playbook

## Ground rules

- **Every tweak must justify itself.** PRs adding tweaks need: what it changes, measurable effect (FPS, latency, process count — not "feels faster"), and any compatibility risk. Placebo tweaks get closed.
- **Anti-cheat safety is non-negotiable.** Nothing that disables Secure Boot, patches system binaries, or touches anything kernel-level that Vanguard/EAC/BattlEye could flag.
- **Test in a VM first.** Fresh Windows 11 install in VMware/Hyper-V, snapshot before applying, run the packaged .apbx through AME Wizard, then run verification: `C:\ChamberTech\PostInstall\START-HERE.bat` as administrator, option 1.

## Workflow

1. Edit task YAML in `Configuration/Tasks/` (see [AME docs](https://docs.amelabs.net/creating_playbooks.html) for action syntax).
2. Regenerate the verification manifest: `python3 tools/generate_verification_manifest.py` — commit the updated `PostInstall/Verify/verification-manifest.json`. CI fails if it's stale.
3. Package locally: 7z the repo contents (not the folder) with password `malte`, rename to `.apbx`.
4. Test in a VM, run verification, include the summary in your PR.

## Style

- YAML: single quotes for all paths (`'HKLM\...'`), one logical grouping per task file, comment any non-obvious tweak with what it does and why.
- PowerShell: `Set-StrictMode -Version Latest`, all scripts must be idempotent and read-only unless clearly labeled otherwise.
