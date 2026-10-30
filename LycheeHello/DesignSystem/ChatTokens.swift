import SwiftUI

/// Chat-surface tokens — the conversation screen follows WhatsApp's layout, type scale and shapes.
///
/// Kept apart from the brand tokens on purpose: the onboarding and settings screens are brand
/// surfaces, while the conversation deliberately borrows the messaging conventions people already
/// know (wallpaper, bubble shapes, inline time and ticks, date chips). Brand green still marks the
/// things that are Lychee's own — the send button, payment confirmations and the avatar.
///
/// **Colours and type must stay identical to `Tokens.Chat` in `lychee-hello-android/.../Tokens.kt`.**
/// The deliberate platform differences each follow that platform's own WhatsApp app: the bars
/// (light grey here, white on Android) and the bubble geometry — iOS draws a rounder bubble with the
/// tail at the bottom of the *last* bubble of a run, Android a squarer one with it at the top of
/// the *first*.
extension Tokens {

    enum Chat {

        // MARK: Colour

        /// Warm beige behind the transcript. The dark values follow WhatsApp's own dark theme.
        static let wallpaper = Color(light: 0xEFEAE2, dark: 0x0B141A)
        /// Ink for the wallpaper doodles; kept faint so text never competes with it.
        static let wallpaperInk = Color(light: 0x111B3A, dark: 0xFFFFFF, lightOpacity: 0.05, darkOpacity: 0.04)

        static let bubbleOutgoing = Color(light: 0xD9FDD3, dark: 0x005C4B)
        static let bubbleIncoming = Color(light: 0xFFFFFF, dark: 0x202C33)
        /// The hairline under every bubble, standing in for a (much more expensive) shadow.
        static let bubbleShade = Color(light: 0x0B141A, dark: 0x000000, lightOpacity: 0.13, darkOpacity: 0.25)

        static let text = Color(light: 0x111B21, dark: 0xE9EDEF)
        /// Timestamps, subtitles, secondary lines.
        static let meta = Color(light: 0x667781, dark: 0x9AABB3)

        static let tickRead = Color(hex: 0x53BDEB)
        static let tickUnread = Color(hex: 0x8696A0)

        /// Tappable text inside the transcript (reply buttons, "Review payment"). 4.8:1 on white.
        static let action = Color(light: 0x027EB5, dark: 0x53BDEB)

        static let dateChip = Color(light: 0xFFFFFF, dark: 0x182229, lightOpacity: 0.94, darkOpacity: 0.94)
        static let dateChipText = Color(light: 0x54656F, dark: 0x8696A0)

        /// Pale yellow of in-thread notices ("Payment cancelled…"); amber text on dark.
        static let notice = Color(light: 0xFFF3C5, dark: 0x182229)
        static let noticeText = Color(light: 0x54656F, dark: 0xFFD279)

        /// Navigation bar, pinned bar and composer bar.
        static let bar = Color(light: 0xF6F6F6, dark: 0x1C1C1E)
        static let barHairline = Color(light: 0xD1D1D6, dark: 0x38383A)
        static let fieldBorder = Color(light: 0xD1D1D6, dark: 0x38383A)
        /// The composer's text field and the floating scroll-to-bottom button.
        static let field = Color(light: 0xFFFFFF, dark: 0x2C2C2E)

        /// "typing…", "Payment sent". Darker than the brand green so small text stays readable
        /// (5.2:1 on white, where the brand green measures 2.2:1); brighter on dark.
        static let success = Color(light: 0x0A7D3E, dark: 0x21C063)

        // MARK: Shape & spacing

        static let bubbleRadius: CGFloat = 16
        /// How far the tail reaches past the bubble edge.
        static let tailReach: CGFloat = 6
        static let bubblePaddingH: CGFloat = 10
        static let bubblePaddingV: CGFloat = 6
        /// Gap between bubbles of one run, and between runs.
        static let runSpacing: CGFloat = 2
        static let groupSpacing: CGFloat = 8
        /// Distance from the screen edge to the bubble body (the tail sits inside this).
        static let edgeInset: CGFloat = 12
        /// Minimum free space on the far side of a bubble — caps bubbles at roughly 80% width.
        static let oppositeInset: CGFloat = 56

        // MARK: Type — Dynamic Type styles, so the transcript scales with the user's setting.

        /// 17pt at the default size, the same as WhatsApp's message text.
        static let message = Font.body
        /// 11pt.
        static let metaFont = Font.caption2
        static let title = Font.headline
        static let subtitle = Font.caption
        static let chip = Font.footnote.weight(.medium)
        static let noticeFont = Font.footnote
        static let amount = Font.system(.title, design: .rounded).weight(.bold)
    }
}
