import Foundation

/// Public catalog identifiers only. No ownership, access hash, file reference or session data.
public struct MoonTelegramGift: Codable, Hashable, Sendable {
    public var baseGiftID: Int64
    public var modelFileID: Int64
    public var patternFileID: Int64
    public var backdropID: Int32

    public init(baseGiftID: Int64, modelFileID: Int64, patternFileID: Int64, backdropID: Int32) {
        self.baseGiftID = baseGiftID
        self.modelFileID = modelFileID
        self.patternFileID = patternFileID
        self.backdropID = backdropID
    }

    private enum CodingKeys: String, CodingKey { case baseGiftID, modelFileID, patternFileID, backdropID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func identifier(_ key: CodingKeys) throws -> Int64 {
            let text = try values.decode(String.self, forKey: key)
            guard let value = Int64(text), String(value) == text, value != 0 else { throw MoonError.invalid("ID ресурса Telegram") }
            return value
        }
        self.baseGiftID = try identifier(.baseGiftID)
        self.modelFileID = try identifier(.modelFileID)
        self.patternFileID = try identifier(.patternFileID)
        self.backdropID = try values.decode(Int32.self, forKey: .backdropID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(String(self.baseGiftID), forKey: .baseGiftID)
        try values.encode(String(self.modelFileID), forKey: .modelFileID)
        try values.encode(String(self.patternFileID), forKey: .patternFileID)
        try values.encode(self.backdropID, forKey: .backdropID)
    }

    public func validate() throws {
        guard self.baseGiftID != 0, self.modelFileID != 0, self.patternFileID != 0 else { throw MoonError.invalid("ID ресурса Telegram") }
    }
}
