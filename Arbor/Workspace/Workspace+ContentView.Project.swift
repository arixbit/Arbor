import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Register the persisted project Git executable for the roots currently
/// known by this window. The Rust engine resolves the longest matching root
/// for every system-Git command, while the application-level executable stays
/// the fallback for projects without an override.
func applyProjectGitExecutableOverride(for projectPath: String, roots: [String]) {
    guard let override = GitExecutableSettings.projectOverride(for: projectPath) else {
        clearProjectGitExecutable(projectPath: projectPath)
        return
    }
    let registeredRoots = GitExecutableSettings.registeredRoots(
        projectPath: projectPath,
        repositoryRoot: nil,
        discoveredRoots: roots
    )
    do {
        _ = try setProjectGitExecutable(
            projectPath: projectPath,
            rootPaths: registeredRoots,
            path: override
        )
    } catch {
        DiagnosticsLogger.shared.record(
            operation: "settings",
            repositoryPath: projectPath,
            code: "project-git-executable-invalid"
        )
    }
}

}


extension ContentView {
func handleContentViewAppearAndLoadRoots() {
    logRuntime.externalSessionDisposed = false
    // Root discovery starts after the primary status snapshot is visible so
    // startup work cannot compete with the first usable Changes rows.
    handleContentViewAppear()
    credentialAuth.ensureInstalled()
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

}
