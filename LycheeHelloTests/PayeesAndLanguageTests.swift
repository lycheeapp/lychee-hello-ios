import XCTest
import SwiftUI
@testable import LycheeHello

/// The stores directory, "pay again", the composer's payee hint, the Pay sheet's keypad, payment
/// history — and the Arabic, which must cover every English string. Mirrors the Android tests of the
/// same names.
final class PayeesAndLanguageTests: XCTestCase {

    override func tearDown() {
        AppLanguage.set(.system)
        super.tearDown()
    }

    // MARK: - Keypad

    private func type(_ keys: String) -> String {
        keys.reduce("") { AmountInput.press($0, $1) }
    }

    func testTheKeypadAlwaysLeavesANumber() {
        XCTAssertEqual(type("25.5"), "25.5")
        XCTAssertEqual(type("25..5"), "25.5")
        XCTAssertEqual(type(".5"), "0.5")
        XCTAssertEqual(type("12.259"), "12.25")
        XCTAssertEqual(type("007"), "7")
        XCTAssertEqual(type("99999999"), "999999")
        XCTAssertNil(AmountInput.value("0."))
        XCTAssertEqual(AmountInput.value("12.5"), 12.5)
    }

    func testLastTimesAmountIsOfferedAsTyped() {
        XCTAssertEqual(AmountInput.initial(20), "20")
        XCTAssertEqual(AmountInput.initial(15.5), "15.5")
        XCTAssertEqual(AmountInput.initial(12.25), "12.25")
        XCTAssertEqual(AmountInput.initial(nil), "")
        XCTAssertEqual("12a.34".reduce("") { VoucherInput.press($0, $1) }, "1234")
    }

    // MARK: - Payee hint

    func testTheComposerLooksUpOnlyWhatCouldBeAPayee() {
        XCTAssertEqual(PayeeHints.candidate("RIO1 50"), "RIO1")
        XCTAssertNil(PayeeHints.candidate("BALANCE"))
        XCTAssertNil(PayeeHints.candidate("رصيد"))
        XCTAssertNil(PayeeHints.candidate("topup 0599123456 50 1234"))
        XCTAssertNil(PayeeHints.candidate("PS92PALS000000000400123456702 100"))
        XCTAssertNil(PayeeHints.candidate("R"))
        XCTAssertNil(PayeeHints.candidate("hello, how are you"))
        XCTAssertTrue(PayeeHints.isPhone("0599123456"))
        XCTAssertFalse(PayeeHints.isPhone("RIO1"))
    }

    @MainActor
    func testAKnownPayeeIsNamedWhileTyping() async throws {
        let repository = LookupRepository()
        let model = ChatModel(repository: repository)

        for draft in ["RIO1", "RIO1 5", "RIO1 50"] {
            model.draft = draft
            model.draftChanged()
        }
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(model.payeeHint?.found, true)
        XCTAssertEqual(model.payeeHint?.name, "Rio Taxi")
        XCTAssertEqual(repository.lookedUp, ["RIO1"])
    }

    @MainActor
    func testAPrivateNumberGetsNoHint() async throws {
        let model = ChatModel(repository: LookupRepository())
        model.draft = "0599123456 50"
        model.draftChanged()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(model.payeeHint)
    }

    // MARK: - Pay again and history

    func testOnlyAPayeeWithACodeIsOfferedAgain() throws {
        let json = """
        {"entries":[
          {"id":"pi-1","direction":"SENT","kind":"TRANSFER","amount":20,"totalAmount":20.5,
           "counterparty":"Rio Taxi","counterpartyCode":"RIO1","counterpartyType":"SERVICE_PROVIDER",
           "txnReference":"LH-42"},
          {"id":"pi-2","direction":"SENT","kind":"TRANSFER","amount":10,"counterpartyCode":"****3456"},
          {"id":"m-1","direction":"RECEIVED","amount":12.5,"counterparty":"059***1234","newBalance":80}
        ],"nextCursor":1761768600000}
        """
        let page = try JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))

        XCTAssertEqual(page.entries[0].shownAmount, 20.5)
        XCTAssertEqual(page.entries[0].payAgain?.code, "RIO1")
        XCTAssertEqual(page.entries[0].payAgain?.lastAmount, 20)
        XCTAssertNil(page.entries[1].payAgain)
        XCTAssertNil(page.entries[2].payAgain)
        XCTAssertEqual(page.nextCursor, 1761768600000)

        XCTAssertEqual(PayeeRef(receipt: ["kind": "TRANSFER", "recipientCode": "BRV", "recipientDisplay": "Bravo", "amount": "15"])?.lastAmount, 15)
        XCTAssertNil(PayeeRef(receipt: ["kind": "MTB_REQUEST", "recipientCode": "PS12****7890"]))
    }

    func testADirectoryEntryDescribesItself() throws {
        let json = """
        {"entries":[{"code":"BRV","name":"Bravo Market","type":"STORE","categoryLabel":"Supermarket","area":"Ramallah"}],"nextPage":1}
        """
        let page = try JSONDecoder().decode(DirectoryPage.self, from: Data(json.utf8))
        let payee = PayeeRef(page.entries[0])
        XCTAssertEqual(payee.subtitle, "Supermarket · Ramallah")
        XCTAssertTrue(payee.isMerchant)
        XCTAssertEqual(page.nextPage, 1)
    }

    // MARK: - Language

    private func strings(_ language: String) throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    func testEveryStringHasAnArabicTranslationTakingTheSameValues() throws {
        let english = try strings("en")
        let arabic = try strings("ar")
        XCTAssertEqual(Set(english.keys), Set(arabic.keys))

        let placeholder = try NSRegularExpression(pattern: "%(\\d+\\$)?[@d]")
        func placeholders(_ text: String) -> [String] {
            placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .sorted()
        }
        for (key, value) in english {
            XCTAssertEqual(placeholders(value), placeholders(arabic[key] ?? ""), "Arguments differ for \(key)")
        }
    }

    func testTheAppSpeaksTheChosenLanguage() {
        AppLanguage.set(.arabic)
        XCTAssertEqual(AppLanguage.effectiveTag, "ar")
        XCTAssertEqual(AppLanguage.layoutDirection, .rightToLeft)
        XCTAssertEqual(PaymentRecipient.summary(type: "SERVICE_PROVIDER", category: "TAXI", code: "RIO1"), "تاكسي · RIO1")
        XCTAssertEqual(L("payment_to", "Rio Taxi"), "إلى Rio Taxi")

        AppLanguage.set(.english)
        XCTAssertEqual(AppLanguage.effectiveTag, "en")
        XCTAssertEqual(PaymentRecipient.summary(type: "SERVICE_PROVIDER", category: "TAXI", code: "RIO1"), "Taxi · RIO1")
    }
}

/// Answers payee lookups; everything else is unused here.
private final class LookupRepository: HelloRepositoryProtocol, @unchecked Sendable {
    var lookedUp: [String] = []

    func lookupPayee(_ payee: String) async throws -> PayeeLookup {
        lookedUp.append(payee)
        if payee.uppercased() == "RIO1" {
            return PayeeLookup(found: true, code: "RIO1", name: "Rio Taxi", type: "SERVICE_PROVIDER", category: "TAXI")
        }
        return PayeeLookup(found: false, code: payee.uppercased(), name: nil, type: nil, category: nil)
    }

    func directory(query: String?, page: Int) async throws -> DirectoryPage { DirectoryPage(entries: [], nextPage: nil) }
    func recentPayees() async throws -> [RecentPayee] { [] }
    func paymentHistory(query: String?, before: Int64?) async throws -> HistoryPage { HistoryPage(entries: [], nextCursor: nil) }
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
    func paymentIntent(id: String) async throws -> PaymentIntent { throw APIError.offline }
    func pendingPaymentIntent() async throws -> PaymentIntent? { nil }
    func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent { throw APIError.offline }
    func cancelPayment(intentId: String) async throws -> PaymentIntent { throw APIError.offline }
}
