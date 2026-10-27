import SwiftUI
import UIKit

/// The user's accent color: ONE stored hex drives all of the app's
/// brand/selection chrome — active buttons, action-bar outlines,
/// selection highlights, the selected-sketch glow, measure markers,
/// and the draft-preview tint. Picked in Home ▸ Settings; the whole
/// app recolors immediately because every surface reads the same
/// `@AppStorage` key.
///
/// NOT accent (never reads this): part MATERIAL colors, and the
/// semantic colors — error red and warning orange keep their meaning.
enum MCAccent {
    /// The @AppStorage / UserDefaults key used everywhere.
    static let key = "accentColorHex"
    /// The orange the app shipped with (system orange) — the default
    /// until the user picks something else.
    static let defaultHex = "#FF9500"

    /// Large tappable swatches offered in Settings.
    static let swatches: [(name: String, hex: String)] = [
        ("Orange", "#FF9500"),
        ("Blue", "#0A84FF"),
        ("Teal", "#40C8E0"),
        ("Green", "#30D158"),
        ("Purple", "#BF5AF2"),
        ("Pink", "#FF375F"),
        ("Red", "#FF453A"),
        ("Yellow", "#FFD60A"),
    ]

    static func color(hex: String) -> Color {
        Color(uiColor: uiColor(hex: hex))
    }

    static func uiColor(hex: String) -> UIColor {
        UIColor(mcHex: hex) ?? .systemOrange
    }

    /// "#RRGGBB" for a color coming back from the free ColorPicker.
    static func hexString(from color: Color) -> String {
        let ci = CIColor(cgColor: UIColor(color).cgColor)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(ci.red), byte(ci.green), byte(ci.blue))
    }
}

extension UIColor {
    /// "#RRGGBB" (or bare "RRGGBB") parser; nil for anything else.
    convenience init?(mcHex: String) {
        var s = mcHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
