import Foundation
import CryptoKit

/// LYCHEE-SIGN-V1 canonical-string construction. Pure, dependency-free, so it can be unit-tested
/// against the committed TEST_VECTORS.md byte-for-byte. MUST stay identical to the Java
/// CanonicalRequestBuilder and the other clients. See TEST_VECTORS.md at the repo root.
enum SigningCanonical {

    static let versionTag = "LYCHEE-SIGN-V1"

    /// SHA-256 of the empty byte array (GET/DELETE bodies and `none` mode).
    static let emptyBodySha256Hex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private static let hexUpper = Array("0123456789ABCDEF")

    /// Build the 9-line canonical string (each line terminated by '\n', trailing newline included).
    static func build(
        method: String, appRelativePath: String, rawQuery: String?,
        bodyMode: String, bodyHashHex: String, timestampMs: String,
        nonce: String, clientId: String, keyId: String
    ) -> String {
        let lines = [
            versionTag,
            method.uppercased(),
            appRelativePath,
            canonicalizeQuery(rawQuery),
            "\(bodyMode):\(bodyHashHex)",
            timestampMs,
            nonce,
            clientId,
            keyId,
        ]
        return lines.map { $0 + "\n" }.joined()
    }

    /// Canonicalize a raw wire query string: split on '&', split each on first '=', decode-%XX then
    /// re-encode with the unreserved set A-Za-z0-9-_.~, sort encoded `name=value` by byte order,
    /// join with '&'. A token with no '=' becomes `name=`. Returns "" for nil/empty input.
    static func canonicalizeQuery(_ rawQuery: String?) -> String {
        guard let rawQuery = rawQuery, !rawQuery.isEmpty else { return "" }
        var pairs: [String] = []
        for token in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let t = String(token)
            if let eq = t.firstIndex(of: "=") {
                let name = String(t[t.startIndex..<eq])
                let value = String(t[t.index(after: eq)...])
                pairs.append(encodeUnreserved(decodePercent(name)) + "=" + encodeUnreserved(decodePercent(value)))
            } else {
                pairs.append(encodeUnreserved(decodePercent(t)) + "=")
            }
        }
        pairs.sort()
        return pairs.joined(separator: "&")
    }

    /// Decode only %XX escapes to raw bytes; '+' stays literal (never a space).
    private static func decodePercent(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "%"), i + 2 < chars.count,
               let hi = hexVal(chars[i + 1]), let lo = hexVal(chars[i + 2]) {
                out.append(UInt8((hi << 4) | lo))
                i += 3
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Percent-encode bytes leaving only the unreserved set A-Za-z0-9-_.~ literal.
    private static func encodeUnreserved(_ bytes: [UInt8]) -> String {
        var sb = ""
        for b in bytes {
            let c = Character(UnicodeScalar(b))
            if (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
                || c == "-" || c == "_" || c == "." || c == "~" {
                sb.append(c)
            } else {
                sb.append("%")
                sb.append(hexUpper[Int((b >> 4) & 0xF)])
                sb.append(hexUpper[Int(b & 0xF)])
            }
        }
        return sb
    }

    /// SHA-256 of `data` as lowercase hex.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hexVal(_ b: UInt8) -> Int? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(b - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(b - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(b - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }
}
