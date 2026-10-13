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

/// The page every screen sits on: frosted paper with the desktop showing through, blurred, and a little grain. With
/// Reduce Transparency or Increase Contrast it's solid. The grain also goes with Increase Contrast, and when the person
/// switches it off in Settings.
struct PaperBackground: View {
    @AppStorage(Feel.paperKey) private var texture = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Ink.paper
            } else {
                // Enough paper over the blur to keep its warmth, little enough to see the desktop through it.
                BehindWindow().overlay(Ink.paper.opacity(scheme == .dark ? 0.35 : 0.3))
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
}

/// What's behind the window, blurred by macOS as its sidebars are, and kept blurred while the window is in the
/// background too.
private struct BehindWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
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
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content.background {
            ZStack {
                shape.fill(Ink.shade)
                    .padding(.top, 5 * lift)
                    .padding(.leading, 3 * lift)
                    .padding(.trailing, -1.2 * lift)
                    .padding(.bottom, -2.6 * lift)
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
    func deskShadow<S: Shape>(_ shape: S, lift: CGFloat = 1) -> some View {
        modifier(DeskShadow(shape: shape, lift: lift))
    }
}

/// Rows that light up under the pointer sit this far inside their card on every side, and their wash is rounded so
/// its corners follow the card's 14 pt ones.
enum RowWash {
    static let inset: CGFloat = 4
    static let radius: CGFloat = 14 - inset
}

/// A card on the paper: off-white, a hairline edge, evenly rounded corners and a light desk shadow. `hoverRows`
/// keeps rows with a hover wash `RowWash.inset` from its top and bottom; the rows keep it from the sides.
struct Card<Content: View>: View {
    var radius: CGFloat = 14
    var lift: CGFloat = 1
    var fill: Color = Ink.card
    var hoverRows = false
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle.continuous(radius)
        // Each row also keeps 1 pt above and below its wash, so neighbouring washes never touch.
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, hoverRows ? RowWash.inset - 1 : 0)
            .background(shape.fill(fill))
            .overlay {
                shape.strokeBorder(Ink.line, lineWidth: contrast == .increased ? 1.25 : 0.75)
                    .allowsHitTesting(false)
            }
            .deskShadow(shape, lift: lift)
    }
}

/// A hairline between rows.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Ink.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
