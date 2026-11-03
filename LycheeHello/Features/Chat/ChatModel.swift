import Foundation
import Observation
import SwiftUI

/// The General Chat.
///
/// Sending is optimistic for responsiveness but **never optimistic about payments**: the user's
/// bubble appears immediately, while any payment card comes from the server response. The client
/// must never draw a payment it invented.
@Observable
@MainActor
public final class ChatModel {

    static let pageSize = 50

    /// Appends and the optimistic → server hand-over animate with this; full reloads do not.
    static let insertAnimation: Animation = .snappy(duration: 0.28)

    public private(set) var messages: [ChatMessage] = []
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public private(set) var isLoadingOlder = false
    /// More history exists above the oldest loaded message.
    public private(set) var hasOlder = false
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

    /// Bound to the composer; the view reports each change with `draftChanged()`.
    public var draft: String = ""

    /// Who the first word of the draft names, once the server has said — "Rio Taxi ✓" over the
    /// keyboard while the person is still typing "RIO1 50". Nil while there is nothing to say.
    public private(set) var payeeHint: PayeeHint?

    private var hintTask: Task<Void, Never>?
    private var pendingHintKey: String?
    /// Lookups already answered, by upper-cased word: retyping a payee costs no request.
    private var lookups: [String: PayeeLookup] = [:]

    /// How long typing pauses before the payee is looked up.
    static let hintDelay: Duration = .milliseconds(350)

    /// Bumped on every send, so the view can tie a haptic to it.
    public private(set) var sendCount = 0

    /// Server message id → the id its bubble was first drawn with.
    ///
    /// When the server echo replaces an optimistic bubble the row keeps its original identity, so
    /// the list sees an in-place update (the clock turns into a tick) instead of a removal plus an
    /// insertion — which is what made sent messages flicker.
    public private(set) var rowAliases: [String: String] = [:]

    /// Local bubbles the server has not acknowledged: in flight, or failed.
    private var localIds: Set<String> = []
    private var olderCursor: String?
    /// A refresh that arrived mid-send; replayed once the send settles.
    private var refreshDeferred = false

    /// The load in flight, owned by the model rather than by the screen that asked for it.
    ///
    /// SwiftUI cancels a view's `.task` whenever the view leaves the screen, even for a moment — as
    /// the chat does while the tabs are rebuilt for the account just switched to. The request then
    /// came back cancelled, was shown as "Something went wrong", and the one-at-a-time guard skipped
    /// the load the reappearing screen asked for, so the alert stayed. A load the model owns runs to
    /// the end whatever the screen does, as the Android app's view-model scope does.
    private var loadTask: Task<Void, Never>?

    private let repository: HelloRepositoryProtocol

    public init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    public var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func rowID(for message: ChatMessage) -> String {
        rowAliases[message.id] ?? message.id
    }

    /// Changes whenever a message lands at the bottom; the view follows it.
    public var lastRowID: String? {
        messages.last.map { rowID(for: $0) }
    }

    public var lastMessageIsFromUser: Bool {
        messages.last?.isFromUser ?? false
    }

    // MARK: - Loading

    public func load() async {
        // One load at a time: the screen's own load and a refresh arriving before the conversation
        // is known would otherwise both ask for the thread at once. A second caller waits for the
        // load in flight instead of being turned away.
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task {
            await self.performLoad()
            self.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let conversation = try await repository.generalConversation()
            conversationId = conversation.id
            try await refreshMessages(conversationId: conversation.id, animated: false)
        } catch is CancellationError {
            // Nobody is waiting for this answer; the next load asks again.
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "conversations/general", error: error)
            errorMessage = error.userMessage
        } catch {
            errorMessage = L("chat_error_load")
        }
    }

    /// Re-reads the transcript. Called on realtime hints and on foreground.
    public func refresh() async {
        guard let conversationId else {
            await load()
            return
        }
        // A refresh landing mid-send would race the send's response: the server already holds the
        // user's message while its optimistic twin is still on screen, and both would be drawn.
        if isSending {
            refreshDeferred = true
            return
        }
        do {
            try await refreshMessages(conversationId: conversationId, animated: true)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "messages", error: error)
        } catch {
            // Silent: a background refresh failing should not interrupt the user.
        }
    }

    private func refreshMessages(conversationId: String, animated: Bool) async throws {
        let page = try await repository.messages(conversationId: conversationId, before: nil, limit: Self.pageSize)
        // Read alongside the page so a pending review card renders live on the first frame rather
        // than flashing "closed" until a second request lands. Failure is silent: this is
        // supplementary state and must not break the transcript.
        let pending = (try? await repository.pendingPaymentIntent()) ?? nil

        // Server returns newest-first; the transcript renders oldest-first.
        let merged = Self.merge(
            current: messages,
            latest: Array(page.messages.reversed()),
            localIds: localIds,
            pageIsFull: page.messages.count >= Self.pageSize
        )

        let known = Set(messages.map(\.id))
        let arrivals = merged.messages.filter { !known.contains($0.id) }.count
        if animated, !messages.isEmpty, (1...3).contains(arrivals) {
            withAnimation(Self.insertAnimation) { messages = merged.messages }
        } else {
            messages = merged.messages
        }
        localIds = merged.localIds
        resumableIntent = pending
        if !merged.keptOlder {
            olderCursor = page.nextCursor
            hasOlder = page.messages.count >= Self.pageSize && page.nextCursor != nil
        }
        errorMessage = nil
    }

    struct MergeResult: Equatable {
        let messages: [ChatMessage]
        let localIds: Set<String>
        /// Older pages loaded earlier were kept, so their cursor still applies.
        let keptOlder: Bool
    }

    /// Folds the newest page into what is on screen.
    ///
    /// - Older history loaded by scrolling up is kept, as long as the new page is full (a short
    ///   page *is* the whole conversation).
    /// - Local bubbles the server has not acknowledged stay at the end. Replacing the list
    ///   wholesale used to wipe a failed message the moment any realtime hint arrived, taking the
    ///   user's text and the retry with it.
    nonisolated static func merge(
        current: [ChatMessage],
        latest: [ChatMessage],
        localIds: Set<String>,
        pageIsFull: Bool
    ) -> MergeResult {
        let latestIds = Set(latest.map(\.id))
        let unsent = current.filter { localIds.contains($0.id) && !latestIds.contains($0.id) }

        var older: [ChatMessage] = []
        if pageIsFull, let boundary = latest.first?.sentAt {
            older = current.filter { message in
                guard !localIds.contains(message.id), !latestIds.contains(message.id),
                      let sentAt = message.sentAt else { return false }
                return sentAt < boundary
            }
        }

        return MergeResult(
            messages: older + latest + unsent,
            localIds: Set(unsent.map(\.id)),
            keptOlder: !older.isEmpty
        )
    }

    /// Loads the page above the oldest loaded message.
    public func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let conversationId, let cursor = olderCursor else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await repository.messages(conversationId: conversationId, before: cursor, limit: Self.pageSize)
            let known = Set(messages.map(\.id))
            let older = page.messages.reversed().filter { !known.contains($0.id) }
            messages.insert(contentsOf: older, at: 0)
            olderCursor = page.nextCursor
            hasOlder = page.messages.count >= Self.pageSize && page.nextCursor != nil
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "messages(older)", error: error)
        } catch {
            // Silent: the button stays, the user can tap again.
        }
    }

    // MARK: - Payment sheet

    /// Re-opens the review sheet for a payment the user backed out of.
    public func resumePendingPayment() {
        guard let resumableIntent else { return }
        pendingIntent = resumableIntent
    }

    /// Called by the view when the sheet closes, so the transcript stops offering a stale card.
    public func closePaymentSheet() {
        pendingIntent = nil
    }

    /// The confirm response. The receipt (or why it failed) goes into the transcript at once, and
    /// the review card learns how its payment ended — no waiting for a refresh or a realtime hint.
    public func applySettlement(_ intent: PaymentIntent) {
        withAnimation(Self.insertAnimation) {
            for (index, message) in messages.enumerated()
            where message.type == .paymentReview && message.paymentIntentId == intent.id {
                messages[index] = message.with(paymentIntent: intent)
            }
            for message in intent.messages ?? [] where !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        }
        if resumableIntent?.id == intent.id, intent.status != .pending {
            resumableIntent = nil
        }
    }

    // MARK: - Sending

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, conversationId != nil, !isSending else { return }
        draft = ""
        hintTask?.cancel()
        payeeHint = nil
        await send(text: text)
    }

    /// Sends `text` exactly as if typed — also used by tapped reply buttons.
    public func send(text: String) async {
        guard let conversationId, !isSending else { return }
        // Stable across retries — this is what makes a resend after a dropped response safe rather
        // than a duplicate message or a second payment intent.
        let clientMessageId = UUID().uuidString
        appendOptimistic(text: text, clientMessageId: clientMessageId)
        await deliver(text: text, clientMessageId: clientMessageId, conversationId: conversationId)
    }

    /// Resends a failed message with its original client id, so a send that did reach the server
    /// is replayed by the backend's idempotency check rather than duplicated.
    public func retry(messageId: String) async {
        guard let conversationId, !isSending, localIds.contains(messageId),
              let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].status == .failed,
              let text = messages[index].body else { return }
        messages[index] = messages[index].with(status: nil)
        await deliver(text: text, clientMessageId: messageId, conversationId: conversationId)
    }

    private func deliver(text: String, clientMessageId: String, conversationId: String) async {
        isSending = true
        sendCount += 1
        defer {
            isSending = false
            if refreshDeferred {
                refreshDeferred = false
                Task { await refresh() }
            }
        }

        do {
            let result = try await repository.sendText(
                conversationId: conversationId, text: text, clientMessageId: clientMessageId)
            apply(result: result, replacing: clientMessageId)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "messages", error: error)
            // The bubble turns red with a retry; an alert on top would only repeat it.
            markOptimisticFailed(clientMessageId)
        } catch {
            markOptimisticFailed(clientMessageId)
        }
    }

    /// Quick-action form path. The server composes the canonical command, so this cannot diverge
    /// from what free text accepts.
    public func sendPaymentForm(payee: String, voucherCode: String?, amount: Double) async {
        await sendForm(endpoint: "messages(form)", fallback: L("chat_error_payment")) { repository, conversationId, clientMessageId in
            try await repository.sendPaymentForm(
                conversationId: conversationId,
                payee: payee,
                voucherCode: voucherCode,
                amount: amount,
                clientMessageId: clientMessageId
            )
        }
    }

    /// "Withdraw to bank". The server composes the WhatsApp command `<IBAN> [amount]`; a nil amount
    /// withdraws the whole available balance. Nothing is held until the review card is confirmed.
    public func sendWithdrawal(iban: String, amount: Double?) async {
        await sendForm(endpoint: "messages(withdrawal)", fallback: L("chat_error_withdrawal")) { repository, conversationId, clientMessageId in
            try await repository.sendWithdrawalForm(
                conversationId: conversationId, iban: iban, amount: amount, clientMessageId: clientMessageId)
        }
    }

    /// An operator's top-up for a customer. Never drawn optimistically: the message carries the PIN,
    /// and the server's copy — the only one shown — has it redacted.
    public func sendTopUp(recipientPhone: String, amount: Double, pin: String) async {
        await sendForm(endpoint: "messages(topup)", fallback: L("chat_error_top_up")) { repository, conversationId, clientMessageId in
            try await repository.sendTopUpForm(
                conversationId: conversationId, recipientPhone: recipientPhone, amount: amount, pin: pin,
                clientMessageId: clientMessageId)
        }
    }

    /// Pays a payee the app already knows — a store from the directory, a "pay again" shortcut — as
    /// the guided form does: the server composes the command, and the review card follows in the
    /// chat. Works before the chat has loaded, so the Stores tab can pay straight away.
    public func pay(_ payee: PayeeRef, voucherCode: String?, amount: Double) async {
        let voucher = voucherCode?.trimmingCharacters(in: .whitespaces)
        await sendPaymentForm(payee: payee.code, voucherCode: voucher?.isEmpty == false ? voucher : nil, amount: amount)
    }

    /// The shared form path: no optimistic bubble (the user did not type a message), and the
    /// server's reply — a review card, or the reason it was refused — lands in the transcript.
    private func sendForm(
        endpoint: String,
        fallback: String,
        _ send: (HelloRepositoryProtocol, String, String) async throws -> SendMessageResult
    ) async {
        guard !isSending else { return }
        if conversationId == nil {
            conversationId = try? await repository.generalConversation().id
        }
        guard let conversationId else {
            errorMessage = fallback
            return
        }
        isSending = true
        defer {
            isSending = false
            if refreshDeferred {
                refreshDeferred = false
                Task { await refresh() }
            }
        }

        let clientMessageId = UUID().uuidString
        do {
            let result = try await send(repository, conversationId, clientMessageId)
            apply(result: result, replacing: nil)
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: endpoint, error: error)
            errorMessage = error.userMessage
        } catch {
            errorMessage = fallback
        }
    }

    private func apply(result: SendMessageResult, replacing clientMessageId: String?) {
        withAnimation(Self.insertAnimation) {
            if let clientMessageId {
                localIds.remove(clientMessageId)
            }
            if let message = result.message {
                if let clientMessageId, let index = messages.firstIndex(where: { $0.id == clientMessageId }) {
                    // In place, keeping the row identity — see `rowAliases`.
                    rowAliases[message.id] = clientMessageId
                    messages[index] = message
                } else if !messages.contains(where: { $0.id == message.id }) {
                    messages.append(message)
                }
            } else if let clientMessageId {
                messages.removeAll { $0.id == clientMessageId }
            }
            for reply in result.replies ?? [] where !messages.contains(where: { $0.id == reply.id }) {
                messages.append(reply)
            }
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
        localIds.insert(clientMessageId)
        let bubble = ChatMessage(
            id: clientMessageId,
            direction: .inbound,
            type: .text,
            body: text,
            payload: nil,
            status: nil,          // nil = not yet acknowledged (drawn with a clock)
            paymentIntentId: nil,
            sentAt: Date()
        )
        withAnimation(Self.insertAnimation) {
            messages.append(bubble)
        }
    }

    private func markOptimisticFailed(_ clientMessageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == clientMessageId }) else { return }
        messages[index] = messages[index].with(status: .failed)
    }

    public func dismissError() { errorMessage = nil }

    // MARK: - Payee hint

    /// Looks up the draft's first word a moment after the person stops typing it. Read-only and
    /// best-effort: a failed lookup shows nothing, and the payment itself is checked properly.
    public func draftChanged() {
        guard let word = PayeeHints.candidate(draft) else {
            hintTask?.cancel()
            payeeHint = nil
            return
        }
        let key = word.uppercased()
        if let known = lookups[key] {
            hintTask?.cancel()
            payeeHint = hint(for: key, lookup: known, draft: draft)
            return
        }
        // Still typing after the payee ("RIO1 5", "RIO1 50"): the lookup under way answers it.
        if hintTask != nil, pendingHintKey == key { return }
        hintTask?.cancel()
        pendingHintKey = key
        if payeeHint?.payee != key { payeeHint = nil }
        hintTask = Task { [weak self, repository] in
            try? await Task.sleep(for: ChatModel.hintDelay)
            var lookup: PayeeLookup?
            if !Task.isCancelled {
                lookup = try? await repository.lookupPayee(word)
            }
            guard let self else { return }
            // Finished either way: a failed lookup must not stop the next one for this word.
            if self.pendingHintKey == key { self.pendingHintKey = nil }
            guard !Task.isCancelled, let lookup else { return }
            self.lookups[key] = lookup
            if PayeeHints.candidate(self.draft)?.uppercased() == key {
                self.payeeHint = self.hint(for: key, lookup: lookup, draft: self.draft)
            }
        }
    }

    private func hint(for key: String, lookup: PayeeLookup, draft: String) -> PayeeHint? {
        if lookup.found {
            return PayeeHint(payee: key, found: true, name: lookup.name, code: lookup.code,
                             type: lookup.type, category: lookup.category)
        }
        // A number nobody's business answers to is most likely a person: say nothing either way.
        if PayeeHints.isPhone(key) { return nil }
        return PayeeHints.hasMore(draft) ? PayeeHint(payee: key, found: false) : nil
    }
}
