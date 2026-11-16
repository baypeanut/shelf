import AppKit
import Combine
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

@MainActor final class SettingsTests: HistoryTestCase {
    func testOpeningSettingsPreservesPreferencesHistoryAndSelection() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup(); Layout.size = .medium }
        let line = f.line()
        line.hang(try f.image(), quietly: true)
        line.texts.add("Synthetic settings test")
        line.select(try XCTUnwrap(line.newestID))
        let before = f.defaults.persistentDomain(forName: f.suite)! as NSDictionary
        let ids = line.items.map(\.id), selected = line.selectedIDs
        let model = SettingsModel(line: line, allowsSystemChanges: false)
        let controller = SettingsWindowController(model: model)
        XCTAssertTrue(controller.window?.title.contains(AppIdentity.name) == true)
        XCTAssertFalse(model.allowsSystemChanges)
        model.refresh()
        XCTAssertTrue(before.isEqual(to: f.defaults.persistentDomain(forName: f.suite)!))
        XCTAssertEqual(line.items.map(\.id), ids)
        XCTAssertEqual(line.selectedIDs, selected)
        XCTAssertEqual(line.texts.entries.count, 1)
        controller.close()
    }

    func testIgnoredAppsAreAddedFromThePickerAndRunningAppsAndRemovedAgain() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let editor = SourceApp(bundleID: "com.example.editor", name: "Editor"), browser = SourceApp(bundleID: "com.example.browser", name: "Browser")
        let capture = CaptureControl(defaults: f.defaults, frontmost: { nil }, appName: { _ in nil }, ownBundleID: "com.baypeanut.Shelf")
        let model = SettingsModel(line: f.line(), allowsSystemChanges: false, capture: capture)
        var refreshes = 0; let observation = model.objectWillChange.sink { refreshes += 1 }; defer { observation.cancel() }
        var picked: SourceApp? = nil
        model.chooseIgnoredApp = { picked }; model.runningApps = { [editor, browser] }
        XCTAssertTrue(capture.ignoredBundleIDs.isEmpty)
        XCTAssertEqual(model.ignorableRunningApps, [editor, browser])
        // A cancelled panel adds nothing.
        model.addIgnoredApp(); XCTAssertTrue(capture.ignoredBundleIDs.isEmpty)
        picked = editor; model.addIgnoredApp(); model.addIgnoredApp()
        XCTAssertEqual(f.defaults.stringArray(forKey: "captureIgnoredApps"), ["com.example.editor"])
        XCTAssertEqual(model.ignorableRunningApps, [browser])
        XCTAssertGreaterThan(refreshes, 2)
        capture.ignore(browser.bundleID); XCTAssertTrue(model.ignorableRunningApps.isEmpty)
        capture.stopIgnoring(editor.bundleID)
        XCTAssertEqual(capture.ignoredBundleIDs, ["com.example.browser"]); XCTAssertEqual(model.ignorableRunningApps, [editor])
    }

    func testSettingsBindingsApplyAppearanceWithoutMovingFocusOrDroppingHistory() throws {
        let f = try SyntheticFixture(); defer { f.cleanup(); Layout.size = .medium }
        let line = f.line()
        line.hang(try f.image(), quietly: true)
        line.texts.add("Synthetic text")
        line.select(try XCTUnwrap(line.newestID))
        let selected = line.selectedIDs
        var focusRequests = 0
        line.onFocusRequested = { focusRequests += 1 }
        let model = SettingsModel(line: line, allowsSystemChanges: false)
        model.setSize = { line.setSize($0) }
        let size = model.binding(get: { line.size }, set: model.setSize)
        let shelves = model.binding(get: { line.presentation }, set: { line.setPresentation($0, requestFocus: false) })
        size.wrappedValue = .small
        shelves.wrappedValue = .both
        XCTAssertEqual(f.line().size, .small)
        XCTAssertEqual(f.line().presentation, .both)
        XCTAssertEqual(line.items.count, 1)
        XCTAssertEqual(line.texts.entries.count, 1)
        XCTAssertEqual(line.selectedIDs, selected)
        XCTAssertEqual(focusRequests, 0)
    }

    func testCompactMenuIdentifiesTheAppAndKeepsDailyActions() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        let delegate = AppDelegate(line: line, watchesFiles: false)
        let menu = NSMenu(); delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            AppIdentity.name, L("Show line"), L("Library…"), L("Actions") + "…  " + line.keyboardBindings.title(.commandPalette), L("Copy latest image"), L("Open screenshots folder"),
            L("Settings…"), String(format: L("Quit %@"), AppIdentity.name)])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == L("Copy latest image") }).isEnabled)
        XCTAssertEqual(menu.items.filter { $0.submenu != nil }.count, 0)
    }
}
