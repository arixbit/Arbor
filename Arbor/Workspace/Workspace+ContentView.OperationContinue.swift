import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// OPS-001 恢复动作：根据 operation_state() 的类别分派
/// continue/skip/abort（引擎层已按 origin 分派到引擎实现或系统 git）。
func doOperationContinue() {
    if stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress {
        finishStashConflict()
        return
    }
    guard let repo, let state = operationRecovery.operation else { return }
    let rebaseRootPath = repo.workdir()
    let rebaseSessionID = state.kind == .rebase
        ? rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == rebaseRootPath }) == true
            ? rebaseWorkspace.multiRootSession?.id
            : nil
        : nil
    let sourceBranch = state.kind == .merge && state.origin == .engine
        ? (mergeWorkspace.pendingDeleteBranch ?? repo.mergeSourceReference())
        : nil
    let protectedPatterns = effectiveProtectedBranchPatterns
    let pendingPullStash = stashRecovery.pendingPullStashPop
    let pendingPullStashIDValue = stashRecovery.pendingPullStashID
    let pendingPullStashMessageValue = stashRecovery.pendingPullStashMessage
    let pendingPullShelfNameValue = stashRecovery.pendingPullShelfName
    let singleRootRebaseSeed = state.kind == .rebase && rebaseSessionID == nil
        ? rebaseWorkspace.undoSeed
        : nil
    let completedLogApplyRecovery = rebaseRootPath.flatMap { rootPath -> PersistedLogApplyRecovery? in
        guard let recovery = loadLogApplyRecovery(repositoryPath: rootPath) else { return nil }
        switch state.kind {
        case .cherryPick:
            return recovery.operation == .cherryPick ? recovery : nil
        case .revert:
            return recovery.operation == .revert ? recovery : nil
        case .merge, .rebase:
            return nil
        }
    }
    let operationNotificationID = rebaseRootPath.map {
        operationRecoveryNotificationID(rootPath: $0)
    }
    beginFeedbackOperation(
        "Continue operation",
        notificationID: operationNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            switch state.kind {
            case .merge:
                _ = try state.origin == .engine
                    ? repo.finishMerge(message: nil)
                    : repo.mergeContinue(message: nil)
            case .rebase:
                _ = try repo.rebaseContinue()
            case .cherryPick:
                try repo.cherryPickContinueWithOptions(
                    emptyPolicy: configuredCherryPickEmptyPolicy()
                )
            case .revert:
                try repo.revertContinue()
            }
            let continuationState = try repo.operationState()
            let operationStillActive = continuationState != nil
            if !operationStillActive, let rootPath = rebaseRootPath {
                clearLogApplyRecovery(repositoryPath: rootPath)
            }
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
            var pullStashRestoreConflictPaths: [String]?
            var pullStashRestoreIndex: Int?
            var pullStashRestoreConflictID: String?
            var pullShelfRestoreConflictName: String?
            var pullShelfRestoreConflictPaths: [String]?
            var pullRestoreError: String?
            var pullRestoreStashID: String?
            var pullRestoreShelfName: String?
            var pullChangesRestored = false
            if !operationStillActive {
                if let pendingPullShelfNameValue {
                    pullRestoreShelfName = pendingPullShelfNameValue
                    do {
                        try repo.shelvePopPreservation(name: pendingPullShelfNameValue)
                        pullChangesRestored = true
                    } catch let error as EngineError {
                        if case let .ShelveApplyConflict(name, paths) = error {
                            pullShelfRestoreConflictName = name
                            pullShelfRestoreConflictPaths = paths
                        } else {
                            pullRestoreError = errorMessage(error)
                        }
                    } catch {
                        pullRestoreError = errorMessage(error)
                    }
                } else if pendingPullStash {
                    do {
                        let reference = try Self.pullStashReference(
                            repo: repo,
                            stashID: pendingPullStashIDValue,
                            message: pendingPullStashMessageValue
                        )
                        pullRestoreStashID = reference.stash.id
                        pullStashRestoreIndex = Int(reference.index)
                        try repo.stashPopWithIndex(
                            index: try currentStashIndex(repo: repo, stashID: reference.stash.id),
                            restoreIndex: true
                        )
                        pullChangesRestored = true
                    } catch let error as EngineError {
                        if case let .StashApplyConflict(paths, conflictID) = error {
                            pullStashRestoreConflictPaths = paths
                            pullStashRestoreConflictID = conflictID ?? pullRestoreStashID
                        } else {
                            pullRestoreError = errorMessage(error)
                        }
                    } catch {
                        pullRestoreError = errorMessage(error)
                    }
                }
            }
            let pullRestoreBlocked = pullStashRestoreConflictPaths != nil
                || pullShelfRestoreConflictPaths != nil
                || pullRestoreError != nil
            let canProposeDelete = (
                !operationStillActive && (sourceBranch.map {
                    canProposeDeleteMergedBranch(
                        repo: repo,
                        branch: $0,
                        protectedPatterns: protectedPatterns
                    )
                } ?? false)
            ) && !pullRestoreBlocked
            let pullStashRestoreConflictPathsValue = pullStashRestoreConflictPaths
            let pullStashRestoreIndexValue = pullStashRestoreIndex
            let pullStashRestoreConflictIDValue = pullStashRestoreConflictID
            let pullShelfRestoreConflictNameValue = pullShelfRestoreConflictName
            let pullShelfRestoreConflictPathsValue = pullShelfRestoreConflictPaths
            let pullRestoreErrorValue = pullRestoreError
            let pullRestoreStashIDValue = pullRestoreStashID
            let pullRestoreShelfNameValue = pullRestoreShelfName
            let pullChangesRestoredValue = pullChangesRestored
            await MainActor.run {
                self.operationRecovery.feedback = "已继续"
                if let pullStashRestoreConflictPathsValue {
                    self.showStashRestoreConflict(
                        pullStashRestoreConflictPathsValue,
                        operationName: "Pull",
                        notificationID: operationNotificationID,
                        stashID: pullStashRestoreConflictIDValue ?? pullRestoreStashIDValue
                    )
                    self.stashRecovery.pendingPopIndex = pullStashRestoreIndexValue
                    self.stashRecovery.pendingPullStashPop = false
                    self.stashRecovery.pendingPullStashID = nil
                    self.stashRecovery.pendingPullStashMessage = nil
                } else if let pullShelfRestoreConflictNameValue,
                          let pullShelfRestoreConflictPathsValue
                {
                    self.stashRecovery.pendingPullShelfName = nil
                    self.presentShelveConflict(
                        name: pullShelfRestoreConflictNameValue,
                        paths: pullShelfRestoreConflictPathsValue,
                        isPop: true,
                        notificationID: operationNotificationID
                    )
                } else if pullChangesRestoredValue {
                    self.stashRecovery.pendingPullStashPop = false
                    self.stashRecovery.pendingPullStashID = nil
                    self.stashRecovery.pendingPullStashMessage = nil
                    self.stashRecovery.pendingPullShelfName = nil
                    if let rebaseRootPath {
                        clearPendingPullPreservation(repositoryPath: rebaseRootPath)
                    }
                }
                if let pullRestoreErrorValue {
                    let savedChangesAction: FeedbackAction? = {
                        if let pullRestoreShelfNameValue {
                            return self.savedChangesFeedbackAction(
                                kind: .shelf,
                                identifier: pullRestoreShelfNameValue
                            )
                        }
                        if let pullRestoreStashIDValue {
                            return self.savedChangesFeedbackAction(
                                kind: .stash,
                                identifier: pullRestoreStashIDValue
                            )
                        }
                        return nil
                    }()
                    self.feedbackCenter.error(
                        "Pull local changes restore failed",
                        detail: pullRestoreErrorValue,
                        nextStep: "View the saved changes, resolve the local issue, then retry the restore.",
                        additionalActions: savedChangesAction.map { [$0] } ?? [],
                        notificationID: operationNotificationID
                    )
                } else if pullRestoreBlocked {
                    self.feedbackCenter.warning(
                        "Pull local changes restore paused",
                        detail: "Resolve the restored local changes, then complete the restore.",
                        notificationID: operationNotificationID
                    )
                }
                if state.kind == .merge {
                    self.mergeWorkspace.pendingDeleteBranch = nil
                }
                if state.kind == .rebase, rebaseSessionID == nil {
                    if operationStillActive {
                        self.rebaseWorkspace.paused = true
                        self.rebaseWorkspace.pauseReason = continuationState?.conflictedFiles.isEmpty == false
                            ? .conflict
                            : .edit
                        self.rebaseWorkspace.conflicts = continuationState?.conflictedFiles ?? []
                        self.rebaseWorkspace.undoSeed = singleRootRebaseSeed
                        self.rebaseWorkspace.undoTarget = nil
                        if let singleRootRebaseSeed {
                            saveRebaseUndoSeed(singleRootRebaseSeed)
                        }
                    } else if !pullRestoreBlocked {
                        self.rebaseWorkspace.paused = false
                        self.rebaseWorkspace.pauseReason = nil
                        self.rebaseWorkspace.conflicts = []
                        self.rebaseWorkspace.undoSeed = nil
                        self.rebaseWorkspace.undoTarget = completedRebaseUndoTarget
                        if let singleRootRebaseSeed {
                            clearRebaseUndoSeed(repositoryPath: singleRootRebaseSeed.repositoryPath)
                        }
                    } else {
                        // The Git rebase has completed; only the saved local
                        // scene remains unresolved. Keep its seed for a
                        // later expected-HEAD Undo, but do not leave the
                        // operation bar pretending that Git is still paused.
                        self.rebaseWorkspace.paused = false
                        self.rebaseWorkspace.pauseReason = nil
                        self.rebaseWorkspace.conflicts = []
                        self.rebaseWorkspace.undoSeed = singleRootRebaseSeed
                        self.rebaseWorkspace.undoTarget = nil
                        if let singleRootRebaseSeed {
                            saveRebaseUndoSeed(singleRootRebaseSeed)
                        }
                    }
                }
                self.refreshAll(showFeedback: false)
                if state.kind == .rebase,
                   let rebaseRootPath,
                   let rebaseSessionID,
                   !pullRestoreBlocked {
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rebaseRootPath,
                        action: .continueOperation,
                        operationStillActive: operationStillActive,
                        sessionID: rebaseSessionID
                    )
                    return
                }
                if canProposeDelete, let sourceBranch {
                    self.feedbackCenter.success(
                        "Merge completed",
                        detail: sourceBranch,
                        actionTitle: "Delete branch",
                        action: postMergeDeleteAction(repo: repo, branch: sourceBranch),
                        notificationID: operationNotificationID
                    )
                } else if state.kind == .rebase,
                          rebaseSessionID == nil,
                          operationStillActive,
                          !pullRestoreBlocked
                {
                    self.feedbackCenter.warning(
                        "Rebase paused",
                        detail: continuationState?.conflictedFiles.isEmpty == false
                            ? "Resolve the remaining conflicts before continuing."
                            : "The rebase is paused at an edit step.",
                        nextStep: "Continue or abort the rebase from the recovery bar.",
                        notificationID: operationNotificationID
                    )
                } else if state.kind == .rebase,
                          rebaseSessionID == nil,
                          let completedRebaseUndoTarget,
                          !pullRestoreBlocked
                {
                    self.feedbackCenter.success(
                        "Rebase completed",
                        detail: String(completedRebaseUndoTarget.expectedHead.prefix(7)),
                        additionalActions: [self.rebaseUndoFeedbackAction(for: completedRebaseUndoTarget)],
                        notificationID: rebaseUndoNotificationID(
                            repositoryPath: completedRebaseUndoTarget.repositoryPath
                        ),
                        notificationGroup: .standard
                    )
                } else if !pullRestoreBlocked {
                    let detail = pullChangesRestoredValue
                        ? "The Git operation is no longer paused; local changes were restored."
                        : "The Git operation is no longer paused."
                    self.feedbackCenter.success(
                        "Operation continued",
                        detail: detail,
                        notificationID: operationNotificationID
                    )
                    if !operationStillActive,
                       let completedLogApplyRecovery {
                        self.retryNextLogApplyRoot(after: completedLogApplyRecovery)
                    }
                }
            }
        } catch {
            let latestState = try? repo.operationState()
            let latestRootPath = repo.workdir()
            await MainActor.run {
                self.operationRecovery.feedback = friendlyRemoteError(error)
                // A failed recovery command can leave Git at a different
                // paused step (or with a different conflict set). Read the
                // state synchronously before publishing actions; refresh the
                // visible UI as well, so neither surface keeps a stale
                // pre-command snapshot.
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
                        "Continue failed",
                        detail: errorMessage(error),
                        nextStep: "解决剩余冲突后重试，或选择 Abort。",
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
