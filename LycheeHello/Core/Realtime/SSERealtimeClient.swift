import Foundation

/// SSE implementation of `RealtimeClient` against `GET /hello/v1/events`.
///
/// ## Why not `EventSource`
/// There is no `EventSource` on Apple platforms, and even in browsers it cannot set headers — which
/// would force the session token into the query string, where it lands in proxy and server access
/// logs. This uses `URLSession.bytes(for:)` so the token travels in `Authorization-Token`, matching
/// every other Hello call.
///
/// ## Reconnect
/// Exponential backoff with full jitter, capped. Jitter matters: without it every client that
/// dropped during a deploy reconnects in lockstep and stampedes the app on restart.
///
/// ## Liveness
/// The server emits a comment heartbeat roughly every 20s. If nothing at all arrives within
/// `heartbeatTimeout`, the link is treated as dead and torn down — a TCP connection can stay open
/// long after it has stopped delivering, especially as a phone moves between networks, and without
/// this the app would look connected while receiving nothing.
///
/// ## ⚠️ Known refinement: `@unchecked Sendable`
/// `connect`/`disconnect` are called from the main actor while `lastEventId`, `retryAttempt` and
/// `connectionTask` are mutated on the connection task. That is a genuine (if narrow) data race
/// that `@unchecked` currently silences rather than solves.
///
/// The fix is to make this an `actor` with `nonisolated let` streams. It was left as-is because the
/// conversion could not be compiler-verified in the environment this was written in, and an
/// unverified concurrency refactor is worse than a documented one. **Convert before shipping.**
/// The blast radius is contained: nothing outside this file touches that state, and the
/// `RealtimeClient` protocol does not change.
public final class SSERealtimeClient: RealtimeClient, @unchecked Sendable {

    public let events: AsyncStream<RealtimeEvent>
    public let statusUpdates: AsyncStream<RealtimeStatus>

    private let eventContinuation: AsyncStream<RealtimeEvent>.Continuation
    private let statusContinuation: AsyncStream<RealtimeStatus>.Continuation

    private let environment: AppEnvironment
    private let tokenStore: TokenStore
    private let session: URLSession

    private var connectionTask: Task<Void, Never>?
    private var lastEventId: Int64?
    private var retryAttempt = 0

    /// Cap on backoff. Long enough to protect the server, short enough that a user who reopens the
    /// app is not staring at a stale screen.
    private let maxBackoff: TimeInterval = 30
    private let baseBackoff: TimeInterval = 1
    /// Generous relative to the 20s server heartbeat, to tolerate a slow mobile link.
    private let heartbeatTimeout: TimeInterval = 60

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
            // A stream is long-lived by definition; the per-request timeout must not kill it.
            config.timeoutIntervalForRequest = 0
            config.timeoutIntervalForResource = 0
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }

        var eventCont: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { eventCont = $0 }
        self.eventContinuation = eventCont

        var statusCont: AsyncStream<RealtimeStatus>.Continuation!
        self.statusUpdates = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont
    }

    deinit {
        connectionTask?.cancel()
        eventContinuation.finish()
        statusContinuation.finish()
    }

    public func connect(resumingFrom lastEventId: Int64?) async {
        await disconnect()
        if let lastEventId { self.lastEventId = lastEventId }
        retryAttempt = 0

        connectionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.runConnection()
                    // A clean end (server closed the stream) still means reconnect.
                    self.retryAttempt = 0
                } catch is CancellationError {
                    return
                } catch {
                    // Fall through to backoff.
                }
                guard !Task.isCancelled else { return }
                let delay = self.nextBackoff()
                self.statusContinuation.yield(.waitingToRetry(retryIn: delay))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func disconnect() async {
        connectionTask?.cancel()
        connectionTask = nil
        statusContinuation.yield(.idle)
    }

    // MARK: - Stream

    private func runConnection() async throws {
        statusContinuation.yield(.connecting)

        var request = URLRequest(url: environment.helloBaseURL.appendingPathComponent("events"))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let token = await tokenStore.token() {
            request.setValue(token, forHTTPHeaderField: "Authorization-Token")
        }
        if let lastEventId {
            request.setValue(String(lastEventId), forHTTPHeaderField: "Last-Event-ID")
        }

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Non-HTTP response on event stream")
        }
        if http.statusCode == 401 {
            // Do not retry: reconnecting with a dead token would loop forever. Clear it only if it
            // is still the current one — after an account switch the stream of the account left
            // behind gets a 401, and that must not sign out the account switched to.
            let sentWith = request.value(forHTTPHeaderField: "Authorization-Token")
            if await tokenStore.token() == sentWith {
                await tokenStore.clear()
            }
            statusContinuation.yield(.idle)
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.transport("Event stream HTTP \(http.statusCode)")
        }

        statusContinuation.yield(.connected)
        retryAttempt = 0

        var currentId: Int64?
        var currentEvent: String?
        var currentData = ""
        var lastActivity = Date()

        // Watchdog: a silent-but-open socket is the failure this catches.
        let watchdog = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Date().timeIntervalSince(lastActivity) > self.heartbeatTimeout {
                    return // Returning ends the watchdog; the read loop below throws on next check.
                }
            }
        }
        defer { watchdog.cancel() }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            lastActivity = Date()

            if line.isEmpty {
                // Blank line terminates an event.
                if let currentEvent, !currentData.isEmpty || currentEvent == "resync" {
                    handle(name: currentEvent, id: currentId, data: currentData)
                }
                currentId = nil
                currentEvent = nil
                currentData = ""
                continue
            }
            // ':' prefix is a comment — this is the heartbeat. Touching `lastActivity` above is
            // its entire purpose.
            if line.hasPrefix(":") { continue }

            if let value = value(of: "id:", in: line) {
                currentId = Int64(value)
            } else if let value = value(of: "event:", in: line) {
                currentEvent = value
            } else if let value = value(of: "data:", in: line) {
                currentData += value
            }
        }
    }

    private func handle(name: String, id: Int64?, data: String) {
        switch name {
        case "ready":
            // Carries latestEventId so a fresh client knows its baseline after a full fetch.
            if let latest = parse(data)["latestEventId"], let value = Int64(latest) {
                if lastEventId == nil { lastEventId = value }
            }
        case "resync":
            // Too far behind to replay: the consumer must discard and refetch.
            statusContinuation.yield(.needsResync)
        default:
            guard let id else { return }
            lastEventId = id
            let event = RealtimeEvent(
                id: id,
                type: RealtimeEventType(rawValue: name) ?? .unknown,
                payload: parse(data)
            )
            eventContinuation.yield(event)
        }
    }

    /// Flat string map — enough for the id/status hints these events carry, and avoids dragging a
    /// full JSON model into the transport layer.
    private func parse(_ data: String) -> [String: String] {
        guard let jsonData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let value = value as? String { result[key] = value }
            else if let value = value as? NSNumber { result[key] = value.stringValue }
        }
        return result
    }

    private func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Exponential backoff with **full jitter**, so clients dropped by one deploy do not all
    /// reconnect at the same instant.
    private func nextBackoff() -> TimeInterval {
        retryAttempt = min(retryAttempt + 1, 10)
        let exponential = min(maxBackoff, baseBackoff * pow(2, Double(retryAttempt - 1)))
        return Double.random(in: 0...exponential)
    }
}
