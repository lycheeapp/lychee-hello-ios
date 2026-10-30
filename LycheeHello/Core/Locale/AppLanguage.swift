import Foundation
import SwiftUI
import UIKit

/// The language the app is shown in.
///
/// `.system` — the default — follows the phone: Arabic on a phone set to Arabic, English otherwise
/// (the two languages the app speaks), including the per-app language iOS offers in Settings.
/// The app's own Settings can pin either one regardless of the phone.
///
/// The root view applies it: the strings (through `L`), the layout direction (right-to-left for
/// Arabic) and the locale for dates. The server answers in the same language — `APIClient` sends
/// `effectiveTag` as `Accept-Language`, which is what the chat's replies are written in.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case arabic

    public static let storageKey = "appLanguage"

    public var id: String { rawValue }

    /// The language this pins, or nil to follow the phone.
    public var tag: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .arabic: return "ar"
        }
    }

    /// The stored choice; `.system` until the person picks one.
    public static var current: AppLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    public static func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        cachedBundle = nil
        applyToUIKit()
    }

    /// "ar" or "en": the language the screens are in — the chosen one, or the phone's.
    public static var effectiveTag: String { effectiveTag(for: current) }

    public static func effectiveTag(for language: AppLanguage) -> String {
        if let tag = language.tag { return tag }
        let phone = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return phone.hasPrefix("ar") ? "ar" : "en"
    }

    public static var isRightToLeft: Bool { effectiveTag == "ar" }

    public static var layoutDirection: LayoutDirection { isRightToLeft ? .rightToLeft : .leftToRight }

    /// For dates and day names. Western digits in both languages, as amounts and codes use.
    public static var locale: Locale {
        if effectiveTag == "ar" { return Locale(identifier: "ar@numbers=latn") }
        return current == .system ? Locale.current : Locale(identifier: "en")
    }

    private static var cachedBundle: (tag: String?, bundle: Bundle)?

    /// The strings bundle for the app's language: the chosen `.lproj`, or the main bundle, which
    /// already follows the phone.
    public static var bundle: Bundle {
        let tag = current.tag
        if let cached = cachedBundle, cached.tag == tag { return cached.bundle }
        let resolved: Bundle
        if let tag, let path = Bundle.main.path(forResource: tag, ofType: "lproj"), let lproj = Bundle(path: path) {
            resolved = lproj
        } else {
            resolved = .main
        }
        cachedBundle = (tag, resolved)
        return resolved
    }

    /// Navigation bars, tab bars, alerts and other UIKit pieces take their direction from here, not
    /// from SwiftUI's environment. Applied at launch and whenever the language changes.
    public static func applyToUIKit() {
        let attribute: UISemanticContentAttribute
        switch current.tag {
        case nil: attribute = .unspecified
        case "ar": attribute = .forceRightToLeft
        default: attribute = .forceLeftToRight
        }
        // Synchronously when already on the main thread (launch, Settings), so the first screen
        // drawn after it is already the right way round.
        if Thread.isMainThread {
            MainActor.assumeIsolated { UIView.appearance().semanticContentAttribute = attribute }
        } else {
            Task { @MainActor in UIView.appearance().semanticContentAttribute = attribute }
        }
    }
}

/// A string in the app's language, from `Localizable.strings`. With arguments, the string is a
/// format (`%@`, `%d`, or positional `%1$@`), filled with Western digits whatever the language.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = AppLanguage.bundle.localizedString(forKey: key, value: nil, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: nil, arguments: arguments)
}

public extension String {
    /// Wraps text the app did not write — a name, a masked number, a code — so it keeps its own
    /// reading order inside a sentence in the other direction. Without it "059***1234" inside
    /// Arabic text comes out as "1234***059": the stars take the sentence's direction.
    var bidiIsolated: String { "\u{2068}\(self)\u{2069}" }
}
