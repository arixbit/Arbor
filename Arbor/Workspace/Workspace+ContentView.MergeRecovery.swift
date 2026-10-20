import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func multiRootMergeRollbackRequest(
    branchName: String,
    targets: [MultiRootMergeRollbackTarget],
    resultRows: [FeedbackResultRow] = []
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootMerge,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootMergeBranchName: branchName,
        multiRootMergeRollbackTargets: targets.map(PersistedMultiRootMergeRollbackTarget.init),
        multiRootMergeRollbackResultRows: resultRows.isEmpty ? nil : resultRows
    )
}

func multiRootMergeRollbackAction(
    branchName: String,
    targets: [MultiRootMergeRollbackTarget]
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = multiRootMergeRollbackRequest(branchName: branchName, targets: targets)
    return FeedbackAction(title: "Rollback Successful Roots", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootMergeRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-merge.rollback.\(stableProject)"
}

/// Stable display identity for the initial multi-root Merge result. Rollback
/// and delete-on-merge use separate IDs so their later lifecycle updates do
/// not erase the original root-qualified result tree.
func multiRootMergeNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-merge.\(stableProject)"
}

/// Roll back only roots whose HEAD is still the exact merge result recorded by
/// the engine. Pending merges use Abort so conflict worktrees are not silently
/// overwritten; completed merges use the configured preserving lifecycle and a
/// hard reset, matching IntelliJ's smart rollback for dirty repositories.
func rollbackMultiRootMerge(
    _ targets: [MultiRootMergeRollbackTarget],
    branchName: String? = nil,
    priorResultRows: [FeedbackResultRow] = []
) {
    guard !targets.isEmpty else { return }
    let rollbackContext = mergeWorkspace.multiRootRollbackContext
    let rollbackBranchName = branchName
        ?? rollbackContext?.branchName
        ?? mergeWorkspace.multiRootBranchName
    let previousFailures = rollbackContext?.failures ?? []
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    mergeWorkspace.multiRootRollbackContext = nil
    let stableNotificationID = multiRootMergeRollbackNotificationID()
    beginFeedbackOperation(
        "Rollback multi-root merge",
        notificationID: stableNotificationID
    )
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [MultiRootMergeRollbackTarget] = []
        var results: [RootOperationResult] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard rootRepo.headCommitId() == target.expectedHead else {
                    throw NSError(
                        domain: "Arbor.MultiRootMergeRollback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "HEAD changed after the merge; rollback was skipped."]
                    )
                }
                if target.operationPending {
                    try rootRepo.mergeAbort()
                } else {
                    try rootRepo.resetWithPolicy(
                        commitId: target.initialHead,
                        mode: .hard,
                        savePolicy: savePolicy
                    )
                }
                guard rootRepo.headCommitId() == target.initialHead else {
                    throw NSError(
                        domain: "Arbor.MultiRootMergeRollback",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Rollback did not restore the original HEAD."]
                    )
                }
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: target.displayName,
                        success: true,
                        skipped: false,
                        message: target.operationPending
                            ? "Aborted merge and restored the original HEAD"
                            : "Restored the original HEAD"
                    )
                )
            } catch {
                let message = errorMessage(error)
                failures.append("\(target.displayName): \(message)")
                remaining.append(target)
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: target.displayName,
                        success: false,
                        skipped: false,
                        message: message
                    )
                )
            }
        }
        let rollbackSucceeded = failures.isEmpty
        let remainingTargets = remaining
        let rollbackFailureDetails = failures
        let rollbackFailures = previousFailures + rollbackFailureDetails
        let rollbackResultRows = mergeFeedbackResultRows(
            preserved: priorResultRows,
            retry: feedbackResultRows(from: results)
        )
        await MainActor.run {
            self.loadMultiRoots()
            if rollbackSucceeded {
                self.feedbackCenter.success(
                    "Multi-root merge rollback completed",
                    detail: "\(targets.count) repositories restored",
                    notificationID: stableNotificationID,
                    notificationGroup: .standard
                )
                self.feedbackCenter.attachResultRows(
                    rollbackResultRows,
                    notificationID: stableNotificationID
                )
            } else {
                self.mergeWorkspace.multiRootRollbackContext = MultiRootMergeRollbackContext(
                    branchName: rollbackBranchName,
                    targets: remainingTargets,
                    failures: rollbackFailures,
                    pendingRootPath: nil
                )
                let retryRequest = self.multiRootMergeRollbackRequest(
                    branchName: rollbackBranchName,
                    targets: remainingTargets,
                    resultRows: rollbackResultRows
                )
                self.feedbackCenter.warning(
                    "Multi-root merge rollback partially failed",
                    detail: rollbackFailureDetails.joined(separator: "\n"),
                    nextStep: "Review the remaining roots and retry only after confirming their current HEAD.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Remaining Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    ],
                    notificationID: stableNotificationID,
                    notificationGroup: .standard
                )
                self.feedbackCenter.attachResultRows(
                    rollbackResultRows,
                    notificationID: stableNotificationID
                )
                self.presentMultiRootMergeRollbackRestoreConflict(remainingTargets)
            }
        }
    }
}

/// GitMergeAction exposes the same received-commits follow-up as Update when
/// a merge actually creates or advances a commit. Keep the range derived from
/// the engine's per-root before/after heads so fast-forward, no-ff and mixed
/// multi-root results do not expose an unrelated or unchanged Log range.
nonisolated static func completedMergeRevisionRanges(
    _ results: [MultiRootMergeResult]
) -> [PersistedLogRevisionRange] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    return results
        .filter { result in
            result.success
                && !result.skipped
                && result.completed
                && result.initialHead != nil
                && result.finalHead != nil
        }
        .compactMap { result in
            guard let initialHead = result.initialHead,
                  let finalHead = result.finalHead,
                  !initialHead.isEmpty,
                  !finalHead.isEmpty,
                  initialHead != finalHead else {
                return nil
            }
            return PersistedLogRevisionRange(
                rootPath: normalizedPath(result.rootPath),
                oldRevision: initialHead,
                newRevision: finalHead
            )
        }
        .sorted { $0.rootPath < $1.rootPath }
}

func completedMergeViewCommitsAction(
    rootPath: String,
    initialHead: String?,
    finalHead: String?,
    completed: Bool
) -> FeedbackAction? {
    guard completed,
          let initialHead,
          let finalHead,
          !initialHead.isEmpty,
          !finalHead.isEmpty,
          initialHead != finalHead else {
        return nil
    }
    return multiRootUpdateViewCommitsAction(
        ranges: [PersistedLogRevisionRange(
            rootPath: URL(fileURLWithPath: rootPath).standardizedFileURL.path,
            oldRevision: initialHead,
            newRevision: finalHead
        )]
    )
}

/// A completed merge can be rolled back without discarding unrelated local
/// edits. The request carries the exact pre-merge HEAD and repository handle;
/// the action is posted through NotificationCenter because ContentView is a
/// SwiftUI value type and must not be captured by a long-lived feedback action.
struct MergeRollbackRequest {
    let repo: Repository
    let initialHead: String
    let expectedHead: String
    let branch: String
}

struct MergeDeleteBranchRequest {
    let repo: Repository
    let branch: String
    let rootPath: String?
}

func handleMergeDeleteNotification(_ notification: Notification) {
    guard let request = notification.object as? MergeDeleteBranchRequest else { return }
    if let rootPath = request.rootPath {
        deleteBranchInRoot(rootPath: rootPath, name: request.branch)
    } else if projectWorkspace.repository === request.repo {
        branchDelete(request.branch)
    } else {
        feedbackCenter.error(
            "Delete merged branch unavailable",
            detail: "The original repository is no longer active."
        )
    }
}

nonisolated func canProposeDeleteMergedBranch(
    repo: Repository,
    branch: String,
    protectedPatterns: [String]
) -> Bool {
    guard !branch.isEmpty,
          !GitProtectedBranchRules.matches(branch, patterns: protectedPatterns),
          let localBranches = try? repo.branchList(),
          let source = localBranches.first(where: { $0.name == branch }) else {
        return false
    }
    return !source.isCurrent
}

func confirmAndDeleteMultiRootMergedBranch(
    name: String,
    selectedRootPaths: Set<String>
) {
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    guard !GitProtectedBranchRules.matches(
        branchName,
        patterns: effectiveProtectedBranchPatterns
    ) else {
        feedbackCenter.warning(
            "Delete merged branch unavailable",
            detail: "The branch is protected: \(branchName)",
            nextStep: "Remove the branch from the protected-branch rules before deleting it."
        )
        return
    }

    let candidates = multiRootWorkspace.branchSnapshots.compactMap { snapshot -> MultiRootMergeDeleteCandidate? in
        guard snapshot.branches.contains(where: {
            $0.name == branchName && !$0.isCurrent
        }) else { return nil }
        return MultiRootMergeDeleteCandidate(
            rootPath: snapshot.rootPath,
            displayName: snapshot.displayName
        )
    }
    let targets = multiRootMergeDeleteTargets(
        selectedRootPaths: selectedRootPaths,
        candidates: candidates
    )
    guard !targets.isEmpty else {
        feedbackCenter.warning(
            "Delete merged branch unavailable",
            detail: "No selected Git root still contains a non-current local branch named \(branchName).",
            nextStep: "Refresh Git state and retry the action."
        )
        return
    }

    let rootList = targets.map { target in
        let displayName = target.displayName.isEmpty ? target.rootPath : target.displayName
        return "• \(displayName) — \(target.rootPath)"
    }.joined(separator: "\n")
    let alert = NSAlert()
    alert.messageText = "Delete merged branch \(branchName) from \(targets.count) Git root\(targets.count == 1 ? "" : "s")?"
    alert.informativeText = "This removes the local branch reference in:\n\(rootList)"
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    deleteMultiRootBranch(
        name: branchName,
        selectedRootPaths: Set(targets.map(\.rootPath)),
        allowForceDelete: false
    )
}

func postMergeRollbackAction(
    repo: Repository,
    initialHead: String,
    expectedHead: String,
    branch: String
) -> (() -> Void) {
    {
        NotificationCenter.default.post(
            name: .arborRollbackMerge,
            object: MergeRollbackRequest(
                repo: repo,
                initialHead: initialHead,
                expectedHead: expectedHead,
                branch: branch
            )
        )
    }
}

func postMergeDeleteAction(
    repo: Repository,
    branch: String,
    rootPath: String? = nil
) -> (() -> Void) {
    {
        NotificationCenter.default.post(
            name: .arborDeleteMergedBranch,
            object: MergeDeleteBranchRequest(
                repo: repo,
                branch: branch,
                rootPath: rootPath
            )
        )
    }
}

func multiRootMergeDeleteRequest(
    branch: String,
    rootPaths: [String]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .deleteMultiRootMergeBranch,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootMergeDeleteBranchName: branch,
        multiRootMergeDeleteRootPaths: rootPaths
    )
}

func multiRootMergeDeleteAction(
    branch: String,
    rootPaths: [String]
) -> FeedbackAction? {
    let normalizedRootPaths = Array(Set(rootPaths)).sorted()
    guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !normalizedRootPaths.isEmpty else { return nil }
    let request = multiRootMergeDeleteRequest(
        branch: branch,
        rootPaths: normalizedRootPaths
    )
    return FeedbackAction(title: "Delete branch", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootMergeDeleteNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-merge.delete-branch.\(stableProject)"
}

}
