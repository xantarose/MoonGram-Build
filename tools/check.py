#!/usr/bin/env python3
"""Checks available without Apple's SDK. This is not an iOS typecheck or visual QA."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    swiftc = shutil.which("swiftc")
    local = ROOT / ".tools/swift/usr/bin/swiftc"
    if swiftc is None and local.exists():
        swiftc = str(local)
    if swiftc is None:
        raise SystemExit("Install Swift to run syntax checks.")
    files = sorted((ROOT / "MoonGram").rglob("*.swift"))
    source = ROOT / "upstream/Telegram-iOS"
    if source.exists():
        changed = subprocess.run(["git", "diff", "--name-only", "--", "*.swift"], cwd=source,
                                 text=True, capture_output=True, check=True).stdout.splitlines()
        files += [source / path for path in changed]
        subprocess.run(["git", "diff", "--check"], cwd=source, check=True)
        subprocess.run(["git", "apply", "--reverse", "--check", str(ROOT / "patches/moongram.patch")], cwd=source, check=True)
    subprocess.run([swiftc, "-frontend", "-parse", *map(str, files)], check=True)
    for path in (ROOT / "MoonGram/Brand").rglob("*.svg"):
        ET.parse(path)
    for path in [ROOT / "upstream.lock.json", ROOT / "config/build.example.json", ROOT / "service/package.json"]:
        json.loads(path.read_text())
    for path in (ROOT / "service").rglob("*.mjs"):
        subprocess.run(["node", "--check", str(path)], check=True)
    for path in (ROOT / "tools").glob("*.py"):
        compile(path.read_text(), str(path), "exec")
    print(f"Parsed {len(files)} Swift files; integration patch, SVG, JSON, Python and JavaScript checks passed.")
    print("UIKit/SwiftUI typechecking, a full Telegram build and device/visual checks still require Xcode.")


if __name__ == "__main__":
    main()
