import Foundation
import FirebaseCrashlytics

/// Strips anything that must never reach a crash report.
///
/// Crashlytics payloads leave the device and are retained by a third party. In a payments app the
/// realistic leak vectors are error messages that embed a phone number, a voucher code, or a URL
/// containing an id — so redaction happens here rather than being left to each call site to
/// remember.
public enum Redactor {

    /// Phone numbers in E.164 or local form (7+ consecutive digits, optional leading +).
    private static let phonePattern = try? NSRegularExpression(pattern: #"\+?\d{7,15}"#)
    /// Bearer-ish tokens and the Lychee session token shape.
    private static let tokenPattern = try? NSRegularExpression(
        pattern: #"(?i)(token|authorization)[^\s]{0,12}[:=]\s*\S+"#)

    public static func redact(_ input: String?) -> String {
        guard let input, !input.isEmpty else { return "" }
        var output = input as NSString

        if let tokenPattern {
            output = tokenPattern.stringByReplacingMatches(
                in: output as String,
                range: NSRange(location: 0, length: output.length),
                withTemplate: "[redacted-token]") as NSString
        }
        if let phonePattern {
            output = phonePattern.stringByReplacingMatches(
                in: output as String,
                range: NSRange(location: 0, length: output.length),
                withTemplate: "[redacted-number]") as NSString
        }
        return output as String
    }
}

/// Crashlytics facade.
///
/// Everything the app reports goes through here so redaction cannot be bypassed, and so the
/// Crashlytics dependency stays in one file if it is ever swapped.
///
/// **Never recorded:** OTP codes, voucher codes, session tokens, full phone numbers, request or
/// response bodies, amounts tied to an identifiable payee.
public enum CrashReporter {

    public static func configure(environment: AppEnvironment) {
        Crashlytics.crashlytics().setCustomValue(environment.name.rawValue, forKey: "environment")
        Crashlytics.crashlytics().setCustomValue(environment.signingClientId, forKey: "signing_client")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Crashlytics.crashlytics().setCustomValue(version, forKey: "app_version")
    }

    /// Associates reports with an opaque server id — **never** the phone number.
    public static func setUser(id: Int64?) {
        Crashlytics.crashlytics().setUserID(id.map(String.init) ?? "")
    }

    /// Breadcrumb. Keep these coarse: screen transitions and state changes, not user input.
    public static func log(_ message: String) {
        Crashlytics.crashlytics().log(Redactor.redact(message))
    }

    /// Records a non-fatal API failure.
    ///
    /// Captures the endpoint and stable error code — enough to diagnose — and deliberately not the
    /// body, which on this app is where the sensitive values live.
    public static func recordAPIFailure(endpoint: String, error: APIError) {
        var info: [String: Any] = ["endpoint": endpoint]
        switch error {
        case let .api(code, _, status):
            info["error_code"] = code.rawValue
            info["http_status"] = status
        case .offline:      info["error_code"] = "OFFLINE"
        case .timedOut:     info["error_code"] = "TIMEOUT"
        case .unauthorized: info["error_code"] = "UNAUTHORIZED"
        case let .decoding(detail):  info["error_code"] = "DECODING"; info["detail"] = Redactor.redact(detail)
        case let .transport(detail): info["error_code"] = "TRANSPORT"; info["detail"] = Redactor.redact(detail)
        }
        Crashlytics.crashlytics().record(
            error: NSError(domain: "LycheeHello.API", code: 1, userInfo: info))
    }

    /// Records a payment failure by intent id and code only.
    ///
    /// The intent id is a server-side UUID and safe to correlate on; amount, recipient and voucher
    /// are intentionally omitted.
    public static func recordPaymentFailure(intentId: String?, code: String) {
        Crashlytics.crashlytics().record(
            error: NSError(domain: "LycheeHello.Payment", code: 2, userInfo: [
                "intent_id": intentId ?? "unknown",
                "error_code": code
            ]))
    }

    /// Records that OTP verification failed. **The code itself is never captured.**
    public static func recordOtpFailure(reason: String) {
        Crashlytics.crashlytics().record(
            error: NSError(domain: "LycheeHello.Auth", code: 3, userInfo: ["reason": reason]))
    }

    public static func recordRealtimeDrop(reason: String) {
        Crashlytics.crashlytics().log("realtime disconnected: \(reason)")
    }
}
