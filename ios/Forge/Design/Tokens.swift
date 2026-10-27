import SwiftUI
import UIKit

/// Design tokens. New feature views use only these and the components in `Components.swift`:
/// no hardcoded colors, fonts, spacing or radii in feature code.
/// (The existing Forge screens keep their own `Theme`; they are untouched.)
enum DS {
    // MARK: Color: neutrals + one accent per area

    enum Palette {
        /// Screen background: near-white / near-black.
        static let background = Color(light: 0xF6F6F7, dark: 0x0B0B0D)
        /// Cards: one step off the background.
        static let surface = Color(light: 0xFFFFFF, dark: 0x1A1A1D)
        /// Inputs and pressed states: one more step.
        static let raised = Color(light: 0xEDEDEF, dark: 0x26262A)
        static let primary = Color.primary
        static let secondary = Color.secondary
        /// Default accent when an area has none.
        static let accent = Color(rgb: RGB(hex: AreaPalette.fallback)!)
        // Status colors signal meaning only (done, behind, overdue).
        static let positive = Color(light: 0x2E9E6B, dark: 0x3CC48A)
        static let warning = Color(light: 0xC7861D, dark: 0xE8A23B)
        static let critical = Color(light: 0xD0473A, dark: 0xF0685A)

        /// An area's accent from `areas.color`, falling back to the kind's default.
        static func area(hex: String?, kind: String = "custom") -> Color {
            Color(rgb: RGB(hex: hex) ?? RGB(hex: AreaPalette.defaultHex(forKind: kind))!)
        }
    }

    // MARK: Spacing: 8pt grid

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: Shape

    enum Radius {
        static let card: CGFloat = 20
        static let control: CGFloat = 12
    }

    // MARK: Type: three sizes per screen (hero number, body, caption). Dynamic Type aware.

    enum Typo {
        static let hero = Font.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit()
        static let title = Font.system(.title2, design: .default, weight: .semibold)
        static let body = Font.body
        static let bodyEmphasis = Font.body.weight(.semibold)
        static let caption = Font.footnote
    }

    // MARK: Motion: short springs only

    enum Motion {
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.86)
        static let quick = Animation.spring(response: 0.25, dampingFraction: 0.9)
    }

    // MARK: Icons: SF Symbols, one weight, monochrome

    static let symbolWeight = Font.Weight.medium

    // MARK: Haptics

    @MainActor
    enum Haptics {
        static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }
}

extension Color {
    /// A color that adapts to light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            UIColor(rgbHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(rgb: RGB) {
        self = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

private extension UIColor {
    convenience init(rgbHex v: UInt32) {
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Standard screen background for new screens.
    func dsScreen() -> some View {
        background(DS.Palette.background.ignoresSafeArea())
    }

    /// Card surface: padding, one step off the background, 20pt radius, no border or shadow.
    func dsCard(padding: CGFloat = DS.Space.m) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}
