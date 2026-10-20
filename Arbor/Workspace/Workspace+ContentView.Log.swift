import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Log ref actions must retain the selected commit's Git root. Resolving a
/// missing path through `repo` would make an aggregate Log mutate the window's
/// primary repository, so this action path fails closed instead.
func performLogReferenceAction(
    _ commit: CommitInfo,
    target: LogReferenceActionTarget,
    action: LogReferenceAction
) {
    guard let rootPath = logReferenceRootPath(for: commit) else {
        feedbackCenter.warning(
            "Reference action unavailable",
            detail: "The selected commit has no Git root.",
            nextStep: "Refresh Git Roots, then retry from the commit history."
        )
        return
    }

    switch action {
    case .checkout:
        checkoutBranchInRoot(
            rootPath: rootPath,
            reference: target.name,
            isRemote: target.kind == .remote
        )
    case .checkoutAndUpdate:
        executeMultiRootCheckoutAndUpdate(
            reference: target.name,
            rootPath: rootPath,
            detach: false,
            rebase: false
        )
    case .checkoutWithRebase:
        executeMultiRootCheckoutAndUpdate(
            reference: target.name,
            rootPath: rootPath,
            detach: false,
            rebase: true
        )
    case .compare:
        compareBranchInRoot(rootPath: rootPath, branch: target.name)
    case .showDiff:
        showBranchDiffWithWorkingTree(rootPath: rootPath, branch: target.name)
    case .rebase:
        rebaseCurrentInRoot(rootPath: rootPath, onto: target.name)
    case .merge:
        mergeBranchInRoot(rootPath: rootPath, branch: target.name)
    case .update:
        updateBranchInRoot(rootPath: rootPath, branch: target.name)
    case .push:
        beginMultiRootPushDialog(rootPath: rootPath, branch: target.name)
    case .pullMerge:
        pullBranchInRoot(rootPath: rootPath, branch: target.name, rebase: false)
    case .pullRebase:
        pullBranchInRoot(rootPath: rootPath, branch: target.name, rebase: true)
    case .rename:
        renameBranchInRoot(rootPath: rootPath, oldName: target.name)
    case .delete:
        switch target.kind {
        case .local:
            deleteBranchInRoot(rootPath: rootPath, name: target.name)
        case .remote:
            deleteRemoteBranchInRoot(rootPath: rootPath, branch: target.name)
        case .tag:
            deleteTagInRoot(rootPath: rootPath, name: target.name)
        }
    }
}

func externalLogTabIsAlive(_ tabID: UUID) -> Bool {
    guard externalLogWindow else { return true }
    guard !externalLogSessionDisposed else { return false }
    return externalLogUIManager?.isUIAlive(tabID) == true
}

func persistExternalLogTabs() {
    guard externalLogWindow, let persistenceKey = externalLogTabsPersistenceKey else { return }

    let snapshot = currentLogTabSnapshot()
    var tabs = logSelectionState.tabs
    if let index = tabs.firstIndex(where: { $0.id == snapshot.id }) {
        tabs[index] = snapshot
    } else {
        tabs.insert(snapshot, at: 0)
    }
    ExternalLogTabsStore.save(
        ExternalLogTabsState(tabs: tabs, activeTabID: snapshot.id),
        key: persistenceKey
    )
}

/// Mirrors IntelliJ's external VCS Log provider disposal. The external Log
/// window owns its root-scoped query/repository state; closing it must cancel
/// pending loads and release those repositories instead of leaving a watcher
/// or stale result alive after the window is gone.
func disposeExternalLogSession() {
    guard externalLogWindow, !externalLogSessionDisposed else { return }
    persistExternalLogTabs()
    externalLogSessionDisposed = true
    if let externalLogUIManager {
        externalLogUIManager.dispose()
    } else {
        externalLogProviderSession?.dispose()
    }
    logList.refreshTask?.cancel()
    logList.refreshTask = nil
    logList.loadTask?.cancel()
    logList.loadTask = nil
    logRuntime.signatureLoadTask?.cancel()
    logRuntime.signatureLoadTask = nil
    logRuntime.commandTask?.cancel()
    logRuntime.commandTask = nil
    logSelectionState.detailLoadTask?.cancel()
    logSelectionState.detailLoadTask = nil
    reflog.detailLoadTask?.cancel()
    reflog.detailLoadTask = nil
    reflog.loadTask?.cancel()
    reflog.loadTask = nil
    reflog.loadMoreTask?.cancel()
    reflog.loadMoreTask = nil
    compareLoadTask?.cancel()
    compareLoadTask = nil
    cancelBranchComparisonTasks()
    logBranchesPanel.showMyTask?.cancel()
    logBranchesPanel.showMyTask = nil
    repositoryChangeDeliveryTask?.cancel()
    repositoryChangeDeliveryTask = nil
    repositoryChangeBatch.removeAll()
    repositoryExternalVCSActionManager.removeAll()
    repositoryDirtyScopeManager.removeAll()
    repositoryDirtyFileManager.removeAll()
    multiRootLoadTask?.cancel()
    multiRootLoadTask = nil
    multiRootLoadGeneration &+= 1
    multiRootLoadNeedsRefresh = false
    multiRootLoadCompletion = nil
    logList.generation &+= 1
    logRuntime.signatureGeneration &+= 1
    logRuntime.commandGeneration &+= 1
    reflog.generation &+= 1
    logRuntime.aggregateRepositories.removeAll()
    logList.activeRepo = nil
    reflog.rootRepo = nil
    activeCompareRepo = nil
    projectRepo = nil
    multiRoots = []
    multiRootBranchSnapshots = []
    multiRootConflictGroups = []
}

var currentLogTabID: UUID {
    logSelectionState.activeTabID ?? logSelectionState.tabs.first?.id ?? UUID()
}

/// IntelliJ's branch filter accepts multiple heads. Keep the legacy singular
/// field as a compatibility bridge for old in-memory tabs and revision-entry
/// actions, while using the set as the source of truth for the graph query.
var activeLogStartRevisions: [String] {
    let selected = logList.startRevisions
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .sorted()
    if !selected.isEmpty {
        return selected
    }
    let legacy = logList.startRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    return legacy.isEmpty ? [] : [legacy]
}

func setLogStartRevisions(_ revisions: [String]) {
    let normalized = revisions
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    logList.startRevisions = Set(normalized)
    logList.startRevision = normalized.count == 1 ? normalized[0] : ""
}

func setLogStartRevision(_ revision: String) {
    setLogStartRevisions(revision.isEmpty ? [] : [revision])
}

func setLogStartRevisionSelected(_ revision: String, selected: Bool) {
    var revisions = logList.startRevisions
    if selected {
        revisions.insert(revision)
    } else {
        revisions.remove(revision)
    }
    setLogStartRevisions(Array(revisions))
}

/// Opens IntelliJ's update-session "View Commits" target. Each distinct range
/// gets a dedicated Update Info Log tab so the user's ordinary Log stays
/// intact; every result keeps its owning repository identity.
func showLogRevisionRanges(_ persistedRanges: [PersistedLogRevisionRange]) {
    guard let projectPath else { return }
    let projectRoot = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    var seen = Set<LogRootRevisionRange>()
    let ranges = persistedRanges.compactMap { persisted -> LogRootRevisionRange? in
        let rootPath = URL(fileURLWithPath: persisted.rootPath).standardizedFileURL.path
        let oldRevision = persisted.oldRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRevision = persisted.newRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldRevision.isEmpty,
              !newRevision.isEmpty,
              oldRevision != newRevision,
              rootPath == projectRoot || rootPath.hasPrefix(projectRoot + "/") else {
            return nil
        }
        let range = LogRootRevisionRange(
            rootPath: rootPath,
            oldRevision: oldRevision,
            newRevision: newRevision
        )
        return seen.insert(range).inserted ? range : nil
    }
    guard !ranges.isEmpty else { return }

    var repositories: [String: Repository] = [:]
    for rootPath in Set(ranges.map(\.rootPath)) {
        if let rootRepo = try? openRepository(path: rootPath) {
            repositories[rootPath] = rootRepo
        }
    }
    guard repositories.count == Set(ranges.map(\.rootPath)).count else {
        feedbackCenter.error(
            "View Commits unavailable",
            detail: "One or more Git roots from the update session could not be opened.",
            nextStep: "Refresh Git Roots, then retry the notification action."
        )
        return
    }

    let persistedRanges = ranges.map(\.persisted).sorted {
        if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
        if $0.oldRevision != $1.oldRevision { return $0.oldRevision < $1.oldRevision }
        return $0.newRevision < $1.newRevision
    }
    saveCurrentLogTab()
    if let existing = logSelectionState.tabs.first(where: { $0.updateInfoRanges == persistedRanges }) {
        logSelectionState.activeTabID = existing.id
        applyLogTab(existing)
        persistExternalLogTabs()
        toolWindowMode = .log
        toolWindowExpanded = true
        loadActiveLogTab(existing)
        return
    }

    let tab = makeUpdateInfoLogTab(
        ranges: persistedRanges,
        title: "Update Info · \(dateStr(Int64(Date().timeIntervalSince1970)))"
    )
    let updateInfoSelections = GitUpdateInfoPathFilterSettings.selections(for: projectPath)
    var filteredTab = tab
    filteredTab.pathSelections = updateInfoSelections
    filteredTab.pathFilter = logPathFilterEditorText(updateInfoSelections)
    appendLogTabAndLoad(filteredTab)
    toolWindowMode = .log
    toolWindowExpanded = true
}

/// Search Everywhere selects a revision without changing the user's branch
/// filter. Wait for the first Log page so a selected historical commit can be
/// inserted into the visible graph by `selectLogRevision` when it is outside
/// the initial page.
func navigateLogToRevision(rootPath: String, revision: String) {
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.error(
            "Log navigation failed",
            detail: "Unable to open Git root: \(rootPath)",
            nextStep: "Refresh Git roots and retry."
        )
        return
    }
    logList.activeRootPath = rootPath
    logList.activeRepo = rootRepo
    logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
    logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
    logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
    setLogStartRevisions([])
    logSelectionState.selection = nil
    logSelectionState.selectedIDs = []
    logList.viewMode = .graph
    loadLog()
    Task { @MainActor in
        while logList.isLoading {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled else { return }
        selectLogRevision(revision)
    }
}

func logStartRevisionBinding(for revision: String) -> Binding<Bool> {
    Binding(
        get: { self.logList.startRevisions.contains(revision) },
        set: { self.setLogStartRevisionSelected(revision, selected: $0) }
    )
}

func currentLogTabSnapshot() -> LogTabDescriptor {
    let existingTab = logSelectionState.tabs.first(where: { $0.id == currentLogTabID })
    return LogTabDescriptor(
        id: currentLogTabID,
        title: logSelectionState.tabs.first(where: { $0.id == currentLogTabID })?.title ?? "Log",
        rootPath: (logList.activeRootPath ?? existingTab?.rootPath).map(canonicalExternalLogPath),
        historyPath: existingTab?.historyPath,
        updateInfoRanges: existingTab?.updateInfoRanges,
        aggregateBranchFilters: logRuntime.aggregateBranchFilters,
        aggregateRevisionRanges: logRuntime.aggregateRevisionRanges.map(\.persisted),
        aggregateRootPaths: logRuntime.aggregateRootPaths.sorted(),
        viewMode: logList.viewMode,
        startRevision: logList.startRevision,
        startRevisions: activeLogStartRevisions,
        pathFilter: logList.pathFilter,
        pathSelections: activeLogPathFilterSelections(),
        visibleRootPathsRaw: logList.visibleRootPathsRaw,
        authorFilter: logList.authorFilter,
        messageFilter: logList.messageFilter,
        messageRegex: logList.messageRegex,
        messageMatchCase: logList.messageMatchCase,
        sinceText: logList.since,
        untilText: logList.until,
        commandFilter: logRuntime.commandFilter,
        follow: logList.follow,
        graphSortModeRaw: logRuntime.sortModeRaw,
        compareRevision1: compareRev1,
        compareRevision2: compareRev2,
        compareRepositoryPath: compareRepositoryPath,
        compareWithWorkingTree: compareWithWorkingTree,
        compareFirstFilter: logList.viewMode == .compareBranches
            ? branchComparison.firstFilter
            : nil,
        compareSecondFilter: logList.viewMode == .compareBranches
            ? branchComparison.secondFilter
            : nil,
        selection: logSelectionState.selection,
        selectedIDs: logSelectionState.selectedIDs,
        reflogRootPath: reflog.rootPath.map(canonicalExternalLogPath),
        reflogSelection: reflog.selection,
        reflogSelectedIDs: persistedReflogSelectionIDs(
            entries: reflog.entries,
            selectedIDs: reflog.selectedIDs
        )
    )
}

func saveCurrentLogTab() {
    let snapshot = currentLogTabSnapshot()
    if let index = logSelectionState.tabs.firstIndex(where: { $0.id == snapshot.id }) {
        logSelectionState.tabs[index] = snapshot
    } else {
        logSelectionState.tabs.insert(snapshot, at: 0)
    }
    logSelectionState.activeTabID = snapshot.id
    if externalLogWindow {
        persistExternalLogTabs()
    }
}

func clearLogActiveRootContext() {
    logList.activeRootPath = nil
    logList.activeRepo = nil
    logRuntime.activeBranches = []
    logRuntime.activeRemoteBranches = []
    logRuntime.activeRemotes = []
}

func loadActiveLogTab(_ tab: LogTabDescriptor) {
    if tab.viewMode == .command {
        runLogCommand()
    } else if tab.viewMode == .compare {
        DispatchQueue.main.async { self.loadTreeChanges() }
    } else if tab.viewMode == .compareBranches {
        DispatchQueue.main.async { self.loadBranchComparison() }
    } else if tab.viewMode == .reflog {
        prepareReflogRoot()
    } else {
        loadLog()
    }
}

func appendLogTabAndLoad(_ tab: LogTabDescriptor) {
    if let externalLogUIManager,
       !externalLogUIManager.registerUI(tab.id) {
        return
    }
    logSelectionState.tabs.append(tab)
    logSelectionState.activeTabID = tab.id
    applyLogTab(tab)
    persistExternalLogTabs()
    loadActiveLogTab(tab)
}

func openAnotherLogTab() {
    saveCurrentLogTab()
    var tab = currentLogTabSnapshot()
    tab.id = UUID()
    tab.title = "Log \(logSelectionState.tabs.count + 1)"
    appendLogTabAndLoad(tab)
}

func switchLogTab(_ id: UUID) {
    guard id != currentLogTabID,
          let tab = logSelectionState.tabs.first(where: { $0.id == id }) else { return }
    let previousMode = logList.viewMode
    saveCurrentLogTab()
    logSelectionState.activeTabID = id
    applyLogTab(tab)
    persistExternalLogTabs()
    if tab.viewMode == previousMode,
       tab.viewMode == .graph || tab.viewMode == .reflog {
        loadLog()
    } else if tab.viewMode == .compare {
        DispatchQueue.main.async { self.loadTreeChanges() }
    } else if tab.viewMode == .compareBranches {
        DispatchQueue.main.async { self.loadBranchComparison() }
    } else if tab.viewMode == .command {
        runLogCommand()
    }
}

func closeLogTab(_ id: UUID) {
    guard logSelectionState.tabs.count > 1,
          let index = logSelectionState.tabs.firstIndex(where: { $0.id == id }) else { return }
    let closingActive = id == currentLogTabID
    if closingActive { saveCurrentLogTab() }
    externalLogUIManager?.disposeUI(id)
    logSelectionState.tabs.remove(at: index)
    if !closingActive {
        persistExternalLogTabs()
        return
    }
    let previousMode = logList.viewMode
    let replacementIndex = min(index, logSelectionState.tabs.count - 1)
    let replacement = logSelectionState.tabs[replacementIndex]
    logSelectionState.activeTabID = replacement.id
    applyLogTab(replacement)
    persistExternalLogTabs()
    if replacement.viewMode == previousMode,
       replacement.viewMode == .graph || replacement.viewMode == .reflog {
        reloadLogView()
    } else if replacement.viewMode == .compare {
        DispatchQueue.main.async { self.loadTreeChanges() }
    } else if replacement.viewMode == .compareBranches {
        DispatchQueue.main.async { self.loadBranchComparison() }
    } else if replacement.viewMode == .command {
        runLogCommand()
    }
}

func runLogCommand(reset: Bool = true) {
    logRuntime.commandTask?.cancel()
    logRuntime.commandGeneration += 1
    let generation = logRuntime.commandGeneration
    let tabID = currentLogTabID
    let arguments = tokenizeGitCommandLine(logRuntime.commandFilter)
    let pageLimit = 500
    let previousEntryCount = reset ? 0 : logRuntime.commandEntries.count
    let commandHasExplicitLimit = gitLogCommandHasExplicitLimit(arguments)
    let explicitCommandMaximum = gitLogCommandMaximum(arguments)
    let commandLimit = max(
        pageLimit,
        previousEntryCount + pageLimit,
        reset ? (explicitCommandMaximum ?? 0) : 0
    )
    let aggregateFilterRoots = normalizedLogRootPaths(
        logRuntime.aggregateBranchFilters.map(\.rootPath)
            + logRuntime.aggregateRevisionRanges.map(\.rootPath)
            + Array(logRuntime.aggregateRootPaths)
    )
    let discoveredRootPaths = normalizedLogRootPaths(multiRoots.map(\.path))
    let hasStoredAggregateLog = !logRuntime.aggregateBranchFilters.isEmpty
        || !logRuntime.aggregateRevisionRanges.isEmpty
        || !logRuntime.aggregateRootPaths.isEmpty
    let commandIsAggregate = hasStoredAggregateLog || discoveredRootPaths.count > 1
    let commandRootPaths: [String]
    if commandIsAggregate {
        let candidateRoots = aggregateFilterRoots.isEmpty
            ? discoveredRootPaths
            : aggregateFilterRoots
        commandRootPaths = reconciledLogVisibleRootPaths(
            allRoots: candidateRoots,
            raw: logVisibleRootFilterRaw(for: candidateRoots)
        ).sorted()
    } else if let commandRepository = logRepository ?? logList.activeRepo ?? repo,
              let rootPath = commandRepository.workdir() {
        commandRootPaths = [canonicalExternalLogPath(rootPath)]
    } else {
        commandRootPaths = []
    }
    let requestedAggregateFilters = logRuntime.aggregateBranchFilters
    let requestedAggregateRanges = logRuntime.aggregateRevisionRanges
    let requestedAggregateRootPaths = logRuntime.aggregateRootPaths
    let requestedVisibleRootPathsRaw = logList.visibleRootPathsRaw
    let requestedDiscoveredRootPaths = discoveredRootPaths
    var commandRepositories: [(String, Repository)] = []
    for rootPath in commandRootPaths {
        if let cached = logRuntime.aggregateRepositories[rootPath] {
            commandRepositories.append((rootPath, cached))
            continue
        }
        if let active = logList.activeRepo,
           let activePath = active.workdir(),
           canonicalExternalLogPath(activePath) == rootPath {
            commandRepositories.append((rootPath, active))
            continue
        }
        if let current = repo,
           let currentPath = current.workdir(),
           canonicalExternalLogPath(currentPath) == rootPath {
            commandRepositories.append((rootPath, current))
            continue
        }
        if let opened = try? openRepository(path: rootPath) {
            commandRepositories.append((rootPath, opened))
        }
    }
    if commandRepositories.isEmpty,
       let commandRepository = logRepository ?? logList.activeRepo ?? repo {
        commandRepositories = [(
            canonicalExternalLogPath(commandRepository.workdir() ?? ""),
            commandRepository
        )].filter { !$0.0.isEmpty }
    }
    guard !commandRepositories.isEmpty else {
        logRuntime.isLoadingCommand = false
        logRuntime.commandError = "No Git root is available for the command Log."
        return
    }
    logRuntime.commandIsAggregate = commandIsAggregate
    logRuntime.isLoadingCommand = true
    if reset {
        logRuntime.commandEntries = []
        logSelectionState.selectedIDs = []
        logSelectionState.selection = nil
    }
    logRuntime.hasMoreCommand = !commandHasExplicitLimit
    logRuntime.commandError = nil
    let task = Task.detached(priority: .userInitiated) { [commandRepositories] in
        do {
            var entriesByRoot: [[CommitInfo]] = []
            for (_, commandRepository) in commandRepositories {
                guard !Task.isCancelled else { return }
                entriesByRoot.append(
                    try commandRepository.logWithCommand(
                        commandArgs: arguments,
                        limit: UInt32(commandLimit)
                    )
                )
            }
            let entries = mergedLogCommandEntries(
                entriesByRoot,
                limit: commandLimit,
                aggregate: commandIsAggregate
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == self.logRuntime.commandGeneration,
                      self.externalLogTabIsAlive(tabID),
                      self.logList.viewMode == .command,
                      self.logRuntime.commandIsAggregate == commandIsAggregate,
                      self.logRuntime.commandEntries.count == previousEntryCount,
                      self.logRuntime.aggregateBranchFilters == requestedAggregateFilters,
                      self.logRuntime.aggregateRevisionRanges == requestedAggregateRanges,
                      self.logRuntime.aggregateRootPaths == requestedAggregateRootPaths,
                      self.logList.visibleRootPathsRaw == requestedVisibleRootPathsRaw,
                      normalizedLogRootPaths(self.multiRoots.map(\.path))
                          == requestedDiscoveredRootPaths else { return }
                self.logRuntime.isLoadingCommand = false
                self.logRuntime.commandEntries = entries
                self.logRuntime.hasMoreCommand = !commandHasExplicitLimit && entries.count >= commandLimit
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == self.logRuntime.commandGeneration,
                      self.externalLogTabIsAlive(tabID),
                      self.logList.viewMode == .command,
                      self.logRuntime.commandIsAggregate == commandIsAggregate,
                      self.logRuntime.commandEntries.count == previousEntryCount,
                      self.logRuntime.aggregateBranchFilters == requestedAggregateFilters,
                      self.logRuntime.aggregateRevisionRanges == requestedAggregateRanges,
                      self.logRuntime.aggregateRootPaths == requestedAggregateRootPaths,
                      self.logList.visibleRootPathsRaw == requestedVisibleRootPathsRaw,
                      normalizedLogRootPaths(self.multiRoots.map(\.path))
                          == requestedDiscoveredRootPaths else { return }
                self.logRuntime.isLoadingCommand = false
                self.logRuntime.commandError = errorMessage(error)
                if reset {
                    self.logRuntime.hasMoreCommand = false
                }
            }
        }
    }
    logRuntime.commandTask = task
}

/// Reflog belongs to one Git root even when the surrounding Log is showing a
/// multi-root aggregate. Selecting a root here also gives commit actions the
/// correct repository context for the revision they are about to recover.
func selectReflogRoot(_ rootPath: String, preservingSelection: Bool = false) {
    let trimmedPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else { return }
    let normalizedPath = canonicalExternalLogPath(trimmedPath)
    let primaryPath = repo?.workdir().map(canonicalExternalLogPath)
    let rootRepo: Repository?
    if normalizedPath == primaryPath {
        rootRepo = repo
    } else {
        rootRepo = try? openRepository(path: normalizedPath)
    }
    guard let rootRepo else {
        feedbackCenter.error(
            "Reflog unavailable",
            detail: "Unable to open Git root: \(normalizedPath)",
            nextStep: "Refresh Git Roots and retry."
        )
        return
    }

    reflog.rootPath = normalizedPath
    reflog.rootRepo = rootRepo
    reflog.loadMoreTask?.cancel()
    reflog.loadMoreTask = nil
    reflog.isLoadingMore = false
    if !preservingSelection {
        reflog.entries = []
        reflog.selection = nil
        reflog.selectedIDs = []
        reflog.detailCommit = nil
        reflog.detailCommits = []
        reflog.detailLoadTask?.cancel()
        reflog.detailLoadTask = nil
    }
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logList.startRevision = ""
    logList.startRevisions = []
    logSelectionState.selection = nil
    logSelectionState.selectedIDs = []

    if normalizedPath == primaryPath {
        logList.activeRootPath = nil
        logList.activeRepo = nil
        logRuntime.activeBranches = []
        logRuntime.activeRemoteBranches = []
        logRuntime.activeRemotes = []
    } else {
        logList.activeRootPath = normalizedPath
        logList.activeRepo = rootRepo
        logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
        logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
        logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
    }
    loadReflog()
    if externalLogWindow {
        persistExternalLogTabs()
    }
}

func prepareReflogRoot() {
    let rootPath = reflog.rootPath
        ?? logList.activeRootPath
        ?? repo?.workdir()
        ?? availableReflogRootPaths.first
    guard let rootPath, !rootPath.isEmpty else {
        logList.error = "No Git root is available for Reflog."
        return
    }
    if reflog.rootPath == rootPath, reflog.rootRepo != nil {
        loadReflog()
    } else {
        selectReflogRoot(rootPath, preservingSelection: true)
    }
}

func loadReflog() {
    guard logList.viewMode == .reflog else { return }
    guard let rootPath = reflog.rootPath, !rootPath.isEmpty else {
        prepareReflogRoot()
        return
    }
    reflog.loadTask?.cancel()
    reflog.loadMoreTask?.cancel()
    reflog.loadMoreTask = nil
    reflog.generation += 1
    let generation = reflog.generation
    let tabID = currentLogTabID
    let requestedRepo = reflog.rootRepo
    let pageSize: UInt32 = 100
    logList.isLoading = true
    reflog.isLoadingMore = false
    reflog.hasMore = false
    logList.error = nil

    let task = Task.detached(priority: .userInitiated) {
        do {
            let rootRepo: Repository
            if let requestedRepo {
                rootRepo = requestedRepo
            } else {
                rootRepo = try openRepository(path: rootPath)
            }
            let page = try rootRepo.reflogPage(limit: pageSize + 1, offset: 0)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == self.reflog.generation,
                      self.externalLogTabIsAlive(tabID),
                      self.logList.viewMode == .reflog,
                      self.reflog.rootPath == rootPath else { return }
                if self.reflog.rootRepo == nil {
                    self.reflog.rootRepo = rootRepo
                }
                let entries = Array(page.prefix(Int(pageSize)))
                let selectionState = reconciledReflogSelection(
                    entries: entries,
                    previousSelection: self.reflog.selection,
                    previousSelectedIDs: self.reflog.selectedIDs
                )
                self.reflog.entries = entries
                self.reflog.selection = selectionState.selection
                self.reflog.selectedIDs = selectionState.selectedIDs
                self.reflog.hasMore = page.count > Int(pageSize)
                self.logList.isLoading = false
                self.logList.error = nil
                self.loadReflogCommitDetails()
            }
        } catch {
            await MainActor.run {
                guard generation == self.reflog.generation,
                      self.externalLogTabIsAlive(tabID),
                      self.logList.viewMode == .reflog,
                      self.reflog.rootPath == rootPath else { return }
                self.logList.isLoading = false
                self.reflog.hasMore = false
                self.logList.error = errorMessage(error)
            }
        }
    }
    reflog.loadTask = task
}

/// Append older HEAD reflog records without replacing the current root or
/// selection. The extra record is only a has-more probe, so a page boundary
/// never needs a second request merely to discover that the file ended.
func loadMoreReflog() {
    guard logList.viewMode == .reflog,
          reflog.hasMore,
          !logList.isLoading,
          !reflog.isLoadingMore,
          let rootPath = reflog.rootPath,
          !rootPath.isEmpty else { return }

    reflog.loadMoreTask?.cancel()
    reflog.generation += 1
    let generation = reflog.generation
    let tabID = currentLogTabID
    let requestedRepo = reflog.rootRepo
    let offset = reflog.entries.count
    let pageSize: UInt32 = 100
    reflog.isLoadingMore = true

    let task = Task.detached(priority: .userInitiated) {
        do {
            let rootRepo: Repository
            if let requestedRepo {
                rootRepo = requestedRepo
            } else {
                rootRepo = try openRepository(path: rootPath)
            }
            let page = try rootRepo.reflogPage(
                limit: pageSize + 1,
                offset: UInt32(offset)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == self.reflog.generation,
                      self.externalLogTabIsAlive(tabID),
                      self.logList.viewMode == .reflog,
                      self.reflog.rootPath == rootPath else { return }
                let entries = appendedReflogEntries(
                    existing: self.reflog.entries,
                    page: Array(page.prefix(Int(pageSize)))
                )
                self.reflog.entries.append(contentsOf: entries)
                self.reflog.hasMore = page.count > Int(pageSize)
                self.reflog.isLoadingMore = false
                self.loadReflogCommitDetails()
            }
        } catch {
            await MainActor.run {
                guard generation == self.reflog.generation,
                      self.externalLogTabIsAlive(tabID),
                      self.logList.viewMode == .reflog,
                      self.reflog.rootPath == rootPath else { return }
                self.reflog.isLoadingMore = false
                self.logList.error = errorMessage(error)
            }
        }
    }
    reflog.loadMoreTask = task
}

func reloadLogView() {
    if logList.viewMode == .command {
        runLogCommand()
    } else if logList.viewMode == .reflog {
        loadReflog()
    } else {
        loadLog()
    }
}

/// Mirrors VisiblePackRefresher's request coalescing at the SwiftUI boundary:
/// toggling Regex, Match Case, graph options or multiple branch heads in one
/// event turn produces one refresh request with the final state snapshot.
func scheduleLogRefresh() {
    logList.refreshTask?.cancel()
    logList.refreshTask = Task { @MainActor in
        await Task.yield()
        guard !Task.isCancelled else { return }
        logList.refreshTask = nil
        loadLog()
    }
}

/// Paths structure-filter state is stored as recent groups of normalized,
/// root-qualified selections. Legacy `[[String]]` values are still accepted
/// and become shared selections that apply to every visible Git root.
func activeLogPathFilterSelections() -> [LogPathFilterSelection] {
    let normalized = normalizedLogPathFilterSelections(logList.pathFilterSelections)
    if !normalized.isEmpty {
        return normalized
    }
    return makeLogPathFilterSelections(from: normalizedLogPathFilters(logList.pathFilter))
}

func recentLogPathFilterSelections() -> [[LogPathFilterSelection]] {
    guard let data = logRecentPathFiltersRaw.data(using: .utf8) else { return [] }
    if let decoded = try? JSONDecoder().decode([[LogPathFilterSelection]].self, from: data) {
        return decoded.compactMap { values in
            let normalized = normalizedLogPathFilterSelections(values)
            return normalized.isEmpty ? nil : normalized
        }
    }
    guard let legacy = try? JSONDecoder().decode([[String]].self, from: data) else {
        return []
    }
    return legacy.compactMap { values in
        let normalized = makeLogPathFilterSelections(from: normalizedLogPathFilters(values.joined(separator: "\n")))
        return normalized.isEmpty ? nil : normalized
    }
}

func rememberLogPathFilterSelections(_ selections: [LogPathFilterSelection]) {
    let normalized = normalizedLogPathFilterSelections(selections)
    guard !normalized.isEmpty else { return }
    let updated = ([normalized] + recentLogPathFilterSelections().filter { $0 != normalized }).prefix(10)
    guard let data = try? JSONEncoder().encode(Array(updated)) else { return }
    logRecentPathFiltersRaw = String(decoding: data, as: UTF8.self)
}

func setLogPathFilterSelections(
    _ selections: [LogPathFilterSelection],
    remember: Bool = true
) {
    let normalized = normalizedLogPathFilterSelections(selections)
    if let projectPath,
       logSelectionState.tabs.first(where: { $0.id == currentLogTabID })?.updateInfoRanges != nil {
        GitUpdateInfoPathFilterSettings.save(
            logPathFilterEditorText(normalized),
            roots: logStructureFilterRootPaths,
            for: projectPath
        )
    }
    logList.pathFilterSelections = normalized
    logList.pathFilter = logPathFilterEditorText(normalized)
    if remember {
        rememberLogPathFilterSelections(normalized)
    }
    scheduleLogRefresh()
}

func setLogPathFilterPaths(_ paths: [String], remember: Bool = true) {
    setLogPathFilterSelections(makeLogPathFilterSelections(from: paths), remember: remember)
}

func openLogPathsEditor() {
    logList.pathsEditorText = logPathFilterEditorText(activeLogPathFilterSelections())
    logList.pathsEditorPresented = true
}

func clearRecentLogPathFilters() {
    logRecentPathFiltersRaw = ""
}

func logPathTreeSelections() -> Set<LogPathFilterSelection> {
    let roots = normalizedLogRootPaths(
        logStructureFilterRootPaths.isEmpty ? availableReflogRootPaths : logStructureFilterRootPaths
    )
    var result = Set<LogPathFilterSelection>()
    for selection in activeLogPathFilterSelections() {
        if let rootPath = selection.rootPath {
            if roots.contains(rootPath) {
                result.insert(selection)
            }
        } else {
            for rootPath in roots {
                result.insert(LogPathFilterSelection(rootPath: rootPath, path: selection.path))
            }
        }
    }
    return normalizedLogTreeSelections(Array(result))
}

func openLogPathsTreeChooser() {
    let rootPaths = normalizedLogRootPaths(
        logStructureFilterRootPaths.isEmpty ? availableReflogRootPaths : logStructureFilterRootPaths
    )
    let roots = rootPaths.compactMap { rootPath -> LogPathChooserRoot? in
        guard let repository = try? openRepository(path: rootPath) else { return nil }
        return LogPathChooserRoot(path: rootPath, repository: repository)
    }
    guard !roots.isEmpty else {
        feedbackCenter.warning(
            "Paths filter unavailable",
            detail: "No Git root is available for selecting a path.",
            nextStep: "Open or refresh a Git repository and retry.",
            localized: false
        )
        return
    }
    logList.pathsTreeChooserRoots = roots
    logList.pathsTreeChooserSelections = logPathTreeSelections()
    logList.pathsTreeChooserPresented = true
}

var logStructureFilterRootPaths: [String] {
    if isLogAggregate {
        return normalizedLogRootPaths(
            logRuntime.aggregateBranchFilters.map(\.rootPath)
                + logRuntime.aggregateRevisionRanges.map(\.rootPath)
                + Array(logRuntime.aggregateRootPaths)
        )
    }
    return normalizedLogRootPaths([logRepository?.workdir()].compactMap { $0 })
}

var visibleLogStructureFilterRootPaths: Set<String> {
    reconciledLogVisibleRootPaths(
        allRoots: logStructureFilterRootPaths,
        raw: logVisibleRootFilterRaw(for: logStructureFilterRootPaths)
    )
}

func logVisibleRootPersistenceScope(_ roots: [String]) -> String {
    normalizedLogRootPaths(roots).joined(separator: "\u{1f}")
}

func persistedLogVisibleRootPaths(for roots: [String]) -> Set<String>? {
    guard let data = logVisibleRootPathsPersistedRaw.data(using: .utf8),
          let values = try? JSONDecoder().decode([String: [String]].self, from: data),
          let selected = values[logVisibleRootPersistenceScope(roots)] else {
        return nil
    }
    return Set(normalizedLogRootPaths(selected)).intersection(normalizedLogRootPaths(roots))
}

func logVisibleRootFilterRaw(for roots: [String]) -> String {
    guard logList.visibleRootPathsRaw.isEmpty,
          let selected = persistedLogVisibleRootPaths(for: roots) else {
        return logList.visibleRootPathsRaw
    }
    return serializedLogVisibleRootPaths(selected: selected, allRoots: roots)
}

func persistLogVisibleRootPaths(selected: Set<String>, allRoots: [String]) {
    let normalizedRoots = normalizedLogRootPaths(allRoots)
    let scope = logVisibleRootPersistenceScope(normalizedRoots)
    guard !scope.isEmpty else { return }
    var values = (try? JSONDecoder().decode(
        [String: [String]].self,
        from: logVisibleRootPathsPersistedRaw.data(using: .utf8) ?? Data()
    )) ?? [:]
    if selected == Set(normalizedRoots) {
        values.removeValue(forKey: scope)
    } else {
        values[scope] = normalizedLogRootPaths(Array(selected.intersection(Set(normalizedRoots))))
    }
    guard let data = try? JSONEncoder().encode(values) else { return }
    logVisibleRootPathsPersistedRaw = String(decoding: data, as: UTF8.self)
}

func setLogStructureFilterRoot(_ rootPath: String, visible: Bool) {
    let allRoots = logStructureFilterRootPaths
    guard allRoots.contains(rootPath) else { return }
    var selected = visibleLogStructureFilterRootPaths
    if visible {
        selected.insert(rootPath)
    } else {
        guard selected.count > 1 else { return }
        selected.remove(rootPath)
    }
    logList.visibleRootPathsRaw = serializedLogVisibleRootPaths(selected: selected, allRoots: allRoots)
    persistLogVisibleRootPaths(selected: selected, allRoots: allRoots)
    loadLog()
}

func chooseLogPathFilter() {
    let roots = logStructureFilterRootPaths.isEmpty
        ? availableReflogRootPaths
        : logStructureFilterRootPaths
    guard let firstRoot = roots.first else {
        feedbackCenter.warning(
            "Paths filter unavailable",
            detail: "No Git root is available for selecting a path.",
            nextStep: "Open or refresh a Git repository and retry.",
            localized: false
        )
        return
    }

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.prompt = "Select Path"
    panel.directoryURL = URL(fileURLWithPath: logRepository?.workdir() ?? firstRoot)
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

    let normalizedRoots = logRootPathsDeepestFirst(roots)
    var selections: [LogPathFilterSelection] = []
    for url in panel.urls {
        guard let filter = relativeLogPathFilter(for: url, roots: roots) else {
            feedbackCenter.warning(
                "Path is outside the Git roots",
                detail: url.standardizedFileURL.path,
                nextStep: "Select files or folders inside one of the project's Git roots.",
                localized: false
            )
            return
        }
        if !filter.isEmpty {
            let selectedPath = url.standardizedFileURL.path
            let rootPath = normalizedRoots.first(where: {
                selectedPath == $0 || selectedPath.hasPrefix($0 + "/")
            })
            selections.append(LogPathFilterSelection(rootPath: rootPath, path: filter))
        }
    }
    guard !selections.isEmpty else {
        setLogPathFilterPaths([])
        return
    }
    setLogPathFilterSelections(activeLogPathFilterSelections() + selections)
}

func clearLogPathFilter() {
    guard !activeLogPathFilterSelections().isEmpty else { return }
    setLogPathFilterSelections([], remember: false)
}

func loadLog(reset: Bool = true) {
    if logList.viewMode == .reflog {
        loadReflog()
        return
    }
    if isLogAggregate {
        loadAggregatedLog(reset: reset)
        return
    }
    guard let repo = logRepository else { return }
    // Phase 5 取消行为:新加载使旧请求结果失效(切换条件后不覆盖新结果)
    logList.loadTask?.cancel()
    logList.generation += 1
    let generation = logList.generation
    let tabID = currentLogTabID
    let activePathSelections = activeLogPathFilterSelections()
    let pathFilters = logPathFilterPathsForRoot(
        activePathSelections,
        rootPath: repo.workdir() ?? ""
    ) ?? []
    let hasActivePathFilter = !activePathSelections.isEmpty
    let startRevisions = activeLogStartRevisions
    let start = startRevisions.count == 1 ? startRevisions[0] : ""
    let author = logList.authorFilter.trimmingCharacters(in: .whitespaces)
    let message = logList.messageFilter.trimmingCharacters(in: .whitespaces)
    let messageRegex = logList.messageRegex
    let messageMatchCase = logList.messageMatchCase
    let hashQuery = isCommitHashQuery(message) ? message.lowercased() : nil
    let since = parseLogSince(logList.since)
    let until = parseLogUntil(logList.until)
    let noMerges = logNoMerges
    let follow = logList.follow
    let querySortModeRaw = logRuntime.sortModeRaw
    let sortMode = LogGraphSortChoice(rawValue: logRuntime.sortModeRaw)?.engineValue
        ?? LogGraphSortChoice.byCommitDate.engineValue
    let effectiveStart = hashQuery ?? start
    let effectiveMessage = hashQuery == nil ? message : ""
    let dateText = logList.since.trimmingCharacters(in: .whitespacesAndNewlines)
    let untilText = logList.until.trimmingCharacters(in: .whitespacesAndNewlines)
    let canPage = !hasActivePathFilter && startRevisions.isEmpty && effectiveStart.isEmpty
        && author.isEmpty && effectiveMessage.isEmpty
        && since == nil && dateText.isEmpty && until == nil && untilText.isEmpty && !noMerges
    // VisiblePackRefresher can request more commits with filters applied. The
    // engine keeps the same revision/filter state and resumes from afterId;
    // short-hash lookup is intentionally a single-row query, and a path
    // selection that does not belong to this root has no continuation.
    let canContinueWithCursor = hashQuery == nil
        && !(hasActivePathFilter && pathFilters.isEmpty)
    if (!dateText.isEmpty && since == nil) || (!untilText.isEmpty && until == nil) {
        logList.error = "Date filters must be YYYY-MM-DD, YYYY-MM-DD HH:mm, or Unix seconds."
        logList.isLoading = false
        logList.isLoadingMore = false
        return
    }
    if let since, let until, since >= until {
        logList.error = "The Since date must be earlier than the Until date."
        logList.isLoading = false
        logList.isLoadingMore = false
        return
    }
    let requestedCursor = reset ? nil : logList.pageCursor
    if reset {
        logList.isLoading = true
        logList.isLoadingMore = false
        logList.isShowingCachedSnapshot = false
        logSelectionState.detailCommit = nil
        reflog.detailCommit = nil
        reflog.detailCommits = []
        reflog.selectedIDs = []
        reflog.selection = nil
        reflog.detailLoadTask?.cancel()
        reflog.detailLoadTask = nil
    } else {
        logList.isLoadingMore = true
    }
    let pageLimit = reset ? initialLogPageLimit : continuationLogPageLimit
    let rootPath = canonicalExternalLogPath(repo.workdir() ?? "")
    let queryFingerprint = persistedLogCacheQueryFingerprint(
        rootPath: rootPath,
        pathFilters: pathFilters,
        startRevisions: effectiveStart.isEmpty ? startRevisions : [effectiveStart],
        author: author,
        message: effectiveMessage,
        messageRegex: messageRegex,
        messageMatchCase: messageMatchCase,
        since: dateText,
        until: untilText,
        noMerges: noMerges,
        follow: follow,
        sortMode: querySortModeRaw,
        pageLimit: pageLimit
    )
    let graphQueryFingerprint = persistedLogGraphQueryFingerprint(
        rootPath: rootPath,
        pathFilters: pathFilters,
        startRevisions: effectiveStart.isEmpty ? startRevisions : [effectiveStart],
        author: author,
        message: effectiveMessage,
        messageRegex: messageRegex,
        messageMatchCase: messageMatchCase,
        since: dateText,
        until: untilText,
        noMerges: noMerges,
        follow: follow,
        sortMode: querySortModeRaw
    )
    let canRestoreLogSnapshot = !(hasActivePathFilter && pathFilters.isEmpty)
    let cachedEntry = reset && !rootPath.isEmpty && canRestoreLogSnapshot
        ? loadPersistedLogCache(rootPath: rootPath)
        : nil
    let cachedGraphEntry = reset && !rootPath.isEmpty && canRestoreLogSnapshot
        ? loadPersistedLogGraph(rootPath: rootPath)
        : nil
    let task = Task.detached(priority: .userInitiated) {
        do {
            let refsToken = persistedLogRefsToken(repo: repo, rootPath: rootPath)
            let restoredGraph: PersistedLogGraphRestore? = if reset,
                                                              let cachedGraphEntry,
                                                              let refsToken {
                cachedGraphEntry.restoredIfValid(
                    rootPath: rootPath,
                    queryFingerprint: graphQueryFingerprint,
                    refsToken: refsToken
                )
            } else {
                nil
            }
            if let restoredGraph {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.logList.generation,
                          self.externalLogTabIsAlive(tabID),
                          self.isActiveLogRepository(repo) else { return }
                    self.logList.entries = restoredGraph.commits
                    self.logList.pageCursor = restoredGraph.cursor
                    self.logList.hasMore = restoredGraph.hasMore
                    self.logSelectionState.selection = restoredGraph.commits.first?.id
                    self.logSelectionState.selectedIDs = restoredGraph.commits.first.map { [$0.id] } ?? []
                    self.logList.isShowingCachedSnapshot = true
                }
            } else if reset,
                      let cachedEntry,
                      let refsToken,
                      let cachedLog = cachedEntry.restoredCommitsIfValid(
                          rootPath: rootPath,
                          queryFingerprint: queryFingerprint,
                          refsToken: refsToken
                      ) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.logList.generation,
                          self.externalLogTabIsAlive(tabID),
                          self.isActiveLogRepository(repo) else { return }
                    self.logList.entries = cachedLog
                    self.logList.pageCursor = cachedLog.last?.id
                    self.logList.hasMore = canPage && cachedLog.count >= Int(pageLimit)
                    self.logList.isShowingCachedSnapshot = true
                }
            }
            // A completed snapshot still needs a fresh first-page read on an
            // explicit reset/refresh. A partial snapshot can continue from its
            // saved cursor without replaying all previously loaded pages.
            let cursor = reset
                ? (restoredGraph?.hasMore == true ? restoredGraph?.cursor : nil)
                : requestedCursor
            let log: [CommitInfo]
            if canPage {
                log = try repo.logWithSort(
                    path: nil,
                    limit: pageLimit,
                    follow: follow,
                    afterId: cursor,
                    sortMode: sortMode
                )
            } else if hasActivePathFilter && pathFilters.isEmpty {
                log = []
            } else {
                let loaded = try repo.logFilteredWithPathsWithMessageAndDateOptionsForRevisionsWithAfterId(
                    paths: pathFilters,
                    limit: pageLimit,
                    follow: follow,
                    startRevs: effectiveStart.isEmpty ? startRevisions : [effectiveStart],
                    author: author.isEmpty ? nil : author,
                    since: since,
                    until: until,
                    message: effectiveMessage.isEmpty ? nil : effectiveMessage,
                    messageRegex: messageRegex,
                    messageMatchCase: messageMatchCase,
                    noMerges: noMerges,
                    sortMode: sortMode,
                    afterId: cursor
                )
                // A short object id is a revision lookup, not a message
                // substring search. Start the walk at the resolved commit and
                // keep only the requested row in the result table.
                log = if let hashQuery {
                    loaded.filter { $0.id.lowercased().hasPrefix(hashQuery) }
                } else {
                    loaded
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.logList.generation,
                      self.externalLogTabIsAlive(tabID),
                      self.isActiveLogRepository(repo) else { return } // 过期结果丢弃
                if reset {
                    let previousSelection = self.logSelectionState.selection
                    let previousSelections = self.logSelectionState.selectedIDs
                    var restoredEntries = restoredGraph?.commits ?? []
                    let restoredIDs = Set(restoredEntries.map(\.id))
                    restoredEntries.append(contentsOf: log.filter { !restoredIDs.contains($0.id) })
                    self.logList.entries = restoredEntries
                    self.logList.isShowingCachedSnapshot = false
                    // Keep the current row when a refresh still contains it;
                    // otherwise select the first visible revision. Refresh
                    // changes the model, not the user's context.
                    let retainedSelections = restoredEntries.filter { commit in
                        previousSelections.contains { selectedID in
                            commit.id == selectedID
                                || commit.id.hasPrefix(selectedID)
                                || selectedID.hasPrefix(commit.id)
                        }
                    }
                    if !retainedSelections.isEmpty {
                        self.logSelectionState.selectedIDs = Set(retainedSelections.map(\.id))
                        self.logSelectionState.selection = retainedSelections.first(where: { $0.id == previousSelection })?.id
                            ?? retainedSelections.first?.id
                    } else if let selectedID = matchingLogCommitID(
                        requestedID: previousSelection,
                        in: restoredEntries
                    ) {
                        self.logSelectionState.selection = selectedID
                        self.logSelectionState.selectedIDs = [selectedID]
                    } else {
                        self.logSelectionState.selection = restoredEntries.first?.id
                        self.logSelectionState.selectedIDs = restoredEntries.first.map { Set([$0.id]) } ?? []
                    }
                    self.logList.pageCursor = log.last?.id ?? restoredGraph?.cursor
                } else {
                    let oldIds = Set(self.logList.entries.map(\.id))
                    self.logList.entries.append(contentsOf: log.filter { !oldIds.contains($0.id) })
                    self.logList.pageCursor = log.last?.id ?? self.logList.pageCursor
                }
                self.logList.hasMore = if let restoredGraph {
                    restoredGraph.hasMore && log.count >= Int(pageLimit)
                } else {
                    canContinueWithCursor && log.count >= Int(pageLimit)
                }
                self.logList.isLoadingMore = false
                if reset { self.logList.isLoading = false }
                if reset, let refsToken {
                    savePersistedLogCache(
                        PersistedLogCacheEntry(
                            rootPath: rootPath,
                            queryFingerprint: queryFingerprint,
                            refsToken: refsToken,
                            commits: log
                        )
                    )
                    savePersistedLogGraph(
                        PersistedLogGraphEntry(
                            rootPath: rootPath,
                            queryFingerprint: graphQueryFingerprint,
                            refsToken: refsToken,
                            commits: self.logList.entries,
                            cursor: self.logList.pageCursor,
                            hasMore: self.logList.hasMore
                        )
                    )
                } else if let refsToken {
                    savePersistedLogGraph(
                        PersistedLogGraphEntry(
                            rootPath: rootPath,
                            queryFingerprint: graphQueryFingerprint,
                            refsToken: refsToken,
                            commits: self.logList.entries,
                            cursor: self.logList.pageCursor,
                            hasMore: self.logList.hasMore
                        )
                    )
                }
                self.logList.error = nil
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.logList.generation,
                      self.externalLogTabIsAlive(tabID),
                      self.isActiveLogRepository(repo) else { return }
                self.logList.error = self.logList.isShowingCachedSnapshot
                    ? "Refresh failed; showing cached history. \(errorMessage(error))"
                    : errorMessage(error)
                self.logList.isLoadingMore = false
                if reset { self.logList.isLoading = false }
            }
        }
    }
    logList.loadTask = task
}

struct AggregatedLogRootResult {
    let rootPath: String
    let repository: Repository
    let commits: [CommitInfo]
    let queryFingerprint: String
    let graphQueryFingerprint: String
    let refsToken: String?
    let cursor: String?
    let hasMore: Bool
}

nonisolated func flattenedAggregatedLogEntries(
    _ results: [AggregatedLogRootResult]
) -> [CommitInfo] {
    var entries: [CommitInfo] = []
    var seen = Set<String>()
    for result in results {
        for commit in result.commits {
            var flatCommit = commit
            flatCommit.repositoryPath = result.rootPath
            flatCommit.lane = 0
            flatCommit.parentLanes = []
            let key = "\(flatCommit.repositoryPath ?? result.rootPath)\u{1f}\(flatCommit.id)"
            if seen.insert(key).inserted {
                entries.append(flatCommit)
            }
        }
    }
    return entries.sorted {
        if $0.time != $1.time { return $0.time > $1.time }
        let leftRoot = $0.repositoryPath ?? ""
        let rightRoot = $1.repositoryPath ?? ""
        if leftRoot != rightRoot { return leftRoot < rightRoot }
        return $0.id < $1.id
    }
}

/// Loads one filtered VCS Log query per selected root and merges the rows by
/// `(repositoryPath, object id)`. Git's graph lanes are intentionally cleared:
/// lanes are meaningful inside one repository only, so drawing them across
/// roots would create false parent edges. The table remains fully selectable,
/// sortable, and diff-capable while each row keeps its owning repository.
func loadAggregatedLog(reset: Bool) {
    logList.loadTask?.cancel()
    logList.generation += 1
    let generation = logList.generation
    let filters = logRuntime.aggregateBranchFilters
    let revisionRanges = logRuntime.aggregateRevisionRanges
    let aggregateRootPaths = logRuntime.aggregateRootPaths
    let providerSession = externalLogProviderSession
    let logManager = externalLogUIManager
    let tabID = currentLogTabID
    let allFilterByRoot: [String: [String]]
    if !revisionRanges.isEmpty {
        allFilterByRoot = Dictionary(grouping: revisionRanges, by: \LogRootRevisionRange.rootPath)
            .mapValues { ranges in
                ranges.map { "\($0.oldRevision)..\($0.newRevision)" }
            }
    } else if !filters.isEmpty {
        allFilterByRoot = Dictionary(grouping: filters, by: \LogRootBranchFilter.rootPath)
            .mapValues { $0.map(\.branch) }
    } else {
        // An external Git Log window with no branch/range filter means all
        // refs in each selected root. The Rust engine deliberately preserves
        // that default when startRevs is empty.
        allFilterByRoot = Dictionary(uniqueKeysWithValues: aggregateRootPaths.map {
            ($0, [String]())
        })
    }
    let aggregateRoots = Array(allFilterByRoot.keys)
    let visibleRootPaths = reconciledLogVisibleRootPaths(
        allRoots: aggregateRoots,
        raw: logVisibleRootFilterRaw(for: aggregateRoots)
    )
    let filterByRoot = allFilterByRoot.filter { visibleRootPaths.contains($0.key) }
    let visibleRootPathsRaw = logList.visibleRootPathsRaw
    let visibleRootPathsPersistedRaw = logVisibleRootPathsPersistedRaw
    let activePathSelections = activeLogPathFilterSelections()
    let pathFiltersByRoot = Dictionary(uniqueKeysWithValues: allFilterByRoot.keys.map { rootPath in
        (rootPath, logPathFilterPathsForRoot(activePathSelections, rootPath: rootPath) ?? [])
    })
    let rootsWithoutMatchingPathFilter = Set(
        activePathSelections.isEmpty
            ? []
            : pathFiltersByRoot.compactMap { $0.value.isEmpty ? $0.key : nil }
    )
    let author = logList.authorFilter.trimmingCharacters(in: .whitespaces)
    let message = logList.messageFilter.trimmingCharacters(in: .whitespaces)
    let messageRegex = logList.messageRegex
    let messageMatchCase = logList.messageMatchCase
    let hashQuery = isCommitHashQuery(message) ? message.lowercased() : nil
    let since = parseLogSince(logList.since)
    let until = parseLogUntil(logList.until)
    let noMerges = logNoMerges
    let follow = logList.follow
    let querySortModeRaw = logRuntime.sortModeRaw
    let sortMode = LogGraphSortChoice(rawValue: logRuntime.sortModeRaw)?.engineValue
        ?? LogGraphSortChoice.byCommitDate.engineValue
    let dateText = logList.since.trimmingCharacters(in: .whitespacesAndNewlines)
    let untilText = logList.until.trimmingCharacters(in: .whitespacesAndNewlines)
    if (!dateText.isEmpty && since == nil) || (!untilText.isEmpty && until == nil) {
        logList.error = "Date filters must be YYYY-MM-DD, YYYY-MM-DD HH:mm, or Unix seconds."
        logList.isLoading = false
        logList.isLoadingMore = false
        return
    }
    if let since, let until, since >= until {
        logList.error = "The Since date must be earlier than the Until date."
        logList.isLoading = false
        logList.isLoadingMore = false
        return
    }
    if reset {
        logList.isLoading = true
        logList.isLoadingMore = false
        logList.isShowingCachedSnapshot = false
        logRuntime.aggregateLoadedCounts = [:]
        logRuntime.aggregatePageCursors = [:]
        logSelectionState.detailCommit = nil
        logRuntime.aggregateRepositories = [:]
        logCherryPick.cherryPickedCommitIDs = []
        logCherryPick.comparisonReady = false
        logCherryPick.completedRoots = 0
        logCherryPick.totalRoots = 0
    } else {
        logList.isLoadingMore = true
    }
    let pageCursors = reset ? [:] : logRuntime.aggregatePageCursors
    let pageSize = reset ? Int(initialLogPageLimit) : Int(continuationLogPageLimit)
    let task = Task.detached(priority: .userInitiated) {
        do {
            var requests: [(
                rootPath: String,
                repository: Repository,
                startRevisions: [String],
                limit: UInt32,
                afterID: String?,
                queryFingerprint: String,
                graphQueryFingerprint: String,
                refsToken: String?,
                cachedCommits: [CommitInfo]?,
                cachedGraph: PersistedLogGraphRestore?
            )] = []
            for rootPath in filterByRoot.keys.sorted() {
                guard !Task.isCancelled else { return }
                let rootRepo: Repository
                if let logManager {
                    guard let sessionRepository = logManager.repository(for: rootPath) else {
                        return
                    }
                    rootRepo = sessionRepository
                } else if let providerSession {
                    guard let sessionRepository = providerSession.repository(for: rootPath) else {
                        return
                    }
                    rootRepo = sessionRepository
                } else {
                    rootRepo = try openRepository(path: rootPath)
                }
                let startRevisions = hashQuery.map { [$0] } ?? filterByRoot[rootPath, default: []]
                let limit = UInt32(max(1, pageSize))
                let rootPathFilters = pathFiltersByRoot[rootPath] ?? []
                let queryFingerprint = persistedLogCacheQueryFingerprint(
                    rootPath: rootPath,
                    pathFilters: rootPathFilters,
                    startRevisions: startRevisions,
                    author: author,
                    message: hashQuery == nil ? message : "",
                    messageRegex: messageRegex,
                    messageMatchCase: messageMatchCase,
                    since: dateText,
                    until: untilText,
                    noMerges: noMerges,
                    follow: follow,
                    sortMode: querySortModeRaw,
                    pageLimit: limit
                )
                let graphQueryFingerprint = persistedLogGraphQueryFingerprint(
                    rootPath: rootPath,
                    pathFilters: rootPathFilters,
                    startRevisions: startRevisions,
                    author: author,
                    message: hashQuery == nil ? message : "",
                    messageRegex: messageRegex,
                    messageMatchCase: messageMatchCase,
                    since: dateText,
                    until: untilText,
                    noMerges: noMerges,
                    follow: follow,
                    sortMode: querySortModeRaw
                )
                let refsToken = persistedLogRefsToken(repo: rootRepo, rootPath: rootPath)
                let cachedGraph: PersistedLogGraphRestore?
                if reset,
                   !rootsWithoutMatchingPathFilter.contains(rootPath),
                   let cachedEntry = loadPersistedLogGraph(rootPath: rootPath),
                   let refsToken {
                    cachedGraph = cachedEntry.restoredIfValid(
                        rootPath: rootPath,
                        queryFingerprint: graphQueryFingerprint,
                        refsToken: refsToken
                    )
                } else {
                    cachedGraph = nil
                }
                let afterID = if reset {
                    cachedGraph?.hasMore == true ? cachedGraph?.cursor : nil
                } else {
                    pageCursors[rootPath]
                }
                let cachedCommits: [CommitInfo]?
                if reset,
                   cachedGraph == nil,
                   !rootsWithoutMatchingPathFilter.contains(rootPath),
                   let cachedEntry = loadPersistedLogCache(rootPath: rootPath),
                   let refsToken {
                    cachedCommits = cachedEntry.restoredCommitsIfValid(
                        rootPath: rootPath,
                        queryFingerprint: queryFingerprint,
                        refsToken: refsToken
                    )
                } else {
                    cachedCommits = nil
                }
                requests.append((
                    rootPath: rootPath,
                    repository: rootRepo,
                    startRevisions: startRevisions,
                    limit: limit,
                    afterID: afterID,
                    queryFingerprint: queryFingerprint,
                    graphQueryFingerprint: graphQueryFingerprint,
                    refsToken: refsToken,
                    cachedCommits: cachedCommits,
                    cachedGraph: cachedGraph
                ))
            }

            let cachedResults = requests.compactMap { request -> AggregatedLogRootResult? in
                if let cachedGraph = request.cachedGraph {
                    return AggregatedLogRootResult(
                        rootPath: request.rootPath,
                        repository: request.repository,
                        commits: cachedGraph.commits,
                        queryFingerprint: request.queryFingerprint,
                        graphQueryFingerprint: request.graphQueryFingerprint,
                        refsToken: request.refsToken,
                        cursor: cachedGraph.cursor,
                        hasMore: cachedGraph.hasMore
                    )
                }
                guard let cachedCommits = request.cachedCommits else { return nil }
                return AggregatedLogRootResult(
                    rootPath: request.rootPath,
                    repository: request.repository,
                    commits: cachedCommits,
                    queryFingerprint: request.queryFingerprint,
                    graphQueryFingerprint: request.graphQueryFingerprint,
                    refsToken: request.refsToken,
                    cursor: cachedCommits.last?.id,
                    hasMore: cachedCommits.count >= Int(initialLogPageLimit)
                )
            }
            let cachedEntriesSnapshot = flattenedAggregatedLogEntries(cachedResults)
            let cachedCountsSnapshot = Dictionary(
                uniqueKeysWithValues: cachedResults.map { ($0.rootPath, $0.commits.count) }
            )
            let cachedCursorsSnapshot = Dictionary(
                uniqueKeysWithValues: cachedResults.compactMap { result in
                    result.cursor.map { (result.rootPath, $0) }
                }
            )
            let cachedRepositoriesSnapshot = Dictionary(
                uniqueKeysWithValues: cachedResults.map { ($0.rootPath, $0.repository) }
            )
            let cachedHasMoreSnapshot = cachedResults.contains { $0.hasMore }
            if reset, !cachedResults.isEmpty {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.logList.generation,
                          self.externalLogTabIsAlive(tabID),
                          !(self.externalLogWindow && self.externalLogSessionDisposed),
                          self.logRuntime.aggregateBranchFilters == filters,
                          self.logRuntime.aggregateRevisionRanges == revisionRanges,
                          self.logRuntime.aggregateRootPaths == aggregateRootPaths,
                          self.logList.visibleRootPathsRaw == visibleRootPathsRaw,
                          self.logVisibleRootPathsPersistedRaw == visibleRootPathsPersistedRaw else { return }
                    self.logList.entries = cachedEntriesSnapshot
                    self.logRuntime.aggregateRepositories = cachedRepositoriesSnapshot
                    self.logRuntime.aggregateLoadedCounts = cachedCountsSnapshot
                    self.logRuntime.aggregatePageCursors = cachedCursorsSnapshot
                    self.logSelectionState.selection = cachedEntriesSnapshot.first.map(self.logCommitIdentity)
                    self.logSelectionState.selectedIDs = cachedEntriesSnapshot.first.map { [self.logCommitIdentity($0)] } ?? []
                    self.logList.hasMore = cachedHasMoreSnapshot
                    self.logList.isShowingCachedSnapshot = true
                }
            }

            var results: [AggregatedLogRootResult] = []
            for request in requests {
                guard !Task.isCancelled else { return }
                let rootPath = request.rootPath
                let rootRepo = request.repository
                let loaded: [CommitInfo]
                if rootsWithoutMatchingPathFilter.contains(rootPath) {
                    loaded = []
                } else {
                    loaded = try rootRepo.logFilteredWithPathsWithMessageAndDateOptionsForRevisionsWithAfterId(
                        paths: pathFiltersByRoot[rootPath] ?? [],
                        limit: request.limit,
                        follow: follow,
                        startRevs: request.startRevisions,
                        author: author.isEmpty ? nil : author,
                        since: since,
                        until: until,
                        message: hashQuery == nil && !message.isEmpty ? message : nil,
                        messageRegex: messageRegex,
                        messageMatchCase: messageMatchCase,
                        noMerges: noMerges,
                        sortMode: sortMode,
                        afterId: request.afterID
                    )
                }
                let commits = if let hashQuery {
                    loaded.filter { $0.id.lowercased().hasPrefix(hashQuery) }
                } else {
                    loaded
                }
                let rootScopedCommits = commits.map { commit in
                    var rootScopedCommit = commit
                    rootScopedCommit.repositoryPath = rootPath
                    return rootScopedCommit
                }
                let hasMore = if request.cachedGraph != nil {
                    request.cachedGraph!.hasMore && commits.count >= Int(request.limit)
                } else {
                    commits.count >= Int(request.limit)
                }
                let cursor = if let cachedGraph = request.cachedGraph,
                                !cachedGraph.hasMore {
                    cachedGraph.cursor
                } else {
                    rootScopedCommits.last?.id ?? request.cachedGraph?.cursor
                }
                results.append(AggregatedLogRootResult(
                    rootPath: rootPath,
                    repository: rootRepo,
                    commits: rootScopedCommits,
                    queryFingerprint: request.queryFingerprint,
                    graphQueryFingerprint: request.graphQueryFingerprint,
                    refsToken: request.refsToken,
                    cursor: cursor,
                    hasMore: hasMore
                ))
            }
            guard !Task.isCancelled else { return }
            let loadedResults = results
            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.logList.generation,
                      self.externalLogTabIsAlive(tabID),
                      !(self.externalLogWindow && self.externalLogSessionDisposed),
                      self.logRuntime.aggregateBranchFilters == filters,
                      self.logRuntime.aggregateRevisionRanges == revisionRanges,
                      self.logRuntime.aggregateRootPaths == aggregateRootPaths,
                      self.logList.visibleRootPathsRaw == visibleRootPathsRaw,
                      self.logVisibleRootPathsPersistedRaw == visibleRootPathsPersistedRaw else { return }
                var visible: [CommitInfo] = reset ? cachedEntriesSnapshot : self.logList.entries
                var cursors = reset ? cachedCursorsSnapshot : self.logRuntime.aggregatePageCursors
                var repositories = reset
                    ? (self.externalLogUIManager?.repositories(for: aggregateRoots)
                        ?? self.externalLogProviderSession?.repositories(for: aggregateRoots)
                        ?? cachedRepositoriesSnapshot)
                    : self.logRuntime.aggregateRepositories
                for result in loadedResults {
                    repositories[result.rootPath] = result.repository
                    visible.append(contentsOf: result.commits.map { commit in
                        var flatCommit = commit
                        flatCommit.lane = 0
                        flatCommit.parentLanes = []
                        return flatCommit
                    })
                    if let cursor = result.cursor {
                        cursors[result.rootPath] = cursor
                    }
                }
                var deduplicated: [CommitInfo] = []
                var seen = Set<String>()
                for commit in visible.sorted(by: {
                    if $0.time != $1.time { return $0.time > $1.time }
                    let leftRoot = $0.repositoryPath ?? ""
                    let rightRoot = $1.repositoryPath ?? ""
                    if leftRoot != rightRoot { return leftRoot < rightRoot }
                    return $0.id < $1.id
                }) {
                    let key = "\(commit.repositoryPath ?? "")\u{1f}\(commit.id)"
                    if seen.insert(key).inserted {
                        deduplicated.append(commit)
                    }
                }
                var counts: [String: Int] = [:]
                for commit in deduplicated {
                    counts[commit.repositoryPath ?? "", default: 0] += 1
                }
                let previousSelection = self.logSelectionState.selection
                let previousSelections = self.logSelectionState.selectedIDs
                self.logList.entries = deduplicated
                self.logRuntime.aggregateRepositories = repositories
                self.logRuntime.aggregateLoadedCounts = counts
                self.logRuntime.aggregatePageCursors = cursors
                self.logList.pageCursor = nil
                self.logList.hasMore = loadedResults.contains { $0.hasMore }
                let retained = deduplicated.filter { commit in
                    let identity = self.logCommitIdentity(commit)
                    return previousSelections.contains(identity) || identity == previousSelection
                }
                if let first = retained.first {
                    self.logSelectionState.selection = self.logCommitIdentity(first)
                    self.logSelectionState.selectedIDs = Set(retained.map(self.logCommitIdentity))
                } else if let first = deduplicated.first {
                    self.logSelectionState.selection = self.logCommitIdentity(first)
                    self.logSelectionState.selectedIDs = [self.logCommitIdentity(first)]
                } else {
                    self.logSelectionState.selection = nil
                    self.logSelectionState.selectedIDs = []
                }
                self.logList.isLoadingMore = false
                if reset { self.logList.isLoading = false }
                self.logList.isShowingCachedSnapshot = false
                if reset {
                    for result in loadedResults {
                        if let refsToken = result.refsToken {
                            savePersistedLogCache(
                                PersistedLogCacheEntry(
                                    rootPath: result.rootPath,
                                    queryFingerprint: result.queryFingerprint,
                                    refsToken: refsToken,
                                    commits: result.commits
                                )
                            )
                            let rootCommits = deduplicated.filter {
                                ($0.repositoryPath ?? "") == result.rootPath
                            }
                            savePersistedLogGraph(
                                PersistedLogGraphEntry(
                                    rootPath: result.rootPath,
                                    queryFingerprint: result.graphQueryFingerprint,
                                    refsToken: refsToken,
                                    commits: rootCommits,
                                    cursor: result.cursor,
                                    hasMore: result.hasMore
                                )
                            )
                        }
                    }
                } else {
                    for result in loadedResults {
                        if let refsToken = result.refsToken {
                            let rootCommits = deduplicated.filter {
                                ($0.repositoryPath ?? "") == result.rootPath
                            }
                            savePersistedLogGraph(
                                PersistedLogGraphEntry(
                                    rootPath: result.rootPath,
                                    queryFingerprint: result.graphQueryFingerprint,
                                    refsToken: refsToken,
                                    commits: rootCommits,
                                    cursor: result.cursor,
                                    hasMore: result.hasMore
                                )
                            )
                        }
                    }
                }
                self.logList.error = nil
                self.refreshCherryPickedHighlights()
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.logList.generation,
                      self.externalLogTabIsAlive(tabID),
                      !(self.externalLogWindow && self.externalLogSessionDisposed),
                      self.logRuntime.aggregateBranchFilters == filters,
                      self.logRuntime.aggregateRevisionRanges == revisionRanges,
                      self.logRuntime.aggregateRootPaths == aggregateRootPaths,
                      self.logList.visibleRootPathsRaw == visibleRootPathsRaw,
                      self.logVisibleRootPathsPersistedRaw == visibleRootPathsPersistedRaw else { return }
                self.logList.error = self.logList.isShowingCachedSnapshot
                    ? "Refresh failed; showing cached history. \(errorMessage(error))"
                    : errorMessage(error)
                self.logList.isLoadingMore = false
                if reset { self.logList.isLoading = false }
            }
        }
    }
    logList.loadTask = task
}

func isActiveLogRepository(_ candidate: Repository) -> Bool {
    if let activeRepo = logList.activeRepo {
        return logList.activeRepo === candidate
    }
    return projectRepo === candidate
}

/// Aggregate VCS Log rows carry their owning Git root. A secondary root is
/// active even though it is not `logList.activeRepo`; use the aggregate repository
/// map for navigation and stale-result checks in that mode.
func isActiveLogNavigationRepository(
    _ candidate: Repository,
    rootPath: String?
) -> Bool {
    guard isLogRootQualified, let rootPath, !rootPath.isEmpty else {
        return isActiveLogRepository(candidate)
    }
    return logRuntime.aggregateRepositories[rootPath] === candidate
}

/// Reflog uses the same multi-commit Changes browser as the main Log. A
/// reflog row points at an object rather than carrying a full CommitInfo, so
/// resolve the selected object IDs together and preserve the visible Reflog
/// order while loading them off the main actor.
func loadReflogCommitDetails() {
    reflog.detailLoadTask?.cancel()
    reflog.detailLoadTask = nil
    reflog.detailCommit = nil
    reflog.detailCommits = []
    guard let repo = reflogRepository, !reflog.selectedIDs.isEmpty else { return }

    let expectedSelection = reflog.selectedIDs
    let expectedEntryIDs = selectedReflogEntries.map(reflogEntryIdentifier)
    let commitIDs = orderedUniqueReflogCommitIDs(selectedReflogEntries)
    let tabID = currentLogTabID
    guard !commitIDs.isEmpty else { return }

    let task = Task.detached(priority: .userInitiated) {
        var commits: [CommitInfo] = []
        for id in commitIDs {
            guard !Task.isCancelled else { return }
            guard let candidates = try? repo.logFiltered(
                path: nil,
                limit: 1,
                follow: false,
                startRev: id,
                author: nil,
                since: nil
            ), let commit = candidates.first(where: {
                $0.id == id || $0.id.hasPrefix(id) || id.hasPrefix($0.id)
            }) else { continue }
            commits.append(commit)
        }
        guard !Task.isCancelled else { return }
        let loadedCommits = commits
        await MainActor.run {
            guard self.externalLogTabIsAlive(tabID),
                  self.isActiveLogRepository(repo),
                  self.reflog.selectedIDs == expectedSelection,
                  self.selectedReflogEntries.map(reflogEntryIdentifier) == expectedEntryIDs else { return }
            self.reflog.detailCommits = loadedCommits
        }
    }
    reflog.detailLoadTask = task
}

func loadMoreLog() {
    if logList.viewMode == .command {
        guard logRuntime.hasMoreCommand else { return }
        runLogCommand(reset: false)
        return
    }
    guard !logList.isLoadingMore, logList.hasMore else { return }
    guard logList.pageCursor != nil else { return }
    loadLog(reset: false)
}

func selectLogRevision(_ id: String) {
    let visibleEntries = logList.viewMode == .command ? logRuntime.commandEntries : logList.entries
    if let visible = visibleEntries.first(where: {
        let identity = logCommitIdentity($0)
        return identity == id || identity.hasPrefix(id) || id.hasPrefix(identity)
    }) {
        let identity = logCommitIdentity(visible)
        logSelectionState.selection = identity
        logSelectionState.selectedIDs = [identity]
        return
    }

    let parts = id.split(separator: "\u{1f}", maxSplits: 1)
    let repositoryPath = parts.count == 2 ? String(parts[0]) : nil
    let revision = parts.last.map(String.init) ?? id
    let revisionRepo = repositoryPath.flatMap { logRuntime.aggregateRepositories[$0] }
        ?? repositoryPath.flatMap { try? openRepository(path: $0) }
        ?? logRepository
    guard let repo = revisionRepo else { return }
    let expectedGeneration = logList.generation
    Task.detached(priority: .userInitiated) {
        guard let commit = try? repo.logFiltered(
            path: nil,
            limit: 1,
            follow: false,
            startRev: revision,
            author: nil,
            since: nil
        ).first else { return }
        await MainActor.run {
            guard self.isActiveLogNavigationRepository(repo, rootPath: repositoryPath),
                  self.logList.generation == expectedGeneration else { return }
            if self.logList.viewMode == .command {
                if !self.logRuntime.commandEntries.contains(where: { $0.id == commit.id }) {
                    self.logRuntime.commandEntries.insert(commit, at: 0)
                }
            } else if !self.logList.entries.contains(where: { $0.id == commit.id }) {
                self.logList.entries.insert(commit, at: 0)
            }
            let identity = self.logCommitIdentity(commit)
            self.logSelectionState.selection = identity
            self.logSelectionState.selectedIDs = [identity]
        }
    }
}

func copySelectedLogIDs() {
    let ids = logList.entries
        .filter { logSelectionState.selectedIDs.contains(logCommitIdentity($0)) }
        .map(\.id)
    guard !ids.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(formattedRevisionIDsForClipboard(ids), forType: .string)
    feedbackCenter.success("Copied revisions", detail: "\(ids.count) commit ID(s)")
}

/// IntelliJ's `Show.Current.Revision` displays the metadata for the latest
/// committed revision that owns the selected file. Resolve the owning Git
/// root before querying history so nested repositories cannot use the parent
/// repository's revision.
func showCurrentRevision(path: String) {
    guard let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          normalizedRepositoryRelativePath(path) != nil else {
        feedbackCenter.error(
            "Current revision unavailable",
            detail: "The selected project-tree path is not a safe repository-relative path.",
            nextStep: "Refresh the project tree, then try again."
        )
        return
    }

    let cachedRoots = multiRoots
    Task.detached(priority: .userInitiated) {
        let roots = cachedRoots.isEmpty
            ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
            : cachedRoots
        guard let target = fileReferenceComparisonTarget(
            path: path,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Current revision unavailable",
                    detail: "The selected file is outside the discovered Git roots.",
                    nextStep: "Refresh the project roots, then retry."
                )
            }
            return
        }

        do {
            let targetRepo: Repository
            if canonicalExternalLogPath(primaryRootPath) == target.rootPath {
                targetRepo = primaryRepo
            } else {
                targetRepo = try openRepository(path: target.rootPath)
            }
            guard let commit = try targetRepo.logWithCommand(
                commandArgs: [
                    "--all",
                    "--follow",
                    "-n1",
                    "--",
                    target.relativePath
                ],
                limit: 1
            ).first else {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Current revision unavailable",
                        detail: "No committed revision was found for \(target.relativePath).",
                        nextStep: "Only tracked files with committed history can show a current revision."
                    )
                }
                return
            }
            await MainActor.run {
                guard let currentRootPath = self.repo?.workdir(),
                      canonicalExternalLogPath(currentRootPath)
                          == canonicalExternalLogPath(primaryRootPath) else {
                    return
                }
                self.currentRevisionRequest = CurrentRevisionRequest(
                    repo: targetRepo,
                    path: target.relativePath,
                    commit: commit
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to load current revision",
                    detail: "\(target.rootPath)\n\(errorMessage(error))",
                    nextStep: "Check the repository state, then retry."
                )
            }
        }
    }
}

func parseLogSince(_ value: String) -> Int64? {
    parseLogDate(value)
}

func parseLogUntil(_ value: String) -> Int64? {
    parseLogDate(value)
}

/// LOG-004：在本地只读仓库浏览器中打开提交对应的树。
func browseRevisionFromLog(_ commit: CommitInfo) {
    guard logRepository(for: commit) != nil else {
        feedbackCenter.error(
            "Browse revision unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }
    revisionBrowserPath = nil
    revisionBrowserCommit = commit
    showRevisionBrowser = true
}

/// Open the selected file directly in the read-only revision browser.
func browseFileRevisionFromLog(_ commit: CommitInfo, path: String) {
    guard logRepository(for: commit) != nil else {
        feedbackCenter.error(
            "Browse revision unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }
    revisionBrowserPath = path
    revisionBrowserCommit = commit
    showRevisionBrowser = true
}

/// Map IntelliJ's `Vcs.EditSource` to the macOS default application for the
/// current worktree file. Arbor is not an IDE, so this deliberately delegates
/// editing to the user's system file association rather than embedding one.
func editSourceFromLog(_ path: String) {
    guard let repo = logRepository, let workdir = repo.workdir() else {
        feedbackCenter.error(
            "Edit source unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }

    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty, !components.contains("..") else {
        feedbackCenter.error(
            "Edit source unavailable",
            detail: "The selected path is not a repository-relative file.",
            nextStep: "Refresh the Changes browser and retry."
        )
        return
    }
    let fileURL = root
        .appendingPathComponent(components.joined(separator: "/"))
        .standardizedFileURL
    guard fileURL.path == root.path || fileURL.path.hasPrefix(root.path + "/") else {
        feedbackCenter.error(
            "Edit source unavailable",
            detail: "The selected path is outside the repository.",
            nextStep: "Refresh the Changes browser and retry."
        )
        return
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL.deletingLastPathComponent()])
        feedbackCenter.warning(
            "Source file unavailable",
            detail: "\(path) is not present in the current worktree.",
            nextStep: "Use Show File at Revision to inspect the historical copy."
        )
        return
    }

    guard NSWorkspace.shared.open(fileURL) else {
        feedbackCenter.error(
            "Open source failed",
            detail: "macOS could not open \(path) with its default application.",
            nextStep: "Choose an application for this file type in Finder."
        )
        return
    }
}

/// LOG-005：复制与 Log 提交对应的远程仓库链接。
func copyRevisionLinkFromLog(_ commit: CommitInfo, remote: RemoteInfo) {
    guard let repo = logRepository(for: commit) else {
        feedbackCenter.error(
            "Copy repository link unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    Task.detached(priority: .userInitiated) {
        let link = repo.permalink(remoteUrl: remote.url, commitId: commit.id)
        await MainActor.run {
            guard let link else {
                self.feedbackCenter.error(
                    "Copy repository link unavailable",
                    detail: "The remote does not expose a repository permalink.",
                    nextStep: "Use Copy Commit ID instead."
                )
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            self.feedbackCenter.success("Repository link copied", detail: link)
        }
    }
}

/// LOG-005：在所选 hosted remote 打开提交 permalink。
func browseHostedRevisionFromLog(_ commit: CommitInfo, remote: RemoteInfo) {
    guard let repo = logRepository(for: commit) else {
        feedbackCenter.error(
            "Browse commit in browser unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    Task.detached(priority: .userInitiated) {
        let link = repo.permalink(remoteUrl: remote.url, commitId: commit.id)
        await MainActor.run {
            guard let link, let url = URL(string: link) else {
                self.feedbackCenter.error(
                    "Browse commit in browser unavailable",
                    detail: "The selected remote does not expose a commit permalink.",
                    nextStep: "Choose another hosted remote or use Copy Commit ID."
                )
                return
            }
            guard NSWorkspace.shared.open(url) else {
                self.feedbackCenter.error(
                    "Browse commit in browser failed",
                    detail: link,
                    nextStep: "Copy the repository link and open it manually."
                )
                return
            }
        }
    }
}

/// LOG-006：Changes Browser / File History 的文件级托管链接。
/// IntelliJ 的 Git.Hosting actions 在文件 revision 上同样可用；这里使用
/// commit.repositoryPath 解析出的 root，避免多仓库项目把文件链接发到错误 remote。
func browseHostedFileRevisionFromLog(_ record: LogChangeRecord, remote: RemoteInfo) {
    guard let repo = logRepository(for: record.commit) else {
        feedbackCenter.error(
            "Browse file in browser unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    let target = hostedFileRevisionTarget(for: record)
    Task.detached(priority: .userInitiated) {
        let link = hostedFileRevisionLink(
            repository: repo,
            remoteURL: remote.url,
            commitID: target.commitID,
            path: target.path
        )
        await MainActor.run {
            guard let link, let url = URL(string: link) else {
                self.feedbackCenter.error(
                    "Browse file in browser unavailable",
                    detail: "The selected root has no supported hosting remote.",
                    nextStep: "Configure a GitHub, GitLab, or Bitbucket remote."
                )
                return
            }
            guard NSWorkspace.shared.open(url) else {
                self.feedbackCenter.error(
                    "Browse file in browser failed",
                    detail: link,
                    nextStep: "Open the copied link manually."
                )
                return
            }
        }
    }
}

/// LOG-007：复制 Changes Browser / File History 的文件级托管链接。
func copyHostedFileRevisionFromLog(_ record: LogChangeRecord, remote: RemoteInfo) {
    guard let repo = logRepository(for: record.commit) else {
        feedbackCenter.error(
            "Copy file link unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    let target = hostedFileRevisionTarget(for: record)
    Task.detached(priority: .userInitiated) {
        let link = hostedFileRevisionLink(
            repository: repo,
            remoteURL: remote.url,
            commitID: target.commitID,
            path: target.path
        )
        await MainActor.run {
            guard let link else {
                self.feedbackCenter.error(
                    "Copy file link unavailable",
                    detail: "The selected root has no supported hosting remote.",
                    nextStep: "Configure a GitHub, GitLab, or Bitbucket remote."
                )
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            self.feedbackCenter.success("File link copied", detail: link)
        }
    }
}

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
    alert.messageText = "Drop selected changes?"
    alert.informativeText = "The selected files will be removed from \(commit.shortId) and the rewritten history will replace the current branch tip."
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
                self.commitFeedback = "已从 \(commit.shortId) 丢弃 \(paths.count) 个文件变更"
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
    alert.messageText = "Extract selected changes"
    alert.informativeText = "The selected files will become a new commit after \(commit.shortId)."
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
                self.commitFeedback = "已将 \(paths.count) 个文件变更抽取为新提交"
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
    resetTargetCommits = commits
    resetTargetCommit = first
    resetMode = GitResetModeSettings.mode(for: projectPath).engineValue
    showResetDialog = true
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
        let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
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
                        self.operationFeedback = "Root reword cancelled; saved local changes were restored"
                        self.feedbackCenter.warning(
                            "Root reword cancelled",
                            detail: self.operationFeedback ?? "Saved local changes were restored",
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
        projectPath: projectPath,
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
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
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

func openFileHistoryTab(path: String, startRevision: String, rootPath: String?) {
    let tab = makeFileHistoryLogTab(
        path: path,
        startRevision: startRevision,
        rootPath: rootPath
    )
    saveCurrentLogTab()
    if let existing = logSelectionState.tabs.first(where: {
        $0.historyPath == tab.historyPath
            && $0.rootPath == tab.rootPath
            && $0.startRevision == tab.startRevision
            && $0.startRevisions == tab.startRevisions
            && $0.pathFilter == tab.pathFilter
            && $0.pathSelections == tab.pathSelections
            && $0.follow
    }) {
        if existing.id == currentLogTabID {
            applyLogTab(existing)
            loadLog()
        } else {
            switchLogTab(existing.id)
        }
        return
    }
    appendLogTabAndLoad(tab)
}

/// HISTORY-001：File History 入口——打开独立 Log tab 并按路径过滤（follow renames）。
func showFileHistory(_ path: String, rootPath: String? = nil) {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPath.isEmpty else { return }
    let historyRootPath = resolvedFileHistoryRootPath(
        preferredRootPath: rootPath,
        selectedCommitRootPath: selectedCommit?.repositoryPath,
        activeLogRootPath: logList.activeRootPath,
        repositoryRootPath: repo?.workdir()
    )
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    toolWindowMode = .log
    toolWindowExpanded = true
    // File History is a Log editor hand-off. The left workspace must return
    // to Commit/Stash immediately instead of leaving the Project tool window
    // expanded over the staging surface.
    projectPanelExpanded = false
    selection = nil
    fileSelection = nil
    selectionModePath = nil
    commitPreviewPath = nil
    commitPreviewVisible = false
    openFileHistoryTab(path: normalizedPath, startRevision: "HEAD", rootPath: historyRootPath)
}

/// Vcs.ShowHistoryForRevision: open the file history rooted at the selected
/// revision instead of silently starting from the current branch tip.
func showFileHistoryForRevision(_ commit: CommitInfo, _ path: String) {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPath.isEmpty else { return }
    let historyRootPath = commit.repositoryPath
        ?? logList.activeRootPath
        ?? repo?.workdir()
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    toolWindowMode = .log
    toolWindowExpanded = true
    projectPanelExpanded = false
    selection = nil
    fileSelection = nil
    selectionModePath = nil
    commitPreviewPath = nil
    commitPreviewVisible = false
    openFileHistoryTab(
        path: normalizedPath,
        startRevision: commit.id,
        rootPath: historyRootPath
    )
}

/// Change the root scope of an external Git Log window. Root selection is a
/// query scope, so changing it deliberately clears branch/range filters from
/// another Log action instead of silently combining incompatible scopes.
func setExternalLogRootSelection(_ rootPath: String, selected: Bool) {
    guard externalLogWindow else { return }
    let normalizedPath = canonicalExternalLogPath(rootPath)
    var next = logRuntime.aggregateRootPaths
    if selected {
        next.insert(normalizedPath)
    } else {
        guard next.count > 1 else { return }
        next.remove(normalizedPath)
    }
    applyExternalLogRootSelection(next)
}

func selectAllExternalLogRoots() {
    applyExternalLogRootSelection(Set(multiRoots.map(\.path)))
}

func selectPrimaryExternalLogRoot() {
    guard let primaryPath = repo?.workdir() ?? projectPath else { return }
    let normalizedPrimaryPath = canonicalExternalLogPath(primaryPath)
    guard multiRoots.contains(where: {
        canonicalExternalLogPath($0.path) == normalizedPrimaryPath
    }) else { return }
    applyExternalLogRootSelection([normalizedPrimaryPath])
}

/// Update Project's View Commits action needs the exact before/after tip for
/// each root that actually advanced. Keep this derived in Swift so the
/// existing RootOperationResult UniFFI record remains source-compatible for
/// every other multi-root operation.
nonisolated static func updateSessionRevisionRanges(
    previousHeads: [String: String],
    currentHeads: [String: String],
    results: [RootOperationResult]
) -> [PersistedLogRevisionRange] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    var previousByRoot: [String: String] = [:]
    for (path, head) in previousHeads {
        previousByRoot[normalizedPath(path)] = head
    }
    var currentByRoot: [String: String] = [:]
    for (path, head) in currentHeads {
        currentByRoot[normalizedPath(path)] = head
    }

    return results
        .filter { $0.success && !$0.skipped }
        .compactMap { result in
            let rootPath = normalizedPath(result.rootPath)
            guard let oldRevision = previousByRoot[rootPath],
                  let newRevision = currentByRoot[rootPath],
                  !oldRevision.isEmpty,
                  !newRevision.isEmpty,
                  oldRevision != newRevision else {
                return nil
            }
            return PersistedLogRevisionRange(
                rootPath: rootPath,
                oldRevision: oldRevision,
                newRevision: newRevision
            )
        }
        .sorted { $0.rootPath < $1.rootPath }
}

/// IntelliJ joins ranges when a rejected Push recovery performs more than one
/// Update before the next Push attempt. Keep the first pre-update boundary and
/// advance only the latest post-update tip for each normalized Git root.
nonisolated static func joinedRevisionRanges(
    existing: [PersistedLogRevisionRange],
    latest: [PersistedLogRevisionRange]
) -> [PersistedLogRevisionRange] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    var rangesByRoot: [String: PersistedLogRevisionRange] = [:]
    for range in existing {
        let rootPath = normalizedPath(range.rootPath)
        rangesByRoot[rootPath] = PersistedLogRevisionRange(
            rootPath: rootPath,
            oldRevision: range.oldRevision,
            newRevision: range.newRevision
        )
    }
    for range in latest {
        let rootPath = normalizedPath(range.rootPath)
        if let previous = rangesByRoot[rootPath] {
            rangesByRoot[rootPath] = PersistedLogRevisionRange(
                rootPath: rootPath,
                oldRevision: previous.oldRevision,
                newRevision: range.newRevision
            )
        } else {
            rangesByRoot[rootPath] = PersistedLogRevisionRange(
                rootPath: rootPath,
                oldRevision: range.oldRevision,
                newRevision: range.newRevision
            )
        }
    }
    return rangesByRoot.values.sorted { $0.rootPath < $1.rootPath }
}

/// IntelliJ's Update Project dialog exposes RESET as a one-shot action rather
/// than as a persisted update method. Keep the same boundary here: only a
/// single checked-out branch with a configured upstream can use it.
func beginHeadResetDialog() {
    guard isArborVCSActionEnabled(.reset, in: vcsActionContext) else { return }
    let roots = resetHeadRootOptions
    guard !roots.isEmpty else { return }
    let defaultRootPath = repo?.workdir() ?? roots[0].path
    headResetRootPath = roots.first(where: {
        canonicalExternalLogPath($0.path) == canonicalExternalLogPath(defaultRootPath)
    })?.path ?? roots[0].path
    headResetTarget = "HEAD"
    let savedMode = GitResetModeSettings.mode(for: projectPath).engineValue
    headResetMode = savedMode == .keep ? .mixed : savedMode
    showHeadResetDialog = true
}

func smartCheckoutRevisionInRoot(rootPath: String, revision: String) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Smart Checkout", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.smartCheckoutDetachedWithPolicyAndCancel(
                commitId: revision,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.feedbackCenter.success("Smart Checkout completed", detail: "\(revision) · \(rootPath)")
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Smart Checkout cancelled",
                        detail: "\(revision) · \(rootPath)",
                        nextStep: "The preservation Shelf was kept when restore had started; retry after reviewing the root."
                    )
                } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    let viewAction = stashID.flatMap {
                        self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: $0,
                            rootPath: rootPath
                        )
                    }
                    var stashIndex = 0
                    if let stashID,
                       let rootRepo = try? openRepository(path: rootPath),
                       let index = try? rootRepo.stashList().firstIndex(where: { $0.id == stashID }) {
                        stashIndex = index
                    }
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: stashIndex,
                        stashID: stashID,
                        isPop: true,
                        paths: paths,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: .shelf,
                        identifier: name,
                        rootPath: rootPath
                    )
                    self.presentMultiRootShelveConflict(
                        rootPath: rootPath,
                        name: name,
                        paths: paths,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                } else {
                    self.feedbackCenter.error(
                        "Smart Checkout failed",
                        detail: "\(revision) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Resolve the root-specific restore conflict, then retry."
                    )
                }
            }
        }
    }
}

func forceCheckoutRevisionInRoot(rootPath: String, revision: String) {
    beginFeedbackOperation("Force Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.forceCheckoutDetached(commitId: revision)
            await MainActor.run {
                self.feedbackCenter.success("Force Checkout completed", detail: "\(revision) · \(rootPath)")
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Force Checkout failed", detail: "\(revision) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

}
