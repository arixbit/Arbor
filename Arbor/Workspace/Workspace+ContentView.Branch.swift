import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func loadProjectProtectedBranchSettings(for projectPath: String?) {
    gitSettings.projectProtectedBranchPatterns = GitProtectedBranchRules.projectRawValue(for: projectPath)
    gitSettings.projectProtectedBranchSynchronize = GitProtectedBranchRules.projectSynchronizeValue(for: projectPath)
}

nonisolated static func branchNameForProtection(_ remoteBranch: RemoteBranchInfo) -> String {
    let prefix = "\(remoteBranch.remote)/"
    if remoteBranch.name.hasPrefix(prefix) {
        return String(remoteBranch.name.dropFirst(prefix.count))
    }
    return remoteBranch.name.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/")
}

/// Capture the symbolic HEAD identity alongside commit IDs so an Update
/// rollback cannot mutate a different branch that happens to share the same
/// commit tip. An empty value represents detached HEAD.
nonisolated static func headBranchNames(for rootPaths: [String]) -> [String: String] {
    var branches: [String: String] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
        let branch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""
        branches[rootPath] = branch
    }
    return branches
}

func multiRootCommonTrackingBranches(
    remoteBranch: String,
    snapshots: [GitRootBranchSnapshot],
    selectedRootPaths: Set<String>
) -> [String] {
    let selected = snapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.remoteBranches.contains { $0.name == remoteBranch }
    }
    guard let first = selected.first else { return [] }
    let initial = Set(
        first.syncStatuses
            .filter { $0.upstream == remoteBranch && $0.trackingExists }
            .map(\.branch)
    )
    let common = selected.dropFirst().reduce(initial) { current, snapshot in
        current.intersection(
            snapshot.syncStatuses
                .filter { $0.upstream == remoteBranch && $0.trackingExists }
                .map(\.branch)
        )
    }
    let currentBranches = Set(selected.compactMap(\.headBranch))
    return common.subtracting(currentBranches).sorted()
}
}
