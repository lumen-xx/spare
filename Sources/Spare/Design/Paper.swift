import AppKit
import SwiftUI

/// Paper grain: one tile of fine speckles, made once at launch and repeated across the page. Light and dark specks
/// balance out, so the paper keeps its colour; at 2.5–3 % it's felt more than seen.
enum Grain {
    static let tile: CGImage? = make(pixels: 256, seed: 0x5ba2e)

    private static func make(pixels size: Int, seed: UInt64) -> CGImage? {
        var state = seed
        func random() -> Double {
            state = Jitter.mix(state)
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        // Fine noise, plus a softer layer of clumps averaged from its neighbours, wrapping at the edges so tiles meet.
        let fine = (0..<(size * size)).map { _ in random() * 2 - 1 }
        var clumps = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                var sum = 0.0
                for dy in -2...2 { for dx in -2...2 { sum += fine[((y + dy + size) % size) * size + (x + dx + size) % size] } }
                clumps[y * size + x] = sum / 25 * 2.2
            }
        }
        let value = (0..<(size * size)).map { fine[$0] * 0.6 + clumps[$0] * 0.4 }
        // Dark specks are black with some opacity, light ones white; premultiplied.
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let v = max(-1, min(1, value[i]))
            let alpha = UInt8(abs(v) * 255)
            let white = v > 0 ? alpha : 0
            bytes[i * 4] = white; bytes[i * 4 + 1] = white; bytes[i * 4 + 2] = white; bytes[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The page every screen sits on: frosted paper with the desktop showing through, blurred, and a little grain. In a
/// window that's in the background it settles into solid paper, as macOS's own sidebars turn solid; with Reduce
/// Transparency or Increase Contrast it's always solid. The grain also goes with Increase Contrast, and when the person
/// switches it off in Settings.
struct PaperBackground: View {
    @AppStorage(Feel.paperKey) private var texture = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var windowState

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Ink.paper
            } else {
                // Enough paper over the blur to keep its warmth and the text's contrast, little enough to see through.
                BehindWindow().overlay(Ink.paper.opacity(inFront ? (scheme == .dark ? 0.55 : 0.45) : 1))
                    .animation(.easeOut(duration: 0.2), value: inFront)
            }
        }
        .overlay {
            if texture, contrast == .standard, let tile = Grain.tile {
                Image(decorative: tile, scale: 2)
                    .resizable(resizingMode: .tile)
                    .opacity(scheme == .dark ? 0.03 : 0.025)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    private var inFront: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "paperActive") { return true }
        #endif
        return windowState != .inactive
    }
}

/// What's behind the window, blurred by macOS as its sidebars are.
private struct BehindWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        #if DEBUG
        // Screenshots are taken of a window in the background, which would show it solid.
        if UserDefaults.standard.bool(forKey: "paperActive") { view.state = .active }
        #endif
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A shadow cast by light from the upper left onto a desk: almost none along the top and left, most of it falling
/// down and to the right, plus a faint line where the card touches the paper. Never a centred halo, and never heavy.
private struct DeskShadow<S: Shape>: ViewModifier {
    var shape: S
    /// 1 is a card lying on the desk; 2 is a message held above it.
    var lift: CGFloat
    var seed: UInt64
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let vary = { (index: Int) in 1 + 0.15 * Wobble(seed).pick(index) }
        content.background {
            ZStack {
                shape.fill(Ink.shade)
                    .padding(.top, 5 * lift * vary(0))
                    .padding(.leading, 3 * lift * vary(1))
                    .padding(.trailing, -1.2 * lift * vary(2))
                    .padding(.bottom, -2.6 * lift * vary(3))
                    .offset(x: 0.8 * lift, y: 1.6 * lift)
                    .blur(radius: 5 * lift)
                    .opacity(dark ? 0.26 + 0.03 * lift : 0.04 + 0.015 * lift)
                shape.fill(Ink.shade)
                    .offset(x: 0.2, y: 0.6)
                    .blur(radius: 0.6)
                    .opacity(dark ? 0.3 : 0.045)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func deskShadow<S: Shape>(_ shape: S, lift: CGFloat = 1, seed: UInt64 = 1) -> some View {
        modifier(DeskShadow(shape: shape, lift: lift, seed: seed))
    }
}

/// A card on the paper: off-white, a hairline edge, corners that differ by a hair, and a light desk shadow.
/// Without a seed each place in the code gets its own, so two cards on a page never share the same shape.
struct Card<Content: View>: View {
    var seed: UInt64
    var radius: CGFloat
    var lift: CGFloat
    var fill: Color
    var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(seed: UInt64? = nil, radius: CGFloat = 14, lift: CGFloat = 1, fill: Color = Ink.card,
         file: String = #fileID, line: Int = #line, @ViewBuilder content: () -> Content) {
        self.seed = seed ?? Jitter.seed("\(file):\(line)")
        self.radius = radius
        self.lift = lift
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        let shape = SketchRect(radius: radius, seed: seed, wobble: 0.35, corners: 0.1)
        VStack(alignment: .leading, spacing: 0) { content }
            .background(shape.fill(fill))
            .overlay {
                SketchBorder(shape: shape, width: contrast == .increased ? 1.25 : 0.75, swell: 0.3)
                    .fill(Ink.line)
                    .allowsHitTesting(false)
            }
            .deskShadow(shape, lift: lift, seed: seed)
    }
}

/// A hairline between rows, drawn by hand: it eases in and out at the ends.
struct SketchDivider: View {
    var seed: UInt64 = 1
    var body: some View {
        SketchLine(seed: seed, width: 0.8, wobble: 0.3)
            .fill(Ink.line)
            .frame(height: 2)
            .padding(.vertical, -0.5)
            .accessibilityHidden(true)
    }
}
