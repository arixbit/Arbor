import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func multiRootUpdateRollbackRequest(
    targets: [PersistedMultiRootUpdateRollbackTarget],
    kind: ArborVCSActionRequest.Kind = .rollbackMultiRootUpdate
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: kind,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootUpdateRollbackTargets: targets
    )
}

func multiRootUpdateRollbackAction(
    targets: [PersistedMultiRootUpdateRollbackTarget],
    title: String = "Rollback Updated Roots"
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = multiRootUpdateRollbackRequest(targets: targets)
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func updateRootRecoveryActions(
    _ targets: [UpdateRootRecoveryTarget]
) -> [FeedbackAction] {
    var actions: [FeedbackAction] = []
        for target in targets where target.kind == .chooseUpstream {
            guard let branch = target.branch else { continue }
            actions.append(
                FeedbackAction(title: "Choose Upstream · \(target.displayName)") {
                    self.presentUpstreamDialogInRoot(
                        rootPath: target.rootPath,
                        displayName: target.displayName,
                        branch: branch
                    )
                }
            )
        }
    if targets.contains(where: { $0.kind == .openBranches }) {
        actions.append(
            FeedbackAction(title: "Open Branches") {
                self.loadMultiRoots()
                self.branchWorkspace.showPopover = true
            }
        )
    }
    return actions
}

/// Roll back every root that advanced during one compound Update Project run.
/// Targets are expected-HEAD guarded and ordered deepest-first so a detached
/// submodule is restored before its parent gitlink. A later user change or a
/// local edit that would be overwritten leaves only that target retryable.
func rollbackMultiRootUpdate(
    _ targets: [PersistedMultiRootUpdateRollbackTarget],
    completionTitle: String = "Update Project rollback completed",
    operationTitle: String = "Rollback Update Project",
    notificationID: String? = nil,
    rollbackKind: ArborVCSActionRequest.Kind = .rollbackMultiRootUpdate
) {
    guard !targets.isEmpty else { return }
    let stableNotificationID = notificationID ?? multiRootUpdateRollbackNotificationID()
    beginFeedbackOperation(
        operationTitle,
        notificationID: stableNotificationID
    )
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [PersistedMultiRootUpdateRollbackTarget] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard try rootRepo.operationState() == nil else {
                    throw NSError(
                        domain: "Arbor.MultiRootUpdateRollback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "A Git operation is still in progress."]
                    )
                }
                try rootRepo.restoreHeadIfExpectedWithIgnoredPathsAndBranch(
                    initialCommitId: target.initialHead,
                    expectedCommitId: target.expectedHead,
                    expectedHeadBranch: target.expectedHeadBranch,
                    ignoredPaths: target.ignoredPaths
                )
            } catch {
                failures.append("\(target.displayName): \(errorMessage(error))")
                remaining.append(target)
            }
        }
        let rollbackFailures = failures
        let rollbackRemaining = remaining
        await MainActor.run {
            self.loadMultiRoots()
            if rollbackFailures.isEmpty {
                self.feedbackCenter.success(
                    completionTitle,
                    detail: "Restored \(targets.count) updated root\(targets.count == 1 ? "" : "s").",
                    notificationID: stableNotificationID
                )
            } else {
                let retryRequest = self.multiRootUpdateRollbackRequest(
                    targets: rollbackRemaining,
                    kind: rollbackKind
                )
                self.feedbackCenter.warning(
                    "\(operationTitle) partially failed",
                    detail: rollbackFailures.joined(separator: "\n"),
                    nextStep: "Review the affected roots and retry the remaining rollback targets.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Remaining Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    ],
                    notificationID: stableNotificationID,
                    notificationGroup: .standard
                )
            }
        }
    }
}

}
