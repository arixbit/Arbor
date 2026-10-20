import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

func updateSelectedBranch(_ name: String) {
    guard let repo, let rootPath = repo.workdir() else { return }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let rebase = GitUpdateMethodSettings.method(for: projectWorkspace.path) == .rebase
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Update branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let result = try executeBranchUpdateInRoot(
                repo: repo,
                rootPath: rootPath,
                branch: name,
                displayName: name,
                rebase: rebase,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: savePolicy
            )
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                if result.success && !result.skipped {
                    self.feedbackCenter.success("Branch updated", detail: name)
                    self.refreshAll(showFeedback: false)
                    self.loadRepoData()
                } else if result.skipped {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: result.message,
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Branch update paused",
                        detail: result.message,
                        nextStep: "Resolve the update state, then retry the branch."
                    )
                }
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.repositoryStatus.loadError = detail
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: detail,
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Update branch failed",
                        detail: detail,
                        nextStep: "Check the upstream, credentials, and Git operation state, then retry."
                    )
                }
            }
        }
    }
}

/// 多 root Branches Popup 的 Update：操作必须固定到行所属的 root。
func updateBranchInRoot(rootPath: String, branch: String) {
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let rebase = GitUpdateMethodSettings.method(for: projectWorkspace.path) == .rebase
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Update branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let result = try executeBranchUpdateInRoot(
                repo: rootRepo,
                rootPath: rootPath,
                branch: branch,
                displayName: rootPath,
                rebase: rebase,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: savePolicy
            )
            await MainActor.run {
                if result.success && !result.skipped {
                    self.feedbackCenter.success("Branch updated", detail: "\(branch) · \(rootPath)")
                } else if result.skipped {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: "\(branch) · \(rootPath): \(result.message)",
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Branch update paused",
                        detail: "\(branch) · \(rootPath): \(result.message)",
                        nextStep: "Resolve the update state, then retry the branch."
                    )
                }
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Update branch failed",
                        detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Check the upstream, credentials, and Git operation state, then retry."
                    )
                }
            }
        }
    }
}

/// IntelliJ's MultipleLocalBranchActions.UpdateSelectedBranchAction for the
/// Log dashboard. Each selected reference keeps its root and branch name; a
/// failure in one target does not silently skip the remaining independent
/// targets, and the aggregated result is exposed in the Operations workbench.
func updateSelectedBranchesInRoots(_ targets: [BranchDashboardReference]) {
    let selected = targets
        .filter { $0.kind == .local && $0.hasTracking }
        .sorted {
            if $0.rootPath == $1.rootPath {
                if $0.isCurrent != $1.isCurrent { return !$0.isCurrent }
                return $0.name < $1.name
            }
            return $0.rootPath < $1.rootPath
        }
    guard !selected.isEmpty, !multiRootWorkspace.running else { return }

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    multiRootWorkspace.running = true
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let rebase = GitUpdateMethodSettings.method(for: projectWorkspace.path) == .rebase
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Update selected branches", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        for target in selected {
            if cancel.isCancelled() {
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: false,
                        skipped: true,
                        message: "Cancelled before updating \(target.name)"
                    )
                )
                continue
            }
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                results.append(
                    try executeBranchUpdateInRoot(
                        repo: rootRepo,
                        rootPath: target.rootPath,
                        branch: target.name,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        rebase: rebase,
                        tagMode: tagMode,
                        broker: broker,
                        cancel: cancel,
                        savePolicy: savePolicy
                    )
                )
            } catch {
                let wasCancelled: Bool
                if case .Cancelled = error as? EngineError {
                    wasCancelled = true
                } else {
                    wasCancelled = false
                }
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: false,
                        skipped: wasCancelled,
                        message: wasCancelled
                            ? "Cancelled while updating \(target.name)"
                            : "\(target.name): \(errorMessage(error))"
                    )
                )
            }
        }
        let completedResults = results
        let completedFailures = completedResults.filter { !$0.success && !$0.skipped }
        let completedSkipped = completedResults.filter(\.skipped)
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.multiRootWorkspace.results = completedResults
            self.loadMultiRoots()
            if completedFailures.isEmpty && completedSkipped.isEmpty {
                self.feedbackCenter.success(
                    "Selected branches updated",
                    detail: "\(selected.count) branches"
                )
            } else {
                let failureDetail = completedFailures.map {
                    "\($0.displayName): \($0.message)"
                }
                let skippedDetail = completedSkipped.map {
                    "\($0.displayName): \($0.message)"
                }
                self.feedbackCenter.warning(
                    "Selected branch update partially completed",
                    detail: (failureDetail + skippedDetail).joined(separator: "\n"),
                    nextStep: completedFailures.isEmpty
                        ? "Retry the skipped branch updates when ready."
                        : "Resolve the failed branch upstreams, then retry those branches."
                )
            }
        }
    }
}
}
