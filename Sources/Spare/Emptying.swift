import AppKit
import SwiftUI
import SpareCore

/// Emptying the Trash. While it runs, a screen is laid over the whole window: what Spare is doing, a bar, how much is
/// deleted and roughly how long is left, and Stop.
@MainActor
final class TrashEmptying: ObservableObject {
    static let shared = TrashEmptying()

    enum Step: Equatable {
        /// Looking through the Trash to see how much there is.
        case counting
        case deleting
        /// Clearing the locked flag on something that wouldn't delete.
        case unlocking
        /// macOS is asking for an administrator's password to delete this many items that belong to the system.
        case administrator(Int)
        /// Without Full Disk Access, Finder empties the Trash and shows how far it is in its own window.
        case finder
        case stopping
        case done

        var stoppable: Bool { [.counting, .deleting, .unlocking].contains(self) }
    }

    /// What the screen shows. It changes many times a second, so it's published on its own: the window only
    /// redraws when emptying starts or ends.
    @MainActor
    final class Status: ObservableObject {
        @Published fileprivate(set) var step = Step.counting
        @Published fileprivate(set) var progress = TrashEmptier.Progress()
        /// Seconds left, once enough has been deleted to tell.
        @Published fileprivate(set) var secondsLeft: Double?
    }

    @Published private(set) var active = false
    let status = Status()
    private var cancel = Cancellation()
    /// When deleting started, and how far it had got then, for the estimate.
    private var deleting: (since: Date, entries: Int)?

    /// Starts emptying. The person has already said yes.
    func start() {
        guard !active else { return }
        let token = Cancellation()
        cancel = token
        status.step = Shared.shared.canSeeTrash ? .counting : .finder
        status.progress = .init()
        status.secondsLeft = nil
        deleting = nil
        // A message from before, such as Undo for something now being deleted for good, no longer applies.
        Shared.shared.banner = nil
        active = true
        Feedback.announce("Emptying the Trash")
        Task { await run(token) }
    }

    /// Stops after the file being deleted now. What's left stays in the Trash.
    func stop() {
        guard active, status.step.stoppable else { return }
        cancel.cancel()
        status.step = .stopping
    }

    private func run(_ token: Cancellation) async {
        let shown = Date()
        let shared = Shared.shared
        let before = shared.space?.free ?? 0
        guard Shared.shared.canSeeTrash else {
            // Without Full Disk Access macOS hides the Trash's contents from Spare, so Finder has to do it. Finder holds
            // Spare up while it works, so the screen gets a moment to appear first.
            try? await Task.sleep(nanoseconds: 450_000_000)
            let problem = Privileged.emptyTrash()
            await finish(shown: shown, banner: problem.map {
                Shared.Banner(title: "The Trash wasn't emptied", detail: $0 + " Giving Spare Full Disk Access lets it empty the Trash itself.",
                              failed: true, next: .init(title: "Open Settings…") { Permissions.openFullDiskAccessSettings() })
            } ?? Shared.Banner(title: "Emptied the Trash", detail: nil))
            return
        }

        // Item by item, so one item Finder would stop at doesn't keep the rest.
        let trash = Shared.trashFolder
        var result = await background {
            TrashEmptier.empty(trash, cancel: token) { progress in
                DispatchQueue.main.async { MainActor.assumeIsolated { TrashEmptying.shared.update(progress, token) } }
            }
        }
        if !result.needsAdministrator.isEmpty, !result.stopped {
            status.step = .administrator(result.needsAdministrator.count)
            status.secondsLeft = nil
            // macOS's password prompt holds Spare up too, so the screen says why first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            let command = "rm -rf " + result.needsAdministrator.map { Privileged.quoted($0.path) }.joined(separator: " ")
            if let problem = Privileged.run(command, prompt: "Spare wants to delete items in the Trash that belong to the system."), problem != "Cancelled." {
                result.failed += result.needsAdministrator.map { ($0, problem) }
            } else {
                let left = result.needsAdministrator.filter { FileManager.default.fileExists(atPath: $0.path) }
                result.removed += result.needsAdministrator.count - left.count
                result.failed += left.map { ($0, "Still there; it needs an administrator to delete.") }
            }
        }

        shared.refreshSpace()
        let freed = max(0, (shared.space?.free ?? before) - before)
        let problems = result.failed.map { "\($0.0.lastPathComponent): \($0.1)" }
        let banner: Shared.Banner
        if result.stopped {
            banner = Shared.Banner(title: "Stopped emptying the Trash",
                                   detail: (result.removed > 0 ? "Deleted \(countText(result.removed, "item")). " : "") + "The rest is still in the Trash.",
                                   problems: problems)
        } else if problems.isEmpty {
            banner = Shared.Banner(title: "Emptied the Trash", detail: freed > 0 ? "\(Bytes.text(freed)) is free again." : nil)
        } else {
            banner = Shared.Banner(title: result.removed > 0 ? "Emptied the Trash, except \(problems.count == 1 ? "1 item" : "\(problems.count) items")" : "The Trash wasn't emptied",
                                   detail: nil, problems: problems, failed: true)
        }
        await finish(shown: shown, banner: banner, stopped: result.stopped)
    }

    /// Fills the bar, lets it be seen for a moment, then takes the screen away and says how it went.
    private func finish(shown: Date, banner: Shared.Banner, stopped: Bool = false) async {
        if !stopped {
            status.progress.entriesDone = status.progress.entries
            status.progress.bytesDone = max(status.progress.bytesDone, status.progress.bytes)
            status.progress.itemsDone = status.progress.items
            status.step = .done
        }
        status.secondsLeft = nil
        // Long enough to read as finished rather than flicker, even when there was almost nothing to delete.
        let hold = max(0.35, 0.9 - Date().timeIntervalSince(shown))
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        Shared.shared.refreshSpace()
        HistoryModel.shared.refresh()
        active = false
        Shared.shared.banner = banner
    }

    private func update(_ progress: TrashEmptier.Progress, _ token: Cancellation) {
        guard active, token === cancel else { return }
        status.progress = progress
        switch status.step {
        case .stopping, .done, .administrator, .finder: return
        default: break
        }
        switch progress.step {
        case .counting: status.step = .counting
        case .unlocking: status.step = .unlocking
        case .deleting:
            status.step = .deleting
            estimate(progress)
        }
    }

    /// Seconds left from how fast files have gone so far, smoothed so the number doesn't jump about.
    private func estimate(_ progress: TrashEmptier.Progress) {
        guard let deleting else {
            deleting = (Date(), progress.entriesDone)
            return
        }
        let elapsed = Date().timeIntervalSince(deleting.since)
        let done = progress.entriesDone - deleting.entries
        guard elapsed >= 1.5, done > 0 else { return }
        let left = Double(max(0, progress.entries - progress.entriesDone)) / (Double(done) / elapsed)
        status.secondsLeft = status.secondsLeft.map { $0 * 0.8 + left * 0.2 } ?? left
    }

    /// "About 2 minutes left", rounded the way people say it.
    nonisolated static func timeLeft(_ seconds: Double) -> String {
        switch seconds {
        case ..<5: return "Almost done"
        case ..<15: return "A few seconds left"
        case ..<55: return "About \(Int((seconds / 10).rounded()) * 10) seconds left"
        case ..<90: return "About a minute left"
        case ..<(55 * 60): return "About \(Int((seconds / 60).rounded())) minutes left"
        case ..<(90 * 60): return "About an hour left"
        default: return "About \(Int((seconds / 3600).rounded())) hours left"
        }
    }
}

/// Laid over the whole window while the Trash empties: the window blurred behind warm paper, and a card in the middle
/// with what's happening. Everything under it waits until it's done.
struct EmptyingScreen: View {
    @ObservedObject private var emptying = TrashEmptying.shared
    @ObservedObject private var status = TrashEmptying.shared.status
    @State private var shown = false
    @Environment(\.reduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private var progress: TrashEmptier.Progress { status.progress }

    var body: some View {
        ZStack {
            Group {
                if reduceTransparency || contrast == .increased {
                    Ink.paper
                } else {
                    WithinWindowBlur().overlay(Ink.paper.opacity(scheme == .dark ? 0.55 : 0.5))
                }
            }
            .accessibilityHidden(true)
            card
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown || reduceMotion ? 1 : 0.96)
                .offset(y: shown || reduceMotion ? 0 : 8)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(reduceMotion ? Motion.calm : Motion.arrive.delay(Beat.settle)) { shown = true }
        }
    }

    private var card: some View {
        Card(radius: 18, lift: 2.2, fill: Ink.lifted) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    SymbolTile(symbol: status.step == .done ? "checkmark" : "trash", tint: Ink.sea, size: 40)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Emptying the Trash")
                            .font(.spare(size: 15, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(doing)
                            .font(.spare(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if measured {
                        UsageBar(fraction: status.step == .done ? 1 : progress.fraction, height: 8)
                    } else {
                        SweepBar(height: 8)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        // Changes many times a second, so it isn't rolled: rolling digits would never settle enough to read.
                        Text(amount)
                        Spacer(minLength: 12)
                        Text(time).contentTransition(.numericText())
                    }
                    .font(.spare(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Progress")
                .accessibilityValue(measured && status.step != .done ? "\(Int(progress.fraction * 100)) percent. \(amount). \(time)" : doing)
                .accessibilityAddTraits(.updatesFrequently)
                HStack {
                    Text(footnote).font(.spare(size: 11).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(2)
                    Spacer(minLength: 12)
                    Button("Stop") { emptying.stop() }
                        .spareButton(.secondary)
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!status.step.stoppable)
                        .help("Stops after the file being deleted now. What's left stays in the Trash.")
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
        }
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Whether the bar can show how far along it is, or only that something is happening.
    private var measured: Bool {
        switch status.step {
        case .done: true
        case .deleting, .unlocking, .stopping: progress.entries > 0
        default: false
        }
    }

    private var place: String {
        progress.items > 1 ? " (\(min(progress.itemsDone + 1, progress.items)) of \(progress.items))" : ""
    }

    private var doing: String {
        switch status.step {
        case .counting:
            progress.items == 0 ? "Looking in the Trash…" : "Counting what's in the Trash…"
        case .deleting:
            progress.current.map { "Deleting “\($0)”" + place } ?? "Deleting…"
        case .unlocking:
            progress.current.map { "Unlocking “\($0)” to delete it" } ?? "Unlocking locked files…"
        case .administrator(let count):
            "Waiting for an administrator's password to delete \(countText(count, "item")) that belong to the system"
        case .finder:
            "Finder is emptying the Trash"
        case .stopping:
            "Finishing the file being deleted now"
        case .done:
            "Done"
        }
    }

    private var amount: String {
        switch status.step {
        case .counting:
            progress.items == 0 ? " " : "Counted \(progress.itemsDone) of \(countText(progress.items, "item")) · \(Bytes.text(progress.bytes))"
        case .finder:
            "Finder shows how far it is in its own window."
        case .administrator:
            "\(Bytes.text(progress.bytesDone)) deleted so far"
        default:
            // Files, like the bar: they're what deleting takes time over. A big film goes in a moment, a folder of
            // small files takes a while.
            progress.entries > 0 ? "\(progress.entriesDone.formatted()) of \(progress.entries.formatted()) files" : " "
        }
    }

    private var time: String {
        switch status.step {
        case .deleting, .unlocking:
            status.secondsLeft.map(TrashEmptying.timeLeft) ?? "Working out how long…"
        default:
            ""
        }
    }

    private var footnote: String {
        switch status.step {
        case .administrator: "macOS asks for the password in its own window."
        case .finder: "Spare waits until Finder is done."
        case .counting: "Deleted for good; History can't put these back."
        default: progress.bytesDone > 0 ? "\(Bytes.text(progress.bytesDone)) deleted so far" : "Deleted for good; History can't put these back."
        }
    }
}

/// The window's own contents, blurred, as macOS does under a sheet's glass.
private struct WithinWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
