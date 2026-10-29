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
                    Text("Verified Lychee account")
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
