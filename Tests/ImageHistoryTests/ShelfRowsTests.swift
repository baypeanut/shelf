import Foundation

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// Only temporary folders and disposable preferences.
@MainActor final class ShelfRowsTests: HistoryTestCase {
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture()
        value.date = Date(timeIntervalSince1970: 1_700_000_000)
        return value
    }
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }
    private func line(_ f: SyntheticFixture, _ library: LibraryStore) -> Line {
        Line(
            defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, moveToTrash: fixtureTrash(f.folder), copyImage: { _ in },
            copyText: { _ in }, library: library)
    }
    /// The three shelves as they are shown, against the shelves read whole from the store.
    private func assertShelvesMatchStore(
        _ line: Line, _ library: LibraryStore, _ step: String, file: StaticString = #filePath, line number: UInt = #line
    ) throws {
        let texts = try library.shelfItems(.text).map {
            TextHistory.Entry(
                id: $0.id, text: $0.text ?? "", capturedAt: $0.createdAt, pinned: $0.favorite, title: $0.title.isEmpty ? nil : $0.title)
        }
        XCTAssertTrue(line.texts.entries == texts, "texts after \(step)", file: file, line: number)
        XCTAssertTrue(line.links.entries == (try library.shelfItems(.link)), "links after \(step)", file: file, line: number)
        let images = try library.shelfItems(.image).filter { $0.path != nil }
        XCTAssertEqual(line.items.map(\.id), images.map(\.id), "images after \(step)", file: file, line: number)
        XCTAssertEqual(line.items.map(\.url.path), images.compactMap(\.path), "image files after \(step)", file: file, line: number)
        XCTAssertEqual(line.items.map(\.pinned), images.map(\.favorite), "image pins after \(step)", file: file, line: number)
        XCTAssertEqual(
            line.items.map(\.title), images.map { $0.title.isEmpty ? nil : $0.title }, "image names after \(step)", file: file, line: number
        )
        XCTAssertEqual(
            line.items.map(\.managedCopy), images.compactMap { $0.fileURL.map(library.files.isAppCopy) }, "image ownership after \(step)",
            file: file, line: number)
    }

    func testShelvesFollowEveryKindOfChangeExactlyAsAFullReadWould() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        var generator = SeededGenerator(seed: 0x5E1F5)
        var texts = [String]()
        var urls = [URL]()
        var files = [URL]()
        for index in 0..<12 {
            texts.append("shelf text \(index)")
            _ = try library.captureText(texts[index])
            urls.append(try XCTUnwrap(URL(string: "https://example.com/shelf/\(index)")))
            _ = try library.captureLink(urls[index])
            files.append(try f.image(owned: index % 2 == 0))
            _ = try library.captureImage(files[index])
        }
        let shown = line(f, library)
        try assertShelvesMatchStore(shown, library, "loading")
        func some(_ kind: LibraryKind?, live: Bool = true) throws -> [UUID] {
            var query = LibraryQuery(scope: live ? .shelf : .trash)
            query.kind = kind
            let ids = try library.queryIDs(query)
            return ids.isEmpty ? [] : (0..<(1 + generator.index(3))).map { _ in ids[generator.index(ids.count)] }
        }
        for step in 0..<700 {
            // The clock often stands still, so order falls to the rows' own places.
            if generator.index(3) == 0 { f.date.addTimeInterval(Double(generator.index(3))) }
            let kind = LibraryKind.allCases[generator.index(3)]
            let choice = generator.index(21)
            let name: String
            switch choice {
            case 0:
                name = "capture text"
                texts.append("shelf text \(texts.count)")
                _ = try library.captureText(texts[texts.count - 1])
            case 1:
                name = "recopy text"
                _ = try library.captureText(texts[generator.index(texts.count)])
            case 2:
                name = "capture link"
                urls.append(try XCTUnwrap(URL(string: "https://example.com/shelf/\(urls.count)")))
                _ = try library.captureLink(urls[urls.count - 1])
            case 3:
                name = "recopy link"
                _ = try library.captureLink(urls[generator.index(urls.count)])
            case 4:
                name = "capture image"
                files.append(try f.image(owned: generator.index(2) == 0))
                _ = try library.captureImage(files[files.count - 1])
            case 5:
                name = "recapture image"
                _ = try? library.captureImage(files[generator.index(files.count)])
            case 6:
                name = "pin"
                try library.toggleFavorite(Array(Set(try some(kind))))
            case 7:
                name = "rename"
                if let id = try some(kind).first { try library.update(id) { $0.title = generator.index(3) == 0 ? "" : "Name \(step)" } }
            case 8:
                name = "edit text"
                if let id = try some(.text).first { try library.update(id) { $0.text = "edited \(step)" } }
            case 9:
                name = "remove from shelf"
                try library.removeFromShelf(try some(kind))
            case 10:
                name = "undo removal"
                _ = try library.undoShelfRemoval()
            case 11:
                name = "trash"
                try library.trash(Array(Set(try some(kind))))
            case 12:
                name = "restore"
                try library.restore(Array(Set(try some(kind, live: false))))
            case 13:
                name = "trash with undo"
                try library.trashUndoably(try some(kind))
            case 14:
                name = "undo trash"
                _ = try library.undoTrash()
            case 15:
                name = "copied"
                try library.markCopied(Array(Set(try some(kind))))
            case 16:
                name = "tag and folder"
                let ids = Array(Set(try some(kind)))
                if !ids.isEmpty {
                    try library.addTag("topic \(generator.index(3))", to: ids)
                    try library.assign(ids, to: try library.createCollection("Folder \(step)"))
                }
            case 17:
                name = "name and pin"
                if let id = try some(kind).first { _ = try library.nameAndPin(id, name: "Pinned \(step)") }
            case 18:
                name = "purge"
                _ = try library.purgeTrash(olderThan: f.date)
            case 19:
                name = "shelf actions"
                if let entry = shown.texts.entries.first { shown.texts.togglePin(entry.id) }
                if let entry = shown.links.entries.last { shown.links.removeFromShelf(entry.id) }
                if let item = shown.items.first { shown.pinFromUI(item.id) }
            default:
                name = "clear unsaved"
                if generator.index(6) == 0 { _ = try library.clearUnsavedHistory(try library.unsavedHistorySnapshot(kind: kind)) }
            }
            try assertShelvesMatchStore(shown, library, "step \(step): \(name)")
        }
        XCTAssertFalse(shown.texts.entries.isEmpty)
        XCTAssertFalse(shown.links.entries.isEmpty)
        XCTAssertFalse(shown.items.isEmpty)
    }

    func testShelvesReadAgainAfterCompactionAndAfterAnotherWriterAddsOrRemovesRows() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        var kept = [UUID]()
        var bulk = [UUID]()
        for index in 0..<8 { kept.append(try XCTUnwrap(library.captureText("kept \(index)")).id) }
        for index in 0..<150 {
            bulk.append(try XCTUnwrap(library.captureText("bulk \(index) " + String(repeating: "filler \(index) ", count: 600))).id)
        }
        for index in 0..<8 { kept.append(try XCTUnwrap(library.captureText("later \(index)")).id) }
        let shown = line(f, library)
        try library.trash(bulk)
        try assertShelvesMatchStore(shown, library, "trash")
        // Emptying Trash compacts in the background, which renumbers every row.
        XCTAssertEqual(try library.emptyTrash().count, 150)
        let generation = library.storageGeneration
        let end = Date().addingTimeInterval(20)
        while library.storageGeneration == generation && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(library.storageGeneration > generation)
        // All at one instant: only the rows' new places order these.
        for index in 0..<6 { _ = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/after/\(index)"))) }
        for index in 0..<6 { _ = try library.captureText("after compaction \(index)") }
        try library.toggleFavorite([kept[0], kept[15]])
        try assertShelvesMatchStore(shown, library, "compaction")

        // An older build adds a text and removes one while this one is running.
        let other = try LibraryDatabase(url: library.databaseURL, verify: false)
        try other.execute("CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(id UNINDEXED,content,tokenize='unicode61')")
        var added = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date.addingTimeInterval(-5), updatedAt: f.date)
        added.text = "added by another writer"
        try other.transaction {
            try PreviousLibrary.save(added, isNew: true, in: other)
            try other.execute("UPDATE items SET shelf=0 WHERE id=?", [.text(kept[3].uuidString)])
            try other.execute("UPDATE items SET shelf=0 WHERE id=?", [.text(kept[4].uuidString)])
        }
        // The next change this build makes to that shelf brings the others in with it.
        try library.toggleFavorite([kept[1]])
        XCTAssertTrue(shown.texts.entries.contains { $0.id == added.id })
        XCTAssertFalse(shown.texts.entries.contains { $0.id == kept[3] })
        try assertShelvesMatchStore(shown, library, "another writer")
    }

    func testAChangeToOneShelfReadsOnlyTheChangedRows() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        for index in 0..<40 { _ = try library.captureText("text \(index)") }
        let rows = ShelfRows(store: library, kind: .text)
        guard case .reloaded(let all) = try rows.update() else { return XCTFail("The first update reads the shelf") }
        XCTAssertEqual(all.count, 40)
        guard case .unchanged = try rows.update() else { return XCTFail("Nothing has changed") }
        func note() { rows.note(revision: library.revision, ids: library.changedIDs, kinds: library.changedKinds) }
        // A new capture is one insertion at the front.
        f.date.addTimeInterval(1)
        let captured = try XCTUnwrap(library.captureText("newest"))
        note()
        note()
        guard case .patched(let insert) = try rows.update(), insert.count == 1, case .inserted(let index, let record) = insert[0] else {
            return XCTFail("One insertion")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(record.id, captured.id)
        // A pin keeps its place.
        try library.toggleFavorite([all[10].id])
        note()
        guard case .patched(let replace) = try rows.update(), replace.count == 1, case .replaced(let place, let pinned) = replace[0] else {
            return XCTFail("One replacement")
        }
        XCTAssertEqual(place, 11)
        XCTAssertTrue(pinned.favorite)
        // A recopy moves an old row to the front; a change to another shelf is nothing here.
        f.date.addTimeInterval(1)
        _ = try library.captureText("text 0")
        note()
        _ = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/other-shelf")))
        note()
        guard case .patched(let move) = try rows.update(), move.count == 2, case .removed(40, all[39].id) = move[0],
            case .inserted(0, _) = move[1]
        else {
            return XCTFail("A removal and an insertion")
        }
        // A change that names nothing reads the shelf again.
        _ = try library.createCollection("Folder")
        note()
        guard case .reloaded(let again) = try rows.update() else { return XCTFail("A full read") }
        XCTAssertEqual(again.count, 41)
        XCTAssertEqual(rows.count, 41)
        // Steps made for other rows are refused rather than applied.
        guard case .outOfStep = ShelfRows.apply([.removed(3, UUID())], to: again, id: \.id, make: { $0 }) else {
            return XCTFail("Out of step")
        }
        guard case .outOfStep = ShelfRows.apply([.inserted(99, again[0])], to: again, id: \.id, make: { $0 }) else {
            return XCTFail("Out of step")
        }
    }
}
