import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func multiRootResetRollbackRequest(
    targets: [PersistedMultiRootResetRollbackTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootReset,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootResetRollbackTargets: targets
    )
}

/// Roll back only soft-reset roots whose expected HEAD and branch still match.
/// The engine operation is ref-only, so user edits made after the reset remain
/// untouched. Failed roots stay as retryable semantic targets.
func rollbackMultiRootReset(
    _ targets: [PersistedMultiRootResetRollbackTarget]
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Rollback multi-root soft reset")
    Task.detached(priority: .userInitiated) {
        do {
            let results = try Arbor.rollbackMultiRootReset(
                targets: targets.map { $0.makeLiveTarget() }
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.loadMultiRoots()
                let failures = results.filter { !$0.success }
                guard !failures.isEmpty else {
                    self.feedbackCenter.success(
                        "Soft reset rollback completed",
                        detail: "Restored \(results.count) root\(results.count == 1 ? "" : "s").",
                        notificationID: self.multiRootResetNotificationID(),
                        notificationGroup: .standard
                    )
                    return
                }
                let failedPaths = Set(failures.map(\.rootPath))
                let remainingTargets = targets.filter { failedPaths.contains($0.rootPath) }
                let retryRequest = self.multiRootResetRollbackRequest(targets: remainingTargets)
                self.feedbackCenter.warning(
                    "Soft reset rollback partially failed",
                    detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                    nextStep: "Review the changed roots and retry only the remaining rollback targets.",
                    additionalActions: remainingTargets.isEmpty
                        ? []
                        : [FeedbackAction(
                            title: "Retry Remaining Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }],
                    notificationID: self.multiRootResetNotificationID(),
                    notificationGroup: .standard
                )
            }
        } catch {
            await MainActor.run {
                let retryRequest = self.multiRootResetRollbackRequest(targets: targets)
                self.feedbackCenter.warning(
                    "Soft reset rollback failed",
                    detail: errorMessage(error),
                    nextStep: "Confirm the roots still have the expected HEAD, then retry the rollback action.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Soft Reset Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    ],
                    notificationID: self.multiRootResetNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

}
