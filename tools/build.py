#!/usr/bin/env python3
"""Build a MoonGram IPA on a configured Mac; never pretends Linux can run Xcode."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import zipfile

from prepare import ROOT, prepare
from build_configuration import KINDS, validate_configuration, template_configuration
from ipa_verification import verify_ipa


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--codesigning", type=Path, help="Directory with certs/ and profiles/, required for a device.")
    parser.add_argument("--kind", choices=KINDS, default="simulator")
    parser.add_argument("--build-number", type=int, default=1)
    parser.add_argument("--source", type=Path, default=ROOT / "upstream/Telegram-iOS")
    parser.add_argument("--template", action="store_true", help="Produce a public template with placeholder API values only.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        print("IPA build requires a macOS host with Xcode. Linux can run the core/service tests and prepare the patch.", file=sys.stderr)
        return 2
    try:
        config = validate_configuration(json.loads(args.configuration.resolve().read_text()), args.kind)
        if args.template and config != template_configuration(args.kind):
            raise ValueError("Public templates must use the documented placeholder configuration.")
        if args.build_number <= 0:
            raise ValueError("Build number must be positive.")
        expected = "27.1"
        xcode = subprocess.run(["xcodebuild", "-version"], text=True, capture_output=True, check=True).stdout
        if not xcode.startswith(f"Xcode {expected}\n"):
            raise ValueError(f"This pinned Telegram source requires Xcode {expected}; select that version first.")
        source = args.source.resolve()
        prepare(source, dependencies=True)
        command = [sys.executable, "build-system/Make/Make.py"]
        # A disposable CI runner cannot reuse this disk cache; avoid storing outputs twice.
        if os.environ.get("GITHUB_ACTIONS") != "true":
            command += ["--cacheDir=" + str(ROOT / ".build/bazel")]
        if args.kind != "device":
            flags = ["--//Telegram:disableProvisioningProfiles", "--jobs=2"]
            configuration = "debug_sim_arm64" if args.kind.endswith("simulator") else "release_arm64"
            if not args.kind.endswith("simulator"):
                flags += ["--features=disable_legacy_signing", "--features=moongram_unsigned_ipa"]
            if args.kind.startswith("standalone-"):
                flags += ["--//Telegram:moongramStandalone"]
            if args.template and args.kind == "standalone-device":
                flags += ["--//Telegram:moongramRuntimeAPI"]
            command += ["--bazelArguments=" + " ".join(flags), "build", "--continueOnError", "--xcodeManagedCodesigning", "--configuration=" + configuration]
        else:
            if args.codesigning is None or not (args.codesigning.resolve() / "profiles").is_dir():
                raise ValueError("Device build needs matching provisioning profiles and an installed signing identity.")
            command += ["build", "--continueOnError", "--configuration=release_arm64", "--codesigningInformationPath=" + str(args.codesigning.resolve())]
        command += ["--configurationPath=" + str(args.configuration.resolve()), "--buildNumber=" + str(args.build_number)]
        subprocess.run(command, cwd=source, check=True)
        ipa = source / "bazel-bin/Telegram/Telegram.ipa"
        report = verify_ipa(ipa, config["bundle_id"], args.kind, allow_unconfigured=args.template)
        report["source_commit"] = os.environ.get("GITHUB_SHA")
        report["build_number"] = args.build_number
        if args.kind.startswith("standalone-"):
            import plistlib
            entitlements = plistlib.loads((source / "bazel-bin/Telegram/TelegramEntitlements.entitlements").read_bytes())
            if "com.apple.security.application-groups" in entitlements:
                raise RuntimeError("Personal build unexpectedly requests an App Group.")
        names = {"device": "MoonGram.ipa", "simulator": "MoonGram-simulator.ipa", "unsigned-device": "MoonGram-unsigned.ipa", "standalone-device": "MoonGram-personal.ipa", "standalone-simulator": "MoonGram-personal-simulator.ipa"}
        filename = names[args.kind]
        if args.template: filename = filename.replace("MoonGram-", "MoonGram-template-", 1)
        output = ROOT / "dist" / filename
        output.parent.mkdir(exist_ok=True)
        shutil.copyfile(ipa, output)
        output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Built and identified: {output}")
        if args.kind.endswith("simulator"):
            print("Simulator artifact: cannot be installed on an iPhone.")
        elif args.kind == "standalone-device":
            print("Personal ARM64 artifact: requires valid signing; uses app-only storage and has no system extensions.")
        elif args.kind == "unsigned-device":
            print("Unsigned ARM64 artifact: requires compatible signing and entitlements before installation. App Groups remain required.")
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print("Build command failed. Review the build log; no release was produced.", file=sys.stderr)
        else:
            print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
