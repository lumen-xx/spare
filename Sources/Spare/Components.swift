import SwiftUI
import SpareCore

extension Rule.Safety {
    var label: String {
        switch self {
        case .rebuilds: "Rebuilds itself"
        case .redownloads: "Downloads again"
        case .disposable: "Not needed"
        case .review: "Your call"
        }
    }
    var color: Color {
        switch self {
        case .rebuilds: Ink.sage
        case .redownloads: Ink.ink
        case .disposable: Ink.sea
        case .review: Ink.warm
        }
    }
    var help: String {
        switch self {
        case .rebuilds: "Apps recreate it on their own as they need it."
        case .redownloads: "Comes back the next time you install or build, which takes time and bandwidth."
        case .disposable: "Nothing uses it once it's been written."
        case .review: "Only you know whether you still need it, so Spare never selects it for you."
        }
    }
}

struct SafetyPill: View {
    let safety: Rule.Safety
    var body: some View {
        Tag(text: safety.label, tint: safety.color).help(safety.help)
    }
}

struct SizeText: View {
    let bytes: Int64?
    var weight: Font.Weight = .medium
    var body: some View {
        Text(bytes.map(Bytes.text) ?? "—")
            .font(.spare(size: 12.5, weight: weight).monospacedDigit())
            .foregroundStyle(bytes == nil ? .tertiary : .primary)
            .contentTransition(.numericText())
            .animation(Motion.count, value: bytes)
    }
}

struct RevealButton: View {
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
        }
        .spareButton(.icon)
        .controlSize(.small)
        .help("Show in Finder")
        .accessibilityLabel("Show in Finder")
    }
}

/// A scrolling page: its parts at a readable width in the middle, arriving one after another.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 860
    var spacing: CGFloat = 26
    var replay = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 96)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.top)
        .arrivalStage(replay: replay)
    }
}

/// A heading for a group on a page, with a line of explanation and something on the right.
struct SectionHeading<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.spare(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeading where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Asks for Full Disk Access, saying plainly what's missed without it. When access comes on while it's showing, it
/// says thank you for a moment and then folds away.
struct FullDiskAccessNote: View {
    var compact = false
    @ObservedObject private var shared = Shared.shared
    @State private var thanking = false
    @State private var gone = Shared.shared.fullDiskAccess
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        if !gone {
            Card(fill: Ink.lifted) {
                HStack(alignment: .center, spacing: 14) {
                    if thanking {
                        DoneMark(warning: false, size: compact ? 26 : 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Thank you. Spare can see everything now.").font(.spare(size: 13, weight: .semibold))
                            Text("It's looking again, including the folders that were locked.").font(.spare(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    } else {
                        if compact { SymbolTile(symbol: "lock", tint: Ink.warm, size: 28) } else { DoodleView(doodle: .lock, width: 78) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Spare can't see everything yet").font(.spare(size: 13, weight: .semibold))
                            Text(compact ? "Locked folders stay closed until Spare has Full Disk Access."
                                         : "Without Full Disk Access, macOS hides Downloads, Documents, Desktop, iPhone backups, Mail and other apps' data. Spare only reads; it never changes anything without asking.")
                                .font(.spare(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                        }
                        Spacer(minLength: 8)
                        Button("Open Settings…") { Permissions.openFullDiskAccessSettings() }
                            .spareButton(.primary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, compact ? 10 : 14)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            .onChange(of: shared.fullDiskAccess) { _, granted in
                guard granted else { return }
                withAnimation(reduceMotion ? Motion.calm : Motion.settle) { thanking = true }
                Feedback.finished("Full Disk Access is on. Spare can see everything now.")
                Task {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    withAnimation(reduceMotion ? Motion.calm : Motion.expand) { gone = true }
                }
            }
        }
    }
}

/// A hand-drawn circle with a tick, or with an exclamation mark when something needs a look. It waits for a breath,
/// draws the circle, then the mark, and lands with a small bounce.
struct DoneMark: View {
    let warning: Bool
    var size: CGFloat = 28
    @State private var drawn = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        let tint = warning ? Ink.warm : Ink.sage
        let seed = Jitter.seed(warning ? "warning" : "done")
        ZStack {
            SketchRect(radius: size / 2, seed: seed, wobble: 0.8, corners: 0.1).fill(tint.opacity(drawn ? 0.15 : 0))
            SketchLoop(seed: seed)
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            if warning {
                VStack(spacing: size * 0.09) {
                    Capsule().fill(tint).frame(width: 2.4, height: drawn ? size * 0.32 : 0)
                    Circle().fill(tint).frame(width: 3, height: 3).scaleEffect(drawn ? 1 : 0)
                }
                .offset(y: size * 0.02)
            } else {
                CheckMark(seed: seed)
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.24)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? Motion.calm : Motion.draw.speed(1.5).delay(Beat.breath), value: drawn)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: drawn) { [still = reduceMotion] content, scale in
            content.scaleEffect(still ? 1 : scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: Beat.breath + 0.3)
                SpringKeyframe(1.14, duration: 0.12, spring: .snappy)
                SpringKeyframe(1, duration: 0.4, spring: Spring(response: 0.34, dampingRatio: 0.45))
            }
        }
        .onAppear { DispatchQueue.main.async { drawn = true } }
        .accessibilityHidden(true)
    }
}

/// What just happened, at the bottom of the window: a short message held a little above the page, with Undo, the
/// next step, or what went wrong. Successes leave after a couple of seconds unless the pointer is on them; problems
/// stay until they're dismissed.
struct BannerView: View {
    @ObservedObject var shared = Shared.shared
    @State private var showingProblems = false
    @State private var hovering = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        if let banner = shared.banner {
            let warning = banner.failed || !banner.problems.isEmpty
            let shape = SketchRect(radius: 16, seed: Jitter.seed(banner.title), wobble: 0.35, corners: 0.1)
            HStack(spacing: 13) {
                DoneMark(warning: warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.spare(size: 13, weight: .semibold))
                    if let detail = banner.detail {
                        Text(detail).font(.spare(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    if !banner.problems.isEmpty {
                        Button("Details") { showingProblems = true }
                            .spareButton(.quiet)
                            .popover(isPresented: $showingProblems) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(banner.problems, id: \.self) { Text($0).font(.spare(size: 12)).textSelection(.enabled) }
                                }
                                .padding(14).frame(maxWidth: 420)
                            }
                    }
                    if let session = banner.session {
                        Button("Undo") { HistoryModel.shared.putBack(session: session) }.spareButton(.secondary)
                    }
                    if banner.offerEmptyTrash {
                        Button("Empty Trash…") { shared.emptyTrash() }.spareButton(.secondary)
                    }
                    if let next = banner.next {
                        Button(next.title) { shared.banner = nil; next.run() }.spareButton(.primary)
                    }
                }
                .controlSize(.small)
                Button { withAnimation(reduceMotion ? Motion.calm : Motion.panel) { shared.banner = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                }
                .spareButton(.icon)
                .controlSize(.small)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(shape.fill(Ink.lifted))
            .overlay(SketchBorder(shape: shape, width: 0.75, swell: 0.3).fill(Ink.line).allowsHitTesting(false))
            .deskShadow(shape, lift: 2.2, seed: shape.seed)
            .padding(16)
            .frame(maxWidth: 780)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .id(banner.id)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .task(id: banner.id) {
                Feedback.announce([banner.title, banner.detail].compactMap { $0 }.joined(separator: ". "))
                // The tap and the sound land with the tick, after the breath and the circle.
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard !Task.isCancelled else { return }
                Feedback.finished(success: !warning)
                guard !warning else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                while (hovering || showingProblems) && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard !Task.isCancelled, shared.banner?.id == banner.id else { return }
                withAnimation(reduceMotion ? Motion.calm : Motion.panel) { shared.banner = nil }
            }
        }
    }
}

/// A page with nothing to show: a small drawing, what that means, and what to do next if anything.
struct EmptyState<Actions: View>: View {
    let doodle: Doodle
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            DoodleView(doodle: doodle, width: 132).padding(.bottom, 4)
            Text(title).font(.spare(size: 14, weight: .semibold))
            // No fixed height: outside a scroll view, wrapping text that fixes its height can ask for any height while
            // it's measured, which made the whole window taller than the screen.
            Text(text).font(.spare(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                .lineLimit(5)
            actions.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    init(doodle: Doodle, title: String, text: String) {
        self.init(doodle: doodle, title: title, text: text) { EmptyView() }
    }
}

/// Something went wrong, said plainly: what happened, what it means, and the next step as a button.
struct ProblemNote: View {
    let title: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        Card(fill: Ink.lifted) {
            HStack(alignment: .center, spacing: 16) {
                DoodleView(doodle: .knot, width: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.spare(size: 13.5, weight: .semibold))
                    Text(text).font(.spare(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                    if let actionTitle, let action {
                        Button(actionTitle, action: action).spareButton(.secondary).controlSize(.small).padding(.top, 6)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A search field: a soft grey well with its own focus ring.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let shape = SketchRect(radius: 8, seed: Jitter.seed(prompt), wobble: 0.3, corners: 0.15)
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(shape.fill(Ink.press))
        .overlay { SketchFocusRing(focused: focused, radius: 8, seed: shape.seed) }
        .animation(Motion.settle, value: text.isEmpty)
    }
}

/// A tray held just above the bottom of the page, for what to do with a selection.
struct FloatingTray<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = SketchRect(radius: 14, seed: 0x7EA1, wobble: 0.35, corners: 0.1)
        HStack(spacing: 10) { content }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(shape.fill(Ink.lifted))
            .overlay(SketchBorder(shape: shape, width: 0.75, swell: 0.3).fill(Ink.line).allowsHitTesting(false))
            .deskShadow(shape, lift: 1.6, seed: shape.seed)
            .padding(.horizontal, 20).padding(.bottom, 14)
    }
}

/// The strip under a table: what's selected on the left, what can be done with it on the right.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .controlSize(.regular)
            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14)
    }
}

/// A table set on a card, with the paper showing around it.
struct TableCard<Content: View>: View {
    var seed: String
    @ViewBuilder var content: Content
    var body: some View {
        Card(seed: Jitter.seed(seed), radius: 12) {
            content
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .scrollIndicators(.never)
                .clipShape(SketchRect(radius: 11, seed: Jitter.seed(seed), wobble: 0.3))
                .padding(1)
        }
        .padding(.horizontal, 18)
    }
}

extension Date {
    var ago: String { Catalog.ago(self, from: Date()) }
}

/// "1 item", "3 items".
func countText(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }
