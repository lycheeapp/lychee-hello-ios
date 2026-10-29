import XCTest
@testable import LycheeHello

/// Realtime deduplication and resume behaviour.
///
/// Delivery is at-least-once, so duplicates are expected rather than exceptional. Without correct
/// dedup a replayed `PAYMENT_INTENT_UPDATED` would re-drive UI state, and a replayed
/// `MESSAGE_CREATED` would double a chat bubble.
final class RealtimeTests: XCTestCase {

    func testNewerEventsAreApplied() async {
        let dedup = RealtimeDeduplicator()
        XCTAssertTrue(await dedup.shouldApply(event(id: 1)))
        XCTAssertTrue(await dedup.shouldApply(event(id: 2)))
    }

    func testReplayedEventsAreIgnored() async {
        let dedup = RealtimeDeduplicator()
        _ = await dedup.shouldApply(event(id: 5))

        // Overlapping replay window after a reconnect.
        XCTAssertFalse(await dedup.shouldApply(event(id: 5)))
        XCTAssertFalse(await dedup.shouldApply(event(id: 4)))
        XCTAssertFalse(await dedup.shouldApply(event(id: 1)))
    }

    func testOutOfOrderArrivalNeverRewindsState() async {
        let dedup = RealtimeDeduplicator()
        _ = await dedup.shouldApply(event(id: 10))
        XCTAssertFalse(await dedup.shouldApply(event(id: 9)))
        XCTAssertTrue(await dedup.shouldApply(event(id: 11)))
    }

    /// After a full state fetch the client anchors to the server's head, so events it already
    /// reflects are not re-applied.
    func testResetAnchorsToAFetchedBaseline() async {
        let dedup = RealtimeDeduplicator()
        await dedup.reset(to: 100)

        XCTAssertFalse(await dedup.shouldApply(event(id: 100)))
        XCTAssertFalse(await dedup.shouldApply(event(id: 50)))
        XCTAssertTrue(await dedup.shouldApply(event(id: 101)))
    }

    func testUnknownEventTypeDegradesGracefully() {
        // A backend that adds an event type must not break a shipped client.
        XCTAssertEqual(RealtimeEventType(rawValue: "SOMETHING_NEW") ?? .unknown, .unknown)
        XCTAssertEqual(RealtimeEventType(rawValue: "MESSAGE_CREATED"), .messageCreated)
    }

    private func event(id: Int64) -> RealtimeEvent {
        RealtimeEvent(id: id, type: .messageCreated, payload: [:])
    }
}

/// Error-mapping rules the UI depends on.
final class APIErrorTests: XCTestCase {

    func testUnknownServerCodeDoesNotCrashTheClient() {
        XCTAssertEqual(HelloErrorCode(rawValueOrUnknown: "A_CODE_FROM_THE_FUTURE"), .unknown)
        XCTAssertEqual(HelloErrorCode(rawValueOrUnknown: nil), .unknown)
        XCTAssertEqual(HelloErrorCode(rawValueOrUnknown: "WALLET_NOT_ACTIVE"), .walletNotActive)
    }

    func testOnlyTransientFailuresAreRetryable() {
        XCTAssertTrue(APIError.offline.isRetryable)
        XCTAssertTrue(APIError.timedOut.isRetryable)
        XCTAssertTrue(APIError.api(code: .internalError, message: nil, status: 500).isRetryable)

        // Retrying these would waste an attempt or, worse, re-drive a payment.
        XCTAssertFalse(APIError.unauthorized.isRetryable)
        XCTAssertFalse(APIError.api(code: .voucherNotUsable, message: nil, status: 400).isRetryable)
        XCTAssertFalse(APIError.api(code: .paymentAlreadyPending, message: nil, status: 409).isRetryable)
    }

    func testServerMessageIsPreferredOverTheLocalFallback() {
        let error = APIError.api(code: .voucherNotUsable, message: "Voucher expired", status: 400)
        XCTAssertEqual(error.userMessage, "Voucher expired")
    }

    func testFallbackCopyIsUsedWhenServerSendsNoMessage() {
        let error = APIError.api(code: .walletNotActive, message: nil, status: 403)
        XCTAssertTrue(error.userMessage.contains("wallet"))
    }
}

/// Money rendering — single currency at launch, ₪ symbol (decision U2).
final class MoneyTests: XCTestCase {

    func testWholeAmountsDropDecimals() {
        XCTAssertEqual(Money.format(700), "₪700")
        XCTAssertEqual(Money.format(50), "₪50")
    }

    func testFractionalAmountsShowTwoDecimals() {
        XCTAssertEqual(Money.format(50.25), "₪50.25")
    }

    func testNilRendersAsZeroRatherThanEmpty() {
        XCTAssertEqual(Money.format(nil), "₪0")
    }
}

/// Phone normalisation. The backend is authoritative, but a wrong E.164 here means the OTP goes to
/// the wrong number — worth pinning.
@MainActor
final class PhoneEntryTests: XCTestCase {

    func testLeadingNationalZeroIsDropped() {
        let model = PhoneEntryModel(repository: StubRepository())
        model.nationalNumber = "0594651099"
        XCTAssertEqual(model.e164, "+970594651099")
    }

    func testFormattingCharactersAreStripped() {
        let model = PhoneEntryModel(repository: StubRepository())
        model.nationalNumber = "59 465-1099"
        XCTAssertEqual(model.e164, "+970594651099")
    }

    func testSubmitIsDisabledUntilEnoughDigits() {
        let model = PhoneEntryModel(repository: StubRepository())
        model.nationalNumber = "594"
        XCTAssertFalse(model.canSubmit)
        model.nationalNumber = "594651099"
        XCTAssertTrue(model.canSubmit)
    }
}

/// Minimal stub; the network is not under test here.
private struct StubRepository: HelloRepositoryProtocol {
    func requestOtp(phoneNumber: String, countryCode: String) async throws -> OtpRequestResult {
        OtpRequestResult(expiresInSeconds: 300, codeLength: 6, resendAfterSeconds: 60)
    }
    func verifyOtp(phoneNumber: String, countryCode: String, code: String, pushToken: String) async throws -> SessionResult {
        throw APIError.offline
    }
    func currentUser() async throws -> SessionResult { throw APIError.offline }
    func updateProfile(firstName: String, lastName: String) async throws -> HelloUser { throw APIError.offline }
    func walletBalance() async throws -> WalletBalance { throw APIError.offline }
    func registerPushToken(_ token: String) async throws {}
    func logout() async throws {}
    func generalConversation() async throws -> Conversation { throw APIError.offline }
    func conversations() async throws -> [Conversation] { [] }
    func messages(conversationId: String, before: String?, limit: Int) async throws -> MessagePage { throw APIError.offline }
    func sendText(conversationId: String, text: String, clientMessageId: String) async throws -> SendMessageResult { throw APIError.offline }
    func sendPaymentForm(conversationId: String, payee: String, voucherCode: String?, amount: Double, clientMessageId: String) async throws -> SendMessageResult { throw APIError.offline }
    func paymentIntent(id: String) async throws -> PaymentIntent { throw APIError.offline }
    func pendingPaymentIntent() async throws -> PaymentIntent? { nil }
    func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent { throw APIError.offline }
    func cancelPayment(intentId: String) async throws -> PaymentIntent { throw APIError.offline }
}
