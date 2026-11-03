import SafariServices
import SwiftUI
import UIKit
import UserNotifications

/// The pages behind Settings' rows: Account & profile (with deactivation), Privacy & security,
/// Notifications and About. Help & support is the Lychee website, opened in the app.

/// Where Help, the privacy policy and "get the Lychee app" point.
enum LycheeLinks {
    static let website = URL(string: "https://lycheeapp.org/")!
}

// MARK: - In-app browser

/// Safari inside the app, so the user comes straight back to Settings when they close it.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Tokens.Colour.brandAccessible)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A page to open in `SafariView`, as a sheet item.
struct BrowsedPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Account & profile

struct AccountProfileView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @State private var editingName = false
    @State private var confirmDeactivate = false
    @State private var isDeactivating = false
    @State private var deactivateError: String?
    @State private var browsing: BrowsedPage?

    private var user: HelloUser? { coordinator.user }

    var body: some View {
        List {
            Section {
                HStack(spacing: Tokens.Spacing.lg) {
                    Text(user?.initials ?? "?")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Colour.navyFixed)
                        .frame(width: 64, height: 64)
                        .background(Tokens.Colour.surfaceMuted)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        Text(user?.resolvedDisplayName ?? "—")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Colour.textPrimary)
                        Text(kindLabel)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Colour.textSecondary)
                    }
                }
                .padding(.vertical, Tokens.Spacing.xs)
                .accessibilityElement(children: .combine)
            }

            Section {
                if user?.isGuest == true {
                    Button {
                        editingName = true
                    } label: {
                        detailRow(L("account_name"), user?.resolvedDisplayName ?? "—", chevron: true)
                    }
                } else {
                    detailRow(L("account_name"), user?.resolvedDisplayName ?? "—", chevron: false)
                }
                detailRow(L("account_phone"), phoneText, chevron: false)
                detailRow(L("account_type"), kindLabel, chevron: false)
            } footer: {
                Text(nameFooter)
            }

            if user?.isGuest == true {
                Section {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                        Label(L("account_guest_title"), systemImage: "sparkles")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Colour.textPrimary)
                        Text(L("account_guest_body"))
                            .font(.subheadline)
                            .foregroundStyle(Tokens.Colour.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("account_guest_get_app")) { browsing = BrowsedPage(url: LycheeLinks.website) }
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Colour.brandAccessible)
                            .padding(.top, Tokens.Spacing.xs)
                    }
                    .padding(.vertical, Tokens.Spacing.xs)
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDeactivate = true
                } label: {
                    HStack {
                        Text(L("account_deactivate"))
                            .foregroundStyle(Tokens.Colour.danger)
                        Spacer()
                        if isDeactivating { ProgressView() }
                    }
                }
                .disabled(isDeactivating)
            } footer: {
                Text(L("account_deactivate_footer"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .navigationTitle(L("settings_account"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingName) {
            EditNameSheet(firstName: user?.firstName ?? "", lastName: user?.lastName ?? "")
                .presentationDetents([.medium])
        }
        .sheet(item: $browsing) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .alert(L("account_deactivate_confirm_title"), isPresented: $confirmDeactivate) {
            Button(L("account_deactivate"), role: .destructive) { Task { await deactivate() } }
            Button(L("common_cancel"), role: .cancel) {}
        } message: {
            Text(L("account_deactivate_confirm_body"))
        }
        .alert(L("account_deactivate_failed"),
               isPresented: .init(get: { deactivateError != nil }, set: { if !$0 { deactivateError = nil } })) {
            Button(L("common_ok"), role: .cancel) { deactivateError = nil }
        } message: {
            Text(deactivateError ?? "")
        }
    }

    private var kindLabel: String {
        guard let user else { return "" }
        if user.isGuest { return L("account_guest") }
        if user.isBusiness {
            if let code = user.accountCode, !code.isEmpty { return L("account_business_code", code) }
            return L("account_business")
        }
        return L("account_personal")
    }

    private var nameFooter: String {
        guard let user else { return "" }
        if user.isGuest { return L("account_name_footer_guest") }
        return user.isBusiness ? L("account_name_footer_business") : L("account_name_footer_lychee")
    }

    private var phoneText: String {
        // Left to right in Arabic too.
        "\u{2066}\(user?.phoneNumber ?? "—")\u{2069}"
    }

    private func detailRow(_ title: String, _ value: String, chevron: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(Tokens.Colour.textPrimary)
            Spacer(minLength: Tokens.Spacing.md)
            Text(value)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Colour.textSecondary.opacity(0.6))
            }
        }
        .frame(minHeight: Tokens.Hit.minimum)
        .contentShape(Rectangle())
    }

    private func deactivate() async {
        isDeactivating = true
        defer { isDeactivating = false }
        do {
            try await coordinator.deactivateAccount()
        } catch let error as APIError {
            deactivateError = error.userMessage
        } catch {
            deactivateError = L("error_generic")
        }
    }
}

/// A guest's name — the only account whose name is edited in Hello. A Lychee account's name is
/// its registration's, and a business's is its trading name.
private struct EditNameSheet: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State var firstName: String
    @State var lastName: String
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let repository = HelloRepository()

    private var canSave: Bool {
        !isSaving
            && firstName.trimmingCharacters(in: .whitespaces).count >= 2
            && lastName.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("profile_first_name"), text: $firstName)
                        .textContentType(.givenName)
                        .focused($focused)
                    TextField(L("profile_last_name"), text: $lastName)
                        .textContentType(.familyName)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(Tokens.Colour.danger)
                    } else {
                        Text(L("profile_subtitle_ios"))
                    }
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .navigationTitle(L("account_name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(L("common_save")) { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let updated = try await repository.updateProfile(
                firstName: firstName.trimmingCharacters(in: .whitespaces),
                lastName: lastName.trimmingCharacters(in: .whitespaces))
            coordinator.didUpdateProfile(updated)
            dismiss()
        } catch let failure as APIError {
            error = failure.userMessage
        } catch {
            self.error = L("error_generic")
        }
    }
}

// MARK: - Privacy & security

struct PrivacySecurityView: View {

    @AppStorage("biometricLoginEnabled") private var biometricLogin = true
    @State private var browsing: BrowsedPage?

    var body: some View {
        List {
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
            } footer: {
                Text(L("privacy_code_warning"))
            }

            Section {
                Button {
                    browsing = BrowsedPage(url: LycheeLinks.website)
                } label: {
                    Label {
                        Text(L("privacy_policy")).foregroundStyle(Tokens.Colour.textPrimary)
                    } icon: {
                        Image(systemName: "hand.raised").foregroundStyle(Tokens.Colour.navy)
                    }
                    .frame(minHeight: Tokens.Hit.minimum)
                }
            } footer: {
                Text(L("privacy_policy_footer"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .navigationTitle(L("settings_privacy"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browsing) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }
}

// MARK: - Notifications

/// Whether this phone lets Lychee Hello notify, what it notifies about, and the way to change it —
/// iOS keeps the switch in its own Settings, so that is where the button goes.
struct NotificationsSettingsView: View {

    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        List {
            Section {
                HStack(spacing: Tokens.Spacing.md) {
                    Image(systemName: isOn ? "bell.badge.fill" : "bell.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(isOn ? Tokens.Colour.brand : Tokens.Colour.textSecondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isOn ? L("notifications_on") : L("notifications_off"))
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Colour.textPrimary)
                        Text(isOn ? L("notifications_on_body") : L("notifications_off_body"))
                            .font(.subheadline)
                            .foregroundStyle(Tokens.Colour.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Tokens.Spacing.xs)
                .accessibilityElement(children: .combine)

                if status == .notDetermined {
                    Button(L("notifications_turn_on")) { Task { await askPermission() } }
                        .foregroundStyle(Tokens.Colour.brandAccessible)
                } else {
                    Button(L("notifications_open_settings")) { openSystemSettings() }
                        .foregroundStyle(Tokens.Colour.brandAccessible)
                }
            }

            Section {
                bullet("arrow.down.circle", L("notifications_kind_received"))
                bullet("checkmark.circle", L("notifications_kind_payments"))
                bullet("bubble.left", L("notifications_kind_messages"))
            } header: {
                Text(L("notifications_kinds_header"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .navigationTitle(L("settings_notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await readStatus() }
        // Back from iOS Settings: show what the user chose there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await readStatus() } }
        }
    }

    private var isOn: Bool {
        switch status ?? .notDetermined {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private func bullet(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text).font(Tokens.Typography.body).foregroundStyle(Tokens.Colour.textPrimary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Tokens.Colour.navy)
        }
    }

    private func readStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func askPermission() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await readStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - About

struct AboutView: View {

    @State private var browsing: BrowsedPage?

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return L("about_version", short, build)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Tokens.Spacing.md) {
                    BrandLockup(width: 200)
                    Text(version)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.Colour.textSecondary)
                    Text(L("about_body"))
                        .font(.subheadline)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.lg)
                .listRowBackground(Color.clear)
            }

            Section {
                linkRow(L("about_website"), "globe")
                linkRow(L("privacy_policy"), "hand.raised")
            } footer: {
                Text(L("about_copyright", String(Calendar.current.component(.year, from: Date()))))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .navigationTitle(L("settings_about"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browsing) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }

    private func linkRow(_ title: String, _ systemImage: String) -> some View {
        Button {
            browsing = BrowsedPage(url: LycheeLinks.website)
        } label: {
            Label {
                HStack {
                    Text(title).foregroundStyle(Tokens.Colour.textPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tokens.Colour.textSecondary.opacity(0.6))
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Tokens.Colour.navy)
            }
            .frame(minHeight: Tokens.Hit.minimum)
        }
    }
}
