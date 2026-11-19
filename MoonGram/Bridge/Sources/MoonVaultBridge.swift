import AccountContext
import Foundation
import MoonGramCore
import MoonGramVault
import PhotoResources
import SwiftSignalKit
import TelegramCore

public enum MoonVaultBridge {
    private static let observers = MoonDeletionObservers()
    public static func loadedMessage(context: AccountContext, message: EngineRawMessage) {
        let accountID = context.account.peerId.id._internalGetInt64Value()
        guard self.isAllowed(context: context, message: message, media: false), !message.text.isEmpty else { return }
        self.observers.observe(context: context)
        MoonVault.shared.capture(self.entry(message), accountID: accountID)
    }

    /// Observes only the resource fetched by the real gallery. Does not postpone consumed/read events.
    public static func viewOnce(context: AccountContext, message: EngineRawMessage, cachedVideoPath: String?) -> Disposable? {
        guard self.isAllowed(context: context, message: message, media: true), message.minAutoremoveOrClearTimeout == viewOnceTimeout else { return nil }
        self.observers.observe(context: context)
        var resource: EngineMediaResource?
        var entry = self.entry(message)
        for media in message.media {
            if let image = media as? TelegramMediaImage,
               let representation = largestRepresentationForPhoto(image, maxSize: PixelDimensions(width: 4096, height: 4096)) {
                resource = EngineMediaResource(representation.resource)
                entry.kind = .photo
                break
            } else if let file = media as? TelegramMediaFile, file.isVideo, !file.isInstantVideo {
                entry.kind = .video
                if let cachedVideoPath = cachedVideoPath {
                    MoonVault.shared.capture(entry, accountID: context.account.peerId.id._internalGetInt64Value(), mediaPath: cachedVideoPath)
                    return nil
                }
                resource = EngineMediaResource(file.resource)
                break
            }
        }
        guard let resource = resource else { return nil }
        let snapshot = entry
        return (context.engine.resources.data(resource: resource, pathExtension: nil, waitUntilFetchStatus: false,
                                              incremental: false, attemptSynchronously: false)
                |> filter { $0.isComplete }
                |> take(1)
                |> timeout(20.0, queue: Queue.concurrentDefaultQueue(), alternate: .complete())).start(next: { data in
            MoonVault.shared.capture(snapshot, accountID: context.account.peerId.id._internalGetInt64Value(), mediaPath: data.path)
        })
    }

    private static func isAllowed(context: AccountContext, message: EngineRawMessage, media: Bool) -> Bool {
        guard message.flags.contains(.Incoming), message.id.namespace == Namespaces.Message.Cloud,
              message.id.peerId.namespace == Namespaces.Peer.CloudUser else { return false }
        return (try? MoonStore.shared.settings(accountID: context.account.peerId.id._internalGetInt64Value()).experiments)?
            .allows(peerID: message.id.peerId.id._internalGetInt64Value(), media: media) == true
    }

    private static func entry(_ message: EngineRawMessage) -> MoonVaultEntry {
        MoonVaultEntry(peerID: message.id.peerId.id._internalGetInt64Value(), namespace: message.id.namespace, messageID: message.id.id,
                       timestamp: message.timestamp, text: message.text)
    }
}

private final class MoonDeletionObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [Int64: (ObjectIdentifier, Disposable)] = [:]

    func observe(context: AccountContext) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let accountID = context.account.peerId.id._internalGetInt64Value()
        let identity = ObjectIdentifier(context.account)
        if self.subscriptions[accountID]?.0 == identity { return }
        self.subscriptions[accountID]?.1.dispose()
        let disposable = context.account.stateManager.deletedMessages.start(next: { deleted in
            var ids: [MoonVaultDeletion] = []
            for id in deleted {
                switch id {
                case let .global(messageID): ids.append(MoonVaultDeletion(peerID: nil, messageID: messageID))
                case let .messageId(messageID):
                    if messageID.peerId.namespace == Namespaces.Peer.CloudUser, messageID.namespace == Namespaces.Message.Cloud {
                        ids.append(MoonVaultDeletion(peerID: messageID.peerId.id._internalGetInt64Value(), messageID: messageID.id))
                    }
                }
            }
            if !ids.isEmpty { MoonVault.shared.markDeleted(accountID: accountID, ids: ids) }
        })
        self.subscriptions[accountID] = (identity, disposable)
    }
}
