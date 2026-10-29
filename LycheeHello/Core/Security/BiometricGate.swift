import Foundation
import LocalAuthentication

/// Local authentication before authorising a payment.
///
/// **This is a UX and device-possession control, not a security boundary.** The backend does not
/// know whether Face ID succeeded, so a compromised app could skip it. Real authorisation is the
/// session token plus the signed request. What this buys is that someone holding an unlocked phone
/// cannot silently spend from it.
public enum BiometricGate {

    public enum Outcome: Equatable {
        case success
        /// User cancelled or chose to abandon. Not an error — do not show a failure alert.
        case cancelled
        /// No biometry or passcode enrolled.
        case unavailable
        case failed(String)
    }

    /// Prompts for Face ID / Touch ID, falling back to the device passcode.
    ///
    /// Uses `.deviceOwnerAuthentication` rather than `...WithBiometrics` so a user without biometry
    /// enrolled, or whose biometry is locked out after failed attempts, can still pay with their
    /// passcode instead of being locked out of the app entirely.
    public static func authorise(reason: String) async -> Outcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return success ? .success : .cancelled
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            case .userFallback:
                return .cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return .unavailable
            default:
                return .failed(laError.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Human-readable biometry name for settings copy.
    public static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }
}
