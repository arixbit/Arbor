import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Execute IntelliJ's Update Selected Branch semantics for one Git root:
/// update the current branch with the configured merge/rebase method, while
/// advancing a non-current local ref directly from its tracking branch.
/// Repository metadata is re-read here so a stale dashboard snapshot cannot
/// update the wrong root or accidentally route the current branch through the
/// non-current ref-update path.
func executeBranchUpdateInRoot(
    repo: Repository,
    rootPath: String,
    branch: String,
    displayName: String,
    rebase: Bool,
    tagMode: FetchTagsMode,
    broker: CredentialBroker,
    cancel: GitCancelHandle,
    savePolicy: LocalChangesSavePolicy
) throws -> RootOperationResult {
    let branches = try repo.branchList()
    guard branches.contains(where: { $0.name == branch }) else {
        throw NSError(
            domain: "Arbor.Git",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Branch does not exist: \(branch)"]
        )
    }

    let sync = try repo.syncStatus().first { $0.branch == branch }
    guard let sync, sync.trackingExists,
          let target = remoteBranchTargetForConfiguredUpstream(
              sync.upstream,
              remotes: try repo.remoteList()
          ) else {
        throw NSError(
            domain: "Arbor.Git",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Branch has no valid tracking branch: \(branch)"]
        )
    }

    if branches.first(where: { $0.isCurrent })?.name == branch {
        let result = try runRootUpdateForCurrentBranchWithOptions(
            rootPath: rootPath,
            remote: target.remote,
            localBranch: branch,
            remoteBranch: target.branch,
            rebase: rebase,
            tagMode: tagMode,
            broker: broker,
            cancel: cancel,
            savePolicy: savePolicy
        )
        return RootOperationResult(
            rootPath: rootPath,
            displayName: displayName,
            success: result.success,
            skipped: result.skipped,
            message: result.message.isEmpty ? "Updated \(branch)" : result.message
        )
    }

    try repo.updateBranchWithOptionsAndAuthAndCancel(
        branch: branch,
        tagMode: tagMode,
        broker: broker,
        cancel: cancel
    )
    return RootOperationResult(
        rootPath: rootPath,
        displayName: displayName,
        success: true,
        skipped: false,
        message: "Updated \(branch)"
    )
}
