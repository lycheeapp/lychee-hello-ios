import XCTest
@testable import LycheeHello

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
        throw APIError.offline
    }
    func verifyOtp(phoneNumber: String, countryCode: String, code: String, pushToken: String) async throws -> SessionResult {
        throw APIError.offline
    }
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
    func paymentIntent(id: String) async throws -> PaymentIntent { throw APIError.offline }
    func pendingPaymentIntent() async throws -> PaymentIntent? { nil }
    func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent { throw APIError.offline }
    func cancelPayment(intentId: String) async throws -> PaymentIntent { throw APIError.offline }
    func lookupPayee(_ payee: String) async throws -> PayeeLookup { throw APIError.offline }
    func directory(query: String?, page: Int) async throws -> DirectoryPage { throw APIError.offline }
    func recentPayees() async throws -> [RecentPayee] { [] }
    func paymentHistory(query: String?, before: Int64?) async throws -> HistoryPage { throw APIError.offline }
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
