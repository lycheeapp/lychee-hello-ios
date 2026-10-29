import XCTest
@testable import LycheeHello

/// Payment authorisation rules — the tests worth having in a payments app.
@MainActor
final class PaymentFlowTests: XCTestCase {

    /// A retry must reuse the same idempotency key, or the second attempt is a *new* payment as
    /// far as the backend is concerned. This is the single most expensive bug this app could have.
    func testIdempotencyKeyIsStableAcrossRetries() async {
        let repository = RecordingRepository()
        repository.confirmBehaviour = .failThenSucceed

        let model = PaymentReviewModel(intent: pendingIntent(), repository: repository)
        await model.confirm()
        await model.confirm()

        XCTAssertEqual(repository.confirmKeys.count, 2)
        XCTAssertEqual(repository.confirmKeys[0], repository.confirmKeys[1],
                       "Retrying a payment must reuse the original idempotency key")
    }

    /// Expired and not-actionable are terminal: offering "try again" would guarantee another
    /// failure and imply the payment might still go through.
    func testExpiredPaymentIsNotOfferedAsRetryable() async {
        let repository = RecordingRepository()
        repository.confirmBehaviour = .fail(.api(code: .paymentIntentExpired, message: nil, status: 409))

        let model = PaymentReviewModel(intent: pendingIntent(), repository: repository)
        await model.confirm()

        guard case let .failed(_, retryable) = model.phase else {
            return XCTFail("Expected a failed phase, got \(model.phase)")
        }
        XCTAssertFalse(retryable)
    }

    func testTransientFailureIsRetryable() async {
        let repository = RecordingRepository()
        repository.confirmBehaviour = .fail(.offline)

        let model = PaymentReviewModel(intent: pendingIntent(), repository: repository)
        await model.confirm()

        guard case let .failed(_, retryable) = model.phase else {
            return XCTFail("Expected a failed phase, got \(model.phase)")
        }
        XCTAssertTrue(retryable)
    }

    /// Success is rendered from the server's status, never inferred from a 200.
    func testSuccessRequiresServerReportedExecutedStatus() async {
        let repository = RecordingRepository()
        repository.confirmBehaviour = .succeed(status: .executed)

        let model = PaymentReviewModel(intent: pendingIntent(), repository: repository)
        await model.confirm()

        guard case let .succeeded(intent) = model.phase else {
            return XCTFail("Expected success, got \(model.phase)")
        }
        XCTAssertEqual(intent.status, .executed)
    }

    /// A confirm that returns CANCELLED must not be shown as success even though the HTTP call
    /// succeeded.
    func testCancelledStatusIsAFailureNotASuccess() async {
        let repository = RecordingRepository()
        repository.confirmBehaviour = .succeed(status: .cancelled)

        let model = PaymentReviewModel(intent: pendingIntent(), repository: repository)
        await model.confirm()

        guard case let .failed(_, retryable) = model.phase else {
            return XCTFail("Expected failure, got \(model.phase)")
        }
        XCTAssertFalse(retryable)
    }

    private func pendingIntent() -> PaymentIntent {
        PaymentIntent(
            id: "11111111-1111-1111-1111-111111111111",
            kind: "VOUCHER",
            status: .pending,
            amount: 50,
            feeAmount: 0,
            totalAmount: 50,
            currencyCode: "ILS",
            recipientDisplay: "Rio Store",
            recipientCode: "RIO1",
            voucherCodeMasked: "••••2087",
            expiresAt: Date().addingTimeInterval(900),
            txnReference: nil,
            errorCode: nil
        )
    }
}

/// Records confirm calls so idempotency behaviour can be asserted.
private final class RecordingRepository: HelloRepositoryProtocol, @unchecked Sendable {

    enum Behaviour {
        case succeed(status: PaymentIntentStatus)
        case fail(APIError)
        case failThenSucceed
    }

    var confirmBehaviour: Behaviour = .succeed(status: .executed)
    private(set) var confirmKeys: [String] = []
    private var confirmCount = 0

    func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent {
        confirmKeys.append(idempotencyKey)
        confirmCount += 1

        switch confirmBehaviour {
        case let .succeed(status):
            return intent(status: status)
        case let .fail(error):
            throw error
        case .failThenSucceed:
            if confirmCount == 1 { throw APIError.offline }
            return intent(status: .executed)
        }
    }

    private func intent(status: PaymentIntentStatus) -> PaymentIntent {
        PaymentIntent(
            id: "11111111-1111-1111-1111-111111111111",
            kind: "VOUCHER", status: status, amount: 50, feeAmount: 0, totalAmount: 50,
            currencyCode: "ILS", recipientDisplay: "Rio Store", recipientCode: "RIO1",
            voucherCodeMasked: "••••2087", expiresAt: nil,
            txnReference: status == .executed ? "LH-1" : nil, errorCode: nil
        )
    }

    // Unused by these tests.
    func requestOtp(phoneNumber: String, countryCode: String) async throws -> OtpRequestResult { throw APIError.offline }
    func verifyOtp(phoneNumber: String, countryCode: String, code: String, pushToken: String) async throws -> SessionResult { throw APIError.offline }
    func currentUser() async throws -> SessionResult { throw APIError.offline }
    func updateProfile(firstName: String, lastName: String) async throws -> HelloUser { throw APIError.offline }
    func walletBalance() async throws -> WalletBalance { throw APIError.offline }
    func registerPushToken(_ token: String) async throws {}
    func logout() async throws {}
    func switchAccount(to accountType: String) async throws -> SessionResult { throw APIError.offline }
    func generalConversation() async throws -> Conversation { throw APIError.offline }
    func conversations() async throws -> [Conversation] { [] }
    func messages(conversationId: String, before: String?, limit: Int) async throws -> MessagePage { throw APIError.offline }
    func sendText(conversationId: String, text: String, clientMessageId: String) async throws -> SendMessageResult { throw APIError.offline }
    func sendPaymentForm(conversationId: String, payee: String, voucherCode: String?, amount: Double, clientMessageId: String) async throws -> SendMessageResult { throw APIError.offline }
    func sendWithdrawalForm(conversationId: String, iban: String, amount: Double?, clientMessageId: String) async throws -> SendMessageResult { throw APIError.offline }
    func sendTopUpForm(conversationId: String, recipientPhone: String, amount: Double, pin: String, clientMessageId: String) async throws -> SendMessageResult { throw APIError.offline }
    func paymentIntent(id: String) async throws -> PaymentIntent { intent(status: .confirmed) }
    func pendingPaymentIntent() async throws -> PaymentIntent? { nil }
    func cancelPayment(intentId: String) async throws -> PaymentIntent { intent(status: .cancelled) }
}

/// Redaction — these values reach a third-party crash service.
final class RedactorTests: XCTestCase {

    func testPhoneNumbersAreRedacted() {
        let output = Redactor.redact("Failed for +970594651099")
        XCTAssertFalse(output.contains("970594651099"))
        XCTAssertTrue(output.contains("[redacted-number]"))
    }

    func testTokensAreRedacted() {
        let output = Redactor.redact("Authorization-Token: LYCHEE-abc123-XYZ")
        XCTAssertFalse(output.contains("abc123"))
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(Redactor.redact("Voucher expired"), "Voucher expired")
    }

    func testNilAndEmptyAreSafe() {
        XCTAssertEqual(Redactor.redact(nil), "")
        XCTAssertEqual(Redactor.redact(""), "")
    }
}
