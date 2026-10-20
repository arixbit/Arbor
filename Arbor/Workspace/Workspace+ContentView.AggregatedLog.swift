import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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
                          !(self.externalLogWindow && self.logRuntime.externalSessionDisposed),
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
                      !(self.externalLogWindow && self.logRuntime.externalSessionDisposed),
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
                      !(self.externalLogWindow && self.logRuntime.externalSessionDisposed),
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

}
