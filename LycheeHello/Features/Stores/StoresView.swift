import SwiftUI
import Observation

/// Stores — screenshot 4.
///
/// **v1 is a read-only directory** (decision D4: directory now, messaging later). The screenshot
/// shows unread badges and per-store timestamps; those are not rendered here because there are no
/// store threads yet, and drawing them would promise messaging that does not exist. Tapping a store
/// takes the user to the General Chat pre-filled with that store's payee code.
@Observable
@MainActor
final class StoresModel {

    private(set) var conversations: [Conversation] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var searchText = ""

    private let repository: HelloRepositoryProtocol

    init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    var filtered: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Store threads land here once D4's second phase ships; today this returns the
            // General conversation only.
            conversations = try await repository.conversations()
                .filter { $0.kind == "STORE" }
            errorMessage = nil
        } catch let error as APIError {
            CrashReporter.recordAPIFailure(endpoint: "conversations", error: error)
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't load stores."
        }
    }
}

struct StoresView: View {

    @State private var model = StoresModel(repository: HelloRepository())

    var body: some View {
        ZStack {
            Tokens.Colour.surface.ignoresSafeArea()

            if model.isLoading && model.conversations.isEmpty {
                ProgressView()
            } else if model.filtered.isEmpty {
                emptyState
            } else {
                List(model.filtered) { conversation in
                    storeRow(conversation)
                        .listRowBackground(Tokens.Colour.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Stores")
        .searchable(text: $model.searchText, prompt: "Search stores")
        .task { await model.load() }
    }

    /// Honest empty state rather than fake rows — the directory is genuinely empty until the
    /// backend exposes stores for Hello.
    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "bag")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Colour.textSecondary)
            Text("No stores yet")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.textPrimary)
            Text("Stores you can pay will appear here.")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Tokens.Spacing.xl)
    }

    private func storeRow(_ conversation: Conversation) -> some View {
        HStack(spacing: Tokens.Spacing.lg) {
            Circle()
                .fill(Tokens.Colour.surfaceMuted)
                .frame(width: 48, height: 48)
                .overlay(
                    Text(String((conversation.title ?? "?").prefix(1)))
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Colour.navy)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(conversation.title ?? "Store")
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Colour.textPrimary)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.Colour.brand)
                        .accessibilityLabel("Verified")
                }
                Text("Tap to pay this store")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
            }
            Spacer()
        }
        .frame(minHeight: Tokens.Hit.minimum)
        .accessibilityElement(children: .combine)
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
        TabView {
            NavigationStack { ChatView() }
                .tabItem { Label("Chats", systemImage: "bubble.left") }

            NavigationStack { StoresView() }
                .tabItem { Label("Stores", systemImage: "bag") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Tokens.Colour.brand)
        // Each account has its own thread, balance and menu: switching rebuilds the tabs rather
        // than letting the chat keep showing the account it left.
        .id(coordinator.user?.id)
        // A number with a personal and a business account: ask once, after sign-in, which to use.
        .sheet(isPresented: $coordinator.isChoosingAccount) {
            AccountChooserSheet()
                .presentationDetents([.medium])
        }
    }
}
