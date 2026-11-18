// Telegram's real Signal, Subscriber, Disposable, Atomic and mapping implementations are
// prepended by the test runner. Only Postbox/network/store collaborators are stand-ins.
struct RawID {
    let value: Int64
    func _internalGetInt64Value() -> Int64 { self.value }
}
enum EnginePeer {
    struct Id {
        let id: RawID
        let namespace: Int32
        init(_ value: Int64, namespace: Int32 = 0) { self.id = RawID(value: value); self.namespace = namespace }
    }
}
typealias PeerId = EnginePeer.Id
enum Namespaces { enum Peer {
    static let CloudUser: Int32 = 0
    static let CloudGroup: Int32 = 1
    static let CloudChannel: Int32 = 2
    static let SecretChat: Int32 = 3
} }
struct MoonSettings { var privacy: MoonPrivacySettings? }
enum LoadFailure: Error { case corrupt }
final class MoonStore {
    static let shared = MoonStore()
    var entries: [Int64: MoonSettings] = [:]
    var fails = false
    func settings(accountID: Int64) throws -> MoonSettings {
        if self.fails { throw LoadFailure.corrupt }
        return self.entries[accountID] ?? MoonSettings()
    }
    func set(_ value: MoonPrivacySettings, accountID: Int64) {
        self.entries[accountID] = MoonSettings(privacy: value)
        NotificationCenter.default.post(name: .moonGramSettingsDidChange, object: nil, userInfo: ["accountID": accountID])
    }
}
extension Notification.Name {
    static let moonGramSettingsDidChange = Notification.Name("MoonGram.settingsDidChange")
}
enum MTRpcError { case test }
final class Network {}
struct AccountStateManager { let accountPeerId: PeerId }
enum PeerReadStateValidationError { case retry }
final class Postbox {
    var pending = true
    var confirmations = 0
    var maxRead = 123
    var unread = 0
    func transaction<T>(_ action: @escaping (Postbox) -> T) -> Signal<T, NoError> {
        Signal { subscriber in
            subscriber.putNext(action(self))
            subscriber.putCompletion()
            return EmptyDisposable
        }
    }
    func confirmSynchronizedIncomingReadState(_ peerId: PeerId) {
        self.pending = false
        self.confirmations += 1
    }
}

// PRODUCTION_CODE

let owner = PeerId(7)
let other = PeerId(8)
let hidden = MoonPrivacySettings(hideReadReceipts: true, hideTyping: true, hideOnline: true, hideStoryViews: true)
precondition(moonPrivacy(owner) == MoonPrivacySettings())
var values: [MoonPrivacySettings] = []
let observation = moonPrivacySignal(owner).start(next: { values.append($0) })
precondition(values == [MoonPrivacySettings()])
MoonStore.shared.set(hidden, accountID: 8)
precondition(values.count == 1, "Another account must not change the presence policy")
MoonStore.shared.set(hidden, accountID: 7)
MoonStore.shared.set(hidden, accountID: 7)
precondition(values == [MoonPrivacySettings(), hidden], "Policy must update live without duplicate emissions")
observation.dispose()
MoonStore.shared.set(MoonPrivacySettings(), accountID: 7)
precondition(values.count == 2, "Disposed observations must stop")
precondition(moonPrivacy(other) == hidden)
precondition(moonHideReadReceipts(nil))

var requests = 0
let receipt = moonReadReceipt(accountPeerId: owner) { () -> Signal<Int, MTRpcError> in
    requests += 1
    return .single(42)
}
// A toggle after construction but before subscription must still prevent the request.
MoonStore.shared.set(hidden, accountID: 7)
var results: [Int?] = []
var completed = false
let first = receipt.start(next: { results.append($0) }, completed: { completed = true })
precondition(requests == 0 && results.count == 1 && results[0] == nil && completed)
first.dispose()
MoonStore.shared.set(MoonPrivacySettings(), accountID: 7)
let second = receipt.start(next: { results.append($0) })
precondition(requests == 1 && results.last! == 42)
second.dispose()
MoonStore.shared.fails = true
precondition(moonPrivacy(owner) == .protectedOnLoadFailure)
let third = receipt.start(next: { results.append($0) })
precondition(requests == 1 && results.last! == nil)
third.dispose()
MoonStore.shared.fails = false
MoonStore.shared.set(hidden, accountID: 7)

for (push, validate) in [(true, false), (false, true), (true, true)] {
    let postbox = Postbox()
    var ended = false
    let disposable = synchronizePeerReadState(network: Network(), postbox: postbox,
        stateManager: AccountStateManager(accountPeerId: owner), peerId: PeerId(9), push: push, validate: validate).start(completed: { ended = true })
    precondition(ended && !postbox.pending && postbox.confirmations == 1)
    precondition(postbox.maxRead == 123 && postbox.unread == 0, "Suppression must preserve local read state")
    disposable.dispose()
}
let secret = Postbox()
let secretDisposable = synchronizePeerReadState(network: Network(), postbox: secret,
    stateManager: AccountStateManager(accountPeerId: owner), peerId: PeerId(9, namespace: Namespaces.Peer.SecretChat), push: true, validate: true).start()
precondition(secret.pending && secret.confirmations == 0, "Cloud suppression must not change secret-chat timers")
secretDisposable.dispose()
func passesTypingGate(_ activity: PeerInputActivity?, for owner: PeerId) -> Bool {
    var passed = false
    let disposable = verifyTypingGate(accountPeerId: owner, activity: activity).start(next: { passed = true })
    disposable.dispose()
    return passed
}
precondition(!passesTypingGate(.typingText, for: owner))
precondition(passesTypingGate(nil, for: owner), "Existing typing cancellation must still pass")
precondition(passesTypingGate(.speakingInGroupCall(timestamp: 42), for: owner), "Group-call speaking must still pass")
MoonStore.shared.set(MoonPrivacySettings(), accountID: 7)
precondition(passesTypingGate(.typingText, for: owner))
print("privacy signals and queue retirement passed")
