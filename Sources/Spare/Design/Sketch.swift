import SwiftUI

/// Smooth, seeded unevenness for hand-drawn lines. The same seed always draws the same line, so nothing shimmers between
/// frames, and the bumps follow distance along the line, so a card that grows keeps the bumps it had.
struct Wobble {
    private struct Wave { var length: CGFloat; var phase: CGFloat; var weight: CGFloat }
    private let lanes: [[Wave]]
    let seed: UInt64

    /// `scale` shortens the bumps for small shapes: a check box needs tighter wobble than a card.
    init(_ seed: UInt64, scale: CGFloat = 1) {
        self.seed = seed
        lanes = (0..<2).map { lane in
            [(90, 0.55), (32, 0.30), (12, 0.15)].enumerated().map { octave, wave in
                let key = seed &+ UInt64(lane * 16 + octave + 1) &* 0x9e37_79b9_7f4a_7c15
                return Wave(length: CGFloat(wave.0) * scale * (0.8 + 0.4 * Wobble.fraction(key)),
                            phase: Wobble.fraction(key &+ 1) * 2 * .pi, weight: CGFloat(wave.1))
            }
        }
    }

    /// Between -1 and 1, `distance` points along a line. Lane 0 moves the line; lane 1 changes how thick it is.
    func at(_ distance: CGFloat, lane: Int = 0) -> CGFloat {
        lanes[lane % lanes.count].reduce(0) { $0 + $1.weight * sin(distance / $1.length * 2 * .pi + $1.phase) }
    }

    /// A fixed value between -1 and 1 for one choice, such as how round one corner is.
    func pick(_ index: Int) -> CGFloat { Wobble.fraction(seed &+ UInt64(index + 1) &* 0xd1b5_4a32_d192_ed03) * 2 - 1 }

    private static func fraction(_ key: UInt64) -> CGFloat { CGFloat(Jitter.mix(key) >> 11) / CGFloat(UInt64(1) << 53) }
}

/// A rounded rectangle drawn by hand: each corner a little more or less round than the others and the edges gently
/// uneven. Fill it, clip to it, or draw its edge with `SketchBorder`.
struct SketchRect: Shape {
    var radius: CGFloat = 12
    var seed: UInt64 = 1
    /// How far the edge strays, in points.
    var wobble: CGFloat = 0.6
    /// How much corners differ from `radius`, as a fraction of it.
    var corners: CGFloat = 0.15
    /// Mixes the width into the seed, so buttons of different lengths get different wobbles from the same style.
    var bySize = false

    struct Sample { var point: CGPoint; var normal: CGVector; var distance: CGFloat }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = samples(in: rect).map(\.point)
        guard points.count > 2 else { return Path(rect) }
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// Points around the edge, clockwise from the top left, each with the outward direction there.
    func samples(in rect: CGRect) -> [Sample] {
        guard rect.width > 1, rect.height > 1 else { return [] }
        let perimeter = 2 * (rect.width + rect.height)
        let noise = Wobble(bySize ? seed &+ UInt64(max(0, rect.width.rounded())) &* 0x9e37_79b9 : seed, scale: min(1, max(0.22, perimeter / 420)))
        let limit = min(rect.width, rect.height) / 2
        let r = (0..<4).map { min(limit, max(0, radius * (1 + corners * noise.pick($0)))) }
        let step = min(4, max(1.2, perimeter / 140))
        var base: [(CGPoint, CGVector)] = []

        func edge(_ a: CGPoint, _ b: CGPoint, _ normal: CGVector) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let count = max(1, Int(length / step))
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count)
                base.append((CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), normal))
            }
        }
        func corner(_ center: CGPoint, _ radius: CGFloat, from start: CGFloat) {
            guard radius > 0.5 else { return }
            let count = max(3, Int(radius * .pi / 2 / (step * 0.7)))
            for i in 0..<count {
                let angle = (start + 90 * CGFloat(i) / CGFloat(count)) * .pi / 180
                let normal = CGVector(dx: cos(angle), dy: sin(angle))
                base.append((CGPoint(x: center.x + normal.dx * radius, y: center.y + normal.dy * radius), normal))
            }
        }
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        edge(CGPoint(x: minX + r[0], y: minY), CGPoint(x: maxX - r[1], y: minY), CGVector(dx: 0, dy: -1))
        corner(CGPoint(x: maxX - r[1], y: minY + r[1]), r[1], from: -90)
        edge(CGPoint(x: maxX, y: minY + r[1]), CGPoint(x: maxX, y: maxY - r[2]), CGVector(dx: 1, dy: 0))
        corner(CGPoint(x: maxX - r[2], y: maxY - r[2]), r[2], from: 0)
        edge(CGPoint(x: maxX - r[2], y: maxY), CGPoint(x: minX + r[3], y: maxY), CGVector(dx: 0, dy: 1))
        corner(CGPoint(x: minX + r[3], y: maxY - r[3]), r[3], from: 90)
        edge(CGPoint(x: minX, y: maxY - r[3]), CGPoint(x: minX, y: minY + r[0]), CGVector(dx: -1, dy: 0))
        corner(CGPoint(x: minX + r[0], y: minY + r[0]), r[0], from: 180)

        // Distances along the edge, then the wobble, blended into its own start over the last stretch so the line
        // meets itself without a step.
        var distances: [CGFloat] = [0]
        for i in 1..<base.count {
            distances.append(distances[i - 1] + hypot(base[i].0.x - base[i - 1].0.x, base[i].0.y - base[i - 1].0.y))
        }
        let total = distances.last! + hypot(base[0].0.x - base.last!.0.x, base[0].0.y - base.last!.0.y)
        let blend = min(40, total / 3)
        return base.indices.map { i in
            let s = distances[i]
            var shift = noise.at(s)
            if s > total - blend {
                let t = (s - (total - blend)) / blend
                let smooth = t * t * (3 - 2 * t)
                shift = shift * (1 - smooth) + noise.at(s - total) * smooth
            }
            let (point, normal) = base[i]
            return Sample(point: CGPoint(x: point.x + normal.dx * shift * wobble, y: point.y + normal.dy * shift * wobble),
                          normal: normal, distance: s)
        }
    }
}

/// The pencil line around a `SketchRect`: a thin band that swells and thins a little as it goes, as a real line does.
/// Fill it with the colour of the line.
struct SketchBorder: Shape {
    var shape: SketchRect
    var width: CGFloat = 1
    /// How much the width varies, as a fraction of it.
    var swell: CGFloat = 0.4

    func path(in rect: CGRect) -> Path {
        let samples = shape.samples(in: rect)
        guard samples.count > 2 else { return Path() }
        let noise = Wobble(shape.seed &+ 17, scale: min(1, max(0.22, 2 * (rect.width + rect.height) / 420)))
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for sample in samples {
            let half = max(0.25, width * (1 + swell * noise.at(sample.distance, lane: 1))) / 2
            outer.append(CGPoint(x: sample.point.x + sample.normal.dx * half, y: sample.point.y + sample.normal.dy * half))
            inner.append(CGPoint(x: sample.point.x - sample.normal.dx * half, y: sample.point.y - sample.normal.dy * half))
        }
        // The inner edge runs the other way, so the middle stays empty with the ordinary fill rule.
        var path = Path()
        path.addLines(outer)
        path.closeSubpath()
        path.addLines(inner.reversed())
        path.closeSubpath()
        return path
    }
}

/// A hand-drawn horizontal rule: uneven, a little thicker in places, and lighter where the pencil touches down and lifts.
struct SketchLine: Shape {
    var seed: UInt64 = 1
    var width: CGFloat = 1
    var wobble: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        guard rect.width > 2 else { return Path() }
        let noise = Wobble(seed, scale: min(1, max(0.3, rect.width / 300)))
        let count = max(2, Int(rect.width / 3))
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in 0...count {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(count)
            let s = x - rect.minX
            let ends = min(1, min(s, rect.width - s) / 10)
            let taper = 0.35 + 0.65 * ends * ends * (3 - 2 * ends)
            let y = rect.midY + noise.at(s) * wobble
            let half = max(0.15, width * taper * (1 + 0.4 * noise.at(s, lane: 1))) / 2
            top.append(CGPoint(x: x, y: y - half))
            bottom.append(CGPoint(x: x, y: y + half))
        }
        var path = Path()
        path.addLines(top + bottom.reversed())
        path.closeSubpath()
        return path
    }
}

/// A circle drawn in one go: it starts at the upper left, goes all the way round and a little past where it began,
/// tightening slightly, the way a hand closes a loop. Stroke it, and trim it to draw it on.
struct SketchLoop: Shape {
    var seed: UInt64 = 1
    var overlap: CGFloat = 0.07

    func path(in rect: CGRect) -> Path {
        let noise = Wobble(seed, scale: 0.3)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        let start = (-150 + 12 * noise.pick(0)) * .pi / 180
        let sweep = 2 * .pi * (1 + overlap)
        var points: [CGPoint] = []
        for i in 0...64 {
            let t = CGFloat(i) / 64
            let angle = start + sweep * t
            let r = radius * (1 + 0.025 * noise.at(t * 120) - 0.05 * t)
            points.append(CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r * 0.97))
        }
        return Path.smooth(through: points)
    }
}

/// A tick, drawn from its short stroke to the end of its long one, each with a slight bow.
struct CheckMark: Shape {
    var seed: UInt64 = 1

    func path(in rect: CGRect) -> Path {
        let noise = Wobble(seed)
        func point(_ x: CGFloat, _ y: CGFloat, _ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + (x + 0.02 * noise.pick(i)) * rect.width, y: rect.minY + (y + 0.02 * noise.pick(i + 10)) * rect.height)
        }
        var path = Path()
        path.move(to: point(0.2, 0.54, 0))
        path.addQuadCurve(to: point(0.42, 0.76, 1), control: point(0.3, 0.68, 2))
        path.addQuadCurve(to: point(0.82, 0.24, 3), control: point(0.57, 0.44, 4))
        return path
    }
}

/// The short, slightly tilted dash of a partly checked box.
struct Dash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.midY + rect.height * 0.03))
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.midY - rect.height * 0.02),
                          control: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.04))
        return path
    }
}

/// The four-pointed sparkle from Spare's icon, with softly curved sides.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (w, h) = (rect.width / 2, rect.height / 2)
        let tips = [CGPoint(x: c.x, y: c.y - h), CGPoint(x: c.x + w, y: c.y), CGPoint(x: c.x, y: c.y + h), CGPoint(x: c.x - w, y: c.y)]
        var path = Path()
        path.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4]
            path.addQuadCurve(to: next, control: CGPoint(x: c.x + (tips[i].x + next.x - 2 * c.x) * 0.12, y: c.y + (tips[i].y + next.y - 2 * c.y) * 0.12))
        }
        path.closeSubpath()
        return path
    }
}

extension Path {
    /// A smooth curve through every point (Catmull-Rom, as cubic Béziers).
    static func smooth(through points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        guard points.count > 2 else { path.addLine(to: points[1]); return path }
        let count = points.count
        func at(_ i: Int) -> CGPoint {
            closed ? points[(i + count) % count] : points[min(max(i, 0), count - 1)]
        }
        for i in 0..<(closed ? count : count - 1) {
            let (p0, p1, p2, p3) = (at(i - 1), at(i), at(i + 1), at(i + 2))
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
        return path
    }
}

// MARK: - Focus

/// A hand-drawn focus ring for Spare's own controls, in the accent colour, drawn just outside the control.
struct SketchFocusRing: View {
    var focused: Bool
    var radius: CGFloat
    var seed: UInt64

    var body: some View {
        SketchBorder(shape: SketchRect(radius: radius + 3, seed: seed &+ 5, wobble: 0.4), width: 1.8, swell: 0.25)
            .fill(.tint)
            .opacity(0.7)
            .padding(-3.5)
            .opacity(focused ? 1 : 0.0001)
            .scaleEffect(focused ? 1 : 1.04)
            .animation(Motion.settle, value: focused)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
