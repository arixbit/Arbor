import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// IntelliJ only opens the Push-after-commit flow when the commit phase has
/// no failures. A partial commit keeps an explicit "Push Committed Roots"
/// action in the notification, but must not start a second operation
/// implicitly.
func shouldAutomaticallyOpenMultiRootCommitPushOptions(
    pushAfterCommit: Bool,
    pushRootPaths: [String],
    failedRootPaths: [String]
) -> Bool {
    pushAfterCommit && !pushRootPaths.isEmpty && failedRootPaths.isEmpty
}
/// Decide whether the post-commit Push flow must remain visible. This is a
/// read-only preflight: automatic Push is allowed only when the caller has an
/// unambiguous push target and an attached current branch; missing transport
/// state stays in the explicit Push options flow just like IntelliJ's
/// `!canPush()` path.
func pushAfterCommitPreviewRequiresUI(
    choice: GitPushAfterCommitPreviewChoice,
    hasPushTarget: Bool,
    hasCurrentBranch: Bool,
    isProtectedBranch: Bool
) -> Bool {
    switch choice {
    case .always:
        return true
    case .protectedOnly:
        return !hasPushTarget || !hasCurrentBranch || isProtectedBranch
    case .automatic:
        return !hasPushTarget || !hasCurrentBranch
    }
}
nonisolated func pushAfterCommitRequiresPreview(
    rootPath: String,
    choice: GitPushAfterCommitPreviewChoice,
    protectedBranchPatterns: [String]
) -> Bool {
    guard choice != .always else { return true }
    guard let rootRepo = try? openRepository(path: rootPath),
          let remotes = try? rootRepo.remoteList(),
          remotes.count == 1,
          let branch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name else {
        return true
    }
    return pushAfterCommitPreviewRequiresUI(
        choice: choice,
        hasPushTarget: true,
        hasCurrentBranch: true,
        isProtectedBranch: GitProtectedBranchRules.matches(
            branch,
            patterns: protectedBranchPatterns
        )
    )
}
/// Force-pushed replay branches are deliberately kept when the replay or
/// local-change restore cannot finish. They are user-visible recovery refs,
/// not ordinary branches created by the user, so failure feedback can offer a
/// scoped cleanup action without guessing from a shell error string.
func isArborForcePushedBackupBranch(_ name: String) -> Bool {
    name.hasPrefix("arbor-force-pushed-backup-")
}
/// A targeted Force Push retry may only carry force options forward when every
/// still-failed root in that retry is a stale-lease rejection. Never let a
/// force action selected for one root silently turn an unrelated NFF or
/// transport retry into a force push.
func multiRootPushRetryForceOptions(
    requestedForce: Bool,
    requestedForceWithLease: Bool,
    hasPriorResultRows: Bool,
    retryResults: [RootOperationResult]
) -> (force: Bool, forceWithLease: Bool) {
    guard requestedForce else { return (false, false) }
    guard hasPriorResultRows else {
        return (true, requestedForceWithLease)
    }
    let onlyStaleLeaseFailures = !retryResults.isEmpty
        && retryResults.allSatisfy {
            !$0.success && pushResultIsStaleLeaseRejected($0)
        }
    return onlyStaleLeaseFailures
        ? (true, requestedForceWithLease)
        : (false, false)
}
nonisolated func stalePushRejectionDetails(
    _ error: Error
) -> (remote: String, branch: String, message: String)? {
    guard case let .PushRejected(kind, remote, branch, message) = error as? EngineError,
          kind == .staleInfo else { return nil }
    return (remote: remote, branch: branch, message: message)
}
func pushResultIsStaleLeaseRejected(_ result: RootOperationResult) -> Bool {
    let message = result.message.lowercased()
    return message.contains("stale info") || message.contains("stale lease")
}
func pushResultIsRejected(_ result: RootOperationResult) -> Bool {
    guard !result.success else { return false }
    let message = result.message.lowercased()
    let isTransportFailure = message.contains("authentication")
        || message.contains("could not read username")
        || message.contains("permission denied")
        || message.contains("not permitted")
        || message.contains("publickey")
    guard !isTransportFailure else { return false }
    return pushResultIsStaleLeaseRejected(result)
        || pushResultNeedsUpdate(result)
        || message.contains("[rejected]")
        || message.contains("push rejected")
}
func pushResultNeedsUpdate(_ result: RootOperationResult) -> Bool {
    let message = result.message.lowercased()
    return message.contains("non-fast-forward")
        || (message.contains("[rejected]")
            && (message.contains("fetch first")
                || message.contains("remote contains work")
                || message.contains("tip of your current branch is behind")))
}
