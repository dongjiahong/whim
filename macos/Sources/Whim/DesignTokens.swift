import AppKit
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
    static func cardElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x252525) : Color(hex: 0xF9F9F9)
    }
    static func hoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }
    static func activeHoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
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
    static func borderStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        Color(hex: 0x4E7D5E) // flomo sage forest green
    }
    static func accentHover(_ scheme: ColorScheme) -> Color {
        Color(hex: 0x5B916D)
    }
    static func accentSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x4E7D5E).opacity(0.18) : Color(hex: 0x4E7D5E).opacity(0.12)
    }
    static func danger(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xE06C6C) : Color(hex: 0xC93B3B)
    }
    static func warning(_ scheme: ColorScheme) -> Color {
        Color(hex: 0xE5A03D)
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

// MARK: - Full-Area Hit-Testing & Tactile macOS Button Primitives

/// Ensures the entire bounding shape is clickable (fixes SwiftUI plain-button clear-pixel hit-test bug)
/// and shows a pointing-hand cursor on hover.
struct WhimClickableSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var showHoverFill: Bool = false
    var hoverColor: Color? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(showHoverFill && isHovered ? (hoverColor ?? FlomoPalette.hoverFill(scheme)) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func whimClickable(cornerRadius: CGFloat = 8, hoverFill: Bool = false, hoverColor: Color? = nil) -> some View {
        modifier(WhimClickableSurfaceModifier(cornerRadius: cornerRadius, showHoverFill: hoverFill, hoverColor: hoverColor))
    }
}

/// Tactile button style with full-bounds hit testing and crisp press feedback.
struct WhimTactileButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var pressScale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .scaleEffect(configuration.isPressed ? pressScale : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Primary sage-green button with full-area click target and hover state.
struct WhimPrimaryButton: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var icon: String? = nil
    var compact: Bool = false
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
            }
            .foregroundColor(.white.opacity(isEnabled ? 1.0 : 0.55))
            .padding(.horizontal, compact ? 11 : 14)
            .padding(.vertical, compact ? 6 : 7.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isEnabled
                            ? (isHovered ? FlomoPalette.accentHover(scheme) : FlomoPalette.accent(scheme))
                            : FlomoPalette.accent(scheme).opacity(0.38)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 8))
        .onHover { hovering in
            isHovered = hovering
            if isEnabled {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .onDisappear {
            if isHovered { isHovered = false; NSCursor.pop() }
        }
    }
}

/// Secondary subtle surface button with full-area click target, crisp border, and hover state.
struct WhimSecondaryButton: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var icon: String? = nil
    var destructive: Bool = false
    var compact: Bool = false
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
            }
            .foregroundColor(
                destructive
                    ? FlomoPalette.danger(scheme)
                    : (isEnabled ? FlomoPalette.textPrimary(scheme) : FlomoPalette.textMuted(scheme))
            )
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 5.5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isHovered && isEnabled
                            ? FlomoPalette.activeHoverFill(scheme)
                            : FlomoPalette.cardElevated(scheme)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        destructive && isHovered
                            ? FlomoPalette.danger(scheme).opacity(0.45)
                            : FlomoPalette.border(scheme),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 8))
        .onHover { hovering in
            isHovered = hovering
            if isEnabled {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .onDisappear {
            if isHovered { isHovered = false; NSCursor.pop() }
        }
    }
}
