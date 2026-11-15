import Foundation
import Observation
import LycheeHelloKit

/// Owns the app's top-level state: who is signed in, and which flow should be on screen.
///
/// Single source of truth for routing so no screen decides for itself whether the user is
/// authenticated. What the Chats and Cards need — the user, the balance, the menu, and the realtime
/// connection, which is scoped to a session rather than to any one screen — lives in `kit`, the
/// Lychee Hello kit's session, which this fills in from sign-in and starts and stops with it.
@Observable
@MainActor
public final class SessionCoordinator {

    public static let shared = SessionCoordinator(repository: HelloRepository())

    public enum Route: Equatable {
        case launching
        case signedOut
        /// Verified, but a new user still owes us a name (decision D6).
        case onboarding
        case signedIn
    }

    public private(set) var route: Route = .launching

    /// The kit's session: put in the environment above the Chats and Cards.
    public let kit: HelloKitSession

    public var user: HelloUser? { kit.user }
    public var balance: WalletBalance? { kit.balance }

    /// Whether payments are permitted. Driven by the server's `payable` flag, never by balance
    /// (decision D7 — a wallet can hold funds and still be suspended).
    public var canPay: Bool { kit.canPay }

    /// The WhatsApp commands beyond paying that this account may use (`GET /me`). Decides what the
    /// "+" menu offers; the server checks again on every request.
    public var capabilities: Capabilities { kit.capabilities }

    /// Every account on this number (sign-in, `/me`). Most numbers have one; a person who also runs
    /// a business on it has two, and Settings offers a switch.
    public private(set) var accounts: [Account] = []

    /// The accounts this device could switch to.
    public var otherAccounts: [Account] { accounts.filter { !$0.current } }

    /// Set once after signing in to a number with two accounts: the app asks which to use, because
    /// payments come from the account on screen and guessing wrong would spend the wrong money.
    public var isChoosingAccount = false
    public private(set) var isSwitchingAccount = false
    public var accountSwitchError: String?

    private let repository: HelloRepositoryProtocol

    public init(repository: HelloRepositoryProtocol, realtime: RealtimeClient = SSERealtimeClient()) {
        self.repository = repository
        self.kit = HelloKitSession(repository: repository, realtime: realtime)
    }

    // MARK: - Lifecycle

    /// Called once at launch. Restores a session if the Keychain holds a token.
    public func start() async {
        await APIClient.shared.setUnauthorizedHandler { [weak self] in
            await self?.handleUnauthorized()
        }

        guard await TokenStore.shared.isSignedIn() else {
            route = .signedOut
            return
        }
        await loadSession()
    }

    /// After a successful OTP verification.
    public func didAuthenticate(_ result: SessionResult) async {
        kit.setUser(result.user)
        accounts = result.accounts ?? []
        CrashReporter.setUser(id: result.user?.id)

        if result.requiresOnboarding {
            route = .onboarding
            return
        }
        await enterSignedIn()
        isChoosingAccount = accounts.count > 1
    }

    /// After the name was changed in Settings (a guest's): the same account, renamed.
    public func didUpdateProfile(_ updated: HelloUser) {
        kit.setUser(updated)
    }

    /// After onboarding completes.
    public func didCompleteOnboarding(_ updated: HelloUser) async {
        kit.setUser(updated)
        await enterSignedIn()
        isChoosingAccount = accounts.count > 1
    }

    /// Moves this device to another account on the same number — from the person to their
    /// business, or back. Everything account-scoped is re-read: the balance, what "+" offers, and
    /// the chat (each account has its own thread).
    public func switchAccount(to account: Account) async {
        guard !isSwitchingAccount, !account.current else { return }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        // Close the event stream first: the switch ends the session it was opened with, and a
        // reconnect racing the switch would be refused with the old token.
        await kit.stopRealtime()
        do {
            let result = try await repository.switchAccount(to: account.type)
            kit.setUser(result.user)
            accounts = result.accounts ?? []
            kit.resetAccountState()
            CrashReporter.setUser(id: result.user?.id)
            if result.requiresOnboarding {
                route = .onboarding
            } else {
                await enterSignedIn()
            }
            // No chat refresh here: the tabs are rebuilt for the new account (MainTabView keys
            // them on the user), and the new chat loads itself. A refresh on top of that load asked
            // for the new account's thread twice at once.
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "auth/switch-account", error: error)
            accountSwitchError = error.userMessage
            if route == .signedIn { await kit.startRealtime() }
        } catch {
            accountSwitchError = L("settings_switch_failed_body")
            if route == .signedIn { await kit.startRealtime() }
        }
    }

    /// Deactivates this Lychee Hello account on the server, then signs out here. The server ends
    /// every Hello session of the account; signing in again with the number reactivates it.
    /// - Throws: when the server did not deactivate it — the user stays signed in and is told.
    public func deactivateAccount() async throws {
        try await repository.deactivateAccount()
        await leaveSignedOut()
    }

    /// Deletes this Lychee Hello account on the server, then signs out here. The server deletes its
    /// chats and ends every Hello session; an account with no Lychee account is erased. A Lychee
    /// account and its wallet stay — they are deleted in the Lychee app.
    /// - Throws: when the server did not delete it — the user stays signed in and is told.
    public func deleteAccount() async throws {
        try await repository.deleteAccount()
        await leaveSignedOut()
    }

    /// The server ended this account's sessions: forget it here and go back to sign-in.
    private func leaveSignedOut() async {
        await kit.stop()
        await TokenStore.shared.clear()
        accounts = []
        isChoosingAccount = false
        CrashReporter.setUser(id: nil)
        route = .signedOut
    }

    public func signOut() async {
        await kit.stopRealtime()
        try? await repository.logout()
        await kit.stop()
        accounts = []
        isChoosingAccount = false
        CrashReporter.setUser(id: nil)
        route = .signedOut
    }

    // MARK: - State

    private func loadSession() async {
        do {
            let session = try await repository.currentUser()
            kit.setUser(session.user)
            kit.setCapabilities(session.capabilities ?? Capabilities())
            accounts = session.accounts ?? []
            CrashReporter.setUser(id: session.user?.id)
            if session.requiresOnboarding {
                route = .onboarding
            } else {
                await enterSignedIn()
            }
        } catch APIError.unauthorized {
            route = .signedOut
        } catch {
            // Offline at launch with a stored token: let the user in and let individual screens
            // surface their own failures. Forcing a sign-out here would be hostile — the session is
            // probably still valid.
            route = .signedIn
            await kit.startRealtime()
        }
    }

    private func enterSignedIn() async {
        route = .signedIn
        await kit.refreshBalance()
        await kit.startRealtime()
        syncPushTokenWhenAvailable()
        await refreshCapabilities()
    }

    /// The sign-in response carries no capabilities, so they are read from `/me` once signed in.
    /// A failure keeps the last known value: the menu simply offers less until the next launch.
    public func refreshCapabilities() async {
        guard let session = try? await repository.currentUser() else { return }
        if let fresh = session.capabilities {
            kit.setCapabilities(fresh)
        }
        if let fresh = session.accounts {
            accounts = fresh
        }
    }

    /// Registers the real FCM token once it exists.
    ///
    /// Sign-in deliberately does not wait for FCM — a registration token can be slow, refused, or
    /// (on the Simulator) never issued, and authentication must not hinge on a third-party service.
    /// The account is created with a placeholder; this replaces it when a real token turns up.
    ///
    /// Detached and failure-tolerant: pushes are a convenience, and SSE plus foreground refresh
    /// already keep state correct without them.
    private func syncPushTokenWhenAvailable() {
        Task { [weak self] in
            // Generous: the token often arrives seconds after launch, sometimes after a permission
            // prompt is answered.
            guard let token = await AppDelegate.pushToken.value(timeout: 60),
                  !PushTokenPlaceholder.isPlaceholder(token) else {
                CrashReporter.log("no FCM token available; device will not receive pushes")
                return
            }
            do {
                try await self?.repository.registerPushToken(token)
                CrashReporter.log("FCM token registered")
            } catch {
                // Non-fatal by design.
                CrashReporter.log("FCM token registration failed")
            }
        }
    }

    public func refreshBalance() async {
        await kit.refreshBalance()
    }

    private func handleUnauthorized() async {
        await kit.stop()
        accounts = []
        route = .signedOut
    }

    /// Push tap: the payload is untrusted, so re-read authoritative state.
    public func refreshAfterPush() async {
        guard route == .signedIn else { return }
        await kit.refreshAfterPush()
    }
}
