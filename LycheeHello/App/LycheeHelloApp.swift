import SwiftUI

@main
struct LycheeHelloApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SessionCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .task { await coordinator.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Returning to foreground: re-read authoritative state. The realtime stream may
                    // have been torn down while backgrounded, and events are hints anyway.
                    if phase == .active {
                        Task { await coordinator.refreshAfterPush() }
                    }
                }
        }
    }
}

/// Top-level route switch. The only place that decides which flow is on screen.
struct RootView: View {

    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        Group {
            switch coordinator.route {
            case .launching:
                LaunchView()
            case .signedOut:
                OnboardingFlowView()
            case .onboarding:
                ProfileSetupView(model: ProfileSetupModel(repository: HelloRepository()))
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.route)
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Tokens.Colour.surface.ignoresSafeArea()
            BrandLockup()
        }
    }
}

/// Sign-in flow: phone entry, then the code screen.
struct OnboardingFlowView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @State private var pendingVerification: PendingVerification?

    private let repository = HelloRepository()

    var body: some View {
        NavigationStack {
            PhoneEntryView(model: makePhoneModel())
                .navigationDestination(item: $pendingVerification) { pending in
                    OtpEntryView(
                        model: OtpEntryModel(
                            repository: repository,
                            phoneNumber: pending.phoneNumber,
                            countryCode: pending.countryCode,
                            codeLength: pending.codeLength,
                            resendAfterSeconds: pending.resendAfterSeconds,
                            onVerified: { result in
                                Task { await coordinator.didAuthenticate(result) }
                            }
                        )
                    )
                }
        }
    }

    private func makePhoneModel() -> PhoneEntryModel {
        let model = PhoneEntryModel(repository: repository)
        model.onCodeSent = { phone, country, result in
            pendingVerification = PendingVerification(
                phoneNumber: phone,
                countryCode: country,
                codeLength: result.codeLength,
                resendAfterSeconds: result.resendAfterSeconds
            )
        }
        return model
    }
}

struct PendingVerification: Identifiable, Hashable {
    let phoneNumber: String
    let countryCode: String
    let codeLength: Int
    let resendAfterSeconds: Int

    var id: String { phoneNumber }
}
