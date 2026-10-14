import SwiftUI
import SpareCore

/// Xcode's simulators and the systems they run. Each simulator keeps its own apps and data, and each system is a disk
/// image of several gigabytes. Removing either goes through simctl and can't be undone, so every removal is confirmed.
@MainActor
final class SimulatorsModel: ObservableObject {
    static let shared = SimulatorsModel()
    @Published private(set) var devices: [Simulators.Device] = []
    @Published private(set) var runtimes: [Simulators.Runtime] = []
    @Published private(set) var loading = false
    /// Why simulators can't be listed, such as Xcode not being installed.
    @Published private(set) var problem: String?
    /// What's being removed or erased.
    @Published private(set) var working: Set<String> = []
    private var started = false

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    var total: Int64 { devices.reduce(0) { $0 + ($1.bytes ?? 0) } + runtimes.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var broken: [Simulators.Device] { devices.filter { !$0.isAvailable } }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            let (devices, runtimes, problem) = await background { () -> ([Simulators.Device], [Simulators.Runtime], String?) in
                guard let simctl = SimulatorsModel.simctl() else { return ([], [], SimulatorsModel.noXcode) }
                let listed = Shell.run(simctl, ["list", "devices", "--json"], timeout: 60)
                guard listed.succeeded else { return ([], [], listed.output) }
                var devices = Simulators.devices(json: Data(listed.output.utf8))
                // Newer Xcodes say how much each simulator holds; otherwise it's measured.
                for index in devices.indices where devices[index].bytes == nil {
                    if let url = devices[index].dataURL { devices[index].bytes = DiskUsage.measure(url).bytes }
                }
                var runtimes = Simulators.runtimes(json: Data(Shell.run(simctl, ["runtime", "list", "--json"], timeout: 60).output.utf8))
                if runtimes.isEmpty {
                    runtimes = Simulators.runtimes(json: Data(Shell.run(simctl, ["list", "runtimes", "--json"], timeout: 60).output.utf8))
                }
                return (devices, runtimes, nil)
            }
            self.devices = devices.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            self.runtimes = runtimes.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            self.problem = problem
            self.loading = false
        }
    }

    nonisolated static let noXcode = "Simulators come with Xcode, and Xcode isn't installed on this Mac."

    /// simctl inside the Xcode that's in use, or else inside any Xcode in Applications. Found through xcode-select,
    /// which never offers to install anything: /usr/bin/xcrun would ask to install the developer tools on a Mac
    /// without them, and fails when only the Command Line Tools are selected.
    nonisolated static func simctl() -> String? {
        var developers: [String] = []
        let selected = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        if selected.succeeded { developers.append(selected.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        developers += applications.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().map { "/Applications/\($0)/Contents/Developer" }
        return developers.map { $0 + "/usr/bin/simctl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum Action {
        case delete([Simulators.Device]), erase(Simulators.Device), deleteRuntime(Simulators.Runtime)

        var ids: [String] {
            switch self {
            case .delete(let devices): devices.map(\.id)
            case .erase(let device): [device.id]
            case .deleteRuntime(let runtime): [runtime.id]
            }
        }
    }

    func run(_ action: Action) {
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have changed the simulators."); return }
        #endif
        working.formUnion(action.ids)
        Task {
            let (problems, freed) = await background { () -> ([String], Int64) in
                var problems: [String] = []
                var freed: Int64 = 0
                let tool = SimulatorsModel.simctl() ?? "/usr/bin/false"
                func simctl(_ arguments: [String], _ name: String, _ bytes: Int64?) {
                    let result = Shell.run(tool, arguments, timeout: 300)
                    if result.succeeded { freed += bytes ?? 0 }
                    else { problems.append("\(name): \(result.output.split(separator: "\n").first.map(String.init) ?? "simctl stopped with code \(result.status).")") }
                }
                switch action {
                case .delete(let devices): for device in devices { simctl(["delete", device.udid], "\(device.name) (\(device.runtime))", device.bytes) }
                case .erase(let device): simctl(["erase", device.udid], "\(device.name) (\(device.runtime))", device.bytes)
                case .deleteRuntime(let runtime): simctl(["runtime", "delete", runtime.identifier], runtime.name, runtime.bytes)
                }
                return (problems, freed)
            }
            working.subtract(action.ids)
            if problems.isEmpty {
                let title: String
                switch action {
                case .delete(let devices): title = devices.count == 1 ? "Deleted \(devices[0].name)" : "Deleted \(devices.count) simulators"
                case .erase(let device): title = "Erased \(device.name)"
                case .deleteRuntime(let runtime): title = "Deleted \(runtime.name)"
                }
                Shared.shared.banner = .init(title: title, detail: freed > 0 ? "\(Bytes.text(freed)) is free again." : nil)
            } else {
                Shared.shared.banner = .init(title: "Xcode's simulator tool refused", detail: problems.first,
                                             problems: problems.count > 1 ? problems : [], failed: true,
                                             next: .init(title: "Try Again") { SimulatorsModel.shared.run(action) })
            }
            Shared.shared.refreshSpace()
            load()
        }
    }

    #if DEBUG
    func showDemo(devices: [Simulators.Device], runtimes: [Simulators.Runtime]) {
        started = true
        self.devices = devices.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        self.runtimes = runtimes.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
    #endif
}

struct SimulatorsView: View {
    @ObservedObject var model = SimulatorsModel.shared
    @State private var confirming: Confirmation?
    @Environment(\.reduceMotion) private var reduceMotion

    struct Confirmation: Identifiable {
        let id = UUID()
        let action: SimulatorsModel.Action
        let title: String
        let message: String
        let button: String
    }

    var body: some View {
        Group {
            if let problem = model.problem, model.devices.isEmpty {
                EmptyState(doodle: .box, title: "No simulators to show",
                           text: problem == SimulatorsModel.noXcode ? problem
                               : "Xcode's simulator tool didn't answer: \(problem.split(separator: "\n").first ?? "")") {
                    Button("Try Again") { model.load() }.spareButton(.secondary)
                }
            } else if model.devices.isEmpty && model.runtimes.isEmpty && !model.loading {
                EmptyState(doodle: .box, title: "No simulators", text: "Xcode hasn't made any simulators or downloaded any of their systems.")
            } else {
                PageScroll(replay: model.devices.isEmpty) {
                    header.arrives(0)
                    if !model.runtimes.isEmpty { runtimesSection.arrives(1) }
                    devicesSection.arrives(2)
                    Text("Deleting goes through Xcode's simulator tool, not the Trash, so it can't be undone. Xcode makes simulators again when you choose a device to run on, and downloads systems again from Settings > Components.")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .arrives(3)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || !model.working.isEmpty).help("Look Again")
            }
        }
        .alert(item: $confirming) { confirmation in
            Alert(title: Text(confirmation.title), message: Text(confirmation.message),
                  primaryButton: .destructive(Text(confirmation.button)) { model.run(confirmation.action) },
                  secondaryButton: .cancel())
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.loading ? "Asking Xcode" : "Simulators and their systems").contentTransition(.opacity)
                    if model.loading || !model.working.isEmpty { ThinkingDots().transition(.opacity) }
                }
                .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.loading)
                Text(Bytes.text(model.total))
                    .font(.spare(size: 46, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(Motion.count.delay(Beat.settle), value: model.total)
                Text("\(model.devices.count == 1 ? "1 simulator" : "\(model.devices.count) simulators") · \(model.runtimes.count == 1 ? "1 system" : "\(model.runtimes.count) systems")")
                    .font(.spare(size: 12)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if !model.broken.isEmpty {
                Button {
                    let broken = model.broken
                    confirming = Confirmation(action: .delete(broken),
                                              title: "Delete \(broken.count == 1 ? "1 simulator" : "\(broken.count) simulators") that can't run?",
                                              message: "Their system isn't installed any more, so they can't start. Their apps and data are deleted for good.",
                                              button: "Delete")
                } label: {
                    Label("Delete \(model.broken.count) Broken…", systemImage: "trash").padding(.horizontal, 2)
                }
                .spareButton(.primary)
                .controlSize(.large)
                .disabled(!model.working.isEmpty)
            }
        }
    }

    private var runtimesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Systems", subtitle: "The iOS, watchOS, tvOS and visionOS versions simulators run")
            Card {
                ForEach(Array(model.runtimes.enumerated()), id: \.element.id) { index, runtime in
                    if index > 0 { RowDivider().padding(.leading, 56).padding(.trailing, 14) }
                    RuntimeRow(runtime: runtime, users: model.devices.filter { $0.runtime == runtime.name }.count) {
                        confirming = Confirmation(action: .deleteRuntime(runtime), title: "Delete \(runtime.name)?",
                                                  message: "\(runtime.bytes.map(Bytes.text) ?? "Its space") comes back. Simulators that run it stop working until you download it again in Xcode's Settings > Components.",
                                                  button: "Delete")
                    }
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Simulators", subtitle: "Each keeps its own apps and data")
            Card(hoverRows: true) {
                if model.devices.isEmpty {
                    HStack(spacing: 8) {
                        if model.loading { ThinkingDots() }
                        Text(model.loading ? "Looking" : "No simulators.").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { RowDivider().padding(.leading, 56).padding(.trailing, 14) }
                    DeviceRow(device: device, erase: {
                        confirming = Confirmation(action: .erase(device), title: "Erase \(device.name)?",
                                                  message: "Its apps, data and settings are deleted for good. The simulator stays, as if new.",
                                                  button: "Erase")
                    }, delete: {
                        confirming = Confirmation(action: .delete([device]), title: "Delete \(device.name) (\(device.runtime))?",
                                                  message: "Its apps and data are deleted for good. Xcode can make the simulator again, empty.",
                                                  button: "Delete")
                    })
                }
            }
        }
    }
}

private struct RuntimeRow: View {
    let runtime: Simulators.Runtime
    let users: Int
    let delete: () -> Void
    @ObservedObject var model = SimulatorsModel.shared

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, tint: runtime.deletable ? Ink.ink : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(runtime.name).font(.spare(size: 13, weight: .semibold))
                    if let build = runtime.build { Text(build).font(.spare(size: 11)).foregroundStyle(.tertiary) }
                }
                Text(detail).font(.spare(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            SizeText(bytes: runtime.bytes, weight: .semibold)
            if model.working.contains(runtime.id) {
                ThinkingDots().frame(width: 60)
            } else if runtime.deletable {
                Button("Delete…", role: .destructive, action: delete)
                    .spareButton(.secondary).controlSize(.small)
                    .disabled(!model.working.isEmpty)
            } else {
                Tag(text: "Comes with Xcode", tint: .secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var detail: String {
        var parts: [String] = [users == 0 ? "No simulators use it" : users == 1 ? "1 simulator uses it" : "\(users) simulators use it"]
        if let used = runtime.lastUsed { parts.append("last used \(used.ago)") }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        if runtime.name.hasPrefix("watchOS") { return "applewatch" }
        if runtime.name.hasPrefix("tvOS") { return "appletv" }
        if runtime.name.hasPrefix("visionOS") { return "visionpro" }
        return "iphone"
    }
}

private struct DeviceRow: View {
    let device: Simulators.Device
    let erase: () -> Void
    let delete: () -> Void
    @ObservedObject var model = SimulatorsModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, tint: device.isAvailable ? .secondary : Ink.warm, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.spare(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(device.runtime).font(.spare(size: 11)).foregroundStyle(.secondary)
                    if !device.isAvailable { Tag(text: "Can't run", tint: Ink.warm, symbol: "exclamationmark") }
                    if device.state == "Booted" { Tag(text: "Running", tint: Ink.sage) }
                }
                Text(device.problem ?? (device.lastBooted.map { "Last started \($0.ago)" } ?? "Never started"))
                    .font(.spare(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            SizeText(bytes: device.bytes)
            if model.working.contains(device.id) {
                ThinkingDots().frame(width: 24)
            } else {
                Menu {
                    Button("Erase Contents…", action: erase).disabled(device.state == "Booted" || !device.isAvailable)
                    Button("Delete…", role: .destructive, action: delete).disabled(device.state == "Booted")
                    Divider()
                    if let url = device.dataURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .disabled(!model.working.isEmpty)
                .opacity(hovering ? 1 : 0.45)
                .help(device.state == "Booted" ? "Quit the simulator to erase or delete it" : "Erase or delete")
                .accessibilityLabel("Actions for \(device.name)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Erase Contents…", action: erase).disabled(device.state == "Booted" || !device.isAvailable || !model.working.isEmpty)
            Button("Delete…", role: .destructive, action: delete).disabled(device.state == "Booted" || !model.working.isEmpty)
            if let url = device.dataURL {
                Divider()
                FileMenuItems(urls: [url])
            }
        }
        .hoverWash()
        .hoverLag($hovering)
        .padding(.horizontal, RowWash.inset).padding(.vertical, 1)
        .help(device.problem ?? "")
    }

    private var symbol: String {
        let name = device.name.lowercased()
        if name.contains("watch") { return "applewatch" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("tv") { return "appletv" }
        if name.contains("vision") { return "visionpro" }
        return "iphone"
    }
}
