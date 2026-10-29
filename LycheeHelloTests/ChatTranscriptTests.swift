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
        XCTAssertEqual(ReplyAction(title: "Balance"), .send("Balance"))
        XCTAssertTrue(ReplyAction(title: "Use a voucher").needsPayableWallet)
        XCTAssertFalse(ReplyAction(title: "Balance").needsPayableWallet)
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
