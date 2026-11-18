import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PasscodePolicyTests(unittest.TestCase):
    def test_actual_storage_policy_preserves_group_mode_and_isolates_personal_mode(self):
        # Compile the actual Foundation-only configuration/environment definitions.
        # This verifies identity routing, validation and locking, not OS keychain/crypto behavior.
        source = (ROOT / "upstream/Telegram-iOS/submodules/PasscodeCore/Sources/Passcode.swift").read_text()
        source = source[source.index("public struct PasscodeConfiguration"):source.index("\nprotocol PasscodeStorage")]
        probe = (ROOT / "Checks/PasscodePolicyProbe.swift").read_text()
        compiler = shutil.which("swiftc") or str(ROOT / ".tools/swift/usr/bin/swiftc")
        with tempfile.TemporaryDirectory(prefix="moongram-policy-") as directory:
            folder = Path(directory)
            main = folder / "main.swift"
            main.write_text("import Foundation\nenum PasscodeError: Error { case unavailable }\n" + source + "\n" + probe)
            env = {**os.environ, "CLANG_MODULE_CACHE_PATH": str(folder / "cache")}
            compiled = subprocess.run([compiler, "-swift-version", "5", "-warnings-as-errors", "-module-cache-path", str(folder / "cache"),
                            str(main), "-o", str(folder / "probe")], check=False, capture_output=True, text=True, env=env, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            # A recursive NSLock deadlock must fail promptly rather than stall the whole CI job.
            result = subprocess.run([str(folder / "probe")], check=True, capture_output=True, text=True, timeout=5)
            self.assertIn("storage scope policy passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
