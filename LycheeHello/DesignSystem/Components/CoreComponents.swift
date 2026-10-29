import SwiftUI

/// Full-width primary call to action.
///
/// Label is optically centred while the arrow sits against the right edge with generous padding,
/// matching the reference. A plain `HStack` would centre the pair together and push the label left
/// of centre, so the two are layered instead.
///
/// See `Tokens.Colour.brandAccessible` for the measured contrast note on white-on-green.
struct LHPrimaryButton: View {
    let title: String
    var trailingSystemImage: String?
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(Tokens.Colour.textOnBrand)
                } else {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Tokens.Colour.textOnBrand)

                    if let trailingSystemImage {
                        HStack {
                            Spacer()
                            Image(systemName: trailingSystemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Tokens.Colour.textOnBrand)
                        }
                        .padding(.trailing, Tokens.Spacing.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // Reference button height ≈ 128/1844 → ~60pt, slightly shorter than the field above it.
            .frame(height: 60)
            .background(isEnabled ? Tokens.Colour.brand : Tokens.Colour.brand.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Tokens.Colour.brand.opacity(isEnabled ? 0.26 : 0), radius: 16, x: 0, y: 8)
        }
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        // A spinner alone tells VoiceOver nothing.
        .accessibilityValue(isLoading ? "Working" : "")
    }
}
