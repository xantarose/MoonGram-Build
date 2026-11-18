import Foundation

public enum MoonError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unsupportedVersion
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case let .invalid(field): return "Проверьте поле «\(field)»."
        case .unsupportedVersion: return "Этот файл создан неподдерживаемой версией MoonGram."
        case .tooLarge: return "Превышен размер оформления. Уменьшите число изображений."
        }
    }
}

/// Decimal text is kept exact: wallet amounts never pass through Double.
public struct MoonAmount: Codable, Equatable, Sendable {
    public let text: String

    public init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts[0].count <= 18,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) }),
              parts.count == 1 || parts[1].count <= 9 else { throw MoonError.invalid("баланс") }
        let integral = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count == 2 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        self.text = (integral.isEmpty ? "0" : integral) + (fraction.isEmpty ? "" : "." + fraction)
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.text)
    }
}

public enum MoonPattern: String, Codable, CaseIterable, Sendable {
    case moons, stars, diamonds, dots, none
    public var title: String {
        switch self {
        case .moons: return "Луны"
        case .stars: return "Звёзды"
        case .diamonds: return "Ромбы"
        case .dots: return "Точки"
        case .none: return "Без узора"
        }
    }
    public var symbol: String {
        switch self {
        case .moons: return "moon.fill"
        case .stars: return "star.fill"
        case .diamonds: return "diamond.fill"
        case .dots: return "circle.fill"
        case .none: return "circle"
        }
    }
}

public enum MoonModel: String, Codable, CaseIterable, Sendable {
    case moon, star, diamond, crown, heart, bear, sparkles, gift
    public var symbol: String {
        switch self {
        case .moon: return "moon.fill"
        case .star: return "star.fill"
        case .diamond: return "diamond.fill"
        case .crown: return "crown.fill"
        case .heart: return "heart.fill"
        case .bear: return "teddybear.fill"
        case .sparkles: return "sparkles"
        case .gift: return "gift.fill"
        }
    }
}

public struct MoonGift: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var number: String
    public var model: MoonModel
    public var modelName: String
    public var pattern: MoonPattern
    public var backdrop: String
    public var symbolColor: String
    public var collection: String
    /// A bounded, raster thumbnail; never a URL, script, SVG, or executable animation.
    public var artwork: Data?
    public var telegram: MoonTelegramGift?

    public init(id: UUID = UUID(), title: String = "Moon Gift", number: String = "1",
                model: MoonModel = .moon, modelName: String = "Moon", pattern: MoonPattern = .stars,
                backdrop: String = "14334C", symbolColor: String = "B8DDF0",
                collection: String = "Моя коллекция", artwork: Data? = nil, telegram: MoonTelegramGift? = nil) {
        self.id = id
        self.title = title
        self.number = number
        self.model = model
        self.modelName = modelName
        self.pattern = pattern
        self.backdrop = backdrop
        self.symbolColor = symbolColor
        self.collection = collection
        self.artwork = artwork
        self.telegram = telegram
    }

    public func validate() throws {
        try self.telegram?.validate()
        try moonValidateText(self.title, field: "название подарка", maximum: 64, required: true)
        try moonValidateText(self.number, field: "номер подарка", maximum: 32, required: true)
        try moonValidateText(self.modelName, field: "модель", maximum: 64, required: true)
        try moonValidateText(self.collection, field: "коллекция", maximum: 64)
        for color in [self.backdrop, self.symbolColor] {
            guard color.count == 6, color.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw MoonError.invalid("цвет в формате RRGGBB")
            }
        }
        if let artwork = self.artwork {
            guard artwork.count <= 131_072 else { throw MoonError.tooLarge }
            // The iOS importer also decodes and re-encodes the raster image.
            let png = artwork.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            let jpeg = artwork.starts(with: [255, 216, 255])
            guard png || jpeg else { throw MoonError.invalid("изображение модели") }
        }
    }
}

public struct MoonProfile: Codable, Equatable, Sendable {
    public var displayName: String = ""
    public var username: String = ""
    public var collectibleNumber: String = ""
    public var localPremium: Bool = false
    public var stars: Int64? = nil
    public var walletBalance: MoonAmount? = nil
    public var walletCurrency: String = "TON"
    public var gifts: [MoonGift] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case displayName, username, collectibleNumber, localPremium, stars, walletBalance, walletCurrency, gifts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try values.decode(String.self, forKey: .displayName)
        self.username = try values.decode(String.self, forKey: .username)
        self.collectibleNumber = try values.decode(String.self, forKey: .collectibleNumber)
        self.localPremium = try values.decode(Bool.self, forKey: .localPremium)
        if let text = try values.decodeIfPresent(String.self, forKey: .stars) {
            guard !text.isEmpty, text.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }), let value = Int64(text) else {
                throw MoonError.invalid("Stars")
            }
            self.stars = value
        } else { self.stars = nil }
        self.walletBalance = try values.decodeIfPresent(MoonAmount.self, forKey: .walletBalance)
        self.walletCurrency = try values.decode(String.self, forKey: .walletCurrency)
        self.gifts = try values.decode([MoonGift].self, forKey: .gifts)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.displayName, forKey: .displayName)
        try values.encode(self.username, forKey: .username)
        try values.encode(self.collectibleNumber, forKey: .collectibleNumber)
        try values.encode(self.localPremium, forKey: .localPremium)
        try values.encodeIfPresent(self.stars.map(String.init), forKey: .stars)
        try values.encodeIfPresent(self.walletBalance, forKey: .walletBalance)
        try values.encode(self.walletCurrency, forKey: .walletCurrency)
        try values.encode(self.gifts, forKey: .gifts)
    }

    public func validate() throws {
        try moonValidateText(self.displayName, field: "имя", maximum: 64)
        try moonValidateText(self.username, field: "декоративный username", maximum: 64)
        try moonValidateText(self.collectibleNumber, field: "декоративный номер", maximum: 48)
        try moonValidateText(self.walletCurrency, field: "валюта", maximum: 12, required: true)
        if let stars = self.stars, stars < 0 { throw MoonError.invalid("звёзды") }
        guard self.gifts.count <= 128, Set(self.gifts.map(\.id)).count == self.gifts.count else {
            throw MoonError.invalid("список подарков")
        }
        for gift in self.gifts { try gift.validate() }
        guard self.artworkBytes <= 4_194_304 else { throw MoonError.tooLarge }
    }

    public var artworkBytes: Int { self.gifts.reduce(0) { $0 + ($1.artwork?.count ?? 0) } }

    public func shared(includingBalances: Bool) -> MoonProfile {
        var result = self
        if !includingBalances {
            result.stars = nil
            result.walletBalance = nil
        }
        return result
    }
}

public struct MoonPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var profile: MoonProfile

    public init(id: UUID = UUID(), name: String = "Основной", profile: MoonProfile = MoonProfile()) {
        self.id = id
        self.name = name
        self.profile = profile
    }
}

public struct MoonSettings: Codable, Equatable, Sendable {
    public let version: Int
    public var enabled: Bool
    public var showFriends: Bool
    public var activePresetID: UUID
    public var presets: [MoonPreset]
    public var experiments: MoonExperiments?
    public var privacy: MoonPrivacySettings?
    public var displayMode: MoonDisplayMode?

    public init() {
        let preset = MoonPreset()
        self.version = 1
        self.enabled = false
        self.showFriends = true
        self.activePresetID = preset.id
        self.presets = [preset]
        self.experiments = nil
        self.privacy = nil
        self.displayMode = .visual
    }

    public var activeProfile: MoonProfile {
        self.presets.first(where: { $0.id == self.activePresetID })?.profile ?? MoonProfile()
    }

    public var effectiveDisplayMode: MoonDisplayMode { self.enabled ? (self.displayMode ?? .visual) : .original }

    public mutating func setActiveProfile(_ profile: MoonProfile) throws {
        try profile.validate()
        guard let index = self.presets.firstIndex(where: { $0.id == self.activePresetID }) else {
            throw MoonError.invalid("активный пресет")
        }
        self.presets[index].profile = profile
    }

    public func validate() throws {
        guard self.version == 1 else { throw MoonError.unsupportedVersion }
        try self.experiments?.validate()
        guard (1...8).contains(self.presets.count),
              Set(self.presets.map(\.id)).count == self.presets.count,
              self.presets.contains(where: { $0.id == self.activePresetID }) else {
            throw MoonError.invalid("пресеты")
        }
        for preset in self.presets {
            try moonValidateText(preset.name, field: "название пресета", maximum: 40, required: true)
            try preset.profile.validate()
        }
        guard self.presets.reduce(0, { $0 + $1.profile.artworkBytes }) <= 8_388_608 else { throw MoonError.tooLarge }
    }
}

func moonValidateText(_ text: String, field: String, maximum: Int, required: Bool = false) throws {
    guard text.unicodeScalars.count <= maximum, text.utf8.count <= maximum * 8,
          !required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control ||
              (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
        throw MoonError.invalid(field)
    }
}
