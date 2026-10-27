import SwiftUI

/// Dynamic Type support (v4.1): the app was designed with fixed point
/// sizes (kept as the `.large` baseline — they are already large for
/// the user's vision), but fixed sizes ignored the device text-size
/// setting. `mcFont` multiplies the designed size by the standard
/// UIFontMetrics body ratio for the current Dynamic Type size, so all
/// app text now scales with Settings ▸ Display & Brightness ▸ Text
/// Size (and the larger accessibility sizes).
enum MCTypeScale {
    /// The app's own default text scale, applied on top of the
    /// device's Dynamic Type ratio (user-tuned 2026-10-26: text should
    /// start noticeably smaller than the raw designed sizes; the
    /// device setting still multiplies from here).
    static let appTextScale: CGFloat = 0.80

    /// UIFontMetrics-for-body ratios, keyed by Dynamic Type size.
    static func ratio(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1.00
        case .xLarge: return 1.12
        case .xxLarge: return 1.24
        case .xxxLarge: return 1.35
        case .accessibility1: return 1.64
        case .accessibility2: return 1.95
        case .accessibility3: return 2.35
        case .accessibility4: return 2.76
        case .accessibility5: return 3.12
        @unknown default: return 1.00
        }
    }

    /// A designed size scaled for the given Dynamic Type size. Used
    /// where a raw `Font` value is needed (e.g. Canvas-drawn `Text`,
    /// which cannot take a view modifier).
    static func scaled(_ base: CGFloat, for size: DynamicTypeSize) -> CGFloat {
        base * appTextScale * ratio(for: size)
    }
}

/// Sets a Dynamic-Type-scaled system font: the designed `size`,
/// multiplied by the current text-size ratio at render time.
struct MCFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(.system(size: MCTypeScale.scaled(size, for: dynamicTypeSize),
                             weight: weight, design: design))
    }
}

extension View {
    /// Dynamic-Type-scaled replacement for `.font(.system(size:…))`.
    /// Base sizes are unchanged; the device text-size setting scales
    /// them via `MCTypeScale`.
    func mcFont(_ size: CGFloat, weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        modifier(MCFontModifier(size: size, weight: weight, design: design))
    }
}
