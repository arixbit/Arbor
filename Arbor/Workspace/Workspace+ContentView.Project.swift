import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func handleContentViewAppearAndLoadRoots() {
    logRuntime.externalSessionDisposed = false
    // Root discovery starts after the primary status snapshot is visible so
    // startup work cannot compete with the first usable Changes rows.
    handleContentViewAppear()
    credentialAuth.ensureInstalled()
}

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
    let shouldLoadLog = refreshMetadata && projectWorkspace.toolWindowMode == .log && logList.viewMode != .reflog
    let shouldLoadReflog = refreshMetadata && projectWorkspace.toolWindowMode == .log && logList.viewMode == .reflog
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

func handleProjectDrop(_ providers: [NSItemProvider]) -> Bool {
    guard let provider = providers.first else { return false }
    _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
        guard let url = object as? URL, url.hasDirectoryPath else { return }
        DispatchQueue.main.async {
            self.projectWorkspace.inputPath = url.path
            self.requestOpenProject(url.path)
        }
    }
    return true
}

func initializeProject(at requestedPath: String) {
    let selectedPath = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
    if let existingRoot = gitInitializationExistingRepositoryRoot(path: selectedPath) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Directory Already Belongs to Git"
        alert.informativeText = "\(selectedPath) is inside the Git repository at \(existingRoot). Initialize Git again?"
        alert.addButton(withTitle: "Initialize Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    beginFeedbackOperation("Initialize Git repository")
    Task.detached(priority: .userInitiated) {
        do {
            let initializedPath = try initializeRepository(path: selectedPath)
            await MainActor.run {
                self.feedbackCenter.success("Git repository initialized", detail: initializedPath)
                self.projectWorkspace.inputPath = initializedPath
            }
            await MainActor.run { self.requestOpenProject(initializedPath) }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Initialize Git repository failed", detail: errorMessage(error), nextStep: "Choose a writable directory and retry.")
            }
        }
    }
}

/// 请求打开一个项目；已有项目时由用户选择替换当前窗口或新窗口。
func requestOpenProject(_ requestedPath: String) {
    let selectedPath = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
    guard !selectedPath.isEmpty else { return }
    if projectWorkspace.repository != nil, projectWorkspace.path != selectedPath {
        projectWorkspace.pendingPath = selectedPath
        projectWorkspace.showSwitchAlert = true
    } else {
        openProjectPath(selectedPath)
    }
}

func replacePendingProject() {
    guard let pendingProjectPath = projectWorkspace.pendingPath else { return }
    let next = pendingProjectPath
    self.projectWorkspace.pendingPath = nil
    resetProjectState()
    projectWorkspace.path = next
    projectWorkspace.inputPath = next
    openProjectPath(next)
}

func openPendingProjectInNewWindow() {
    guard let pendingProjectPath = projectWorkspace.pendingPath else { return }
    let next = pendingProjectPath
    self.projectWorkspace.pendingPath = nil
    openWindow(value: next)
}

func openProjectPath(_ projectPath: String) {
    expireOperationRecoveryNotifications()
    repositoryStatus.changeDeliveryTask?.cancel()
    repositoryStatus.changeDeliveryTask = nil
    repositoryStatus.changeBatch.removeAll()
    repositoryStatus.externalVCSActionManager.removeAll()
    repositoryStatus.dirtyScopeManager.removeAll()
    repositoryStatus.dirtyFileManager.removeAll()
    multiRootWorkspace.loadTask?.cancel()
    multiRootWorkspace.loadTask = nil
    multiRootWorkspace.loadGeneration &+= 1
    multiRootWorkspace.loadNeedsRefresh = false
    multiRootWorkspace.loadCompletion = nil
    beginFeedbackOperation("Open project")
    logList.refreshTask?.cancel()
    logList.refreshTask = nil
    logList.loadTask?.cancel()
    logList.loadTask = nil
    reflog.loadTask?.cancel()
    reflog.loadTask = nil
    reflog.loadMoreTask?.cancel()
    reflog.loadMoreTask = nil
    reflog.generation += 1
    comparisonWorkspace.loadTask?.cancel()
    comparisonWorkspace.loadTask = nil
    cancelBranchComparisonTasks()
    comparisonWorkspace.repository = nil
    comparisonWorkspace.repositoryPath = nil
    logList.generation += 1
    repositoryStatus.isLoading = true
    logList.isLoading = projectWorkspace.toolWindowMode == .log
    repositoryStatus.loadError = nil
    commitWorkspace.feedback = nil
    stashRecovery.popConflictInProgress = false
    stashRecovery.applyConflictInProgress = false
    shelfWorkspace.conflictInProgress = false
    shelfWorkspace.conflictIsPop = false
    shelfWorkspace.conflictIsDirectPatch = false
    shelfWorkspace.pendingConflictName = nil
    shelfWorkspace.pendingConflictRepository = nil
    shelfWorkspace.pendingConflictChangeList = nil
    shelfWorkspace.pendingConflictPatch = nil
    shelfWorkspace.pendingConflictNotificationID = nil
    stashRecovery.pendingConflictNotificationID = nil
    stashRecovery.pendingPopIndex = nil
    stashRecovery.pendingPopID = nil
    stashRecovery.pendingPullStashPop = false
    stashRecovery.pendingPullStashID = nil
    stashRecovery.pendingPullStashMessage = nil
    stashRecovery.pendingPullShelfName = nil
    operationRecovery.showConflictResolver = false
    // The split workspaces keep their own selections. Clear them before the
    // new repository starts publishing data so a previous project's diff or
    // stash preview cannot remain actionable during the transition.
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    logSelectionState.selectedIDs = []
    reflog.rootPath = nil
    reflog.rootRepo = nil
    reflog.entries = []
    reflog.selection = nil
    reflog.selectedIDs = []
    stashUI.previewStashID = nil
    stashUI.previewText = nil
    stashUI.showPreview = false
    shelfWorkspace.previewName = nil
    shelfWorkspace.previewText = nil
    shelfWorkspace.showPreview = false
    gitSettings.remoteProtectedBranchPatterns = []
    gitSettings.remoteProtectedBranchPatternsByRoot = [:]
    repositoryStatus.isShallowRepository = false
    let requestedPath = projectPath
    logBranchesPanel.selectionActionRaw = GitBranchesPopupSettings.stringValue(
        GitBranchesPopupSettings.logSelectionActionKey,
        for: requestedPath
    )
    logBranchesPanel.groupByDirectory = GitBranchesPopupSettings.value(
        GitBranchesPopupSettings.groupByDirectoryKey,
        for: requestedPath
    )
    logBranchesPanel.groupByRepository = GitBranchesPopupSettings.value(
        GitBranchesPopupSettings.groupByRepositoryKey,
        for: requestedPath
    )
    applyProjectGitExecutableOverride(for: requestedPath, roots: [requestedPath])
    let shouldLoadReflog = logList.viewMode == .reflog
    Task.detached(priority: .userInitiated) {
        do {
            let r = try openRepository(path: requestedPath)
            let bs = try r.branchList()
            let hid = r.headCommitId()
            DiagnosticsLogger.shared.record(
                operation: "project",
                repositoryPath: requestedPath,
                code: "opened"
            )
            await MainActor.run {
                guard !(self.externalLogWindow && self.logRuntime.externalSessionDisposed) else { return }
                let root = r.workdir() ?? requestedPath
                self.projectWorkspace.path = root
                self.projectWorkspace.inputPath = root
                self.loadMergeDialogSettings(for: root)
                self.loadRebaseDialogSettings(for: root)
                self.logBranchesPanel.selectionActionRaw = GitBranchesPopupSettings.stringValue(
                    GitBranchesPopupSettings.logSelectionActionKey,
                    for: root
                )
                self.logBranchesPanel.groupByDirectory = GitBranchesPopupSettings.value(
                    GitBranchesPopupSettings.groupByDirectoryKey,
                    for: root
                )
                self.logBranchesPanel.groupByRepository = GitBranchesPopupSettings.value(
                    GitBranchesPopupSettings.groupByRepositoryKey,
                    for: root
                )
                self.loadProjectProtectedBranchSettings(for: root)
                self.gitSettings.projectIncomingCheckStrategyRaw = GitIncomingCheckStrategySettings.projectRawValue(for: root)
                self.gitSettings.projectFetchTagsMode = GitFetchTagsSettings.mode(for: root)
                self.gitSettings.projectUpdateMethod = GitUpdateMethodSettings.method(for: root)
                self.projectWorkspace.repository = r
                if shouldLoadReflog {
                    self.reflog.rootPath = root
                    self.reflog.rootRepo = r
                    self.prepareReflogRoot()
                }
                self.logList.activeRootPath = nil
                self.logList.activeRepo = nil
                self.logRuntime.activeBranches = []
                self.logRuntime.activeRemoteBranches = []
                self.logRuntime.activeRemotes = []
                self.logRuntime.aggregateBranchFilters = []
                self.logRuntime.aggregateRevisionRanges = []
                self.logRuntime.externalAggregateLoadStarted = false
                let preserveInitialExternalLogRoots = self.externalLogWindow
                    && !self.logRuntime.externalRootRequestConsumed
                    && !self.initialExternalLogRootPaths.isEmpty
                if preserveInitialExternalLogRoots {
                    self.logRuntime.aggregateRootPaths = self.initialExternalLogRootPaths
                    self.logRuntime.externalRootSelectionInitialized = true
                    self.logRuntime.externalRootRequestConsumed = true
                } else {
                    self.logRuntime.aggregateRootPaths = []
                    self.logRuntime.externalRootSelectionInitialized = false
                }
                self.logRuntime.aggregateRepositories = [:]
                self.logRuntime.aggregateLoadedCounts = [:]
                self.restorePersistedMultiRootRebaseSession(for: root)
                if self.rebaseWorkspace.multiRootSession == nil {
                    self.restorePersistedSingleRootRebaseState(for: root)
                    self.restorePersistedPullPreservation(for: root)
                }
                self.rememberRecentPath(root)
                self.repositoryStatus.headId = hid
                // The log and the current branch are the critical path. Do not
                // wait for repository-wide reachability scans before exposing
                // the graph: large repositories such as IntelliJ can contain
                // millions of packed objects.
                self.branchWorkspace.branches = bs
                self.refreshLogMyBranches()
                self.fileWorkspace.selection = nil; self.fileWorkspace.fileSelection = nil
                self.logSelectionState.selection = nil
                self.comparisonWorkspace.selection = nil
                self.comparisonWorkspace.selectedPaths = []
                if let cachedStatus = loadPersistedStatusCache(rootPath: root),
                   let snapshot = cachedStatus.restoredSnapshot(rootPath: root) {
                    self.repositoryStatus.entries = snapshot.files
                    self.repositoryStatus.changeLists = snapshot.changeLists
                    self.repositoryStatus.isShowingCachedStatusSnapshot = true
                } else {
                    self.repositoryStatus.entries = []
                    self.repositoryStatus.changeLists = []
                    self.repositoryStatus.isShowingCachedStatusSnapshot = false
                }
                self.repositoryStatus.ignoredRules = []
                self.repositoryStatus.stagingModel = nil
                self.repositoryStatus.lastIndexRevision = nil
                self.mergeWorkspace.inProgress = false
                self.mergeWorkspace.initialHead = nil
                self.operationRecovery.operation = nil
                expireOperationRecoveryNotifications()
                self.repositoryStatus.isLoading = false
                self.feedbackCenter.success("Project opened")
            }

            // The permanent graph is intentionally loaded after the repository
            // is visible. Route the first load through the same loader used by
            // refresh/filter changes so the persisted snapshot is available
            // after relaunch and the active tab query is not silently dropped.
            await MainActor.run {
                guard self.projectWorkspace.repository === r else { return }
                if self.projectWorkspace.toolWindowMode == .log {
                    self.loadLog(reset: true)
                }
            }

            // Status is the first thing the Commit/Stash workspace needs.
            // Publish it as soon as that scan completes instead of waiting for
            // tags, remotes, worktrees, and the staging model. The old serial
            // bundle made the left workspace look empty for the entire
            // repository metadata scan.
            Task.detached(priority: .utility) {
                do {
                    let st = try r.status()
                    let containsRename = st.contains {
                        $0.staged == .renamed || $0.unstaged == .renamed
                    }
                    let cls = (try? (containsRename
                        ? r.changelistList()
                        : r.changelistListForPaths(currentPaths: st.map(\.path)))) ?? []
                    let mergePending = r.mergeInProgress()
                    let shelveRestore = try? r.shelveRestoreInfo()
                    await MainActor.run {
                        guard self.projectWorkspace.repository === r else { return }
                        self.repositoryStatus.entries = st
                        self.repositoryStatus.changeLists = cls
                        self.repositoryStatus.isShowingCachedStatusSnapshot = false
                        if let rootPath = r.workdir() {
                            savePersistedStatusCache(
                                rootPath: rootPath,
                                files: st,
                                changeLists: cls
                            )
                        }
                        self.mergeWorkspace.inProgress = mergePending
                        if self.mergeWorkspace.inProgress, self.projectWorkspace.toolWindowMode != .log {
                            self.fileWorkspace.selection = st.first(where: {
                                $0.staged == .conflicted || $0.unstaged == .conflicted
                            })?.path
                            self.operationRecovery.showConflictResolver = st.contains {
                                $0.staged == .conflicted || $0.unstaged == .conflicted
                            }
                        } else if let shelveRestore {
                            self.shelfWorkspace.pendingConflictName = shelveRestore.name
                            self.shelfWorkspace.pendingConflictRepository = r
                            self.shelfWorkspace.pendingConflictChangeList = shelveRestore.targetChangeList
                            self.shelfWorkspace.conflictIsPop = shelveRestore.isPop
                            self.shelfWorkspace.conflictIsDirectPatch = shelveRestore.isDirectPatch
                            self.shelfWorkspace.pendingConflictPatch = shelveRestore.patch
                            self.shelfWorkspace.conflictInProgress = true
                            self.operationRecovery.initialPath = shelveRestore.paths.first
                            if self.projectWorkspace.toolWindowMode != .log {
                                self.fileWorkspace.selection = shelveRestore.paths.first
                                self.operationRecovery.showConflictResolver = true
                            }
                        }
                        self.loadMultiRoots()
                    }
                } catch {
                    await MainActor.run {
                        guard self.projectWorkspace.repository === r else { return }
                        self.repositoryStatus.isShowingCachedStatusSnapshot = !self.repositoryStatus.entries.isEmpty
                        self.feedbackCenter.warning(
                            "Status refresh failed",
                            detail: errorMessage(error),
                            nextStep: "Refresh the Changes view after checking the repository."
                        )
                        self.loadMultiRoots()
                    }
                }

                        // Secondary metadata is intentionally independent of
                        // the visible status result. Each call is still off the
                        // main actor, but a slow remote/ref scan can no longer
                        // hold up the first usable Commit/Stash rows.
                        Task.detached(priority: .utility) {
                            let ignoredRules = (try? r.ignoredRules()) ?? []
                            let recentMessages = (try? r.recentCommitMessages(limit: 10)) ?? []
                            let staging = try? r.stagingModel()
                            let operationState = try? r.operationState()
                            let ss = (try? r.stashList()) ?? []
                            let sh = (try? r.shelveList()) ?? []
                            let dsh = (try? r.shelveDeletedList()) ?? []
                            let rs = (try? r.remoteList()) ?? []
                            let isShallow = r.isShallow()
                            let remoteBranches = (try? r.remoteBranchList()) ?? []
                            let syncStatuses = (try? r.syncStatus()) ?? []
                            let ts = (try? r.tagList()) ?? []
                            let submodules = (try? r.submoduleList()) ?? []
                            let worktrees = (try? r.worktreeList()) ?? []
                            let recentBranches = (try? r.recentBranches(limit: 10)) ?? []
                            let mergePending = r.mergeInProgress()
                            await MainActor.run {
                                guard self.projectWorkspace.repository === r else { return }
                                self.repositoryStatus.ignoredRules = ignoredRules
                                self.commitWorkspace.recentMessages = recentMessages
                                self.repositoryStatus.stagingModel = staging
                                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                        self.operationRecovery.operation = operationState
                        self.mergeWorkspace.inProgress = mergePending || self.stashRecovery.popConflictInProgress || self.stashRecovery.applyConflictInProgress
                                self.stashUI.stashes = ss; self.remoteWorkspace.remotes = rs
                                self.repositoryStatus.isShallowRepository = isShallow
                                self.restoreRemoteProtectedBranchPatterns(for: rs, projectPath: self.projectWorkspace.path)
                                self.branchWorkspace.remoteBranches = remoteBranches
                                self.branchWorkspace.recentBranches = recentBranches; self.branchWorkspace.syncStatuses = syncStatuses
                                self.shelfWorkspace.shelves = sh; self.shelfWorkspace.deletedShelves = dsh; self.tagWorkspace.tags = ts
                        self.submoduleWorkspace.submodules = submodules
                        self.worktreeWorkspace.worktrees = worktrees
                        if let operationState,
                           let rootPath = r.workdir() {
                            self.feedbackCenter.expire(
                                notificationID: self.logApplyRecoveryNotificationID(rootPath: rootPath)
                            )
                            self.logSelectionState.applyRecoveryNotificationFingerprints.removeValue(
                                forKey: operationRecoveryNotificationRootKey(rootPath)
                            )
                            self.publishOperationRecoveryNoticeIfNeeded(
                                state: operationState,
                                rootPath: rootPath
                            )
                        } else if let rootPath = r.workdir() {
                            _ = self.publishLogApplyRecoveryNoticeIfNeeded(rootPath: rootPath)
                        }
                    }
                        }
                    }
        } catch {
            await MainActor.run {
                DiagnosticsLogger.shared.record(
                    level: .error,
                    operation: "project",
                    repositoryPath: requestedPath,
                    code: "open-failed"
                )
                self.repositoryStatus.loadError = errorMessage(error)
                self.projectWorkspace.repository = nil
                self.repositoryStatus.entries = []; self.repositoryStatus.isLoading = false
                self.feedbackCenter.error("Open project failed", detail: errorMessage(error), nextStep: "Choose a valid Git repository and retry.")
            }
        }
    }
}

func resetProjectState() {
    expireOperationRecoveryNotifications()
    repositoryStatus.changeDeliveryTask?.cancel()
    repositoryStatus.changeDeliveryTask = nil
    repositoryStatus.changeBatch.removeAll()
    repositoryStatus.externalVCSActionManager.removeAll()
    repositoryStatus.dirtyScopeManager.removeAll()
    repositoryStatus.dirtyFileManager.removeAll()
    multiRootWorkspace.loadTask?.cancel()
    multiRootWorkspace.loadTask = nil
    multiRootWorkspace.loadGeneration &+= 1
    multiRootWorkspace.loadNeedsRefresh = false
    multiRootWorkspace.loadCompletion = nil
    logList.refreshTask?.cancel()
    logList.refreshTask = nil
    logList.loadTask?.cancel()
    logList.loadTask = nil
    reflog.loadTask?.cancel()
    reflog.loadTask = nil
    reflog.loadMoreTask?.cancel()
    reflog.loadMoreTask = nil
    logSelectionState.detailLoadTask?.cancel()
    logSelectionState.detailLoadTask = nil
    reflog.detailLoadTask?.cancel()
    reflog.detailLoadTask = nil
    comparisonWorkspace.loadTask?.cancel()
    comparisonWorkspace.loadTask = nil
    comparisonWorkspace.repository = nil
    logList.activeRootPath = nil
    logList.activeRepo = nil
    logRuntime.activeBranches = []
    logRuntime.activeRemoteBranches = []
    logRuntime.activeRemotes = []
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.externalRootSelectionInitialized = false
    logRuntime.externalAggregateLoadStarted = false
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logList.generation += 1
    reflog.generation += 1
    logBranchesPanel.showMyTask?.cancel()
    logBranchesPanel.showMyTask = nil
    logBranchesPanel.showOnlyMy = false
    logBranchesPanel.myBranchIDs = []
    logBranchesPanel.isLoadingMy = false
    feedbackCenter.clearHistory()
    projectWorkspace.repository = nil
    gitSettings.projectIncomingCheckStrategyRaw = nil
    gitSettings.projectFetchTagsMode = .default
    gitSettings.projectUpdateMethod = .merge
    logBranchesPanel.selectionActionRaw = LogBranchSelectionAction.navigate.rawValue
    logBranchesPanel.groupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    rebaseWorkspace.multiRootSession = nil
    rebaseWorkspace.multiRootRollbackContext = nil
    repositoryStatus.entries = []
    repositoryStatus.changeLists = []
    repositoryStatus.isShowingCachedStatusSnapshot = false
    repositoryStatus.ignoredRules = []
    repositoryStatus.stagingModel = nil
    repositoryStatus.lastIndexRevision = nil
    repositoryStatus.headId = nil
    logList.entries = []
    logSelectionState.tabs = [LogTabDescriptor()]
    logSelectionState.activeTabID = nil
    logSelectionState.detailCommit = nil
    branchComparison.firstEntries = []
    branchComparison.secondEntries = []
    branchComparison.selectionID = nil
    cancelBranchComparisonTasks()
    branchComparison.firstHasMore = false
    branchComparison.secondHasMore = false
    branchComparison.firstError = nil
    branchComparison.secondError = nil
    branchComparison.error = nil
    branchComparison.isLoading = false
    reflog.detailCommit = nil
    reflog.detailCommits = []
    logList.isLoading = false
    logList.isShowingCachedSnapshot = false
    branchWorkspace.branches = []
    branchWorkspace.comparisons = [:]
    stashUI.stashes = []
    shelfWorkspace.shelves = []
    shelfWorkspace.deletedShelves = []
    remoteWorkspace.remotes = []
    repositoryStatus.isShallowRepository = false
    gitSettings.remoteProtectedBranchPatterns = []
    gitSettings.remoteProtectedBranchPatternsByRoot = [:]
    branchWorkspace.remoteBranches = []
    branchWorkspace.syncStatuses = []
    tagWorkspace.tags = []
    worktreeWorkspace.worktrees = []
    worktreeWorkspace.feedback = nil
    operationRecovery.consoleResult = nil
    reflog.entries = []
    reflog.selection = nil
    reflog.selectedIDs = []
    reflog.rootPath = nil
    reflog.rootRepo = nil
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    logSelectionState.selectedIDs = []
    stashUI.previewStashID = nil
    stashUI.previewText = nil
    stashUI.showPreview = false
    shelfWorkspace.previewName = nil
    shelfWorkspace.previewText = nil
    shelfWorkspace.showPreview = false
    logSelectionState.selection = nil
    comparisonWorkspace.selection = nil
    comparisonWorkspace.selectedPaths = []
    mergeWorkspace.inProgress = false
    mergeWorkspace.initialHead = nil
    stashRecovery.popConflictInProgress = false
    stashRecovery.applyConflictInProgress = false
    shelfWorkspace.conflictInProgress = false
    shelfWorkspace.conflictIsPop = false
    shelfWorkspace.conflictIsDirectPatch = false
    shelfWorkspace.pendingConflictName = nil
    shelfWorkspace.pendingConflictRepository = nil
    shelfWorkspace.pendingConflictChangeList = nil
    shelfWorkspace.pendingConflictPatch = nil
    shelfWorkspace.pendingConflictNotificationID = nil
    stashRecovery.pendingConflictNotificationID = nil
    stashRecovery.pendingPopIndex = nil
    stashRecovery.pendingPopID = nil
    stashRecovery.pendingPullStashPop = false
    stashRecovery.pendingPullStashID = nil
    stashRecovery.pendingPullStashMessage = nil
    stashRecovery.pendingPullShelfName = nil
    operationRecovery.showConflictResolver = false
    repositoryStatus.loadError = nil
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

func multiRootResetRollbackRequest(
    targets: [PersistedMultiRootResetRollbackTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootReset,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootResetRollbackTargets: targets
    )
}

func multiRootResetRollbackAction(
    targets: [PersistedMultiRootResetRollbackTarget]
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = multiRootResetRollbackRequest(targets: targets)
    return FeedbackAction(title: "Rollback Soft Reset", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

/// Roll back only soft-reset roots whose expected HEAD and branch still match.
/// The engine operation is ref-only, so user edits made after the reset remain
/// untouched. Failed roots stay as retryable semantic targets.
func rollbackMultiRootReset(
    _ targets: [PersistedMultiRootResetRollbackTarget]
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Rollback multi-root soft reset")
    Task.detached(priority: .userInitiated) {
        do {
            let results = try Arbor.rollbackMultiRootReset(
                targets: targets.map { $0.makeLiveTarget() }
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.loadMultiRoots()
                let failures = results.filter { !$0.success }
                guard !failures.isEmpty else {
                    self.feedbackCenter.success(
                        "Soft reset rollback completed",
                        detail: "Restored \(results.count) root\(results.count == 1 ? "" : "s").",
                        notificationID: self.multiRootResetNotificationID(),
                        notificationGroup: .standard
                    )
                    return
                }
                let failedPaths = Set(failures.map(\.rootPath))
                let remainingTargets = targets.filter { failedPaths.contains($0.rootPath) }
                let retryRequest = self.multiRootResetRollbackRequest(targets: remainingTargets)
                self.feedbackCenter.warning(
                    "Soft reset rollback partially failed",
                    detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                    nextStep: "Review the changed roots and retry only the remaining rollback targets.",
                    additionalActions: remainingTargets.isEmpty
                        ? []
                        : [FeedbackAction(
                            title: "Retry Remaining Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }],
                    notificationID: self.multiRootResetNotificationID(),
                    notificationGroup: .standard
                )
            }
        } catch {
            await MainActor.run {
                let retryRequest = self.multiRootResetRollbackRequest(targets: targets)
                self.feedbackCenter.warning(
                    "Soft reset rollback failed",
                    detail: errorMessage(error),
                    nextStep: "Confirm the roots still have the expected HEAD, then retry the rollback action.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Soft Reset Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    ],
                    notificationID: self.multiRootResetNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

/// IDX-001「Add to Git / Ignore」入口：追加规则到工作区或选定的 .gitignore。
/// Multiple selected unversioned files share one ignore-file choice and are
/// validated by Rust before any rule is written.
struct IgnoreFileCreationRequest: Equatable {
    let paths: [String]
    let workdir: String
}

func ignorePaths(_ paths: [String], ignoreFilePath: String? = nil) {
    guard let repo else { return }
    let paths = Array(Set(paths)).sorted()
    guard !paths.isEmpty else { return }
    if let workdir = repo.workdir(),
       gitIgnoreNeedsRootCreationConfirmation(
           ignoreFilePath: ignoreFilePath,
           workdir: workdir
       ) {
        fileWorkspace.pendingIgnoreFileCreation = IgnoreFileCreationRequest(
            paths: paths,
            workdir: URL(fileURLWithPath: workdir).standardizedFileURL.path
        )
        return
    }
    performIgnorePaths(paths, ignoreFilePath: ignoreFilePath)
}

func confirmPendingIgnoreFileCreation() {
    guard let request = fileWorkspace.pendingIgnoreFileCreation else { return }
    fileWorkspace.pendingIgnoreFileCreation = nil
    guard let repo,
          let workdir = repo.workdir(),
          URL(fileURLWithPath: workdir).standardizedFileURL.path == request.workdir
    else {
        feedbackCenter.error(
            "Ignore failed",
            detail: "The repository changed while confirming .gitignore creation.",
            nextStep: "Select the files again and retry."
        )
        return
    }
    performIgnorePaths(request.paths, ignoreFilePath: nil)
}

func performIgnorePaths(_ paths: [String], ignoreFilePath: String?) {
    guard let repo else { return }
    let targetPaths: [String]
    if let ignoreFilePath, let workdir = repo.workdir() {
        targetPaths = gitIgnoreTargetPaths(
            for: paths,
            ignoreFile: ignoreFilePath,
            workdir: workdir
        )
    } else {
        targetPaths = paths
    }
    guard !targetPaths.isEmpty else { return }
    beginFeedbackOperation("Ignore file")
    Task.detached(priority: .userInitiated) {
        do {
            let rules: [String]
            if let ignoreFilePath, let workdir = repo.workdir() {
                let relativeRules = targetPaths.map { path in
                    gitIgnoreRule(
                        for: path,
                        ignoreFile: ignoreFilePath,
                        workdir: workdir
                    )
                }
                rules = try repo.addToGitignoreAtPaths(
                    rules: relativeRules,
                    ignoreFile: ignoreFilePath,
                    targetPaths: targetPaths
                )
            } else {
                rules = try repo.addToGitignoreRules(rules: targetPaths)
            }
            await MainActor.run {
                let destination = ignoreFilePath ?? ".gitignore"
                self.feedbackCenter.success(
                    "Ignored",
                    detail: "\(rules.joined(separator: ", ")) -> \(destination)"
                )
                self.operationRecovery.feedback = nil
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Ignore failed", detail: errorMessage(error), nextStep: "规则必须是非空单行。")
            }
        }
    }
}

/// Phase 5：在文件编辑器中打开 .gitignore（不存在则创建）。
func editGitignore() {
    guard let repo, let workdir = repo.workdir() else { return }
    let path = URL(fileURLWithPath: workdir).appendingPathComponent(".gitignore").path
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

/// REPO-001:发现项目下的所有 Git root(聚合视图数据源)。
func loadMultiRoots(onCompleted: (() -> Void)? = nil) {
    if multiRootWorkspace.loadTask != nil {
        // Native repository calls are synchronous, so cancelling their Swift
        // task does not stop work already running in the engine. Coalesce
        // requests and run one fresh scan after the active one finishes.
        multiRootWorkspace.loadNeedsRefresh = true
        if let onCompleted {
            multiRootWorkspace.loadCompletion = onCompleted
        }
        return
    }
    multiRootWorkspace.loadGeneration &+= 1
    let generation = multiRootWorkspace.loadGeneration
    guard let projectPath = projectWorkspace.path else {
        onCompleted?()
        return
    }
    let requestedProjectPath = canonicalExternalLogPath(projectPath)
    let requestedExternalRootPaths = externalLogWindow
        ? initialExternalLogRootPaths.map(canonicalExternalLogPath)
        : []
    let task = Task.detached(priority: .utility) {
        do {
            var roots = try discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            guard !Task.isCancelled else { return }
            if !requestedExternalRootPaths.isEmpty {
                var knownRootPaths = Set(roots.map { canonicalExternalLogPath($0.path) })
                for requestedRootPath in requestedExternalRootPaths
                    where !knownRootPaths.contains(requestedRootPath) {
                    guard let requestedRoot = try? discoverGitRoots(
                        scanRoot: requestedRootPath,
                        maxDepth: 0
                    ).first(where: {
                        canonicalExternalLogPath($0.path) == requestedRootPath
                    }) else {
                        continue
                    }
                    roots.append(requestedRoot)
                    knownRootPaths.insert(requestedRootPath)
                }
            }
            guard !Task.isCancelled else { return }
            let operationStates = roots.compactMap { root -> (String, OperationState)? in
                guard root.operation != nil,
                      let rootRepo = try? openRepository(path: root.path),
                      let state = try? rootRepo.operationState() else {
                    return nil
                }
                return (root.path, state)
            }
            if let override = GitExecutableSettings.projectOverride(for: projectPath) {
                let registeredRoots = GitExecutableSettings.registeredRoots(
                    projectPath: projectPath,
                    repositoryRoot: nil,
                    discoveredRoots: roots.map(\.path)
                )
                _ = try? setProjectGitExecutable(
                    projectPath: projectPath,
                    rootPaths: registeredRoots,
                    path: override
                )
            } else {
                clearProjectGitExecutable(projectPath: projectPath)
            }
            guard !Task.isCancelled else { return }
            var snapshots = try listMultiRootBranches(scanRoot: projectPath)
            guard !Task.isCancelled else { return }
            if !requestedExternalRootPaths.isEmpty {
                let knownSnapshotPaths = Set(snapshots.map {
                    canonicalExternalLogPath($0.rootPath)
                })
                for requestedRootPath in requestedExternalRootPaths
                    where !knownSnapshotPaths.contains(requestedRootPath) {
                    if let requestedSnapshot = try? listMultiRootBranches(
                        scanRoot: requestedRootPath
                    ).first(where: {
                        canonicalExternalLogPath($0.rootPath) == requestedRootPath
                    }) {
                        snapshots.append(requestedSnapshot)
                    }
                }
            }
            let conflictGroups = roots.compactMap { root -> MultiRootConflictGroup? in
                guard !Task.isCancelled else { return nil }
                guard let rootRepo = try? openRepository(path: root.path),
                      let entries = try? rootRepo.status() else { return nil }
                let paths = entries
                    .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                    .map(\.path)
                    .sorted()
                guard !paths.isEmpty else { return nil }
                return MultiRootConflictGroup(
                    rootPath: root.path,
                    displayName: root.displayName,
                    relativePath: root.relativePath,
                    operation: root.operation,
                    paths: paths
                )
            }
            guard !Task.isCancelled else { return }
            let updateStashRoots = Set(
                snapshots.compactMap { snapshot in
                    snapshot.stashes.contains(where: { isArborUpdateLocalChangesName($0.message) })
                        || snapshot.shelves.contains(where: { isArborTemporaryShelfName($0.name) })
                        ? snapshot.rootPath
                        : nil
                }
            )
            let rootsSnapshot = roots
            let snapshotsSnapshot = snapshots
            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.multiRootWorkspace.loadGeneration,
                      self.projectWorkspace.path.map(canonicalExternalLogPath) == requestedProjectPath,
                      !(self.externalLogWindow && self.logRuntime.externalSessionDisposed) else { return }
                self.multiRootWorkspace.loadTask = nil
                let needsRefresh = self.multiRootWorkspace.loadNeedsRefresh
                let completion = self.multiRootWorkspace.loadCompletion
                self.multiRootWorkspace.loadNeedsRefresh = false
                self.multiRootWorkspace.loadCompletion = nil
                if needsRefresh {
                    self.loadMultiRoots(onCompleted: completion)
                    return
                }
                let externalLogNeedsInitialLoad = self.externalLogWindow
                    && !self.logRuntime.externalAggregateLoadStarted
                    && !rootsSnapshot.isEmpty
                let externalLogSelection = reconciledExternalLogRootSelection(
                    availableRoots: rootsSnapshot.map(\.path),
                    selectedRoots: self.logRuntime.aggregateRootPaths,
                    initialized: self.logRuntime.externalRootSelectionInitialized
                )
                let externalLogSelectionChanged = self.externalLogWindow
                    && externalLogSelection != self.logRuntime.aggregateRootPaths
                self.multiRootWorkspace.roots = rootsSnapshot
                self.multiRootWorkspace.branchSnapshots = snapshotsSnapshot
                self.gitSettings.remoteProtectedBranchPatternsByRoot = Dictionary(
                    uniqueKeysWithValues: snapshotsSnapshot.compactMap { snapshot -> (String, [String])? in
                        guard !self.hostingRepositories(for: snapshot.remotes).isEmpty else {
                            return nil
                        }
                        let key = canonicalExternalLogPath(snapshot.rootPath)
                        return (key, GitProtectedBranchRules.loadRemotePatterns(for: key))
                    }
                )
                if let primaryPath = self.projectWorkspace.path {
                    let primaryKey = canonicalExternalLogPath(primaryPath)
                    self.gitSettings.remoteProtectedBranchPatterns =
                        self.gitSettings.remoteProtectedBranchPatternsByRoot[primaryKey] ?? []
                }
                self.operationRecovery.multiRootConflictGroups = conflictGroups
                if let selectedShelfRoot = self.shelfWorkspace.rootPath,
                   !rootsSnapshot.contains(where: {
                       canonicalExternalLogPath($0.path)
                           == canonicalExternalLogPath(selectedShelfRoot)
                   }) {
                    self.shelfWorkspace.rootLoadGeneration += 1
                    self.shelfWorkspace.rootPath = nil
                    self.shelfWorkspace.rootLoading = false
                    self.shelfWorkspace.rootRepository = nil
                    self.shelfWorkspace.rootError = nil
                    self.shelfWorkspace.rootSnapshots.removeValue(
                        forKey: canonicalExternalLogPath(selectedShelfRoot)
                    )
                    self.shelfWorkspace.previewName = nil
                    self.shelfWorkspace.previewRootPath = nil
                    self.shelfWorkspace.previewText = nil
                    self.shelfWorkspace.previewIsDeleted = false
                    self.shelfWorkspace.showPreview = false
                }
                if self.externalLogWindow {
                    self.logRuntime.aggregateRootPaths = externalLogSelection
                    self.logRuntime.externalRootSelectionInitialized = !externalLogSelection.isEmpty
                }
                let previousOperationRoots = Set(
                    self.operationRecovery.notificationFingerprints.keys
                )
                let activeOperationRoots = Set(operationStates.map {
                    operationRecoveryNotificationRootKey($0.0)
                })
                for rootKey in previousOperationRoots.subtracting(activeOperationRoots) {
                    self.feedbackCenter.expire(
                        notificationID: operationRecoveryNotificationID(rootPath: rootKey)
                    )
                }
                self.operationRecovery.notificationFingerprints =
                    self.operationRecovery.notificationFingerprints.filter {
                        activeOperationRoots.contains($0.key)
                    }
                for (rootPath, state) in operationStates {
                    self.publishOperationRecoveryNoticeIfNeeded(
                        state: state,
                        rootPath: rootPath
                    )
                }
                if self.logBranchesPanel.showOnlyMy {
                    self.refreshLogMyBranches()
                }
                if let activeRootPath = self.logList.activeRootPath {
                    if snapshotsSnapshot.count <= 1
                        || !snapshotsSnapshot.contains(where: { $0.rootPath == activeRootPath }) {
                        self.logList.activeRootPath = nil
                        self.logList.activeRepo = nil
                        self.logRuntime.activeBranches = []
                        self.logRuntime.activeRemoteBranches = []
                        self.logRuntime.activeRemotes = []
                    } else if let activeSnapshot = snapshotsSnapshot.first(
                        where: { $0.rootPath == activeRootPath }
                    ) {
                        // Keep the Log context tied to the refreshed root while
                        // retaining the live Repository for operations such as
                        // remote URL lookup and credential-aware actions.
                        self.logRuntime.activeBranches = activeSnapshot.branches
                        self.logRuntime.activeRemoteBranches = activeSnapshot.remoteBranches
                        if let activeRepo = self.logList.activeRepo {
                            self.logRuntime.activeRemotes = (try? activeRepo.remoteList()) ?? self.logRuntime.activeRemotes
                        }
                    }
                }
                if self.logRuntime.aggregateBranchFilters.contains(where: { filter in
                    !snapshotsSnapshot.contains(where: { $0.rootPath == filter.rootPath })
                }) {
                    self.logRuntime.aggregateBranchFilters = []
                    self.logRuntime.aggregateRevisionRanges = []
                    self.logRuntime.aggregateRepositories = [:]
                    self.logRuntime.aggregateLoadedCounts = [:]
                    self.logList.entries = []
                    self.logSelectionState.selection = nil
                    self.logSelectionState.selectedIDs = []
                }
                self.applyProjectGitExecutableOverride(
                    for: projectPath,
                    roots: rootsSnapshot.map(\.path)
                )
                // Rebuild this state from Git's stash stack on every refresh.
                // That makes a temporary Update stash discoverable after the
                // app is reopened instead of relying on in-memory bookkeeping.
                self.stashRecovery.multiRootUpdateStashedRoots = updateStashRoots
                self.scanPendingApplyRestores()
                if externalLogSelectionChanged {
                    if self.logRuntime.aggregateRootPaths.isEmpty {
                        self.logList.entries = []
                        self.logSelectionState.selection = nil
                        self.logSelectionState.selectedIDs = []
                    } else {
                        self.logRuntime.externalAggregateLoadStarted = true
                        if self.logList.viewMode == .command {
                            self.runLogCommand()
                        } else {
                            self.loadLog()
                        }
                    }
                } else if externalLogNeedsInitialLoad {
                    self.logRuntime.externalAggregateLoadStarted = true
                    if self.logList.viewMode == .command {
                        self.runLogCommand()
                    } else {
                        self.loadLog()
                    }
                }
                onCompleted?()
            }
        } catch {
            await MainActor.run {
                guard generation == self.multiRootWorkspace.loadGeneration,
                      self.projectWorkspace.path.map(canonicalExternalLogPath) == requestedProjectPath else {
                    return
                }
                self.multiRootWorkspace.loadTask = nil
                let needsRefresh = self.multiRootWorkspace.loadNeedsRefresh
                let completion = self.multiRootWorkspace.loadCompletion
                self.multiRootWorkspace.loadNeedsRefresh = false
                self.multiRootWorkspace.loadCompletion = nil
                if needsRefresh {
                    self.loadMultiRoots(onCompleted: completion)
                    return
                }
                self.multiRootWorkspace.roots = []
                self.multiRootWorkspace.branchSnapshots = []
                self.operationRecovery.multiRootConflictGroups = []
                self.stashRecovery.multiRootUpdateStashedRoots = []
                self.shelfWorkspace.rootLoadGeneration += 1
                self.shelfWorkspace.rootPath = nil
                self.shelfWorkspace.rootSnapshots = [:]
                self.shelfWorkspace.rootRepository = nil
                self.shelfWorkspace.rootLoading = false
                self.shelfWorkspace.rootError = nil
                self.logList.activeRootPath = nil
                self.logList.activeRepo = nil
                self.logRuntime.activeBranches = []
                self.logRuntime.activeRemoteBranches = []
                self.logRuntime.activeRemotes = []
                self.logRuntime.aggregateBranchFilters = []
                self.logRuntime.aggregateRevisionRanges = []
                self.logRuntime.aggregateRootPaths = []
                self.logRuntime.externalRootSelectionInitialized = false
                self.logRuntime.externalAggregateLoadStarted = false
                self.logRuntime.aggregateRepositories = [:]
                self.logRuntime.aggregateLoadedCounts = [:]
                onCompleted?()
            }
        }
    }
    multiRootWorkspace.loadTask = task
}

/// Open the project-level Changes Browser. Its write actions are still routed
/// to an explicit Git root rather than the window's primary repository.
func openMultiRootChanges() {
    multiRootWorkspace.showChanges = true
    loadMultiRootChanges()
}

struct MultiRootChangeMutationFailure: Sendable {
    let path: PersistedMultiRootChangePath
    let message: String
}

func runMultiRootChangeMutation(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    paths: [PersistedMultiRootChangePath]
) {
    let normalizedPaths = normalizedMultiRootChangePaths(paths)
    guard !normalizedPaths.isEmpty else {
        feedbackCenter.warning(
            operation == .stage ? "No changes selected for staging" : "No changes selected for unstaging"
        )
        return
    }

    let rootPaths = Array(Set(normalizedPaths.map(\.rootPath))).sorted()
    let notificationID = multiRootChangesBatchMutationNotificationID(
        operation: operation,
        changePaths: normalizedPaths
    )
    let operationTitle = operation == .stage ? "Stage selected changes" : "Unstage selected changes"
    beginFeedbackOperation(operationTitle, notificationID: notificationID)

    Task.detached(priority: .userInitiated) {
        var completed: [PersistedMultiRootChangePath] = []
        var failures: [MultiRootChangeMutationFailure] = []
        let pathsByRoot = Dictionary(grouping: normalizedPaths, by: \.rootPath)

        for rootPath in rootPaths {
            do {
                let rootRepo = try openRepository(path: rootPath)
                for change in pathsByRoot[rootPath, default: []] {
                    do {
                        switch operation {
                        case .stage:
                            try rootRepo.stage(path: change.path)
                        case .unstage:
                            try rootRepo.unstage(path: change.path)
                        default:
                            continue
                        }
                        completed.append(change)
                    } catch {
                        failures.append(
                            MultiRootChangeMutationFailure(
                                path: change,
                                message: errorMessage(error)
                            )
                        )
                    }
                }
            } catch {
                let message = errorMessage(error)
                failures.append(contentsOf: pathsByRoot[rootPath, default: []].map {
                    MultiRootChangeMutationFailure(path: $0, message: message)
                })
            }
        }

        let completedPaths = completed
        let failurePaths = failures
        await MainActor.run { [completedPaths, failurePaths] in
            self.loadMultiRootChanges()
            let verb = operation == .stage ? "staged" : "unstaged"
            if failurePaths.isEmpty {
                self.feedbackCenter.success(
                    "Selected changes \(verb)",
                    detail: "\(completedPaths.count) file(s) across \(rootPaths.count) Git root(s)",
                    notificationID: notificationID
                )
                return
            }

            let failureDetail = failurePaths.map {
                "\($0.path.rootPath): \($0.path.path)\n\($0.message)"
            }.joined(separator: "\n")
            let nextStep = "Fix the failed files, then retry only the remaining selected paths."
            if completedPaths.isEmpty {
                self.feedbackCenter.error(
                    "Selected changes failed to \(operation == .stage ? "stage" : "unstage")",
                    detail: failureDetail,
                    nextStep: nextStep,
                    additionalActions: [
                        self.multiRootChangesBatchRetryFeedbackAction(
                            operation: operation,
                            changePaths: failurePaths.map(\.path)
                        )
                    ],
                    notificationID: notificationID
                )
            } else {
                self.feedbackCenter.warning(
                    "Selected changes partially \(verb)",
                    detail: "\(completedPaths.count) succeeded;\n\(failureDetail)",
                    nextStep: nextStep,
                    additionalActions: [
                        self.multiRootChangesBatchRetryFeedbackAction(
                            operation: operation,
                            changePaths: failurePaths.map(\.path)
                        )
                    ],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Read status independently for every discovered Git root. The root path is
/// retained alongside the Repository so a diff can never fall back to the
/// primary repository merely because two roots contain the same relative path.
func loadMultiRootChanges() {
    multiRootWorkspace.changesGeneration &+= 1
    let generation = multiRootWorkspace.changesGeneration
    guard !multiRootWorkspace.roots.isEmpty else {
        multiRootWorkspace.changeGroups = []
        multiRootWorkspace.changesError = nil
        multiRootWorkspace.changesLoading = false
        return
    }

    let roots = multiRootWorkspace.roots.map {
        (path: $0.path, displayName: $0.displayName, relativePath: $0.relativePath)
    }
    multiRootWorkspace.changesLoading = true
    multiRootWorkspace.changesError = nil

    Task.detached(priority: .userInitiated) {
        var groups: [MultiRootChangeGroup] = []
        var failures: [String] = []

        for root in roots {
            do {
                let rootRepo = try openRepository(path: root.path)
                let entries = try rootRepo.status()
                groups.append(
                    MultiRootChangeGroup(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        repository: rootRepo,
                        entries: entries
                    )
                )
            } catch {
                failures.append("\(root.displayName): \(error.localizedDescription)")
            }
        }

        groups.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        let loadedGroups = groups
        let failureMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        await MainActor.run {
            guard generation == self.multiRootWorkspace.changesGeneration else { return }
            self.multiRootWorkspace.changeGroups = loadedGroups
            self.multiRootWorkspace.changesLoading = false
            self.multiRootWorkspace.changesError = failureMessage
        }
    }
}

func validateMultiRootRenameName(_ value: String) -> String? {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return nil }
    guard candidate != branchWorkspace.multiRootRenameOldName else {
        return String(localized: "The new name must be different.")
    }
    let selected = multiRootWorkspace.branchSnapshots.filter { snapshot in
        branchWorkspace.multiRootRenameSelectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains(where: { $0.name == branchWorkspace.multiRootRenameOldName })
    }
    for snapshot in selected {
        if let conflict = branchRenameConflictMessage(
            oldName: branchWorkspace.multiRootRenameOldName,
            newName: candidate,
            localBranchNames: snapshot.branches.map(\.name),
            remoteBranchNames: snapshot.remoteBranches.map(\.name)
        ) {
            return "\(conflict) (\(snapshot.relativePath))"
        }
        guard let rootRepo = try? openRepository(path: snapshot.rootPath) else { continue }
        do {
            try rootRepo.validateBranchName(name: candidate)
        } catch {
            return errorMessage(error)
        }
    }
    return nil
}

/// IntelliJ treats an Update Project run with no tracked, checked-out root as
/// NOT_READY. Detached or untracked roots may be skipped only when another
/// root can actually perform the update.
nonisolated static func updateProjectHasEligibleRoot(
    _ results: [RootOperationResult]
) -> Bool {
    results.contains { result in
        result.success && !result.skipped
    }
}

/// The engine performs IntelliJ's project-level readiness check before any
/// root is fetched or updated. Keep the presentation classifier tolerant of
/// the older single-root error wording as well, so a race that is detected at
/// the root boundary still follows the same unavailable/recovery flow.
nonisolated static func updateProjectIsNotReady(
    _ results: [RootOperationResult]
) -> Bool {
    results.contains { result in
        let message = result.message.lowercased()
        return message.contains("update not ready")
            || message.contains("another git operation is already in progress")
            || message.contains("unresolved conflicts remain")
    }
}

nonisolated static func skippedUpdateRootDetails(_ results: [RootOperationResult]) -> [String] {
    var rootsByReason: [String: [String]] = [:]
    for result in results where result.skipped {
        let reason = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        rootsByReason[reason.isEmpty ? "not available" : reason, default: []].append(result.displayName)
    }
    return rootsByReason.keys.sorted().compactMap { reason in
        guard let roots = rootsByReason[reason], !roots.isEmpty else { return nil }
        return "\(roots.joined(separator: ", ")) (\(reason))"
    }
}

struct UpdateRootRecoveryTarget: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case chooseUpstream
        case openBranches
    }

    let kind: Kind
    let rootPath: String
    let displayName: String
    let branch: String?
}

struct UpdateRootRecoveryRoot: Equatable, Sendable {
    let path: String
    let displayName: String
    let isSubmodule: Bool
    let headBranch: String?
}

/// Project Update skips detached or untracked roots instead of turning one
/// root's configuration problem into a compound-operation failure. Keep the
/// recovery target root-qualified so the follow-up action cannot accidentally
/// edit the current window's repository when the skipped root is nested.
nonisolated static func updateRootRecoveryTargets(
    results: [RootOperationResult],
    roots: [UpdateRootRecoveryRoot]
) -> [UpdateRootRecoveryTarget] {
    let rootsByPath = Dictionary(
        uniqueKeysWithValues: roots.map {
            (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0)
        }
    )
    var targets: [UpdateRootRecoveryTarget] = []
    for result in results where result.skipped {
        let path = URL(fileURLWithPath: result.rootPath).standardizedFileURL.path
        guard let root = rootsByPath[path], !root.isSubmodule else { continue }
        let message = result.message.lowercased()
        if message.contains("no configured upstream")
            || message.contains("tracking branch")
        {
            guard let branch = root.headBranch, !branch.isEmpty else { continue }
            targets.append(
                UpdateRootRecoveryTarget(
                    kind: .chooseUpstream,
                    rootPath: path,
                    displayName: root.displayName,
                    branch: branch
                )
            )
        } else if message.contains("detached head") {
            targets.append(
                UpdateRootRecoveryTarget(
                    kind: .openBranches,
                    rootPath: path,
                    displayName: root.displayName,
                    branch: nil
                )
            )
        }
    }
    return targets.sorted {
        if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
        return $0.rootPath < $1.rootPath
    }
}

nonisolated static func multiRootUpdateFailureDetails(
    _ results: [RootOperationResult],
    submoduleRootPaths: Set<String>
) -> [String] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func isDescendant(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor + "/")
    }

    let normalizedSubmodulePaths = Set(submoduleRootPaths.map(normalizedPath))
    let resultPaths = Dictionary(uniqueKeysWithValues: results.map {
        (normalizedPath($0.rootPath), $0)
    })
    let failedPaths = Set(results.filter { !$0.success }.map { normalizedPath($0.rootPath) })

    func nearestFailedAncestor(for path: String) -> String? {
        failedPaths
            .filter { $0 != path && isDescendant(path, of: $0) }
            .max { $0.count < $1.count }
    }

    var grouped: [String: [RootOperationResult]] = [:]
    for result in results where !result.success {
        let path = normalizedPath(result.rootPath)
        let groupPath = nearestFailedAncestor(for: path) ?? path
        grouped[groupPath, default: []].append(result)
    }
    for result in results where result.skipped {
        let path = normalizedPath(result.rootPath)
        guard normalizedSubmodulePaths.contains(path),
              let groupPath = nearestFailedAncestor(for: path) else { continue }
        grouped[groupPath, default: []].append(result)
    }

    var groupedResultPaths = Set<String>()
    var details: [String] = []
    for groupPath in grouped.keys.sorted() {
        guard let groupRoot = resultPaths[groupPath],
              let members = grouped[groupPath] else { continue }
        groupedResultPaths.formUnion(members.map { normalizedPath($0.rootPath) })
        details.append("\(groupRoot.displayName): \(groupRoot.message)")
        for member in members
            .filter({ normalizedPath($0.rootPath) != groupPath })
            .sorted(by: { $0.rootPath < $1.rootPath }) {
            details.append("  \(member.displayName): \(member.message)")
        }
    }

    var skippedByReason: [String: [String]] = [:]
    for result in results where result.skipped {
        let path = normalizedPath(result.rootPath)
        guard !groupedResultPaths.contains(path) else { continue }
        let reason = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        skippedByReason[reason.isEmpty ? "not available" : reason, default: []].append(result.displayName)
    }
    for reason in skippedByReason.keys.sorted() {
        guard let roots = skippedByReason[reason], !roots.isEmpty else { continue }
        details.append("\(roots.joined(separator: ", ")) (\(reason))")
    }
    return details
}

nonisolated static func multiRootUpdateSuccessDetail(
    _ results: [RootOperationResult],
    updatedFilesCount: Int? = nil
) -> String {
    let updatedResults = results.filter { $0.success && !$0.skipped }
    let parsedCommitCounts = updatedResults.compactMap { updatedCommitCount(from: $0.message) }
    let updatedCommits = parsedCommitCounts.reduce(0, +)
    var details: [String] = []
    if updatedResults.isEmpty {
        details.append("Nothing to update")
    } else if parsedCommitCounts.count == updatedResults.count && updatedCommits == 0 {
        details.append("Nothing to update")
    } else if parsedCommitCounts.isEmpty {
        details.append("\(updatedResults.count) updated")
    } else {
        details.append("\(updatedResults.count) updated · \(updatedCommits) commits")
    }
    if let updatedFilesCount,
       !updatedResults.isEmpty,
       !(parsedCommitCounts.count == updatedResults.count && updatedCommits == 0) {
        if parsedCommitCounts.count == updatedResults.count {
            details[0] = "\(updatedFilesCount) files updated in \(updatedCommits) commits"
        } else {
            details[0] = "\(updatedFilesCount) files updated"
        }
    }
    let skipped = skippedUpdateRootDetails(results)
    if !skipped.isEmpty {
        details.append("Skipped: \(skipped.joined(separator: "; "))")
    }
    return details.joined(separator: " · ")
}

func multiRootUpdateRollbackRequest(
    targets: [PersistedMultiRootUpdateRollbackTarget],
    kind: ArborVCSActionRequest.Kind = .rollbackMultiRootUpdate
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: kind,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootUpdateRollbackTargets: targets
    )
}

func multiRootUpdateRollbackAction(
    targets: [PersistedMultiRootUpdateRollbackTarget],
    title: String = "Rollback Updated Roots"
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = multiRootUpdateRollbackRequest(targets: targets)
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func updateRootRecoveryActions(
    _ targets: [UpdateRootRecoveryTarget]
) -> [FeedbackAction] {
    var actions: [FeedbackAction] = []
        for target in targets where target.kind == .chooseUpstream {
            guard let branch = target.branch else { continue }
            actions.append(
                FeedbackAction(title: "Choose Upstream · \(target.displayName)") {
                    self.presentUpstreamDialogInRoot(
                        rootPath: target.rootPath,
                        displayName: target.displayName,
                        branch: branch
                    )
                }
            )
        }
    if targets.contains(where: { $0.kind == .openBranches }) {
        actions.append(
            FeedbackAction(title: "Open Branches") {
                self.loadMultiRoots()
                self.branchWorkspace.showPopover = true
            }
        )
    }
    return actions
}

/// Vcs.UpdateProject first presents the platform options dialog unless the
/// project opted out. The selected method is applied only after confirmation;
/// Reset remains a dialog-side action and never persists a new update method.
func requestUpdateProject() {
    guard !isArborBackgroundVCSOperationInProgress(
        feedbackIsRunning: feedbackCenter.isRunning,
        multiRootIsRunning: multiRootWorkspace.running || multiRootWorkspace.updateDiscoveryRunning
    ) else { return }
    guard repo != nil else { return }
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else {
        executeMultiRootUpdate(rebase: gitSettings.projectUpdateMethod == .rebase)
        return
    }
    if GitUpdateOptionsDialogSettings.shouldShow(for: projectPath) {
        gitSettings.showUpdateProjectOptions = true
    } else {
        executeMultiRootUpdate(rebase: gitSettings.projectUpdateMethod == .rebase)
    }
}

/// Vcs.UpdateProject / ⌘T：多 root 项目必须一次更新所有 configured upstream，
/// 而不是只更新当前窗口绑定的 root。
func executeMultiRootUpdate(rebase: Bool) {
    guard !isArborBackgroundVCSOperationInProgress(
        feedbackIsRunning: feedbackCenter.isRunning,
        multiRootIsRunning: multiRootWorkspace.running || multiRootWorkspace.updateDiscoveryRunning
    ) else { return }
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    multiRootWorkspace.updateRebaseRootPaths = nil
    guard let projectPath = projectWorkspace.path else { return }
    multiRootWorkspace.updateDiscoveryRunning = true
    multiRootWorkspace.updateRebase = rebase
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            guard roots.count > 1 else {
                if rebase, let root = roots.first {
                    let preflight = try prepareMultiRootUpdate(
                        scanRoot: projectPath,
                        selectedRootPaths: [root.path],
                        tagMode: tagMode,
                        broker: broker,
                        cancel: cancel
                    )
                    if preflight.problematicRootPaths.contains(root.path) {
                        let decision = await MainActor.run {
                            presentUpdateRebaseOverMergeDialog(problematicRoots: [root])
                        }
                        guard decision != .cancel else {
                            await MainActor.run {
                                self.multiRootWorkspace.updateDiscoveryRunning = false
                                self.feedbackCenter.warning(
                                    "Update Project cancelled",
                                    detail: "No working tree changes were applied."
                                )
                            }
                            return
                        }
                        await MainActor.run {
                            self.multiRootWorkspace.updateDiscoveryRunning = false
                            self.doPull(
                                nil,
                                rebase: decision == .rebaseAnyway,
                                autoOpenUpdateInfo: true
                            )
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.multiRootWorkspace.updateDiscoveryRunning = false
                    self.doPull(nil, rebase: rebase, autoOpenUpdateInfo: true)
                }
                return
            }
            let submoduleRootPaths = Set(roots.filter(\.isSubmodule).map(\.path))
            let rootPaths = roots.map(\.path)
            await MainActor.run {
                self.multiRootWorkspace.updateDiscoveryRunning = false
                self.multiRootWorkspace.running = true
                self.multiRootWorkspace.updateRetryAvailable = true
                self.beginFeedbackOperation(
                    rebase ? "Update Project (rebase)" : "Update Project",
                    cancelHandle: cancel
                )
            }
            let preflight: UpdateProjectPreflight? = rebase
                ? try prepareMultiRootUpdate(
                    scanRoot: projectPath,
                    selectedRootPaths: nil,
                    tagMode: tagMode,
                    broker: broker,
                    cancel: cancel
                )
                : nil
            let decision: UpdateRebaseOverMergeDecision
            if rebase, let preflight, !preflight.problematicRootPaths.isEmpty {
                let problematicRoots = roots.filter {
                    preflight.problematicRootPaths.contains($0.path)
                }
                decision = await MainActor.run {
                    presentUpdateRebaseOverMergeDialog(problematicRoots: problematicRoots)
                }
            } else {
                decision = .rebaseAnyway
            }
            guard decision != .cancel else {
                await MainActor.run {
                    self.multiRootWorkspace.running = false
                    self.multiRootWorkspace.updateRetryAvailable = false
                    self.feedbackCenter.warning(
                        "Update Project cancelled",
                        detail: "No working tree changes were applied."
                    )
                }
                return
            }
            let rebaseRootPaths: [String]? = decision == .mergeInstead
                ? rootPaths.filter { !(preflight?.problematicRootPaths.contains($0) ?? false) }
                : nil
            await MainActor.run {
                self.multiRootWorkspace.updateRebaseRootPaths = rebaseRootPaths.map(Set.init)
            }
            let previousHeads = Self.headCommitIDs(for: rootPaths)
            let previousHeadBranches = Self.headBranchNames(for: rootPaths)
            let results = try runMultiRootUpdateSelectedWithMethodsAndOptions(
                scanRoot: projectPath,
                selectedRootPaths: nil,
                rebase: rebase,
                rebaseRootPaths: rebaseRootPaths,
                prefetchedRootPaths: preflight?.fetchedRootPaths,
                broker: broker,
                cancel: cancel,
                tagMode: tagMode,
                savePolicy: projectSavePolicy
            )
            let currentHeads = Self.headCommitIDs(for: rootPaths)
            let revisionRanges = Self.updateSessionRevisionRanges(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: results
            )
            let updatedFilesCount = Self.updateSessionUpdatedFilesCount(revisionRanges)
            let rollbackTargets = Self.updateSessionRollbackTargets(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: results,
                submoduleRootPaths: Array(submoduleRootPaths),
                previousHeadBranches: previousHeadBranches
            )
            let recoveryTargets = Self.updateRootRecoveryTargets(
                results: results,
                roots: roots.map {
                    UpdateRootRecoveryRoot(
                        path: $0.path,
                        displayName: $0.displayName,
                        isSubmodule: $0.isSubmodule,
                        headBranch: $0.headBranch
                    )
                }
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.multiRootWorkspace.updateDiscoveryRunning = false
                self.multiRootWorkspace.running = false
                for result in results {
                    if result.success || result.skipped {
                        self.stashRecovery.multiRootUpdateStashedRoots.remove(result.rootPath)
                    } else if result.message.localizedCaseInsensitiveContains("local changes remain in stash")
                                || result.message.localizedCaseInsensitiveContains("local changes remain in shelf")
                                || result.message.localizedCaseInsensitiveContains("local restore conflicted") {
                        self.stashRecovery.multiRootUpdateStashedRoots.insert(result.rootPath)
                    }
                }
                self.loadMultiRoots()
                let failed = results.filter { !$0.success }.count
                let cancelled = results.contains {
                    $0.message.localizedCaseInsensitiveContains("cancelled")
                }
                let hasEligibleRoot = Self.updateProjectHasEligibleRoot(results)
                let updateNotReady = Self.updateProjectIsNotReady(results)
                if !cancelled && updateNotReady {
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let details = Self.multiRootUpdateFailureDetails(
                        results,
                        submoduleRootPaths: submoduleRootPaths
                    )
                    var recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    recoveryActions.insert(
                        FeedbackAction(title: "Open Conflict Workbench") {
                            self.openMultiRootConflictResolver()
                        },
                        at: 0
                    )
                    self.feedbackCenter.error(
                        "Update Project unavailable",
                        detail: details.isEmpty
                            ? "Update Project cannot start because a Git root is not ready."
                            : "Update Project cannot start.\n" + details.joined(separator: "\n"),
                        nextStep: "Resolve the ongoing Git operation or unresolved conflicts, then retry Update Project.",
                        additionalActions: recoveryActions,
                        notificationID: self.multiRootUpdateErrorNotificationID(),
                        notificationGroup: .important
                    )
                    self.feedbackCenter.attachResultRows(
                        feedbackResultRows(from: results),
                        notificationID: self.multiRootUpdateErrorNotificationID()
                    )
                } else if failed == 0 && !cancelled && !hasEligibleRoot {
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let skippedDetails = Self.skippedUpdateRootDetails(results)
                    let detail = skippedDetails.isEmpty
                        ? "No Git root has a checked-out branch with a configured upstream."
                        : "No Git root can be updated.\n" + skippedDetails.joined(separator: "\n")
                    let recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    self.feedbackCenter.error(
                        "Update Project unavailable",
                        detail: detail,
                        nextStep: recoveryActions.isEmpty
                            ? "Check out a branch and configure its upstream, then retry Update Project."
                            : "Configure an upstream or check out a branch, then retry Update Project.",
                        additionalActions: recoveryActions,
                        notificationID: self.multiRootUpdateErrorNotificationID(),
                        notificationGroup: .important
                    )
                    self.feedbackCenter.attachResultRows(
                        feedbackResultRows(from: results),
                        notificationID: self.multiRootUpdateErrorNotificationID()
                    )
                } else if failed == 0 && !cancelled {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: revisionRanges
                    )
                    let recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    self.feedbackCenter.success(
                        rebase ? "Update Project completed (rebase)" : "Update Project completed",
                        detail: Self.multiRootUpdateSuccessDetail(
                            results,
                            updatedFilesCount: revisionRanges.isEmpty ? nil : updatedFilesCount
                        ),
                        additionalActions: (viewCommitsAction.map { [$0] } ?? []) + recoveryActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: false),
                        notificationGroup: .standard
                    )
                    self.autoOpenUpdateInfoIfEnabled(revisionRanges)
                } else {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    var details = Self.multiRootUpdateFailureDetails(
                        results,
                        submoduleRootPaths: submoduleRootPaths
                    )
                    if !revisionRanges.isEmpty {
                        details.insert(
                            Self.multiRootUpdateSuccessDetail(
                                results,
                                updatedFilesCount: updatedFilesCount
                            ),
                            at: 0
                        )
                    }
                    let retryPaths = results.filter { !$0.success }.map(\.rootPath)
                    var additionalActions = [FeedbackAction]()
                    if !retryPaths.isEmpty {
                        let retryRequest = makeMultiRootRetryRequest(
                            operation: .update,
                            rootPaths: retryPaths,
                            rebase: rebase,
                            rebaseRootPaths: self.multiRootWorkspace.updateRebaseRootPaths.map(Array.init)
                        )
                        additionalActions.append(
                            FeedbackAction(
                                title: "Retry Failed Update Roots",
                                semanticAction: retryRequest
                            ) {
                                self.handleVCSActionRequest(retryRequest)
                            }
                        )
                    }
                    if let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: revisionRanges
                    ) {
                        additionalActions.insert(viewCommitsAction, at: 0)
                    }
                    additionalActions.append(contentsOf: self.updateRootRecoveryActions(recoveryTargets))
                    if let rollbackAction = self.multiRootUpdateRollbackAction(
                        targets: rollbackTargets
                    ) {
                        additionalActions.append(rollbackAction)
                    }
                    self.feedbackCenter.warning(
                        rebase ? "Update Project partially completed (rebase)" : "Update Project partially completed",
                        detail: details.joined(separator: "\n"),
                        nextStep: "Resolve conflicted roots, then continue or abort their Git operation.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            NotificationCenter.default.post(
                                name: .arborOpenMultiRootConflictResolver,
                                object: nil
                            )
                        },
                        additionalActions: additionalActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: true),
                        notificationGroup: .standard
                    )
                    self.autoOpenUpdateInfoIfEnabled(revisionRanges)
                    self.presentMultiRootUpdateRestoreConflicts(results)
                    self.recoverMultiRootUpdateStashesAfterFailure(results)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.updateDiscoveryRunning = false
                self.multiRootWorkspace.running = false
                if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                self.feedbackCenter.error(
                    "Update Project failed",
                    detail: errorMessage(error),
                    nextStep: "检查各 Git root 的 upstream 和认证配置后重试。",
                    notificationID: self.multiRootUpdateErrorNotificationID()
                )
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
            }
        }
    }
}

/// Roll back every root that advanced during one compound Update Project run.
/// Targets are expected-HEAD guarded and ordered deepest-first so a detached
/// submodule is restored before its parent gitlink. A later user change or a
/// local edit that would be overwritten leaves only that target retryable.
func rollbackMultiRootUpdate(
    _ targets: [PersistedMultiRootUpdateRollbackTarget],
    completionTitle: String = "Update Project rollback completed",
    operationTitle: String = "Rollback Update Project",
    notificationID: String? = nil,
    rollbackKind: ArborVCSActionRequest.Kind = .rollbackMultiRootUpdate
) {
    guard !targets.isEmpty else { return }
    let stableNotificationID = notificationID ?? multiRootUpdateRollbackNotificationID()
    beginFeedbackOperation(
        operationTitle,
        notificationID: stableNotificationID
    )
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [PersistedMultiRootUpdateRollbackTarget] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard try rootRepo.operationState() == nil else {
                    throw NSError(
                        domain: "Arbor.MultiRootUpdateRollback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "A Git operation is still in progress."]
                    )
                }
                try rootRepo.restoreHeadIfExpectedWithIgnoredPathsAndBranch(
                    initialCommitId: target.initialHead,
                    expectedCommitId: target.expectedHead,
                    expectedHeadBranch: target.expectedHeadBranch,
                    ignoredPaths: target.ignoredPaths
                )
            } catch {
                failures.append("\(target.displayName): \(errorMessage(error))")
                remaining.append(target)
            }
        }
        let rollbackFailures = failures
        let rollbackRemaining = remaining
        await MainActor.run {
            self.loadMultiRoots()
            if rollbackFailures.isEmpty {
                self.feedbackCenter.success(
                    completionTitle,
                    detail: "Restored \(targets.count) updated root\(targets.count == 1 ? "" : "s").",
                    notificationID: stableNotificationID
                )
            } else {
                let retryRequest = self.multiRootUpdateRollbackRequest(
                    targets: rollbackRemaining,
                    kind: rollbackKind
                )
                self.feedbackCenter.warning(
                    "\(operationTitle) partially failed",
                    detail: rollbackFailures.joined(separator: "\n"),
                    nextStep: "Review the affected roots and retry the remaining rollback targets.",
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
            }
        }
    }
}

func normalizedMultiRootChangePaths(
    _ paths: [PersistedMultiRootChangePath]
) -> [PersistedMultiRootChangePath] {
    var seen = Set<String>()
    return paths
        .filter { !$0.rootPath.isEmpty && !$0.path.isEmpty }
        .filter { seen.insert("\($0.rootPath)\u{1f}\($0.path)").inserted }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.path < $1.path }
            return $0.rootPath < $1.rootPath
        }
}

/// 选择统一 resolver 中的 root，并只加载该 root 的 Repository/status。
func selectMultiRootResolverRoot(_ rootPath: String) {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: { $0.rootPath == rootPath }) else { return }
    operationRecovery.multiRootResolverActiveRootPath = rootPath
    operationRecovery.multiRootResolverActiveInitialPath = root.paths.first
    operationRecovery.multiRootResolverActiveKind = root.kind
    operationRecovery.multiRootResolverActiveRepo = nil
    operationRecovery.multiRootResolverActiveEntries = []
    operationRecovery.multiRootResolverWorking = true
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let entries = try rootRepo.status()
            await MainActor.run {
                guard self.operationRecovery.multiRootResolverActiveRootPath == rootPath else { return }
                self.operationRecovery.multiRootResolverActiveRepo = rootRepo
                self.operationRecovery.multiRootResolverActiveEntries = entries
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = nil
            }
        } catch {
            await MainActor.run {
                guard self.operationRecovery.multiRootResolverActiveRootPath == rootPath else { return }
                self.operationRecovery.multiRootResolverWorking = false
                self.operationRecovery.multiRootResolverError = "\(root.displayName): \(errorMessage(error))"
            }
        }
    }
}

func refreshMultiRootResolverActiveRoot() {
    guard let rootRepo = operationRecovery.multiRootResolverActiveRepo,
          let rootPath = operationRecovery.multiRootResolverActiveRootPath else { return }
    Task.detached(priority: .userInitiated) {
        let entries = (try? rootRepo.status()) ?? []
        await MainActor.run {
            guard self.operationRecovery.multiRootResolverActiveRootPath == rootPath,
                  self.operationRecovery.multiRootResolverActiveRepo === rootRepo else { return }
            self.operationRecovery.multiRootResolverActiveEntries = entries
        }
    }
}

func completeMultiRootResolverRoot() {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: {
        $0.rootPath == self.operationRecovery.multiRootResolverActiveRootPath
    }) else { return }
    switch root.kind {
    case .operation:
        runMultiRootResolverRecovery(rootPath: root.rootPath, action: .continueOperation)
    case .stash:
        completeMultiRootResolverStash(root)
    case .shelve(let name, _):
        completeMultiRootResolverShelf(root, name: name)
    case .workingTree:
        openMultiRootConflictResolver(preferredRootPath: root.rootPath)
    }
}

func skipMultiRootResolverRoot() {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: {
        $0.rootPath == self.operationRecovery.multiRootResolverActiveRootPath
    }), root.canSkip else { return }
    runMultiRootResolverRecovery(rootPath: root.rootPath, action: .skip)
}

func abortMultiRootResolverRoot() {
    guard let root = operationRecovery.multiRootResolverRoots.first(where: {
        $0.rootPath == self.operationRecovery.multiRootResolverActiveRootPath
    }) else { return }
    switch root.kind {
    case .operation:
        runMultiRootResolverRecovery(rootPath: root.rootPath, action: .abort)
    case .shelve(let name, _):
        abortMultiRootResolverShelf(root, name: name)
    case .stash, .workingTree:
        break
    }
}

func closeMultiRootResolver() {
    operationRecovery.multiRootResolverLoadGeneration += 1
    operationRecovery.showMultiRootConflictResolver = false
    operationRecovery.multiRootResolverWorking = false
    operationRecovery.multiRootResolverActiveRepo = nil
    operationRecovery.multiRootResolverActiveEntries = []
    operationRecovery.multiRootResolverActiveKind = nil
}

/// 统一 resolver 中的 Continue/Skip/Abort。完成一个 root 后立即重读整个
/// root 队列，因此 rebase 的下一暂停步骤和其它 root 都会留在同一窗口。
func runMultiRootResolverRecovery(
    rootPath: String,
    action: MultiRootRecoveryAction,
    stageTrackedBeforeContinue: Bool = false
) {
    guard !operationRecovery.multiRootResolverWorking else { return }
    let restoresUpdateLocalChanges = stashRecovery.multiRootUpdateStashedRoots.contains(rootPath)
    let batchRebaseSessionID = rebaseWorkspace.multiRootSession?.roots.contains(where: { $0.rootPath == rootPath }) == true
        ? rebaseWorkspace.multiRootSession?.id
        : nil
    let protectedPatterns = effectiveProtectedBranchPatterns
    operationRecovery.multiRootResolverWorking = true
    operationRecovery.multiRootResolverError = nil
    beginFeedbackOperation("Multi-root recovery")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard let state = try rootRepo.operationState() else {
                throw NSError(
                    domain: "Arbor.MultiRootRecovery",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "该 Git root 没有可恢复的进行中操作。"]
                )
            }
            let previousHead = rootRepo.headCommitId()
            let sourceBranch = state.kind == .merge && state.origin == .engine
                ? rootRepo.mergeSourceReference()
                : nil
            let messageMonitor = Task.detached(priority: .userInitiated) {
                while !Task.isCancelled {
                    if let pending = try? rootRepo.rebasePendingMessage() {
                        await MainActor.run {
                            guard !self.rebaseWorkspace.showRawMessageEditor else { return }
                            self.rebaseWorkspace.rawMessageRepository = rootRepo
                            self.rebaseWorkspace.rawMessageText = pending
                            self.rebaseWorkspace.showRawMessageEditor = true
                        }
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { messageMonitor.cancel() }
            switch action {
            case .continueOperation:
                switch state.kind {
                case .merge:
                    _ = try state.origin == .engine
                        ? rootRepo.finishMerge(message: nil)
                        : rootRepo.mergeContinue(message: nil)
                case .rebase:
                    if stageTrackedBeforeContinue {
                        try rootRepo.stageTracked()
                    }
                    _ = try rootRepo.rebaseContinue()
                case .cherryPick:
                    try rootRepo.cherryPickContinueWithOptions(
                        emptyPolicy: configuredCherryPickEmptyPolicy()
                    )
                case .revert:
                    try rootRepo.revertContinue()
                }
            case .skip:
                guard state.kind == .rebase else {
                    throw NSError(
                        domain: "Arbor.MultiRootRecovery",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "只有 rebase 支持 Skip。"]
                    )
                }
                _ = try rootRepo.rebaseSkip()
            case .abort:
                switch state.kind {
                case .merge: try rootRepo.mergeAbort()
                case .rebase: try rootRepo.rebaseAbort()
                case .cherryPick: try rootRepo.cherryPickAbort()
                case .revert: try rootRepo.revertAbort()
                }
            }

            let operationStillActive = try rootRepo.operationState() != nil
            let currentHead = rootRepo.headCommitId()
            var stashConflictPaths: [String]?
            var stashConflictIndex: Int?
            var stashConflictID: String?
            var stashRestoreFailure: String?
            var shelfRestoreConflict = false
            if restoresUpdateLocalChanges && !operationStillActive {
                let shelves = try rootRepo.shelveList()
                if let shelf = shelves.first(where: { isArborTemporaryShelfName($0.name) }) {
                    do {
                        try rootRepo.shelvePopPreservation(name: shelf.name)
                    } catch let error as EngineError {
                        if case .ShelveApplyConflict = error {
                            shelfRestoreConflict = true
                        } else {
                            stashRestoreFailure = errorMessage(error)
                        }
                    } catch {
                        stashRestoreFailure = errorMessage(error)
                    }
                } else {
                    let stashes = try rootRepo.stashList()
                    if let indexedStash = stashes.enumerated().first(where: {
                        isArborTemporaryStashMessage($0.element.message)
                    }) {
                    do {
                        try rootRepo.stashPopWithIndex(
                            index: try currentStashIndex(
                                repo: rootRepo,
                                stashID: indexedStash.element.id
                            ),
                            restoreIndex: true
                        )
                    } catch let error as EngineError {
                        if case let .StashApplyConflict(paths, conflictStashID) = error {
                            stashConflictPaths = paths
                            stashConflictIndex = indexedStash.offset
                            stashConflictID = conflictStashID ?? indexedStash.element.id
                        } else {
                            stashRestoreFailure = errorMessage(error)
                        }
                    } catch {
                        stashRestoreFailure = errorMessage(error)
                    }
                } else {
                    stashRestoreFailure = "The temporary Update Project stash could not be located."
                }
                }
            }

            let canProposeDelete = action == .continueOperation
                && !operationStillActive
                && stashConflictPaths == nil
                && !shelfRestoreConflict
                && stashRestoreFailure == nil
                && sourceBranch.map {
                    canProposeDeleteMergedBranch(
                        repo: rootRepo,
                        branch: $0,
                        protectedPatterns: protectedPatterns
                    )
                } ?? false

            let resolvedStashConflictPaths = stashConflictPaths
            let resolvedStashConflictIndex = stashConflictIndex
            let resolvedStashConflictID = stashConflictID
            let resolvedStashRestoreFailure = stashRestoreFailure
            let resolvedShelfRestoreConflict = shelfRestoreConflict
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                if (self.rebaseWorkspace.rawMessageRepository?.workdir() ?? "") == rootPath {
                    self.rebaseWorkspace.showRawMessageEditor = false
                    self.rebaseWorkspace.rawMessageRepository = nil
                    self.rebaseWorkspace.rawMessageText = ""
                }
                if let resolvedStashConflictPaths {
                    self.stashRecovery.multiRootConflicts[rootPath] = resolvedStashConflictPaths
                    self.stashRecovery.multiRootConflictIndexes[rootPath] = resolvedStashConflictIndex ?? 0
                    self.stashRecovery.multiRootConflictIDs[rootPath] = resolvedStashConflictID
                    self.stashRecovery.multiRootConflictPopModes[rootPath] = true
                } else if resolvedStashRestoreFailure == nil
                            && !resolvedShelfRestoreConflict
                            && restoresUpdateLocalChanges {
                    self.stashRecovery.multiRootUpdateStashedRoots.remove(rootPath)
                }
                if resolvedShelfRestoreConflict {
                    self.operationRecovery.multiRootResolverError = nil
                    self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                } else if let resolvedStashRestoreFailure {
                    self.operationRecovery.multiRootResolverError = "\(rootPath): \(resolvedStashRestoreFailure)"
                } else if state.kind == .rebase, let batchRebaseSessionID {
                    self.closeMultiRootResolver()
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rootPath,
                        action: action,
                        operationStillActive: operationStillActive,
                        sessionID: batchRebaseSessionID
                    )
                    if operationStillActive {
                        self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                    }
                } else {
                    self.operationRecovery.multiRootResolverError = nil
                    let mergeViewCommitsAction = state.kind == .merge
                        && action == .continueOperation
                        ? self.completedMergeViewCommitsAction(
                            rootPath: rootPath,
                            initialHead: previousHead,
                            finalHead: currentHead,
                            completed: !operationStillActive
                        )
                        : nil
                    if canProposeDelete, let sourceBranch {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: "\(sourceBranch) · \(rootPath)",
                            actionTitle: "Delete branch",
                            action: postMergeDeleteAction(
                                repo: rootRepo,
                                branch: sourceBranch,
                                rootPath: rootPath
                            ),
                            additionalActions: mergeViewCommitsAction.map { [$0] } ?? [],
                            notificationGroup: .standard
                        )
                    } else if let mergeViewCommitsAction {
                        self.feedbackCenter.success(
                            "Merge completed",
                            detail: rootPath,
                            additionalActions: [mergeViewCommitsAction],
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Git root recovery completed",
                            detail: "\(rootPath): \(multiRootRecoveryTitle(action))"
                        )
                    }
                }
                self.openMultiRootConflictResolver(preferredRootPath: rootPath)
            }
        } catch {
            let canStageAndRetry: Bool = {
                guard action == .continueOperation else { return false }
                guard batchRebaseSessionID != nil else { return false }
                guard let rootRepo = try? openRepository(path: rootPath) else { return false }
                return (try? rootRepo.status().contains {
                    $0.unstaged != .unchanged
                        && $0.unstaged != .untracked
                        && $0.unstaged != .ignored
                        && $0.unstaged != .conflicted
                }) ?? false
            }()
            await MainActor.run {
                self.operationRecovery.multiRootResolverWorking = false
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.presentMultiRootMergeRestoreConflict(
                        rootPath: rootPath,
                        paths: paths,
                        stashID: stashID
                    )
                    return
                }
                if case .ShelveApplyConflict = error as? EngineError {
                    self.presentMultiRootMergeRestoreConflict(rootPath: rootPath, paths: [])
                    return
                }
                self.operationRecovery.multiRootResolverError = "\(rootPath): \(errorMessage(error))"
                let stageAndRetryAction = canStageAndRetry
                    ? batchRebaseSessionID.map {
                        self.multiRootRebaseRecoveryFeedbackAction(
                            .stageAndRetry,
                            rootPath: rootPath,
                            sessionID: $0
                        )
                    }
                    : nil
                self.feedbackCenter.error(
                    "Multi-root recovery failed",
                    detail: self.operationRecovery.multiRootResolverError,
                    nextStep: "Resolve the remaining conflicts in that root, then retry Continue, Skip, or Abort.",
                    additionalActions: stageAndRetryAction.map { [$0] } ?? [],
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.refreshMultiRootResolverActiveRoot()
            }
        }
    }
}

func executeMultiRootRecovery(
    rootPath: String,
    action: MultiRootRecoveryAction
) {
    runMultiRootResolverRecovery(rootPath: rootPath, action: action)
}

func multiRootRecoveryTitle(_ action: MultiRootRecoveryAction) -> String {
    switch action {
    case .continueOperation: return "Continue"
    case .skip: return "Skip"
    case .abort: return "Abort"
    }
}

func loadRepoData(includeComparisons: Bool = true) {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let bs = try repo.branchList()
            let ignoredRules = (try? repo.ignoredRules()) ?? []
            let comparisons = includeComparisons ? branchComparisonMap(repo: repo) : nil
            let ss = try repo.stashList()
            let sh = try repo.shelveList()
            let dsh = (try? repo.shelveDeletedList()) ?? []
            let rs = try repo.remoteList()
            let isShallow = repo.isShallow()
            let remoteBranches = (try? repo.remoteBranchList()) ?? []
            let recentBranches = (try? repo.recentBranches(limit: 10)) ?? []
            let syncStatuses = (try? repo.syncStatus()) ?? []
            let ts = try repo.tagList()
            let submodules = (try? repo.submoduleList()) ?? []
            let identity = (try? repo.gitIdentity()) ?? GitIdentity(name: nil, email: nil, signingKey: nil, signingFormat: nil, signCommits: false)
            await MainActor.run {
                guard self.projectWorkspace.repository === repo else { return }
                self.branchWorkspace.branches = bs; self.repositoryStatus.ignoredRules = ignoredRules
                self.refreshLogMyBranches()
                if let comparisons { self.branchWorkspace.comparisons = comparisons }
                self.stashUI.stashes = ss; self.remoteWorkspace.remotes = rs
                self.repositoryStatus.isShallowRepository = isShallow
                self.restoreRemoteProtectedBranchPatterns(for: rs, projectPath: self.projectWorkspace.path)
                self.branchWorkspace.remoteBranches = remoteBranches
                self.branchWorkspace.recentBranches = recentBranches; self.branchWorkspace.syncStatuses = syncStatuses
                self.shelfWorkspace.shelves = sh; self.shelfWorkspace.deletedShelves = dsh; self.tagWorkspace.tags = ts
                self.refreshLfsPathMarkers()
                self.submoduleWorkspace.submodules = submodules
                self.gitSettings.identityName = identity.name ?? ""
                self.gitSettings.identityEmail = identity.email ?? ""
                self.gitSettings.identitySetNameEmailGlobally = GitIdentityScopeSettings.setNameEmailGlobally(
                    for: self.projectWorkspace.path
                )
                self.gitSettings.identitySigningKey = identity.signingKey ?? ""
                self.gitSettings.identitySigningFormat = identity.signingFormat ?? "gpg"
                self.gitSettings.identitySignCommits = identity.signCommits
                self.refreshCherryPickedHighlights()
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
}

struct BranchMergeScanResult {
    let index: Int
    let root: BranchCleanupRoot
    let repositoryScanned: Bool
    let candidateBranchesChecked: Int
    let mergedBranchesFound: Int
    let error: String?
}

nonisolated func scanBranchMergeRoot(
    _ root: BranchCleanupRoot,
    index: Int,
    target: String,
    prefix: String
) -> BranchMergeScanResult {
    let candidates = root.branches.filter {
        $0.name != target && (prefix.isEmpty || $0.name.hasPrefix(prefix))
    }
    guard root.branches.contains(where: { $0.name == target }) else {
        let error = "target branch '\(target)' was not found"
        return BranchMergeScanResult(
            index: index,
            root: BranchCleanupRoot(
                rootPath: root.rootPath,
                displayName: root.displayName,
                relativePath: root.relativePath,
                branches: root.branches,
                trackingByBranch: root.trackingByBranch,
                mergedBranches: [],
                calculatedTarget: nil,
                calculatedPrefix: nil,
                calculationError: error
            ),
            repositoryScanned: false,
            candidateBranchesChecked: 0,
            mergedBranchesFound: 0,
            error: error
        )
    }

    do {
        let rootRepo = try openRepository(path: root.rootPath)
        let merged = try rootRepo.branchListMergedInto(target: target, prefix: prefix)
        // The engine and the UI both exclude the comparison branch. Keeping
        // this boundary here also protects older engine builds that returned
        // the target itself for an empty prefix.
        let mergedNames = Set(merged.map(\.name).filter { $0 != target })
        return BranchMergeScanResult(
            index: index,
            root: BranchCleanupRoot(
                rootPath: root.rootPath,
                displayName: root.displayName,
                relativePath: root.relativePath,
                branches: root.branches,
                trackingByBranch: root.trackingByBranch,
                mergedBranches: mergedNames,
                calculatedTarget: target,
                calculatedPrefix: prefix,
                calculationError: nil
            ),
            repositoryScanned: true,
            candidateBranchesChecked: candidates.count,
            mergedBranchesFound: mergedNames.count,
            error: nil
        )
    } catch {
        let error = errorMessage(error)
        return BranchMergeScanResult(
            index: index,
            root: BranchCleanupRoot(
                rootPath: root.rootPath,
                displayName: root.displayName,
                relativePath: root.relativePath,
                branches: root.branches,
                trackingByBranch: root.trackingByBranch,
                mergedBranches: [],
                calculatedTarget: nil,
                calculatedPrefix: nil,
                calculationError: error
            ),
            repositoryScanned: true,
            candidateBranchesChecked: candidates.count,
            mergedBranchesFound: 0,
            error: error
        )
    }
}

/// Scan roots concurrently in small batches. IntelliJ bounds its comparison
/// pool to five workers; batching gives the same upper bound while retaining
/// deterministic ordering and a cancellation boundary between batches.
nonisolated func scanBranchMergeRoots(
    _ roots: [BranchCleanupRoot],
    target: String,
    prefix: String
) async -> [BranchMergeScanResult] {
    let batchSize = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 5))
    var results: [BranchMergeScanResult] = []

    for start in stride(from: 0, to: roots.count, by: batchSize) {
        if Task.isCancelled { break }
        let end = min(start + batchSize, roots.count)
        let batch = Array(roots[start..<end])
        let batchResults = await withTaskGroup(of: BranchMergeScanResult?.self) { group in
            for (offset, root) in batch.enumerated() {
                let index = start + offset
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return scanBranchMergeRoot(root, index: index, target: target, prefix: prefix)
                }
            }

            var collected: [BranchMergeScanResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }
        results.append(contentsOf: batchResults)
    }

    return results.sorted { $0.index < $1.index }
}

nonisolated func dirtyPathsForSmartDecision(_ repo: Repository) throws -> [String] {
    try repo.status()
        .filter {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
        .map(\.path)
}

func validateSingleRootRenameName(rootPath: String, oldName: String, value: String) -> String? {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return nil }
    guard let snapshot = multiRootWorkspace.branchSnapshots.first(where: { $0.rootPath == rootPath }) else {
        return "The selected Git root is no longer available."
    }
    if let conflict = branchRenameConflictMessage(
        oldName: oldName,
        newName: candidate,
        localBranchNames: snapshot.branches.map(\.name),
        remoteBranchNames: snapshot.remoteBranches.map(\.name)
    ) {
        return conflict
    }
    guard let rootRepo = try? openRepository(path: rootPath) else {
        return "The selected Git root could not be opened."
    }
    do {
        try rootRepo.validateBranchName(name: candidate)
        return nil
    } catch {
        return errorMessage(error)
    }
}

/// Capture the saved-artifact identity before a multi-root preserving
/// operation. The engine intentionally keeps the artifact on disk when a
/// restore conflicts; comparing object/name sets lets the notification point
/// at that exact root-scoped artifact without relying on stash index 0.
nonisolated static func savedChangeIDsByRoot(
    rootPaths: [String]
) -> (stashes: [String: Set<String>], shelves: [String: Set<String>]) {
    var stashes: [String: Set<String>] = [:]
    var shelves: [String: Set<String>] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
        if let entries = try? rootRepo.stashList() {
            stashes[rootPath] = Set(entries.map(\.id))
        }
        if let entries = try? rootRepo.shelveList() {
            shelves[rootPath] = Set(entries.map(\.name))
        }
    }
    return (stashes, shelves)
}

nonisolated static func newSavedChangeIDsByRoot(
    rootPaths: [String],
    before: (stashes: [String: Set<String>], shelves: [String: Set<String>]),
    stashMessagePrefix: String,
    shelfNamePrefix: String
) -> (stashes: [String: String], shelves: [String: String]) {
    var stashes: [String: String] = [:]
    var shelves: [String: String] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
        if let beforeStashes = before.stashes[rootPath],
           let entries = try? rootRepo.stashList(),
           let stash = entries.first(where: {
               !beforeStashes.contains($0.id) && $0.message.hasPrefix(stashMessagePrefix)
           }) {
            stashes[rootPath] = stash.id
        }
        if let beforeShelves = before.shelves[rootPath],
           let entries = try? rootRepo.shelveList(),
           let shelf = entries.first(where: {
               !beforeShelves.contains($0.name) && $0.name.hasPrefix(shelfNamePrefix)
           }) {
            shelves[rootPath] = shelf.name
        }
    }
    return (stashes, shelves)
}

/// Capture the native todo for one repository in the multi-root editor. The
/// branch is explicit because the batch may target a branch that is not the
/// currently checked-out branch in that root.
func prepareMultiRootRawTodoEditor(_ draft: MultiRootRebaseTodoDraft) {
    guard draft.loadError == nil else { return }
    let onto = rebaseWorkspace.onto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseWorkspace.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let preserveMerges = rebaseWorkspace.preserveMerges
    let autoSquash = rebaseWorkspace.autoSquash
    let keepEmpty = rebaseWorkspace.keepEmpty
    let updateRefs = rebaseWorkspace.updateRefs
    let rootMode = rebaseWorkspace.root
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    if let rawTodo = draft.rawTodo {
        rebaseWorkspace.multiRootRawTodoText = rawTodo
        rebaseWorkspace.multiRootRawTodoContext = MultiRootRawTodoContext(
            rootPath: draft.rootPath,
            displayName: draft.displayName,
            onto: onto,
            preserveMerges: preserveMerges,
            root: rootMode
        )
        return
    }

    let cancel = GitCancelHandle()
    beginFeedbackOperation(
        "Prepare Native Todo · \(draft.displayName)",
        cancelHandle: cancel
    )
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: draft.rootPath)
            let rawTodo = try rootRepo.rebaseRawTodoForBranchWithOptionsAndPolicyAndCancel(
                onto: onto,
                branch: branch,
                preserveMerges: preserveMerges,
                autoSquash: autoSquash,
                keepEmpty: keepEmpty,
                updateRefs: updateRefs,
                root: rootMode,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.rebaseWorkspace.multiRootRawTodoText = rawTodo
                self.rebaseWorkspace.multiRootRawTodoContext = MultiRootRawTodoContext(
                    rootPath: draft.rootPath,
                    displayName: draft.displayName,
                    onto: onto,
                    preserveMerges: preserveMerges,
                    root: rootMode
                )
                self.feedbackCenter.success(
                    "Native todo ready",
                    detail: draft.displayName + " · control rows remain editable"
                )
            }
        } catch {
            await MainActor.run {
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Native todo preparation cancelled",
                        detail: draft.displayName,
                        nextStep: "The local scene was restored; reopen the native todo editor to retry."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Prepare native todo failed",
                        detail: draft.displayName + ": " + errorMessage(error),
                        nextStep: "The root must be free of another Git operation; retry after refreshing."
                    )
                }
            }
        }
    }
}

/// Store the text edited for one root without starting the batch yet. Other
/// roots remain structured or raw independently in the same editor.
func finishMultiRootRawTodoEditor(_ context: MultiRootRawTodoContext) {
    let rawTodo = rebaseWorkspace.multiRootRawTodoText
    guard !rawTodo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let index = rebaseWorkspace.multiRootDrafts.firstIndex(where: { $0.rootPath == context.rootPath }) else {
        return
    }
    rebaseWorkspace.multiRootDrafts[index].rawTodo = rawTodo
    rebaseWorkspace.multiRootRawTodoContext = nil
    rebaseWorkspace.multiRootRawTodoText = ""
}

}
