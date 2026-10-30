import SwiftUI
import UIKit

/// Light or dark.
///
/// `.system` — the default — follows the phone's appearance and changes with it. Settings can pin
/// either one regardless of the phone. Every colour token has a light and a dark value (see
/// `Tokens.Colour`), so this only has to tell the windows which one to draw.
///
/// Applied to the windows themselves (`overrideUserInterfaceStyle`) rather than with
/// `.preferredColorScheme`: that covers sheets, alerts and the keyboard too, and going back to
/// "System default" takes effect at once — `.preferredColorScheme(nil)` keeps the last pinned value
/// until the app restarts.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Paints every window of the app in `self`.
    func apply() {
        let style = interfaceStyle
        if Thread.isMainThread {
            MainActor.assumeIsolated { Self.paint(style) }
        } else {
            Task { @MainActor in Self.paint(style) }
        }
    }

    @MainActor
    private static func paint(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    /// "System default", "Light", "Dark".
    var title: String {
        switch self {
        case .system: return L("settings_appearance_system")
        case .light: return L("settings_appearance_light")
        case .dark: return L("settings_appearance_dark")
        }
    }
}

/// Keeps the windows in the stored appearance: when the app starts, and whenever Settings changes it.
struct AppAppearanceApplier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear { (AppAppearance(rawValue: appearanceRaw) ?? .system).apply() }
            .onChange(of: appearanceRaw) { _, raw in (AppAppearance(rawValue: raw) ?? .system).apply() }
    }
}
