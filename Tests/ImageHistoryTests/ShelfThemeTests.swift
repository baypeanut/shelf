import SwiftUI
import XCTest
@testable import Shelf

@MainActor
final class ShelfThemeTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { ShelfAccessibility.current = { ShelfAccessibility.system } }
    }

    func testDefaultsAreTheOrdinaryHairlineAndMaterial() {
        ShelfAccessibility.current = { ShelfAccessibility() }
        XCTAssertEqual(ShelfTheme.hairlineWidth, 0.5)
        XCTAssertEqual(ShelfTheme.hairline, Color(nsColor: .separatorColor).opacity(0.5))
        XCTAssertEqual(ShelfTheme.selectedFill, Color.primary.opacity(0.08))
        XCTAssertNotNil(ShelfTheme.stateChange())
    }

    func testIncreaseContrastStrengthensEdgesAndSelection() {
        ShelfAccessibility.current = { ShelfAccessibility(increaseContrast: true) }
        XCTAssertEqual(ShelfTheme.hairlineWidth, 1)
        XCTAssertEqual(ShelfTheme.hairline, Color(nsColor: .labelColor).opacity(0.6))
        XCTAssertEqual(ShelfTheme.selectedFill, Color.primary.opacity(0.16))
    }

    func testReduceMotionRemovesStateAnimation() {
        ShelfAccessibility.current = { ShelfAccessibility(reduceMotion: true) }
        XCTAssertNil(ShelfTheme.stateChange())
    }

    func testEveryStoredThemeStillReads() {
        // The setting is gone; a preference written by an earlier build must still decode.
        XCTAssertNotNil(ShelfTheme(rawValue: "soft"))
        XCTAssertNotNil(ShelfTheme(rawValue: "neutral"))
    }

    func testRadiiNestFromPanelToBadge() {
        XCTAssertGreaterThan(ShelfTheme.Radius.panel, ShelfTheme.Radius.card)
        XCTAssertGreaterThan(ShelfTheme.Radius.card, ShelfTheme.Radius.control)
        XCTAssertGreaterThan(ShelfTheme.Radius.control, ShelfTheme.Radius.badge)
        XCTAssertEqual(Frame.radius, ShelfTheme.Radius.card)
    }
}
