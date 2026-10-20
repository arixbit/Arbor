import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func doOperationSkip() {
    guard let repo, let state = operationRecovery.operation, state.kind == .rebase else { return }
    let rebaseRootPath = repo.workdir()
    let rebaseSessionID = rebaseRootPath.flatMap { rootPath in
        rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == rootPath }) == true
            ? rebaseWorkspace.multiRootSession?.id
            : nil
    }
    let singleRootRebaseSeed = rebaseSessionID == nil ? rebaseWorkspace.undoSeed : nil
    let operationNotificationID = rebaseRootPath.map {
        operationRecoveryNotificationID(rootPath: $0)
    }
    beginFeedbackOperation(
        "Skip rebase step",
        notificationID: operationNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            let outcome = try repo.rebaseSkip()
            let continuationState = try repo.operationState()
            let operationStillActive = continuationState != nil
            let completedRebaseUndoTarget: RebaseUndoTarget?
            if !operationStillActive, let singleRootRebaseSeed {
                let finalHead = try? repo.revisionCommitId(revision: singleRootRebaseSeed.branch)
                let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
                completedRebaseUndoTarget = rebaseUndoTargetAfterCompletion(
                    seed: singleRootRebaseSeed,
                    currentBranch: currentBranch,
                    finalHead: finalHead
                )
            } else {
                completedRebaseUndoTarget = nil
            }
            await MainActor.run {
                self.operationRecovery.feedback = outcome.paused ? "已跳过当前步，rebase 继续暂停" : "已跳过，rebase 完成"
                if operationStillActive {
                    self.rebaseWorkspace.undoSeed = singleRootRebaseSeed
                    self.rebaseWorkspace.undoTarget = nil
                    if let singleRootRebaseSeed {
                        saveRebaseUndoSeed(singleRootRebaseSeed)
                    }
                } else {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = completedRebaseUndoTarget
                    if let singleRootRebaseSeed {
                        clearRebaseUndoSeed(repositoryPath: singleRootRebaseSeed.repositoryPath)
                    }
                }
                self.refreshAll(showFeedback: false)
                if let rebaseRootPath,
                   let rebaseSessionID {
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rebaseRootPath,
                        action: .skip,
                        operationStillActive: operationStillActive,
                        sessionID: rebaseSessionID
                    )
                    return
                }
                    if let completedRebaseUndoTarget, !operationStillActive {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: self.operationRecovery.feedback,
                            additionalActions: [self.rebaseUndoFeedbackAction(for: completedRebaseUndoTarget)],
                            notificationID: rebaseUndoNotificationID(
                                repositoryPath: completedRebaseUndoTarget.repositoryPath
                            ),
                            notificationGroup: .standard
                        )
                } else {
                    self.feedbackCenter.success(
                        outcome.paused ? "Rebase step skipped" : "Rebase completed",
                        detail: self.operationRecovery.feedback,
                        notificationID: operationNotificationID
                    )
                }
            }
        } catch {
            let latestState = try? repo.operationState()
            let latestRootPath = repo.workdir()
            await MainActor.run {
                self.operationRecovery.feedback = friendlyRemoteError(error)
                // Re-read the native rebase state before exposing another
                // Skip/Continue/Abort action after a failed command.
                self.refreshAll(showFeedback: false)
                let recoveryRootPath = latestRootPath ?? rebaseRootPath
                let recoveryActions: [FeedbackAction]
                if let latestState, let recoveryRootPath {
                    recoveryActions = self.operationRecoveryFeedbackActions(
                        state: latestState,
                        rootPath: recoveryRootPath
                    )
                } else {
                    recoveryActions = []
                }
                self.feedbackCenter.error(
                    "Skip failed",
                    detail: errorMessage(error),
                    nextStep: "可改为 Continue 或 Abort。",
                    additionalActions: recoveryActions + (self.pendingSavedChangesFeedbackAction(
                        repo: repo,
                        rootPath: latestRootPath ?? rebaseRootPath
                    ).map { [$0] } ?? []),
                    notificationID: recoveryRootPath.map {
                        operationRecoveryNotificationID(rootPath: $0)
                    }
                )
            }
        }
    }
}

func doOperationAbort() {
    guard let repo, let state = operationRecovery.operation else { return }
    let repositoryName = repo.workdir()
        .map { URL(fileURLWithPath: $0).lastPathComponent }
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? "repository"
    let confirmation = operationAbortConfirmation(
        for: state.kind,
        repositoryName: repositoryName
    )
    let alert = NSAlert()
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmation.confirmTitle)
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let rebaseRootPath = repo.workdir()
    let rebaseSessionID = state.kind == .rebase
        ? rebaseRootPath.flatMap { rootPath in
            rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == rootPath }) == true
                ? rebaseWorkspace.multiRootSession?.id
                : nil
        }
        : nil
    let singleRootRebaseSeed = state.kind == .rebase && rebaseSessionID == nil
        ? rebaseWorkspace.undoSeed
        : nil
    let operationNotificationID = rebaseRootPath.map {
        operationRecoveryNotificationID(rootPath: $0)
    }
    let activeLogApplyRecovery = rebaseRootPath.flatMap { rootPath -> PersistedLogApplyRecovery? in
        guard let recovery = loadLogApplyRecovery(repositoryPath: rootPath) else {
            return nil
        }
        switch state.kind {
        case .cherryPick:
            return recovery.operation == .cherryPick ? recovery : nil
        case .revert:
            return recovery.operation == .revert ? recovery : nil
        case .merge, .rebase:
            return nil
        }
    }
    let logApplyRecoveriesToCancel = activeLogApplyRecovery.map {
        logApplyRecoveryCancellationTargets(
            current: $0,
            pending: pendingLogApplyRecoveries(sessionID: $0.sessionID)
        )
    } ?? []
    beginFeedbackOperation(
        "Abort operation",
        notificationID: operationNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            switch state.kind {
            case .merge:
                try repo.mergeAbort()
            case .rebase:
                try repo.rebaseAbort()
            case .cherryPick:
                try repo.cherryPickAbort()
            case .revert:
                try repo.revertAbort()
            }
            let operationStillActive = try repo.operationState() != nil
            await MainActor.run {
                self.operationRecovery.feedback = "已中止"
                if !operationStillActive {
                    for recovery in logApplyRecoveriesToCancel {
                        clearLogApplyRecovery(repositoryPath: recovery.rootPath)
                        self.logSelectionState.applyRecoveryNotificationFingerprints.removeValue(
                            forKey: operationRecoveryNotificationRootKey(recovery.rootPath)
                        )
                        self.feedbackCenter.expire(
                            notificationID: self.logApplyRecoveryNotificationID(
                                rootPath: recovery.rootPath
                            )
                        )
                    }
                }
                if state.kind == .merge {
                    self.mergeWorkspace.pendingDeleteBranch = nil
                    self.mergeWorkspace.initialHead = nil
                }
                if state.kind == .rebase, rebaseSessionID == nil {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = nil
                    if let singleRootRebaseSeed {
                        clearRebaseUndoSeed(repositoryPath: singleRootRebaseSeed.repositoryPath)
                    } else if let rebaseRootPath {
                        clearRebaseUndoSeed(repositoryPath: rebaseRootPath)
                    }
                }
                if state.kind == .rebase,
                   let rebaseRootPath,
                   let rebaseSessionID {
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rebaseRootPath,
                        action: .abort,
                        operationStillActive: operationStillActive,
                        sessionID: rebaseSessionID
                    )
                    self.refreshAll(showFeedback: false)
                    return
                }
                self.refreshAll(showFeedback: false)
                self.feedbackCenter.success(
                    "Operation aborted",
                    detail: "The repository was restored to its pre-operation state.",
                    notificationID: operationNotificationID
                )
            }
        } catch {
            let latestState = try? repo.operationState()
            let latestRootPath = repo.workdir()
            await MainActor.run {
                self.operationRecovery.feedback = friendlyRemoteError(error)
                // Abort failures must retain the current Git operation and
                // its latest conflicts, not the snapshot captured at click
                // time. This keeps Retry/Continue/Abort root-qualified.
                self.refreshAll(showFeedback: false)
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: state.kind == .cherryPick ? "Cherry-pick" : "Revert",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? [],
                        notificationID: operationNotificationID,
                        stashID: stashID
                    )
                } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? [],
                        notificationID: operationNotificationID
                    )
                } else {
                    let recoveryRootPath = latestRootPath ?? rebaseRootPath
                    let recoveryActions: [FeedbackAction]
                    if let latestState, let recoveryRootPath {
                        recoveryActions = self.operationRecoveryFeedbackActions(
                            state: latestState,
                            rootPath: recoveryRootPath
                        )
                    } else {
                        recoveryActions = []
                    }
                    self.feedbackCenter.error(
                        "Abort failed",
                        detail: errorMessage(error),
                        nextStep: "状态已保留，可重试或选择其他动作。",
                        additionalActions: recoveryActions + (self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: latestRootPath ?? rebaseRootPath
                        ).map { [$0] } ?? []),
                        notificationID: recoveryRootPath.map {
                            operationRecoveryNotificationID(rootPath: $0)
                        }
                    )
                }
            }
        }
    }
}

}
