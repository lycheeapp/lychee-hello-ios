import Foundation

// The Cards tab's wire models: the user's Lychee balance, OnePay vouchers and store vouchers, and
// a POS payment request read off the POS's NFC tag. Lenient like the rest: every field the server
// might leave out is optional, so a server that adds one cannot break an older app.

public enum CardKind: Sendable, Equatable {
    case wallet, onePay, store, unknown

    init(raw: String?) {
        switch raw?.uppercased() {
        case "WALLET": self = .wallet
        case "ONEPAY": self = .onePay
        case "STATIC": self = .store
        default: self = .unknown
        }
    }
}

public struct WalletCard: Decodable, Sendable, Equatable, Identifiable {
    /// `WALLET`, `ONEPAY:<code>` or `STATIC:<code>`: what the app selects and pays with.
    public let id: String
    public let kind: String?
    public let code: String?
    public let codeMasked: String?
    public let title: String?
    /// Who made and sent it, or the store a static voucher pays; nil for the user's own.
    public let from: String?
    public let balance: Double?
    public let currencyCode: String?
    /// Epoch millis; nil when it does not expire.
    public let validUntil: Int64?
    public let status: String?
    public let usable: Bool?
    /// Why it cannot pay: `spent`, `expired`, `unconfirmed`, `wallet_not_active`…
    public let reason: String?
    public let storeName: String?
    public let logoUrl: String?
    public let ownedSince: Int64?

    public var cardKind: CardKind { CardKind(raw: kind) }
    public var canPay: Bool { usable == true }

    public init(id: String, kind: String?, code: String? = nil, codeMasked: String? = nil, title: String? = nil,
                from: String? = nil, balance: Double? = nil, currencyCode: String? = nil, validUntil: Int64? = nil,
                status: String? = nil, usable: Bool? = true, reason: String? = nil, storeName: String? = nil,
                logoUrl: String? = nil, ownedSince: Int64? = nil) {
        self.id = id
        self.kind = kind
        self.code = code
        self.codeMasked = codeMasked
        self.title = title
        self.from = from
        self.balance = balance
        self.currencyCode = currencyCode
        self.validUntil = validUntil
        self.status = status
        self.usable = usable
        self.reason = reason
        self.storeName = storeName
        self.logoUrl = logoUrl
        self.ownedSince = ownedSince
    }
}

public struct Wallet: Decodable, Sendable, Equatable {
    public let cards: [WalletCard]
    /// The Tap&Pay default the user set in the Lychee app, when it is one of `cards`.
    public let defaultCardId: String?
    public let canCreateOnePay: Bool?
    /// False for a business account.
    public let available: Bool?
    /// After creating a voucher: the new card.
    public let newCardId: String?

    public init(cards: [WalletCard], defaultCardId: String? = nil, canCreateOnePay: Bool? = true,
                available: Bool? = true, newCardId: String? = nil) {
        self.cards = cards
        self.defaultCardId = defaultCardId
        self.canCreateOnePay = canCreateOnePay
        self.available = available
        self.newCardId = newCardId
    }
}

public struct OnePaySettings: Decodable, Sendable, Equatable {
    public let voucherName: String?
    public let min: Double?
    public let max: Double?
    public let currencyCode: String?
    /// `PERMANENT`, `ONE_MONTH`, `THREE_MONTHS`, `SIX_MONTHS`, `ONE_YEAR`.
    public let validity: String?
    public let terms: [String]?
}

/// One card judged for one request: amount, currency and store included.
public struct CardOption: Decodable, Sendable, Equatable {
    public let cardId: String
    public let usable: Bool?
    public let reason: String?
    public let balance: Double?
}

/// A POS's payment request, as the phone reads it before paying.
public struct TapPreview: Decodable, Sendable, Equatable {
    public let storeName: String?
    public let amount: Double?
    public let currencyCode: String?
    /// Epoch millis.
    public let expiresAt: Int64?
    public let transit: Bool?
    public let options: [CardOption]?

    public func option(_ cardId: String?) -> CardOption? {
        options?.first { $0.cardId == cardId }
    }

    public func canPay(with cardId: String?) -> Bool {
        option(cardId)?.usable == true
    }
}

public struct TapReceipt: Decodable, Sendable, Equatable {
    public let txnRef: String?
    public let status: String?
    public let amount: Double?
    public let currencyCode: String?
    public let storeName: String?
    public let cardId: String?
    public let newBalance: Double?
    public let paidAt: Int64?

    /// Only an explicit `PAID` is success; anything this release cannot read is not.
    public var isPaid: Bool { status?.uppercased() == "PAID" }
}

/// The link a Lychee POS shows on its Tap to pay screen, as an NFC tag (and a QR code):
/// `https://<host>/pay?p=<payload>`.
public enum TapLink {
    /// The `p` parameter, byte for byte — never URL-decoded: the server checks a signature over
    /// exactly these bytes, and base64url never needs decoding.
    public static func payload(_ url: String?) -> String? {
        guard let text = url?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let afterScheme = text.range(of: "://").map { String(text[$0.upperBound...]) } ?? text
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let pathAndQuery = String(afterScheme[slash...])
        let pathPart = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let path = (pathPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed == "/pay", let question = pathAndQuery.firstIndex(of: "?") else { return nil }
        var query = String(pathAndQuery[pathAndQuery.index(after: question)...])
        if let hash = query.firstIndex(of: "#") { query = String(query[..<hash]) }
        for pair in query.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            if pair[..<equals] == "p" {
                let value = String(pair[pair.index(after: equals)...])
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
