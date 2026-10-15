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
            elif name == "cmd" and (mf := FSUTIL_LASTACCESS_RE.search(p.get("command", ""))):
                # fsutil behavior set disablelastaccess N writes this value
                manifest["registryValues"].append(
                    {
                        "source": source,
                        "path": r"HKLM\SYSTEM\CurrentControlSet\Control\FileSystem",
                        "value": "NtfsDisableLastAccessUpdate",
                        "type": "REG_DWORD",
                        "data": mf.group(1),
                    }
                )
            elif name == "cmd" and "bcdedit" in p.get("command", ""):
                cmd = p["command"]
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
