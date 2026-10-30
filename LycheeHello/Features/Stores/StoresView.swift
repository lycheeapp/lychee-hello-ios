import SwiftUI
import Observation

/// The Stores tab: every store the app can pay, from the server's directory, searched on the server
/// (a name or a code), a page at a time — and the "pay again" row of the caller's recent payees.
///
/// Read-only. Tapping a store opens the Pay sheet; paying goes through the chat.
@Observable
@MainActor
final class StoresModel {

    private(set) var entries: [DirectoryEntry] = []
    /// "Pay again": the caller's recent payees, newest first.
    private(set) var recent: [RecentPayee] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loaded = false
    private(set) var errorMessage: String?
    private var nextPage: Int?
    /// The query the entries on screen answer.
    private var loadedQuery = ""

    var query = ""

    private let repository: HelloRepositoryProtocol

    init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    var showsRecent: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && !recent.isEmpty }
    var hasMore: Bool { nextPage != nil }

    /// The first page for the current query. Called on appear and, debounced, as the query changes.
    func search() async {
        let current = query
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.directory(query: current, page: 0)
            guard current == query else { return }
            entries = page.entries
            nextPage = page.nextPage
            loadedQuery = current
            loaded = true
            errorMessage = nil
        } catch {
            // A search overtaken by the next keystroke is not a failure.
            guard current == query, !Task.isCancelled else { return }
            if let error = error as? APIError {
                CrashReporter.recordAPIFailure(endpoint: "directory", error: error)
                errorMessage = error.userMessage
            } else {
                errorMessage = L("stores_error_load")
            }
        }
    }

    func loadMore() async {
        guard let page = nextPage, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = loadedQuery
        guard let result = try? await repository.directory(query: current, page: page),
              current == loadedQuery else { return }
        let known = Set(entries.map(\.code))
        entries += result.entries.filter { !known.contains($0.code) }
        nextPage = result.nextPage
    }

    /// Supplementary: without it the directory still works.
    func refreshRecent() async {
        if let recent = try? await repository.recentPayees() {
            self.recent = recent
        }
    }
}

struct StoresView: View {

    @State private var model = StoresModel(repository: HelloRepository())
    /// Opens the Pay sheet.
    var onPay: (PayeeRef) -> Void = { _ in }

    var body: some View {
        // The list is the screen's root and is always there — loading and empty states sit over it.
        // The navigation bar finds its scroll view when the screen first appears; a list that only
        // replaced a spinner later left the large title sitting lower than on the other tabs (and
        // not collapsing on scroll), because the bar was laid out without it.
        list
            .overlay {
                if model.entries.isEmpty && !model.showsRecent {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        emptyState
                    }
                }
            }
            .background(Tokens.Colour.surface.ignoresSafeArea())
            .navigationTitle(L("stores_title"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $model.query, prompt: L("stores_search"))
            .task { await model.refreshRecent() }
            // Debounced on the server, so a search covers every store, not just the loaded page.
            .task(id: model.query) {
                if model.loaded {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                await model.search()
            }
    }

    private var list: some View {
        List {
            if model.showsRecent {
                Section {
                    recentRow
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Tokens.Colour.surface)
                } header: {
                    Text(L("stores_pay_again"))
                }
            }
            Section {
                ForEach(model.entries) { entry in
                    Button {
                        onPay(PayeeRef(entry))
                    } label: {
                        storeRow(entry)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Tokens.Colour.surface)
                    .onAppear {
                        if entry.code == model.entries.last?.code {
                            Task { await model.loadMore() }
                        }
                    }
                }
                if model.isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Tokens.Colour.surface)
                }
            } header: {
                if model.showsRecent { Text(L("stores_all")) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// "Pay again": round avatars of the latest payees, as WhatsApp lays out its status row.
    private var recentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.recent) { payee in
                    Button {
                        onPay(PayeeRef(payee))
                    } label: {
                        VStack(spacing: 6) {
                            PayeeAvatar(name: payee.displayName, size: 56)
                            Text(payee.displayName)
                                .font(.caption)
                                .foregroundStyle(Tokens.Colour.textPrimary)
                                .lineLimit(1)
                        }
                        .frame(width: 76)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(L("stores_pay_again"))
                }
            }
        }
    }

    private func storeRow(_ entry: DirectoryEntry) -> some View {
        HStack(spacing: Tokens.Spacing.lg) {
            PayeeAvatar(name: entry.displayName, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                PayeeNameLine(name: entry.displayName, verified: true)
                Text(entry.subtitle ?? L("stores_tap_to_pay"))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The code a message to this store starts with — what to type next time.
            Text(entry.code)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(Tokens.Colour.navy)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.Colour.surfaceMuted))
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(minHeight: Tokens.Hit.minimum)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Honest rather than fake rows: what is missing, and why.
    private var emptyState: some View {
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: searching ? "magnifyingglass" : "bag")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Colour.textSecondary)
            Text(model.errorMessage != nil ? L("stores_error_title")
                 : searching ? L("stores_no_match_title") : L("stores_none_title"))
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.textPrimary)
            Text(model.errorMessage
                 ?? (searching ? L("stores_no_match_body", model.query.trimmingCharacters(in: .whitespaces).bidiIsolated)
                     : L("stores_none_body")))
                .font(Tokens.Typography.body)
                .foregroundStyle(model.errorMessage != nil ? Tokens.Colour.danger : Tokens.Colour.textSecondary)
                .multilineTextAlignment(.center)
            if model.errorMessage != nil {
                Button(L("common_try_again")) { Task { await model.search() } }
                    .foregroundStyle(Tokens.Colour.brandAccessible)
            }
        }
        .padding(.horizontal, Tokens.Spacing.xl)
    }
}

/// A payee's round avatar: their first letter on the brand tint.
struct PayeeAvatar: View {
    let name: String
    var size: CGFloat = 48

    var body: some View {
        Circle()
            .fill(Tokens.Colour.surfaceMuted)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Tokens.Colour.navy)
            )
            .accessibilityHidden(true)
    }
}

/// A payee's name, with the verified mark when it is a business, store, branch or bus.
struct PayeeNameLine: View {
    let name: String
    let verified: Bool
    var font: Font = Tokens.Typography.headline

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(name)
                .font(font)
                .foregroundStyle(Tokens.Colour.textPrimary)
                .lineLimit(1)
            if verified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.Colour.brand)
                    .accessibilityLabel(L("payee_verified"))
            }
        }
    }
}

/// Bottom navigation — Chats / Stores / Settings.
///
/// A standard `TabView` rather than the screenshot's floating pill: it gives the correct safe-area
/// behaviour, VoiceOver tab semantics and Dynamic Type for free, and matches what iOS users expect
/// (decision D5 — brand-identical, platform-native).
struct MainTabView: View {

    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        // Each account has its own thread, balance and menu: switching rebuilds the tabs rather
        // than letting the chat keep showing the account it left.
        MainTabs()
            .id(coordinator.user?.id)
            // A number with a personal and a business account: ask once, after sign-in, which to use.
            .sheet(isPresented: $coordinator.isChoosingAccount) {
                AccountChooserSheet()
                    .presentationDetents([.medium])
            }
    }
}

/// The tabs of one signed-in account.
///
/// The chat's model lives here, above the tabs, because every tab can start a payment — a store,
/// a "pay again" shortcut, a receipt in the history — and every payment goes through the chat: the
/// Pay sheet hands it over, and the Chats tab shows the review card.
private struct MainTabs: View {

    enum Tab: Hashable { case chats, stores, settings }

    @Environment(SessionCoordinator.self) private var coordinator
    @State private var chatModel = ChatModel(repository: HelloRepository())
    @State private var selection: Tab = .chats
    @State private var paying: PayeeRef?

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { ChatView(model: chatModel, onPay: { paying = $0 }) }
                .tabItem { Label(L("tab_chats"), systemImage: "bubble.left") }
                .tag(Tab.chats)

            NavigationStack { StoresView(onPay: { paying = $0 }) }
                .tabItem { Label(L("tab_stores"), systemImage: "bag") }
                .tag(Tab.stores)

            NavigationStack { SettingsView(onPay: { paying = $0 }) }
                .tabItem { Label(L("tab_settings"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Tokens.Colour.brand)
        .sheet(item: $paying) { payee in
            PaySheet(payee: payee, canPayFromBalance: coordinator.canPay) { voucher, amount in
                paying = nil
                selection = .chats
                Task {
                    // Let this sheet finish closing: the review card opens as a sheet of its own.
                    try? await Task.sleep(for: .milliseconds(450))
                    await chatModel.pay(payee, voucherCode: voucher, amount: amount)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}
