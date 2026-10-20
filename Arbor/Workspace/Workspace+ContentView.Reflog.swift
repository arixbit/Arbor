import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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

}
