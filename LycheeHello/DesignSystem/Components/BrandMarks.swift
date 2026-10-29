import SwiftUI

/// The Lychee icon: **three** solid green circles, no outlines.
///
/// Arrangement per the brand spec — one large upper-right, one medium lower-right, one smaller
/// toward the lower-left. Drawn in code rather than shipped as an asset so the app runs before the
/// real artwork arrives; swap this view for an `Image` when the SVG lands and nothing else changes.
struct LycheeMark: View {

    var size: CGFloat = 56

    var body: some View {
        // Proportions expressed as fractions of `size` so the mark scales cleanly.
        ZStack {
            Circle()
                .fill(Tokens.Colour.brand)
                .frame(width: size * 0.44, height: size * 0.44)
                .offset(x: size * 0.16, y: -size * 0.24)

            Circle()
                .fill(Tokens.Colour.brand)
                .frame(width: size * 0.40, height: size * 0.40)
                .offset(x: size * 0.20, y: size * 0.26)

            Circle()
                .fill(Tokens.Colour.brand)
                .frame(width: size * 0.28, height: size * 0.28)
                .offset(x: -size * 0.24, y: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Lychee" wordmark, deep navy, bold geometric sans.
struct LycheeWordmark: View {

    var size: CGFloat = 46

    var body: some View {
        Text("Lychee")
            .font(.system(size: size, weight: .bold, design: .default))
            .foregroundStyle(Tokens.Colour.navy)
            .kerning(-0.5)
            .accessibilityHidden(true)
    }
}

/// Speech-bubble outline with a pointed tail at the lower-left.
///
/// A custom `Shape` rather than a rounded rectangle plus a triangle: one continuous path means the
/// stroke joins cleanly at the tail instead of showing a seam where two shapes meet.
struct SpeechBubbleShape: Shape {

    var cornerRadius: CGFloat = 22
    var tailWidth: CGFloat = 16
    var tailHeight: CGFloat = 14
    /// Distance from the left edge to the tail's start.
    var tailInset: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)
        let r = min(cornerRadius, body.height / 2)

        // Top edge, left → right.
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)

        // Right edge.
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)

        // Bottom edge, right → tail.
        path.addLine(to: CGPoint(x: body.minX + tailInset + tailWidth, y: body.maxY))
        // Tail: down to the point, then back up.
        path.addLine(to: CGPoint(x: body.minX + tailInset, y: body.maxY + tailHeight))
        path.addLine(to: CGPoint(x: body.minX + tailInset, y: body.maxY))

        // Bottom edge, tail → left.
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)

        // Left edge.
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        path.closeSubpath()
        return path
    }
}

/// The green outlined "Hello" bubble that sits below and right of the wordmark.
struct HelloBubble: View {

    var fontSize: CGFloat = 24

    var body: some View {
        Text("Hello")
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(Tokens.Colour.brand)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            // Extra bottom padding reserves room for the tail, which the shape draws below the
            // body rect — without it the tail would clip the text's descenders.
            .padding(.bottom, 18)
            .background(
                SpeechBubbleShape()
                    .stroke(Tokens.Colour.brand, lineWidth: 2.5)
            )
            // Interior is intentionally transparent so the page background shows through.
            .accessibilityHidden(true)
    }
}

/// Combined lockup: mark + wordmark centred, with the Hello bubble tucked below-right.
///
/// Exposed as one accessibility element reading "Lychee Hello" — a screen reader should hear the
/// product name once, not three decorative fragments.
struct BrandLockup: View {

    var body: some View {
        VStack(alignment: .trailing, spacing: -2) {
            HStack(spacing: 14) {
                LycheeMark()
                LycheeWordmark()
            }
            HelloBubble()
                .padding(.trailing, 4)
        }
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
