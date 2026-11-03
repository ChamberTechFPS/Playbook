#!/usr/bin/env python3
"""Chamber Playbook — Verification Manifest Generator.

Parses Configuration/Tasks/*.yml and Executables/ scripts to produce
PostInstall/Verify/verification-manifest.json, the single source of truth the
post-install verifier reads. Regenerate whenever tasks change:

    python3 tools/generate_verification_manifest.py

Runs in CI (see .github/workflows/release.yml) so the manifest can never
drift out of sync with the playbook.

Deliberately line-based rather than a full YAML parser: AME task files are
regular, and this avoids a PyYAML dependency (bang-tags break stock loaders).

A !cmd that sets a registry value (Set-ItemProperty, reg add, fsutil
disablelastaccess) is recorded too. DisablePagingExecutive is applied that
way, behind an 8 GB RAM guard, and used to be invisible to Verify, the
pre-install snapshot and Restore.
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TASKS_DIR = REPO / "Configuration" / "Tasks"
DEBLOAT_PS1 = REPO / "Executables" / "Invoke-BalancedDebloat.ps1"
HOSTS_PS1 = REPO / "Executables" / "Update-HostsTelemetryBlocks.ps1"
OUT = REPO / "PostInstall" / "Verify" / "verification-manifest.json"

KV_RE = re.compile(r"^\s*(\w+):\s*(.*)$")
BCD_RE = re.compile(r"bcdedit\s+/set\s+(\S+)\s+(\S+)")
BCD_TIMEOUT_RE = re.compile(r"bcdedit\s+/timeout\s+(\d+)")
HOSTS_ENTRY_RE = re.compile(r"'(0\.0\.0\.0\s+\S+)'")
APPX_NAMES_RE = re.compile(r"-AppxNames\s+@\(([^)]*)\)")
FSUTIL_LASTACCESS_RE = re.compile(r"fsutil\s+behavior\s+set\s+disablelastaccess\s+(\d)", re.IGNORECASE)
# A !cmd that writes the registry. `reg query` is a read and must not match.
REGISTRY_WRITE_RE = re.compile(
    r"(?i)(?:\b(?:Set|New)-ItemProperty\b|\breg(?:\.exe)?\s+add\b|fsutil\s+behavior\s+set\s+disablelastaccess\b)"
)
PS_REG_TYPES = {
    "dword": "REG_DWORD",
    "qword": "REG_QWORD",
    "string": "REG_SZ",
    "expandstring": "REG_EXPAND_SZ",
    "binary": "REG_BINARY",
    "multistring": "REG_MULTI_SZ",
}
RAM_GE_RE = re.compile(r"(?i)\$ram\s*-ge\s*(\d+)\s*GB\b")


def normalize_reg_path(path: str) -> str:
    """PowerShell provider path or reg.exe key -> the HKLM\\... form the manifest uses."""
    path = path.strip().strip('"').strip("'")
    for src, dst in (
        ("HKEY_LOCAL_MACHINE\\", "HKLM\\"),
        ("HKEY_CURRENT_USER\\", "HKCU\\"),
        ("HKEY_CLASSES_ROOT\\", "HKCR\\"),
        ("HKLM:\\", "HKLM\\"),
        ("HKCU:\\", "HKCU\\"),
        ("HKCR:\\", "HKCR\\"),
    ):
        if path.upper().startswith(src.upper()):
            path = dst + path[len(src):]
            break
    m = re.match(r"(?i)^(HKLM|HKCU|HKCR|HKU)\\(.*)$", path)
    if not m:
        return ""
    return m.group(1).upper() + "\\" + m.group(2)


def _statement_end(text: str) -> int:
    """Index of the next semicolon that is not inside quotes, or len(text)."""
    quote = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
        elif ch == ";":
            return i
    return len(text)


def _invocations(command: str, pattern: str):
    for match in re.finditer(pattern, command):
        rest = command[match.end():]
        yield command[match.start(): match.end() + _statement_end(rest)]


def _ps_param(chunk: str, name: str):
    match = re.search(
        rf"(?i)-{name}\s+(?:'([^']*)'|\"([^\"]*)\"|(\S+))",
        chunk,
    )
    if not match:
        return None
    token = next(group for group in match.groups() if group is not None)
    return token.strip().rstrip(";}")


def _flag_value(chunk: str, flag: str):
    match = re.search(
        rf"(?i)(?:^|\s)/{flag}\s+(?:\"([^\"]*)\"|'([^']*)'|(\S+))",
        chunk,
    )
    if not match:
        return None
    return next(group for group in match.groups() if group is not None)


def command_writes_registry(command: str) -> bool:
    return REGISTRY_WRITE_RE.search(command or "") is not None


def registry_writes_from_command(command: str):
    """Registry values a !cmd command string sets.

    Returned dicts use manifest fields (path, value, type, data). `emit` is
    false for a write whose effect is the key existing (reg add /ve): Restore
    deletes that key, and an empty default value is not a useful manifest row.
    `error` is set when the write is visible but not parseable — the generator
    and the validator both fail closed on that, so a tweak cannot silently
    skip verification and undo.

    `$ram -ge NGB` around a Set-ItemProperty is recorded as whenRamAtLeastGb.
    DisablePagingExecutive uses that guard: below 8 GB the value is not set,
    and Verify must not call that a failure.
    """
    command = command or ""
    writes = []

    for chunk in _invocations(command, r"(?i)\b(?:Set|New)-ItemProperty\b"):
        path, name, value, typ = (
            _ps_param(chunk, "Path"),
            _ps_param(chunk, "Name"),
            _ps_param(chunk, "Value"),
            _ps_param(chunk, "Type"),
        )
        ame = normalize_reg_path(path) if path else ""
        reg_type = PS_REG_TYPES.get(typ.lower()) if typ else None
        if not (ame and name and value is not None and reg_type):
            writes.append({
                "error": (
                    "Set-ItemProperty must use -Path, -Name, -Value and -Type "
                    "with a hive path (HKLM:\\... or HKCU:\\...) so it can be "
                    "verified and undone"
                ),
                "emit": False,
            })
            continue
        entry = {
            "path": ame,
            "value": name,
            "type": reg_type,
            "data": value,
            "emit": True,
        }
        # Only a write that sits inside the RAM test gets the guard. A later
        # unconditional Set-ItemProperty in the same command must not inherit it.
        ram = RAM_GE_RE.search(command)
        if ram and command.find(chunk) >= ram.end():
            entry["whenRamAtLeastGb"] = int(ram.group(1))
        writes.append(entry)

    for chunk in _invocations(command, r"(?i)\breg(?:\.exe)?\s+add\b"):
        key_match = re.search(
            r"(?i)\breg(?:\.exe)?\s+add\s+(?:\"([^\"]+)\"|'([^']+)'|(\S+))",
            chunk,
        )
        key = next((g for g in key_match.groups() if g is not None), "") if key_match else ""
        ame = normalize_reg_path(key) if key else ""
        if not ame:
            writes.append({
                "error": "reg add is missing a hive key (HKLM\\... or HKCU\\...)",
                "emit": False,
            })
            continue
        if re.search(r"(?i)(?:^|\s)/ve(?:\s|$)", chunk):
            # Default value, usually empty. The classic context-menu tweak is
            # this shape: the key's existence is the change, and Restore
            # deletes the key. Emitting value "" would make the registry
            # restore loop report UNKNOWN.
            writes.append({
                "path": ame,
                "value": "",
                "type": "REG_SZ",
                "data": "",
                "emit": False,
            })
            continue
        vname = _flag_value(chunk, "v")
        if not vname:
            writes.append({
                "error": f"reg add {ame} has no /v value name and no /ve",
                "emit": False,
            })
            continue
        reg_type = (_flag_value(chunk, "t") or "REG_SZ").upper()
        if not reg_type.startswith("REG_"):
            writes.append({
                "error": f"reg add type {reg_type!r} is not a REG_* type",
                "emit": False,
            })
            continue
        data = _flag_value(chunk, "d")
        writes.append({
            "path": ame,
            "value": vname,
            "type": reg_type,
            "data": "" if data is None else data,
            "emit": True,
        })

    fsutil = FSUTIL_LASTACCESS_RE.search(command)
    if fsutil:
        writes.append({
            "path": r"HKLM\SYSTEM\CurrentControlSet\Control\FileSystem",
            "value": "NtfsDisableLastAccessUpdate",
            "type": "REG_DWORD",
            "data": fsutil.group(1),
            "emit": True,
        })

    if command_writes_registry(command) and not writes:
        writes.append({
            "error": "a !cmd writes the registry but the write could not be parsed",
            "emit": False,
        })
    return writes


def unquote(v: str) -> str:
    v = v.strip().rstrip(",").strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        v = v[1:-1].replace("''", "'")
    return v


def parse_actions(text: str):
    """Yield (action_name, props_dict, option) for each bang action.

    Handles both inline `!x: {a: b}` and block form. Tracks the shared
    `option:` param so conditional actions are marked conditional.
    """
    actions = []
    current = None
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        m = re.match(r"^-\s*!(\w+):\s*(.*)$", stripped)
        if m:
            if current:
                actions.append(current)
            name, rest = m.group(1), m.group(2).strip()
            current = {"action": name, "props": {}}
            if rest.startswith("{") and rest.endswith("}"):
                inner = rest[1:-1]
                # split on commas outside quotes
                parts, buf, q = [], "", None
                for ch in inner:
                    if q:
                        buf += ch
                        if ch == q:
                            q = None
                    elif ch in "'\"":
                        q = ch
                        buf += ch
                    elif ch == ",":
                        parts.append(buf)
                        buf = ""
                    else:
                        buf += ch
                if buf.strip():
                    parts.append(buf)
                for p in parts:
                    kv = KV_RE.match(p.strip())
                    if kv:
                        current["props"][kv.group(1)] = unquote(kv.group(2))
                actions.append(current)
                current = None
        elif current is not None:
            kv = KV_RE.match(stripped)
            if kv and line.startswith(" "):
                current["props"][kv.group(1)] = unquote(kv.group(2))
            elif stripped and not stripped.startswith("#"):
                # left the block
                actions.append(current)
                current = None
    if current:
        actions.append(current)
    return actions


def main() -> int:
    if not TASKS_DIR.is_dir():
        print(f"ERROR: {TASKS_DIR} not found — run from repo root layout", file=sys.stderr)
        return 2

    manifest = {
        "schema": 1,
        "generatedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "registryValues": [],
        # Values Chamber removes - retired tweaks deleted so an in-place upgrade
        # cleans up after an earlier version. Verified absent, never restored.
        "registryDeletes": [],
        "services": [],
        "scheduledTasks": [],
        "bcd": {"flags": [], "timeout": None},
        "hostsEntries": [],
        "debloat": {"balanced": [], "xbox": []},
        "unparsedActions": [],
    }

    parse_errors = []

    for task_file in sorted(TASKS_DIR.glob("*.yml")):
        text = task_file.read_text(encoding="utf-8", errors="replace")
        source = task_file.name
        for act in parse_actions(text):
            name, p = act["action"], act["props"]
            option = p.get("option")
            if name == "registryValue" and p.get("operation", "").lower() == "delete":
                if not all(k in p for k in ("path", "value")):
                    manifest["unparsedActions"].append({"source": source, "action": name, "props": p})
                    continue
                manifest["registryDeletes"].append({"source": source, "path": p["path"], "value": p["value"]})
            elif name == "registryValue":
                if not all(k in p for k in ("path", "value", "type")):
                    manifest["unparsedActions"].append({"source": source, "action": name, "props": p})
                    continue
                entry = {
                    "source": source,
                    "path": p["path"],
                    "value": p["value"],
                    "type": p["type"],
                    "data": p.get("data", ""),
                }
                if option:
                    entry["option"] = option
                if p.get("scope"):
                    entry["scope"] = p["scope"]
                manifest["registryValues"].append(entry)
            elif name == "service" and p.get("operation") == "change" and "startup" in p:
                entry = {"source": source, "name": p["name"], "startup": int(p["startup"])}
                if option:
                    entry["option"] = option
                manifest["services"].append(entry)
            elif name == "cmd":
                cmd = p.get("command", "")
                for write in registry_writes_from_command(cmd):
                    if write.get("error"):
                        parse_errors.append(f"{source}: {write['error']}")
                        continue
                    if not write.get("emit", True):
                        continue
                    entry = {
                        "source": source,
                        "path": write["path"],
                        "value": write["value"],
                        "type": write["type"],
                        "data": write.get("data", ""),
                    }
                    if "whenRamAtLeastGb" in write:
                        entry["whenRamAtLeastGb"] = write["whenRamAtLeastGb"]
                    if option:
                        entry["option"] = option
                    manifest["registryValues"].append(entry)
                if "bcdedit" in cmd:
                    mb = BCD_RE.search(cmd)
                    mt = BCD_TIMEOUT_RE.search(cmd)
                    tolerant = "||" in cmd  # hardware-dependent, WARN not FAIL
                    if mb:
                        manifest["bcd"]["flags"].append(
                            {"source": source, "flag": mb.group(1), "expected": mb.group(2), "tolerant": tolerant}
                        )
                    elif mt:
                        manifest["bcd"]["timeout"] = int(mt.group(1))
            elif name == "scheduledTask" and p.get("operation", "").lower() in ("disable", "enable") and "path" in p:
                entry = {"source": source, "path": p["path"], "state": p["operation"].lower()}
                if option:
                    entry["option"] = option
                manifest["scheduledTasks"].append(entry)
            elif name in ("registryKey", "appx", "scheduledTask"):
                manifest["unparsedActions"].append({"source": source, "action": name, "props": p})

    # Hosts entries — parse from the executable that writes them
    if HOSTS_PS1.exists():
        manifest["hostsEntries"] = HOSTS_ENTRY_RE.findall(HOSTS_PS1.read_text(encoding="utf-8", errors="replace"))

    # Debloat targets — parse from the debloat script (single source of truth)
    if DEBLOAT_PS1.exists():
        txt = DEBLOAT_PS1.read_text(encoding="utf-8", errors="replace")
        xbox_start = txt.find("$XboxTargets")
        for m in APPX_NAMES_RE.finditer(txt):
            names = [unquote(x) for x in m.group(1).split(",") if unquote(x)]
            bucket = "xbox" if xbox_start != -1 and m.start() > xbox_start else "balanced"
            manifest["debloat"][bucket].extend(names)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {OUT.relative_to(REPO)}")
    print(
        f"  registry values: {len(manifest['registryValues'])} (+{len(manifest['registryDeletes'])} deletes) | "
        f"services: {len(manifest['services'])} | "
        f"scheduled tasks: {len(manifest['scheduledTasks'])} | "
        f"BCD flags: {len(manifest['bcd']['flags'])} | "
        f"hosts entries: {len(manifest['hostsEntries'])} | "
        f"debloat: {len(manifest['debloat']['balanced'])} balanced + {len(manifest['debloat']['xbox'])} xbox | "
        f"unparsed: {len(manifest['unparsedActions'])}"
    )
    if manifest["unparsedActions"]:
        print("  NOTE: unparsed actions are listed in the manifest for manual verification coverage.")
    if parse_errors:
        for err in parse_errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
