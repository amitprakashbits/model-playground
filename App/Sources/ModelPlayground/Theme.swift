import AppKit
import SwiftUI

/// Warm, quiet palette in the spirit of the Claude apps, with light and dark variants.
enum Theme {
    static let background = dynamic(light: 0xFAF9F5, dark: 0x262624)
    static let sidebar = dynamic(light: 0xF3F1EA, dark: 0x1F1E1D)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x30302E)
    static let surfaceMuted = dynamic(light: 0xF0EEE6, dark: 0x1A1A18)
    static let userBubble = dynamic(light: 0xEFECE3, dark: 0x141413)
    static let border = dynamic(light: 0xE5E2D8, dark: 0x3D3D3A)
    static let text = dynamic(light: 0x141413, dark: 0xF5F4EE)
    static let secondaryText = dynamic(light: 0x6F6D66, dark: 0xA6A39A)
    static let accent = dynamic(light: 0xC96442, dark: 0xD97757)
    static let accentSoft = dynamic(light: 0xC96442, dark: 0xD97757, alpha: 0.14)
    static let codeBackground = dynamic(light: 0xF5F3EC, dark: 0x1C1C1A)

    /// Distinct, colorblind-friendly series colors for comparing models.
    static let series: [Color] = [
        dynamic(light: 0xC96442, dark: 0xE08A68),
        dynamic(light: 0x2F6FDB, dark: 0x6C9CF0),
        dynamic(light: 0x2E8B57, dark: 0x5DBB85),
        dynamic(light: 0x8A4FD3, dark: 0xB08AF0),
    ]

    static func seriesColor(_ i: Int) -> Color { series[i % series.count] }

    static let serif = Font.system(size: 15.5, design: .serif)
    static let greeting = Font.system(size: 36, weight: .regular, design: .serif)

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

struct CardStyle: ViewModifier {
    var radius: CGFloat = 14
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 14, padding: CGFloat = 14) -> some View {
        modifier(CardStyle(radius: radius, padding: padding))
    }
}

/// Pill-shaped button used throughout the app.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .background(
                Capsule().fill(prominent ? Theme.accent : Theme.surface)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .overlay(Capsule().stroke(prominent ? Color.clear : Theme.border))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}
