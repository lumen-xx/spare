import SwiftUI
import SpareCore

/// Docker and the apps like it keep images, containers, volumes and build cache inside one large disk file. Spare
/// shows that file and what's inside it, and clears what Docker can fetch or build again. Volumes can hold databases,
/// so they're only shown.
@MainActor
final class DockerModel: ObservableObject {
    static let shared = DockerModel()
    @Published private(set) var disks: [Docker.DiskImage] = []
    @Published private(set) var usage: [Docker.Usage] = []
    @Published private(set) var loading = false
    /// Whether the docker command is installed.
    @Published private(set) var hasCommand = true
    /// Why Docker didn't say what's inside, such as it not running.
    @Published private(set) var problem: String?
    @Published private(set) var working: String?
    private var started = false

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    var total: Int64 { disks.reduce(0) { $0 + $1.bytes } }
    var reclaimable: Int64 { usage.filter { Clearing(kind: $0.kind) != nil }.reduce(0) { $0 + $1.reclaimable } }

    /// What Spare clears for each kind, with Docker's own commands.
    enum Clearing {
        case buildCache, images, containers

        init?(kind: String) {
            switch kind.lowercased() {
            case "build cache": self = .buildCache
            case "images": self = .images
            case "containers": self = .containers
            default: return nil
            }
        }

        var arguments: [String] {
            switch self {
            case .buildCache: ["builder", "prune", "--force"]
            case .images: ["image", "prune", "--all", "--force"]
            case .containers: ["container", "prune", "--force"]
            }
        }

        var button: String {
            switch self {
            case .buildCache: "Clear Build Cache…"
            case .images: "Remove Unused…"
            case .containers: "Remove Stopped…"
            }
        }

        var question: String {
            switch self {
            case .buildCache: "Clear Docker's build cache?"
            case .images: "Remove images no container uses?"
            case .containers: "Remove stopped containers?"
            }
        }

        var consequence: String {
            switch self {
            case .buildCache: "The next build takes longer while Docker builds its layers again."
            case .images: "Docker downloads or builds them again the next time they're needed."
            case .containers: "Anything they wrote outside a volume is deleted for good. Running containers aren't touched."
            }
        }
    }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            let (disks, usage, hasCommand, problem) = await background { () -> ([Docker.DiskImage], [Docker.Usage], Bool, String?) in
                let disks = Docker.diskImages(home: home).sorted { $0.bytes > $1.bytes }
                guard Shell.which("docker") != nil else { return (disks, [], false, nil) }
                let result = Shell.run("docker", ["system", "df", "--format", "{{json .}}"], timeout: 30)
                guard result.succeeded else { return (disks, [], true, result.output.split(separator: "\n").first.map(String.init) ?? "") }
                return (disks, Docker.usage(lines: result.output), true, nil)
            }
            self.disks = disks
            self.usage = usage
            self.hasCommand = hasCommand
            self.problem = problem
            self.loading = false
        }
    }

    func clear(_ clearing: Clearing, kind: String) {
        guard working == nil else { return }
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have asked Docker to clear it."); return }
        #endif
        working = kind
        Task {
            let result = await background { Shell.run("docker", clearing.arguments, timeout: 600) }
            working = nil
            if result.succeeded {
                // Docker ends with "Total reclaimed space: 1.2GB".
                let line = result.output.split(separator: "\n").last { $0.lowercased().contains("reclaimed space") }
                let freed = line.flatMap { $0.split(separator: ":").last }.flatMap { Docker.bytes(String($0)) } ?? 0
                Shared.shared.banner = .init(title: freed > 0 ? "Docker freed \(Bytes.text(freed))" : "Docker had nothing to free",
                                             detail: freed > 0 ? "Its disk file may take a few minutes to shrink on the Mac." : nil)
            } else {
                Shared.shared.banner = .init(title: "Docker didn't clear it",
                                             detail: result.output.split(separator: "\n").first.map(String.init) ?? "docker stopped with code \(result.status).",
                                             failed: true, next: .init(title: "Try Again") { DockerModel.shared.clear(clearing, kind: kind) })
            }
            Shared.shared.refreshSpace()
            load()
        }
    }

    #if DEBUG
    func showDemo(disks: [Docker.DiskImage], usage: [Docker.Usage]) {
        started = true
        self.disks = disks
        self.usage = usage
    }
    #endif
}

struct DockerView: View {
    @ObservedObject var model = DockerModel.shared
    @State private var confirming: (clearing: DockerModel.Clearing, usage: Docker.Usage)?
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.disks.isEmpty && !model.hasCommand && !model.loading {
                EmptyState(doodle: .box, title: "No Docker here",
                           text: "Docker Desktop, OrbStack, Colima and Podman keep containers in one large disk file. None of them is set up on this Mac.")
            } else {
                PageScroll(replay: model.disks.isEmpty && model.usage.isEmpty) {
                    header.arrives(0)
                    inside.arrives(1)
                    if !model.disks.isEmpty { disksSection.arrives(2) }
                    Text("Docker Desktop and OrbStack give freed space back to the Mac by themselves, sometimes after a few minutes. Other tools' disks can keep their size until the machine is made again.")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .arrives(3)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.working != nil).help("Look Again")
            }
        }
        .alert(confirming?.clearing.question ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let confirming {
                Button(confirming.clearing.button.replacingOccurrences(of: "…", with: ""), role: .destructive) {
                    model.clear(confirming.clearing, kind: confirming.usage.kind)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let confirming {
                Text("Up to \(Bytes.text(confirming.usage.reclaimable)) comes back. \(confirming.clearing.consequence)")
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(model.loading ? "Asking Docker" : model.working != nil ? "Docker is clearing" : "Docker's disk on this Mac").contentTransition(.opacity)
                if model.loading || model.working != nil { ThinkingDots().transition(.opacity) }
            }
            .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.loading)
            Text(Bytes.text(model.total))
                .font(.spare(size: 46, weight: .bold))
                .contentTransition(.numericText())
                .animation(Motion.count.delay(Beat.settle), value: model.total)
            Text(model.reclaimable > 0 ? "\(Bytes.text(model.reclaimable)) inside it can be cleared" : "Images, containers, volumes and build cache, all in one file")
                .font(.spare(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var inside: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Inside", subtitle: "As Docker counts it")
            if !model.hasCommand {
                ProblemNote(title: "Docker's command isn't installed",
                            text: "Spare asks the docker command what's inside the disk. Install it with Docker Desktop, OrbStack or Homebrew to see more here.")
            } else if let problem = model.problem {
                ProblemNote(title: "Docker isn't running",
                            text: "Start Docker Desktop, OrbStack or Colima to see what's inside its disk. Docker said: “\(problem)”",
                            actionTitle: "Try Again") { model.load() }
            } else {
                Card {
                    if model.usage.isEmpty {
                        HStack(spacing: 8) {
                            if model.loading { ThinkingDots() }
                            Text(model.loading ? "Asking Docker" : "Docker has nothing stored.").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(Array(model.usage.enumerated()), id: \.element.id) { index, usage in
                        if index > 0 { RowDivider().padding(.leading, 56).padding(.trailing, 14) }
                        UsageRow(usage: usage) { clearing in confirming = (clearing, usage) }
                    }
                }
            }
        }
    }

    private var disksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Disk Files", subtitle: "Space they really take, which can be less than Finder shows")
            Card {
                ForEach(Array(model.disks.enumerated()), id: \.element.id) { index, disk in
                    if index > 0 { RowDivider().padding(.leading, 44).padding(.trailing, 12) }
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(disk.app).font(.spare(size: 12.5, weight: .medium))
                            Text(Catalog.tilde(disk.url, home: home)).font(.spare(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        SizeText(bytes: disk.bytes, weight: .semibold)
                        RevealButton(url: disk.url)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .fileMenu([disk.url])
                }
            }
        }
    }
}

private struct UsageRow: View {
    let usage: Docker.Usage
    let clear: (DockerModel.Clearing) -> Void
    @ObservedObject var model = DockerModel.shared

    private var clearing: DockerModel.Clearing? { DockerModel.Clearing(kind: usage.kind) }

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, tint: clearing != nil && usage.reclaimable > 0 ? Ink.sea : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.kind).font(.spare(size: 13, weight: .semibold))
                Text(detail).font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: usage.bytes, weight: .semibold)
                if usage.reclaimable > 0 {
                    Text("\(Bytes.text(usage.reclaimable)) unused").font(.spare(size: 11)).foregroundStyle(.secondary)
                }
            }
            if model.working == usage.kind {
                ThinkingDots().frame(width: 60)
            } else if let clearing {
                Button(clearing.button) { clear(clearing) }
                    .spareButton(.secondary).controlSize(.small)
                    .disabled(usage.reclaimable == 0 || model.working != nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var symbol: String {
        switch usage.kind.lowercased() {
        case "images": "square.stack.3d.up"
        case "containers": "shippingbox"
        case "local volumes": "cylinder"
        default: "hammer"
        }
    }

    private var detail: String {
        let count = "\(usage.count) · \(usage.active) in use"
        switch usage.kind.lowercased() {
        case "local volumes": return count + " · Volumes can hold databases, so Spare leaves them to you"
        case "build cache": return "Layers kept to make builds faster"
        default: return count
        }
    }
}
