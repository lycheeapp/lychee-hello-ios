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
            return L("error_offline")
        case .timedOut:
            return L("error_timed_out")
        case .unauthorized:
            return L("error_session_expired")
        case let .api(code, message, _):
            if let message, !message.isEmpty { return message }
            return APIError.fallbackMessage(for: code)
        case .decoding, .transport:
            return L("error_generic")
        }
    }

    private static func fallbackMessage(for code: HelloErrorCode) -> String {
        switch code {
        case .invalidPhoneNumber:      return L("error_invalid_phone_number")
        case .invalidVerificationCode: return L("error_invalid_code")
        case .rateLimited:             return L("error_rate_limited")
        case .walletNotActive:         return L("error_wallet_not_active")
        case .invalidMessageFormat:    return L("error_message_format")
        case .recipientNotFound:       return L("error_recipient_not_found")
        case .invalidAmount:           return L("error_invalid_amount")
        case .voucherNotUsable:        return L("error_voucher_not_usable")
        case .paymentAlreadyPending:   return L("error_payment_pending")
        case .paymentIntentExpired:    return L("error_payment_expired")
        case .paymentIntentNotActionable, .paymentIntentNotFound:
                                       return L("error_payment_unavailable")
        default:                       return L("error_generic")
        }
    }
}

/// Wire shape of the backend's error envelope.
struct APIErrorEnvelope: Decodable {
    let code: String?
    let message: String?
}
