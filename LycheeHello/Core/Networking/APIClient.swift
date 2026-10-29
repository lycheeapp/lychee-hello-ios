import Foundation

/// HTTP entry point for every Hello backend call.
///
/// Responsibilities, in order of application:
/// 1. build the URL from `AppEnvironment` (never a hardcoded host),
/// 2. attach the session token as `Authorization-Token` — the existing Lychee scheme, unchanged,
/// 3. attach LYCHEE-SIGN-V1 headers,
/// 4. map transport and envelope failures to typed `APIError`s,
/// 5. clear the session on 401 so the app cannot sit holding a dead token.
///
/// Signing runs **after** the body is finalised, because the signature covers the body hash. Any
/// future request mutation must happen before `sign`, or every request will 401 in enforce mode.
public actor APIClient {

    public static let shared = APIClient()

    private let environment: AppEnvironment
    private let session: URLSession
    private let tokenStore: TokenStore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Invoked when the backend rejects the session, so the app can route to sign-in.
    private var onUnauthorized: (@Sendable () async -> Void)?

    public init(
        environment: AppEnvironment = .current,
        tokenStore: TokenStore = .shared,
        session: URLSession? = nil
    ) {
        self.environment = environment
        self.tokenStore = tokenStore

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            // Never cache API responses: balances and payment state must not be served stale, and
            // cached payment payloads on disk are an unnecessary data-at-rest exposure.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }

        let decoder = JSONDecoder()
        // Backend uses Gson with yyyy-MM-dd'T'HH:mm:ss.SSSZ
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        decoder.dateDecodingStrategy = .formatted(formatter)
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(formatter)
        self.encoder = encoder
    }

    public func setUnauthorizedHandler(_ handler: @escaping @Sendable () async -> Void) {
        self.onUnauthorized = handler
    }

    // MARK: - Requests

    public func get<Response: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let request = try await buildRequest(method: "GET", path: path, query: query, body: nil)
        return try await perform(request)
    }

    /// GET for endpoints that answer `204 No Content` to mean "nothing here".
    ///
    /// Distinct from `get` because an empty body is a legitimate answer, not a decode failure —
    /// "no payment is pending" is normal state, and modelling it as an error would force every
    /// call site to catch and reinterpret.
    public func getOptional<Response: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response? {
        let request = try await buildRequest(method: "GET", path: path, query: query, body: nil)
        let data = try await performRaw(request)
        guard !data.isEmpty else { return nil }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("\(Response.self): \(error.localizedDescription)")
        }
    }

    public func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        idempotencyKey: String? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try encoder.encode(body)
        let request = try await buildRequest(
            method: "POST", path: path, query: [:], body: data, idempotencyKey: idempotencyKey)
        return try await perform(request)
    }

    /// POST with no request body (confirm/cancel style endpoints).
    public func post<Response: Decodable>(
        _ path: String,
        idempotencyKey: String? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let request = try await buildRequest(
            method: "POST", path: path, query: [:], body: nil, idempotencyKey: idempotencyKey)
        return try await perform(request)
    }

    public func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try encoder.encode(body)
        let request = try await buildRequest(method: "PATCH", path: path, query: [:], body: data)
        return try await perform(request)
    }

    public func put<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try encoder.encode(body)
        let request = try await buildRequest(method: "PUT", path: path, query: [:], body: data)
        return try await perform(request)
    }

    public func delete(_ path: String) async throws {
        let request = try await buildRequest(method: "DELETE", path: path, query: [:], body: nil)
        _ = try await performRaw(request)
    }

    // MARK: - Internals

    func buildRequest(
        method: String,
        path: String,
        query: [String: String],
        body: Data?,
        idempotencyKey: String? = nil
    ) async throws -> URLRequest {
        var components = URLComponents(
            url: environment.helloBaseURL.appendingPathComponent(path.trimmingPrefix("/")),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            // Sorted so the signed query is deterministic and easier to debug against server logs.
            components?.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw APIError.transport("Could not build URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        // Existing Lychee session scheme — not `Authorization`, which the backend reserves for
        // server-to-server tokens.
        if let token = await tokenStore.token() {
            request.setValue(token, forHTTPHeaderField: "Authorization-Token")
        }
        request.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")

        // Signed last: the signature binds the final body bytes.
        if let signed = RequestSigner.sign(method: method, url: url, body: body) {
            for (key, value) in signed.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await performRaw(request)
        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("\(Response.self): \(error.localizedDescription)")
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw APIError.offline
            case .timedOut:
                throw APIError.timedOut
            default:
                throw APIError.transport(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Non-HTTP response")
        }

        if environment.logNetwork {
            // Never logs headers (they carry the session token and signature) or the body.
            print("[Hello API] \(request.httpMethod ?? "?") \(request.url?.path ?? "") -> \(http.statusCode)")
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            await tokenStore.clear()
            await onUnauthorized?()
            throw APIError.unauthorized
        default:
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            throw APIError.api(
                code: HelloErrorCode(rawValueOrUnknown: envelope?.code),
                message: envelope?.message,
                status: http.statusCode
            )
        }
    }
}

/// For endpoints that return no body.
public struct EmptyResponse: Codable, Sendable {
    public init() {}
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
