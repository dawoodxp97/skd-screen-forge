import SwiftUI

enum Theme {
    static let background = Color(hex: 0x08090C)
    static let backgroundRaised = Color(hex: 0x11131A)
    static let panel = Color(hex: 0x151821)
    static let panelElevated = Color(hex: 0x1B1F2A)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.14)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.38)
    static let accent = Color(hex: 0x7C5CFF)
    static let accentSecondary = Color(hex: 0xFF6B9D)
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFFB340)
    static let danger = Color(hex: 0xFF453A)

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x7C5CFF), Color(hex: 0xFF6B9D)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let backgroundGradient = LinearGradient(
        colors: [Color(hex: 0x0B0D14), Color(hex: 0x08090C)],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    init(hexString: String) {
        let rgba = ColorHex.parse(hexString)
        self.init(
            .sRGB,
            red: Double(rgba.0),
            green: Double(rgba.1),
            blue: Double(rgba.2),
            opacity: Double(rgba.3)
        )
    }
}

private struct PanelModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func panel(padding: CGFloat = 18, radius: CGFloat = 18) -> some View {
        modifier(PanelModifier(padding: padding, radius: radius))
    }

    func card(padding: CGFloat = 14, radius: CGFloat = 14) -> some View {
        modifier(PanelModifier(padding: padding, radius: radius))
    }

    func sectionLabel() -> some View {
        font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? color.opacity(0.75) : color)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}
