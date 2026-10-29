import SwiftUI

/// Full-width primary call to action.
///
/// Label is optically centred while the arrow sits against the right edge with generous padding,
/// matching the reference. A plain `HStack` would centre the pair together and push the label left
/// of centre, so the two are layered instead.
///
/// See `Tokens.Colour.brandAccessible` for the measured contrast note on white-on-green.
struct LHPrimaryButton: View {
    let title: String
    var trailingSystemImage: String?
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(Tokens.Colour.textOnBrand)
                } else {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Tokens.Colour.textOnBrand)

                    if let trailingSystemImage {
                        HStack {
                            Spacer()
                            Image(systemName: trailingSystemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Tokens.Colour.textOnBrand)
                        }
                        .padding(.trailing, Tokens.Spacing.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // Reference button height ≈ 128/1844 → ~60pt, slightly shorter than the field above it.
            .frame(height: 60)
            .background(isEnabled ? Tokens.Colour.brand : Tokens.Colour.brand.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Tokens.Colour.brand.opacity(isEnabled ? 0.26 : 0), radius: 16, x: 0, y: 8)
        }
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        // A spinner alone tells VoiceOver nothing.
        .accessibilityValue(isLoading ? "Working" : "")
    }
}

/// Balance card on the chat header — navy→green gradient with a reveal toggle.
struct LHBalanceCard: View {
    let amount: Double?
    let isHidden: Bool
    let isPayable: Bool
    let onToggleHidden: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Available balance")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textOnDark.opacity(0.75))
                    Text(isHidden ? "••••" : Money.format(amount))
                        .font(Tokens.Typography.amount)
                        .foregroundStyle(Tokens.Colour.textOnDark)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button(action: onToggleHidden) {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.system(size: 20))
                        .foregroundStyle(Tokens.Colour.textOnDark)
                        .frame(width: Tokens.Hit.minimum, height: Tokens.Hit.minimum)
                }
                .accessibilityLabel(isHidden ? "Show balance" : "Hide balance")
            }

            // Surfaced here because a user seeing a balance will otherwise assume they can spend it
            // (decision D7).
            if !isPayable {
                Text("Your wallet is being activated. Payments will be available once your wallet is active.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textOnDark.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Colour.cardGradient)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }
}

/// A chat bubble. Incoming is white and left-aligned; outgoing is mint and right-aligned.
struct LHChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isFromUser { Spacer(minLength: 48) }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: Tokens.Spacing.xs) {
                Text(message.body ?? "")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                    .padding(.horizontal, Tokens.Spacing.lg)
                    .padding(.vertical, Tokens.Spacing.md)
                    .background(message.isFromUser
                                ? Tokens.Colour.bubbleOutgoing
                                : Tokens.Colour.bubbleIncoming)
                    .clipShape(bubbleShape)

                HStack(spacing: Tokens.Spacing.xs) {
                    Text(timestamp)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                    if message.isFromUser {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Tokens.Colour.brand)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.xs)
            }

            if !message.isFromUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.isFromUser ? "You said" : "Lychee said"): \(message.body ?? "")")
    }

    /// Asymmetric corner marks the speaker, as in the screenshot.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Tokens.Radius.bubble,
            bottomLeadingRadius: message.isFromUser ? Tokens.Radius.bubble : Tokens.Radius.bubbleTail,
            bottomTrailingRadius: message.isFromUser ? Tokens.Radius.bubbleTail : Tokens.Radius.bubble,
            topTrailingRadius: Tokens.Radius.bubble,
            style: .continuous
        )
    }

    private var timestamp: String {
        guard let sentAt = message.sentAt else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: sentAt)
    }
}

/// The in-thread payment review card.
///
/// Renders only server-computed figures — the client never derives a total.
struct LHPaymentReviewCard: View {
    let intent: PaymentIntent
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            if let masked = intent.voucherCodeMasked {
                row(label: "Voucher", value: masked)
                Divider().background(Tokens.Colour.divider)
            } else if let recipient = intent.recipientDisplay ?? intent.recipientCode {
                row(label: "To", value: recipient)
                Divider().background(Tokens.Colour.divider)
            }

            HStack {
                Text("Amount")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                Spacer()
                Text(Money.format(intent.amount))
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Colour.textPrimary)
            }

            // Only shown when non-zero — a "₪0 fee" line is noise.
            if let fee = intent.feeAmount, fee > 0 {
                HStack {
                    Text("Fee")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                    Spacer()
                    Text(Money.format(fee))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                }
            }

            LHPrimaryButton(title: "Review payment", isEnabled: intent.status == .pending, action: onReview)
        }
        .padding(Tokens.Spacing.lg)
        .background(Tokens.Colour.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .stroke(Tokens.Colour.divider, lineWidth: 1)
        )
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
            Spacer()
            Text(value)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textPrimary)
        }
    }
}

/// Quick-action chip — "Pay from balance", "Use a voucher".
struct LHQuickActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(Tokens.Colour.brand)
                Text(title)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Colour.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Tokens.Hit.minimum)
            .background(Tokens.Colour.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.pill))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.pill)
                    .stroke(Tokens.Colour.divider, lineWidth: 1)
            )
        }
        .accessibilityLabel(title)
    }
}
