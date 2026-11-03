import Foundation

// Domain models mirroring the Hello backend contract.
//
// Deliberately `Decodable` structs rather than a mapping layer: the backend DTOs are already narrow
// and Hello-specific, so an extra translation tier would add ceremony without insulating anything.
// If the wire format ever diverges from what the UI wants, introduce mappers then — not now.

public enum UserState: String, Decodable, Sendable {
    case existing = "EXISTING"
    case new = "NEW"
}

public struct HelloUser: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let firstName: String?
    public let lastName: String?
    public let displayName: String?
    public let phoneNumber: String?
    public let countryCode: String?
    public let profilePictureUrl: String?
    /// `MOBILE_USER` (a person) or `SERVICE_PROVIDER` (a business).
    public var accountType: String? = nil
    /// A business's payee code ("RIO1"); `nil` for a person.
    public var accountCode: String? = nil

    /// Signed in as a business rather than as a person.
    public var isBusiness: Bool { accountType == Account.business }

    /// Signed in with no Lychee account: pays from the vouchers sent to the number, has no wallet.
    /// The Lychee app is where full access is.
    public var isGuest: Bool { accountType == Account.guest }

    /// Screenshot shows "Talal Raddad" — first + last (decision D6).
    public var resolvedDisplayName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    /// "TR" for the settings avatar.
    public var initials: String {
        let parts = [firstName, lastName].compactMap { $0?.first }.map(String.init)
        return parts.isEmpty ? "?" : parts.joined().uppercased()
    }
}

public struct SessionResult: Decodable, Sendable {
    public let authToken: String?
    public let userState: UserState?
    public let profileComplete: Bool
    public let walletStatus: String?
    public let kycStatus: String?
    public let user: HelloUser?
    /// Which WhatsApp commands beyond paying this account may use. Sent by `GET /me` only.
    public var capabilities: Capabilities? = nil
    /// Every account on this number — the person's own, and a business run on it. More than one
    /// means the app offers a switch.
    public var accounts: [Account]? = nil

    /// A brand-new user must complete onboarding before the chat is useful (decision D6).
    public var requiresOnboarding: Bool {
        userState == .new || !profileComplete
    }
}

/// One account on a phone number: the person, or a business they run on it.
public struct Account: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public static let person = "MOBILE_USER"
    public static let business = "SERVICE_PROVIDER"
    /// A number with no Lychee account.
    public static let guest = "HELLO_GUEST"

    public let type: String
    public let name: String?
    /// A business's payee code ("RIO1"); `nil` for a person.
    public let code: String?
    /// The account this session is signed in as.
    public let current: Bool

    public var id: String { type }
    public var isBusiness: Bool { type == Account.business }

    /// "Personal account" / "Business account · RIO1", in the app's language.
    public var kindLabel: String {
        guard isBusiness else { return L("account_personal") }
        if let code, !code.isEmpty { return L("account_business_code", code) }
        return L("account_business")
    }

    public init(type: String, name: String?, code: String?, current: Bool) {
        self.type = type
        self.name = name
        self.code = code
        self.current = current
    }
}

/// The commands beyond paying that this account may use — what the "+" menu offers. Each flag is
/// the server's answer about the caller only; the app never decides who is an operator.
public struct Capabilities: Decodable, Sendable, Equatable {
    /// `<IBAN> [amount]`: withdraw to a bank account.
    public var withdraw: Bool = false
    /// `topup <phone> <amount> <pin>`: an operator's balance top-up for a customer.
    public var topUp: Bool = false
    /// Create OnePay vouchers: a person's Lychee account only.
    public var createVoucher: Bool = false

    public init(withdraw: Bool = false, topUp: Bool = false, createVoucher: Bool = false) {
        self.withdraw = withdraw
        self.topUp = topUp
        self.createVoucher = createVoucher
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        withdraw = try container.decodeIfPresent(Bool.self, forKey: .withdraw) ?? false
        topUp = try container.decodeIfPresent(Bool.self, forKey: .topUp) ?? false
        createVoucher = try container.decodeIfPresent(Bool.self, forKey: .createVoucher) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case withdraw, topUp, createVoucher
    }
}

public struct OtpRequestResult: Decodable, Sendable {
    public let expiresInSeconds: Int
    public let codeLength: Int
    public let resendAfterSeconds: Int
}

public struct WalletBalance: Decodable, Sendable, Equatable {
    public let amount: Double
    public let currencyCode: String?
    public let status: String?
    /// Authoritative gate for payment affordances — a wallet can hold funds and still be
    /// SUSPENDED (decision D7). Never infer payability from `amount`.
    public let payable: Bool
    /// `WALLET`, or `VOUCHERS` for an account with no wallet (no Lychee account): the amount is the
    /// vouchers sent to the number added up, and it is never "activating".
    public var source: String? = nil

    public var isVouchers: Bool { source?.uppercased() == "VOUCHERS" }
}

// MARK: - Chat

public enum MessageDirection: String, Decodable, Sendable {
    case inbound = "INBOUND"    // from the user
    case outbound = "OUTBOUND"  // from Lychee
}

public enum MessageType: String, Decodable, Sendable {
    case text = "TEXT"
    case quickReplies = "QUICK_REPLIES"
    case paymentReview = "PAYMENT_REVIEW"
    case paymentReceipt = "PAYMENT_RECEIPT"
    /// Money that arrived from someone else — WhatsApp's "you received a payment".
    case paymentReceived = "PAYMENT_RECEIVED"
    case system = "SYSTEM"
    case error = "ERROR"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageType(rawValue: raw) ?? .unknown
    }
}

public enum MessageStatus: String, Decodable, Sendable {
    case sent = "SENT"
    case delivered = "DELIVERED"
    case read = "READ"
    case failed = "FAILED"
}

public struct ChatMessage: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let direction: MessageDirection
    public let type: MessageType
    public let body: String?
    public let payload: String?
    public let status: MessageStatus?
    public let paymentIntentId: String?
    public let sentAt: Date?
    /// On a review card: the payment as it stands now — paid (with its reference), cancelled or
    /// expired — so a closed card can say how it ended.
    public var paymentIntent: PaymentIntent? = nil

    public var isFromUser: Bool { direction == .inbound }
}

public extension ChatMessage {

    /// A bubble drawn locally that the server has not acknowledged yet. Server rows always carry a
    /// status, so a missing one can only be ours.
    var isPending: Bool { isFromUser && status == nil }

    /// Everything except in-thread notices sits in a bubble.
    var rendersAsBubble: Bool { type != .system }

    func with(status: MessageStatus?) -> ChatMessage {
        var copy = ChatMessage(
            id: id,
            direction: direction,
            type: type,
            body: body,
            payload: payload,
            status: status,
            paymentIntentId: paymentIntentId,
            sentAt: sentAt
        )
        copy.paymentIntent = paymentIntent
        return copy
    }

    /// The same message with its payment brought up to date.
    func with(paymentIntent: PaymentIntent?) -> ChatMessage {
        var copy = self
        copy.paymentIntent = paymentIntent
        return copy
    }

    /// The payload's top-level fields as strings (numbers included), for display only.
    var payloadFields: [String: String] {
        guard let raw = payload?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return [:]
        }
        var flat: [String: String] = [:]
        for (key, value) in object {
            if let value = value as? String {
                flat[key] = value
            } else if let value = value as? NSNumber {
                flat[key] = value.stringValue
            }
        }
        return flat
    }

    /// Reply buttons attached to a `QUICK_REPLIES` message.
    var quickReplies: [String] {
        guard type == .quickReplies,
              let raw = payload?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let replies = object["quickReplies"] as? [String] else {
            return []
        }
        return replies
    }

    /// The reply buttons with their ids. The server sends a stable id next to each title
    /// (`form:balance`, `cmd:balance`…), as a WhatsApp button reply carries one, so a button works
    /// whatever language its title is in. Older messages have titles only.
    var quickReplyOptions: [QuickReply] {
        let titles = quickReplies
        guard !titles.isEmpty else { return [] }
        var ids: [String] = []
        if let raw = payload?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let values = object["quickReplyIds"] as? [String] {
            ids = values
        }
        return titles.enumerated().map { index, title in
            QuickReply(title: title, id: index < ids.count ? ids[index] : nil)
        }
    }

    /// Whether the text opens with a right-to-left script (Arabic, Hebrew), judged by its first
    /// letter the way the Unicode bidi algorithm picks a paragraph's direction.
    var isRightToLeft: Bool {
        guard let body else { return false }
        for scalar in body.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}

/// A reply button: what it says, and what it does (`id`, when the server sent one).
public struct QuickReply: Sendable, Equatable, Hashable {
    public let title: String
    public let id: String?
}

public struct Conversation: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String?
    public let title: String?
    public let lastMessageAt: Date?
    public let unreadCount: Int?
}

public struct MessagePage: Decodable, Sendable {
    public let messages: [ChatMessage]
    public let nextCursor: String?
}

// MARK: - Payments

public enum PaymentIntentStatus: String, Decodable, Sendable {
    case pending = "PENDING"
    case confirmed = "CONFIRMED"
    case executed = "EXECUTED"
    case cancelled = "CANCELLED"
    case expired = "EXPIRED"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaymentIntentStatus(rawValue: raw) ?? .unknown
    }

    public var isTerminal: Bool {
        self == .executed || self == .cancelled || self == .expired
    }
}

/// The review card and authoritative payment state.
///
/// **Every monetary value here is server-computed.** The client renders them and must never derive
/// its own total — the backend is the only authority on what a payment costs.
public struct PaymentIntent: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String?
    public let status: PaymentIntentStatus
    public let amount: Double?
    public let feeAmount: Double?
    public let totalAmount: Double?
    public let currencyCode: String?
    public let recipientDisplay: String?
    public let recipientCode: String?
    /// Already masked server-side, e.g. `••••2087`. The full code never reaches the client.
    public let voucherCodeMasked: String?
    public let expiresAt: Date?
    public let txnReference: String?
    public let errorCode: String?
    /// The kind of payment, named by the server in the user's language ("Bank withdrawal").
    public var title: String? = nil
    /// `SERVICE_PROVIDER`, `STORE`, `REDEMPTION_POINT`, `TRANSIT_VEHICLE`, `MOBILE_USER`…
    public var recipientType: String? = nil
    /// For a business payee, its line of work: `TAXI`, `BUS_OPERATOR`, `PLAYGROUND`.
    public var recipientCategory: String? = nil
    /// When the money moved.
    public var executedAt: Date? = nil
    /// Only on the confirm response: the receipt and anything after it, to show at once.
    public var messages: [ChatMessage]? = nil

    /// "Taxi · RIO1", "Store · BRV2", "Lychee user · ****3456" — what kind of payee, and the code
    /// the payer typed, under the payee's name.
    public var recipientSummary: String? {
        PaymentRecipient.summary(type: recipientType, category: recipientCategory, code: recipientCode)
    }

    /// A business, store, branch or bus: shown with a verified mark.
    public var isMerchantRecipient: Bool { PaymentRecipient.isMerchant(recipientType) }

    /// What kind of payment this is — it decides how the card and the review sheet read.
    public var paymentKind: PaymentKind { PaymentKind(raw: kind) }
}

/// How a payee is described under its name. Shared by the review card, the sheet and the receipt.
public enum PaymentRecipient {

    public static func kindLabel(type: String?, category: String?) -> String? {
        switch category?.uppercased() {
        case "TAXI": return L("payee_kind_taxi")
        case "BUS_OPERATOR": return L("payee_kind_bus_operator")
        case "PLAYGROUND": return L("payee_kind_playground")
        default: break
        }
        switch type?.uppercased() {
        case "SERVICE_PROVIDER": return L("payee_kind_business")
        case "STORE": return L("payee_kind_store")
        case "REDEMPTION_POINT": return L("payee_kind_branch")
        case "TRANSIT_VEHICLE": return L("payee_kind_bus")
        case "MOBILE_USER": return L("payee_kind_person")
        default: return nil
        }
    }

    public static func summary(type: String?, category: String?, code: String?) -> String? {
        let parts = [kindLabel(type: type, category: category), code].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func isMerchant(_ type: String?) -> Bool {
        switch type?.uppercased() {
        case "SERVICE_PROVIDER", "STORE", "REDEMPTION_POINT", "TRANSIT_VEHICLE": return true
        default: return false
        }
    }
}

/// The payments the WhatsApp channel takes, all reviewed and confirmed the same way.
public enum PaymentKind: Sendable, Equatable {
    case transfer
    case voucher
    /// `<IBAN> [amount]`: money to a bank account. `recipientDisplay` is the bank, `recipientCode`
    /// the masked IBAN, and `totalAmount` what the bank pays out.
    case withdrawal
    /// An operator's top-up for a customer; `recipientDisplay` is the customer's masked number.
    case topUp
    /// Paid at a Lychee POS from the Cards tab, by holding the phone near its Tap to pay screen.
    case tap
    case unknown

    public init(raw: String?) {
        switch raw?.uppercased() {
        case "TRANSFER": self = .transfer
        case "VOUCHER": self = .voucher
        case "MTB_REQUEST": self = .withdrawal
        case "TOPUP": self = .topUp
        case "TAP": self = .tap
        default: self = .unknown
        }
    }
}

public struct SendMessageResult: Decodable, Sendable {
    public let message: ChatMessage?
    public let replies: [ChatMessage]?
    public let paymentIntent: PaymentIntent?
}

// MARK: - Money formatting

public enum Money {
    /// Single currency at launch: ILS, displayed as ₪ (decision U2).
    public static let symbol = "₪"
    public static let currencyCode = "ILS"

    /// Renders "₪700" / "₪50.25". Whole amounts drop the decimals, matching the screenshots.
    public static func format(_ amount: Double?) -> String {
        guard let amount else { return "\(symbol)0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = amount == amount.rounded() ? 0 : 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(symbol)\(number)"
    }
}
