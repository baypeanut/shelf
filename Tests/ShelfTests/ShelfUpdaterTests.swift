import XCTest
@testable import Shelf

final class ShelfUpdaterTests: XCTestCase {
    func testOnlyThePinnedHTTPSChannelAndSignedContentAreAccepted() {
        let info: [String: Any] = ["SUFeedURL": ShelfUpdateTrust.feed, "SUPublicEDKey": Data(repeating: 3, count: 32).base64EncodedString(), "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true]
        XCTAssertTrue(ShelfUpdateTrust.valid(info))
        for (key, value): (String, Any) in [("SUFeedURL", "http://github.com/feed"), ("SUFeedURL", "https://example.com/feed"), ("SUPublicEDKey", "invalid"), ("SURequireSignedFeed", false), ("SUVerifyUpdateBeforeExtraction", false)] {
            var changed = info; changed[key] = value
            XCTAssertFalse(ShelfUpdateTrust.valid(changed))
        }
        XCTAssertFalse(ShelfUpdateTrust.valid([:]))
    }

    func testActiveWorkPostponesRestartAndResumesOnlyOnce() async {
        await MainActor.run {
            let updater = ShelfUpdater()
            var busy = true, count = 0
            updater.isBusy = { busy }
            XCTAssertTrue(updater.postponeIfBusy { count += 1 })
            updater.resumeIfIdle()
            XCTAssertEqual(count, 0)
            XCTAssertTrue(updater.waitingForWork)
            busy = false
            updater.resumeIfIdle(); updater.resumeIfIdle()
            XCTAssertEqual(count, 1)
            XCTAssertFalse(updater.waitingForWork)
        }
    }

    func testCancelledSessionCannotRestartLater() async {
        await MainActor.run {
            let updater = ShelfUpdater()
            var busy = true, count = 0
            updater.isBusy = { busy }
            XCTAssertTrue(updater.postponeIfBusy { count += 1 })
            updater.finishWaiting(); busy = false; updater.resumeIfIdle()
            XCTAssertEqual(count, 0)
            XCTAssertFalse(updater.postponeIfBusy { count += 1 })
            XCTAssertEqual(count, 0)
        }
    }
}
