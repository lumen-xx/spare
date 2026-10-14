import SwiftUI
import SpareCore

/// The page list, drawn by Spare rather than as a system list so it has Spare's look: its tint on the chosen page,
/// quiet grey icons in one column, sections that fold away, and the disk across the bottom. The arrow keys move between pages.
struct Sidebar: View {
    @ObservedObject var navigation = Navigation.shared
    @ObservedObject var cleanup = CleanupModel.shared
    /// Titles of folded sections, kept between launches; every section starts unfolded.
    @AppStorage("sidebarFoldedSections") private var foldedText = ""
    @FocusState private var focused: Bool
    @Environment(\.reduceMotion) private var reduceMotion

    private var folded: Set<String> { Set(foldedText.split(separator: ",").map(String.init)) }

    /// Pages that show, in order, for the arrow keys.
    private var visible: [Page] {
        Page.sections.flatMap { title, pages in folded.contains(title) ? [] : pages } + [.history, .settings]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // The first pages, what Spare is mostly for, stand on their own at the top without a title,
                        // as History and Settings do at the bottom.
                        if let (_, top) = Page.sections.first {
                            VStack(spacing: 1) { ForEach(top) { row($0) } }
                        }
                        ForEach(Page.sections.dropFirst(), id: \.0) { title, pages in
                            section(title, pages)
                        }
                        VStack(spacing: 1) {
                            row(.history)
                            row(.settings)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4).padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                // Rows fade out under the title bar and above the disk rather than ending at a hard line.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    }
                }
                .onChange(of: navigation.page) { _, page in
                    unfold(sectionOf(page))
                    withAnimation(reduceMotion ? nil : Motion.settle) { scroller.scrollTo(page, anchor: nil) }
                }
                .onAppear {
                    unfold(sectionOf(navigation.page))
                    // After the first layout, so the row exists to scroll to.
                    let page = navigation.page
                    DispatchQueue.main.async { scroller.scrollTo(page, anchor: .center) }
                }
            }
            // Only the page list takes the arrow keys, never the disk card's button.
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            // The disk across the sidebar's whole width, under a hairline.
            DiskSummary()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { RowDivider() }
        }
    }

    // MARK: Sections

    private func section(_ title: String, _ pages: [Page]) -> some View {
        let isFolded = folded.contains(title)
        return VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: title, count: pages.count, folded: isFolded) { fold(title, !isFolded) }
            if !isFolded {
                // A thin line down the section's pages, a little in from its title, so they read as one group;
                // beside the chosen page it takes the tint.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pages) { page in
                        HStack(spacing: 4) {
                            Guide(chosen: navigation.page == page)
                            row(page)
                        }
                    }
                }
                .padding(.leading, 9)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func sectionOf(_ page: Page) -> String? { Page.sections.first { $0.1.contains(page) }?.0 }

    private func fold(_ title: String, _ fold: Bool) {
        var set = folded
        if fold { set.insert(title) } else { set.remove(title) }
        withAnimation(reduceMotion ? Motion.calm : Motion.expand) { foldedText = set.sorted().joined(separator: ",") }
    }

    /// The chosen page's section always shows.
    private func unfold(_ title: String?) {
        if let title, folded.contains(title) { fold(title, false) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard let index = visible.firstIndex(of: navigation.page) else { return .ignored }
        let next = index + step
        guard visible.indices.contains(next) else { return .handled }
        navigation.page = visible[next]
        return .handled
    }

    // MARK: Rows

    private func row(_ page: Page) -> some View {
        SidebarRow(page: page, chosen: navigation.page == page, badge: badge(for: page)) {
            navigation.page = page
            focused = true
        }
        .id(page)
    }

    private func badge(for page: Page) -> String? {
        guard page == .cleanup, !cleanup.isScanning, cleanup.scannedAt != nil, cleanup.foundBytes > 0 else { return nil }
        return Bytes.text(cleanup.foundBytes)
    }
}

/// The line beside a section's pages: hairline grey, and the tint beside the chosen page.
private struct Guide: View {
    let chosen: Bool

    var body: some View {
        Capsule()
            .fill(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(Ink.line))
            .frame(width: chosen ? 2 : 1)
            .padding(.vertical, chosen ? 5 : 0)
            .frame(width: 2)
            .animation(Motion.settle, value: chosen)
            .accessibilityHidden(true)
    }
}

/// A section's title, which folds it away; the chevron shows only while the pointer is on it.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.spare(size: 11.5, weight: .bold))
                    .tracking(0.2)
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(Ink.pencil))
                Spacer(minLength: 4)
                // Folded, it says how many pages it holds.
                if folded {
                    Text("\(count)").font(.spare(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Ink.wash))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .opacity(hovering ? 1 : 0)
                    .animation(Motion.settle, value: hovering)
            }
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(folded ? "folded" : "unfolded")
        .accessibilityHint(folded ? "Shows its pages" : "Hides its pages")
    }
}

private struct SidebarRow: View {
    let page: Page
    let chosen: Bool
    let badge: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.tintText) private var tintText

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(chosen ? (tintText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)) : AnyShapeStyle(Ink.pencil))
                    .frame(width: 20, height: 18)
                Text(page.rawValue)
                    .font(.spare(size: 13, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.88)))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.spare(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(chosen ? (tintText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                RoundedRectangle.continuous(8)
                    .fill(chosen ? AnyShapeStyle(.tint.opacity(0.17)) : AnyShapeStyle(hovering ? Ink.wash : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.settle, value: chosen)
        .accessibilityLabel(page.rawValue)
        .accessibilityValue(badge ?? "")
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}
