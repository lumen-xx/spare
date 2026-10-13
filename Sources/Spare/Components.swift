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
        case .rebuilds: .green
        case .redownloads: .blue
        case .disposable: .teal
        case .review: .orange
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
        Text(safety.label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(safety.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(safety.color.opacity(0.13), in: Capsule())
            .help(safety.help)
    }
}

/// A square check box with a mixed state, for a group of items.
struct CheckBox: View {
    let state: CheckState
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(state == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(state == .on ? "checked" : state == .mixed ? "partly checked" : "unchecked")
    }
}

struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// A quiet rounded panel that groups rows.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct SizeText: View {
    let bytes: Int64?
    var weight: Font.Weight = .medium
    var body: some View {
        Text(bytes.map(Bytes.text) ?? "—")
            .font(.system(size: 12.5, weight: weight).monospacedDigit())
            .foregroundStyle(bytes == nil ? .tertiary : .primary)
    }
}

struct RevealButton: View {
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Show in Finder")
    }
}

/// Asks for Full Disk Access, saying plainly what is missed without it.
struct FullDiskAccessNote: View {
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: "lock", tint: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Spare can't see everything yet").font(.system(size: 13, weight: .semibold))
                Text(compact ? "Locked folders stay closed until Spare has Full Disk Access."
                             : "Without Full Disk Access, macOS hides Downloads, Documents, Desktop, iPhone backups, Mail and other apps' data. Spare only reads; it never changes anything without asking.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer(minLength: 8)
            Button("Open Settings…") { Permissions.openFullDiskAccessSettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.18), lineWidth: 1))
    }
}

/// What just happened, with Undo, at the bottom of the window.
struct BannerView: View {
    @ObservedObject var shared = Shared.shared
    @State private var showingProblems = false

    var body: some View {
        if let banner = shared.banner {
            HStack(spacing: 12) {
                Image(systemName: banner.problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(banner.problems.isEmpty ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title).font(.system(size: 13, weight: .semibold))
                    if let detail = banner.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                if !banner.problems.isEmpty {
                    Button("Details") { showingProblems = true }
                        .popover(isPresented: $showingProblems) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(banner.problems, id: \.self) { Text($0).font(.system(size: 12)).textSelection(.enabled) }
                            }.padding(14).frame(maxWidth: 420)
                        }
                }
                if let session = banner.session {
                    Button("Undo") { HistoryModel.shared.putBack(session: session) }
                }
                if banner.offerEmptyTrash {
                    Button("Empty Trash…") { shared.emptyTrash() }
                }
                Button { withAnimation { shared.banner = nil } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .modifier(FloatingSurface())
            .padding(16)
            .frame(maxWidth: 760)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(banner.id)
        }
    }
}

/// Liquid Glass where macOS has it, a material before.
struct FloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

extension Date {
    var ago: String { Catalog.ago(self, from: Date()) }
}
