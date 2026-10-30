import Foundation
import Observation

/// State for the phone-entry screen.
///
/// Uses `@Observable` (iOS 17+) rather than `ObservableObject`: fewer republish cycles and no
/// `@Published` boilerplate. Every mutation is main-actor bound so SwiftUI never sees a torn state.
@Observable
@MainActor
public final class PhoneEntryModel {

    public struct Country: Sendable, Equatable {
        public let name: String
        public let dialCode: String
        /// ISO code the backend needs to normalise the number (`validateNewUser` requires it).
        public let isoCode: String
        public let placeholder: String
        /// Digits expected after the dial code, used for a cheap local sanity check only.
        public let nationalDigits: Int
    }

    /// Palestine first and default, matching the screenshot's `+970` and the backend's
    /// `phone.default.region=PS`. Deliberately a short list — Hello launches single-market
    /// (decision U2), and an unfiltered world list would imply support that does not exist.
    public static let supportedCountries: [Country] = [
        Country(name: "Palestine", dialCode: "+970", isoCode: "PS", placeholder: "59X XXX XXX", nationalDigits: 9),
        Country(name: "Israel", dialCode: "+972", isoCode: "IL", placeholder: "5X XXX XXXX", nationalDigits: 9)
    ]

    public var country: Country = supportedCountries[0]
    public var nationalNumber: String = "" {
        didSet { errorMessage = nil }
    }
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?

    /// Set when the code has been sent, so the coordinator can push the OTP screen.
    public var onCodeSent: ((String, String, OtpRequestResult) -> Void)?

    private let repository: HelloRepositoryProtocol

    public init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    /// Digits only; the user may type spaces or dashes.
    private var sanitisedNumber: String {
        nationalNumber.filter(\.isNumber)
    }

    /// E.164 for the backend. A leading national `0` is dropped — people type "059..." constantly
    /// and `+9700594...` is not a valid number.
    public var e164: String {
        var digits = sanitisedNumber
        if digits.hasPrefix("0") { digits.removeFirst() }
        return country.dialCode + digits
    }

    /// Cheap local check to keep the button honest. **Not** validation — the backend's libphonenumber
    /// pass is authoritative, and this must never be relied on for correctness.
    public var canSubmit: Bool {
        !isSubmitting && sanitisedNumber.count >= country.nationalDigits - 1
    }

    public func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let result = try await repository.requestOtp(
                phoneNumber: e164,
                countryCode: country.isoCode
            )
            onCodeSent?(e164, country.isoCode, result)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = L("error_generic")
        }
    }
}
