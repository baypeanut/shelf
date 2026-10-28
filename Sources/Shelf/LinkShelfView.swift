import SwiftUI

struct LinkShelfView: View {
    let line: Line
    @ObservedObject var links: LinkHistory
    let width: CGFloat
    var body: some View {
        LinkShelfContents(line: line, links: links, width: width, renderState: ShelfRenderState(line: line, shelf: .links)).equatable()
    }
}

private struct LinkShelfContents: View, Equatable {
    let line: Line
    @ObservedObject var links: LinkHistory
    let width: CGFloat
    let renderState: ShelfRenderState
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line === rhs.line && lhs.links === rhs.links && lhs.width == rhs.width && lhs.renderState == rhs.renderState
    }
    var body: some View {
        let entries = links.displayEntries
        let quickNumbers = Dictionary(uniqueKeysWithValues: renderState.quickIDs.enumerated().map { ($0.element, $0.offset + 1) })
        let range = Layout.visibleRange(count: entries.count, width: width, offset: links.scrollOffset)
        let payload = range.map { VisibleLinkPayload(id: entries[$0].id, thumbnailPath: entries[$0].thumbnailPath) }
        ZStack(alignment: .topLeading) {
            if entries.isEmpty {
                ShelfEmptyState(icon: "link", title: renderState.searchActive ? L("No matching items") : links.favoritesOnly ? L("No matching items") + " · " + renderState.pinnedHint : L("Copied web addresses appear here when link capture is enabled"))
                    .position(x: width / 2, y: Layout.panelHeight / 2 + 8)
            }
            ForEach(range.map { (index: $0, entry: entries[$0]) }, id: \.entry.id) { index, entry in
                LinkCard(entry: entry, line: line, links: links, renderState: renderState, quickNumber: quickNumbers[entry.id])
                    .frame(width: Layout.cardWidth, height: Layout.panelHeight - Layout.ropeTop, alignment: .top)
                    .position(x: Layout.x(index: index, scrollOffset: links.scrollOffset),
                        y: Layout.ropeTop - Layout.pinAbove + (Layout.panelHeight - Layout.ropeTop) / 2)
            }
        }.onAppear { requestThumbnails(payload) }
            .onChange(of: payload) { _, value in requestThumbnails(value) }
    }
    private func requestThumbnails(_ payload: [VisibleLinkPayload]) {
        links.thumbnails.request(payload.compactMap { $0.thumbnailPath.map { URL(fileURLWithPath: $0) } }, pixels: 320)
        line.onLinkItemsVisible?(payload.map(\.id))
    }
}

private struct LinkCard: View {
    let entry: LibraryRecord
    let line: Line
    @ObservedObject var links: LinkHistory
    let renderState: ShelfRenderState
    let quickNumber: Int?
    @State private var hovering = false
    private var thumbnail: NSImage? { entry.thumbnailPath.flatMap { links.thumbnails.image(for: URL(fileURLWithPath: $0), pixels: 320) } }
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5 * Layout.scale) {
                ZStack {
                    renderState.theme.wash(.links)
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else { Image(systemName: LinkIdentity.youtubeID(entry.linkURL ?? URL(string: "https://invalid.example")!) == nil ? "link" : "play.rectangle").font(.system(size: 24)).foregroundStyle(.secondary) }
                }.frame(width: Layout.cardWidth - 16 * Layout.scale, height: 38 * Layout.scale).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                Text(entry.displayTitle).font(.system(size: 11 * Layout.scale, weight: .semibold)).lineLimit(2).frame(height: 26 * Layout.scale, alignment: .topLeading)
                Text(entry.author ?? entry.linkURL?.host ?? L("Link")).font(.system(size: 10 * Layout.scale)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(8 * Layout.scale).padding(.top, 6 * Layout.scale).frame(width: Layout.cardWidth, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Frame.radius))
                .background(renderState.theme.wash(.links), in: RoundedRectangle(cornerRadius: Frame.radius))
                .overlay(RoundedRectangle(cornerRadius: Frame.radius).strokeBorder(links.selectedIDs.contains(entry.id) ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: links.selectedIDs.contains(entry.id) ? 2 : 0.5))
                .overlay(alignment: .topLeading) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 20, height: 20).glassFrame(circle: true).padding(3).opacity(hovering ? 1 : 0).allowsHitTesting(false) }
                .overlay(alignment: .topTrailing) { FavoriteBadge(pinned: entry.favorite, visible: hovering || links.focusedID == entry.id) }
                .overlay(LinkGrabArea(entry: entry, line: line, links: links))
                .overlay(alignment: .bottomLeading) { QuickSelectionBadge(number: quickNumber) }
                .overlay(alignment: .bottom) { if links.copiedIDs.contains(entry.id) { CopyBadge(title: L("Link copied")) } }
                .shadow(color: .black.opacity(hovering ? 0.09 : 0.04), radius: hovering ? 5 : 2, y: 2)
                .onHover { hovering = $0 }
        }.accessibilityElement(children: .ignore).accessibilityLabel(entry.displayTitle)
            .accessibilityAddTraits(links.selectedIDs.contains(entry.id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { links.select(entry.id, width: line.viewportWidth); line.focusShelf(.links); links.copyAction(entry.id) }
            .accessibilityAction(named: Text(L("Preview"))) { line.onLinkPreviewRequested?(entry.id) }
            .accessibilityAction(named: Text(entry.favorite ? L("Unpin") : L("Pin favorite"))) { links.togglePin(entry.id) }
            .background(GeometryReader { geo in Color.clear.preference(key: HitRectsKey.self, value: [entry.id: geo.frame(in: .global)]) })
    }
}

private struct LinkGrabArea: NSViewRepresentable {
    let entry: LibraryRecord
    let line: Line
    let links: LinkHistory
    func makeNSView(context: Context) -> GrabView { let view = GrabView(); configure(view); return view }
    func updateNSView(_ view: GrabView, context: Context) { configure(view) }
    private func configure(_ view: GrabView) {
        let id = entry.id
        view.selectionMode = links.selecting; view.appCopy = true; view.allowsMove = false
        view.payloadProvider = { links.dragItems(id) }
        view.onDeleteItems = { links.trash($0.map(\.id)) }
        view.onPin = { links.select(id, width: line.viewportWidth); line.focusShelf(.links); links.togglePin(id) }
        view.onClick = { flags in
            links.select(id, toggle: flags.contains(.command), extending: flags.contains(.shift), width: line.viewportWidth)
            if !links.selecting && flags.intersection([.command, .shift]).isEmpty { links.copyAction(id) }
            line.focusShelf(.links)
        }
        view.onDoubleClick = { line.onLinkPreviewRequested?(id) }; view.onLongPress = { line.onLinkPreviewRequested?(id) }
        view.onDiscard = { links.removeFromShelf(id) }
        view.onPressChange = { line.pressedID = $0 ? id : nil; if $0 { line.focusShelf(.links, requestFocus: false) } }
        view.onDragStart = { line.draggingID = id }; view.onDragEnd = { line.draggingID = nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy")) { links.copyAction(id) })
            menu.addItem(ClosureMenuItem(L("Preview")) { line.onLinkPreviewRequested?(id) })
            menu.addItem(ClosureMenuItem(entry.favorite ? L("Unpin") : L("Pin favorite")) { links.togglePin(id) })
            menu.addItem(ClosureMenuItem(L("Name and pin…")) { line.onNameAndPinRequested?(id) })
            menu.addItem(ClosureMenuItem(L("Open in browser")) { if let url = entry.linkURL { NSWorkspace.shared.open(url) } })
            menu.addItem(ClosureMenuItem(L("Move to Trash…")) { links.select(id, width: line.viewportWidth); line.focusShelf(.links); line.onTrashRequested?() })
            menu.addItem(ClosureMenuItem(L("Library…")) { line.onLibraryRequested?() })
            return menu
        }
    }
}
