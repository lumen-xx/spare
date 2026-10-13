import SwiftUI

/// Small line drawings for empty pages, onboarding and problems. Each is a few strokes in a 120 × 90 box, drawn on in
/// the order a hand would draw them, with one or two of the icon's mint sparkles.
enum Doodle: String, CaseIterable {
    /// All clean, nothing found.
    case broom
    /// An empty list.
    case box
    /// Tidy: no leftovers, nothing left behind.
    case sprout
    /// Choose something to look at.
    case magnifier
    /// Nothing starts on its own.
    case moon
    /// History is empty.
    case clock
    /// Nothing downloaded from the cloud.
    case cloud
    /// Something went wrong.
    case knot
    /// Spare needs permission to look.
    case lock
    /// An empty folder.
    case folder

    struct Stroke {
        var points: [CGPoint]
        var closed = false
        var weight: CGFloat = 1
    }

    /// The strokes, in drawing order.
    var strokes: [Stroke] {
        switch self {
        case .broom:
            return [
                Stroke(points: [p(86, 8), p(77, 23), p(67, 37.5), p(57, 51)], weight: 1.25),
                Stroke(points: [p(48, 48), p(56, 53), p(64, 57)]),
                Stroke(points: [p(48, 48), p(40, 63), p(32, 77), p(46, 82), p(62, 82), p(72, 79), p(68, 67), p(64, 57)]),
                Stroke(points: [p(53, 57), p(48, 70), p(45, 80)]),
                Stroke(points: [p(59, 59), p(58, 70), p(58, 81)]),
                Stroke(points: [p(14, 83), p(19, 78), p(25, 80), p(23, 85), p(18, 84)])
            ]
        case .box:
            return [
                Stroke(points: [p(30, 46), p(60, 45), p(90, 46), p(88, 66), p(87, 84), p(60, 85), p(32, 84), p(31, 66)], closed: true),
                Stroke(points: [p(30, 46), p(14, 36), p(22, 28), p(38, 40)]),
                Stroke(points: [p(90, 46), p(106, 36), p(98, 28), p(82, 40)]),
                Stroke(points: [p(38, 40), p(60, 39.5), p(82, 40)]),
                Stroke(points: [p(57, 46), p(57.5, 52), p(57, 58)])
            ]
        case .sprout:
            return [
                Stroke(points: [p(28, 80), p(44, 79), p(60, 80.5), p(76, 79.5), p(92, 80)]),
                Stroke(points: [p(60, 80), p(59, 66), p(60, 52), p(62, 39)], weight: 1.15),
                Stroke(points: [p(60, 58), p(50, 49), p(37, 47), p(42, 56), p(52, 60)], closed: true),
                Stroke(points: [p(61, 46), p(70, 35), p(85, 31), p(80, 42), p(70, 47)], closed: true),
                Stroke(points: [p(57, 57), p(45, 52)]),
                Stroke(points: [p(64, 43), p(78, 36)])
            ]
        case .magnifier:
            return [
                Stroke(points: Doodle.arc(52, 40, 22, -100, 262, steps: 18), weight: 1.1),
                Stroke(points: [p(68, 56), p(78, 66.5), p(88, 77)], weight: 2.2),
                Stroke(points: [p(37, 36), p(40, 29), p(47, 25)])
            ]
        case .moon:
            return [
                Stroke(points: Doodle.arc(56, 46, 26, 70, 290, steps: 16) + Doodle.arc(80, 46, 28.7, 238, 122, steps: 12), closed: true),
                Stroke(points: [p(34, 34), p(37, 31)]),
                Stroke(points: [p(40, 60), p(44, 63)])
            ]
        case .clock:
            let arrow = Doodle.arc(60, 46, 37, 300, 150, steps: 16)
            let tip = arrow.last!
            return [
                Stroke(points: Doodle.arc(60, 46, 27, -80, 282, steps: 18)),
                Stroke(points: [p(60, 46), p(60.5, 38), p(60, 30)], weight: 1.2),
                Stroke(points: [p(60, 46), p(66, 49), p(71, 52)], weight: 1.2),
                Stroke(points: arrow),
                Stroke(points: [CGPoint(x: tip.x + 0.8, y: tip.y - 9), tip, CGPoint(x: tip.x - 8.2, y: tip.y - 3.8)])
            ]
        case .cloud:
            return [
                Stroke(points: [p(30, 64), p(24, 54), p(32, 43), p(45, 42), p(51, 30), p(66, 25), p(79, 33), p(83, 42), p(95, 44), p(99, 55), p(92, 64), p(60, 65)],
                       closed: true),
                Stroke(points: [p(61, 47), p(61.5, 60), p(61, 75)], weight: 1.1),
                Stroke(points: [p(53, 67), p(61, 76), p(69, 67)])
            ]
        case .knot:
            return [
                Stroke(points: [p(12, 62), p(28, 59), p(42, 53), p(53, 41), p(49, 30), p(39, 32), p(40, 45), p(53, 55), p(67, 56), p(77, 46),
                                p(72, 35), p(61, 38), p(64, 51), p(77, 61), p(93, 62), p(108, 55)], weight: 1.1),
                Stroke(points: [p(98, 70), p(103, 73)]),
                Stroke(points: [p(94, 76), p(96, 81)])
            ]
        case .lock:
            return [
                Stroke(points: [p(47, 44), p(46, 31), p(52, 21), p(62, 17), p(72, 21), p(77, 31), p(76, 44)], weight: 1.15),
                Stroke(points: [p(40, 44), p(62, 43.5), p(83, 43), p(85, 47), p(85.5, 62), p(85, 76), p(82, 79.5), p(61, 80), p(41, 80), p(38, 77),
                                p(37.5, 62), p(37, 47)], closed: true),
                Stroke(points: Doodle.arc(61, 58, 4, -90, 270, steps: 8)),
                Stroke(points: [p(61, 62), p(61.5, 66), p(61, 70)])
            ]
        case .folder:
            return [
                Stroke(points: [p(26, 36), p(46, 34), p(53, 41), p(74, 40), p(94, 41), p(95, 60), p(94, 79), p(60, 80), p(27, 79), p(26, 58)], closed: true),
                Stroke(points: [p(24, 51), p(60, 50), p(97, 51)]),
                Stroke(points: [p(40, 64), p(48, 63.5)])
            ]
        }
    }

    /// Where the mint sparkles go, and how big they are.
    var sparkles: [(CGPoint, CGFloat)] {
        switch self {
        case .broom: [(p(96, 38), 10), (p(104, 54), 5)]
        case .box: [(p(60, 22), 9)]
        case .sprout: [(p(90, 22), 9)]
        case .magnifier: [(p(98, 22), 9)]
        case .moon: [(p(94, 24), 9), (p(100, 48), 5)]
        case .clock: [(p(100, 22), 7)]
        case .cloud: [(p(104, 28), 7)]
        case .knot: []
        case .lock: [(p(98, 28), 8)]
        case .folder: [(p(102, 26), 8)]
        }
    }

    static let size = CGSize(width: 120, height: 90)

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// Points along a circle, in degrees with 0° to the right and 90° down, from `start` to `end` either way round.
    static func arc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ start: CGFloat, _ end: CGFloat, steps: Int) -> [CGPoint] {
        (0...steps).map { i in
            let angle = (start + (end - start) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            return CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
        }
    }
}

/// One pencil stroke of a doodle, scaled from the 120 × 90 drawing box to the frame, with its own gentle unevenness.
private struct DoodleStroke: Shape {
    var stroke: Doodle.Stroke
    var seed: UInt64
    var wobble: CGFloat

    func path(in rect: CGRect) -> Path {
        let noise = Wobble(seed, scale: 0.25)
        let (sx, sy) = (rect.width / Doodle.size.width, rect.height / Doodle.size.height)
        let points = stroke.points.enumerated().map { index, point in
            CGPoint(x: rect.minX + (point.x + wobble * noise.pick(index)) * sx, y: rect.minY + (point.y + wobble * noise.pick(index + 40)) * sy)
        }
        return Path.smooth(through: points, closed: stroke.closed)
    }
}

/// Draws a doodle, stroke by stroke, the first time it appears. With Reduce Motion it fades in, already drawn.
struct DoodleView: View {
    let doodle: Doodle
    var width: CGFloat = 120
    @State private var drawn = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        let seed = Jitter.seed(doodle.rawValue)
        let strokes = doodle.strokes
        ZStack {
            ForEach(strokes.indices, id: \.self) { index in
                let stroke = strokes[index]
                let delay = 0.1 + Double(index) * 0.11 * (1 + 0.1 * Jitter.unit(index))
                DoodleStroke(stroke: stroke, seed: seed &+ UInt64(index), wobble: 0.5)
                    .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                    .stroke(Ink.pencil, style: StrokeStyle(lineWidth: 1.5 * stroke.weight * width / 120, lineCap: .round, lineJoin: .round))
                    .animation(reduceMotion ? nil : Motion.draw.delay(delay), value: drawn)
            }
            ForEach(doodle.sparkles.indices, id: \.self) { index in
                let (center, size) = doodle.sparkles[index]
                let scale = width / 120
                Sparkle()
                    .fill(Ink.sparkle)
                    .frame(width: size * scale, height: size * 1.15 * scale)
                    .scaleEffect(drawn || reduceMotion ? 1 : 0.2)
                    .opacity(drawn ? 1 : 0)
                    .position(x: center.x * scale, y: center.y * scale)
                    .animation(reduceMotion ? Motion.calm : Motion.bounce.delay(0.25 + Double(strokes.count) * 0.1 + Double(index) * 0.07), value: drawn)
            }
        }
        .frame(width: width, height: width * Doodle.size.height / Doodle.size.width)
        .opacity(reduceMotion && !drawn ? 0 : 1)
        .animation(reduceMotion ? Motion.calm : nil, value: drawn)
        .onAppear { DispatchQueue.main.async { drawn = true } }
        .accessibilityHidden(true)
    }
}
