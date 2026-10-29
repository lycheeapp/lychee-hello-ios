import Foundation
import Observation

/// The General Chat.
///
/// Sending is optimistic for responsiveness but **never optimistic about payments**: the user's
/// bubble appears immediately, while any payment card comes from the server response. The client
/// must never draw a payment it invented.
@Observable
@MainActor
public final class ChatModel {

    public private(set) var messages: [ChatMessage] = []
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public private(set) var errorMessage: String?
    public private(set) var conversationId: String?

    /// Drives the review sheet. Non-nil means the sheet is open.
    public var pendingIntent: PaymentIntent?

    /// A PENDING intent that exists on the server but is not currently on screen.
    ///
    /// Kept separate from `pendingIntent` so re-opening the app does not slam a modal in the user's
    /// face — the review card reappears in the transcript and they tap it. Without this the user is
    /// stranded: the intent blocks every new payment while being unreachable.
    public private(set) var resumableIntent: PaymentIntent?

    public var draft: String = ""

    /// Locally-appended bubbles awaiting their server echo, keyed by client message id so the
    /// reconciliation on refresh is exact rather than heuristic.
    private var optimisticIds: Set<String> = []

    private let repository: HelloRepositoryProtocol

    public init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    public var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let conversation = try await repository.generalConversation()
            conversationId = conversation.id
            try await refreshMessages(conversationId: conversation.id)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "conversations/general", error: error)
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't load your chat."
        }
    }

    /// Re-reads the transcript. Called on realtime hints and on foreground.
    public func refresh() async {
        guard let conversationId else {
            await load()
            return
        }
        do {
            try await refreshMessages(conversationId: conversationId)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "messages", error: error)
        } catch {
            // Silent: a background refresh failing should not interrupt the user.
        }
    }

    private func refreshMessages(conversationId: String) async throws {
        let page = try await repository.messages(conversationId: conversationId, before: nil, limit: 50)
        // Server returns newest-first; the transcript renders oldest-first.
        messages = page.messages.reversed()
        // Anything the server now knows about supersedes its optimistic twin.
        optimisticIds.removeAll()
        errorMessage = nil
        await refreshResumableIntent()
    }

    /// Re-reads whether a payment is still awaiting confirmation.
    ///
    /// Failure is silent: this is supplementary state, and an error here should not break the
    /// transcript the user came to read.
    private func refreshResumableIntent() async {
        resumableIntent = (try? await repository.pendingPaymentIntent()) ?? nil
    }

    /// Re-opens the review sheet for a payment the user backed out of.
    public func resumePendingPayment() {
        guard let resumableIntent else { return }
        pendingIntent = resumableIntent
    }

    /// Called by the view when the sheet closes, so the transcript stops offering a stale card.
    public func closePaymentSheet() {
        pendingIntent = nil
    }

    // MARK: - Sending

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let conversationId, !isSending else { return }

        isSending = true
        draft = ""
        defer { isSending = false }

        // Stable across retries — this is what makes a resend after a dropped response safe rather
        // than a duplicate message or a second payment intent.
        let clientMessageId = UUID().uuidString
        appendOptimistic(text: text, clientMessageId: clientMessageId)

        do {
            let result = try await repository.sendText(
                conversationId: conversationId, text: text, clientMessageId: clientMessageId)
            apply(result: result, replacing: clientMessageId)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "messages", error: error)
            markOptimisticFailed(clientMessageId)
            errorMessage = error.userMessage
        } catch {
            markOptimisticFailed(clientMessageId)
            errorMessage = "Couldn't send that message."
        }
    }

    /// Quick-action form path. The server composes the canonical command, so this cannot diverge
    /// from what free text accepts.
    public func sendPaymentForm(payee: String, voucherCode: String?, amount: Double) async {
        guard let conversationId, !isSending else { return }
        isSending = true
        defer { isSending = false }

        let clientMessageId = UUID().uuidString
        do {
            let result = try await repository.sendPaymentForm(
                conversationId: conversationId,
                payee: payee,
                voucherCode: voucherCode,
                amount: amount,
                clientMessageId: clientMessageId
            )
            apply(result: result, replacing: nil)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "messages(form)", error: error)
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't start that payment."
        }
    }

    private func apply(result: SendMessageResult, replacing clientMessageId: String?) {
        if let clientMessageId {
            messages.removeAll { $0.id == clientMessageId }
            optimisticIds.remove(clientMessageId)
        }
        if let message = result.message {
            messages.append(message)
        }
        for reply in result.replies ?? [] {
            messages.append(reply)
        }
        // Only the server may produce a payment card. This also covers the
        // PAYMENT_ALREADY_PENDING case, where the server returns the *existing* pending intent so
        // the user can act on it instead of being told to finish something they cannot see.
        if let intent = result.paymentIntent, intent.status == .pending {
            resumableIntent = intent
            pendingIntent = intent
        }
    }

    private func appendOptimistic(text: String, clientMessageId: String) {
        optimisticIds.insert(clientMessageId)
        messages.append(
            ChatMessage(
                id: clientMessageId,
                direction: .inbound,
                type: .text,
                body: text,
                payload: nil,
                status: .sent,
                paymentIntentId: nil,
                sentAt: Date()
            )
        )
    }

    private func markOptimisticFailed(_ clientMessageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == clientMessageId }) else { return }
        let failed = messages[index]
        messages[index] = ChatMessage(
            id: failed.id,
            direction: failed.direction,
            type: failed.type,
            body: failed.body,
            payload: failed.payload,
            status: .failed,
            paymentIntentId: failed.paymentIntentId,
            sentAt: failed.sentAt
        )
    }

    public func dismissError() { errorMessage = nil }
}
