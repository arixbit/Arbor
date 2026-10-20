import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
func currentMergeEngineOptions() -> MergeOptions {
    let strategy = MergeStrategyChoice(rawValue: mergeWorkspace.strategyRaw) ?? .automatic
    let message = mergeWorkspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    return MergeOptions(
        mode: mergeEngineMode(for: strategy),
        commitMessage: mergeWorkspace.useCustomCommitMessage && !message.isEmpty ? message : nil,
        noCommit: mergeWorkspace.noCommit,
        noVerify: mergeWorkspace.noVerify,
        allowUnrelatedHistories: mergeWorkspace.allowUnrelatedHistories
    )
}

func doMerge() {
    guard operationRecovery.operation?.kind == nil,
          isArborVCSActionEnabled(.merge, in: vcsActionContext) else { return }
    saveMergeDialogSettings()
    runMerge(preserveLocalChanges: false)
}

func runMerge(preserveLocalChanges: Bool) {
    guard let repo, !mergeWorkspace.branch.isEmpty else { return }
    beginFeedbackOperation("Merge")
    mergeWorkspace.pendingDeleteBranch = nil
    let branch = mergeWorkspace.branch
    let initialHead = repo.headCommitId()
    mergeWorkspace.initialHead = initialHead
    let strategy = MergeStrategyChoice(rawValue: mergeWorkspace.strategyRaw) ?? .automatic
    let commitMessage = mergeWorkspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let noCommit = mergeWorkspace.noCommit
    let noVerify = mergeWorkspace.noVerify
    let allowUnrelatedHistories = mergeWorkspace.allowUnrelatedHistories
    let canDeleteMergedBranch = branchWorkspace.branches.contains {
        $0.name == branch && !$0.isCurrent
    } && !GitProtectedBranchRules.matches(
        branch,
        patterns: effectiveProtectedBranchPatterns
    )
    let deleteOnMerge = GitDeleteOnMergeOption.effectiveOption(
        mergeDeleteOnMergeOption,
        canDeleteBranch: canDeleteMergedBranch
    )
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        do {
            let mergedBranchNames = Set((try? repo.branchListMergedAll().map(\.name)) ?? [])
            if mergeBranchIsAlreadyMerged(branch, mergedBranches: mergedBranchNames) {
                await MainActor.run {
                    self.mergeWorkspace.initialHead = nil
                    self.mergeWorkspace.feedback = "分支已合并，无需再次合并：\(branch)"
                    self.feedbackCenter.warning(
                        "Merge is not needed",
                        detail: "\(branch) is already merged into the current branch.",
                        nextStep: "Choose a branch with unmerged commits."
                    )
                }
                return
            }
            let mode: MergeMode
            switch strategy {
            case .automatic: mode = .fastForward
            case .fastForwardOnly: mode = .fastForwardOnly
            case .noFastForward: mode = .noFastForward
            case .squash: mode = .squash
            }
            let options = MergeOptions(
                mode: mode,
                commitMessage: commitMessage.isEmpty ? nil : commitMessage,
                noCommit: noCommit,
                noVerify: noVerify,
                allowUnrelatedHistories: allowUnrelatedHistories
            )
            let mo = if preserveLocalChanges {
                try repo.mergeWithSettingsAndPolicy(
                    branch: branch,
                    options: options,
                    savePolicy: projectSavePolicy
                )
            } else {
                try repo.mergeWithSettings(branch: branch, options: options)
            }
            let finalHead = repo.headCommitId()
            let st = try repo.status()
            await MainActor.run {
                self.repositoryStatus.entries = st
                self.projectWorkspace.toolWindowMode = .commit
                self.toolWindowExpanded = true
                self.mergeWorkspace.inProgress = mo.requiresFinish
                self.mergeWorkspace.pendingDeleteBranch = mo.requiresFinish ? branch : nil
                self.fileWorkspace.selection = mo.conflicts.first
                self.operationRecovery.showConflictResolver = !mo.conflicts.isEmpty
                if !mo.conflicts.isEmpty {
                    self.mergeWorkspace.feedback = "冲突 \(mo.conflicts.count) 个文件：\(mo.conflicts.joined(separator: ", "))"
                } else if mo.completed {
                    self.mergeWorkspace.feedback = "合并成功（已完成）"
                    let viewCommitsAction = repo.workdir().flatMap { rootPath in
                        self.completedMergeViewCommitsAction(
                            rootPath: rootPath,
                            initialHead: initialHead,
                            finalHead: finalHead,
                            completed: mo.completed
                        )
                    }
                    let viewCommitsActions = viewCommitsAction.map { [$0] } ?? []
                    if deleteOnMerge == .delete {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: branch,
                            additionalActions: viewCommitsActions,
                            notificationGroup: .standard
                        )
                        self.branchDelete(branch)
                    } else if deleteOnMerge == .propose {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: branch,
                            actionTitle: "Delete branch",
                            action: postMergeDeleteAction(repo: repo, branch: branch),
                            additionalActions: viewCommitsActions,
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: branch,
                            additionalActions: viewCommitsActions,
                            notificationGroup: .standard
                        )
                    }
                    self.mergeWorkspace.initialHead = nil
                    self.refreshAll(showFeedback: false)
                } else if mo.squashed {
                    self.mergeWorkspace.feedback = "Squash 合并已应用，点击「完成合并」创建单父提交"
                } else {
                    self.mergeWorkspace.feedback = "合并已应用，点击「完成合并」创建双父提交"
                }
            }
        } catch {
            if case let .LocalChangesWouldBeOverwritten(paths) = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Merge needs a decision",
                        detail: paths.joined(separator: ", "),
                        nextStep: "Choose Smart Merge to preserve local changes, or cancel and keep the current worktree."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Merge",
                        paths: paths,
                        detail: errorMessage(error),
                        smartButtonTitle: "Smart Merge",
                        onSmart: {
                            self.runMerge(preserveLocalChanges: true)
                        }
                    )
                    self.mergeWorkspace.feedback = errorMessage(error)
                }
            } else {
                await MainActor.run {
                    self.mergeWorkspace.initialHead = nil
                    self.mergeWorkspace.feedback = friendlyRemoteError(error)
                    if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
                }
            }
        }
    }
}

func finishMerge() {
    if stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress {
        finishStashConflict()
        return
    }
    guard let repo, mergeWorkspace.inProgress else { return }
    let sourceBranch = mergeWorkspace.pendingDeleteBranch ?? repo.mergeSourceReference()
    let initialHead = mergeWorkspace.initialHead
        ?? (try? repo.revisionCommitId(revision: "ORIG_HEAD"))
    let canProposeDelete = sourceBranch.map {
        canProposeDeleteMergedBranch(
            repo: repo,
            branch: $0,
            protectedPatterns: effectiveProtectedBranchPatterns
        )
    } ?? false
    beginFeedbackOperation("Complete merge")
    Task.detached(priority: .userInitiated) {
        do {
            let commitID = try repo.finishMerge(message: nil)
            let finalHead = repo.headCommitId()
            await MainActor.run {
                self.mergeWorkspace.inProgress = false
                self.mergeWorkspace.pendingDeleteBranch = nil
                self.mergeWorkspace.feedback = "已完成合并 \(String(commitID.prefix(7)))"
                self.operationRecovery.showConflictResolver = false
                let deleteOnMerge = GitDeleteOnMergeOption.effectiveOption(
                    self.mergeDeleteOnMergeOption,
                    canDeleteBranch: canProposeDelete
                )
                let viewCommitsActions = repo.workdir().flatMap { rootPath in
                    self.completedMergeViewCommitsAction(
                        rootPath: rootPath,
                        initialHead: initialHead,
                        finalHead: finalHead,
                        completed: true
                    )
                }.map { [$0] } ?? []
                self.mergeWorkspace.initialHead = nil
                if deleteOnMerge == .delete, let sourceBranch {
                    self.feedbackCenter.success(
                        "Merge completed",
                        detail: sourceBranch,
                        additionalActions: viewCommitsActions,
                        notificationGroup: .standard
                    )
                    self.branchDelete(sourceBranch)
                } else if deleteOnMerge == .propose, let sourceBranch {
                    self.feedbackCenter.success(
                        "Merge completed",
                        detail: sourceBranch,
                        actionTitle: "Delete branch",
                        action: postMergeDeleteAction(repo: repo, branch: sourceBranch),
                        additionalActions: viewCommitsActions,
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.success(
                        "Merge completed",
                        detail: String(commitID.prefix(7)),
                        additionalActions: viewCommitsActions,
                        notificationGroup: .standard
                    )
                }
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.mergeWorkspace.feedback = errorMessage(error)
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Merge",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? [],
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
                        ).map { [$0] } ?? []
                    )
                } else {
                    self.feedbackCenter.error(
                        "Complete merge failed",
                        detail: errorMessage(error),
                        nextStep: "Resolve remaining conflicts, or abort the merge.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? []
                    )
                }
            }
        }
    }
}

/// Roll back a completed merge only when the branch has not moved since the
/// success notification. This prevents an old toast action from undoing a
/// later commit or branch switch.
func rollbackMerge(_ request: MergeRollbackRequest) {
    guard projectWorkspace.repository === request.repo else {
        feedbackCenter.error(
            "Merge rollback unavailable",
            detail: "The repository is no longer the active project.",
            nextStep: "Open the original project window and retry the rollback."
        )
        return
    }
    beginFeedbackOperation("Rollback Merge")
    Task.detached(priority: .userInitiated) {
        do {
            guard request.repo.headCommitId() == request.expectedHead else {
                throw NSError(
                    domain: "Arbor.MergeRollback",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The merge result changed after the notification was created."
                    ]
                )
            }
            guard try request.repo.operationState() == nil else {
                throw NSError(
                    domain: "Arbor.MergeRollback",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Another Git operation is active in this repository."
                    ]
                )
            }
            try request.repo.reset(commitId: request.initialHead, mode: .keep)
            await MainActor.run {
                self.loadRepoData(includeComparisons: false)
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
                self.feedbackCenter.success(
                    "Merge rollback completed",
                    detail: request.branch
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Merge rollback failed",
                    detail: errorMessage(error),
                    nextStep: "No changes were discarded; resolve overlapping local edits or use Reset explicitly."
                )
            }
        }
    }
}

/// 多 root Branches Popup 的 Merge into Current：在目标 root 的当前分支上执行，
/// 冲突状态留在目标 root，由 Git Roots 面板提供 root 定向恢复入口。
func mergeBranchInRoot(rootPath: String, branch: String) {
    beginFeedbackOperation("Merge branch")
    let protectedPatterns = effectiveProtectedBranchPatterns
    let configuredDeleteOnMerge = mergeDeleteOnMergeOption
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let initialHead = rootRepo.headCommitId()
            let localSourceBranch = try? rootRepo.branchList().first {
                $0.name == branch && !$0.isCurrent
            }
            let canDeleteMergedBranch = localSourceBranch != nil
                && !GitProtectedBranchRules.matches(branch, patterns: protectedPatterns)
            let deleteOnMerge = GitDeleteOnMergeOption.effectiveOption(
                configuredDeleteOnMerge,
                canDeleteBranch: canDeleteMergedBranch
            )
            let outcome = try rootRepo.mergeWithSettings(
                branch: branch,
                options: MergeOptions(
                    mode: .fastForward,
                    commitMessage: nil,
                    noCommit: false,
                    noVerify: false,
                    allowUnrelatedHistories: false
                )
            )
            let finalHead = rootRepo.headCommitId()
            await MainActor.run {
                self.loadMultiRoots()
                if outcome.completed {
                    let viewCommitsActions = self.completedMergeViewCommitsAction(
                        rootPath: rootPath,
                        initialHead: initialHead,
                        finalHead: finalHead,
                        completed: outcome.completed
                    ).map { [$0] } ?? []
                    if deleteOnMerge == .delete {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: "\(branch) · \(rootPath)",
                            additionalActions: viewCommitsActions,
                            notificationGroup: .standard
                        )
                        self.deleteBranchInRoot(rootPath: rootPath, name: branch, confirm: false)
                    } else if deleteOnMerge == .propose {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: "\(branch) · \(rootPath)",
                            actionTitle: "Delete branch",
                            action: postMergeDeleteAction(
                                repo: rootRepo,
                                branch: branch,
                                rootPath: rootPath
                            ),
                            additionalActions: viewCommitsActions,
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: "\(branch) · \(rootPath)",
                            additionalActions: viewCommitsActions,
                            notificationGroup: .standard
                        )
                    }
                } else {
                    self.feedbackCenter.warning(
                        "Merge paused",
                        detail: outcome.conflicts.isEmpty
                            ? "\(branch) · \(rootPath): merge result awaits completion"
                            : "\(branch) · \(rootPath): \(outcome.conflicts.count) conflict(s)",
                        nextStep: outcome.conflicts.isEmpty
                            ? "Use Continue in Git Roots to create the merge commit."
                            : "Resolve conflicts in that root, then use Continue or Abort in Git Roots."
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error(
                    "Merge failed",
                    detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the target root status, then retry Merge."
                )
            }
        }
    }
}

}
