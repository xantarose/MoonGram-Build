import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeEntrypointTests(unittest.TestCase):
    def test_actual_gift_entrypoints_hop_to_the_main_actor(self):
        base = ROOT / 'upstream/Telegram-iOS/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources'
        profile = (base / 'PeerInfoProfileItems.swift').read_text()
        profile = profile.split('id: "moonCollection"', 1)[1].split('action: {', 1)[1].split('\n                    }))', 1)[0]
        settings = (base / 'PeerInfoScreenSettingsActions.swift').read_text()
        settings = settings.split('case .moonGram:', 1)[1].split('case .avatar:', 1)[0]
        # Compile the actual patched callbacks against the native provider's isolation contract.
        # Other Telegram UI types are small stand-ins; this is not a full SDK typecheck.
        stubs = '''
import Foundation
struct RawID { func _internalGetInt64Value() -> Int64 { 1 } }
struct PeerID { let id = RawID() }
struct Account { let peerId = PeerID() }
struct Context { let account = Account() }
struct User { let id = PeerID() }
@MainActor final class MoonTelegramGiftProvider { init(context: Context) {} }
struct MoonTransportControls {}
@MainActor func moonTransportControls(context: Context, openProxySettings: @escaping @MainActor () -> Void) -> MoonTransportControls { MoonTransportControls() }
struct ProxyScreen {}
func proxySettingsController(context: Context) -> ProxyScreen { ProxyScreen() }
struct MoonGramScreen {
    init(accountID: Int64, peerID: Int64? = nil, nativeGifts: MoonTelegramGiftProvider, transport: MoonTransportControls? = nil, pushed: Bool = false) {}
}
enum Root { case root }
enum Surface { case window(Root) }
class Controller {
    func present(_ screen: MoonGramScreen, in: Surface) {}
    func push(_ screen: MoonGramScreen) {}
    func push(_ screen: ProxyScreen) {}
}
struct Interaction { func getController() -> Controller? { nil } }
func profileEntry(context: Context, accountID: Int64, peerID: Int64, interaction: Interaction) {
'''
        source = stubs + profile + '''
}
class Settings {
    let context = Context()
    var controller: Controller?
    func entry() {
''' + settings + '\n    }\n}\n'
        compiler = shutil.which('swiftc') or str(ROOT / '.tools/swift/usr/bin/swiftc')
        with tempfile.TemporaryDirectory(prefix='moongram-entrypoints-') as directory:
            folder = Path(directory)
            path = folder / 'entrypoints.swift'
            path.write_text(source)
            result = subprocess.run([compiler, '-swift-version', '5', '-warnings-as-errors', '-typecheck',
                                     '-module-cache-path', str(folder / 'cache'), str(path)],
                                    capture_output=True, text=True, timeout=90,
                                    env={**os.environ, 'CLANG_MODULE_CACHE_PATH': str(folder / 'cache')})
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
