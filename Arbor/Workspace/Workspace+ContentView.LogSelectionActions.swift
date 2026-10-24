import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func cherryPickFromLog(_ commit: CommitInfo) {
    cherryPickCommitsFromLog([commit])
}

func revertFromLog(_ commit: CommitInfo) {
    revertCommitsFromLog([commit])
}

/// Drop/Extract operate on a single commit's file selection from the Log
/// Changes browser. The engine preserves local changes around the object-level
/// rewrite, while the UI keeps the destructive action behind the same explicit
/// confirmation used by the reference workflow.
func dropSelectedChangesFromLog(_ commit: CommitInfo, paths: [String]) {
    guard let repo = logRepository(for: commit) else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Drop selected changes?")
    alert.informativeText = String(localized: "The selected files will be removed from \(commit.shortId) and the rewritten history will replace the current branch tip.")
    alert.addButton(withTitle: "Drop Changes")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    beginFeedbackOperation("Drop Selected Changes")
    Task.detached(priority: .userInitiated) {
        do {
            guard let rootPath = repo.workdir(),
                  let initialHead = repo.headCommitId() else {
                throw EngineError.GitOperation(
                    message: "Drop Selected Changes requires a worktree with a current HEAD."
                )
            }
            let expectedBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""
            let outcome = try repo.dropSelectedChanges(commitId: commit.id, paths: paths)
            let undoTarget = LogSelectedChangesUndoTarget(
                repositoryPath: rootPath,
                branch: expectedBranch,
                initialHead: initialHead,
                expectedHead: outcome.headId
            )
            let notificationID = logSelectedChangesUndoNotificationID(
                repositoryPath: rootPath,
                expectedHead: outcome.headId
            )
            await MainActor.run {
                self.commitWorkspace.feedback = "已从 \(commit.shortId) 丢弃 \(paths.count) 个文件变更"
                self.feedbackCenter.success(
                    "Drop Selected Changes",
                    detail: commit.shortId,
                    additionalActions: [logSelectedChangesUndoFeedbackAction(for: undoTarget)],
                    notificationID: notificationID
                )
                self.logSelectionState.selection = nil
                let isCurrentRoot = self.repo?.workdir().map {
                    logSelectedChangesRootPathsMatch(rootPath, $0)
                } == true
                if isCurrentRoot {
                    self.refreshAll(showFeedback: false)
                    self.loadLog()
                } else {
                    self.loadMultiRoots {
                        let activeRootMatches = self.logList.activeRootPath.map {
                            logSelectedChangesRootPathsMatch(rootPath, $0)
                        } == true
                        if self.isLogAggregate || self.logList.viewMode == .command || activeRootMatches {
                            self.reloadLogView()
                        }
                    }
                }
            }
        } catch {
            let failedRootPath = repo.workdir() ?? ""
            await MainActor.run {
                self.feedbackCenter.error(
                    "Drop Selected Changes failed",
                    detail: errorMessage(error),
                    nextStep: "本操作会保存并恢复本地修改；若恢复冲突，请先处理冲突或使用保留的临时 stash。目标须在当前分支 first-parent 历史中；merge 目标及其后继 merge 会保留 parent 拓扑并按 first-parent 变更重放，无法安全重放时会拒绝改写。rename 会按旧路径和新路径成对处理，submodule gitlink 会按子模块边界同步。"
                )
                self.presentLogSelectedChangesRestoreConflict(rootPath: failedRootPath)
            }
        }
    }
}

func extractSelectedChangesFromLog(_ commit: CommitInfo, paths: [String]) {
    guard let repo = logRepository(for: commit) else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Extract selected changes")
    alert.informativeText = String(localized: "The selected files will become a new commit after \(commit.shortId).")
    let messageField = NSTextField(string: commit.summary)
    messageField.placeholderString = "New commit message"
    messageField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
    alert.accessoryView = messageField
    alert.addButton(withTitle: "Extract Changes")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        feedbackCenter.warning(
            "Extract Selected Changes cancelled",
            detail: "A non-empty commit message is required.",
            nextStep: "Run the action again and enter a commit message."
        )
        return
    }

    beginFeedbackOperation("Extract Selected Changes")
    Task.detached(priority: .userInitiated) {
        do {
            guard let rootPath = repo.workdir(),
                  let initialHead = repo.headCommitId() else {
                throw EngineError.GitOperation(
                    message: "Extract Selected Changes requires a worktree with a current HEAD."
                )
            }
            let expectedBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""
            let outcome = try repo.extractSelectedChanges(
                commitId: commit.id,
                paths: paths,
                newMessage: message
            )
            let undoTarget = LogSelectedChangesUndoTarget(
                repositoryPath: rootPath,
                branch: expectedBranch,
                initialHead: initialHead,
                expectedHead: outcome.headId
            )
            let notificationID = logSelectedChangesUndoNotificationID(
                repositoryPath: rootPath,
                expectedHead: outcome.headId
            )
            await MainActor.run {
                self.commitWorkspace.feedback = "已将 \(paths.count) 个文件变更抽取为新提交"
                self.feedbackCenter.success(
                    "Extract Selected Changes",
                    detail: message,
                    additionalActions: [logSelectedChangesUndoFeedbackAction(for: undoTarget)],
                    notificationID: notificationID
                )
                self.logSelectionState.selection = nil
                let isCurrentRoot = self.repo?.workdir().map {
                    logSelectedChangesRootPathsMatch(rootPath, $0)
                } == true
                if isCurrentRoot {
                    self.refreshAll(showFeedback: false)
                    self.loadLog()
                } else {
                    self.loadMultiRoots {
                        let activeRootMatches = self.logList.activeRootPath.map {
                            logSelectedChangesRootPathsMatch(rootPath, $0)
                        } == true
                        if self.isLogAggregate || self.logList.viewMode == .command || activeRootMatches {
                            self.reloadLogView()
                        }
                    }
                }
            }
        } catch {
            let failedRootPath = repo.workdir() ?? ""
            await MainActor.run {
                self.feedbackCenter.error(
                    "Extract Selected Changes failed",
                    detail: errorMessage(error),
                    nextStep: "本操作会保存并恢复本地修改；若恢复冲突，请先处理冲突或使用保留的临时 stash。目标须在当前分支 first-parent 历史中；merge 目标及其后继 merge 会保留 parent 拓扑并按 first-parent 变更重放，无法安全重放时会拒绝改写。rename 会按旧路径和新路径成对处理，submodule gitlink 会按子模块边界同步。"
                )
                self.presentLogSelectedChangesRestoreConflict(rootPath: failedRootPath)
            }
        }
    }
}

func resetFromLog(_ commit: CommitInfo) {
    resetFromLog([commit])
}

/// IntelliJ's VCS log reset action accepts at most one selected revision per
/// Git root. Keep the selection root-qualified before presenting the mode
/// dialog, so aggregate Log cannot accidentally reset every root to the first
/// selected repository's object.
func resetFromLog(_ commits: [CommitInfo]) {
    let commits = commits.filter { logRepository(for: $0) != nil }
    guard isResetSelectionAvailable(for: commits) else {
        feedbackCenter.warning(
            "Reset unavailable",
            detail: "Select at most one revision per Git root.",
            nextStep: "Choose one commit in each repository and retry."
        )
        return
    }
    guard let first = commits.first else { return }
    resetWorkspace.targetCommits = commits
    resetWorkspace.targetCommit = first
    resetWorkspace.mode = GitResetModeSettings.mode(for: projectWorkspace.path).engineValue
    resetWorkspace.showDialog = true
}

/// Reword the current HEAD without changing its tree or consuming staged files.
func submitLogHeadReword() {
    guard let repo = logRepository, let commit = logRewrite.rewordCommit else { return }
    let message = logRewrite.rewordMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        feedbackCenter.warning(
            "Commit message required",
            detail: "A reworded commit must keep a non-empty message.",
            nextStep: "Enter a commit title and retry."
        )
        return
    }
    if logRewrite.rewordUsesRootRebase {
        logRewrite.showRewordDialog = false
        let cancel = GitCancelHandle()
        beginFeedbackOperation("Reword Root History", cancelHandle: cancel)
        let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
        Task.detached(priority: .userInitiated) {
            do {
                guard let rootPath = repo.workdir(),
                      let initialHeadID = repo.headCommitId() else {
                    throw EngineError.GitOperation(
                        message: "Reword undo requires a worktree repository with a HEAD."
                    )
                }
                let expectedBranch = try repo.branchList()
                    .first(where: { $0.isCurrent })?.name ?? ""
                // A merge descendant must be rewritten through the native
                // merge-preserving todo. The linear object-level path remains
                // the smaller/faster path when the root history has no merges.
                let outcome: RebaseOutcome
                let mergePreservingTodo = try repo.rebaseRootTodo(
                    autoSquash: false,
                    preserveMerges: true
                )
                if mergePreservingTodo.items.contains(where: { $0.isMergeCommit }) {
                    guard let todo = preparedRootRewordTodo(
                        mergePreservingTodo,
                        rootCommitID: commit.id,
                        message: message
                    ) else {
                        throw NSError(
                            domain: "Arbor.Git",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "The selected root commit is not in the current root rebase range."
                            ]
                        )
                    }
                    outcome = try repo.rebaseRootWithTodoAndPolicyAndCancel(
                        todo: todo,
                        preserveMerges: true,
                        savePolicy: projectSavePolicy,
                        cancel: cancel
                    )
                } else {
                    outcome = try repo.rewordRootCommit(commitId: commit.id, message: message)
                }
                let undoContext = PersistedRewordUndo(
                    initialHeadID: initialHeadID,
                    expectedHeadID: outcome.headId,
                    expectedBranch: expectedBranch
                )
                await MainActor.run {
                    self.logRewrite.rewordCommit = nil
                    self.logRewrite.rewordUsesRootRebase = false
                    self.feedbackCenter.expire(
                        notificationID: self.commitNotificationID(rootPath: rootPath)
                    )
                    self.feedbackCenter.success(
                        "Root commit reworded",
                        detail: String(outcome.headId.prefix(7)),
                        additionalActions: [
                            self.rewordUndoFeedbackAction(
                                rootPath: rootPath,
                                context: undoContext
                            )
                        ],
                        notificationID: self.rewordUndoNotificationID(
                            rootPath: rootPath,
                            expectedHeadID: outcome.headId
                        )
                    )
                    self.refreshAll(showFeedback: false)
                    self.loadLog()
                }
            } catch {
                if case .Cancelled = error as? EngineError {
                    await MainActor.run {
                        self.logRewrite.showRewordDialog = true
                        self.operationRecovery.feedback = "Root reword cancelled; saved local changes were restored"
                        self.feedbackCenter.warning(
                            "Root reword cancelled",
                            detail: self.operationRecovery.feedback ?? "Saved local changes were restored",
                            nextStep: "Review Saved Changes or Stash, then retry the root reword."
                        )
                    }
                    return
                }
                await MainActor.run {
                    // Keep the draft available so repository-state or todo
                    // mapping errors can be reviewed and retried.
                    self.logRewrite.showRewordDialog = true
                    self.feedbackCenter.error(
                        "Root commit reword failed",
                        detail: errorMessage(error),
                        nextStep: "Resolve the repository state, then retry the root reword.",
                        localized: true
                    )
                }
            }
        }
        return
    }
    guard commit.isHead else {
        logRewrite.showRewordDialog = false
        logRewrite.rewordCommit = nil
        logRewrite.rewordUsesRootRebase = false
        return
    }
    logRewrite.showRewordDialog = false
    beginFeedbackOperation("Reword HEAD")
    Task.detached(priority: .userInitiated) {
        do {
            guard let rootPath = repo.workdir(),
                  let initialHeadID = repo.headCommitId() else {
                throw EngineError.GitOperation(
                    message: "Reword undo requires a worktree repository with a HEAD."
                )
            }
            let expectedBranch = try repo.branchList()
                .first(where: { $0.isCurrent })?.name ?? ""
            let id = try repo.rewordHead(message: message, skipHooks: true)
            let undoContext = PersistedRewordUndo(
                initialHeadID: initialHeadID,
                expectedHeadID: id,
                expectedBranch: expectedBranch
            )
            await MainActor.run {
                self.logRewrite.rewordCommit = nil
                self.logRewrite.rewordUsesRootRebase = false
                self.feedbackCenter.expire(
                    notificationID: self.commitNotificationID(rootPath: rootPath)
                )
                self.feedbackCenter.success(
                    "Commit reworded",
                    detail: String(id.prefix(7)),
                    additionalActions: [
                        self.rewordUndoFeedbackAction(
                            rootPath: rootPath,
                            context: undoContext
                        )
                    ],
                    notificationID: self.rewordUndoNotificationID(
                        rootPath: rootPath,
                        expectedHeadID: id
                    )
                )
                self.refreshAll(showFeedback: false)
                self.loadLog()
            }
        } catch {
            await MainActor.run {
                // Keep the draft available so a hook/index/permission error can
                // be reviewed and retried without rebuilding the message.
                self.logRewrite.showRewordDialog = true
                self.feedbackCenter.error(
                    "Reword HEAD failed",
                    detail: errorMessage(error),
                    nextStep: "The commit message was not changed; review the error and retry."
                )
            }
        }
    }
}

nonisolated func logSelectedChangesRootPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
    URL(fileURLWithPath: lhs).standardizedFileURL.path
        == URL(fileURLWithPath: rhs).standardizedFileURL.path
}

func logSelectedChangesUndoRequest(
    for target: LogSelectedChangesUndoTarget
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .undoLogSelectedChanges,
        projectPath: projectWorkspace.path,
        rootPath: target.repositoryPath,
        shelfName: "",
        logSelectedChangesUndoInitialHead: target.initialHead,
        logSelectedChangesUndoExpectedHead: target.expectedHead,
        logSelectedChangesUndoBranch: target.branch
    )
}

/// Undo a completed Drop/Extract history rewrite only while its exact branch
/// tip is still checked out. The engine uses reset --keep, so local changes
/// made after the rewrite survive when they do not overlap the restored tree.
func undoLogSelectedChanges(_ target: LogSelectedChangesUndoTarget) {
    let notificationID = logSelectedChangesUndoNotificationID(
        repositoryPath: target.repositoryPath,
        expectedHead: target.expectedHead
    )
    let protectedPatterns = effectiveProtectedBranchPatterns
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Undo Selected Changes", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let targetRepo = try openRepository(path: target.repositoryPath)
            guard try targetRepo.operationState() == nil else {
                throw EngineError.GitOperation(
                    message: "Undo Selected Changes is unavailable while another Git operation is active."
                )
            }
            guard targetRepo.headCommitId() == target.expectedHead else {
                throw EngineError.GitOperation(
                    message: "Undo Selected Changes refused: HEAD changed after the rewrite."
                )
            }
            let currentBranch = try targetRepo.branchList()
                .first(where: { $0.isCurrent })?.name ?? ""
            guard currentBranch == target.branch else {
                throw EngineError.GitOperation(
                    message: "Undo Selected Changes refused: the current branch changed after the rewrite."
                )
            }
            let remoteBranches = try targetRepo.remoteBranchList()
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: targetRepo,
                commitID: target.initialHead,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                throw EngineError.GitOperation(
                    message: "Undo Selected Changes blocked: \(protectedBranch) contains published pre-rewrite history."
                )
            }
            try targetRepo.undoLogSelectedChangesExpectedHead(
                initialCommitId: target.initialHead,
                expectedHead: target.expectedHead,
                expectedBranch: target.branch,
                savePolicy: projectSavePolicy
            )
            await MainActor.run {
                self.feedbackCenter.expire(notificationID: notificationID)
                self.feedbackCenter.success(
                    "Selected Changes rewrite undone",
                    detail: "HEAD restored to \(String(target.initialHead.prefix(8)))."
                )
                let isCurrentRoot = self.repo?.workdir().map {
                    logSelectedChangesRootPathsMatch(target.repositoryPath, $0)
                } == true
                if isCurrentRoot {
                    self.refreshAll(showFeedback: false)
                    self.loadLog()
                } else {
                    self.loadMultiRoots {
                        let activeRootMatches = self.logList.activeRootPath.map {
                            logSelectedChangesRootPathsMatch(target.repositoryPath, $0)
                        } == true
                        if self.isLogAggregate || self.logList.viewMode == .command || activeRootMatches {
                            self.reloadLogView()
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Selected Changes failed",
                    detail: errorMessage(error),
                    nextStep: "The repository may have changed after Drop/Extract; inspect the current Log before retrying.",
                    notificationID: notificationID
                )
            }
        }
    }
}

}
