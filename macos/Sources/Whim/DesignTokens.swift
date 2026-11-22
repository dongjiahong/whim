import SwiftUI

/// Flomo-inspired calm, high-contrast macOS visual palette & typography.
/// Dark mode mirrors the deep charcoal (#141414) + elevated card (#1E1E1E) + sage forest green (#4E7D5E) aesthetic.
enum FlomoPalette {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x141414) : Color(hex: 0xF5F5F5)
    }
    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x141414) : Color(hex: 0xEFEFEF)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1E1E1E) : Color.white
    }
    static func composer(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1A1A1A) : Color.white
    }
    static func searchBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1E1E1E) : Color(hex: 0xE8E8E8)
    }
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        Color(hex: 0x4E7D5E) // flomo sage forest green
    }
    static func accentHover(_ scheme: ColorScheme) -> Color {
        Color(hex: 0x5B916D)
    }
    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xE6E6E6) : Color(hex: 0x1E1E1E)
    }
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x8A8A8A) : Color(hex: 0x707070)
    }
    static func textMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x626262) : Color(hex: 0x999999)
    }
    static func tagBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1E2A3A) : Color(hex: 0xEAF2FF)
    }
    static func tagText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x5B9BFF) : Color(hex: 0x2F6FE4)
    }
    static func heatmapCell(_ count: Int, scheme: ColorScheme) -> Color {
        if count <= 0 {
            return scheme == .dark ? Color(hex: 0x282828) : Color(hex: 0xE3E5E4)
        }
        switch count {
        case 1:
            return scheme == .dark ? Color(hex: 0x2D4636) : Color(hex: 0xC6DEC9)
        case 2:
            return scheme == .dark ? Color(hex: 0x3D634A) : Color(hex: 0x92C19B)
        case 3...4:
            return scheme == .dark ? Color(hex: 0x4E7D5E) : Color(hex: 0x639E72)
        default:
            return scheme == .dark ? Color(hex: 0x6AA57D) : Color(hex: 0x467956)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
}
