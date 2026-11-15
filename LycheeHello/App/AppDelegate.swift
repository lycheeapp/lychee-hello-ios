import UIKit
import FirebaseCore
import FirebaseCrashlytics
import FirebaseMessaging
import UserNotifications

/// Firebase bootstrap and push registration.
///
/// A `UIApplicationDelegate` is still required: APNs token delivery and `MessagingDelegate` have no
/// pure-SwiftUI equivalent.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Resolved once the FCM token arrives. The backend rejects a device without a push token
    /// (`DeviceUtils.validateDevice`), so OTP verification cannot complete before this exists —
    /// which is why it is awaited rather than read optimistically.
    static let pushToken = PushTokenBox()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        CrashReporter.configure(environment: .current)

        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self

        // Registration is started immediately; the *permission prompt* is deferred to the point
        // where notifications are actually explained (see PushPermission.request), because asking
        // on first launch measurably tanks opt-in.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal: the app still works, it just cannot receive background payment updates.
        CrashReporter.log("APNs registration failed: \(error.localizedDescription)")
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { await AppDelegate.pushToken.set(fcmToken) }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Foreground presentation, the way WhatsApp does it.
    ///
    /// Looking at the chat, the message is already on screen (SSE delivered it), so only the sound
    /// plays. Anywhere else in the app — Stores, Cards, Settings — the banner shows too, so a
    /// payment received is never missed. Either way the balance and the chat are refetched: the
    /// push may be the first the app hears of it when the realtime stream was down.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await SessionCoordinator.shared.refreshAfterPush()
        return await MainActor.run { ChatVisibility.isShowing } ? [.sound, .list] : [.banner, .list, .sound]
    }

    /// Tapping a push must **fetch**, never trust the payload.
    ///
    /// FCM can drop, delay, coalesce and truncate; rendering payment state from a notification body
    /// would show the user something the server never confirmed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        CrashReporter.log("push opened")
        await SessionCoordinator.shared.refreshAfterPush()
    }
}

/// Async box for the FCM token, so callers can await it rather than poll.
///
/// Every continuation is resumed exactly once — either by `set` when the token arrives, or by the
/// timeout. Resuming twice is a hard crash in Swift, so `waiters` is drained under actor isolation
/// before any resume.
actor PushTokenBox {
    private var token: String?
    private var waiters: [CheckedContinuation<String?, Never>] = []

    func set(_ value: String) {
        token = value
        drain(with: value)
    }

    /// Current token, or `nil` if not yet issued.
    func current() -> String? { token }

    /// Waits for a token, giving up after `timeout` so a push-registration failure cannot strand
    /// the user on a spinner.
    func value(timeout: TimeInterval = 8) async -> String? {
        if let token { return token }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            waiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutExpired()
            }
        }
    }

    private func timeoutExpired() {
        guard token == nil else { return }
        drain(with: nil)
    }

    private func drain(with value: String?) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

/// Stand-in used when sign-in happens before FCM has issued a registration token.
///
/// The backend requires `notificationsToken` to be non-empty, but authentication must not wait on a
/// third-party service. The placeholder is deliberately recognisable so it can be spotted in the
/// devices table and is obviously not a deliverable token — sends to it fail and are swallowed by
/// the server's push path.
enum PushTokenPlaceholder {
    static let prefix = "pending-ios:"

    static func make() -> String {
        prefix + DeviceInfoProvider().installationId
    }

    static func isPlaceholder(_ token: String?) -> Bool {
        token?.hasPrefix(prefix) ?? false
    }
}

/// Notification permission, requested at a moment the user understands.
enum PushPermission {
    @discardableResult
    static func request() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        CrashReporter.log("push permission granted=\(granted)")
        return granted
    }
}
