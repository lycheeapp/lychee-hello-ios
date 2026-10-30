import SwiftUI

// MARK: - Wallpaper

/// The beige chat wallpaper with a faint, original doodle pattern (lychee clusters, leaves, rings).
///
/// Drawn once into a `Canvas` that sits *behind* the scroll view rather than inside it, so it costs
/// nothing while scrolling and stays put the way a chat wallpaper should.
struct ChatWallpaper: View {

    private static let tile: CGFloat = 76

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Tokens.Chat.wallpaper))

            let ink = GraphicsContext.Shading.color(Tokens.Chat.wallpaperInk)
            let tile = Self.tile
            let columns = Int((size.width / tile).rounded(.up)) + 1
            let rows = Int((size.height / tile).rounded(.up)) + 1

            for row in 0..<rows {
                for column in 0..<columns {
                    // Alternate rows are offset by half a tile so the pattern never reads as a grid.
                    let shift: CGFloat = row.isMultiple(of: 2) ? 0 : tile / 2
                    let centre = CGPoint(x: CGFloat(column) * tile + shift, y: CGFloat(row) * tile + tile / 2)
                    Self.drawMotif((row * 7 + column * 3) % 5, at: centre, context: context, ink: ink)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func drawMotif(_ kind: Int, at c: CGPoint, context: GraphicsContext, ink: GraphicsContext.Shading) {
        switch kind {
        case 0:
            // A small lychee cluster — the brand mark's three circles.
            for (dx, dy, d) in [(3.5, -4.0, 9.0), (4.5, 5.0, 8.0), (-5.0, 2.0, 6.0)] as [(CGFloat, CGFloat, CGFloat)] {
                context.fill(Path(ellipseIn: CGRect(x: c.x + dx - d / 2, y: c.y + dy - d / 2, width: d, height: d)), with: ink)
            }
        case 1:
            context.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: ink, lineWidth: 1.4)
        case 2:
            var leaf = Path()
            leaf.move(to: CGPoint(x: c.x - 7, y: c.y + 7))
            leaf.addQuadCurve(to: CGPoint(x: c.x + 7, y: c.y - 7), control: CGPoint(x: c.x - 8, y: c.y - 8))
            leaf.addQuadCurve(to: CGPoint(x: c.x - 7, y: c.y + 7), control: CGPoint(x: c.x + 8, y: c.y + 8))
            context.fill(leaf, with: ink)
        case 3:
            for i in -1...1 {
                let x = c.x + CGFloat(i) * 6
                context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)), with: ink)
            }
        default:
            let card = CGRect(x: c.x - 7, y: c.y - 5, width: 14, height: 10)
            context.stroke(Path(roundedRect: card, cornerRadius: 2.5), with: ink, lineWidth: 1.3)
        }
    }
}

// MARK: - Header

/// Round avatar with the Lychee mark.
struct ChatAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Tokens.Colour.surfaceMuted)
            LycheeMark(size: size * 0.74)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Avatar, name and status line, left-aligned in the navigation bar as on WhatsApp.
struct ChatHeaderTitle: View {
    let isTyping: Bool

    var body: some View {
        HStack(spacing: 10) {
            ChatAvatar(size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(L("app_name"))
                    .font(Tokens.Chat.title)
                    .foregroundStyle(Tokens.Chat.text)
                Text(isTyping ? L("chat_typing") : L("chat_subtitle"))
                    .font(Tokens.Chat.subtitle)
                    .foregroundStyle(isTyping ? Tokens.Chat.success : Tokens.Chat.meta)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isTyping)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Pinned balance

/// The balance, pinned under the navigation bar the way WhatsApp pins a message.
///
/// Replaces the large balance card: the conversation gets the space back, and the figure is still
/// one glance away. A suspended wallet says so here (decision D7) — a visible balance would
/// otherwise read as spendable.
struct PinnedBalanceBar: View {
    let balance: WalletBalance?
    let isHidden: Bool
    let onToggleHidden: () -> Void

    /// Unknown until the first fetch lands; do not claim "activating" before we know.
    private var isPayable: Bool { balance?.payable ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 17))
                .foregroundStyle(Tokens.Chat.success)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(isPayable ? L("chat_balance_available") : L("chat_balance_activating"))
                    .font(.caption)
                    .foregroundStyle(isPayable ? Tokens.Chat.meta : Tokens.Colour.danger)
                Text(isHidden ? "••••" : Money.format(balance?.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Chat.text)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: balance?.amount)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(isPayable ? "" : L("error_wallet_not_active"))

            Spacer(minLength: 8)

            Button(action: onToggleHidden) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(Tokens.Chat.meta)
                    .frame(width: Tokens.Hit.minimum, height: Tokens.Hit.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isHidden ? L("chat_balance_show") : L("chat_balance_hide"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 48)
        .background(Tokens.Chat.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Chat.barHairline).frame(height: 0.5)
        }
    }
}

// MARK: - Composer

/// "+", the growing text field and the send button — WhatsApp's composer bar.
///
/// "+" holds the guided payments (WhatsApp's attachment menu), which frees the row of quick-action
/// chips that used to sit above the composer.
struct ChatComposer: View {
    @Binding var draft: String
    let focus: FocusState<Bool>.Binding
    let canSend: Bool
    let canPay: Bool
    /// What `/me` says this account may do beyond paying.
    var capabilities = Capabilities()
    let onSend: () -> Void
    let onPick: (PaymentFormSheet.Mode) -> Void
    /// Sends the WhatsApp `BALANCE` command.
    var onBalance: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Menu {
                // A suspended wallet cannot pay or withdraw, so those are disabled rather than
                // hidden; the balance and an operator's top-up do not depend on it.
                Button {
                    onPick(.balance)
                } label: {
                    Label(L("attach_pay_balance"), systemImage: "wallet.pass")
                }
                .disabled(!canPay)
                // A voucher pays for itself, so it works before the wallet is active.
                Button {
                    onPick(.voucher)
                } label: {
                    Label(L("attach_voucher"), systemImage: "ticket")
                }
                Button(action: onBalance) {
                    Label(L("attach_check_balance"), systemImage: "banknote")
                }
                if capabilities.withdraw {
                    Button {
                        onPick(.withdraw)
                    } label: {
                        Label(L("form_title_withdraw"), systemImage: "building.columns")
                    }
                    .disabled(!canPay)
                }
                if capabilities.topUp {
                    Button {
                        onPick(.topUp)
                    } label: {
                        Label(L("form_title_top_up"), systemImage: "arrow.up.circle")
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Tokens.Chat.action)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L("chat_attach"))

            TextField(L("chat_composer_placeholder"), text: $draft, axis: .vertical)
                .font(Tokens.Chat.message)
                .foregroundStyle(Tokens.Chat.text)
                .tint(Tokens.Colour.brandAccessible)
                .lineLimit(1...6)
                .focused(focus)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Tokens.Chat.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Tokens.Chat.fieldBorder, lineWidth: 0.5)
                )
                .accessibilityLabel(L("chat_composer_placeholder"))

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Colour.textOnBrand)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Tokens.Colour.brand))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)
            .scaleEffect(canSend ? 1 : 0.9)
            .animation(.snappy(duration: 0.18), value: canSend)
            .accessibilityLabel(L("chat_send"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Tokens.Chat.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Chat.barHairline).frame(height: 0.5)
        }
    }
}

// MARK: - Scroll to latest

struct ScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Chat.meta)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Tokens.Chat.field)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                )
                .frame(width: Tokens.Hit.minimum, height: Tokens.Hit.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("chat_scroll_latest"))
    }
}
