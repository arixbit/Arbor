import AppKit
import SwiftUI

extension ContentView {

    /// Menu/settings entry point. Manual checks always report their result
    /// through the feedback surface so the user knows the check ran.
    func performManualUpdateCheck() {
        AppUpdateChecker.shared.checkNow { outcome in
            presentUpdateOutcome(outcome, silentOnFailure: false)
        }
    }

    /// One automatic check per 24h per install, delayed so startup work (root
    /// discovery, first status snapshot) is never competing with it. Failures
    /// stay silent: a background check must not nag the user about network
    /// conditions. Suppressed entirely under XCTest hosts.
    func scheduleAutomaticUpdateCheck() {
        guard !AppUpdateChecker.isRunningUnderTestHost else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            AppUpdateChecker.shared.autoCheckIfNeeded { outcome in
                presentUpdateOutcome(outcome, silentOnFailure: true)
            }
        }
    }

    private func presentUpdateOutcome(
        _ outcome: AppUpdateCheckOutcome,
        silentOnFailure: Bool
    ) {
        switch outcome {
        case .skipped:
            break
        case .updateAvailable(let info, let current):
            feedbackCenter.warning(
                "发现新版本 \(info.version)",
                detail: "当前版本 \(current)。打开 Releases 页面下载新的 DMG 或 ZIP。",
                actionTitle: "打开下载页",
                action: { NSWorkspace.shared.open(info.releaseURL) },
                notificationID: "app.update.available.\(info.version)",
                localized: false
            )
        case .upToDate(let current):
            guard !silentOnFailure else { return }
            feedbackCenter.success(
                "已是最新版本",
                detail: "当前版本 \(current)。",
                localized: false
            )
        case .failed(let reason):
            guard !silentOnFailure else { return }
            feedbackCenter.error(
                "检查更新失败",
                detail: reason,
                nextStep: "稍后重试，或直接打开 Releases 页面下载。",
                actionTitle: "打开下载页",
                action: { NSWorkspace.shared.open(AppUpdateChecker.releasesPage) },
                localized: false
            )
        }
    }
}
