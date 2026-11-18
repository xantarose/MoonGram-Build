import Foundation
import MoonGramCore
import MtProtoKit
import SwiftSignalKit

func moonPrivacy(_ accountPeerId: EnginePeer.Id) -> MoonPrivacySettings {
    do {
        return try MoonStore.shared.settings(accountID: accountPeerId.id._internalGetInt64Value()).privacy ?? MoonPrivacySettings()
    } catch {
        return .protectedOnLoadFailure
    }
}

func moonPrivacySignal(_ accountPeerId: EnginePeer.Id) -> Signal<MoonPrivacySettings, NoError> {
    return Signal { subscriber in
        let lock = NSRecursiveLock()
        let emit = {
            lock.lock()
            defer { lock.unlock() }
            subscriber.putNext(moonPrivacy(accountPeerId))
        }
        let observer = NotificationCenter.default.addObserver(forName: .moonGramSettingsDidChange, object: nil, queue: nil) { notification in
            guard notification.userInfo?["accountID"] as? Int64 == accountPeerId.id._internalGetInt64Value() else { return }
            emit()
        }
        // Subscribe before reading so a save between these steps cannot be lost.
        emit()
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
    |> distinctUntilChanged
}

/// Evaluate at subscription time. A suppressed receipt emits no fabricated pts/update payload;
/// callers retain their normal local bookkeeping using the optional absence of a server result.
func moonReadReceipt<T>(accountPeerId: EnginePeer.Id, request: @escaping () -> Signal<T, MTRpcError>) -> Signal<T?, MTRpcError> {
    return Signal { subscriber in
        if moonPrivacy(accountPeerId).hideReadReceipts {
            subscriber.putNext(nil)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        return request().start(next: { value in
            subscriber.putNext(value)
        }, error: { error in
            subscriber.putError(error)
        }, completed: {
            subscriber.putCompletion()
        })
    }
}

func moonHideReadReceipts(_ accountPeerId: EnginePeer.Id?) -> Bool {
    guard let accountPeerId else { return true }
    return moonPrivacy(accountPeerId).hideReadReceipts
}
