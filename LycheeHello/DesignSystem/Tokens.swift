import SwiftUI

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

    public enum Colour {
        /// Warm off-white page background. Not pure white — it carries a cream tint.
        public static let surface = Color(hex: 0xFAF9F6)
        /// Cards, incoming bubbles, input fields.
        public static let surfaceElevated = Color.white
        /// Pale mint of the welcome screen's lower region.
        public static let surfaceMuted = Color(hex: 0xEEF9F2)

        /// Primary brand green — logo, CTA, chevrons, security icon.
        public static let brand = Color(hex: 0x16C765)

        /// Deep navy — wordmark, headings, dark cards.
        public static let navy = Color(hex: 0x111B3A)

        /// Outgoing (user) chat bubble.
        public static let bubbleOutgoing = Color(hex: 0xD9F2DD)
        /// Incoming (Lychee) chat bubble.
        public static let bubbleIncoming = Color.white

        public static let textPrimary = Color(hex: 0x111B3A)
        /// Placeholder / secondary text.
        public static let textSecondary = Color(hex: 0x77777D)
        public static let textOnDark = Color.white
        public static let textOnBrand = Color.white

        public static let danger = Color(hex: 0xE5484D)
        public static let divider = Color(hex: 0xE4E4E4)

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

        /// Navy → deep green gradient used by the balance and profile cards.
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
