import SwiftUI

/// A clean image card on the shelf. Selection and drag behavior stay native;
/// decorative physics never compete with the content.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line
    let quickNumber: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var hovering = false

    private var selected: Bool { line.selectedIDs.contains(item.id) }
    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.cardOffsetBelowTop).accessibilityHidden(true)
            card
        }
        .offset(y: arrived ? 0 : 4)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: arrived)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title ?? item.url.lastPathComponent)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { line.select(item.id); line.focusShelf(.images); line.copyAction(item.id) }
        .accessibilityAction(named: Text(L("Preview"))) { line.open(item.id) }
        .accessibilityAction(named: Text(item.pinned ? L("Unpin") : L("Pin favorite"))) { line.pinFromUI(item.id) }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = Layout.cardWidth - 14, maxH = Layout.photoMaxHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The card around the photo: the photo plus the glass inset.
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + Frame.inset * 2, height: p.height + Frame.inset * 2)
    }

    /// Shared top inset used by preview and native drag geometry.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    private var photoSize: CGSize { Self.photoSize(for: item.thumb?.size ?? CGSize(width: 136, height: 104)) }

    private var card: some View {
        Image(nsImage: item.thumb ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: photoSize.width, height: photoSize.height)
            // Concentric corners: the photo's radius is the frame's minus the
            // inset, the way macOS rounds nested shapes.
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay {
                // A recording says so with a play button over its first frame.
                if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassFrame(circle: true)
                        .allowsHitTesting(false)
                }
            }
            .padding(Frame.inset)
            .glassFrame(cornerRadius: Frame.radius)
            .background(line.theme.wash(.images), in: RoundedRectangle(cornerRadius: Frame.radius))
            .shadow(color: .black.opacity(hovering ? 0.09 : 0.04), radius: hovering ? 5 : 2, y: 2)
            // Holding presses the photo in slowly, so a long press feels like
            // it is building up to something.
            .scaleEffect(pressed ? 0.985 : 1, anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top. A
                // cross sends a file in Shelf's folder to the Trash; for a
                // file anywhere else it only hides it from the line.
                Image(systemName: item.managedCopy ? "xmark" : "eye.slash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .glassFrame(circle: true)
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Frame.radius).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                FavoriteBadge(pinned: item.pinned, visible: (hovering || line.focusedID == item.id) && !dragging)
            }
            .overlay(alignment: .bottom) {
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 2)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: Layout.cardWidth)
                        .background(.regularMaterial, in: Capsule()).offset(y: 18).allowsHitTesting(false)
                }
            }
            .overlay(GrabArea(item: item, line: line))
            .overlay(alignment: .bottomLeading) { QuickSelectionBadge(number: quickNumber) }
            .overlay(alignment: .bottom) {
                if copied {
                    CopyBadge(title: L("Copied"))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }

    private func arrive() {
        _ = line.consumeArrival(item.id)
        arrived = true
    }
}

enum Frame {
    static let radius: CGFloat = 10
    static let inset: CGFloat = 4
}

extension View {
    /// Native materials follow appearance and accessibility preferences.
    /// One quiet separator replaces decorative highlights.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}


struct FavoriteBadge: View {
    let pinned: Bool
    let visible: Bool
    var body: some View {
        Image(systemName: pinned ? "pin.fill" : "pin")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(pinned ? Color.accentColor : Color.primary)
            .frame(width: 20, height: 20).glassFrame(circle: true).padding(3)
            .opacity(visible ? 1 : 0).allowsHitTesting(false)
    }
}
struct CopyBadge: View {
    let title: String
    var body: some View {
        Label(title, systemImage: "checkmark").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary).fixedSize().padding(.horizontal, 10).padding(.vertical, 5)
            .glassFrame(capsule: true).offset(y: 16).allowsHitTesting(false)
            .transition(.opacity.combined(with: .offset(y: -4)))
    }
}
