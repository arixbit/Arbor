import CoreServices
import SwiftUI


/// IntelliJ's incoming-change strategies run against every configured remote
/// for every Git root. FETCH refreshes local remote-tracking refs; LS_REMOTE
/// only checks the live remote and reports branches whose cached tracking ref
/// is stale. Transport failures still reach the common feedback surface.
func groupedAutoFetchValues(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
}

func normalizedGitRootPath(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    return URL(fileURLWithPath: path).standardizedFileURL.path
}

/// A root-qualified incoming branch is the SwiftUI equivalent of IntelliJ's
/// cached `GitBranchIncomingOutgoingManager` state. Keep the remote identity
/// separate from its display value so roots and remotes with similarly named
/// branches never get merged accidentally.
struct GitIncomingBranch: Hashable, Sendable {
    let rootPath: String
    let remote: String
    let branch: String

    init(rootPath: String, remote: String, branch: String) {
        self.rootPath = normalizedGitRootPath(rootPath)
        self.remote = remote
        self.branch = branch
    }

    var remoteBranch: String {
        "\(remote)/\(branch)"
    }

    var displayValue: String {
        "\(rootPath) · \(remoteBranch)"
    }
}

struct GitIncomingRemote: Hashable, Sendable {
    let rootPath: String
    let remote: String

    init(rootPath: String, remote: String) {
        self.rootPath = normalizedGitRootPath(rootPath)
        self.remote = remote
    }
}

/// Incoming state is a per-remote snapshot. Failed or contended remotes are
/// deliberately absent from `checkedRemotes`, so applying this result cannot
/// erase state that was not actually refreshed during this cycle.
struct GitIncomingBranchesSnapshot: Sendable {
    let branches: [GitIncomingBranch]
    let configuredRoots: Set<String>
    let configuredRemotes: Set<GitIncomingRemote>
    let checkedRemotes: Set<GitIncomingRemote>

    init(
        branches: [GitIncomingBranch],
        configuredRoots: Set<String> = [],
        configuredRemotes: Set<GitIncomingRemote> = [],
        checkedRemotes: Set<GitIncomingRemote> = []
    ) {
        self.branches = groupedAutoFetchIncomingBranches(branches)
        self.configuredRoots = Set(configuredRoots.map(normalizedGitRootPath))
        self.configuredRemotes = Set(configuredRemotes.map {
            GitIncomingRemote(rootPath: $0.rootPath, remote: $0.remote)
        })
        self.checkedRemotes = Set(checkedRemotes.map {
            GitIncomingRemote(rootPath: $0.rootPath, remote: $0.remote)
        })
    }
}

func groupedAutoFetchIncomingBranches(_ values: [GitIncomingBranch]) -> [GitIncomingBranch] {
    Array(Set(values)).sorted {
        if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
        if $0.remote != $1.remote { return $0.remote < $1.remote }
        return $0.branch < $1.branch
    }
}

func hasUnfetchedIncomingBranch(
    rootPath: String?,
    branch: String,
    in values: Set<GitIncomingBranch>
) -> Bool {
    let normalizedRoot = normalizedGitRootPath(rootPath ?? "")
    return values.contains {
        $0.rootPath == normalizedRoot && $0.branch == branch
    }
}

func hasUnfetchedIncomingRemoteBranch(
    rootPath: String?,
    remote: String,
    branch: String,
    in values: Set<GitIncomingBranch>
) -> Bool {
    let normalizedRoot = normalizedGitRootPath(rootPath ?? "")
    return values.contains {
        $0.rootPath == normalizedRoot && $0.remote == remote && $0.branch == branch
    }
}

func applyingAutoFetchIncomingSnapshot(
    _ snapshot: GitIncomingBranchesSnapshot,
    to existing: Set<GitIncomingBranch>
) -> Set<GitIncomingBranch> {
    var result = existing.filter { branch in
        guard snapshot.configuredRoots.contains(branch.rootPath) else { return true }
        let remote = GitIncomingRemote(rootPath: branch.rootPath, remote: branch.remote)
        return snapshot.configuredRemotes.contains(remote)
            && !snapshot.checkedRemotes.contains(remote)
    }
    result.formUnion(snapshot.branches)
    return result
}

func autoFetchRemoteBranchIdentity(_ name: String) -> (remote: String, branch: String)? {
    guard let separator = name.firstIndex(of: "/") else { return nil }
    let remote = String(name[..<separator])
    let branchStart = name.index(after: separator)
    let branch = String(name[branchStart...])
    guard !remote.isEmpty, !branch.isEmpty else { return nil }
    return (remote, branch)
}

func mergedAutoFetchRootPaths(primary: String?, discovered: [String]) -> [String] {
    groupedAutoFetchValues([primary].compactMap { $0 } + discovered)
}
