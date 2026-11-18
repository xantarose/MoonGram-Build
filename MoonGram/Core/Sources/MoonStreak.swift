import Foundation

public struct MoonStreakSummary: Equatable, Sendable {
    public let days: Int
    public let canRestoreYesterday: Bool
    public let remainingRestores: Int
}

/// Keeps only daily direction flags and restored dates, never message text or message IDs.
struct MoonStreakLedger: Codable {
    static let maximumDays = 731
    static let monthlyLimit = 5
    private var chats: [Int64: [Int: UInt8]] = [:]
    private var restores: [Int: Int] = [:]

    static func day(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }

    private static func month(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return (parts.year ?? 0) * 12 + (parts.month ?? 1)
    }

    mutating func record(peerID: Int64, date: Date, incoming: Bool, now: Date) -> Bool {
        let day = Self.day(date)
        let today = Self.day(now)
        guard day <= today, day > today - Self.maximumDays else { return false }
        guard self.chats[peerID] != nil || self.chats.count < 256 else { return false }
        var entries = self.chats[peerID] ?? [:]
        let old = entries[day, default: 0]
        let next = old | (incoming ? 1 : 2)
        guard old != next else { return false }
        entries[day] = next
        if entries.count >= Self.maximumDays { entries = entries.filter { $0.key > today - Self.maximumDays } }
        self.chats[peerID] = entries
        return true
    }

    func summary(peerID: Int64, now: Date) -> MoonStreakSummary {
        let today = Self.day(now)
        let entries = self.chats[peerID] ?? [:]
        func isComplete(_ day: Int) -> Bool {
            guard let flags = entries[day] else { return false }
            return flags & 3 == 3 || flags & 4 != 0
        }
        let remaining = max(0, Self.monthlyLimit - self.restores[Self.month(now), default: 0])
        var currentDay = isComplete(today) ? today : today - 1
        var count = 0
        while currentDay > today - Self.maximumDays && isComplete(currentDay) {
            count += 1
            currentDay -= 1
        }
        return MoonStreakSummary(days: count,
                                 canRestoreYesterday: remaining > 0 && !isComplete(today - 1) && isComplete(today - 2),
                                 remainingRestores: remaining)
    }

    mutating func restoreYesterday(peerID: Int64, now: Date) -> Bool {
        guard self.summary(peerID: peerID, now: now).canRestoreYesterday else { return false }
        let month = Self.month(now)
        self.restores[month, default: 0] += 1
        self.restores = self.restores.filter { $0.key >= month - 12 }
        self.chats[peerID, default: [:]][Self.day(now) - 1, default: 0] |= 4
        return true
    }
}
