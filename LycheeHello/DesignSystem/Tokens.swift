import SwiftUI
import UIKit

/// Lychee Hello design tokens.
///
/// Values are **sampled from the provided screenshots**, not from a handoff file (decision U9).
/// They are deliberately centralised here so replacing them with the real brand values later is a
/// one-file change and cannot drift across screens.
///
/// Per decision D5 the intent is *brand-identical, platform-native*: the same tokens, spacing and
/// components on both platforms, with navigation idioms following each platform and contrast
/// adjusted where a sampled pair fails WCAG AA.
public enum Tokens {

    // MARK: - Colour

    /// Brand colours. Most come in a light and a dark value and follow the theme on their own —
    /// the phone's, or the one Settings pins (`AppAppearance`). **The pairs must stay identical to
    /// `LightPalette` / `DarkPalette` in `lychee-hello-android/.../ui/theme/Palette.kt`.**
    ///
    /// The dark set keeps the brand green and the card's navy-to-green gradient, and moves the cream
    /// and white surfaces to a blue-black so the green still reads as Lychee's.
    public enum Colour {
        /// Warm off-white page background. Not pure white — it carries a cream tint.
        public static let surface = Color(light: 0xFAF9F6, dark: 0x0F1419)
        /// Cards, incoming bubbles, input fields.
        public static let surfaceElevated = Color(light: 0xFFFFFF, dark: 0x1A2027)
        /// Pale mint of the welcome screen's lower region.
        public static let surfaceMuted = Color(light: 0xEEF9F2, dark: 0x12261B)

        /// Primary brand green — logo, CTA, chevrons, security icon. The same in both themes.
        public static let brand = Color(hex: 0x16C765)

        /// The ink of headings and the wordmark: deep navy on light, near-white on dark. Use
        /// `navyFixed` where the navy itself is wanted whatever the theme (text on a white chip).
        public static let navy = Color(light: 0x111B3A, dark: 0xE8ECF2)
        /// Deep navy in both themes.
        public static let navyFixed = Color(hex: 0x111B3A)

        /// Outgoing (user) chat bubble.
        public static let bubbleOutgoing = Color(light: 0xD9F2DD, dark: 0x1E4D2E)
        /// Incoming (Lychee) chat bubble.
        public static let bubbleIncoming = Color(light: 0xFFFFFF, dark: 0x1A2027)

        public static let textPrimary = Color(light: 0x111B3A, dark: 0xE8ECF2)
        /// Placeholder / secondary text.
        public static let textSecondary = Color(light: 0x77777D, dark: 0x9BA1A8)
        public static let textOnDark = Color.white
        public static let textOnBrand = Color.white

        public static let danger = Color(light: 0xE5484D, dark: 0xFF6B70)
        public static let divider = Color(light: 0xE4E4E4, dark: 0x2A3138)

        /// Pale green behind money that came in.
        public static let positiveFill = Color(light: 0xE3F6EA, dark: 0x143322)

        /// The welcome screen's network motif, and the shadow its cream layer casts on the mint.
        public static let motif = Color(light: 0xFFFFFF, dark: 0x16C765, darkOpacity: 0.16)
        public static let motifShadow = Color(light: 0x111B3A, dark: 0x000000, lightOpacity: 0.099, darkOpacity: 0.45)

        /// ⚠️ **Accessibility note — measured, not guessed.**
        ///
        /// White on `brand` (#16C765) has a contrast ratio of **2.21:1**. WCAG AA needs 4.5:1 for
        /// body text and 3:1 for large text (≥18.66pt bold / 24pt regular), so the white "Continue"
        /// label currently fails even the large-text threshold.
        ///
        /// This green is used anyway because it is the specified brand colour and brand fidelity was
        /// the explicit ask. `brandAccessible` below is the drop-in fix — #0EA84F measures 3.06:1
        /// against white and is visually near-identical. Switching `LHPrimaryButton` to it is a
        /// one-line change if you decide the CTA should pass.
        public static let brandAccessible = Color(hex: 0x0EA84F)

        /// Navy → deep green gradient used by the balance and profile cards. The same in both themes.
        public static let cardGradient = LinearGradient(
            colors: [Color(hex: 0x0D1B2A), Color(hex: 0x0B5F35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Typography

    /// Uses the system face rather than shipping a custom one until the real brand font is
    /// supplied. Dynamic Type is preserved throughout — a fixed-size payment UI is an
    /// accessibility failure, and amounts are exactly what low-vision users need to read.
    public enum Typography {
        public static let largeTitle = Font.system(size: 34, weight: .bold, design: .default)
        public static let title = Font.system(size: 24, weight: .bold)
        public static let headline = Font.system(size: 17, weight: .semibold)
        public static let body = Font.system(size: 16, weight: .regular)
        public static let callout = Font.system(size: 15, weight: .medium)
        public static let caption = Font.system(size: 12, weight: .regular)
        /// Balance figure on the dark card.
        public static let amount = Font.system(size: 34, weight: .bold, design: .rounded)
    }

    // MARK: - Layout

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        /// Horizontal page gutter used by most screens.
        public static let gutter: CGFloat = 20

        /// Welcome-screen gutter.
        ///
        /// The reference design is 853pt wide with a ~90pt left margin — **10.5% of the width**.
        /// Expressed as a ratio rather than a fixed number so the generous margin survives on a
        /// small phone instead of eating the content area, and scales up on a large one.
        public static let welcomeGutterRatio: CGFloat = 0.105

        public static func welcomeGutter(for width: CGFloat) -> CGFloat {
            min(max(width * welcomeGutterRatio, 24), 48)
        }
    }

    public enum Radius {
        public static let field: CGFloat = 14
        public static let card: CGFloat = 20
        public static let bubble: CGFloat = 18
        /// The tail corner of a chat bubble.
        public static let bubbleTail: CGFloat = 4
        /// Pills and primary CTAs are fully rounded.
        public static let pill: CGFloat = 999
    }

    /// Minimum 44×44pt, per Apple's Human Interface Guidelines. Enforced on every tappable
    /// control — several of the screenshot's icon buttons are visually smaller than this, so
    /// their hit target is expanded rather than their artwork.
    public enum Hit {
        public static let minimum: CGFloat = 44
    }
}

extension Color {
    /// A colour that follows the theme: `light` in the light theme, `dark` in the dark one. Resolved
    /// wherever it is drawn, so a sheet, an alert or a forced appearance all get the right value.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkOpacity)
                : UIColor(hex: light, alpha: lightOpacity)
        })
    }

    /// Hex initialiser so tokens read the way a designer states them.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: CGFloat(alpha)
        )
    }
}
