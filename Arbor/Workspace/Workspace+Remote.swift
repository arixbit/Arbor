import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Resolve a configured upstream such as `corp/release/2026` to the remote
/// and branch that GitUpdateSelectedBranchAction should fetch or pull. Prefer
/// the longest remote prefix so remote names containing separators remain
/// unambiguous.
func remoteBranchTargetForConfiguredUpstream(
    _ upstream: String,
    remotes: [RemoteInfo]
) -> (remote: String, branch: String)? {
    let normalized = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    return remotes
        .compactMap { remote -> (remote: String, branch: String, prefixLength: Int)? in
            let prefix = "\(remote.name)/"
            guard normalized.hasPrefix(prefix) else { return nil }
            let branch = String(normalized.dropFirst(prefix.count))
            guard !branch.isEmpty else { return nil }
            return (remote: remote.name, branch: branch, prefixLength: prefix.count)
        }
        .max { $0.prefixLength < $1.prefixLength }
        .map { (remote: $0.remote, branch: $0.branch) }
}
/// GitCheckoutWithUpdateAction revalidates the selected local branch's
/// tracking branch when the action is invoked. Keep the single-root callback
/// from switching branches when its asynchronous dashboard snapshot is stale.
func checkoutAndUpdateUpstream(
    branch: String,
    syncStatuses: [SyncStatus]
) -> String? {
    guard let sync = syncStatuses.first(where: { $0.branch == branch }),
          sync.trackingExists else { return nil }
    let upstream = sync.upstream.trimmingCharacters(in: .whitespacesAndNewlines)
    guard upstream.contains("/"), !upstream.hasSuffix("/") else { return nil }
    return upstream
}
/// IntelliJ 的 GitDefineRemoteDialog 在提交新增/编辑前执行 `git ls-remote`。
/// 复用 Arbor 已有的 askpass 桥，让私有 HTTPS/SSH remote 也走同一套凭证交互。
func remoteURLCheckFailure(
    repo: Repository,
    url: String,
    broker: CredentialBroker
) throws -> String? {
    let outcome = try broker.runGitWithAskpass(
        argv: ["ls-remote", "--", url],
        workingDir: repo.workdir()
    )
    guard outcome.exitCode == 0, !outcome.cancelled, !outcome.timedOut else {
        let detail = [outcome.stderr, outcome.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let detail {
            return detail
        }
        if outcome.cancelled {
            return "Remote URL check was cancelled."
        }
        if outcome.timedOut {
            return "Remote URL check timed out."
        }
        return "git ls-remote exited with code \(outcome.exitCode)."
    }
    return nil
}
func loadRemoteConfigRoots(scanRoot: String) throws -> [MultiRootRemoteConfigRoot] {
    let roots = try discoverGitRoots(scanRoot: scanRoot, maxDepth: nil)
    return try roots.map { root in
        let rootRepo = try openRepository(path: root.path)
        return MultiRootRemoteConfigRoot(
            rootPath: root.path,
            displayName: root.displayName,
            relativePath: root.relativePath,
            remotes: try rootRepo.remoteList()
        )
    }
}
/// Mirrors GitDeleteBranchOperation's optional notification action. The
/// remote ref is only offered when the deleted local branch was the sole
/// tracker, the tracking ref still exists, and the remote branch is not
/// protected by the effective project rules.
func deletableTrackedRemoteBranch(
    branchName: String,
    upstream: String?,
    syncStatuses: [SyncStatus],
    protectedPatterns: [String]
) -> String? {
    let candidate = deletableTrackedRemoteBranches(
        branchName: branchName,
        syncStatusesByRoot: [syncStatuses],
        protectedPatterns: protectedPatterns
    )
    guard let upstream = upstream?.trimmingCharacters(in: .whitespacesAndNewlines),
          candidate.contains(upstream) else { return nil }
    return upstream
}
func deletableTrackedRemoteBranches(
    branchName: String,
    syncStatusesByRoot: [[SyncStatus]],
    protectedPatterns: [String]
) -> Set<String> {
    let normalizedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedBranch.isEmpty else { return [] }
    let candidates = Set(
        syncStatusesByRoot
            .flatMap { $0 }
            .filter {
                $0.branch == normalizedBranch
                    && $0.trackingExists
                    && $0.upstream.contains("/")
            }
            .map(\.upstream)
    )
    let otherTrackers = Set(
        syncStatusesByRoot
            .flatMap { $0 }
            .filter { $0.branch != normalizedBranch && $0.trackingExists }
            .map(\.upstream)
    )
    return Set(
        candidates.filter { upstream in
            guard !otherTrackers.contains(upstream) else { return false }
            let remoteBranchName = String(
                upstream.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/")
            )
            return !remoteBranchName.isEmpty
                && !GitProtectedBranchRules.matches(remoteBranchName, patterns: protectedPatterns)
        }
    )
}
