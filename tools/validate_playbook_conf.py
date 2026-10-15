#!/usr/bin/env python3
"""Chamber Playbook - playbook.conf / ISO-injection validator.

Re-implements the checks AME Wizard performs on a Playbook when it loads, so a
config that AME would reject - or silently refuse to offer for ISO injection -
fails in CI instead of on a user's machine.

    python3 tools/validate_playbook_conf.py
    python3 tools/validate_playbook_conf.py --expect-version 1.3.0

Rules mirror Ameliorated-LLC/trusted-uninstaller-cli:
  Playbook.Validate()            - required fields, version format, OOBE rules
  AmeliorationUtil.ParseActions  - the per-action IsISOCompatible() gate

On top of AME's own rules it enforces Chamber's ISO staging, because those
mistakes are the expensive kind: they do not fail at load, they fail on a
machine somebody has already booted.

  - `!task:` paths resolve, and every task file has a title and an actions list
  - each <Software> package has a matching !download and a real feature option
  - cached downloads are HTTPS from a vendor-owned host, with an option, a
    package name, a destination and cpuArch X64, staged `iso: only`/`oobe: false`
  - every cached payload is one Install-CachedBrowser.ps1 knows how to install
  - winget and shutdown.exe actions are `oobe: false`, so neither reaches an
    injected OOBE
  - !powerShell is never staged to injection
  - main.yml opens with the ARM64 guard, ungated, halting before any phase
  - progress text is "Step N of M: ..." and never counts backwards
  - the security trade-off page is the last feature page
  - the deployment receipt's version literal matches <Version>
  - the welcome page <ProgressText> promises ships, is self-contained, and is
    scheduled machine-wide by Install-PostInstallCompanion.ps1

Exits non-zero and prints every problem found.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONF = REPO / "playbook.conf"
CONFIG_DIR = REPO / "Configuration"

# Playbook.Validate() requires these to be non-empty.
REQUIRED_FIELDS = [
    "Name", "Username", "UniqueId", "ShortDescription",
    "Title", "Description", "Details", "Version",
]

# ComponentIcon enum - the only icons AME can render on the OOBE page.
VALID_ICONS = {"Rocket", "Privacy", "Lock"}
VALID_INTERNET = {"Request", "Force"}

# Action types whose IsISOCompatible() always returns an error string. Giving
# any of these an `iso:` value other than false aborts playbook parsing with
# e.g. "For safety reasons, CmdAction does not support iso." Two more are
# conditional and checked separately: !service accepts iso only for its
# delete/change operations, and !software rejects `iso: only`.
ISO_INCOMPATIBLE_ACTIONS = {"cmd", "run", "powerShell", "taskKill", "appx", "systemPackage"}

VERSION_RE = re.compile(r"^\d+(\.\d+){0,2}$")
BUILD_RE = re.compile(r"^\d{5}(\.\d+)?$")
# AME renders these on the OOBE summary page; its own examples set the band.
TITLE_LEN = (6, 20)
DESC_LEN = (80, 120)
EMPTY_GUID = "00000000-0000-0000-0000-000000000000"

ACTION_RE = re.compile(r"^(\s*)-\s*!(\w+):")
# A `key: value` property line inside an action block.
PROP_RE = re.compile(r"^(\w+):\s*(.*)$")

# Hosts a cached installer may come from. The payload runs elevated during
# Windows setup with nobody watching, so the source is pinned to release hosts
# the vendor itself controls - not a mirror, not a shortener, not a CDN whose
# namespace someone else can write to (NFR-003).
VENDOR_HOSTS = {"dl.google.com", "github.com", "brave.com"}

# $ChamberVersion in Executables/Write-ChamberReceipt.ps1.
RECEIPT_VERSION_RE = re.compile(r"\$ChamberVersion\s*=\s*'([^']+)'")


def text_of(root, tag):
    el = root.find(tag)
    return el.text.strip() if el is not None and el.text else ""


def check_conf(errors):
    try:
        root = ET.parse(CONF).getroot()
    except ET.ParseError as exc:
        errors.append(f"playbook.conf is not well-formed XML: {exc}")
        return None

    if root.tag != "Playbook":
        errors.append(f"Root element must be <Playbook>, found <{root.tag}>.")

    for field in REQUIRED_FIELDS:
        if not text_of(root, field):
            errors.append(f"<{field}> is required and must be non-empty.")

    version = text_of(root, "Version")
    if version and not VERSION_RE.match(version):
        errors.append(
            f"Version '{version}' is invalid. AME accepts 1, 1.0 or 1.0.0."
        )

    unique_id = text_of(root, "UniqueId")
    if unique_id and unique_id.lower() == EMPTY_GUID:
        errors.append("UniqueId must be a real UUIDv4, not the empty GUID.")

    # SupportedBuilds gates whether AME will run the playbook at all, and a typo
    # here fails silently by simply excluding that Windows release.
    builds = root.findall("SupportedBuilds/string")
    if builds:
        for b in builds:
            raw = (b.text or "").strip()
            if not BUILD_RE.match(raw):
                errors.append(
                    f"SupportedBuilds entry {raw!r} is not a build number. "
                    "Use the major build alone (e.g. 26300), optionally with an "
                    "update build (26300.1234)."
                )
        seen = [(b.text or "").strip() for b in builds]
        dupes = {x for x in seen if seen.count(x) > 1}
        if dupes:
            errors.append(f"Duplicate SupportedBuilds entries: {sorted(dupes)}.")

    supports_iso = text_of(root, "SupportsISO").lower() == "true"
    if not supports_iso:
        errors.append(
            "SupportsISO is not true. AME Wizard only lists playbooks with "
            "<SupportsISO>true</SupportsISO> in its ISO injection picker."
        )
        return root

    # --- Rules AME enforces only when SupportsISO is true ------------------
    oobe = root.find("OOBE")
    bullets = oobe.findall("BulletPoints/BulletPoint") if oobe is not None else []

    if oobe is None or not bullets:
        errors.append(
            "OOBE BulletPoints must be specified when SupportsISO is true."
        )
    elif len(bullets) != 3:
        errors.append(
            f"There must be exactly three OOBE BulletPoints, found {len(bullets)}."
        )
    else:
        icons = [b.get("Icon", "") for b in bullets]
        if len(set(icons)) != len(icons):
            errors.append(f"OOBE bullet point icons must be distinct: {icons}.")
        for icon in icons:
            if icon not in VALID_ICONS:
                errors.append(
                    f"Icon '{icon}' is not a ComponentIcon. "
                    f"Valid icons: {', '.join(sorted(VALID_ICONS))}."
                )
        for b in bullets:
            if not (b.get("Title") or "").strip():
                errors.append("Every OOBE bullet point needs a non-empty Title.")
            if not (b.get("Description") or "").strip():
                errors.append("Every OOBE bullet point needs a non-empty Description.")
            # "The Description and Title lengths must roughly match the lengths
            # in the examples above." AME's own examples run 8-16 char titles and
            # 92-106 char descriptions, and these render on the OOBE summary page,
            # so anything much longer risks being clipped on screen.
            title, desc = b.get("Title") or "", b.get("Description") or ""
            if title and not (TITLE_LEN[0] <= len(title) <= TITLE_LEN[1]):
                errors.append(
                    f"OOBE bullet Title {title!r} is {len(title)} chars; AME's "
                    f"examples are {TITLE_LEN[0]}-{TITLE_LEN[1]}."
                )
            if desc and not (DESC_LEN[0] <= len(desc) <= DESC_LEN[1]):
                errors.append(
                    f"OOBE bullet Description for {title!r} is {len(desc)} chars; "
                    f"AME's examples are {DESC_LEN[0]}-{DESC_LEN[1]}."
                )

    if oobe is not None:
        internet = text_of(oobe, "Internet")
        if internet and internet not in VALID_INTERNET:
            errors.append(
                f"OOBE Internet '{internet}' is invalid. "
                f"Valid values: {', '.join(sorted(VALID_INTERNET))}."
            )

    # Software packages render icons from an Images/ folder; AME throws if the
    # folder is missing, so only allow <Software> when Images/ actually exists.
    packages = root.findall("Software/Package")
    if packages:
        images = REPO / "Images"
        if not images.is_dir():
            errors.append(
                "<Software> is declared but there is no Images/ folder at the "
                "playbook root; AME resolves every Package <Icon> from it."
            )
        else:
            for pkg in packages:
                icon = text_of(pkg, "Icon")
                if icon and not list(images.glob(icon + "*")):
                    errors.append(f"Software icon '{icon}' not found in Images/.")

    return root


def parse_task_actions(path):
    """Yield (lineno, action_name, props) for every bang action in a task file.

    Line-based on purpose, matching tools/generate_verification_manifest.py:
    AME's bang tags (`!cmd:`, `!download:`) are not valid YAML to a stock loader,
    and adding PyYAML plus custom constructors to a CI validator buys nothing
    over reading these very regular files directly.
    """
    actions, props = [], {}
    current, indent, start = None, 0, 0
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = ACTION_RE.match(line)
        if match:
            if current is not None:
                actions.append((start, current, props))
            indent, current, start, props = len(match.group(1)), match.group(2), lineno, {}
            rest = line[match.end():].strip()
            if rest.startswith("{") and rest.endswith("}"):
                for part in rest[1:-1].split(","):
                    kv = PROP_RE.match(part.strip())
                    if kv:
                        props[kv.group(1)] = kv.group(2).strip().strip("'\"")
                actions.append((start, current, props))
                current = None
            continue
        if current is None:
            continue
        if (len(line) - len(line.lstrip())) <= indent:
            actions.append((start, current, props))
            current = None
            continue
        kv = PROP_RE.match(line.strip())
        if kv:
            props[kv.group(1)] = kv.group(2).strip().strip("'\"")
    if current is not None:
        actions.append((start, current, props))
    return actions


def check_actions(errors):
    """Stage-correctness gates for every action AME will run.

    Three separate failure modes live here:

    1. `iso:` on an action type AME refuses to inject. !cmd, !run, !powerShell,
       !taskKill, !appx and !systemPackage fail IsISOCompatible()
       unconditionally, and the failure is a parse abort - the whole playbook
       stops loading, not just that action.
    2. `iso:` on the conditionally compatible types: !service outside its
       delete/change operations, and !software set to `iso: only`.
    3. A live-network or restart action left reachable from an injected OOBE.
       winget is the whole reason ISO support needed a cached-payload path, and
       an unannotated winget action puts the network dependency straight back.
    """
    for path in sorted(CONFIG_DIR.rglob("*.yml")):
        rel = path.relative_to(REPO).as_posix()
        for lineno, name, props in parse_task_actions(path):
            iso = props.get("iso", "").lower()
            oobe = props.get("oobe", "").lower()

            if iso and iso != "false" and name in ISO_INCOMPATIBLE_ACTIONS:
                errors.append(
                    f"{rel}:{lineno}: !{name} has `iso: {iso}`. "
                    f"{name}Action always fails IsISOCompatible(), so this "
                    "aborts playbook parsing. Remove it or use `iso: false`."
                )
            operation = props.get("operation", "").lower()
            if iso and iso != "false" and name == "service" and operation not in ("delete", "change"):
                errors.append(
                    f"{rel}:{lineno}: !service has `iso: {iso}` with operation "
                    f"{operation or '(default)'!r}. ServiceAction only supports iso "
                    "for delete and change, so this aborts playbook parsing."
                )
            # SoftwareAction defaults to `iso: true`, so a bare !software is
            # checked too - only an explicit `only` is rejected.
            if name == "software" and iso == "only":
                errors.append(
                    f"{rel}:{lineno}: !software has `iso: only`, which "
                    "SoftwareAction rejects at parse time. Use the default "
                    "(cache at injection, install at OOBE) or `iso: false`."
                )

            blob = " ".join(str(v) for v in props.values())
            if "winget" in blob and oobe != "false":
                errors.append(
                    f"{rel}:{lineno}: !{name} calls winget but is not "
                    "`oobe: false`. winget ships as App Installer, a "
                    "Store-provisioned package that is not reliably registered "
                    "during an injected OOBE - and it would race the cached "
                    "installer. Traditional runs only."
                )
            if "shutdown.exe" in blob and oobe != "false":
                errors.append(
                    f"{rel}:{lineno}: !{name} calls shutdown.exe but is not "
                    "`oobe: false`. AME owns the restart during an injected "
                    "OOBE; restarting underneath it truncates its completion "
                    "state and logs."
                )


def check_iso_cache(root, errors):
    """The injection stage: what gets cached, and whether anything can use it.

    Every rule here catches a failure that is otherwise invisible until an ISO
    has been built, booted and watched - the slowest feedback loop in the repo.
    """
    cache = CONFIG_DIR / "Tasks" / "0-iso-cache.yml"
    supports_iso = root is not None and text_of(root, "SupportsISO").lower() == "true"

    if not cache.is_file():
        if supports_iso:
            errors.append(
                "Configuration/Tasks/0-iso-cache.yml is missing. Without it the "
                "OOBE has no cached payload and falls back to needing a network."
            )
        return

    downloads = {}
    for lineno, name, props in parse_task_actions(cache):
        where = f"Configuration/Tasks/0-iso-cache.yml:{lineno}"
        if name != "download":
            errors.append(
                f"{where}: !{name} does not belong in the injection stage. This "
                "file runs offline against a mounted image - only !download is "
                "safe there."
            )
            continue

        for required in ("option", "package", "url", "destination"):
            if not props.get(required):
                errors.append(f"{where}: !download is missing `{required}`.")

        url = props.get("url", "")
        if url and not url.startswith("https://"):
            errors.append(f"{where}: download URL is not HTTPS: {url}")
        host = url.split("/")[2].lower() if url.count("/") >= 2 else ""
        if host and not any(host == d or host.endswith("." + d) for d in VENDOR_HOSTS):
            errors.append(
                f"{where}: download host {host!r} is not a known vendor-owned "
                f"release host ({', '.join(sorted(VENDOR_HOSTS))}). A cached "
                "installer runs elevated during setup; it has to come from the "
                "vendor."
            )
        if props.get("cpuArch", "").upper() != "X64":
            errors.append(
                f"{where}: !download needs `cpuArch: X64`. Chamber ISO v1 is x64 "
                "only (PRD FR-008)."
            )
        if props.get("iso", "").lower() != "only":
            errors.append(
                f"{where}: !download must be `iso: only` so it never runs against "
                "the live system."
            )
        if props.get("oobe", "").lower() != "false":
            errors.append(
                f"{where}: !download must be `oobe: false`. Downloading at first "
                "boot is the network dependency the cache exists to remove."
            )

        if props.get("package"):
            downloads[props["package"]] = props.get("destination", "")

    _check_software_pairing(root, downloads, errors)


def _check_software_pairing(root, downloads, errors):
    """Tie <Software> tiles, cached payloads and the OOBE installer together."""
    if root is not None:
        option_names = [
            (o.findtext("Name") or "").strip()
            for o in root.findall("FeaturePages/*/Options/*")
        ]
        for pkg_el in root.findall("Software/Package"):
            pkg_name = text_of(pkg_el, "Name")
            # AME's docs: Name "should ideally correspond to the `package`
            # property" on a !download. A tile matching no cached payload is
            # almost certainly a typo, so Chamber makes it a hard rule.
            if pkg_name and pkg_name not in downloads:
                errors.append(
                    f"<Software> package {pkg_name!r} has no matching !download "
                    "`package:` in Configuration/Tasks/0-iso-cache.yml, so the "
                    "OOBE tile names a browser nothing caches."
                )
            option = pkg_el.get("Option")
            if option and option_names and option not in option_names:
                errors.append(
                    f"<Software> package {pkg_name!r} is gated on option "
                    f"{option!r}, which no feature page defines."
                )

    # Every cached file needs something that installs it, and that installer has
    # to know the same file name. This is the pairing FR-025 rests on: a
    # signature check against a file nothing downloaded is not a check.
    installer = REPO / "Executables" / "Install-CachedBrowser.ps1"
    catalog = installer.read_text(encoding="utf-8") if installer.is_file() else ""
    for pkg, destination in downloads.items():
        filename = destination.replace("/", "\\").split("\\")[-1]
        if filename and filename not in catalog:
            errors.append(
                f"Cached payload {filename!r} (package {pkg!r}) does not appear "
                "in Executables/Install-CachedBrowser.ps1, so nothing during the "
                "OOBE knows how to verify or install it."
            )


def check_receipt_version(root, errors):
    """The receipt is the only record of which Chamber built a given machine."""
    if root is None:
        return
    script = REPO / "Executables" / "Write-ChamberReceipt.ps1"
    if not script.is_file():
        return
    match = RECEIPT_VERSION_RE.search(script.read_text(encoding="utf-8"))
    if not match:
        errors.append(
            "Executables/Write-ChamberReceipt.ps1 has no $ChamberVersion literal; "
            "the deployment receipt would record no version."
        )
        return
    declared = text_of(root, "Version")
    if declared and match.group(1) != declared:
        errors.append(
            f"Write-ChamberReceipt.ps1 stamps version {match.group(1)!r} but "
            f"playbook.conf declares {declared!r}. Every receipt written by this "
            "build would name the wrong Chamber."
        )


def check_welcome_page(root, errors):
    """<ProgressText> promises a driver page at first sign-in; keep that true.

    The progress screen is all a first-boot user sees of Chamber, and it tells
    them a page will open with the drivers they need. The page is also the
    target of the desktop shortcut, so it is checked whatever the text says. If the page stops shipping, or
    the companion stops scheduling it, they reach the desktop with nothing.
    Machine-wide paths are required because at OOBE time the person who will
    use the PC may not have a profile yet.
    """
    if root is None:
        return
    page = REPO / "PostInstall" / "Welcome.html"
    if not page.is_file():
        errors.append(
            "<ProgressText> promises a welcome page but PostInstall/Welcome.html "
            "does not exist."
        )
        return
    html = page.read_text(encoding="utf-8")
    if re.search(r"""(?:src|href)=["']http://|<script[^>]+src=|<link[^>]+stylesheet""", html, re.I):
        errors.append(
            "PostInstall/Welcome.html loads external resources or uses http://. "
            "It opens at first sign-in, possibly offline: keep it self-contained."
        )
    script = REPO / "Executables" / "Install-PostInstallCompanion.ps1"
    body = script.read_text(encoding="utf-8") if script.is_file() else ""
    for needle, why in (
        ("Welcome.html", "does not reference Welcome.html"),
        ("CommonStartup", "does not schedule the page from the All Users Startup folder"),
        ("CommonDesktopDirectory", "does not put the shortcut on the Public Desktop"),
    ):
        if needle not in body:
            errors.append(
                f"Executables/Install-PostInstallCompanion.ps1 {why}, but "
                "<ProgressText> tells the user a welcome page will open."
            )


def check_task_files(errors):
    """`!task:` targets exist, and every task file is one AME can read."""
    main = CONFIG_DIR / "main.yml"
    if not main.is_file():
        errors.append("Configuration/main.yml is missing.")
        return

    for lineno, name, props in parse_task_actions(main):
        if name != "task":
            continue
        target = props.get("path", "").replace("\\", "/")
        if not target:
            errors.append(f"Configuration/main.yml:{lineno}: !task has no `path`.")
        elif not (CONFIG_DIR / target).is_file():
            errors.append(
                f"Configuration/main.yml:{lineno}: !task path {target!r} does not "
                "exist. AME fails the run when it cannot resolve an include."
            )

    for path in sorted(CONFIG_DIR.rglob("*.yml")):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(REPO).as_posix()
        if not re.search(r"^title:\s*\S", text, re.M):
            errors.append(f"{rel}: no `title:` at the top level.")
        if not re.search(r"^actions:\s*$", text, re.M):
            errors.append(f"{rel}: no `actions:` list.")


def check_arch_guard(errors):
    """main.yml must open with the ARM64 guard, and nothing may weaken it.

    Chamber is x64 only, and AME has no architecture requirement in
    playbook.conf, so this action is the only thing standing between an ARM64
    machine and ten untested phases. Each rule below is a way it could be
    quietly disabled: moved after a phase, gated on an option nobody ticks,
    filtered by `cpuArch` or `builds` (the command does its own test), staged away from
    the live system, or left logging instead of halting.
    """
    main = CONFIG_DIR / "main.yml"
    if not main.is_file():
        return
    where = "Configuration/main.yml"

    actions = parse_task_actions(main)
    guard_index = next(
        (
            i for i, (_, name, props) in enumerate(actions)
            if name == "cmd"
            and "PROCESSOR_ARCHITECTURE" in props.get("command", "")
            and "ARM64" in props.get("command", "").upper()
        ),
        None,
    )
    if guard_index is None:
        errors.append(
            f"{where}: the ARM64 guard (!cmd reading PROCESSOR_ARCHITECTURE) is "
            "missing. Chamber is x64 only and AME will otherwise run every phase "
            "on ARM64."
        )
        return

    lineno, _, props = actions[guard_index]
    if guard_index != 0:
        errors.append(
            f"{where}:{lineno}: the ARM64 guard must be the first action, so it "
            "halts before the snapshot or any phase changes the system."
        )
    for key in ("option", "options", "cpuArch", "builds", "iso", "oobe"):
        if key in props:
            errors.append(
                f"{where}:{lineno}: the ARM64 guard must not set `{key}:`. It has "
                "to run unconditionally on every live run."
            )
    if props.get("errorAction", "") != "Halt" or "halt" not in props.get("handleExitCodes", "").lower():
        errors.append(
            f"{where}:{lineno}: the ARM64 guard needs `errorAction: Halt` and a "
            "`handleExitCodes` entry mapping its exit code to halt, or AME logs "
            "the failure and carries on."
        )
    if props.get("wait", "").lower() != "true":
        errors.append(
            f"{where}:{lineno}: the ARM64 guard needs `wait: true` - !cmd defaults "
            "to not waiting, so no exit code would ever be seen."
        )


STEP_RE = re.compile(r"^Step (\d+) of (\d+): \S")


def check_status_order(errors):
    """Progress text reads "Step N of M: ..." and N never goes backwards.

    The status line is the one thing on screen for the whole run, and the OOBE
    tutorial walks viewers through it. Walks main.yml in run order, descending
    into each live `!task:` include, so a status added anywhere is checked
    where it will actually appear.
    """
    main = CONFIG_DIR / "main.yml"
    if not main.is_file():
        return
    last, total = 0, None

    def walk(path):
        nonlocal last, total
        rel = path.relative_to(REPO).as_posix()
        for lineno, name, props in parse_task_actions(path):
            if name == "task" and props.get("iso", "").lower() != "only":
                target = CONFIG_DIR / props.get("path", "").replace("\\", "/")
                if target.is_file():
                    walk(target)
                continue
            if name not in ("status", "writeStatus"):
                continue
            text = props.get("status", "")
            match = STEP_RE.match(text)
            if not match:
                errors.append(
                    f"{rel}:{lineno}: status {text!r} does not start with "
                    "'Step N of M: '. Every progress line is numbered."
                )
                continue
            step, of = int(match.group(1)), int(match.group(2))
            if total is None:
                total = of
            elif of != total:
                errors.append(f"{rel}:{lineno}: status says 'of {of}', earlier ones say 'of {total}'.")
            if step < last:
                errors.append(
                    f"{rel}:{lineno}: status is Step {step} after Step {last}. "
                    "Progress text must never count backwards."
                )
            last = max(last, step)

    walk(main)


def check_feature_pages(root, errors, supports_iso):
    """Feature page rules from FeaturePage.Validate(), plus the radio-selection trap.

    RadioOption has no IsChecked property - only CheckboxOption does - so a radio
    page carries its selection solely in the page's DefaultOption attribute. With
    neither set the page resolves to no selection, which the GUI papers over
    (the user clicks one) but ISO injection cannot: there is nobody to click, and
    AME dies with a NullReferenceException in IsoProgressDialog.Begin.
    """
    pages = root.find("FeaturePages")
    if pages is None:
        return

    # Pages run friendly-first. The security trade-offs close the wizard, so a
    # first-time viewer's first screen is a browser choice, not "turn off
    # VBS" - and the riskiest page is the last thing decided. The page is found
    # by disable-vbs; remove-defender used to anchor it and was retired in 1.3.0.
    page_list = list(pages)
    all_names = [(o.findtext("Name") or "").strip() for p in page_list for o in p.findall("Options/*")]
    if "remove-defender" in all_names:
        errors.append(
            "FeaturePages: remove-defender was retired in 1.3.0 - Tamper Protection "
            "makes Windows ignore it on every fresh install. Do not bring it back."
        )
    security = [
        i for i, p in enumerate(page_list)
        if any((o.findtext("Name") or "").strip() == "disable-vbs" for o in p.findall("Options/*"))
    ]
    if security and security[0] != len(page_list) - 1:
        errors.append(
            "FeaturePages: the security trade-off page (disable-vbs) must be "
            "the last page."
        )

    for page in pages:
        opts = page.findall("Options/*")
        names = [(o.findtext("Name") or "").strip() for o in opts]
        has_top = page.find("TopLine") is not None
        has_bottom = page.find("BottomLine") is not None
        label = f"{page.tag} '{(page.get('Description') or '')[:45]}'"

        if page.tag in ("CheckboxPage", "RadioPage"):
            if len(opts) > 2 and has_top and has_bottom:
                errors.append(
                    f"{label}: max 2 options with both a TopLine and a BottomLine, "
                    f"found {len(opts)}."
                )
            elif len(opts) > 3 and (has_top or has_bottom):
                errors.append(
                    f"{label}: max 3 options with a TopLine or BottomLine, "
                    f"found {len(opts)}."
                )
        if len(opts) > 4:
            errors.append(f"{label}: max 4 options, found {len(opts)}.")

        if len(set(names)) != len(names):
            errors.append(f"{label}: duplicate option names {names}.")

        if page.tag not in ("RadioPage", "RadioImagePage"):
            continue

        for opt in opts:
            if opt.get("IsChecked") is not None:
                errors.append(
                    f"{label}: <{opt.tag} IsChecked=...> is not a real attribute — "
                    "only CheckboxOption has IsChecked, so this is silently ignored. "
                    "Set the page's DefaultOption instead."
                )

        default = page.get("DefaultOption")
        if not default:
            msg = (
                f"{label}: no DefaultOption. A radio page has no other way to carry "
                "a selection"
            )
            errors.append(
                msg + ", and ISO injection crashes without one."
                if supports_iso
                else msg + "."
            )
        elif default not in names:
            errors.append(
                f"{label}: DefaultOption '{default}' matches no option name {names}."
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--expect-version",
        help="Fail unless <Version> equals this (leading 'v' ignored).",
    )
    args = parser.parse_args()

    errors = []
    root = check_conf(errors)
    check_actions(errors)
    check_task_files(errors)
    check_arch_guard(errors)
    check_status_order(errors)
    check_iso_cache(root, errors)
    check_receipt_version(root, errors)
    check_welcome_page(root, errors)
    if root is not None:
        check_feature_pages(root, errors, text_of(root, "SupportsISO").lower() == "true")

    if args.expect_version and root is not None:
        expected = args.expect_version.lstrip("vV")
        actual = text_of(root, "Version")
        if actual != expected:
            errors.append(
                f"<Version> is {actual!r} but the release tag says {expected!r}. "
                "Bump playbook.conf before tagging."
            )

    if errors:
        print("playbook.conf validation FAILED:\n", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("playbook.conf OK - valid for AME Wizard and eligible for ISO injection.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
