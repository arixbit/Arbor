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

func presentMultiRootMergeDialog(name: String) {
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let eligible = multiRootWorkspace.branchSnapshots.filter { snapshot in
        snapshot.branches.contains { $0.name == branchName }
    }
    guard !branchName.isEmpty, !eligible.isEmpty else {
        feedbackCenter.warning(
            "Merge branch unavailable",
            detail: "No Git root contains " + branchName + "."
        )
        return
    }
    mergeWorkspace.multiRootBranchName = branchName
    mergeWorkspace.multiRootSelectedRootPaths = Set(eligible.map(\.rootPath))
    mergeWorkspace.multiRootMergedBranchesByRoot = [:]
    mergeWorkspace.multiRootDialogGeneration &+= 1
    let generation = mergeWorkspace.multiRootDialogGeneration
    mergeWorkspace.showMultiRootDialog = true
    let rootPaths = eligible.map(\.rootPath)
    Task.detached(priority: .userInitiated) {
        var mergedBranchesByRoot: [String: Set<String>] = [:]
        for rootPath in rootPaths {
            guard let rootRepo = try? openRepository(path: rootPath),
                  let mergedBranches = try? rootRepo.branchListMergedAll() else {
                continue
            }
            mergedBranchesByRoot[rootPath] = Set(mergedBranches.map(\.name))
        }
        let loadedMergedBranchesByRoot = mergedBranchesByRoot
        await MainActor.run {
            guard generation == self.mergeWorkspace.multiRootDialogGeneration else { return }
            let alreadyMergedRootPaths = Set(
                loadedMergedBranchesByRoot.compactMap { rootPath, mergedBranches in
                    mergeBranchIsAlreadyMerged(branchName, mergedBranches: mergedBranches)
                        ? rootPath
                        : nil
                }
            )
            self.mergeWorkspace.multiRootMergedBranchesByRoot = loadedMergedBranchesByRoot
            self.mergeWorkspace.multiRootSelectedRootPaths.subtract(alreadyMergedRootPaths)
        }
    }
}

func presentMultiRootMergeFromPopup(name: String) {
    presentMultiRootMergeDialog(name: name)
    branchWorkspace.showPopover = false
}

func dismissMultiRootMergeDialog() {
    mergeWorkspace.multiRootDialogGeneration &+= 1
    mergeWorkspace.showMultiRootDialog = false
    mergeWorkspace.multiRootBranchName = ""
    mergeWorkspace.multiRootSelectedRootPaths = []
    mergeWorkspace.multiRootMergedBranchesByRoot = [:]
}

func startMultiRootMergeFromDialog() {
    let actionableRootPaths = mergeWorkspace.multiRootSelectedRootPaths.filter { rootPath in
        guard let mergedBranches = mergeWorkspace.multiRootMergedBranchesByRoot[rootPath] else {
            return true
        }
        return !mergeBranchIsAlreadyMerged(
            mergeWorkspace.multiRootBranchName,
            mergedBranches: mergedBranches
        )
    }
    mergeWorkspace.multiRootSelectedRootPaths = actionableRootPaths
    guard !actionableRootPaths.isEmpty else {
        feedbackCenter.warning(
            "Merge is not needed",
            detail: "The selected branch is already merged in every selected repository."
        )
        return
    }
    saveMergeDialogSettings()
    mergeMultiRootBranch(
        name: mergeWorkspace.multiRootBranchName,
        selectedRootPaths: actionableRootPaths,
        options: currentMergeEngineOptions()
    )
}

func dismissMultiRootMergeRollback() {
    mergeWorkspace.multiRootRollbackContext = nil
    if let notificationID = multiRootMergeRollbackNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
}

func keepMultiRootMergePartial(_ context: MultiRootMergeRollbackContext) {
    mergeWorkspace.multiRootRollbackContext = nil
    let pendingRootPath = context.targets.first(where: { $0.operationPending })?.rootPath
        ?? context.pendingRootPath
    feedbackCenter.warning(
        "Partial merge kept",
        detail: context.branchName,
        nextStep: pendingRootPath == nil
            ? "Review the successful repositories in Git Roots."
            : "Resolve the pending merge in the affected Git root.",
        notificationID: multiRootMergeRollbackNotificationID(),
        notificationGroup: .standard
    )
    if let pendingRootPath {
        openMultiRootConflictResolver(preferredRootPath: pendingRootPath)
    }
}

/// Merge one local branch in the selected Git roots using IntelliJ's
/// repository-operation sequencing: conflicts are retained and the next root
/// is attempted, while a fatal failure marks all later roots as skipped.
func mergeMultiRootBranch(
    name: String,
    selectedRootPaths: Set<String>,
    options: MergeOptions? = nil
) {
    runMultiRootMergeOperation(
        name: name,
        selectedRootPaths: selectedRootPaths,
        options: options ?? currentMergeEngineOptions(),
        preserveLocalChanges: false
    )
}

func runMultiRootMergeOperation(
    name: String,
    selectedRootPaths: Set<String>,
    options: MergeOptions,
    preserveLocalChanges: Bool,
    rootOrder: [String]? = nil,
    preservedResults: [MultiRootMergeResult] = []
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains { $0.name == branchName }
    }
    guard !branchName.isEmpty, !roots.isEmpty, let projectPath = projectWorkspace.path else { return }

    let canDeleteMergedBranch = roots.allSatisfy { snapshot in
        !snapshot.branches.contains { $0.name == branchName && $0.isCurrent }
    } && !GitProtectedBranchRules.matches(
        branchName,
        patterns: effectiveProtectedBranchPatterns
    )
    let deleteOnMerge = GitDeleteOnMergeOption.effectiveOption(
        mergeDeleteOnMergeOption,
        canDeleteBranch: canDeleteMergedBranch
    )
    let mergeRootPaths = roots.map(\.rootPath)
    let resultRootOrder = rootOrder ?? (
        mergeRootPaths + preservedResults
            .map(\.rootPath)
            .filter { !mergeRootPaths.contains($0) }
    )
    let allMergeRootPaths = rootOrder ?? mergeRootPaths
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    multiRootWorkspace.running = true
    beginFeedbackOperation(
        "Multi-root merge",
        notificationID: multiRootMergeNotificationID()
    )
    Task.detached(priority: .userInitiated) {
        do {
            let results: [MultiRootMergeResult]
            if preserveLocalChanges {
                results = try runMultiRootMergeWithPolicy(
                    scanRoot: projectPath,
                    selectedRootPaths: roots.map(\.rootPath),
                    branch: branchName,
                    options: options,
                    savePolicy: projectSavePolicy
                )
            } else {
                results = try runMultiRootMerge(
                    scanRoot: projectPath,
                    selectedRootPaths: roots.map(\.rootPath),
                    branch: branchName,
                    options: options
                )
            }
            let combinedResults = mergeMultiRootMergeResults(
                preserved: preservedResults,
                retry: results,
                rootOrder: resultRootOrder
            )
            let operationResults = combinedResults.map { result in
                RootOperationResult(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    success: result.success,
                    skipped: result.skipped,
                    message: result.message
                )
            }
            let rollbackTargets = combinedResults.compactMap { result -> MultiRootMergeRollbackTarget? in
                guard result.success, !result.skipped,
                      let initialHead = result.initialHead,
                      let expectedHead = result.finalHead,
                      result.requiresFinish || !result.conflicts.isEmpty || initialHead != expectedHead else {
                    return nil
                }
                return MultiRootMergeRollbackTarget(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    initialHead: initialHead,
                    expectedHead: expectedHead,
                    operationPending: result.requiresFinish || !result.conflicts.isEmpty
                )
            }
            let conflicts = combinedResults.filter { $0.success && !$0.skipped && !$0.conflicts.isEmpty }
            let failures = combinedResults.filter { !$0.success || $0.skipped }
            let overwriteFailures = combinedResults.filter {
                !$0.success && !$0.skipped && !$0.localChangesOverwritePaths.isEmpty
            }
            let pendingOperations = combinedResults.contains {
                !$0.skipped && $0.requiresFinish
            }
            let pendingFailureRootPath = combinedResults.first {
                !$0.success && !$0.skipped && $0.requiresFinish
            }?.rootPath
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.mergeWorkspace.showMultiRootDialog = false
                self.mergeWorkspace.multiRootBranchName = ""
                self.mergeWorkspace.multiRootSelectedRootPaths = []
                self.multiRootWorkspace.results = operationResults
                self.loadMultiRoots()
                if preserveLocalChanges {
                    self.presentMultiRootMergeRestoreConflicts(combinedResults)
                }

                let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: Self.completedMergeRevisionRanges(combinedResults)
                )

                if !overwriteFailures.isEmpty && !pendingOperations && !preserveLocalChanges {
                    let details = overwriteFailures.map {
                        "\($0.displayName): \($0.localChangesOverwritePaths.joined(separator: ", "))"
                    }.joined(separator: "\n")
                    self.feedbackCenter.warning(
                        "Multi-root Merge needs a decision",
                        detail: details,
                        nextStep: "Choose Smart Merge to preserve local changes in each affected root, or cancel.",
                        additionalActions: viewCommitsAction.map { [$0] } ?? [],
                        notificationID: self.multiRootMergeNotificationID()
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Multi-root Merge",
                        paths: overwriteFailures.flatMap { result in
                            result.localChangesOverwritePaths.map { "\(result.displayName): \($0)" }
                        },
                        detail: details,
                        smartButtonTitle: "Smart Merge",
                        onSmart: {
                            self.runMultiRootMergeOperation(
                                name: branchName,
                                selectedRootPaths: Set(overwriteFailures.map(\.rootPath)),
                                options: options,
                                preserveLocalChanges: true,
                                rootOrder: resultRootOrder,
                                preservedResults: combinedResults.filter { result in
                                    !overwriteFailures.contains(where: { $0.rootPath == result.rootPath })
                                }
                            )
                        }
                    )
                } else if !failures.isEmpty {
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let failureDetails = failures.map {
                        "\($0.displayName): \($0.message.isEmpty ? ($0.skipped ? "skipped" : "failed") : $0.message)"
                    }
                    var additionalActions = self.multiRootMergeRollbackAction(
                        branchName: branchName,
                        targets: rollbackTargets
                    ).map { [$0] } ?? []
                    if let viewCommitsAction {
                        additionalActions.append(viewCommitsAction)
                    }
                    self.feedbackCenter.warning(
                        "Multi-root merge partially completed",
                        detail: failureDetails.joined(separator: "\n"),
                        nextStep: rollbackTargets.isEmpty
                            ? "Review the affected Git roots and resolve or abort any pending merge."
                            : "Choose whether to rollback successful roots or keep the partial state.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootMergeNotificationID(),
                        notificationGroup: rollbackTargets.isEmpty ? .toolWindow : .standard
                    )
                    if !rollbackTargets.isEmpty {
                        self.mergeWorkspace.multiRootRollbackContext = MultiRootMergeRollbackContext(
                            branchName: branchName,
                            targets: rollbackTargets,
                            failures: failureDetails,
                            pendingRootPath: pendingFailureRootPath
                        )
                    }
                    if rollbackTargets.isEmpty, let pendingFailureRootPath {
                        self.openMultiRootConflictResolver(preferredRootPath: pendingFailureRootPath)
                    }
                } else if !conflicts.isEmpty {
                    let conflict = conflicts.first
                    self.feedbackCenter.warning(
                        "Multi-root merge paused",
                        detail: conflicts.map {
                            "\($0.displayName): \($0.conflicts.count) conflict(s)"
                        }.joined(separator: "\n"),
                        nextStep: "Resolve conflicts in each affected root, then use Continue or Abort in Git Roots.",
                        additionalActions: viewCommitsAction.map { [$0] } ?? [],
                        notificationID: self.multiRootMergeNotificationID(),
                        notificationGroup: viewCommitsAction == nil ? .toolWindow : .standard
                    )
                    self.openMultiRootConflictResolver(
                        preferredRootPath: conflict?.rootPath,
                        preferredPath: conflict?.conflicts.first
                    )
                } else {
                    let mergeResultRows = feedbackResultRows(from: operationResults)
                    if deleteOnMerge == .delete {
                        self.feedbackCenter.success(
                            "Multi-root merge completed",
                            detail: "\(combinedResults.filter { $0.success && !$0.skipped }.count) repositories · \(branchName)",
                            additionalActions: viewCommitsAction.map { [$0] } ?? [],
                            notificationID: self.multiRootMergeNotificationID(),
                            notificationGroup: .standard
                        )
                        self.feedbackCenter.attachResultRows(
                            mergeResultRows,
                            notificationID: self.multiRootMergeNotificationID()
                        )
                        self.deleteMultiRootBranch(
                            name: branchName,
                            selectedRootPaths: Set(allMergeRootPaths),
                            allowForceDelete: false
                        )
                    } else if deleteOnMerge == .propose {
                        if let deleteAction = self.multiRootMergeDeleteAction(
                            branch: branchName,
                            rootPaths: allMergeRootPaths
                        ) {
                            self.feedbackCenter.success(
                                "Multi-root merge completed",
                                detail: "\(combinedResults.filter { $0.success && !$0.skipped }.count) repositories · \(branchName)",
                                additionalActions: [deleteAction] + (viewCommitsAction.map { [$0] } ?? []),
                                notificationID: self.multiRootMergeDeleteNotificationID(),
                                notificationGroup: .standard
                            )
                            self.feedbackCenter.attachResultRows(
                                mergeResultRows,
                                notificationID: self.multiRootMergeDeleteNotificationID()
                            )
                        }
                    } else {
                        self.feedbackCenter.success(
                            "Multi-root merge completed",
                            detail: "\(combinedResults.filter { $0.success && !$0.skipped }.count) repositories · \(branchName)",
                            additionalActions: viewCommitsAction.map { [$0] } ?? [],
                            notificationID: self.multiRootMergeNotificationID(),
                            notificationGroup: .standard
                        )
                        self.feedbackCenter.attachResultRows(
                            mergeResultRows,
                            notificationID: self.multiRootMergeNotificationID()
                        )
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    "Multi-root merge failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry the merge."
                )
            }
        }
    }
}

func multiRootMergeRollbackRequest(
    branchName: String,
    targets: [MultiRootMergeRollbackTarget],
    resultRows: [FeedbackResultRow] = []
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootMerge,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootMergeBranchName: branchName,
        multiRootMergeRollbackTargets: targets.map(PersistedMultiRootMergeRollbackTarget.init),
        multiRootMergeRollbackResultRows: resultRows.isEmpty ? nil : resultRows
    )
}

func multiRootMergeRollbackAction(
    branchName: String,
    targets: [MultiRootMergeRollbackTarget]
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = multiRootMergeRollbackRequest(branchName: branchName, targets: targets)
    return FeedbackAction(title: "Rollback Successful Roots", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootMergeRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-merge.rollback.\(stableProject)"
}

/// Stable display identity for the initial multi-root Merge result. Rollback
/// and delete-on-merge use separate IDs so their later lifecycle updates do
/// not erase the original root-qualified result tree.
func multiRootMergeNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-merge.\(stableProject)"
}

/// Roll back only roots whose HEAD is still the exact merge result recorded by
/// the engine. Pending merges use Abort so conflict worktrees are not silently
/// overwritten; completed merges use the configured preserving lifecycle and a
/// hard reset, matching IntelliJ's smart rollback for dirty repositories.
func rollbackMultiRootMerge(
    _ targets: [MultiRootMergeRollbackTarget],
    branchName: String? = nil,
    priorResultRows: [FeedbackResultRow] = []
) {
    guard !targets.isEmpty else { return }
    let rollbackContext = mergeWorkspace.multiRootRollbackContext
    let rollbackBranchName = branchName
        ?? rollbackContext?.branchName
        ?? mergeWorkspace.multiRootBranchName
    let previousFailures = rollbackContext?.failures ?? []
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    mergeWorkspace.multiRootRollbackContext = nil
    let stableNotificationID = multiRootMergeRollbackNotificationID()
    beginFeedbackOperation(
        "Rollback multi-root merge",
        notificationID: stableNotificationID
    )
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [MultiRootMergeRollbackTarget] = []
        var results: [RootOperationResult] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard rootRepo.headCommitId() == target.expectedHead else {
                    throw NSError(
                        domain: "Arbor.MultiRootMergeRollback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "HEAD changed after the merge; rollback was skipped."]
                    )
                }
                if target.operationPending {
                    try rootRepo.mergeAbort()
                } else {
                    try rootRepo.resetWithPolicy(
                        commitId: target.initialHead,
                        mode: .hard,
                        savePolicy: savePolicy
                    )
                }
                guard rootRepo.headCommitId() == target.initialHead else {
                    throw NSError(
                        domain: "Arbor.MultiRootMergeRollback",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Rollback did not restore the original HEAD."]
                    )
                }
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: target.displayName,
                        success: true,
                        skipped: false,
                        message: target.operationPending
                            ? "Aborted merge and restored the original HEAD"
                            : "Restored the original HEAD"
                    )
                )
            } catch {
                let message = errorMessage(error)
                failures.append("\(target.displayName): \(message)")
                remaining.append(target)
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: target.displayName,
                        success: false,
                        skipped: false,
                        message: message
                    )
                )
            }
        }
        let rollbackSucceeded = failures.isEmpty
        let remainingTargets = remaining
        let rollbackFailureDetails = failures
        let rollbackFailures = previousFailures + rollbackFailureDetails
        let rollbackResultRows = mergeFeedbackResultRows(
            preserved: priorResultRows,
            retry: feedbackResultRows(from: results)
        )
        await MainActor.run {
            self.loadMultiRoots()
            if rollbackSucceeded {
                self.feedbackCenter.success(
                    "Multi-root merge rollback completed",
                    detail: "\(targets.count) repositories restored",
                    notificationID: stableNotificationID,
                    notificationGroup: .standard
                )
                self.feedbackCenter.attachResultRows(
                    rollbackResultRows,
                    notificationID: stableNotificationID
                )
            } else {
                self.mergeWorkspace.multiRootRollbackContext = MultiRootMergeRollbackContext(
                    branchName: rollbackBranchName,
                    targets: remainingTargets,
                    failures: rollbackFailures,
                    pendingRootPath: nil
                )
                let retryRequest = self.multiRootMergeRollbackRequest(
                    branchName: rollbackBranchName,
                    targets: remainingTargets,
                    resultRows: rollbackResultRows
                )
                self.feedbackCenter.warning(
                    "Multi-root merge rollback partially failed",
                    detail: rollbackFailureDetails.joined(separator: "\n"),
                    nextStep: "Review the remaining roots and retry only after confirming their current HEAD.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Remaining Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    ],
                    notificationID: stableNotificationID,
                    notificationGroup: .standard
                )
                self.feedbackCenter.attachResultRows(
                    rollbackResultRows,
                    notificationID: stableNotificationID
                )
                self.presentMultiRootMergeRollbackRestoreConflict(remainingTargets)
            }
        }
    }
}

/// GitMergeAction exposes the same received-commits follow-up as Update when
/// a merge actually creates or advances a commit. Keep the range derived from
/// the engine's per-root before/after heads so fast-forward, no-ff and mixed
/// multi-root results do not expose an unrelated or unchanged Log range.
nonisolated static func completedMergeRevisionRanges(
    _ results: [MultiRootMergeResult]
) -> [PersistedLogRevisionRange] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    return results
        .filter { result in
            result.success
                && !result.skipped
                && result.completed
                && result.initialHead != nil
                && result.finalHead != nil
        }
        .compactMap { result in
            guard let initialHead = result.initialHead,
                  let finalHead = result.finalHead,
                  !initialHead.isEmpty,
                  !finalHead.isEmpty,
                  initialHead != finalHead else {
                return nil
            }
            return PersistedLogRevisionRange(
                rootPath: normalizedPath(result.rootPath),
                oldRevision: initialHead,
                newRevision: finalHead
            )
        }
        .sorted { $0.rootPath < $1.rootPath }
}

func completedMergeViewCommitsAction(
    rootPath: String,
    initialHead: String?,
    finalHead: String?,
    completed: Bool
) -> FeedbackAction? {
    guard completed,
          let initialHead,
          let finalHead,
          !initialHead.isEmpty,
          !finalHead.isEmpty,
          initialHead != finalHead else {
        return nil
    }
    return multiRootUpdateViewCommitsAction(
        ranges: [PersistedLogRevisionRange(
            rootPath: URL(fileURLWithPath: rootPath).standardizedFileURL.path,
            oldRevision: initialHead,
            newRevision: finalHead
        )]
    )
}

/// A completed merge can be rolled back without discarding unrelated local
/// edits. The request carries the exact pre-merge HEAD and repository handle;
/// the action is posted through NotificationCenter because ContentView is a
/// SwiftUI value type and must not be captured by a long-lived feedback action.
struct MergeRollbackRequest {
    let repo: Repository
    let initialHead: String
    let expectedHead: String
    let branch: String
}

struct MergeDeleteBranchRequest {
    let repo: Repository
    let branch: String
    let rootPath: String?
}

func handleMergeDeleteNotification(_ notification: Notification) {
    guard let request = notification.object as? MergeDeleteBranchRequest else { return }
    if let rootPath = request.rootPath {
        deleteBranchInRoot(rootPath: rootPath, name: request.branch)
    } else if projectWorkspace.repository === request.repo {
        branchDelete(request.branch)
    } else {
        feedbackCenter.error(
            "Delete merged branch unavailable",
            detail: "The original repository is no longer active."
        )
    }
}

nonisolated func canProposeDeleteMergedBranch(
    repo: Repository,
    branch: String,
    protectedPatterns: [String]
) -> Bool {
    guard !branch.isEmpty,
          !GitProtectedBranchRules.matches(branch, patterns: protectedPatterns),
          let localBranches = try? repo.branchList(),
          let source = localBranches.first(where: { $0.name == branch }) else {
        return false
    }
    return !source.isCurrent
}

func confirmAndDeleteMultiRootMergedBranch(
    name: String,
    selectedRootPaths: Set<String>
) {
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    guard !GitProtectedBranchRules.matches(
        branchName,
        patterns: effectiveProtectedBranchPatterns
    ) else {
        feedbackCenter.warning(
            "Delete merged branch unavailable",
            detail: "The branch is protected: \(branchName)",
            nextStep: "Remove the branch from the protected-branch rules before deleting it."
        )
        return
    }

    let candidates = multiRootWorkspace.branchSnapshots.compactMap { snapshot -> MultiRootMergeDeleteCandidate? in
        guard snapshot.branches.contains(where: {
            $0.name == branchName && !$0.isCurrent
        }) else { return nil }
        return MultiRootMergeDeleteCandidate(
            rootPath: snapshot.rootPath,
            displayName: snapshot.displayName
        )
    }
    let targets = multiRootMergeDeleteTargets(
        selectedRootPaths: selectedRootPaths,
        candidates: candidates
    )
    guard !targets.isEmpty else {
        feedbackCenter.warning(
            "Delete merged branch unavailable",
            detail: "No selected Git root still contains a non-current local branch named \(branchName).",
            nextStep: "Refresh Git state and retry the action."
        )
        return
    }

    let rootList = targets.map { target in
        let displayName = target.displayName.isEmpty ? target.rootPath : target.displayName
        return "• \(displayName) — \(target.rootPath)"
    }.joined(separator: "\n")
    let alert = NSAlert()
    alert.messageText = "Delete merged branch \(branchName) from \(targets.count) Git root\(targets.count == 1 ? "" : "s")?"
    alert.informativeText = "This removes the local branch reference in:\n\(rootList)"
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    deleteMultiRootBranch(
        name: branchName,
        selectedRootPaths: Set(targets.map(\.rootPath)),
        allowForceDelete: false
    )
}

func postMergeRollbackAction(
    repo: Repository,
    initialHead: String,
    expectedHead: String,
    branch: String
) -> (() -> Void) {
    {
        NotificationCenter.default.post(
            name: .arborRollbackMerge,
            object: MergeRollbackRequest(
                repo: repo,
                initialHead: initialHead,
                expectedHead: expectedHead,
                branch: branch
            )
        )
    }
}

func postMergeDeleteAction(
    repo: Repository,
    branch: String,
    rootPath: String? = nil
) -> (() -> Void) {
    {
        NotificationCenter.default.post(
            name: .arborDeleteMergedBranch,
            object: MergeDeleteBranchRequest(
                repo: repo,
                branch: branch,
                rootPath: rootPath
            )
        )
    }
}

func multiRootMergeDeleteRequest(
    branch: String,
    rootPaths: [String]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .deleteMultiRootMergeBranch,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootMergeDeleteBranchName: branch,
        multiRootMergeDeleteRootPaths: rootPaths
    )
}

func multiRootMergeDeleteAction(
    branch: String,
    rootPaths: [String]
) -> FeedbackAction? {
    let normalizedRootPaths = Array(Set(rootPaths)).sorted()
    guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !normalizedRootPaths.isEmpty else { return nil }
    let request = multiRootMergeDeleteRequest(
        branch: branch,
        rootPaths: normalizedRootPaths
    )
    return FeedbackAction(title: "Delete branch", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootMergeDeleteNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-merge.delete-branch.\(stableProject)"
}

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

nonisolated func isUnmergedBranchDeletionError(_ error: Error) -> Bool {
    errorMessage(error).localizedCaseInsensitiveContains("not fully merged")
}

/// IntelliJ Cleanup Branches 的项目级入口：加载所有 Git root 的本地分支，
/// 由 BranchCleanupDialogView 决定目标分支、前缀、合并状态和批量删除集合。
func deleteMergedBranches() {
    beginBranchCleanup()
}

/// Find Merged follows IntelliJ's `reposWithTarget` boundary: a repository
/// without the requested local target is not a failed comparison and must not
/// make an otherwise successful multi-root scan look incomplete.
static func findMergedRootsContainingTarget(
    _ target: String,
    in roots: [BranchCleanupRoot]
) -> [BranchCleanupRoot] {
    roots.filter { root in
        root.branches.contains { $0.name == target }
    }
}

/// IntelliJ FindMergedLocalBranchesAction 的项目级入口：只读加载所有 Git
/// root，再由独立 sheet 按目标分支和名称前缀计算结果。
func beginFindMergedBranches() {
    guard let projectPath = projectWorkspace.path else { return }
    branchCleanup.task?.cancel()
    branchCleanup.task = nil
    let generation = nextFindMergedGeneration()
    let activeBranch = branchWorkspace.branches.first(where: { $0.isCurrent })?.name ?? ""
    branchCleanup.targetBranch = activeBranch
    branchCleanup.prefix = ""
    branchCleanup.roots = []
    branchCleanup.hasCalculated = false
    branchCleanup.summary = nil
    branchCleanup.reportID = nil
    branchCleanup.reportText = ""
    branchCleanup.isRunning = true
    branchCleanup.showFindMergedDialog = true
    beginFeedbackOperation("Load merged branch roots")
    let scanRoot = projectPath
    let task = Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            guard !Task.isCancelled else { return }
            let allBranches = roots.flatMap { $0.branches }
            let fallbackTarget: String
            if !activeBranch.isEmpty {
                fallbackTarget = activeBranch
            } else if let main = allBranches.first(where: { $0.name == "main" })?.name {
                fallbackTarget = main
            } else if let master = allBranches.first(where: { $0.name == "master" })?.name {
                fallbackTarget = master
            } else {
                fallbackTarget = allBranches.first(where: { $0.isCurrent })?.name ?? ""
            }
            await MainActor.run {
                guard self.branchCleanup.generation == generation else { return }
                self.branchCleanup.task = nil
                self.branchCleanup.roots = roots
                self.branchCleanup.targetBranch = fallbackTarget
                self.branchCleanup.isRunning = false
                self.feedbackCenter.success("Merged branch roots loaded", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                guard self.branchCleanup.generation == generation else { return }
                self.branchCleanup.task = nil
                self.branchCleanup.isRunning = false
                self.feedbackCenter.error(
                    "Load merged branch roots failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
    branchCleanup.task = task
}

func nextFindMergedGeneration() -> Int {
    branchCleanup.generation += 1
    return branchCleanup.generation
}

func dismissFindMergedBranches() {
    branchCleanup.task?.cancel()
    branchCleanup.task = nil
    _ = nextFindMergedGeneration()
    branchCleanup.showFindMergedDialog = false
    branchCleanup.isRunning = false
    branchCleanup.hasCalculated = false
    branchCleanup.summary = nil
    branchCleanup.roots = []
}

func cancelFindMergedBranches() {
    guard branchCleanup.isRunning else { return }
    // Root discovery is cancellable and dismisses the sheet; an active scan
    // keeps its partial roots and reports cancellation at the next boundary.
    if branchCleanup.roots.isEmpty && branchCleanup.summary == nil {
        dismissFindMergedBranches()
    } else {
        branchCleanup.task?.cancel()
    }
}

func calculateFindMergedBranches() {
    let target = branchCleanup.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = branchCleanup.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
        feedbackCenter.warning("Target branch is required")
        return
    }
    let discoveredRoots = branchCleanup.roots
    let roots = Self.findMergedRootsContainingTarget(target, in: discoveredRoots)
    let generation = nextFindMergedGeneration()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    branchCleanup.isRunning = true
    branchCleanup.hasCalculated = false
    branchCleanup.summary = nil
    branchCleanup.task?.cancel()
    beginFeedbackOperation("Find merged branches")
    let task = Task.detached(priority: .userInitiated) {
        let scanResults = await scanBranchMergeRoots(roots, target: target, prefix: prefix)
        let calculatedRoots = scanResults.map(\.root)
        let failures = scanResults.compactMap { result in
            result.error.map { "\(result.root.displayName): \($0)" }
        }
        let repositoriesScanned = scanResults.filter(\.repositoryScanned).count
        let candidateBranchesChecked = scanResults.reduce(0) {
            $0 + $1.candidateBranchesChecked
        }
        let mergedBranchesFound = scanResults.reduce(0) {
            $0 + $1.mergedBranchesFound
        }
        let wasCancelled = Task.isCancelled
        let rootsToApply = calculatedRoots
        let completedRepositoryCount = calculatedRoots.count
        let failuresToReport = failures
        let elapsedMilliseconds = Int64(
            (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        )
        let summary = FindMergedScanSummary(
            targetBranch: target,
            prefix: prefix,
            repositoriesDiscovered: discoveredRoots.count,
            repositoriesScanned: repositoriesScanned,
            candidateBranchesChecked: candidateBranchesChecked,
            mergedBranchesFound: mergedBranchesFound,
            errors: failuresToReport,
            elapsedMilliseconds: elapsedMilliseconds,
            isCancelled: wasCancelled
        )
        await MainActor.run {
            guard self.branchCleanup.generation == generation else { return }
            self.branchCleanup.task = nil
            self.branchCleanup.roots = rootsToApply
            self.branchCleanup.isRunning = false
            self.branchCleanup.hasCalculated = true
            self.branchCleanup.summary = summary
            let reportID = UUID().uuidString
            let report = findMergedBranchesReportText(
                summary: summary,
                roots: rootsToApply,
                projectName: self.projectWorkspace.path.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? ""
            )
            FindMergedReportStore.save(
                PersistedFindMergedReport(
                    id: reportID,
                    projectPath: self.projectWorkspace.path ?? "",
                    targetBranch: summary.targetBranch,
                    prefix: summary.prefix,
                    report: report,
                    createdAt: Date()
                )
            )
            self.branchCleanup.reportID = reportID
            let reportAction = self.findMergedReportAction(reportID: reportID)
            let notificationID = self.findMergedNotificationID(
                targetBranch: summary.targetBranch,
                prefix: summary.prefix
            )
            if summary.isCancelled {
                self.feedbackCenter.warning(
                    "Find merged branches cancelled",
                    detail: "\(completedRepositoryCount) of \(roots.count) repositories completed",
                    additionalActions: [reportAction],
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
            } else if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Merged branches found",
                    detail: target,
                    additionalActions: [reportAction],
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
            } else {
                self.feedbackCenter.warning(
                    "Find merged branches incomplete",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Choose a target branch that exists in the affected roots.",
                    additionalActions: [reportAction],
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
            }
        }
    }
    branchCleanup.task = task
}

func findMergedReportAction(reportID: String) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .showFindMergedReport,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        findMergedReportID: reportID
    )
    return FeedbackAction(
        id: "open-find-merged-report",
        title: "Open Report",
        semanticAction: request
    ) {
        NotificationCenter.default.post(name: .arborVCSAction, object: request)
    }
}

func findMergedNotificationID(targetBranch: String, prefix: String) -> String {
    let source = [projectWorkspace.path ?? "", targetBranch, prefix].joined(separator: "\u{1f}")
    let encoded = Data(source.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "git.find-merged.\(encoded)"
}

func presentFindMergedReport() {
    if branchCleanup.showFindMergedDialog {
        // The report editor is attached to the project view rather than the
        // scan sheet. Dismiss the scan sheet first so SwiftUI does not reject
        // a second presentation while the first sheet is still mounted.
        branchCleanup.showFindMergedDialog = false
        Task { @MainActor in
            await Task.yield()
            self.branchCleanup.showReport = true
        }
    } else {
        branchCleanup.showReport = true
    }
}

func openFindMergedReport() {
    let target = branchCleanup.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = branchCleanup.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let summary = branchCleanup.summary,
          summary.targetBranch == target,
          summary.prefix == prefix else {
        feedbackCenter.warning("Run Find to calculate merged branches")
        return
    }
    let report = findMergedBranchesReportText(
        summary: summary,
        roots: branchCleanup.roots,
        projectName: projectWorkspace.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    )
    let reportID = branchCleanup.reportID ?? UUID().uuidString
    if let projectPath = projectWorkspace.path {
        FindMergedReportStore.save(
            PersistedFindMergedReport(
                id: reportID,
                projectPath: projectPath,
                targetBranch: summary.targetBranch,
                prefix: summary.prefix,
                report: report,
                createdAt: Date()
            )
        )
    }
    branchCleanup.reportID = reportID
    branchCleanup.reportText = report
    presentFindMergedReport()
}

func openFindMergedReport(reportID: String) {
    guard let saved = FindMergedReportStore.load(id: reportID) else {
        feedbackCenter.warning(
            "Merged branches report unavailable",
            detail: "The saved report is no longer available.",
            nextStep: "Run Find Merged Local Branches again."
        )
        return
    }
    if let projectPath = projectWorkspace.path,
       URL(fileURLWithPath: projectPath).standardizedFileURL.path
            != URL(fileURLWithPath: saved.projectPath).standardizedFileURL.path
    {
        return
    }
    branchCleanup.reportID = saved.id
    branchCleanup.targetBranch = saved.targetBranch
    branchCleanup.prefix = saved.prefix
    branchCleanup.reportText = saved.report
    presentFindMergedReport()
}

func copyFindMergedBranches() {
    let target = branchCleanup.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = branchCleanup.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let summary = branchCleanup.summary,
          summary.targetBranch == target,
          summary.prefix == prefix else {
        feedbackCenter.warning("Run Find to calculate merged branches")
        return
    }
    let report = findMergedBranchesReportText(
        summary: summary,
        roots: branchCleanup.roots,
        projectName: projectWorkspace.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    )
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(report, forType: .string)
    feedbackCenter.success("Merged branches copied", detail: "\(summary.mergedBranchesFound) branches")
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
