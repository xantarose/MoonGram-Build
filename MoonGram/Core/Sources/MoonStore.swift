import Foundation

private final class MoonCachedProfile: NSObject {
    let profile: MoonProfile?
    init(_ profile: MoonProfile?) { self.profile = profile }
}

extension Notification.Name {
    public static let moonGramSettingsDidChange = Notification.Name("MoonGram.settingsDidChange")
}

/// A separate Application Support store. It never opens the Telegram database or media cache.
public final class MoonStore: @unchecked Sendable {
    public static let shared: MoonStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".moongram")
        return MoonStore(directory: base.appendingPathComponent("MoonGram", isDirectory: true))
    }()

    private let directory: URL
    private let lock = NSRecursiveLock()
    private var cache: [Int64: MoonSettings] = [:]
    private let friendCache = NSCache<NSString, MoonCachedProfile>()
    private let maximumFileBytes = 16_777_216

    public init(directory: URL) {
        self.directory = directory
        self.friendCache.countLimit = 64
        self.friendCache.totalCostLimit = 8_388_608
    }

    public func settings(accountID: Int64) throws -> MoonSettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let settings = self.cache[accountID] { return settings }
        let file = self.settingsURL(accountID)
        guard FileManager.default.fileExists(atPath: file.path) else {
            let settings = MoonSettings()
            self.cache[accountID] = settings
            return settings
        }
        let data = try self.readBounded(file, maximumBytes: self.maximumFileBytes)
        let settings = try JSONDecoder().decode(MoonSettings.self, from: data)
        try settings.validate()
        self.cache[accountID] = settings
        return settings
    }

    public func save(_ settings: MoonSettings, accountID: Int64) throws {
        try settings.validate()
        let data = try JSONEncoder().encode(settings)
        guard data.count <= self.maximumFileBytes else { throw MoonError.tooLarge }
        self.lock.lock()
        do {
            try self.write(data, to: self.settingsURL(accountID))
            self.cache[accountID] = settings
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .moonGramSettingsDidChange, object: nil, userInfo: ["accountID": accountID])
    }

    /// Fail closed for display: a corrupt cosmetic store leaves real Telegram values visible.
    public func visibleProfile(accountID: Int64, peerID: Int64) -> MoonProfile? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let settings = try? self.settings(accountID: accountID), settings.effectiveDisplayMode != .original else { return nil }
        if accountID == peerID { return settings.activeProfile }
        guard settings.showFriends else { return nil }
        let key = "\(accountID):\(peerID)" as NSString
        if let cached = self.friendCache.object(forKey: key) { return cached.profile }
        let file = self.friendURL(accountID: accountID, peerID: peerID)
        guard let data = try? self.readBounded(file, maximumBytes: MoonArchive.maximumBytes),
              let archive = try? MoonArchive.decode(data) else {
            self.friendCache.setObject(MoonCachedProfile(nil), forKey: key, cost: 1)
            return nil
        }
        self.friendCache.setObject(MoonCachedProfile(archive.profile), forKey: key, cost: data.count)
        return archive.profile
    }

    /// In combined mode the native fields retain their real values; cosmetics have a separate section.
    public func replacementProfile(accountID: Int64, peerID: Int64) -> MoonProfile? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let settings = try? self.settings(accountID: accountID), settings.effectiveDisplayMode == .visual else { return nil }
        return self.visibleProfile(accountID: accountID, peerID: peerID)
    }

    /// The owner ID is supplied by the user's verified contact or the authenticated sync service.
    /// An imported JSON file is never accepted as proof of Telegram account ownership.
    public func importFriend(_ archive: MoonArchive, accountID: Int64, peerID: Int64) throws {
        guard accountID != peerID, peerID > 0 else { throw MoonError.invalid("ID друга") }
        let data = try archive.encoded()
        self.lock.lock()
        do {
            try self.write(data, to: self.friendURL(accountID: accountID, peerID: peerID))
            self.friendCache.setObject(MoonCachedProfile(archive.profile), forKey: "\(accountID):\(peerID)" as NSString, cost: data.count)
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .moonGramSettingsDidChange, object: nil, userInfo: ["accountID": accountID])
    }

    public func removeFriend(accountID: Int64, peerID: Int64) throws {
        self.lock.lock()
        do {
            let url = self.friendURL(accountID: accountID, peerID: peerID)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            self.friendCache.removeObject(forKey: "\(accountID):\(peerID)" as NSString)
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .moonGramSettingsDidChange, object: nil, userInfo: ["accountID": accountID])
    }

    private func settingsURL(_ accountID: Int64) -> URL {
        self.directory.appendingPathComponent(String(accountID), isDirectory: true).appendingPathComponent("settings.json")
    }

    private func friendURL(accountID: Int64, peerID: Int64) -> URL {
        self.directory.appendingPathComponent(String(accountID), isDirectory: true)
            .appendingPathComponent("friends", isDirectory: true).appendingPathComponent("\(peerID).json")
    }

    private func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw MoonError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw MoonError.tooLarge }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
