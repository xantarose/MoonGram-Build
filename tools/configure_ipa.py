#!/usr/bin/env python3
"""Add a local Telegram API pair to an unsigned MoonGram template before ESign signing."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile
import zipfile

from build_configuration import from_api_credentials
from ipa_verification import verify_ipa

API_RESOURCE = 'Payload/Telegram.app/MoonGramAPI.json'


def encode_api(credentials):
    checked = from_api_credentials(credentials, 'standalone-device')
    return json.dumps({'api_id': int(checked['api_id']), 'api_hash': checked['api_hash']}, separators=(',', ':')).encode()


def configure_ipa(source, output, credentials, kind='standalone-device'):
    if kind not in ('standalone-device', 'standalone-simulator'):
        raise ValueError('Runtime API configuration is supported only by personal builds.')
    source, output = Path(source), Path(output)
    if source.is_symlink() or output.is_symlink():
        raise ValueError('Refusing a symbolic IPA path.')
    bundle = 'app.moongram.ios.personal'
    before = verify_ipa(source, bundle, kind, allow_unconfigured=True)
    if not before.get('runtime_api_required'):
        raise ValueError('This IPA does not support local runtime API configuration.')
    data = encode_api(credentials)
    temporary = None
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.moongram-ipa-', delete=False) as stream:
            temporary = Path(stream.name)
        os.chmod(temporary, 0o600)
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(temporary, 'w', allowZip64=True) as modified:
            entries = original.infolist()
            names = [entry.filename for entry in entries]
            if len(names) > 100_000 or len(set(names)) != len(names) or sum(x.file_size for x in entries) > 4_294_967_296:
                raise ValueError('Duplicate or oversized IPA archive.')
            for entry in entries:
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1:
                    raise ValueError('Unsafe IPA archive entry.')
                if entry.filename == API_RESOURCE:
                    continue
                with original.open(entry) as reader, modified.open(entry, 'w') as writer:
                    while chunk := reader.read(1_048_576):
                        writer.write(chunk)
            resource = zipfile.ZipInfo(API_RESOURCE)
            resource.compress_type = zipfile.ZIP_DEFLATED
            resource.external_attr = (stat.S_IFREG | 0o600) << 16
            modified.writestr(resource, data)
        report = verify_ipa(temporary, bundle, kind)
        os.replace(temporary, output)
        return report
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--api', type=Path, required=True, help='Private API JSON file; never put credentials on the command line.')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--simulator', action='store_true')
    args = parser.parse_args()
    try:
        report = configure_ipa(args.template, args.output, json.loads(args.api.read_text()),
                               'standalone-simulator' if args.simulator else 'standalone-device')
    except (OSError, ValueError, zipfile.BadZipFile, KeyError):
        raise SystemExit('IPA configuration failed; credential values are omitted and the output was not replaced.')
    args.output.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Configured and verified the personal IPA locally. Sign it with ESign before installation. Keep this configured IPA private.')


if __name__ == '__main__':
    main()
