import Foundation

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// Only temporary folders and disposable preferences. Damage is a page of a
/// synthetic database overwritten in place.
@MainActor final class LibraryIntegrityTests: HistoryTestCase {
    private let flag = "libraryIntegrityCheckFailed"
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture()
        value.date = Date(timeIntervalSince1970: 1_700_000_000)
        return value
    }
    /// `threshold` 0 is a library too large to check before opening; nil is the shipped limit.
    private func store(_ f: SyntheticFixture, threshold: Int? = nil) throws -> LibraryStore {
        try LibraryStore(
            defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder),
            deferredIntegrityCheckBytes: threshold ?? LibraryStore.deferredIntegrityCheckBytes)
    }
    /// A library this build has prepared, closed, with everything in the main file.
    private func prepared(_ f: SyntheticFixture) throws -> (url: URL, kept: UUID) {
        let library = try store(f)
        var kept: UUID?
        for index in 0..<400 {
            let record = try XCTUnwrap(library.captureText("synthetic note \(index) " + String(repeating: "filler \(index) ", count: 40)))
            if index == 0 { kept = record.id }
        }
        let url = library.databaseURL
        _ = try LibraryDatabase(url: url, verify: false).rows("PRAGMA wal_checkpoint(TRUNCATE)")
        return (url, try XCTUnwrap(kept))
    }
    /// Overwrites one leaf page of the items table. The schema, and so opening and most reads, still work.
    private func damage(_ url: URL) throws {
        let database = try LibraryDatabase(url: url, readOnly: true, verify: false)
        let size = try XCTUnwrap(database.rows("PRAGMA page_size").first?.values.first?.number)
        let page = try XCTUnwrap(
            database.rows("SELECT pageno FROM dbstat WHERE name='items' AND pagetype='leaf' ORDER BY pageno DESC LIMIT 1").first?["pageno"]?
                .number)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64((page - 1) * size))
        try handle.write(contentsOf: Data(repeating: 0xA5, count: Int(size)))
        try handle.synchronize()
    }
    private func bytes(_ url: URL) throws -> [Data] {
        [try Data(contentsOf: url), (try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data()]
    }

    func testDamagedLibraryIsRefusedBeforeItOpensWhenSmallUnpreparedOrPreviouslyFailed() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let url = try prepared(f).url
        try damage(url)
        let before = try bytes(url)
        // The shipped limit: a small database is checked first, as every database used to be.
        XCTAssertThrowsError(try store(f))
        XCTAssertEqual(try bytes(url), before)
        // After a failed check, even a library large enough to defer is checked first.
        f.defaults.set(true, forKey: flag)
        XCTAssertThrowsError(try store(f, threshold: 0))
        XCTAssertEqual(try bytes(url), before)
        XCTAssertTrue(f.defaults.bool(forKey: flag))
    }

    func testLibraryNotYetPreparedByThisBuildIsCheckedAndPreparedBeforeItOpens() throws {
        let f = try fixture()
        defer { f.cleanup() }
        // New: there is nothing to defer.
        let fresh = try store(f, threshold: 0)
        XCTAssertEqual(fresh.integrity, .verified)
        XCTAssertNotNil(try fresh.captureText("first synthetic note"))
        // Written by the previous build: the check, the snapshot and the upgrade all come first.
        let g = try fixture()
        defer { g.cleanup() }
        let records = try SyntheticLibraryCorpus.records(count: 60, seed: 4, inbox: g.inbox, end: g.date)
        try PreviousLibrary.make(g, records: records)
        let upgraded = try store(g, threshold: 0)
        XCTAssertEqual(upgraded.integrity, .verified)
        XCTAssertEqual(upgraded.snapshots.all().count, 1)
        // A healthy check clears an earlier failure mark.
        f.defaults.set(true, forKey: flag)
        XCTAssertEqual(try store(f, threshold: 0).integrity, .verified)
        XCTAssertNil(f.defaults.object(forKey: flag))
    }

    func testLargeLibraryOpensAtOnceWritesNothingUntilCheckedAndThenFinishesOpening() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let (url, kept) = try prepared(f)
        let before = try bytes(url)
        let library = try store(f, threshold: 0)
        XCTAssertEqual(library.integrity, .checking)
        var started = 0
        library.afterIntegrityCheck { started += 1 }
        // Reading works straight away, and so far nothing has been written.
        XCTAssertEqual(try library.shelfItems(.text).count, 400)
        XCTAssertEqual(try library.item(kept)?.kind, .text)
        var query = LibraryQuery(scope: .recent, search: "synthetic note 399")
        query.searchMode = .text
        XCTAssertEqual(try library.queryIDs(query).count, 1)
        XCTAssertEqual(try bytes(url), before)
        XCTAssertEqual(started, 0)
        // The first write waits for the check instead of going ahead of it.
        let captured = try XCTUnwrap(library.captureText("written after the check"))
        XCTAssertEqual(library.integrity, .verified)
        XCTAssertEqual(started, 1)
        XCTAssertEqual(try library.item(captured.id)?.text, "written after the check")
        library.afterIntegrityCheck { started += 1 }
        XCTAssertEqual(started, 2)
        XCTAssertNil(f.defaults.object(forKey: flag))

        // Without a write, the check still completes and opening finishes.
        let reopened = try store(f, threshold: 0)
        XCTAssertEqual(reopened.integrity, .checking)
        XCTAssertEqual(reopened.waitForIntegrityCheck(), .verified)
        try reopened.toggleFavorite([kept])
        XCTAssertEqual(try reopened.item(kept)?.favorite, true)
    }

    func testFailureAfterOpeningRefusesEveryWriteAndTheNextLaunchRefusesToOpen() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let (url, kept) = try prepared(f)
        try damage(url)
        let before = try bytes(url)
        do {
            let library = try store(f, threshold: 0)
            XCTAssertEqual(library.integrity, .checking)
            var started = 0
            var failures = 0
            library.afterIntegrityCheck { started += 1 }
            library.onIntegrityFailure = { failures += 1 }
            let revision = library.revision
            // A capture that arrives before the check has finished waits for it and is refused.
            XCTAssertThrowsError(try library.captureText("must not be written"))
            XCTAssertEqual(library.integrity, .failed)
            XCTAssertTrue(f.defaults.bool(forKey: flag))
            // So is every other kind of write, from then on.
            XCTAssertThrowsError(try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/refused"))))
            XCTAssertThrowsError(try library.captureImage(f.image()))
            XCTAssertThrowsError(try library.toggleFavorite([kept]))
            XCTAssertThrowsError(try library.update(kept) { $0.note = "refused" })
            XCTAssertThrowsError(try library.trash([kept]))
            XCTAssertThrowsError(try library.emptyTrash())
            XCTAssertThrowsError(try library.createCollection("Refused"))
            XCTAssertThrowsError(try library.prune())
            XCTAssertEqual(library.revision, revision)
            XCTAssertEqual(try bytes(url), before, "Not one byte of the damaged database or its log changed")
            // Work that writes on its own connection is never started.
            library.afterIntegrityCheck { started += 1 }
            XCTAssertEqual(started, 0)
            let end = Date().addingTimeInterval(5)
            while failures == 0 && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(failures, 1)
        }
        // The next launch checks first and fails to open, which is where recovery mode has always begun.
        XCTAssertThrowsError(try store(f, threshold: 0))
        XCTAssertEqual(try bytes(url), before)

        // The same failure found by waiting rather than by a write.
        f.defaults.removeObject(forKey: flag)
        let library = try store(f, threshold: 0)
        XCTAssertEqual(library.waitForIntegrityCheck(), .failed)
        XCTAssertThrowsError(try library.captureText("must not be written"))
        XCTAssertEqual(try bytes(url), before)
        XCTAssertTrue(f.defaults.bool(forKey: flag))
    }
}
