import CryptoKit
import Foundation

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// A library file as the build before the search index wrote it: the same
/// statements, the same derived rows, and the `search_fts` table that build
/// rewrote on every save.
enum PreviousLibrary {
    static let schema = [
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
        "CREATE TABLE item_source(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,bundle TEXT NOT NULL COLLATE NOCASE,name TEXT NOT NULL)",
        "CREATE INDEX item_source_bundle ON item_source(bundle)",
        "CREATE TRIGGER item_source_payload_changed AFTER UPDATE OF payload ON items BEGIN DELETE FROM item_source WHERE item=NEW.id; END",
        "CREATE VIRTUAL TABLE search_fts USING fts5(id UNINDEXED,content,tokenize='unicode61')",
        "CREATE TABLE image_analysis(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,path TEXT NOT NULL,fingerprint TEXT NOT NULL,version TEXT NOT NULL,content TEXT NOT NULL,ocr TEXT NOT NULL,vectors BLOB NOT NULL)",
        "CREATE TABLE image_markup_garbage(path TEXT PRIMARY KEY)",
        "INSERT INTO metadata VALUES('migration-v1','synthetic')",
        "INSERT INTO metadata VALUES('text-identity-v2','complete')",
        "PRAGMA user_version=1",
    ]

    /// What that build's save wrote for one record.
    static func save(_ item: LibraryRecord, tagNames: String = "", isNew: Bool = false, in database: LibraryDatabase) throws {
        let imageName =
            item.kind == .image
            ? (item.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.fileURL?.lastPathComponent ?? "") : ""
        let content = [
            item.displayTitle, imageName, item.metadataTitle ?? "", item.text ?? "", item.note, item.originalURL ?? "", tagNames,
        ]
        .joined(separator: " ").libraryFolded
        try database.execute(
            "INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,created=excluded.created,updated=excluded.updated,copied=excluded.copied,retained=excluded.retained,favorite=excluded.favorite,shelf=excluded.shelf,deleted=excluded.deleted,path=excluded.path,normalized=excluded.normalized,domain=excluded.domain,sort_title=excluded.sort_title,search=excluded.search,payload=excluded.payload",
            [
                .text(item.id.uuidString), .text(item.kind.rawValue), .real(item.createdAt.timeIntervalSince1970),
                .real(item.updatedAt.timeIntervalSince1970),
                item.lastCopiedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                item.retainedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .integer(item.favorite ? 1 : 0), .integer(item.onShelf ? 1 : 0),
                item.deletedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                item.path.map(SQLValue.text) ?? .null, item.normalizedURL.map(SQLValue.text) ?? .null,
                .text(item.linkURL?.host?.lowercased() ?? ""),
                .text(item.displayTitle.libraryFolded), .text(content), .blob(try JSONEncoder().encode(item)),
            ])
        if item.kind == .text, let text = item.text {
            try database.execute(
                "INSERT INTO text_identity(item,digest,captured,version) VALUES(?,?,?,?) ON CONFLICT(item) DO UPDATE SET digest=excluded.digest,captured=excluded.captured,version=excluded.version",
                [
                    .text(item.id.uuidString), .blob(Data(SHA256.hash(data: Data(TextIdentity.key(text).utf8)))),
                    .real((item.lastCapturedAt ?? item.createdAt).timeIntervalSince1970), .integer(TextIdentity.version),
                ])
        }
        // That build looked for an earlier row by reading the whole table; a new library has none.
        if !isNew { try database.execute("DELETE FROM search_fts WHERE id=?", [.text(item.id.uuidString)]) }
        try database.execute("INSERT INTO search_fts(id,content) VALUES(?,?)", [.text(item.id.uuidString), .text(content)])
    }

    @MainActor @discardableResult static func make(_ f: SyntheticFixture, records: [LibraryRecord]) throws -> URL {
        let root = f.inbox.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(url: url)
        try database.execute("PRAGMA secure_delete=ON")
        for sql in schema { try database.execute(sql) }
        try database.transaction { for record in records { try save(record, isNew: true, in: database) } }
        return url
    }
}

/// Only temporary folders and disposable preferences.
@MainActor final class LibrarySearchIndexTests: HistoryTestCase {
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture()
        value.date = Date(timeIntervalSince1970: 1_700_000_000)
        return value
    }
    private func store(_ f: SyntheticFixture, background: Bool = true) throws -> LibraryStore {
        try LibraryStore(
            defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder), backgroundMaintenance: background)
    }
    private func corpus(_ f: SyntheticFixture, count: Int, seed: UInt64) throws -> [LibraryRecord] {
        var mix = SyntheticLibraryCorpus.Mix()
        mix.largeBytes = 6_000
        mix.largeTexts = 0.03
        mix.offShelf = 0.3
        var records = try SyntheticLibraryCorpus.records(count: count, seed: seed, inbox: f.inbox, end: f.date, mix: mix)
        // Texts the index cannot hold or cannot narrow.
        for (offset, text) in ["meeting\u{0}notes after a NUL istanbul", "ab", "é", "", "中文", "a\"b\"c \"\"\" quoted"].enumerated() {
            var record = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date.addingTimeInterval(Double(offset)), updatedAt: f.date)
            record.text = text
            records.append(record)
        }
        return records
    }
    private func recognize(_ records: [LibraryRecord], in url: URL, seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed)
        let database = try LibraryDatabase(url: url, verify: false)
        try database.transaction {
            for record in records where record.kind == .image && generator.index(2) == 0 {
                let text = SyntheticLibraryCorpus.text(&generator, bytes: 200)
                // One in five describes a file the item no longer points to.
                let path = generator.index(5) == 0 ? "/synthetic/stale.png" : record.path ?? ""
                try database.execute(
                    "INSERT INTO image_analysis(item,path,fingerprint,version,content,ocr,vectors) VALUES(?,?,?,?,?,?,?)",
                    [
                        .text(record.id.uuidString), .text(path), .text("synthetic"), .text("vision-ocr-v1"), .text(text.libraryFolded),
                        .text(text),
                        .blob(Data()),
                    ])
            }
        }
    }

    /// Runs seeded random searches twice, once through the index and once by
    /// reading every item, and requires the same items in the same order.
    private func compare(
        _ library: LibraryStore, queries: Int, seed: UInt64, ids: [UUID], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var generator = SeededGenerator(seed: seed)
        let folders = try library.collections().map(\.id)
        let tags = try library.tags().map(\.id)
        var scopes: [LibraryQuery.Scope] = [.saved, .favorites, .unorganized, .recent, .shelf, .trash, .recent, .shelf, .saved]
        scopes += folders.map { .collection($0) } + tags.map { .tag($0) }
        var narrowed = 0
        var matched = 0
        for number in 0..<queries {
            var query = LibraryQuery(scope: scopes[generator.index(scopes.count)])
            // One in twenty browses without searching; paging must agree there too.
            query.search = generator.index(20) == 0 ? "" : SyntheticLibraryCorpus.query(&generator)
            query.kind = [nil, nil, .text, .text, .image, .link][generator.index(6)]
            query.sort = LibraryQuery.Sort.allCases[generator.index(LibraryQuery.Sort.allCases.count)]
            query.searchMode = [.all, .text, .text, .text, .visual][generator.index(5)]
            if query.searchMode != .text, generator.index(2) == 0 { query.visualIDs = (0..<4).map { _ in ids[generator.index(ids.count)] } }
            query.favoritesOnly = generator.index(9) == 0
            if generator.index(12) == 0 { query.days = 1 }
            let offset = generator.index(3) * 7
            library.searchIndexDisabled = true
            let expected = try library.queryIDs(query)
            let expectedPage = try library.query(query, limit: 20, offset: offset).map(\.id)
            library.searchIndexDisabled = false
            let actual = try library.queryIDs(query)
            let actualPage = try library.query(query, limit: 20, offset: offset).map(\.id)
            guard actual == expected, actualPage == expectedPage else {
                XCTFail("Search \(number) with seed \(seed) differs: \(query)", file: file, line: line)
                return
            }
            if query.search.libraryFolded.split(whereSeparator: \.isWhitespace).contains(where: {
                LibrarySearchIndex.match(String($0)) != nil
            }) {
                narrowed += 1
            }
            if !expected.isEmpty { matched += 1 }
        }
        XCTAssertTrue(narrowed * 3 > queries, "Most searches should have gone through the index", file: file, line: line)
        XCTAssertTrue(matched * 5 > queries, "Many searches should have had results", file: file, line: line)
    }
    /// Every item is in the index or listed as outside it, never both, and the
    /// index agrees with itself.
    private func assertIndexCoversEveryItem(_ library: LibraryStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let database = try LibraryDatabase(url: library.databaseURL, verify: false)
        func number(_ sql: String) throws -> Int64? { try database.rows(sql).first?["n"]?.number }
        let items = try number("SELECT count(*) AS n FROM items")
        XCTAssertEqual(
            try number("SELECT (SELECT count(*) FROM search_docs)+(SELECT count(*) FROM search_unindexed) AS n"), items, file: file,
            line: line)
        XCTAssertEqual(
            try number(
                "SELECT count(*) AS n FROM items i WHERE (SELECT count(*) FROM search_docs d WHERE d.item=i.id)+(SELECT count(*) FROM search_unindexed u WHERE u.item=i.id)<>1"
            ), 0, file: file, line: line)
        try database.execute("INSERT INTO search_trigram(search_trigram) VALUES('integrity-check')")
        XCTAssertEqual(try database.rows("PRAGMA quick_check").first?.values.first?.string, "ok", file: file, line: line)
    }
    private func rows(_ url: URL, _ sql: String) throws -> [String] {
        try LibraryDatabase(url: url, verify: false).rows(sql).map { row in
            row.keys.sorted().map { key -> String in
                switch row[key] {
                case .text(let value)?: return value
                case .blob(let value)?: return value.base64EncodedString()
                case .integer(let value)?: return String(value)
                case .real(let value)?: return String(value.bitPattern)
                default: return "null"
                }
            }.joined(separator: "|")
        }
    }

    func testTermsBecomeQuotedTrigramsAndShortOrUnsafeTermsAreNotNarrowed() {
        XCTAssertNil(LibrarySearchIndex.match(""))
        XCTAssertNil(LibrarySearchIndex.match("ab"))
        XCTAssertNil(LibrarySearchIndex.match("中文"))
        XCTAssertNil(LibrarySearchIndex.match("ab\u{0}cd"))
        XCTAssertEqual(LibrarySearchIndex.match("abc"), "\"abc\"")
        XCTAssertEqual(LibrarySearchIndex.match("abcab"), "\"abc\" AND \"bca\" AND \"cab\"")
        XCTAssertEqual(LibrarySearchIndex.match("aaaaa"), "\"aaa\"")
        XCTAssertEqual(LibrarySearchIndex.match("東京都渋"), "\"東京都\" AND \"京都渋\"")
        XCTAssertEqual(LibrarySearchIndex.match("a\"b"), "\"a\"\"b\"")
        // A combining mark after a quotation mark is still an escaped quotation mark.
        XCTAssertEqual(LibrarySearchIndex.match("\"\u{301}x"), "\"\"\"\u{301}x\"")
        let long = LibrarySearchIndex.match(String((0..<200).map { Character(UnicodeScalar(0x4E00 + $0)!) }))
        XCTAssertEqual(long?.components(separatedBy: " AND ").count, 24)
    }

    func testIndexedSearchReturnsExactlyWhatReadingEveryItemReturns() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let records = try corpus(f, count: 900, seed: 0xD1FF)
        try library.importRecords(records)
        XCTAssertEqual(library.searchIndexComplete, true)
        try recognize(records, in: library.databaseURL, seed: 7)
        let live = records.filter { $0.deletedAt == nil }
        let folder = try library.createCollection("Folder")
        let child = try library.createCollection("Child", parent: folder)
        try library.assign(live.prefix(40).map(\.id), to: folder)
        try library.assign(live.dropFirst(40).prefix(25).map(\.id), to: child)
        try library.addTag("İŞ takibi", to: live.dropFirst(20).prefix(60).map(\.id))
        try library.addTag("quarterly", to: live.dropFirst(100).prefix(30).map(\.id))
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 2_500, seed: 0xA11CE, ids: records.map(\.id))

        // Every kind of write, then the same comparison.
        var generator = SeededGenerator(seed: 99)
        for record in live.prefix(120) {
            f.date.addTimeInterval(1)
            switch generator.index(7) {
            case 0: try library.update(record.id) { $0.note = SyntheticLibraryCorpus.text(&generator, bytes: 40) }
            case 1: try library.update(record.id) { $0.title = "Çekim " + SyntheticLibraryCorpus.word(&generator) }
            case 2: try library.trash([record.id])
            case 3: try library.toggleFavorite([record.id])
            case 4:
                if record.kind == .text { try library.update(record.id) { $0.text = SyntheticLibraryCorpus.text(&generator, bytes: 300) } }
            case 5: try library.removeFromShelf([record.id])
            default: if let text = record.text, !text.isEmpty { _ = try library.captureText(text) }
            }
        }
        for index in 0..<40 { _ = try library.captureText("new " + SyntheticLibraryCorpus.text(&generator, bytes: 30 + index)) }
        try library.renameTag(try XCTUnwrap(library.tags().first { $0.name == "quarterly" }).id, name: "Ångström")
        try library.restore(Array(records.filter { $0.deletedAt != nil }.prefix(10).map(\.id)))
        XCTAssertFalse(try library.emptyTrash().isEmpty)
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 1_500, seed: 0xB0B, ids: records.map(\.id))

        // Compaction renumbers the rows of `items`; the index must not care.
        var compacted: Bool?
        library.compact { compacted = $0 }
        let end = Date().addingTimeInterval(20)
        while compacted == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(compacted, true)
        _ = try library.captureText("captured after compaction istanbul")
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 600, seed: 0xC0FFEE, ids: records.map(\.id))
        // The same library, reopened.
        try compare(try store(f), queries: 300, seed: 0xD00D, ids: records.map(\.id))
    }

    func testSearchAgreesWithAnIndependentReadingOfTheStoredText() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let library = try store(f)
        let records = try corpus(f, count: 400, seed: 0x0A7)
        try library.importRecords(records)
        try recognize(records, in: library.databaseURL, seed: 3)
        let database = try LibraryDatabase(url: library.databaseURL, verify: false)
        // NUL-bearing text is compared by SQLite only; a C string would cut it short here.
        let stored = try database.rows(
            "SELECT i.id,i.search,i.path,a.path AS analysis_path,a.content FROM items i LEFT JOIN image_analysis a ON a.item=i.id WHERE i.deleted IS NULL AND i.retained IS NULL AND instr(CAST(i.search AS BLOB),x'00')=0"
        )
        var generator = SeededGenerator(seed: 0x51)
        for _ in 0..<400 {
            let text = SyntheticLibraryCorpus.query(&generator)
            let terms = text.libraryFolded.split(whereSeparator: \.isWhitespace).map { Data(String($0).utf8) }
            guard !terms.isEmpty, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { continue }
            let expected = Set(
                stored.compactMap { row -> UUID? in
                    let search = Data((row["search"]?.string ?? "").utf8)
                    let recognized =
                        row["analysis_path"]?.string == row["path"]?.string ? row["content"]?.string.map { Data($0.utf8) } : nil
                    let matches = terms.allSatisfy { search.range(of: $0) != nil || recognized?.range(of: $0) != nil }
                    return matches ? row["id"]?.string.flatMap(UUID.init(uuidString:)) : nil
                })
            var query = LibraryQuery(scope: .recent, search: text)
            query.searchMode = .text
            let found = Set(try library.queryIDs(query)).filter { id in stored.contains { $0["id"]?.string == id.uuidString } }
            XCTAssertEqual(found, expected, text)
        }
    }

    func testLibraryFromThePreviousBuildIsSnapshottedThenIndexedInTheBackgroundAndItsOldSearchTableRemoved() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let records = try corpus(f, count: 500, seed: 0x1E6)
        let url = try PreviousLibrary.make(f, records: records)
        try recognize(records, in: url, seed: 5)
        let itemsBefore = try rows(url, "SELECT * FROM items ORDER BY id")
        let identitiesBefore = try rows(url, "SELECT * FROM text_identity ORDER BY item")
        XCTAssertEqual(itemsBefore.count, records.count)
        XCTAssertEqual(try rows(url, "SELECT count(*) AS n FROM search_fts"), ["\(records.count)"])

        let library = try store(f)
        // The copy was made before anything changed: it has the old table and no index.
        let snapshot = try XCTUnwrap(library.snapshots.all().first)
        XCTAssertEqual(library.snapshots.all().count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try LibraryDatabase(url: snapshot, readOnly: true).rows("PRAGMA quick_check").first?.values.first?.string, "ok")
        XCTAssertEqual(try rows(snapshot, "SELECT * FROM items ORDER BY id"), itemsBefore)
        XCTAssertEqual(try rows(snapshot, "SELECT count(*) AS n FROM search_fts"), ["\(records.count)"])
        XCTAssertTrue(try rows(snapshot, "SELECT name FROM sqlite_master WHERE name LIKE 'search_index%' OR name='search_docs'").isEmpty)

        // Searches are already correct while the index catches up.
        try compare(library, queries: 150, seed: 0xFEED, ids: records.map(\.id))
        library.waitForMaintenance()
        XCTAssertEqual(library.searchIndexComplete, true)
        XCTAssertTrue(
            try rows(url, "SELECT name FROM sqlite_master WHERE name LIKE 'search_fts%'").isEmpty, "The unused table and its parts are gone"
        )
        XCTAssertEqual(try rows(url, "SELECT * FROM items ORDER BY id"), itemsBefore, "No item changed")
        XCTAssertEqual(try rows(url, "SELECT * FROM text_identity ORDER BY item"), identitiesBefore)
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 1_200, seed: 0xBEEF, ids: records.map(\.id))

        // The next launch has nothing left to do and makes no second copy.
        let reopened = try store(f)
        XCTAssertEqual(reopened.searchIndexComplete, true)
        XCTAssertEqual(reopened.snapshots.all(), [snapshot])
        XCTAssertEqual(try reopened.query(LibraryQuery(scope: .trash), limit: 10_000).count, records.filter { $0.deletedAt != nil }.count)
    }

    func testCatchUpStopsAndResumesAndSearchStaysExactThroughout() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let records = try corpus(f, count: 400, seed: 0x5EED)
        let url = try PreviousLibrary.make(f, records: records)
        let ids = records.map(\.id)
        var generator = SeededGenerator(seed: 12)
        do {
            let library = try store(f, background: false)
            XCTAssertEqual(library.searchIndexComplete, false)
            XCTAssertEqual(try rows(url, "SELECT count(*) AS n FROM search_docs"), ["0"])
            try compare(library, queries: 200, seed: 1, ids: ids)
            // A few steps, then a quit.
            let worker = try LibraryDatabase(url: url, verify: false)
            XCTAssertFalse(try LibrarySearchIndex.maintain(worker, status: LibrarySearchIndex.Status(), pause: 0, steps: 9))
            XCTAssertEqual(library.searchIndexComplete, false)
            try compare(library, queries: 200, seed: 2, ids: ids)
            // Writes land on items that are indexed, not yet indexed and new.
            for record in records.filter({ $0.deletedAt == nil }).prefix(60) + records.suffix(30) {
                f.date.addTimeInterval(1)
                switch generator.index(4) {
                case 0: try library.update(record.id) { $0.note = "edited " + SyntheticLibraryCorpus.text(&generator, bytes: 30) }
                case 1: try library.trash([record.id])
                case 2: try library.toggleFavorite([record.id])
                default: _ = try library.captureText("during catch-up " + SyntheticLibraryCorpus.text(&generator, bytes: 30))
                }
            }
            XCTAssertEqual(library.snapshots.all().count, 1)
            _ = try library.purgeTrash(olderThan: f.date)
            try compare(library, queries: 300, seed: 3, ids: ids)
            XCTAssertFalse(try LibrarySearchIndex.maintain(worker, status: LibrarySearchIndex.Status(), pause: 0, steps: 5))
            try compare(library, queries: 200, seed: 4, ids: ids)
        }
        // The next launch continues from what is stored, in the background.
        let library = try store(f)
        XCTAssertEqual(library.snapshots.all().count, 1, "Catching up is not a second storage change")
        library.waitForMaintenance()
        XCTAssertEqual(library.searchIndexComplete, true)
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 800, seed: 5, ids: ids)
        XCTAssertTrue(try rows(url, "SELECT name FROM sqlite_master WHERE name LIKE 'search_fts%'").isEmpty)
    }

    func testWithoutASnapshotNothingChangesAndSearchStillWorks() throws {
        let f = try fixture()
        defer { f.cleanup() }
        var records = try corpus(f, count: 120, seed: 0xFA11)
        let marker = "zqlegacy" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var secret = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date, updatedAt: f.date)
        secret.text = "First line\nBefore \(marker) after"
        records.append(secret)
        let url = try PreviousLibrary.make(f, records: records)
        let schemaBefore = try rows(url, "SELECT type,name,sql FROM sqlite_master ORDER BY name")
        let itemsBefore = try rows(url, "SELECT * FROM items ORDER BY id")
        let searchBefore = try rows(url, "SELECT id,content FROM search_fts ORDER BY id")
        // Something is in the way of the snapshot folder.
        let obstacle = f.inbox.appendingPathComponent("Library/Snapshots")
        try Data("synthetic".utf8).write(to: obstacle)
        do {
            let library = try store(f)
            library.waitForMaintenance()
            XCTAssertNil(library.searchIndexComplete)
            XCTAssertEqual(try rows(url, "SELECT type,name,sql FROM sqlite_master ORDER BY name"), schemaBefore)
            XCTAssertEqual(try rows(url, "SELECT * FROM items ORDER BY id"), itemsBefore)
            XCTAssertEqual(try rows(url, "SELECT id,content FROM search_fts ORDER BY id"), searchBefore)
            XCTAssertEqual(try Data(contentsOf: obstacle), Data("synthetic".utf8))
            // The library is fully usable on the old path.
            var query = LibraryQuery(scope: .recent, search: "istanbul")
            query.searchMode = .text
            let found = try library.queryIDs(query)
            XCTAssertFalse(found.isEmpty)
            library.searchIndexDisabled = true
            XCTAssertEqual(try library.queryIDs(query), found)
            library.searchIndexDisabled = false
            let captured = try XCTUnwrap(library.captureText("captured without an index"))
            query.search = "without an index"
            XCTAssertEqual(try library.queryIDs(query), [captured.id])
            query.search = marker
            XCTAssertEqual(try library.queryIDs(query), [secret.id])
            // The old table keeps no text that an edit or a purge removed.
            let edited = try XCTUnwrap(records.first { $0.kind == .text && $0.deletedAt == nil })
            try library.update(edited.id) { $0.text = "rewritten" }
            XCTAssertEqual(try rows(url, "SELECT count(*) AS n FROM search_fts WHERE id='\(edited.id.uuidString)'"), ["0"])
            try library.trash([secret.id])
            XCTAssertTrue(try library.emptyTrash().contains(secret.id))
            let bytes = try Data(contentsOf: url) + ((try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data())
            XCTAssertNil(bytes.range(of: Data(marker.utf8)))
        }
        // Once the snapshot can be made, the next launch finishes the job.
        try FileManager.default.removeItem(at: obstacle)
        let library = try store(f)
        library.waitForMaintenance()
        XCTAssertEqual(library.searchIndexComplete, true)
        XCTAssertEqual(library.snapshots.all().count, 1)
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 300, seed: 6, ids: records.map(\.id))
    }

    func testWritesByThePreviousBuildKeepTheIndexCurrent() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let records = try corpus(f, count: 150, seed: 0x01D)
        let url = try PreviousLibrary.make(f, records: records)
        do {
            let library = try store(f)
            library.waitForMaintenance()
            XCTAssertEqual(library.searchIndexComplete, true)
        }
        // The previous build opens the library again: it recreates its table
        // and saves, edits and deletes without knowing about the index.
        let previous = try LibraryDatabase(url: url)
        try previous.execute("CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(id UNINDEXED,content,tokenize='unicode61')")
        var added = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date, updatedAt: f.date)
        added.text = "written by the previous build zebrafinch"
        var edited = try XCTUnwrap(records.first { $0.kind == .text && $0.deletedAt == nil && $0.retainedAt == nil })
        edited.text = "edited by the previous build kingfisher"
        let removed = try XCTUnwrap(records.last { $0.kind == .text && $0.deletedAt == nil && $0.retainedAt == nil && $0.id != edited.id })
        try previous.transaction {
            try PreviousLibrary.save(added, in: previous)
            try PreviousLibrary.save(edited, in: previous)
            try previous.execute("DELETE FROM search_fts WHERE id=?", [.text(removed.id.uuidString)])
            try previous.execute("DELETE FROM text_identity WHERE item=?", [.text(removed.id.uuidString)])
            try previous.execute("DELETE FROM items WHERE id=?", [.text(removed.id.uuidString)])
        }
        try previous.execute("VACUUM")
        let library = try store(f)
        library.waitForMaintenance()
        func found(_ text: String) throws -> [UUID] {
            var query = LibraryQuery(scope: .recent, search: text)
            query.searchMode = .text
            return try library.queryIDs(query)
        }
        XCTAssertEqual(try found("zebrafinch"), [added.id])
        XCTAssertEqual(try found("kingfisher"), [edited.id])
        XCTAssertTrue(
            try rows(url, "SELECT name FROM sqlite_master WHERE name LIKE 'search_fts%'").isEmpty, "Its recreated table is cleared again")
        XCTAssertEqual(library.snapshots.all().count, 1)
        try assertIndexCoversEveryItem(library)
        try compare(library, queries: 400, seed: 8, ids: records.map(\.id))
    }

    func testPurgedTextLeavesTheMigratedDatabaseAndASaveStoresTextOnlyTwice() throws {
        let f = try fixture()
        defer { f.cleanup() }
        var records = try corpus(f, count: 60, seed: 0xB17E)
        let marker = "zqindex" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var secret = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date, updatedAt: f.date)
        // Short enough to sit in one page, so each stored copy is one unbroken match.
        secret.text = "First line\nBefore \(marker) after"
        records.append(secret)
        let url = try PreviousLibrary.make(f, records: records)
        func occurrences() throws -> Int {
            let bytes = try Data(contentsOf: url) + ((try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data())
            let needle = Data(marker.utf8)
            var count = 0
            var range = bytes.startIndex..<bytes.endIndex
            while let found = bytes.range(of: needle, in: range) {
                count += 1
                range = found.upperBound..<bytes.endIndex
            }
            return count
        }
        // Stored by the previous build: the record, its folded text, and the search table's own copy.
        _ = try? LibraryDatabase(url: url, verify: false).rows("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertTrue(try occurrences() >= 3)
        let library = try store(f)
        library.waitForMaintenance()
        XCTAssertEqual(try occurrences(), 2, "The record and its folded text; the search table's copy is gone and the index stores no text")
        let fresh = try XCTUnwrap(library.captureText("Fresh line\n\(marker)"))
        _ = try? LibraryDatabase(url: url, verify: false).rows("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertEqual(try occurrences(), 4)
        try library.trash([secret.id, fresh.id])
        XCTAssertTrue(Set(try library.emptyTrash()).isSuperset(of: [secret.id, fresh.id]))
        XCTAssertEqual(try occurrences(), 0)
        XCTAssertTrue(library.snapshots.all().isEmpty)
        try assertIndexCoversEveryItem(library)
    }
}
