import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Rebuild the current branch when its upstream was force-pushed. IntelliJ
/// first offers the affected local changes, then routes Smart/Force/Cancel
/// through the same preserving decision used by checkout and merge.
func updateForcePushedBranch() {
    guard let repo else { return }
    do {
        let paths = try dirtyPathsForSmartDecision(repo)
        if paths.isEmpty {
            runForcePushedBranchUpdate(repo: repo, rootPath: nil, force: false)
        } else {
            feedbackCenter.warning(
                "Force-pushed branch update needs a decision",
                detail: paths.joined(separator: ", "),
                nextStep: "Choose Smart Update to preserve local changes, Force Update to discard them, or cancel."
            )
            presentSmartOperationDecision(
                operationTitle: "Force-pushed branch update",
                paths: paths,
                smartButtonTitle: "Smart Update",
                forceButtonTitle: "Force Update",
                onSmart: {
                    self.runForcePushedBranchUpdate(repo: repo, rootPath: nil, force: false)
                },
                onForce: {
                    self.runForcePushedBranchUpdate(repo: repo, rootPath: nil, force: true)
                }
            )
        }
    } catch {
        feedbackCenter.error(
            "Force-pushed branch update unavailable",
            detail: errorMessage(error),
            nextStep: "Refresh the repository, then retry the update."
        )
    }
}

/// The multi-root Branches Popup can target a current branch in a root that is
/// not the window's primary Repository. Preflight that root on a worker before
/// presenting the same affected-changes dialog.
func updateForcePushedBranchInRoot(rootPath: String, branch: String) {
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let paths = try dirtyPathsForSmartDecision(rootRepo)
            await MainActor.run {
                if paths.isEmpty {
                    self.runForcePushedBranchUpdate(
                        repo: rootRepo,
                        rootPath: rootPath,
                        force: false
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Force-pushed branch update needs a decision",
                        detail: "\(rootPath): \(paths.joined(separator: ", "))",
                        nextStep: "Choose Smart Update to preserve local changes, Force Update to discard them, or cancel."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Force-pushed branch update",
                        paths: paths.map { "\(rootPath): \($0)" },
                        smartButtonTitle: "Smart Update",
                        forceButtonTitle: "Force Update",
                        onSmart: {
                            self.runForcePushedBranchUpdate(
                                repo: rootRepo,
                                rootPath: rootPath,
                                force: false
                            )
                        },
                        onForce: {
                            self.runForcePushedBranchUpdate(
                                repo: rootRepo,
                                rootPath: rootPath,
                                force: true
                            )
                        }
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Force-pushed branch update unavailable",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Refresh Git Roots, then retry the update."
                )
            }
        }
    }
}

/// Present one Smart/Force decision for all eligible current roots that share
/// a branch name, then execute the engine's per-root aggregate operation.
func updateForcePushedBranchAcrossRoots(_ branch: String) {
    guard self.projectWorkspace.path != nil else { return }
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        snapshot.branches.contains { $0.name == branch && $0.isCurrent }
            && snapshot.syncStatuses.contains {
                $0.branch == branch
                    && $0.trackingExists
                    && $0.ahead > 0
                    && $0.behind > 0
            }
    }
    guard !roots.isEmpty else {
        feedbackCenter.warning(
            "Force-pushed branch update unavailable",
            detail: branch,
            nextStep: "Refresh Git Roots and retry after the branch shows both local and remote divergence."
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        var dirtyByRoot: [(rootPath: String, displayName: String, paths: [String])] = []
        var preflightErrors: [String] = []
        for root in roots {
            do {
                let rootRepo = try openRepository(path: root.rootPath)
                let paths = try dirtyPathsForSmartDecision(rootRepo)
                if !paths.isEmpty {
                    dirtyByRoot.append((root.rootPath, root.displayName, paths))
                }
            } catch {
                preflightErrors.append("\(root.displayName): \(errorMessage(error))")
            }
        }

        let dirtyRoots = dirtyByRoot
        let errors = preflightErrors
        await MainActor.run {
            if !errors.isEmpty {
                self.feedbackCenter.error(
                    "Multi-root force-pushed update unavailable",
                    detail: errors.joined(separator: "\n"),
                    nextStep: "Refresh Git Roots, then retry the update."
                )
                return
            }
            let selectedRootPaths = roots.map(\.rootPath)
            if dirtyRoots.isEmpty {
                self.runMultiRootForcePushedBranchUpdate(
                    branch: branch,
                    selectedRootPaths: selectedRootPaths,
                    force: false
                )
            } else {
                let detail = dirtyRoots.map {
                    "\($0.displayName): \($0.paths.joined(separator: ", "))"
                }.joined(separator: "\n")
                self.feedbackCenter.warning(
                    "Multi-root force-pushed update needs a decision",
                    detail: detail,
                    nextStep: "Choose Smart Update to preserve local changes in each root, Force Update to discard them, or cancel."
                )
                self.presentSmartOperationDecision(
                    operationTitle: "Multi-root force-pushed branch update",
                    paths: dirtyRoots.flatMap { root in
                        root.paths.map { "\(root.displayName): \($0)" }
                    },
                    smartButtonTitle: "Smart Update",
                    forceButtonTitle: "Force Update",
                    onSmart: {
                        self.runMultiRootForcePushedBranchUpdate(
                            branch: branch,
                            selectedRootPaths: selectedRootPaths,
                            force: false
                        )
                    },
                    onForce: {
                        self.runMultiRootForcePushedBranchUpdate(
                            branch: branch,
                            selectedRootPaths: selectedRootPaths,
                            force: true
                        )
                    }
                )
            }
        }
    }
}

func runForcePushedBranchUpdate(
    repo: Repository,
    rootPath: String?,
    force: Bool
) {
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Update force-pushed branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let outcome: ForcePushedBranchUpdateOutcome
            if force {
                outcome = try repo.forcePushedBranchUpdateWithAuthAndCancelForce(
                    broker: broker,
                    cancel: cancel
                )
            } else {
                outcome = try repo.forcePushedBranchUpdateWithAuthAndCancel(
                    savePolicy: projectSavePolicy,
                    broker: broker,
                    cancel: cancel
                )
            }
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                let updateDetail = outcome.usedMergeUpdate
                    ? "\(outcome.branch) ← \(outcome.upstream) · merge update"
                    : "\(outcome.branch) ← \(outcome.upstream) · replayed \(outcome.replayedCommits) local commit(s)"
                let counts = outcome.receivedCommitsCount > 0 || outcome.updatedFilesCount > 0
                    ? " · \(outcome.updatedFilesCount) updated file(s) in \(outcome.receivedCommitsCount) received commit(s)"
                    : ""
                let detail = rootPath.map { "\($0): \(updateDetail)\(counts)" } ?? "\(updateDetail)\(counts)"
                let viewCommitRanges = self.forcePushedRevisionRanges(
                    oldTip: outcome.updateRangeStart,
                    newTip: outcome.newUpstreamTip,
                    rootPath: rootPath
                )
                let viewAction = self.forcePushedViewCommitsAction(
                    ranges: viewCommitRanges,
                    rootPath: rootPath
                )
                self.feedbackCenter.success(
                    "Force-pushed branch updated",
                    detail: detail,
                    additionalActions: viewAction.map { [$0] } ?? [],
                    notificationID: rootPath.map { "git.force-pushed-update.\($0)" }
                        ?? "git.force-pushed-update"
                )
                self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
                if rootPath == nil {
                    self.refreshAll(showFeedback: false)
                    self.loadRepoData()
                } else {
                    self.loadMultiRoots()
                }
            }
        } catch {
            let operationState = (try? repo.operationState()) ?? nil
            let backupBranchNames = (try? repo.branchList())?
                .filter { isArborForcePushedBackupBranch($0.name) }
                .map(\.name)
                .sorted() ?? []
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                let isPrimaryRoot = rootPath == nil || rootPath == repo.workdir()
                let backupActions = self.forcePushedBackupActions(
                    rootPath: rootPath,
                    branchNames: backupBranchNames
                )
                if !backupBranchNames.isEmpty {
                    self.feedbackCenter.warning(
                        "Force-pushed backup branch kept",
                        detail: backupBranchNames.joined(separator: ", "),
                        nextStep: "Saved backup branches remain available for inspection or deletion.",
                        additionalActions: backupActions
                    )
                }
                if isPrimaryRoot, case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Force-pushed branch update",
                        stashID: stashID
                    )
                } else if isPrimaryRoot,
                          case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    self.presentShelveConflict(name: name, paths: paths, isPop: true)
                } else if let rootPath {
                    self.feedbackCenter.warning(
                        "Force-pushed branch update paused",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Open the Git Roots conflict workbench to resolve the saved local changes.",
                        actionTitle: "Resolve Conflicts",
                        action: { self.openMultiRootConflictResolver(preferredRootPath: rootPath) },
                        additionalActions: backupActions
                    )
                    self.loadMultiRoots()
                } else if operationState != nil {
                    self.feedbackCenter.warning(
                        "Force-pushed branch update paused",
                        detail: errorMessage(error),
                        nextStep: "Resolve the pending operation, then Continue or Abort.",
                        actionTitle: "Resolve Conflicts",
                        action: self.openActiveOperationConflictResolver,
                        additionalActions: backupActions
                    )
                } else {
                    self.feedbackCenter.error(
                        "Force-pushed branch update failed",
                        detail: errorMessage(error),
                        nextStep: "Inspect the backup branch and current Git state before retrying.",
                        additionalActions: backupActions
                    )
                }
            }
        }
    }
}

func runMultiRootForcePushedBranchUpdate(
    branch: String,
    selectedRootPaths: [String],
    force: Bool
) {
    guard let projectPath = projectWorkspace.path else { return }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    multiRootWorkspace.running = true
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Multi-root force-pushed branch update", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let results = try runMultiRootForcePushedBranchUpdateWithAuthAndCancel(
                scanRoot: projectPath,
                selectedRootPaths: selectedRootPaths,
                broker: broker,
                cancel: cancel,
                savePolicy: projectSavePolicy,
                force: force
            )
            let operationResults = results.map { result in
                RootOperationResult(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    success: result.success,
                    skipped: result.skipped,
                    message: result.message
                )
            }
            let failures = results.filter { !$0.success }
            let skippedResults = results.filter { $0.skipped }
            let successCount = results.filter { $0.success && !$0.skipped }.count
            var backupBranchesByRoot: [String: [String]] = [:]
            for result in failures {
                guard let rootRepo = try? openRepository(path: result.rootPath) else { continue }
                let branchNames = (try? rootRepo.branchList())?
                    .filter { isArborForcePushedBackupBranch($0.name) }
                    .map(\.name)
                    .sorted() ?? []
                if !branchNames.isEmpty {
                    backupBranchesByRoot[result.rootPath] = branchNames
                }
            }
            let finalizedBackupBranchesByRoot = backupBranchesByRoot
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.multiRootWorkspace.results = operationResults
                self.loadMultiRoots()
                let successfulResults = results.filter { $0.success && !$0.skipped }
                let receivedCommits = successfulResults.reduce(0) { $0 + Int($1.receivedCommitsCount) }
                let updatedFiles = successfulResults.reduce(0) { $0 + Int($1.updatedFilesCount) }
                let countDetail = receivedCommits > 0 || updatedFiles > 0
                    ? " · \(updatedFiles) updated file(s) in \(receivedCommits) received commit(s)"
                    : ""
                let skippedDetail = self.forcePushedSkippedDetail(skippedResults)
                let viewCommitRanges = successfulResults.compactMap { result in
                    self.forcePushedRevisionRanges(
                        oldTip: result.updateRangeStart,
                        newTip: result.newUpstreamTip,
                        rootPath: result.rootPath
                    ).first
                }
                let viewAction = self.forcePushedViewCommitsAction(
                    ranges: viewCommitRanges
                )
                if failures.isEmpty {
                    self.feedbackCenter.success(
                        "Multi-root force-pushed branch updated",
                        detail: "\(successCount) repositories · \(branch)\(countDetail)\(skippedDetail)",
                        additionalActions: viewAction.map { [$0] } ?? [],
                        notificationID: "git.force-pushed-update.multi-root"
                    )
                } else {
                    let detail = failures.map {
                        "\($0.displayName): \($0.message.isEmpty ? "failed" : $0.message)"
                    }.joined(separator: "\n")
                    let pendingRoot = failures.first(where: { !$0.localChangesOverwritePaths.isEmpty })?.rootPath
                    let backupActions = self.forcePushedBackupActionsByRoot(finalizedBackupBranchesByRoot)
                    let backupDetail = finalizedBackupBranchesByRoot
                        .sorted { $0.key < $1.key }
                        .flatMap { rootPath, names in
                            names.map { "\(rootPath): \($0)" }
                        }
                        .joined(separator: "\n")
                    let detailWithBackups = backupDetail.isEmpty
                        ? detail
                        : "\(detail)\n\n\(String(localized: "Backup branches kept")):\n\(backupDetail)"
                    var additionalActions = backupActions
                    if let viewAction {
                        additionalActions.insert(viewAction, at: 0)
                    }
                    self.feedbackCenter.warning(
                        "Multi-root force-pushed update partially completed",
                        detail: "\(detailWithBackups)\(countDetail)\(skippedDetail)",
                        nextStep: "Review each Git root; saved local changes remain available for recovery.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            self.openMultiRootConflictResolver(preferredRootPath: pendingRoot)
                        },
                        additionalActions: additionalActions,
                        notificationID: "git.force-pushed-update.multi-root"
                    )
                }
                self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    "Multi-root force-pushed update failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry the update."
                )
            }
        }
    }
}

func forcePushedSkippedDetail(
    _ results: [MultiRootForcePushedBranchUpdateResult]
) -> String {
    guard !results.isEmpty else { return "" }
    let grouped = Dictionary(grouping: results, by: \.message)
        .sorted { $0.key < $1.key }
        .map { reason, roots in
            "\(roots.map(\.displayName).sorted().joined(separator: ", ")) (\(reason))"
        }
        .joined(separator: "; ")
    return " · skipped roots: \(grouped)"
}

func forcePushedRevisionRanges(
    oldTip: String?,
    newTip: String,
    rootPath: String?
) -> [PersistedLogRevisionRange] {
    guard let oldTip,
          !oldTip.isEmpty,
          !newTip.isEmpty,
          oldTip != newTip,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return [] }
    return [PersistedLogRevisionRange(
        rootPath: resolvedRootPath,
        oldRevision: oldTip,
        newRevision: newTip
    )]
}

func forcePushedViewCommitsAction(
    oldTip: String?,
    newTip: String,
    rootPath: String?
) -> FeedbackAction? {
    let ranges = forcePushedRevisionRanges(
        oldTip: oldTip,
        newTip: newTip,
        rootPath: rootPath
    )
    return forcePushedViewCommitsAction(ranges: ranges, rootPath: rootPath)
}

func forcePushedViewCommitsAction(
    ranges: [PersistedLogRevisionRange],
    rootPath: String? = nil
) -> FeedbackAction? {
    guard !ranges.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showLogRanges,
        projectPath: projectWorkspace.path,
        rootPath: ranges.count == 1 ? rootPath : nil,
        shelfName: "",
        logRevisionRanges: ranges
    )
    return FeedbackAction(title: "View Commits", semanticAction: request) {
        self.showLogRevisionRanges(ranges)
    }
}

func forcePushedBackupActions(
    rootPath: String?,
    branchNames: [String]
) -> [FeedbackAction] {
    guard !branchNames.isEmpty else { return [] }
    var actions = [
        FeedbackAction(title: "Open Branches") {
            if rootPath == nil {
                self.loadRepoData()
            } else {
                self.loadMultiRoots()
            }
            self.branchWorkspace.showPopover = true
        }
    ]
    actions.append(contentsOf: branchNames.map { branchName in
        FeedbackAction(title: "Delete backup branch") {
            self.deleteForcePushedBackupBranch(rootPath: rootPath, name: branchName)
        }
    })
    return actions
}

func forcePushedBackupActionsByRoot(
    _ branchesByRoot: [String: [String]]
) -> [FeedbackAction] {
    guard !branchesByRoot.isEmpty else { return [] }
    var actions = [
        FeedbackAction(title: "Open Branches") {
            self.loadMultiRoots()
            self.branchWorkspace.showPopover = true
        }
    ]
    for (rootPath, branchNames) in branchesByRoot.sorted(by: { $0.key < $1.key }) {
        actions.append(contentsOf: branchNames.map { branchName in
            FeedbackAction(title: "Delete backup branch") {
                self.deleteForcePushedBackupBranch(rootPath: rootPath, name: branchName)
            }
        })
    }
    return actions
}

func deleteForcePushedBackupBranch(rootPath: String?, name: String) {
    guard isArborForcePushedBackupBranch(name) else { return }
    if let rootPath {
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                await MainActor.run {
                    self.prepareForceDeleteBranch(repo: rootRepo, name: name, rootPath: rootPath)
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Delete backup branch failed",
                        detail: "\(rootPath): \(errorMessage(error))"
                    )
                }
            }
        }
    } else if let repo {
        prepareForceDeleteBranch(repo: repo, name: name, rootPath: nil)
    }
}

}
