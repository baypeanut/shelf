import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

/// Only temporary folders, disposable preferences and a folder standing in
/// for the system Trash.
@MainActor final class TrashPurgeTests: HistoryTestCase {
    private let day = 86_400.0
    private func store(_ fixture: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: fixture.defaults, inbox: fixture.inbox,
            now: { fixture.date }, moveToTrash: fixtureTrash(fixture.folder))
    }
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture(); value.date = Date(timeIntervalSince1970: 1_700_000_000); return value
    }
    private func count(_ library: LibraryStore, _ table: String, _ column: String, _ id: UUID) throws -> Int64? {
        try LibraryDatabase(url: library.databaseURL).rows("SELECT count(*) AS n FROM \(table) WHERE \(column)=?", [.text(id.uuidString)]).first?["n"]?.number
    }
    private func trashed(_ f: SyntheticFixture) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: f.folder.appendingPathComponent(".test-trash"), includingPropertiesForKeys: nil)) ?? []
    }

    func testPurgeRemovesOnlyExpiredTrashWithItsFolderTagSearchAndIdentityRows() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let old = try XCTUnwrap(library.captureText("expired synthetic note")), recent = try XCTUnwrap(library.captureText("recent synthetic note"))
        let restored = try XCTUnwrap(library.captureText("restored synthetic note")), live = try XCTUnwrap(library.captureText("live synthetic note"))
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/expired")))
        let folder = try library.createCollection("Folder"); try library.assign([old.id, live.id], to: folder); try library.addTag("topic", to: [old.id, live.id])
        try library.trash([old.id, link.id, restored.id])
        let cutoff = f.date.addingTimeInterval(5 * day)
        f.date = f.date.addingTimeInterval(10 * day)
        try library.restore([restored.id]); try library.trash([recent.id])
        let revision = library.revision
        XCTAssertEqual(Set(try library.purgeTrash(olderThan: cutoff)), [old.id, link.id])
        XCTAssertTrue(library.revision > revision)
        XCTAssertNil(try library.item(old.id)); XCTAssertNil(try library.item(link.id))
        XCTAssertEqual(try library.item(recent.id)?.deletedAt, f.date)
        XCTAssertNil(try XCTUnwrap(library.item(restored.id)).deletedAt); XCTAssertEqual(try library.item(restored.id)?.text, "restored synthetic note")
        XCTAssertEqual(try library.item(live.id)?.text, "live synthetic note")
        for (table, column) in [("items", "id"), ("item_tags", "item"), ("item_collections", "item"), ("search_docs", "item"), ("text_identity", "item")] {
            XCTAssertEqual(try count(library, table, column, old.id), 0, table)
            XCTAssertEqual(try count(library, table, column, live.id), 1, table)
        }
        XCTAssertEqual(try count(library, "search_docs", "item", link.id), 0)
        XCTAssertEqual(try count(library, "text_identity", "item", recent.id), 1); XCTAssertEqual(try count(library, "search_docs", "item", recent.id), 1)
        XCTAssertEqual(try library.tags().map(\.name), ["topic"]); XCTAssertEqual(try library.collections().map(\.name), ["Folder"])
        var query = LibraryQuery(scope: .trash); XCTAssertEqual(try library.queryIDs(query), [recent.id]); XCTAssertEqual(try library.trashCount(), 1)
        query.search = "expired"; XCTAssertTrue(try library.queryIDs(query).isEmpty)
        XCTAssertTrue(try library.purgeTrash(olderThan: cutoff).isEmpty)
        // The same words can be copied again as a new item.
        XCTAssertNotNil(try library.captureText("expired synthetic note"))
        let reopened = try store(f); XCTAssertEqual(try reopened.trashCount(), 1); XCTAssertEqual(try reopened.item(live.id)?.text, "live synthetic note")
    }

    func testImageAnalysisRowsLeaveWithThePurgedImage() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let image = try library.captureImage(f.image()), database = try LibraryDatabase(url: library.databaseURL)
        try database.execute("INSERT INTO image_analysis VALUES(?,?,?,?,?,?,?)", [.text(image.id.uuidString), .text("synthetic"), .text("f"), .text("v"), .text(""), .text("synthetic ocr"), .blob(Data())])
        try library.trash([image.id]); XCTAssertEqual(try library.emptyTrash(), [image.id])
        XCTAssertEqual(try count(library, "image_analysis", "item", image.id), 0)
    }

    func testAutomaticPurgeWaitsOutTheTrashPeriodAndNeverKeepsTrash() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        XCTAssertEqual(HistoryRetention.trashDays(defaults: f.defaults), 30)
        let removed = try XCTUnwrap(library.captureText("removed by hand")), copy = try XCTUnwrap(library.captureText("unsaved copy"))
        let saved = try XCTUnwrap(library.captureText("saved note")); try library.retain([saved.id])
        try library.trash([removed.id])
        // Retention moves the unsaved copy to Trash; its Trash clock starts then.
        f.date = f.date.addingTimeInterval(30 * day - 1); try library.prune()
        XCTAssertNotNil(try library.item(removed.id)); XCTAssertNil(try XCTUnwrap(library.item(copy.id)).deletedAt)
        f.date = f.date.addingTimeInterval(2); try library.prune()
        XCTAssertNil(try library.item(removed.id)); XCTAssertEqual(try library.item(copy.id)?.deletedAt, f.date)
        f.date = f.date.addingTimeInterval(30 * day - 1); try library.prune(); XCTAssertNotNil(try library.item(copy.id))
        f.date = f.date.addingTimeInterval(2); try library.prune(); XCTAssertNil(try library.item(copy.id))
        XCTAssertEqual(try library.item(saved.id)?.text, "saved note")

        f.defaults.set(0, forKey: HistoryRetention.trashKey); XCTAssertNil(HistoryRetention.trashDays(defaults: f.defaults))
        let kept = try XCTUnwrap(library.captureText("kept in trash")); try library.trash([kept.id])
        f.date = f.date.addingTimeInterval(4000 * day); try library.prune()
        XCTAssertEqual(try library.item(kept.id)?.text, "kept in trash")
        f.defaults.set(7, forKey: HistoryRetention.trashKey); XCTAssertEqual(HistoryRetention.trashDays(defaults: f.defaults), 7)
        f.defaults.set(12, forKey: HistoryRetention.trashKey); XCTAssertEqual(HistoryRetention.trashDays(defaults: f.defaults), 30)
        f.defaults.set(7, forKey: HistoryRetention.trashKey); try library.prune(); XCTAssertNil(try library.item(kept.id))
    }

    func testEmptyTrashPurgesWhatWasConfirmedAndInvalidatesUndo() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let first = try XCTUnwrap(library.captureText("first")), second = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/second")))
        let later = try XCTUnwrap(library.captureText("trashed after the question")), live = try XCTUnwrap(library.captureText("live"))
        try library.trashUndoably([first.id, second.id]); XCTAssertTrue(library.canUndoTrash)
        let asked = f.date; XCTAssertEqual(try library.trashCount(olderThan: asked), 2)
        f.date = f.date.addingTimeInterval(1); try library.trashUndoably([later.id])
        XCTAssertEqual(Set(try library.emptyTrash(asOf: asked)), [first.id, second.id])
        XCTAssertNil(try library.item(first.id)); XCTAssertNil(try library.item(second.id)); XCTAssertNotNil(try library.item(live.id))
        // Only the batch whose items still exist can be undone.
        XCTAssertEqual(try library.undoTrash(), [later.id]); XCTAssertFalse(library.canUndoTrash); XCTAssertTrue(try library.undoTrash().isEmpty)
        try library.trashUndoably([later.id, live.id]); XCTAssertEqual(Set(try library.emptyTrash()), [later.id, live.id])
        XCTAssertFalse(library.canUndoTrash); XCTAssertTrue(try library.undoTrash().isEmpty); XCTAssertEqual(try library.trashCount(), 0)
        XCTAssertTrue(try library.emptyTrash().isEmpty)
    }

    func testPurgeMovesShelfCopiesToTrashAndLeavesOriginalsAndSharedFiles() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let clipboard = try f.image(), original = try f.image(owned: false), pinnedOriginal = try f.image(owned: false), shared = try f.image()
        let bytes = try Data(contentsOf: original)
        let copy = try library.captureImage(clipboard), external = try library.captureImage(original), pinned = try library.captureImage(pinnedOriginal)
        try library.toggleFavorite([pinned.id])
        let favorite = try XCTUnwrap(library.item(pinned.id)?.fileURL); XCTAssertTrue(library.files.isFavoriteCopy(favorite))
        let text = try XCTUnwrap(library.captureText("materialized synthetic text")), textFile = try LibraryTransfer.materialize(text, store: library)
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/materialized"))), linkFile = try LibraryTransfer.materialize(link, store: library)
        let earlier = try library.captureImage(shared); try library.trash([earlier.id])
        let recaptured = try library.captureImage(shared); XCTAssertTrue(earlier.id != recaptured.id)
        try library.trash([copy.id, external.id, pinned.id, text.id, link.id])
        XCTAssertEqual(try library.emptyTrash().count, 6)
        for gone in [clipboard, favorite, textFile, linkFile] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent) }
        XCTAssertEqual(trashed(f).count, 4)
        XCTAssertEqual(try Data(contentsOf: original), bytes); XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path)); XCTAssertEqual(try library.item(recaptured.id)?.path, shared.path)
    }

    /// Inbox mode saves screenshots into Shelf's folder under the names macOS
    /// gives them. Purging the item moves that file to the Trash too.
    func testPurgeMovesInboxScreenshotsAndRecordingsToTrashButNotFilesElsewhere() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let shot = try f.image(owned: true, name: "Screenshot 2026-11-24 at 10.00.00.png")
        let favored = try f.image(owned: true, name: "Screenshot 2026-11-24 at 10.00.01.png")
        let recording = f.inbox.appendingPathComponent("Screen Recording 2026-11-24 at 10.00.02.mov"); try Data([0]).write(to: recording)
        let outside = try f.image(owned: false), nested = f.inbox.appendingPathComponent("Texts/Screenshot nested.png")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: shot, to: nested)
        let linked = f.inbox.appendingPathComponent("Screenshot linked.png"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertTrue(library.files.isInboxCapture(shot)); XCTAssertFalse(library.files.isInboxCapture(outside))
        XCTAssertFalse(library.files.isInboxCapture(nested)); XCTAssertFalse(library.files.isInboxCapture(linked))
        let items = try [shot, favored, recording, outside].map { try library.captureImage($0) }
        try library.toggleFavorite([items[1].id]); XCTAssertEqual(try library.item(items[1].id)?.originalPath, favored.path)
        try library.trash(items.map(\.id))
        XCTAssertEqual(try library.emptyTrash().count, 4)
        for gone in [shot, favored, recording] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent) }
        for kept in [outside, nested, linked] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent) }
        XCTAssertEqual(trashed(f).count, 4)
    }

    func testFileThatCannotMoveToTrashDoesNotBringItsRowBack() throws {
        let f = try fixture(); defer { f.cleanup() }
        let library = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: { _ in throw HistoryFiles.Failure.unsafeFile })
        let clipboard = try f.image(), image = try library.captureImage(clipboard), live = try XCTUnwrap(library.captureText("live"))
        try library.trash([image.id]); XCTAssertEqual(try library.emptyTrash(), [image.id])
        XCTAssertNil(try library.item(image.id)); XCTAssertTrue(FileManager.default.fileExists(atPath: clipboard.path))
        XCTAssertEqual(try library.item(live.id)?.text, "live"); XCTAssertEqual(try library.trashCount(), 0)
        XCTAssertEqual(try LibraryDatabase(url: library.databaseURL).rows("PRAGMA quick_check").first?.values.first?.string, "ok")
    }

    func testPurgedTextIsNoLongerInTheDatabaseFiles() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let marker = "zqmarker" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func found() throws -> Bool {
            let wal = URL(fileURLWithPath: library.databaseURL.path + "-wal")
            let bytes = try Data(contentsOf: library.databaseURL) + ((try? Data(contentsOf: wal)) ?? Data())
            return bytes.range(of: Data(marker.utf8)) != nil
        }
        for index in 0..<40 { _ = try library.captureText("ordinary synthetic copy \(index) " + String(repeating: "filler ", count: 200)) }
        let secret = try XCTUnwrap(library.captureText("Before \(marker) after\n" + String(repeating: "\(marker) ", count: 400)))
        try library.addTag("topic", to: [secret.id]); try library.update(secret.id) { $0.note = "note \(marker)"; $0.title = "Title \(marker)" }
        XCTAssertTrue(try found())
        try library.trash([secret.id]); XCTAssertTrue(try found())
        XCTAssertEqual(try library.emptyTrash(), [secret.id])
        XCTAssertFalse(try found())
        var query = LibraryQuery(scope: .recent); query.search = marker; XCTAssertTrue(try library.queryIDs(query).isEmpty)
        query.search = "ordinary"; XCTAssertEqual(try library.queryIDs(query).count, 40)
    }

    func testTrashPeriodSettingPersistsRejectsUnknownValuesAndDeletesNothingWhenChosen() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, moveToTrash: fixtureTrash(f.folder), library: library)
        XCTAssertEqual(line.trashRetentionDays, 30)
        let old = try XCTUnwrap(library.captureText("trashed twenty days ago")); try library.trash([old.id])
        f.date = f.date.addingTimeInterval(20 * day)
        line.setTrashRetentionDays(12); XCTAssertEqual(line.trashRetentionDays, 30)
        line.setTrashRetentionDays(7); XCTAssertEqual(line.trashRetentionDays, 7); XCTAssertEqual(f.defaults.integer(forKey: "trashRetentionDays"), 7)
        // Picking a shorter period is not itself a deletion; the next cleanup applies it.
        XCTAssertNotNil(try library.item(old.id))
        line.setTrashRetentionDays(0); XCTAssertEqual(line.trashRetentionDays, 0); line.prune(); XCTAssertNotNil(try library.item(old.id))
        line.setTrashRetentionDays(7); line.prune(); XCTAssertNil(try library.item(old.id))
    }

    func testEmptyTrashIsACatalogCommandAndALibraryRequest() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f), model = LibraryModel(store: library)
        var context = ActionBarCatalog.Context()
        let bindings = KeyboardBindings(defaults: f.defaults)
        func enabled() throws -> Bool { try XCTUnwrap(ActionBarCatalog.entries(context: context, bindings: bindings).first { $0.action == .menu(.emptyTrash) }?.command).isEnabled }
        XCTAssertTrue(try enabled()); context.libraryAvailable = false; XCTAssertFalse(try enabled())
        let trashed = try XCTUnwrap(library.captureText("in trash")), later = try XCTUnwrap(library.captureText("trashed later")); try library.trash([trashed.id])
        var requests = 0; model.onEmptyTrashRequested = { requests += 1 }
        model.onEmptyTrashRequested?(); XCTAssertEqual(requests, 1); XCTAssertNotNil(try library.item(trashed.id))
        let snapshot = try library.trashSnapshot(); XCTAssertEqual(snapshot.count, 1)
        f.date = f.date.addingTimeInterval(60); try library.trash([later.id])
        XCTAssertEqual(try library.emptyTrash(asOf: snapshot.asOf), [trashed.id]); XCTAssertNotNil(try library.item(later.id))
    }

    func testCompactionReturnsFreedPagesAndKeepsTheLibraryUsable() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let kept = try XCTUnwrap(library.captureText("kept synthetic note"))
        var ids = [UUID]()
        for index in 0..<120 { ids.append(try XCTUnwrap(library.captureText("bulk \(index) " + String(repeating: "synthetic filler \(index) ", count: 2500))).id) }
        func pages() throws -> Int64 { try XCTUnwrap(LibraryDatabase(url: library.databaseURL).rows("PRAGMA page_count").first?["page_count"]?.number) }
        try library.trash(ids)
        let before = try pages(); XCTAssertEqual(try library.purgeTrash(olderThan: f.date).count, 120)
        var finished: Bool?
        library.compact { finished = $0 }
        let end = Date().addingTimeInterval(20)
        while finished == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(finished, true); XCTAssertTrue(try pages() * 2 < before)
        XCTAssertEqual(try library.item(kept.id)?.text, "kept synthetic note"); XCTAssertNotNil(try library.captureText("written after compaction"))
        var query = LibraryQuery(scope: .recent); query.search = "kept"; XCTAssertEqual(try library.queryIDs(query), [kept.id])
    }
}
