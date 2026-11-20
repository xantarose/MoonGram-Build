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
        let owner = context.account.peerId
        guard message.id.namespace == Namespaces.Message.Cloud, message.id.peerId.namespace == Namespaces.Peer.CloudUser,
              !message.flags.contains(.Incoming), message.author?.id == owner, message.forwardInfo == nil,
              !message.isCopyProtected() else { return }
        let accountID = owner.id._internalGetInt64Value()
        guard let settings = try? MoonStore.shared.settings(accountID: accountID), settings.recordOwnMessages == true || settings.keepOwnMedia == true else { return }
        let edited = message.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.first
        var entry = MoonVaultEntry(peerID: message.id.peerId.id._internalGetInt64Value(), namespace: message.id.namespace,
            messageID: message.id.id, timestamp: message.timestamp, text: settings.recordOwnMessages == true ? message.text : "")
        entry.editTimestamp = edited ?? message.timestamp
        self.observers.observe(context: context)
        if settings.recordOwnMessages == true && (!entry.text.isEmpty || edited != nil) {
            MoonVault.shared.capture(entry, accountID: accountID)
        }
        guard settings.keepOwnMedia == true else { return }
        for medium in message.media {
            let resource: EngineMediaResource.Id
            if let photo = medium as? TelegramMediaImage, let image = largestRepresentationForPhoto(photo, maxSize: PixelDimensions(width: 4096, height: 4096)) {
                resource = EngineMediaResource.Id(image.resource.id)
                entry.kind = .photo
            } else if let file = medium as? TelegramMediaFile, file.isVideo && !file.isInstantVideo {
                resource = EngineMediaResource.Id(file.resource.id)
                entry.kind = .video
            } else { continue }
            if let path = context.engine.resources.completedResourcePath(id: resource) {
                MoonVault.shared.capture(entry, accountID: accountID, mediaPath: path)
            }
            break
        }
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
