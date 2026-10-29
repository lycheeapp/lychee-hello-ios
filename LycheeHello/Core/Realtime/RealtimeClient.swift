import Foundation

/// A realtime event from the backend.
///
/// Mirrors `HelloEventType`. `unknown` is deliberate: a backend that adds an event type must not
/// break a shipped client.
public enum RealtimeEventType: String, Sendable {
    case messageCreated = "MESSAGE_CREATED"
    case paymentIntentUpdated = "PAYMENT_INTENT_UPDATED"
    case balanceInvalidated = "BALANCE_INVALIDATED"
    case unknown = "UNKNOWN"
}

public struct RealtimeEvent: Sendable, Equatable {
    /// Server-assigned monotonic id. The dedup and resume key.
    public let id: Int64
    public let type: RealtimeEventType
    /// Raw JSON payload. Treat as a *hint* — never render state from it directly.
    public let payload: [String: String]

    public init(id: Int64, type: RealtimeEventType, payload: [String: String]) {
        self.id = id
        self.type = type
        self.payload = payload
    }
}

/// Connection state, so the UI can show an honest indicator instead of pretending to be live.
public enum RealtimeStatus: Sendable, Equatable {
    case idle
    case connecting
    case connected
    /// Disconnected; a reconnect is scheduled after `retryIn`.
    case waitingToRetry(retryIn: TimeInterval)
    /// Fell too far behind to replay — the app must discard local state and refetch.
    case needsResync
}

/// Transport-agnostic realtime interface.
///
/// **This protocol is the point of the abstraction** (decision D3): chat and payment logic depend
/// only on it, so SSE can be replaced with WebSocket, long-poll or XMPP without touching a single
/// feature file. Nothing above this layer may reference `URLSession`, SSE framing or `Last-Event-ID`.
///
/// Implementations must guarantee:
/// - **at-least-once** delivery, never exactly-once — consumers deduplicate on `id`;
/// - events surface in ascending `id` order within a connection;
/// - `status` reflects reality, including backoff.
public protocol RealtimeClient: AnyObject, Sendable {
    var events: AsyncStream<RealtimeEvent> { get }
    var statusUpdates: AsyncStream<RealtimeStatus> { get }

    /// Connects, resuming from `lastEventId` when provided.
    func connect(resumingFrom lastEventId: Int64?) async
    func disconnect() async
}

/// Tracks the highest applied event id and rejects anything already seen.
///
/// Extracted so dedup is testable without a network, and so every consumer shares one rule rather
/// than reimplementing it. At-least-once delivery means duplicates are *expected*, not exceptional
/// — replay windows overlap by design.
public actor RealtimeDeduplicator {

    private(set) var lastAppliedId: Int64

    public init(lastAppliedId: Int64 = 0) {
        self.lastAppliedId = lastAppliedId
    }

    /// - Returns: `true` when the event is new and should be applied.
    public func shouldApply(_ event: RealtimeEvent) -> Bool {
        guard event.id > lastAppliedId else { return false }
        lastAppliedId = event.id
        return true
    }

    /// Called after a full state fetch, to anchor the stream.
    public func reset(to id: Int64) {
        lastAppliedId = id
    }
}
