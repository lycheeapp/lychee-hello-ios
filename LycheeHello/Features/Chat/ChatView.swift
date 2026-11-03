import SwiftUI
import UIKit

/// The General Chat, laid out like a WhatsApp conversation: avatar header, pinned balance,
/// wallpaper, tailed bubbles with inline time and ticks, day chips, and a "+" composer.
///
/// Smoothness choices, all deliberate:
/// - the wallpaper is drawn once behind the scroll view, never inside it;
/// - rows have stable identities (see `ChatModel.rowAliases`), so a sent bubble updates in place;
/// - only small appends animate — a reload of fifty rows does not;
/// - the transcript follows new messages only when the user is already at the bottom, or sent the
///   message themselves; otherwise a scroll-to-latest button appears.
struct ChatView: View {

    static let bottomID = "chat-bottom"

    @Environment(SessionCoordinator.self) private var coordinator
    /// Owned by the tabs: every tab can start a payment, and every payment goes through the chat.
    let model: ChatModel
    /// Opens the Pay sheet for a payee from a receipt.
    var onPay: (PayeeRef) -> Void = { _ in }
    @State private var balanceHidden = false
    @State private var activeForm: PaymentFormSheet.Mode?
    @State private var isAtBottom = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            transcript(proxy)
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        ScrollToBottomButton { scrollToBottom(proxy, animated: true) }
                            .padding(.trailing, 6)
                            .padding(.bottom, 6)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: isAtBottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    PinnedBalanceBar(
                        balance: coordinator.balance,
                        isHidden: balanceHidden,
                        onToggleHidden: { balanceHidden.toggle() }
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                    PayeeHintChip(hint: model.payeeHint)
                    ChatComposer(
                        draft: $model.draft,
                        focus: $composerFocused,
                        canSend: model.canSend,
                        canPay: coordinator.canPay,
                        capabilities: coordinator.capabilities,
                        onSend: { Task { await model.send() } },
                        onPick: { activeForm = $0 },
                        onBalance: { Task { await model.send(text: "BALANCE") } }
                    )
                    }
                }
                .onChange(of: model.draft) { _, _ in
                    model.draftChanged()
                }
                .onChange(of: model.lastRowID) { _, newValue in
                    guard newValue != nil else { return }
                    // Follow the conversation, unless the user has scrolled up to read something —
                    // then only their own new message pulls them down.
                    if isAtBottom || model.lastMessageIsFromUser {
                        scrollToBottom(proxy, animated: true)
                    }
                }
                // Opening the keyboard to type moves the conversation up with it, as WhatsApp does:
                // the latest message stays just above the composer instead of the keyboard covering
                // the middle of the chat. Done on the keyboard's own notifications — the transcript
                // has shrunk by then — and once more when it has finished moving.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    guard composerFocused else { return }
                    Task {
                        await Task.yield()
                        scrollToBottom(proxy, animated: true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    guard composerFocused else { return }
                    scrollToBottom(proxy, animated: false)
                }
                // Focus can land a moment after the keyboard's first notification.
                .onChange(of: composerFocused) { _, focused in
                    guard focused else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(120))
                        scrollToBottom(proxy, animated: true)
                    }
                }
                // The first page has landed: start at the latest message. Without this the transcript
                // could sit on an empty stretch until the user scrolled or sent something.
                .onChange(of: model.isLoading) { wasLoading, isLoading in
                    guard wasLoading, !isLoading else { return }
                    settleAtBottom(proxy)
                }
                .onAppear {
                    if !model.messages.isEmpty { settleAtBottom(proxy) }
                }
        }
        .background { ChatWallpaper().ignoresSafeArea() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Tokens.Chat.bar, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Tokens.Chat.bar, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ChatHeaderTitle(isTyping: model.isSending)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Payment history, where WhatsApp keeps a chat's media and files.
                NavigationLink {
                    HistoryView(onPay: onPay)
                } label: {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .foregroundStyle(Tokens.Chat.meta)
                }
                .accessibilityLabel(L("history_title"))
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.sendCount)
        .task { await model.load() }
        .onAppear { ChatVisibility.isShowing = true }
        .onDisappear { ChatVisibility.isShowing = false }
        // Realtime hints arrive via the coordinator; the chat never talks to SSE directly.
        .onChange(of: coordinator.chatInvalidationToken) { _, _ in
            Task { await model.refresh() }
        }
        .sheet(item: $model.pendingIntent) { intent in
            PaymentReviewSheet(intent: intent, onSettled: { settled in
                // The receipt is in the confirm response: draw it now, under the sheet, so it is
                // there the moment the sheet closes.
                model.applySettlement(settled)
                Task { await coordinator.refreshBalance() }
            }) {
                // Clearing the binding is what dismisses an `.sheet(item:)` — deterministic, and
                // it does not depend on the environment's dismiss action resolving correctly.
                model.closePaymentSheet()
                Task { await model.refresh(); await coordinator.refreshBalance() }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $activeForm) { mode in
            PaymentFormSheet(mode: mode) { submission in
                Task {
                    switch submission {
                    case let .payment(payee, voucher, amount):
                        await model.sendPaymentForm(payee: payee, voucherCode: voucher, amount: amount)
                    case let .withdrawal(iban, amount):
                        await model.sendWithdrawal(iban: iban, amount: amount)
                    case let .topUp(phone, amount, pin):
                        await model.sendTopUp(recipientPhone: phone, amount: amount, pin: pin)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert(L("common_something_went_wrong"),
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.dismissError() } })) {
            Button(L("common_ok"), role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Transcript

    /// A plain `VStack`, not a `LazyVStack`: rows are made eagerly, so the scroll view always knows
    /// the real height of what it holds. With lazy rows it guessed, and anchored to the bottom it
    /// could show a blank stretch after loading (until a scroll or a send forced the rows in), and a
    /// scroll to the latest message — the arrow — fell short or did nothing. History arrives a page
    /// at a time, so the transcript stays a size an eager stack handles easily.
    private func transcript(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                header(proxy)

                ForEach(ChatRowBuilder.rows(for: model.messages, aliases: model.rowAliases)) { row in
                    rowView(row)
                        .padding(.top, topSpacing(for: row))
                        .id(row.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // Bottom sentinel: scroll target, and the "is the user at the bottom" probe.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomID)
                    .onGeometryChange(for: Bool.self) { geometry in
                        guard let visible = geometry.bounds(of: .scrollView) else { return true }
                        return geometry.frame(in: .scrollView).minY <= visible.height + 120
                    } action: { atBottom in
                        isAtBottom = atBottom
                    }
            }
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func header(_ proxy: ScrollViewProxy) -> some View {
        if model.hasOlder {
            Button {
                loadOlder(proxy)
            } label: {
                Group {
                    if model.isLoadingOlder {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("chat_load_earlier"))
                    }
                }
                .font(Tokens.Chat.chip)
                .foregroundStyle(Tokens.Chat.action)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Tokens.Chat.dateChip))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
        } else if !model.isLoading || !model.messages.isEmpty {
            // The top of the conversation, like WhatsApp's encryption notice.
            NoticePill(Text("\(Image(systemName: "lock.fill")) \(L("chat_notice"))"))
                .padding(.top, 10)
        }

        if model.isLoading && model.messages.isEmpty {
            ProgressView()
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        } else if !model.isLoading && model.messages.isEmpty {
            emptyState
        }
    }

    private func topSpacing(for row: ChatRow) -> CGFloat {
        switch row.kind {
        case .day:
            return 10
        case .message:
            return row.isFirstInRun ? Tokens.Chat.groupSpacing : Tokens.Chat.runSpacing
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row.kind {
        case let .day(label):
            DayChip(label: label)
                .padding(.vertical, 2)
        case let .message(message):
            messageView(message, row: row)
        }
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage, row: ChatRow) -> some View {
        let time = ChatRowBuilder.time(for: message)
        let tail: BubbleTail = row.isLastInRun ? (message.isFromUser ? .trailing : .leading) : .none

        switch message.type {
        case .system:
            NoticePill(message.body ?? "")

        case .paymentReview:
            BubbleRow(fromUser: false) {
                // Rendered from the authoritative intent, matched by public id — never from the
                // message payload. `resumableIntent` survives an app restart, so a backed-out
                // payment can be reopened from its card.
                if let intent = model.resumableIntent, intent.id == message.paymentIntentId {
                    PaymentRequestBubble(intent: intent, time: time, tail: tail) {
                        model.resumePendingPayment()
                    }
                } else {
                    // Settled, cancelled or expired: the card says which, from the payment as the
                    // server sent it with the card.
                    ClosedPaymentRequestBubble(intent: message.paymentIntent, time: time, tail: tail)
                }
            }

        case .paymentReceipt:
            BubbleRow(fromUser: false) {
                PaymentReceiptBubble(message: message, time: time, tail: tail, onPayAgain: onPay)
            }

        case .paymentReceived:
            BubbleRow(fromUser: false) {
                PaymentReceivedBubble(message: message, time: time, tail: tail)
            }

        case .quickReplies:
            BubbleRow(fromUser: message.isFromUser) {
                VStack(alignment: .leading, spacing: Tokens.Chat.runSpacing) {
                    TextBubble(message: message, time: time, ticks: row.ticks, tail: tail, fillsWidth: true)
                    ReplyButtons(
                        replies: message.quickReplyOptions,
                        isEnabled: { reply in
                            !ReplyAction(reply: reply).needsPayableWallet || coordinator.canPay
                        },
                        onTap: { handleReply($0) }
                    )
                }
            }

        default:
            BubbleRow(fromUser: message.isFromUser) {
                HStack(spacing: 4) {
                    if row.ticks == .failed {
                        RetryButton { Task { await model.retry(messageId: message.id) } }
                    }
                    TextBubble(message: message, time: time, ticks: row.ticks, tail: tail)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ChatAvatar(size: 64)
            Text(coordinator.user?.firstName.flatMap { $0.isEmpty ? nil : L("chat_empty_hi_name", $0) } ?? L("chat_empty_hi"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Tokens.Chat.text)
            Text(L("chat_empty_intro"))
                .font(.subheadline)
                .foregroundStyle(Tokens.Chat.meta)
            VStack(alignment: .leading, spacing: 6) {
                example(L("chat_example_balance_command"), L("chat_example_balance_meaning"))
                example(L("chat_example_voucher_command"), L("chat_example_voucher_meaning"))
                example(L("chat_example_check_command"), L("chat_example_check_meaning"))
            }
            Text(L("chat_empty_outro"))
                .font(.footnote)
                .foregroundStyle(Tokens.Chat.meta)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tokens.Chat.bubbleIncoming.opacity(0.92))
        )
        .padding(.horizontal, 32)
        .padding(.top, 32)
    }

    private func example(_ command: String, _ meaning: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .foregroundStyle(Tokens.Chat.text)
            Text(meaning)
                .font(.footnote)
                .foregroundStyle(Tokens.Chat.meta)
        }
    }

    // MARK: - Actions

    private func handleReply(_ reply: QuickReply) {
        switch ReplyAction(reply: reply) {
        case let .openForm(mode):
            activeForm = mode
        case let .send(text):
            Task { await model.send(text: text) }
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        // Keep the message the user was looking at in place once older ones are inserted above.
        let anchor = model.messages.first.map { model.rowID(for: $0) }
        Task {
            await model.loadOlder()
            if let anchor {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    /// Scrolls to the latest message now, and again after the next layout pass: rows that just
    /// arrived are measured during it, and a single scroll could stop short of them.
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy, animated: false)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            scrollToBottom(proxy, animated: false)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}

/// "Rio Taxi ✓" over the keyboard while "RIO1 50" is still being typed: who the payment will go to,
/// before the review card — or that no payee has that code, before a message is wasted on it.
struct PayeeHintChip: View {
    let hint: PayeeHint?

    var body: some View {
        Group {
            if let hint {
                HStack(spacing: 6) {
                    if hint.found {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Tokens.Chat.success)
                        Text((hint.name ?? hint.code ?? hint.payee).bidiIsolated)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tokens.Chat.text)
                            .lineLimit(1)
                        if let summary = PaymentRecipient.summary(type: hint.type, category: hint.category, code: hint.code) {
                            Text("· \(summary)")
                                .font(.footnote)
                                .foregroundStyle(Tokens.Chat.meta)
                                .lineLimit(1)
                        }
                    } else {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Tokens.Chat.meta)
                        Text(L("chat_hint_not_found", hint.payee.bidiIsolated))
                            .font(.subheadline)
                            .foregroundStyle(Tokens.Chat.meta)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Tokens.Chat.bubbleIncoming.opacity(0.96)))
                .overlay(Capsule().strokeBorder(Tokens.Chat.barHairline, lineWidth: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.snappy(duration: 0.2), value: hint)
    }
}
