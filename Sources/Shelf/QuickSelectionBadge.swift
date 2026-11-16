import SwiftUI

struct QuickSelectionBadge: View {
    let number: Int?
    var body: some View {
        if let number {
            Text(String(number)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 18, height: 18)
                .shelfBadge(RoundedRectangle(cornerRadius: ShelfTheme.Radius.badge))
                .padding(5).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
