import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Keeps operation failures and the recovery bar on the same project-level
/// conflict entry point. The resolver rescans every Git root, so the action
/// remains valid after another root changed while the notification was open.
var operationConflictResolverAction: (() -> Void)? {
    guard let state = operationRecovery.operation,
          !state.conflictedFiles.isEmpty else { return nil }
    let preferredRootPath = projectWorkspace.path
    let preferredPath = state.conflictedFiles.first
    return {
        var userInfo: [AnyHashable: Any] = [:]
        if let preferredRootPath {
            userInfo["rootPath"] = preferredRootPath
        }
        if let preferredPath {
            userInfo["path"] = preferredPath
        }
        NotificationCenter.default.post(
            name: .arborOpenMultiRootConflictResolver,
            object: nil,
            userInfo: userInfo
        )
    }
}

func openActiveOperationConflictResolver() {
    operationConflictResolverAction?()
}

/// 打开项目级统一冲突 resolver。所有 root 的状态先在后台重新读取，
/// 然后由同一个队列视图管理当前 root；不能复用当前窗口的 `repo`。
func openMultiRootConflictResolver(
    preferredRootPath: String? = nil,
    preferredPath: String? = nil
) {
    guard let projectPath = projectWorkspace.path else { return }
    let currentRootPath = preferredRootPath ?? operationRecovery.multiRootResolverActiveRootPath
    let pendingStashPaths = stashRecovery.multiRootConflicts
    let pendingStashIndexes = stashRecovery.multiRootConflictIndexes
    let pendingStashIDs = stashRecovery.multiRootConflictIDs
    let pendingStashPopModes = stashRecovery.multiRootConflictPopModes
    operationRecovery.multiRootResolverLoadGeneration += 1
    let generation = operationRecovery.multiRootResolverLoadGeneration
    operationRecovery.multiRootResolverWorking = true
    operationRecovery.multiRootResolverError = nil
    operationRecovery.multiRootResolverActiveRepo = nil
    operationRecovery.multiRootResolverActiveEntries = []
    operationRecovery.multiRootResolverActiveKind = nil

    Task.detached(priority: .userInitiated) {
        do {
            let discovered = try discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            let pendingRoots = stableMultiRootConflictResolverRoots(
                discovered.compactMap { root -> MultiRootConflictResolverRoot? in
                guard let rootRepo = try? openRepository(path: root.path) else { return nil }
                let state = try? rootRepo.operationState()
                let statusPaths = ((try? rootRepo.status()) ?? [])
                    .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                    .map(\.path)
                    .sorted()

                if let state {
                    let paths = Array(Set(statusPaths + state.conflictedFiles)).sorted()
                    return MultiRootConflictResolverRoot(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        paths: paths,
                        kind: .operation(state.kind)
                    )
                }

                if let stashPaths = pendingStashPaths[root.path] {
                    return MultiRootConflictResolverRoot(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        paths: statusPaths.isEmpty ? stashPaths.sorted() : statusPaths,
                        kind: .stash(
                            stashID: pendingStashIDs[root.path],
                            index: pendingStashIndexes[root.path] ?? 0,
                            isPop: pendingStashPopModes[root.path] ?? false
                        )
                    )
                }

                let shelveRestore = (try? rootRepo.shelveRestoreInfo()) ?? nil
                if let shelveRestore {
                    return MultiRootConflictResolverRoot(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        paths: statusPaths.isEmpty ? shelveRestore.paths : statusPaths,
                        kind: .shelve(name: shelveRestore.name, isPop: shelveRestore.isPop)
                    )
                }

                let applyInfo = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil
                if let applyInfo, applyInfo.kind == "stash",
                   let stashIndex = try? rootRepo.stashList().firstIndex(where: {
                       $0.id == applyInfo.identifier
                   }) {
                    return MultiRootConflictResolverRoot(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        paths: statusPaths,
                        kind: .stash(
                            stashID: applyInfo.identifier,
                            index: stashIndex,
                            isPop: true
                        )
                    )
                }
                if let applyInfo, applyInfo.kind == "shelf" {
                    return MultiRootConflictResolverRoot(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        paths: statusPaths,
                        kind: .shelve(name: applyInfo.identifier, isPop: true)
                    )
                }

                guard !statusPaths.isEmpty else { return nil }
                return MultiRootConflictResolverRoot(
                    rootPath: root.path,
                    displayName: root.displayName,
                    relativePath: root.relativePath,
                    paths: statusPaths,
                    kind: .workingTree
                )
                }
            )
            let selected = pendingRoots.first(where: { $0.rootPath == currentRootPath })
                ?? pendingRoots.first

            await MainActor.run {
                guard self.operationRecovery.multiRootResolverLoadGeneration == generation else { return }
                self.operationRecovery.multiRootResolverRoots = pendingRoots
                self.operationRecovery.multiRootResolverActiveRootPath = selected?.rootPath
                self.operationRecovery.multiRootResolverActiveInitialPath = selected?.paths.first
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = nil
                self.operationRecovery.showMultiRootConflictResolver = selected != nil
                if let selected {
                    self.selectMultiRootResolverRoot(selected.rootPath)
                    if let preferredPath, selected.paths.contains(preferredPath) {
                        self.operationRecovery.multiRootResolverActiveInitialPath = preferredPath
                    }
                }
            }
        } catch {
            await MainActor.run {
                guard self.operationRecovery.multiRootResolverLoadGeneration == generation else { return }
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = errorMessage(error)
                self.feedbackCenter.error(
                    "Conflict workbench unavailable",
                    detail: errorMessage(error),
                    nextStep: "Refresh Git Roots, then reopen the project conflict resolver."
                )
            }
        }
    }
}

/// 多 root 恢复动作必须以 root 路径打开对应 Repository；不能复用当前窗口的
/// `repo`，否则会把一个 root 的冲突恢复误应用到另一个 root。
func openMultiRootOperationConflict(rootPath: String, path: String? = nil) {
    openMultiRootConflictResolver(preferredRootPath: rootPath, preferredPath: path)
}

/// 项目级冲突树的批量 Accept。按 root 分组打开 Repository，逐文件继续执行，
/// 因此一个 root 或单个文件失败不会回滚已经成功的其它文件。
func acceptMultiRootConflicts(_ targets: [MultiRootConflictTarget], pick: FilePick) {
    guard !targets.isEmpty, !operationRecovery.multiRootConflictBatchWorking else { return }
    var seen = Set<String>()
    let selected = targets
        .filter { seen.insert($0.id).inserted }
        .sorted {
            if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
            return $0.path < $1.path
        }
    guard !selected.isEmpty else { return }

    operationRecovery.multiRootConflictBatchWorking = true
    operationRecovery.multiRootConflictBatchError = nil
    Task.detached(priority: .userInitiated) {
        let grouped = Dictionary(grouping: selected, by: \.rootPath)
        var failures: [String] = []

        for rootPath in grouped.keys.sorted() {
            guard let rootTargets = grouped[rootPath] else { continue }
            do {
                let rootRepo = try openRepository(path: rootPath)
                for target in rootTargets.sorted(by: { $0.path < $1.path }) {
                    do {
                        try rootRepo.acceptConflict(path: target.path, pick: pick)
                    } catch {
                        failures.append("\(target.rootPath)/\(target.path): \(error)")
                    }
                }
            } catch {
                failures.append(contentsOf: rootTargets.map {
                    "\($0.rootPath)/\($0.path): \(error)"
                })
            }
        }

        let failureMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        await MainActor.run {
            self.operationRecovery.multiRootConflictBatchWorking = false
            self.operationRecovery.multiRootConflictBatchError = failureMessage
            self.loadMultiRoots()
            self.refreshAll(showFeedback: false)
        }
    }
}

/// stash pop 的冲突不是分支 merge，不创建新的 merge commit；用户解决后，
/// 只需确认所有冲突 stages 已清除，再删除已经成功应用的 stash 记录。
func finishStashConflict() {
    guard let repo, stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress else { return }
    let stashID = stashRecovery.pendingPopID
    let shouldDropStash = stashRecovery.popConflictInProgress
    let repositoryPath = repo.workdir()
    let pullRebaseSeed = rebaseWorkspace.undoSeed
    let conflictNotificationID = stashRecovery.pendingConflictNotificationID
    beginFeedbackOperation(
        "Complete stash restore",
        notificationID: conflictNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            let st = try repo.status()
            let conflicts = st.filter {
                $0.staged == .conflicted || $0.unstaged == .conflicted
            }
            guard conflicts.isEmpty else {
                throw NSError(
                    domain: "Arbor.StashRestore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "仍有冲突文件未解决：\(conflicts.map(\.path).joined(separator: ", "))"]
                )
            }
            if shouldDropStash {
                let finalizedPreserved = try repo.finalizeApplyLocalChangesRestore()
                if !finalizedPreserved {
                    guard let stashID else {
                        throw NSError(
                            domain: "Arbor.StashRestore",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The stash identity is unavailable; the stash was kept."]
                        )
                    }
                    try repo.stashDrop(index: try currentStashIndex(repo: repo, stashID: stashID))
                }
            }
            let pullRebaseRestoreCompleted = pullRebaseSeed != nil
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
                self.stashRecovery.popConflictInProgress = false
                self.stashRecovery.applyConflictInProgress = false
                self.stashRecovery.pendingConflictNotificationID = nil
                self.stashRecovery.pendingPopIndex = nil
                self.stashRecovery.pendingPopID = nil
                self.stashRecovery.pendingPullStashPop = false
                self.stashRecovery.pendingPullStashID = nil
                self.stashRecovery.pendingPullStashMessage = nil
                if let repositoryPath {
                    clearPendingPullPreservation(repositoryPath: repositoryPath)
                }
                if pullRebaseRestoreCompleted {
                    self.finishPendingPullRebaseRestore(
                        seed: pullRebaseSeed,
                        target: completedPullRebaseUndoTarget
                    )
                }
                self.mergeWorkspace.inProgress = false
                self.operationRecovery.showConflictResolver = false
                if shouldDropStash, let repositoryPath, let stashID {
                    self.clearStashDiffIfMatching(rootPath: repositoryPath, stashID: stashID)
                }
                self.mergeWorkspace.feedback = shouldDropStash ? "已完成本地变更恢复" : "已完成 stash 应用"
                if let completedPullRebaseUndoTarget {
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
                        shouldDropStash ? "Local changes restored" : "Stash applied",
                        notificationID: conflictNotificationID
                    )
                }
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                let detail = errorMessage(error)
                self.mergeWorkspace.feedback = detail
                self.feedbackCenter.error(
                    "Complete stash restore failed",
                    detail: detail,
                    nextStep: "Resolve every conflicted file, then complete the restore.",
                    notificationID: conflictNotificationID
                )
            }
        }
    }
}

}
