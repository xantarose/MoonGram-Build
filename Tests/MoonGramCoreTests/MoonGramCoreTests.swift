import Foundation
import XCTest
@testable import MoonGramCore

final class MoonGramCoreTests: XCTestCase {
    func testVisualIdentityKeepsEveryCardAndLegacyFields() throws {
        var profile = MoonProfile()
        profile.username = "old_user"
        profile.collectibleNumber = "+888 1000"
        let old = try MoonArchive.decode(try MoonArchive(profile: profile).encoded()).profile
        XCTAssertEqual(old.usernames, ["old_user"])
        XCTAssertEqual(old.collectibleNumbers, ["+888 1000"])

        let names = (0..<150).map { "alias_\($0)" }
        let numbers = (0..<150).map { "+888 21\($0)" }
        profile.setVisualIdentity(usernames: [" @alias_0 ", ""] + Array(names.dropFirst()), numbers: numbers)
        let restored = try MoonArchive.decode(try MoonArchive(profile: profile).encoded()).profile
        XCTAssertEqual(restored.usernames, names)
        XCTAssertEqual(restored.collectibleNumbers, numbers)
        XCTAssertEqual(restored.username, names[0])
        XCTAssertEqual(restored.collectibleNumber, numbers[0])

        profile.setVisualIdentity(usernames: [], numbers: [])
        XCTAssertTrue(profile.usernames.isEmpty)
        XCTAssertTrue(profile.collectibleNumbers.isEmpty)
    }

    func testMonthlyStreakRestoresPersistAndDoNotCrossAccounts() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MoonSettings()
        settings.streaksEnabled = true
        try store.save(settings, accountID: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let twoDaysAgo = Int32(now.timeIntervalSince1970) - 172_800
        for peer in 10...15 {
            let peerID = Int64(peer)
            try store.recordStreakActivity(accountID: 1, peerID: peerID, timestamp: twoDaysAgo, incoming: false, now: now)
            XCTAssertFalse(try store.streakSummary(accountID: 1, peerID: peerID, now: now).canRestoreYesterday)
            try store.recordStreakActivity(accountID: 1, peerID: peerID, timestamp: twoDaysAgo, incoming: true, now: now)
            let summary = try store.restoreStreak(accountID: 1, peerID: peerID, now: now)
            XCTAssertEqual(summary.days, peer < 15 ? 2 : 0)
            XCTAssertFalse(summary.canRestoreYesterday)
        }
        let reopened = MoonStore(directory: directory)
        XCTAssertEqual(try reopened.streakSummary(accountID: 1, peerID: 10, now: now).remainingRestores, 0)
        XCTAssertEqual(try reopened.streakSummary(accountID: 2, peerID: 10, now: now).remainingRestores, 5)
        XCTAssertEqual(try reopened.streakSummary(accountID: 1, peerID: 10, now: now.addingTimeInterval(35 * 86_400)).remainingRestores, 5)
    }

    func testRemovingSyncedStylePreservesManualImport() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MoonSettings()
        settings.enabled = true
        try store.save(settings, accountID: 1)
        var manual = MoonProfile()
        manual.displayName = "Локальный импорт"
        var synced = MoonProfile()
        synced.displayName = "Публикация друга"
        try store.importFriend(MoonArchive(profile: manual), accountID: 1, peerID: 2)
        try store.importFriend(MoonArchive(profile: synced), accountID: 1, peerID: 2, synced: true)
        XCTAssertEqual(store.visibleProfile(accountID: 1, peerID: 2), manual)
        try store.removeFriend(accountID: 1, peerID: 2, synced: true)
        XCTAssertEqual(store.visibleProfile(accountID: 1, peerID: 2), manual)
    }

    func testPrivacyDefaultsMigrateAndRemainIndependentOfCosmetics() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MoonSettings()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "privacy")
        let migrated = try JSONDecoder().decode(MoonSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.privacy ?? MoonPrivacySettings(), MoonPrivacySettings())
        let privacy = MoonPrivacySettings(hideReadReceipts: true, hideTyping: true, hideOnline: true, hideStoryViews: true)
        settings.privacy = privacy
        for mode in MoonDisplayMode.allCases {
            settings.enabled = mode != .original
            settings.displayMode = mode
            try store.save(settings, accountID: 7)
            XCTAssertEqual(try store.settings(accountID: 7).privacy, privacy)
        }
        XCTAssertNil(try store.settings(accountID: 8).privacy)
        XCTAssertEqual(try MoonStore(directory: directory).settings(accountID: 7).privacy, privacy)
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: MoonArchive(profile: settings.activeProfile).encoded()) as? [String: Any])
        XCTAssertNil(archive["privacy"])
        XCTAssertFalse(String(decoding: try MoonArchive(profile: settings.activeProfile).encoded(), as: UTF8.self).contains("hideReadReceipts"))
    }

    func testNativeGiftCatalogIDsRoundTripWithoutLosingInt64Precision() throws {
        var profile = MoonProfile()
        profile.gifts = [MoonGift(telegram: MoonTelegramGift(baseGiftID: Int64.max, modelFileID: Int64.min, patternFileID: 42, backdropID: Int32.min))]
        let data = try MoonArchive(profile: profile).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedProfile = try XCTUnwrap(object["profile"] as? [String: Any])
        let gifts = try XCTUnwrap(encodedProfile["gifts"] as? [[String: Any]])
        let native = try XCTUnwrap(gifts.first?["telegram"] as? [String: Any])
        XCTAssertEqual(native["modelFileID"] as? String, String(Int64.min))
        XCTAssertEqual(try MoonArchive.decode(data).profile, profile)
        XCTAssertThrowsError(try MoonTelegramGift(baseGiftID: 0, modelFileID: 1, patternFileID: 2, backdropID: 0).validate())
    }

    func testDisplayModesNeverOverwriteOrDeleteCosmetics() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MoonSettings()
        var profile = MoonProfile()
        profile.localPremium = true
        profile.stars = Int64.max
        profile.username = "visual_name"
        profile.collectibleNumber = "+888 123456"
        profile.gifts = [MoonGift()]
        try settings.setActiveProfile(profile)
        settings.enabled = true
        for mode in MoonDisplayMode.allCases {
            settings.displayMode = mode
            try store.save(settings, accountID: 1)
            XCTAssertEqual(try store.settings(accountID: 1).activeProfile, profile)
            XCTAssertEqual(store.visibleProfile(accountID: 1, peerID: 1) != nil, mode != .original)
            XCTAssertEqual(store.replacementProfile(accountID: 1, peerID: 1) != nil, mode == .visual)
        }
        XCTAssertEqual(try MoonArchive.decode(MoonArchive(profile: profile).encoded()).profile.stars, Int64.max)
    }

    func testExperimentIsDisabledAndScopedToOnePeer() throws {
        let off = MoonExperiments()
        XCTAssertFalse(off.allows(peerID: 2, media: false))
        XCTAssertFalse(off.allows(peerID: 2, media: true))
        let enabled = MoonExperiments(testPeerID: 2, saveLoadedMessages: true, saveViewOnceMedia: true)
        try enabled.validate()
        XCTAssertTrue(enabled.allows(peerID: 2, media: true))
        XCTAssertFalse(enabled.allows(peerID: 3, media: true))
        XCTAssertThrowsError(try MoonExperiments(saveViewOnceMedia: true).validate())
    }
    private func temporaryStore() throws -> (MoonStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (MoonStore(directory: directory), directory)
    }

    func testTogglePreservesProfileAndRestart() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MoonSettings()
        var profile = MoonProfile()
        profile.stars = 9_999_999_999
        profile.walletBalance = try MoonAmount("123456789012345678.123456789")
        profile.gifts = [MoonGift(title: "Лунный медведь", number: "888", model: .bear)]
        try settings.setActiveProfile(profile)
        settings.enabled = true
        try store.save(settings, accountID: 1)
        XCTAssertEqual(store.visibleProfile(accountID: 1, peerID: 1), profile)
        settings.enabled = false
        try store.save(settings, accountID: 1)
        XCTAssertNil(store.visibleProfile(accountID: 1, peerID: 1))
        let reopened = MoonStore(directory: directory)
        var restored = try reopened.settings(accountID: 1)
        XCTAssertEqual(restored.activeProfile, profile)
        restored.enabled = true
        try reopened.save(restored, accountID: 1)
        XCTAssertEqual(reopened.visibleProfile(accountID: 1, peerID: 1), profile)
    }

    func testAccountsAndFriendsAreIsolated() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MoonSettings()
        settings.enabled = true
        try store.save(settings, accountID: 1)
        var friend = MoonProfile()
        friend.displayName = "Друг"
        try store.importFriend(MoonArchive(profile: friend), accountID: 1, peerID: 2)
        XCTAssertEqual(store.visibleProfile(accountID: 1, peerID: 2), friend)
        XCTAssertNil(store.visibleProfile(accountID: 3, peerID: 2))
        settings.showFriends = false
        try store.save(settings, accountID: 1)
        XCTAssertNil(store.visibleProfile(accountID: 1, peerID: 2))
        settings.showFriends = true
        try store.save(settings, accountID: 1)
        XCTAssertEqual(store.visibleProfile(accountID: 1, peerID: 2), friend)
        try store.removeFriend(accountID: 1, peerID: 2)
        XCTAssertNil(store.visibleProfile(accountID: 1, peerID: 2))
    }

    func testArchiveRoundTripAndPrivacy() throws {
        var profile = MoonProfile()
        profile.stars = 100
        profile.walletBalance = try MoonAmount("1000.000001")
        profile.gifts = [MoonGift()]
        let data = try MoonArchive(profile: profile).encoded()
        XCTAssertEqual(try MoonArchive.decode(data).profile, profile)
        let shared = profile.shared(includingBalances: false)
        XCTAssertNil(shared.stars)
        XCTAssertNil(shared.walletBalance)
        XCTAssertEqual(shared.gifts, profile.gifts)
    }

    func testInvalidArchiveCannotReplaceSavedSettings() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = MoonSettings()
        try store.save(original, accountID: 1)
        var bad = original
        bad.activePresetID = UUID()
        XCTAssertThrowsError(try store.save(bad, accountID: 1))
        XCTAssertEqual(try store.settings(accountID: 1), original)
        XCTAssertThrowsError(try MoonArchive.decode(Data("{\"format\":\"moongram.profile\",\"version\":999}".utf8)))
        XCTAssertThrowsError(try MoonArchive.decode(Data(repeating: 0, count: MoonArchive.maximumBytes + 1)))
    }

    func testExactDecimalAndInvalidInput() throws {
        XCTAssertEqual(try MoonAmount("00042,120000000").text, "42.12")
        XCTAssertEqual(try MoonAmount("0.000000001").text, "0.000000001")
        for value in ["-1", "NaN", "Infinity", "1e9", "1.0000000001", "١٢", "1..2", "1.", "", "1\u{0301}", "1\u{FE0F}"] {
            XCTAssertThrowsError(try MoonAmount(value), value)
        }
    }

    func testUntrustedTextColorsAndAssetsAreRejected() throws {
        var profile = MoonProfile()
        profile.username = "\u{202E}admin"
        XCTAssertThrowsError(try profile.validate())
        profile.username = ""
        profile.gifts = [MoonGift(backdrop: "../../")]
        XCTAssertThrowsError(try profile.validate())
        profile.gifts = [MoonGift(artwork: Data("<svg onload='bad'>".utf8))]
        XCTAssertThrowsError(try profile.validate())
        let gift = MoonGift()
        profile.gifts = [gift, gift]
        XCTAssertThrowsError(try profile.validate())
    }

    func testCorruptionFallsBackToRealDataWithoutOverwriting() throws {
        let (store, directory) = try self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountDirectory = directory.appendingPathComponent("1")
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        let file = accountDirectory.appendingPathComponent("settings.json")
        let broken = Data("broken-json".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try store.settings(accountID: 1))
        XCTAssertNil(store.visibleProfile(accountID: 1, peerID: 1))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testPresetSelectionDoesNotDeleteOtherPresets() throws {
        var settings = MoonSettings()
        let first = settings.activePresetID
        var profile = MoonProfile()
        profile.stars = 900
        let other = MoonPreset(name: "Другой", profile: profile)
        settings.presets.append(other)
        settings.activePresetID = other.id
        try settings.validate()
        XCTAssertEqual(settings.activeProfile.stars, 900)
        settings.activePresetID = first
        XCTAssertNil(settings.activeProfile.stars)
        XCTAssertEqual(settings.presets.count, 2)
    }
}
