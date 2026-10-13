import SwiftUI

/// How Spare moves: springs with a little weight, never linear or stock ease-in-out. Similar things move a few percent
/// apart so a list never moves in lockstep, and with Reduce Motion everything becomes a short crossfade.
enum Motion {
    /// A check box or switch settling into place.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.80)
    /// Rows and cards arriving: a few points of overshoot, then still.
    static let arrive = Animation.spring(response: 0.55, dampingFraction: 0.72)
    /// Messages and trays sliding in from the bottom edge.
    static let panel = Animation.spring(response: 0.50, dampingFraction: 0.66)
    /// A button going down under the pointer: quick, so the press is felt at once.
    static let press = Animation.spring(response: 0.20, dampingFraction: 0.55)
    /// The button coming back up, overshooting a touch.
    static let release = Animation.spring(response: 0.32, dampingFraction: 0.60)
    /// A finished task's tick landing.
    static let bounce = Animation.spring(response: 0.34, dampingFraction: 0.45)
    /// Opening and closing a group of rows. Layout moves, so it barely overshoots.
    static let expand = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// A pen drawing a line: it slows into the end and never overshoots.
    static let draw = Animation.spring(response: 0.62, dampingFraction: 1)
    /// Numbers counting to a new value.
    static let count = Animation.spring(response: 0.45, dampingFraction: 0.9)
    /// Noticing the pointer: a moment's lag, then a soft fade. Leaving is quicker.
    static let hoverIn = Animation.spring(response: 0.28, dampingFraction: 1).delay(0.06)
    static let hoverOut = Animation.spring(response: 0.18, dampingFraction: 1)
    /// Everything, when Reduce Motion is on.
    static let calm = Animation.easeInOut(duration: 0.2)

    /// The same motion up to 8 % faster or slower, picked by `seed`, so neighbours never move as clones.
    static func varied(_ animation: Animation, _ seed: Int) -> Animation {
        animation.speed(1 + Jitter.unit(seed) * 0.08)
    }

    /// `animation`, or a crossfade with Reduce Motion.
    static func gentle(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? calm : animation
    }
}

/// Deliberate pauses before an acknowledgement, 40–120 ms. They only hold back the drawing of an answer, never the
/// answer: the state changes at once, so typing, scrolling, dragging, shortcuts and VoiceOver never wait.
enum Beat {
    /// A check box considering before its tick appears.
    static let tick = 0.05
    /// A switch's knob deciding before it slides.
    static let toggle = 0.06
    /// A count or row settling after a change.
    static let settle = 0.08
    /// The satisfied breath before a success mark is drawn.
    static let breath = 0.12
}

/// Things arriving one after another: 35 ms apart, each nudged by up to ±9 ms so the rhythm isn't mechanical, and
/// capped at the tenth so a long list never makes anyone wait.
enum Stagger {
    static let step = 0.035
    static let cap = 10

    static func delay(_ index: Int) -> Double {
        let place = min(max(index, 0), cap)
        return max(0, Double(place) * step + Jitter.unit(place &* 7 &+ 3) * step * 0.25)
    }
}

/// Repeatable randomness: the same seed always gives the same answer, so nothing changes between frames or launches.
enum Jitter {
    /// A value between -1 and 1.
    static func unit(_ seed: Int) -> Double {
        Double(mix(UInt64(bitPattern: Int64(seed))) >> 11) / Double(1 << 53) * 2 - 1
    }

    /// A stable seed for a name, such as a rule's identifier (FNV-1a).
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    /// SplitMix64's finaliser: spreads nearby seeds far apart.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

// MARK: - Reduce Motion

private struct ReduceMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Reduce Motion as Spare's views read it: the system setting, passed down from the window's root, so a
    /// development build can turn it on for checking (`-reduceMotion YES`) without changing the Mac's settings.
    var reduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

// MARK: - Arriving

private struct ArrivedKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False for the first frame of a page, so its parts can arrive in order. Outside a stage it's always true.
    var arrived: Bool {
        get { self[ArrivedKey.self] }
        set { self[ArrivedKey.self] = newValue }
    }
}

/// Holds a page's parts back for one frame, then lets them arrive in order. When `replay` turns false, as when a
/// list that was empty fills, they arrive again; what was already on screen never blinks.
private struct ArrivalStage: ViewModifier {
    var replay: Bool
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .environment(\.arrived, arrived)
            .onAppear { DispatchQueue.main.async { arrived = true } }
            .onChange(of: replay) { _, waiting in
                guard !waiting else { return }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { arrived = false }
                DispatchQueue.main.async { arrived = true }
            }
    }
}

/// One part of a page arriving: it rises a few points and fades in, `index` places later than the first. Nothing
/// grows as it arrives, so a page-tall table never looks stretched.
private struct Arrive: ViewModifier {
    let index: Int
    let rise: CGFloat
    @Environment(\.arrived) private var arrived
    @Environment(\.reduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : rise)
            .animation(arrived ? (reduceMotion ? Motion.calm : Motion.varied(Motion.arrive, index).delay(Stagger.delay(index))) : nil,
                       value: arrived)
    }
}

extension View {
    /// Makes this the stage its parts arrive on; see `arrives(_:)`.
    func arrivalStage(replay: Bool = false) -> some View { modifier(ArrivalStage(replay: replay)) }

    /// Arrives with the page, `index` places after its first part.
    func arrives(_ index: Int, rise: CGFloat = 8) -> some View { modifier(Arrive(index: index, rise: rise)) }
}

// MARK: - Noticing the pointer

/// A soft wash behind a row that fades in a moment after the pointer arrives, as if the row noticed it.
private struct HoverWash: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle.continuous(radius)
                    .fill(Ink.wash)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { inside in withAnimation(inside ? Motion.hoverIn : Motion.hoverOut) { hovering = inside } }
    }
}

/// Whether the pointer is over something, reported with the same soft lag as the wash.
private struct HoverLag: ViewModifier {
    @Binding var hovering: Bool
    func body(content: Content) -> some View {
        content.onHover { inside in withAnimation(inside ? Motion.hoverIn : Motion.hoverOut) { hovering = inside } }
    }
}

extension View {
    func hoverWash(radius: CGFloat = RowWash.radius) -> some View { modifier(HoverWash(radius: radius)) }
    func hoverLag(_ hovering: Binding<Bool>) -> some View { modifier(HoverLag(hovering: hovering)) }
}
