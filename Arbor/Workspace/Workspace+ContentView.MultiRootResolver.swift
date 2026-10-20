import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// 选择统一 resolver 中的 root，并只加载该 root 的 Repository/status。
func selectMultiRootResolverRoot(_ rootPath: String) {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: { $0.rootPath == rootPath }) else { return }
    operationRecovery.multiRootResolverActiveRootPath = rootPath
    operationRecovery.multiRootResolverActiveInitialPath = root.paths.first
    operationRecovery.multiRootResolverActiveKind = root.kind
    operationRecovery.multiRootResolverActiveRepo = nil
    operationRecovery.multiRootResolverActiveEntries = []
    operationRecovery.multiRootResolverWorking = true
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let entries = try rootRepo.status()
            await MainActor.run {
                guard self.operationRecovery.multiRootResolverActiveRootPath == rootPath else { return }
                self.operationRecovery.multiRootResolverActiveRepo = rootRepo
                self.operationRecovery.multiRootResolverActiveEntries = entries
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = nil
            }
        } catch {
            await MainActor.run {
                guard self.operationRecovery.multiRootResolverActiveRootPath == rootPath else { return }
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = "\(root.displayName): \(errorMessage(error))"
            }
        }
    }
}

func refreshMultiRootResolverActiveRoot() {
    guard let rootRepo = operationRecovery.multiRootResolverActiveRepo,
          let rootPath = operationRecovery.multiRootResolverActiveRootPath else { return }
    Task.detached(priority: .userInitiated) {
        let entries = (try? rootRepo.status()) ?? []
        await MainActor.run {
            guard self.operationRecovery.multiRootResolverActiveRootPath == rootPath,
                  self.operationRecovery.multiRootResolverActiveRepo === rootRepo else { return }
            self.operationRecovery.multiRootResolverActiveEntries = entries
        }
    }
}

func completeMultiRootResolverRoot() {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: {
        $0.rootPath == self.operationRecovery.multiRootResolverActiveRootPath
    }) else { return }
    switch root.kind {
    case .operation:
        runMultiRootResolverRecovery(rootPath: root.rootPath, action: .continueOperation)
    case .stash:
        completeMultiRootResolverStash(root)
    case .shelve(let name, _):
        completeMultiRootResolverShelf(root, name: name)
    case .workingTree:
        openMultiRootConflictResolver(preferredRootPath: root.rootPath)
    }
}

func skipMultiRootResolverRoot() {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: {
        $0.rootPath == self.operationRecovery.multiRootResolverActiveRootPath
    }), root.canSkip else { return }
    runMultiRootResolverRecovery(rootPath: root.rootPath, action: .skip)
}

func abortMultiRootResolverRoot() {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: {
        $0.rootPath == self.operationRecovery.multiRootResolverActiveRootPath
    }) else { return }
    switch root.kind {
    case .operation:
        runMultiRootResolverRecovery(rootPath: root.rootPath, action: .abort)
    case .shelve(let name, _):
        abortMultiRootResolverShelf(root, name: name)
    case .stash, .workingTree:
        break
    }
}

func closeMultiRootResolver() {
    operationRecovery.multiRootResolverLoadGeneration += 1
    operationRecovery.showMultiRootConflictResolver = false
    operationRecovery.multiRootResolverWorking = false
    operationRecovery.multiRootResolverActiveRepo = nil
    operationRecovery.multiRootResolverActiveEntries = []
    operationRecovery.multiRootResolverActiveKind = nil
}

/// 统一 resolver 中的 Continue/Skip/Abort。完成一个 root 后立即重读整个
/// root 队列，因此 rebase 的下一暂停步骤和其它 root 都会留在同一窗口。
func runMultiRootResolverRecovery(
    rootPath: String,
    action: MultiRootRecoveryAction,
    stageTrackedBeforeContinue: Bool = false
) {
    guard !operationRecovery.multiRootResolverWorking else { return }
    let restoresUpdateLocalChanges = stashRecovery.multiRootUpdateStashedRoots.contains(rootPath)
    let batchRebaseSessionID = rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == rootPath }) == true
        ? rebaseWorkspace.multiRootSession?.id
        : nil
    let protectedPatterns = effectiveProtectedBranchPatterns
    operationRecovery.multiRootResolverWorking = true
    operationRecovery.multiRootResolverError = nil
    beginFeedbackOperation("Multi-root recovery")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard let state = try rootRepo.operationState() else {
                throw NSError(
                    domain: "Arbor.MultiRootRecovery",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "该 Git root 没有可恢复的进行中操作。"]
                )
            }
            let previousHead = rootRepo.headCommitId()
            let sourceBranch = state.kind == .merge && state.origin == .engine
                ? rootRepo.mergeSourceReference()
                : nil
            let messageMonitor = Task.detached(priority: .userInitiated) {
                while !Task.isCancelled {
                    if let pending = try? rootRepo.rebasePendingMessage() {
                        await MainActor.run {
                            guard !self.rebaseWorkspace.showRawMessageEditor else { return }
                            self.rebaseWorkspace.rawMessageRepository = rootRepo
                            self.rebaseWorkspace.rawMessageText = pending
                            self.rebaseWorkspace.showRawMessageEditor = true
                        }
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { messageMonitor.cancel() }
            switch action {
            case .continueOperation:
                switch state.kind {
                case .merge:
                    _ = try state.origin == .engine
                        ? rootRepo.finishMerge(message: nil)
                        : rootRepo.mergeContinue(message: nil)
                case .rebase:
                    if stageTrackedBeforeContinue {
                        try rootRepo.stageTracked()
                    }
                    _ = try rootRepo.rebaseContinue()
                case .cherryPick:
                    try rootRepo.cherryPickContinueWithOptions(
                        emptyPolicy: configuredCherryPickEmptyPolicy()
                    )
                case .revert:
                    try rootRepo.revertContinue()
                }
            case .skip:
                guard state.kind == .rebase else {
                    throw NSError(
                        domain: "Arbor.MultiRootRecovery",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "只有 rebase 支持 Skip。"]
                    )
                }
                _ = try rootRepo.rebaseSkip()
            case .abort:
                switch state.kind {
                case .merge: try rootRepo.mergeAbort()
                case .rebase: try rootRepo.rebaseAbort()
                case .cherryPick: try rootRepo.cherryPickAbort()
                case .revert: try rootRepo.revertAbort()
                }
            }

            let operationStillActive = try rootRepo.operationState() != nil
            let currentHead = rootRepo.headCommitId()
            var stashConflictPaths: [String]?
            var stashConflictIndex: Int?
            var stashConflictID: String?
            var stashRestoreFailure: String?
            var shelfRestoreConflict = false
            if restoresUpdateLocalChanges && !operationStillActive {
                let shelves = try rootRepo.shelveList()
                if let shelf = shelves.first(where: { isArborTemporaryShelfName($0.name) }) {
                    do {
                        try rootRepo.shelvePopPreservation(name: shelf.name)
                    } catch let error as EngineError {
                        if case .ShelveApplyConflict = error {
                            shelfRestoreConflict = true
                        } else {
                            stashRestoreFailure = errorMessage(error)
                        }
                    } catch {
                        stashRestoreFailure = errorMessage(error)
                    }
                } else {
                    let stashes = try rootRepo.stashList()
                    if let indexedStash = stashes.enumerated().first(where: {
                        isArborTemporaryStashMessage($0.element.message)
                    }) {
                    do {
                        try rootRepo.stashPopWithIndex(
                            index: try currentStashIndex(
                                repo: rootRepo,
                                stashID: indexedStash.element.id
                            ),
                            restoreIndex: true
                        )
                    } catch let error as EngineError {
                        if case let .StashApplyConflict(paths, conflictStashID) = error {
                            stashConflictPaths = paths
                            stashConflictIndex = indexedStash.offset
                            stashConflictID = conflictStashID ?? indexedStash.element.id
                        } else {
                            stashRestoreFailure = errorMessage(error)
                        }
                    } catch {
                        stashRestoreFailure = errorMessage(error)
                    }
                } else {
                    stashRestoreFailure = "The temporary Update Project stash could not be located."
                }
                }
            }

            let canProposeDelete = action == .continueOperation
                && !operationStillActive
                && stashConflictPaths == nil
                && !shelfRestoreConflict
                && stashRestoreFailure == nil
                && sourceBranch.map {
                    canProposeDeleteMergedBranch(
                        repo: rootRepo,
                        branch: $0,
                        protectedPatterns: protectedPatterns
                    )
                } ?? false

            let resolvedStashConflictPaths = stashConflictPaths
            let resolvedStashConflictIndex = stashConflictIndex
            let resolvedStashConflictID = stashConflictID
            let resolvedStashRestoreFailure = stashRestoreFailure
            let resolvedShelfRestoreConflict = shelfRestoreConflict
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                if (self.rebaseWorkspace.rawMessageRepository?.workdir() ?? "") == rootPath {
                    self.rebaseWorkspace.showRawMessageEditor = false
                    self.rebaseWorkspace.rawMessageRepository = nil
                    self.rebaseWorkspace.rawMessageText = ""
                }
                if let resolvedStashConflictPaths {
                    self.stashRecovery.multiRootConflicts[rootPath] = resolvedStashConflictPaths
                    self.stashRecovery.multiRootConflictIndexes[rootPath] = resolvedStashConflictIndex ?? 0
                    self.stashRecovery.multiRootConflictIDs[rootPath] = resolvedStashConflictID
                    self.stashRecovery.multiRootConflictPopModes[rootPath] = true
                } else if resolvedStashRestoreFailure == nil
                            && !resolvedShelfRestoreConflict
                            && restoresUpdateLocalChanges {
                    self.stashRecovery.multiRootUpdateStashedRoots.remove(rootPath)
                }
                if resolvedShelfRestoreConflict {
                    self.operationRecovery.multiRootResolverError = nil
                    self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                } else if let resolvedStashRestoreFailure {
                    self.operationRecovery.multiRootResolverError = "\(rootPath): \(resolvedStashRestoreFailure)"
                } else if state.kind == .rebase, let batchRebaseSessionID {
                    self.closeMultiRootResolver()
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rootPath,
                        action: action,
                        operationStillActive: operationStillActive,
                        sessionID: batchRebaseSessionID
                    )
                    if operationStillActive {
                        self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                    }
                } else {
                    self.operationRecovery.multiRootResolverError = nil
                    let mergeViewCommitsAction = state.kind == .merge
                        && action == .continueOperation
                        ? self.completedMergeViewCommitsAction(
                            rootPath: rootPath,
                            initialHead: previousHead,
                            finalHead: currentHead,
                            completed: !operationStillActive
                        )
                        : nil
                    if canProposeDelete, let sourceBranch {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: "\(sourceBranch) · \(rootPath)",
                            actionTitle: "Delete branch",
                            action: postMergeDeleteAction(
                                repo: rootRepo,
                                branch: sourceBranch,
                                rootPath: rootPath
                            ),
                            additionalActions: mergeViewCommitsAction.map { [$0] } ?? [],
                            notificationGroup: .standard
                        )
                    } else if let mergeViewCommitsAction {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: rootPath,
                            additionalActions: [mergeViewCommitsAction],
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Git root recovery completed",
                            detail: "\(rootPath): \(multiRootRecoveryTitle(action))"
                        )
                    }
                }
                self.openMultiRootConflictResolver(preferredRootPath: rootPath)
            }
        } catch {
            let canStageAndRetry: Bool = {
                guard action == .continueOperation else { return false }
                guard batchRebaseSessionID != nil else { return false }
                guard let rootRepo = try? openRepository(path: rootPath) else { return false }
                return (try? rootRepo.status().contains {
                    $0.unstaged != .unchanged
                        && $0.unstaged != .untracked
                        && $0.unstaged != .ignored
                        && $0.unstaged != .conflicted
                }) ?? false
            }()
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.presentMultiRootMergeRestoreConflict(
                        rootPath: rootPath,
                        paths: paths,
                        stashID: stashID
                    )
                    return
                }
                if case .ShelveApplyConflict = error as? EngineError {
                    self.presentMultiRootMergeRestoreConflict(rootPath: rootPath, paths: [])
                    return
                }
                self.operationRecovery.multiRootResolverError = "\(rootPath): \(errorMessage(error))"
                let stageAndRetryAction = canStageAndRetry
                    ? batchRebaseSessionID.map {
                        self.multiRootRebaseRecoveryFeedbackAction(
                            .stageAndRetry,
                            rootPath: rootPath,
                            sessionID: $0
                        )
                    }
                    : nil
                self.feedbackCenter.error(
                    "Multi-root recovery failed",
                    detail: self.operationRecovery.multiRootResolverError,
                    nextStep: "Resolve the remaining conflicts in that root, then retry Continue, Skip, or Abort.",
                    additionalActions: stageAndRetryAction.map { [$0] } ?? [],
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.refreshMultiRootResolverActiveRoot()
            }
        }
    }
}

func executeMultiRootRecovery(
    rootPath: String,
    action: MultiRootRecoveryAction
) {
    runMultiRootResolverRecovery(rootPath: rootPath, action: action)
}

func multiRootRecoveryTitle(_ action: MultiRootRecoveryAction) -> String {
    switch action {
    case .continueOperation: return "Continue"
    case .skip: return "Skip"
    case .abort: return "Abort"
    }
}

}
