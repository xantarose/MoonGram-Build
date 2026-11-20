import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SUBMODULES = ROOT / 'upstream/Telegram-iOS/submodules'


class NativeEntrypointTests(unittest.TestCase):
    def swift_probe(self, source, execute=False):
        compiler = shutil.which('swiftc') or str(ROOT / '.tools/swift/usr/bin/swiftc')
        with tempfile.TemporaryDirectory(prefix='moongram-entrypoints-') as tmp:
            folder = Path(tmp)
            path = folder / 'main.swift'
            path.write_text(source)
            args = ['-o', str(folder / 'probe')] if execute else ['-typecheck']
            result = subprocess.run([compiler, '-swift-version', '5', '-warnings-as-errors', *args,
                                     '-module-cache-path', str(folder / 'cache'), str(path)],
                                    capture_output=True, text=True, timeout=90,
                                    env={**os.environ, 'CLANG_MODULE_CACHE_PATH': str(folder / 'cache')})
            self.assertEqual(result.returncode, 0, result.stderr)
            if execute:
                subprocess.run([str(folder / 'probe')], check=True, timeout=5)

    def test_actual_settings_entry_uses_the_owning_controller_and_main_actor(self):
        base = SUBMODULES / 'TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources'
        settings = (base / 'PeerInfoScreenSettingsActions.swift').read_text()
        entry = settings.split('case .moonGram:', 1)[1].split('case .avatar:', 1)[0]
        self.swift_probe('''
import Foundation
struct RawID { func _internalGetInt64Value() -> Int64 { 1 } }
struct PeerID { let id = RawID() }
struct Account { let peerId = PeerID() }
struct Context { let account = Account() }
struct Theme { let overallDarkAppearance = false }
struct DataSource { let theme = Theme() }
@MainActor final class MoonTelegramGiftProvider { init(context: Context) {} }
struct MoonTransportControls {}
@MainActor func moonTransportControls(context: Context, openProxySettings: @escaping @MainActor () -> Void) -> MoonTransportControls { MoonTransportControls() }
struct ProxyScreen {}
func proxySettingsController(context: Context) -> ProxyScreen { ProxyScreen() }
class Controller { func push(_ screen: ProxyScreen) {} }
@MainActor enum MoonGramScreen {
    static func open(from: Controller, accountID: Int64, nativeGifts: MoonTelegramGiftProvider, transport: MoonTransportControls, dark: Bool) {}
}
class Settings {
    let context = Context()
    let presentationData = DataSource()
    var controller: Controller?
    func entry() {
''' + entry + '\n    }\n}\n')

    def test_builtin_proxy_preserves_and_roundtrips_the_native_server_list(self):
        model = (SUBMODULES / 'TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift').read_text().replace('import Postbox', '')
        key = (SUBMODULES / 'TelegramCore/Sources/TelegramEngine/Utils/StringCodingKey.swift').read_text()
        policy = (SUBMODULES / 'TelegramCore/Sources/Settings/ProxySettings.swift').read_text()
        policy = policy[policy.index('public extension ProxyServerSettings {'):policy.index('\nextension ProxyServerSettings {')]
        self.swift_probe(key + '\n' + model + '\n' + policy + '''
let remote = ProxyServerSettings(host: "example.org", port: 1080, connection: .socks5(username: nil, password: nil))
let previous = ProxySettings(enabled: true, servers: [remote], activeServer: remote, useForCalls: true)
let enabled = previous.withMoonTelegramWebSocket(true).withMoonTelegramWebSocket(true)
precondition(enabled.servers == [.moonTelegramWebSocket, remote] && enabled.effectiveActiveServer == .moonTelegramWebSocket)
precondition(enabled.useForCalls && previous.withMoonTelegramWebSocket(false) == previous)
let restored = try JSONDecoder().decode(ProxySettings.self, from: JSONEncoder().encode(enabled))
precondition(restored == enabled && restored.activeServer?.isMoonTelegramWebSocket == true)
let off = restored.withMoonTelegramWebSocket(false)
precondition(off.effectiveActiveServer == nil && off.servers == enabled.servers)
''', execute=True)

    @unittest.skipUnless(shutil.which('xcrun'), 'requires an Apple SDK')
    def test_ios_websocket_compiles_against_the_actual_socket_protocol(self):
        header = (SUBMODULES / 'MtProtoKit/PublicHeaders/MtProtoKit/MTContext.h').read_text()
        protocols = header[header.index('@protocol MTTcpConnectionInterfaceDelegate'):header.index('@protocol MTContextChangeListener')]
        with tempfile.TemporaryDirectory() as tmp:
            include = Path(tmp) / 'MtProtoKit'
            include.mkdir()
            (include / 'MTContext.h').write_text('#import <Foundation/Foundation.h>\n@class MTNetworkUsageCalculationInfo;\n' + protocols)
            subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios15.0-simulator', '-fobjc-arc', '-fmodules', '-Werror', '-fsyntax-only', '-I', tmp,
                            str(ROOT / 'MoonGram/Transport/Sources/MTTelegramWebSocket.m')], check=True)


if __name__ == '__main__':
    unittest.main()
