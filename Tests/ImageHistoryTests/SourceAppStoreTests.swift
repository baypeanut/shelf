import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

@MainActor final class SourceAppStoreTests: HistoryTestCase {
    private let editor = SourceApp(bundleID: "com.example.Editor", name: "Editor")
    private let browser = SourceApp(bundleID: "com.example.browser", name: "Browser")
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }

    func testSourceIsPersistedForEveryKindAndReturnedAfterReopening() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        var library = try store(f)
        let text = try XCTUnwrap(library.captureText("Synthetic sourced text", source: editor))
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/sourced")), source: browser)
        let image = try library.captureImage(try f.image(), source: editor)
        let plain = try XCTUnwrap(library.captureText("Synthetic unsourced text"))
        XCTAssertEqual(text.source, editor); XCTAssertEqual(link.source, browser); XCTAssertEqual(image.source, editor); XCTAssertNil(plain.source)
        library = try store(f)
        XCTAssertEqual(try library.item(text.id)?.source, editor)
        XCTAssertEqual(try library.item(link.id)?.source, browser)
        XCTAssertEqual(try library.item(image.id)?.source, editor)
        XCTAssertNil(try library.item(plain.id)?.source)
        XCTAssertEqual(try library.shelfItems(.text).first { $0.id == text.id }?.source, editor)
        XCTAssertEqual(try library.sourceApps(), [browser, editor])
    }

    func testSourceFilterMatchesBundleIdentifierWithoutCaseAndCombinesWithOtherFilters() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let text = try XCTUnwrap(library.captureText("Synthetic filter text", source: editor))
        let image = try library.captureImage(try f.image(), source: editor)
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/filter")), source: browser)
        _ = try XCTUnwrap(library.captureText("Synthetic filter text without a source"))
        var query = LibraryQuery(scope: .recent)
        XCTAssertFalse(query.hasFilters)
        query.sourceBundleID = "com.example.editor"
        XCTAssertTrue(query.hasFilters)
        XCTAssertEqual(Set(try library.query(query).map(\.id)), [text.id, image.id])
        XCTAssertEqual(Set(try library.queryIDs(query)), [text.id, image.id])
        query.kind = .text
        XCTAssertEqual(try library.query(query).map(\.id), [text.id])
        query.kind = nil; query.sourceBundleID = browser.bundleID
        XCTAssertEqual(try library.query(query).map(\.id), [link.id])
        query.sourceBundleID = "com.example.unknown"
        XCTAssertTrue(try library.query(query).isEmpty)
    }

    func testRecopyRecordsItsNewSourceAndAnUnknownSourceKeepsTheEarlierOne() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let url = try XCTUnwrap(URL(string: "https://example.com/recopied"))
        let text = try XCTUnwrap(library.captureText("Synthetic recopied text", source: editor))
        let link = try library.captureLink(url, source: editor)
        f.date.addTimeInterval(1)
        XCTAssertEqual(try XCTUnwrap(library.captureText("Synthetic recopied text")).id, text.id)
        XCTAssertEqual(try library.captureLink(url).id, link.id)
        XCTAssertEqual(try library.item(text.id)?.source, editor); XCTAssertEqual(try library.item(link.id)?.source, editor)
        f.date.addTimeInterval(1)
        _ = try library.captureText("Synthetic recopied text", source: browser); _ = try library.captureLink(url, source: browser)
        XCTAssertEqual(try library.item(text.id)?.source, browser); XCTAssertEqual(try library.item(link.id)?.source, browser)
        XCTAssertEqual(try library.sourceApps(), [browser])
    }

    func testEditsKeepTheSourceAndTrashedItemsLeaveTheSourceList() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let text = try XCTUnwrap(library.captureText("Synthetic edited text", source: editor))
        try library.toggleFavorite([text.id]); try library.addTag("source", to: [text.id])
        XCTAssertEqual(try library.item(text.id)?.source, editor)
        var query = LibraryQuery(scope: .saved); query.sourceBundleID = editor.bundleID
        XCTAssertEqual(try library.query(query).map(\.id), [text.id])
        try library.trash([text.id])
        XCTAssertTrue(try library.sourceApps().isEmpty)
        XCTAssertEqual(try library.item(text.id)?.source, editor)
        try library.restore([text.id])
        XCTAssertEqual(try library.sourceApps(), [editor])
    }

    /// The schema an earlier release created, written out literally: no
    /// item_source table, and payloads without any source key.
    private func makePreviousLibrary(_ f: SyntheticFixture, id: UUID) throws -> URL {
        let root = f.inbox.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("library.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        let db = try LibraryDatabase(url: url)
        for sql in [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE items(id TEXT PRIMARY KEY,kind TEXT NOT NULL,created REAL NOT NULL,updated REAL NOT NULL,copied REAL,retained REAL,favorite INTEGER NOT NULL,shelf INTEGER NOT NULL,deleted REAL,path TEXT,normalized TEXT,domain TEXT NOT NULL,sort_title TEXT NOT NULL,search TEXT NOT NULL,payload BLOB NOT NULL)",
            "CREATE INDEX live_image_path ON items(path) WHERE kind='image' AND deleted IS NULL",
            "CREATE INDEX live_link_url ON items(normalized) WHERE kind='link' AND deleted IS NULL",
            "CREATE INDEX item_order ON items(deleted,retained,kind,created DESC)",
            "CREATE INDEX shelf_search_scope ON items(kind,shelf,deleted)",
            "CREATE INDEX shelf_capture_order ON items(kind,shelf,deleted,created)",
            "CREATE TABLE collections(id TEXT PRIMARY KEY,name TEXT NOT NULL,parent TEXT REFERENCES collections(id),folded TEXT NOT NULL)",
            "CREATE TABLE tags(id TEXT PRIMARY KEY,name TEXT NOT NULL,folded TEXT NOT NULL UNIQUE)",
            "CREATE TABLE item_collections(item TEXT REFERENCES items(id),collection TEXT REFERENCES collections(id),PRIMARY KEY(item,collection))",
            "CREATE TABLE item_tags(item TEXT REFERENCES items(id),tag TEXT REFERENCES tags(id),PRIMARY KEY(item,tag))",
            "CREATE INDEX collection_members ON item_collections(collection,item)",
            "CREATE INDEX tag_members ON item_tags(tag,item)",
            "CREATE TABLE text_identity(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,digest BLOB NOT NULL,captured REAL NOT NULL,version INTEGER NOT NULL DEFAULT 1)",
            "CREATE INDEX text_identity_digest ON text_identity(digest)",
            "CREATE INDEX text_identity_expiry ON text_identity(captured)",
            "CREATE TRIGGER text_identity_payload_changed AFTER UPDATE OF payload ON items BEGIN DELETE FROM text_identity WHERE item=NEW.id; END",
            "CREATE VIRTUAL TABLE search_fts USING fts5(id UNINDEXED,content,tokenize='unicode61')",
            "CREATE TABLE image_analysis(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,path TEXT NOT NULL,fingerprint TEXT NOT NULL,version TEXT NOT NULL,content TEXT NOT NULL,ocr TEXT NOT NULL,vectors BLOB NOT NULL)",
            "CREATE TABLE image_markup_garbage(path TEXT PRIMARY KEY)",
            "INSERT INTO metadata VALUES('migration-v1','synthetic')",
            "PRAGMA user_version=1"
        ] { try db.execute(sql) }
        let created = f.date.timeIntervalSince1970
        let payload = "{\"id\":\"\(id.uuidString)\",\"kind\":\"text\",\"createdAt\":\(f.date.timeIntervalSinceReferenceDate),\"updatedAt\":\(f.date.timeIntervalSinceReferenceDate),\"favorite\":true,\"onShelf\":true,\"retainedAt\":\(f.date.timeIntervalSinceReferenceDate),\"title\":\"Legacy title\",\"note\":\"\",\"text\":\"Synthetic legacy text\",\"metadataState\":\"pending\"}"
        try db.execute("INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .text(id.uuidString), .text("text"), .real(created), .real(created), .null, .real(created), .integer(1), .integer(1), .null,
            .null, .null, .text(""), .text("legacy title"), .text("legacy title synthetic legacy text"), .blob(Data(payload.utf8))])
        try db.execute("INSERT INTO search_fts(id,content) VALUES(?,?)", [.text(id.uuidString), .text("legacy title synthetic legacy text")])
        return url
    }

    func testLibraryCreatedWithThePreviousSchemaOpensUnchangedAndThenRecordsSources() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let id = UUID(), url = try makePreviousLibrary(f, id: id)
        do {
            let before = try LibraryDatabase(url: url)
            XCTAssertTrue(try before.rows("SELECT name FROM sqlite_master WHERE name='item_source'").isEmpty)
        }
        let original = try XCTUnwrap(LibraryDatabase(url: url).rows("SELECT payload FROM items WHERE id=?", [.text(id.uuidString)]).first?["payload"]?.data)
        let library = try store(f)
        let legacy = try XCTUnwrap(library.item(id))
        XCTAssertEqual(legacy.text, "Synthetic legacy text"); XCTAssertEqual(legacy.title, "Legacy title")
        XCTAssertTrue(legacy.favorite); XCTAssertEqual(legacy.createdAt, f.date); XCTAssertNil(legacy.source)
        XCTAssertEqual(try library.query(LibraryQuery()).map(\.id), [id])
        XCTAssertEqual(try library.shelfItems(.text).map(\.id), [id])
        XCTAssertTrue(try library.sourceApps().isEmpty)
        // Opening rewrites no existing row and keeps the version an earlier release accepts.
        let reader = try LibraryDatabase(url: url, readOnly: true)
        XCTAssertEqual(try reader.rows("SELECT payload FROM items WHERE id=?", [.text(id.uuidString)]).first?["payload"]?.data, original)
        XCTAssertEqual(try reader.rows("PRAGMA user_version").first?["user_version"]?.number, 1)
        XCTAssertEqual(try reader.rows("SELECT name FROM sqlite_master WHERE name='item_source'").count, 1)
        var query = LibraryQuery(); query.sourceBundleID = editor.bundleID
        XCTAssertTrue(try library.query(query).isEmpty)
        // The legacy row gains a source when it is copied again, and new rows record theirs.
        f.date.addTimeInterval(1)
        XCTAssertEqual(try XCTUnwrap(library.captureText("Synthetic legacy text", source: editor)).id, id)
        let fresh = try XCTUnwrap(library.captureText("Synthetic new text", source: browser))
        XCTAssertEqual(try library.query(query).map(\.id), [id])
        XCTAssertEqual(try library.item(id)?.title, "Legacy title")
        XCTAssertEqual(try store(f).item(fresh.id)?.source, browser)
        XCTAssertEqual(try store(f).sourceApps(), [browser, editor])
    }

    func testPayloadRewrittenByAnEarlierReleaseDropsTheStaleSourceIndexRow() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let text = try XCTUnwrap(library.captureText("Synthetic rollback text", source: editor))
        XCTAssertEqual(try library.sourceApps(), [editor])
        // An earlier release decodes the record without its source and writes it back.
        let old = try LibraryDatabase(url: library.databaseURL)
        let payload = "{\"id\":\"\(text.id.uuidString)\",\"kind\":\"text\",\"createdAt\":\(text.createdAt.timeIntervalSinceReferenceDate),\"updatedAt\":\(text.updatedAt.timeIntervalSinceReferenceDate),\"favorite\":false,\"onShelf\":true,\"title\":\"\",\"note\":\"edited by an earlier release\",\"text\":\"Synthetic rollback text\",\"metadataState\":\"pending\"}"
        try old.execute("UPDATE items SET payload=? WHERE id=?", [.blob(Data(payload.utf8)), .text(text.id.uuidString)])
        XCTAssertNil(try library.item(text.id)?.source)
        XCTAssertTrue(try library.sourceApps().isEmpty)
        var query = LibraryQuery(scope: .recent); query.sourceBundleID = editor.bundleID
        XCTAssertTrue(try library.query(query).isEmpty)
    }
}
