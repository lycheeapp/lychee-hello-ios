import SwiftUI
import Observation

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
            reason: "Confirm your \(Money.format(intent.totalAmount ?? intent.amount)) payment")

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
                    message: "This payment was not completed.",
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
            phase = .failed(message: "The payment could not be completed.", retryable: true)
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
                phase = .failed(message: "This payment was not completed.", retryable: false)
                return
            }
        }
        phase = .failed(
            message: "We're still confirming this payment. Check your chat in a moment.",
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

    init(intent: PaymentIntent, onClose: @escaping () -> Void) {
        _model = State(initialValue: PaymentReviewModel(intent: intent, repository: HelloRepository()))
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
                        Button("Cancel") { cancelAndFinish() }
                    }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
        }
    }

    private var title: String {
        let kind = model.intent.paymentKind
        switch model.phase {
        case .succeeded:
            switch kind {
            case .withdrawal: return "Withdrawal requested"
            case .topUp: return "Top-up complete"
            default: return "Payment complete"
            }
        case .failed:
            return model.intent.title ?? "Payment"
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
            Text("You'll be asked to confirm with \(BiometricGate.biometryName).")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Colour.textSecondary)
            Spacer()
        }
        .padding(.top, Tokens.Spacing.xl)
    }

    private var confirmTitle: String {
        switch model.intent.paymentKind {
        case .withdrawal: return "Confirm withdrawal"
        case .topUp: return "Confirm top-up"
        default: return "Confirm payment"
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
                    row("Bank", bank)
                }
                if let iban = intent.recipientCode {
                    row("IBAN", iban)
                }
                row("Fee", Money.format(intent.feeAmount ?? 0))
                row("The bank pays", Money.format(intent.totalAmount ?? intent.amount))

            case .topUp:
                Text(Money.format(intent.totalAmount ?? intent.amount))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                if let customer = intent.recipientDisplay ?? intent.recipientCode {
                    row("Customer", customer)
                }

            default:
                Text(Money.format(intent.totalAmount ?? intent.amount))
                    .font(Tokens.Typography.largeTitle)
                    .foregroundStyle(Tokens.Colour.textPrimary)

                if let recipient = intent.recipientDisplay ?? intent.recipientCode {
                    row("To", recipient)
                }
                if let voucher = intent.voucherCodeMasked {
                    row("Voucher", voucher)
                }
                if let fee = intent.feeAmount, fee > 0 {
                    row("Fee", Money.format(fee))
                    row("Amount", Money.format(intent.amount))
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
            Text(model.phase == .authorising ? "Waiting for confirmation…" : "Completing your payment…")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
            // Explicit instruction not to retry: a user force-quitting mid-settlement is exactly
            // how support tickets about "double payments" start.
            Text("Please don't close the app.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Colour.textSecondary)
            Spacer()
        }
    }

    private func successContent(_ intent: PaymentIntent) -> some View {
        VStack(spacing: Tokens.Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Tokens.Colour.brand)
            Text(Money.format(intent.totalAmount ?? intent.amount))
                .font(Tokens.Typography.largeTitle)
                .foregroundStyle(Tokens.Colour.textPrimary)
            if let reference = intent.txnReference {
                Text("Reference \(reference)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .textSelection(.enabled)   // users are asked for this by support
            }
            Spacer()
            LHPrimaryButton(title: "Done") { finish() }
        }
        .padding(.bottom, Tokens.Spacing.xl)
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
                LHPrimaryButton(title: "Try again") { Task { await model.confirm() } }
            }
            Button("Close") { finish() }
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
