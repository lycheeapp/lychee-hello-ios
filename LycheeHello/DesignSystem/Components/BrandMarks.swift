import SwiftUI

/// The Lychee mark: **four** solid green circles, no outlines — the brand artwork's geometry.
///
/// Drawn in code, so it is crisp at every size and can take any colour (white on a card). The
/// circles are the supplied logo's, measured from it: centre and radius as fractions of the mark's
/// height, the mark centred in a `size` × `size` box. Android's `LycheeMark` and both app icons use
/// the same numbers — change one, change all.
struct LycheeMark: View {

    var size: CGFloat = 56
    /// The brand green; white on a coloured card.
    var color: Color = Tokens.Colour.brand

    /// (x, y, radius) in a unit box: top, middle-left, bottom-right (largest), bottom-left.
    static let circles: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (0.5747, 0.1781, 0.1781),
        (0.3790, 0.5369, 0.1373),
        (0.7121, 0.8078, 0.1922),
        (0.2339, 0.8598, 0.1382)
    ]

    var body: some View {
        Canvas { context, canvas in
            let side = min(canvas.width, canvas.height)
            let origin = CGPoint(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2)
            for circle in Self.circles {
                let r = circle.r * side
                let rect = CGRect(x: origin.x + circle.x * side - r, y: origin.y + circle.y * side - r,
                                  width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The "Lychee" wordmark from the brand artwork (a vector asset), in one colour: navy on light, or
/// whatever `color` says — white on a card.
struct LycheeWordmark: View {

    /// Height of the whole word, the "y" descender included.
    var height: CGFloat = 40
    var color: Color = Tokens.Colour.navy

    var body: some View {
        Image("LycheeWordmark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

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
