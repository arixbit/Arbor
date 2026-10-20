import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Commit success notifications in IntelliJ expose a Reword action while the
/// newly created commit is still the repository HEAD. Keep the request tied
/// to the owning root and commit id so a notification from a nested root
/// cannot accidentally rewrite the primary repository after a reload.
func commitRewordFeedbackAction(
    rootPath: String,
    commitID: String
) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .rewordCommit,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        rewordCommitID: commitID
    )
    return FeedbackAction(
        id: "reword-commit:\(rootPath):\(commitID)",
        title: "Reword Commit",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func commitNotificationID(rootPath: String) -> String {
    let stableRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.commit.\(stableRoot)"
}

/// Reopen the exact Git root and commit referenced by a commit notification,
/// then enter the same HEAD-only reword flow used by the Log action group.
/// The HEAD check is repeated after loading the commit so a stale notification
/// can never rewrite a newer commit created after the original commit.
func openRewordCommit(rootPath: String, commitID: String) {
    let normalizedRootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let normalizedCommitID = commitID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedCommitID.isEmpty,
          let rootRepo = try? openRepository(path: normalizedRootPath) else {
        feedbackCenter.error(
            "Reword Commit unavailable",
            detail: "The Git root or commit from the notification is no longer available.",
            nextStep: "Refresh Git Roots and retry from Log."
        )
        return
    }

    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logSelectionState.selection = nil
    logSelectionState.selectedIDs = []
    logList.viewMode = .graph
    projectWorkspace.toolWindowMode = .log
    toolWindowExpanded = true
    projectPanelExpanded = false

    let primaryRoot = repo?.workdir().map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    if normalizedRootPath == primaryRoot {
        logList.activeRootPath = nil
        logList.activeRepo = nil
        logRuntime.activeBranches = []
        logRuntime.activeRemoteBranches = []
        logRuntime.activeRemotes = []
    } else {
        logList.activeRootPath = normalizedRootPath
        logList.activeRepo = rootRepo
        logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
        logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
        logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
    }
    loadLog()

    Task.detached(priority: .userInitiated) {
        do {
            guard rootRepo.headCommitId() == normalizedCommitID else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The committed HEAD has changed."]
                )
            }
            let commit = try rootRepo.logFiltered(
                path: nil,
                limit: 1,
                follow: false,
                startRev: normalizedCommitID,
                author: nil,
                since: nil
            ).first { candidate in
                candidate.id == normalizedCommitID
                    || candidate.id.hasPrefix(normalizedCommitID)
                    || normalizedCommitID.hasPrefix(candidate.id)
            }
            guard let commit, rootRepo.headCommitId() == commit.id else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The committed HEAD has changed."]
                )
            }
            await MainActor.run {
                guard self.isActiveLogRepository(rootRepo) else { return }
                self.logSelectionState.selection = commit.id
                self.logSelectionState.selectedIDs = [commit.id]
                self.logSelectionState.detailCommit = commit
                self.logRewrite.rewordCommit = commit
                self.logRewrite.rewordMessage = commit.messageBody.isEmpty
                    ? commit.summary
                    : "\(commit.summary)\n\n\(commit.messageBody)"
                self.logRewrite.rewordUsesRootRebase = false
                if commit.parentIds.isEmpty {
                    self.logRewrite.pendingInitialCommitReword = commit
                    self.logRewrite.showInitialCommitRewordAlert = true
                } else {
                    self.logRewrite.showRewordDialog = true
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.warning(
                    "Reword Commit unavailable",
                    detail: errorMessage(error),
                    nextStep: "The action applies only while the referenced commit remains the current HEAD."
                )
            }
        }
    }
}

/// Resolve a selected revision that is outside the current paged graph. This
/// is required for reflog rows and for external "open commit" notifications:
/// the inspector must remain useful even when the graph has only loaded its
/// first page.
func loadCommitDetailsIfNeeded(_ id: String, forReflog: Bool = false) {
    let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repo = logRepository, !normalized.isEmpty else { return }
    let revision = normalized.split(separator: "\u{1f}", maxSplits: 1).last.map(String.init) ?? normalized
    if !forReflog,
       let visible = (logList.viewMode == .command ? logRuntime.commandEntries : logList.entries).first(where: {
           let identity = logCommitIdentity($0)
           return identity == normalized || identity.hasPrefix(normalized) || normalized.hasPrefix(identity)
       }) {
        logSelectionState.detailLoadTask?.cancel()
        logSelectionState.detailCommit = visible
        return
    }
    if forReflog, reflog.detailCommit?.id == normalized { return }
    logSelectionState.detailLoadTask?.cancel()
    if forReflog {
        reflog.detailCommit = nil
    } else {
        logSelectionState.detailCommit = nil
    }
    let expectedReflogSelection = forReflog ? reflog.selection : nil
    let expectedLogSelection = forReflog ? nil : logSelectionState.selection
    let tabID = currentLogTabID
    let task = Task.detached(priority: .userInitiated) {
        do {
            let candidates = try repo.logFiltered(
                path: nil,
                limit: 1,
                follow: false,
                startRev: revision,
                author: nil,
                since: nil
            )
            guard !Task.isCancelled,
                  let commit = candidates.first(where: {
                      $0.id == normalized || $0.id.hasPrefix(normalized) || normalized.hasPrefix($0.id)
            }) else { return }
            await MainActor.run {
                guard self.externalLogTabIsAlive(tabID),
                      self.isActiveLogRepository(repo) else { return }
                if forReflog {
                    guard self.reflog.selection == expectedReflogSelection,
                          self.selectedReflogEntry?.newId == commit.id else { return }
                    self.reflog.detailCommit = commit
                } else if let selected = expectedLogSelection,
                          selected == normalized
                            || selected.hasPrefix(normalized)
                            || normalized.hasPrefix(selected) {
                    self.logSelectionState.detailCommit = commit
                }
            }
        } catch {
            // The graph/inspector will keep its existing content. A missing
            // reflog object is not a reason to replace a usable log with an
            // error screen.
        }
    }
    logSelectionState.detailLoadTask = task
}

/// Vcs.Log.GoToParent / GoToChild: keep navigation inside the graph table so
/// the details inspector follows the new lead selection immediately. IntelliJ
/// exposes all adjacent graph rows when there is more than one choice; resolve
/// those rows from the repository rather than treating the loaded page as the
/// complete graph.
func selectParentLogCommit() {
    guard let commit = selectedCommit,
          !commit.parentIds.isEmpty,
          let repository = logRepository(for: commit) else { return }

    let parentIDs = commit.parentIds
    let expectedSelection = logCommitIdentity(commit)
    let expectedGeneration = logList.generation
    if parentIDs.count == 1 {
        selectLogRevision(
            logCommitIdentity(repositoryPath: commit.repositoryPath, id: parentIDs[0])
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        let parents = try? parentIDs.map { try repository.commitInfo(commitId: $0) }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.logList.generation == expectedGeneration,
                  self.logSelectionState.selection == expectedSelection,
                  self.isActiveLogNavigationRepository(repository, rootPath: commit.repositoryPath) else {
                return
            }
            guard let parents, !parents.isEmpty else {
                self.feedbackCenter.warning(
                    "Parent navigation unavailable",
                    detail: "The selected commit's parent records could not be loaded.",
                    nextStep: "Refresh Log and try again."
                )
                return
            }
            self.logSelectionState.pendingNavigationCommits = parents
            self.logSelectionState.navigationChoosesParent = true
            self.logSelectionState.pendingNavigationSelection = expectedSelection
            self.logSelectionState.pendingNavigationGeneration = expectedGeneration
            self.logSelectionState.isNavigationChoicePresented = true
        }
    }
}

func selectChildLogCommit() {
    guard let commit = selectedCommit,
          let repository = logRepository(for: commit) else { return }

    let expectedSelection = logCommitIdentity(commit)
    let expectedGeneration = logList.generation
    Task.detached(priority: .userInitiated) {
        let children = try? repository.commitChildren(commitId: commit.id)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.logList.generation == expectedGeneration,
                  self.logSelectionState.selection == expectedSelection,
                  self.isActiveLogNavigationRepository(repository, rootPath: commit.repositoryPath) else {
                return
            }
            guard let children else {
                self.feedbackCenter.warning(
                    "Child navigation unavailable",
                    detail: "The selected commit's child records could not be loaded.",
                    nextStep: "Refresh Log and try again."
                )
                return
            }
            guard !children.isEmpty else {
                self.feedbackCenter.warning(
                    "No child commits",
                    detail: "The selected commit has no reachable direct child in this Git root.",
                    nextStep: "Select another commit in Log."
                )
                return
            }
            if children.count == 1 {
                self.selectLogRevision(self.logCommitIdentity(children[0]))
            } else {
                self.logSelectionState.pendingNavigationCommits = children
                self.logSelectionState.navigationChoosesParent = false
                self.logSelectionState.pendingNavigationSelection = expectedSelection
                self.logSelectionState.pendingNavigationGeneration = expectedGeneration
                self.logSelectionState.isNavigationChoicePresented = true
            }
        }
    }
}

func choosePendingLogNavigationCommit(_ commit: CommitInfo) {
    guard logSelectionState.isNavigationChoicePresented,
          logSelectionState.pendingNavigationSelection == logSelectionState.selection,
          logSelectionState.pendingNavigationGeneration == logList.generation else {
        logSelectionState.isNavigationChoicePresented = false
        logSelectionState.pendingNavigationCommits = []
        logSelectionState.pendingNavigationSelection = nil
        logSelectionState.pendingNavigationGeneration = nil
        return
    }
    let identity = logCommitIdentity(commit)
    logSelectionState.isNavigationChoicePresented = false
    logSelectionState.pendingNavigationCommits = []
    logSelectionState.pendingNavigationSelection = nil
    logSelectionState.pendingNavigationGeneration = nil
    selectLogRevision(identity)
}

func isCommitHashQuery(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (4...40).contains(normalized.count) else { return false }
    return normalized.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }
}

func createBranchFromCommit(_ commit: CommitInfo) {
    guard let targetRepo = logRepository(for: commit) else {
        feedbackCenter.warning(
            "Create Branch unavailable",
            detail: "The selected commit's Git root could not be opened.",
            nextStep: "Refresh Git Roots, then retry from the commit history."
        )
        return
    }
    presentNewBranchDialog(
        baseRevision: commit.id,
        suggestedName: "branch-\(commit.shortId)",
        title: String(localized: "New Branch from %@")
            .replacingOccurrences(of: "%@", with: commit.shortId),
        repositoryOverride: targetRepo
    )
}

/// Return the complete message shown by IntelliJ's Squash dialog.
nonisolated func completeCommitMessage(_ commit: CommitInfo) -> String {
    commit.messageBody.isEmpty
        ? commit.summary
        : "\(commit.summary)\n\n\(commit.messageBody)"
}

func cherryPickCommitsFromLog(_ commits: [CommitInfo]) {
    runLogApplyOperation(
        .cherryPick,
        commits: commits,
        confirm: false,
        preserveLocalChanges: false
    )
}

func revertCommitsFromLog(_ commits: [CommitInfo]) {
    runLogApplyOperation(
        .revert,
        commits: commits,
        confirm: true,
        preserveLocalChanges: false
    )
}

func resetCommit(_ commit: CommitInfo, mode: ResetMode) {
    guard let repo = logRepository(for: commit) else { return }
    GitResetModeSettings.save(GitResetModeChoice(mode), for: projectWorkspace.path)
    runResetCommit(repo: repo, id: commit.id, mode: mode, preserveLocalChanges: false)
}

func runResetCommit(
    repo: Repository,
    id: String,
    mode: ResetMode,
    preserveLocalChanges: Bool
) {
    beginFeedbackOperation("Reset branch")
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        do {
            let recovery = try repo.resetWithRecovery(
                commitId: id,
                mode: mode,
                savePolicy: projectSavePolicy,
                smart: preserveLocalChanges,
                force: false
            )
            await MainActor.run {
                self.commitWorkspace.feedback = "已 \(resetModeName(mode)) reset 到 \(String(id.prefix(7)))"
                let recoveryTarget = recovery.rollbackId.map {
                    PersistedResetRecoveryTarget(
                        rootPath: repo.workdir() ?? "",
                        displayName: URL(fileURLWithPath: repo.workdir() ?? "").lastPathComponent,
                        initialHead: recovery.initialHead,
                        expectedHead: recovery.finalHead,
                        expectedHeadBranch: recovery.finalBranch,
                        mode: mode,
                        rollbackID: $0
                    )
                }
                self.feedbackCenter.success(
                    "Reset completed",
                    detail: "\(resetModeName(mode)) · \(String(id.prefix(7)))",
                    additionalActions: recoveryTarget.map {
                        self.resetRecoveryActions(targets: [$0])
                    } ?? [],
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.commitWorkspace.feedback = errorMessage(error)
                if case let .LocalChangesWouldBeOverwritten(paths) = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Reset needs a decision",
                        detail: paths.joined(separator: ", "),
                        nextStep: "Choose Smart Reset to preserve local changes, or cancel and keep the current worktree."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Reset",
                        paths: paths,
                        detail: errorMessage(error),
                        smartButtonTitle: "Smart Reset",
                        forceButtonTitle: mode == .hard ? "Reset hard anyway" : nil,
                        onSmart: {
                            self.runResetCommit(
                                repo: repo,
                                id: id,
                                mode: mode,
                                preserveLocalChanges: true
                            )
                        },
                        onForce: mode == .hard ? {
                            self.forceResetCommit(repo: repo, id: id)
                        } : nil
                    )
                } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Reset",
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
                        "Reset failed",
                        detail: errorMessage(error),
                        nextStep: "Check the target revision and current Git state, then retry.",
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

func forceResetCommit(repo: Repository, id: String) {
    beginFeedbackOperation("Force reset branch")
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        do {
            let recovery = try repo.resetWithRecovery(
                commitId: id,
                mode: .hard,
                savePolicy: projectSavePolicy,
                smart: false,
                force: true
            )
            await MainActor.run {
                self.commitWorkspace.feedback = "已 hard reset 到 \(String(id.prefix(7)))"
                let recoveryTarget = recovery.rollbackId.map {
                    PersistedResetRecoveryTarget(
                        rootPath: repo.workdir() ?? "",
                        displayName: URL(fileURLWithPath: repo.workdir() ?? "").lastPathComponent,
                        initialHead: recovery.initialHead,
                        expectedHead: recovery.finalHead,
                        expectedHeadBranch: recovery.finalBranch,
                        mode: .hard,
                        rollbackID: $0
                    )
                }
                self.feedbackCenter.success(
                    "Hard reset completed",
                    detail: String(id.prefix(7)),
                    additionalActions: recoveryTarget.map {
                        self.resetRecoveryActions(targets: [$0])
                    } ?? [],
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Hard reset failed",
                    detail: errorMessage(error),
                    nextStep: "No local changes were restored; inspect the current Git state before retrying."
                )
            }
        }
    }
}

/// Reset the same revision across all discovered Git roots. The first pass is
/// deliberately direct so the engine can return every affected path; only the
/// explicit Smart/Force choice retries the roots that were actually blocked.
func resetCommitsAcrossRoots(_ commit: CommitInfo, mode: ResetMode) {
    guard let projectPath = projectWorkspace.path, multiRootWorkspace.roots.count > 1 else { return }
    GitResetModeSettings.save(GitResetModeChoice(mode), for: projectPath)
    let selectedRootPaths = multiRootWorkspace.roots.map(\.path)
    runMultiRootResetOperation(
        projectPath: projectPath,
        selectedRootPaths: selectedRootPaths,
        commitID: commit.id,
        mode: mode,
        smart: false,
        force: false
    )
}

/// Reset the Log selection with one target revision per owning Git root.
func resetCommitsAcrossRoots(_ commits: [CommitInfo], mode: ResetMode) {
    guard let projectPath = projectWorkspace.path, isResetSelectionAvailable(for: commits) else { return }
    GitResetModeSettings.save(GitResetModeChoice(mode), for: projectPath)
    let targets = commits.compactMap { commit -> MultiRootResetTarget? in
        guard let repository = logRepository(for: commit),
              let rootPath = repository.workdir() else { return nil }
        return MultiRootResetTarget(rootPath: rootPath, commitId: commit.id)
    }
    guard targets.count == commits.count else {
        feedbackCenter.error(
            "Reset unavailable",
            detail: "One or more selected revisions no longer belongs to an available Git root.",
            nextStep: "Refresh the Log and select the revisions again."
        )
        return
    }
    runMultiRootResetOperation(
        projectPath: projectPath,
        selectedRootPaths: targets.map(\.rootPath),
        targetSpecs: targets,
        mode: mode,
        smart: false,
        force: false
    )
}

/// Open the Uncommit chooser against the repository that owns the selected
/// Log commit. This matters in aggregate/multi-root Log: the visible HEAD may
/// belong to a nested repository rather than the primary Commit workspace.
func uncommitFromLog(_ selectedCommit: CommitInfo) {
    guard isUncommitActionAvailable(for: selectedCommit) else {
        feedbackCenter.warning(
            "Undo commit unavailable",
            detail: "Only the current HEAD commit with a parent can be undone.",
            nextStep: "Select the latest commit in the owning Git root."
        )
        return
    }
    guard let selectedRepo = logRepository(for: selectedCommit) else {
        feedbackCenter.error(
            "Undo commit unavailable",
            detail: "The Git root for the selected commit is no longer available.",
            nextStep: "Refresh Git roots and retry."
        )
        return
    }
    let protectedPatterns = effectiveProtectedBranchPatterns
    Task.detached(priority: .userInitiated) {
        do {
            guard let repositoryPath = selectedRepo.workdir() else {
                throw EngineError.GitOperation(message: "Undo commit requires a worktree repository.")
            }
            guard selectedRepo.headCommitId() == selectedCommit.id else {
                throw EngineError.GitOperation(
                    message: "The selected commit is no longer HEAD in its Git root."
                )
            }
            guard let head = try selectedRepo.log(path: nil, limit: 1, follow: false, afterId: nil).first,
                  let parentID = head.parentIds.first else {
                throw EngineError.GitOperation(message: "Undo commit requires a HEAD commit with a parent.")
            }
            let remoteBranches = try selectedRepo.remoteBranchList()
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: selectedRepo,
                commitID: head.id,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Undo commit blocked",
                        detail: "The selected commit is published to protected branch \(protectedBranch).",
                        nextStep: "Fetch or select an unpublished commit before rewriting history."
                    )
                }
                return
            }
            let changes = try selectedRepo.treeChanges(rev1: parentID, rev2: head.id)
            let changedPaths = uncommitChangedPaths(changes)
            let rootChangeLists = try selectedRepo.changelistList()
            let headBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            await MainActor.run {
                self.commitWorkspace.uncommitRequest = RebasedUncommitRequest(
                    commit: head,
                    repositoryPath: repositoryPath,
                    changedPaths: changedPaths,
                    changeLists: rootChangeLists,
                    headBranch: headBranch
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo commit unavailable",
                    detail: errorMessage(error),
                    nextStep: "Select a non-root HEAD commit."
                )
            }
        }
    }
}

func performUncommit(_ request: RebasedUncommitRequest, targetName: String) {
    let restoredCommitMessage = request.commit.messageBody.isEmpty
        ? request.commit.summary
        : "\(request.commit.summary)\n\n\(request.commit.messageBody)"
    beginFeedbackOperation("Undo commit")
    Task.detached(priority: .userInitiated) {
        var didUncommit = false
        do {
            let targetRepo = try openRepository(path: request.repositoryPath)
            guard targetRepo.headCommitId() == request.commit.id else {
                throw EngineError.GitOperation(
                    message: "The selected commit is no longer HEAD in its Git root."
                )
            }
            let normalizedTargetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedTargetName.isEmpty {
                // Create/lookup the target before the destructive soft reset.
                try targetRepo.changelistEnsure(name: normalizedTargetName)
            }
            try targetRepo.uncommitExpectedHead(expectedHead: request.commit.id)
            didUncommit = true
            let statusPaths = Set(try targetRepo.status().map(\.path))
            let assignablePaths = request.changedPaths.filter(statusPaths.contains)
            if !normalizedTargetName.isEmpty, !assignablePaths.isEmpty {
                try targetRepo.changelistMovePaths(paths: assignablePaths, targetName: normalizedTargetName)
            }
            let lists = try targetRepo.changelistList()
            await MainActor.run {
                // IntelliJ restores the undone commit's full message into the
                // Changes workflow so the user can recommit without copying it.
                self.commitWorkspace.message = restoredCommitMessage
                self.commitWorkspace.feedback = "已撤销最近一次提交，变更仍保留在暂存区"
                if self.repo?.workdir() == request.repositoryPath {
                    self.repositoryStatus.changeLists = lists
                    self.refreshAll(showFeedback: false)
                } else {
                    self.loadMultiRoots {
                        if self.logList.viewMode == .command || self.isLogAggregate {
                            self.reloadLogView()
                        }
                    }
                }
                let undoAction = self.uncommitUndoFeedbackAction(for: request)
                self.feedbackCenter.success(
                    "Latest commit undone",
                    detail: normalizedTargetName.isEmpty
                        ? "Changes remain staged"
                        : "Changes moved to \(normalizedTargetName)",
                    additionalActions: undoAction.map { [$0] } ?? [],
                    notificationID: self.uncommitUndoNotificationID(
                        rootPath: request.repositoryPath
                    )
                )
            }
        } catch {
            let uncommitDidComplete = didUncommit
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo commit failed",
                    detail: errorMessage(error),
                    nextStep: uncommitDidComplete
                        ? "Uncommit 已完成，但后续 Changelist 同步失败；先恢复或重新检查当前状态。"
                        : "确认当前提交存在父提交且工作区状态允许 soft reset。",
                    additionalActions: uncommitDidComplete
                        ? (self.uncommitUndoFeedbackAction(for: request).map { [$0] } ?? [])
                        : [],
                    notificationID: uncommitDidComplete
                        ? self.uncommitUndoNotificationID(rootPath: request.repositoryPath)
                        : nil
                )
            }
        }
    }
}

func uncommitUndoNotificationID(rootPath: String) -> String {
    let normalized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.uncommit-undo.\(normalized)"
}

func uncommitUndoRequest(
    for request: RebasedUncommitRequest
) -> ArborVCSActionRequest? {
    guard let expectedHead = request.commit.parentIds.first else { return nil }
    return ArborVCSActionRequest(
        kind: .undoUncommit,
        projectPath: projectWorkspace.path,
        rootPath: request.repositoryPath,
        shelfName: "",
        uncommitCommitID: request.commit.id,
        uncommitExpectedHead: expectedHead,
        uncommitExpectedBranch: request.headBranch ?? ""
    )
}

func uncommitUndoFeedbackAction(
    for request: RebasedUncommitRequest
) -> FeedbackAction? {
    guard let semanticRequest = uncommitUndoRequest(for: request) else { return nil }
    return FeedbackAction(
        id: "undo-uncommit:\(semanticRequest.rootPath ?? ""):\(semanticRequest.uncommitCommitID ?? "")",
        title: "Undo Uncommit",
        semanticAction: semanticRequest
    ) {
        handleVCSActionRequest(semanticRequest)
    }
}

/// Restore the exact commit that was just soft-uncommitted. The engine only
/// moves the ref and checks both the expected parent and branch identity, so
/// local edits made after the Uncommit are never rewritten.
func undoUncommit(
    rootPath: String,
    originalCommitID: String,
    expectedHead: String,
    expectedBranch: String
) {
    beginFeedbackOperation("Undo Uncommit")
    Task.detached(priority: .userInitiated) {
        do {
            let targetRepo = try openRepository(path: rootPath)
            try targetRepo.undoUncommitExpectedHead(
                originalCommitId: originalCommitID,
                expectedHead: expectedHead,
                expectedBranch: expectedBranch
            )
            await MainActor.run {
                self.feedbackCenter.expire(
                    notificationID: self.uncommitUndoNotificationID(rootPath: rootPath)
                )
                let isCurrentRoot = self.repo?.workdir().map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                        == URL(fileURLWithPath: rootPath).standardizedFileURL.path
                } == true
                if isCurrentRoot {
                    self.refreshAll(showFeedback: false)
                } else {
                    self.loadMultiRoots {
                        if self.logList.viewMode == .command || self.isLogAggregate {
                            self.reloadLogView()
                        }
                    }
                }
                self.feedbackCenter.success(
                    "Uncommit undone",
                    detail: "HEAD restored to \(String(originalCommitID.prefix(8)))."
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Uncommit failed",
                    detail: errorMessage(error),
                    nextStep: "The repository changed after Uncommit; review the current branch and retry only if the original HEAD is still intended."
                )
            }
        }
    }
}

/// Undo a successful reword by restoring only the original HEAD ref. The
/// expected HEAD and branch make the operation compare-and-swap safe, while
/// the protected-remote check mirrors IntelliJ's refusal to rewrite published
/// history. No index or worktree materialization is performed.
func undoRewordCommit(
    rootPath: String,
    context: PersistedRewordUndo
) {
    let notificationID = rewordUndoNotificationID(
        rootPath: rootPath,
        expectedHeadID: context.expectedHeadID
    )
    let protectedPatterns = effectiveProtectedBranchPatterns
    beginFeedbackOperation("Undo Reword Commit", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let targetRepo = try openRepository(path: rootPath)
            guard try targetRepo.operationState() == nil else {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit is unavailable while another Git operation is active."
                )
            }
            guard targetRepo.headCommitId() == context.expectedHeadID else {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit refused: HEAD changed after reword."
                )
            }
            let currentBranch = try targetRepo.branchList()
                .first(where: { $0.isCurrent })?.name ?? ""
            guard currentBranch == context.expectedBranch else {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit refused: the current branch changed after reword."
                )
            }
            let remoteBranches = try targetRepo.remoteBranchList()
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: targetRepo,
                commitID: context.initialHeadID,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit blocked: \(protectedBranch) contains the published commit."
                )
            }
            try targetRepo.restoreHeadRefIfExpected(
                initialCommitId: context.initialHeadID,
                expectedCommitId: context.expectedHeadID,
                expectedHeadBranch: context.expectedBranch
            )
            await MainActor.run {
                self.feedbackCenter.expire(notificationID: notificationID)
                let isCurrentRoot = self.repo?.workdir().map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                        == URL(fileURLWithPath: rootPath).standardizedFileURL.path
                } == true
                if isCurrentRoot {
                    self.refreshAll(showFeedback: false)
                } else {
                    self.loadMultiRoots {
                        if self.logList.viewMode == .command || self.isLogAggregate {
                            self.reloadLogView()
                        }
                    }
                }
                self.feedbackCenter.success(
                    "Reword undone",
                    detail: "HEAD restored to \(String(context.initialHeadID.prefix(8)))."
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Reword Commit failed",
                    detail: errorMessage(error),
                    nextStep: "The repository may have changed after reword; review the current HEAD and branch before retrying.",
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Git.FileActions > Checkin Files is scoped to the selected worktree file.
/// Keep the selection in the Commit workspace instead of silently opening the
/// first changed row in the repository.
func beginFileCheckin(_ path: String) {
    guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return }
    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    projectPanelExpanded = false
    shelfWorkspace.isWorkspaceTabActive = false
    fileWorkspace.previewPath = normalizedPath
    fileWorkspace.previewMode = .unstaged
    fileWorkspace.previewComparisonMode = nil
    fileWorkspace.previewThreeVersions = false
    fileWorkspace.previewVisible = true
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
}

struct BeforeCommitCheckError: Error {
    let command: String
    let output: String
}

nonisolated func runBeforeCommitChecks(repo: Repository, commands: [BeforeCommitCommand]) throws {
    for item in commands {
        let outcome = try repo.runCheckCommand(command: item.command, args: item.args)
        guard outcome.success else {
            throw BeforeCommitCheckError(command: item.display, output: outcome.output)
        }
    }
}

struct CommitWarningPresentation: Sendable, Hashable {
    let setting: GitCommitWarningSetting
    let rootLabel: String
    let message: String
}

struct CommitWarningDecision: Sendable {
    let shouldContinue: Bool
    let setCoreAutocrlf: Bool
}

nonisolated func commitWarningOrder(_ setting: GitCommitWarningSetting) -> Int {
    switch setting {
    case .crlf: return 0
    case .largeFile: return 1
    case .detachedHead: return 2
    case .badFileName: return 3
    }
}

nonisolated func commitWarningPresentations(
    _ checks: [CommitCheckResult],
    rootLabel: String,
    projectPath: String?
) -> [CommitWarningPresentation] {
    checks.compactMap { check in
        guard !check.blocking,
              let setting = commitWarningSetting(for: check.kind),
              GitCommitWarningSettings.warningEnabled(setting, for: projectPath) else {
            return nil
        }
        return CommitWarningPresentation(
            setting: setting,
            rootLabel: rootLabel,
            message: check.message
        )
    }.sorted { lhs, rhs in
        commitWarningOrder(lhs.setting) < commitWarningOrder(rhs.setting)
    }
}

func presentCommitWarningDecision(
    _ warnings: [CommitWarningPresentation],
    projectPath: String?
) -> CommitWarningDecision {
    guard !warnings.isEmpty else {
        return CommitWarningDecision(shouldContinue: true, setCoreAutocrlf: false)
    }

    // IntelliJ runs CommitCheck handlers in order and presents the first
    // unresolved CommitProblem as a modal decision. Keeping one warning per
    // dialog matters when a commit spans multiple roots: the user can accept
    // a large-file warning while still cancelling a later detached-HEAD or
    // filename warning, and each "don't warn again" choice remains scoped to
    // its own warning category.
    var setCoreAutocrlf = false
    var seenSettings = Set<GitCommitWarningSetting>()
    for warning in warnings {
        guard !seenSettings.contains(warning.setting) else { continue }

        let alert = NSAlert()
        alert.messageText = "Commit warning: \(warning.setting.title)"
        let prefix = warning.rootLabel.isEmpty ? "" : "\(warning.rootLabel): "
        alert.informativeText = "\(prefix)\(warning.message)"
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't warn about this again in this project"
        if warning.setting == .crlf {
            alert.addButton(withTitle: "Set core.autocrlf and Commit")
        }
        alert.addButton(withTitle: "Commit Anyway")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let isCrlfFix = warning.setting == .crlf
            && response == .alertFirstButtonReturn
        let commitResponse: NSApplication.ModalResponse = warning.setting == .crlf
            ? .alertSecondButtonReturn
            : .alertFirstButtonReturn
        guard isCrlfFix || response == commitResponse else {
            return CommitWarningDecision(shouldContinue: false, setCoreAutocrlf: false)
        }
        seenSettings.insert(warning.setting)

        if alert.suppressionButton?.state == .on {
            if !(isCrlfFix && warning.setting == .crlf) {
                GitCommitWarningSettings.saveWarning(false, warning.setting, for: projectPath)
            }
        }
        if isCrlfFix {
            setCoreAutocrlf = true
        }
    }
    return CommitWarningDecision(
        shouldContinue: true,
        setCoreAutocrlf: setCoreAutocrlf
    )
}

nonisolated func collectMultiRootCommitWarnings(
    rootPaths: [String],
    selectedChanges: [MultiRootChangeSelection]?,
    projectPath: String?
) throws -> [CommitWarningPresentation] {
    let selectedPathsByRoot = selectedChanges.map {
        Dictionary(grouping: normalizedMultiRootCommitSelections($0), by: \.rootPath)
            .mapValues { selections in Array(Set(selections.map(\.path)).sorted()) }
    }
    let largeFileLimitBytes = GitCommitWarningSettings.largeFileLimitBytes(for: projectPath)
    var warnings: [CommitWarningPresentation] = []
    for rootPath in rootPaths {
        let repository = try openRepository(path: rootPath)
        let checks: [CommitCheckResult]
        if let paths = selectedPathsByRoot?[rootPath], !paths.isEmpty {
            checks = try repository.commitChecksWithLargeFileLimitForPaths(
                maxFileSizeBytes: largeFileLimitBytes,
                paths: paths
            )
        } else {
            checks = try repository.commitChecksWithLargeFileLimit(
                maxFileSizeBytes: largeFileLimitBytes
            )
        }
        let rootLabel = URL(fileURLWithPath: rootPath).lastPathComponent
        warnings.append(contentsOf: commitWarningPresentations(
            checks,
            rootLabel: rootLabel,
            projectPath: projectPath
        ))
    }
    return warnings
}

func doCommit(forceChecks: Bool = false, rebaseAfterCommit: Bool = false) {
    guard let repo, !commitWorkspace.message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    let isRebaseEditAmend = commitWorkspace.amendMode && rebaseEditPauseAllowsAmend(operationRecovery.operation)
    guard operationRecovery.operation == nil || isRebaseEditAmend else { return }
    beginFeedbackOperation(commitWorkspace.amendMode ? "Amend commit" : "Commit")
    let msg = commitWorkspace.message
    let isAmend = commitWorkspace.amendMode
    let hooks = GitCommitHooksSettings.effectiveSkipHooks(requested: self.commitWorkspace.skipHooks)
    let checks = commitWorkspace.beforeCommitCommands
    let authorName = gitSettings.identityAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorEmail = gitSettings.identityAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerName = gitSettings.identityCommitterName.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerEmail = gitSettings.identityCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let signOff = gitSettings.identitySignOff
    let coAuthors = parseCoAuthors(gitSettings.identityCoAuthors)
    let pendingRebase = rebaseAfterCommit ? rebaseWorkspace.pendingAutoSquash : nil
    let operationProjectPath = projectWorkspace.path
    let operationRootPath = repo.workdir() ?? ""
    let operationRootLabel = operationRootPath.isEmpty
        ? ""
        : URL(fileURLWithPath: operationRootPath).lastPathComponent
    rememberCommitAuthor(
        name: authorName,
        email: authorEmail,
        projectPath: operationProjectPath
    )
    Task.detached(priority: .userInitiated) {
        do {
            // COMMIT-001 内置检查:身份缺失/未解决冲突(阻塞),大文件/CRLF/detached(警告)
            let builtin = try repo.commitChecksWithLargeFileLimit(
                maxFileSizeBytes: GitCommitWarningSettings.largeFileLimitBytes(
                    for: operationProjectPath
                )
            )
            let blocking = builtin.filter { $0.blocking }
            if !blocking.isEmpty {
                await MainActor.run {
                    self.commitWorkspace.pendingCommitAndPush = false
                    let kinds = blocking.map { $0.kind }.map { kind -> String in
                        switch kind {
                        case .identityMissing: return "Git 身份未配置 (user.name / user.email)"
                        case .unresolvedConflicts: return "存在未解决冲突"
                        default: return "提交被内置检查阻止"
                        }
                    }
                    self.feedbackCenter.error(
                        "Commit blocked",
                        detail: kinds.joined(separator: "\n"),
                        nextStep: "配置身份或解决冲突后重试。"
                    )
                    if blocking.contains(where: { $0.kind == .identityMissing }) {
                        self.gitSettings.pendingIdentityCommitRetry = true
                        self.gitSettings.showIdentitySettings = true
                    }
                }
                return
            }
            let warningPresentations = commitWarningPresentations(
                builtin,
                rootLabel: operationRootLabel,
                projectPath: operationProjectPath
            )
            if !warningPresentations.isEmpty {
                let decision = await MainActor.run {
                    presentCommitWarningDecision(
                        warningPresentations,
                        projectPath: operationProjectPath
                    )
                }
                guard decision.shouldContinue else {
                    await MainActor.run {
                        self.commitWorkspace.pendingCommitAndPush = false
                        self.commitWorkspace.feedback = "Commit cancelled"
                        self.feedbackCenter.warning(
                            "Commit cancelled",
                            detail: "Review the pre-commit warnings before committing.",
                            notificationID: operationRootLabel.isEmpty
                                ? nil
                                : self.commitNotificationID(rootPath: operationRootPath)
                        )
                    }
                    return
                }
                if decision.setCoreAutocrlf {
                    try? repo.setGlobalCoreAutocrlf()
                }
            }
            if !forceChecks {
                try runBeforeCommitChecks(repo: repo, commands: checks)
            }
            let identity = (try? repo.gitIdentity())
            let hasOverrides = !authorName.isEmpty || !authorEmail.isEmpty || !committerName.isEmpty || !committerEmail.isEmpty || signOff || !coAuthors.isEmpty
            let id = if identity?.signCommits == true || hasOverrides {
                try withArborPinentrySession {
                    try repo.commitWithOptions(
                        message: msg,
                        skipHooks: hooks,
                        authorName: authorName.isEmpty ? nil : authorName,
                        authorEmail: authorEmail.isEmpty ? nil : authorEmail,
                        committerName: committerName.isEmpty ? nil : committerName,
                        committerEmail: committerEmail.isEmpty ? nil : committerEmail,
                        signKey: identity?.signingKey,
                        signOff: signOff,
                        coAuthors: coAuthors,
                        amend: isAmend
                    )
                }
            } else if isAmend {
                try repo.amend(message: msg, skipHooks: hooks)
            } else {
                try repo.commit(message: msg, skipHooks: hooks)
            }
            let st = try repo.status(); let hid = repo.headCommitId()
            let repositoryPath = repo.workdir()
            let recent = (try? repo.recentCommitMessages(limit: 10)) ?? []
            let staging = try? repo.stagingModel()
            let branchList = (try? repo.branchList()) ?? []
            let syncStatuses = (try? repo.syncStatus()) ?? []
            await MainActor.run {
                self.repositoryStatus.entries = st; self.repositoryStatus.headId = hid
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.branchWorkspace.branches = branchList
                self.branchWorkspace.syncStatuses = syncStatuses
                self.logSelectionState.detailCommit = nil
                if self.projectWorkspace.toolWindowMode == .log {
                    // The Log workspace stays live beside Commit in Rebased;
                    // committing from the left pane must immediately move
                    // the graph and inspector to the new HEAD.
                    self.loadLog()
                }
                self.commitWorkspace.recentMessages = recent
                self.commitWorkspace.message = ""
                if isRebaseEditAmend {
                    self.refreshAll(showFeedback: false)
                    let recoveryActions = repositoryPath.flatMap { rootPath in
                        self.operationRecovery.operation.map {
                            self.operationRecoveryFeedbackActions(
                                state: $0,
                                rootPath: rootPath
                            )
                        }
                    } ?? []
                    self.commitWorkspace.feedback = "已 Amend rebase edit \(String(id.prefix(7)))"
                    self.feedbackCenter.success(
                        "Rebase commit amended",
                        detail: "\(String(id.prefix(7)))；请从恢复栏 Continue Rebase。",
                        additionalActions: recoveryActions,
                        notificationID: repositoryPath.map {
                            operationRecoveryNotificationID(rootPath: $0)
                        },
                        notificationGroup: .standard,
                        localized: false
                    )
                    return
                }
                let shouldOpenPushDialog = self.commitWorkspace.pendingCommitAndPush
                self.commitWorkspace.pendingCommitAndPush = false
                self.rebaseWorkspace.pendingAutoSquash = nil
                self.commitWorkspace.feedback = isAmend
                    ? "已 Amend \(String(id.prefix(7)))"
                    : "已提交 \(String(id.prefix(7)))"
                let rewordAction = repositoryPath.map {
                    self.commitRewordFeedbackAction(rootPath: $0, commitID: id)
                }
                self.feedbackCenter.success(
                    isAmend ? "Amend completed" : "Commit completed",
                    detail: String(id.prefix(7)),
                    additionalActions: rewordAction.map { [$0] } ?? [],
                    notificationID: repositoryPath.map(self.commitNotificationID)
                )
                if shouldOpenPushDialog, let repositoryPath {
                    self.beginSingleRootPushAfterCommit(rootPath: repositoryPath)
                }
                if let pendingRebase {
                    let hasResidualChanges = st.contains {
                        $0.staged != .unchanged
                            || $0.unstaged != .unchanged
                    }
                    if hasResidualChanges {
                        self.commitWorkspace.feedback = "已提交；为保护未提交改动，未自动变基"
                        self.feedbackCenter.warning(
                            "Commit completed; rebase skipped",
                            detail: "Uncommitted changes remain after the partial commit.",
                            nextStep: "Review or stash the remaining changes, then run the rebase again."
                        )
                    } else {
                        self.startAutoSquashRebase(
                            onto: pendingRebase.onto,
                            targetID: pendingRebase.targetID,
                            root: pendingRebase.root
                        )
                    }
                }
            }
        } catch {
            await MainActor.run {
                if let checkError = error as? BeforeCommitCheckError {
                    self.feedbackCenter.warning(
                        "Commit checks failed",
                        detail: "\(checkError.command)\n\n\(checkError.output)",
                        nextStep: "Review the check output, then retry or choose the force action."
                    )
                    let alert = NSAlert()
                    alert.messageText = "提交前检查失败"
                    alert.informativeText = "\(checkError.command)\n\n\(checkError.output)"
                    alert.addButton(withTitle: "强制提交")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        self.doCommit(forceChecks: true, rebaseAfterCommit: rebaseAfterCommit)
                    } else {
                        self.commitWorkspace.pendingCommitAndPush = false
                    }
                    return
                }
                self.commitWorkspace.pendingCommitAndPush = false
                self.commitWorkspace.feedback = errorMessage(error)
                self.repositoryStatus.loadError = self.commitWorkspace.feedback
                let detail = errorMessage(error)
                if gitCommitSigningFailureNeedsGPGConfiguration(detail) {
                    self.feedbackCenter.error(
                        "Commit signing failed",
                        detail: detail,
                        nextStep: "Install GnuPG if needed, or configure a working pinentry program, then retry the commit.",
                        additionalActions: [self.gpgAgentSettingsFeedbackAction()],
                        notificationID: self.repo?.workdir().map(self.commitNotificationID)
                    )
                }
            }
        }
    }
}

/// IntelliJ's Git.Stage.ToggleCommitAll path: when nothing is staged, commit
/// all tracked worktree changes without adding untracked files implicitly.
/// The explicit Stage All action remains available for users who also want to
/// include untracked files.
func commitAllTrackedChanges() {
    guard let repo,
          !commitWorkspace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          repositoryStatus.entries.contains(where: {
              $0.staged != .conflicted
                  && $0.unstaged != .conflicted
                  && $0.unstaged != .unchanged
                  && $0.unstaged != .untracked
                  && $0.unstaged != .ignored
          }) else { return }
    beginFeedbackOperation("Commit all tracked changes")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stageTracked()
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                self.doCommit()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Commit All failed",
                    detail: errorMessage(error),
                    nextStep: "Check the tracked changes and retry."
                )
            }
        }
    }
}

/// REBASE-002：从 Log 的提交上下文菜单预配置单提交改写动作。
/// 仍然交给 todo 编辑器确认，避免上下文菜单直接执行不可逆的历史重写。
func rewriteCommitFromLog(
    _ commit: CommitInfo,
    action: RebaseTodoAction,
    initialCommitConfirmed: Bool = false
) {
    guard let repo = logRepository(for: commit) else { return }
    guard (try? repo.isCommitReachableFrom(commitId: commit.id, descendantId: "HEAD")) == true else {
        feedbackCenter.error(
            "Rewrite commit unavailable",
            detail: "The selected commit is not on the current branch's linear history.",
            nextStep: "Select a commit from the current branch and retry."
        )
        return
    }
    if let protectedBranch = protectedRemoteBranchContainingCommit(
        repo: repo,
        commitID: commit.id,
        remoteBranches: activeLogRemoteBranches,
        protectedPatterns: effectiveProtectedBranchPatterns
    ) {
        feedbackCenter.error(
            "History rewrite blocked",
            detail: "The selected commit is published to protected branch \(protectedBranch).",
            nextStep: "Fetch or select an unpublished commit before rewriting history."
        )
        return
    }

    // IntelliJ uses `git commit --amend --only` for the latest commit. Keep
    // this fast path separate from the todo editor: a Log reword must never
    // absorb unrelated staged changes from the Commit workspace.
    if action == .reword, commit.isHead {
        logRewrite.rewordUsesRootRebase = false
        logRewrite.rewordCommit = commit
        logRewrite.rewordMessage = commit.messageBody.isEmpty
            ? commit.summary
            : "\(commit.summary)\n\n\(commit.messageBody)"
        if commit.parentIds.isEmpty {
            logRewrite.pendingInitialCommitReword = commit
            logRewrite.showInitialCommitRewordAlert = true
        } else {
            logRewrite.showRewordDialog = true
        }
        return
    }
    if action == .reword, commit.parentIds.isEmpty {
        // IntelliJ uses `git rebase --root` when the selected root is not
        // HEAD. Keep the same full-message editor, but route confirmation to
        // the engine's clean linear root-history rewrite path.
        logRewrite.rewordUsesRootRebase = true
        logRewrite.rewordCommit = commit
        logRewrite.rewordMessage = commit.messageBody.isEmpty
            ? commit.summary
            : "\(commit.summary)\n\n\(commit.messageBody)"
        logRewrite.showRewordDialog = true
        return
    }
    if action == .drop, commit.parentIds.isEmpty {
        if !initialCommitConfirmed {
            logRewrite.pendingInitialCommitRewrite = PendingInitialCommitRewrite(
                commits: [commit],
                action: action
            )
            logRewrite.showInitialCommitRewriteAlert = true
            return
        }
        dropSelectedCommitsFromLog([commit], repository: repo)
        return
    }
    guard let firstParent = commit.parentIds.first else {
        feedbackCenter.error(
            "Rewrite commit unavailable",
            detail: "The initial commit can only be reworded when it is HEAD.",
            nextStep: "Check out the branch containing the initial commit, then retry."
        )
        return
    }
    if commit.parentIds.count > 1 {
        feedbackCenter.error(
            "Rewrite commit unavailable",
            detail: "Merge commits are not supported by the linear todo editor.",
            nextStep: "Use a regular interactive rebase with merge preservation."
        )
        return
    }
    if action == .drop {
        dropSelectedCommitsFromLog([commit], repository: repo)
        return
    }

    beginFeedbackOperation("Prepare Commit Rewrite")
    Task.detached(priority: .userInitiated) {
        do {
            let onto: String
            switch action {
            case .squash, .fixup:
                let previous = try repo.logFiltered(
                    path: nil,
                    limit: 1,
                    follow: false,
                    startRev: firstParent,
                    author: nil,
                    since: nil
                ).first
                guard let previous,
                      let previousParent = previous.parentIds.first else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected commit has no previous commit to combine with."]
                    )
                }
                onto = previousParent
            default:
                onto = firstParent
            }

            var todo = try repo.rebaseTodo(onto: onto, autoSquash: false)
            guard let targetIndex = todo.items.firstIndex(where: { item in
                item.commitId == commit.id
                    || item.commitId.hasPrefix(commit.id)
                    || commit.id.hasPrefix(item.commitId)
            }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commit is not on the current branch's linear history."]
                )
            }
            todo.items[targetIndex].action = action
            let preparedItems = todo.items

            await MainActor.run {
                self.rebaseWorkspace.todoOnto = onto
                self.rebaseWorkspace.todoItems = preparedItems
                self.rebaseWorkspace.todoPreserveMerges = false
                self.rebaseWorkspace.todoRoot = false
                self.rebaseWorkspace.showTodoEditor = true
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Prepare commit rewrite failed",
                    detail: errorMessage(error),
                    nextStep: "The action applies only to a linear commit on the current branch."
                )
            }
        }
    }
}

/// Continue the IntelliJ-style initial-commit warning into the normal full
/// message editor. The engine still uses `--amend --only`, which also works
/// for a root HEAD commit without importing staged changes.
func confirmInitialCommitReword() {
    guard let commit = logRewrite.pendingInitialCommitReword else { return }
    logRewrite.pendingInitialCommitReword = nil
    logRewrite.rewordUsesRootRebase = false
    logRewrite.rewordCommit = commit
    logRewrite.rewordMessage = commit.messageBody.isEmpty
        ? commit.summary
        : "\(commit.summary)\n\n\(commit.messageBody)"
    logRewrite.showRewordDialog = true
}

/// Execute IntelliJ's direct multi-commit Drop path. The engine still builds
/// and validates the explicit todo, but the user gets the native action
/// confirmation instead of an intermediate todo editor.
func dropSelectedCommitsFromLog(_ commits: [CommitInfo], repository repo: Repository) {
    // IntelliJ permits Log Drop while HEAD is detached. Keep an empty branch
    // identity so the same expected-HEAD Undo/CAS path can validate detached
    // state without inventing a ref to update.
    let branch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""

    if GitDropCommitSettings.showConfirmation() {
        let alert = NSAlert()
        alert.messageText = commits.count == 1 ? "Drop this commit?" : "Drop selected commits?"
        let summaries = commits.prefix(3).map { $0.summary }.joined(separator: ", ")
        let suffix = commits.count > 3 ? " …" : ""
        let noun = commits.count == 1 ? "commit" : "commits"
        let destination = branch.isEmpty ? "detached HEAD" : branch
        alert.informativeText = String(commits.count) + " " + noun + " will be removed from " + destination + " and the history will be rewritten. " + summaries + suffix
        alert.addButton(withTitle: commits.count == 1 ? "Drop Commit" : "Drop Commits")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    let repositoryPath = repo.workdir() ?? ""
    let commitIDs = commits.map { $0.id }
    let commitSummaries = commits.map { $0.summary }
    let protectedPatterns = effectiveProtectedBranchPatterns
    let remoteBranchesForRewrite = activeLogRemoteBranches
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    let useInMemory = shouldUseInMemoryCommitEditing(
        settingEnabled: GitInMemoryCommitEditingSettings.isEnabled(),
        items: [],
        preserveMerges: false
    )
    beginFeedbackOperation("Drop Commits", cancelHandle: cancel)

    Task.detached(priority: .userInitiated) {
        do {
            guard commitIDs.allSatisfy({
                (try? repo.isCommitReachableFrom(
                    commitId: $0,
                    descendantId: "HEAD"
                )) == true
            }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected commit is not on the current branch's linear history."
                    ]
                )
            }
            if let protectedBranch = commitIDs.compactMap({ commitID in
                protectedRemoteBranchContainingCommit(
                    repo: repo,
                    commitID: commitID,
                    remoteBranches: remoteBranchesForRewrite,
                    protectedPatterns: protectedPatterns
                )
            }).first {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected commit is published to protected branch \(protectedBranch)."
                    ]
                )
            }

            guard let initialHead = repo.headCommitId() else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Drop Commits requires a checked-out commit."]
                )
            }
            let seed = RebaseUndoSeed(
                repositoryPath: repositoryPath,
                branch: branch,
                initialHead: initialHead,
                updateRefs: false
            )
            saveRebaseUndoSeed(seed)
            let runNativeDrop: () throws -> RebaseOutcome = {
                try repo.dropSelectedCommitsNativeWithPolicyAndCancel(
                    commitIds: commitIDs,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            }
            let outcome: RebaseOutcome
            if useInMemory {
                let inMemoryOutcome = try repo.dropSelectedCommitsWithPolicyAndCancel(
                    commitIds: commitIDs,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
                if inMemoryOutcome.paused, inMemoryOutcome.pauseReason == .conflict {
                    // IntelliJ drops the partial object-level rewrite before
                    // retrying native Git, so the native path sees the same
                    // original HEAD and local scene as the first attempt.
                    try repo.rebaseAbort()
                    outcome = try runNativeDrop()
                } else {
                    outcome = inMemoryOutcome
                }
            } else {
                outcome = try runNativeDrop()
            }
            let status = try repo.status()
            let finalHead = repo.headCommitId()
            let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )

            await MainActor.run {
                self.repositoryStatus.entries = status
                self.rebaseWorkspace.range = []
                self.rebaseWorkspace.actions = []
                self.rebaseWorkspace.todoItems = []
                self.rebaseWorkspace.todoRoot = false
                self.rebaseWorkspace.showTodoEditor = false
                self.rebaseWorkspace.paused = outcome.paused
                self.rebaseWorkspace.pauseReason = outcome.pauseReason
                self.rebaseWorkspace.conflicts = outcome.conflicts
                if outcome.paused, outcome.pauseReason == .conflict {
                    let names = outcome.conflicts.prefix(3).joined(separator: "、")
                    let suffix = names.isEmpty ? "" : "：\(names)"
                    self.rebaseWorkspace.feedback = "Drop Commits 冲突 \(outcome.conflicts.count) 个文件\(suffix)，请解决后「继续」"
                    self.operationRecovery.showConflictResolver = true
                } else if outcome.paused {
                    self.rebaseWorkspace.feedback = "Drop Commits 已暂停，可修改文件后「继续」"
                } else {
                    self.rebaseWorkspace.feedback = "已删除 \(commitIDs.count) 个提交"
                }
                self.rebaseWorkspace.undoSeed = outcome.paused ? seed : nil
                self.rebaseWorkspace.undoTarget = outcome.paused ? nil : undoTarget
                if outcome.paused {
                    saveRebaseUndoSeed(seed)
                } else {
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                if let undoTarget {
                    self.feedbackCenter.success(
                        "Drop Commits completed",
                        detail: commitSummaries.prefix(3).joined(separator: ", "),
                        additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                        notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                        notificationGroup: .standard
                    )
                } else if !outcome.paused {
                    self.feedbackCenter.success(
                        "Drop Commits completed",
                        detail: commitSummaries.prefix(3).joined(separator: ", "),
                        notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                        notificationGroup: .standard
                    )
                }
                self.logSelectionState.selection = nil
                self.refreshAll(showFeedback: false)
                self.loadLog()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.rebaseWorkspace.feedback = "Drop Commits 已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Drop Commits cancelled",
                        detail: self.rebaseWorkspace.feedback ?? "保存的本地现场未被丢弃",
                        nextStep: "Check Saved Changes or Stash, then retry when the repository is ready.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repositoryPath
                        ).map { [$0] } ?? []
                    )
                }
                return
            }
            await MainActor.run {
                if (try? repo.operationState())?.kind != .rebase {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = nil
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                self.feedbackCenter.error(
                    "Drop Commits failed",
                    detail: errorMessage(error),
                    nextStep: "The operation only accepts linear commits on the checked-out history; resolve any preserved local-change conflict or Abort the paused rebase."
                )
            }
        }
    }
}

/// REBASE-003：从 Log 多选提交预配置批量 reword/squash/drop。
/// 多选动作只接受当前分支上的线性提交；root 可用于 Reword/Squash/Drop，
/// 其中 Drop 仍保持 merge-preserving 边界。Squash 使用独立完整消息
/// 对话框，Reword 仍交给 todo 编辑器确认，Drop 使用 IntelliJ 的直接确认执行路径。
func rewriteSelectedCommitsFromLog(
    _ commits: [CommitInfo],
    action: RebaseTodoAction,
    initialCommitConfirmed: Bool = false
) {
    guard let repo = logRepository(for: commits) else {
        feedbackCenter.warning("Batch rewrite unavailable", detail: "Selected commits must belong to one Git root.", nextStep: "Select commits from one repository and retry.")
        return
    }
    var seenCommitIDs = Set<String>()
    let selected = commits.filter { commit in
        seenCommitIDs.insert(commit.id).inserted
    }
    guard selected.count >= 2 else {
        feedbackCenter.warning(
            "Select at least two commits",
            detail: "Batch rewrite needs multiple selected commits.",
            nextStep: "Use Cmd-click or Shift-click in the Log graph."
        )
        return
    }
    guard action == .reword || action == .squash || action == .drop else {
        feedbackCenter.error(
            "Batch rewrite unavailable",
            detail: "Only reword, squash, and drop support multi-selection from Log.",
            nextStep: "Use the interactive rebase editor for other actions."
        )
        return
    }
    if action == .drop {
        guard selected.allSatisfy({ $0.parentIds.count <= 1 }) else {
            feedbackCenter.error(
                "Batch drop unavailable",
                detail: "Merge commits cannot be dropped by the linear multi-selection action.",
                nextStep: "Use Interactive Rebase with the appropriate history-preserving mode."
            )
            return
        }
        dropSelectedCommitsFromLog(selected, repository: repo)
        return
    }

    guard selected.allSatisfy({ $0.parentIds.count <= 1 }) else {
        feedbackCenter.error(
            "Batch rewrite unavailable",
            detail: "Merge commits cannot be rewritten by the linear multi-selection action.",
            nextStep: "Use Interactive Rebase with merge preservation instead."
        )
        return
    }

    if selected.contains(where: { $0.parentIds.isEmpty }), !initialCommitConfirmed {
        logRewrite.pendingInitialCommitRewrite = PendingInitialCommitRewrite(
            commits: selected,
            action: action
        )
        logRewrite.showInitialCommitRewriteAlert = true
        return
    }

    beginFeedbackOperation("Prepare Batch Commit Rewrite")
    let protectedPatterns = effectiveProtectedBranchPatterns
    let remoteBranchesForRewrite = activeLogRemoteBranches
    Task.detached(priority: .userInitiated) {
        do {
            guard selected.allSatisfy({
                (try? repo.isCommitReachableFrom(
                    commitId: $0.id,
                    descendantId: "HEAD"
                )) == true
            }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commit is not on the current branch's linear history."]
                )
            }
            guard let oldest = oldestSelectedLinearCommit(
                selected,
                isAncestor: { ancestor, descendant in
                    (try? repo.isCommitReachableFrom(
                        commitId: ancestor,
                        descendantId: descendant
                    )) == true
                }
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commits do not form one linear history range."]
                )
            }
            let rootRebase = oldest.parentIds.isEmpty
            let onto = oldest.parentIds.first ?? ""
            if let protectedBranch = selected.compactMap({ commit in
                protectedRemoteBranchContainingCommit(
                    repo: repo,
                    commitID: commit.id,
                    remoteBranches: remoteBranchesForRewrite,
                    protectedPatterns: protectedPatterns
                )
            }).first {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commit is published to protected branch \(protectedBranch)."]
                )
            }
            var todo: RebaseTodo = if rootRebase {
                try repo.rebaseRootTodo(autoSquash: false, preserveMerges: false)
            } else {
                try repo.rebaseTodo(onto: onto, autoSquash: false)
            }
            let indexes = selected.map { commit in
                todo.items.firstIndex { item in
                    item.commitId == commit.id
                        || item.commitId.hasPrefix(commit.id)
                        || commit.id.hasPrefix(item.commitId)
                }
            }
            guard indexes.allSatisfy({ $0 != nil }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "One or more selected commits are not on the current branch's linear history."]
                )
            }
            let sortedIndexes = indexes.compactMap { $0 }.sorted()
            guard sortedIndexes.count == selected.count else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commits could not be mapped to one rebase range."]
                )
            }
            let squashCommits: [CommitInfo]
            let preparedSquashIndexes: [Int]
            if action == .squash {
                // IntelliJ's in-memory `unite` moves selected entries next to
                // the first selected entry, preserving their history order,
                // then turns that group into one squash. Do the same before
                // presenting the standalone message editor so non-contiguous
                // selection does not silently lose its intended semantics.
                let selectedTodoIDs = Set(sortedIndexes.map { todo.items[$0].commitId })
                let selectedItems = sortedIndexes.map { todo.items[$0] }
                let insertionIndex = sortedIndexes[0]
                let remainingItems = todo.items.filter { !selectedTodoIDs.contains($0.commitId) }
                var reorderedItems = remainingItems
                reorderedItems.insert(contentsOf: selectedItems, at: insertionIndex)
                todo.items = reorderedItems
                preparedSquashIndexes = Array(insertionIndex..<(insertionIndex + selectedItems.count))
                squashCommits = selectedItems.compactMap { item in
                    let todoID = item.commitId
                    return selected.first { commit in
                        commit.id == todoID
                            || todoID.hasPrefix(commit.id)
                            || commit.id.hasPrefix(todoID)
                    }
                }
                guard squashCommits.count == selectedItems.count else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "The selected commits could not be loaded for the Squash message."]
                    )
                }
            } else if action == .reword {
                preparedSquashIndexes = sortedIndexes
                squashCommits = []
                for index in sortedIndexes {
                    todo.items[index].action = .reword
                    // The todo editor exposes each message field so every
                    // selected commit can be changed independently before
                    // the destructive operation starts.
                    todo.items[index].message = todo.items[index].summary
                }
            } else {
                preparedSquashIndexes = sortedIndexes
                squashCommits = []
                for index in sortedIndexes {
                    todo.items[index].action = .drop
                }
            }
            let preparedItems = todo.items
            let squashSummaries = squashCommits.map(\.summary)
            let squashMessage = prettySquashMessage(squashCommits)
            await MainActor.run {
                self.rebaseWorkspace.todoOnto = onto
                self.rebaseWorkspace.todoItems = preparedItems
                self.rebaseWorkspace.todoPreserveMerges = false
                self.rebaseWorkspace.todoRoot = rootRebase
                if action == .squash {
                    self.logRewrite.squashIndexes = preparedSquashIndexes
                    self.logRewrite.squashSummaries = squashSummaries
                    self.logRewrite.squashMessage = squashMessage
                    self.feedbackCenter.success(
                        "Squash message ready",
                        detail: "Edit the combined message before rewriting \(squashSummaries.count) commits."
                    )
                    self.logRewrite.showSquashDialog = true
                } else {
                    self.rebaseWorkspace.showTodoEditor = true
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Prepare batch rewrite failed",
                    detail: errorMessage(error),
                    nextStep: action == .squash
                        ? "Select linear commits on the current branch, then retry."
                        : "Select linear commits from the current branch, then retry."
                )
            }
        }
    }
}

/// Continue the IntelliJ-style warning shown before a multi-selection that
/// includes the initial commit enters the root todo editor.
func confirmInitialCommitRewrite() {
    guard let pending = logRewrite.pendingInitialCommitRewrite else { return }
    logRewrite.pendingInitialCommitRewrite = nil
    if pending.commits.count == 1,
       let commit = pending.commits.first,
       pending.action == .drop {
        rewriteCommitFromLog(commit, action: pending.action, initialCommitConfirmed: true)
    } else {
        rewriteSelectedCommitsFromLog(
            pending.commits,
            action: pending.action,
            initialCommitConfirmed: true
        )
    }
}

/// Open the project-level Changes Browser without widening the write boundary
/// of the existing single-root commit workspace.
func openMultiRootCommitDialog(_ selectedChanges: [MultiRootChangeSelection]? = nil) {
    commitWorkspace.multiRootSelectedPaths = selectedChanges
    commitWorkspace.multiRootMessage = ""
    commitWorkspace.multiRootRecentMessages = []
    commitWorkspace.multiRootAmendMode = false
    commitWorkspace.multiRootSkipHooks = commitWorkspace.skipHooks
    commitWorkspace.multiRootAuthorName = gitSettings.identityAuthorName
    commitWorkspace.multiRootAuthorEmail = gitSettings.identityAuthorEmail
    commitWorkspace.multiRootCommitterName = gitSettings.identityCommitterName
    commitWorkspace.multiRootCommitterEmail = gitSettings.identityCommitterEmail
    commitWorkspace.multiRootSignOff = gitSettings.identitySignOff
    commitWorkspace.multiRootCoAuthors = gitSettings.identityCoAuthors
    commitWorkspace.showMultiRootDialog = true
    loadMultiRootChanges()
    loadMultiRootCommitMetadata(rootPaths: multiRootWorkspace.roots.map(\.path))
}

func currentMultiRootCommitOptions() -> MultiRootCommitOptions {
    MultiRootCommitOptions(
        skipHooks: commitWorkspace.multiRootSkipHooks,
        authorName: commitWorkspace.multiRootAuthorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootAuthorName.trimmingCharacters(in: .whitespacesAndNewlines),
        authorEmail: commitWorkspace.multiRootAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines),
        committerName: commitWorkspace.multiRootCommitterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootCommitterName.trimmingCharacters(in: .whitespacesAndNewlines),
        committerEmail: commitWorkspace.multiRootCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines),
        signOff: commitWorkspace.multiRootSignOff,
        coAuthors: parseCoAuthors(commitWorkspace.multiRootCoAuthors),
        amend: commitWorkspace.multiRootAmendMode,
        runBeforeCommitChecks: true,
        beforeCommitCommands: commitWorkspace.beforeCommitCommands.map {
            MultiRootCommitCheck(command: $0.command, args: $0.args)
        }
    )
}

/// Commit a validated message only in the repositories explicitly selected by
/// the project-level Commit dialog. The engine returns a root-qualified
/// partial result, including clean and unselected roots as skipped entries.
func commitMultiRootSelectedRoots(_ rootPaths: [String], _ message: String) {
    let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootPaths.isEmpty, !commitMessage.isEmpty else { return }

    let options = currentMultiRootCommitOptions()

    performMultiRootCommit(
        rootPaths: rootPaths,
        message: commitMessage,
        options: options,
        allowForceRetry: true,
        pushAfterCommit: false
    )
}

/// Commit only the root-qualified files selected in the project-level Changes
/// Browser. The selected rows are normalized before crossing the FFI boundary
/// so identical relative paths in different Git roots remain independent.
func commitMultiRootSelectedChanges(
    _ selectedChanges: [MultiRootChangeSelection],
    _ message: String
) {
    let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedChanges = normalizedMultiRootCommitSelections(selectedChanges)
    guard !normalizedChanges.isEmpty, !commitMessage.isEmpty else { return }

    performMultiRootCommit(
        rootPaths: Array(Set(normalizedChanges.map(\.rootPath))).sorted(),
        message: commitMessage,
        options: currentMultiRootCommitOptions(),
        allowForceRetry: true,
        pushAfterCommit: false,
        selectedChanges: normalizedChanges
    )
}

/// Execute a project-level commit and, when a custom before-commit command
/// fails, offer IntelliJ's explicit Commit Anyway decision for only those
/// roots. Built-in identity/conflict checks remain enforced by Rust.
func performMultiRootCommit(
    rootPaths: [String],
    message: String,
    options requestedOptions: MultiRootCommitOptions,
    allowForceRetry: Bool,
    pushAfterCommit: Bool = false,
    priorPushRootPaths: [String] = [],
    selectedChanges: [MultiRootChangeSelection]? = nil
) {
    guard !rootPaths.isEmpty, !message.isEmpty, let projectPath = projectWorkspace.path else { return }
    var options = requestedOptions
    options.skipHooks = GitCommitHooksSettings.effectiveSkipHooks(
        requested: requestedOptions.skipHooks
    )
    commitWorkspace.showMultiRootDialog = false
    multiRootWorkspace.running = true
    beginFeedbackOperation(
        "Multi-root commit",
        notificationID: multiRootRetryNotificationID(.commit)
    )
    rememberCommitAuthor(
        name: options.authorName ?? "",
        email: options.authorEmail ?? "",
        projectPath: projectPath
    )

    Task.detached(priority: .userInitiated) { [options] in
        do {
            let warningPresentations = try collectMultiRootCommitWarnings(
                rootPaths: rootPaths,
                selectedChanges: selectedChanges,
                projectPath: projectPath
            )
            var setCoreAutocrlf = false
            if !warningPresentations.isEmpty {
                let decision = await MainActor.run {
                    presentCommitWarningDecision(
                        warningPresentations,
                        projectPath: projectPath
                    )
                }
                guard decision.shouldContinue else {
                    await MainActor.run {
                        self.multiRootWorkspace.running = false
                        self.feedbackCenter.warning(
                            "Multi-root Commit cancelled",
                            detail: "Review the pre-commit warnings before committing.",
                            notificationID: self.multiRootRetryNotificationID(.commit)
                        )
                    }
                    return
                }
                setCoreAutocrlf = decision.setCoreAutocrlf
            }
            if setCoreAutocrlf, let rootPath = rootPaths.first,
               let warningRepository = try? openRepository(path: rootPath) {
                // Match IntelliJ's non-blocking CRLF fix: a config failure
                // leaves the warning enabled for the next commit, but must
                // not turn an otherwise valid commit into a failed commit.
                try? warningRepository.setGlobalCoreAutocrlf()
            }
            let results = try withArborPinentrySession {
                if let selectedChanges {
                    return try runMultiRootCommitSelectedPathsWithOptions(
                        scanRoot: projectPath,
                        selections: makeLiveMultiRootCommitSelections(selectedChanges),
                        commitMessage: message,
                        options: options
                    )
                }
                return try runMultiRootCommitWithOptions(
                    scanRoot: projectPath,
                    rootPaths: rootPaths,
                    commitMessage: message,
                    options: options
                )
            }
            let committedHeadIDs = Self.headCommitIDs(
                for: results
                    .filter { $0.success && !$0.skipped }
                    .map(\.rootPath)
            )
            await MainActor.run {
                let checkFailures = results.filter {
                    !$0.success && $0.message.contains("before-commit check")
                }
                let failedRootPaths = results.filter { !$0.success }.map(\.rootPath)
                let committedRootPaths = results
                    .filter { $0.success && !$0.skipped }
                    .map(\.rootPath)
                let pushRootPaths = Array(Set(priorPushRootPaths + committedRootPaths)).sorted()
                let retryAction = failedRootPaths.isEmpty
                    ? nil
                    : self.multiRootCommitRetryFeedbackAction(
                        rootPaths: failedRootPaths,
                        message: message,
                        options: options,
                        pushAfterCommit: pushAfterCommit,
                        pushRootPaths: pushAfterCommit ? pushRootPaths : [],
                        selectedChanges: selectedChanges?.filter {
                            failedRootPaths.contains($0.rootPath)
                        }
                    )
                let pushAction = pushAfterCommit && !pushRootPaths.isEmpty
                    ? self.multiRootCommitPushFeedbackAction(rootPaths: pushRootPaths)
                    : nil
                let signingActions = results.contains(where: {
                    !$0.success && gitCommitSigningFailureNeedsGPGConfiguration($0.message)
                }) ? [self.gpgAgentSettingsFeedbackAction()] : []
                let identityActions = results.contains(where: {
                    !$0.success && $0.message.localizedCaseInsensitiveContains("git identity missing")
                }) ? [self.identitySettingsFeedbackAction()] : []
                let rewordActions = committedRootPaths.compactMap { rootPath -> FeedbackAction? in
                    guard let commitID = committedHeadIDs[rootPath], !commitID.isEmpty else {
                        return nil
                    }
                    return self.commitRewordFeedbackAction(
                        rootPath: rootPath,
                        commitID: commitID
                    )
                }
                self.multiRootWorkspace.results = results
                self.multiRootWorkspace.running = false
                if allowForceRetry && options.runBeforeCommitChecks && !checkFailures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Commit checks failed"
                    alert.informativeText = checkFailures.map {
                        "\($0.displayName): \($0.message)"
                    }.joined(separator: "\n")
                    alert.addButton(withTitle: "Commit Anyway")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        var forcedOptions = options
                        forcedOptions.runBeforeCommitChecks = false
                        self.performMultiRootCommit(
                            rootPaths: checkFailures.map(\.rootPath),
                            message: message,
                            options: forcedOptions,
                            allowForceRetry: false,
                            pushAfterCommit: pushAfterCommit,
                            priorPushRootPaths: pushRootPaths,
                            selectedChanges: selectedChanges?.filter {
                                checkFailures.map(\.rootPath).contains($0.rootPath)
                            }
                        )
                    } else {
                        var additionalActions = rewordActions
                        if let retryAction {
                            additionalActions.append(retryAction)
                        }
                        if let pushAction {
                            additionalActions.append(pushAction)
                        }
                        self.feedbackCenter.warning(
                            "Commit checks failed",
                            detail: alert.informativeText,
                            nextStep: "Fix the checks or choose Commit Anyway for the failed roots.",
                            additionalActions: additionalActions,
                            notificationID: self.multiRootRetryNotificationID(.commit)
                        )
                        self.feedbackCenter.attachResultRows(
                            feedbackResultRows(from: results),
                            notificationID: self.multiRootRetryNotificationID(.commit)
                        )
                        if shouldAutomaticallyOpenMultiRootCommitPushOptions(
                            pushAfterCommit: pushAfterCommit,
                            pushRootPaths: pushRootPaths,
                            failedRootPaths: failedRootPaths
                        ) {
                            self.beginMultiRootCommitPush(rootPaths: pushRootPaths)
                        }
                        self.refreshAll(showFeedback: false)
                        self.loadMultiRoots(onCompleted: self.loadMultiRootChanges)
                    }
                    return
                }

                let committed = results.filter { $0.success && !$0.skipped }.count
                let failed = results.filter { !$0.success }.count
                let skipped = results.filter { $0.skipped }.count
                let detail = "\(committed) committed · \(failed) failed · \(skipped) skipped"
                var additionalActions = rewordActions
                additionalActions.append(contentsOf: signingActions)
                additionalActions.append(contentsOf: identityActions)
                if let retryAction {
                    additionalActions.append(retryAction)
                }
                if let pushAction {
                    additionalActions.append(pushAction)
                }
                if failed == 0 {
                    self.feedbackCenter.success(
                        "Multi-root commit complete",
                        detail: detail,
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit)
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Multi-root commit partially completed",
                        detail: detail,
                        nextStep: "Review the failed roots and retry the selected commit.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit)
                    )
                }
                self.feedbackCenter.attachResultRows(
                    feedbackResultRows(from: results),
                    notificationID: self.multiRootRetryNotificationID(.commit)
                )
                if shouldAutomaticallyOpenMultiRootCommitPushOptions(
                    pushAfterCommit: pushAfterCommit,
                    pushRootPaths: pushRootPaths,
                    failedRootPaths: failedRootPaths
                ) {
                    self.beginMultiRootCommitPush(rootPaths: pushRootPaths)
                }
                self.refreshAll(showFeedback: false)
                self.loadMultiRoots(onCompleted: self.loadMultiRootChanges)
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                let retryAction = self.multiRootCommitRetryFeedbackAction(
                    rootPaths: rootPaths,
                    message: message,
                    options: options,
                    pushAfterCommit: pushAfterCommit,
                    pushRootPaths: pushAfterCommit ? priorPushRootPaths : [],
                    selectedChanges: selectedChanges
                )
                var additionalActions = [retryAction]
                let detail = errorMessage(error)
                if gitCommitSigningFailureNeedsGPGConfiguration(detail) {
                    additionalActions.append(self.gpgAgentSettingsFeedbackAction())
                }
                if pushAfterCommit && !priorPushRootPaths.isEmpty {
                    additionalActions.append(
                        self.multiRootCommitPushFeedbackAction(rootPaths: priorPushRootPaths)
                    )
                }
                if let engineError = error as? EngineError, case .Cancelled = engineError {
                    self.feedbackCenter.warning(
                        "Multi-root commit canceled",
                        detail: "The selected roots were kept for an explicit retry.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit),
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        "Multi-root commit failed",
                        detail: detail,
                        nextStep: "Check the commit message and selected roots, then retry.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit)
                    )
                }
            }
        }
    }
}

/// Load recent messages from all discovered roots so the aggregate dialog
/// never silently presents the primary repository's history as every root's.
func loadMultiRootCommitMetadata(rootPaths: [String]) {
    let paths = Array(Set(rootPaths)).sorted()
    Task.detached(priority: .utility) {
        var messages: [String] = []
        for path in paths {
            guard let rootRepo = try? openRepository(path: path) else { continue }
            messages.append(contentsOf: (try? rootRepo.recentCommitMessages(limit: 10)) ?? [])
        }
        var seen = Set<String>()
        let unique = messages.filter { seen.insert($0).inserted }
        await MainActor.run {
            self.commitWorkspace.multiRootRecentMessages = unique
        }
    }
}

/// Apply the first configured template from the selected roots in stable
/// order. A single project-level message cannot represent multiple different
/// repository templates, so the choice is deterministic and visible.
func loadMultiRootCommitTemplate(_ rootPaths: [String]) {
    let paths = Array(Set(rootPaths)).sorted()
    Task.detached(priority: .userInitiated) {
        var template: String?
        for path in paths {
            guard let rootRepo = try? openRepository(path: path),
                  let candidate = try? rootRepo.commitTemplate(),
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            template = candidate
            break
        }
        let selectedTemplate = template
        await MainActor.run {
            if let selectedTemplate {
                self.commitWorkspace.multiRootMessage = selectedTemplate
            } else {
                self.feedbackCenter.warning(
                    "No commit template configured",
                    detail: "None of the selected Git roots exposes a non-empty commit.template."
                )
            }
        }
    }
}

func viewDeletedBranchCommitsFromSemanticTargets(
    _ targets: [PersistedBranchDeleteRecoveryTarget]
) {
    guard let normalizedTargets = normalizedBranchDeleteRecoveryTargets(targets) else { return }
    var contexts: [BranchDeleteRecoveryContext] = []
    for target in normalizedTargets {
        guard let rootRepo = try? openRepository(path: target.rootPath) else {
            feedbackCenter.error(
                "View deleted commits unavailable",
                detail: "The Git root could not be opened: \(target.rootPath)",
                nextStep: "Refresh Git Roots, then retry the notification action."
            )
            return
        }
        let preview = BranchDeletePreview(
            branchName: target.branchName,
            tipId: target.tipID,
            upstream: target.upstream,
            baseBranches: target.baseBranches,
            unmergedCommits: target.unmergedCommits.map {
                BranchDeleteCommit(
                    id: $0.id,
                    shortId: $0.shortID,
                    summary: $0.summary,
                    time: $0.time
                )
            }
        )
        contexts.append(
            BranchDeleteRecoveryContext(
                repo: rootRepo,
                preview: preview,
                rootPath: target.rootPath
            )
        )
    }
    guard !contexts.isEmpty else { return }
    branchWorkspace.deleteRecovery = nil
    branchWorkspace.multiRootDeleteRecovery = nil
    if contexts.count == 1 {
        branchWorkspace.deleteRecovery = contexts[0]
    } else {
        let branchNames = Array(Set(contexts.map { $0.preview.branchName })).sorted()
        branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
            branchName: branchNames.joined(separator: ", "),
            contexts: contexts
        )
    }
}

nonisolated static func updatedCommitCount(from updateMessage: String) -> Int? {
    let words = updateMessage.split(whereSeparator: { $0 == " " || $0 == "\n" })
    guard let index = words.firstIndex(where: { $0.caseInsensitiveCompare("updated") == .orderedSame }),
          index < words.index(before: words.endIndex) else {
        return nil
    }
    return Int(words[words.index(after: index)])
}

nonisolated static func headCommitIDs(for rootPaths: [String]) -> [String: String] {
    var heads: [String: String] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath),
              let head = rootRepo.headCommitId(),
              !head.isEmpty else { continue }
        heads[rootPath] = head
    }
    return heads
}

func multiRootUpdateViewCommitsAction(
    ranges: [PersistedLogRevisionRange]
) -> FeedbackAction? {
    guard !ranges.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showLogRanges,
        projectPath: projectWorkspace.path,
        rootPath: ranges.count == 1 ? ranges[0].rootPath : nil,
        shelfName: "",
        logRevisionRanges: ranges
    )
    return FeedbackAction(title: "View Commits", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func branchDeleteViewCommitsAction(
    contexts: [BranchDeleteRecoveryContext]
) -> FeedbackAction? {
    guard contexts.contains(where: { !$0.preview.unmergedCommits.isEmpty }),
          let targets = branchDeleteRecoveryTargets(from: contexts) else {
        return nil
    }
    let request = ArborVCSActionRequest(
        kind: .viewDeletedBranchCommits,
        projectPath: projectWorkspace.path,
        rootPath: targets.count == 1 ? targets[0].rootPath : nil,
        shelfName: "",
        branchDeleteRecoveryTargets: targets
    )
    return FeedbackAction(title: "View Commits", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootCommitRetryFeedbackAction(
    rootPaths: [String],
    message: String,
    options: MultiRootCommitOptions,
    pushAfterCommit: Bool = false,
    pushRootPaths: [String] = [],
    selectedChanges: [MultiRootChangeSelection]? = nil
) -> FeedbackAction {
    let normalizedSelectedChanges = selectedChanges.map(normalizedMultiRootCommitSelections)
    let request = makeMultiRootRetryRequest(
        operation: .commit,
        rootPaths: rootPaths,
        commitRetry: PersistedMultiRootCommitRetry(
            message: message,
            options: options,
            pushAfterCommit: pushAfterCommit,
            pushRootPaths: pushRootPaths,
            selectedPaths: normalizedSelectedChanges?.map(PersistedMultiRootChangePath.init)
        )
    )
    return FeedbackAction(
        id: "retry-multi-root-commit:\(rootPaths.sorted().joined(separator: "|")):\(normalizedSelectedChanges?.map(\.id).joined(separator: "|") ?? "roots")",
        title: "Retry Failed Commits",
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

nonisolated func normalizedMultiRootCommitSelections(
    _ selections: [MultiRootChangeSelection]
) -> [MultiRootChangeSelection] {
    var seen = Set<String>()
    return selections
        .filter {
            !$0.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .filter { seen.insert($0.id).inserted }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.path < $1.path }
            return $0.rootPath < $1.rootPath
        }
}

nonisolated func makeLiveMultiRootCommitSelections(
    _ selections: [MultiRootChangeSelection]
) -> [MultiRootCommitSelection] {
    let normalized = normalizedMultiRootCommitSelections(selections)
    let grouped = Dictionary(grouping: normalized, by: \.rootPath)
    return grouped.keys.sorted().map { rootPath in
        let paths = grouped[rootPath, default: []]
            .map(\.path)
        return MultiRootCommitSelection(
            rootPath: rootPath,
            paths: Array(Set(paths)).sorted()
        )
    }
}

func rememberCommitAuthor(name: String, email: String, projectPath: String?) {
    guard let value = GitCommitAuthorHistorySettings.formattedAuthor(name: name, email: email) else {
        return
    }
    GitCommitAuthorHistorySettings.save(value, for: projectPath)
    gitSettings.identityRecentAuthors = GitCommitAuthorHistorySettings.authors(for: projectPath)
}

}
