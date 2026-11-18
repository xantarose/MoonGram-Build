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
    private var streakCache: [Int64: MoonStreakLedger] = [:]
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
        let archives = [false, true].lazy.compactMap { synced -> (MoonArchive, Int)? in
            let file = self.friendURL(accountID: accountID, peerID: peerID, synced: synced)
            guard let data = try? self.readBounded(file, maximumBytes: MoonArchive.maximumBytes),
                  let archive = try? MoonArchive.decode(data) else { return nil }
            return (archive, data.count)
        }
        guard let (archive, byteCount) = archives.first else {
            self.friendCache.setObject(MoonCachedProfile(nil), forKey: key, cost: 1)
            return nil
        }
        self.friendCache.setObject(MoonCachedProfile(archive.profile), forKey: key, cost: byteCount)
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
    public func importFriend(_ archive: MoonArchive, accountID: Int64, peerID: Int64, synced: Bool = false) throws {
        guard accountID != peerID, peerID > 0 else { throw MoonError.invalid("ID друга") }
        let data = try archive.encoded()
        self.lock.lock()
        do {
            try self.write(data, to: self.friendURL(accountID: accountID, peerID: peerID, synced: synced))
            self.friendCache.removeObject(forKey: "\(accountID):\(peerID)" as NSString)
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .moonGramSettingsDidChange, object: nil, userInfo: ["accountID": accountID])
    }

    public func removeFriend(accountID: Int64, peerID: Int64, synced: Bool = false) throws {
        self.lock.lock()
        do {
            let url = self.friendURL(accountID: accountID, peerID: peerID, synced: synced)
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.lock.unlock()
                return
            }
            try FileManager.default.removeItem(at: url)
            self.friendCache.removeObject(forKey: "\(accountID):\(peerID)" as NSString)
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .moonGramSettingsDidChange, object: nil, userInfo: ["accountID": accountID])
    }

    public func recordStreakActivity(accountID: Int64, peerID: Int64, timestamp: Int32, incoming: Bool, now: Date = Date()) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard accountID > 0, peerID > 0, peerID != accountID,
              try self.settings(accountID: accountID).streaksEnabled == true else { return }
        var ledger = try self.streakLedger(accountID: accountID)
        if ledger.record(peerID: peerID, date: Date(timeIntervalSince1970: TimeInterval(timestamp)), incoming: incoming, now: now) {
            try self.saveStreakLedger(ledger, accountID: accountID)
        }
    }

    public func streakSummary(accountID: Int64, peerID: Int64, now: Date = Date()) throws -> MoonStreakSummary {
        self.lock.lock()
        defer { self.lock.unlock() }
        return try self.streakLedger(accountID: accountID).summary(peerID: peerID, now: now)
    }

    public func restoreStreak(accountID: Int64, peerID: Int64, now: Date = Date()) throws -> MoonStreakSummary {
        self.lock.lock()
        defer { self.lock.unlock() }
        var ledger = try self.streakLedger(accountID: accountID)
        guard try self.settings(accountID: accountID).streaksEnabled == true else { return ledger.summary(peerID: peerID, now: now) }
        if ledger.restoreYesterday(peerID: peerID, now: now) { try self.saveStreakLedger(ledger, accountID: accountID) }
        return ledger.summary(peerID: peerID, now: now)
    }

    private func streakURL(accountID: Int64) -> URL {
        self.directory.appendingPathComponent(String(accountID), isDirectory: true).appendingPathComponent("streaks.json")
    }

    private func streakLedger(accountID: Int64) throws -> MoonStreakLedger {
        if let ledger = self.streakCache[accountID] { return ledger }
        let path = self.streakURL(accountID: accountID)
        let ledger: MoonStreakLedger
        if FileManager.default.fileExists(atPath: path.path) {
            ledger = try JSONDecoder().decode(MoonStreakLedger.self, from: self.readBounded(path, maximumBytes: 4_194_304))
        } else {
            ledger = MoonStreakLedger()
        }
        self.streakCache[accountID] = ledger
        return ledger
    }

    private func saveStreakLedger(_ ledger: MoonStreakLedger, accountID: Int64) throws {
        let data = try JSONEncoder().encode(ledger)
        guard data.count <= 4_194_304 else { throw MoonError.tooLarge }
        try self.write(data, to: self.streakURL(accountID: accountID))
        self.streakCache[accountID] = ledger
    }

    private func settingsURL(_ accountID: Int64) -> URL {
        self.directory.appendingPathComponent(String(accountID), isDirectory: true).appendingPathComponent("settings.json")
    }

    private func friendURL(accountID: Int64, peerID: Int64, synced: Bool) -> URL {
        self.directory.appendingPathComponent(String(accountID), isDirectory: true)
            .appendingPathComponent(synced ? "synced-friends" : "friends", isDirectory: true).appendingPathComponent("\(peerID).json")
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
