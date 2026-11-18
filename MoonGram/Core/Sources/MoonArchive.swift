import Foundation

/// Contains cosmetics only. Telegram sessions, credentials and wallet keys have no fields here.
public struct MoonArchive: Codable, Equatable, Sendable {
    public let format: String
    public let version: Int
    public let profile: MoonProfile

    public init(profile: MoonProfile) {
        self.format = "moongram.profile"
        self.version = 1
        self.profile = profile
    }

    public func encoded() throws -> Data {
        try self.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw MoonError.tooLarge }
        return data
    }

    public static let maximumBytes = 6_291_456

    public static func decode(_ data: Data) throws -> MoonArchive {
        guard data.count <= Self.maximumBytes else { throw MoonError.tooLarge }
        let archive = try JSONDecoder().decode(MoonArchive.self, from: data)
        try archive.validate()
        return archive
    }

    public func validate() throws {
        guard self.format == "moongram.profile", self.version == 1 else { throw MoonError.unsupportedVersion }
        try self.profile.validate()
    }
}
