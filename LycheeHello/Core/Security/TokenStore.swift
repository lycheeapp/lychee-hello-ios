import Foundation
import Security

/// Keychain-backed storage for the Lychee session token.
///
/// An `actor` so concurrent callers (an API request refreshing while the realtime stream
/// reconnects) cannot race on the Keychain.
///
/// Design notes that matter for a payments app:
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the token survives a background relaunch
///   (needed for push-triggered fetches) but never leaves the device and is unavailable before
///   first unlock. Not `WhenUnlocked`, which would break background work; not a non-`ThisDeviceOnly`
///   class, which would sync the token to a restored backup or another device.
/// - The token is never written to `UserDefaults`, logged, or included in crash reports.
public actor TokenStore {

    public static let shared = TokenStore()

    private let service: String
    private let account = "session-auth-token"
    private var cached: String?

    public init(service: String = "org.lycheeapp.lychee-hello.session") {
        self.service = service
    }

    /// Current token, or `nil` when signed out.
    public func token() -> String? {
        if let cached { return cached }
        let value = readFromKeychain()
        cached = value
        return value
    }

    public func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError.keychain(status)
        }
        cached = token
    }

    /// Removes the token. Called on sign-out and whenever the backend reports the session invalid.
    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        cached = nil
    }

    public func isSignedIn() -> Bool {
        token() != nil
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

public enum TokenStoreError: Error, Equatable {
    case encodingFailed
    case keychain(OSStatus)
}
