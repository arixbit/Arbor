import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Smart Checkout restores the user's local changes after switching branches.
/// Inspect the repository again before Update; otherwise a clean checkout
/// followed by a successful Smart restore would make pull reject the restored
/// worktree instead of entering the normal stash/pull/pop flow.
func pullAfterCheckout(
    repo: Repository,
    upstream: String,
    onComplete: @escaping () -> Void
) {
    Task.detached(priority: .userInitiated) {
        let dirty = (try? repo.status())?.contains { entry in
            entry.staged != .unchanged
                || (entry.unstaged != .unchanged && entry.unstaged != .ignored)
        } == true
        await MainActor.run {
            if dirty {
                self.stashAndPull(
                    remote: nil,
                    remoteBranch: upstream,
                    rebase: false,
                    onComplete: onComplete
                )
            } else {
                self.runPull(
                    remote: nil,
                    remoteBranch: upstream,
                    rebase: false,
                    restoreStash: false,
                    onComplete: onComplete
                )
            }
        }
    }
}

func pullSelectedBranch(_ name: String, rebase: Bool) {
    guard let repo else { return }
    if branchWorkspace.branches.first(where: { $0.name == name })?.isCurrent == true {
        doPull(nil, rebase: rebase)
        return
    }
    beginFeedbackOperation(rebase ? "Pull branch with rebase" : "Pull branch")
    Task.detached(priority: .userInitiated) {
        do {
            let outcome = try repo.pullBranch(branch: name, rebase: rebase)
            let detail = outcome.updatedCommits > 0
                ? "\(name) ← \(outcome.upstream) (+\(outcome.updatedCommits) commits)"
                : "\(name) 已是最新"
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Branch pull completed", detail: detail)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                let detail = errorMessage(error)
                self.repositoryStatus.loadError = detail
                self.feedbackCenter.error(
                    "Branch pull failed",
                    detail: detail,
                    nextStep: "The current branch was not changed. Checkout the selected branch to resolve conflicts if needed."
                )
            }
        }
    }
}

/// 多 root Branches Popup 的非当前分支 Pull：只在目标 root 的临时 worktree
/// 更新该分支，不改变当前窗口绑定的另一个 root。
func pullBranchInRoot(rootPath: String, branch: String, rebase: Bool) {
    beginFeedbackOperation(rebase ? "Pull branch with rebase" : "Pull branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let outcome = try rootRepo.pullBranch(branch: branch, rebase: rebase)
            let detail = outcome.updatedCommits > 0
                ? "\(branch) (+\(outcome.updatedCommits) commits) · \(rootPath)"
                : "\(branch) already up to date · \(rootPath)"
            await MainActor.run {
                self.feedbackCenter.success("Branch pull completed", detail: detail)
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error(
                    "Branch pull failed",
                    detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Checkout the selected branch in that root to resolve conflicts if needed."
                )
            }
        }
    }
}

/// Multi-root Branches Popup 的 remote ref Pull：严格把 remote-tracking
/// branch 作为 merge/rebase 来源，目标固定为该 root 的当前分支；不能退化为
/// 按本地 branch 名称读取 configured upstream。
func pullRemoteBranchInRoot(rootPath: String, remoteBranch: String, rebase: Bool) {
    pullRemoteBranchInRoot(
        rootPath: rootPath,
        remoteBranch: remoteBranch,
        rebase: rebase,
        options: nil
    )
}

func pullRemoteBranchInRoot(
    rootPath: String,
    remoteBranch: String,
    rebase: Bool,
    options: PullOptions?
) {
    let normalizedRemoteBranch = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRemoteBranch.isEmpty else { return }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let tagMode = fetchTagsMode
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation(
        rebase ? "Pull remote branch with rebase" : "Pull remote branch",
        cancelHandle: cancel
    )
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let effectiveOptions = options ?? PullOptions(
                rebase: rebase,
                mode: .fastForward,
                noCommit: false,
                noVerify: false
            )
            let outcome = try rootRepo.pullRemoteBranchWithSettingsAndPolicy(
                remoteBranch: normalizedRemoteBranch,
                options: effectiveOptions,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: savePolicy
            )
            let detail = outcome.updatedCommits > 0
                ? "\(normalizedRemoteBranch) (+\(outcome.updatedCommits) commits) · \(rootPath)"
                : "\(normalizedRemoteBranch) already up to date · \(rootPath)"
            await MainActor.run {
                if outcome.requiresFinish || !outcome.conflicts.isEmpty {
                    self.feedbackCenter.warning(
                        "Remote branch pull paused",
                        detail: "\(detail) · \(outcome.conflicts.joined(separator: ", "))",
                        nextStep: "Resolve the conflicts in the selected Git root, then Continue or Abort.",
                        additionalActions: [
                            FeedbackAction(title: "Open conflict workbench") {
                                self.openMultiRootConflictResolver(
                                    preferredRootPath: rootPath,
                                    preferredPath: outcome.conflicts.first
                                )
                            }
                        ]
                    )
                } else {
                    self.feedbackCenter.success("Remote branch pull completed", detail: detail)
                }
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.presentMultiRootMergeRestoreConflict(
                        rootPath: rootPath,
                        paths: paths,
                        stashID: stashID
                    )
                    return
                }
                if case let .ShelveApplyConflict(_, paths) = error as? EngineError {
                    self.presentMultiRootMergeRestoreConflict(rootPath: rootPath, paths: paths)
                    return
                }
                self.feedbackCenter.error(
                    "Remote branch pull failed",
                    detail: "\(normalizedRemoteBranch) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the current branch, remote branch, and working tree, then retry."
                )
            }
        }
    }
}

func presentPullDialog(rebase: Bool?) {
    guard let projectPath = projectWorkspace.path,
          isArborVCSActionEnabled(
        rebase == true ? .pullRebase : .pullMerge,
        in: vcsActionContext
    ) else {
        return
    }
    let defaultRebase = pullDialogDefaultRebase(
        explicit: rebase,
        savedOptions: GitPullDialogSettingsStore.load(for: projectPath).options
    )
    pullWorkspace.generation &+= 1
    let generation = pullWorkspace.generation
    pullWorkspace.rebase = defaultRebase
    pullWorkspace.snapshots = []
    pullWorkspace.showDialog = false
    Task.detached(priority: .userInitiated) {
        do {
            let snapshots = try listMultiRootBranches(scanRoot: projectPath)
            await MainActor.run {
                guard self.pullWorkspace.generation == generation else { return }
                guard !snapshots.isEmpty else {
                    self.feedbackCenter.warning(
                        "Pull unavailable",
                        detail: "No Git root was discovered for this project.",
                        nextStep: "Refresh the project and retry Pull."
                    )
                    return
                }
                self.pullWorkspace.snapshots = snapshots
                self.pullWorkspace.showDialog = true
            }
        } catch {
            await MainActor.run {
                guard self.pullWorkspace.generation == generation else { return }
                self.feedbackCenter.error(
                    "Pull dialog unavailable",
                    detail: errorMessage(error),
                    nextStep: "Refresh the project and retry Pull."
                )
            }
        }
    }
}

func savePullDialogSettings(_ options: PullDialogOptions) {
    var selected = GitPullDialogSettingsStore.load(for: projectWorkspace.path).options
    selected.removeAll()
    if options.rebase { selected.insert(.rebase) }
    switch options.mode {
    case .fastForwardOnly: selected.insert(.ffOnly)
    case .noFastForward: selected.insert(.noFF)
    case .squash: selected.insert(.squash)
    case .fastForward: break
    }
    if options.noCommit { selected.insert(.noCommit) }
    if options.noVerify { selected.insert(.noVerify) }
    GitPullDialogSettingsStore.save(
        GitPullDialogSettings(options: selected),
        for: projectWorkspace.path
    )
}

func refreshPullDialogSnapshots() {
    guard let projectPath = projectWorkspace.path else { return }
    let generation = pullWorkspace.generation
    Task.detached(priority: .utility) {
        guard let snapshots = try? listMultiRootBranches(scanRoot: projectPath) else { return }
        await MainActor.run {
            guard self.pullWorkspace.generation == generation, self.pullWorkspace.showDialog else { return }
            self.pullWorkspace.snapshots = snapshots
        }
    }
}

func executePullDialogSelection(_ selection: PullDialogSelection) {
    let options = PullOptions(
        rebase: selection.options.rebase,
        mode: selection.options.mode,
        noCommit: selection.options.noCommit,
        noVerify: selection.options.noVerify
    )
    let selectedRootPath = canonicalExternalLogPath(selection.rootPath)
    let currentRootPath = repo?.workdir().map(canonicalExternalLogPath)
    guard !selection.remoteBranch.isEmpty,
          !multiRootWorkspace.running,
          operationRecovery.operation == nil,
          !feedbackCenter.isRunning,
          !multiRootWorkspace.roots.contains(where: { root in
              canonicalExternalLogPath(root.path) == selectedRootPath && root.operation != nil
          }),
          isArborVCSActionEnabled(
              selection.options.rebase ? .pullRebase : .pullMerge,
              in: vcsActionContext
          ) else {
        return
    }

    if selectedRootPath != currentRootPath {
        // The root-qualified path is intentionally explicit. The existing
        // multi-root operation reports conflicts against that root instead of
        // silently redirecting the Pull to the window's primary repository.
        pullRemoteBranchInRoot(
            rootPath: selection.rootPath,
            remoteBranch: selection.remoteBranch,
            rebase: selection.options.rebase,
            options: options
        )
        return
    }

    guard let currentRepo = repo else { return }
    let dirty = (try? currentRepo.status())?.contains { entry in
        entry.staged != .unchanged
            || (entry.unstaged != .unchanged && entry.unstaged != .ignored)
    } == true
    if dirty {
        stashAndPull(
            remote: selection.remote,
            remoteBranch: selection.remoteBranch,
            rebase: selection.options.rebase,
            pullOptions: options,
            onComplete: nil
        )
    } else {
        runPull(
            remote: selection.remote,
            remoteBranch: selection.remoteBranch,
            rebase: selection.options.rebase,
            pullOptions: options,
            restoreStash: false,
            onComplete: nil
        )
    }
}

func doPull(
    _ name: String? = nil,
    rebase: Bool = false,
    autoOpenUpdateInfo: Bool = false,
    onComplete: (() -> Void)? = nil
) {
    guard repo != nil, !remoteWorkspace.remotes.isEmpty else { return }
    if hasTrackedChanges || hasUntrackedOrIgnoredFiles {
        // Match Rebased: preserve the complete local workspace automatically.
        // This includes untracked/ignored files so users never need to Add or
        // Commit local-only files just to update from the remote.
        stashAndPull(
            remote: name,
            remoteBranch: nil,
            rebase: rebase,
            autoOpenUpdateInfo: autoOpenUpdateInfo,
            onComplete: onComplete
        )
        return
    }
    runPull(
        remote: name,
        remoteBranch: nil,
        rebase: rebase,
        restoreStash: false,
        autoOpenUpdateInfo: autoOpenUpdateInfo,
        onComplete: onComplete
    )
}

func pullRemoteBranch(_ branch: RemoteBranchInfo, rebase: Bool) {
    guard repo != nil, !remoteWorkspace.remotes.isEmpty else { return }
    if hasTrackedChanges || hasUntrackedOrIgnoredFiles {
        stashAndPull(
            remote: nil,
            remoteBranch: branch.name,
            rebase: rebase,
            onComplete: nil
        )
        return
    }
    runPull(
        remote: nil,
        remoteBranch: branch.name,
        rebase: rebase,
        restoreStash: false,
        onComplete: nil
    )
}

/// Save all dirty paths using IntelliJ's configured local-changes policy.
/// Returning the exact Shelf name or stash ID prevents a later user-created
/// artifact from being mistaken for the operation's temporary preservation.
nonisolated static func saveLocalChangesBeforePull(
    repo: Repository,
    policy: LocalChangesSavePolicy,
    purpose: String = "pull"
) throws -> PullLocalChangesPreservation {
    let paths = try repo.status()
        .filter { $0.staged != .unchanged || $0.unstaged != .unchanged }
        .map(\.path)
    guard !paths.isEmpty else {
        return PullLocalChangesPreservation(shelfName: nil, stashMessage: nil)
    }

    switch policy {
    case .stash:
        let message = "Arbor: \(purpose) \(UUID().uuidString)"
        let stashID = try repo.stashSaveIncludingUntracked(message: message)
        return PullLocalChangesPreservation(
            shelfName: nil,
            stashMessage: message,
            stashID: stashID
        )
    case .shelve:
        let name = "Arbor: \(purpose) \(UUID().uuidString)"
        try repo.shelveForPreservation(name: name, paths: paths)
        return PullLocalChangesPreservation(shelfName: name, stashMessage: nil)
    }
}

func runPull(
    remote: String?,
    remoteBranch: String?,
    rebase: Bool,
    pullOptions: PullOptions? = nil,
    restoreStash: Bool,
    restoreStashID: String? = nil,
    restoreStashMessage: String? = nil,
    restoreShelf: String? = nil,
    autoOpenUpdateInfo: Bool = false,
    onComplete: (() -> Void)? = nil
) {
    guard let repo else { return }
    let effectivePullOptions = pullOptions ?? PullOptions(
        rebase: rebase,
        mode: .fastForward,
        noCommit: false,
        noVerify: false
    )
    let pullRebaseSeed: RebaseUndoSeed? = {
        guard rebase else { return nil }
        if (try? repo.operationState()) != nil {
            return rebaseWorkspace.undoSeed
        }
        guard let branch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name else {
            return nil
        }
        let configuredUpstream: String? = remote == nil
            ? (try? repo.syncStatus())?.first {
                $0.branch == branch
                    && !$0.upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?.upstream
            : nil
        return makeRebaseUndoSeed(
            repo: repo,
            branch: branch,
            onto: remoteBranch ?? configuredUpstream
        )
    }()
    if rebase {
        rebaseWorkspace.undoTarget = nil
        rebaseWorkspace.undoSeed = pullRebaseSeed
        if let pullRebaseSeed {
            saveRebaseUndoSeed(pullRebaseSeed)
        }
    }
    let cancel = GitCancelHandle()
    beginFeedbackOperation(rebase ? "Pull with rebase" : "Pull", cancelHandle: cancel)
    let repositoryPath = repo.workdir()
    let initialHead = repo.headCommitId()
    let persistedPreservation = repositoryPath.flatMap {
        loadPendingPullPreservation(repositoryPath: $0)
    }
    let stashIDToRestore = restoreStashID ?? persistedPreservation?.stashID
    let stashMessageToRestore = restoreStashMessage ?? persistedPreservation?.stashMessage
    let stashWillBePopped = restoreStash || stashIDToRestore != nil || stashMessageToRestore != nil
    let shelfToRestore = restoreShelf ?? persistedPreservation?.shelfName
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    Task.detached(priority: .userInitiated) {
        do {
            let mo: MergeOutcome
            if let remoteBranch {
                mo = try repo.pullRemoteBranchWithSettingsAndAuthAndCancel(
                    remoteBranch: remoteBranch,
                    options: effectivePullOptions,
                    tagMode: tagMode,
                    broker: broker,
                    cancel: cancel
                )
            } else {
                mo = try repo.pullWithSettingsAndAuthAndCancel(
                    remote: remote,
                    options: effectivePullOptions,
                    tagMode: tagMode,
                    broker: broker,
                    cancel: cancel
                )
            }
            let completedUpdateRange: PersistedLogRevisionRange? = {
                guard mo.conflicts.isEmpty,
                      let initialHead,
                      let finalHead = repo.headCommitId(),
                      let repositoryPath,
                      !initialHead.isEmpty,
                      !finalHead.isEmpty,
                      initialHead != finalHead else {
                    return nil
                }
                return PersistedLogRevisionRange(
                    rootPath: repositoryPath,
                    oldRevision: initialHead,
                    newRevision: finalHead
                )
            }()
            let completedRebaseUndoTarget: RebaseUndoTarget? = {
                guard rebase, mo.conflicts.isEmpty, let pullRebaseSeed else { return nil }
                return rebaseUndoTargetAfterCompletion(
                    seed: pullRebaseSeed,
                    currentBranch: (try? repo.branchList())?.first(where: { $0.isCurrent })?.name,
                    finalHead: try? repo.revisionCommitId(revision: pullRebaseSeed.branch)
                )
            }()
            var stashPopError: String?
            var stashPopConflicts: [String]?
            var stashPopID: String? = stashIDToRestore
            var stashPopIndex: Int?
            var stashPopConflictID: String?
            var stashPopCancelled = false
            var shelfPopError: String?
            var shelfPopConflictName: String?
            var shelfPopConflicts: [String]?
            var shelfPopCancelled = false
            if mo.conflicts.isEmpty, let shelfToRestore {
                do {
                    try repo.shelvePopWithCancel(name: shelfToRestore, cancel: cancel)
                    await MainActor.run { self.stashRecovery.pendingPullShelfName = nil }
                } catch {
                    if case .Cancelled = error as? EngineError {
                        shelfPopCancelled = true
                    } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                        shelfPopConflictName = name
                        shelfPopConflicts = paths
                    } else {
                        shelfPopError = String(describing: error)
                    }
                }
            } else if mo.conflicts.isEmpty, stashWillBePopped {
                do {
                    let reference = try Self.pullStashReference(
                        repo: repo,
                        stashID: stashIDToRestore,
                        message: stashMessageToRestore
                    )
                    stashPopID = reference.stash.id
                    stashPopIndex = Int(reference.index)
                    try repo.stashPopWithIndexAndCancel(
                        index: try currentStashIndex(repo: repo, stashID: reference.stash.id),
                        restoreIndex: true,
                        cancel: cancel
                    )
                    await MainActor.run {
                        self.stashRecovery.pendingPullStashPop = false
                        self.stashRecovery.pendingPullStashID = nil
                        self.stashRecovery.pendingPullStashMessage = nil
                    }
                } catch {
                    if case .Cancelled = error as? EngineError {
                        stashPopCancelled = true
                    } else if case let .StashApplyConflict(paths, conflictID) = error as? EngineError {
                        stashPopConflicts = paths
                        stashPopConflictID = conflictID ?? stashPopID
                    } else {
                        stashPopError = String(describing: error)
                    }
                }
            }
            let st = try repo.status()
            let stashPopErrorMessage = stashPopError
            let stashPopConflictPaths = stashPopConflicts
            let stashPopIDValue = stashPopID
            let stashPopIndexValue = stashPopIndex
            let stashPopConflictIDValue = stashPopConflictID
            let shelfPopConflictNameValue = shelfPopConflictName
            let shelfPopConflictsValue = shelfPopConflicts
            let shelfPopErrorMessage = shelfPopError
            let shelfPopCancelledValue = shelfPopCancelled
            let stashPopCancelledValue = stashPopCancelled
            await MainActor.run {
                let savedChangesAction: FeedbackAction? = {
                    if shelfToRestore != nil,
                       shelfPopCancelledValue
                        || shelfPopConflictNameValue != nil
                        || shelfPopConflictsValue != nil
                        || shelfPopErrorMessage != nil
                    {
                        return self.savedChangesFeedbackAction(
                            kind: .shelf,
                            identifier: shelfPopConflictNameValue ?? shelfToRestore!
                        )
                    }
                    if let stashPopIDValue,
                       stashPopCancelledValue
                        || stashPopConflictPaths != nil
                        || stashPopErrorMessage != nil
                    {
                        return self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: stashPopIDValue
                        )
                    }
                    return nil
                }()
                let savedChangesActions = savedChangesAction.map { [$0] } ?? []
                let viewCommitsActions = completedUpdateRange
                    .flatMap { range in
                        self.forcePushedViewCommitsAction(
                            ranges: [range],
                            rootPath: range.rootPath
                        )
                    }
                    .map { [$0] } ?? []
                self.repositoryStatus.entries = st
                self.projectWorkspace.toolWindowMode = .commit
                self.toolWindowExpanded = true
                self.rebaseWorkspace.paused = !mo.conflicts.isEmpty && rebase
                self.rebaseWorkspace.pauseReason = rebase && !mo.conflicts.isEmpty ? .conflict : nil
                self.rebaseWorkspace.conflicts = rebase ? mo.conflicts : []
                let localRestoreCompleted = stashPopConflictPaths == nil
                    && shelfPopConflictsValue == nil
                    && stashPopErrorMessage == nil
                    && !stashPopCancelledValue
                    && shelfPopErrorMessage == nil
                    && !shelfPopCancelledValue
                if rebase, !mo.conflicts.isEmpty {
                    self.rebaseWorkspace.undoSeed = pullRebaseSeed
                    if let pullRebaseSeed {
                        saveRebaseUndoSeed(pullRebaseSeed)
                    }
                } else if rebase, localRestoreCompleted {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = completedRebaseUndoTarget
                    if let pullRebaseSeed {
                        clearRebaseUndoSeed(repositoryPath: pullRebaseSeed.repositoryPath)
                    }
                } else if rebase {
                    self.rebaseWorkspace.undoSeed = pullRebaseSeed
                    self.rebaseWorkspace.undoTarget = nil
                    if let pullRebaseSeed {
                        saveRebaseUndoSeed(pullRebaseSeed)
                    }
                }
                if mo.conflicts.isEmpty,
                   localRestoreCompleted,
                   (shelfToRestore != nil || stashWillBePopped),
                   let repositoryPath
                {
                    clearPendingPullPreservation(repositoryPath: repositoryPath)
                }
                if localRestoreCompleted, let repositoryPath, let stashPopIDValue {
                    self.clearStashDiffIfMatching(rootPath: repositoryPath, stashID: stashPopIDValue)
                }
                self.stashRecovery.popConflictInProgress = stashPopConflictPaths != nil
                self.stashRecovery.applyConflictInProgress = false
                self.stashRecovery.pendingPopIndex = stashPopConflictPaths != nil ? 0 : nil
                self.stashRecovery.pendingPopID = stashPopConflictIDValue
                if stashPopConflictPaths != nil {
                    self.stashRecovery.pendingPopIndex = stashPopIndexValue
                    self.stashRecovery.pendingPullStashPop = false
                    self.stashRecovery.pendingPullStashID = nil
                    self.stashRecovery.pendingPullStashMessage = nil
                }
                if shelfPopConflictNameValue != nil { self.stashRecovery.pendingPullShelfName = nil }
                if let shelfPopConflictNameValue, let shelfPopConflictsValue {
                    self.presentShelveConflict(
                        name: shelfPopConflictNameValue,
                        paths: shelfPopConflictsValue,
                        isPop: true
                    )
                }
                self.mergeWorkspace.inProgress = (!rebase && mo.requiresFinish)
                    || stashPopConflictPaths != nil
                    || shelfPopConflictsValue != nil
                self.fileWorkspace.selection = shelfPopConflictsValue?.first
                    ?? stashPopConflictPaths?.first
                    ?? mo.conflicts.first
                self.operationRecovery.showConflictResolver = !mo.conflicts.isEmpty
                    || stashPopConflictPaths != nil
                    || shelfPopConflictsValue != nil
                if let stashPopConflictPaths {
                    self.mergeWorkspace.feedback = "pull 完成，但恢复本地变更时发生冲突：\(stashPopConflictPaths.joined(separator: ", "))"
                } else if let shelfPopConflictsValue {
                    self.mergeWorkspace.feedback = "pull 完成，但恢复 Shelf 本地变更时发生冲突：\(shelfPopConflictsValue.joined(separator: ", "))"
                } else if !mo.conflicts.isEmpty {
                    self.mergeWorkspace.feedback = "pull\(rebase ? " --rebase" : "") 冲突 \(mo.conflicts.count) 个文件"
                } else if let stashPopErrorMessage {
                    self.mergeWorkspace.feedback = "pull 完成，但自动 stash pop 产生冲突：\(stashPopErrorMessage)"
                } else if let shelfPopErrorMessage {
                    self.mergeWorkspace.feedback = "pull 完成，但自动 Shelf 恢复失败：\(shelfPopErrorMessage)"
                } else if stashPopCancelledValue {
                    self.mergeWorkspace.feedback = "pull 完成，但恢复 Stash 本地变更已取消，Stash 已保留"
                } else if shelfPopCancelledValue {
                    self.mergeWorkspace.feedback = "pull 完成，但恢复 Shelf 本地变更已取消，Shelf 已保留"
                } else if mo.updatedCommits > 0, !mo.upstream.isEmpty, !mo.branch.isEmpty {
                    self.mergeWorkspace.feedback = "已更新 \(mo.upstream) → \(mo.branch)（+\(mo.updatedCommits) commits）"
                } else if stashWillBePopped || shelfToRestore != nil {
                    self.mergeWorkspace.feedback = "pull 完成，已恢复本地变更"
                } else {
                    self.mergeWorkspace.feedback = "pull 完成（已是最新）"
                }
                let detail = self.mergeWorkspace.feedback ?? "pull 完成"
                let rebaseRecoveryAction = rebase && !mo.conflicts.isEmpty
                    ? pullRebaseSeed.map {
                        self.persistedRebaseRecoveryAction(
                            rootPath: $0.repositoryPath,
                            branch: $0.branch
                        )
                    }
                    : nil
                let recoveryActions = savedChangesActions + (rebaseRecoveryAction.map { [$0] } ?? [])
                if !mo.conflicts.isEmpty || stashPopConflictPaths != nil || shelfPopConflictsValue != nil {
                    self.feedbackCenter.warning(
                        "Pull paused for conflicts",
                        detail: detail,
                        nextStep: (stashPopConflictPaths != nil || shelfPopConflictsValue != nil)
                            ? "Open Merge Revisions, resolve the restored local changes, then complete the restore."
                            : "Open Merge Revisions, resolve the files, then finish the merge.",
                        additionalActions: recoveryActions,
                        notificationID: rebaseRecoveryAction.map { _ in
                            rebaseRecoveryNotificationID(repositoryPath: pullRebaseSeed?.repositoryPath ?? "")
                        }
                    )
                } else {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if savedChangesActions.isEmpty {
                        if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                            self.feedbackCenter.expire(notificationID: notificationID)
                        }
                    } else if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let completedRebaseUndoTarget {
                        self.feedbackCenter.success(
                            "Pull completed",
                            detail: detail,
                            additionalActions: [self.rebaseUndoFeedbackAction(for: completedRebaseUndoTarget)]
                                + savedChangesActions + viewCommitsActions,
                            notificationID: self.multiRootUpdateNotificationID(partial: false),
                            notificationGroup: .standard
                        )
                } else if stashPopCancelledValue || shelfPopCancelledValue {
                    self.feedbackCenter.warning(
                        "Local changes restore cancelled",
                        detail: detail,
                        nextStep: stashPopCancelledValue
                            ? "The preservation Stash was kept. Retry restoring it when ready."
                            : "The preservation Shelf was kept. Retry restoring it when ready.",
                        additionalActions: savedChangesActions + viewCommitsActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: true),
                        notificationGroup: .standard
                    )
                } else if savedChangesActions.isEmpty {
                    self.feedbackCenter.success(
                        "Pull completed",
                        detail: detail,
                        additionalActions: viewCommitsActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: false),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Local changes were not restored",
                        detail: detail,
                        nextStep: "View the saved changes and restore them after fixing the conflict.",
                        additionalActions: savedChangesActions + viewCommitsActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: true),
                        notificationGroup: .standard
                    )
                }
                }
                if autoOpenUpdateInfo,
                   mo.conflicts.isEmpty,
                   localRestoreCompleted,
                   let completedUpdateRange
                {
                    self.autoOpenUpdateInfoIfEnabled([completedUpdateRange])
                }
                if mo.conflicts.isEmpty,
                   stashPopConflictPaths == nil,
                   shelfPopConflictsValue == nil,
                   stashPopErrorMessage == nil,
                   shelfPopErrorMessage == nil,
                   !stashPopCancelledValue,
                   !shelfPopCancelledValue {
                    onComplete?()
                }
                self.refreshAll(showFeedback: false)
            }
        } catch {
            let failedOperationState = try? repo.operationState()
            let rebaseStillActive = rebase && failedOperationState?.kind == .rebase
            var restoreError: String?
            var stashRestoreID: String? = stashIDToRestore
            var stashRestoreIndex: Int?
            var stashRestoreConflictID: String?
            var stashRestoreConflictPaths: [String]?
            var shelfRestoreConflictName: String?
            var shelfRestoreConflictPaths: [String]?
            if !rebaseStillActive, let shelfToRestore {
                do {
                    try repo.shelvePopPreservation(name: shelfToRestore)
                    await MainActor.run { self.stashRecovery.pendingPullShelfName = nil }
                } catch {
                    if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                        shelfRestoreConflictName = name
                        shelfRestoreConflictPaths = paths
                    } else {
                        restoreError = String(describing: error)
                    }
                }
            } else if !rebaseStillActive, stashWillBePopped {
                do {
                    let reference = try Self.pullStashReference(
                        repo: repo,
                        stashID: stashIDToRestore,
                        message: stashMessageToRestore
                    )
                    stashRestoreID = reference.stash.id
                    stashRestoreIndex = Int(reference.index)
                    try repo.stashPopWithIndex(
                        index: try currentStashIndex(repo: repo, stashID: reference.stash.id),
                        restoreIndex: true
                    )
                    await MainActor.run {
                        self.stashRecovery.pendingPullStashPop = false
                        self.stashRecovery.pendingPullStashID = nil
                        self.stashRecovery.pendingPullStashMessage = nil
                    }
                } catch let error as EngineError {
                if case let .StashApplyConflict(paths, conflictStashID) = error {
                        stashRestoreConflictID = conflictStashID ?? stashRestoreID
                        stashRestoreConflictPaths = paths
                    } else {
                        restoreError = String(describing: error)
                    }
                } catch {
                    restoreError = String(describing: error)
                }
            }
            let restoreErrorMessage = restoreError
            let stashRestoreIDValue = stashRestoreID
            let stashRestoreIndexValue = stashRestoreIndex
            let stashRestoreConflictIDValue = stashRestoreConflictID
            let stashRestoreConflictPathsValue = stashRestoreConflictPaths
            let shelfRestoreConflictNameValue = shelfRestoreConflictName
            let shelfRestoreConflictPathsValue = shelfRestoreConflictPaths
            await MainActor.run {
                let savedChangesAction: FeedbackAction? = {
                    if let shelfRestoreConflictNameValue,
                       shelfRestoreConflictPathsValue != nil || restoreErrorMessage != nil
                    {
                        return self.savedChangesFeedbackAction(
                            kind: .shelf,
                            identifier: shelfRestoreConflictNameValue
                        )
                    }
                    if let stashRestoreIDValue,
                       stashRestoreConflictPathsValue != nil || restoreErrorMessage != nil
                    {
                        return self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: stashRestoreIDValue
                        )
                    }
                    return nil
                }()
                let savedChangesActions = savedChangesAction.map { [$0] } ?? []
                let pullError = friendlyRemoteError(error)
                let localRestoreCompleted = restoreErrorMessage == nil
                    && shelfRestoreConflictPathsValue == nil
                    && stashRestoreConflictPathsValue == nil
                if !rebaseStillActive,
                   localRestoreCompleted,
                   (shelfToRestore != nil || stashWillBePopped),
                   let repositoryPath
                {
                    clearPendingPullPreservation(repositoryPath: repositoryPath)
                }
                if rebaseStillActive {
                    if let pullRebaseSeed {
                        self.rebaseWorkspace.undoSeed = pullRebaseSeed
                        saveRebaseUndoSeed(pullRebaseSeed)
                    }
                    self.rebaseWorkspace.paused = true
                    self.rebaseWorkspace.pauseReason = .conflict
                    self.rebaseWorkspace.conflicts = failedOperationState?.conflictedFiles ?? []
                    self.operationRecovery.operation = failedOperationState
                    self.operationRecovery.showConflictResolver = true
                } else if rebase {
                    self.rebaseWorkspace.paused = false
                    self.rebaseWorkspace.pauseReason = nil
                    self.rebaseWorkspace.conflicts = []
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = nil
                    if let pullRebaseSeed {
                        clearRebaseUndoSeed(repositoryPath: pullRebaseSeed.repositoryPath)
                    }
                }
                let rebaseRecoveryAction = rebaseStillActive
                    ? pullRebaseSeed.map {
                        self.persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)
                    }
                    : nil
                if let shelfRestoreConflictNameValue, let shelfRestoreConflictPathsValue {
                    self.stashRecovery.pendingPullShelfName = nil
                    self.presentShelveConflict(
                        name: shelfRestoreConflictNameValue,
                        paths: shelfRestoreConflictPathsValue,
                        isPop: true
                    )
                }
                if let stashRestoreConflictPathsValue {
                    self.showStashRestoreConflict(
                        stashRestoreConflictPathsValue,
                        operationName: "Pull",
                        stashID: stashRestoreConflictIDValue ?? stashRestoreIDValue
                    )
                    self.stashRecovery.pendingPopIndex = stashRestoreIndexValue
                    self.stashRecovery.pendingPullStashPop = false
                    self.stashRecovery.pendingPullStashID = nil
                    self.stashRecovery.pendingPullStashMessage = nil
                }
                let untrackedPaths: [String]? = {
                    guard case let .UntrackedWouldBeOverwritten(paths) = error as? EngineError else {
                        return nil
                    }
                    return paths
                }()
                if let shelfRestoreConflictPathsValue {
                    self.mergeWorkspace.feedback = "pull 失败：\(pullError)；恢复 Shelf 本地变更时发生冲突：\(shelfRestoreConflictPathsValue.joined(separator: ", "))"
                } else if let stashRestoreConflictPathsValue {
                    self.mergeWorkspace.feedback = "pull 失败：\(pullError)；恢复 stash 本地变更时发生冲突：\(stashRestoreConflictPathsValue.joined(separator: ", "))"
                } else if let restoreErrorMessage {
                    self.mergeWorkspace.feedback = "pull 失败：\(pullError)；自动恢复本地变更失败：\(restoreErrorMessage)"
                } else if stashWillBePopped || shelfToRestore != nil {
                    self.mergeWorkspace.feedback = "pull 失败，已恢复本地变更：\(pullError)"
                } else if let untrackedPaths {
                    self.mergeWorkspace.feedback = "远程更新涉及本地未跟踪文件，正在临时保存后重试：\(untrackedPaths.joined(separator: ", "))"
                } else {
                    self.mergeWorkspace.feedback = pullError
                }
                let detail = self.mergeWorkspace.feedback ?? pullError
                let upstreamAction = self.chooseUpstreamFeedbackAction(for: error)
                let recoveryActions = savedChangesActions
                    + (rebaseRecoveryAction.map { [$0] } ?? [])
                    + (upstreamAction.map { [$0] } ?? [])
                if rebaseStillActive {
                    self.feedbackCenter.warning(
                        "Pull with Rebase paused",
                        detail: detail,
                        nextStep: "Resolve the files, then Continue or Abort the rebase. Pull's saved local changes will be restored after completion.",
                        additionalActions: recoveryActions,
                        notificationID: rebaseRecoveryAction.map { _ in
                            rebaseRecoveryNotificationID(repositoryPath: pullRebaseSeed?.repositoryPath ?? "")
                        }
                    )
                } else if let untrackedPaths, !stashWillBePopped, shelfToRestore == nil {
                    self.feedbackCenter.warning(
                        "Preserving local files",
                        detail: detail,
                        nextStep: "These local files will not be added or committed; Arbor is retrying pull after a temporary save."
                    )
                    self.temporarilySaveWorkspaceAndRetryPull(
                        paths: untrackedPaths,
                        remote: remote,
                        remoteBranch: remoteBranch,
                        rebase: rebase,
                        pullOptions: pullOptions,
                        autoOpenUpdateInfo: autoOpenUpdateInfo,
                        onComplete: onComplete
                    )
                } else {
                    let nextStep: String
                    if restoreErrorMessage != nil
                        || shelfRestoreConflictPathsValue != nil
                        || stashRestoreConflictPathsValue != nil
                    {
                        nextStep = "Resolve the local restore conflict in Merge Revisions, then complete the restore."
                    } else if stashWillBePopped || shelfToRestore != nil {
                        nextStep = "Your local changes were restored; fix the remote or upstream issue, then retry pull."
                    } else {
                        nextStep = "Check the branch upstream and remote, then retry pull."
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.feedbackCenter.error(
                        "Pull failed",
                        detail: detail,
                        nextStep: nextStep,
                        additionalActions: recoveryActions,
                        notificationID: self.multiRootUpdateErrorNotificationID()
                    )
                    if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
                }
                if rebaseStillActive || stashWillBePopped || shelfToRestore != nil {
                    self.refreshAll(showFeedback: false)
                }
            }
        }
    }
}

/// 未跟踪文件和远程更新发生路径冲突时，不要求用户 Add 或 Commit。
/// 先把完整本地现场（tracked + untracked + ignored）按保存策略临时保存，
/// 再重试 pull；真正的同路径内容冲突才进入 Merge Revisions。
func temporarilySaveWorkspaceAndRetryPull(
    paths: [String],
    remote: String?,
    remoteBranch: String?,
    rebase: Bool,
    pullOptions: PullOptions? = nil,
    autoOpenUpdateInfo: Bool = false,
    onComplete: (() -> Void)? = nil
) {
    guard let repo else { return }
    beginFeedbackOperation("Preserve local files and retry pull")
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        do {
            let preservation = try Self.saveLocalChangesBeforePull(
                repo: repo,
                policy: savePolicy
            )
            let savedStash = preservation.stashID != nil || preservation.stashMessage != nil
            if let repositoryPath = repo.workdir() {
                savePendingPullPreservation(
                    repositoryPath: repositoryPath,
                    preservation: preservation
                )
            }
            await MainActor.run {
                self.stashRecovery.pendingPullShelfName = preservation.shelfName
                self.stashRecovery.pendingPullStashPop = savedStash
                self.stashRecovery.pendingPullStashID = preservation.stashID
                self.stashRecovery.pendingPullStashMessage = preservation.stashMessage
                self.mergeWorkspace.feedback = "已临时保存本地文件，正在重试 pull：\(paths.joined(separator: ", "))"
                self.runPull(
                        remote: remote,
                        remoteBranch: remoteBranch,
                        rebase: rebase,
                        pullOptions: pullOptions,
                        restoreStash: savedStash,
                        restoreStashID: preservation.stashID,
                        restoreStashMessage: preservation.stashMessage,
                        restoreShelf: preservation.shelfName,
                        autoOpenUpdateInfo: autoOpenUpdateInfo,
                        onComplete: onComplete
                )
            }
        } catch {
            await MainActor.run {
                let detail = errorMessage(error)
                self.mergeWorkspace.feedback = detail
                self.feedbackCenter.error("Preserve local files failed", detail: detail, nextStep: "Keep the files local and retry after checking the worktree.")
            }
        }
    }
}

}
