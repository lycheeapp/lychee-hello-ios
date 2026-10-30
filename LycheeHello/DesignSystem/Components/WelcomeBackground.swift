import SwiftUI

/// The boundary between the warm off-white upper area and the pale mint lower area.
///
/// ## Source
/// Traced from a supplied getwaves.io path (`viewBox 0 0 1440 320`), converted to unit space and
/// mapped into a vertical band on screen. Its character, left to right:
///
/// ```
///   low ●╲                     ╭───╮                    ← trough returns near mid-screen
///         ╲╭─────╮            ╱     ╲
///          ╰─────╯╲          ╱       ╰──●  high         ← rises through the last third
///                  ╰────────╯
/// ```
///
/// Unlike the previous hand-sampled version this has a genuine **double bend**: it lifts off the
/// left edge, settles, dips back down around mid-width, then climbs to the right. The dip is the
/// defining feature — flattening it would produce the plateau shape this replaced.
///
/// ## Geometry vs. placement
/// The path's *shape* is fixed; its *placement* is not. `bandTop` and `bandHeight` decide where it
/// sits and how much vertical travel it gets, which is what lets a banner-proportioned curve read
/// correctly on a tall screen. Adjust those two rather than editing the coordinates.
struct WaveShape: Shape {

    /// Where the top of the wave's bounding box sits, as a fraction of screen height.
    var bandTop: CGFloat = 0.510

    /// How much of the screen height the wave's vertical travel occupies.
    ///
    /// **This is the important knob.** The source path was authored for a 1440 × 320 banner — an
    /// aspect ratio of 4.5:1 — while the screen is roughly 0.46:1. Mapping the path's own
    /// proportions directly would compress it horizontally by about 10×, turning those lazy curves
    /// into steep switchbacks. Confining the vertical travel to a band restores the gradient the
    /// shape was drawn with.
    ///
    /// Larger = more dramatic; smaller = flatter. At `0.175` the boundary runs from ≈0.535h on the
    /// left to ≈0.380h on the right, which keeps it clear of the form starting at ≈0.56h.
    var bandHeight: CGFloat = 0.075

    // MARK: - Source geometry
    //
    // Traced from the supplied getwaves.io path, normalised to a unit box:
    //   x ÷ 1440 · y mapped from its 43…224 range onto 0…1 (0 = highest, 1 = lowest)
    //
    // Kept in unit space rather than as raw viewBox numbers so the shape is resolution-independent
    // and the band mapping below is the only place geometry meets the screen.
    //
    // The path is already C¹-continuous — at every anchor the incoming and outgoing control vectors
    // match almost exactly (at x=360: (120, 5.7) in, (120, 5.3) out) — so it needs no smoothing
    // pass. The Catmull–Rom spline that previously lived here has been removed rather than left
    // dormant.

    private static let start = CGPoint(x: 0.000000, y: 1.000000)
    private static let shoulder = CGPoint(x: 0.041667, y: 0.852486)

    private static let curves: [(c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
        (CGPoint(x: 0.083333, y: 0.707182),
         CGPoint(x: 0.166667, y: 0.408840),
         CGPoint(x: 0.250000, y: 0.440331)),

        (CGPoint(x: 0.333333, y: 0.469613),
         CGPoint(x: 0.416667, y: 0.823204),
         CGPoint(x: 0.500000, y: 0.793923)),

        (CGPoint(x: 0.583333, y: 0.762431),
         CGPoint(x: 0.666667, y: 0.353591),
         CGPoint(x: 0.750000, y: 0.175138)),

        (CGPoint(x: 0.833333, y: 0.000000),
         CGPoint(x: 0.916667, y: 0.055249),
         CGPoint(x: 0.958333, y: 0.086740))
    ]

    private static let end = CGPoint(x: 1.000000, y: 0.116022)

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height

        /// Unit space → screen. `y` is compressed into the band; `x` spans the full width.
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * w, y: (bandTop + p.y * bandHeight) * h)
        }

        var path = Path()
        path.move(to: map(WaveShape.start))
        path.addLine(to: map(WaveShape.shoulder))
        for segment in WaveShape.curves {
            path.addCurve(to: map(segment.end),
                          control1: map(segment.c1),
                          control2: map(segment.c2))
        }
        path.addLine(to: map(WaveShape.end))

        path.addLine(to: CGPoint(x: w+w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }
}

/// The abstract network motif inside the mint region.
///
/// The reference is **line-led, not blob-led** — large hairline-stroked ellipses, taller than they
/// are wide, several running off-canvas, with only a whisper of fill. An earlier pass used soft
/// filled circles, which produced fog rather than structure.
///
/// Ellipse radii are intentionally split: `rx` as a fraction of width, `ry` as a fraction of
/// height. Using one axis for both would render circles and lose the elongation that gives the
/// motif its character on a tall screen.
struct NetworkPattern: View {

    /// x, y, rx (of width), ry (of height), stroke opacity, fill opacity.
    private let ellipses: [(x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat, stroke: Double, fill: Double)] = [
        (0.229, 0.694, 0.158, 0.193, 0.75, 0.16),   // tall oval, left
        (0.662, 0.645, 0.158, 0.144, 0.70, 0.14),   // centre-right
        (0.205, 0.940, 0.217, 0.163, 0.60, 0.12),   // bottom-left, runs off-canvas
        (0.868, 0.946, 0.182, 0.130, 0.60, 0.12),   // bottom-right
        (1.020, 0.723, 0.141, 0.163, 0.65, 0.10),   // clipped by the right edge
        (0.470, 0.845, 0.230, 0.150, 0.40, 0.00)    // wide faint arc tying the lower half together
    ]

    /// x, y, radius (points), opacity, whether to draw a soft halo.
    private let nodes: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double, halo: Bool)] = [
        (0.821, 0.498, 9, 0.98, true),
        (0.191, 0.828, 7, 0.85, false),
        (0.070, 0.828, 5, 0.65, false),
        (0.906, 0.811, 26, 0.30, false),
        (0.932, 0.923, 6, 0.70, false),
        (0.577, 0.681, 4, 0.55, false),
        (0.686, 0.672, 4, 0.50, false)
    ]

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            for e in ellipses {
                let rect = CGRect(
                    x: w * e.x - w * e.rx,
                    y: h * e.y - h * e.ry,
                    width: w * e.rx * 2,
                    height: h * e.ry * 2
                )
                let path = Path(ellipseIn: rect)
                if e.fill > 0 {
                    context.fill(path, with: .color(Tokens.Colour.motif.opacity(e.fill)))
                }
                context.stroke(path, with: .color(Tokens.Colour.motif.opacity(e.stroke)), lineWidth: 1.6)
            }

            // Connectors: long, shallow curves threading between the ellipses. Several deliberately
            // start or end off-canvas so the motif reads as a fragment of something larger.
            var connectors = Path()
            connectors.move(to: CGPoint(x: w * 0.86, y: 0))
            connectors.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.72),
                                    control: CGPoint(x: w * 0.90, y: h * 0.42))
            connectors.move(to: CGPoint(x: -w * 0.05, y: h * 0.70))
            connectors.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.62),
                                    control: CGPoint(x: w * 0.24, y: h * 0.58))
            connectors.move(to: CGPoint(x: w * 0.02, y: h * 0.86))
            connectors.addQuadCurve(to: CGPoint(x: w * 0.72, y: h * 1.02),
                                    control: CGPoint(x: w * 0.34, y: h * 0.99))
            connectors.move(to: CGPoint(x: w * 0.30, y: h * 0.47))
            connectors.addQuadCurve(to: CGPoint(x: w * 0.05, y: h * 0.78),
                                    control: CGPoint(x: w * 0.10, y: h * 0.58))
            context.stroke(connectors, with: .color(Tokens.Colour.motif.opacity(0.65)), lineWidth: 1.4)

            for n in nodes {
                if n.halo {
                    let hr = n.r * 2.4
                    context.fill(
                        Path(ellipseIn: CGRect(x: w * n.x - hr, y: h * n.y - hr,
                                               width: hr * 2, height: hr * 2)),
                        with: .color(Tokens.Colour.motif.opacity(0.22))
                    )
                }
                context.fill(
                    Path(ellipseIn: CGRect(x: w * n.x - n.r, y: h * n.y - n.r,
                                           width: n.r * 2, height: n.r * 2)),
                    with: .color(Tokens.Colour.motif.opacity(n.o))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The cream upper region — the whole screen **minus** the wave area.
///
/// Expressed as a rectangle plus the wave sub-path, filled with the even-odd rule, so the wave
/// region is punched out. This avoids hand-reversing four cubic Béziers to trace the boundary
/// right-to-left, which is where an off-by-one control point would silently deform the curve.
struct CreamOverlayShape: Shape {

    var wave = WaveShape()

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addPath(wave.path(in: rect))
        return path
    }
}

/// Full welcome-screen backdrop.
///
/// ## Layer order is the important part
/// ```
///   mint fills the whole screen
///   network motif on top of the mint
///   cream region on top of everything, casting a soft shadow DOWNWARD
/// ```
///
/// The cream is a **raised layer**, not a background the mint is painted over. That is what
/// produces the soft, feathered green glow just under the boundary in the reference — a shadow
/// cast by the upper surface onto the mint below.
///
/// An earlier pass filled the mint *over* the cream, which can only ever yield a hard edge. No
/// amount of tuning the curve would have reproduced the feathering, because the feathering is not
/// part of the curve; it is depth.
///
/// The shadow is only visible along the wave: the shape's other three edges lie on or beyond the
/// screen bounds, so their shadows fall outside the visible area.
struct WelcomeBackground: View {

    var body: some View {
        ZStack {
            // Mint is the base plane, not an overlay.
            Tokens.Colour.surfaceMuted

            // Sits on the mint. No clipping needed — the cream layer above occludes whatever
            // strays into the upper half.
            NetworkPattern()

            CreamOverlayShape()
                .fill(Tokens.Colour.surface, style: FillStyle(eoFill: true))
                // Flattens the even-odd fill into one layer first, so the shadow is derived from
                // the composited result rather than from each sub-path separately.
                .compositingGroup()
                .shadow(color: Tokens.Colour.motifShadow, radius: 30, x: 0, y: 7)
        }
        .ignoresSafeArea()
    }
}
