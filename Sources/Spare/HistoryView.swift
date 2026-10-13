import SwiftUI
import SpareCore

struct HistoryView: View {
    @ObservedObject var model = HistoryModel.shared
    @ObservedObject var shared = Shared.shared

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                EmptyNote(symbol: "clock.arrow.circlepath", title: "Nothing moved yet",
                          text: "Everything Spare moves to the Trash is listed here, so you can put it back until the Trash is emptied.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Put things back as long as they're still in the Trash. Once the Trash is emptied they're gone for good.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        ForEach(model.sessions) { session in SessionView(session: session) }
                    }
                    .padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 90)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.top)
                .id(model.revision)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { shared.emptyTrash() } label: { Label("Empty Trash…", systemImage: "trash.slash") }
                    .help("Empty the Trash to free the space")
            }
        }
        .onAppear { model.refresh() }
    }
}

struct SessionView: View {
    let session: TrashSession
    @ObservedObject var model = HistoryModel.shared
    @State private var expanded = false

    var body: some View {
        let states = session.records.map(\.state)
        let inTrash = states.filter { $0 == .inTrash }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 14, weight: .semibold))
                    Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.records.count == 1 ? "1 item" : "\(session.records.count) items")\(session.bytes > 0 ? " · " + Bytes.text(session.bytes) : "")")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(inTrash == 0 ? (states.contains(.putBack) ? "Put back" : "Trash emptied")
                     : inTrash == states.count ? "In the Trash" : "\(inTrash) still in the Trash")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button("Put Back All") { model.putBack(session: session.id) }
                    .controlSize(.small).disabled(inTrash == 0)
                Menu {
                    Button("Forget This") { model.forget(session.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            }
            Panel {
                let shown = expanded ? session.records : Array(session.records.prefix(5))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider().padding(.leading, 40) }
                    RecordRow(record: record)
                }
                if session.records.count > 5 {
                    Divider()
                    Button(expanded ? "Show fewer" : "Show all \(session.records.count)") { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.borderless).font(.system(size: 12)).padding(10)
                }
            }
        }
    }
}

struct RecordRow: View {
    let record: TrashRecord
    @ObservedObject var model = HistoryModel.shared

    var body: some View {
        let state = record.state
        HStack(spacing: 10) {
            Image(systemName: state == .inTrash ? "trash" : state == .putBack ? "arrow.uturn.backward.circle" : "xmark.circle")
                .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: record.original).lastPathComponent).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Text(Catalog.tilde(URL(fileURLWithPath: record.original), home: home))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let bytes = record.bytes, bytes > 0 { SizeText(bytes: bytes) }
            switch state {
            case .inTrash:
                Button("Put Back") {
                    let problems = model.putBack([record])
                    if !problems.isEmpty { Shared.shared.banner = .init(title: "Couldn't put it back", detail: nil, problems: problems) }
                }
                .controlSize(.small)
            case .putBack:
                Text("Put back").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .gone:
                Text("Deleted").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}
