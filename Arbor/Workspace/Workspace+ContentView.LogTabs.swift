import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func externalLogTabIsAlive(_ tabID: UUID) -> Bool {
    guard externalLogWindow else { return true }
    guard !logRuntime.externalSessionDisposed else { return false }
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
    guard externalLogWindow, !logRuntime.externalSessionDisposed else { return }
    persistExternalLogTabs()
    logRuntime.externalSessionDisposed = true
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
    comparisonWorkspace.loadTask?.cancel()
    comparisonWorkspace.loadTask = nil
    cancelBranchComparisonTasks()
    logBranchesPanel.showMyTask?.cancel()
    logBranchesPanel.showMyTask = nil
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
    logList.generation &+= 1
    logRuntime.signatureGeneration &+= 1
    logRuntime.commandGeneration &+= 1
    reflog.generation &+= 1
    logRuntime.aggregateRepositories.removeAll()
    logList.activeRepo = nil
    reflog.rootRepo = nil
    comparisonWorkspace.repository = nil
    projectWorkspace.repository = nil
    multiRootWorkspace.roots = []
    multiRootWorkspace.branchSnapshots = []
    operationRecovery.multiRootConflictGroups = []
}

var currentLogTabID: UUID {
    logSelectionState.activeTabID ?? logSelectionState.tabs.first?.id ?? UUID()
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
        compareRevision1: comparisonWorkspace.revision1,
        compareRevision2: comparisonWorkspace.revision2,
        compareRepositoryPath: comparisonWorkspace.repositoryPath,
        compareWithWorkingTree: comparisonWorkspace.withWorkingTree,
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
    applyExternalLogRootSelection(Set(multiRootWorkspace.roots.map(\.path)))
}

func selectPrimaryExternalLogRoot() {
    guard let primaryPath = repo?.workdir() ?? projectWorkspace.path else { return }
    let normalizedPrimaryPath = canonicalExternalLogPath(primaryPath)
    guard multiRootWorkspace.roots.contains(where: {
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

}
