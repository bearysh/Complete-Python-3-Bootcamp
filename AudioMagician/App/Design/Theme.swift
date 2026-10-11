import SwiftUI

/// Audio Magician's palette: a deep twilight base with luminous accents.
/// Dark-first by design; every surface sits on the animated aura.
enum Theme {
    static let ink = Color(hex: 0x0D0A1A)
    static let dusk = Color(hex: 0x1A1433)
    static let plum = Color(hex: 0x3B2A6B)
    static let lumen = Color(hex: 0xFFC27A)   // warm amber: primary actions, highlights
    static let aurora = Color(hex: 0x5EE6D0)  // teal: success, "just right"
    static let orchid = Color(hex: 0xC59BFF)  // violet: measuring, magic moments
    static let coral = Color(hex: 0xFF8A7A)   // soft warning
    static let mist = Color(hex: 0xB9B3D6)    // secondary text
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)

    enum Mood {
        case calm, listening, measuring, success, attention

        var colors: [Color] {
            switch self {
            case .calm: [Theme.ink, Theme.dusk, Theme.plum, Color(hex: 0x24395E)]
            case .listening: [Theme.ink, Color(hex: 0x153B44), Theme.dusk, Color(hex: 0x1E5A5A)]
            case .measuring: [Theme.ink, Theme.plum, Color(hex: 0x5B2E7A), Theme.dusk]
            case .success: [Theme.ink, Color(hex: 0x15403A), Color(hex: 0x3D3A1E), Theme.dusk]
            case .attention: [Theme.ink, Color(hex: 0x4A2230), Theme.dusk, Theme.plum]
            }
        }

        var accent: Color {
            switch self {
            case .calm: Theme.lumen
            case .listening: Theme.aurora
            case .measuring: Theme.orchid
            case .success: Theme.aurora
            case .attention: Theme.coral
            }
        }
    }

    static func color(for severity: Int) -> Color {
        switch severity {
        case 2: coral
        case 1: lumen
        default: aurora
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Font {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static let headlineRounded = Font.system(.title3, design: .rounded, weight: .semibold)
    static let bodySoft = Font.system(.body, design: .default)
    static let caption2Rounded = Font.system(.caption, design: .rounded, weight: .medium)
}
