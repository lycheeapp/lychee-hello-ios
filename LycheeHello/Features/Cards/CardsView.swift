import SwiftUI

/// Card geometry, shared by the stack and its sheets.
enum CardGeometry {
    /// A card's full height: the front card shows all of it.
    static let height: CGFloat = 200
    /// How much of each card behind the front one shows: its header row.
    static let peek: CGFloat = 64
    /// Breathing room between the last peeking card and the front card.
    static let frontGap: CGFloat = 10
    static let corner: CGFloat = 22
}

/// Colours of a card. The balance wears the brand's navy-to-green; the user's own OnePay vouchers a
/// deep Lychee green; a voucher from someone else, or a store voucher, a colour of its own picked
/// from who it is from — so the same issuer always looks the same. Same pairs as Android.
enum CardPalette {
    private static let balance = [Color(hex: 0x0D1B2A), Color(hex: 0x0B5F35)]
    private static let own = [Color(hex: 0x0E7A43), Color(hex: 0x07402A)]
    private static let issuers: [[Color]] = [
        [Color(hex: 0xD81B60), Color(hex: 0x7B1040)], // magenta
        [Color(hex: 0x1E9E4A), Color(hex: 0x0E5C2C)], // green
        [Color(hex: 0x3A3F47), Color(hex: 0x1A1D22)], // charcoal
        [Color(hex: 0x2F6BFF), Color(hex: 0x0B3FB3)], // royal blue
        [Color(hex: 0x1EA7FF), Color(hex: 0x0A6FD1)], // sky
        [Color(hex: 0x6CC644), Color(hex: 0x2E8B2A)], // lime
        [Color(hex: 0x7F66FF), Color(hex: 0x4B2FCC)], // violet
        [Color(hex: 0xF2803C), Color(hex: 0xB8471A)], // orange
        [Color(hex: 0x02A698), Color(hex: 0x015E56)]  // teal
    ]

    static func colours(_ card: WalletCard) -> [Color] {
        if card.cardKind == .wallet { return balance }
        guard let from = card.from, !from.isEmpty else { return own }
        // Java's String.hashCode, so a card is the same colour on both platforms.
        var hash: Int32 = 0
        for unit in from.lowercased().utf16 { hash = hash &* 31 &+ Int32(unit) }
        let index = ((Int(hash) % issuers.count) + issuers.count) % issuers.count
        return issuers[index]
    }

    static func gradient(_ card: WalletCard) -> LinearGradient {
        LinearGradient(colors: colours(card), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func glow(_ card: WalletCard) -> Color { colours(card)[0] }
}

/// The Cards tab: the user's balance and vouchers as a stack, Apple Wallet style.
///
/// The chosen card sits in front, at the bottom of the stack, showing its balance; the others peek
/// out above it. Tapping one brings it to the front — it trades places with the card that was there,
/// the two sliding past each other — with a lift and a haptic tick so the choice is felt.
///
/// "Pay at a POS" opens the system NFC sheet; hold the iPhone near the POS's Tap to pay screen and
/// the payment request opens, ready to pay with the card in front.
struct CardsView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @State private var model = CardsModel(repository: HelloRepository())
    @State private var reader = PosTagReader()
    @State private var selectionTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                header
                if model.isLoading && model.wallet == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if model.wallet == nil {
                    loadError
                } else {
                    CardStack(cards: model.cards) { id in
                        selectionTick += 1
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.8)) {
                            model.select(id)
                        }
                    }
                    readerPanel
                }
            }
            .padding(.horizontal, Tokens.Spacing.lg)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: selectionTick)
        .task(id: coordinator.user?.id) { await model.start(accountKey: String(coordinator.user?.id ?? 0)) }
        .refreshable { await model.load() }
        .sheet(isPresented: Binding(get: { model.pay.isPresented }, set: { if !$0 { model.dismissPay() } })) {
            TapPaySheet(model: model, onDone: {
                if case .paid = model.pay { Task { await coordinator.refreshBalance() } }
                model.dismissPay()
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.isPaying)
        }
        .sheet(isPresented: Binding(get: { model.create != nil }, set: { if !$0 { model.closeCreate() } })) {
            CreateVoucherSheet(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("cards_title"))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(L("cards_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(Tokens.Colour.textSecondary)
            }
            Spacer()
            if model.wallet?.canCreateOnePay == true {
                Button {
                    Task { await model.openCreate() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Tokens.Colour.textOnBrand)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Tokens.Colour.brand))
                        .shadow(color: Tokens.Colour.brand.opacity(0.35), radius: 10, y: 4)
                }
                .accessibilityLabel(L("cards_add"))
            }
        }
        .padding(.top, Tokens.Spacing.sm)
    }

    private var loadError: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Text(L("cards_error_load"))
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.textPrimary)
            if let error = model.error {
                Text(error)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(L("common_try_again")) { Task { await model.load() } }
                .foregroundStyle(Tokens.Colour.brandAccessible)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// What happens next: tap Pay at a POS and hold the iPhone near it — or why it cannot.
    private var readerPanel: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            if PosTagReader.isAvailable {
                NfcPulse()
                Text(L("cards_ready_title"))
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                Text(L("cards_ready_body_ios"))
                    .font(.subheadline)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .multilineTextAlignment(.center)
                LHPrimaryButton(title: L("cards_pay_at_pos"), trailingSystemImage: "wave.3.right") {
                    Task { await readTag() }
                }
                .padding(.top, Tokens.Spacing.xs)
            } else {
                Image(systemName: "creditcard.trianglebadge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(Tokens.Colour.textSecondary)
                Text(L("cards_nfc_unsupported"))
                    .font(.subheadline)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let selected = model.selected, !selected.canPay {
                Text(L("cards_selected_cannot_pay", CardCopy.reason(selected.reason, store: selected.storeName)))
                    .font(.caption)
                    .foregroundStyle(Tokens.Colour.danger)
                    .multilineTextAlignment(.center)
            } else if model.cards.count > 1 {
                Text(L("cards_selected_hint"))
                    .font(.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Tokens.Colour.surfaceElevated))
    }

    private func readTag() async {
        do {
            let url = try await reader.read(prompt: L("tap_nfc_prompt"))
            guard url != nil else { return } // cancelled
            await model.tagRead(url)
        } catch {
            model.pay = .failed(message: L("tap_nfc_failed"), payload: nil)
        }
    }
}

extension CardsModel {
    var isPaying: Bool {
        if case let .ready(_, _, _, paying, _) = pay { return paying }
        return false
    }
}

/// The stack. Every card is placed absolutely: the ones behind one peek apart, the front one below
/// them. Offsets animate per card, so when two cards trade places each slides to the other's slot;
/// the card coming forward is drawn above everything for the whole move — it lifts out of the stack
/// rather than passing behind it.
struct CardStack: View {
    let cards: [WalletCard]
    let onSelect: (String) -> Void

    /// The card being brought forward: it grows a touch as it lifts out, then settles.
    @State private var lifted: String?

    var body: some View {
        let behind = max(cards.count - 1, 0)
        let frontTop = CGFloat(behind) * CardGeometry.peek + (behind > 0 ? CardGeometry.frontGap : 0)
        ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let front = index == cards.count - 1
                WalletCardView(card: card, expanded: front)
                    .shadow(color: CardPalette.glow(card).opacity(front ? 0.45 : 0.18),
                            radius: front ? 18 : 4, y: front ? 10 : 2)
                    .scaleEffect(lifted == card.id ? 1.04 : (front ? 1 : 0.995))
                    .offset(y: front ? frontTop : CGFloat(index) * CardGeometry.peek)
                    .zIndex(front ? 1000 : Double(index))
                    .onTapGesture { choose(card.id, front: front) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(CardCopy.accessibility(card, selected: front))
                    .accessibilityAddTraits(front ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: frontTop + CardGeometry.height, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private func choose(_ id: String, front: Bool) {
        guard !front else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { lifted = id }
        onSelect(id)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                if lifted == id { lifted = nil }
            }
        }
    }
}

/// One card: the Lychee mark, who it is from and what kind of card it is across the top — the part
/// that peeks out of the stack — and, on the front card, the balance and the details below.
struct WalletCardView: View {
    let card: WalletCard
    let expanded: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CardGeometry.corner, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(CardPalette.gradient(card))
            CardPattern(strong: expanded).clipShape(shape)
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded { details }
            }
        }
        .frame(height: CardGeometry.height)
        .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .contentShape(shape)
    }

    private var header: some View {
        HStack(spacing: 6) {
            LycheeMark(size: 30, color: .white)
            LycheeWordmark(height: 21, color: .white)
            Spacer(minLength: 10)
            if let from = card.from, !from.isEmpty {
                Text(from.bidiIsolated)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            Text(CardCopy.kind(card))
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 18)
        .frame(height: CardGeometry.peek)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            Text(L("cards_available_balance"))
                .font(.system(size: 12, weight: .semibold))
                .kerning(1.6)
                .foregroundStyle(.white.opacity(0.85))
            Text(Money.format(card.balance))
                .font(.system(size: 40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .environment(\.layoutDirection, .leftToRight)
            HStack(spacing: 10) {
                if let masked = card.codeMasked {
                    // Left to right in Arabic too: "•••• 3302", not "3302 ••••".
                    Text("\u{2066}\(masked)\u{2069}")
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                        .environment(\.layoutDirection, .leftToRight)
                }
                Text(CardCopy.detail(card))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                if !card.canPay {
                    Text(CardCopy.reason(card.reason, store: card.storeName))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.28)))
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Faint rings and a rounded lattice, so a card reads as a card and not a coloured rectangle.
private struct CardPattern: View {
    let strong: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(ellipseIn: CGRect(x: w * 0.08 - h * 0.9, y: -h * 0.35 - h * 0.9, width: h * 1.8, height: h * 1.8)),
                         with: .color(.white.opacity(0.07)))
            var lattice = context
            lattice.translateBy(x: w * 0.86, y: h * 0.82)
            lattice.rotate(by: .degrees(-18))
            for i in 1...4 {
                let side = h * 0.34 * CGFloat(i)
                let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
                lattice.stroke(Path(roundedRect: rect, cornerRadius: side * 0.22),
                               with: .color(.white.opacity(strong ? 0.10 : 0.06)), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Contactless waves breathing outwards: ready to read.
private struct NfcPulse: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Tokens.Colour.brand.opacity(animate ? 0 : 0.45), lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(animate ? 2.2 : 1)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(i) * 0.53), value: animate)
            }
            Circle().fill(Tokens.Colour.brand).frame(width: 36, height: 36)
            Image(systemName: "wave.3.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.Colour.textOnBrand)
        }
        .frame(width: 64, height: 64)
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}

/// How cards and their refusals are worded.
enum CardCopy {
    static func kind(_ card: WalletCard) -> String {
        switch card.cardKind {
        case .wallet: return L("cards_kind_balance")
        case .store: return L("cards_kind_static")
        default: return L("cards_kind_onepay")
        }
    }

    /// "Valid until 3 Mar 2027", "Only at Bravo", or the balance's title.
    static func detail(_ card: WalletCard) -> String {
        if card.cardKind == .store, let store = card.storeName, !store.isEmpty {
            return L("cards_only_at", store.bidiIsolated)
        }
        if let until = card.validUntil {
            let date = Date(timeIntervalSince1970: TimeInterval(until) / 1000)
            return L("cards_valid_until", date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.locale)))
        }
        return card.cardKind == .wallet ? (card.title ?? "") : ""
    }

    static func reason(_ reason: String?, store: String?) -> String {
        switch reason {
        case "expired": return L("cards_reason_expired")
        case "unconfirmed": return L("cards_reason_unconfirmed")
        case "wallet_not_active": return L("cards_reason_wallet_not_active")
        case "spent", "redeemed": return L("cards_reason_spent")
        case "insufficient_balance": return L("cards_reason_insufficient")
        case "currency_mismatch": return L("cards_reason_currency")
        case "other_store":
            if let store, !store.isEmpty { return L("cards_reason_other_store", store.bidiIsolated) }
            return L("cards_reason_generic")
        default: return L("cards_reason_generic")
        }
    }

    static func accessibility(_ card: WalletCard, selected: Bool) -> String {
        let name = [card.title, card.from].compactMap { $0 }.joined(separator: ", ")
        return L(selected ? "cards_a11y_selected" : "cards_a11y_card", name, Money.format(card.balance))
    }
}
