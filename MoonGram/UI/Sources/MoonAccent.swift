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
