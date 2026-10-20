import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Route a typed preserving-operation restore failure to the root-scoped
/// workbench. The apply marker identifies the exact saved artifact; the
/// conflict paths come from the failed restore when available. Pull uses the
/// same marker after a selected secondary root completes Merge/Rebase.
func presentMultiRootMergeRestoreConflict(
    rootPath: String,
    paths: [String],
    stashID: String? = nil
) {
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard let info = try rootRepo.applyLocalChangesRestoreInfo() else {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Saved local changes unavailable",
                        detail: "\(rootPath): the preservation marker is missing.",
                        nextStep: "Inspect that Git root's saved changes before continuing."
                    )
                }
                return
            }
            if info.kind == "shelf" {
                await MainActor.run {
                    self.openMultiRootConflictResolver(
                        preferredRootPath: rootPath,
                        preferredPath: paths.first
                    )
                }
            } else {
                let resolvedStashID = stashID ?? info.identifier
                guard let index = try rootRepo.stashList().firstIndex(where: {
                    $0.id == resolvedStashID
                }) else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Saved local changes unavailable",
                            detail: "\(rootPath): the temporary \(info.kind) for \(info.operation) could not be located.",
                            nextStep: "Inspect that Git root's saved changes before continuing."
                        )
                    }
                    return
                }
                await MainActor.run {
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: index,
                        stashID: resolvedStashID,
                        isPop: true,
                        paths: paths
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Saved local changes unavailable",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Open that Git root and resolve its saved local changes manually."
                )
            }
        }
    }
}

/// Rehydrate Smart Merge's per-root preservation marker after a merge result
/// reports a restore failure. The marker is authoritative; stash messages and
/// numeric positions are only used to connect the root to the existing
/// conflict workbench.
func presentMultiRootMergeRestoreConflicts(_ results: [MultiRootMergeResult]) {
    for result in results where !result.success {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                guard let info = try rootRepo.applyLocalChangesRestoreInfo(),
                      info.operation == "merge" else { return }
                let paths = try rootRepo.status()
                    .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                    .map(\.path)
                if info.kind == "shelf" {
                    await MainActor.run {
                        self.openMultiRootConflictResolver(
                            preferredRootPath: rootPath,
                            preferredPath: paths.first
                        )
                    }
                } else if let index = try rootRepo.stashList().firstIndex(where: {
                    $0.id == info.identifier
                }) {
                    await MainActor.run {
                        self.presentMultiRootStashConflict(
                            rootPath: rootPath,
                            index: index,
                            stashID: info.identifier,
                            isPop: true,
                            paths: paths
                        )
                    }
                } else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Merge local changes unavailable",
                            detail: "\(rootPath): the temporary \(info.kind) could not be located.",
                            nextStep: "Inspect that Git root's saved changes before changing its conflicted files."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Merge local changes unavailable",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Open that Git root and resolve its saved local changes manually."
                    )
                }
            }
        }
    }
}

/// Smart rollback can leave a reset preserving marker when the user's saved
/// changes conflict during restore. Reuse the project resolver immediately so
/// the failure is actionable before the next retry.
func presentMultiRootMergeRollbackRestoreConflict(
    _ targets: [MultiRootMergeRollbackTarget]
) {
    Task.detached(priority: .utility) {
        for target in targets {
            guard let rootRepo = try? openRepository(path: target.rootPath),
                  let info = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil,
                  info.operation == "reset" else {
                continue
            }
            let paths = ((try? rootRepo.status()) ?? [])
                .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                .map(\.path)
            await MainActor.run {
                self.openMultiRootConflictResolver(
                    preferredRootPath: target.rootPath,
                    preferredPath: paths.first
                )
            }
            return
        }
    }
}

func completeMultiRootResolverShelf(
    _ root: MultiRootConflictResolverRoot,
    name: String
) {
    guard case let .shelve(_, isPop) = root.kind,
          let rootRepo = operationRecovery.multiRootResolverActiveRepo else { return }
    let batchRebaseSessionID = isPop
        && rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == root.rootPath }) == true
        ? rebaseWorkspace.multiRootSession?.id
        : nil
    operationRecovery.multiRootResolverWorking = true
    operationRecovery.multiRootResolverError = nil
    Task.detached(priority: .userInitiated) {
        do {
            let conflicts = try rootRepo.status().filter {
                $0.staged == .conflicted || $0.unstaged == .conflicted
            }
            guard conflicts.isEmpty else {
                throw NSError(
                    domain: "Arbor.MultiRootShelfRestore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "仍有冲突文件未解决：\(conflicts.map(\.path).joined(separator: ", "))"]
                )
            }
            // A crash can happen after the preserving apply marker is written
            // but before the Shelf restore snapshot is created. In that
            // narrow window there is no shelveRestoreInfo yet; replay the
            // exact marked Shelf so a clean apply finalizes the marker and a
            // conflicting apply creates the normal restore snapshot.
            let pendingShelveRestore = (try? rootRepo.shelveRestoreInfo()) ?? nil
            let applyInfo = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil
            if pendingShelveRestore == nil,
               let applyInfo,
               applyInfo.kind == "shelf",
               applyInfo.identifier == name {
                try rootRepo.shelvePopPreservation(name: name)
                _ = try rootRepo.finalizeApplyLocalChangesRestore()
            } else {
                try rootRepo.shelveCompleteRestore(name: name)
            }
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = nil
                if let batchRebaseSessionID {
                    self.closeMultiRootResolver()
                    self.handleMultiRootRebaseRecovery(
                        rootPath: root.rootPath,
                        action: .continueOperation,
                        operationStillActive: false,
                        sessionID: batchRebaseSessionID
                    )
                } else {
                    self.feedbackCenter.success(
                        isPop ? "Shelf pop completed" : "Unshelve completed",
                        detail: "\(root.rootPath) · \(name)"
                    )
                    self.openMultiRootConflictResolver(preferredRootPath: root.rootPath)
                }
            }
        } catch {
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = "\(root.rootPath): \(errorMessage(error))"
                self.refreshMultiRootResolverActiveRoot()
            }
        }
    }
}

func abortMultiRootResolverShelf(
    _ root: MultiRootConflictResolverRoot,
    name: String
) {
    guard let rootRepo = operationRecovery.multiRootResolverActiveRepo else { return }
    let batchRebaseSessionID = rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == root.rootPath }) == true
        ? rebaseWorkspace.multiRootSession?.id
        : nil
    operationRecovery.multiRootResolverWorking = true
    operationRecovery.multiRootResolverError = nil
    Task.detached(priority: .userInitiated) {
        do {
            try rootRepo.shelveAbortRestore(name: name)
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = nil
                if let batchRebaseSessionID {
                    self.closeMultiRootResolver()
                    self.handleMultiRootRebaseRecovery(
                        rootPath: root.rootPath,
                        action: .continueOperation,
                        operationStillActive: false,
                        sessionID: batchRebaseSessionID
                    )
                } else {
                    self.feedbackCenter.success(
                        "Shelf restore rolled back",
                        detail: "\(root.rootPath) · \(name)"
                    )
                    self.openMultiRootConflictResolver(preferredRootPath: root.rootPath)
                }
            }
        } catch {
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = "\(root.rootPath): \(errorMessage(error))"
                self.refreshMultiRootResolverActiveRoot()
            }
        }
    }
}

func presentMultiRootUpdateRestoreConflicts(_ results: [RootOperationResult]) {
    let roots = results.filter {
        !$0.success && $0.message.localizedCaseInsensitiveContains("local restore conflicted")
    }
    for result in roots {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                let paths = try rootRepo.status().filter {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                }.map(\.path)
                let shelveRestore = (try? rootRepo.shelveRestoreInfo()) ?? nil
                let stash = try rootRepo.stashList().enumerated().first {
                    isArborUpdateStashMessage($0.element.message)
                }
                await MainActor.run {
                    if shelveRestore != nil {
                        self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                        return
                    }
                    guard !paths.isEmpty, let stash else {
                        self.feedbackCenter.error(
                            "Update local changes unavailable",
                            detail: "\(rootPath): the temporary Update Project local-change save could not be located.",
                            nextStep: "Inspect that root's stash or Shelf list before changing its conflicted files."
                        )
                        return
                    }
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: stash.offset,
                        stashID: stash.element.id,
                        isPop: true,
                        paths: paths
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Local restore conflict unavailable",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Open that Git root and resolve its conflicted files manually."
                    )
                }
            }
        }
    }
}

/// Smart Checkout and Checkout and Update can also leave a named Shelf in a
/// pending restore state. Reuse the project resolver so this remains
/// root-scoped instead of falling back to the currently selected Repository.
func presentMultiRootShelfRestoreConflicts(_ results: [RootOperationResult]) {
    for result in results where !result.success {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            guard let rootRepo = try? openRepository(path: rootPath) else { return }
            let pending = (try? rootRepo.shelveRestoreInfo()) ?? nil
            let paths = ((try? rootRepo.status()) ?? [])
                .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                .map(\.path)
            let stash = try? rootRepo.stashList().enumerated().first(where: {
                $0.element.message.hasPrefix("Arbor: Smart Checkout to")
                    || $0.element.message.hasPrefix("Arbor: Checkout and Update to")
            })
            await MainActor.run {
                if pending != nil {
                    self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                } else if let stash {
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: stash.offset,
                        stashID: stash.element.id,
                        isPop: true,
                        paths: paths
                    )
                }
            }
        }
    }
}

/// Restore temporary Update Project local changes discovered after relaunch.
///
/// A Git operation in progress must be completed or aborted first; popping
/// the stash while merge/rebase metadata is active would mix two recovery
/// flows. If the root is clean from Git's operation-state perspective, this
/// follows the same root-scoped conflict workbench used by in-session Update.
func restoreMultiRootUpdateStash(rootPath: String) {
    guard !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    beginFeedbackOperation("Restore Update Project changes")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard try rootRepo.operationState() == nil else {
                throw NSError(
                    domain: "Arbor.MultiRootRecovery",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "该 Git root 仍有进行中的操作，请先 Continue 或 Abort。"]
                )
            }
            let shelf = try rootRepo.shelveList().first(where: { isArborUpdateShelfName($0.name) })
            let stash = try rootRepo.stashList().enumerated().first(where: {
                isArborUpdateStashMessage($0.element.message)
            })
            guard shelf != nil || stash != nil else {
                throw NSError(
                    domain: "Arbor.MultiRootRecovery",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "找不到临时 Update Project stash 或 Shelf。"]
                )
            }
            do {
                if let shelf {
                    try rootRepo.shelvePopPreservation(name: shelf.name)
                } else if let stash {
                    try rootRepo.stashPopWithIndex(
                        index: try currentStashIndex(
                            repo: rootRepo,
                            stashID: stash.element.id
                        ),
                        restoreIndex: true
                    )
                }
                await MainActor.run {
                    self.loadMultiRoots()
                    self.feedbackCenter.success(
                        "Local changes restored",
                        detail: "\(rootPath): the Update Project local changes were restored after relaunch."
                    )
                }
            } catch let error as EngineError {
                if case let .StashApplyConflict(paths, conflictStashID) = error {
                    await MainActor.run {
                        self.presentMultiRootStashConflict(
                            rootPath: rootPath,
                            index: stash?.offset ?? 0,
                            stashID: conflictStashID ?? stash?.element.id,
                            isPop: true,
                            paths: paths
                        )
                    }
                } else if case .ShelveApplyConflict = error {
                    await MainActor.run {
                        self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                    }
                } else {
                    throw error
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Local changes restore failed",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Inspect the root's status and Update Project stash before retrying."
                )
            }
        }
    }
}

func showStashRestoreConflict(
    _ paths: [String],
    operationName: String = "Smart Checkout",
    additionalActions: [FeedbackAction] = [],
    notificationID: String? = nil,
    stashID: String? = nil
) {
    stashRecovery.pendingConflictNotificationID = notificationID
    stashRecovery.popConflictInProgress = true
    stashRecovery.applyConflictInProgress = false
    stashRecovery.pendingPopIndex = 0
    stashRecovery.pendingPopID = stashID
    stashRecovery.pendingPullStashPop = false
    stashRecovery.pendingPullStashID = nil
    stashRecovery.pendingPullStashMessage = nil
    mergeWorkspace.inProgress = true
    operationRecovery.initialPath = paths.first
    if projectWorkspace.toolWindowMode != .log {
        fileWorkspace.selection = paths.first
    }
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    operationRecovery.showConflictResolver = true
    mergeWorkspace.feedback = "\(operationName) 冲突：\(paths.joined(separator: ", "))"
    feedbackCenter.error(
        "\(operationName) paused",
        detail: paths.joined(separator: ", "),
        nextStep: "Resolve every file, then complete the local-change restore.",
        additionalActions: additionalActions,
        notificationID: notificationID
    )
    refreshAll(showFeedback: false)
}

}
