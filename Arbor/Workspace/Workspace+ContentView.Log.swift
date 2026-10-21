import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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
    let discoveredRootPaths = normalizedLogRootPaths(multiRootWorkspace.roots.map(\.path))
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
                      normalizedLogRootPaths(self.multiRootWorkspace.roots.map(\.path))
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
                      normalizedLogRootPaths(self.multiRootWorkspace.roots.map(\.path))
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

func isActiveLogRepository(_ candidate: Repository) -> Bool {
    if let activeRepo = logList.activeRepo {
        return activeRepo === candidate
    }
    return projectWorkspace.repository === candidate
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

func parseLogSince(_ value: String) -> Int64? {
    parseLogDate(value)
}

func parseLogUntil(_ value: String) -> Int64? {
    parseLogDate(value)
}

}
