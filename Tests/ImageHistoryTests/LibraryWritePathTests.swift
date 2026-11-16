import Combine
import Foundation

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// Only temporary folders and disposable preferences.
@MainActor final class LibraryWritePathTests: HistoryTestCase {
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture()
        value.date = Date(timeIntervalSince1970: 1_700_000_000)
        return value
    }
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }

    func testTitleOfATextIsStillItsFirstLine() {
        var generator = SeededGenerator(seed: 0x717)
        var texts = [
            "", "\n", "\n\nsecond", "one line", "first\nsecond", "  padded \t\nsecond", "crlf stays one line\r\nsecond", "\r\n",
            "tab\tinside",
        ]
        texts.append(String(repeating: "long ", count: 80) + "\nsecond")
        for _ in 0..<200 { texts.append(SyntheticLibraryCorpus.text(&generator, bytes: 1 + generator.index(300))) }
        for text in texts {
            var record = LibraryRecord(id: UUID(), kind: .text, createdAt: Date(), updatedAt: Date())
            record.text = text
            // The definition this replaced: split the whole text into lines and take the first.
            let expected = String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces).prefix(120).description
            XCTAssertEqual(record.displayTitle, expected, text)
        }
    }

    func testEachChangeReportsItsItemsAndTheirKindsOnce() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        var seen = [(ids: Set<UUID>, kinds: Set<LibraryKind>)]()
        let observation = library.$revision.dropFirst().sink { _ in seen.append((library.changedIDs, library.changedKinds)) }
        defer { observation.cancel() }
        let text = try XCTUnwrap(library.captureText("synthetic note"))
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/a")))
        let image = try library.captureImage(f.image())
        XCTAssertEqual(seen.map(\.kinds), [[.text], [.link], [.image]])
        XCTAssertEqual(seen.map(\.ids), [[text.id], [link.id], [image.id]])
        seen.removeAll()
        try library.toggleFavorite([text.id, image.id])
        XCTAssertEqual(seen.last?.kinds, [.text, .image])
        try library.trash([link.id])
        XCTAssertEqual(seen.last?.kinds, [.link])
        // Purged items no longer have a row to read a kind from.
        XCTAssertEqual(try library.emptyTrash(), [link.id])
        XCTAssertEqual(seen.last?.kinds, [.link])
        XCTAssertEqual(seen.last?.ids, [link.id])
        // More items than one query names, and a change that names none.
        var many = [UUID]()
        for index in 0..<1_100 { many.append(try XCTUnwrap(library.captureText("bulk synthetic \(index)")).id) }
        seen.removeAll()
        try library.toggleFavorite(many + [image.id])
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.last?.kinds, [.text, .image])
        XCTAssertEqual(seen.last?.ids.count, 1_101)
        _ = try library.createCollection("Folder")
        XCTAssertEqual(seen.last?.kinds, Set(LibraryKind.allCases))
        XCTAssertEqual(seen.last?.ids, [])
    }

    func testRecaptureFindsExistingItemsThroughTheirIndexes() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let file = try f.image()
        let image = try library.captureImage(file)
        let url = try XCTUnwrap(URL(string: "https://example.com/path?item=1"))
        let link = try library.captureLink(url)
        for index in 0..<50 {
            _ = try library.captureText("filler \(index)")
            _ = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/other/\(index)")))
        }
        XCTAssertEqual(try library.captureImage(file).id, image.id)
        XCTAssertEqual(try library.captureLink(url).id, link.id)
        // A trashed copy is not reused; a new item is made beside it.
        try library.trash([image.id, link.id])
        let newImage = try library.captureImage(file)
        let newLink = try library.captureLink(url)
        XCTAssertTrue(newImage.id != image.id)
        XCTAssertTrue(newLink.id != link.id)
        XCTAssertEqual(try library.captureImage(file).id, newImage.id)
        XCTAssertEqual(try library.captureLink(url).id, newLink.id)
        // The lookups are answered by the partial indexes, not by reading every item.
        let database = try LibraryDatabase(url: library.databaseURL, verify: false)
        func plan(_ sql: String) throws -> String {
            try database.rows("EXPLAIN QUERY PLAN " + sql, [.text("x")]).compactMap { $0["detail"]?.string }.joined(separator: " ")
        }
        XCTAssertTrue(
            try plan("SELECT payload FROM items INDEXED BY live_image_path WHERE kind='image' AND path=? AND deleted IS NULL").contains(
                "live_image_path"))
        XCTAssertTrue(
            try plan("SELECT payload FROM items INDEXED BY live_link_url WHERE kind='link' AND normalized=? AND deleted IS NULL").contains(
                "live_link_url"))
    }

    func testWritesOnAnotherConnectionDoNotDisturbTextIdentityAndForeignEditsAreStillRepaired() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let first = try XCTUnwrap(library.captureText("Repeated synthetic text"))
        let other = try XCTUnwrap(library.captureText("Another synthetic text"))
        let image = try library.captureImage(f.image())
        // Another connection writes something unrelated, as the image indexer does.
        let foreign = try LibraryDatabase(url: library.databaseURL, verify: false)
        try foreign.execute(
            "INSERT INTO image_analysis VALUES(?,?,?,?,?,?,?)",
            [
                .text(image.id.uuidString), .text(image.path ?? ""), .text("f"), .text("v"), .text("synthetic"), .text("synthetic"),
                .blob(Data()),
            ])
        f.date.addTimeInterval(1)
        XCTAssertEqual(try library.captureText("Repeated synthetic text")?.id, first.id)
        // An older build edits a text: its trigger drops the identity row, which a recopy must not miss.
        var edited = try XCTUnwrap(library.item(other.id))
        edited.text = "Edited by an older build"
        try foreign.execute("UPDATE items SET payload=? WHERE id=?", [.blob(try JSONEncoder().encode(edited)), .text(other.id.uuidString)])
        XCTAssertEqual(
            try foreign.rows("SELECT count(*) AS n FROM text_identity WHERE item=?", [.text(other.id.uuidString)]).first?["n"]?.number, 0)
        f.date.addTimeInterval(1)
        XCTAssertEqual(try library.captureText("Edited by an older build")?.id, other.id)
        XCTAssertEqual(try foreign.rows("SELECT count(*) AS n FROM text_identity").first?["n"]?.number, 2)
        XCTAssertEqual(try library.shelfItems(.text).count, 2)
    }
}
