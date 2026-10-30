import XCTest
@testable import LycheeHello

/// The transcript's presentation rules — day chips, runs (which bubble gets the tail), ticks — and
/// the merge that keeps unsent and older messages through a refresh. Mirrors `ChatRowsTest` on
/// Android so both apps draw the same conversation the same way.
final class ChatTranscriptTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!

    // The labels these assert are the English strings the app ships, whatever the simulator's
    // language or a language left pinned in Settings.
    override func setUp() {
        super.setUp()
        AppLanguage.set(.english)
    }

    override func tearDown() {
        AppLanguage.set(.system)
        super.tearDown()
    }

    func testADayChipOpensEachDay() {
        let rows = build([
            message("a", fromUser: true, at: "2026-10-28T09:00:00Z"),
            message("b", fromUser: false, at: "2026-10-28T09:00:05Z"),
            message("c", fromUser: true, at: "2026-10-29T08:00:00Z")
        ])

        let labels = rows.map { row -> String in
            if case let .day(label) = row.kind { return label }
            return row.id
        }
        XCTAssertEqual(labels, ["Yesterday", "a", "b", "Today", "c"])
    }

    func testConsecutiveBubblesFromOneSideFormARun() {
        let rows = build([
            message("a", fromUser: true),
            message("b", fromUser: true),
            message("c", fromUser: false),
            message("d", fromUser: false)
        ]).filter { if case .message = $0.kind { return true } else { return false } }

        XCTAssertEqual(rows.map(\.isFirstInRun), [true, false, true, false])
        XCTAssertEqual(rows.map(\.isLastInRun), [false, true, false, true])
    }

    func testANoticeBreaksARun() {
        let rows = build([
            message("a", fromUser: false),
            message("n", fromUser: false, type: .system),
            message("b", fromUser: false)
        ])
        XCTAssertTrue(rows.first { $0.id == "a" }!.isLastInRun)
        XCTAssertTrue(rows.first { $0.id == "b" }!.isFirstInRun)
    }

    func testTicksTurnBlueOnceLycheeHasAnswered() {
        let rows = Dictionary(uniqueKeysWithValues: build([
            message("answered", fromUser: true),
            message("reply", fromUser: false),
            message("waiting", fromUser: true)
        ]).map { ($0.id, $0) })

        XCTAssertEqual(rows["answered"]?.ticks, .read)
        XCTAssertEqual(rows["waiting"]?.ticks, .sent)
        XCTAssertNil(rows["reply"]?.ticks, "Lychee's own messages carry no ticks")
    }

    func testUnacknowledgedAndFailedBubbles() {
        let pending = message("local-1", fromUser: true).with(status: nil)
        let failed = message("local-2", fromUser: true).with(status: .failed)
        let rows = Dictionary(uniqueKeysWithValues: build([pending, failed]).map { ($0.id, $0) })

        XCTAssertEqual(rows["local-1"]?.ticks, .pending)
        XCTAssertEqual(rows["local-2"]?.ticks, .failed)
    }

    func testAliasesKeepTheOptimisticIdentityAfterTheServerEcho() {
        let rows = ChatRowBuilder.rows(
            for: [message("srv-1", fromUser: true)],
            aliases: ["srv-1": "local-1"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(rows.last?.id, "local-1")
    }

    func testPaymentRepliesOpenFormsAndOthersAreSent() {
        XCTAssertEqual(ReplyAction(title: "Pay from balance"), .openForm(.balance))
        XCTAssertEqual(ReplyAction(title: " use a VOUCHER "), .openForm(.voucher))
        XCTAssertEqual(ReplyAction(title: "Balance"), .send("BALANCE"))
        XCTAssertEqual(ReplyAction(title: "Something else"), .send("Something else"))
        XCTAssertTrue(ReplyAction(title: "Pay from balance").needsPayableWallet)
        // A voucher pays for itself, so its form opens before the wallet is active.
        XCTAssertFalse(ReplyAction(title: "Use a voucher").needsPayableWallet)
        XCTAssertFalse(ReplyAction(title: "Balance").needsPayableWallet)
    }

    /// Reply titles arrive in the user's language; the id is what the app acts on.
    func testReplyIdsWorkWhateverTheTitleSays() {
        XCTAssertEqual(ReplyAction(reply: QuickReply(title: "الدفع من الرصيد", id: "form:balance")), .openForm(.balance))
        XCTAssertEqual(ReplyAction(reply: QuickReply(title: "استخدام قسيمة", id: "form:voucher")), .openForm(.voucher))
        XCTAssertEqual(ReplyAction(reply: QuickReply(title: "الرصيد", id: "cmd:balance")), .send("BALANCE"))
        XCTAssertEqual(ReplyAction(reply: QuickReply(title: "السحب إلى البنك", id: "form:withdraw")), .openForm(.withdraw))
        // No id: an older message, matched by its English title.
        XCTAssertEqual(ReplyAction(reply: QuickReply(title: "Pay from balance", id: nil)), .openForm(.balance))
        XCTAssertTrue(ReplyAction(reply: QuickReply(title: "x", id: "form:withdraw")).needsPayableWallet)
    }

    func testQuickReplyIdsAreReadAlongsideTitles() {
        let message = ChatMessage(
            id: "m1", direction: .outbound, type: .quickReplies, body: "Help",
            payload: #"{"quickReplies":["Pay from balance","Balance"],"quickReplyIds":["form:balance","cmd:balance"]}"#,
            status: .sent, paymentIntentId: nil, sentAt: nil
        )
        XCTAssertEqual(message.quickReplyOptions, [
            QuickReply(title: "Pay from balance", id: "form:balance"),
            QuickReply(title: "Balance", id: "cmd:balance")
        ])
    }

    // MARK: - WhatsApp formatting

    func testWhatsAppMarkersStyleTheirText() {
        let runs = WhatsAppFormatting.runs("Send *BALANCE* or _anything_ ~else~")
        XCTAssertEqual(runs, [
            .init(text: "Send ", style: []),
            .init(text: "BALANCE", style: .bold),
            .init(text: " or ", style: []),
            .init(text: "anything", style: .italic),
            .init(text: " ", style: []),
            .init(text: "else", style: .strike)
        ])
    }

    /// The Arabic WhatsApp replies use doubled markers.
    func testDoubledMarkersCountAsOne() {
        XCTAssertEqual(WhatsAppFormatting.runs("**مثال:** 0599"), [
            .init(text: "مثال:", style: .bold),
            .init(text: " 0599", style: [])
        ])
    }

    /// A masked number, an amount and a product code are not formatting.
    func testTextThatIsNotFormattingIsLeftAlone() {
        XCTAssertEqual(WhatsAppFormatting.runs("from ****1234"), [.init(text: "from ****1234", style: [])])
        XCTAssertEqual(WhatsAppFormatting.runs("2*3*4"), [.init(text: "2*3*4", style: [])])
        XCTAssertEqual(WhatsAppFormatting.runs("snake_case_name"), [.init(text: "snake_case_name", style: [])])
        XCTAssertEqual(WhatsAppFormatting.runs("* not bold *"), [.init(text: "* not bold *", style: [])])
    }

    func testAStyleNeverSpansLines() {
        XCTAssertEqual(WhatsAppFormatting.runs("*one\ntwo*"), [.init(text: "*one\ntwo*", style: [])])
    }

    func testPaymentKindsAreReadFromTheWire() {
        XCTAssertEqual(PaymentKind(raw: "MTB_REQUEST"), .withdrawal)
        XCTAssertEqual(PaymentKind(raw: "TOPUP"), .topUp)
        XCTAssertEqual(PaymentKind(raw: "VOUCHER"), .voucher)
        XCTAssertEqual(PaymentKind(raw: "SOMETHING_NEW"), .unknown)
    }

    // MARK: - Payees and payment outcomes

    func testAPayeeIsDescribedByKindAndCode() {
        XCTAssertEqual(PaymentRecipient.summary(type: "SERVICE_PROVIDER", category: "TAXI", code: "RIO1"), "Taxi · RIO1")
        XCTAssertEqual(PaymentRecipient.summary(type: "STORE", category: nil, code: "BRV"), "Store · BRV")
        XCTAssertEqual(PaymentRecipient.summary(type: "MOBILE_USER", category: nil, code: "****3456"), "Lychee user · ****3456")
        XCTAssertNil(PaymentRecipient.summary(type: nil, category: nil, code: nil))
        XCTAssertTrue(PaymentRecipient.isMerchant("REDEMPTION_POINT"))
        XCTAssertFalse(PaymentRecipient.isMerchant("MOBILE_USER"))
    }

    /// A review card arrives with its payment as it stands now, so a settled card can say "Paid".
    func testAReviewCardCarriesItsPaymentFromTheWire() throws {
        let json = """
        {"id":"m1","direction":"OUTBOUND","type":"PAYMENT_REVIEW","body":"Review","status":"SENT",
         "paymentIntentId":"p1",
         "paymentIntent":{"id":"p1","kind":"TRANSFER","status":"EXECUTED","amount":50,"totalAmount":50,
           "recipientDisplay":"Rio Taxi","recipientCode":"RIO1","recipientType":"SERVICE_PROVIDER",
           "recipientCategory":"TAXI","txnReference":"LH-12"}}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.paymentIntent?.status, .executed)
        XCTAssertEqual(message.paymentIntent?.txnReference, "LH-12")
        XCTAssertEqual(message.paymentIntent?.recipientSummary, "Taxi · RIO1")
        XCTAssertEqual(message.paymentIntent?.isMerchantRecipient, true)
    }

    func testAnAccountSaysWhatKindItIs() {
        XCTAssertEqual(Account(type: Account.business, name: "Rio Taxi", code: "RIO1", current: false).kindLabel,
                       "Business account · RIO1")
        XCTAssertEqual(Account(type: Account.person, name: "Khaled", code: nil, current: true).kindLabel,
                       "Personal account")
    }

    // MARK: - Merge

    func testARefreshKeepsAFailedLocalMessage() {
        let failed = message("local-1", fromUser: true).with(status: .failed)
        let merged = ChatModel.merge(
            current: [failed],
            latest: [message("srv-1", fromUser: false)],
            localIds: ["local-1"],
            pageIsFull: false
        )
        XCTAssertEqual(merged.messages.map(\.id), ["srv-1", "local-1"])
        XCTAssertEqual(merged.localIds, ["local-1"])
    }

    func testAFullPageKeepsOlderHistory() {
        let older = message("old", fromUser: true, at: "2026-10-29T08:00:00Z")
        let latest = [message("new", fromUser: true, at: "2026-10-29T09:00:00Z")]
        let merged = ChatModel.merge(current: [older] + latest, latest: latest, localIds: [], pageIsFull: true)

        XCTAssertEqual(merged.messages.map(\.id), ["old", "new"])
        XCTAssertTrue(merged.keptOlder)
    }

    func testAShortPageIsTheWholeConversation() {
        let stale = message("gone", fromUser: true, at: "2026-10-29T08:00:00Z")
        let latest = [message("new", fromUser: true, at: "2026-10-29T09:00:00Z")]
        let merged = ChatModel.merge(current: [stale] + latest, latest: latest, localIds: [], pageIsFull: false)

        XCTAssertEqual(merged.messages.map(\.id), ["new"])
        XCTAssertFalse(merged.keptOlder)
    }

    func testArabicTextReadsRightToLeft() {
        XCTAssertTrue(message("ar", fromUser: true, body: "رصيد").isRightToLeft)
        XCTAssertFalse(message("en", fromUser: true, body: "RIO1 50").isRightToLeft)
        XCTAssertTrue(message("mixed", fromUser: true, body: "50 شيكل").isRightToLeft)
    }

    // MARK: - Helpers

    private func build(_ messages: [ChatMessage]) -> [ChatRow] {
        ChatRowBuilder.rows(for: messages, now: now, calendar: calendar)
    }

    private func message(
        _ id: String,
        fromUser: Bool,
        type: MessageType = .text,
        at timestamp: String = "2026-10-29T10:00:00Z",
        body: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            direction: fromUser ? .inbound : .outbound,
            type: type,
            body: body ?? id,
            payload: nil,
            status: .sent,
            paymentIntentId: nil,
            sentAt: ISO8601DateFormatter().date(from: timestamp)
        )
    }
}
