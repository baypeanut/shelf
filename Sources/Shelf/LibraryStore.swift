import Foundation
import Combine
import CryptoKit
import Darwin
import SQLite3

enum LibraryKind: String, Codable, CaseIterable { case image, text, link }
/// Capture versions protect a recopy that reuses a deduplicated identity.
struct UnsavedHistorySnapshot: Equatable {
    let kind: LibraryKind?
    let ids: [UUID]
    let captures: [UUID: String]
}
struct LibraryRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: LibraryKind
    var createdAt: Date
    var updatedAt: Date
    var lastCopiedAt: Date?
    var lastCapturedAt: Date?
    /// Optional for existing libraries; unrelated edits preserve this value.
    var captureRevision: UUID?
    /// A recoverable-trash generation, independent of capture identity. Older
    /// records need no migration; every new trash transition gets a fresh value.
    var trashRevision: UUID?
    var retainedAt: Date?
    var favorite = false
    var onShelf = true
    var deletedAt: Date?
    var title = ""
    var note = ""
    var text: String?
    var path: String?
    var originalPath: String?
    /// Vectors are separate from the full-resolution flattened PNG used by
    /// copy/export/OCR. The first unmarked pixels remain in a managed file.
    var imageMarkup: ImageMarkupDocument?
    var markupBasePath: String?
    /// First private recording bytes survive every later trim. originalPath
    /// remains filename/provenance metadata and is never used as a backup.
    var recordingOriginalPath: String?
    var originalURL: String?
    var normalizedURL: String?
    var thumbnailPath: String?
    var metadataTitle: String?
    var author: String?
    var metadataState = "pending"
    var metadataAttemptedAt: Date?
    /// The application the latest capture came from. Optional: records made
    /// before sources were recorded, screenshots and unattributed copies have
    /// none, and unrelated edits preserve the value.
    var sourceBundleID: String?
    var sourceName: String?
    var source: SourceApp? {
        get { sourceBundleID.map { SourceApp(bundleID: $0, name: sourceName ?? $0) } }
        set { sourceBundleID = newValue?.bundleID; sourceName = newValue?.name }
    }
    /// The one line that names a recorded source wherever details are listed.
    var sourceCaption: String? { source.map { String(format: L("Copied from %@"), $0.name) } }
    var displayTitle: String {
        if !title.isEmpty { return title }
        if kind == .link, let metadataTitle, !metadataTitle.isEmpty { return metadataTitle }
        // Only the first line is read; a long text is not split into all of its lines to title it.
        if let text { return String(text.prefix(while: { $0 != "\n" })).trimmingCharacters(in: .whitespaces).prefix(120).description }
        if let path { return URL(fileURLWithPath: originalPath ?? path).deletingPathExtension().lastPathComponent }
        return URL(string: originalURL ?? "")?.host ?? L("Link")
    }
    var fileURL: URL? { path.map { URL(fileURLWithPath: $0) } }
    var markupSourceURL: URL? { (markupBasePath ?? path).map { URL(fileURLWithPath: $0) } }
    var recordingOriginalURL: URL? { recordingOriginalPath.map { URL(fileURLWithPath: $0) } }
    var exportFileName: String? { fileURL.map { HistoryFiles.exportName(for: $0, originalPath: originalPath) } }
    var linkURL: URL? { originalURL.flatMap(URL.init(string:)) }
}
struct LibraryCollection: Identifiable, Equatable { let id: UUID; var name: String; var parentID: UUID? }
struct LibraryTag: Identifiable, Equatable { let id: UUID; var name: String }
/// Paged display data; tag labels never become part of the persisted payload.
struct LibraryCardSummary {
    var record: LibraryRecord
    let tagNames: [String]
    let tagCount: Int
    var tagLabel: String {
        let names = tagNames.map { "#" + $0 }.joined(separator: " · ")
        return tagCount > tagNames.count ? names + " · +\(tagCount - tagNames.count)" : names
    }
}
struct LibraryQuery: Equatable {
    enum Scope: Equatable { case saved, favorites, unorganized, recent, shelf, trash, collection(UUID), tag(UUID) }
    enum Sort: String, CaseIterable { case newest, oldest, title, titleDescending, copied, relevance }
    var scope: Scope = .saved
    var kind: LibraryKind?
    var search = ""
    enum SearchMode: String, CaseIterable { case all, text, visual }
    var searchMode: SearchMode = .all
    var visualIDs = [UUID]()
    var favoritesOnly = false
    var tagIDs = Set<UUID>()
    var days: Int?
    var domain = ""
    /// A source application's bundle identifier; empty matches every item.
    var sourceBundleID = ""
    var sort: Sort = .newest
    var hasFilters: Bool { kind != nil || !search.isEmpty || searchMode != .all || favoritesOnly || !tagIDs.isEmpty || days != nil || !domain.isEmpty || !sourceBundleID.isEmpty }
}

private enum LibrarySQL {
    /// `indexComplete` is nil when the library has no search index; the query
    /// then reads every item in scope, as it always did. Otherwise the terms
    /// the index can narrow choose the candidate items, and the same conditions
    /// as before decide among them.
    static func query(_ query: LibraryQuery, limit: Int, offset: Int, now: Date, projection: String = "i.payload", unlimited: Bool = false, indexComplete: Bool? = nil) -> (String, [SQLValue]) {
        var whereParts = [query.scope == .trash ? "i.deleted IS NOT NULL" : "i.deleted IS NULL"], values = [SQLValue]()
        switch query.scope {
        case .saved: whereParts.append("i.retained IS NOT NULL")
        case .favorites: whereParts.append("i.favorite=1")
        case .unorganized: whereParts += ["i.retained IS NOT NULL", "NOT EXISTS(SELECT 1 FROM item_collections c WHERE c.item=i.id)", "NOT EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id)"]
        case .recent: whereParts.append("i.retained IS NULL")
        case .shelf: whereParts.append("i.shelf=1")
        case .trash: break
        case let .collection(id): whereParts.append("EXISTS(SELECT 1 FROM item_collections c JOIN collections f ON c.collection=f.id WHERE c.item=i.id AND (f.id=? OR f.parent=?))"); values += [.text(id.uuidString), .text(id.uuidString)]
        case let .tag(id): whereParts.append("EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id AND t.tag=?)"); values.append(.text(id.uuidString))
        }
        if let kind = query.kind { whereParts.append("i.kind=?"); values.append(.text(kind.rawValue)) }
        if query.favoritesOnly { whereParts.append("i.favorite=1") }
        for id in query.tagIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            whereParts.append("EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id AND t.tag=?)"); values.append(.text(id.uuidString))
        }
        if let days = query.days { whereParts.append("i.created>=?"); values.append(.real(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)) }
        if !query.domain.isEmpty {
            var domain = query.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain.hasPrefix("www.") { domain.removeFirst(4) }
            let suffix = "." + domain
            // Literal host boundaries include subdomains without wildcard or
            // suffix collisions (youtube.com must not match notyoutube.com).
            whereParts.append("(i.domain=? OR substr(i.domain,-length(?))=?)")
            values += [.text(domain), .text(suffix), .text(suffix)]
        }
        if !query.sourceBundleID.isEmpty {
            whereParts.append("EXISTS(SELECT 1 FROM item_source s WHERE s.item=i.id AND s.bundle=?)"); values.append(.text(query.sourceBundleID))
        }
        // Bound literal substring search handles Turkish, short strings, CJK
        // and punctuation.
        var textRank = "0", textRankValues = [SQLValue]()
        var source = "items i", sourceValues = [SQLValue]()
        if !query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var searchParts = [String](), searchValues = [SQLValue]()
            var narrowing = [String]()
            if query.searchMode != .visual {
                for term in query.search.libraryFolded.split(whereSeparator: \.isWhitespace) {
                    searchParts.append("(instr(i.search,?)>0 OR EXISTS(SELECT 1 FROM image_analysis a WHERE a.item=i.id AND a.path=i.path AND instr(a.content,?)>0))")
                    searchValues += [.text(String(term)), .text(String(term))]
                    if LibrarySearchIndex.match(String(term)) != nil { narrowing.append(String(term)) }
                }
            }
            let text = searchParts.isEmpty ? "0" : "(" + searchParts.joined(separator: " AND ") + ")"
            textRank = text; textRankValues = searchValues
            let visual = query.searchMode != .text && !query.visualIDs.isEmpty ? "i.id IN (" + query.visualIDs.map { _ in "?" }.joined(separator: ",") + ")" : "0"
            whereParts.append("(\(text) OR \(visual))"); values += searchValues
            if visual != "0" { values += query.visualIDs.map { .text($0.uuidString) } }
            if let indexComplete, let candidates = LibrarySearchIndex.candidates(terms: narrowing, complete: indexComplete, kind: query.kind, extraIDs: visual == "0" ? [] : query.visualIDs) {
                source = candidates.sql + " hit CROSS JOIN items i ON i.id=hit.item"; sourceValues = candidates.values
            }
        }
        var order: String
        switch query.sort { case .newest, .relevance: order = "i.created DESC"; case .oldest: order = "i.created ASC"; case .title: order = "i.sort_title ASC"; case .titleDescending: order = "i.sort_title DESC"; case .copied: order = "COALESCE(i.copied,i.created) DESC" }
        if query.sort == .relevance, !query.search.isEmpty, query.searchMode != .text, !query.visualIDs.isEmpty {
            // UUID values are typed, never user SQL. Literal text/OCR matches
            // precede semantic suggestions; semantic images retain model rank.
            let ranks = query.visualIDs.enumerated().map { "WHEN '\($0.element.uuidString)' THEN \($0.offset)" }.joined(separator: " ")
            order = "CASE WHEN \(textRank) THEN -1 ELSE CASE i.id \(ranks) ELSE \(query.visualIDs.count) END END," + order
        } else { textRankValues = [] }
        let ordered = " ORDER BY \(order),i.rowid DESC"
        let matching = " FROM \(source) WHERE \(whereParts.joined(separator: " AND "))" + ordered
        values = sourceValues + values + textRankValues
        if unlimited { return ("SELECT \(projection)" + matching, values) }
        let page: [SQLValue] = [.integer(Int64(max(1, min(limit, 10000)))), .integer(Int64(max(0, offset)))]
        // Sorting every match with its payload would copy megabytes to return
        // one page. Choose the page's rows first, then read only those.
        if indexComplete != nil { return ("SELECT \(projection) FROM items i WHERE i.rowid IN (SELECT i.rowid" + matching + " LIMIT ? OFFSET ?)" + ordered, values + page + textRankValues) }
        return ("SELECT \(projection)" + matching + " LIMIT ? OFFSET ?", values + page)
    }
    static func decode(_ rows: [[String: SQLValue]]) throws -> [LibraryRecord] {
        try rows.map { row in guard let data = row["payload"]?.data else { throw HistoryFiles.Failure.unsafeFile }; return try JSONDecoder().decode(LibraryRecord.self, from: data) }
    }
}
extension String {
    var libraryFolded: String { folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR")).lowercased() }
}

/// The production source of truth. Existing history classes are adapters to
/// this store; old JSON/preferences are migration input and rollback copies.
@MainActor final class LibraryStore: ObservableObject {
    static let maximumItemNameLength = 160
    enum ItemNameError: Error, LocalizedError {
        case invalid
        var errorDescription: String? { L("Enter a name (1–160 characters)") }
    }
    @Published private(set) var revision = 0
    private(set) var changedKinds = Set(LibraryKind.allCases)
    private(set) var changedIDs = Set<UUID>()
    @Published var notice: String?
    @Published private(set) var searchRevision = 0
    @Published var imageSearchStatus = ""
    var imageSearch: LibraryImageSearch?
    let root: URL
    let databaseURL: URL
    let defaults: UserDefaults
    let files: HistoryFiles
    let snapshots: LibrarySnapshots
    private let db: LibraryDatabase
    private var textIdentityDataVersion: Int64?
    /// Nil when this library has no search index: the snapshot that must come
    /// first could not be made, or the trigram tokenizer is missing.
    private var searchStatus: LibrarySearchIndex.Status?
    /// The search table an earlier build wrote on every save. Nothing reads
    /// it; it is cleared in the background and kept clean until it is gone.
    private var legacySearchTable = false
    /// Makes search read every item, as it does in a library without an
    /// index, so tests can compare the two.
    var searchIndexDisabled = false
    var searchIndexComplete: Bool? { searchIndexDisabled ? nil : searchStatus?.isComplete }
    private let now: () -> Date
    private struct ShelfRemoval {
        let id: UUID
        let removedAt: Date?
    }
    private var shelfRemovalUndo = [[ShelfRemoval]]()
    private struct TrashRemoval {
        let id: UUID
        let onShelf: Bool
        let fingerprint: Data
    }
    private var trashRemovalUndo = [[TrashRemoval]]()
    struct RecordingTrimContext: Equatable, Sendable {
        let token: UUID
        let id: UUID
        let source: URL
        let sourceFingerprint: String
        let snapshot: URL
        let output: URL
    }
    private var recordingTrims = [UUID: RecordingTrimContext]()
    private var recordingTrimPending = Set<String>()
    var canUndoShelfRemoval: Bool { !shelfRemovalUndo.isEmpty }
    var canUndoTrash: Bool { !trashRemovalUndo.isEmpty }
    private let readerQueue = DispatchQueue(label: "com.baypeanut.Shelf.library.reader", qos: .userInitiated)
    private let maintenanceQueue = DispatchQueue(label: "com.baypeanut.Shelf.library.maintenance", qos: .utility)
    var retentionDays: Int { let days = defaults.integer(forKey: "historyRetentionDays"); return ImageHistory.dayChoices.contains(days) ? days : 30 }
    func retentionDays(for kind: LibraryKind) -> Int { HistoryRetention.days(kind, defaults: defaults) }
    var thumbnailsFolder: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }

    /// Whether the database has passed its integrity check.
    enum Integrity: Equatable { case verified, checking, failed }
    private(set) var integrity = Integrity.verified
    /// Called once, on a later turn of the main loop, when a check that was
    /// still running after launch fails. Every write is refused from then on.
    var onIntegrityFailure: (() -> Void)?
    private var integrityCheck: LibraryIntegrityCheck?
    private var afterIntegrity = [() -> Void]()
    private var maintainsInBackground = true
    /// A database up to this size is checked before `init` returns, as every
    /// database used to be. A larger one is checked on another thread, and
    /// nothing is written to it until that check has passed.
    nonisolated static let deferredIntegrityCheckBytes = 16 * 1024 * 1024
    private static let integrityFailedKey = "libraryIntegrityCheckFailed"

    /// `backgroundMaintenance` is false only in tests that step through the
    /// search index's catch-up themselves; `deferredIntegrityCheckBytes` is
    /// lowered or raised only in tests of the integrity check.
    init(defaults: UserDefaults, inbox: URL, now: @escaping () -> Date = Date.init,
         moveToTrash: @escaping (URL) throws -> URL = HistoryFiles.systemTrash, backgroundMaintenance: Bool = true,
         deferredIntegrityCheckBytes: Int = LibraryStore.deferredIntegrityCheckBytes) throws {
        self.defaults = defaults; self.now = now; files = HistoryFiles(inbox: inbox, moveToTrash: moveToTrash)
        root = inbox.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        databaseURL = root.appendingPathComponent("library.sqlite")
        snapshots = LibrarySnapshots(root: root)
        guard root.resolvingSymlinksInPath().path == root.path else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            guard FileManager.default.createFile(atPath: databaseURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw HistoryFiles.Failure.unsafeFile }
        }
        maintainsInBackground = backgroundMaintenance
        db = try LibraryDatabase(url: databaseURL, verify: false)
        // The check may run later only for a database this build has already
        // prepared, so that nothing has to be written before it passes, and
        // never after an earlier check failed.
        let size = ["", "-wal"].reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: databaseURL.path + $1))?[.size] as? NSNumber)?.intValue ?? 0) }
        let deferred = size > deferredIntegrityCheckBytes && !defaults.bool(forKey: Self.integrityFailedKey) && Self.isPrepared(db)
        if !deferred {
            try db.checkIntegrity()
            if defaults.object(forKey: Self.integrityFailedKey) != nil { defaults.removeObject(forKey: Self.integrityFailedKey) }
        }
        guard (try db.rows("PRAGMA user_version").first?["user_version"]?.number ?? 0) <= 1 else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        // Already in effect for a prepared database; neither writes to it.
        try db.execute("PRAGMA journal_mode=WAL")
        // Every commit is flushed before a save returns. In write-ahead mode
        // NORMAL could not corrupt the database, but a power loss could undo
        // the last commits, pins, names and edits among them. A commit costs
        // well under a tenth of a millisecond here, so nothing is traded away.
        try db.execute("PRAGMA synchronous=FULL")
        // Content removed from Trash is overwritten rather than left in free pages.
        try db.execute("PRAGMA secure_delete=ON")
        if deferred {
            try loadSearchState()
            checkIntegrityInBackground()
        } else {
            try finishOpening()
        }
    }
    /// True when opening this database needs no write: this build created or
    /// upgraded it and it is already in write-ahead mode.
    private static func isPrepared(_ database: LibraryDatabase) -> Bool {
        (try? database.rows("PRAGMA user_version").first?["user_version"]?.number) == 1
            && (try? database.rows("PRAGMA journal_mode").first?.values.first?.string) == "wal"
            && (try? LibrarySearchIndex.isInstalled(database)) == true
            && (try? database.rows("SELECT 1 FROM metadata WHERE key='migration-v1'").isEmpty) == false
    }
    /// Everything `init` does that can write: the schema, the first import,
    /// repairs after an older build, and the background work.
    private func finishOpening() throws {
        let populated = try !db.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='items'").isEmpty && !db.rows("SELECT 1 FROM items LIMIT 1").isEmpty
        for sql in [
            "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,kind TEXT NOT NULL,created REAL NOT NULL,updated REAL NOT NULL,copied REAL,retained REAL,favorite INTEGER NOT NULL,shelf INTEGER NOT NULL,deleted REAL,path TEXT,normalized TEXT,domain TEXT NOT NULL,sort_title TEXT NOT NULL,search TEXT NOT NULL,payload BLOB NOT NULL)",
            "CREATE INDEX IF NOT EXISTS item_order ON items(deleted,retained,kind,created DESC)",
            "CREATE INDEX IF NOT EXISTS shelf_search_scope ON items(kind,shelf,deleted)",
            "CREATE INDEX IF NOT EXISTS shelf_capture_order ON items(kind,shelf,deleted,created)",
            "CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY,name TEXT NOT NULL,parent TEXT REFERENCES collections(id),folded TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS tags(id TEXT PRIMARY KEY,name TEXT NOT NULL,folded TEXT NOT NULL UNIQUE)",
            "CREATE TABLE IF NOT EXISTS item_collections(item TEXT REFERENCES items(id),collection TEXT REFERENCES collections(id),PRIMARY KEY(item,collection))",
            "CREATE TABLE IF NOT EXISTS item_tags(item TEXT REFERENCES items(id),tag TEXT REFERENCES tags(id),PRIMARY KEY(item,tag))",
            "CREATE INDEX IF NOT EXISTS collection_members ON item_collections(collection,item)",
            "CREATE INDEX IF NOT EXISTS tag_members ON item_tags(tag,item)",
            // Clipboard identity is independent of search folding. Keep the items schema
            // compatible with existing imports and rollback snapshots.
            "CREATE TABLE IF NOT EXISTS text_identity(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,digest BLOB NOT NULL,captured REAL NOT NULL,version INTEGER NOT NULL DEFAULT 1)",
            "CREATE INDEX IF NOT EXISTS text_identity_digest ON text_identity(digest)",
            "CREATE INDEX IF NOT EXISTS text_identity_expiry ON text_identity(captured)",
            // An older rollback app knows nothing about this index. Its text
            // edits must invalidate old digests; startup repairs missing rows.
            "CREATE TRIGGER IF NOT EXISTS text_identity_payload_changed AFTER UPDATE OF payload ON items BEGIN DELETE FROM text_identity WHERE item=NEW.id; END",
            // The source application lives in the payload; this derived index
            // only serves the Library's source filter. Like text_identity it
            // keeps the items schema unchanged for an older rollback app, whose
            // payload edits drop the source and must drop its index row too.
            "CREATE TABLE IF NOT EXISTS item_source(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,bundle TEXT NOT NULL COLLATE NOCASE,name TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS item_source_bundle ON item_source(bundle)",
            "CREATE TRIGGER IF NOT EXISTS item_source_payload_changed AFTER UPDATE OF payload ON items BEGIN DELETE FROM item_source WHERE item=NEW.id; END",
            "CREATE TABLE IF NOT EXISTS image_analysis(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,path TEXT NOT NULL,fingerprint TEXT NOT NULL,version TEXT NOT NULL,content TEXT NOT NULL,ocr TEXT NOT NULL,vectors BLOB NOT NULL)",
            // Durable intent also covers a crash between creating a new PNG
            // and committing its record; only unpublished/retired assets go
            // to recoverable Trash, never external source screenshots.
            "CREATE TABLE IF NOT EXISTS image_markup_garbage(path TEXT PRIMARY KEY)"
        ] { try db.execute(sql) }
        // These two once had another definition. Rebuild one only if it is not
        // the current one, rather than on every launch.
        for (name, definition) in [("live_image_path", "items(path) WHERE kind='image' AND deleted IS NULL"), ("live_link_url", "items(normalized) WHERE kind='link' AND deleted IS NULL")] {
            let current = try db.rows("SELECT sql FROM sqlite_master WHERE type='index' AND name=?", [.text(name)]).first?["sql"]?.string
            guard current != "CREATE INDEX \(name) ON \(definition)" else { continue }
            try db.execute("DROP INDEX IF EXISTS \(name)"); try db.execute("CREATE INDEX \(name) ON \(definition)")
        }
        if try !db.rows("PRAGMA table_info(text_identity)").contains(where: { $0["name"]?.string == "version" }) {
            try db.execute("ALTER TABLE text_identity ADD COLUMN version INTEGER NOT NULL DEFAULT 1")
        }
        try installSearchIndex(populated: populated)
        try migrateLegacy()
        try backfillTextIdentity()
        try db.execute("PRAGMA user_version=1")
        drainMarkupGarbage()
        if maintainsInBackground { startSearchMaintenance() }
    }
    deinit { searchStatus?.cancel() }
    /// Runs the check on a connection of its own. Until it passes, the first
    /// statement that would write waits for it, so nothing reaches a damaged
    /// database that the check at launch would have kept out.
    private func checkIntegrityInBackground() {
        let check = LibraryIntegrityCheck(), url = databaseURL
        integrityCheck = check; integrity = .checking
        db.beforeWrite = { [unowned self] in try MainActor.assumeIsolated { try self.awaitIntegrity() } }
        DispatchQueue.global(qos: .userInitiated).async {
            check.finish((try? LibraryDatabase(url: url, readOnly: true, verify: true)) != nil)
            Task { @MainActor [weak self] in self?.resolveIntegrity() }
        }
    }
    private func awaitIntegrity() throws {
        integrityCheck?.wait()
        resolveIntegrity()
        if integrity == .failed { throw LibraryDatabase.Failure(code: SQLITE_CORRUPT) }
    }
    private func resolveIntegrity() {
        guard let check = integrityCheck, let passed = check.result else { return }
        integrityCheck = nil; db.beforeWrite = nil
        do {
            // A failure seen from the other connection counts only once this one confirms it.
            if !passed { try db.checkIntegrity() }
            try finishOpening()
            integrity = .verified
            let waiting = afterIntegrity; afterIntegrity = []
            for body in waiting { body() }
        } catch {
            integrity = .failed; afterIntegrity = []
            db.beforeWrite = { throw LibraryDatabase.Failure(code: SQLITE_CORRUPT) }
            // The next launch checks before it opens and enters recovery as it always has.
            defaults.set(true, forKey: Self.integrityFailedKey)
            DispatchQueue.main.async { [weak self] in self?.onIntegrityFailure?() }
        }
    }
    /// Blocks until a check still running has finished, and returns the result.
    @discardableResult func waitForIntegrityCheck() -> Integrity {
        integrityCheck?.wait()
        resolveIntegrity()
        return integrity
    }
    /// Runs `body` once the database has passed its check: now if it already
    /// has, never if it fails. For work that writes on a connection of its own.
    func afterIntegrityCheck(_ body: @escaping () -> Void) {
        switch integrity { case .verified: body(); case .checking: afterIntegrity.append(body); case .failed: break }
    }
    /// The first change to how an existing library is stored. A snapshot comes
    /// first; if it cannot be made, or the index cannot be created, nothing is
    /// changed, search keeps reading every item, and the next launch tries again.
    private func installSearchIndex(populated: Bool) throws {
        var installed = try LibrarySearchIndex.isInstalled(db)
        if !installed {
            do {
                // Without the tokenizer there is nothing to prepare for.
                try LibrarySearchIndex.probe(db)
                if populated { try snapshots.make(of: db, at: now()) }
                try db.transaction { try LibrarySearchIndex.install(in: db, complete: !populated) }
                installed = true
            } catch { log.error("The library search index was not created; the library is unchanged") }
        }
        try loadSearchState()
        // Only a shortcut; without it the old table is still kept clean, slowly.
        if installed, legacySearchTable { try? LibrarySearchIndex.indexLegacyTable(db) }
    }
    /// What this launch needs to know about search before it can read.
    private func loadSearchState() throws {
        legacySearchTable = try LibrarySearchIndex.hasLegacyTable(db)
        guard searchStatus == nil, try LibrarySearchIndex.isInstalled(db) else { return }
        let status = LibrarySearchIndex.Status()
        if try LibrarySearchIndex.isComplete(db) { status.markComplete() }
        searchStatus = status
    }
    /// Indexes what an earlier build stored and clears its unused search
    /// table, in small steps on a connection of its own.
    private func startSearchMaintenance() {
        guard let status = searchStatus, legacySearchTable || !status.isComplete else { return }
        let url = databaseURL
        maintenanceQueue.async {
            guard let database = try? LibraryDatabase(url: url, verify: false) else { return }
            _ = try? LibrarySearchIndex.maintain(database, status: status)
            // The cleared pages were overwritten in the log first; fold it back.
            _ = try? database.rows("PRAGMA wal_checkpoint(TRUNCATE)")
            // The old table leaves free pages behind; return them as a purge does.
            if !status.isCancelled, Self.hasWorthwhileFreeSpace(database, fraction: 8) { _ = Self.vacuum(database, at: url) }
        }
    }
    /// Waits for background maintenance that has been started. For tests.
    func waitForMaintenance() { maintenanceQueue.sync {} }
    private func migrateLegacy() throws {
        guard try db.rows("SELECT value FROM metadata WHERE key='migration-v1'").isEmpty else { return }
        // Decode before writing any record or applying expiry. A damaged
        // source is preserved and blocks activation rather than becoming empty.
        let images: [ImageHistory.Entry]
        if let data = defaults.data(forKey: "imageHistoryV1") { images = try JSONDecoder().decode([ImageHistory.Entry].self, from: data) }
        else { images = ImageHistory(defaults: defaults, inbox: files.inbox, now: now, moveToTrash: files.moveToTrash, pruneOnLoad: false).entries }
        let textFile = files.inbox.appendingPathComponent("Texts/history.json")
        var texts = [TextHistory.Entry]()
        if FileManager.default.fileExists(atPath: textFile.path) {
            guard textFile.resolvingSymlinksInPath().path == textFile.standardizedFileURL.path,
                  (try textFile.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 32 * 1024 * 1024 else { throw HistoryFiles.Failure.unsafeFile }
            texts = try JSONDecoder().decode([TextHistory.Entry].self, from: Data(contentsOf: textFile))
        }
        let backup = root.appendingPathComponent("Backups/Before-Library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(try PropertyListSerialization.data(fromPropertyList: defaults.dictionaryRepresentation(), format: .binary, options: 0), to: backup.appendingPathComponent("preferences.plist"))
        if FileManager.default.fileExists(atPath: textFile.path) { try FileManager.default.copyItem(at: textFile, to: backup.appendingPathComponent("text-history.json")) }
        let owned = files.files(in: files.inbox, matching: files.isClipboardCopy) + files.files(in: files.favoritesFolder, matching: files.isFavoriteCopy)
        for url in owned { try FileManager.default.copyItem(at: url, to: backup.appendingPathComponent(url.lastPathComponent)) }
        try db.transaction {
            var paths = Set<String>(), textIDs = Set<UUID>()
            for entry in images.reversed() where paths.insert(entry.path).inserted {
                var item = LibraryRecord(id: entry.id, kind: .image, createdAt: entry.capturedAt, updatedAt: entry.capturedAt)
                item.path = entry.path; item.originalPath = entry.originalPath; item.favorite = entry.pinned; item.title = entry.title ?? ""
                if entry.pinned { item.retainedAt = entry.capturedAt; try ensureOwned(&item) }
                try put(item)
            }
            for entry in texts.reversed() where textIDs.insert(entry.id).inserted {
                guard entry.text.utf8.count <= TextClipboardWatcher.maximumDataBytes else { throw HistoryFiles.Failure.unsafeFile }
                var item = LibraryRecord(id: entry.id, kind: .text, createdAt: entry.capturedAt, updatedAt: entry.capturedAt)
                item.text = entry.text; item.favorite = entry.pinned; item.retainedAt = entry.pinned ? entry.capturedAt : nil; item.title = entry.title ?? ""
                try put(item)
            }
            let count = try db.rows("SELECT count(*) AS n FROM items").first?["n"]?.number
            guard count == Int64(paths.count + textIDs.count) else { throw HistoryFiles.Failure.unsafeFile }
            try db.execute("INSERT INTO metadata VALUES('migration-v1',?)", [.text(backup.path)])
        }
        try db.backup(to: backup.appendingPathComponent("library-after-migration.sqlite"))
    }
    private static func textDigest(_ text: String) -> Data { Data(SHA256.hash(data: Data(TextIdentity.key(text).utf8))) }
    /// `digest` is the caller's digest of this item's text when it already has one.
    private func putTextIdentity(_ item: LibraryRecord, digest: Data? = nil) throws {
        if item.kind == .text, let text = item.text {
            try db.execute("INSERT INTO text_identity(item,digest,captured,version) VALUES(?,?,?,?) ON CONFLICT(item) DO UPDATE SET digest=excluded.digest,captured=excluded.captured,version=excluded.version", [.text(item.id.uuidString), .blob(digest ?? Self.textDigest(text)), .real((item.lastCapturedAt ?? item.createdAt).timeIntervalSince1970), .integer(TextIdentity.version)])
        } else {
            try db.execute("DELETE FROM text_identity WHERE item=?", [.text(item.id.uuidString)])
        }
    }
    /// Existing libraries need only a derived identity index, not a destructive
    /// cleanup. Read a bounded page of missing IDs, then one payload at a
    /// time; a large text archive must not all be decoded into memory at
    /// launch. Usually no rows are missing after the initial backfill, but
    /// this also repairs inserts and edits made by an older rollback app.
    private func backfillTextIdentity() throws {
        let observedVersion = try db.transaction {
            let observed = try db.rows("PRAGMA data_version").first?["data_version"]?.number
            try repairTextIdentity()
            return observed
        }
        textIdentityDataVersion = observedVersion
    }
    private func repairTextIdentity() throws {
        // Identity rows exist only for text items, so equal counts mean none
        // is missing or outdated. Three counts replace a read of every text
        // item each time another connection has written anything at all.
        if let counts = try db.rows("SELECT (SELECT count(*) FROM items WHERE kind='text') AS texts,(SELECT count(*) FROM text_identity) AS identities,(SELECT count(*) FROM text_identity WHERE version=?) AS current", [.integer(TextIdentity.version)]).first,
           let texts = counts["texts"]?.number, texts == counts["identities"]?.number, texts == counts["current"]?.number {
            try db.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('text-identity-v2','complete')"); return
        }
        var cursor = ""
        while true {
            let rows = try db.rows("SELECT i.id FROM items i LEFT JOIN text_identity t ON t.item=i.id WHERE i.kind='text' AND (t.item IS NULL OR t.version<>?) AND i.id>? ORDER BY i.id LIMIT 256", [.integer(TextIdentity.version), .text(cursor)])
            guard !rows.isEmpty else { break }
            for row in rows {
                guard let key = row["id"]?.string, let id = UUID(uuidString: key), let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }
                try putTextIdentity(value)
                cursor = key
            }
        }
        try db.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('text-identity-v2','complete')")
    }
    private func put(_ item: LibraryRecord, textDigest: Data? = nil) throws {
        let tagNames = try tags(for: item.id).map(\.name).joined(separator: " ")
        // A personal label supplements the recognizable source filename.
        // Index its basename only; private directory names are not content.
        let imageName = item.kind == .image ? (item.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.fileURL?.lastPathComponent ?? "") : ""
        let title = item.displayTitle
        let content = [title,imageName,item.metadataTitle ?? "",item.text ?? "",item.note,item.originalURL ?? "",tagNames].joined(separator: " ").libraryFolded
        try db.execute("INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,created=excluded.created,updated=excluded.updated,copied=excluded.copied,retained=excluded.retained,favorite=excluded.favorite,shelf=excluded.shelf,deleted=excluded.deleted,path=excluded.path,normalized=excluded.normalized,domain=excluded.domain,sort_title=excluded.sort_title,search=excluded.search,payload=excluded.payload", [
            .text(item.id.uuidString), .text(item.kind.rawValue), .real(item.createdAt.timeIntervalSince1970), .real(item.updatedAt.timeIntervalSince1970),
            item.lastCopiedAt.map { .real($0.timeIntervalSince1970) } ?? .null, item.retainedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .integer(item.favorite ? 1 : 0), .integer(item.onShelf ? 1 : 0), item.deletedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            item.path.map(SQLValue.text) ?? .null, item.normalizedURL.map(SQLValue.text) ?? .null, .text(item.linkURL?.host?.lowercased() ?? ""),
            .text(title.libraryFolded), .text(content), .blob(try JSONEncoder().encode(item))])
        try putTextIdentity(item, digest: textDigest)
        if let source = item.source {
            try db.execute("INSERT INTO item_source(item,bundle,name) VALUES(?,?,?) ON CONFLICT(item) DO UPDATE SET bundle=excluded.bundle,name=excluded.name", [.text(item.id.uuidString), .text(source.bundleID), .text(source.name)])
        } else {
            try db.execute("DELETE FROM item_source WHERE item=?", [.text(item.id.uuidString)])
        }
        // The search index follows `items.search` through its triggers.
        try forgetLegacySearch("id=?", [.text(item.id.uuidString)])
    }
    /// Until the old search table is gone it must not keep text that an edit
    /// or a purge removed. The table can disappear between two statements.
    private func forgetLegacySearch(_ condition: String, _ values: [SQLValue]) throws {
        guard legacySearchTable else { return }
        do { try LibrarySearchIndex.forgetLegacy(db, indexed: searchStatus != nil, where: condition, values) }
        catch {
            guard try !LibrarySearchIndex.hasLegacyTable(db) else { throw error }
            legacySearchTable = false
        }
    }
    func item(_ id: UUID) throws -> LibraryRecord? { try LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE id=?", [.text(id.uuidString)])).first }
    /// Read cached OCR only for the current live image and unchanged pixels.
    /// File metadata and SQLite reads stay on the reader queue; no search
    /// model, index scan or image decode is started by this clipboard action.
    func imageTextSource(_ id: UUID) async throws -> ImageTextSource? {
        let databaseURL = self.databaseURL
        return try await withCheckedThrowingContinuation { continuation in
            readerQueue.async {
                do {
                    let connection = try LibraryDatabase(url: databaseURL, readOnly: true, verify: false)
                    let rows = try connection.rows("SELECT i.path,a.path AS analysis_path,a.fingerprint,a.version,a.ocr FROM items i LEFT JOIN image_analysis a ON a.item=i.id WHERE i.id=? AND i.kind='image' AND i.deleted IS NULL", [.text(id.uuidString)])
                    guard let row = rows.first, let path = row["path"]?.string else {
                        continuation.resume(returning: nil); return
                    }
                    let url = URL(fileURLWithPath: path)
                    guard ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"].contains(url.pathExtension.lowercased()),
                          let fingerprint = ImageSearchWorker.fingerprint(url) else {
                        continuation.resume(returning: nil); return
                    }
                    let version = row["version"]?.string
                    let fresh = row["analysis_path"]?.string == path && row["fingerprint"]?.string == fingerprint &&
                        (version == "vision-ocr-v1" || version == ImageSearchWorker.version)
                    continuation.resume(returning: ImageTextSource(url: url, fingerprint: fingerprint, cachedText: fresh ? row["ocr"]?.string : nil))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func shelfItems(_ kind: LibraryKind) throws -> [LibraryRecord] {
        let order = kind == .link ? "COALESCE(copied,created) DESC,rowid DESC" : "created DESC,rowid DESC"
        return try LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE kind=? AND shelf=1 AND deleted IS NULL ORDER BY \(order)", [.text(kind.rawValue)]))
    }
    func query(_ query: LibraryQuery, limit: Int = 80, offset: Int = 0) throws -> [LibraryRecord] {
        let (sql, values) = LibrarySQL.query(query, limit: limit, offset: offset, now: now(), indexComplete: searchIndexComplete); return try LibrarySQL.decode(db.rows(sql, values))
    }
    func queryAsync(_ query: LibraryQuery, limit: Int = 80, offset: Int = 0, completion: @escaping (Result<[LibraryRecord], Error>) -> Void) {
        let url = databaseURL, date = now(), indexComplete = searchIndexComplete
        readerQueue.async {
            let result = Result { () throws -> [LibraryRecord] in
                let db = try LibraryDatabase(url: url, readOnly: true, verify: false)
                let (sql, values) = LibrarySQL.query(query, limit: limit, offset: offset, now: date, indexComplete: indexComplete)
                return try LibrarySQL.decode(db.rows(sql, values))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func cardSummariesAsync(_ query: LibraryQuery, limit: Int = 80, offset: Int = 0, completion: @escaping (Result<[LibraryCardSummary], Error>) -> Void) {
        let url = databaseURL, date = now(), indexComplete = searchIndexComplete
        readerQueue.async {
            let result = Result { () throws -> [LibraryCardSummary] in
                let connection = try LibraryDatabase(url: url, readOnly: true, verify: false)
                // One read statement gives each page a consistent record/tag
                // snapshot, without per-card database reads on the UI thread.
                let tags = "FROM item_tags it JOIN tags t ON t.id=it.tag WHERE it.item=i.id ORDER BY t.folded,t.id"
                let projection = "i.payload,(SELECT t.name \(tags) LIMIT 1) AS tag0,(SELECT t.name \(tags) LIMIT 1 OFFSET 1) AS tag1,(SELECT count(*) FROM item_tags it WHERE it.item=i.id) AS tag_count"
                let (sql, values) = LibrarySQL.query(query, limit: min(limit, 80), offset: offset, now: date, projection: projection, indexComplete: indexComplete)
                let rows = try connection.rows(sql, values), records = try LibrarySQL.decode(rows)
                return zip(records, rows).map { record, row in
                    LibraryCardSummary(record: record, tagNames: [row["tag0"]?.string, row["tag1"]?.string].compactMap { $0 }, tagCount: Int(row["tag_count"]?.number ?? 0))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func queryIDs(_ query: LibraryQuery) throws -> [UUID] {
        let (sql, values) = LibrarySQL.query(query, limit: 1, offset: 0, now: now(), projection: "i.id", unlimited: true, indexComplete: searchIndexComplete)
        return try db.rows(sql, values).compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
    }
    func queryIDsAsync(_ query: LibraryQuery, completion: @escaping (Result<[UUID], Error>) -> Void) {
        let url = databaseURL, date = now(), indexComplete = searchIndexComplete
        readerQueue.async {
            let result = Result { () throws -> [UUID] in
                let connection = try LibraryDatabase(url: url, readOnly: true, verify: false)
                let (sql, values) = LibrarySQL.query(query, limit: 1, offset: 0, now: date, projection: "i.id", unlimited: true, indexComplete: indexComplete)
                return try connection.rows(sql, values).compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    /// Shelf search shares the persisted, folded metadata/OCR index with the
    /// Library, but includes both temporary and saved records still on a row.
    /// It deliberately skips semantic suggestions: typing in a narrow shelf
    /// needs literal matches, without starting an image/model scan per key.
    func shelfMatchingIDsAsync(kind: LibraryKind, search: String, favoritesOnly: Bool = false,
                               completion: @escaping (Result<[UUID], Error>) -> Void) {
        var query = LibraryQuery(scope: .shelf, kind: kind, search: search)
        query.searchMode = .text; query.favoritesOnly = favoritesOnly
        queryIDsAsync(query, completion: completion)
    }
    func records(_ ids: [UUID]) throws -> [LibraryRecord] { try ids.map { guard let record = try item($0) else { throw HistoryFiles.Failure.unsafeFile }; return record } }
    func resolveImageSearch(_ query: LibraryQuery, completion: @escaping (LibraryQuery) -> Void) {
        guard let imageSearch else { var query = query; query.visualIDs = []; completion(query); return }
        imageSearch.resolve(query, completion: completion)
    }
    func imageSearchChanged() { searchRevision += 1 }
    /// The applications live items were copied from, for the source filter.
    /// Each carries the name recorded with its newest item.
    func sourceApps() throws -> [SourceApp] {
        try db.rows("SELECT s.bundle,s.name,max(i.created) AS newest FROM item_source s JOIN items i ON i.id=s.item WHERE i.deleted IS NULL GROUP BY s.bundle").compactMap { row in
            guard let bundleID = row["bundle"]?.string, let name = row["name"]?.string else { return nil }
            return SourceApp(bundleID: bundleID, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @discardableResult func createNote() throws -> LibraryRecord {
        let date = now(); var record = LibraryRecord(id: UUID(), kind: .text, createdAt: date, updatedAt: date)
        record.text = ""; record.retainedAt = date; record.title = L("Untitled note")
        try db.transaction { try put(record) }; changed(); return record
    }
    @discardableResult func captureImage(_ url: URL, capturedAt: Date? = nil, source: SourceApp? = nil) throws -> LibraryRecord {
        // Naming the kind lets the partial index answer; without it every item was read.
        if let existing = try LibrarySQL.decode(db.rows("SELECT payload FROM items INDEXED BY live_image_path WHERE kind='image' AND path=? AND deleted IS NULL", [.text(url.standardizedFileURL.path)])).first { return existing }
        guard files.isRegularFile(url) else { throw HistoryFiles.Failure.unsafeFile }
        let date = capturedAt ?? now(); var item = LibraryRecord(id: UUID(), kind: .image, createdAt: date, updatedAt: date); item.path = url.standardizedFileURL.path; item.captureRevision = UUID()
        item.source = source
        try db.transaction { try put(item) }; changed([item.id]); return item
    }
    /// A recopy records its new source; one without a known source keeps the
    /// earlier attribution.
    @discardableResult func captureText(_ text: String, source: SourceApp? = nil) throws -> LibraryRecord? {
        guard !text.isEmpty, text.utf8.count <= TextClipboardWatcher.maximumDataBytes else { throw HistoryFiles.Failure.unsafeFile }
        let date = now()
        var affected = [UUID]()
        var textFileRollback: (url: URL, data: Data)?
        var observedVersion: Int64?
        let captured: LibraryRecord
        do { captured = try db.transaction { () throws -> LibraryRecord in
            observedVersion = try db.rows("PRAGMA data_version").first?["data_version"]?.number
            // A rollback app can insert or edit while this app stays open.
            // Repair only after another connection writes, not on every copy.
            if observedVersion != textIdentityDataVersion { try repairTextIdentity() }
            let identity = TextIdentity.key(text), digest = Data(SHA256.hash(data: Data(identity.utf8)))
            // The index narrows the read; verify the normalized candidate too.
            let rows = try db.rows("SELECT i.id FROM text_identity t JOIN items i ON i.id=t.item WHERE t.digest=? AND i.kind='text' AND i.deleted IS NULL ORDER BY i.created DESC,i.rowid DESC", [.blob(digest)])
            var canonical: LibraryRecord?
            for row in rows {
                guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), var duplicate = try item(id) else { throw HistoryFiles.Failure.unsafeFile }
                guard let candidate = duplicate.text, TextIdentity.key(candidate).utf8.elementsEqual(identity.utf8) else { continue }
                guard var current = canonical else { canonical = duplicate; continue }
                // Preserve personal organization on the surviving identity.
                // The old row and its memberships remain recoverable in Trash.
                current.favorite = current.favorite || duplicate.favorite
                if let retained = duplicate.retainedAt { current.retainedAt = current.retainedAt.map { min($0, retained) } ?? retained }
                if current.title.isEmpty, !duplicate.title.isEmpty { current.title = duplicate.title }
                if current.note.isEmpty, !duplicate.note.isEmpty { current.note = duplicate.note }
                try db.execute("INSERT OR IGNORE INTO item_collections(item,collection) SELECT ?,collection FROM item_collections WHERE item=?", [.text(current.id.uuidString), .text(id.uuidString)])
                try db.execute("INSERT OR IGNORE INTO item_tags(item,tag) SELECT ?,tag FROM item_tags WHERE item=?", [.text(current.id.uuidString), .text(id.uuidString)])
                duplicate.deletedAt = date; duplicate.onShelf = false; duplicate.updatedAt = date; duplicate.trashRevision = UUID()
                try put(duplicate)
                affected.append(id)
                canonical = current
            }
            var result = canonical ?? LibraryRecord(id: UUID(), kind: .text, createdAt: date, updatedAt: date)
            if let canonical { textFileRollback = try rewriteMaterializedText(canonical, to: text) }
            var orderedDate = date
            if case let .real(front)? = try db.rows("SELECT created FROM items WHERE kind='text' AND shelf=1 AND deleted IS NULL ORDER BY created DESC,rowid DESC LIMIT 1").first?["created"] {
                // Reusing a stable ID also reuses its rowid. An equal clock
                // reading must still move that record ahead of a newer row;
                // subsequent new captures must also stay ahead of this tiny
                // ordering increment or a clock that has moved backwards.
                let timestamp = date.timeIntervalSince1970
                if timestamp < front || (canonical != nil && timestamp == front) {
                    orderedDate = Date(timeIntervalSince1970: front.nextUp)
                }
            }
            result.text = text; result.createdAt = orderedDate; result.updatedAt = date
            result.lastCapturedAt = date; result.lastCopiedAt = date; result.onShelf = true
            result.captureRevision = UUID()
            if let source { result.source = source }
            // `result.text` is `text`, whose identity was computed above.
            try put(result, textDigest: digest)
            affected.append(result.id)
            return result
        } } catch {
            if let rollback = textFileRollback { try? writePrivate(rollback.data, to: rollback.url) }
            throw error
        }
        // Cache the version seen under the transaction's writer lock. A later
        // writer must remain observable on the next capture, including on error.
        textIdentityDataVersion = observedVersion
        invalidateShelfUndo(affected)
        invalidateTrashUndo(affected)
        changed(affected)
        return captured
    }
    @discardableResult func captureLink(_ url: URL, source: SourceApp? = nil) throws -> LibraryRecord {
        guard let normalized = LinkIdentity.normalized(url) else { throw HistoryFiles.Failure.unsafeFile }
        if var item = try LibrarySQL.decode(db.rows("SELECT payload FROM items INDEXED BY live_link_url WHERE kind='link' AND normalized=? AND deleted IS NULL ORDER BY created DESC,rowid DESC LIMIT 1", [.text(normalized)])).first {
            item.onShelf = true; item.updatedAt = now(); item.lastCopiedAt = now(); item.lastCapturedAt = now(); item.captureRevision = UUID()
            if let source { item.source = source }
            try db.transaction { try put(item) }; changed([item.id]); return item
        }
        let date = now(); var item = LibraryRecord(id: UUID(), kind: .link, createdAt: date, updatedAt: date)
        item.originalURL = url.absoluteString; item.normalizedURL = normalized; item.lastCapturedAt = date; item.captureRevision = UUID(); item.source = source
        try db.transaction { try put(item) }; changed([item.id]); return item
    }
    /// Returns the private copy it made, if any, so a caller whose write then
    /// fails can hand that copy to `discardUnpublished`.
    @discardableResult private func ensureOwned(_ item: inout LibraryRecord) throws -> URL? {
        guard item.kind == .image, let url = item.fileURL, !files.isAppCopy(url) else { return nil }
        let copy = try files.makeFavoriteCopy(of: url); item.originalPath = item.originalPath ?? url.path; item.path = copy.path
        return copy
    }
    /// No row references a copy whose write failed. Move it to the recoverable
    /// Trash, as naming does, instead of leaving it to accumulate in Favorites.
    private func discardUnpublished(_ copies: [URL]) {
        for copy in copies where files.isFavoriteCopy(copy) { _ = try? files.trashAppCopy(copy) }
    }
    /// Save editable vectors and a flattened PNG under the same item identity.
    /// Nothing writes to the original screenshot. A failed render/write/SQLite
    /// transaction leaves the prior record and its visible pixels unchanged.
    @discardableResult func saveImageMarkup(_ id: UUID, document: ImageMarkupDocument) throws -> LibraryRecord {
        let document = try document.validated()
        guard var value = try item(id), value.kind == .image, value.deletedAt == nil,
              let source = value.markupSourceURL, files.isRegularFile(source) else { throw HistoryFiles.Failure.unsafeFile }
        let previous = value
        if (document == value.imageMarkup && value.fileURL.map(files.isRegularFile) == true) ||
            (document.isEmpty && value.imageMarkup == nil && value.markupBasePath == nil) { return value }
        var pending = [URL]()
        do {
            var base = source
            if !document.isEmpty, value.markupBasePath == nil, !files.isAppCopy(source) {
                base = try reserveMarkupAsset(extension: source.pathExtension)
                pending.append(base)
                try FileManager.default.copyItem(at: source, to: base)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: base.path)
                guard files.isFavoriteCopy(base) else { throw HistoryFiles.Failure.unsafeFile }
                let handle = try FileHandle(forWritingTo: base)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            }
            if document.isEmpty {
                value.path = base.path; value.imageMarkup = nil; value.markupBasePath = nil
            } else {
                let data = try ImageMarkupRenderer.render(sourceURL: base, document: document)
                let rendered = try reserveMarkupAsset(extension: "png")
                pending.append(rendered)
                try writeNewMarkupAsset(data, to: rendered)
                value.originalPath = value.originalPath ?? source.path
                value.path = rendered.path; value.markupBasePath = base.path; value.imageMarkup = document
            }
            value.updatedAt = now()
            try db.transaction {
                try put(value)
                // Old OCR cannot describe the new pixels, including when all
                // marks are removed and the base image is restored.
                try db.execute("DELETE FROM image_analysis WHERE item=?", [.text(id.uuidString)])
                for asset in pending { try db.execute("DELETE FROM image_markup_garbage WHERE path=?", [.text(asset.path)]) }
                if previous.markupBasePath != nil, let old = previous.fileURL,
                   old.path != value.path, old.path != value.markupBasePath, files.isFavoriteCopy(old) {
                    try db.execute("INSERT OR IGNORE INTO image_markup_garbage VALUES(?)", [.text(old.path)])
                }
            }
        } catch {
            // A durable queue entry was recorded before every creation. This
            // retries safely after an interrupted save or failed Trash action.
            drainMarkupGarbage()
            throw error
        }
        drainMarkupGarbage()
        changed([id]); return value
    }
    private func reserveMarkupAsset(extension ext: String) throws -> URL {
        try reserveManagedAsset(extension: ext, allowed: ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"])
    }
    private func reserveManagedAsset(extension ext: String, allowed: Set<String>) throws -> URL {
        guard allowed.contains(ext.lowercased()),
              files.favoritesFolder.resolvingSymlinksInPath().path == files.favoritesFolder.path else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.createDirectory(at: files.favoritesFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.favoritesFolder.path)
        let result = files.favoritesFolder.appendingPathComponent("Favorite \(UUID()).\(ext.lowercased())")
        guard !FileManager.default.fileExists(atPath: result.path) else { throw HistoryFiles.Failure.unsafeFile }
        try db.execute("INSERT INTO image_markup_garbage VALUES(?)", [.text(result.path)])
        return result
    }
    private func writeNewMarkupAsset(_ data: Data, to url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) } ?? -1 }
        guard descriptor >= 0 else { throw HistoryFiles.Failure.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard files.isFavoriteCopy(url) else { throw HistoryFiles.Failure.unsafeFile }
    }
    private func drainMarkupGarbage() {
        guard let queued = try? db.rows("SELECT path FROM image_markup_garbage"), !queued.isEmpty,
              let records = try? LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE kind='image'")) else { return }
        let referenced = Set(records.flatMap { [$0.path, $0.markupBasePath, $0.recordingOriginalPath].compactMap { $0 } }).union(recordingTrimPending)
        for row in queued {
            guard let path = row["path"]?.string else { continue }
            if referenced.contains(path) { continue }
            let url = URL(fileURLWithPath: path)
            do {
                if FileManager.default.fileExists(atPath: path) {
                    guard files.isFavoriteCopy(url) else { continue }
                    _ = try files.trashAppCopy(url)
                }
                try db.execute("DELETE FROM image_markup_garbage WHERE path=?", [.text(path)])
            } catch { /* Retry on the next save or launch; no permanent deletion. */ }
        }
    }
    /// Snapshot outside the main actor so a large recording never freezes the
    /// shelves. A durable unpublished-asset intent covers interruption/crash.
    func prepareRecordingTrim(_ id: UUID) async throws -> RecordingTrimContext {
        guard let value = try item(id), value.kind == .image, value.deletedAt == nil,
              let source = value.fileURL, isRecordingFile(source), files.isRegularFile(source),
              value.recordingOriginalURL.map(files.isFavoriteCopy) != false else { throw HistoryFiles.Failure.unsafeFile }
        var reserved = [URL]()
        do {
            let snapshot = try reserveManagedAsset(extension: source.pathExtension, allowed: ["mov", "mp4"]); reserved.append(snapshot)
            let output = try reserveManagedAsset(extension: source.pathExtension, allowed: ["mov", "mp4"]); reserved.append(output)
            recordingTrimPending.formUnion(reserved.map(\.path))
            let worker = Task.detached(priority: .userInitiated) { try RecordingTrimFiles.snapshot(source, to: snapshot) }
            let fingerprint = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard let current = try item(id), current.deletedAt == nil, current.path == source.path else { throw HistoryFiles.Failure.unsafeFile }
            let context = RecordingTrimContext(token: UUID(), id: id, source: source, sourceFingerprint: fingerprint, snapshot: snapshot, output: output)
            recordingTrims[context.token] = context
            return context
        } catch {
            recordingTrimPending.subtract(reserved.map(\.path)); drainMarkupGarbage(); throw error
        }
    }
    func discardRecordingTrim(_ context: RecordingTrimContext) {
        guard recordingTrims[context.token] == context else { return }
        recordingTrims.removeValue(forKey: context.token)
        recordingTrimPending.subtract([context.snapshot.path, context.output.path])
        drainMarkupGarbage()
    }
    /// Publish the validated derivative under the existing ID only. Pinning,
    /// retention, names, notes and memberships may change while export runs;
    /// take them from the current record rather than its opening snapshot.
    @discardableResult func commitRecordingTrim(_ context: RecordingTrimContext) async throws -> LibraryRecord {
        guard recordingTrims[context.token] == context else { throw HistoryFiles.Failure.unsafeFile }
        defer { discardRecordingTrim(context) }
        let worker = Task.detached(priority: .userInitiated) {
            try await RecordingTrimFiles.validateExport(context.output)
            guard try RecordingTrimFiles.fingerprint(context.source) == context.sourceFingerprint else { throw HistoryFiles.Failure.unsafeFile }
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard recordingTrims[context.token] == context,
              var value = try item(context.id), value.kind == .image, value.deletedAt == nil, value.path == context.source.path,
              files.isFavoriteCopy(context.snapshot), files.isFavoriteCopy(context.output),
              value.recordingOriginalURL.map(files.isFavoriteCopy) != false else { throw HistoryFiles.Failure.unsafeFile }
        let previousPath = value.path
        value.recordingOriginalPath = value.recordingOriginalPath ?? context.snapshot.path
        value.originalPath = value.originalPath ?? context.source.path
        value.path = context.output.path; value.updatedAt = now()
        try db.transaction {
            try put(value)
            try db.execute("DELETE FROM image_analysis WHERE item=?", [.text(value.id.uuidString)])
            for path in [value.path, value.recordingOriginalPath].compactMap({ $0 }) {
                try db.execute("DELETE FROM image_markup_garbage WHERE path=?", [.text(path)])
            }
            if let path = previousPath, path != value.recordingOriginalPath, files.isFavoriteCopy(URL(fileURLWithPath: path)) {
                try db.execute("INSERT OR IGNORE INTO image_markup_garbage VALUES(?)", [.text(path)])
            }
        }
        changed([value.id]); return value
    }
    func update(_ id: UUID, _ transform: (inout LibraryRecord) throws -> Void) throws {
        guard var value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }
        let previous = value
        try transform(&value); value.updatedAt = now()
        if previous.deletedAt == nil, value.deletedAt != nil { value.trashRevision = UUID() }
        else if previous.deletedAt != nil, value.deletedAt == nil { value.trashRevision = nil }
        guard (value.text?.utf8.count ?? 0) <= TextClipboardWatcher.maximumDataBytes, value.note.utf8.count <= TextClipboardWatcher.maximumDataBytes else { throw HistoryFiles.Failure.unsafeFile }
        let copy = value.retainedAt != nil ? try ensureOwned(&value) : nil
        let textFileRollback = value.kind == .text ? try rewriteMaterializedText(previous, to: value.text ?? "") : nil
        do { try db.transaction { try put(value) } }
        catch {
            if let rollback = textFileRollback { try? writePrivate(rollback.data, to: rollback.url) }
            discardUnpublished(copy.map { [$0] } ?? []); throw error
        }
        changed([id])
    }
    private func rewriteMaterializedText(_ previous: LibraryRecord, to text: String) throws -> (url: URL, data: Data)? {
        let old = Data((previous.text ?? "").utf8), new = Data(text.utf8)
        guard old != new else { return nil }
        let file = files.inbox.appendingPathComponent("Texts/Text \(previous.id).txt")
        let isLink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard FileManager.default.fileExists(atPath: file.path) || isLink else { return nil }
        guard files.isRegularFile(file), file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
              try Data(contentsOf: file) == old else { throw HistoryFiles.Failure.unsafeFile }
        try writePrivate(new, to: file)
        return (file, old)
    }
    func retain(_ ids: [UUID]) throws { try mutate(ids) { if $0.retainedAt == nil { $0.retainedAt = self.now() } } }
    /// Naming is one durable action: never publish a title without its pin or
    /// pin an external screenshot without first protecting a private copy.
    /// Clipboard bytes, fetched metadata and organization stay independent.
    @discardableResult func nameAndPin(_ id: UUID, name: String) throws -> LibraryRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLineOrControl = name.unicodeScalars.contains {
            [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
        guard !name.isEmpty, name.count <= Self.maximumItemNameLength,
              name.utf8.count <= 1024, !hasLineOrControl else { throw ItemNameError.invalid }
        guard var value = try item(id), value.deletedAt == nil else { throw HistoryFiles.Failure.unsafeFile }
        let previousPath = value.path
        value.title = name; value.favorite = true
        value.retainedAt = value.retainedAt ?? now(); value.updatedAt = now()
        try ensureOwned(&value)
        do { try db.transaction { try put(value) } }
        catch {
            if value.path != previousPath, let copy = value.fileURL, files.isFavoriteCopy(copy) { _ = try? files.trashAppCopy(copy) }
            throw error
        }
        changed([id]); return value
    }
    func toggleFavorite(_ ids: [UUID]) throws { try mutate(ids) { $0.favorite.toggle(); if $0.favorite && $0.retainedAt == nil { $0.retainedAt = self.now() } } }
    private func mutate(_ ids: [UUID], _ transform: (inout LibraryRecord) throws -> Void) throws {
        var values = try ids.map { id -> LibraryRecord in guard let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }; return value }
        var copies = [URL]()
        do {
            for index in values.indices {
                try transform(&values[index]); values[index].updatedAt = now()
                if values[index].retainedAt != nil, let copy = try ensureOwned(&values[index]) { copies.append(copy) }
            }
            try db.transaction { for value in values { try put(value) } }
        } catch { discardUnpublished(copies); throw error }
        invalidateTrashUndo(ids); changed(ids)
    }
    func removeFromShelf(_ ids: [UUID]) throws {
        let values = try records(Array(Set(ids))).filter { $0.onShelf && $0.deletedAt == nil }
        guard !values.isEmpty else { return }
        let date = now()
        try mutate(values.map(\.id)) { $0.onShelf = false; if $0.retainedAt == nil { $0.deletedAt = date; $0.trashRevision = UUID() } }
        shelfRemovalUndo.append(values.map { ShelfRemoval(id: $0.id, removedAt: $0.retainedAt == nil ? date : nil) })
        if shelfRemovalUndo.count > 32 { shelfRemovalUndo.removeFirst() }
    }
    /// Restore only shelf visibility/deletion flags. Edits, pins, tags, folders,
    /// original dates and managed file paths may have changed since removal.
    @discardableResult func undoShelfRemoval() throws -> [UUID] {
        while let snapshot = shelfRemovalUndo.last {
            let values = try snapshot.filter { entry in
                guard let record = try item(entry.id) else { return false }
                return !record.onShelf && record.deletedAt == entry.removedAt
            }
            guard !values.isEmpty else { shelfRemovalUndo.removeLast(); continue }
            let ids = values.map(\.id)
            try mutate(ids) { $0.onShelf = true; $0.deletedAt = nil; $0.trashRevision = nil }
            shelfRemovalUndo.removeLast(); return ids
        }
        return []
    }
    private func invalidateShelfUndo(_ ids: [UUID]) {
        let affected = Set(ids)
        shelfRemovalUndo = shelfRemovalUndo.map { $0.filter { !affected.contains($0.id) } }.filter { !$0.isEmpty }
    }
    func trash(_ ids: [UUID]) throws { try mutate(ids) { $0.deletedAt = self.now(); $0.onShelf = false; $0.trashRevision = UUID() }; invalidateShelfUndo(ids) }
    /// Library user actions have a separate, bounded undo history. Keep only
    /// visibility and a digest of the exact committed trash generation; never
    /// retain a second megabyte-sized text or a copy of image bytes in RAM.
    func trashUndoably(_ ids: [UUID]) throws {
        var snapshot = [TrashRemoval]()
        try db.transaction {
            let date = now()
            var seen = Set<UUID>(), previousVisibility = [(UUID, Bool)]()
            for id in ids where seen.insert(id).inserted {
                guard var value = try item(id), value.deletedAt == nil else { continue }
                let onShelf = value.onShelf
                value.deletedAt = date; value.onShelf = false; value.updatedAt = date; value.trashRevision = UUID()
                try put(value)
                previousVisibility.append((id, onShelf))
            }
            for (id, onShelf) in previousVisibility {
                guard let fingerprint = try trashFingerprint(id) else { throw HistoryFiles.Failure.unsafeFile }
                snapshot.append(TrashRemoval(id: id, onShelf: onShelf, fingerprint: fingerprint))
            }
        }
        guard !snapshot.isEmpty else { return }
        let affected = snapshot.map(\.id)
        invalidateShelfUndo(affected); invalidateTrashUndo(affected)
        trashRemovalUndo.append(snapshot)
        if trashRemovalUndo.count > 80 { trashRemovalUndo.removeFirst(trashRemovalUndo.count - 80) }
        changed(affected)
    }
    /// Restore flags only when the complete committed row and organization
    /// still match. Later captures, edits, restores and re-trashes are never
    /// overwritten, including writers using the same clock and another store.
    @discardableResult func undoTrash() throws -> [UUID] {
        guard !trashRemovalUndo.isEmpty else { return [] }
        var consumed = 0, restored = [UUID]()
        try db.transaction {
            for snapshot in trashRemovalUndo.reversed() {
                consumed += 1
                let eligible = try snapshot.filter { entry in try trashFingerprint(entry.id) == entry.fingerprint }
                guard !eligible.isEmpty else { continue }
                let date = now()
                for entry in eligible {
                    guard var value = try item(entry.id), value.deletedAt != nil else { throw HistoryFiles.Failure.unsafeFile }
                    value.deletedAt = nil; value.onShelf = entry.onShelf; value.updatedAt = date; value.trashRevision = nil
                    try put(value); restored.append(entry.id)
                }
                break
            }
        }
        // Transaction failures leave both the data and every pending batch
        // intact. Even stale batches are retired only after a successful commit.
        trashRemovalUndo.removeLast(consumed)
        if !restored.isEmpty { invalidateShelfUndo(restored) }
        if consumed > 0 { changed(restored) }
        return restored
    }
    private func invalidateTrashUndo(_ ids: [UUID]) {
        let affected = Set(ids)
        trashRemovalUndo = trashRemovalUndo.map { $0.filter { !affected.contains($0.id) } }.filter { !$0.isEmpty }
    }
    private func trashFingerprint(_ id: UUID) throws -> Data? {
        guard let row = try db.rows("SELECT * FROM items WHERE id=? AND deleted IS NOT NULL", [.text(id.uuidString)]).first else { return nil }
        var digest = SHA256()
        func field(_ value: Data) {
            var size = UInt64(value.count).bigEndian
            digest.update(data: withUnsafeBytes(of: &size) { Data($0) }); digest.update(data: value)
        }
        func value(_ value: SQLValue) {
            switch value {
            case let .text(text): field(Data("text".utf8)); field(Data(text.utf8))
            case let .integer(number): field(Data("integer".utf8)); field(Data(String(number).utf8))
            case let .real(number): field(Data("real".utf8)); field(Data(String(number.bitPattern, radix: 16).utf8))
            case let .blob(data): field(Data("blob".utf8)); field(data)
            case .null: field(Data("null".utf8))
            }
        }
        for key in row.keys.sorted() { field(Data(key.utf8)); value(row[key]!) }
        let folders = try db.rows("SELECT c.id,c.name,c.parent FROM collections c JOIN item_collections m ON m.collection=c.id WHERE m.item=? ORDER BY c.id", [.text(id.uuidString)])
        let tags = try db.rows("SELECT t.id,t.name FROM tags t JOIN item_tags m ON m.tag=t.id WHERE m.item=? ORDER BY t.id", [.text(id.uuidString)])
        for (kind, rows) in [("folders", folders), ("tags", tags)] {
            field(Data(kind.utf8))
            for row in rows { for key in row.keys.sorted() { field(Data(key.utf8)); value(row[key]!) } }
        }
        return Data(digest.finalize())
    }
    private static let unsavedHistoryWhere = "i.deleted IS NULL AND i.retained IS NULL AND i.favorite=0 AND NOT EXISTS(SELECT 1 FROM item_collections c WHERE c.item=i.id) AND NOT EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id)"
    func unsavedHistoryCount(kind: LibraryKind? = nil) throws -> Int {
        let clause = Self.unsavedHistoryWhere + (kind == nil ? "" : " AND i.kind=?")
        let values: [SQLValue] = kind.map { [.text($0.rawValue)] } ?? []
        return Int(try db.rows("SELECT COUNT(*) AS n FROM items i WHERE " + clause, values).first?["n"]?.number ?? 0)
    }
    func unsavedHistorySnapshot(kind: LibraryKind? = nil) throws -> UnsavedHistorySnapshot {
        let clause = Self.unsavedHistoryWhere + (kind == nil ? "" : " AND i.kind=?")
        let values: [SQLValue] = kind.map { [.text($0.rawValue)] } ?? []
        let rows = try db.rows("SELECT i.id,printf('%!.17g|%!.17g|%s|%s',i.created,i.updated,COALESCE(json_extract(CAST(i.payload AS TEXT),'$.captureRevision'),''),COALESCE(json_extract(CAST(i.payload AS TEXT),'$.lastCopiedAt'),'')) AS version FROM items i WHERE " + clause + " ORDER BY i.id", values)
        var ids = [UUID](), captures = [UUID: String]()
        for row in rows {
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let version = row["version"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            ids.append(id); captures[id] = version
        }
        return UnsavedHistorySnapshot(kind: kind, ids: ids, captures: captures)
    }
    @discardableResult func clearUnsavedHistory(_ snapshot: UnsavedHistorySnapshot) throws -> [UUID] {
        guard !snapshot.ids.isEmpty else { return [] }
        let date = now()
        var eligible = [UUID]()
        // Acquire the writer lock before reading eligibility or payloads. A
        // rollback app's save must never be overwritten by a stale read.
        try db.transaction {
            let current = try unsavedHistorySnapshot(kind: snapshot.kind)
            var seen = Set<UUID>()
            for id in snapshot.ids where seen.insert(id).inserted {
                guard let version = snapshot.captures[id], current.captures[id] == version,
                      var value = try item(id) else { continue }
                value.deletedAt = date; value.onShelf = false; value.updatedAt = date; value.trashRevision = UUID()
                try put(value); eligible.append(id)
            }
        }
        guard !eligible.isEmpty else { return [] }
        invalidateShelfUndo(eligible); invalidateTrashUndo(eligible); changed(eligible)
        return eligible
    }
    func restore(_ ids: [UUID]) throws { try mutate(ids) { $0.deletedAt = nil; $0.onShelf = true; $0.trashRevision = nil }; invalidateShelfUndo(ids) }
    func markCopied(_ ids: [UUID]) throws { try mutate(ids) { $0.lastCopiedAt = self.now(); $0.captureRevision = UUID() } }
    func prune() throws {
        var expired = [LibraryRecord]()
        for kind in LibraryKind.allCases {
            let cutoff = now().addingTimeInterval(-Double(retentionDays(for: kind)) * 86400)
            // Text ordering may advance slightly beyond the wall clock after
            // a clock correction. Expiry must use actual capture time, never
            // that ordering timestamp. The derivative index keeps it bounded.
            let sql = kind == .text
                ? "SELECT i.payload FROM text_identity t JOIN items i ON i.id=t.item WHERE i.kind=? AND i.deleted IS NULL AND i.retained IS NULL AND t.captured<=?"
                : "SELECT payload FROM items WHERE kind=? AND deleted IS NULL AND retained IS NULL AND created<=?"
            expired += try LibrarySQL.decode(db.rows(sql, [.text(kind.rawValue), .real(cutoff.timeIntervalSince1970)])).filter { ($0.lastCapturedAt ?? $0.createdAt) <= cutoff }
        }
        if !expired.isEmpty { try trash(expired.map(\.id)) }
        // Copies trashed above start their Trash clock now; only items that
        // have already waited out the Trash period are removed for good.
        if let days = HistoryRetention.trashDays(defaults: defaults) {
            try purgeTrash(olderThan: now().addingTimeInterval(-Double(days) * 86400))
        }
        // A snapshot still holds what was purged above, but only for its week.
        snapshots.expire(now: now())
    }
    func trashCount(olderThan cutoff: Date = .distantFuture) throws -> Int {
        Int(try db.rows("SELECT count(*) AS n FROM items WHERE deleted IS NOT NULL AND deleted<=?", [.real(cutoff.timeIntervalSince1970)]).first?["n"]?.number ?? 0)
    }
    /// What an Empty Trash confirmation describes, and the moment it describes.
    func trashSnapshot() throws -> (count: Int, asOf: Date) { let date = now(); return (try trashCount(olderThan: date), date) }
    /// Permanently removes items that entered Trash at or before `cutoff`,
    /// with their folder, tag, search and identity rows, in one transaction.
    /// Restored items and items trashed later are untouched. Files Shelf made
    /// for those items then move to the system Trash; a file that cannot be
    /// moved stays where it is and never brings a row back. Originals outside
    /// Shelf's storage are not touched.
    @discardableResult func purgeTrash(olderThan cutoff: Date) throws -> [UUID] {
        let bound: [SQLValue] = [.real(cutoff.timeIntervalSince1970)]
        let expired = "deleted IS NOT NULL AND deleted<=?", expiredIDs = "SELECT id FROM items WHERE deleted IS NOT NULL AND deleted<=?"
        func extract(_ field: String) -> String { "json_extract(CAST(payload AS TEXT),'$.\(field)') AS \(field)" }
        let fileFields = ["path", "markupBasePath", "recordingOriginalPath"]
        var rows = [[String: SQLValue]]()
        try db.transaction {
            // Paths only: a trashed megabyte of text is never decoded to delete it.
            rows = try db.rows("SELECT id,kind,path,\(extract("markupBasePath")),\(extract("recordingOriginalPath")),\(extract("thumbnailPath")) FROM items WHERE \(expired)", bound)
            guard !rows.isEmpty else { return }
            for row in rows where row["kind"]?.string == LibraryKind.image.rawValue {
                // The durable queue retries a managed copy that cannot move now.
                for path in fileFields.compactMap({ row[$0]?.string }) where files.isFavoriteCopy(URL(fileURLWithPath: path)) {
                    try db.execute("INSERT OR IGNORE INTO image_markup_garbage VALUES(?)", [.text(path)])
                }
            }
            try db.execute("DELETE FROM item_tags WHERE item IN (\(expiredIDs))", bound)
            try db.execute("DELETE FROM item_collections WHERE item IN (\(expiredIDs))", bound)
            try forgetLegacySearch(expired, bound)
            try db.execute("DELETE FROM text_identity WHERE item IN (\(expiredIDs))", bound)
            try db.execute("DELETE FROM image_analysis WHERE item IN (\(expiredIDs))", bound)
            try db.execute("DELETE FROM items WHERE \(expired)", bound)
        }
        let ids = rows.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty else { return [] }
        invalidateShelfUndo(ids); invalidateTrashUndo(ids)
        // Committed. Nothing below can fail the purge or restore a row.
        drainMarkupGarbage()
        let live = (try? db.rows("SELECT path,\(extract("markupBasePath")),\(extract("recordingOriginalPath")) FROM items WHERE kind='image'")) ?? []
        let referenced = Set(live.flatMap { row in fileFields.compactMap { row[$0]?.string } })
        for row in rows {
            guard let id = row["id"]?.string else { continue }
            switch row["kind"]?.string.flatMap(LibraryKind.init(rawValue:)) {
            case .image:
                for path in Set(fileFields.compactMap { row[$0]?.string }) where !referenced.contains(path) {
                    let url = URL(fileURLWithPath: path)
                    if files.isClipboardCopy(url) { _ = try? files.trashAppCopy(url) }
                }
            case .text: trashMaterializedCopy("Texts/Text \(id).txt")
            case .link:
                trashMaterializedCopy("Links/Link \(id).webloc")
                if let path = row["thumbnailPath"]?.string {
                    let file = URL(fileURLWithPath: path)
                    if file.deletingLastPathComponent() == thumbnailsFolder, file.resolvingSymlinksInPath() == file { try? FileManager.default.removeItem(at: file) }
                }
            case nil: break
            }
        }
        changedIDs = Set(ids)
        changedKinds = Set(rows.compactMap { $0["kind"]?.string.flatMap(LibraryKind.init(rawValue:)) })
        revision += 1
        // Deleting from the search index only marks its words; merging the
        // index drops them. Until the log is folded back and truncated it
        // still holds the old pages.
        if searchStatus != nil { try? db.execute("INSERT INTO search_trigram(search_trigram) VALUES('optimize')") }
        if legacySearchTable { try? db.execute("INSERT INTO search_fts(search_fts) VALUES('optimize')") }
        _ = try? db.rows("PRAGMA wal_checkpoint(TRUNCATE)")
        if Self.hasWorthwhileFreeSpace(db) { compact() }
        return ids
    }
    /// Empties Trash as the user saw it at `date`: an item trashed after the
    /// confirmation appeared is kept.
    @discardableResult func emptyTrash(asOf date: Date = .distantFuture) throws -> [UUID] {
        let ids = try purgeTrash(olderThan: date)
        // A snapshot would keep what was just deleted; an explicit Empty Trash
        // does not wait for it to expire.
        snapshots.removeAll()
        if !ids.isEmpty { compact() }
        return ids
    }
    /// The text or link file Shelf wrote for a drag or export of this item.
    private func trashMaterializedCopy(_ name: String) {
        let file = files.inbox.appendingPathComponent(name), folder = file.deletingLastPathComponent()
        guard folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path, files.isRegularFile(file) else { return }
        _ = try? files.moveToTrash(file)
    }
    /// Returns free pages to the system. Purged content is already overwritten,
    /// so this only shrinks the file. VACUUM rewrites all of it: it runs on its
    /// own connection off the main actor, and is skipped for a library large
    /// enough that a save could wait on it longer than the busy timeout.
    func compact(completion: (@MainActor (Bool) -> Void)? = nil) {
        let url = databaseURL
        maintenanceQueue.async {
            var compacted = false
            if let database = try? LibraryDatabase(url: url, verify: false) { compacted = Self.vacuum(database, at: url) }
            if let completion { Task { @MainActor in completion(compacted) } }
        }
    }
    nonisolated private static func hasWorthwhileFreeSpace(_ database: LibraryDatabase, fraction: Int64 = 4) -> Bool {
        guard let free = try? database.rows("PRAGMA freelist_count").first?["freelist_count"]?.number,
              let pages = try? database.rows("PRAGMA page_count").first?["page_count"]?.number else { return false }
        return free >= 256 && free * fraction > pages
    }
    nonisolated private static func vacuum(_ database: LibraryDatabase, at url: URL) -> Bool {
        // Asked of the file system each time; a URL remembers an earlier answer.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= maximumCompactedBytes else { return false }
        let compacted = (try? database.execute("VACUUM")) != nil
        _ = try? database.rows("PRAGMA wal_checkpoint(TRUNCATE)")
        return compacted
    }
    nonisolated static let maximumCompactedBytes = 256 * 1024 * 1024
    func collections() throws -> [LibraryCollection] {
        try db.rows("SELECT * FROM collections ORDER BY folded,id").map { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            return LibraryCollection(id: id, name: name, parentID: row["parent"]?.string.flatMap(UUID.init(uuidString:)))
        }
    }
    @discardableResult func createCollection(_ name: String, parent: UUID? = nil) throws -> UUID {
        let name = try cleanedName(name), all = try collections()
        if let parent { guard let value = all.first(where: { $0.id == parent }), value.parentID == nil else { throw HistoryFiles.Failure.invalidDestination } }
        guard !all.contains(where: { $0.parentID == parent && $0.name.libraryFolded == name.libraryFolded }) else { throw HistoryFiles.Failure.invalidDestination }
        let id = UUID(); try db.execute("INSERT INTO collections VALUES(?,?,?,?)", [.text(id.uuidString), .text(name), parent.map { .text($0.uuidString) } ?? .null, .text(name.libraryFolded)]); changed(); return id
    }
    func renameCollection(_ id: UUID, name: String) throws {
        let name = try cleanedName(name), all = try collections()
        guard let collection = all.first(where: { $0.id == id }), !all.contains(where: { $0.id != id && $0.parentID == collection.parentID && $0.name.libraryFolded == name.libraryFolded }) else { throw HistoryFiles.Failure.invalidDestination }
        try db.execute("UPDATE collections SET name=?,folded=? WHERE id=?", [.text(name), .text(name.libraryFolded), .text(id.uuidString)]); changed()
    }
    func removeCollection(_ id: UUID) throws {
        try db.transaction {
            let ids = try collections().filter { $0.id == id || $0.parentID == id }.map(\.id)
            for child in ids { try db.execute("DELETE FROM item_collections WHERE collection=?", [.text(child.uuidString)]) }
            for child in ids.filter({ $0 != id }) { try db.execute("DELETE FROM collections WHERE id=?", [.text(child.uuidString)]) }
            try db.execute("DELETE FROM collections WHERE id=?", [.text(id.uuidString)])
        }; changed()
    }
    func collections(for item: UUID) throws -> [LibraryCollection] {
        try db.rows("SELECT c.* FROM collections c JOIN item_collections m ON m.collection=c.id WHERE m.item=? ORDER BY c.folded,c.id", [.text(item.uuidString)]).map { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            return LibraryCollection(id: id, name: name, parentID: row["parent"]?.string.flatMap(UUID.init(uuidString:)))
        }
    }
    func pin(_ ids: [UUID], to collection: UUID? = nil) throws {
        if let collection { try assign(ids, to: collection, pinning: true) }
        else { try mutate(ids) { guard $0.deletedAt == nil else { throw HistoryFiles.Failure.unsafeFile }; $0.favorite = true; $0.retainedAt = $0.retainedAt ?? self.now() } }
    }
    func assign(_ ids: [UUID], to collection: UUID, movingFrom source: UUID? = nil, pinning: Bool = false) throws {
        let folders = try collections()
        guard folders.contains(where: { $0.id == collection }), source == nil || folders.contains(where: { $0.id == source }) else { throw HistoryFiles.Failure.invalidDestination }
        let sources = source.map { source in folders.filter { $0.id == source || $0.parentID == source }.map(\.id) } ?? []
        var values = try ids.map { id -> LibraryRecord in guard let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }; return value }
        var copies = [URL]()
        do {
            for index in values.indices {
                if pinning { guard values[index].deletedAt == nil else { throw HistoryFiles.Failure.unsafeFile }; values[index].favorite = true }
                values[index].retainedAt = values[index].retainedAt ?? now()
                if let copy = try ensureOwned(&values[index]) { copies.append(copy) }
            }
            try db.transaction {
                for value in values {
                    try put(value); try db.execute("INSERT OR IGNORE INTO item_collections VALUES(?,?)", [.text(value.id.uuidString), .text(collection.uuidString)])
                    for source in sources where source != collection { try db.execute("DELETE FROM item_collections WHERE item=? AND collection=?", [.text(value.id.uuidString), .text(source.uuidString)]) }
                }
            }
        } catch { discardUnpublished(copies); throw error }
        changed()
    }
    func unassign(_ id: UUID, from collection: UUID) throws { try db.execute("DELETE FROM item_collections WHERE item=? AND collection=?", [.text(id.uuidString), .text(collection.uuidString)]); changed() }
    func tags() throws -> [LibraryTag] { try db.rows("SELECT * FROM tags ORDER BY folded,id").map { row in guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }; return LibraryTag(id: id, name: name) } }
    func tags(for item: UUID) throws -> [LibraryTag] {
        try db.rows("SELECT t.* FROM tags t JOIN item_tags m ON m.tag=t.id WHERE m.item=? ORDER BY t.folded,t.id", [.text(item.uuidString)]).map { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            return LibraryTag(id: id, name: name)
        }
    }
    private func cleanedName(_ name: String) throws -> String { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty, value.count <= 64, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw HistoryFiles.Failure.invalidDestination }; return value }
    func addTag(_ name: String, to ids: [UUID]) throws {
        let name = try cleanedName(name.trimmingCharacters(in: CharacterSet(charactersIn: "#"))), folded = name.libraryFolded
        let existing = try tags().first { $0.name.libraryFolded == folded }, tagID = existing?.id ?? UUID()
        var values = try ids.map { id -> LibraryRecord in guard let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }; return value }
        var copies = [URL]()
        do {
            for index in values.indices {
                values[index].retainedAt = values[index].retainedAt ?? now()
                if let copy = try ensureOwned(&values[index]) { copies.append(copy) }
            }
            try db.transaction {
                if existing == nil { try db.execute("INSERT INTO tags VALUES(?,?,?)", [.text(tagID.uuidString), .text(name), .text(folded)]) }
                for value in values { try put(value); try db.execute("INSERT OR IGNORE INTO item_tags VALUES(?,?)", [.text(value.id.uuidString), .text(tagID.uuidString)]); try put(value) }
            }
        } catch { discardUnpublished(copies); throw error }
        changed()
    }
    func removeTag(_ tag: UUID, from itemID: UUID? = nil) throws {
        let affected = try db.rows("SELECT item FROM item_tags WHERE tag=?", [.text(tag.uuidString)]).compactMap { $0["item"]?.string.flatMap(UUID.init(uuidString:)) }
        try db.transaction {
            if let itemID { try db.execute("DELETE FROM item_tags WHERE tag=? AND item=?", [.text(tag.uuidString), .text(itemID.uuidString)]) }
            else { try db.execute("DELETE FROM item_tags WHERE tag=?", [.text(tag.uuidString)]); try db.execute("DELETE FROM tags WHERE id=?", [.text(tag.uuidString)]) }
            for id in affected { if let value = try item(id) { try put(value) } }
        }; changed()
    }
    func renameTag(_ id: UUID, name: String) throws {
        let name = try cleanedName(name)
        let existing = try tags()
        guard existing.contains(where: { $0.id == id }), !existing.contains(where: { $0.id != id && $0.name.libraryFolded == name.libraryFolded }) else { throw HistoryFiles.Failure.invalidDestination }
        let affected = try db.rows("SELECT item FROM item_tags WHERE tag=?", [.text(id.uuidString)]).compactMap { $0["item"]?.string.flatMap(UUID.init(uuidString:)) }
        try db.transaction { try db.execute("UPDATE tags SET name=?,folded=? WHERE id=?", [.text(name), .text(name.libraryFolded), .text(id.uuidString)]); for id in affected { if let value = try item(id) { try put(value) } } }; changed()
    }
    func backup(to url: URL) throws { try db.backup(to: url) }
    /// A dated standalone copy of the database as it is now. See `LibrarySnapshots`.
    @discardableResult func makeSnapshot() throws -> URL { try snapshots.make(of: db, at: now()) }
    func writePrivate(_ data: Data, to url: URL) throws {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == url.deletingLastPathComponent().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: url.path) || url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw HistoryFiles.Failure.unsafeFile }
        let stage = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID())")
        guard FileManager.default.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw HistoryFiles.Failure.unsafeFile }
        do {
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: stage) }
            else { try FileManager.default.moveItem(at: stage, to: url) }
        } catch {
            // The stage holds only the bytes this call was given; nothing else refers to it.
            try? FileManager.default.removeItem(at: stage); throw error
        }
    }
    private func changed(_ ids: [UUID] = []) {
        changedIDs = Set(ids)
        changedKinds = ids.isEmpty ? Set(LibraryKind.allCases) : kinds(of: ids)
        revision += 1
    }
    /// The kinds among `ids`, read from the kind column in one query per few
    /// hundred items instead of decoding each item's whole record. If that
    /// cannot be read, every kind is reported so no shelf misses the change.
    private func kinds(of ids: [UUID]) -> Set<LibraryKind> {
        var result = Set<LibraryKind>(), start = 0
        while start < ids.count {
            let batch = ids[start..<min(ids.count, start + 500)]; start += 500
            guard let rows = try? db.rows("SELECT DISTINCT kind FROM items WHERE id IN (" + batch.map { _ in "?" }.joined(separator: ",") + ")", batch.map { .text($0.uuidString) }) else { return Set(LibraryKind.allCases) }
            result.formUnion(rows.compactMap { $0["kind"]?.string.flatMap(LibraryKind.init(rawValue:)) })
        }
        return result
    }
    /// Used by local import and large synthetic fixtures. One transaction and
    /// one publication keep the UI from re-reading every intermediate record.
    func importRecords(_ records: [LibraryRecord]) throws {
        var seen = Set<UUID>()
        for record in records {
            guard seen.insert(record.id).inserted, (record.text?.utf8.count ?? 0) <= TextClipboardWatcher.maximumDataBytes,
                  record.note.utf8.count <= TextClipboardWatcher.maximumDataBytes, try item(record.id) == nil else { throw HistoryFiles.Failure.unsafeFile }
            if record.kind == .image { guard let file = record.fileURL, files.isRegularFile(file) else { throw HistoryFiles.Failure.unsafeFile } }
            if record.kind == .link { guard let url = record.linkURL, LinkIdentity.normalized(url) == record.normalizedURL else { throw HistoryFiles.Failure.unsafeFile } }
        }
        var copies = [URL]()
        do { try db.transaction { for var record in records { if record.retainedAt != nil, let copy = try ensureOwned(&record) { copies.append(copy) }; try put(record) } } }
        catch { discardUnpublished(copies); throw error }
        changed()
    }
}
