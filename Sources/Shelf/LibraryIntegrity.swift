import Foundation

/// The outcome of an integrity check that runs on another thread while the
/// library is already open for reading. The main thread waits on it only if
/// something is about to be written before the check has finished.
final class LibraryIntegrityCheck: @unchecked Sendable {
    private let condition = NSCondition()
    private var outcome: Bool?

    var result: Bool? {
        condition.lock()
        defer { condition.unlock() }
        return outcome
    }

    func finish(_ passed: Bool) {
        condition.lock()
        outcome = passed
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult func wait() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while outcome == nil { condition.wait() }
        return outcome ?? false
    }
}
