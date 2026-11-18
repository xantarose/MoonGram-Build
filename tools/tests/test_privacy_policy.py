import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PrivacyPolicyTests(unittest.TestCase):
    def test_actual_signal_policy_and_read_queue_retirement(self):
        signal_root = ROOT / 'upstream/Telegram-iOS/submodules/SSignalKit/SwiftSignalKit/Source'
        parts = [(signal_root / name).read_text() for name in
                 ['Atomic.swift', 'Disposable.swift', 'Subscriber.swift', 'Signal_Mapping.swift']]
        # The optional async Signal.get() extension depends on other operators unused here.
        parts.append((signal_root / 'Signal.swift').read_text().split('@available(iOS 13.0, macOS 10.15, *)', 1)[0])
        meta = (signal_root / 'Signal_Meta.swift').read_text()
        parts.append(meta[meta.index('public func ignoreValues<'):meta.index('public func mapToSignalPromotingError<')])
        parts.append((ROOT / 'MoonGram/Core/Sources/MoonPrivacySettings.swift').read_text())
        engine = (ROOT / 'MoonGram/Engine/Sources/MoonPrivacy.swift').read_text()
        engine = '\n'.join(line for line in engine.splitlines() if not line.startswith('import '))
        sync = (ROOT / 'upstream/Telegram-iOS/submodules/TelegramCore/Sources/State/SynchronizePeerReadState.swift').read_text()
        confirm = sync[sync.index('private func confirmSynchronized('):sync.index('/// Whether a local incoming read mark')]
        gate = sync[sync.index('func synchronizePeerReadState('):].split('    // A channel the account is not a member of', 1)[0]
        # The remainder is intentionally a no-op stand-in: only the production suppression branch is under test.
        gate += '    return .complete()\n}\n'
        probe = (ROOT / 'Checks/MoonPrivacyProbe.swift').read_text().replace('// PRODUCTION_CODE', engine + '\n' + confirm + '\n' + gate)
        source = '\n'.join(parts) + '\n' + probe
        compiler = shutil.which('swiftc') or str(ROOT / '.tools/swift/usr/bin/swiftc')
        with tempfile.TemporaryDirectory(prefix='moongram-privacy-') as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            main.write_text(source)
            result = subprocess.run([compiler, '-swift-version', '5', '-warnings-as-errors', '-module-cache-path',
                                     str(folder / 'cache'), str(main), '-o', str(folder / 'probe')],
                                    text=True, capture_output=True, timeout=90,
                                    env={**os.environ, 'CLANG_MODULE_CACHE_PATH': str(folder / 'cache')})
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(folder / 'probe')], text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('privacy signals and queue retirement passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
