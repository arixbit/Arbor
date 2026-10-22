import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Applies the multi-root Branches dashboard selection as one VCS Log query.
/// The root is part of every filter, so identically named branches in two
/// repositories remain independent while their histories are shown together.
func applyLogBranchFilters(_ filters: [LogRootBranchFilter]) {
    var seen = Set<LogRootBranchFilter>()
    let normalized = filters.filter { filter in
        let rootPath = filter.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = filter.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty, !branch.isEmpty else { return false }
        return seen.insert(LogRootBranchFilter(rootPath: rootPath, branch: branch)).inserted
    }
    guard !normalized.isEmpty else { return }
    logRuntime.aggregateBranchFilters = normalized
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logList.activeRootPath = nil
    logList.activeRepo = nil
    logRuntime.activeBranches = []
    logRuntime.activeRemoteBranches = []
    logRuntime.activeRemotes = []
    logList.startRevision = ""
    logList.startRevisions = []
    logSelectionState.selection = nil
    logSelectionState.selectedIDs = []
    logList.viewMode = .graph
    loadLog()
}

func applyLogTab(_ tab: LogTabDescriptor) {
    applyLogTabRootContext(tab.rootPath)
    logRuntime.aggregateBranchFilters = tab.aggregateBranchFilters ?? []
    logRuntime.aggregateRevisionRanges = (tab.aggregateRevisionRanges ?? tab.updateInfoRanges ?? [])
        .map(LogRootRevisionRange.init)
    if let aggregateRootPaths = tab.aggregateRootPaths {
        logRuntime.aggregateRootPaths = Set(normalizedLogRootPaths(aggregateRootPaths))
    } else if !externalLogWindow {
        logRuntime.aggregateRootPaths = []
    }
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logRuntime.aggregatePageCursors = [:]
    logList.viewMode = tab.viewMode
    let tabRevisions = tab.startRevisions.isEmpty
        ? (tab.startRevision.isEmpty ? [] : [tab.startRevision])
        : tab.startRevisions
    setLogStartRevisions(tabRevisions)
    logList.pathFilter = tab.pathFilter
    logList.pathFilterSelections = normalizedLogPathFilterSelections(tab.pathSelections)
    logList.visibleRootPathsRaw = tab.visibleRootPathsRaw
    logList.authorFilter = tab.authorFilter
    logList.messageFilter = tab.messageFilter
    logList.messageRegex = tab.messageRegex
    logList.messageMatchCase = tab.messageMatchCase
    logList.since = tab.sinceText
    logList.until = tab.untilText
    logRuntime.commandFilter = tab.commandFilter
    logRuntime.commandEntries = []
    logRuntime.hasMoreCommand = true
    logRuntime.commandError = nil
    logList.follow = tab.follow
    logRuntime.sortModeRaw = tab.graphSortModeRaw
    comparisonWorkspace.revision1 = tab.compareRevision1
    comparisonWorkspace.revision2 = tab.compareRevision2
    comparisonWorkspace.repositoryPath = tab.compareRepositoryPath
    comparisonWorkspace.withWorkingTree = tab.compareWithWorkingTree
    branchComparison.firstFilter = tab.compareFirstFilter ?? BranchComparisonFilter()
    branchComparison.secondFilter = tab.compareSecondFilter ?? BranchComparisonFilter()
    if let path = tab.compareRepositoryPath,
       let comparisonRepo = try? openRepository(path: path) {
        activateComparisonRepository(comparisonRepo, rootPath: path)
    } else {
        comparisonWorkspace.repository = nil
    }
    logList.entries = []
    logList.isShowingCachedSnapshot = false
    logSelectionState.selection = tab.selection
    logSelectionState.selectedIDs = tab.selectedIDs
    logList.pageCursor = nil
    reflog.entries = []
    let restoredReflogRoot = tab.reflogRootPath
        ?? (tab.viewMode == .reflog ? tab.rootPath : nil)
    reflog.rootPath = restoredReflogRoot.map(canonicalExternalLogPath)
    reflog.rootRepo = nil
    reflog.selection = tab.reflogSelection
    reflog.selectedIDs = Set(tab.reflogSelectedIDs ?? [])
    logSelectionState.detailCommit = nil
    reflog.detailCommit = nil
    reflog.detailCommits = []
    reflog.detailLoadTask?.cancel()
    reflog.detailLoadTask = nil
    logList.hasMore = true
}

func applyLogTabRootContext(_ rootPath: String?) {
    guard let rootPath,
          !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        clearLogActiveRootContext()
        return
    }
    let normalizedRootPath = canonicalExternalLogPath(rootPath)
    let primaryRootPath = repo?.workdir().map(canonicalExternalLogPath)
    if normalizedRootPath == primaryRootPath {
        clearLogActiveRootContext()
        return
    }
    logList.activeRootPath = normalizedRootPath
    guard let rootRepo = try? openRepository(path: normalizedRootPath) else {
        logList.activeRepo = nil
        logRuntime.activeBranches = []
        logRuntime.activeRemoteBranches = []
        logRuntime.activeRemotes = []
        return
    }
    logList.activeRepo = rootRepo
    logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
    logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
    logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
}

func applyLogPathsEditor() {
    logList.pathsEditorPresented = false
    let roots = logStructureFilterRootPaths + availableReflogRootPaths
    setLogPathFilterSelections(parseLogPathFilterEditorText(logList.pathsEditorText, roots: roots))
}

func applyLogPathsTreeChooser() {
    logList.pathsTreeChooserPresented = false
    setLogPathFilterSelections(Array(logList.pathsTreeChooserSelections))
}

func applyExternalLogRootSelection(_ requestedPaths: Set<String>) {
    guard externalLogWindow else { return }
    let availablePaths = normalizedLogRootPaths(multiRootWorkspace.roots.map(\.path))
    let next = reconciledExternalLogRootSelection(
        availableRoots: availablePaths,
        selectedRoots: requestedPaths,
        initialized: true
    )
    guard !next.isEmpty, next != logRuntime.aggregateRootPaths else { return }
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = next
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logSelectionState.selection = nil
    logSelectionState.selectedIDs = []
    logList.error = nil
    logList.viewMode = .graph
    loadLog()
}

}
