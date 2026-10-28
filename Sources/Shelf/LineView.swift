import SwiftUI

struct LineView: View {
    @ObservedObject var line: Line
    private let texts: TextHistory
    private let links: LinkHistory
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }
    private static let controlsIDs: [Shelf: UUID] = [.images: UUID(), .texts: UUID(), .links: UUID()]
    private static let headerIDs: [Shelf: UUID] = [.images: UUID(), .texts: UUID(), .links: UUID()]
    static let searchSummaryID = UUID()
    static let searchPanelID = UUID()
    private static let noticeID = UUID()
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 0) {
                ForEach(line.presentation.shelves, id: \.self) { shelf in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.55)).frame(height: 0.5)
                            }.allowsHitTesting(false)
                        if shelf == .texts { TextShelfView(line: line, texts: texts, width: width) }
                        else if shelf == .links { LinkShelfView(line: line, links: links, width: width) }
                        else {
                            if line.displayItems.isEmpty {
                                ShelfEmptyState(icon: "photo", title: line.shelfSearch?.isActive(for: .image) == true || line.favoritesOnly ? L("No matching items") : L("Take a screenshot and it will hang here"))
                                    .position(x: width / 2, y: Layout.panelHeight / 2 + 8)
                            }
                            let displayed = line.displayItems
                            let quickNumbers = line.activeShelf == .images && line.searchEditingShelf == nil
                                ? Dictionary(uniqueKeysWithValues: line.quickSelectionIDs.enumerated().map { ($0.element, $0.offset + 1) }) : [:]
                            let range = Layout.visibleRange(count: displayed.count, width: width, offset: line.scrollOffset)
                            ForEach(range.map { (index: $0, item: displayed[$0]) }, id: \.item.id) { index, item in
                                let x = Layout.x(index: index, scrollOffset: line.scrollOffset)
                                let ropeY = Layout.ropeY(x: x, width: width)
                                PeggedView(item: item, line: line, quickNumber: quickNumbers[item.id])
                                    .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                                    .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                            }
                        }
                        HStack(spacing: 6) {
                            Button { line.focusShelf(shelf) } label: {
                                Label(shelf.title, systemImage: shelf.icon)
                            }.padding(.horizontal, 9).padding(.vertical, 6)
                                .foregroundStyle(line.activeShelf == shelf ? line.theme.accent(shelf) : Color.secondary)
                                .background(line.activeShelf == shelf ? line.theme.accent(shelf).opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .accessibilityAddTraits(line.activeShelf == shelf ? .isSelected : [])
                                .help(L("Tab switches the active shelf"))
                                .background(hitRect(Self.headerIDs[shelf]!))
                            Spacer()
                            if line.activeShelf == shelf { ShelfControls(line: line).background(hitRect(Self.controlsIDs[shelf]!)) }
                        }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).controlSize(.small)
                            .padding(.horizontal, 16).padding(.top, 8)
                    }.frame(width: width, height: Layout.panelHeight).clipped()
                }
            }.frame(width: width, height: line.panelHeight, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 0.5) }
                .overlay(alignment: .top) {
                    if width >= 700, line.isShelfSearchActive, line.searchEditingShelf == nil {
                        ShelfSearchSummary(line: line, shelf: line.activeShelf)
                            .frame(maxWidth: min(360, width - 380))
                            .fixedSize(horizontal: false, vertical: true)
                            .background(hitRect(Self.searchSummaryID))
                            .padding(.top, 11)
                    }
                }
                .overlay(alignment: .center) {
                    if let shelf = line.searchEditingShelf,
                       line.isShelfSearchActive {
                        ShelfSearchBar(line: line, shelf: shelf).id(shelf)
                            .frame(width: max(0, min(560, width - 32)))
                            .background(hitRect(Self.searchPanelID))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    ShelfNotice(line: line)
                        .background(hitRect(Self.noticeID))
                }
                .onAppear { line.setViewportWidth(width) }
                .onChange(of: width) { _, value in line.setViewportWidth(value) }
        }
        .onPreferenceChange(HitRectsKey.self) { line.hitRects = $0; line.shelfHitGeometryUpdateCount += 1 }
    }
    private func hitRect(_ id: UUID) -> some View {
        GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [id: g.frame(in: .global)]) }
    }
}

/// High-frequency row scrolling must not invalidate the other two rows just
/// to update a selection count or a notice. Observe their models at the small
/// controls that actually depend on them.
private struct ShelfControls: View {
    @ObservedObject var line: Line
    @ObservedObject private var texts: TextHistory
    @ObservedObject private var links: LinkHistory
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }
    var body: some View {
        HStack(spacing: 6) {
            if line.activeSelectionCount > 1 {
                Text(String(format: L("%d selected"), line.activeSelectionCount)).monospacedDigit()
                iconButton("doc.on.doc", L("Copy")) { line.copySelection() }
                iconButton("trash", L("Move to Trash…")) { line.onTrashRequested?() }
            }
            Button { line.onCommandsRequested?() } label: {
                Label(L("Actions"), systemImage: "command").frame(minHeight: 26)
            }.help(L("Actions") + " · " + line.keyboardBindings.title(.commandPalette))
                .accessibilityLabel(L("Actions")).accessibilityIdentifier("shelf-actions")
            iconButton("magnifyingglass", L("Search shelves")) { line.beginShelfSearch() }.disabled(line.shelfSearch == nil)
            iconButton("arrow.left.arrow.right", L("Switch shelf")) { line.switchShelf() }
            iconButton("rectangle.split.2x1", L("Both shelves")) { line.toggleBothShelves() }
            iconButton("square.grid.2x2", L("Library…")) { line.onLibraryRequested?() }
            Menu {
                Toggle(L("Favorites"), isOn: Binding(get: { line.activeFavoritesOnly }, set: { line.setActiveFavorites($0) }))
                Button(L("Export copies…")) { line.onExportRequested?() }.disabled(line.activeSelectionCount == 0)
                Button(L("Move to Trash…")) { line.onTrashRequested?() }.disabled(line.activeSelectionCount == 0)
                Divider()
                Button(L("Settings…")) { line.onSettingsRequested?() }
            } label: { Image(systemName: "ellipsis").frame(minWidth: 26, minHeight: 26) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Shelf settings"))
        }.padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }
    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(minWidth: 26, minHeight: 26) }
            .accessibilityLabel(title).help(title)
    }
}

private struct ShelfNotice: View {
    @ObservedObject var line: Line
    @ObservedObject private var texts: TextHistory
    @ObservedObject private var links: LinkHistory
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }
    var body: some View {
        if let message = (line.activeShelf == .texts ? (texts.notice ?? line.notice) : line.activeShelf == .links ? (links.notice ?? line.notice) : line.notice) {
            HStack { Text(message); Button(L("Dismiss")) { line.notice = nil; texts.notice = nil; links.notice = nil } }
                .font(.system(size: 11)).padding(7).background(.regularMaterial, in: Capsule())
        }
    }
}

/// A legible empty state with no decorative chrome or disabled-looking pill.
struct ShelfEmptyState: View {
    let icon: String
    let title: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
        }.padding(.horizontal, 24).accessibilityElement(children: .combine)
    }
}
struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}
