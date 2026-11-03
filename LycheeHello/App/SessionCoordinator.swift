import Foundation
import Observation

/// Owns the app's top-level state: who is signed in, and which flow should be on screen.
///
/// Single source of truth for routing so no screen decides for itself whether the user is
/// authenticated. It also owns the realtime connection lifecycle, because that is scoped to a
/// session rather than to any one screen — a stream started by the chat screen would die when the
/// user visits Settings.
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
    public private(set) var user: HelloUser?
    public private(set) var balance: WalletBalance?

    /// Whether payments are permitted. Driven by the server's `payable` flag, never by balance
    /// (decision D7 — a wallet can hold funds and still be suspended).
    public var canPay: Bool { balance?.payable ?? false }

    /// The WhatsApp commands beyond paying that this account may use (`GET /me`). Decides what the
    /// "+" menu offers; the server checks again on every request.
    public private(set) var capabilities = Capabilities()

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
    private let realtime: RealtimeClient
    private let dedup = RealtimeDeduplicator()

    private var realtimeTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    /// Bumped whenever something invalidates chat state, so the chat screen can refetch without
    /// the coordinator knowing anything about chat.
    public private(set) var chatInvalidationToken = UUID()

    public init(repository: HelloRepositoryProtocol, realtime: RealtimeClient = SSERealtimeClient()) {
        self.repository = repository
        self.realtime = realtime
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
        user = result.user
        accounts = result.accounts ?? []
        CrashReporter.setUser(id: result.user?.id)

        if result.requiresOnboarding {
            route = .onboarding
            return
        }
        await enterSignedIn()
        isChoosingAccount = accounts.count > 1
    }

    /// After onboarding completes.
    public func didCompleteOnboarding(_ updated: HelloUser) async {
        user = updated
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
        await stopRealtime()
        do {
            let result = try await repository.switchAccount(to: account.type)
            user = result.user
            accounts = result.accounts ?? []
            balance = nil
            capabilities = Capabilities()
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
            if route == .signedIn { await startRealtime() }
        } catch {
            accountSwitchError = L("settings_switch_failed_body")
            if route == .signedIn { await startRealtime() }
        }
    }

    public func signOut() async {
        await stopRealtime()
        try? await repository.logout()
        user = nil
        balance = nil
        capabilities = Capabilities()
        accounts = []
        isChoosingAccount = false
        CrashReporter.setUser(id: nil)
        route = .signedOut
    }

    // MARK: - State

    private func loadSession() async {
        do {
            let session = try await repository.currentUser()
            user = session.user
            capabilities = session.capabilities ?? Capabilities()
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
            await startRealtime()
        }
    }

    private func enterSignedIn() async {
        route = .signedIn
        await refreshBalance()
        await startRealtime()
        syncPushTokenWhenAvailable()
        await refreshCapabilities()
    }

    /// The sign-in response carries no capabilities, so they are read from `/me` once signed in.
    /// A failure keeps the last known value: the menu simply offers less until the next launch.
    public func refreshCapabilities() async {
        guard let session = try? await repository.currentUser() else { return }
        if let fresh = session.capabilities {
            capabilities = fresh
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
        do {
            balance = try await repository.walletBalance()
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "wallet/balance", error: error)
        } catch {
            // Non-fatal; the card shows its last known value.
        }
    }

    private func handleUnauthorized() async {
        await stopRealtime()
        user = nil
        balance = nil
        accounts = []
        route = .signedOut
    }

    /// Push tap: the payload is untrusted, so re-read authoritative state.
    public func refreshAfterPush() async {
        guard route == .signedIn else { return }
        await refreshBalance()
        chatInvalidationToken = UUID()
    }

    // MARK: - Realtime

    private func startRealtime() async {
        await stopRealtime()

        realtimeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.realtime.events {
                guard await self.dedup.shouldApply(event) else { continue }
                await self.apply(event)
            }
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.realtime.statusUpdates {
                await self.handle(status: status)
            }
        }

        await realtime.connect(resumingFrom: nil)
    }

    private func stopRealtime() async {
        realtimeTask?.cancel(); realtimeTask = nil
        statusTask?.cancel(); statusTask = nil
        await realtime.disconnect()
    }

    /// Every event is a **hint**: re-read the authoritative resource rather than rendering the
    /// payload.
    private func apply(_ event: RealtimeEvent) async {
        switch event.type {
        case .balanceInvalidated:
            await refreshBalance()
        case .messageCreated, .paymentIntentUpdated:
            chatInvalidationToken = UUID()
            if event.type == .paymentIntentUpdated {
                // A settled payment moves money; the balance card must not lag behind the receipt.
                await refreshBalance()
            }
        case .unknown:
            break
        }
    }

    private func handle(status: RealtimeStatus) async {
        switch status {
        case .needsResync:
            // Fell too far behind to replay — discard and refetch wholesale.
            chatInvalidationToken = UUID()
            await refreshBalance()
        case let .waitingToRetry(retryIn):
            CrashReporter.recordRealtimeDrop(reason: "retry in \(Int(retryIn))s")
        case .connected, .connecting, .idle:
            break
        }
    }
}
