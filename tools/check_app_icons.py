#!/usr/bin/env python3
"""Check MoonGram icons before Xcode compilation and in the packaged app."""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import zipfile

from prepare import ROOT

BRAND = ROOT / "MoonGram/Brand"
PRIMARY = "MoonGram"
PREVIEW = "MoonGramRaspberry"
PALETTES = {"MoonGramCyan", "MoonGramAmber", "MoonGramMono", "MoonGramViolet"}
TELEGRAM = {"BlackClassicIcon", "BlackFilledIcon", "BlackIcon", "BlueClassicIcon",
            "BlueFilledIcon", "BlueIcon", "New1", "New2", "Premium", "PremiumBlack",
            "PremiumTurbo", "WhiteFilledIcon"}
FAMILIES = ("CFBundleIcons", "CFBundleIcons~ipad")
BUNDLE = "Payload/Telegram.app/"


def check_png(data, size):
    signature = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
    if not data.startswith(signature) or struct.unpack_from(">IIBB", data, 16) != (size, size, 8, 2):
        raise ValueError(f"Expected an opaque {size}×{size} RGB PNG.")


def check_sources():
    icon = BRAND / f"{PRIMARY}.icon"
    layer = json.loads((icon / "icon.json").read_text())["groups"][0]["layers"][0]
    check_png((icon / "Assets" / layer["image-name"]).read_bytes(), 1024)
    for scale, size in ((2, 120), (3, 180)):
        check_png((BRAND / f"MoonGramIconPreview/{PREVIEW}@{scale}x.png").read_bytes(), size)
    for palette in PALETTES:
        for suffix, size in (("@2x", 120), ("@3x", 180), ("Pad", 76), ("Pad@2x", 152), ("PadLarge@2x", 167)):
            check_png((BRAND / f"{palette}.alticon/{palette}{suffix}.png").read_bytes(), size)


def check_primary(info):
    for family in FAMILIES:
        if info[family]["CFBundlePrimaryIcon"].get("CFBundleIconName") != PRIMARY:
            raise ValueError(f"Primary MoonGram icon not registered for {family}.")


def check_actool():
    with tempfile.TemporaryDirectory(prefix="moongram-icon-") as directory:
        compiled = Path(directory)
        partial = compiled / "icons.plist"
        subprocess.run(["xcrun", "actool", "--compile", str(compiled), "--errors", "--warnings",
                        "--platform", "iphoneos", "--minimum-deployment-target", "15.0",
                        "--target-device", "iphone", "--target-device", "ipad", "--app-icon", PRIMARY,
                        "--output-partial-info-plist", str(partial), str(BRAND / f"{PRIMARY}.icon")],
                       check=True)
        check_primary(plistlib.loads(partial.read_bytes()))


def check_ipa(ipa):
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read(BUNDLE + "Info.plist"))
        check_primary(info)
        expected_files = {PREVIEW}
        for family in FAMILIES:
            icons = info[family]["CFBundleAlternateIcons"]
            if not (PALETTES | TELEGRAM) <= icons.keys():
                raise ValueError(f"Registered icons missing from {family}.")
            for palette in PALETTES:
                if palette not in icons[palette]["CFBundleIconFiles"]:
                    raise ValueError(f"Missing asset registration for {palette}.")
                expected_files.add(palette)
        for asset in expected_files:
            for scale in (2, 3):
                archive.getinfo(f"{BUNDLE}{asset}@{scale}x.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile", action="store_true", help="Run Xcode actool for the primary icon.")
    parser.add_argument("--ipa", type=Path, help="Inspect the final IPA icon registrations and resources.")
    args = parser.parse_args()
    check_sources()
    if args.compile:
        check_actool()
    if args.ipa:
        check_ipa(args.ipa)
    print("MoonGram icon assets passed verification.")


if __name__ == "__main__":
    main()
