import Foundation
import Observation

/// Verification-code entry.
///
/// Two behaviours worth calling out:
/// - **The push token is awaited before verifying.** The backend rejects a device without one
///   (`DeviceUtils.validateDevice`), so verifying too early fails with a generic 400 that looks
///   like a wrong code. Awaiting it turns a confusing failure into a brief wait.
/// - **Wrong and expired codes are not distinguished**, matching the backend. Telling a user which
///   one it was would help an attacker more than it helps them.
@Observable
@MainActor
public final class OtpEntryModel {

    public let phoneNumber: String
    public let countryCode: String
    public let codeLength: Int

    public var code: String = "" {
        didSet {
            // Digits only, capped at the expected length.
            let filtered = String(code.filter(\.isNumber).prefix(codeLength))
            if filtered != code { code = filtered }
            errorMessage = nil
            if code.count == codeLength { Task { await verify() } }
        }
    }

    public private(set) var isVerifying = false
    public private(set) var errorMessage: String?
    public private(set) var secondsUntilResend: Int

    private let repository: HelloRepositoryProtocol
    private let resendAfterSeconds: Int
    private let onVerified: (SessionResult) -> Void
    private var timerTask: Task<Void, Never>?

    public init(
        repository: HelloRepositoryProtocol,
        phoneNumber: String,
        countryCode: String,
        codeLength: Int,
        resendAfterSeconds: Int,
        onVerified: @escaping (SessionResult) -> Void
    ) {
        self.repository = repository
        self.phoneNumber = phoneNumber
        self.countryCode = countryCode
        // Defensive: a backend change to code length must not break the input.
        self.codeLength = max(4, min(codeLength, 8))
        self.resendAfterSeconds = resendAfterSeconds
        self.secondsUntilResend = resendAfterSeconds
        self.onVerified = onVerified
    }

    // No `deinit` cancellation: `deinit` is nonisolated even on a @MainActor type, so it cannot
    // touch `timerTask`. It is not needed anyway — the countdown task holds `self` weakly and
    // returns on its next tick once this model deallocates. `stopCountdown()` exists for the
    // deterministic case, and the view calls it on disappear.

    public var canResend: Bool { secondsUntilResend <= 0 && !isVerifying }

    /// Masked for display — the screen should confirm the number without reprinting it in full.
    public var maskedPhone: String {
        guard phoneNumber.count > 4 else { return phoneNumber }
        return String(phoneNumber.prefix(4)) + "•••" + String(phoneNumber.suffix(3))
    }

    /// Stops the countdown immediately. Safe to call repeatedly.
    public func stopCountdown() {
        timerTask?.cancel()
        timerTask = nil
    }

    public func startResendCountdown() {
        timerTask?.cancel()
        secondsUntilResend = resendAfterSeconds
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.secondsUntilResend > 0 {
                    self.secondsUntilResend -= 1
                } else {
                    return
                }
            }
        }
    }

    public func verify() async {
        guard code.count == codeLength, !isVerifying else { return }
        isVerifying = true
        errorMessage = nil
        defer { isVerifying = false }

        // Ask permission at a moment the user understands — they have just asked to be signed in,
        // and payment updates are the obvious reason to allow notifications.
        await PushPermission.request()

        // Sign-in must NOT depend on FCM. A registration token can be slow, can be refused, and on
        // the iOS Simulator typically never arrives at all (no APNs token to derive it from).
        // Blocking here made a third-party service a hard dependency of authentication.
        //
        // Instead: proceed with a clearly-marked placeholder — the backend only requires the field
        // to be non-empty — and register the real token via PUT /devices/fcm-token as soon as one
        // exists. Until then this device simply receives no pushes, and SSE plus polling cover it.
        let pushToken = await AppDelegate.pushToken.value(timeout: 3)
            ?? PushTokenPlaceholder.make()

        if pushToken.hasPrefix(PushTokenPlaceholder.prefix) {
            CrashReporter.log("signing in without an FCM token; will register when available")
        }

        do {
            let result = try await repository.verifyOtp(
                phoneNumber: phoneNumber,
                countryCode: countryCode,
                code: code,
                pushToken: pushToken
            )
            CrashReporter.log("otp verified state=\(result.userState?.rawValue ?? "?")")
            onVerified(result)
        } catch let error as APIError {
            // Never log the code itself.
            CrashReporter.recordOtpFailure(reason: error.code?.rawValue ?? "unknown")
            errorMessage = error.userMessage
            code = ""
        } catch {
            errorMessage = L("error_generic")
            code = ""
        }
    }

    public func resend() async {
        guard canResend else { return }
        errorMessage = nil
        do {
            _ = try await repository.requestOtp(phoneNumber: phoneNumber, countryCode: countryCode)
            startResendCountdown()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = L("otp_error_resend")
        }
    }
}
