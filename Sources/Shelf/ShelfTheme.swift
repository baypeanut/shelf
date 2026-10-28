import SwiftUI

/// A quiet native palette. Color identifies a content type, never a surface.
enum ShelfTheme: String, CaseIterable {
    case soft, neutral
    var title: String { self == .soft ? L("Soft colors") : L("Neutral glass") }
    func accent(_ shelf: Shelf) -> Color {
        guard self == .soft else { return .accentColor }
        let light: NSColor
        let dark: NSColor
        switch shelf {
        case .images:
            light = NSColor(red: 0.24, green: 0.43, blue: 0.56, alpha: 1)
            dark = NSColor(red: 0.62, green: 0.77, blue: 0.87, alpha: 1)
        case .texts:
            light = NSColor(red: 0.50, green: 0.39, blue: 0.25, alpha: 1)
            dark = NSColor(red: 0.84, green: 0.73, blue: 0.57, alpha: 1)
        case .links:
            light = NSColor(red: 0.21, green: 0.43, blue: 0.37, alpha: 1)
            dark = NSColor(red: 0.60, green: 0.79, blue: 0.71, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    func wash(_ shelf: Shelf) -> Color {
        self == .soft ? accent(shelf).opacity(0.055) : Color(nsColor: .quaternaryLabelColor).opacity(0.12)
    }
}
