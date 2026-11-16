import AppKit

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

@MainActor private final class CaptureClipboard: ClipboardSource {
    var count = 810000
    var values = [[NSPasteboard.PasteboardType: Data]]()
    var changeCount: Int { count }
    var itemTypes: [[NSPasteboard.PasteboardType]] { values.map { Array($0.keys) } }
    func data(forType type: NSPasteboard.PasteboardType, at index: Int) -> Data? { values[index][type] }
    func copy(_ text: String) {
        count += 1
        values = [[.string: Data(text.utf8)]]
    }
    func copy(image: Data) {
        count += 1
        values = [[.png: image]]
    }
}

/// A synthetic clock, an isolated preferences suite and an injected frontmost
/// application: nothing here reads the workspace or the real pasteboard.
@MainActor final class CaptureControlTests: HistoryTestCase {
    @MainActor private final class Rig {
        let suite = "synthetic-capture-\(UUID().uuidString)"
        let defaults: UserDefaults
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var front: SourceApp? = SourceApp(bundleID: "com.example.editor", name: "Editor")
        var frontmostReads = 0
        let source = CaptureClipboard()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var texts = [String](), images = [URL]()
        private(set) var control: CaptureControl!
        private(set) var textWatcher: TextClipboardWatcher!
        private(set) var imageWatcher: ClipboardWatcher!
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            relaunch()
        }
        /// A new control and new watchers over the same preferences, as after quitting and reopening.
        func relaunch() {
            textWatcher?.stop()
            imageWatcher?.stop()
            control = CaptureControl(
                defaults: defaults, now: { [unowned self] in self.now },
                frontmost: { [unowned self] in
                    self.frontmostReads += 1
                    return self.front
                }, appName: { _ in nil }, ownBundleID: "com.baypeanut.Shelf")
            textWatcher = TextClipboardWatcher(source: source, capture: control, onText: { [unowned self] in self.texts.append($0) })
            imageWatcher = ClipboardWatcher(
                source: source, folder: folder, capture: control, onImage: { [unowned self] in self.images.append($0) })
            control.onResume = { [unowned self] in
                self.imageWatcher.skipCurrent()
                self.textWatcher.skipCurrent()
            }
            control.scheduleExpiry()
            textWatcher.start()
            imageWatcher.start()
        }
        func poll() {
            imageWatcher.check()
            textWatcher.check()
        }
        func cleanup() {
            textWatcher.stop()
            imageWatcher.stop()
            control.resume()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }
    private func png() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([40, 160, 210, 255]) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 1), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    func testFreshPreferencesCaptureEverythingAndIgnoreNoApp() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        XCTAssertEqual(rig.control.pauseState, .running)
        XCTAssertFalse(rig.control.isPaused)
        XCTAssertTrue(rig.control.ignoredBundleIDs.isEmpty)
        XCTAssertFalse(rig.control.skipsNextCopy)
    }

    func testPauseBlocksBothWatchersAndNothingCopiedMeanwhileIsCapturedOnResume() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let image = try png()
        rig.source.copy("before the pause")
        rig.poll()
        XCTAssertEqual(rig.texts, ["before the pause"])
        rig.control.pause(for: nil)
        rig.source.copy("copied while paused")
        rig.poll()
        rig.source.copy(image: image)
        rig.poll()
        rig.source.copy("last copy while paused")
        XCTAssertEqual(rig.texts, ["before the pause"])
        XCTAssertTrue(rig.images.isEmpty)
        // Resumed before either watcher polled the last paused copy.
        rig.control.resume()
        rig.poll()
        rig.poll()
        XCTAssertEqual(rig.texts, ["before the pause"])
        XCTAssertTrue(rig.images.isEmpty)
        rig.source.copy("after the pause")
        rig.poll()
        XCTAssertEqual(rig.texts, ["before the pause", "after the pause"])
        rig.source.copy(image: image)
        rig.poll()
        XCTAssertEqual(rig.images.count, 1)
    }

    func testCopyMadeRightAfterResumeIsCapturedOnTheNextPoll() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.pause(for: 300)
        rig.source.copy("paused")
        rig.poll()
        rig.control.resume()
        rig.source.copy("first copy after resume")
        rig.poll()
        XCTAssertEqual(rig.texts, ["first copy after resume"])
    }

    func testTimedPauseExpiresByTheInjectedClockWithoutRetroactiveCapture() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.pause(for: 300)
        XCTAssertEqual(rig.control.pauseState, .paused(until: rig.now.addingTimeInterval(300)))
        rig.now.addTimeInterval(299)
        rig.source.copy("one second before the deadline")
        rig.poll()
        XCTAssertTrue(rig.control.isPaused)
        XCTAssertTrue(rig.texts.isEmpty)
        rig.source.copy("unseen before the deadline")
        // The deadline passes between two polls: no timer announced it, so
        // the watchers cannot tell when the copy on the board was made.
        rig.now.addTimeInterval(2)
        XCTAssertEqual(rig.control.pauseState, .running)
        rig.poll()
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        rig.source.copy("after the deadline")
        rig.poll()
        XCTAssertEqual(rig.texts, ["after the deadline"])
    }

    func testTimedPauseSurvivesRelaunchUntilItsDeadline() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.pause(for: 3600)
        let deadline = rig.now.addingTimeInterval(3600)
        rig.now.addTimeInterval(1800)
        rig.relaunch()
        XCTAssertEqual(rig.control.pauseState, .paused(until: deadline))
        rig.source.copy("copied after the relaunch")
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        rig.now.addTimeInterval(1801)
        rig.relaunch()
        XCTAssertEqual(rig.control.pauseState, .running)
        XCTAssertNil(rig.defaults.object(forKey: "capturePausedUntil"))
        // A relaunch starts from the board as it is, as it always has.
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        rig.source.copy("captured again")
        rig.poll()
        XCTAssertEqual(rig.texts, ["captured again"])
    }

    func testPauseUntilResumedSurvivesRelaunchAndAnyAmountOfTime() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.pause(for: nil)
        rig.now.addTimeInterval(90 * 86400)
        rig.relaunch()
        XCTAssertEqual(rig.control.pauseState, .paused(until: nil))
        rig.source.copy("still paused")
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        rig.control.resume()
        rig.relaunch()
        XCTAssertEqual(rig.control.pauseState, .running)
    }

    func testTimedPauseReplacesAnIndefiniteOneAndABackwardsClockCannotStretchIt() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.pause(for: nil)
        rig.control.pause(for: 300)
        XCTAssertEqual(rig.control.pauseState, .paused(until: rig.now.addingTimeInterval(300)))
        rig.now.addTimeInterval(-86400)
        XCTAssertEqual(rig.control.pauseState, .paused(until: rig.now.addingTimeInterval(3600)))
        rig.defaults.set(Double.infinity, forKey: "capturePausedUntil")
        XCTAssertEqual(rig.control.pauseState, .running)
    }

    func testPauseAndResumeAnnounceEveryChange() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        var changes = 0
        var resumes = 0
        rig.control.onChange = { changes += 1 }
        rig.control.onResume = { resumes += 1 }
        rig.control.resume()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(resumes, 0)
        rig.control.pause(for: 300)
        XCTAssertEqual(changes, 1)
        rig.control.resume()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(resumes, 1)
    }

    func testSkipNextCopyIgnoresExactlyOneChangeInBothWatchers() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let image = try png()
        rig.control.setSkipsNextCopy(true)
        XCTAssertTrue(rig.control.skipsNextCopy)
        rig.source.copy("skipped")
        rig.poll()
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        XCTAssertFalse(rig.control.skipsNextCopy)
        rig.source.copy("captured")
        rig.poll()
        XCTAssertEqual(rig.texts, ["captured"])
        rig.control.setSkipsNextCopy(true)
        rig.source.copy(image: image)
        rig.poll()
        XCTAssertTrue(rig.images.isEmpty)
        rig.source.copy(image: image)
        rig.poll()
        XCTAssertEqual(rig.images.count, 1)
        rig.control.setSkipsNextCopy(true)
        rig.control.setSkipsNextCopy(false)
        rig.source.copy("skip was cancelled")
        rig.poll()
        XCTAssertEqual(rig.texts, ["captured", "skip was cancelled"])
    }

    func testShelfOwnCopyIsNeitherCapturedNorAttributedAndDoesNotUseUpTheSkip() throws {
        let oldOwn = ClipboardWatcher.ownChangeCount
        defer { ClipboardWatcher.recordOwnCopy(changeCount: oldOwn) }
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.setSkipsNextCopy(true)
        rig.source.copy("written by Shelf")
        ClipboardWatcher.recordOwnCopy(changeCount: rig.source.changeCount)
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        XCTAssertEqual(rig.frontmostReads, 0)
        XCTAssertTrue(rig.control.skipsNextCopy)
        rig.source.copy("the copy to skip")
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        XCTAssertFalse(rig.control.skipsNextCopy)
    }

    func testCopyMadeWithShelfInFrontIsCapturedWithoutASource() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.front = SourceApp(bundleID: "com.baypeanut.Shelf", name: "Shelf")
        XCTAssertEqual(rig.control.admit(source: rig.source, items: []), .admitted(nil))
        rig.source.copy("copied with Shelf in front")
        rig.poll()
        XCTAssertEqual(rig.texts, ["copied with Shelf in front"])
        rig.front = SourceApp(bundleID: "com.example.editor", name: "Editor")
        XCTAssertEqual(rig.control.admit(source: rig.source, items: []), .admitted(rig.front))
    }

    func testIgnoredAppsPersistAsBundleIdentifiersAndCanBeRemoved() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.control.ignore("com.example.editor")
        rig.control.ignore("com.example.Editor")
        rig.control.ignore("com.example.terminal")
        rig.control.ignore("")
        rig.control.ignore("not a bundle identifier")
        rig.control.ignore(String(repeating: "a", count: 300))
        XCTAssertEqual(rig.defaults.stringArray(forKey: "captureIgnoredApps"), ["com.example.editor", "com.example.terminal"])
        rig.source.copy("from the ignored editor")
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        rig.relaunch()
        XCTAssertTrue(rig.control.isIgnored("COM.EXAMPLE.EDITOR"))
        rig.source.copy("still ignored after a relaunch")
        rig.poll()
        XCTAssertTrue(rig.texts.isEmpty)
        rig.control.stopIgnoring("com.example.editor")
        XCTAssertEqual(rig.control.ignoredBundleIDs, ["com.example.terminal"])
        rig.source.copy("no longer ignored")
        rig.poll()
        XCTAssertEqual(rig.texts, ["no longer ignored"])
    }

    func testOversizedOrUndecodableSourceMarkerFallsBackToTheFrontmostApp() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        for marker in [Data(repeating: 0x61, count: 256), Data([0xff, 0xfe, 0xfd]), Data()] {
            rig.source.count += 1
            rig.source.values = [[.string: Data("synthetic".utf8), CaptureControl.sourceType: marker]]
            XCTAssertEqual(rig.control.sourceApp(of: rig.source, items: rig.source.itemTypes), rig.front)
        }
        rig.source.values = [[.string: Data("synthetic".utf8), CaptureControl.sourceType: Data(" com.example.terminal\n".utf8)]]
        XCTAssertEqual(
            rig.control.sourceApp(of: rig.source, items: rig.source.itemTypes),
            SourceApp(bundleID: "com.example.terminal", name: "com.example.terminal"))
    }
}
