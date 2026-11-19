#!/usr/bin/env python3
"""Create an explicit source-only upload set; never walk the entire workspace."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = ("MoonGram", "Tests", "Checks", "config", "patches", "service/src", "service/test", "tools", ".github")
FILES = ("README.md", "LICENSE", ".gitignore", "Package.swift", "upstream.lock.json", "service/package.json", "service/admin.mjs")
SUFFIXES = {".swift", ".py", ".mjs", ".json", ".md", ".svg", ".patch", ".yml", ".yaml"}
SECRET = re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{40,}|[0-9]{7,}:[A-Za-z0-9_-]{30,}")


def is_brand_png(file):
    return file.suffix == ".png" and file.is_relative_to(ROOT / "MoonGram/Brand")


def source_bytes(file):
    return base64.b64decode(file["content"], validate=True) if file.get("encoding") == "base64" else file["content"].encode()


def source_files():
    paths = [ROOT / name for name in FILES]
    for name in DIRECTORIES:
        paths.extend(file for file in (ROOT / name).rglob("*") if file.is_file() and (file.suffix in SUFFIXES or file.name == "BUILD" or is_brand_png(file)) and "__pycache__" not in file.parts)
    result = []
    for file in sorted(set(paths)):
        relative = file.relative_to(ROOT).as_posix()
        if file.is_symlink() or not file.is_file():
            raise RuntimeError(f"Missing or symbolic source file: {relative}")
        if ".local." in file.name or file.name.startswith(".env") or file.stat().st_size > 2_000_000:
            raise RuntimeError(f"Excluded private or oversized source: {relative}")
        data = file.read_bytes()
        if is_brand_png(file):
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise RuntimeError(f"Invalid PNG: {relative}")
            record = {"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"}
        else:
            content = data.decode()
            if SECRET.search(content):
                raise RuntimeError(f"Potential credential in {relative}; upload refused without printing its value.")
            record = {"content": content}
        result.append({"path": relative, **record, "sha256": hashlib.sha256(data).hexdigest()})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit the upload set for the GitHub connector.")
    args = parser.parse_args()
    try:
        files = source_files()
        if args.json:
            print(json.dumps(files, ensure_ascii=False))
            return
        output = ROOT / "dist"
        output.mkdir(exist_ok=True)
        with zipfile.ZipFile(output / "MoonGram-source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for file in files: archive.writestr("MoonGram/" + file["path"], source_bytes(file))
        (output / "source-manifest.json").write_text(json.dumps([{k: v for k, v in file.items() if k != "content"} for file in files], indent=2))
        print(f"Source-only package: {len(files)} files, {sum(len(source_bytes(x)) for x in files)} bytes. No working tree, toolchain, build cache or local configuration included.")
    except (OSError, UnicodeError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
