#if !STANDALONE_TESTS
import Foundation
import XCTest
@testable import Shelf

final class InboxTests: XCTestCase {
    private final class Preferences {
        var values: [String: Any]
        var writes = 0
        init(_ values: [String: Any]) { self.values = values }
    }
    private func environment(_ preferences: Preferences, defaults: UserDefaults,
                             prepare: @escaping (URL) throws -> Void = { _ in }) -> Inbox.Environment {
        .init(folder: URL(fileURLWithPath: "/synthetic/Shelf/Screenshots"), defaults: defaults,
              read: { preferences.values[$0] },
              write: { key, value in preferences.writes += 1; preferences.values[key] = value },
              prepareFolder: prepare)
    }
    private func defaults() -> (UserDefaults, String) {
        let suite = "com.baypeanut.Shelf.inbox-tests.\(UUID())"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    func testUnavailableScreenshotFolderLeavesAllSystemSettingsUntouched() {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(["location": "/synthetic/Desktop", "target": "clipboard"])
        let before = preferences.values as NSDictionary
        let env = environment(preferences, defaults: defaults, prepare: { _ in throw HistoryFiles.Failure.unsafeFile })
        XCTAssertFalse(Inbox.apply(environment: env))
        XCTAssertEqual(preferences.writes, 0)
        XCTAssertEqual(preferences.values as NSDictionary, before)
        XCTAssertNil(defaults.dictionary(forKey: "inboxSavedSettings"))
    }
    func testRestoreReturnsOriginalValuesAndRemovesPreviouslyMissingKeys() {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(["location": "/synthetic/Desktop", "target": "clipboard", "show-thumbnail": true])
        let before = preferences.values as NSDictionary
        let env = environment(preferences, defaults: defaults)
        XCTAssertTrue(Inbox.apply(environment: env))
        XCTAssertTrue(Inbox.isApplied(in: env))
        XCTAssertEqual(preferences.values["target-screenshot"] as? String, "file")
        XCTAssertEqual(preferences.values["show-thumbnail"] as? Bool, false)
        Inbox.restore(environment: env)
        XCTAssertEqual(preferences.values as NSDictionary, before)
        XCTAssertNil(defaults.dictionary(forKey: "inboxSavedSettings"))
    }
    func testRestorePreservesScreenshotChoicesChangedWhileShelfWasRunning() {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(["location": "/synthetic/Desktop", "target": "clipboard", "show-thumbnail": true])
        let env = environment(preferences, defaults: defaults)
        XCTAssertTrue(Inbox.apply(environment: env))
        preferences.values["location-screenshot"] = "/synthetic/New Destination"
        preferences.values["target-screenrecording"] = "preview"
        XCTAssertFalse(Inbox.isApplied(in: env))
        Inbox.restore(environment: env)
        XCTAssertEqual(preferences.values["location-screenshot"] as? String, "/synthetic/New Destination")
        XCTAssertEqual(preferences.values["target-screenrecording"] as? String, "preview")
        XCTAssertEqual(preferences.values["location"] as? String, "/synthetic/Desktop")
        XCTAssertNil(preferences.values["location-screenrecording"])
    }
    func testReapplyingAfterCrashKeepsTheFirstRecoverySnapshot() {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(["location": "/synthetic/Desktop", "show-thumbnail": true])
        let before = preferences.values as NSDictionary
        let env = environment(preferences, defaults: defaults)
        XCTAssertTrue(Inbox.apply(environment: env))
        XCTAssertTrue(Inbox.apply(environment: env))
        Inbox.restore(environment: env)
        XCTAssertEqual(preferences.values as NSDictionary, before)
    }
    func testRestoreWithoutSnapshotNeverChangesSystemSettings() {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(["location": "/synthetic/Shelf/Screenshots", "target": "file"])
        let env = environment(preferences, defaults: defaults)
        Inbox.restore(environment: env)
        XCTAssertEqual(preferences.writes, 0)
    }
}
#endif
