import Foundation
#if canImport(Sparkle)
import Combine
#endif
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

final class PublicUpdateChannelTests: HistoryTestCase {
    @MainActor
    func testLocalReleaseRejectsAnyInjectedFeedIncludingAnExternalIdentity() {
        for bundle in ["com.baypeanut.Shelf", "local.shelf.review", "another.app"] {
            let info: [String: Any] = ["CFBundleIdentifier": bundle,
                "SUFeedURL": "https://example.invalid/appcast.xml",
                "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
                "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true]
            XCTAssertNil(PublicUpdateChannel(info: info))
            #if canImport(Sparkle)
            XCTAssertNil(SparkleUpdateDriver(info: info))
            #endif
        }
    }

    func testAutomaticChecksRequireAnExplicitShelfPreference() {
        let suite = "synthetic-public-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        XCTAssertFalse(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
        defaults.set(true, forKey: AutomaticUpdateSchedule.preferenceKey)
        XCTAssertTrue(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
    }

    @MainActor
    func testLocalUpdaterNeverTouchesCredentialsOrNetworkEvenWhenActionsAreCalled() async {
        let suite = "synthetic-disabled-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentialCalls = DisabledUpdateCalls()
        let credentials = UpdateCredentialStore(load: { credentialCalls.record(); return nil },
            save: { _ in credentialCalls.record() }, remove: { credentialCalls.record() },
            authorize: { credentialCalls.record(); return nil })
        let controller = AppUpdateController(credentials: credentials,
            fetch: { _, _, _, _ in credentialCalls.record(); return Data() }, defaults: defaults,
            startupDelay: 0.01, automaticInterval: 0.01)
        controller.setAutomaticChecksEnabled(true)
        controller.startAutomaticChecks()
        controller.manualCheck()
        controller.saveToken("synthetic-unused-token")
        controller.authorizeSavedToken()
        controller.disconnect()
        controller.refreshWhenUpdatesAreShown()
        controller.recheckAutomaticUpdatesAfterWake()
        controller.downloadAndInstall()
        try? await Task.sleep(nanoseconds: 30_000_000)
        controller.stopAutomaticChecks()
        XCTAssertFalse(controller.isConfigured)
        XCTAssertFalse(controller.usesPublicUpdates)
        XCTAssertFalse(controller.automaticChecksEnabled)
        XCTAssertEqual(credentialCalls.count, 0)
    }

#if canImport(Sparkle)
    @MainActor
    func testNativeCheckResultsReplaceBusyStatusAndCheckDateWithoutDeferredReads() {
        let suite = "synthetic-native-check-result-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = UpdateCredentialStore(load: { nil }, save: { _ in }, remove: {})
        let controller = AppUpdateController(enabled: false, credentials: credentials, defaults: defaults)
        let previousCheck = Date(timeIntervalSince1970: 1_750_000_000)
        let freshCheck = previousCheck.addingTimeInterval(120)
        let states = CurrentValueSubject<SparkleUpdateDriver.State, Never>(.init(
            status: "Checking for updates…", error: nil, availableVersion: nil,
            availableBuild: nil, busy: true, lastSuccessfulCheck: previousCheck,
            automaticChecksEnabled: true))
        controller.observeNativeState(states.eraseToAnyPublisher())
        XCTAssertTrue(controller.busy)

        states.send(.init(status: "You are up to date.", error: nil, availableVersion: nil,
            availableBuild: nil, busy: false, lastSuccessfulCheck: freshCheck,
            automaticChecksEnabled: true))
        XCTAssertEqual(controller.status, "You are up to date.")
        XCTAssertEqual(controller.lastSuccessfulCheck, freshCheck)
        XCTAssertFalse(controller.busy)

        states.send(.init(status: "Version 1.7.1 is ready to install.", error: nil,
            availableVersion: "1.7.1", availableBuild: 65, busy: false,
            lastSuccessfulCheck: freshCheck, automaticChecksEnabled: true))
        XCTAssertEqual(controller.availableVersion, "1.7.1")
        XCTAssertEqual(controller.availableBuild, 65)
        states.send(.init(status: "Update check could not be completed.", error: "Synthetic network failure",
            availableVersion: nil, availableBuild: nil, busy: false,
            lastSuccessfulCheck: freshCheck, automaticChecksEnabled: false))
        XCTAssertEqual(controller.error, "Synthetic network failure")
        XCTAssertNil(controller.availableVersion)
        XCTAssertNil(controller.availableBuild)
        XCTAssertEqual(controller.lastSuccessfulCheck, freshCheck)
        XCTAssertFalse(controller.automaticChecksEnabled)
    }

#endif
}

private final class DisabledUpdateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}
