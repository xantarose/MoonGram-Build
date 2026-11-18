import Foundation

/// Device-local outgoing-signal preferences. Never part of a shared cosmetic profile.
public struct MoonPrivacySettings: Codable, Equatable, Sendable {
    public var hideReadReceipts: Bool
    public var hideTyping: Bool
    public var hideOnline: Bool
    public var hideStoryViews: Bool

    public init(hideReadReceipts: Bool = false, hideTyping: Bool = false, hideOnline: Bool = false, hideStoryViews: Bool = false) {
        self.hideReadReceipts = hideReadReceipts
        self.hideTyping = hideTyping
        self.hideOnline = hideOnline
        self.hideStoryViews = hideStoryViews
    }

    /// If an existing settings file is unreadable, do not silently resume outgoing receipts.
    /// The settings screen reports the load failure and keeps the file intact.
    public static let protectedOnLoadFailure = MoonPrivacySettings(hideReadReceipts: true, hideTyping: true, hideOnline: true, hideStoryViews: true)
}
