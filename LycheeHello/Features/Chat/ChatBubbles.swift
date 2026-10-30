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
                .accessibilityLabel(L("chat_tick_sending"))
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.Chat.tickUnread)
                .accessibilityLabel(L("chat_tick_sent"))
        case .read:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark").offset(x: 4.5)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Tokens.Chat.tickRead)
            .padding(.trailing, 4.5)
            .accessibilityLabel(L("chat_tick_read"))
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
                    Label(L("common_copy"), systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var styledText: Text {
        // Lychee's replies are WhatsApp's replies, which use WhatsApp's *bold* and _italic_.
        let body = WhatsAppFormatting.text(message.body ?? "")
        let composed: Text
        if message.type == .error {
            // Interpolated rather than added together: `Text + Text` is deprecated in the iOS 26 SDK.
            let icon: Text = Text(Image(systemName: "exclamationmark.circle.fill"))
                .foregroundStyle(Tokens.Colour.danger)
            composed = Text("\(icon) \(body)")
        } else {
            composed = body
        }
        return composed
            .font(Tokens.Chat.message)
            .foregroundStyle(Tokens.Chat.text)
    }

    private var accessibilityText: String {
        let speaker = message.isFromUser ? L("chat_a11y_you") : L("chat_a11y_lychee")
        var status = ""
        switch ticks {
        case .pending?: status = ", " + L("chat_a11y_sending")
        case .sent?:    status = ", " + L("chat_a11y_sent")
        case .read?:    status = ", " + L("chat_a11y_read")
        case .failed?:  status = ", " + L("chat_a11y_not_sent")
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
                Label(PaymentCopy.readyLabel(intent.paymentKind), systemImage: PaymentCopy.icon(intent.paymentKind))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Chat.meta)

                Text(Money.format(intent.totalAmount ?? intent.amount))
                    .font(Tokens.Chat.amount)
                    .foregroundStyle(Tokens.Chat.text)
                    .padding(.top, 2)

                if intent.paymentKind == .withdrawal {
                    if let bank = intent.recipientDisplay ?? intent.recipientCode {
                        Text(L("payment_to", bank.bidiIsolated))
                            .font(.subheadline)
                            .foregroundStyle(Tokens.Chat.text)
                    }
                } else if let name = intent.recipientDisplay ?? intent.recipientCode {
                    RecipientName(
                        name: name,
                        summary: intent.recipientDisplay != nil ? intent.recipientSummary : nil,
                        verified: intent.isMerchantRecipient
                    )
                }
                if intent.paymentKind == .withdrawal, let iban = intent.recipientCode, intent.recipientDisplay != nil {
                    Text(L("payment_iban", iban.bidiIsolated))
                        .font(.footnote.monospaced())
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let masked = intent.voucherCodeMasked {
                    Text(L("payment_voucher", masked.bidiIsolated))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let fee = intent.feeAmount, fee > 0 {
                    Text(L("payment_plus_fee", Money.format(intent.amount), Money.format(fee)))
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
                Text(PaymentCopy.reviewAction(intent.paymentKind))
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

/// A review card whose payment has moved on. It says how it ended — paid (with the amount, the
/// payee and the reference), cancelled, expired — from the payment as it stands now, which the
/// server sends with the card.
struct ClosedPaymentRequestBubble: View {
    let intent: PaymentIntent?
    let time: String
    let tail: BubbleTail

    var body: some View {
        if let intent, let outcome = Outcome(intent) {
            VStack(alignment: .leading, spacing: 3) {
                Label(outcome.label, systemImage: outcome.icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(outcome.colour)

                Text(Money.format(intent.paymentKind == .withdrawal
                                  ? intent.amount : (intent.totalAmount ?? intent.amount)))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(intent.status == .executed ? Tokens.Chat.text : Tokens.Chat.meta)
                    .strikethrough(intent.status == .cancelled || intent.status == .expired)

                if let name = intent.recipientDisplay ?? intent.recipientCode {
                    Text(L("payment_to", name.bidiIsolated))
                        .font(.subheadline)
                        .foregroundStyle(Tokens.Chat.text)
                        .lineLimit(1)
                }

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    if intent.status == .executed, let reference = intent.txnReference {
                        Text(L("payment_ref", reference))
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
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Label(L("payment_review_closed"), systemImage: "creditcard")
                    .font(.subheadline)
                    .foregroundStyle(Tokens.Chat.meta)
                MessageMeta(time: time)
            }
            .padding(.horizontal, Tokens.Chat.bubblePaddingH)
            .padding(.vertical, 8)
            .modifier(BubbleBackground(fromUser: false, tail: tail))
        }
    }

    /// How a payment ended, as the card says it. `nil`: nothing to say beyond "closed".
    private struct Outcome {
        let label: String
        let icon: String
        let colour: Color

        init?(_ intent: PaymentIntent) {
            switch intent.status {
            case .executed:
                switch intent.paymentKind {
                case .withdrawal: label = L("payment_withdrawal_requested")
                case .topUp: label = L("payment_top_up_sent")
                default: label = L("payment_paid")
                }
                icon = "checkmark.circle.fill"
                colour = Tokens.Chat.success
            case .confirmed:
                label = L("payment_processing")
                icon = "hourglass"
                colour = Tokens.Chat.meta
            case .cancelled:
                label = L("payment_cancelled")
                icon = "xmark.circle"
                colour = Tokens.Chat.meta
            case .expired:
                label = L("payment_review_expired")
                icon = "clock.badge.xmark"
                colour = Tokens.Chat.meta
            default:
                return nil
            }
        }
    }
}

/// A payee's name with what kind of payee it is under it — "Rio Taxi ✓" / "Taxi · RIO1" — so the
/// payer can check they are paying who they meant to.
struct RecipientName: View {
    let name: String
    var summary: String?
    var verified = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(L("payment_to", name.bidiIsolated))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Chat.text)
                    .lineLimit(1)
                if verified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.Colour.brand)
                        .accessibilityLabel(L("payee_verified"))
                }
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Chat.meta)
                    .lineLimit(1)
            }
        }
    }
}

/// The settled-payment receipt, rendered from the payload the server wrote at settlement.
///
/// The reference is selectable and copyable — it is the first thing support asks for.
struct PaymentReceiptBubble: View {
    let message: ChatMessage
    let time: String
    let tail: BubbleTail
    /// Pays the same payee again; nil hides the button.
    var onPayAgain: ((PayeeRef) -> Void)? = nil

    var body: some View {
        let fields = message.payloadFields
        let reference = fields["txnReference"].flatMap { $0.isEmpty ? nil : $0 }
        let kind = PaymentKind(raw: fields["kind"])

        VStack(alignment: .leading, spacing: 3) {
            Label(PaymentCopy.doneLabel(kind, stage: fields["stage"]), systemImage: "checkmark.circle.fill")
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
                    if kind == .withdrawal {
                        Text(L("payment_to", recipient.bidiIsolated))
                            .font(.subheadline)
                            .foregroundStyle(Tokens.Chat.text)
                    } else {
                        RecipientName(
                            name: recipient,
                            summary: PaymentRecipient.summary(
                                type: fields["recipientType"], category: fields["recipientCategory"],
                                code: fields["recipientCode"]),
                            verified: PaymentRecipient.isMerchant(fields["recipientType"])
                        )
                    }
                }
                if let voucher = fields["voucherCodeMasked"], !voucher.isEmpty {
                    Text(L("payment_voucher", voucher.bidiIsolated))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let fee = Double(fields["feeAmount"] ?? ""), fee > 0 {
                    Text(L("payment_plus_fee", Money.format(Double(fields["amount"] ?? "")), Money.format(fee)))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if kind == .withdrawal, let iban = fields["recipientCode"], !iban.isEmpty {
                    Text(L("payment_iban", iban.bidiIsolated))
                        .font(.footnote.monospaced())
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let balance = Double(fields["newBalance"] ?? "") {
                    Text(L("payment_new_balance", Money.format(balance)))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                if let left = Double(fields["voucherRemaining"] ?? "") {
                    Text(L("payment_voucher_left", Money.format(left)))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
                // A withdrawal's message says when the money will arrive — worth keeping in view.
                if kind == .withdrawal, let body = message.body, !body.isEmpty {
                    WhatsAppFormatting.text(body)
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.text)
                        .padding(.top, 4)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                if let reference {
                    Text(L("payment_ref", reference))
                        .font(.footnote.monospaced())
                        .foregroundStyle(Tokens.Chat.meta)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                MessageMeta(time: time)
            }
            .padding(.top, 2)

            // WhatsApp's button under a payment message: the same payee again, amount filled in.
            if let onPayAgain, let payee = PayeeRef(receipt: fields) {
                Divider()
                    .padding(.horizontal, -12)
                    .padding(.top, 4)
                Button {
                    onPayAgain(payee)
                } label: {
                    Label(L("payment_pay_again"), systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.Chat.action)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
                    Label(L("review_copy_reference"), systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Money that arrived from someone else — WhatsApp's "you received a payment", as a card.
struct PaymentReceivedBubble: View {
    let message: ChatMessage
    let time: String
    let tail: BubbleTail

    var body: some View {
        let fields = message.payloadFields

        VStack(alignment: .leading, spacing: 3) {
            Label(L("payment_received"), systemImage: "arrow.down.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tokens.Chat.success)

            if let amount = Double(fields["amount"] ?? "") {
                Text(Money.format(amount))
                    .font(Tokens.Chat.amount)
                    .foregroundStyle(Tokens.Chat.text)
                    .padding(.top, 2)
                if let from = fields["fromDisplay"], !from.isEmpty {
                    Text(L("payment_from", from.bidiIsolated))
                        .font(.subheadline)
                        .foregroundStyle(Tokens.Chat.text)
                }
                if let balance = Double(fields["newBalance"] ?? "") {
                    Text(L("payment_new_balance", Money.format(balance)))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Chat.meta)
                }
            } else {
                // Unreadable payload: the body is always written alongside it.
                WhatsAppFormatting.text(message.body ?? "")
                    .font(Tokens.Chat.message)
                    .foregroundStyle(Tokens.Chat.text)
            }

            HStack {
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
        .accessibilityElement(children: .combine)
    }
}

/// How the payment cards name each kind of payment.
enum PaymentCopy {
    static func readyLabel(_ kind: PaymentKind) -> String {
        switch kind {
        case .withdrawal: return L("payment_ready_withdrawal")
        case .topUp: return L("payment_ready_top_up")
        default: return L("payment_ready")
        }
    }

    static func reviewAction(_ kind: PaymentKind) -> String {
        switch kind {
        case .withdrawal: return L("payment_review_withdrawal")
        case .topUp: return L("payment_review_top_up")
        default: return L("payment_review")
        }
    }

    static func doneLabel(_ kind: PaymentKind, stage: String?) -> String {
        switch kind {
        case .withdrawal: return stage == "COMPLETED" ? L("payment_withdrawal_complete") : L("payment_withdrawal_requested")
        case .topUp: return L("payment_top_up_sent")
        case .tap: return L("payment_paid_at_pos")
        default: return L("payment_sent")
        }
    }

    static func icon(_ kind: PaymentKind) -> String {
        switch kind {
        case .withdrawal: return "building.columns.fill"
        case .topUp: return "arrow.up.circle.fill"
        case .tap: return "wave.3.right.circle.fill"
        default: return "creditcard.fill"
        }
    }
}

/// WhatsApp's inline formatting — `*bold*`, `_italic_`, `~strikethrough~`, ` ```monospace``` ` —
/// which Lychee's replies use because they are the WhatsApp replies.
///
/// WhatsApp's rules: a marker opens after a space, punctuation or the start of the line and before a
/// non-space; it closes after a non-space and before a space, punctuation or the end; a style never
/// spans lines. A doubled marker (`**bold**`) counts as one. Anything that does not form a pair is
/// shown as typed, so `****1234` stays a masked number.
enum WhatsAppFormatting {

    struct Style: OptionSet, Hashable {
        let rawValue: Int
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let strike = Style(rawValue: 4)
        static let mono = Style(rawValue: 8)
    }

    struct Run: Equatable {
        let text: String
        let style: Style
    }

    private static let markers: [Character: Style] = ["*": .bold, "_": .italic, "~": .strike]

    /// The styled text, ready for a bubble. Built as one `AttributedString` rather than by adding
    /// `Text`s together, which the iOS 26 SDK deprecates; the presentation intents are the ones
    /// SwiftUI already draws for Markdown, so they follow the bubble's font.
    static func text(_ source: String) -> Text {
        Text(attributed(source))
    }

    static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        for run in runs(source) {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.strike) { intent.insert(.strikethrough) }
            if run.style.contains(.mono) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            result.append(piece)
        }
        return result
    }

    /// The source split into styled runs. Separate from `text` so it can be tested.
    static func runs(_ source: String) -> [Run] {
        var runs: [Run] = []
        parse(Array(source), style: [], into: &runs)
        return runs
    }

    private static func parse(_ chars: [Character], style: Style, into runs: inout [Run]) {
        var buffer = ""
        var i = 0
        func flush() {
            if !buffer.isEmpty {
                runs.append(Run(text: buffer, style: style))
                buffer = ""
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "`", let close = monospaceEnd(chars, from: i) {
                flush()
                runs.append(Run(text: String(chars[(i + 3)..<close]), style: style.union(.mono)))
                i = close + 3
                continue
            }
            if let markerStyle = markers[c] {
                let width = markerWidth(chars, at: i, marker: c)
                if width > 0, let close = closingIndex(chars, marker: c, width: width, from: i + width) {
                    flush()
                    parse(Array(chars[(i + width)..<close]), style: style.union(markerStyle), into: &runs)
                    i = close + width
                    continue
                }
            }
            buffer.append(c)
            i += 1
        }
        flush()
    }

    /// 1 or 2 when a marker opens here, 0 when it does not.
    private static func markerWidth(_ chars: [Character], at i: Int, marker: Character) -> Int {
        guard isBoundary(i > 0 ? chars[i - 1] : nil) else { return 0 }
        let width = (i + 1 < chars.count && chars[i + 1] == marker) ? 2 : 1
        let after = i + width
        guard after < chars.count, chars[after] != marker, !chars[after].isWhitespace else { return 0 }
        return width
    }

    private static func closingIndex(_ chars: [Character], marker: Character, width: Int, from start: Int) -> Int? {
        var j = start + 1
        while j + width <= chars.count {
            if chars[j] == "\n" { return nil }
            let matches = (0..<width).allSatisfy { chars[j + $0] == marker }
            if matches, chars[j - 1] != marker, !chars[j - 1].isWhitespace,
               isBoundary(j + width < chars.count ? chars[j + width] : nil) {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func monospaceEnd(_ chars: [Character], from i: Int) -> Int? {
        guard i + 2 < chars.count, chars[i + 1] == "`", chars[i + 2] == "`" else { return nil }
        var j = i + 4
        while j + 2 < chars.count {
            if chars[j] == "`", chars[j + 1] == "`", chars[j + 2] == "`" { return j }
            j += 1
        }
        return nil
    }

    private static func isBoundary(_ c: Character?) -> Bool {
        guard let c else { return true }
        return c.isWhitespace || c.isPunctuation || c.isSymbol
    }
}

/// Reply buttons hanging under a bubble, as on WhatsApp business messages.
struct ReplyButtons: View {
    let replies: [QuickReply]
    let isEnabled: (QuickReply) -> Bool
    let onTap: (QuickReply) -> Void

    var body: some View {
        VStack(spacing: Tokens.Chat.runSpacing) {
            ForEach(replies, id: \.self) { reply in
                let enabled = isEnabled(reply)
                Button {
                    onTap(reply)
                } label: {
                    Label(reply.title, systemImage: "arrowshape.turn.up.left")
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
        .accessibilityLabel(L("chat_retry"))
    }
}
