import ast
import contextlib
import io
import os
import plistlib
import re
import zipfile
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_configuration import from_api_credentials, validate_configuration, write_private
from ipa_verification import inspect_macho, verify_ipa
from package_source import source_files

ROOT = Path(__file__).resolve().parents[2]


def executable(platform=2, encrypted=False):
    commands = struct.pack("<IIIIII", 0x32, 24, platform, 0, 0, 0)
    if encrypted:
        commands += struct.pack("<IIIIII", 0x2C, 24, 0, 0, 1, 0)
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2 if encrypted else 1, len(commands), 0, 0) + commands


class BuildTests(unittest.TestCase):
    def test_source_package_contains_every_native_module_build_file(self):
        paths = {file["path"] for file in source_files()}
        for path in (ROOT / "MoonGram").rglob("BUILD"):
            self.assertIn(path.relative_to(ROOT).as_posix(), paths)
        self.assertFalse(any(path.startswith((".private/", "upstream/", "docs/")) for path in paths))

    def test_main_application_display_name_is_moongram_before_full_build(self):
        source = (ROOT / "upstream/Telegram-iOS/Telegram/BUILD").read_text()
        match = re.search(r'name = "TelegramInfoPlist"[\s\S]*?<key>CFBundleDisplayName</key>\s*<string>([^<]+)</string>', source)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "MoonGram")

    def test_personal_namespace_cannot_switch_storage_modes(self):
        personal = from_api_credentials(self.credentials(), "standalone-device")
        self.assertTrue(personal["bundle_id"].endswith(".personal"))
        with self.assertRaises(ValueError):
            validate_configuration(personal, "unsigned-device")
        regular = from_api_credentials(self.credentials(), "simulator")
        with self.assertRaises(ValueError):
            validate_configuration(regular, "standalone-simulator")

    def test_personal_ipa_requires_storage_marker_and_no_extensions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.ipa"
            bundle = "app.moongram.ios.personal"
            info = {"CFBundleIdentifier": bundle, "CFBundleDisplayName": "MoonGram", "CFBundleExecutable": "Telegram", "MoonGramStorageMode": "standalone"}
            def write(marker=True, extension=False):
                values = dict(info)
                if not marker: values.pop("MoonGramStorageMode")
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("Payload/Telegram.app/Info.plist", plistlib.dumps(values))
                    archive.writestr("Payload/Telegram.app/Telegram", executable())
                    if extension: archive.writestr("Payload/Telegram.app/PlugIns/Test.appex/Info.plist", b"test")
            write()
            self.assertEqual(verify_ipa(path, bundle, "standalone-device")["storage_mode"], "standalone")
            for marker, extension in ((False, False), (True, True)):
                write(marker, extension)
                with self.assertRaises(ValueError): verify_ipa(path, bundle, "standalone-device")

    def credentials(self):
        return {"api_id": "12345", "api_hash": "0123456789abcdef0123456789abcdef"}

    def test_unsigned_configuration_never_fabricates_signing_identity(self):
        config = from_api_credentials(self.credentials(), "unsigned-device")
        self.assertEqual(config["team_id"], "")
        with self.assertRaises(ValueError):
            validate_configuration(config, "device")

    def test_configuration_rejects_generated_code_injection_and_wrong_types(self):
        config = from_api_credentials(self.credentials(), "simulator")
        for field, value in (("app_specific_url_scheme", 'moon"\nload("bad")'), ("api_id", True),
                             ("api_id", "2147483648"), ("enable_siri", "False"), ("is_internal_build", "true\n"),
                             ("premium_iap_product_id", '"'), ("api_hash", "secret\nvalue")):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_configuration({**config, field: value}, "simulator")

    def test_private_configuration_permissions_and_symlink_boundary(self):
        config = from_api_credentials(self.credentials(), "simulator")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build.local.json"
            write_private(path, config)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            link = Path(directory) / "link.local.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                write_private(link, config)

    def test_macho_distinguishes_device_and_simulator(self):
        self.assertEqual(inspect_macho(executable(2))["platform"], 2)
        self.assertEqual(inspect_macho(executable(7))["platform"], 7)

    def test_macho_rejects_encryption_and_truncated_or_invalid_commands(self):
        for data in (executable(encrypted=True), executable()[:-1], executable()[:32], b"not a Mach-O"):
            with self.assertRaises(ValueError):
                inspect_macho(data)

    def test_make_forwards_quoted_bazel_flags_to_actual_build_invocation(self):
        # Run the real pinned command builder with external build/SDK operations stubbed.
        path = ROOT / "upstream/Telegram-iOS/build-system/Make/Make.py"
        module = ast.parse(path.read_text())
        nodes = [node for node in module.body if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in ("BazelCommandLine", "build")]
        calls = []
        class Arguments(SimpleNamespace):
            def __getattr__(self, key):
                return None
        namespace = {"os": SimpleNamespace(getcwd=lambda: "/source", cpu_count=lambda: 4,
                        path=SimpleNamespace(exists=lambda path: False)), "sys": sys, "shlex": shlex, "subprocess": subprocess,
                     "BuildEnvironment": lambda **kwargs: SimpleNamespace(bazel_path="bazel"),
                     "PostboxImportCheck": SimpleNamespace(run=lambda path: 0), "resolve_configuration": lambda **kwargs: None,
                     "call_executable": lambda arguments: calls.append(arguments)}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
        arguments = Arguments(configuration="debug_sim_arm64", buildNumber=1,
                              bazelArguments="--//Telegram:disableProvisioningProfiles --define=label='two words'")
        with contextlib.redirect_stdout(io.StringIO()):
            namespace["build"]("bazel", arguments)
        self.assertEqual(len(calls), 1)
        self.assertIn("Telegram/Telegram", calls[0])
        self.assertIn("--//Telegram:disableProvisioningProfiles", calls[0])
        self.assertIn("--define=label=two words", calls[0])


if __name__ == "__main__":
    unittest.main()
