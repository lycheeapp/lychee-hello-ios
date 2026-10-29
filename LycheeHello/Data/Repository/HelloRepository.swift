import Foundation
import Security

/// Request bodies for the Hello API.
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

    struct SendMessage: Encodable {
        let text: String?
        let form: PaymentForm?
        let clientMessageId: String?
        /// "Withdraw to bank" — the server composes the WhatsApp command `<IBAN> [amount]`.
        var withdrawal: WithdrawalForm? = nil
        /// Operator top-up — the server composes `topup <phone> <amount> <pin>`.
        var topUp: TopUpForm? = nil

        struct PaymentForm: Encodable {
            let payee: String
            let voucherCode: String?
            let amount: Double
        }

        /// A missing amount withdraws the whole available balance, as on WhatsApp.
        struct WithdrawalForm: Encodable {
            let iban: String
            let amount: Double?
        }

        /// The PIN is checked by the server and redacted before the message is stored.
        struct TopUpForm: Encodable {
            let recipientPhone: String
            let amount: Double
            let pin: String
        }
    }
}

/// Everything the app can ask the Hello backend to do.
///
/// A protocol so features depend on behaviour rather than on `APIClient`, which keeps view models
/// testable without a network and lets the transport change underneath.
public protocol HelloRepositoryProtocol: Sendable {
    func requestOtp(phoneNumber: String, countryCode: String) async throws -> OtpRequestResult
    func verifyOtp(phoneNumber: String, countryCode: String, code: String,
                   pushToken: String) async throws -> SessionResult
    func currentUser() async throws -> SessionResult
    func updateProfile(firstName: String, lastName: String) async throws -> HelloUser
    func walletBalance() async throws -> WalletBalance
    func registerPushToken(_ token: String) async throws
    func logout() async throws

    func generalConversation() async throws -> Conversation
    func conversations() async throws -> [Conversation]
    func messages(conversationId: String, before: String?, limit: Int) async throws -> MessagePage
    func sendText(conversationId: String, text: String, clientMessageId: String) async throws -> SendMessageResult
    func sendPaymentForm(conversationId: String, payee: String, voucherCode: String?,
                         amount: Double, clientMessageId: String) async throws -> SendMessageResult
    func sendWithdrawalForm(conversationId: String, iban: String, amount: Double?,
                            clientMessageId: String) async throws -> SendMessageResult
    func sendTopUpForm(conversationId: String, recipientPhone: String, amount: Double, pin: String,
                       clientMessageId: String) async throws -> SendMessageResult

    func paymentIntent(id: String) async throws -> PaymentIntent
    /// The payment awaiting confirmation, if any. `nil` is a normal answer, not an error.
    func pendingPaymentIntent() async throws -> PaymentIntent?
    func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent
    func cancelPayment(intentId: String) async throws -> PaymentIntent
}

public actor HelloRepository: HelloRepositoryProtocol {

    private let api: APIClient
    private let tokenStore: TokenStore
    private let deviceInfo: DeviceInfoProviding

    public init(
        api: APIClient = .shared,
        tokenStore: TokenStore = .shared,
        deviceInfo: DeviceInfoProviding = DeviceInfoProvider()
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.deviceInfo = deviceInfo
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

    public func currentUser() async throws -> SessionResult {
        try await api.get("me")
    }

    public func updateProfile(firstName: String, lastName: String) async throws -> HelloUser {
        try await api.patch(
            "me",
            body: HelloRequests.UpdateProfile(firstName: firstName, lastName: lastName)
        )
    }

    public func walletBalance() async throws -> WalletBalance {
        try await api.get("wallet/balance")
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

    // MARK: - Chat

    public func generalConversation() async throws -> Conversation {
        try await api.get("conversations/general")
    }

    public func conversations() async throws -> [Conversation] {
        try await api.get("conversations")
    }

    public func messages(conversationId: String, before: String?, limit: Int = 50) async throws -> MessagePage {
        var query = ["limit": String(limit)]
        if let before { query["before"] = before }
        return try await api.get("conversations/\(conversationId)/messages", query: query)
    }

    public func sendText(
        conversationId: String, text: String, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await api.post(
            "conversations/\(conversationId)/messages",
            body: HelloRequests.SendMessage(text: text, form: nil, clientMessageId: clientMessageId),
            idempotencyKey: clientMessageId
        )
    }

    /// Structured form path. The server composes the canonical command and runs the same parser as
    /// free text, so the two can never diverge.
    public func sendPaymentForm(
        conversationId: String, payee: String, voucherCode: String?,
        amount: Double, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await api.post(
            "conversations/\(conversationId)/messages",
            body: HelloRequests.SendMessage(
                text: nil,
                form: .init(payee: payee, voucherCode: voucherCode, amount: amount),
                clientMessageId: clientMessageId
            ),
            idempotencyKey: clientMessageId
        )
    }

    /// "Withdraw to bank" form. The server composes `<IBAN> [amount]` and runs the WhatsApp
    /// withdrawal flow; nothing is held until the review card is confirmed.
    public func sendWithdrawalForm(
        conversationId: String, iban: String, amount: Double?, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await api.post(
            "conversations/\(conversationId)/messages",
            body: HelloRequests.SendMessage(
                text: nil, form: nil, clientMessageId: clientMessageId,
                withdrawal: .init(iban: iban, amount: amount)
            ),
            idempotencyKey: clientMessageId
        )
    }

    /// Operator top-up form. Only offered when `/me` says the caller is an operator; the server
    /// checks that again, and the PIN, and never stores the PIN.
    public func sendTopUpForm(
        conversationId: String, recipientPhone: String, amount: Double, pin: String, clientMessageId: String
    ) async throws -> SendMessageResult {
        try await api.post(
            "conversations/\(conversationId)/messages",
            body: HelloRequests.SendMessage(
                text: nil, form: nil, clientMessageId: clientMessageId,
                topUp: .init(recipientPhone: recipientPhone, amount: amount, pin: pin)
            ),
            idempotencyKey: clientMessageId
        )
    }

    // MARK: - Payments

    public func paymentIntent(id: String) async throws -> PaymentIntent {
        try await api.get("payments/intents/\(id)")
    }

    public func pendingPaymentIntent() async throws -> PaymentIntent? {
        try await api.getOptional("payments/intents/pending")
    }

    /// Confirms a payment.
    ///
    /// `idempotencyKey` must be **stable across retries of the same user action** — that is what
    /// makes a retry after a dropped response safe rather than a double charge. Generate it once
    /// when the user taps, not per attempt.
    public func confirmPayment(intentId: String, idempotencyKey: String) async throws -> PaymentIntent {
        try await api.post("payments/intents/\(intentId)/confirm", idempotencyKey: idempotencyKey)
    }

    public func cancelPayment(intentId: String) async throws -> PaymentIntent {
        try await api.post("payments/intents/\(intentId)/cancel")
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
