import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Mirrors IntelliJ's `stopTaskAndUnhighlight`: cancelling must also remove
/// fallback/trailer highlighting instead of leaving stale decoration visible.
func cancelCherryPickedHighlighting() {
    logCherryPick.comparisonTask?.cancel()
    logCherryPick.comparisonTask = nil
    logCherryPick.cancelHandle?.cancel()
    logCherryPick.cancelHandle = nil
    logCherryPick.generation += 1
    logCherryPick.inProgress = false
    logCherryPick.cherryPickedCommitIDs = []
    logCherryPick.comparisonReady = false
    logHighlightCherryPicked = false
}

nonisolated func configuredCherryPickEmptyPolicy() -> CherryPickEmptyPolicy {
    configuredCherryPickEmptyPolicyChoice().engineValue
}

nonisolated func configuredCherryPickEmptyPolicyChoice() -> GitCherryPickEmptyPolicyChoice {
    let rawValue = UserDefaults.standard.string(forKey: GitCherryPickSettings.emptyPolicyKey)
        ?? GitCherryPickSettings.defaultEmptyPolicy.rawValue
    return GitCherryPickEmptyPolicyChoice(rawValue: rawValue)
        ?? GitCherryPickSettings.defaultEmptyPolicy
}

nonisolated func shouldAppendCherryPickSuffix(
    projectPath: String?,
    commits: [CommitInfo],
    repo: Repository,
    remoteBranches: [RemoteBranchInfo],
    protectedPatterns: [String]
) -> Bool {
    guard GitCherryPickSettings.effectiveAppendPublishedSuffix(for: projectPath),
          !commits.isEmpty else {
        return false
    }
    let protectedBranches = remoteBranches.filter {
        GitProtectedBranchRules.matches(
            ContentView.branchNameForProtection($0),
            patterns: protectedPatterns
        )
    }
    guard !protectedBranches.isEmpty else { return false }
    return commits.allSatisfy { commit in
        protectedBranches.contains { remoteBranch in
            (try? repo.isCommitReachableFrom(
                commitId: commit.id,
                descendantId: remoteBranch.shortId
            )) == true
        }
    }
}

func resetRecoveryRollbackRequest(
    targets: [PersistedResetRecoveryTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackResetRecovery,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        resetRecoveryTargets: targets
    )
}

func resetRecoveryRollbackAction(
    targets: [PersistedResetRecoveryTarget]
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = resetRecoveryRollbackRequest(targets: targets)
    return FeedbackAction(
        title: targets.count == 1 ? "Undo Reset" : "Rollback Successful Resets",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func resetRecoveryKeepRequest(
    targets: [PersistedResetRecoveryTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .keepResetRecovery,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        resetRecoveryTargets: targets
    )
}

func resetRecoveryKeepAction(
    targets: [PersistedResetRecoveryTarget]
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = resetRecoveryKeepRequest(targets: targets)
    return FeedbackAction(
        title: targets.count == 1 ? "Keep Reset Result" : "Keep Successful Resets",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func resetRecoveryActions(
    targets: [PersistedResetRecoveryTarget]
) -> [FeedbackAction] {
    [
        resetRecoveryRollbackAction(targets: targets),
        resetRecoveryKeepAction(targets: targets)
    ].compactMap { $0 }
}

/// Full-scene reset undo. Rust validates every target's post-reset index and
/// worktree snapshot before changing anything; failed roots remain as a
/// persisted retry action while successful roots are removed from the action.
func rollbackResetRecovery(
    _ targets: [PersistedResetRecoveryTarget]
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Rollback reset")
    Task.detached(priority: .userInitiated) {
        do {
            let results = try rollbackMultiRootResetRecovery(
                targets: targets.map { $0.makeLiveTarget() }
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
                let failures = results.filter { !$0.success }
                guard !failures.isEmpty else {
                    self.feedbackCenter.success(
                        "Reset rollback completed",
                        detail: "Restored \(results.count) root\(results.count == 1 ? "" : "s") including local changes.",
                        notificationID: self.resetRecoveryNotificationID(),
                        notificationGroup: .standard
                    )
                    return
                }
                let failedPaths = Set(failures.map(\.rootPath))
                let remainingTargets = targets.filter { failedPaths.contains($0.rootPath) }
                let retryRequest = self.resetRecoveryRollbackRequest(targets: remainingTargets)
                self.feedbackCenter.warning(
                    "Reset rollback partially failed",
                    detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                    nextStep: "The failed roots were left untouched. Retry after confirming their HEAD and local scene.",
                    additionalActions: remainingTargets.isEmpty
                        ? []
                        : [FeedbackAction(
                            title: "Retry Remaining Reset Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        },
                        self.resetRecoveryKeepAction(targets: remainingTargets)].compactMap { $0 },
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
            }
        } catch {
            await MainActor.run {
                let retryRequest = self.resetRecoveryRollbackRequest(targets: targets)
                self.feedbackCenter.warning(
                    "Reset rollback failed",
                    detail: errorMessage(error),
                    nextStep: "No root was assumed restored. Confirm the repository state and retry.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Reset Rollback",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        },
                        self.resetRecoveryKeepAction(targets: targets)
                    ].compactMap { $0 },
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

/// Keep the reset result after verifying that every selected root still has
/// the exact post-reset scene. Failed roots remain as retryable semantic
/// targets; successful roots release their repository-owned snapshots.
func keepResetRecovery(
    _ targets: [PersistedResetRecoveryTarget]
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Keep reset result")
    Task.detached(priority: .userInitiated) {
        do {
            let results = try keepMultiRootResetRecovery(
                targets: targets.map { $0.makeLiveTarget() }
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
                let failures = results.filter { !$0.success }
                guard !failures.isEmpty else {
                    self.feedbackCenter.success(
                        "Reset result kept",
                        detail: "Released recovery snapshots for \(results.count) root\(results.count == 1 ? "" : "s").",
                        notificationID: self.resetRecoveryNotificationID(),
                        notificationGroup: .standard
                    )
                    return
                }
                let failedPaths = Set(failures.map(\.rootPath))
                let remainingTargets = targets.filter { failedPaths.contains($0.rootPath) }
                let retryRequest = self.resetRecoveryKeepRequest(targets: remainingTargets)
                self.feedbackCenter.warning(
                    "Reset result partially kept",
                    detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                    nextStep: "The failed roots remain protected. Retry Keep after confirming their HEAD and local scene.",
                    additionalActions: remainingTargets.isEmpty
                        ? []
                        : [FeedbackAction(
                            title: "Retry Remaining Keep",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        },
                        self.resetRecoveryRollbackAction(targets: remainingTargets)].compactMap { $0 },
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
            }
        } catch {
            await MainActor.run {
                let retryRequest = self.resetRecoveryKeepRequest(targets: targets)
                self.feedbackCenter.warning(
                    "Keep Reset result failed",
                    detail: errorMessage(error),
                    nextStep: "Confirm the repository state, then retry Keep or Undo.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Keep Reset Result",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        },
                        self.resetRecoveryRollbackAction(targets: targets)
                    ].compactMap { $0 },
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

func resetModeName(_ mode: ResetMode) -> String {
    switch mode {
    case .soft: return "soft"
    case .mixed: return "mixed"
    case .hard: return "hard"
    case .keep: return "keep"
    }
}

/// Changes-view entry point for IntelliJ Git.RevertResolved. The resolved
/// ledger supplies the exact file set; the confirmation remains at the file
/// level so the user can review the path before Git reopens its conflict.
func revertResolvedPath(_ path: String) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = "Revert resolved file?"
    alert.informativeText = "\(path) will return to the unresolved conflict list."
    alert.addButton(withTitle: "Revert")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Revert Resolved")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.revertResolvedConflict(path: path)
            await MainActor.run {
                self.feedbackCenter.success("Revert Resolved", detail: path)
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Revert Resolved failed",
                    detail: errorMessage(error),
                    nextStep: "打开冲突工作台并检查该文件后重试。"
                )
            }
        }
    }
}

/// Build the expected-HEAD set for an Update Project rollback. Only roots
/// that completed and actually advanced are included; failed roots may still
/// have an active merge/rebase state and must remain in their recovery flow.
nonisolated static func updateSessionRollbackTargets(
    previousHeads: [String: String],
    currentHeads: [String: String],
    results: [RootOperationResult],
    submoduleRootPaths: [String],
    previousHeadBranches: [String: String] = [:]
) -> [PersistedMultiRootUpdateRollbackTarget] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    let previousByRoot = Dictionary(
        uniqueKeysWithValues: previousHeads.map { (normalizedPath($0.key), $0.value) }
    )
    let currentByRoot = Dictionary(
        uniqueKeysWithValues: currentHeads.map { (normalizedPath($0.key), $0.value) }
    )
    let previousBranchByRoot = Dictionary(
        uniqueKeysWithValues: previousHeadBranches.map { (normalizedPath($0.key), $0.value) }
    )
    let normalizedSubmodulePaths = submoduleRootPaths.map(normalizedPath)
    return results
        .filter { $0.success && !$0.skipped }
        .compactMap { result in
            let rootPath = normalizedPath(result.rootPath)
            guard let initialHead = previousByRoot[rootPath],
                  let expectedHead = currentByRoot[rootPath],
                  !initialHead.isEmpty,
                  !expectedHead.isEmpty,
                  initialHead != expectedHead else {
                return nil
            }
            let ignoredPaths = normalizedSubmodulePaths
                .filter {
                    $0 != rootPath && $0.hasPrefix(rootPath + "/")
                }
                .map {
                    String($0.dropFirst(rootPath.count + 1))
                }
                .sorted()
            return PersistedMultiRootUpdateRollbackTarget(
                rootPath: rootPath,
                displayName: result.displayName,
                initialHead: initialHead,
                expectedHead: expectedHead,
                expectedHeadBranch: previousBranchByRoot[rootPath],
                ignoredPaths: ignoredPaths
            )
        }
        .sorted { lhs, rhs in
            if lhs.rootPath.count != rhs.rootPath.count {
                return lhs.rootPath.count > rhs.rootPath.count
            }
            return lhs.rootPath < rhs.rootPath
        }
}

func validateResetHeadTarget(
    _ target: String,
    rootPath: String
) -> RebasedResetTargetValidation {
    let revision = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !revision.isEmpty else {
        return RebasedResetTargetValidation(isValid: false, message: "Enter a revision.")
    }
    guard let repository = try? openRepository(path: rootPath) else {
        return RebasedResetTargetValidation(
            isValid: false,
            message: "The selected Git root is no longer available."
        )
    }
    do {
        let commitID = try repository.revisionCommitId(revision: revision)
        return RebasedResetTargetValidation(
            isValid: true,
            message: "Resolves to \(String(commitID.prefix(12)))."
        )
    } catch {
        return RebasedResetTargetValidation(isValid: false, message: errorMessage(error))
    }
}

/// IntelliJ's Git.Reset accepts an arbitrary revision expression, unlike the
/// separate reset-to-upstream command. Resolve the expression off the main
/// actor, then reuse the existing recovery-aware reset pipeline.
func resetHead(rootPath: String, target: String, mode: ResetMode) {
    let revision = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !revision.isEmpty, let repository = try? openRepository(path: rootPath) else {
        feedbackCenter.error(
            "Reset Head failed",
            detail: "The selected Git root or revision is unavailable.",
            nextStep: "Refresh the project and enter a valid revision, then retry."
        )
        return
    }
    Task.detached(priority: .userInitiated) {
        do {
            let commitID = try repository.revisionCommitId(revision: revision)
            await MainActor.run {
                self.runResetCommit(
                    repo: repository,
                    id: commitID,
                    mode: mode,
                    preserveLocalChanges: false
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Reset Head failed",
                    detail: errorMessage(error),
                    nextStep: "Check the revision expression and current Git state, then retry."
                )
            }
        }
    }
}

}
