import Foundation
import ImageIO
import MoonGramCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@available(iOS 16.0, *)
struct MoonSharedStyleView: View {
    let profile: MoonProfile?
    var nativeGifts: MoonNativeGiftProvider? = nil

    var body: some View {
        ScrollView {
            if let profile = self.profile {
                VStack(spacing: 20) {
                    Image(systemName: "moon.circle.fill").font(.system(size: 76)).foregroundStyle(.tint).accessibilityHidden(true)
                    HStack {
                        Text(profile.displayName.isEmpty ? "Оформление" : profile.displayName).font(.largeTitle.bold())
                        if profile.localPremium { Image(systemName: "star.fill").foregroundStyle(.tint).accessibilityLabel("Визуальный Premium") }
                    }.multilineTextAlignment(.center)
                    ForEach(Array(profile.usernames.enumerated()), id: \.offset) { _, username in
                        Text("@\(username.trimmingCharacters(in: CharacterSet(charactersIn: "@")))").foregroundStyle(.secondary)
                    }
                    ForEach(Array(profile.collectibleNumbers.enumerated()), id: \.offset) { _, number in
                        Text(number).font(.body.monospaced()).textSelection(.enabled)
                    }
                    if let stars = profile.stars { self.balance(title: "Stars · оформление", value: "\(stars)", symbol: "star.fill") }
                    if let balance = profile.walletBalance { self.balance(title: "Кошелёк · оформление", value: "\(balance.text) \(profile.walletCurrency)", symbol: "wallet.pass") }
                    if !profile.gifts.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 14) {
                            ForEach(profile.gifts) { gift in
                                VStack(alignment: .leading, spacing: 8) {
                                    MoonGiftArtwork(gift: gift, nativeGifts: self.nativeGifts).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(gift.title).font(.headline)
                                    Text("#\(gift.number)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Оформление MoonGram").font(.footnote).foregroundStyle(.secondary)
                }.padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz").font(.largeTitle).accessibilityHidden(true)
                    Text("Оформление скрыто").font(.title2.bold())
                    Text("Включите визуалы или импортируйте оформление этого друга в настройках MoonGram.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.padding(24)
            }
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("Оформление друга").navigationBarTitleDisplayMode(.inline)
    }

    private func balance(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

@available(iOS 16.0, *)
struct MoonGiftArtwork: View {
    let gift: MoonGift
    var nativeGifts: MoonNativeGiftProvider? = nil

    var body: some View {
        if self.gift.telegram != nil {
            if let provider = self.nativeGifts {
                MoonNativeArtwork(provider: provider, gift: self.gift).id(self.gift.telegram)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "gift").accessibilityHidden(true)
                    Text("Ресурсы Telegram доступны в полном клиенте").font(.caption).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .secondarySystemGroupedBackground))
            }
        } else {
            self.customArtwork
        }
    }

    private var customArtwork: some View {
        ZStack {
            Color(moonHex: self.gift.backdrop)
            if self.gift.pattern != .none {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    VStack {
                        ForEach(0..<4, id: \.self) { _ in
                            HStack {
                                ForEach(0..<4, id: \.self) { _ in
                                    Image(systemName: self.gift.pattern.symbol).font(.system(size: max(7, side * 0.07)))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    }.foregroundStyle(Color(moonHex: self.gift.symbolColor).opacity(0.15)).padding(6)
                }
            }
            GeometryReader { geometry in
                Group {
                    if let data = self.gift.artwork, let image = MoonRaster.thumbnail(data) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: self.gift.model.symbol).resizable().scaledToFit().foregroundStyle(Color(moonHex: self.gift.symbolColor))
                    }
                }.padding(min(geometry.size.width, geometry.size.height) * 0.25)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(self.gift.title), модель \(self.gift.modelName), узор \(self.gift.pattern.title)")
    }
}

extension Color {
    init(moonHex: String) {
        let value = UInt32(moonHex, radix: 16) ?? 0x14334C
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    var moonHex: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

enum MoonRaster {
    static func thumbnail(_ data: Data) -> UIImage? {
        guard data.count <= 8_388_608,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, width.intValue <= 8192, height.intValue <= 8192,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func normalized(_ data: Data) throws -> Data {
        guard let image = self.thumbnail(data) else { throw MoonError.invalid("PNG или JPEG до 8192×8192") }
        for quality in [0.85, 0.65, 0.45, 0.25] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= 131_072 { return data }
        }
        throw MoonError.tooLarge
    }
}

struct MoonDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= MoonArchive.maximumBytes else { throw MoonError.tooLarge }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: self.data) }
}

func moonReadFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size = size, size <= maximumBytes else { throw MoonError.tooLarge }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumBytes else { throw MoonError.tooLarge }
    return data
}
