import SwiftUI

/// Settings — screenshot 5.
///
/// Uses a SwiftUI `List` with `.insetGrouped`, which reproduces the screenshot's grouped-card look
/// natively while keeping Dynamic Type, VoiceOver grouping and the standard row hit targets. A
/// hand-built stack of rounded `VStack`s would look identical and lose all three.
struct SettingsView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @AppStorage("biometricLoginEnabled") private var biometricLogin = true
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue
    /// Applied at once by `AppAppearanceApplier` at the root — nothing restarts.
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var showSignOutConfirm = false
    /// Opens the Pay sheet for a payee from a receipt in the history.
    var onPay: (PayeeRef) -> Void = { _ in }

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
                                        Text(L("settings_switch_to", (account.name ?? L(account.isBusiness ? "settings_switch_business" : "settings_switch_personal")).bidiIsolated))
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
                        Text(L("settings_switch_footer"))
                    }
                }

                Section {
                    NavigationLink {
                        HistoryView(onPay: onPay)
                    } label: {
                        row(L("history_title"), L("settings_history_subtitle"), "list.bullet.rectangle.portrait")
                    }
                    Picker(selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(Self.name(of: language)).tag(language)
                        }
                    } label: {
                        row(L("settings_language"), Self.name(of: AppLanguage(rawValue: languageRaw) ?? .system), "globe")
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text(L("settings_language_note"))
                }

                Section {
                    row(L("settings_account"), L("settings_account_subtitle"), "person")
                    row(L("settings_privacy"), L("settings_privacy_subtitle"), "lock.shield")
                    row(L("settings_notifications"), L("settings_notifications_subtitle"), "bell")
                }

                Section {
                    Picker(selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    } label: {
                        row(L("settings_appearance"), (AppAppearance(rawValue: appearanceRaw) ?? .system).title, "moon")
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text(L("settings_appearance_note"))
                }

                Section {
                    Toggle(isOn: $biometricLogin) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("settings_biometric")).font(Tokens.Typography.body)
                                Text(L("settings_biometric_use", BiometricGate.biometryName))
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
                    row(L("settings_help"), L("settings_help_subtitle"), "questionmark.circle")
                    row(L("settings_about"), L("settings_about_subtitle"), "info.circle")
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Text(L("settings_log_out"))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Tokens.Colour.danger)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L("settings_title"))
        .overlay {
            if coordinator.isSwitchingAccount {
                ProgressView(L("settings_switching"))
                    .padding(Tokens.Spacing.lg)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }
        }
        .alert(L("settings_switch_failed"),
               isPresented: .init(get: { coordinator.accountSwitchError != nil },
                                  set: { if !$0 { coordinator.accountSwitchError = nil } })) {
            Button(L("common_ok"), role: .cancel) { coordinator.accountSwitchError = nil }
        } message: {
            Text(coordinator.accountSwitchError ?? "")
        }
        .confirmationDialog(L("settings_log_out_confirm"),
                            isPresented: $showSignOutConfirm,
                            titleVisibility: .visible) {
            Button(L("settings_log_out"), role: .destructive) {
                Task { await coordinator.signOut() }
            }
            Button(L("common_cancel"), role: .cancel) {}
        }
    }

    private var profileCard: some View {
        HStack(spacing: Tokens.Spacing.lg) {
            Text(coordinator.user?.initials ?? "?")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Colour.navyFixed)
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
        guard let user = coordinator.user else { return L("account_verified") }
        if user.isBusiness {
            if let code = user.accountCode, !code.isEmpty { return L("account_business_code", code) }
            return L("account_business")
        }
        return coordinator.accounts.count > 1 ? L("account_personal") : L("account_verified")
    }

    /// Changing the language rebuilds the screens in it (see `RootView`), and `/me` carries the new
    /// `Accept-Language`, which the server records: what it writes for this user unprompted — a
    /// payment received, a push — follows.
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { language in
                guard language.rawValue != languageRaw else { return }
                AppLanguage.set(language)
                languageRaw = language.rawValue
                Task { await coordinator.refreshCapabilities() }
            }
        )
    }

    /// "System default (English)", "English", "العربية" — each language named in itself.
    static func name(of language: AppLanguage) -> String {
        switch language {
        case .system:
            return L("settings_language_system", AppLanguage.effectiveTag(for: .system) == "ar" ? "العربية" : "English")
        case .english:
            return "English"
        case .arabic:
            return "العربية"
        }
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
                Text(L("account_chooser_body"))
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
                                    Text(account.name ?? L(account.isBusiness ? "account_chooser_business" : "account_chooser_personal"))
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
                                        .accessibilityLabel(L("account_signed_in"))
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
            .navigationTitle(L("account_chooser_title"))
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
