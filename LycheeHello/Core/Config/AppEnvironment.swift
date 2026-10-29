import Foundation

/// Runtime configuration, sourced entirely from `Info.plist` (populated by the active `.xcconfig`).
///
/// Nothing in the app hardcodes a URL, client id or key id. That is what allows the same source to
/// build against dev and production, and what makes adding a staging tier later a config change
/// rather than an architectural one (decision U7).
///
/// Fails **loudly at startup** on missing or placeholder configuration. A payments app that
/// silently falls back to a default host, or ships with an unreplaced key-id placeholder, is far
/// more dangerous than one that refuses to launch.
public struct AppEnvironment: Sendable {

    public enum Name: String, Sendable {
        case dev
        case prod
    }

    public let name: Name
    /// e.g. `https://apitest.lycheeapp.org/rest/lychee-v2`
    public let apiBaseURL: URL
    /// e.g. `/hello/v1`
    public let helloPath: String
    public let signingClientId: String
    public let signingKeyId: String
    public let logNetwork: Bool

    /// Fully-qualified base for every Hello endpoint.
    public var helloBaseURL: URL {
        apiBaseURL.appendingPathComponent(helloPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    public var isProduction: Bool { name == .prod }

    public static let current: AppEnvironment = {
        do {
            return try AppEnvironment(bundle: .main)
        } catch {
            // Deliberate: an unconfigured payments build must not run.
            fatalError("Lychee Hello configuration error: \(error)")
        }
    }()

    enum ConfigError: Error, CustomStringConvertible {
        case missing(String)
        case invalidURL(String, String)
        case placeholderNotReplaced(String, String)

        var description: String {
            switch self {
            case let .missing(key):
                return "Info.plist is missing required key '\(key)'. Check the active xcconfig."
            case let .invalidURL(key, value):
                return "Info.plist key '\(key)' is not a valid URL: '\(value)'."
            case let .placeholderNotReplaced(key, value):
                return """
                Info.plist key '\(key)' still holds the build-time placeholder '\(value)'. \
                The release pipeline must substitute the real value before archiving.
                """
            }
        }
    }

    init(bundle: Bundle) throws {
        func string(_ key: String) throws -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigError.missing(key)
            }
            return value.trimmingCharacters(in: .whitespaces)
        }

        let rawBase = try string("LYCHEE_API_BASE_URL")
        guard let baseURL = URL(string: rawBase), baseURL.scheme != nil else {
            throw ConfigError.invalidURL("LYCHEE_API_BASE_URL", rawBase)
        }

        let keyId = try string("LYCHEE_SIGNING_KEY_ID")
        let envName = Name(rawValue: try string("LYCHEE_ENVIRONMENT_NAME")) ?? .dev

        // The Release xcconfig ships a deliberate placeholder so a misconfigured archive fails
        // here rather than sending requests the backend will reject (or, worse, accept unsigned).
        if envName == .prod, keyId == "REPLACE_AT_BUILD_TIME" {
            throw ConfigError.placeholderNotReplaced("LYCHEE_SIGNING_KEY_ID", keyId)
        }

        self.name = envName
        self.apiBaseURL = baseURL
        self.helloPath = try string("LYCHEE_API_HELLO_PATH")
        self.signingClientId = try string("LYCHEE_SIGNING_CLIENT_ID")
        self.signingKeyId = keyId
        // Network logging is force-disabled in production regardless of configuration — request
        // logs on a payments app are a data-leak vector.
        self.logNetwork = (try? string("LYCHEE_LOG_NETWORK")) == "YES" && envName != .prod
    }
}
