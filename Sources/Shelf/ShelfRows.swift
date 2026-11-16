import Foundation

/// One shelf's membership in the store's order, kept current by reading only
/// the rows a change names.
///
/// Loading a shelf used to mean decoding every record on it after every save.
/// A shelf's owner calls `note` for each store revision and `update` when it
/// wants its rows: a revision that names the items it touched costs one
/// query for those items, and only a revision that names nothing (folders,
/// tags, an import) or a compaction, which renumbers rows, reads the shelf
/// again.
@MainActor final class ShelfRows {
    enum Change {
        /// The item at `index` left the shelf or moved.
        case removed(Int, UUID)
        /// A record entered the shelf, or arrived from another position, at `index`.
        case inserted(Int, LibraryRecord)
        /// The record at `index` kept its place; its content may differ.
        case replaced(Int, LibraryRecord)
    }
    enum Update {
        case unchanged
        /// Every record, in order.
        case reloaded([LibraryRecord])
        /// Steps to apply, in order, to the previous rows.
        case patched([Change])
    }
    private struct Key: Equatable {
        let rank: Double, position: Int64
        func precedes(_ other: Key) -> Bool { rank > other.rank || (rank == other.rank && position > other.position) }
    }
    private let store: LibraryStore
    private let kind: LibraryKind
    private var keys = [Key]()
    private var known = [UUID: Key]()
    private var pending = Set<UUID>()
    private var stale = true
    private var generation = 0
    private var noted = Int.min
    private var dataVersion: Int64?

    init(store: LibraryStore, kind: LibraryKind) {
        self.store = store
        self.kind = kind
    }

    var count: Int { keys.count }

    /// Records what one store revision changed. Call it for every revision;
    /// hearing of the same revision twice, from two observers, is harmless.
    func note(revision: Int, ids: Set<UUID>, kinds: Set<LibraryKind>) {
        guard revision > noted else { return }
        noted = revision
        if ids.isEmpty {
            stale = true
            return
        }
        if kinds.contains(kind) { pending.formUnion(ids) } else { for id in ids where known[id] != nil { pending.insert(id) } }
    }

    /// Forget everything; the next update reads the whole shelf.
    func invalidate() { stale = true }

    func update() throws -> Update {
        if generation != store.storageGeneration { stale = true }
        if stale { return .reloaded(try reload()) }
        // Rows that are not where they are remembered to be are read again, never guessed at.
        guard let changes = pending.isEmpty ? [] : try patch() else { return .reloaded(try reload()) }
        // Another connection has committed since the last look. The image
        // indexer and the search index do that without touching a shelf, so
        // nothing is assumed; but if the shelf no longer has as many rows as
        // are held here, something else added or removed one, and it is read again.
        let version = try store.dataVersion()
        if version != dataVersion {
            dataVersion = version
            if try store.shelfCount(kind) != keys.count { return .reloaded(try reload()) }
        }
        return changes.isEmpty ? .unchanged : .patched(changes)
    }

    private func reload() throws -> [LibraryRecord] {
        stale = true
        let generation = store.storageGeneration
        let version = try store.dataVersion()
        let rows = try store.shelfRows(kind)
        keys = rows.map { Key(rank: $0.rank, position: $0.position) }
        known = Dictionary(zip(rows.map(\.record.id), keys), uniquingKeysWith: { first, _ in first })
        pending.removeAll()
        stale = false
        self.generation = generation
        dataVersion = version
        return rows.map(\.record)
    }

    private func patch() throws -> [Change]? {
        let ids = pending
        let current: [UUID: LibraryStore.ShelfRow]
        do {
            current = Dictionary(try store.shelfRows(kind, ids: ids).map { ($0.record.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            stale = true
            throw error
        }
        pending.removeAll()
        var changes = [Change]()
        // A fixed order keeps the steps reproducible.
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let old = known[id]
            let new = current[id].map { Key(rank: $0.rank, position: $0.position) }
            if let old {
                let index = index(of: old)
                guard keys.indices.contains(index), keys[index] == old else { return nil }
                if old == new, let row = current[id] {
                    changes.append(.replaced(index, row.record))
                    continue
                }
                keys.remove(at: index)
                known[id] = nil
                changes.append(.removed(index, id))
            }
            if let new, let row = current[id] {
                let index = index(of: new)
                keys.insert(new, at: index)
                known[id] = new
                changes.append(.inserted(index, row.record))
            }
        }
        return changes
    }

    enum Applied<Row> {
        case same
        case changed([Row])
        /// The rows were not the ones these steps were made for; read the shelf again.
        case outOfStep
    }
    /// Applies an update's steps to the rows an owner built from this shelf.
    static func apply<Row: Equatable>(_ changes: [Change], to rows: [Row], id: (Row) -> UUID, make: (LibraryRecord) -> Row) -> Applied<Row>
    {
        var updated = rows
        var different = false
        for change in changes {
            switch change {
            case .removed(let index, let item):
                guard updated.indices.contains(index), id(updated[index]) == item else { return .outOfStep }
                updated.remove(at: index)
                different = true
            case .inserted(let index, let record):
                guard index <= updated.count else { return .outOfStep }
                updated.insert(make(record), at: index)
                different = true
            case .replaced(let index, let record):
                guard updated.indices.contains(index), id(updated[index]) == record.id else { return .outOfStep }
                let row = make(record)
                if updated[index] != row {
                    updated[index] = row
                    different = true
                }
            }
        }
        return different ? .changed(updated) : .same
    }

    /// Where `key` is, or belongs, in descending order.
    private func index(of key: Key) -> Int {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = (low + high) / 2
            if keys[middle].precedes(key) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
