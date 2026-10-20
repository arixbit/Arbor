import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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
    guard let projectPath = projectWorkspace.path else { return }
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
        projectWorkspace.toolWindowMode = .log
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
    projectWorkspace.toolWindowMode = .log
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

    let cachedRoots = multiRootWorkspace.roots
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
                self.fileWorkspace.currentRevisionRequest = CurrentRevisionRequest(
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

}
