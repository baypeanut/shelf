import SwiftUI

/// The display settings under System Settings → Accessibility that change how
/// Shelf's own surfaces are drawn. Stock controls follow them without help.
struct ShelfAccessibility: Equatable {
    var reduceMotion = false
    var increaseContrast = false
    var reduceTransparency = false

    /// Replaced in tests and by the screen renderer.
    @MainActor static var current: () -> ShelfAccessibility = { system }

    @MainActor static var system: ShelfAccessibility {
        let workspace = NSWorkspace.shared
        return ShelfAccessibility(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
    }
}

/// The few values Shelf's custom surfaces share. Everything is a system
/// colour, the system accent or a system material; nothing here is a palette.
///
/// The two cases are the choices of a setting that no longer exists. They are
/// kept so a stored preference still reads, and they draw the same.
enum ShelfTheme: String, CaseIterable {
    case soft, neutral

    /// Corner radii, from the outside in: a floating panel, a card on it, a
    /// control or thumbnail inside a card, a badge.
    enum Radius {
        static let panel: CGFloat = 12
        static let card: CGFloat = 8
        static let control: CGFloat = 6
        static let badge: CGFloat = 4
    }

    /// Selection, focus and the pinned mark use the accent the user chose.
    static var accent: Color { .accentColor }

    /// A divider or card edge. Increase Contrast draws it at full strength.
    @MainActor static var hairline: Color {
        ShelfAccessibility.current().increaseContrast
            ? Color(nsColor: .labelColor).opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.5)
    }
    @MainActor static var hairlineWidth: CGFloat { ShelfAccessibility.current().increaseContrast ? 1 : 0.5 }

    /// The fill of a card that holds copied content.
    static var card: Color { Color(nsColor: .controlBackgroundColor) }

    /// The quiet fill behind a selected header or a key hint.
    @MainActor static var selectedFill: Color { Color.primary.opacity(ShelfAccessibility.current().increaseContrast ? 0.16 : 0.08) }

    /// What floats over content: a badge, a notice, the search panel. A
    /// material, or the opaque window colour under Reduce Transparency.
    @MainActor static var overlay: AnyShapeStyle {
        ShelfAccessibility.current().reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    }

    /// No animation under Reduce Motion, otherwise the short ease macOS uses
    /// for a control changing state.
    @MainActor static func stateChange(_ duration: Double = 0.15) -> Animation? {
        ShelfAccessibility.current().reduceMotion ? nil : .easeOut(duration: duration)
    }
}

extension View {
    /// A floating badge over a card: the overlay fill and one hairline.
    func shelfBadge<S: InsettableShape>(_ shape: S) -> some View {
        background(ShelfTheme.overlay, in: shape)
            .overlay(shape.strokeBorder(ShelfTheme.hairline, lineWidth: ShelfTheme.hairlineWidth))
    }
}
