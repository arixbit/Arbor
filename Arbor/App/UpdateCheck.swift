import Combine
import Foundation
import Sparkle

/// Preserve the old opt-out once, then let Sparkle own the preference.
func appUpdateLegacyAutomaticCheckPreference(in defaults: UserDefaults) -> Bool? {
    guard defaults.object(forKey: "SUEnableAutomaticChecks") == nil else { return nil }
    return defaults.object(forKey: "arbor.autoCheckForUpdates") as? Bool
}

/// A UI test launches the app as its own process, where XCTest's own
/// environment is absent. `ARBOR_UI_TEST` marks that launch: the updater must
/// stay idle, or an update alert opens over the window under test and every
/// click in the suite lands on the alert instead.
func isUITestLaunch(environment: [String: String]) -> Bool {
    environment["ARBOR_UI_TEST"] == "1"
}

/// One updater for the entire application, including launches without a project.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true

    private let controller: SPUStandardUpdaterController
    private var started = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func start() {
        let environment = ProcessInfo.processInfo.environment
        guard !started,
              !isUITestLaunch(environment: environment),
              environment["XCTestBundlePath"] == nil,
              environment["XCTestSessionIdentifier"] == nil,
              !ArborPinentryProcess.isInvocation else { return }
        started = true
        if let enabled = appUpdateLegacyAutomaticCheckPreference(in: .standard) {
            controller.updater.automaticallyChecksForUpdates = enabled
        }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
