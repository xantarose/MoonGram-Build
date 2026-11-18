import Foundation

/// Per-account, explicit consent scope. These settings never enter a shared cosmetic profile.
public struct MoonExperiments: Codable, Equatable, Sendable {
    public var testPeerID: Int64?
    public var saveLoadedMessages: Bool
    public var saveViewOnceMedia: Bool

    public init(testPeerID: Int64? = nil, saveLoadedMessages: Bool = false, saveViewOnceMedia: Bool = false) {
        self.testPeerID = testPeerID
        self.saveLoadedMessages = saveLoadedMessages
        self.saveViewOnceMedia = saveViewOnceMedia
    }

    public func allows(peerID: Int64, media: Bool) -> Bool {
        peerID > 0 && self.testPeerID == peerID && (media ? self.saveViewOnceMedia : self.saveLoadedMessages)
    }

    public func validate() throws {
        if self.saveLoadedMessages || self.saveViewOnceMedia {
            guard let id = self.testPeerID, id > 0 else { throw MoonError.invalid("ID участника эксперимента") }
        }
    }
}
