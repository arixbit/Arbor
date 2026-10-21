import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// IntelliJ 的 Checkout with Rebase：将选中的本地分支 rebase 到当前分支，
/// 而不是切换后 pull 它自己的 upstream。引擎使用 --autostash，冲突时留下
/// system rebase 状态，由统一 Continue/Skip/Abort 工作台接管。
func checkoutAndRebaseOntoCurrent(repo: Repository, name: String) {
    rebaseWorkspace.undoTarget = nil
    rebaseWorkspace.undoSeed = nil
    let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
    let seed = makeRebaseUndoSeed(repo: repo, branch: name, onto: currentBranch)
    if let seed {
        saveRebaseUndoSeed(seed)
        rebaseWorkspace.undoSeed = seed
    }
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Checkout with Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.rebaseBranchOnCurrentWithPolicyAndCancel(
                branch: name,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.rebaseWorkspace.undoSeed = nil
                if let seed {
                    clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                }
                self.feedbackCenter.success("Checked out and rebased", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Checkout with Rebase cancelled",
                        detail: "The saved local scene for \(name) was not discarded.",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: seed?.repositoryPath ?? repo.workdir()
                        ).map { [$0] } ?? []
                    )
                }
                return
            }
            let status = (try? repo.status()) ?? []
            let state = try? repo.operationState()
            let firstConflict = status.first {
                $0.staged == .conflicted || $0.unstaged == .conflicted
            }?.path
            await MainActor.run {
                if state?.kind == .rebase {
                    if let seed {
                        self.rebaseWorkspace.undoSeed = seed
                        saveRebaseUndoSeed(seed)
                    }
                    self.repositoryStatus.entries = status
                    self.operationRecovery.operation = state
                    self.mergeWorkspace.inProgress = true
                    self.operationRecovery.initialPath = firstConflict
                    self.operationRecovery.showConflictResolver = true
                    self.feedbackCenter.warning(
                        "Checkout with Rebase paused",
                        detail: errorMessage(error),
                        nextStep: "Resolve conflicts, then Continue or Abort the rebase.",
                        additionalActions: [
                            seed.map {
                                persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)
                            },
                            self.pendingSavedChangesFeedbackAction(
                                repo: repo,
                                rootPath: seed?.repositoryPath ?? repo.workdir()
                            )
                        ].compactMap { $0 },
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    self.rebaseWorkspace.undoSeed = nil
                    if let seed {
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    self.feedbackCenter.error(
                        "Checkout with Rebase failed",
                        detail: errorMessage(error),
                        nextStep: "检查目标分支与当前仓库状态后重试。",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: seed?.repositoryPath ?? repo.workdir()
                        ).map { [$0] } ?? []
                    )
                }
                self.refreshAll(showFeedback: false)
            }
        }
    }
}

/// Finish the remote Checkout with Rebase workflow after the user confirms
/// the local branch name in the shared New Branch dialog. Reuse the existing
/// checkout-with-rebase recovery path so conflicts remain resumable instead
/// of becoming an untracked background failure.
func branchCreateAndRebase(
    at baseRevision: String? = nil,
    reset: Bool = false,
    repository repositoryOverride: Repository? = nil
) {
    guard let targetRepo = repositoryOverride ?? branchWorkspace.newRepositoryOverride ?? repo else { return }
    let name = GitBranchNameCleanup.cleanUp(branchWorkspace.newName)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let base = baseRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let existingBranches = try? targetRepo.branchList() else {
        feedbackCenter.error(
            "Checkout with Rebase failed",
            detail: "Unable to inspect the selected repository's local branches."
        )
        return
    }
    guard existingBranches.first(where: { $0.isCurrent })?.name != name else {
        feedbackCenter.error(
            "Checkout with Rebase failed",
            detail: "The branch '\(name)' is already checked out."
        )
        return
    }
    let branchAlreadyExists = existingBranches.contains { $0.name == name }
    guard !reset || confirmBranchResetIfNeeded(
        repo: targetRepo,
        name: name,
        startPoint: base
    ) else { return }
    beginFeedbackOperation("Create branch for Checkout with Rebase")
    Task.detached(priority: .userInitiated) {
        do {
            let startPoint = base?.isEmpty == true ? nil : base
            // Keep the original branch checked out while the rebase starts.
            // `rebaseBranchOnCurrentWithPolicy` deliberately rejects a target
            // that is already HEAD; the native operation then switches the
            // newly rebased branch into HEAD as IntelliJ does.
            // An existing local branch is intentionally reused when Reset is
            // off. IntelliJ's remote Checkout with Rebase workflow only
            // creates the branch for roots that do not already have it.
            if branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: branchAlreadyExists,
                resetExisting: reset
            ) {
                try targetRepo.branchCreateOrReset(
                    name: name,
                    at: startPoint,
                    checkout: false,
                    reset: reset
                )
            }
            let bs = try targetRepo.branchList()
            await MainActor.run {
                if self.repo?.workdir() == targetRepo.workdir() {
                    self.branchWorkspace.branches = bs
                    self.loadRepoData()
                } else {
                    self.loadMultiRoots()
                }
                self.branchWorkspace.newName = ""
                self.branchWorkspace.newBase = ""
                if self.projectWorkspace.toolWindowMode == .log { self.loadLog() }
                self.checkoutAndRebaseOntoCurrent(repo: targetRepo, name: name)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Checkout with Rebase failed",
                    detail: errorMessage(error),
                    nextStep: "Check the branch name and working tree, then retry."
                )
            }
        }
    }
}

/// 多 root Branches Popup 的 Rebase Current onto：先生成该 root 当前分支的
/// explicit todo，再交给引擎执行，保持与单 root Rebase 对话框相同的历史语义。
func rebaseCurrentInRoot(rootPath: String, onto: String) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Rebase branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let seed = try rootRepo.branchList()
                .first(where: { $0.isCurrent })
                .flatMap { makeRebaseUndoSeed(repo: rootRepo, branch: $0.name, onto: onto) }
            if let seed {
                saveRebaseUndoSeed(seed)
            }
            let todo = try rootRepo.rebaseTodo(onto: onto, autoSquash: false)
            let outcome = try rootRepo.rebaseWithTodoAndPolicyAndCancel(
                onto: onto,
                todo: todo,
                preserveMerges: false,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            let finalHead = seed.flatMap { try? rootRepo.revisionCommitId(revision: $0.branch) }
            let currentBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                self.loadMultiRoots()
                if outcome.paused {
                    if let seed {
                        self.rebaseWorkspace.undoSeed = seed
                        saveRebaseUndoSeed(seed)
                    }
                    self.feedbackCenter.warning(
                        "Rebase paused",
                        detail: "\(onto) · \(rootPath): \(outcome.conflicts.count) conflict(s)",
                        nextStep: "Resolve conflicts in that root, then use Continue, Skip, or Abort in Git Roots.",
                        additionalActions: seed.map {
                            [persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)]
                        } ?? [],
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    if let seed {
                        self.rebaseWorkspace.undoSeed = nil
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: "\(onto) · \(rootPath)",
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(
                                repositoryPath: undoTarget.repositoryPath
                            ),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success("Rebase completed", detail: "\(onto) · \(rootPath)")
                    }
                }
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Rebase cancelled",
                        detail: "The saved local scene for \(rootPath) was not discarded.",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry."
                    )
                }
                return
            }
            let rootRepo = try? openRepository(path: rootPath)
            let state = rootRepo.flatMap { try? $0.operationState() }
            let seed = rootRepo?.workdir().flatMap {
                loadRebaseUndoSeed(repositoryPath: $0)
            }
            await MainActor.run {
                self.loadMultiRoots()
                if state?.kind == .rebase {
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.feedbackCenter.warning(
                        "Rebase paused",
                        detail: "\(onto) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Resolve conflicts in that root, then use Continue, Skip, or Abort in Git Roots.",
                        additionalActions: seed.map {
                            [persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)]
                        } ?? [],
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    if let seed {
                        self.rebaseWorkspace.undoSeed = nil
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    self.feedbackCenter.error(
                        "Rebase failed",
                        detail: "\(onto) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Check the target root status, then retry Rebase."
                    )
                }
            }
        }
    }
}

func loadRebaseRange() {
    rebaseWorkspace.rangeGeneration += 1
    let generation = rebaseWorkspace.rangeGeneration
    guard let repo else {
        rebaseWorkspace.range = []
        rebaseWorkspace.actions = []
        return
    }
    let onto = rebaseWorkspace.onto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseWorkspace.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = rebaseWorkspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = rebaseWorkspace.root
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root) else {
        rebaseWorkspace.range = []
        rebaseWorkspace.actions = []
        return
    }
    let preserveMerges = rebaseWorkspace.preserveMerges
    let currentRepositoryPath = repo.workdir() ?? ""
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            let range = try selectedRepo.rebaseRangeForBranch(
                onto: onto,
                preserveMerges: preserveMerges,
                root: root,
                branch: branch
            )
            await MainActor.run {
                guard rebaseRangeRequestIsCurrent(
                    generation: generation,
                    currentGeneration: self.rebaseWorkspace.rangeGeneration,
                    requestedOnto: onto,
                    currentOnto: self.rebaseWorkspace.onto,
                    requestedPreserveMerges: preserveMerges,
                    currentPreserveMerges: self.rebaseWorkspace.preserveMerges,
                    requestedRoot: root,
                    currentRoot: self.rebaseWorkspace.root,
                    requestedBranch: branch,
                    currentBranch: self.rebaseWorkspace.branch,
                    requestedRepositoryPath: repositoryPath,
                    currentRepositoryPath: self.rebaseWorkspace.rootPath
                ) else { return }
                self.rebaseWorkspace.range = range
                self.rebaseWorkspace.actions = Array(repeating: .pick, count: range.count)
                self.rebaseWorkspace.feedback = "范围 \(range.count) 个提交"
            }
        } catch {
            await MainActor.run {
                guard rebaseRangeRequestIsCurrent(
                    generation: generation,
                    currentGeneration: self.rebaseWorkspace.rangeGeneration,
                    requestedOnto: onto,
                    currentOnto: self.rebaseWorkspace.onto,
                    requestedPreserveMerges: preserveMerges,
                    currentPreserveMerges: self.rebaseWorkspace.preserveMerges,
                    requestedRoot: root,
                    currentRoot: self.rebaseWorkspace.root,
                    requestedBranch: branch,
                    currentBranch: self.rebaseWorkspace.branch,
                    requestedRepositoryPath: repositoryPath,
                    currentRepositoryPath: self.rebaseWorkspace.rootPath
                ) else { return }
                self.rebaseWorkspace.range = []
                self.rebaseWorkspace.actions = []
                self.rebaseWorkspace.feedback = "\(error)"
            }
        }
    }
}

func invalidateLoadedRebaseRange() {
    rebaseWorkspace.rangeGeneration += 1
    rebaseWorkspace.range = []
    rebaseWorkspace.actions = []
    rebaseWorkspace.feedback = nil
}

func doRebase() {
    guard operationRecovery.operation?.kind == nil,
          isArborVCSActionEnabled(.rebase, in: vcsActionContext),
          let repo else { return }
    let interactive = rebaseWorkspace.interactive
    guard !interactive || !rebaseWorkspace.actions.isEmpty else { return }
    let onto = rebaseWorkspace.onto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseWorkspace.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = rebaseWorkspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = rebaseWorkspace.root
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root) else { return }
    let currentRepositoryPath = repo.workdir() ?? ""
    let persistedRepositoryPath = repositoryPath.isEmpty ? currentRepositoryPath : repositoryPath
    rebaseWorkspace.rangeGeneration += 1
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = nil
    clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Rebase", cancelHandle: cancel)
    let actions = rebaseWorkspace.actions
    let preserveMerges = rebaseWorkspace.preserveMerges
    let autoSquash = rebaseWorkspace.autoSquash
    let keepEmpty = rebaseWorkspace.keepEmpty
    let updateRefs = rebaseWorkspace.updateRefs
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    rebaseWorkspace.retryContext = RebaseRetryContext(
        repositoryPath: repositoryPath,
        branch: branch,
        onto: onto,
        actions: actions,
        interactive: interactive,
        preserveMerges: preserveMerges,
        autoSquash: autoSquash,
        keepEmpty: keepEmpty,
        updateRefs: updateRefs,
        root: root
    )
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            let initialHead = try? selectedRepo.revisionCommitId(revision: branch)
            let undoSeed = initialHead.map {
                RebaseUndoSeed(
                    repositoryPath: persistedRepositoryPath,
                    branch: branch,
                    initialHead: $0,
                    updateRefs: updateRefs,
                    protectionCommitID: rebaseUndoProtectionCommitBeforeOperation(
                        repo: selectedRepo,
                        initialHead: $0,
                        onto: onto
                    )
                )
            }
            if let undoSeed {
                await MainActor.run {
                    self.rebaseWorkspace.undoSeed = undoSeed
                    saveRebaseUndoSeed(undoSeed)
                }
            }
            let outcome: RebaseOutcome
            if interactive {
                outcome = try selectedRepo.rebaseBranchWithAdvancedOptionsAndPolicyAndCancel(
                    onto: onto,
                    branch: branch,
                    actions: actions,
                    preserveMerges: preserveMerges,
                    autoSquash: autoSquash,
                    keepEmpty: keepEmpty,
                    updateRefs: updateRefs,
                    root: root,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            } else {
                outcome = try selectedRepo.rebaseBranchWithOptionsAndPolicyAndCancel(
                    onto: onto,
                    branch: branch,
                    preserveMerges: preserveMerges,
                    autoSquash: autoSquash,
                    keepEmpty: keepEmpty,
                    updateRefs: updateRefs,
                    root: root,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            }
            let st = try selectedRepo.status()
            let finalHead = try? selectedRepo.revisionCommitId(revision: branch)
            let currentBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: undoSeed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    self.repositoryStatus.entries = st
                }
                if outcome.paused {
                    self.rebaseWorkspace.retryContext = nil
                    let pausedSeed = undoSeed
                    self.rebaseWorkspace.undoSeed = pausedSeed
                    if let pausedSeed {
                        saveRebaseUndoSeed(pausedSeed)
                    } else {
                        clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
                    }
                    self.rebaseWorkspace.undoTarget = nil
                    self.rebaseWorkspace.paused = true
                    self.rebaseWorkspace.pauseReason = outcome.pauseReason
                    self.rebaseWorkspace.conflicts = outcome.conflicts
                    if outcome.pauseReason == .conflict {
                        let names = outcome.conflicts.prefix(3).joined(separator: "、")
                        let suffix = names.isEmpty ? "" : "：\(names)"
                        self.rebaseWorkspace.feedback = "冲突 \(outcome.conflicts.count) 个文件\(suffix)，请在状态页解决后「继续」"
                        self.operationRecovery.showConflictResolver = true
                    } else {
                        self.rebaseWorkspace.feedback = "已暂停在 edit 提交，可修改文件后「继续」"
                    }
                    self.rebaseWorkspace.range = []
                    self.rebaseWorkspace.actions = []
                } else {
                    self.rebaseWorkspace.retryContext = nil
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = undoTarget
                    clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
                    self.rebaseWorkspace.paused = false
                    self.rebaseWorkspace.pauseReason = nil
                    self.rebaseWorkspace.conflicts = []
                    self.rebaseWorkspace.feedback = "变基完成"
                    self.rebaseWorkspace.range = []
                    self.rebaseWorkspace.actions = []
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: String(outcome.headId.prefix(7)),
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: String(outcome.headId.prefix(7))
                        )
                    }
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.rebaseWorkspace.feedback = "变基已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Rebase cancelled",
                        detail: self.rebaseWorkspace.feedback ?? detail,
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry if needed."
                    )
                }
                return
            }
            // Re-running the original command is unsafe while Git has an
            // unfinished operation in the worktree. The recovery bar owns
            // Continue/Abort in that case; Retry is only offered for a clean
            // failed start.
            let operationStillActive: Bool
            do {
                let operationRepo: Repository
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    operationRepo = repo
                } else {
                    operationRepo = try openRepository(path: repositoryPath)
                }
                operationStillActive = try operationRepo.operationState() != nil
            } catch {
                // Do not offer a destructive retry when the recovery state
                // itself cannot be inspected.
                operationStillActive = true
            }
            await MainActor.run {
                self.rebaseWorkspace.feedback = detail
                if operationStillActive {
                    self.feedbackCenter.error(
                        "Rebase failed",
                        detail: detail,
                        nextStep: "Resolve conflicts, then Continue or Abort the rebase."
                    )
                } else {
                    self.rebaseWorkspace.undoSeed = nil
                    clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
                    self.feedbackCenter.error(
                        "Rebase failed",
                        detail: detail,
                        nextStep: "Resolve the cause and retry, or Abort if Git left an operation in progress.",
                        actionTitle: "Retry",
                        action: { self.retryLastRebase() }
                    )
                }
            }
        }
    }
}

func retryLastRebase() {
    guard let context = rebaseWorkspace.retryContext else { return }
    rebaseWorkspace.rootPath = context.repositoryPath
    rebaseWorkspace.branch = context.branch
    rebaseWorkspace.onto = context.onto
    rebaseWorkspace.actions = context.actions
    rebaseWorkspace.interactive = context.interactive
    rebaseWorkspace.preserveMerges = context.preserveMerges
    rebaseWorkspace.autoSquash = context.autoSquash
    rebaseWorkspace.keepEmpty = context.keepEmpty
    rebaseWorkspace.updateRefs = context.updateRefs
    rebaseWorkspace.root = context.root
    doRebase()
}

}
