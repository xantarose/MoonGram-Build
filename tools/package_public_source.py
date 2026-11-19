#!/usr/bin/env python3
"""Prepare a source-only public mirror; exclude the private credential-based build workflow."""
import argparse
import json
from pathlib import Path
import zipfile

from package_source import ROOT, source_bytes, source_files


def public_files():
    return [file for file in source_files() if file['path'] != '.github/workflows/build.yml']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    files = public_files()
    if args.json:
        print(json.dumps(files, ensure_ascii=False))
        return
    output = ROOT / 'dist'
    output.mkdir(exist_ok=True)
    with zipfile.ZipFile(output / 'MoonGram-public-source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in files: archive.writestr('MoonGram/' + file['path'], source_bytes(file))
    (output / 'public-source-manifest.json').write_text(json.dumps([{k:v for k,v in file.items() if k != 'content'} for file in files], indent=2))
    print(f'Prepared {len(files)} public source files. No Git history, private workflow, credentials, sessions, phone certificates or configured IPA included.')


if __name__ == '__main__': main()
