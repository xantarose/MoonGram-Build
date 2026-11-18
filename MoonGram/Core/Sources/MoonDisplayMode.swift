import Foundation

public enum MoonDisplayMode: String, Codable, CaseIterable, Sendable {
    case original, visual, both
    public var title: String {
        switch self {
        case .original: return "Оригинал"
        case .visual: return "Визуалы"
        case .both: return "Оригинал + визуалы"
        }
    }
}
