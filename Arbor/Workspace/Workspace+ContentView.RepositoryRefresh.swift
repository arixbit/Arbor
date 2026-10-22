import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// 用路径范围状态替换文件树中的对应条目，避免每次单文件操作都重建整棵状态树。
func applyIncrementalStatus(_ updates: [FileEntry], paths: [String]) {
    let pathSet = Set(paths)
    repositoryStatus.entries.removeAll { pathSet.contains($0.path) }
    repositoryStatus.entries.append(contentsOf: updates)
    repositoryStatus.entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    repositoryStatus.isShowingCachedStatusSnapshot = false
    fileWorkspace.refreshToken &+= 1
}

}


extension ContentView {

func handleRepositoryChange(_ event: RepositoryChangeEvent) {
    guard !(externalLogWindow && logRuntime.externalSessionDisposed) else { return }
    let eventPath = URL(fileURLWithPath: event.repositoryPath)
        .standardizedFileURL.path
    // Invalidate at event delivery, before the 100 ms packed refresh debounce,
    // so an Apply Patch dialog opened during that window cannot read stale
    // filename membership.
    RebasedPatchFilenameIndexStore.invalidate(rootPath: eventPath)
    repositoryStatus.changeBatch.insert(event)
    guard repositoryStatus.changeDeliveryTask == nil else { return }
    repositoryStatus.changeDeliveryTask = Task { @MainActor in
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            self.repositoryStatus.changeDeliveryTask = nil
            return
        }
        guard !Task.isCancelled else {
            self.repositoryStatus.changeDeliveryTask = nil
            return
        }
        let events = self.repositoryStatus.changeBatch.drain()
        self.repositoryStatus.changeDeliveryTask = nil
        for event in events {
            processRepositoryChange(event)
        }
    }
}

func processRepositoryChange(_ event: RepositoryChangeEvent) {
    let eventPath = URL(fileURLWithPath: event.repositoryPath)
        .standardizedFileURL.path
    repositoryStatus.dirtyScopeManager.register(
        repositoryPaths: autoFetchRootPaths + [eventPath]
    )
    // Keep the exact VFS records before RootDirtySet-style compaction. The
    // refresh scope may become a directory or full-root scan, but actions and
    // lifecycle completion still need the original file/rename endpoints.
    repositoryStatus.dirtyFileManager.mark(
        repositoryPath: eventPath,
        dirtyPaths: event.dirtyPaths
    )
    let primaryPath = repo?.workdir().map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    }
    let eventRepo: Repository?
    if primaryPath == eventPath {
        eventRepo = repo
    } else {
        eventRepo = try? openRepository(path: eventPath)
    }
    var affectedRootPaths = [eventPath]
    if let eventRepo,
       let workdir = eventRepo.workdir() {
        let scope = repositoryDirtyScope(
            workdir: workdir,
            gitDir: eventRepo.gitDir(),
            dirtyPaths: event.dirtyPaths
        )
        affectedRootPaths = repositoryStatus.dirtyScopeManager.mark(
            repositoryPath: eventPath,
            scope: scope,
            changeScope: event.scopes,
            dirtyPaths: event.dirtyPaths
        )
    } else {
        // Keep the event in the same packed lifecycle even if the repository
        // disappeared while the watcher was delivering it. A later root
        // discovery will reconcile the full state instead of dropping the
        // invalidation because the Repository object is temporarily absent.
        affectedRootPaths = repositoryStatus.dirtyScopeManager.markEverything(
            repositoryPath: eventPath,
            changeScope: event.scopes,
            dirtyPaths: event.dirtyPaths
        )
    }

    let hasExternalVCSActionEvents = event.scopes.contains(.worktree)
        && event.dirtyPaths.contains {
            $0.kind == .created || $0.kind == .removed || $0.kind == .renamed
        }
    if hasExternalVCSActionEvents, eventRepo != nil {
        repositoryStatus.externalVCSActionManager.enqueue(event)
    }

    for rootPath in affectedRootPaths where rootPath != eventPath {
        // GitVcsDirtyScope marks every nested root dirty when a recursive
        // parent event covers it. The exact file ledger still needs a record
        // for that synthetic full-root refresh.
        repositoryStatus.dirtyFileManager.mark(
            repositoryPath: rootPath,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: rootPath,
                    isDirectory: true,
                    kind: .modified
                )
            ]
        )
    }

    // Do not start a second refresh while the packed scope is being consumed.
    // retrieveScopes() returns an empty batch until changesProcessed() is
    // called, so events arriving during the current refresh remain pending.
    startPendingRepositoryDirtyScopes()
}

/// Consumes one IntelliJ-style packed dirty-scope batch. The scope manager is
/// deliberately the source of truth here; the watcher/event batch only
/// schedules this function and never directly acknowledges a dirty path.
func startPendingRepositoryDirtyScopes() {
    let records = repositoryStatus.dirtyScopeManager.retrieveScopes()
    guard !records.isEmpty else { return }

    for record in records {
        let refreshEvent = record.event
        let dirtyFileTicket = repositoryStatus.dirtyFileManager.beginProcessing(
            repositoryPath: record.repositoryPath
        )
        let shouldStartExternalVCSActions = refreshEvent.scopes.contains(.worktree)
            && refreshEvent.dirtyPaths.contains {
                $0.kind == .created || $0.kind == .removed || $0.kind == .renamed
            }
        let eventRepo: Repository?
        let primaryPath = repo?.workdir().map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        if primaryPath == record.repositoryPath {
            eventRepo = repo
        } else {
            eventRepo = try? openRepository(path: record.repositoryPath)
        }

        refreshRepositoryChange(refreshEvent) {
            self.repositoryStatus.dirtyScopeManager.changesProcessed(
                repositoryPath: record.repositoryPath
            )
            if let dirtyFileTicket {
                self.repositoryStatus.dirtyFileManager.changesProcessed(dirtyFileTicket)
            }
            if shouldStartExternalVCSActions, let eventRepo {
                self.startNextExternalVCSAction(repo: eventRepo)
            }
            // A new watcher event may have arrived while this batch was in
            // progress. Only now is the next packed scope eligible.
            self.startPendingRepositoryDirtyScopes()
        }
    }
}

func refreshRepositoryChange(
    _ event: RepositoryChangeEvent,
    onCompleted: (() -> Void)? = nil
) {
    let primaryPath = repo?.workdir().map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    }
    let eventPath = URL(fileURLWithPath: event.repositoryPath)
        .standardizedFileURL.path
    if primaryPath == eventPath {
        refreshAll(
            showFeedback: false,
            changeScope: event.scopes,
            dirtyPaths: event.dirtyPaths,
            onCompleted: onCompleted
        )
        if event.scopes.contains(.gitMetadata) {
            loadRepoData(includeComparisons: false)
            loadMultiRoots()
        }
    } else {
        // A non-primary root has no dedicated Commit workspace state, but it
        // still owns Branches, Roots, conflicts, and aggregate Log rows.
        let shouldRefreshSecondaryShelf = shouldRefreshSecondaryShelfSnapshot(
            eventRootPath: eventPath,
            activeRootPath: activeShelfRootPath,
            primaryRootPath: primaryShelfRootPath,
            scopes: event.scopes
        )
        loadMultiRoots {
            if self.logList.viewMode == .command || self.isLogAggregate {
                self.reloadLogView()
            }
            if shouldRefreshSecondaryShelf {
                self.reloadSecondaryShelfSnapshot(rootPath: eventPath)
            }
            onCompleted?()
        }
    }
}

func refreshAll() {
    refreshAll(showFeedback: true)
}

// Operation handlers call the overload with `showFeedback: false` after they
// have already published their terminal success/warning/error message. A
// status refresh must not replace that message with a second operation.
func refreshAll(showFeedback: Bool) {
    refreshAll(showFeedback: showFeedback, changeScope: nil)
}

/// Refreshes the visible change tree for every event, but only reloads
/// repository-wide metadata when the Git administrative area changed. This
/// mirrors IntelliJ's separation between a dirty VFS scope and global VCS
/// cache invalidation: editing one worktree file must not rewalk refs, tags,
/// submodules, worktrees, or the log model.
func refreshAll(
    showFeedback: Bool,
    changeScope: RepositoryChangeScope?,
    dirtyPaths: [RepositoryDirtyPath] = [],
    onCompleted: (() -> Void)? = nil
) {
    guard let repo else {
        onCompleted?()
        return
    }
    if showFeedback {
        beginFeedbackOperation("Refresh status")
    }
    let repositoryPath = projectWorkspace.path
    let refreshMetadata = changeScope?.contains(.gitMetadata) ?? true
    let requestedIncrementalStatusPaths = refreshMetadata
        ? nil
        : repositoryWorktreeStatusPaths(
            workdir: repo.workdir() ?? "",
            gitDir: repo.gitDir(),
            dirtyPaths: dirtyPaths
        )
    let refreshTicket = repositoryStatus.refreshGate.begin(
        usesIncrementalStatus: requestedIncrementalStatusPaths != nil
    )
    let incrementalStatusPaths = refreshTicket.usesIncrementalStatus
        ? requestedIncrementalStatusPaths
        : nil
    let existingEntries = repositoryStatus.entries
    let shouldLoadLog = refreshMetadata && showsLogWorkspace && logList.viewMode != .reflog
    let shouldLoadReflog = refreshMetadata && showsLogWorkspace && logList.viewMode == .reflog
    DiagnosticsLogger.shared.record(operation: "refresh", repositoryPath: repositoryPath, code: "started")
    Task.detached(priority: .userInitiated) {
        do {
            let st: [FileEntry]
            if let incrementalStatusPaths {
                if incrementalStatusPaths.isEmpty {
                    st = existingEntries
                } else if let refreshed = try? repo.statusPaths(paths: incrementalStatusPaths) {
                    // Replace only the pathspecs covered by this VFS batch.
                    // Deleted paths disappear from `refreshed`, which removes
                    // stale rows from the previous status snapshot.
                    let impacted = { (path: String) in
                        incrementalStatusPaths.contains { scope in
                            path == scope || path.hasPrefix("\(scope)/")
                        }
                    }
                    st = (existingEntries.filter { !impacted($0.path) } + refreshed)
                        .sorted { $0.path < $1.path }
                } else {
                    // Git pathspecs can become invalid while a directory is
                    // being atomically replaced. Preserve correctness over
                    // the optimization and rescan the repository.
                    st = try repo.status()
                }
            } else {
                st = try repo.status()
            }
            // `st` is already the authoritative visible status snapshot.
            // Projecting Changelists from it avoids another full worktree walk
            // inside the engine for both full and incremental refreshes.
            let containsRename = st.contains {
                $0.staged == .renamed || $0.unstaged == .renamed
            }
            let cls = (try? (containsRename
                ? repo.changelistList()
                : repo.changelistListForPaths(currentPaths: st.map(\.path)))) ?? []
            let hid = repo.headCommitId()
            let mergePending = repo.mergeInProgress()
            let opState = try? repo.operationState()
            let resolvedPaths = (try? repo.conflictWorkspace().resolvedFiles) ?? []
            await MainActor.run {
                guard self.projectWorkspace.repository === repo else {
                    onCompleted?()
                    return
                }
                guard self.repositoryStatus.refreshGate.isCurrent(refreshTicket) else {
                    onCompleted?()
                    return
                }
                guard self.repositoryStatus.refreshGate.finish(refreshTicket) else {
                    onCompleted?()
                    return
                }
                self.repositoryStatus.entries = st
                self.repositoryStatus.changeLists = cls
                self.repositoryStatus.isShowingCachedStatusSnapshot = false
                if incrementalStatusPaths == nil,
                   let rootPath = repo.workdir() {
                    savePersistedStatusCache(
                        rootPath: rootPath,
                        files: st,
                        changeLists: cls
                    )
                }
                self.fileWorkspace.refreshToken &+= 1
                self.repositoryStatus.headId = hid
                self.mergeWorkspace.inProgress = mergePending || self.stashRecovery.popConflictInProgress || self.stashRecovery.applyConflictInProgress
                self.operationRecovery.operation = opState
                if let opState, let rootPath = repo.workdir() {
                    self.feedbackCenter.expire(
                        notificationID: self.logApplyRecoveryNotificationID(rootPath: rootPath)
                    )
                    self.logSelectionState.applyRecoveryNotificationFingerprints.removeValue(
                        forKey: operationRecoveryNotificationRootKey(rootPath)
                    )
                    self.publishOperationRecoveryNoticeIfNeeded(
                        state: opState,
                        rootPath: rootPath
                    )
                } else if let rootPath = repo.workdir() {
                    _ = self.publishLogApplyRecoveryNoticeIfNeeded(rootPath: rootPath)
                    self.feedbackCenter.expire(
                        notificationID: operationRecoveryNotificationID(rootPath: rootPath)
                    )
                    self.operationRecovery.notificationFingerprints.removeValue(
                        forKey: operationRecoveryNotificationRootKey(rootPath)
                    )
                }
                self.operationRecovery.resolvedConflictPaths = resolvedPaths
                if (mergePending || self.stashRecovery.popConflictInProgress),
                   self.projectWorkspace.toolWindowMode != .log,
                   self.fileWorkspace.selection == nil {
                    self.fileWorkspace.selection = st.first(where: {
                        $0.staged == .conflicted || $0.unstaged == .conflicted
                    })?.path
                }
                if showFeedback {
                    self.feedbackCenter.success("Status refreshed")
                }
                // Rebased refreshes the visible VCS log model with the active
                // filters. Never replace it with an unfiltered history walk:
                // doing so made a refresh silently discard Text/Paths/User/
                // Date/Branch filters and could also replace the selected
                // commit with an unrelated row.
                if shouldLoadLog {
                    self.reloadLogView()
                }
                if shouldLoadReflog {
                    self.loadReflog()
                }
                onCompleted?()
            }

            // Metadata that is not needed to render the visible change tree
            // is deliberately loaded after the first MainActor update. The
            // staging model itself performs a status scan, so keeping it out
            // of the critical path avoids making every refresh wait for two
            // full worktree walks.
            Task.detached(priority: .utility) {
                let staging = try? repo.stagingModel()
                guard refreshMetadata else {
                    await MainActor.run {
                        guard self.projectWorkspace.repository === repo,
                              self.repositoryStatus.refreshGate.isCurrent(refreshTicket) else { return }
                        self.repositoryStatus.stagingModel = staging
                        self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                    }
                    return
                }

                let ignoredRules = (try? repo.ignoredRules()) ?? []
                let recent = (try? repo.recentCommitMessages(limit: 10)) ?? []
                let tags = (try? repo.tagList()) ?? []
                let submodules = (try? repo.submoduleList()) ?? []
                let worktrees = (try? repo.worktreeList()) ?? []
                let isShallow = repo.isShallow()
                let remoteBranches = (try? repo.remoteBranchList()) ?? []
                let recentBranches = (try? repo.recentBranches(limit: 10)) ?? []
                let syncStatuses = (try? repo.syncStatus()) ?? []
                await MainActor.run {
                    guard self.projectWorkspace.repository === repo,
                          self.repositoryStatus.refreshGate.isCurrent(refreshTicket) else { return }
                    self.repositoryStatus.ignoredRules = ignoredRules
                    self.commitWorkspace.recentMessages = recent
                    self.tagWorkspace.tags = tags
                    self.submoduleWorkspace.submodules = submodules
                    self.worktreeWorkspace.worktrees = worktrees
                    self.repositoryStatus.isShallowRepository = isShallow
                    self.repositoryStatus.stagingModel = staging
                    self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                    self.branchWorkspace.remoteBranches = remoteBranches
                    self.branchWorkspace.recentBranches = recentBranches
                    self.branchWorkspace.syncStatuses = syncStatuses
                }
            }
        } catch {
            DiagnosticsLogger.shared.record(level: .error, operation: "refresh", repositoryPath: repositoryPath, code: "failed")
            await MainActor.run {
                guard self.projectWorkspace.repository === repo else {
                    onCompleted?()
                    return
                }
                guard self.repositoryStatus.refreshGate.isCurrent(refreshTicket) else {
                    onCompleted?()
                    return
                }
                guard self.repositoryStatus.refreshGate.finish(refreshTicket) else {
                    onCompleted?()
                    return
                }
                if showFeedback {
                    self.repositoryStatus.loadError = errorMessage(error)
                    self.feedbackCenter.error("Refresh failed", detail: errorMessage(error), nextStep: "Check the repository and retry.")
                }
                onCompleted?()
            }
        }
    }
}

/// IntelliJ's cherry-picked highlighter compares a selected source branch with
/// the current target branch using patch equivalence, not a commit-message
/// trailer. A commit is highlighted only after the branch-aware comparison
/// finishes. In an aggregate Log, run the comparison independently for every
/// root and qualify returned ids with that root so identical object ids from
/// separate repositories cannot cross-highlight.
func refreshCherryPickedHighlights() {
    logCherryPick.comparisonTask?.cancel()
    logCherryPick.comparisonTask = nil
    logCherryPick.cancelHandle?.cancel()
    logCherryPick.cancelHandle = nil
    logCherryPick.generation += 1
    let requestedComparisonGeneration = logCherryPick.generation
    logCherryPick.inProgress = false
    logCherryPick.completedRoots = 0
    logCherryPick.totalRoots = 0

    guard logHighlightCherryPicked,
          !logCherryPickCompareBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        logCherryPick.cherryPickedCommitIDs = []
        logCherryPick.comparisonReady = false
        return
    }
    let source = logCherryPickCompareBranch
    let aggregate = isLogAggregate
    let aggregateFilters = logRuntime.aggregateBranchFilters
    let aggregateRevisionRanges = logRuntime.aggregateRevisionRanges
    let aggregateRootPaths = logRuntime.aggregateRootPaths
    let requestedLogGeneration = logList.generation
    let requestedRepositories: [(path: String, repo: Repository)]
    if aggregate {
        requestedRepositories = logRuntime.aggregateRepositories
            .sorted { $0.key < $1.key }
            .map { (path: $0.key, repo: $0.value) }
    } else if let repo = logRepository {
        requestedRepositories = [(path: repo.workdir() ?? "", repo: repo)]
    } else {
        requestedRepositories = []
    }
    guard !requestedRepositories.isEmpty else {
        logCherryPick.cherryPickedCommitIDs = []
        logCherryPick.comparisonReady = false
        return
    }

    let target = cherryPickTargetBranch(
        mode: logList.viewMode,
        sourceBranch: source,
        firstBranch: comparisonWorkspace.revision1,
        secondBranch: comparisonWorkspace.revision2,
        currentBranch: activeLogBranches.first(where: \.isCurrent)?.name
    )
    let eligibleRepositories = requestedRepositories.filter { request in
        let localBranchNames = (try? request.repo.branchList().map(\.name)) ?? []
        let remoteBranchNames = (try? request.repo.remoteBranchList().map(\.name)) ?? []
        return cherryPickSourceBranchExists(
            source,
            localBranchNames: localBranchNames,
            remoteBranchNames: remoteBranchNames
        )
    }
    guard !eligibleRepositories.isEmpty else {
        logCherryPick.cherryPickedCommitIDs = []
        logCherryPick.comparisonReady = false
        return
    }
    logCherryPick.comparisonReady = false
    logCherryPick.inProgress = true
    logCherryPick.totalRoots = eligibleRepositories.count
    let cancel = GitCancelHandle()
    logCherryPick.cancelHandle = cancel
    let task = Task.detached(priority: .userInitiated) {
        var highlighted: Set<String> = []
        var successfulComparisons = 0
        var failedComparisons = 0
        var lastError: Error?
        var completedComparisons = 0

        for request in eligibleRepositories {
            if Task.isCancelled {
                break
            }
            do {
                let comparisonTarget = aggregate
                    ? ((try? request.repo.branchList()) ?? []).first(where: \.isCurrent)?.name ?? "HEAD"
                    : target
                let ids = try request.repo.cherryPickedCommitsWithCancel(
                    source: source,
                    target: comparisonTarget,
                    cancel: cancel
                )
                successfulComparisons += 1
                highlighted.formUnion(ids.map {
                    logCommitDisplayIdentity(
                        repositoryPath: request.path,
                        id: $0,
                        aggregate: aggregate
                    )
                })
            } catch {
                // A branch can exist in one selected root but not another.
                // Keep successful roots visible and report only an all-roots
                // failure below.
                lastError = error
                failedComparisons += 1
            }
            completedComparisons += 1
            let completed = completedComparisons
            await MainActor.run {
                guard self.logCherryPick.generation == requestedComparisonGeneration,
                      self.logList.generation == requestedLogGeneration,
                      self.logHighlightCherryPicked,
                      self.logCherryPickCompareBranch == source else { return }
                self.logCherryPick.completedRoots = completed
            }
        }

        let resultIDs = highlighted
        let resultCount = successfulComparisons
        let failedCount = failedComparisons
        let resultError = lastError
        let comparisonWasCancelled = Task.isCancelled

        await MainActor.run {
            guard isCurrentCherryPickedComparison(
                highlightingEnabled: self.logHighlightCherryPicked,
                currentComparisonGeneration: self.logCherryPick.generation,
                resultComparisonGeneration: requestedComparisonGeneration,
                currentLogGeneration: self.logList.generation,
                resultLogGeneration: requestedLogGeneration,
                currentSourceBranch: self.logCherryPickCompareBranch,
                resultSourceBranch: source
            ) else { return }
            if aggregate {
                guard self.logRuntime.aggregateBranchFilters == aggregateFilters,
                      self.logRuntime.aggregateRevisionRanges == aggregateRevisionRanges,
                      self.logRuntime.aggregateRootPaths == aggregateRootPaths else { return }
            } else {
                guard self.isActiveLogRepository(eligibleRepositories[0].repo),
                      cherryPickTargetBranch(
                          mode: self.logList.viewMode,
                          sourceBranch: self.logCherryPickCompareBranch,
                          firstBranch: self.comparisonWorkspace.revision1,
                          secondBranch: self.comparisonWorkspace.revision2,
                          currentBranch: self.activeLogBranches.first(where: \.isCurrent)?.name
                      ) == target else { return }
            }
            self.logCherryPick.comparisonTask = nil
            self.logCherryPick.cancelHandle = nil
            self.logCherryPick.inProgress = false
            guard !comparisonWasCancelled else { return }
            self.logCherryPick.cherryPickedCommitIDs = resultIDs
            // A successful comparison with zero picked commits is still a
            // completed comparison. The graph must remain unhighlighted,
            // rather than reviving the old trailer heuristic.
            self.logCherryPick.comparisonReady = resultCount > 0
            if resultCount == 0, let resultError {
                self.feedbackCenter.error(
                    "Cherry-picked comparison failed",
                    detail: errorMessage(resultError),
                    nextStep: "Choose a valid local or remote branch, then retry."
                )
            } else if failedCount > 0 {
                self.feedbackCenter.warning(
                    "Cherry-picked comparison partially completed",
                    detail: "Compared \(resultCount) root(s); \(failedCount) root(s) could not be compared.",
                    nextStep: "Verify that the selected source branch exists in every affected Git root."
                )
            }
        }
    }
    logCherryPick.comparisonTask = task
}

func loadTreeChanges() {
    comparisonWorkspace.loadTask?.cancel()
    comparisonWorkspace.loadTask = nil
    let comparisonRepo = comparisonWorkspace.repository ?? repo
    guard let comparisonRepo else {
        comparisonWorkspace.treeChanges = []
        comparisonWorkspace.selection = nil
        comparisonWorkspace.selectedPaths = []
        comparisonWorkspace.error = nil
        return
    }
    let old = comparisonWorkspace.revision1.trimmingCharacters(in: .whitespaces)
    let new = comparisonWorkspace.revision2.trimmingCharacters(in: .whitespaces)
    let usesWorkingTree = comparisonWorkspace.withWorkingTree
    let tabID = currentLogTabID
    guard !old.isEmpty, usesWorkingTree || !new.isEmpty else {
        comparisonWorkspace.treeChanges = []
        comparisonWorkspace.selection = nil
        comparisonWorkspace.selectedPaths = []
        comparisonWorkspace.error = "请输入两个 revision"
        return
    }
    let task = Task.detached(priority: .userInitiated) {
        do {
            let changes = if usesWorkingTree {
                try comparisonRepo.treeChangesWithWorktree(revision: old)
            } else {
                try comparisonRepo.treeChanges(rev1: old, rev2: new)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled,
                      self.externalLogTabIsAlive(tabID),
                      self.comparisonWorkspace.revision1.trimmingCharacters(in: .whitespaces) == old,
                      (usesWorkingTree || self.comparisonWorkspace.revision2.trimmingCharacters(in: .whitespaces) == new),
                      self.comparisonWorkspace.withWorkingTree == usesWorkingTree,
                      self.comparisonWorkspace.repository === comparisonRepo ||
                        (self.comparisonWorkspace.repository == nil && self.projectWorkspace.repository === comparisonRepo) else { return }
                self.comparisonWorkspace.treeChanges = changes
                // The reference changes browser selects the first affected
                // file when a comparison is opened, so the right preview is
                // immediately useful instead of showing a blank inspector.
                self.comparisonWorkspace.selection = changes.first?.path
                self.comparisonWorkspace.selectedPaths = changes.first.map { [$0.path] } ?? []
                self.comparisonWorkspace.error = nil
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled,
                      self.externalLogTabIsAlive(tabID),
                      self.comparisonWorkspace.revision1.trimmingCharacters(in: .whitespaces) == old,
                      (usesWorkingTree || self.comparisonWorkspace.revision2.trimmingCharacters(in: .whitespaces) == new),
                      self.comparisonWorkspace.withWorkingTree == usesWorkingTree,
                      self.comparisonWorkspace.repository === comparisonRepo ||
                        (self.comparisonWorkspace.repository == nil && self.projectWorkspace.repository === comparisonRepo) else { return }
                self.comparisonWorkspace.treeChanges = []
                self.comparisonWorkspace.selection = nil
                self.comparisonWorkspace.selectedPaths = []
                self.comparisonWorkspace.error = errorMessage(error)
            }
        }
    }
    comparisonWorkspace.loadTask = task
}

}
