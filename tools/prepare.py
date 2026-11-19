#!/usr/bin/env python3
"""Apply the reviewed MoonGram patch to one pinned official Telegram revision."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, cwd=None, check=True):
    return subprocess.run(arguments, cwd=cwd, check=check, text=True, capture_output=True)


def prepare_unsigned_rules(source, lock):
    rules = source / "build-system/bazel-rules/rules_apple"
    if not (rules / ".git").exists():
        raise RuntimeError("rules_apple submodule has not been initialized.")
    revision = run(["git", "rev-parse", "HEAD"], rules).stdout.strip()
    if revision != lock["rules_apple_revision"]:
        raise RuntimeError("Unexpected rules_apple revision; refusing to patch it.")
    patch = ROOT / "patches/rules-apple-unsigned.patch"
    forward = run(["git", "apply", "--check", str(patch)], rules, check=False)
    if forward.returncode == 0:
        run(["git", "apply", str(patch)], rules)
    elif run(["git", "apply", "--reverse", "--check", str(patch)], rules, check=False).returncode != 0:
        raise RuntimeError("Unsigned rules patch conflicts with local changes; no reset performed.")
    run(["git", "diff", "--check"], rules)


def prepare(source: Path, dependencies: bool = False) -> None:
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--depth", "1", "--branch", lock["tag"], lock["repository"], str(source)])
    revision = run(["git", "rev-parse", "HEAD"], source).stdout.strip()
    if revision != lock["revision"]:
        raise RuntimeError("Wrong upstream revision; refusing to modify this checkout.")
    patch = ROOT / "patches/moongram.patch"
    forward = run(["git", "apply", "--check", str(patch)], source, check=False)
    reverse = run(["git", "apply", "--reverse", "--check", str(patch)], source, check=False)
    if forward.returncode != 0 and reverse.returncode != 0:
        raise RuntimeError("Patch conflicts with local changes. No reset or overwrite was performed.")
    targets = [
        (ROOT / "MoonGram/Core", source / "submodules/MoonGramCore"),
        (ROOT / "MoonGram/Engine/Sources", source / "submodules/TelegramCore/Sources/MoonGram"),
        (ROOT / "MoonGram/UI", source / "submodules/MoonGramUI"),
        (ROOT / "MoonGram/Vault", source / "submodules/MoonGramVault"),
        (ROOT / "MoonGram/Bridge", source / "submodules/MoonGramBridge"),
        (ROOT / "MoonGram/NativeGifts", source / "submodules/MoonGramNativeGifts"),
    ]
    targets.extend(
        (ROOT / "MoonGram/Brand" / icon, source / "Telegram/Telegram-iOS" / icon)
        for icon in (
            "MoonGram.icon", "MoonGramIconPreview",
            "MoonGramCyan.alticon", "MoonGramAmber.alticon",
            "MoonGramMono.alticon", "MoonGramViolet.alticon",
        )
    )
    for _, destination in targets:
        if destination.exists() and not (destination / ".moongram-managed").is_file():
            raise RuntimeError(f"Refusing to overwrite an unmanaged directory: {destination.name}")
    if forward.returncode == 0:
        run(["git", "apply", str(patch)], source)
    for origin, destination in targets:
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(origin, destination)
        (destination / ".moongram-managed").write_text("MoonGram overlay\n")
    if dependencies:
        run(["git", "submodule", "update", "--init", "--recursive", "--jobs", "4"], source)
        prepare_unsigned_rules(source, lock)
    run(["git", "diff", "--check"], source)
    print(f"MoonGram applied to Telegram {lock['tag']} ({revision[:12]}).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "upstream/Telegram-iOS")
    parser.add_argument("--dependencies", action="store_true", help="Fetch recursive upstream submodules.")
    args = parser.parse_args()
    try:
        prepare(args.source.resolve(), args.dependencies)
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print("Upstream command failed: " + error.stderr.strip(), file=sys.stderr)
        else:
            print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
