import SwiftUI
import UIKit

@available(iOS 16.0, *)
enum MoonAccent {
    private static func raspberry() -> UIColor {
        UIColor(red: 169.0 / 255.0, green: 9.0 / 255.0, blue: 65.0 / 255.0, alpha: 1)
    }

    static var control: Color { Color(uiColor: self.raspberry()) }

    // The dark fill works behind white switch thumbs. Text uses a lighter tint on dark surfaces.
    static var text: Color {
        Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 255.0 / 255.0, green: 125.0 / 255.0, blue: 173.0 / 255.0, alpha: 1)
            }
            return Self.raspberry()
        })
    }
}

@available(iOS 16.0, *)
struct MoonActionDock<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        self.content()
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
    }
}

@available(iOS 16.0, *)
extension View {
    func moonBottomAction(_ title: String, busy: Bool, action: @escaping () -> Void) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            MoonActionDock {
                Button(action: action) {
                    Text(busy ? "Сохраняю…" : title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(MoonAccent.control)
                .disabled(busy)
            }
        }
    }
}

@available(iOS 16.0, *)
struct MoonSettingsBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shifted = false

    var body: some View {
        Label {
            Text("Оформление MoonGram")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "moon.stars.fill").font(.title3).accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Color(uiColor: UIColor(red: 63 / 255, green: 8 / 255, blue: 32 / 255, alpha: 1)),
                             MoonAccent.control, Color(uiColor: UIColor(red: 101 / 255, green: 6 / 255, blue: 43 / 255, alpha: 1))],
                    startPoint: self.shifted ? .topTrailing : .topLeading,
                    endPoint: self.shifted ? .bottomLeading : .bottomTrailing
                ))
        }
        .task(id: self.reduceMotion) {
            self.shifted = false
            guard !self.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                self.shifted = true
            }
        }
    }
}
