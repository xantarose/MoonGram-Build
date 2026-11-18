#!/usr/bin/env python3
"""Import an explicitly supplied signing identity into a temporary CI-only Mac keychain."""
import base64
import io
import json
import os
from pathlib import Path
import platform
import secrets
import shlex
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".build/ci-signing-state.json"
DIRECTORY = ROOT / ".build/ci-signing"


def security(*arguments):
    process = subprocess.run(["security", *arguments], text=True, capture_output=True)
    if process.returncode:
        raise RuntimeError("A macOS keychain command failed. Signing credentials were not printed.")
    return process.stdout


def cleanup():
    if STATE.exists():
        state = json.loads(STATE.read_text())
        security("list-keychains", "-d", "user", "-s", *state["previous"])
        security("delete-keychain", state["keychain"])
        STATE.unlink(missing_ok=True)
    shutil.rmtree(DIRECTORY, ignore_errors=True)


def setup():
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Signing setup is restricted to an ephemeral macOS GitHub Actions job.")
    if STATE.exists():
        raise RuntimeError("A signing state already exists; refusing to replace it.")
    p12_text = os.environ.get("MOONGRAM_CERTIFICATE_P12_BASE64", "")
    profiles_text = os.environ.get("MOONGRAM_PROFILES_ZIP_BASE64", "")
    password = os.environ.get("MOONGRAM_CERTIFICATE_PASSWORD", "")
    if not p12_text or not profiles_text:
        raise RuntimeError("Device build needs the P12 and provisioning profiles repository secrets.")
    if len(p12_text) > 1_000_000 or len(profiles_text) > 32_000_000:
        raise RuntimeError("Signing input exceeds its size limit.")
    p12 = base64.b64decode(p12_text, validate=True)
    zip_data = base64.b64decode(profiles_text, validate=True)
    profiles = []
    with zipfile.ZipFile(io.BytesIO(zip_data)) as archive:
        entries = [item for item in archive.infolist() if not item.is_dir()]
        if not 1 <= len(entries) <= 32 or sum(item.file_size for item in entries) > 16_000_000:
            raise RuntimeError("Invalid provisioning profiles collection size.")
        if len({item.filename for item in entries}) != len(entries):
            raise RuntimeError("Duplicate provisioning profile names.")
        for item in entries:
            path = Path(item.filename)
            if path.name != item.filename or path.suffix != ".mobileprovision" or item.file_size > 2_000_000:
                raise RuntimeError("Profiles ZIP must contain only flat .mobileprovision files.")
            with archive.open(item) as stream:
                data = stream.read(2_000_001)
            if len(data) > 2_000_000:
                raise RuntimeError("Provisioning profile exceeds its size limit.")
            profiles.append((path.name, data))
        if not 1 <= len(profiles) <= 32 or len({name for name, _ in profiles}) != len(profiles):
            raise RuntimeError("Invalid provisioning profiles collection.")
    (DIRECTORY / "certs").mkdir(parents=True, mode=0o700)
    (DIRECTORY / "profiles").mkdir(mode=0o700)
    certificate = DIRECTORY / "certs/signing.p12"
    certificate.touch(mode=0o600)
    certificate.write_bytes(p12)
    for name, data in profiles:
        file = DIRECTORY / "profiles" / name
        file.touch(mode=0o600)
        file.write_bytes(data)
    previous = shlex.split(security("list-keychains", "-d", "user"))
    keychain = str(Path(os.environ["RUNNER_TEMP"]) / ("moongram-" + secrets.token_hex(8) + ".keychain-db"))
    keychain_password = secrets.token_urlsafe(32)
    security("create-keychain", "-p", keychain_password, keychain)
    STATE.parent.mkdir(exist_ok=True)
    STATE.write_text(json.dumps({"keychain": keychain, "previous": previous}))
    try:
        security("unlock-keychain", "-p", keychain_password, keychain)
        security("set-keychain-settings", "-lut", "10800", keychain)
        security("list-keychains", "-d", "user", "-s", keychain, *previous)
        security("import", str(certificate), "-k", keychain, "-P", password, "-T", "/usr/bin/codesign")
        security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, keychain)
    except Exception:
        cleanup()
        raise
    print("Temporary MoonGram signing identity imported. Certificate and password were not printed.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--cleanup"]:
            cleanup()
        elif not sys.argv[1:]:
            setup()
        else:
            raise RuntimeError("Usage: ci_signing.py [--cleanup]")
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "Signing setup failed; private input was not printed.", file=sys.stderr)
        sys.exit(1)
