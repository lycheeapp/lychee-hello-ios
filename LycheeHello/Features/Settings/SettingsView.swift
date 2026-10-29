import SwiftUI

/// Settings — screenshot 5.
///
/// Uses a SwiftUI `List` with `.insetGrouped`, which reproduces the screenshot's grouped-card look
/// natively while keeping Dynamic Type, VoiceOver grouping and the standard row hit targets. A
/// hand-built stack of rounded `VStack`s would look identical and lose all three.
struct SettingsView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @AppStorage("biometricLoginEnabled") private var biometricLogin = true
    @State private var showSignOutConfirm = false

    var body: some View {
        ZStack {
            Tokens.Colour.surface.ignoresSafeArea()

            List {
                Section {
                    profileCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if !coordinator.otherAccounts.isEmpty {
                    Section {
                        ForEach(coordinator.otherAccounts) { account in
                            Button {
                                Task { await coordinator.switchAccount(to: account) }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Switch to \(account.name ?? (account.isBusiness ? "business" : "personal"))")
                                            .font(Tokens.Typography.body)
                                            .foregroundStyle(Tokens.Colour.textPrimary)
                                        Text(account.kindLabel)
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Colour.textSecondary)
                                    }
                                } icon: {
                                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Tokens.Colour.navy)
                                }
                                .frame(minHeight: Tokens.Hit.minimum)
                            }
                            .disabled(coordinator.isSwitchingAccount)
                        }
                    } footer: {
                        Text("Payments come from the account you're signed in as.")
                    }
                }

                Section {
                    row("Account & profile", "Personal details and phone number", "person")
                    row("Privacy & security", "Blocked accounts and connected devices", "lock.shield")
                    row("Notifications", "Messages and payment alerts", "bell")
                    row("Appearance", "Light mode", "moon")
                }

                Section {
                    Toggle(isOn: $biometricLogin) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Biometric login").font(Tokens.Typography.body)
                                Text("Use \(BiometricGate.biometryName)")
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Colour.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "faceid").foregroundStyle(Tokens.Colour.navy)
                        }
                    }
                    .tint(Tokens.Colour.brand)
                }

                Section {
                    row("Help & support", "Get help with Lychee Hello", "questionmark.circle")
                    row("About Lychee Hello", "Privacy, terms and app information", "info.circle")
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Text("Log out")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Tokens.Colour.danger)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .overlay {
            if coordinator.isSwitchingAccount {
                ProgressView("Switching account…")
                    .padding(Tokens.Spacing.lg)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }
        }
        .alert("Couldn't switch accounts",
               isPresented: .init(get: { coordinator.accountSwitchError != nil },
                                  set: { if !$0 { coordinator.accountSwitchError = nil } })) {
            Button("OK", role: .cancel) { coordinator.accountSwitchError = nil }
        } message: {
            Text(coordinator.accountSwitchError ?? "")
        }
        .confirmationDialog("Log out of Lychee Hello?",
                            isPresented: $showSignOutConfirm,
                            titleVisibility: .visible) {
            Button("Log out", role: .destructive) {
                Task { await coordinator.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var profileCard: some View {
        HStack(spacing: Tokens.Spacing.lg) {
            Text(coordinator.user?.initials ?? "?")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Colour.navy)
                .frame(width: 64, height: 64)
                .background(Color.white)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(coordinator.user?.resolvedDisplayName ?? "—")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Colour.textOnDark)
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(accountLine)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.textOnDark.opacity(0.85))
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.Colour.brand)
                }
            }
            Spacer()
        }
        .padding(Tokens.Spacing.lg)
        .background(Tokens.Colour.cardGradient)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .padding(.vertical, Tokens.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    /// "Verified Lychee account", or which account this is when the number has two.
    private var accountLine: String {
        guard let user = coordinator.user else { return "Verified Lychee account" }
        if user.isBusiness {
            if let code = user.accountCode, !code.isEmpty { return "Business account · \(code)" }
            return "Business account"
        }
        return coordinator.accounts.count > 1 ? "Personal account" : "Verified Lychee account"
    }

    /// Placeholder destinations. Wired as non-navigating rows rather than dead `NavigationLink`s so
    /// the UI never promises a screen that does not exist.
    private func row(_ title: String, _ subtitle: String, _ systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Tokens.Typography.body).foregroundStyle(Tokens.Colour.textPrimary)
                Text(subtitle).font(Tokens.Typography.caption).foregroundStyle(Tokens.Colour.textSecondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Tokens.Colour.navy)
        }
        .frame(minHeight: Tokens.Hit.minimum)
    }
}

/// Asked once, after signing in to a number that has both a personal and a business account:
/// which one to use. Payments come from the account on screen, so this is not a guess the app
/// makes for the person. Settings offers the same switch any time.
struct AccountChooserSheet: View {

    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                Text("This number has more than one Lychee account. Payments come from the one you choose — you can switch any time in Settings.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Colour.textSecondary)

                VStack(spacing: Tokens.Spacing.sm) {
                    ForEach(coordinator.accounts) { account in
                        Button {
                            choose(account)
                        } label: {
                            HStack(spacing: Tokens.Spacing.md) {
                                Image(systemName: account.isBusiness ? "storefront" : "person")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Tokens.Colour.navy)
                                    .frame(width: 40, height: 40)
                                    .background(Tokens.Colour.surfaceMuted)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name ?? (account.isBusiness ? "Business" : "Personal"))
                                        .font(Tokens.Typography.headline)
                                        .foregroundStyle(Tokens.Colour.textPrimary)
                                    Text(account.kindLabel)
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(Tokens.Colour.textSecondary)
                                }
                                Spacer()
                                if account.current {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Tokens.Colour.brand)
                                        .accessibilityLabel("Signed in")
                                }
                            }
                            .padding(Tokens.Spacing.md)
                            .background(Tokens.Colour.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.isSwitchingAccount)
                    }
                }

                if coordinator.isSwitchingAccount {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                Spacer()
            }
            .padding(Tokens.Spacing.gutter)
            .background(Tokens.Colour.surface.ignoresSafeArea())
            .navigationTitle("Which account?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(coordinator.isSwitchingAccount)
    }

    private func choose(_ account: Account) {
        guard !account.current else {
            coordinator.isChoosingAccount = false
            return
        }
        Task {
            await coordinator.switchAccount(to: account)
            coordinator.isChoosingAccount = false
        }
    }
}
