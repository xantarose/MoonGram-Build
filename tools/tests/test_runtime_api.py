import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_configuration import template_configuration
from configure_ipa import configure_ipa, API_RESOURCE
from ipa_verification import verify_ipa
from test_build import executable

ROOT = Path(__file__).resolve().parents[2]


class RuntimeAPITests(unittest.TestCase):
    def template(self, path, unsafe=False):
        info = {'CFBundleIdentifier': 'app.moongram.ios.personal', 'CFBundleDisplayName': 'MoonGram',
                'CFBundleExecutable': 'Telegram', 'MoonGramStorageMode': 'standalone', 'MoonGramRuntimeAPIRequired': True}
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Telegram.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/Telegram.app/Telegram', executable())
            archive.writestr('Payload/Telegram.app/Assets.car', b'unchanged assets')
            if unsafe: archive.writestr('../outside', b'bad')

    def test_template_cli_ignores_credential_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'build.json'
            credentials = {'api_id': '12345', 'api_hash': '0123456789abcdef0123456789abcdef'}
            result = subprocess.run([sys.executable, str(ROOT / 'tools/build_configuration.py'), '--kind', 'standalone-device',
                                     '--template', '--output', str(path)], text=True, capture_output=True, check=True,
                                    env={**os.environ, 'MOONGRAM_TELEGRAM_API': json.dumps(credentials), 'MOONGRAM_BUILD_CONFIG': 'invalid'})
            self.assertEqual(json.loads(path.read_text()), template_configuration('standalone-device'))
            self.assertNotIn(credentials['api_hash'], result.stdout + result.stderr)
        with self.assertRaises(ValueError): template_configuration('device')

    def test_local_configuration_keeps_executable_and_assets_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); source = folder/'template.ipa'; output = folder/'configured.ipa'
            self.template(source)
            before = verify_ipa(source, 'app.moongram.ios.personal', 'standalone-device', allow_unconfigured=True)
            self.assertFalse(before['runtime_api_configured'])
            with self.assertRaises(ValueError): verify_ipa(source, 'app.moongram.ios.personal', 'standalone-device')
            credentials = {'api_id': '12345', 'api_hash': '0123456789abcdef0123456789abcdef'}
            report = configure_ipa(source, output, credentials)
            self.assertTrue(report['runtime_api_configured'])
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            with zipfile.ZipFile(source) as old, zipfile.ZipFile(output) as new:
                for name in old.namelist(): self.assertEqual(new.read(name), old.read(name))
                api = json.loads(new.read(API_RESOURCE))
                self.assertEqual(api, {'api_id': 12345, 'api_hash': credentials['api_hash']})
                self.assertNotIn(API_RESOURCE, old.namelist())
            self.assertNotIn(credentials['api_hash'], json.dumps(report))

    def test_invalid_input_never_replaces_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory); source=folder/'template.ipa'; output=folder/'configured.ipa'
            self.template(source); output.write_bytes(b'keep output')
            for credentials in [{'api_id': True, 'api_hash': '0'*32}, {'api_id': '1', 'api_hash': 'wrong'}]:
                with self.assertRaises(ValueError): configure_ipa(source, output, credentials)
                self.assertEqual(output.read_bytes(), b'keep output')
            self.template(source, unsafe=True)
            with self.assertRaises(ValueError): configure_ipa(source, output, {'api_id': '1', 'api_hash': '0'*32})
            self.assertEqual(output.read_bytes(), b'keep output')
            self.assertFalse(list(folder.glob('.moongram-ipa-*')))


if __name__ == '__main__': unittest.main()
