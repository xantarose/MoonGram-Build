import MoonGramCore
import SwiftUI
import UIKit

/// The full Telegram target supplies its native renderer. The portable UI knows no Telegram entities.
@available(iOS 16.0, *)
@MainActor
public protocol MoonNativeGiftProvider: AnyObject {
    func artwork(for gift: MoonGift) -> UIView
    func editor(for gift: MoonGift, completion: @escaping (MoonGift) -> Void) -> AnyView
}

@available(iOS 16.0, *)
struct MoonNativeArtwork: UIViewRepresentable {
    let provider: MoonNativeGiftProvider
    let gift: MoonGift
    func makeUIView(context: Context) -> UIView { self.provider.artwork(for: self.gift) }
    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityLabel = "\(self.gift.title), модель \(self.gift.modelName), оформление MoonGram"
    }
}
