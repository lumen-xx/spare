import SwiftUI
import SpareCore

/// Add-ons in Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox and Safari. Spare only lists them: removing one in its
/// browser is what stops the browser syncing it back. The ones that can read and change every website come first,
/// since they see whatever is typed into them.
@MainActor
final class BrowserExtensionsModel: ObservableObject {
    static let shared = BrowserExtensionsModel()
    @Published private(set) var extensions: [BrowserExtension] = []
    @Published private(set) var loading = false
    private var started = false

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    var everySite: Int { extensions.filter { $0.allSites && $0.enabled != false }.count }

    /// Browser and profile, in the order the browsers are listed, each with its extensions, every-site ones first.
    var groups: [(key: String, browser: BrowserExtension.Browser, profile: String?, items: [BrowserExtension])] {
        var order: [String] = []
        var grouped: [String: [BrowserExtension]] = [:]
        for item in extensions {
            let key = item.browser.rawValue + "|" + (item.profile ?? "")
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let items = grouped[key], let first = items.first else { return nil }
            let sorted = items.sorted { a, b in
                if a.allSites != b.allSites { return a.allSites }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return (key, first.browser, first.profile, sorted)
        }
    }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            let found = await background { () -> [BrowserExtension] in
                // Safari's come from the system's list of app extensions: web extensions, older ones and content blockers.
                let safari = ["com.apple.Safari.web-extension", "com.apple.Safari.extension", "com.apple.Safari.content-blocker"]
                    .map { Shell.run("/usr/bin/pluginkit", ["-mAvvv", "-p", $0], timeout: 20).output }
                    .joined(separator: "\n\n")
                return BrowserExtensions.chromium(home: home) + BrowserExtensions.firefox(home: home) + BrowserExtensions.safari(pluginkit: safari)
            }
            let order = BrowserExtension.Browser.allCases
            self.extensions = found.sorted { (order.firstIndex(of: $0.browser) ?? 0) < (order.firstIndex(of: $1.browser) ?? 0) }
            self.loading = false
        }
    }

    #if DEBUG
    func showDemo(_ demo: [BrowserExtension]) {
        started = true
        extensions = demo
    }
    #endif
}

struct BrowserExtensionsView: View {
    @ObservedObject var model = BrowserExtensionsModel.shared

    var body: some View {
        Group {
            if model.extensions.isEmpty && !model.loading {
                EmptyState(doodle: .sprout, title: "No browser extensions",
                           text: "None of Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox or Safari has extensions added on this Mac.")
            } else {
                PageScroll(replay: model.extensions.isEmpty) {
                    header.arrives(0)
                    ForEach(Array(model.groups.enumerated()), id: \.element.key) { index, group in
                        section(group.browser, profile: group.profile, items: group.items).arrives(index + 1)
                    }
                    Text("Remove an extension in its browser, where it's managed: removing its folder would only bring it back with the next sync. One that can read and change every website sees what you type there, passwords included, so keep those you know and use.")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .arrives(model.groups.count + 1)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(model.loading ? "Looking in your browsers" : "Added to your browsers").contentTransition(.opacity)
                if model.loading { ThinkingDots().transition(.opacity) }
            }
            .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(model.extensions.count == 1 ? "1 extension" : "\(model.extensions.count) extensions")
                .font(.spare(size: 46, weight: .bold))
                .contentTransition(.numericText())
                .animation(Motion.count.delay(Beat.settle), value: model.extensions.count)
            Text(model.everySite == 0 ? "None of them can read every website you visit."
                 : model.everySite == 1 ? "1 can read and change every website you visit."
                 : "\(model.everySite) can read and change every website you visit.")
                .font(.spare(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func section(_ browser: BrowserExtension.Browser, profile: String?, items: [BrowserExtension]) -> some View {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: browser.rawValue, subtitle: profile.map { "Profile: \($0)" }) {
                if let app {
                    Button("Open \(browser.rawValue)") { NSWorkspace.shared.open(app) }
                        .spareButton(.quiet).controlSize(.small)
                        .help(manageHint(browser))
                }
            }
            Card(hoverRows: true) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider().padding(.leading, 56).padding(.trailing, 14) }
                    AddOnRow(item: item)
                }
            }
        }
    }

    private func manageHint(_ browser: BrowserExtension.Browser) -> String {
        switch browser {
        case .safari: "In Safari, choose Safari > Settings, then Extensions."
        case .firefox: "In Firefox, choose Tools > Add-ons and Themes."
        default: "In \(browser.rawValue), open Extensions from its menu."
        }
    }
}

private struct AddOnRow: View {
    let item: BrowserExtension
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: "puzzlepiece.extension", tint: item.allSites && item.enabled != false ? Ink.warm : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.spare(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(item.enabled == false ? .secondary : .primary)
                    if item.allSites { Tag(text: "Every website", tint: Ink.warm, symbol: "eye") }
                    if item.fromStore == false { Tag(text: "Not from the store", tint: Ink.ink) }
                    if item.enabled == false { Tag(text: "Off", tint: .secondary) }
                }
                Text(detail).font(.spare(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let bytes = item.bytes { SizeText(bytes: bytes) }
            if let url = item.url ?? item.containingApp {
                RevealButton(url: url).opacity(hovering ? 1 : 0.0001)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .hoverWash()
        .hoverLag($hovering)
        .padding(.horizontal, RowWash.inset).padding(.vertical, 1)
        .contextMenu {
            if let url = item.url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            if let app = item.containingApp { Button("Show \(app.deletingPathExtension().lastPathComponent) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) } }
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.extensionID, forType: .string)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let version = item.version, !version.isEmpty { parts.append("Version \(version)") }
        if let app = item.containingApp { parts.append("Comes with \(app.deletingPathExtension().lastPathComponent)") }
        if item.allSites { parts.append("Can read and change what you see and type on every site") }
        return parts.isEmpty ? item.extensionID : parts.joined(separator: " · ")
    }
}
