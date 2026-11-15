import SwiftUI

/// The Lychee Hello lockup — mark, wordmark and the "Hello" bubble — exactly as the brand artwork,
/// from a vector asset with a dark-mode version (light wordmark), so it stays sharp and legible.
///
/// Exposed as one accessibility element reading "Lychee Hello" — a screen reader should hear the
/// product name once, not three decorative fragments.
struct BrandLockup: View {

    var width: CGFloat = 240

    var body: some View {
        Image("BrandLockup")
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lychee Hello")
            .accessibilityAddTraits(.isHeader)
    }
}

/// Green outlined shield with an inner checkmark, used by the verification row.
struct ShieldCheckIcon: View {

    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "checkmark.shield")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Tokens.Colour.brand)
            .accessibilityHidden(true)
    }
}
