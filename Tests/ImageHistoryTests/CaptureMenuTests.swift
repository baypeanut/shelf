import AppKit

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// Menu rows and status wording only: no status item, window or workspace.
@MainActor final class CaptureMenuTests: HistoryTestCase {
    @MainActor private final class Rig {
        let suite = "synthetic-capture-menu-\(UUID().uuidString)"
        let defaults: UserDefaults
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        private(set) var control: CaptureControl!
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            control = CaptureControl(
                defaults: defaults, now: { [unowned self] in self.now }, frontmost: { nil }, appName: { _ in nil },
                ownBundleID: "com.baypeanut.Shelf")
        }
        func cleanup() {
            control.resume()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testRunningCaptureHasNoPausedStatus() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        XCTAssertNil(CaptureMenu.status(rig.control, now: rig.now))
    }

    func testPausedStatusNamesTheRemainingTime() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.pause(for: nil)
        XCTAssertEqual(CaptureMenu.status(rig.control, now: rig.now), L("Clipboard capture paused until you resume"))
        rig.control.pause(for: 300)
        let five = try XCTUnwrap(CaptureMenu.status(rig.control, now: rig.now))
        XCTAssertTrue(five.contains("5"), five)
        rig.now.addTimeInterval(200)
        let two = try XCTUnwrap(CaptureMenu.status(rig.control, now: rig.now))
        XCTAssertTrue(two.contains("2"), two)
        rig.now.addTimeInterval(90)
        let seconds = try XCTUnwrap(CaptureMenu.status(rig.control, now: rig.now))
        XCTAssertTrue(seconds.contains("10"), seconds)
        rig.control.pause(for: 3600)
        let hour = try XCTUnwrap(CaptureMenu.status(rig.control, now: rig.now))
        XCTAssertTrue(hour.contains("1"), hour)
        XCTAssertFalse(hour.contains("60"), hour)
        XCTAssertNotNil(NSImage(systemSymbolName: AppIdentity.pausedStatusSymbol, accessibilityDescription: nil))
    }

    func testMenuOffersPauseChoicesAndSkipThenOnlyResumeWhilePaused() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        var items = CaptureMenu.items(rig.control)
        XCTAssertEqual(items.map(\.title), [L("Pause clipboard capture"), L("Skip next copy")])
        XCTAssertEqual(items[0].submenu?.items.map(\.title), [L("For 5 minutes"), L("For 1 hour"), L("Until I resume")])
        let hour = try XCTUnwrap(items[0].submenu?.items[1])
        _ = hour.target?.perform(hour.action)
        XCTAssertEqual(rig.control.pauseState, .paused(until: rig.now.addingTimeInterval(3600)))
        items = CaptureMenu.items(rig.control)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertEqual(items[1].title, L("Resume capture"))
        _ = items[1].target?.perform(items[1].action)
        XCTAssertFalse(rig.control.isPaused)
        let skip = CaptureMenu.items(rig.control)[1]
        _ = skip.target?.perform(skip.action)
        XCTAssertTrue(rig.control.skipsNextCopy)
        XCTAssertEqual(CaptureMenu.items(rig.control)[1].state, .on)
    }
}
