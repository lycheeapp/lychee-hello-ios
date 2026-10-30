import Foundation

/// How far a message the user sent has got, as the ticks beside its time show it.
enum DeliveryTicks: Equatable, Sendable {
    /// Drawn locally, not yet acknowledged by the server (clock).
    case pending
    /// The server holds it (one grey tick).
    case sent
    /// Lychee has answered after it (two blue ticks).
    case read
    /// The send failed; the bubble offers a retry.
    case failed
}

/// One line of the transcript.
struct ChatRow: Identifiable, Equatable {

    enum Kind: Equatable {
        /// "Today", "Yesterday", "Monday", "12 Oct 2026".
        case day(String)
        case message(ChatMessage)
    }

    /// Stable across the optimistic → server hand-over, so a sent bubble never re-animates.
    let id: String
    let kind: Kind

    /// First / last bubble of a run from the same side on the same day. Spacing tightens inside a
    /// run, and only the last bubble of a run carries a tail (WhatsApp on iOS).
    var isFirstInRun = true
    var isLastInRun = true

    /// Only for the user's own messages.
    var ticks: DeliveryTicks?
}

/// Turns the flat message list into transcript rows: day chips, runs and ticks.
///
/// Pure and cheap (one pass forwards, one backwards), so the view rebuilds it on every change
/// instead of the model keeping a second copy of the transcript in sync.
enum ChatRowBuilder {

    /// - Parameter aliases: server message id → the id its bubble was first drawn with.
    static func rows(
        for messages: [ChatMessage],
        aliases: [String: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ChatRow] {

        // A message the user sent counts as read once Lychee has said anything after it.
        var answered = Set<String>()
        var sawLycheeReply = false
        for message in messages.reversed() {
            if message.isFromUser {
                if sawLycheeReply { answered.insert(message.id) }
            } else {
                sawLycheeReply = true
            }
        }

        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count + 4)
        var currentDay: Date?
        var previousBubble: ChatMessage?

        for message in messages {
            let day = calendar.startOfDay(for: message.sentAt ?? now)
            if currentDay != day {
                rows.append(ChatRow(
                    id: "day-\(Int(day.timeIntervalSince1970))",
                    kind: .day(dayLabel(for: day, now: now, calendar: calendar))))
                currentDay = day
                previousBubble = nil
            }

            var row = ChatRow(id: aliases[message.id] ?? message.id, kind: .message(message))

            if message.rendersAsBubble {
                // `previousBubble` is only ever the row appended last, so it can be closed here.
                if let previous = previousBubble, previous.isFromUser == message.isFromUser {
                    row.isFirstInRun = false
                    rows[rows.count - 1].isLastInRun = false
                }
                previousBubble = message
            } else {
                previousBubble = nil
            }

            if message.isFromUser {
                row.ticks = ticks(for: message, answered: answered.contains(message.id))
            }
            rows.append(row)
        }
        return rows
    }

    static func ticks(for message: ChatMessage, answered: Bool) -> DeliveryTicks {
        switch message.status {
        case .none:      return .pending
        case .failed?:   return .failed
        case .read?:     return .read
        default:         return answered ? .read : .sent
        }
    }

    // MARK: - Labels

    static func dayLabel(for day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return L("day_today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return L("day_yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), day >= weekAgo {
            return weekdayFormatter.string(from: day)
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return (sameYear ? dayMonthFormatter : fullDateFormatter).string(from: day)
    }

    /// "14:05" / "2:05 PM", following the user's 12/24-hour setting.
    static func time(for message: ChatMessage) -> String {
        guard let sentAt = message.sentAt else { return "" }
        return timeFormatter.string(from: sentAt)
    }

    // Formatters are expensive to build; one each for the whole transcript.
    // In the app's language, so day names follow it even when it differs from the phone's.
    private static var timeFormatter: DateFormatter { formatter(style: .short) }
    private static var weekdayFormatter: DateFormatter { formatter(template: "EEEE") }
    private static var dayMonthFormatter: DateFormatter { formatter(template: "EEE d MMM") }
    private static var fullDateFormatter: DateFormatter { formatter(template: "d MMM yyyy") }

    private static var formatters: [String: DateFormatter] = [:]

    /// One formatter per language and pattern: building a `DateFormatter` per row is what makes a
    /// long transcript stutter.
    private static func formatter(template: String? = nil, style: DateFormatter.Style? = nil) -> DateFormatter {
        let locale = AppLanguage.locale
        let key = "\(locale.identifier)|\(template ?? "")|\(style?.rawValue ?? 0)"
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        if let template { formatter.setLocalizedDateFormatFromTemplate(template) }
        if let style {
            formatter.dateStyle = .none
            formatter.timeStyle = style
        }
        formatters[key] = formatter
        return formatter
    }
}

/// What tapping a reply button does.
///
/// The payment replies open the guided forms (which compose the same command the server parses);
/// "Balance" sends the WhatsApp command; anything else is sent back as if the user had typed it.
enum ReplyAction: Equatable {
    case openForm(PaymentFormSheet.Mode)
    case send(String)

    /// Acts on the button's id when the server sent one — titles arrive in the user's language,
    /// ids do not change — and falls back to the English title for older messages.
    init(reply: QuickReply) {
        self = ReplyAction.forId(reply.id) ?? ReplyAction(title: reply.title)
    }

    private static func forId(_ id: String?) -> ReplyAction? {
        switch id {
        case "form:balance":  return .openForm(.balance)
        case "form:voucher":  return .openForm(.voucher)
        case "form:withdraw": return .openForm(.withdraw)
        case "cmd:balance":   return .send("BALANCE")
        default:              return nil
        }
    }

    init(title: String) {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pay from balance": self = .openForm(.balance)
        case "use a voucher":    self = .openForm(.voucher)
        case "withdraw to bank": self = .openForm(.withdraw)
        case "balance":          self = .send("BALANCE")
        default:                 self = .send(title)
        }
    }

    var needsPayableWallet: Bool {
        if case let .openForm(mode) = self { return mode.needsPayableWallet }
        return false
    }
}
