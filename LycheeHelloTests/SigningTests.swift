import XCTest
@testable import LycheeHello

/// Canonical-string tests.
///
/// These are the highest-value tests in the app: a one-byte divergence from the Java
/// `CanonicalRequestBuilder` produces a signature the backend rejects, and the only symptom is a
/// 401 with no indication of which byte was wrong.
///
/// Vectors are taken from the committed `TEST_VECTORS.md`, shared with the backend and the other
/// clients. **If one of these fails, do not "fix" it by changing the expectation** — the
/// canonicaliser is wrong, or the spec moved and every client needs updating together.
final class SigningTests: XCTestCase {

    func testCanonicalStringIsNineNewlineTerminatedLines() {
        let canonical = SigningCanonical.build(
            method: "POST",
            appRelativePath: "/hello/v1/auth/otp/request",
            rawQuery: nil,
            bodyMode: "sha256",
            bodyHashHex: SigningCanonical.emptyBodySha256Hex,
            timestampMs: "1700000000000",
            nonce: "0123456789abcdef0123456789abcdef",
            clientId: "hello-ios",
            keyId: "test-key-1"
        )

        let lines = canonical.components(separatedBy: "\n")
        // 9 lines each terminated by \n produces a trailing empty component.
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.last, "")
        XCTAssertEqual(lines[0], "LYCHEE-SIGN-V1")
        XCTAssertEqual(lines[1], "POST")
        XCTAssertEqual(lines[2], "/hello/v1/auth/otp/request")
        XCTAssertEqual(lines[3], "")
        XCTAssertEqual(lines[4], "sha256:\(SigningCanonical.emptyBodySha256Hex)")
        XCTAssertEqual(lines[7], "hello-ios")
        XCTAssertEqual(lines[8], "test-key-1")
    }

    func testMethodIsUppercased() {
        let canonical = SigningCanonical.build(
            method: "post", appRelativePath: "/x", rawQuery: nil,
            bodyMode: "none", bodyHashHex: SigningCanonical.emptyBodySha256Hex,
            timestampMs: "1", nonce: "n", clientId: "c", keyId: "k")
        XCTAssertTrue(canonical.contains("\nPOST\n"))
    }

    func testEmptyBodyHashMatchesTheSpecConstant() {
        XCTAssertEqual(
            SigningCanonical.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // MARK: - Query canonicalisation

    func testQueryParametersAreSortedByEncodedBytes() {
        XCTAssertEqual(SigningCanonical.canonicalizeQuery("b=2&a=1"), "a=1&b=2")
    }

    func testValuelessTokenBecomesNameEquals() {
        XCTAssertEqual(SigningCanonical.canonicalizeQuery("flag"), "flag=")
    }

    func testNilAndEmptyQueriesCanonicaliseToEmptyString() {
        XCTAssertEqual(SigningCanonical.canonicalizeQuery(nil), "")
        XCTAssertEqual(SigningCanonical.canonicalizeQuery(""), "")
    }

    /// `+` must stay literal and never decode to a space — otherwise a phone number like
    /// `+970594651099` in a query would canonicalise differently on client and server.
    func testPlusIsNotTreatedAsASpace() {
        XCTAssertEqual(SigningCanonical.canonicalizeQuery("phone=%2B970594651099"), "phone=%2B970594651099")
    }

    func testReservedCharactersArePercentEncodedUppercase() {
        XCTAssertEqual(SigningCanonical.canonicalizeQuery("q=a b"), "q=a%20b")
    }

    func testUnreservedCharactersAreLeftLiteral() {
        XCTAssertEqual(SigningCanonical.canonicalizeQuery("q=aZ0-_.~"), "q=aZ0-_.~")
    }

    // MARK: - Path handling

    /// The backend canonicalises the app-relative path, so the servlet context must be stripped or
    /// every signature mismatches.
    func testServletContextIsStrippedFromPath() {
        XCTAssertEqual(
            RequestSigner.stripContext("/rest/lychee-v2/hello/v1/me"),
            "/hello/v1/me"
        )
    }

    func testPathWithoutContextIsReturnedWithLeadingSlash() {
        XCTAssertEqual(RequestSigner.stripContext("hello/v1/me"), "/hello/v1/me")
    }
}
