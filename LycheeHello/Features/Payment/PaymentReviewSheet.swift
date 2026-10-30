import SwiftUI
import Observation
import UIKit

/// Review → authorise → result.
///
/// Rules this screen exists to enforce:
/// - **The server decides the outcome.** The client never renders success from a local guess; it
///   renders `intent.status` as returned by confirm.
/// - **The idempotency key is generated once per user intent to pay**, not per attempt. That is
///   what makes a retry after a dropped response safe rather than a double charge.
/// - A `PAYMENT_INTENT_EXPIRED` or `NOT_ACTIONABLE` failure is terminal — no retry button, because
///   retrying cannot succeed.
@Observable
@MainActor
final class PaymentReviewModel {

    enum Phase: Equatable {
        case review
        case authorising
        case settling
        case succeeded(PaymentIntent)
        case failed(message: String, retryable: Bool)
    }

    private(set) var phase: Phase = .review
    private(set) var intent: PaymentIntent

    /// Stable for the lifetime of this sheet — the whole point of the key.
    private let idempotencyKey = UUID().uuidString
    private let repository: HelloRepositoryProtocol

    init(intent: PaymentIntent, repository: HelloRepositoryProtocol) {
        self.intent = intent
        self.repository = repository
    }

    var isBusy: Bool { phase == .authorising || phase == .settling }

    func confirm() async {
        guard !isBusy else { return }

        phase = .authorising
        let outcome = await BiometricGate.authorise(
            reason: L("review_biometric_reason", Money.format(intent.totalAmount ?? intent.amount)))

        switch outcome {
        case .cancelled:
            phase = .review
            return
        case let .failed(message):
            phase = .failed(message: message, retryable: true)
            return
        case .unavailable, .success:
            // `unavailable` still proceeds: biometrics are a possession check, not the authorisation
            // itself, and blocking a user with no passcode enrolled would make the app unusable
            // rather than safer.
            break
        }

        await settle()
    }

    private func settle() async {
        phase = .settling
        do {
            let settled = try await repository.confirmPayment(
                intentId: intent.id, idempotencyKey: idempotencyKey)
            intent = settled

            switch settled.status {
            case .executed:
                phase = .succeeded(settled)
            case .cancelled, .expired:
                phase = .failed(
                    message: L("review_not_completed"),
                    retryable: false)
            default:
                // CONFIRMED but not yet EXECUTED: settlement is in flight. Poll rather than
                // guessing — the server is the only authority on the outcome.
                await pollUntilTerminal()
            }
        } catch let error as APIError {
            CrashReporter.recordPaymentFailure(
                intentId: intent.id, code: error.code?.rawValue ?? "unknown")
            let terminal: Set<HelloErrorCode> = [
                .paymentIntentExpired, .paymentIntentNotActionable, .paymentIntentNotFound
            ]
            phase = .failed(
                message: error.userMessage,
                retryable: !(error.code.map(terminal.contains) ?? false) && error.isRetryable
            )
        } catch {
            CrashReporter.recordPaymentFailure(intentId: intent.id, code: "unexpected")
            phase = .failed(message: L("review_error_confirm"), retryable: true)
        }
    }

    /// Bounded poll. Gives up rather than spinning forever; the receipt will still arrive via
    /// realtime and the transcript.
    private func pollUntilTerminal(attempts: Int = 5) async {
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let refreshed = try? await repository.paymentIntent(id: intent.id) else { continue }
            intent = refreshed
            if refreshed.status == .executed {
                phase = .succeeded(refreshed)
                return
            }
            if refreshed.status.isTerminal {
                phase = .failed(message: L("review_not_completed"), retryable: false)
                return
            }
        }
        phase = .failed(
            message: L("review_still_confirming"),
            retryable: false)
    }

    func cancel() async {
        _ = try? await repository.cancelPayment(intentId: intent.id)
    }
}

struct PaymentReviewSheet: View {

    @State private var model: PaymentReviewModel

    /// Closes the sheet and refreshes.
    ///
    /// The parent owns dismissal by clearing the `.sheet(item:)` binding. That is deterministic;
    /// `@Environment(\.dismiss)` inside a sheet whose content is itself wrapped in a
    /// `NavigationStack` is not reliably the sheet's dismiss action, which is why the buttons
    /// appeared dead.
    let onClose: () -> Void

    /// The settled payment, as confirm returned it — with the receipt — so the chat can show it
    /// under the sheet straight away.
    let onSettled: (PaymentIntent) -> Void

    init(intent: PaymentIntent,
         onSettled: @escaping (PaymentIntent) -> Void = { _ in },
         onClose: @escaping () -> Void) {
        _model = State(initialValue: PaymentReviewModel(intent: intent, repository: HelloRepository()))
        self.onSettled = onSettled
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.Colour.surface.ignoresSafeArea()
                content.padding(.horizontal, Tokens.Spacing.gutter)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .review = model.phase {
                        Button(L("common_cancel")) { cancelAndFinish() }
                    }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
        }
        .onChange(of: model.phase) { _, phase in
            if case let .succeeded(settled) = phase {
                onSettled(settled)
            }
        }
    }

    private var title: String {
        let kind = model.intent.paymentKind
        switch model.phase {
        case .succeeded:
            switch kind {
            case .withdrawal: return L("payment_withdrawal_requested")
            case .topUp: return L("review_top_up_complete")
            default: return L("review_payment_complete")
            }
        case .failed:
            return model.intent.title ?? L("review_payment")
        default:
            return PaymentCopy.reviewAction(kind)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .review:
            reviewContent
        case .authorising, .settling:
            busyContent
        case let .succeeded(intent):
            successContent(intent)
        case let .failed(message, retryable):
            failureContent(message: message, retryable: retryable)
        }
    }

    private var reviewContent: some View {
        VStack(spacing: Tokens.Spacing.xl) {
            summaryCard
            LHPrimaryButton(title: confirmTitle) {
                Task { await model.confirm() }
            }
            Text(L("review_biometric_note", BiometricGate.biometryName))
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Colour.textSecondary)
            Spacer()
        }
        .padding(.top, Tokens.Spacing.xl)
    }

    private var confirmTitle: String {
        switch model.intent.paymentKind {
        case .withdrawal: return L("review_confirm_withdrawal")
        case .topUp: return L("review_confirm_top_up")
        default: return L("review_confirm_payment")
        }
    }

    /// Every figure is the server's. A withdrawal leads with what leaves the wallet and ends with
    /// what the bank pays out; everything else leads with what the user pays.
    private var summaryCard: some View {
        let intent = model.intent
        return VStack(spacing: Tokens.Spacing.md) {
            if let label = intent.title {
                Text(label)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
            }

            switch intent.paymentKind {
            case .withdrawal:
                Text(Money.format(intent.amount))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                if let bank = intent.recipientDisplay, !bank.isEmpty {
                    row(L("review_bank"), bank)
                }
                if let iban = intent.recipientCode {
                    row(L("receipt_iban"), iban)
                }
                row(L("receipt_fee"), Money.format(intent.feeAmount ?? 0))
                row(L("review_bank_pays"), Money.format(intent.totalAmount ?? intent.amount))

            case .topUp:
                Text(Money.format(intent.totalAmount ?? intent.amount))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                if let customer = intent.recipientDisplay ?? intent.recipientCode {
                    row(L("review_customer"), customer)
                }

            default:
                Text(Money.format(intent.totalAmount ?? intent.amount))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)

                if let recipient = intent.recipientDisplay ?? intent.recipientCode {
                    payeeCard(name: recipient, intent: intent)
                }
                if let voucher = intent.voucherCodeMasked {
                    row(L("receipt_voucher"), voucher)
                }
                if let fee = intent.feeAmount, fee > 0 {
                    row(L("receipt_fee"), Money.format(fee))
                    row(L("receipt_amount"), Money.format(intent.amount))
                }
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(Tokens.Colour.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    private var busyContent: some View {
        VStack(spacing: Tokens.Spacing.lg) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(model.phase == .authorising ? L("review_waiting") : L("review_completing"))
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
            // Explicit instruction not to retry: a user force-quitting mid-settlement is exactly
            // how support tickets about "double payments" start.
            Text(L("review_dont_close"))
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Colour.textSecondary)
            Spacer()
        }
    }

    /// The receipt, in the sheet: what was paid, to whom, when, the reference support will ask
    /// for (copyable), and the balance left. The same receipt is already in the chat underneath.
    private func successContent(_ intent: PaymentIntent) -> some View {
        let receipt = intent.messages?.first { $0.type == .paymentReceipt }?.payloadFields ?? [:]
        return VStack(spacing: Tokens.Spacing.lg) {
            Spacer(minLength: Tokens.Spacing.md)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Tokens.Colour.brand)
                .accessibilityHidden(true)
            VStack(spacing: Tokens.Spacing.xs) {
                Text(successHeadline(intent))
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                Text(Money.format(intent.paymentKind == .withdrawal
                                  ? intent.amount : (intent.totalAmount ?? intent.amount)))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                if let name = intent.recipientDisplay ?? intent.recipientCode {
                    Text(L("payment_to", name.bidiIsolated))
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Colour.textPrimary)
                }
            }

            VStack(spacing: Tokens.Spacing.md) {
                if let reference = intent.txnReference {
                    HStack {
                        Text(L("receipt_reference"))
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Colour.textSecondary)
                        Spacer()
                        Text(reference)
                            .font(Tokens.Typography.body.monospaced())
                            .foregroundStyle(Tokens.Colour.textPrimary)
                            .textSelection(.enabled)   // users are asked for this by support
                        Button {
                            UIPasteboard.general.string = reference
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Tokens.Colour.brandAccessible)
                                .frame(width: Tokens.Hit.minimum, height: Tokens.Hit.minimum)
                        }
                        .accessibilityLabel(L("review_copy_reference"))
                    }
                }
                if let when = intent.executedAt {
                    row(L("receipt_date"), when.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale)))
                }
                if let fee = intent.feeAmount, fee > 0, intent.paymentKind != .withdrawal {
                    row(L("receipt_fee"), Money.format(fee))
                }
                if let balance = Double(receipt["newBalance"] ?? "") {
                    row(L("receipt_new_balance"), Money.format(balance))
                }
                if let left = Double(receipt["voucherRemaining"] ?? "") {
                    row(L("receipt_voucher_left"), Money.format(left))
                }
            }
            .padding(Tokens.Spacing.lg)
            .frame(maxWidth: .infinity)
            .background(Tokens.Colour.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))

            Spacer()
            LHPrimaryButton(title: L("common_done")) { finish() }
        }
        .padding(.bottom, Tokens.Spacing.xl)
    }

    private func successHeadline(_ intent: PaymentIntent) -> String {
        switch intent.paymentKind {
        case .withdrawal: return L("payment_withdrawal_requested")
        case .topUp: return L("payment_top_up_sent")
        default: return L("payment_sent")
        }
    }

    /// Who is being paid: the business, store, branch or bus by name, what kind of payee it is and
    /// the code the payer typed — enough to notice "RIO1" when "RI01" was meant.
    private func payeeCard(name: String, intent: PaymentIntent) -> some View {
        HStack(spacing: Tokens.Spacing.md) {
            Text(String(name.prefix(1)).uppercased())
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.navy)
                .frame(width: 40, height: 40)
                .background(Tokens.Colour.surfaceMuted)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(name)
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Colour.textPrimary)
                        .lineLimit(2)
                    if intent.isMerchantRecipient {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Tokens.Colour.brand)
                            .accessibilityLabel(L("payee_verified"))
                    }
                }
                if let summary = intent.recipientDisplay != nil ? intent.recipientSummary : nil {
                    Text(summary)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("payment_to", name))
    }

    private func failureContent(message: String, retryable: Bool) -> some View {
        VStack(spacing: Tokens.Spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Tokens.Colour.danger)
            Text(message)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textPrimary)
                .multilineTextAlignment(.center)
            Spacer()
            if retryable {
                LHPrimaryButton(title: L("common_try_again")) { Task { await model.confirm() } }
            }
            Button(L("common_close")) { finish() }
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .frame(minHeight: Tokens.Hit.minimum)
        }
        .padding(.bottom, Tokens.Spacing.xl)
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

    /// Closes the sheet **immediately**, then refreshes in the background.
    ///
    /// This previously awaited `onFinished()` — two network round-trips — before calling
    /// `dismiss()`. On a slow link the button looked dead for seconds, and if either request hung
    /// the sheet never closed at all. Dismissal is a UI action and must never be gated on the
    /// network. The refresh still happens; the user just is not held hostage to it.
    /// Closes immediately. Never gated on the network — dismissal is a UI action.
    private func finish() {
        onClose()
    }

    /// Cancels the intent, then closes. The close is immediate; the cancel runs after, so a slow
    /// or failed request can never leave the sheet stuck open.
    private func cancelAndFinish() {
        let model = self.model
        onClose()
        Task { await model.cancel() }
    }
}
