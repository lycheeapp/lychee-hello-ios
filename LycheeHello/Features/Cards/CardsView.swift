import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

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
                } else if model.cards.isEmpty {
                    emptyState
                } else {
                    CardStack(cards: model.cards) { id in
                        selectionTick += 1
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.8)) {
                            model.select(id)
                        }
                    }
                    // Everyone with cards pays a POS by tapping — a guest with the vouchers sent to them.
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

    /// No cards: an account with no Lychee balance (no Lychee account) and no vouchers yet.
    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "ticket")
                .font(.system(size: 40))
                .foregroundStyle(Tokens.Colour.brand)
            Text(L("cards_empty_title"))
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.textPrimary)
            Text(L("cards_empty_body"))
                .font(.subheadline)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.Spacing.xl)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Tokens.Colour.surfaceElevated))
        .padding(.top, Tokens.Spacing.lg)
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
            } else if model.selected?.hasQRCode == true {
                Text(L("cards_qr_hint"))
                    .font(.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
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
///
/// Tapping the card in front turns it over when it is a voucher: its back is the voucher's QR code
/// and full code, for the store to scan. Tapping again turns it back. Choosing another card turns
/// the front one back first, so the stack is never left showing a code.
struct CardStack: View {
    let cards: [WalletCard]
    let onSelect: (String) -> Void

    /// The card being brought forward: it grows a touch as it lifts out, then settles.
    @State private var lifted: String?
    /// The front card, turned to show its QR code.
    @State private var flipped: String?
    @State private var flipTick = 0

    var body: some View {
        let behind = max(cards.count - 1, 0)
        let frontTop = CGFloat(behind) * CardGeometry.peek + (behind > 0 ? CardGeometry.frontGap : 0)
        ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let front = index == cards.count - 1
                let showsQR = front && flipped == card.id
                WalletCardView(card: card, expanded: front)
                    .modifier(CardFlip(angle: showsQR ? 180 : 0, back: VoucherQRBack(card: card, live: front)))
                    .shadow(color: CardPalette.glow(card).opacity(front ? 0.45 : 0.18),
                            radius: front ? 18 : 4, y: front ? 10 : 2)
                    .scaleEffect(lifted == card.id ? 1.04 : (front ? 1 : 0.995))
                    .offset(y: front ? frontTop : CGFloat(index) * CardGeometry.peek)
                    .zIndex(front ? 1000 : Double(index))
                    .onTapGesture { tap(card, front: front) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(showsQR ? L("cards_qr_a11y", card.code ?? "") : CardCopy.accessibility(card, selected: front))
                    .accessibilityAddTraits(front ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(front && card.hasQRCode ? L(showsQR ? "cards_qr_hide" : "cards_qr_show") : "")
            }
        }
        .frame(height: frontTop + CardGeometry.height, alignment: .top)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: flipTick)
        // The card in front changed (a refresh, another card chosen): show its face.
        .onChange(of: cards.last?.id) { _, _ in flipped = nil }
    }

    private func tap(_ card: WalletCard, front: Bool) {
        guard front else {
            choose(card.id)
            return
        }
        guard card.hasQRCode else { return }
        flipTick += 1
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
            flipped = flipped == card.id ? nil : card.id
        }
    }

    private func choose(_ id: String) {
        flipped = nil
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

extension WalletCard {
    /// A voucher with a code — OnePay or a store's — can be paid by scanning it, so it turns over to
    /// a QR code. The balance has no code.
    var hasQRCode: Bool {
        guard cardKind == .onePay || cardKind == .store else { return false }
        return !(code ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Turns a card over around its vertical axis. Animatable, so the face swaps exactly when the card
/// is edge-on (90°) — not by cross-fading two faces through the whole turn.
private struct CardFlip<Back: View>: ViewModifier, Animatable {
    var angle: Double
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let showingBack = angle > 90
        ZStack {
            content
                .opacity(showingBack ? 0 : 1)
            back
                // Pre-turned, so it reads the right way round once the card is over.
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(showingBack ? 1 : 0)
                .allowsHitTesting(showingBack)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
    }
}

/// The back of a voucher: its QR code — the bare code, as on the voucher card sent by WhatsApp — and
/// the code written out, so the store can scan it or type it.
struct VoucherQRBack: View {
    let card: WalletCard
    /// Only the front card can turn over; the ones behind skip making a QR code nobody will see.
    var live = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CardGeometry.corner, style: .continuous)
        ZStack {
            shape.fill(CardPalette.gradient(card))
            HStack(spacing: 16) {
                Group {
                    if live, card.hasQRCode, let image = QRCodeImages.image(for: card.code ?? "") {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "qrcode").font(.system(size: 60))
                    }
                }
                .padding(10)
                .frame(width: 150, height: 150)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("cards_qr_title"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(L("cards_qr_body"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // Left to right in Arabic too.
                    Text("\u{2066}\(QRCodeImages.spaced(card.code ?? ""))\u{2069}")
                        .font(.system(size: 16, weight: .semibold).monospaced())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(Money.format(card.balance))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(18)
        }
        .frame(height: CardGeometry.height)
        .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .contentShape(shape)
    }
}

/// QR codes for voucher codes, made once each: the flip redraws the back on every frame.
@MainActor
enum QRCodeImages {
    private static var cache: [String: UIImage] = [:]
    private static let context = CIContext()

    static func image(for text: String) -> UIImage? {
        let code = text.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return nil }
        if let cached = cache[code] { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Whole-number scale and no smoothing: crisp modules a scanner reads at any size.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache[code] = image
        return image
    }

    /// "AB12CD34" → "AB12 CD34": easier to read out and type.
    static func spaced(_ code: String) -> String {
        var out = ""
        for (index, character) in code.enumerated() {
            if index > 0 && index % 4 == 0 { out.append(" ") }
            out.append(character)
        }
        return out
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
                Spacer(minLength: 0)
                if card.hasQRCode {
                    // Says the card turns over to its QR code; the whole card is the button.
                    Image(systemName: "qrcode")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.18)))
                        .accessibilityHidden(true)
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
