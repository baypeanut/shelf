import AppKit
import Combine
import SwiftUI
#if canImport(Sparkle) && !SHELF_WITHOUT_UPDATES
import Sparkle
#endif

/// Trust comes only from the signed application bundle, never from a remote feed.
enum ShelfUpdateTrust {
    static let feed = "https://github.com/baypeanut/shelf/releases/latest/download/appcast.xml"
    static func valid(_ info: [String: Any]) -> Bool {
        guard info["SUFeedURL"] as? String == feed,
              let encoded = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: encoded)?.count == 32 else { return false }
        return info["SURequireSignedFeed"] as? Bool == true && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true
    }
}

@MainActor
final class ShelfUpdater: NSObject, ObservableObject {
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isConfigured = false
    @Published private(set) var waitingForWork = false
    var isBusy: () -> Bool = { false }
    private var pendingInstall: (() -> Void)?
    private var resumeTimer: Timer?
    #if canImport(Sparkle) && !SHELF_WITHOUT_UPDATES
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    #endif

    func start() {
        #if canImport(Sparkle) && !SHELF_WITHOUT_UPDATES
        guard controller == nil, ShelfUpdateTrust.valid(Bundle.main.infoDictionary ?? [:]) else { return }
        let candidate = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        do {
            try candidate.updater.start()
            controller = candidate
            isConfigured = true
            observations = [
                candidate.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                    Task { @MainActor in self?.canCheck = change.newValue ?? false }
                },
                candidate.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                    Task { @MainActor in self?.automaticChecks = change.newValue ?? false }
                },
                candidate.updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                    Task { @MainActor in self?.lastChecked = updater.lastUpdateCheckDate }
                }
            ]
        } catch { errorMessage = error.localizedDescription }
        #endif
    }

    func check() {
        #if canImport(Sparkle) && !SHELF_WITHOUT_UPDATES
        guard canCheck, !isBusy(), !waitingForWork else { return }
        errorMessage = nil
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if canImport(Sparkle) && !SHELF_WITHOUT_UPDATES
        controller?.updater.automaticallyChecksForUpdates = enabled
        #endif
    }

    func postponeIfBusy(_ install: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingInstall = install
        waitingForWork = true
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resumeIfIdle() }
        }
        return true
    }

    func resumeIfIdle() {
        guard !isBusy(), let install = pendingInstall else { return }
        finishWaiting()
        install()
    }

    func finishWaiting() {
        resumeTimer?.invalidate(); resumeTimer = nil
        pendingInstall = nil; waitingForWork = false
    }
}

#if canImport(Sparkle) && !SHELF_WITHOUT_UPDATES
extension ShelfUpdater: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }
    func standardUserDriverWillFinishUpdateSession() { availableVersion = nil; finishWaiting() }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { availableVersion = item.displayVersionString; errorMessage = nil }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { availableVersion = nil; errorMessage = nil }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let value = error as NSError
        guard value.domain != SUSparkleErrorDomain || value.code != Int(SUError.noUpdateError.rawValue) else { return }
        finishWaiting(); errorMessage = error.localizedDescription
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeIfBusy(installHandler)
    }
}
#endif

struct ShelfUpdateSettings: View {
    @ObservedObject var updater: ShelfUpdater
    var body: some View {
        if updater.isConfigured {
            Toggle(L("Check for updates automatically"), isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
            Text(L("Shelf checks hourly. You choose when to download and install.")).foregroundStyle(.secondary)
            if let version = updater.availableVersion {
                Label(String(format: L("Version %@ is available"), version), systemImage: "arrow.down.circle")
            }
            Button(updater.availableVersion == nil ? L("Check for Updates…") : L("Update Shelf…")) { updater.check() }
                .disabled(!updater.canCheck || updater.isBusy() || updater.waitingForWork)
            if updater.waitingForWork { Text(L("Waiting for the current task before restarting.")).foregroundStyle(.secondary) }
            if let date = updater.lastChecked { Text(date, style: .relative).foregroundStyle(.secondary).accessibilityLabel(L("Last update check")) }
            if let error = updater.errorMessage { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
        } else {
            Text(L("This build is updated manually."))
        }
        Link(L("View releases"), destination: AppDelegate.updatesURL)
    }
}
