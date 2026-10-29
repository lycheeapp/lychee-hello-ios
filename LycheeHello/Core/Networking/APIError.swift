import Foundation

/// Stable error codes returned by the Hello backend.
///
/// Mirrors `com.lychee.mobile.hello.dto.HelloErrorCode` exactly. The app switches on these and
/// **never** parses the human-readable message, which is localised and may be reworded server-side
/// at any time.
///
/// `unknown` exists so a backend that adds a code does not crash an older app — the single most
/// common way a strict enum breaks a shipped mobile client.
public enum HelloErrorCode: String, Sendable {
    case invalidPhoneNumber = "INVALID_PHONE_NUMBER"
    case invalidVerificationCode = "INVALID_VERIFICATION_CODE"
    case rateLimited = "RATE_LIMITED"
    case unauthorized = "UNAUTHORIZED"
    case profileIncomplete = "PROFILE_INCOMPLETE"
    case walletNotActive = "WALLET_NOT_ACTIVE"
    case invalidMessageFormat = "INVALID_MESSAGE_FORMAT"
    case recipientNotFound = "RECIPIENT_NOT_FOUND"
    case invalidAmount = "INVALID_AMOUNT"
    case voucherNotUsable = "VOUCHER_NOT_USABLE"
    case paymentAlreadyPending = "PAYMENT_ALREADY_PENDING"
    case paymentIntentNotFound = "PAYMENT_INTENT_NOT_FOUND"
    case paymentIntentNotActionable = "PAYMENT_INTENT_NOT_ACTIONABLE"
    case paymentIntentExpired = "PAYMENT_INTENT_EXPIRED"
    case paymentFailed = "PAYMENT_FAILED"
    case internalError = "INTERNAL_ERROR"
    case unknown = "UNKNOWN"

    public init(rawValueOrUnknown raw: String?) {
        self = raw.flatMap(HelloErrorCode.init(rawValue:)) ?? .unknown
    }
}

/// Everything that can go wrong on a Hello API call.
public enum APIError: Error, Sendable {
    /// The backend returned its structured error envelope.
    case api(code: HelloErrorCode, message: String?, status: Int)
    /// No usable connection. Distinguished from `.api` because it is retryable and the UI should
    /// say "check your connection" rather than surfacing a payment error.
    case offline
    case timedOut
    /// Session expired or invalid — the app must sign out and clear the token.
    case unauthorized
    case decoding(String)
    case transport(String)

    /// Whether a retry could plausibly succeed without user intervention.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut:
            return true
        case let .api(_, _, status):
            // 5xx may be transient. 4xx will not change on retry.
            return status >= 500
        case .transport:
            return true
        case .unauthorized, .decoding:
            return false
        }
    }

    public var code: HelloErrorCode? {
        if case let .api(code, _, _) = self { return code }
        if case .unauthorized = self { return .unauthorized }
        return nil
    }

    /// Copy safe to show a user. Never exposes transport internals or server stack detail.
    public var userMessage: String {
        switch self {
        case .offline:
            return "You appear to be offline. Check your connection and try again."
        case .timedOut:
            return "That took too long. Please try again."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case let .api(code, message, _):
            if let message, !message.isEmpty { return message }
            return APIError.fallbackMessage(for: code)
        case .decoding, .transport:
            return "Something went wrong. Please try again."
        }
    }

    private static func fallbackMessage(for code: HelloErrorCode) -> String {
        switch code {
        case .invalidPhoneNumber:      return "That phone number doesn't look right."
        case .invalidVerificationCode: return "That code isn't valid. Please check and try again."
        case .rateLimited:             return "Too many attempts. Please wait a moment."
        case .walletNotActive:         return "Your wallet is being activated. Payments will be available once your wallet is active."
        case .invalidMessageFormat:    return "Send a payment as \"payee amount\", or \"payee voucher amount\"."
        case .recipientNotFound:       return "We couldn't find that payee."
        case .invalidAmount:           return "That amount isn't valid."
        case .voucherNotUsable:        return "That voucher can't be used for this payment."
        case .paymentAlreadyPending:   return "You already have a payment waiting for confirmation."
        case .paymentIntentExpired:    return "This payment expired before it was confirmed."
        case .paymentIntentNotActionable, .paymentIntentNotFound:
                                       return "This payment is no longer available."
        default:                       return "Something went wrong. Please try again."
        }
    }
}

/// Wire shape of the backend's error envelope.
struct APIErrorEnvelope: Decodable {
    let code: String?
    let message: String?
}
