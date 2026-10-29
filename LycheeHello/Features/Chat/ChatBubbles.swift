import SwiftUI
import UIKit

// MARK: - Shape

enum BubbleTail: Equatable {
    case none
    /// Lychee's side.
    case leading
    /// The user's side.
    case trailing
}

/// A rounded bubble whose bottom corner can curl out into a tail, as on WhatsApp for iOS.
///
/// The tail is drawn *outside* the bubble's rect, into the gutter `BubbleRow` reserves, so bubbles
/// with and without a tail keep identical text frames and a run of messages lines up exactly.
struct BubbleShape: Shape {

    var tail: BubbleTail
    var radius: CGFloat = Tokens.Chat.bubbleRadius
    var reach: CGFloat = Tokens.Chat.tailReach

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        // How far up the side the tail starts to curl.
        let rise = min(r, 11)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)

        if tail == .trailing {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rise))
            path.addCurve(to: CGPoint(x: rect.maxX + reach, y: rect.maxY),
                          control1: CGPoint(x: rect.maxX, y: rect.maxY - 3),
                          control2: CGPoint(x: rect.maxX + reach * 0.4, y: rect.maxY - 0.5))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        }

        if tail == .leading {
            path.addLine(to: CGPoint(x: rect.minX - reach, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - rise),
                          control1: CGPoint(x: rect.minX - reach * 0.4, y: rect.maxY - 0.5),
                          control2: CGPoint(x: rect.minX, y: rect.maxY - 3))
        } else {
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Bubble fill plus the hairline beneath it.
///
/// The hairline is a second fill offset by under a point rather than a `.shadow`: a real shadow on
/// every bubble forces an offscreen pass per row, which is what makes long transcripts stutter.
struct BubbleBackground: ViewModifier {
    let fromUser: Bool
    let tail: BubbleTail

    func body(content: Content) -> some View {
        content.background {
            let shape = BubbleShape(tail: tail)
            shape
                .fill(fromUser ? Tokens.Chat.bubbleOutgoing : Tokens.Chat.bubbleIncoming)
                .background(shape.fill(Tokens.Chat.bubbleShade).offset(y: 0.75))
        }
    }
}

/// Places a bubble on its side, capping it at roughly 80% of the width.
struct BubbleRow<Content: View>: View {
    let fromUser: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            if fromUser { Spacer(minLength: Tokens.Chat.oppositeInset) }
            content
            if !fromUser { Spacer(minLength: Tokens.Chat.oppositeInset) }
        }
        .padding(.horizontal, Tokens.Chat.edgeInset)
    }
}

// MARK: - Time & ticks

struct TicksView: View {
    let ticks: DeliveryTicks

    var body: some View {
        switch ticks {
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Tokens.Chat.tickUnread)
                .accessibilityLabel("Sending")
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.Chat.tickUnread)
                .accessibilityLabel("Sent")
        case .read:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark").offset(x: 4.5)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Tokens.Chat.tickRead)
            .padding(.trailing, 4.5)
            .accessibilityLabel("Read")
        case .failed:
            // The red button beside the bubble carries the failure; repeating it here is noise.
            EmptyView()
        }
    }
}

/// "14:05 ✓✓" in the bubble's bottom corner.
struct MessageMeta: View {
    let time: String
    var ticks: DeliveryTicks?

    var body: some View {
        HStack(spacing: 3) {
            Text(time)
                .font(Tokens.Chat.metaFont)
                .monospacedDigit()
                .foregroundStyle(Tokens.Chat.meta)
            if let ticks {
                TicksView(ticks: ticks)
            }
        }
        .fixedSize()
    }
}

/// Message text with the time tucked into the bubble's corner.
///
/// When text and time fit on one line they share it, as on WhatsApp; otherwise the time drops to
/// its own line at the trailing edge. That rule (rather than measuring the width of the last
/// wrapped line) holds for Arabic as well, where the free end of the last line is on the left.
struct InlineMetaText: View {
    let text: Text
    let isRightToLeft: Bool
    let meta: MessageMeta

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                text.fixedSize()
                meta
            }
            VStack(alignment: .trailing, spacing: 1) {
                text
                    .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
                meta
            }
        }
    }
}

// MARK: - Bubbles

/// Plain text — the user's messages and Lychee's replies, including errors.
struct TextBubble: View {
    let message: ChatMessage
    let time: String
    let ticks: DeliveryTicks?
    let tail: BubbleTail
    /// Stretch to the row's width — used when reply buttons hang underneath.
    var fillsWidth = false

    var body: some View {
        InlineMetaText(
            text: styledText,
            isRightToLeft: message.isRightToLeft,
            meta: MessageMeta(time: time, ticks: ticks)
        )
        .padding(.horizontal, Tokens.Chat.bubblePaddingH)
        .padding(.vertical, Tokens.Chat.bubblePaddingV)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .modifier(BubbleBackground(fromUser: message.isFromUser, tail: tail))
        .contentShape(.contextMenuPreview, BubbleShape(tail: tail))
        .contextMenu {
            if let body = message.body, !body.isEmpty {
                Button {
                    UIPasteboard.general.string = body
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var styledText: Text {
        let body = Text(message.body ?? "")
        let composed: Text
        if message.type == .error {
            composed = Text(Image(systemName: "exclamationmark.circle.fill"))
                .foregroundStyle(Tokens.Colour.danger)
                + Text(" ")
                + body
        } else {
            composed = body
        }
        return composed
            .font(Tokens.Chat.message)
            .foregroundStyle(Tokens.Chat.text)
    }

    private var accessibilityText: String {
        let speaker = message.isFromUser ? "You" : "Lychee"
        var status = ""
        switch ticks {
        case .pending?: status = ", sending"
        case .sent?:    status = ", sent"
        case .read?:    status = ", read"
        case .failed?:  status = ", not sent"
        case nil:       status = ""
        }
        return "\(speaker): \(message.body ?? ""), \(time)\(status)"
    }
}

/// A payment waiting for the user — WhatsApp's payment-message layout: label, large amount,
/// recipient, then a full-width action under a hairline.
///
/// Every figure is the server's; nothing here adds a fee to an amount.
struct PaymentRequestBubble: View {
    let intent: PaymentIntent
    let time: String
    let tail: BubbleTail
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Payment ready to review", systemImage: "creditcard.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Chat.meta)

                Text(Money.format(intent.totalAmount ?? intent.amount))
                    .font(Tokens.Chat.amount)
                    .foregroundStyle(Tokens.Chat.text)
                    .padding(.top, 2)

                if let recipient = intent.recipientDisplay ?? intent.recipientCode {
                    Text("to \(recipient)")
                        .font(.subheadline)
                        .foregroundStyle(Tokens.Chat.text)
                }
                if let masked = intent.voucherCodeMasked {
                    Text("Voucher \(masked)")
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let fee = intent.feeAmount, fee > 0 {
                    Text("\(Money.format(intent.amount)) + \(Money.format(fee)) fee")
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }

                HStack {
                    Spacer(minLength: 0)
                    MessageMeta(time: time)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Rectangle()
                .fill(Tokens.Chat.barHairline)
                .frame(height: 0.5)

            Button(action: onReview) {
                Text("Review payment")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Tokens.Chat.action)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Hit.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 272)
        .modifier(BubbleBackground(fromUser: false, tail: tail))
        .accessibilityElement(children: .contain)
    }
}

/// A review card whose payment has moved on — the receipt or notice below says how it ended.
struct ClosedPaymentRequestBubble: View {
    let time: String
    let tail: BubbleTail

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Label("Payment review closed", systemImage: "creditcard")
                .font(.subheadline)
                .foregroundStyle(Tokens.Chat.meta)
            MessageMeta(time: time)
        }
        .padding(.horizontal, Tokens.Chat.bubblePaddingH)
        .padding(.vertical, 8)
        .modifier(BubbleBackground(fromUser: false, tail: tail))
    }
}

/// The settled-payment receipt, rendered from the payload the server wrote at settlement.
///
/// The reference is selectable and copyable — it is the first thing support asks for.
struct PaymentReceiptBubble: View {
    let message: ChatMessage
    let time: String
    let tail: BubbleTail

    var body: some View {
        let fields = message.payloadFields
        let reference = fields["txnReference"].flatMap { $0.isEmpty ? nil : $0 }

        VStack(alignment: .leading, spacing: 3) {
            Label("Payment sent", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tokens.Chat.success)

            if fields.isEmpty {
                // Unreadable payload: the body is always written alongside it.
                Text(message.body ?? "")
                    .font(Tokens.Chat.message)
                    .foregroundStyle(Tokens.Chat.text)
            } else {
                Text(Money.format(Double(fields["totalAmount"] ?? fields["amount"] ?? "")))
                    .font(Tokens.Chat.amount)
                    .foregroundStyle(Tokens.Chat.text)
                    .padding(.top, 2)

                if let recipient = fields["recipientDisplay"], !recipient.isEmpty {
                    Text("to \(recipient)")
                        .font(.subheadline)
                        .foregroundStyle(Tokens.Chat.text)
                }
                if let voucher = fields["voucherCodeMasked"], !voucher.isEmpty {
                    Text("Voucher \(voucher)")
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let fee = Double(fields["feeAmount"] ?? ""), fee > 0 {
                    Text("\(Money.format(Double(fields["amount"] ?? ""))) + \(Money.format(fee)) fee")
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                if let reference {
                    Text("Ref \(reference)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(Tokens.Chat.meta)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                MessageMeta(time: time)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: 272, alignment: .leading)
        .modifier(BubbleBackground(fromUser: false, tail: tail))
        .contentShape(.contextMenuPreview, BubbleShape(tail: tail))
        .contextMenu {
            if let reference {
                Button {
                    UIPasteboard.general.string = reference
                } label: {
                    Label("Copy reference", systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reply buttons hanging under a bubble, as on WhatsApp business messages.
struct ReplyButtons: View {
    let titles: [String]
    let isEnabled: (String) -> Bool
    let onTap: (String) -> Void

    var body: some View {
        VStack(spacing: Tokens.Chat.runSpacing) {
            ForEach(titles, id: \.self) { title in
                let enabled = isEnabled(title)
                Button {
                    onTap(title)
                } label: {
                    Label(title, systemImage: "arrowshape.turn.up.left")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Tokens.Chat.action)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Hit.minimum)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                            shape
                                .fill(Tokens.Chat.bubbleIncoming)
                                .background(shape.fill(Tokens.Chat.bubbleShade).offset(y: 0.75))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }
        }
    }
}

// MARK: - Chips & notices

/// "Today" / "Yesterday" chip between days.
struct DayChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Tokens.Chat.chip)
            .foregroundStyle(Tokens.Chat.dateChipText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tokens.Chat.dateChip)
                    .shadow(color: Tokens.Chat.bubbleShade, radius: 0.5, y: 0.5)
            }
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Centred yellow notice — cancellations, expiries, the wallet-activation notice.
struct NoticePill: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    init(_ string: String) {
        self.text = Text(string)
    }

    var body: some View {
        text
            .font(Tokens.Chat.noticeFont)
            .foregroundStyle(Tokens.Chat.noticeText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tokens.Chat.notice)
            )
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity)
    }
}

/// The red "!" beside a message that did not send. Tapping resends with the same client id, so
/// a send that actually reached the server is not duplicated.
struct RetryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Tokens.Colour.danger)
                .frame(width: 32, height: Tokens.Hit.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Not sent. Tap to retry")
    }
}
