import Foundation

/// A store the app lists (`GET directory`), with the code that pays it.
public struct DirectoryEntry: Decodable, Sendable, Equatable, Identifiable {
    /// The payee code: what "BRV 50" starts with.
    public let code: String
    public let name: String?
    /// `STORE`, for now; the same vocabulary as a payment's `recipientType`.
    public let type: String?
    /// The store's category, already in the app's language ("Supermarket" / "سوبرماركت").
    public let categoryLabel: String?
    public let area: String?
    public let logoUrl: String?

    public var id: String { code }
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? code }

    /// "Supermarket · Ramallah".
    public var subtitle: String? {
        let parts = [categoryLabel, area].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct DirectoryPage: Decodable, Sendable {
    public let entries: [DirectoryEntry]
    /// The page to ask for next; nil at the end.
    public let nextPage: Int?
}

/// Who the first word of a message names, before anything is sent (`GET recipients/lookup`).
public struct PayeeLookup: Decodable, Sendable, Equatable {
    public let found: Bool
    public let code: String?
    public let name: String?
    public let type: String?
    public let category: String?
}

/// One of the caller's recent payees — a "pay again" shortcut.
public struct RecentPayee: Decodable, Sendable, Equatable, Identifiable {
    public let code: String
    public let name: String?
    public let type: String?
    public let category: String?
    public let lastAmount: Double?
    public let lastPaidAt: Date?

    public var id: String { code }
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? code }
}

/// A payment made or received, as the history lists it.
public struct HistoryEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// `SENT` or `RECEIVED`.
    public let direction: String?
    /// For a payment made: `TRANSFER`, `VOUCHER`, `MTB_REQUEST`, `TOPUP`.
    public let kind: String?
    public let amount: Double?
    public let feeAmount: Double?
    public let totalAmount: Double?
    public let currencyCode: String?
    /// Who was paid, or who paid.
    public let counterparty: String?
    public let counterpartyCode: String?
    public let counterpartyType: String?
    public let counterpartyCategory: String?
    public let voucherCodeMasked: String?
    public let txnReference: String?
    public let newBalance: Double?
    public let at: Date?

    public var isReceived: Bool { direction?.uppercased() == "RECEIVED" }
    public var paymentKind: PaymentKind { PaymentKind(raw: kind) }

    /// What left (or reached) the wallet: the total for a payment made, the amount for one received.
    public var shownAmount: Double? { isReceived ? amount : (totalAmount ?? amount) }

    /// The payee to pay again, when there is one to name: a code, not a masked number, and not a
    /// withdrawal or top-up — those are not "paying someone".
    public var payAgain: PayeeRef? {
        guard !isReceived, paymentKind == .transfer || paymentKind == .voucher,
              let code = counterpartyCode, !code.isEmpty, !code.hasPrefix("*") else { return nil }
        return PayeeRef(
            code: code,
            name: (counterparty?.isEmpty == false ? counterparty : nil) ?? code,
            type: counterpartyType,
            category: counterpartyCategory,
            lastAmount: amount
        )
    }
}

public struct HistoryPage: Decodable, Sendable {
    public let entries: [HistoryEntry]
    /// The `before` to ask for next (epoch millis); nil at the end.
    public let nextCursor: Int64?
}

/// A payee the app can pay without the person typing a code: from the stores directory, a "pay
/// again" shortcut, a receipt or the history. The payment still goes through the chat — the same
/// review and confirmation as a typed message.
public struct PayeeRef: Sendable, Equatable, Hashable, Identifiable {
    public let code: String
    public let name: String
    public var type: String? = nil
    public var category: String? = nil
    /// What was paid last time, to offer again.
    public var lastAmount: Double? = nil
    /// "Supermarket · Ramallah", from the directory.
    public var subtitle: String? = nil

    public var id: String { code }
    public var isMerchant: Bool { PaymentRecipient.isMerchant(type) }

    public init(code: String, name: String, type: String? = nil, category: String? = nil,
                lastAmount: Double? = nil, subtitle: String? = nil) {
        self.code = code
        self.name = name
        self.type = type
        self.category = category
        self.lastAmount = lastAmount
        self.subtitle = subtitle
    }

    public init(_ entry: DirectoryEntry) {
        self.init(code: entry.code, name: entry.displayName, type: entry.type, subtitle: entry.subtitle)
    }

    public init(_ recent: RecentPayee) {
        self.init(code: recent.code, name: recent.displayName, type: recent.type,
                  category: recent.category, lastAmount: recent.lastAmount)
    }

    /// From a receipt in the chat; nil when it names no payee to pay again.
    public init?(receipt fields: [String: String]) {
        let kind = PaymentKind(raw: fields["kind"])
        guard kind == .transfer || kind == .voucher,
              let code = fields["recipientCode"], !code.isEmpty, !code.hasPrefix("*") else { return nil }
        let display = fields["recipientDisplay"]
        self.init(
            code: code,
            name: (display?.isEmpty == false ? display : nil) ?? code,
            type: fields["recipientType"],
            category: fields["recipientCategory"],
            lastAmount: fields["amount"].flatMap(Double.init)
        )
    }
}

/// Which drafts deserve a payee hint, and which word in them is the payee.
public enum PayeeHints {

    /// Words that start a command rather than name a payee, in both languages.
    private static let commands: Set<String> = [
        "BALANCE", "رصيد", "TOPUP", "شحن", "HELP", "مساعدة", "MENU", "HI", "HELLO", "مرحبا",
        "YES", "NO", "نعم", "لا", "OK", "CANCEL", "الغاء", "إلغاء"
    ]

    /// The first word of `draft` when it could be a payee; nil for a command, an IBAN or nothing.
    public static func candidate(_ draft: String) -> String? {
        let words = draft.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return nil }
        let word = String(first)
        let upper = word.uppercased()
        guard (2...32).contains(word.count), !commands.contains(upper), !isIBAN(upper) else { return nil }
        guard word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) else { return nil }
        return word
    }

    /// Whether something follows the payee — an amount or a voucher — so a miss is worth saying.
    public static func hasMore(_ draft: String) -> Bool {
        draft.split(whereSeparator: { $0.isWhitespace }).count > 1
    }

    /// A number — a private person's, unless the server names a business.
    public static func isPhone(_ word: String) -> Bool {
        word.filter(\.isNumber).count >= 7 && word.allSatisfy { $0.isNumber || $0 == "+" || $0 == "-" }
    }

    private static func isIBAN(_ upper: String) -> Bool {
        guard upper.count >= 15, upper.count <= 34 else { return false }
        let chars = Array(upper)
        return chars[0].isLetter && chars[1].isLetter && chars[2].isNumber && chars[3].isNumber
            && chars.allSatisfy { ($0.isLetter && $0.isASCII) || $0.isNumber }
    }
}

/// The composer's hint about the payee being typed.
public struct PayeeHint: Equatable, Sendable {
    /// The word it is about, upper-cased: the hint is dropped as soon as the word changes.
    public let payee: String
    public let found: Bool
    public var name: String? = nil
    public var code: String? = nil
    public var type: String? = nil
    public var category: String? = nil
}
