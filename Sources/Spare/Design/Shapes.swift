import SwiftUI

extension RoundedRectangle {
    /// The rounded rectangle every surface uses: cards, buttons, tags, wells and trays.
    static func continuous(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

/// A tick, drawn from its short stroke to the end of its long one, each with a slight bow.
struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: point(0.2, 0.54))
        path.addQuadCurve(to: point(0.42, 0.76), control: point(0.3, 0.68))
        path.addQuadCurve(to: point(0.82, 0.24), control: point(0.57, 0.44))
        return path
    }
}

/// The short dash of a partly checked box.
struct Dash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.74, y: rect.midY))
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

/// A focus ring for Spare's own controls, in the accent colour, drawn just outside the control.
struct FocusRing: View {
    var focused: Bool
    var radius: CGFloat

    var body: some View {
        RoundedRectangle.continuous(radius + 3)
            .strokeBorder(.tint, lineWidth: 1.8)
            .opacity(0.7)
            .padding(-3.5)
            .opacity(focused ? 1 : 0.0001)
            .scaleEffect(focused ? 1 : 1.04)
            .animation(Motion.settle, value: focused)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
