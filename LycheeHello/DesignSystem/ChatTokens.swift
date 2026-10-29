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

        /// Warm beige behind the transcript.
        static let wallpaper = Color(hex: 0xEFEAE2)
        /// Ink for the wallpaper doodles; kept faint so text never competes with it.
        static let wallpaperInk = Color(hex: 0x111B3A).opacity(0.05)

        static let bubbleOutgoing = Color(hex: 0xD9FDD3)
        static let bubbleIncoming = Color.white
        /// The hairline under every bubble, standing in for a (much more expensive) shadow.
        static let bubbleShade = Color(hex: 0x0B141A).opacity(0.13)

        static let text = Color(hex: 0x111B21)
        /// Timestamps, subtitles, secondary lines.
        static let meta = Color(hex: 0x667781)

        static let tickRead = Color(hex: 0x53BDEB)
        static let tickUnread = Color(hex: 0x8696A0)

        /// Tappable text inside the transcript (reply buttons, "Review payment"). 4.8:1 on white.
        static let action = Color(hex: 0x027EB5)

        static let dateChip = Color.white.opacity(0.94)
        static let dateChipText = Color(hex: 0x54656F)

        /// Pale yellow of in-thread notices ("Payment cancelled…").
        static let notice = Color(hex: 0xFFF3C5)
        static let noticeText = Color(hex: 0x54656F)

        /// Navigation bar, pinned bar and composer bar.
        static let bar = Color(hex: 0xF6F6F6)
        static let barHairline = Color(hex: 0xD1D1D6)
        static let fieldBorder = Color(hex: 0xD1D1D6)

        /// "typing…", "Payment sent". Darker than the brand green so small text stays readable
        /// (5.2:1 on white, where the brand green measures 2.2:1).
        static let success = Color(hex: 0x0A7D3E)

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
