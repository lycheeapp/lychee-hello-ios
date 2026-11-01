import XCTest
import SwiftUI
@testable import LycheeHello

/// The Cards tab: the stack's order and the chosen card, paying a POS's tag, a new OnePay voucher.
/// Mirrors the Android `CardsViewModelTest`.
@MainActor
final class CardsModelTests: XCTestCase {

    private typealias Card = CardFixtures

    /// Each test its own store, so a remembered choice never leaks between tests.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!
    }

    private func wallet(_ cards: [WalletCard], defaultCardId: String? = nil, newCardId: String? = nil) -> Wallet {
        Wallet(cards: cards, defaultCardId: defaultCardId, newCardId: newCardId)
    }

    private func model(_ repository: WalletRepository, defaults: UserDefaults? = nil) -> CardsModel {
        CardsModel(repository: repository, defaults: defaults ?? freshDefaults())
    }

    // MARK: - The stack

    func testTheTapAndPayDefaultIsInFrontTheFirstTime() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance, Card.mine, Card.gift], defaultCardId: "ONEPAY:2222")])
        let model = model(repository)
        await model.start(accountKey: "7")
        XCTAssertEqual(model.selected?.id, "ONEPAY:2222")
        XCTAssertEqual(model.cards.map(\.id), ["WALLET", "ONEPAY:1111", "ONEPAY:2222"])
    }

    func testChoosingACardSwapsItWithTheFrontOneAndIsRemembered() async {
        let defaults = freshDefaults()
        let repository = WalletRepository(wallets: [wallet([Card.balance, Card.mine, Card.gift, Card.bravo])])
        let model = model(repository, defaults: defaults)
        await model.start(accountKey: "7")
        XCTAssertEqual(model.order, ["ONEPAY:1111", "ONEPAY:2222", "STATIC:3333", "WALLET"])
        XCTAssertEqual(model.selected?.id, "WALLET")

        model.select("ONEPAY:1111")
        XCTAssertEqual(model.order, ["WALLET", "ONEPAY:2222", "STATIC:3333", "ONEPAY:1111"], "only the two cards trade places")
        XCTAssertEqual(model.selected?.id, "ONEPAY:1111")

        // Another visit, same phone, same account: the same card is in front.
        let again = self.model(WalletRepository(wallets: [wallet([Card.balance, Card.mine, Card.gift, Card.bravo])]), defaults: defaults)
        await again.start(accountKey: "7")
        XCTAssertEqual(again.selected?.id, "ONEPAY:1111")

        // Another account on the phone has its own choice.
        let other = self.model(WalletRepository(wallets: [wallet([Card.balance, Card.mine])]), defaults: defaults)
        await other.start(accountKey: "8")
        XCTAssertEqual(other.selected?.id, "WALLET")
    }

    func testChoosingTheFrontCardChangesNothing() async {
        let model = model(WalletRepository(wallets: [wallet([Card.balance, Card.mine])]))
        await model.start(accountKey: "7")
        let before = model.order
        model.select(model.order.last!)
        XCTAssertEqual(model.order, before)
    }

    func testARefreshKeepsTheArrangement() {
        XCTAssertEqual(CardsModel.arrange(previous: ["A", "B", "C"], ids: ["A", "B", "C", "D"], front: "C"),
                       ["A", "B", "D", "C"], "a new card joins just behind the front")
        XCTAssertEqual(CardsModel.arrange(previous: ["A", "B", "C"], ids: ["A", "C"], front: "C"),
                       ["A", "C"], "a gone card leaves")
        XCTAssertEqual(CardsModel.arrange(previous: ["A", "B", "C"], ids: ["A", "B", "C"], front: "A"),
                       ["B", "C", "A"])
        XCTAssertEqual(CardsModel.arrange(previous: [], ids: ["A", "B"], front: nil), ["A", "B"])
    }

    // MARK: - Paying at a POS

    func testTheTagsLinkGivesThePayloadByteForByte() {
        XCTAssertEqual(TapLink.payload("https://pay.lycheeapp.org/pay?p=eyJhIjoxfQ.c2ln"), "eyJhIjoxfQ.c2ln")
        XCTAssertEqual(TapLink.payload("https://pay.lycheeapp.org/pay/?x=1&p=abc%2D_#frag"), "abc%2D_", "never URL-decoded")
        XCTAssertNil(TapLink.payload("https://pay.lycheeapp.org/other?p=abc"))
        XCTAssertNil(TapLink.payload("https://pay.lycheeapp.org/pay"))
        XCTAssertNil(TapLink.payload("https://pay.lycheeapp.org/pay?p="))
        XCTAssertNil(TapLink.payload(nil))
    }

    func testATagThatIsNotLycheesSaysSo() async {
        let model = model(WalletRepository(wallets: [wallet([Card.balance])]))
        await model.start(accountKey: "7")
        await model.tagRead("https://example.com/hello")
        guard case let .failed(message, payload) = model.pay else { return XCTFail("\(model.pay)") }
        XCTAssertEqual(message, L("tap_not_lychee"))
        XCTAssertNil(payload)
    }

    func testTheFrontCardPaysWhenItCanOtherwiseTheNearestThatCan() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance, Card.mine, Card.bravo])])
        let model = model(repository)
        await model.start(accountKey: "7")
        model.select("STATIC:3333")

        repository.preview = TapPreview(storeName: "Rio", amount: 12, currencyCode: "ILS", expiresAt: nil, transit: false, options: [
            CardOption(cardId: "WALLET", usable: true, reason: nil, balance: 120),
            CardOption(cardId: "ONEPAY:1111", usable: true, reason: nil, balance: 50),
            CardOption(cardId: "STATIC:3333", usable: false, reason: "other_store", balance: 40)
        ])
        await model.tagRead("https://pay.lycheeapp.org/pay?p=abc")
        guard case let .ready(payload, _, cardId, paying, _) = model.pay else { return XCTFail("\(model.pay)") }
        XCTAssertTrue(repository.paid.isEmpty, "confirm before paying is on by default: nothing is paid yet")
        XCTAssertEqual(payload, "abc")
        XCTAssertFalse(paying)
        let nearest = model.order.reversed().first { $0 != "STATIC:3333" }
        XCTAssertEqual(cardId, nearest, "the Bravo voucher cannot pay Rio: the next card in the stack does")

        repository.receipt = TapReceipt(txnRef: "T1", status: "PAID", amount: 12, currencyCode: "ILS", storeName: "Rio",
                                        cardId: cardId, newBalance: 38, paidAt: nil)
        repository.wallets = [wallet([Card.balance, WalletCard(id: "ONEPAY:1111", kind: "ONEPAY", balance: 38), Card.bravo])]
        await model.confirmPay()
        guard case let .paid(receipt, _) = model.pay else { return XCTFail("\(model.pay)") }
        XCTAssertTrue(receipt.isPaid)
        XCTAssertEqual(repository.paid.first?.payload, "abc")
        XCTAssertEqual(repository.paid.first?.cardId, cardId)
    }

    // MARK: - Confirm before paying: off

    private func confirmationOff() -> UserDefaults {
        let defaults = freshDefaults()
        defaults.set(false, forKey: CardsModel.confirmBeforePayingKey)
        return defaults
    }

    func testWithConfirmationOffTheFrontCardPaysAsSoonAsThePosIsRead() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance, Card.mine])])
        let model = model(repository, defaults: confirmationOff())
        await model.start(accountKey: "7")
        model.select("ONEPAY:1111")
        repository.preview = TapPreview(storeName: "Rio", amount: 12, currencyCode: "ILS",
                                        expiresAt: Int64((Date().timeIntervalSince1970 + 60) * 1000), transit: false, options: [
            CardOption(cardId: "WALLET", usable: true, reason: nil, balance: 120),
            CardOption(cardId: "ONEPAY:1111", usable: true, reason: nil, balance: 50)
        ])
        repository.receipt = TapReceipt(txnRef: "T1", status: "PAID", amount: 12, currencyCode: "ILS", storeName: "Rio",
                                        cardId: "ONEPAY:1111", newBalance: 38, paidAt: nil)

        await model.tagRead("https://pay.lycheeapp.org/pay?p=abc")

        XCTAssertEqual(repository.paid.first?.payload, "abc")
        XCTAssertEqual(repository.paid.first?.cardId, "ONEPAY:1111")
        guard case .paid = model.pay else { return XCTFail("\(model.pay)") }
    }

    func testWithConfirmationOffAFrontCardThatCannotPayOpensThePaymentInstead() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance, Card.mine])])
        let model = model(repository, defaults: confirmationOff())
        await model.start(accountKey: "7")
        model.select("ONEPAY:1111")
        repository.preview = TapPreview(storeName: "Rio", amount: 80, currencyCode: "ILS", expiresAt: nil, transit: false, options: [
            CardOption(cardId: "WALLET", usable: true, reason: nil, balance: 120),
            CardOption(cardId: "ONEPAY:1111", usable: false, reason: "insufficient_balance", balance: 50)
        ])

        await model.tagRead("https://pay.lycheeapp.org/pay?p=abc")

        // Never another card behind the user's back: the payment opens with the balance offered.
        XCTAssertTrue(repository.paid.isEmpty)
        guard case let .ready(_, _, cardId, paying, _) = model.pay else { return XCTFail("\(model.pay)") }
        XCTAssertEqual(cardId, "WALLET")
        XCTAssertFalse(paying)
    }

    func testWithConfirmationOffAnExpiredRequestIsNotPaid() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance])])
        let model = model(repository, defaults: confirmationOff())
        await model.start(accountKey: "7")
        repository.preview = TapPreview(storeName: "Rio", amount: 5, currencyCode: "ILS", expiresAt: 1_000, transit: false, options: [
            CardOption(cardId: "WALLET", usable: true, reason: nil, balance: 120)
        ])

        await model.tagRead("https://pay.lycheeapp.org/pay?p=abc")

        XCTAssertTrue(repository.paid.isEmpty)
        guard case .ready = model.pay else { return XCTFail("\(model.pay)") }
    }

    func testNothingIsPaidWithACardThatCannot() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance])])
        let model = model(repository)
        await model.start(accountKey: "7")
        repository.preview = TapPreview(storeName: "Rio", amount: 500, currencyCode: "ILS", expiresAt: nil, transit: false, options: [
            CardOption(cardId: "WALLET", usable: false, reason: "insufficient_balance", balance: 120)
        ])
        await model.tagRead("https://pay.lycheeapp.org/pay?p=abc")
        await model.confirmPay()
        XCTAssertTrue(repository.paid.isEmpty)
    }

    func testAFailedPaymentKeepsTheRequestToTryAgain() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance])])
        let model = model(repository)
        await model.start(accountKey: "7")
        repository.preview = TapPreview(storeName: "Rio", amount: 5, currencyCode: "ILS", expiresAt: nil, transit: false, options: [
            CardOption(cardId: "WALLET", usable: true, reason: nil, balance: 120)
        ])
        await model.tagRead("https://pay.lycheeapp.org/pay?p=abc")
        repository.payError = APIError.offline
        await model.confirmPay()
        guard case let .ready(_, _, _, paying, error) = model.pay else { return XCTFail("\(model.pay)") }
        XCTAssertFalse(paying)
        XCTAssertNotNil(error)
    }

    // MARK: - A new OnePay voucher

    func testANewVoucherKeepsToTheLimitsAndTheBalance() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance])])
        repository.settings = OnePaySettings(voucherName: "OnePay", min: 10, max: 100, currencyCode: "ILS", validity: "ONE_YEAR", terms: [])
        let model = model(repository)
        await model.start(accountKey: "7")
        await model.openCreate()

        "5".forEach(model.press)
        XCTAssertEqual(model.amountProblem(), L("onepay_too_low", Money.format(10)))
        "00".forEach(model.press)
        XCTAssertEqual(model.create?.amount, "500")
        XCTAssertEqual(model.amountProblem(), L("onepay_too_high", Money.format(100)))
        model.deleteDigit()
        XCTAssertNil(model.amountProblem())

        // Not without accepting the terms.
        await model.submitCreate()
        XCTAssertTrue(repository.created.isEmpty)

        model.create?.accepted = true
        repository.wallets = [wallet([Card.balance, Card.mine], newCardId: "ONEPAY:1111")]
        await model.submitCreate()
        XCTAssertEqual(repository.created, [50])
        XCTAssertNil(model.create)
        XCTAssertEqual(model.selected?.id, "ONEPAY:1111", "the new voucher comes to the front")
    }

    func testOverTheBalanceIsRefused() async {
        let repository = WalletRepository(wallets: [wallet([Card.balance])])
        repository.settings = OnePaySettings(voucherName: nil, min: 1, max: 1000, currencyCode: "ILS", validity: nil, terms: nil)
        let model = model(repository)
        await model.start(accountKey: "7")
        await model.openCreate()
        "130".forEach(model.press)
        XCTAssertEqual(model.amountProblem(), L("onepay_over_balance"))
    }

    // MARK: - Copy and colours

    func testATapReceiptReadsAsPaidAtAPos() {
        XCTAssertEqual(PaymentKind(raw: "TAP"), .tap)
        XCTAssertEqual(PaymentCopy.doneLabel(.tap, stage: nil), L("payment_paid_at_pos"))
    }

    func testAnIssuerAlwaysWearsTheSameColourOnBothPlatforms() {
        let a = WalletCard(id: "ONEPAY:1", kind: "ONEPAY", from: "Bravo")
        let b = WalletCard(id: "STATIC:2", kind: "STATIC", from: "bravo")
        XCTAssertEqual(CardPalette.colours(a), CardPalette.colours(b))
        // Java's "a".hashCode() is 97; 97 mod 9 is 7: orange, as on Android.
        XCTAssertEqual(CardPalette.colours(WalletCard(id: "x", kind: "ONEPAY", from: "a")),
                       [Color(hex: 0xF2803C), Color(hex: 0xB8471A)])
        XCTAssertEqual(CardPalette.colours(WalletCard(id: "x", kind: "ONEPAY")),
                       [Color(hex: 0x0E7A43), Color(hex: 0x07402A)], "the user's own voucher is Lychee green")
    }
}

/// The cards the tests use.
private enum CardFixtures {
    static let balance = WalletCard(id: "WALLET", kind: "WALLET", title: "Lychee balance", balance: 120)
    static let mine = WalletCard(id: "ONEPAY:1111", kind: "ONEPAY", codeMasked: "•••• 1111", balance: 50)
    static let gift = WalletCard(id: "ONEPAY:2222", kind: "ONEPAY", from: "Sara K.", balance: 298)
    static let bravo = WalletCard(id: "STATIC:3333", kind: "STATIC", from: "Bravo", balance: 40, storeName: "Bravo")
}

/// Answers the Cards calls from what each test sets; everything else is unused here.
private final class WalletRepository: HelloRepositoryProtocol, @unchecked Sendable {
    var wallets: [Wallet]
    var settings: OnePaySettings?
    var preview: TapPreview?
    var receipt: TapReceipt?
    var payError: Error?
    var paid: [(payload: String, cardId: String)] = []
    var created: [Double] = []

    init(wallets: [Wallet]) { self.wallets = wallets }

    func wallet() async throws -> Wallet {
        guard let first = wallets.first else { throw APIError.offline }
        if wallets.count > 1 { wallets.removeFirst() }
        return first
    }

    func onePaySettings() async throws -> OnePaySettings {
        guard let settings else { throw APIError.offline }
        return settings
    }

    func createOnePay(amount: Double, acceptedTerms: Bool) async throws -> Wallet {
        created.append(amount)
        return try await wallet()
    }

    func tapPreview(payload: String) async throws -> TapPreview {
        guard let preview else { throw APIError.offline }
        return preview
    }

    func tapPay(payload: String, cardId: String) async throws -> TapReceipt {
        if let payError { throw payError }
        paid.append((payload, cardId))
        guard let receipt else { throw APIError.offline }
        return receipt
    }

    func lookupPayee(_ payee: String) async throws -> PayeeLookup { throw APIError.offline }
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
