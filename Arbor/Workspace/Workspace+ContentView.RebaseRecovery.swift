import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Route a persisted rebase action back to the root-scoped recovery workbench.
/// The actual Continue/Abort command re-reads Git's operation state, so a
/// notification response cannot replay an obsolete command line.
func openPersistedRebaseRecovery(rootPath: String, branch: String? = nil) {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    guard let seed = loadRebaseUndoSeed(repositoryPath: normalizedRoot) else { return }
    rebaseWorkspace.undoSeed = seed
    rebaseWorkspace.rootPath = normalizedRoot
    rebaseWorkspace.branch = branch ?? seed.branch
    rebaseWorkspace.paused = true
    if let persistedRepo = try? openRepository(path: normalizedRoot) {
        let persistedState = try? persistedRepo.operationState()
        operationRecovery.operation = persistedState
        rebaseWorkspace.pauseReason = persistedState?.conflictedFiles.isEmpty == false ? .conflict : .edit
        rebaseWorkspace.conflicts = persistedState?.conflictedFiles ?? []
    }
    openMultiRootConflictResolver(preferredRootPath: normalizedRoot)
    if repo?.workdir() == normalizedRoot {
        loadRepoData()
    }
}

func persistedRebaseRecoveryAction(rootPath: String, branch: String) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .resumeRebase,
        projectPath: projectWorkspace.path ?? rootPath,
        rootPath: rootPath,
        shelfName: "",
        rebaseBranch: branch
    )
    return FeedbackAction(
        title: "Open Rebase Recovery",
        semanticAction: request
    ) {
        self.openPersistedRebaseRecovery(rootPath: rootPath, branch: branch)
    }
}

enum UpdateRebaseOverMergeDecision: Sendable, Equatable {
    case mergeInstead
    case rebaseAnyway
    case cancel
}

/// IntelliJ's Update Project guard: only roots whose local range contains a
/// non-empty merge commit are called out, and the user can substitute merge
/// for those roots without changing the selected rebase method elsewhere.
func presentUpdateRebaseOverMergeDialog(
    problematicRoots: [GitRootInfo]
) -> UpdateRebaseOverMergeDecision {
    let alert = NSAlert()
    alert.messageText = "Rebase would replay merge commits"
    let roots = problematicRoots
        .map { "• \($0.displayName) (\($0.relativePath))" }
        .joined(separator: "\n")
    alert.informativeText = "The following Git roots contain merge commits with file changes in the range that would be rebased:\n\n\(roots)\n\nMerging those roots preserves their merge history."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Merge Instead")
    alert.addButton(withTitle: "Rebase Anyway")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        return .mergeInstead
    case .alertSecondButtonReturn:
        return .rebaseAnyway
    default:
        return .cancel
    }
}

func makeMultiRootRebaseRecoveryRequest(
    _ action: ArborVCSActionRequest.MultiRootRebaseRecoveryAction,
    rootPath: String? = nil,
    sessionID: UUID? = nil,
    rollbackTargets: [MultiRootRebaseRollbackTarget]? = nil
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .multiRootRebaseRecovery,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        multiRootRebaseRecoveryAction: action,
        multiRootRebaseSessionID: sessionID?.uuidString,
        multiRootRebaseRollbackTargets: rollbackTargets?.map(PersistedMultiRootRebaseRollbackTarget.init)
    )
}

func multiRootRebaseRecoveryFeedbackAction(
    _ action: ArborVCSActionRequest.MultiRootRebaseRecoveryAction,
    rootPath: String? = nil,
    sessionID: UUID? = nil,
    rollbackTargets: [MultiRootRebaseRollbackTarget]? = nil
) -> FeedbackAction {
    let request = makeMultiRootRebaseRecoveryRequest(
        action,
        rootPath: rootPath,
        sessionID: sessionID,
        rollbackTargets: rollbackTargets
    )
    let title: String
    switch action {
    case .resume:
        title = "Resume Rebase"
    case .retry:
        title = "Retry Rebase"
    case .stageAndRetry:
        title = "Stage-and-Retry"
    case .openRecovery:
        title = "Open Recovery"
    case .rollback:
        title = "Rollback Rebase"
    case .keepPartial:
        title = "Keep Partial Rebase"
    case .undo:
        title = "Undo Rebase"
    }
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootRebaseNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-rebase.\(stableProject)"
}

/// IntelliJ 的多 root Branches Popup 语义：非当前本地分支 rebase 到当前分支，
/// 而不是 checkout 后 pull 该分支自己的 upstream。远程分支需先检出为本地分支。
func executeMultiRootCheckoutWithRebase(rootPath: String, branch: String) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.warning("Checkout with Rebase cancelled", detail: "A local branch is required.")
        return
    }
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Checkout with Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        let rootRepo: Repository
        do {
            rootRepo = try openRepository(path: rootPath)
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Checkout with Rebase failed",
                    detail: "\(branch): \(errorMessage(error))",
                    nextStep: "Resolve the selected root's status, then retry Checkout with Rebase."
                )
            }
            return
        }
        let currentBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name
        let seed = makeRebaseUndoSeed(repo: rootRepo, branch: branch, onto: currentBranch)
        if let seed {
            saveRebaseUndoSeed(seed)
        }
        do {
            try rootRepo.rebaseBranchOnCurrentWithPolicyAndCancel(
                branch: branch,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                if let seed {
                    clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    if self.repo?.workdir() == seed.repositoryPath {
                        self.rebaseWorkspace.undoSeed = nil
                    }
                }
                self.feedbackCenter.success("Checked out and rebased", detail: branch)
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Checkout with Rebase cancelled",
                        detail: "The saved local scene for \(branch) was not discarded.",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: rootRepo,
                            rootPath: rootPath
                        ).map { [$0] } ?? []
                    )
                }
                return
            }
            let state = try? rootRepo.operationState()
            await MainActor.run {
                self.operationRecovery.viewMode = .roots
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                if state?.kind == .rebase {
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.feedbackCenter.warning(
                        "Checkout with Rebase paused",
                        detail: "\(branch): \(errorMessage(error))",
                        nextStep: "Resolve the selected root's rebase, then continue or abort it.",
                        additionalActions: [
                            seed.map {
                                persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)
                            },
                            self.pendingSavedChangesFeedbackAction(
                                repo: rootRepo,
                                rootPath: rootPath
                            )
                        ].compactMap { $0 },
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    if let seed {
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    self.feedbackCenter.error(
                        "Checkout with Rebase failed",
                        detail: "\(branch): \(errorMessage(error))",
                        nextStep: "Resolve the selected root's status, then retry Checkout with Rebase.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: rootRepo,
                            rootPath: rootPath
                        ).map { [$0] } ?? []
                    )
                }
                self.loadMultiRoots()
            }
        }
    }
}

func stageAndRetryMultiRootRebaseContinue(rootPath: String, sessionID: UUID) {
    guard rebaseWorkspace.multiRootSession?.id == sessionID else { return }
    runMultiRootResolverRecovery(
        rootPath: rootPath,
        action: .continueOperation,
        stageTrackedBeforeContinue: true
    )
}

/// Undo only a completed single-root rebase whose target branch still points
/// at the exact HEAD produced by that operation.  This is the same safety
/// boundary as IntelliJ's notification actions: a later fetch, commit, push,
/// branch switch, active Git operation, or protected-remote publication
/// invalidates the action.
func undoLastRebase(_ requestedTarget: RebaseUndoTarget? = nil) {
    guard let target = requestedTarget ?? rebaseWorkspace.undoTarget else { return }
    let protectedPatterns = effectiveProtectedBranchPatterns
    let notificationID = rebaseUndoNotificationID(repositoryPath: target.repositoryPath)
    beginFeedbackOperation("Undo Rebase", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo = try openRepository(path: target.repositoryPath)
            guard try selectedRepo.operationState() == nil else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The rebase Undo action is unavailable while another Git operation is active."
                    ]
                )
            }
            let currentBranch = (try selectedRepo.branchList()).first(where: { $0.isCurrent })?.name
            guard currentBranch == target.branch,
                  try selectedRepo.revisionCommitId(revision: target.branch) == target.expectedHead else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The branch changed after the rebase; the Undo action is no longer safe."
                    ]
                )
            }
            let remoteBranches = try selectedRepo.remoteBranchList()
            let protectedCommitID = rebaseUndoProtectionCommit(
                repo: selectedRepo,
                initialHead: target.initialHead,
                expectedHead: target.expectedHead,
                recordedCommitID: target.protectionCommitID
            )
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: selectedRepo,
                commitID: protectedCommitID,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The rebase Undo action is blocked: \(protectedBranch) contains published pre-rebase history."
                    ]
                )
            }
            try selectedRepo.reset(commitId: target.initialHead, mode: .keep)
            await MainActor.run {
                self.feedbackCenter.expire(notificationID: notificationID)
                if self.rebaseWorkspace.undoTarget?.expectedHead == target.expectedHead {
                    self.rebaseWorkspace.undoTarget = nil
                }
                clearRebaseUndoSeed(repositoryPath: target.repositoryPath)
                self.feedbackCenter.success(
                    "Rebase undone",
                    detail: target.branch + " restored to " + String(target.initialHead.prefix(7))
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Rebase failed",
                    detail: errorMessage(error),
                    nextStep: "The branch or published history may have changed; inspect the Log before trying another reset.",
                    notificationID: notificationID
                )
            }
        }
    }
}

func doRebaseContinue() {
    guard let repo else { return }
    beginFeedbackOperation("Continue rebase")
    let seed = rebaseWorkspace.undoSeed
    let selectedRootPath = rebaseWorkspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = seed?.repositoryPath ?? selectedRootPath
    let currentRepositoryPath = repo.workdir() ?? ""
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            let outcome = try selectedRepo.rebaseContinue()
            let st = try selectedRepo.status()
            let currentBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let finalHead = seed.flatMap { try? selectedRepo.revisionCommitId(revision: $0.branch) }
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    self.repositoryStatus.entries = st
                }
                self.rebaseWorkspace.paused = outcome.paused
                self.rebaseWorkspace.pauseReason = outcome.pauseReason
                self.rebaseWorkspace.conflicts = outcome.conflicts
                if outcome.paused, outcome.pauseReason == .conflict {
                    let names = outcome.conflicts.prefix(3).joined(separator: "、")
                    let suffix = names.isEmpty ? "" : "：\(names)"
                    self.rebaseWorkspace.feedback = "再次冲突 \(outcome.conflicts.count) 个文件\(suffix)"
                    self.rebaseWorkspace.undoSeed = seed
                    self.rebaseWorkspace.undoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.operationRecovery.showConflictResolver = true
                } else {
                    self.rebaseWorkspace.feedback = outcome.paused ? "再次暂停在 edit 提交" : "变基完成"
                    if !outcome.paused {
                        self.operationRecovery.showConflictResolver = false
                        self.rebaseWorkspace.undoSeed = nil
                        self.rebaseWorkspace.undoTarget = undoTarget
                        if let seed {
                            clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                        }
                        if let undoTarget {
                            self.feedbackCenter.success(
                                "Rebase completed",
                                detail: String(outcome.headId.prefix(7)),
                                additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                                notificationID: rebaseUndoNotificationID(repositoryPath: undoTarget.repositoryPath),
                                notificationGroup: .standard
                            )
                        } else {
                            self.feedbackCenter.success(
                                "Rebase completed",
                                detail: String(outcome.headId.prefix(7))
                            )
                        }
                    } else {
                        self.rebaseWorkspace.undoSeed = seed
                        self.rebaseWorkspace.undoTarget = nil
                        if let seed {
                            saveRebaseUndoSeed(seed)
                        }
                    }
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            let recoveryRepository: Repository?
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                recoveryRepository = repo
            } else {
                recoveryRepository = try? openRepository(path: repositoryPath)
            }
            let canStageAndRetry: Bool
            if let recoveryRepository {
                canStageAndRetry = (try? recoveryRepository.status().contains {
                    $0.unstaged != .unchanged
                        && $0.unstaged != .untracked
                        && $0.unstaged != .ignored
                        && $0.unstaged != .conflicted
                }) ?? false
            } else {
                canStageAndRetry = false
            }
            await MainActor.run {
                self.rebaseWorkspace.feedback = detail
                self.feedbackCenter.error(
                    "Rebase continue failed",
                    detail: detail,
                    nextStep: "Resolve remaining conflicts or stage tracked changes before continuing.",
                    actionTitle: canStageAndRetry ? "Stage-and-Retry" : nil,
                    action: canStageAndRetry ? { self.stageAndRetryRebaseContinue() } : nil
                )
            }
        }
    }
}

func stageAndRetryRebaseContinue() {
    guard let repo else { return }
    beginFeedbackOperation("Stage-and-Retry Rebase")
    let seed = rebaseWorkspace.undoSeed
    let selectedRootPath = rebaseWorkspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = seed?.repositoryPath ?? selectedRootPath
    let currentRepositoryPath = repo.workdir() ?? ""
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            try selectedRepo.stageTracked()
            let outcome = try selectedRepo.rebaseContinue()
            let st = try selectedRepo.status()
            let currentBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let finalHead = seed.flatMap { try? selectedRepo.revisionCommitId(revision: $0.branch) }
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    self.repositoryStatus.entries = st
                }
                self.rebaseWorkspace.paused = outcome.paused
                self.rebaseWorkspace.pauseReason = outcome.pauseReason
                self.rebaseWorkspace.conflicts = outcome.conflicts
                self.rebaseWorkspace.feedback = outcome.paused
                    ? "Rebase 继续后再次暂停"
                    : "Rebase 完成"
                if !outcome.paused {
                    self.operationRecovery.showConflictResolver = false
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = undoTarget
                    if let seed {
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase continued",
                            detail: String(outcome.headId.prefix(7)),
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(repositoryPath: undoTarget.repositoryPath),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Rebase continued",
                            detail: String(outcome.headId.prefix(7))
                        )
                    }
                } else if outcome.pauseReason == .conflict {
                    self.rebaseWorkspace.undoSeed = seed
                    self.rebaseWorkspace.undoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.operationRecovery.showConflictResolver = true
                } else {
                    self.rebaseWorkspace.undoSeed = seed
                    self.rebaseWorkspace.undoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Stage-and-Retry failed",
                    detail: errorMessage(error),
                    nextStep: "Review tracked and conflicted files, then continue or abort the rebase."
                )
            }
        }
    }
}

func doRebaseAbort() {
    guard let repo else { return }
    let repositoryPath = rebaseWorkspace.undoSeed?.repositoryPath ?? repo.workdir() ?? ""
    beginFeedbackOperation("Abort rebase")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.rebaseAbort()
            let st = try repo.status()
            await MainActor.run {
                self.repositoryStatus.entries = st
                self.rebaseWorkspace.paused = false
                self.rebaseWorkspace.pauseReason = nil
                self.rebaseWorkspace.conflicts = []
                self.rebaseWorkspace.undoSeed = nil
                self.rebaseWorkspace.undoTarget = nil
                clearRebaseUndoSeed(repositoryPath: repositoryPath)
                self.rebaseWorkspace.feedback = "已中止变基"
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch { await MainActor.run { self.rebaseWorkspace.feedback = "\(error)" } }
    }
}

}
