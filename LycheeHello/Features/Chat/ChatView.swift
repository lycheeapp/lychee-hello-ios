import SwiftUI

/// General Chat — screenshot 3.
///
/// Deviations from the screenshot, per D5:
/// - navigation uses a standard `NavigationStack` bar so back-swipe and Dynamic Type work;
/// - the composer sits above the keyboard via safe-area insets rather than a fixed offset;
/// - every icon button gets a ≥44pt target.
struct ChatView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @State private var model = ChatModel(repository: HelloRepository())
    @State private var balanceHidden = false
    @State private var showVoucherForm = false
    @State private var showBalanceForm = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            Tokens.Colour.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                balanceCard
                transcript
                quickActions
                composer
            }
        }
        .navigationTitle("Lychee Hello")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneToolbar()
        .task { await model.load() }
        // Realtime hints arrive via the coordinator; the chat never talks to SSE directly.
        .onChange(of: coordinator.chatInvalidationToken) { _, _ in
            Task { await model.refresh() }
        }
        .sheet(item: $model.pendingIntent) { intent in
            PaymentReviewSheet(intent: intent) {
                // Clearing the binding is what dismisses an `.sheet(item:)` — deterministic, and
                // it does not depend on the environment's dismiss action resolving correctly.
                model.closePaymentSheet()
                Task { await model.refresh(); await coordinator.refreshBalance() }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showVoucherForm) {
            PaymentFormSheet(mode: .voucher) { payee, voucher, amount in
                Task { await model.sendPaymentForm(payee: payee, voucherCode: voucher, amount: amount) }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBalanceForm) {
            PaymentFormSheet(mode: .balance) { payee, _, amount in
                Task { await model.sendPaymentForm(payee: payee, voucherCode: nil, amount: amount) }
            }
            .presentationDetents([.medium])
        }
        .alert("Something went wrong",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var balanceCard: some View {
        LHBalanceCard(
            amount: coordinator.balance?.amount,
            isHidden: balanceHidden,
            isPayable: coordinator.canPay,
            onToggleHidden: { balanceHidden.toggle() }
        )
        .padding(.horizontal, Tokens.Spacing.gutter)
        .padding(.vertical, Tokens.Spacing.md)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Tokens.Spacing.md) {
                    if model.isLoading && model.messages.isEmpty {
                        ProgressView().padding(.top, Tokens.Spacing.xxl)
                    }
                    if !model.isLoading && model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        messageRow(message).id(message.id)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.gutter)
                .padding(.vertical, Tokens.Spacing.md)
            }
            // Swiping the transcript closes the keyboard — the gesture people reach for in a
            // messaging app.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.type {
        case .paymentReview:
            // Rendered from the authoritative intent, matched by public id — never from the
            // message payload, which is display text only.
            //
            // `resumableIntent` is what makes a backed-out payment recoverable: it survives an app
            // restart, so the card reappears in the transcript and can be tapped to re-open the
            // sheet. Previously this only checked `pendingIntent`, which is nil after dismissal,
            // leaving the intent blocking new payments with no way to reach it.
            if let intent = model.resumableIntent, intent.id == message.paymentIntentId {
                LHPaymentReviewCard(intent: intent) { model.resumePendingPayment() }
            } else {
                // Settled, cancelled or expired — the receipt or notice below carries the outcome.
                LHChatBubble(message: message)
            }

        case .paymentReceipt:
            LHPaymentReceiptCard(message: message)
        case .system, .error:
            noticeRow(message)
        default:
            LHChatBubble(message: message)
        }
    }

    private func noticeRow(_ message: ChatMessage) -> some View {
        Text(message.body ?? "")
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Colour.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(Tokens.Spacing.md)
            .background(Tokens.Colour.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.field))
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.md) {
            LycheeMark(size: 48)
            Text("Hi \(coordinator.user?.firstName ?? "there") 👋")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Colour.textPrimary)
            Text("Send a payment as \"payee amount\", or use a quick action below.")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Tokens.Spacing.xxl)
        .padding(.horizontal, Tokens.Spacing.xl)
    }

    private var quickActions: some View {
        HStack(spacing: Tokens.Spacing.md) {
            LHQuickActionChip(title: "Pay from balance", systemImage: "wallet.pass") {
                showBalanceForm = true
            }
            LHQuickActionChip(title: "Use a voucher", systemImage: "tag") {
                showVoucherForm = true
            }
        }
        .padding(.horizontal, Tokens.Spacing.gutter)
        .padding(.bottom, Tokens.Spacing.sm)
        // A suspended wallet cannot pay; disabling avoids leading the user into a dead end.
        .disabled(!coordinator.canPay)
        .opacity(coordinator.canPay ? 1 : 0.5)
    }

    private var composer: some View {
        HStack(spacing: Tokens.Spacing.md) {
            TextField("Type a message", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .font(Tokens.Typography.body)
                .focused($composerFocused)
                .padding(.horizontal, Tokens.Spacing.lg)
                .padding(.vertical, Tokens.Spacing.md)
                .background(Tokens.Colour.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.pill))
                .accessibilityLabel("Message")

            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(Tokens.Colour.textOnBrand)
                    .frame(width: Tokens.Hit.minimum, height: Tokens.Hit.minimum)
                    .background(model.canSend ? Tokens.Colour.brand : Tokens.Colour.brand.opacity(0.4))
                    .clipShape(Circle())
            }
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Tokens.Spacing.gutter)
        .padding(.vertical, Tokens.Spacing.md)
        .background(Tokens.Colour.surface)
    }
}

/// The in-thread receipt for a settled payment.
///
/// This is the user's permanent record and the reference support will ask for, so the transaction
/// id is selectable rather than merely displayed.
struct LHPaymentReceiptCard: View {

    let message: ChatMessage

    private var payload: [String: String] {
        guard let raw = message.payload?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return [:]
        }
        var flat: [String: String] = [:]
        for (key, value) in object {
            if let value = value as? String { flat[key] = value }
            else if let value = value as? NSNumber { flat[key] = value.stringValue }
        }
        return flat
    }

    var body: some View {
        let fields = payload
        return VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tokens.Colour.brand)
                Text("Payment complete")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Colour.textPrimary)
            }

            Divider().background(Tokens.Colour.divider)

            if let recipient = fields["recipientDisplay"], !recipient.isEmpty {
                row("To", recipient)
            }
            if let voucher = fields["voucherCodeMasked"], !voucher.isEmpty {
                row("Voucher", voucher)
            }
            row("Amount", Money.format(Double(fields["totalAmount"] ?? fields["amount"] ?? "")))

            if let reference = fields["txnReference"], !reference.isEmpty {
                HStack {
                    Text("Reference")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                    Spacer()
                    Text(reference)
                        .font(Tokens.Typography.caption.monospaced())
                        .foregroundStyle(Tokens.Colour.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Tokens.Spacing.lg)
        .background(Tokens.Colour.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .stroke(Tokens.Colour.brand.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
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

/// Structured payment form for both quick actions.
///
/// One view with a mode rather than two near-identical sheets: the only difference is whether a
/// voucher field appears, and duplicating the payee/amount handling is how the two would drift.
/// Either way the server composes the canonical command, so both share the free-text grammar.
struct PaymentFormSheet: View {

    enum Mode {
        case balance
        case voucher

        var title: String {
            switch self {
            case .balance: return "Pay from balance"
            case .voucher: return "Use a voucher"
            }
        }

        var needsVoucher: Bool { self == .voucher }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var payee = ""
    @State private var voucherCode = ""
    @State private var amountText = ""

    let mode: Mode
    let onSubmit: (String, String?, Double) -> Void

    /// Voucher codes are 6 characters (decision U1).
    private let voucherLength = 6

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: ".")) }

    private var canSubmit: Bool {
        let hasPayee = !payee.trimmingCharacters(in: .whitespaces).isEmpty
        let hasVoucher = !mode.needsVoucher || voucherCode.count == voucherLength
        return hasPayee && hasVoucher && (amount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pay to") {
                    TextField("Payee code or phone number", text: $payee)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                if mode.needsVoucher {
                    Section("Voucher") {
                        TextField("\(voucherLength)-character code", text: $voucherCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onChange(of: voucherCode) { _, value in
                                voucherCode = String(value.prefix(voucherLength))
                            }
                    }
                }
                Section("Amount") {
                    HStack {
                        Text(Money.symbol).foregroundStyle(Tokens.Colour.textSecondary)
                        TextField("0", text: $amountText).keyboardType(.decimalPad)
                    }
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            // The amount field uses decimalPad — no return key, so it needs an explicit escape.
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        if let amount {
                            onSubmit(
                                payee.trimmingCharacters(in: .whitespaces),
                                mode.needsVoucher ? voucherCode : nil,
                                amount
                            )
                        }
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}
