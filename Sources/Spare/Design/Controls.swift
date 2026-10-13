import SwiftUI

/// Spare's buttons: flat and quiet, with evenly rounded corners. Each squashes a little under the pointer and
/// springs back with a small overshoot, notices the pointer with a soft lag, and shows keyboard focus with its own ring.
struct SpareButtonStyle: ButtonStyle {
    enum Kind {
        /// The one thing the page is for, filled with the accent colour.
        case primary
        /// Everything else: a soft grey fill, no edge.
        case secondary
        /// Text only, for small actions inside rows and messages.
        case quiet
        /// A round symbol button, such as Show in Finder.
        case icon
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == SpareButtonStyle {
    static var primary: SpareButtonStyle { SpareButtonStyle(kind: .primary) }
    static var secondary: SpareButtonStyle { SpareButtonStyle(kind: .secondary) }
    static var quiet: SpareButtonStyle { SpareButtonStyle(kind: .quiet) }
    static var icon: SpareButtonStyle { SpareButtonStyle(kind: .icon) }
}

extension View {
    /// A Spare button: the style, and its own focus ring in place of the system's rectangle.
    func spareButton(_ style: SpareButtonStyle) -> some View {
        buttonStyle(style).focusEffectDisabled()
    }
}

private struct StyledButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: SpareButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.controlSize) private var size
    @Environment(\.reduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tintText) private var tintText
    @State private var hovering = false

    private var pressed: Bool { configuration.isPressed }
    private var destructive: Bool { configuration.role == .destructive }

    var body: some View {
        let shape = RoundedRectangle.continuous(radius)
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: kind == .icon ? iconSize : nil, minHeight: kind == .icon ? iconSize : nil)
            .background {
                switch kind {
                case .primary:
                    shape.fill(.tint)
                        .overlay(shape.fill(.black.opacity(pressed ? 0.14 : 0)))
                        .overlay(shape.fill(.white.opacity(hovering && !pressed ? 0.08 : 0)))
                case .secondary:
                    shape.fill(Ink.press)
                        .overlay(shape.fill(pressed ? Ink.press : hovering ? Ink.wash : .clear))
                        .overlay {
                            if contrast == .increased { shape.strokeBorder(Ink.edge, lineWidth: 1.2) }
                        }
                case .quiet, .icon:
                    shape.fill(pressed ? Ink.press : hovering ? Ink.wash : .clear)
                }
            }
            .overlay { FocusRing(focused: focused, radius: radius) }
            .contentShape(shape)
            .scaleEffect(x: pressed && !reduceMotion ? 1.015 : 1, y: pressed && !reduceMotion ? 0.95 : 1)
            .animation(pressed ? Motion.press : Motion.release, value: pressed)
            .opacity(enabled ? 1 : 0.42)
            .onHover { inside in withAnimation(inside ? Motion.hoverIn : Motion.hoverOut) { hovering = inside } }
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(.white)
        case .secondary: destructive ? AnyShapeStyle(Ink.brick) : AnyShapeStyle(.primary)
        case .quiet: destructive ? AnyShapeStyle(Ink.brick) : tintText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)
        case .icon: AnyShapeStyle(hovering ? .primary : .secondary)
        }
    }

    private var font: Font {
        switch size {
        case .mini: .spare(size: 10.5, weight: .medium)
        case .small: .spare(size: 11.5, weight: .medium)
        case .large, .extraLarge: .spare(size: 13.5, weight: .semibold)
        default: .spare(size: 12.5, weight: kind == .primary ? .semibold : .medium)
        }
    }

    private var radius: CGFloat {
        switch kind {
        case .icon: iconSize / 2
        default: size == .large || size == .extraLarge ? 10 : size == .small || size == .mini ? 7 : 8
        }
    }

    private var iconSize: CGFloat { size == .small || size == .mini ? 20 : 24 }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .icon: 0
        case .quiet: size == .small || size == .mini ? 5 : 7
        default: size == .large || size == .extraLarge ? 18 : size == .small || size == .mini ? 9 : 13
        }
    }

    private var verticalPadding: CGFloat {
        switch kind {
        case .icon: 0
        default: size == .large || size == .extraLarge ? 8.5 : size == .small || size == .mini ? 3 : 5
        }
    }
}

// MARK: - Check box

/// A check box with a mixed state for a group. It squashes when pressed, considers for a beat, then the tick draws
/// itself in with a small bounce. The state itself changes at once; only the drawing waits.
struct CheckBox: View {
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) { CheckFace(state: state) }
            .buttonStyle(CheckStyle())
            .focusEffectDisabled()
            .accessibilityValue(state == .on ? "checked" : state == .mixed ? "partly checked" : "unchecked")
            .accessibilityAddTraits(.isToggle)
    }
}

private struct CheckStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressable(configuration: configuration) }

    private struct Pressable: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        @Environment(\.reduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .overlay { FocusRing(focused: focused, radius: 5) }
                .scaleEffect(x: configuration.isPressed && !reduceMotion ? 1.06 : 1, y: configuration.isPressed && !reduceMotion ? 0.9 : 1)
                .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
    }
}

private struct CheckFace: View {
    let state: CheckState
    @Environment(\.isEnabled) private var enabled
    @Environment(\.reduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle.continuous(4.5)
        let filled = state != .off
        ZStack {
            shape.fill(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Ink.card))
            shape.strokeBorder(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Ink.edge), lineWidth: contrast == .increased ? 1.6 : 1.2)
            CheckMark()
                .trim(from: 0, to: state == .on ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .padding(1.5)
                .animation(state == .on && !reduceMotion ? Motion.draw.speed(1.8).delay(Beat.tick) : Motion.calm, value: state)
            Dash()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                .opacity(state == .mixed ? 1 : 0)
                .scaleEffect(x: state == .mixed ? 1 : 0.2)
                .animation(reduceMotion ? Motion.calm : Motion.settle.delay(Beat.tick), value: state)
        }
        .frame(width: 16, height: 16)
        .animation(reduceMotion ? Motion.calm : Motion.settle.delay(Beat.tick), value: filled)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: state) { [still = reduceMotion] content, scale in
            content.scaleEffect(still ? 1 : scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: Beat.tick)
                SpringKeyframe(1.12, duration: 0.1, spring: .snappy)
                SpringKeyframe(1, duration: 0.35, spring: Spring(response: 0.34, dampingRatio: 0.45))
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Switch

/// A switch for Settings. The knob waits a beat, slides with a little overshoot, and stretches while pressed.
struct SpareSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Button { configuration.isOn.toggle() } label: { SwitchFace(on: configuration.isOn) }
                .buttonStyle(SwitchPress())
                .focusEffectDisabled()
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }

    private struct SwitchPress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.environment(\.switchPressed, configuration.isPressed)
        }
    }
}

private struct SwitchPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var switchPressed: Bool {
        get { self[SwitchPressedKey.self] }
        set { self[SwitchPressedKey.self] = newValue }
    }
}

private struct SwitchFace: View {
    let on: Bool
    @Environment(\.switchPressed) private var pressed
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        let track = Capsule()
        ZStack(alignment: on ? .trailing : .leading) {
            track.fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Ink.press))
                .overlay(track.strokeBorder(on ? AnyShapeStyle(.clear) : AnyShapeStyle(Ink.line), lineWidth: 1))
            Circle()
                .fill(.white)
                .frame(width: pressed && !reduceMotion ? 20 : 16, height: 16)
                .shadow(color: Ink.shade.opacity(0.18), radius: 1, x: 0.3, y: 0.8)
                .padding(2)
        }
        .frame(width: 36, height: 20)
        .overlay { FocusRing(focused: focused, radius: 10) }
        .animation(reduceMotion ? Motion.calm : Motion.varied(Motion.settle, on ? 1 : 2).delay(Beat.toggle), value: on)
        .animation(Motion.press, value: pressed)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

// MARK: - Small parts

/// A small label, such as "Rebuilds itself".
struct Tag: View {
    let text: String
    let tint: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text)
        }
        .font(.spare(size: 10.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// A symbol on a small tile of its colour.
struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle.continuous(size * 0.3).fill(tint.opacity(0.12)))
            .accessibilityHidden(true)
    }
}

/// How full something is, as a bar.
struct UsageBar: View {
    var fraction: Double
    /// The accent colour unless given.
    var tint: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.press)
                Capsule()
                    .fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
                    .frame(width: fraction > 0 ? max(height, width) : 0)
            }
        }
        .frame(height: height)
        .animation(Motion.count, value: fraction)
        .accessibilityHidden(true)
    }
}

/// Three dots bobbing while Spare works, so a wait never looks like a stall. With Reduce Motion they only fade.
struct ThinkingDots: View {
    var tint: Color = .secondary
    @State private var up = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 4.5, height: 4.5)
                    .offset(y: up && !reduceMotion ? -2.5 : 1)
                    .opacity(reduceMotion ? (up ? 1 : 0.35) : 0.85)
                    .animation(reduceMotion ? .easeInOut(duration: 0.7).repeatForever().delay(Double(index) * 0.2)
                                            : .spring(response: 0.42, dampingFraction: 0.5).repeatForever().delay(Double(index) * 0.13 * (1 + 0.08 * Jitter.unit(index))),
                               value: up)
            }
        }
        .frame(height: 10)
        .onAppear { DispatchQueue.main.async { up = true } }
        .accessibilityElement()
        .accessibilityLabel("Working")
    }
}

// MARK: - Check box toggle

/// A Toggle drawn as Spare's check box, for options such as "Only what you installed".
struct SpareCheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            CheckBox(state: configuration.isOn ? .on : .off) { configuration.isOn.toggle() }
            configuration.label
                .onTapGesture { configuration.isOn.toggle() }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}
