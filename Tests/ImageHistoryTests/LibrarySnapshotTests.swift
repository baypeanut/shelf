import Foundation

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// Only temporary folders and disposable preferences.
@MainActor final class LibrarySnapshotTests: HistoryTestCase {
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture()
        value.date = Date(timeIntervalSince1970: 1_700_000_000)
        return value
    }
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }
    private func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testSnapshotIsAPrivateStandaloneCopyOfCommittedContent() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let saved = try XCTUnwrap(library.captureText("saved synthetic note"))
        try library.retain([saved.id])
        let folder = try library.createCollection("Folder")
        try library.assign([saved.id], to: folder)
        try library.addTag("topic", to: [saved.id])
        // Still only in the write-ahead log.
        let latest = try XCTUnwrap(library.captureText("latest synthetic note"))
        let snapshot = try library.makeSnapshot()
        XCTAssertEqual(snapshot.deletingLastPathComponent(), library.snapshots.folder)
        XCTAssertEqual(snapshot.lastPathComponent, "library-before-update-2023-11-14T221320Z.sqlite")
        XCTAssertEqual(try mode(snapshot), 0o600)
        XCTAssertEqual(try mode(library.snapshots.folder), 0o700)
        XCTAssertEqual(names(library.snapshots.folder), [snapshot.lastPathComponent], "No staging, log or journal file is left beside it")
        // The copy opens on its own and passes the integrity check.
        let copy = try LibraryDatabase(url: snapshot, readOnly: true)
        XCTAssertEqual(try copy.rows("SELECT count(*) AS n FROM items").first?["n"]?.number, 2)
        XCTAssertEqual(try copy.rows("SELECT count(*) AS n FROM item_tags").first?["n"]?.number, 1)
        XCTAssertEqual(try copy.rows("SELECT count(*) AS n FROM item_collections").first?["n"]?.number, 1)
        let payload = try XCTUnwrap(
            copy.rows("SELECT payload FROM items WHERE id=?", [.text(latest.id.uuidString)]).first?["payload"]?.data)
        XCTAssertEqual(try JSONDecoder().decode(LibraryRecord.self, from: payload).text, "latest synthetic note")
        // Later changes do not reach it.
        try library.update(saved.id) { $0.text = "edited later" }
        XCTAssertEqual(
            try LibraryDatabase(url: snapshot, readOnly: true).rows("SELECT count(*) AS n FROM items WHERE instr(search,'edited later')>0")
                .first?["n"]?.number, 0)
        XCTAssertEqual(library.snapshots.all(), [snapshot])
    }

    func testSnapshotsNeverReplaceOneAnotherAndOnlyTheNewestTwoAreKept() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        _ = try library.captureText("first")
        let first = try library.makeSnapshot()
        let bytes = try Data(contentsOf: first)
        _ = try library.captureText("second")
        // The same second on the clock gets its own name.
        let second = try library.makeSnapshot()
        XCTAssertTrue(first != second)
        XCTAssertEqual(second.lastPathComponent, "library-before-update-2023-11-14T221320Z-2.sqlite")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(library.snapshots.all(), [first, second])
        f.date = f.date.addingTimeInterval(60)
        _ = try library.captureText("third")
        let third = try library.makeSnapshot()
        XCTAssertEqual(library.snapshots.all(), [second, third])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        f.date = f.date.addingTimeInterval(-3600)
        let earlier = try library.makeSnapshot()
        XCTAssertEqual(library.snapshots.all(), [earlier, third], "The copy just made stays even when the clock has moved back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try LibraryDatabase(url: third, readOnly: true).rows("SELECT count(*) AS n FROM items").first?["n"]?.number, 3)
    }

    func testFailedSnapshotThrowsLeavesNothingBehindAndTheLibraryUntouched() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let record = try XCTUnwrap(library.captureText("kept synthetic note"))
        // A file where the folder belongs.
        try Data("synthetic".utf8).write(to: library.snapshots.folder)
        XCTAssertThrowsError(try library.makeSnapshot())
        XCTAssertEqual(try Data(contentsOf: library.snapshots.folder), Data("synthetic".utf8))
        XCTAssertTrue(library.snapshots.all().isEmpty)
        XCTAssertEqual(try library.item(record.id)?.text, "kept synthetic note")
        // A copy that was interrupted before it was named.
        try FileManager.default.removeItem(at: library.snapshots.folder)
        try FileManager.default.createDirectory(at: library.snapshots.folder, withIntermediateDirectories: true)
        try Data("unfinished".utf8).write(to: library.snapshots.folder.appendingPathComponent(".partial-synthetic.sqlite"))
        let made = try library.makeSnapshot()
        XCTAssertEqual(names(library.snapshots.folder), [made.lastPathComponent], "An interrupted copy is cleared, not counted")
        XCTAssertEqual(try store(f).item(record.id)?.text, "kept synthetic note")
    }

    func testEmptyTrashRemovesSnapshotsAndRoutineCleanupExpiresThemAfterAWeek() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let marker = "zqsnapshot" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func found() throws -> Bool {
            let folders = [library.root, library.snapshots.folder]
            let files = try folders.flatMap {
                try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isRegularFileKey])
            }
            return try files.contains { url in
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { return false }
                return try Data(contentsOf: url).range(of: Data(marker.utf8)) != nil
            }
        }
        let secret = try XCTUnwrap(library.captureText("Before \(marker) after"))
        let kept = try XCTUnwrap(library.captureText("kept synthetic note"))
        try library.makeSnapshot()
        XCTAssertEqual(library.snapshots.all().count, 1)
        try library.trash([secret.id])
        // Routine cleanup: the Trash period has not passed, and neither has the snapshot's week.
        f.date = f.date.addingTimeInterval(6 * 86_400)
        try library.prune()
        XCTAssertEqual(library.snapshots.all().count, 1)
        XCTAssertTrue(try found())
        XCTAssertEqual(try library.emptyTrash(), [secret.id])
        XCTAssertTrue(library.snapshots.all().isEmpty)
        XCTAssertFalse(try found(), "Neither the database, its log nor a snapshot still holds the deleted text")
        XCTAssertEqual(try library.item(kept.id)?.text, "kept synthetic note")

        // Without Empty Trash a snapshot lasts a week, then cleanup removes it.
        try library.makeSnapshot()
        f.date = f.date.addingTimeInterval(7 * 86_400)
        try library.prune()
        XCTAssertEqual(library.snapshots.all().count, 1)
        f.date = f.date.addingTimeInterval(1)
        try library.prune()
        XCTAssertTrue(library.snapshots.all().isEmpty)
        // Emptying an already empty Trash still removes them.
        try library.makeSnapshot()
        XCTAssertTrue(try library.emptyTrash().isEmpty)
        XCTAssertTrue(library.snapshots.all().isEmpty)
        XCTAssertEqual(try library.item(kept.id)?.text, "kept synthetic note")
    }
}
