import Foundation
@_exported import LycheeHelloKit

/// Lychee Hello as the kit's host: its own Keychain session, its LYCHEE-SIGN-V1 key, its language
/// and its crash reporter.
///
/// The `@_exported import` makes the kit's types visible across the app (and to its tests through
/// `@testable import LycheeHello`) without importing it in every file.
struct HelloAppKitHost: HelloKitHost {

    private let environment: AppEnvironment
    private let tokenStore: TokenStore

    init(environment: AppEnvironment = .current, tokenStore: TokenStore = .shared) {
        self.environment = environment
        self.tokenStore = tokenStore
    }

    var helloBaseURL: URL { environment.helloBaseURL }

    func sessionToken() async -> String? {
        await tokenStore.token()
    }

    func signingHeaders(method: String, url: URL, body: Data?) -> [String: String] {
        RequestSigner.sign(method: method, url: url, body: body)?.headers ?? [:]
    }

    /// The session is dead: forget it. `SessionCoordinator` routes to sign-in.
    func sessionRefused(token: String) async {
        await tokenStore.clear()
    }

    var pinnedLanguageTag: String? { AppLanguage.current.tag }

    /// "Lychee Hello" where the kit says "Lychee". Read from the app's own strings directly, not
    /// through `L`, which falls back to the kit and would ask here again.
    func localizedOverride(forKey key: String) -> String? {
        let appKey: String
        switch key {
        case "hellokit_brand": appKey = "app_name"
        case "receipt_footer": appKey = "receipt_footer"
        default: return nil
        }
        let missing = "\u{1}"
        let value = AppLanguage.bundle.localizedString(forKey: appKey, value: missing, table: nil)
        return value == missing ? nil : value
    }

    var logsNetwork: Bool { environment.logNetwork }

    func log(_ message: String) { CrashReporter.log(message) }

    func recordAPIFailure(endpoint: String, error: APIError) {
        CrashReporter.recordAPIFailure(endpoint: endpoint, error: error)
    }

    func recordPaymentFailure(intentId: String, code: String) {
        CrashReporter.recordPaymentFailure(intentId: intentId, code: code)
    }

    func recordRealtimeDrop(reason: String) {
        CrashReporter.recordRealtimeDrop(reason: reason)
    }
}
