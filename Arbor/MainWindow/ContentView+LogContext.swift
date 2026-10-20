import SwiftUI
import AppKit

extension ContentView {

    var logRepository: Repository? {
        if let selectedCommit,
           let selectedRepository = logRepository(for: selectedCommit) {
            return selectedRepository
        }
        if isLogRootQualified {
            return nil
        }
        if logList.activeRootPath != nil {
            return logList.activeRepo
        }
        return logList.activeRepo ?? repo
    }

    var isLogAggregate: Bool {
        !logRuntime.aggregateBranchFilters.isEmpty
            || !logRuntime.aggregateRevisionRanges.isEmpty
            || !logRuntime.aggregateRootPaths.isEmpty
    }

    var isLogRootQualified: Bool {
        isLogAggregate || (logList.viewMode == .command && logRuntime.commandIsAggregate)
    }

    var availableReflogRootPaths: [String] {
        var paths: [String] = []
        if let primary = repo?.workdir(), !primary.isEmpty {
            paths.append(primary)
        }
        paths.append(contentsOf: multiRootWorkspace.roots.map(\.path))
        if let active = logList.activeRootPath, !active.isEmpty {
            paths.append(active)
        }
        return Array(Set(paths)).sorted()
    }

    var reflogRootTitle: String {
        guard let path = reflog.rootPath, !path.isEmpty else { return "Repository" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var reflogRepository: Repository? {
        reflog.rootRepo ?? (isLogAggregate ? nil : logRepository)
    }

    /// Graph selection is root-qualified only for an aggregate multi-root
    /// Log. Single-root behavior keeps the existing short-id-compatible
    /// selection model, while aggregate history cannot safely use a raw hash.
    func logCommitIdentity(_ commit: CommitInfo) -> String {
        logCommitIdentity(repositoryPath: commit.repositoryPath, id: commit.id)
    }

    func logCommitIdentity(repositoryPath: String?, id: String) -> String {
        logCommitDisplayIdentity(
            repositoryPath: repositoryPath,
            id: id,
            aggregate: isLogRootQualified
        )
    }

    func logRepository(for commit: CommitInfo) -> Repository? {
        guard let repositoryPath = commit.repositoryPath,
              !repositoryPath.isEmpty else {
            return logList.activeRepo ?? repo
        }
        if let aggregateRepository = logRuntime.aggregateRepositories[repositoryPath] {
            return aggregateRepository
        }
        if logList.activeRootPath == repositoryPath {
            return logList.activeRepo
        }
        if repo?.workdir() == repositoryPath {
            return repo
        }
        return try? openRepository(path: repositoryPath)
    }

    /// Mirrors IntelliJ's HostedGitRepositoryReference action group: only
    /// remotes that can produce a commit web reference participate, and the
    /// selected commit's repository path decides which root owns the remote.
    func hostedRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        guard let repository = logRepository(for: commit) else { return [] }
        return logRemotes(for: commit).filter { remote in
            repository.permalink(remoteUrl: remote.url, commitId: commit.id) != nil
        }
    }

    /// The Log "Open Pull Requests" action is a hosted reference action too,
    /// but it targets the provider's PR list rather than a commit permalink.
    /// Keep its remote candidates root-qualified and filter unsupported hosts.
    func pullRequestRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        return logRemotes(for: commit).filter { remote in
            HostingProvider.parse(remoteURL: remote.url) != nil
        }
    }

    func commentRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        pullRequestRemotesForCommit(commit)
    }

    func logRepository(for commits: [CommitInfo]) -> Repository? {
        guard let first = commits.first else { return nil }
        guard logCommitSelectionRepositoryPath(commits) != nil else { return nil }
        return logRepository(for: first)
    }

    func currentLogBranchName(for commit: CommitInfo) -> String? {
        // Context menus are built for every visible Log row. Reading the
        // current branch from Repository here performs a synchronous Git
        // operation during SwiftUI layout and can block the main thread while
        // the history task owns the repository mutex. Branch snapshots are
        // already kept in view state, so use them instead.
        if let repositoryPath = commit.repositoryPath,
           !repositoryPath.isEmpty {
            if let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
                $0.rootPath == repositoryPath
            }) {
                return snapshot.branches.first(where: \.isCurrent)?.name
            }
            if repositoryPath == logList.activeRootPath {
                return logRuntime.activeBranches.first(where: \.isCurrent)?.name
            }
            return nil
        }
        return activeLogBranches.first(where: \.isCurrent)?.name
    }

    func logRemotes(for commit: CommitInfo) -> [RemoteInfo] {
        if let repositoryPath = commit.repositoryPath,
           !repositoryPath.isEmpty {
            if let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
                $0.rootPath == repositoryPath
            }) {
                return snapshot.remotes
            }
            if repositoryPath == logList.activeRootPath {
                return logRuntime.activeRemotes
            }
            return []
        }
        return activeLogRemotes
    }

    var activeLogBranches: [BranchInfo] {
        logList.activeRootPath == nil ? branchWorkspace.branches : logRuntime.activeBranches
    }

    var activeLogRemoteBranches: [RemoteBranchInfo] {
        logList.activeRootPath == nil ? branchWorkspace.remoteBranches : logRuntime.activeRemoteBranches
    }

    var activeLogRemotes: [RemoteInfo] {
        logList.activeRootPath == nil ? remoteWorkspace.remotes : logRuntime.activeRemotes
    }
    var selectedCommit: CommitInfo? {
        guard let selectedID = logSelectionState.selection else { return nil }
        let visibleEntries = logList.viewMode == .command ? logRuntime.commandEntries : logList.entries
        return visibleEntries.first {
            let identity = logCommitIdentity($0)
            return identity == selectedID
                || identity.hasPrefix(selectedID)
                || selectedID.hasPrefix(identity)
        }
            ?? (logSelectionState.detailCommit.map {
                let identity = logCommitIdentity($0)
                return identity == selectedID
                    || identity.hasPrefix(selectedID)
                    || selectedID.hasPrefix(identity) ? $0 : nil
            } ?? nil)
    }
    var selectedTreeChange: TreeChange? {
        guard let compareSelection = comparisonWorkspace.selection else { return nil }
        return comparisonWorkspace.treeChanges.first { $0.path == compareSelection }
    }
    var selectedTreeChanges: [TreeChange] {
        orderedCompareSelection(changes: comparisonWorkspace.treeChanges, selectedPaths: comparisonWorkspace.selectedPaths)
    }
    var selectedReflogEntry: ReflogEntry? {
        guard let selection = reflog.selection else { return nil }
        return reflog.entries.first { reflogEntryIdentifier($0) == reflog.selection }
    }
    var selectedReflogEntries: [ReflogEntry] {
        orderedReflogSelection(entries: reflog.entries, selectedIDs: reflog.selectedIDs)
    }
    var selectedReflogCommits: [CommitInfo] {
        if !reflog.detailCommits.isEmpty {
            return reflog.detailCommits
        }
        var seen = Set<String>()
        return selectedReflogEntries.compactMap { entry in
            guard let commit = logList.entries.first(where: {
                $0.id == entry.newId || $0.id.hasPrefix(entry.newId) || entry.newId.hasPrefix($0.id)
            }), seen.insert(commit.id).inserted else { return nil }
            return commit
        }
    }
    var selectedReflogCommit: CommitInfo? {
        selectedReflogCommits.first
    }

    func reflogCommit(for entry: ReflogEntry) -> CommitInfo? {
        let matches: (CommitInfo) -> Bool = { commit in
            commit.id == entry.newId
                || commit.id.hasPrefix(entry.newId)
                || entry.newId.hasPrefix(commit.id)
        }
        return reflog.detailCommits.first(where: matches)
            ?? reflog.detailCommit.flatMap { matches($0) ? $0 : nil }
            ?? logList.entries.first(where: matches)
    }
}
