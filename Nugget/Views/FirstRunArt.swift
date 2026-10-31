import SwiftUI

// MARK: - First-run slide artwork
//
// One vector drawing per slide of the first-run guide. All of them are drawn
// from code rather than from asset-catalogue images, for the reason every other
// screen in this app is native: semantic colours and Dynamic Type are the
// things that make a screen work in both appearances and at every text size,
// and a rasterised "beautiful illustration" is locked to the day it was
// exported. Everything here resolves through `Color(.…system…)` and the accent
// tint, so dark mode, light mode and contrast settings are automatic.
//
// Every animated drawing rides one `TimelineView`, whose tick is handed
// forward **as a value** (`stamp: Date`) into a small concrete subview that
// draws the moving part, at most 12 fps, and only while the slide is on
// screen (the slides pass `active`). Two reasons, one load-bearing: a
// `TimelineView` content closure that computes and then hands values into a
// `Canvas` closure defeats the type checker — `swiftc -typecheck` reports
// "generic parameter 'Content' could not be inferred" at the `TimelineView`
// line, so the drawing is parameterised instead and every tick falls out of
// an ordinary view instantiation. And the other reason is cost: static layers
// (rails, nodes, the logo) sit outside the timeline, so a tick rebuilds a
// couple of marks rather than the whole scene — an onboarding screen idled on
// for minutes must not churn memory, which is what a 30fps full-scene
// rebuild once turned into.

/// The welcome slide's hero: the app's icon, orbited by the two things the
/// guide is about to connect — a Wi-Fi/tunnel glyph and a cable/pairing glyph.
/// Slow orbit; the point is "the app brings these together", readable at rest.
struct FirstRunWelcomeArt: View {
    let active: Bool

    var body: some View {
        // Static layers (rails, logo) sit outside the timeline; only the two
        // orbiting chips tick, 12 fps — the slow orbit needs no more, and an
        // onboarding screen must not fork memory over minutes of idling.
        ZStack {
            Circle()
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1.5)
                .frame(width: 280, height: 280)
            Circle()
                .strokeBorder(Color(.separator).opacity(0.2), lineWidth: 1)
                .frame(width: 208, height: 208)
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !active)) { timeline in
                ArtOrbitChips(stamp: timeline.date)
            }
            NativeLogo(size: 120)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }
}

/// The two moving chips of the welcome hero. The angle falls out of `stamp`,
/// so one tick is one rotation step; the chain is counter-rotated chip, orbit
/// offset, orbit rotation, which nets the chip upright. `phase` staggers the
/// two orbits so they do not pass through the same angle together.
private struct ArtOrbitChips: View {
    let stamp: Date

    var body: some View {
        let angle = Double(stamp.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 18) / 18) * 360
        ZStack {
            orbiting(icon: "cable.connector", radius: 140, angle: angle)
            orbiting(icon: "wifi", radius: 104, phase: 0.5, angle: angle)
        }
    }

    private func orbiting(icon: String, radius: CGFloat, phase: Double = 0, angle: Double) -> some View {
        ArtNode(icon: icon, size: 44)
            .rotationEffect(.degrees(-(angle + phase * 360)))
            .offset(x: radius)
            .rotationEffect(.degrees(angle + phase * 360))
    }
}

/// The tunnel slide's drawing: an app node and a device node with the tunnel
/// between them. Dots travel the capsule while the tunnel is being worked on;
/// once `ready`, the segment fills with the accent colour and the seal lands
/// on the device node — the same two facts the status chip states in words.
struct FirstRunTunnelArt: View {
    let ready: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 0) {
            ArtNode(icon: "shippingbox.fill", size: 76)
            ArtTunnelSegment(ready: ready, active: active)
                .padding(.horizontal, 18)
            ArtNode(icon: "iphone.gen3", size: 76, tone: ready ? .green : .accentColor,
                    sealed: ready)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(.vertical, 34)
    }
}

/// The tunnel thread proper: a capsule whose centre carries dots that flow
/// from the app toward the device. Unready it is dashed and slow (it is a
/// promise of what to connect); ready it is solid, accent-tinted and busy —
/// the picture must agree with the chip, the same way `Tunnel.requirements`
/// agrees with the home page's diagnostics.
private struct ArtTunnelSegment: View {
    let ready: Bool
    let active: Bool

    var body: some View {
        // GeometryReader exists only to make the segment greedy for the width
        // the HStack still has after its two nodes.
        GeometryReader { _ in
            ZStack {
                Capsule()
                    .fill(ready ? Color.accentColor.opacity(0.14) : Color.clear)
                    .frame(height: 34)
                Capsule()
                    .strokeBorder(ready ? Color.accentColor : Color(.separator),
                                  style: StrokeStyle(lineWidth: ready ? 3 : 1.5,
                                                     dash: ready ? [] : [6, 5]))
                    .frame(height: 34)
                TimelineView(.animation(minimumInterval: 1 / 12, paused: !active)) { timeline in
                    ArtFlowDots(stamp: timeline.date, ready: ready)
                }
            }
        }
        .frame(height: 34)
    }
}

/// The dots of the tunnel thread. Full crossing takes ~2.5 s when ready and
/// ~8 s otherwise: pace carries the "already working" / "not yet" reading
/// before the label is even read.
private struct ArtFlowDots: View {
    let stamp: Date
    let ready: Bool

    var body: some View {
        Canvas { context, bounds in
            let t = stamp.timeIntervalSinceReferenceDate
            let speed: Double = ready ? 2.5 : 8
            let y = bounds.height / 2
            let w = bounds.width
            for i in 0..<3 {
                let travel = ((t / speed) + Double(i) / 3)
                    .truncatingRemainder(dividingBy: 1)
                let x = (travel - 0.06) * w
                let fade = CGFloat(1 - abs(travel * 2 - 1))
                var dot = context
                dot.opacity = ready ? 0.85 * fade : 0.4 * fade
                dot.fill(
                    Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                    with: .color(ready ? .accentColor : .secondary))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The pairing slide's drawing: a computer (where a pairing file is usually
/// made) and this iPhone, joined by a travelling file. While the record is
/// missing the middle holds the `.mobiledevicepairing` document chip on a
/// dashed bridge; once `linked`, the dashes become a solid arc and the phone
/// gets the seal — the same verdict the pairing card reports.
struct FirstRunPairArt: View {
    let linked: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 0) {
            ArtNode(icon: "desktopcomputer", size: 76)
            ArtPairBridge(linked: linked, active: active)
                .padding(.horizontal, 14)
            ArtNode(icon: "iphone.gen3", size: 76, tone: linked ? .green : .accentColor,
                    sealed: linked)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(.vertical, 34)
    }
}

/// The middle of the pairing drawing: the dashed bridge, its travelling sweep,
/// and the file chip riding the midpoint — its tint agreeing with the state
/// the card on the slide names in words.
private struct ArtPairBridge: View {
    let linked: Bool
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let start = CGPoint(x: 0, y: size.height * 0.75)
            let end = CGPoint(x: size.width, y: size.height * 0.25)
            let curve = Path { path in
                path.move(to: start)
                path.addQuadCurve(to: end,
                                  control: CGPoint(x: size.width / 2,
                                                   y: size.height * 0.1))
            }
            ZStack {
                curve
                    .stroke(linked ? Color.accentColor : Color(.separator),
                            style: StrokeStyle(lineWidth: linked ? 3 : 1.5,
                                               dash: linked ? [] : [6, 5]))
                    .opacity(0.9)
                TimelineView(.animation(minimumInterval: 1 / 12, paused: !active)) { timeline in
                    ArtPairSweep(stamp: timeline.date, linked: linked, curve: curve)
                }
                Image(systemName: linked ? "checkmark.circle.fill" : "doc.badge.plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(linked ? Color.green : Color.accentColor)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: Circle())
                    .overlay(Circle().strokeBorder(Color(.separator).opacity(0.5)))
                    .position(x: size.width / 2, y: size.height * 0.5)
            }
        }
        .frame(height: 44)
    }
}

/// The travelling sweep of the pairing bridge: one moving green/accent head
/// drawn by trimming the same curve the dashes sit on.
private struct ArtPairSweep: View {
    let stamp: Date
    let linked: Bool
    let curve: Path

    var body: some View {
        // The sweep takes ~3 s per crossing when linked and ~7 s otherwise —
        // pace again as the state.
        let speed: Double = linked ? 3 : 7
        let travel = stamp.timeIntervalSinceReferenceDate / speed
            .truncatingRemainder(dividingBy: 1)
        return curve
            .trim(from: max(0, travel - 0.22), to: min(1, travel))
            .stroke(linked ? Color.green : Color.accentColor,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .opacity(linked ? 0.9 : 0.6)
    }
}

/// The finish slide's drawing: the app icon with a confirmation stamp, and —
/// only once both steps check out — a slow drift of confetti marks. The
/// celebration is the state, not the button: `ready` is the caller's
/// `canFinish`, so the drawing cannot promise a finish the footer refuses.
struct FirstRunFinishArt: View {
    let ready: Bool
    let active: Bool

    var body: some View {
        // Static layers (glow, logo, stamp) sit outside the timeline; only the
        // drifting confetti ticks, 12 fps, and only once both steps check out.
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color.accentColor.opacity(0.22), .clear],
                                   center: .center, startRadius: 10, endRadius: 150))
                .frame(width: 300, height: 300)
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !active || !ready)) { timeline in
                ArtConfettiLayer(stamp: timeline.date)
            }
            NativeLogo(size: 124)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .padding(12)
                .background(Color.green, in: Circle())
                .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                .offset(x: 58, y: 62)
                .shadow(color: .green.opacity(0.35), radius: 8, y: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }
}

/// The drifting confetti of the finish hero. The celebration is the state, not
/// the button: the timeline is paused until `canFinish`, so the drawing cannot
/// promise a finish the footer refuses.
private struct ArtConfettiLayer: View {
    let stamp: Date

    var body: some View {
        let t = stamp.timeIntervalSinceReferenceDate
        // Eight marks on four radii, each rising and rotating; the periods are
        // incommensurate on purpose — synced confetti reads as a loop.
        ForEach(0..<8, id: \.self) { i in
            let period = 1.6 + Double(i % 4) * 0.55
            let drift = (t / period)
                .truncatingRemainder(dividingBy: 1)
            ConfettiMark(index: i)
                .rotationEffect(.degrees(Double(i) * 18 + t * 8))
                .offset(y: -70 - drift * 60)
                .offset(x: [ -1.0, 1.0, 0.35, -0.35, 0.8, -0.8, 0.15, -0.15 ][i] * 112)
                .opacity(0.7 * (1 - drift))
        }
    }
}

/// One confetti mark: small rounded rectangles and dots, alternating by index.
private struct ConfettiMark: View {
    let index: Int

    var body: some View {
        Group {
            if index % 3 == 0 {
                Circle().frame(width: 9, height: 9)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .frame(width: 6, height: 14)
            }
        }
        .foregroundStyle(index % 2 == 0 ? Color.accentColor : Color.orange)
    }
}

// MARK: - Shared pieces

/// A node: the drawn stand-in for a real thing (the app, the phone on this
/// slide, the computer where a file is made). Surface, border and shadow are
/// all semantic colours, so the node sits correctly on any background.
private struct ArtNode: View {
    let icon: String
    var size: CGFloat = 72
    var tone: Color = .accentColor
    /// Draws the green seal over the corner when the step this node depicts
    /// has been satisfied — the drawn form of the guide's status tick.
    var sealed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(.secondarySystemBackground),
                                            Color(.tertiarySystemBackground)],
                                   startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tone)
                // Same frame as the surface: the ZStack is corner-aligned for the
                // seal, and without it the glyph would ride up into that corner.
                .frame(width: size, height: size)
            if sealed {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .foregroundStyle(.green)
                    // A background halo so the seal keeps its own silhouette
                    // where it crosses the node's border.
                    .background(Color(.systemBackground), in: Circle())
                    .offset(x: size * 0.04, y: -size * 0.04)
            }
        }
        .frame(width: size, height: size)
    }
}
