import Foundation
import Security
import LycheeHelloKit

/// Request bodies for sign-in and the session. The Chats and Cards have theirs in the kit.
enum HelloRequests {

    struct OtpRequest: Encodable {
        let phoneNumber: String
        let countryCode: String
        let deviceUdid: String?
    }

    struct OtpVerify: Encodable {
        let phoneNumber: String
        let countryCode: String
        let code: String
        let device: Device

        struct Device: Encodable {
            let notificationsToken: String
            let operatingSystem: String
            let userAgent: String?
            let udid: String?
        }
    }

    struct UpdateProfile: Encodable {
        let firstName: String
        let lastName: String
    }

    struct UpdateFcmToken: Encodable {
        let notificationsToken: String
    }

    struct SwitchAccount: Encodable {
        let accountType: String
    }
}

/// Everything the app can ask the Hello backend to do: sign-in and the session here, and the
/// Chats and Cards from the Lychee Hello kit's repository.
///
/// A protocol so features depend on behaviour rather than on `APIClient`, which keeps view models
/// testable without a network and lets the transport change underneath.
public protocol HelloRepositoryProtocol: HelloKitRepositoryProtocol {
    func requestOtp(phoneNumber: String, countryCode: String) async throws -> OtpRequestResult
    func verifyOtp(phoneNumber: String, countryCode: String, code: String,
                   pushToken: String) async throws -> SessionResult
    func updateProfile(firstName: String, lastName: String) async throws -> HelloUser
    func registerPushToken(_ token: String) async throws
    func logout() async throws
    /// Moves this device to another account on the same number (person ↔ business). Saves the
    /// new session token, as sign-in does.
    func switchAccount(to accountType: String) async throws -> SessionResult
    /// Deactivates this Lychee Hello account: every Hello session of it ends; signing in again
    /// reactivates it. The Lychee account, wallet and vouchers are untouched.
    func deactivateAccount() async throws
    /// Deletes this Lychee Hello account: its chats go and every Hello session of it ends; an account
    /// with no Lychee account is erased. A Lychee account and its wallet are not deleted here.
    func deleteAccount() async throws
}

/// Defaults so a test double that has nothing to do with the account need not stub them.
public extension HelloRepositoryProtocol {
    func deactivateAccount() async throws { throw APIError.transport("not supported") }
    func deleteAccount() async throws { throw APIError.transport("not supported") }
}

public actor HelloRepository: HelloRepositoryProtocol {

    private let api: APIClient
    private let tokenStore: TokenStore
    private let deviceInfo: DeviceInfoProviding
    /// The Chats and Cards' calls.
    private let kit: HelloKitRepository

    public init(
        api: APIClient = .shared,
        tokenStore: TokenStore = .shared,
        deviceInfo: DeviceInfoProviding = DeviceInfoProvider()
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.deviceInfo = deviceInfo
        self.kit = HelloKitRepository(api: api)
    }

    // MARK: - Auth

    public func requestOtp(phoneNumber: String, countryCode: String) async throws -> OtpRequestResult {
        try await api.post(
            "auth/otp/request",
            body: HelloRequests.OtpRequest(
                phoneNumber: phoneNumber,
                countryCode: countryCode,
                deviceUdid: deviceInfo.installationId
            )
        )
    }

    /// Verifies the code and persists the session token.
    ///
    /// The backend rejects a device without a push token (`DeviceUtils.validateDevice`), so the
    /// caller must obtain one before reaching here.
    public func verifyOtp(
        phoneNumber: String, countryCode: String, code: String, pushToken: String
    ) async throws -> SessionResult {
        let result: SessionResult = try await api.post(
            "auth/otp/verify",
            body: HelloRequests.OtpVerify(
                phoneNumber: phoneNumber,
                countryCode: countryCode,
                code: code,
                device: .init(
                    notificationsToken: pushToken,
                    operatingSystem: "IOS",
                    userAgent: deviceInfo.userAgent,
                    udid: deviceInfo.installationId
                )
            )
        )
        if let token = result.authToken {
            try await tokenStore.save(token)
        }
        return result
    }

    public func updateProfile(firstName: String, lastName: String) async throws -> HelloUser {
        try await api.patch(
            "me",
            body: HelloRequests.UpdateProfile(firstName: firstName, lastName: lastName)
        )
    }

    /// Registers the real FCM token after sign-in.
    ///
    /// Sign-in proceeds with a placeholder when FCM has not produced a token yet (common on the
    /// Simulator), so this is what turns pushes on for the device.
    public func registerPushToken(_ token: String) async throws {
        let _: EmptyResponse = try await api.put(
            "devices/fcm-token",
            body: HelloRequests.UpdateFcmToken(notificationsToken: token)
        )
    }

    /// Clears the local token even if the server call fails — a user tapping "log out" must end up
    /// signed out locally regardless of connectivity.
    public func logout() async throws {
        defer { Task { await tokenStore.clear() } }
        try? await api.delete("auth/logout")
    }

    /// The server ends this session too, so the token is cleared here whatever the answer body.
    public func deactivateAccount() async throws {
        let _: EmptyResponse = try await api.post("me/deactivate")
        await tokenStore.clear()
    }

    /// As `deactivateAccount`, for good: the server deletes the account's Hello data.
    public func deleteAccount() async throws {
        let _: EmptyResponse = try await api.post("me/delete")
        await tokenStore.clear()
    }

    public func switchAccount(to accountType: String) async throws -> SessionResult {
        let result: SessionResult = try await api.post(
            "auth/switch-account",
            body: HelloRequests.SwitchAccount(accountType: accountType)
        )
        if let token = result.authToken {
            try await tokenStore.save(token)
        }
        return result
    }

    // MARK: - Chats and Cards (the kit's)

    public func currentUser() async throws -> SessionResult { try await kit.currentUser() }
    public func walletBalance() async throws -> WalletBalance { try await kit.walletBalance() }

    public func generalConversation() async throws -> Conversation { try await kit.generalConversation() }
    public func conversations() async throws -> [Conversation] { try await kit.conversations() }
    public func messages(conversationId: String, before: String?, limit: Int = 50) async throws -> MessagePage {
        try await kit.messages(conversationId: conversationId, before: before, limit: limit)
    }
    public func sendText(conversationId: String, text: String, clientMessageId: String) async throws -> SendMessageResult {
        try await kit.sendText(conversationId: conversationId, text: text, clientMessageId: clientMessageId)
    }
    public func sendPaymentForm(
        conversationId: String, payee: String, voucherCode: String?, amount: Double, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await kit.sendPaymentForm(conversationId: conversationId, payee: payee, voucherCode: voucherCode,
                                      amount: amount, clientMessageId: clientMessageId)
    }
    public func sendWithdrawalForm(
        conversationId: String, iban: String, amount: Double?, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await kit.sendWithdrawalForm(conversationId: conversationId, iban: iban, amount: amount,
                                         clientMessageId: clientMessageId)
    }
    public func sendTopUpForm(
        conversationId: String, recipientPhone: String, amount: Double, pin: String, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await kit.sendTopUpForm(conversationId: conversationId, recipientPhone: recipientPhone, amount: amount,
                                    pin: pin, clientMessageId: clientMessageId)
    }

    public func paymentIntent(id: String) async throws -> PaymentIntent { try await kit.paymentIntent(id: id) }
    public func pendingPaymentIntent() async throws -> PaymentIntent? { try await kit.pendingPaymentIntent() }
    public func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent {
        try await kit.confirmPayment(intentId: intentId, idempotencyKey: idempotencyKey)
    }
    public func cancelPayment(intentId: String) async throws -> PaymentIntent { try await kit.cancelPayment(intentId: intentId) }

    public func directory(query: String?, page: Int) async throws -> DirectoryPage {
        try await kit.directory(query: query, page: page)
    }
    public func lookupPayee(_ payee: String) async throws -> PayeeLookup { try await kit.lookupPayee(payee) }
    public func recentPayees() async throws -> [RecentPayee] { try await kit.recentPayees() }
    public func paymentHistory(query: String?, before: Int64?) async throws -> HistoryPage {
        try await kit.paymentHistory(query: query, before: before)
    }

    public func wallet() async throws -> Wallet { try await kit.wallet() }
    public func onePaySettings() async throws -> OnePaySettings { try await kit.onePaySettings() }
    public func createOnePay(amount: Double, acceptedTerms: Bool, recipientName: String?,
                             recipientPhone: String?) async throws -> Wallet {
        try await kit.createOnePay(amount: amount, acceptedTerms: acceptedTerms,
                                   recipientName: recipientName, recipientPhone: recipientPhone)
    }
    public func tapPreview(payload: String) async throws -> TapPreview { try await kit.tapPreview(payload: payload) }
    public func tapPay(payload: String, cardId: String) async throws -> TapReceipt {
        try await kit.tapPay(payload: payload, cardId: cardId)
    }
}

// MARK: - Device info

public protocol DeviceInfoProviding: Sendable {
    /// Stable per-install id, fed to the backend's abuse limiters.
    var installationId: String { get }
    var userAgent: String { get }
}

public struct DeviceInfoProvider: DeviceInfoProviding {

    private static let installationIdKey = "org.lycheeapp.hello.installationId"

    public init() {}

    /// Persisted in the Keychain rather than `UserDefaults` so it survives reinstall, which is what
    /// makes it useful as an abuse signal. `identifierForVendor` resets on reinstall and is
    /// therefore weaker for this purpose.
    public var installationId: String {
        if let existing = Self.readKeychain(key: Self.installationIdKey) {
            return existing
        }
        let generated = UUID().uuidString
        Self.writeKeychain(key: Self.installationIdKey, value: generated)
        return generated
    }

    public var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "LycheeHello-iOS/\(version)(\(build))"
    }

    private static func readKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
