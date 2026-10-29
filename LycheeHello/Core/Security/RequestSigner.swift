import Foundation
import Security

/// Produces LYCHEE-SIGN-V1 signing headers for Lychee Hello.
///
/// Canonicalisation lives in `SigningCanonical`, copied verbatim from the existing client and
/// validated against the committed `TEST_VECTORS.md`. Do not reimplement it — a one-byte
/// difference produces a signature the backend rejects, and the failure mode is a 401 with no
/// indication of which byte was wrong.
///
/// ## Key handling — differs deliberately from the legacy app
/// The legacy `lychee-ios` hardcodes its **production** private key as a Swift constant. Hello does
/// not:
/// - **Debug** uses the committed non-prod test key. Its private half is already in the repository
///   (`TEST_VECTORS.md`), so embedding it exposes nothing new, and it matches the public key seeded
///   by `scripts/seed-hello-signing.sql`.
/// - **Release** loads the key from `LYCHEE_SIGNING_PRIVATE_KEY`, injected at build time by the
///   release pipeline. It is never committed.
///
/// The threat model is unchanged and worth restating: this key is a *build-time* secret, identical
/// in every install and extractable from the binary by a determined attacker. It exists to stop
/// scripted abuse and to give the backend a revocation lever — **not** to prove device identity.
/// Device binding is App Attest's job.
public enum RequestSigner {

    /// Servlet context path baked into the base URL; stripped to get the app-relative path the
    /// backend canonicalises.
    static let contextPath = "/rest/lychee-v2"

    public struct SignResult: Sendable {
        public let headers: [String: String]
        /// The canonical string, needed as App Attest's clientDataHash source.
        public let canonical: String
        public let nonce: String
    }

    public enum SigningError: Error, CustomStringConvertible {
        case missingProductionKey
        case malformedKey
        case signatureFailed

        public var description: String {
            switch self {
            case .missingProductionKey:
                return """
                Release build has no LYCHEE_SIGNING_PRIVATE_KEY. The release pipeline must inject \
                the production signing key; see lychee-api/scripts/seed-hello-signing.sql.
                """
            case .malformedKey:
                return "Signing key is not a valid PKCS#1 RSA private key."
            case .signatureFailed:
                return "SecKeyCreateSignature failed."
            }
        }
    }

    /// Non-prod key. Public half is seeded as ('hello-ios','test-key-1').
    /// Committed on purpose — it is already public in this repository and grants nothing in prod.
    private static let testPrivateKeyPKCS1PEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEAoA4RxVyXju2fftBpkbTVSR46lP4K4ZsHdT9KFxDwlwRr1CML
    40W3yDedVIukb5YUz0jFeLDwGXYMu58K/IIx05BEGGf3aoEEkrBU6X+gKpkIMlmo
    1IU4PDfBiHhHvPNuvH4Xlh//Cb56HzYYy0wMuRh3pW8RY5i0O7Cc9/WIjvM0+HoK
    twnntEjd9dVQ+oOZ+n/qlSOdcOF1ISuDfu3mji1J3Bm2skE61lV0dOLEmDgMYAyt
    o91wqEwfdZi1d7CvsFTWyDznA+0fahcyLmXEULBsq6dDFQNAryLdCBIeYawhDh1U
    EtOH0dM9Sk7EX6CXZdVnKAk+SdP3wWfjzhY6vwIDAQABAoIBACaBnAbmctQBGSky
    TOOwJMwViLSFtep3GME9e7625Zr/hk2gLOD9yexSbPiFLAdojRMdh9y0fN8zRnbx
    GXyMeh5TC/7vLFgkOAxufc87VDZLYOx0I6kVb+UU6OvDPEcaLd8NWvFUO1CF0e2m
    Xyqx3jG90DMt2Hokp9/garNBEByLxx/jSTUC5SouIAMwC5GUgcHWMAwHtt3akbUt
    d1WyNc+n1Ml4YtoBNT3faa0vftAtm1JG9grTe1XtpegiPHFQe9jw5tRKIkb136He
    A0oThZF8fhfdNaFceQBahladVl4x6I+sILYmulpS4XylkfZyXBbxvekyUvcv6Mg6
    lBmuZ+ECgYEAzMpPnqmlOdDnWloj6po64yxnvsFX6NJcnFUaL+QC3vTSupog5GC/
    wnyI+cEHzmgurMaGl7Tq2vpIs5ywoR86ZYndXIX6QWthSVHIN7/s9zUm5uhc/vKF
    i/2SZiQ1Oh4X4OGhQERXcZXXhpUaIJaMrGyxUU/aEF1LwvQDHlYP2PECgYEAyBQE
    tAo1kxB7JfewDmWbveUR47vmSUl/cn7T/kOGUrHcP8aB2hbb1pHNyRk/xhWYzE34
    lHOCeCvlD9KawI57XnitB3KlQgAAnYwxmp5r0VyDs1EHgpZJpVpdttwCerPEuG17
    9R177rrupX0Xb8/08j4AoJX8CC6h9S+Jfiufzq8CgYAIfKnoDWfHiZzM5cdvRY0D
    NSfng+O8xlsIL46yRWTJEKRbD2AllszbpoWWtCU6rJ6ikmepidnh0VWJ/Ahl5QFq
    i9gcqYDBjU2u2DDP/qg3ZoCCOUcBWdOnBY83pHCARBcBPtiL7Ukib+9KqIs4poSV
    8Ls4f3KuEu+82Jf4feCSQQKBgQCh+ZLVLm6w4GbSFfMxtJCg6xHQjA2ixx2mU4bM
    EV5tFBB6kPoO1PKkguVWKFq4wkMxIu5bQCgfoWmPpbAiszatBIUPwoCHLflRkm2V
    /yrKE1uLj83EqmZ0tvOnVfWr4F0h8YCor3XljvAkiWCv5GsosYlQeBvRg+8Zz6I/
    wpFdgQKBgQCwCjdOXLbI5bl4+xcdrFDn+xOJ8WQ6TGv/ufKjdRx79IBkhbx8Zxem
    YhlHyyxxvieVsspEKVVxgRm7D2l+l2Vc7cKo1BufMRQmENdi5sCOAShFhjhGxYj2
    dipOpLvA4yvK+8MQBYsYEi0RhHH4oVmbWz/WA5n8zClkAE009HAH7w==
    -----END RSA PRIVATE KEY-----
    """

    private static let environment = AppEnvironment.current

    /// PEM for the active environment. Production reads from build-time injection only.
    private static func activePEM() throws -> String {
        guard environment.isProduction else {
            return testPrivateKeyPKCS1PEM
        }
        guard let injected = Bundle.main.object(forInfoDictionaryKey: "LYCHEE_SIGNING_PRIVATE_KEY") as? String,
              !injected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SigningError.missingProductionKey
        }
        // xcconfig cannot hold newlines, so the pipeline injects the key with '\n' escaped.
        return injected.replacingOccurrences(of: "\\n", with: "\n")
    }

    private static let privateKey: SecKey? = {
        guard let pem = try? activePEM() else { return nil }
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }()

    public static var isAvailable: Bool { privateKey != nil }

    /// Signs a request.
    ///
    /// Always uses `sha256` body mode: every protected Hello path is either JSON or empty-bodied,
    /// and both bind correctly under that mode.
    ///
    /// - Returns: headers to attach, or `nil` when signing is unavailable. Callers send unsigned in
    ///   that case — the backend decides whether to reject, which keeps the rollout switch on the
    ///   server (`shadow` → `enforce`) rather than in the app.
    public static func sign(
        method: String,
        url: URL,
        body: Data?,
        nonceOverride: String? = nil
    ) -> SignResult? {
        guard let key = privateKey else { return nil }

        let appRelativePath = stripContext(url.path)
        let bodyHashHex = SigningCanonical.sha256Hex(body ?? Data())
        let timestampMs = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = nonceOverride ?? generateNonceHex()

        let canonical = SigningCanonical.build(
            method: method,
            appRelativePath: appRelativePath,
            rawQuery: url.query,
            bodyMode: "sha256",
            bodyHashHex: bodyHashHex,
            timestampMs: timestampMs,
            nonce: nonce,
            clientId: environment.signingClientId,
            keyId: environment.signingKeyId
        )

        guard let signature = rsaSign(canonical, with: key) else { return nil }

        return SignResult(
            headers: [
                "X-Lychee-Sign-Version": "1",
                "X-Lychee-Client": environment.signingClientId,
                "X-Lychee-Key-Id": environment.signingKeyId,
                "X-Lychee-Timestamp": timestampMs,
                "X-Lychee-Nonce": nonce,
                "X-Lychee-Body-Mode": "sha256",
                "X-Lychee-Signature": signature
            ],
            canonical: canonical,
            nonce: nonce
        )
    }

    /// SHA256withRSA (PKCS#1 v1.5) over the canonical string's UTF-8 bytes, base64-encoded.
    private static func rsaSign(_ canonical: String, with key: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(canonical.utf8) as CFData,
            &error
        ) else {
            return nil
        }
        return (signature as Data).base64EncodedString()
    }

    /// The backend canonicalises the *app-relative* path, so the servlet context must be removed.
    static func stripContext(_ path: String) -> String {
        if let range = path.range(of: contextPath) {
            let stripped = String(path[range.upperBound...])
            return stripped.hasPrefix("/") ? stripped : "/" + stripped
        }
        return path.hasPrefix("/") ? path : "/" + path
    }

    /// 16 CSPRNG bytes, lowercase hex — the backend's replay store keys on this.
    private static func generateNonceHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
