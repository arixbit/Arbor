import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func presentMultiRootStashConflict(
    rootPath: String,
    index: Int? = nil,
    stashID: String? = nil,
    isPop: Bool,
    paths: [String],
    additionalActions: [FeedbackAction] = []
) {
    guard (try? openRepository(path: rootPath)) != nil else {
        feedbackCenter.error(
            "Stash conflict unavailable",
            detail: "Could not reopen \(rootPath) to load the conflict workbench."
        )
        return
    }
    let resolvedIndex: Int = {
        guard let stashID,
              let rootRepo = try? openRepository(path: rootPath),
              let stashes = try? rootRepo.stashList(),
              let index = stashes.firstIndex(where: { $0.id == stashID }) else {
            return index ?? 0
        }
        return index
    }()
    stashRecovery.multiRootConflicts[rootPath] = paths
    stashRecovery.multiRootConflictIndexes[rootPath] = resolvedIndex
    stashRecovery.multiRootConflictIDs[rootPath] = stashID
    stashRecovery.multiRootConflictPopModes[rootPath] = isPop
    feedbackCenter.error(
        isPop ? "Stash pop paused" : "Stash apply paused",
        detail: "\(rootPath): \(paths.joined(separator: ", "))",
        nextStep: "Resolve every file in the project conflict workbench, then complete the restore.",
        additionalActions: additionalActions
    )
    openMultiRootConflictResolver(preferredRootPath: rootPath)
}

func presentMultiRootShelveConflict(
    rootPath: String,
    name: String,
    paths: [String],
    additionalActions: [FeedbackAction] = []
) {
    feedbackCenter.warning(
        "Shelve pop paused",
        detail: "\(rootPath) · \(name): \(paths.joined(separator: ", "))",
        nextStep: "Resolve every file in the project conflict workbench, then complete the Shelf restore.",
        additionalActions: additionalActions
    )
    openMultiRootConflictResolver(preferredRootPath: rootPath)
}

func openMultiRootStashConflict(rootPath: String) {
    guard stashRecovery.multiRootConflicts[rootPath] != nil else { return }
    // The unified resolver re-reads status before presenting the root.
    openMultiRootConflictResolver(preferredRootPath: rootPath)
}

/// Shelf 应用冲突进入与 merge/stash 相同的冲突工作台；区别是 shelf 没有
/// Git operation state，因此引擎会持久化应用前的 worktree/index 快照，
/// 让完成、回滚和重启后恢复都拥有明确的生命周期。
func presentShelveConflict(
    name: String,
    paths: [String],
    isPop: Bool,
    changeListName: String? = nil,
    isDirectPatch: Bool = false,
    patchText: String? = nil,
    repository: Repository? = nil,
    additionalActions: [FeedbackAction] = [],
    notificationID: String? = nil
) {
    shelfWorkspace.pendingConflictName = name
    shelfWorkspace.pendingConflictRepository = repository ?? repo
    shelfWorkspace.pendingConflictChangeList = changeListName
    let conflictNotificationID = notificationID
        ?? (isDirectPatch
            ? shelfWorkspace.pendingConflictRepository?.workdir().map(directPatchNotificationID(rootPath:))
            : nil)
    shelfWorkspace.pendingConflictNotificationID = conflictNotificationID
    shelfWorkspace.conflictIsPop = isPop
    shelfWorkspace.conflictIsDirectPatch = isDirectPatch
    shelfWorkspace.pendingConflictPatch = patchText
    shelfWorkspace.conflictInProgress = true
    operationRecovery.initialPath = paths.first
    if projectWorkspace.toolWindowMode != .log {
        fileWorkspace.selection = paths.first
    }
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    operationRecovery.showConflictResolver = true
    if let conflictRepository = shelfWorkspace.pendingConflictRepository {
        if conflictRepository === self.repo {
            refreshAll(showFeedback: false)
        } else {
            refreshShelveConflictStatus(repository: conflictRepository)
        }
    } else {
        refreshAll(showFeedback: false)
    }
    let conflictRootDetail = shelfWorkspace.pendingConflictRepository?.workdir()
        .map { " · Git root: \($0)" } ?? ""
    let conflictDetail = paths.joined(separator: ", ") + conflictRootDetail
    mergeWorkspace.feedback = if isDirectPatch {
        "Apply Patch 冲突：\(conflictDetail)"
    } else if isPop {
        "Shelve pop 冲突：\(conflictDetail)"
    } else {
        "Unshelve 冲突：\(conflictDetail)"
    }
    feedbackCenter.warning(
        isDirectPatch ? "Patch apply paused" : (isPop ? "Shelve pop paused" : "Unshelve paused"),
        detail: conflictDetail,
        nextStep: isDirectPatch
            ? "Resolve every conflicted file, then complete Apply Patch."
            : "Resolve every conflicted file, then complete the shelf operation.",
        actionTitle: "Resolve Conflicts",
        action: { self.operationRecovery.showConflictResolver = true },
        additionalActions: additionalActions,
        notificationID: conflictNotificationID
    )
}

func refreshShelveConflictStatus(repository: Repository? = nil) {
    guard let conflictRepository = repository ?? shelfWorkspace.pendingConflictRepository else { return }
    Task.detached(priority: .userInitiated) {
        let conflictEntries = (try? conflictRepository.status()) ?? []
        let conflictChangeLists = (try? conflictRepository.changelistList()) ?? []
        await MainActor.run {
            guard self.shelfWorkspace.pendingConflictRepository === conflictRepository else { return }
            self.repositoryStatus.entries = conflictEntries
            self.repositoryStatus.changeLists = conflictChangeLists
            self.fileWorkspace.refreshToken &+= 1
        }
    }
}

func clearShelveConflictState() {
    shelfWorkspace.conflictInProgress = false
    shelfWorkspace.conflictIsPop = false
    shelfWorkspace.conflictIsDirectPatch = false
    shelfWorkspace.pendingConflictName = nil
    shelfWorkspace.pendingConflictRepository = nil
    shelfWorkspace.pendingConflictChangeList = nil
    shelfWorkspace.pendingConflictPatch = nil
    shelfWorkspace.pendingConflictNotificationID = nil
    mergeWorkspace.inProgress = false
    operationRecovery.showConflictResolver = false
    operationRecovery.initialPath = nil
}

/// Conflict resolution is finalized by the engine. For Pop, the shelf is
/// removed only after the engine confirms that no conflict stages remain;
/// Unshelve keeps the shelf available for reuse.
func finishShelveConflict() {
    guard let repo = shelfWorkspace.pendingConflictRepository ?? self.repo,
          shelfWorkspace.conflictInProgress,
          let name = shelfWorkspace.pendingConflictName else { return }
    let isPop = shelfWorkspace.conflictIsPop
    let isDirectPatch = shelfWorkspace.conflictIsDirectPatch
    guard let repositoryPath = repo.workdir() else { return }
    let resolvedRootPath = canonicalExternalLogPath(repositoryPath)
    let isPrimaryRoot = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    )
    let pullRebaseSeed = rebaseWorkspace.undoSeed
    let restoreInfo = (try? repo.shelveRestoreInfo()) ?? nil
    let targetChangeList = shelfWorkspace.pendingConflictChangeList ?? restoreInfo?.targetChangeList
    let restorePaths: [String] = if let restoreInfo,
                                    !restoreInfo.appliedPaths.isEmpty
                                        || !restoreInfo.conflictPaths.isEmpty {
        Array(Set(restoreInfo.appliedPaths + restoreInfo.conflictPaths)).sorted()
    } else {
        restoreInfo?.paths ?? []
    }
    let removeApplied = restoreInfo?.removeApplied ?? false
    let deletedShelfNamesBefore = Set(
        (isPrimaryRoot ? shelfWorkspace.deletedShelves : activeDeletedShelfList).map(\.name)
    )
    let conflictNotificationID = shelfWorkspace.pendingConflictNotificationID
        ?? (isDirectPatch
            ? directPatchNotificationID(rootPath: resolvedRootPath)
            : shelfBatchNotificationID(
                operation: isPop ? .pop : .apply,
                rootPath: resolvedRootPath
            ))
    beginFeedbackOperation(
        isDirectPatch ? "Complete Apply Patch" : "Complete shelve restore",
        notificationID: conflictNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            if let targetChangeList {
                let lists = try repo.changelistList()
                guard lists.contains(where: { $0.name == targetChangeList }) else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Move changes failed",
                            detail: targetChangeList,
                            notificationID: conflictNotificationID
                        )
                    }
                    return
                }
            }
            if isDirectPatch {
                try repo.applyImportedPatchCompleteRestore(name: name)
            } else {
                try repo.shelveCompleteRestore(name: name)
            }
            let nextStatus = try repo.status()
            let nextShelves = try repo.shelveList()
            let nextDeletedShelves = (try? repo.shelveDeletedList()) ?? []
            let nextChangeLists: [ChangeListInfo]
            do {
                let currentPaths = Set(nextStatus.map(\.path))
                let assignablePaths = restorePaths.filter(currentPaths.contains)
                if let targetChangeList, !assignablePaths.isEmpty {
                    try repo.changelistMovePaths(
                        paths: assignablePaths,
                        targetName: targetChangeList
                    )
                }
                nextChangeLists = try repo.changelistList()
            } catch {
                let lists = (try? repo.changelistList()) ?? []
                await MainActor.run {
                    let isActiveRoot = shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: resolvedRootPath,
                        currentRootPath: self.activeShelfRootPath
                    )
                    if isActiveRoot {
                        if isPrimaryRoot {
                            self.repositoryStatus.entries = nextStatus
                            self.repositoryStatus.changeLists = lists
                        }
                        self.publishShelfSnapshot(
                            rootPath: resolvedRootPath,
                            shelves: nextShelves,
                            deletedShelves: nextDeletedShelves
                        )
                    }
                    self.clearShelveConflictState()
                    self.feedbackCenter.error(
                        "Move changes failed",
                        detail: targetChangeList ?? errorMessage(error),
                        notificationID: conflictNotificationID
                    )
                    self.refreshAfterShelfMutation(
                        repo: repo,
                        paths: restorePaths
                    )
                }
                return
            }
            let pullRebaseRestoreCompleted = isPrimaryRoot
                && isPop
                && pullRebaseSeed != nil
                && (try? repo.operationState()) == nil
            let completedPullRebaseUndoTarget = pullRebaseRestoreCompleted
                ? pullRebaseSeed.flatMap { seed in
                    rebaseUndoTargetAfterCompletion(
                        seed: seed,
                        currentBranch: (try? repo.branchList())?.first(where: { $0.isCurrent })?.name,
                        finalHead: try? repo.revisionCommitId(revision: seed.branch)
                    )
                }
                : nil
            await MainActor.run {
                let isActiveRoot = shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                )
                if isActiveRoot {
                    if isPrimaryRoot {
                        self.repositoryStatus.entries = nextStatus
                        self.repositoryStatus.changeLists = nextChangeLists
                    }
                    self.publishShelfSnapshot(
                        rootPath: resolvedRootPath,
                        shelves: nextShelves,
                        deletedShelves: nextDeletedShelves
                    )
                }
                self.clearShelveConflictState()
                self.refreshAfterShelfMutation(
                    repo: repo,
                    paths: restorePaths
                )
                if isActiveRoot && !isPrimaryRoot {
                    self.refreshAll(showFeedback: false)
                }
                if isPrimaryRoot && isPop {
                    clearPendingPullPreservation(repositoryPath: repositoryPath)
                }
                if pullRebaseRestoreCompleted {
                    self.finishPendingPullRebaseRestore(
                        seed: pullRebaseSeed,
                        target: completedPullRebaseUndoTarget
                    )
                }
                let restoredName = (!isPop && removeApplied)
                    ? nextDeletedShelves.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                    : nil
                if let restoredName {
                    self.feedbackCenter.success(
                        "Unshelve completed",
                        detail: targetChangeList.map { "\(name) → \($0)" } ?? name,
                        additionalActions: [self.shelfRestoreFeedbackAction(
                            name: restoredName,
                            rootPath: resolvedRootPath
                        )],
                        notificationID: conflictNotificationID
                    )
                } else if let completedPullRebaseUndoTarget {
                    self.feedbackCenter.success(
                        "Local changes restored",
                        additionalActions: [self.rebaseUndoFeedbackAction(for: completedPullRebaseUndoTarget)],
                        notificationID: rebaseUndoNotificationID(
                            repositoryPath: completedPullRebaseUndoTarget.repositoryPath
                        ),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.success(
                        isDirectPatch
                            ? "Patch applied"
                            : (isPop ? "Shelve pop completed" : "Unshelve completed"),
                        detail: isPop
                            ? nil
                            : (targetChangeList.map { "\(name) → \($0)" } ?? "Shelf kept: \(name)"),
                        notificationID: conflictNotificationID
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    isDirectPatch ? "Complete Apply Patch failed" : "Complete shelve restore failed",
                    detail: errorMessage(error),
                    nextStep: isDirectPatch
                        ? "Resolve every conflicted file, then complete Apply Patch."
                        : "Resolve every conflicted file, then complete the shelf operation.",
                    notificationID: conflictNotificationID
                )
            }
        }
    }
}

/// Roll back the exact worktree/index snapshot captured before the shelf was
/// applied. The shelf is intentionally kept for a later retry.
func abortShelveConflict() {
    guard let repo = shelfWorkspace.pendingConflictRepository ?? self.repo,
          shelfWorkspace.conflictInProgress,
          let name = shelfWorkspace.pendingConflictName else { return }
    let isDirectPatch = shelfWorkspace.conflictIsDirectPatch
    let isPop = shelfWorkspace.conflictIsPop
    guard let repositoryPath = repo.workdir() else { return }
    let resolvedRootPath = canonicalExternalLogPath(repositoryPath)
    let isPrimaryRoot = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    )
    let restorePaths = (try? repo.shelveRestoreInfo())?.paths ?? []
    let conflictNotificationID = shelfWorkspace.pendingConflictNotificationID
        ?? (isDirectPatch
            ? directPatchNotificationID(rootPath: resolvedRootPath)
            : shelfBatchNotificationID(
                operation: isPop ? .pop : .apply,
                rootPath: resolvedRootPath
            ))
    beginFeedbackOperation(
        isDirectPatch ? "Rollback Apply Patch" : "Rollback shelve restore",
        notificationID: conflictNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            try repo.shelveAbortRestore(name: name)
            let nextStatus = try repo.status()
            let nextChangeLists = (try? repo.changelistList()) ?? []
            let nextShelves = try repo.shelveList()
            let nextDeletedShelves = (try? repo.shelveDeletedList()) ?? []
            await MainActor.run {
                let isActiveRoot = shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                )
                if isActiveRoot {
                    if isPrimaryRoot {
                        self.repositoryStatus.entries = nextStatus
                        self.repositoryStatus.changeLists = nextChangeLists
                    }
                    self.publishShelfSnapshot(
                        rootPath: resolvedRootPath,
                        shelves: nextShelves,
                        deletedShelves: nextDeletedShelves
                    )
                }
                self.clearShelveConflictState()
                self.refreshAfterShelfMutation(
                    repo: repo,
                    paths: restorePaths
                )
                if isActiveRoot && !isPrimaryRoot {
                    self.refreshAll(showFeedback: false)
                }
                self.feedbackCenter.success(
                    isDirectPatch ? "Apply Patch rolled back" : "Shelve restore rolled back",
                    detail: isDirectPatch ? name : "Shelf kept: \(name)",
                    notificationID: conflictNotificationID
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    isDirectPatch ? "Rollback Apply Patch failed" : "Rollback shelve restore failed",
                    detail: errorMessage(error),
                    nextStep: isDirectPatch
                        ? "Resolve the conflict or retry Apply Patch rollback."
                        : "The shelf was kept. Resolve the conflict or retry rollback.",
                    notificationID: conflictNotificationID
                )
            }
        }
    }
}

}
