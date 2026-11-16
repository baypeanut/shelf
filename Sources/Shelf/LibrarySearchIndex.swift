import Foundation
import SQLite3

/// Substring search without reading every item.
///
/// `items.search` holds each item's folded text, and search has always meant
/// "the folded term occurs in it" (`instr`). This index keeps that meaning and
/// only narrows where to look: an FTS5 table with the trigram tokenizer records
/// which three-character sequences each text contains, so a term of three or
/// more characters can only occur in texts that contain all of its trigrams.
/// Those candidates are then checked with the same `instr` as before. A wrong
/// or stale index entry can therefore add work but never add a result, and the
/// rules below guarantee it never hides one.
///
/// - The index stores no text and no positions (`content=''`, `detail=none`),
///   only trigram-to-item lists, and is case sensitive because the text it is
///   given is already folded.
/// - `search_docs` gives every indexed item a stable integer. The implicit
///   rowid of `items` cannot be used: VACUUM renumbers it.
/// - Triggers on `items` keep the index current for every writer, including an
///   older build of the app that knows nothing about it.
/// - The tokenizer stops at a NUL character, so a text containing one is listed
///   in `search_unindexed` and is always a candidate.
/// - Until `search_index_state.complete` is 1, an item with no entry in either
///   table has not been indexed yet and is always a candidate.
enum LibrarySearchIndex {
    static let minimumTermLength = 3

    static func isInstalled(_ database: LibraryDatabase) throws -> Bool {
        try !database.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='search_index_state'").isEmpty
    }
    static func isComplete(_ database: LibraryDatabase) throws -> Bool {
        try database.rows("SELECT complete FROM search_index_state").first?["complete"]?.number == 1
    }
    static func hasLegacyTable(_ database: LibraryDatabase) throws -> Bool {
        try !database.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='search_fts'").isEmpty
    }
    /// The earlier build found an item's row in `search_fts` by reading the
    /// whole table. Until that table is gone, this lets a save or a purge
    /// remove the row directly. It is dropped with the table.
    static func indexLegacyTable(_ database: LibraryDatabase) throws {
        try database.execute("CREATE INDEX IF NOT EXISTS search_fts_items ON search_fts_content(c0)")
    }
    /// Removes what `search_fts` holds for the items matching `condition`.
    static func forgetLegacy(_ database: LibraryDatabase, indexed: Bool, where condition: String, _ values: [SQLValue]) throws {
        if indexed {
            try database.execute(
                "DELETE FROM search_fts WHERE rowid IN (SELECT c.id FROM search_fts_content c WHERE c.c0 IN (SELECT id FROM items WHERE \(condition)))",
                values)
        } else {
            try database.execute("DELETE FROM search_fts WHERE id IN (SELECT id FROM items WHERE \(condition))", values)
        }
    }

    private static func hasNUL(_ column: String) -> String { "instr(CAST(\(column) AS BLOB),x'00')>0" }
    private static let forget = """
        INSERT INTO search_trigram(search_trigram,rowid,search) SELECT 'delete',doc,OLD.search FROM search_docs WHERE item=OLD.id;
        DELETE FROM search_docs WHERE item=OLD.id;
        DELETE FROM search_unindexed WHERE item=OLD.id;
        """
    private static let learn = """
        INSERT OR IGNORE INTO search_unindexed(item) SELECT NEW.id WHERE \(hasNUL("NEW.search"));
        INSERT INTO search_docs(item) SELECT NEW.id WHERE NOT \(hasNUL("NEW.search"));
        INSERT INTO search_trigram(rowid,search) SELECT doc,NEW.search FROM search_docs WHERE item=NEW.id;
        """

    private static let table = "fts5(search,content='',columnsize=0,detail=none,tokenize='trigram case_sensitive 1')"
    /// Throws when this SQLite cannot build the index, changing nothing.
    static func probe(_ database: LibraryDatabase) throws {
        try database.execute("CREATE VIRTUAL TABLE temp.search_probe USING \(table)")
        try database.execute("DROP TABLE temp.search_probe")
    }

    /// Creates the index. The caller runs this in one transaction. `complete`
    /// is true only for a library with no items yet.
    static func install(in database: LibraryDatabase, complete: Bool) throws {
        for sql in [
            "CREATE TABLE search_index_state(id INTEGER PRIMARY KEY CHECK(id=1),complete INTEGER NOT NULL)",
            "CREATE TABLE search_docs(doc INTEGER PRIMARY KEY,item TEXT NOT NULL UNIQUE)",
            "CREATE TABLE search_unindexed(item TEXT PRIMARY KEY)",
            "CREATE VIRTUAL TABLE search_trigram USING \(table)",
            "CREATE TRIGGER search_index_insert AFTER INSERT ON items BEGIN \(learn) END",
            "CREATE TRIGGER search_index_delete AFTER DELETE ON items BEGIN \(forget) END",
            // An unchanged text, as when an item is only pinned or recopied, costs nothing.
            "CREATE TRIGGER search_index_update AFTER UPDATE OF id,search ON items WHEN OLD.search IS NOT NEW.search OR OLD.id IS NOT NEW.id BEGIN \(forget) \(learn) END",
        ] { try database.execute(sql) }
        try database.execute("INSERT INTO search_index_state VALUES(1,?)", [.integer(complete ? 1 : 0)])
    }

    /// The FTS5 query matching every text that can contain `term`, or nil when
    /// the index cannot narrow it: fewer than three characters, or a NUL.
    static func match(_ term: String) -> String? {
        let scalars = Array(term.unicodeScalars)
        guard scalars.count >= minimumTermLength, !scalars.contains(where: { $0.value == 0 }) else { return nil }
        var seen = Set<[Unicode.Scalar]>()
        var grams = [[Unicode.Scalar]]()
        for start in 0...(scalars.count - minimumTermLength) {
            let gram = Array(scalars[start..<(start + minimumTermLength)])
            if seen.insert(gram).inserted { grams.append(gram) }
        }
        // Enough to be selective; the candidates are verified in any case.
        let limit = 24
        if grams.count > limit { grams = (0..<limit).map { grams[$0 * (grams.count - 1) / (limit - 1)] } }
        return grams.map { gram in
            // Quote by scalar: a combining mark after a quotation mark must not hide it.
            var quoted = String.UnicodeScalarView()
            quoted.append("\"")
            for scalar in gram {
                quoted.append(scalar)
                if scalar == "\"" { quoted.append(scalar) }
            }
            quoted.append("\"")
            return String(quoted)
        }.joined(separator: " AND ")
    }

    /// Every item that can satisfy all of `terms`, each of which `match` can
    /// narrow: texts containing every trigram of every term, items the index
    /// does not cover, and images whose recognized text contains one of the
    /// terms. Nil when there is nothing to narrow by. `kind` only skips
    /// recognized text of other kinds; the caller's own conditions still
    /// decide what is returned.
    static func candidates(terms: [String], complete: Bool, kind: LibraryKind?, extraIDs: [UUID]) -> (sql: String, values: [SQLValue])? {
        let matches = terms.compactMap(match)
        guard !terms.isEmpty, matches.count == terms.count else { return nil }
        var arms = [
            "SELECT d.item AS item FROM search_trigram JOIN search_docs d ON d.doc=search_trigram.rowid WHERE search_trigram MATCH ?",
            "SELECT item FROM search_unindexed",
        ]
        var values: [SQLValue] = [.text(matches.joined(separator: " AND "))]
        if !complete { arms.append("SELECT x.id FROM items x WHERE NOT EXISTS(SELECT 1 FROM search_docs d WHERE d.item=x.id)") }
        let recognized = "(" + terms.map { _ in "instr(a.content,?)>0" }.joined(separator: " OR ") + ")"
        if let kind {
            arms.append("SELECT a.item FROM image_analysis a JOIN items x ON x.id=a.item WHERE x.kind=? AND \(recognized)")
            values.append(.text(kind.rawValue))
        } else {
            arms.append("SELECT a.item FROM image_analysis a WHERE \(recognized)")
        }
        values += terms.map { .text($0) }
        if !extraIDs.isEmpty {
            arms.append("SELECT column1 FROM (VALUES " + extraIDs.map { _ in "(?)" }.joined(separator: ",") + ")")
            values += extraIDs.map { .text($0.uuidString) }
        }
        return ("(" + arms.joined(separator: " UNION ") + ")", values)
    }

    // MARK: Background maintenance

    /// Shared between the store and its readers. `complete` only ever becomes true.
    final class Status: @unchecked Sendable {
        private let lock = NSLock()
        private var complete = false, cancelled = false
        var isComplete: Bool {
            lock.lock()
            defer { lock.unlock() }
            return complete
        }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func markComplete() {
            lock.lock()
            complete = true
            lock.unlock()
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Most text handled while holding the write lock once. A save on the main
    /// thread can wait behind one step, so a step stays in the low milliseconds.
    static let stepBytes: Int64 = 128 * 1024
    static let stepRows = 64
    /// The old index is dropped in one statement only when little of it is left.
    static let maximumDroppedIndexRows: Int64 = 48 * 1024

    /// Removes the unused `search_fts` table an earlier build wrote on every
    /// save, then indexes the items that existed before the index did. Both run
    /// in small transactions and continue where they stopped after a quit or
    /// crash. Returns whether the index is complete. `steps` stops it early,
    /// as a quit would. SQLite does not queue writers, so the pause between
    /// steps is what lets a save on the main thread in; the work is in no hurry.
    @discardableResult static func maintain(
        _ database: LibraryDatabase, status: Status, pause: TimeInterval = 0.01, steps: Int = .max
    ) throws -> Bool {
        try database.execute("PRAGMA secure_delete=ON")
        var remaining = steps
        try removeLegacyTable(database, status: status, pause: pause, remaining: &remaining)
        var cursor: Int64 = 0
        var verified = false
        while !status.isCancelled, remaining > 0 {
            remaining -= 1
            let finished = try database.transaction { () -> Bool in
                if try isComplete(database) { return true }
                let rows = try database.rows(
                    """
                    SELECT i.rowid AS position,i.id FROM items i
                    WHERE i.rowid>? AND NOT EXISTS(SELECT 1 FROM search_docs d WHERE d.item=i.id)
                    AND NOT EXISTS(SELECT 1 FROM search_unindexed u WHERE u.item=i.id) ORDER BY i.rowid LIMIT \(stepRows)
                    """, [.integer(cursor)])
                guard !rows.isEmpty else {
                    // Rows may have been renumbered while this ran; finish only
                    // after a pass from the beginning finds nothing.
                    if cursor == 0 || verified {
                        try database.execute("UPDATE search_index_state SET complete=1")
                        return true
                    }
                    cursor = 0
                    verified = true
                    return false
                }
                verified = false
                var bytes: Int64 = 0
                for row in rows {
                    guard let position = row["position"]?.number, let id = row["id"]?.string else {
                        throw LibraryDatabase.Failure(code: SQLITE_CORRUPT)
                    }
                    let item: [SQLValue] = [.text(id)]
                    try database.execute(
                        "INSERT OR IGNORE INTO search_unindexed(item) SELECT id FROM items WHERE id=? AND \(hasNUL("search"))", item)
                    try database.execute("INSERT INTO search_docs(item) SELECT id FROM items WHERE id=? AND NOT \(hasNUL("search"))", item)
                    try database.execute(
                        "INSERT INTO search_trigram(rowid,search) SELECT d.doc,i.search FROM search_docs d JOIN items i ON i.id=d.item WHERE d.item=?",
                        item)
                    cursor = position
                    bytes +=
                        try database.rows("SELECT length(CAST(search AS BLOB)) AS bytes FROM items WHERE id=?", item).first?["bytes"]?
                        .number ?? 0
                    if bytes >= stepBytes { break }
                }
                return false
            }
            if finished {
                status.markComplete()
                return true
            }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        return false
    }

    private static func removeLegacyTable(_ database: LibraryDatabase, status: Status, pause: TimeInterval, remaining: inout Int) throws {
        guard try hasLegacyTable(database) else { return }
        // Its stored copies of the text go first, a bounded amount at a time.
        while !status.isCancelled, remaining > 0 {
            remaining -= 1
            let emptied = try database.transaction { () -> Bool in
                let rows = try database.rows("SELECT id FROM search_fts_content ORDER BY id LIMIT \(stepRows)")
                guard !rows.isEmpty else { return true }
                var bytes: Int64 = 0
                for row in rows {
                    guard let id = row["id"]?.number else { throw LibraryDatabase.Failure(code: SQLITE_CORRUPT) }
                    let size = try database.rows(
                        "SELECT length(CAST(c1 AS BLOB)) AS bytes FROM search_fts_content WHERE id=?", [.integer(id)])
                    try database.execute("DELETE FROM search_fts WHERE rowid=?", [.integer(id)])
                    bytes += size.first?["bytes"]?.number ?? 0
                    if bytes >= stepBytes { break }
                }
                return false
            }
            if emptied { break }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        guard !status.isCancelled, remaining > 0 else { return }
        // What remains is the word index. Dropping it overwrites its pages in
        // one transaction, so a very large one is left for the next purge to
        // keep clean rather than holding the write lock for seconds.
        let remaining = try database.rows("SELECT count(*) AS n FROM search_fts_data").first?["n"]?.number ?? 0
        if remaining <= maximumDroppedIndexRows { try database.execute("DROP TABLE search_fts") }
    }
}
