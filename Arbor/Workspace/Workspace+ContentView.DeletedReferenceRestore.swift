import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func restoreDeletedBranchesFromSemanticTargets(
    _ targets: [PersistedBranchDeleteRecoveryTarget]
) {
    guard let normalizedTargets = normalizedBranchDeleteRecoveryTargets(targets) else { return }
    if let notificationID = branchDeleteNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
    branchWorkspace.deleteRecovery = nil
    branchWorkspace.multiRootDeleteRecovery = nil
    beginFeedbackOperation("Restore deleted branches")
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [PersistedBranchDeleteRecoveryTarget] = []
        var upstreamWarnings: [String] = []
        for target in normalizedTargets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                try rootRepo.branchCreate(
                    name: target.branchName,
                    at: target.tipID
                )
                if let upstream = target.upstream, !upstream.isEmpty {
                    do {
                        try rootRepo.branchSetUpstream(
                            branch: target.branchName,
                            upstream: upstream
                        )
                    } catch {
                        upstreamWarnings.append(
                            "\(target.rootPath): \(errorMessage(error))"
                        )
                    }
                }
            } catch {
                failures.append(
                    "\(target.rootPath): \(errorMessage(error))"
                )
                remaining.append(target)
            }
        }
        let failuresToReport = failures
        let remainingTargets = remaining
        let upstreamWarningsToReport = upstreamWarnings
        await MainActor.run {
            self.loadMultiRoots()
            if let currentRootPath = self.repo?.workdir().map({
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }), normalizedTargets.contains(where: { $0.rootPath == currentRootPath }) {
                self.loadRepoData()
            }
            if failuresToReport.isEmpty && upstreamWarningsToReport.isEmpty {
                self.feedbackCenter.success(
                    "Deleted branch restore completed",
                    detail: normalizedTargets.map { "\($0.branchName) · \($0.rootPath)" }.joined(separator: ", ")
                )
            } else {
                let details = failuresToReport + upstreamWarningsToReport
                self.feedbackCenter.warning(
                    "Deleted branch restore partially failed",
                    detail: details.joined(separator: "\n"),
                    nextStep: "Retry the remaining branch restore action.",
                    additionalActions: self.branchDeleteRestoreAction(
                        targets: remainingTargets,
                        title: "Retry Restore"
                    ).map { [$0] } ?? [],
                    notificationID: remainingTargets.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: remainingTargets.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

func restoreDeletedBranches(_ contexts: [BranchDeleteRecoveryContext]) {
    guard !contexts.isEmpty else { return }
    if let notificationID = branchDeleteNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
    branchWorkspace.multiRootDeleteRecovery = nil
    beginFeedbackOperation("Restore multi-root branches")
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [BranchDeleteRecoveryContext] = []
        var upstreamWarnings: [String] = []
        for context in contexts {
            do {
                try context.repo.branchCreate(
                    name: context.preview.branchName,
                    at: context.preview.tipId
                )
                if let upstream = context.preview.upstream, !upstream.isEmpty {
                    do {
                        try context.repo.branchSetUpstream(
                            branch: context.preview.branchName,
                            upstream: upstream
                        )
                    } catch {
                        upstreamWarnings.append(
                            "\(context.rootPath ?? String(localized: "Repository")): \(errorMessage(error))"
                        )
                    }
                }
            } catch {
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")): \(errorMessage(error))"
                )
                remaining.append(context)
            }
        }
        let failuresToReport = failures
        let remainingContexts = remaining
        let upstreamWarningsToReport = upstreamWarnings
        await MainActor.run {
            self.loadMultiRoots()
            if failuresToReport.isEmpty && upstreamWarningsToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root branch restore completed",
                    detail: contexts.first?.preview.branchName ?? ""
                )
            } else {
                self.branchWorkspace.multiRootDeleteRecovery = remainingContexts.isEmpty
                    ? nil
                    : MultiRootBranchDeleteRecoveryContext(
                        branchName: contexts.first?.preview.branchName ?? "",
                        contexts: remainingContexts
                    )
                let details = failuresToReport + upstreamWarningsToReport
                self.feedbackCenter.warning(
                    "Multi-root branch restore partially failed",
                    detail: details.joined(separator: "\n"),
                    nextStep: "Review the affected roots and retry the remaining restore action.",
                    additionalActions: self.branchDeleteRestoreAction(
                        contexts: remainingContexts,
                        title: "Retry Restore"
                    ).map { [$0] } ?? [],
                    notificationID: remainingContexts.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: remainingContexts.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

/// Validate the post-Undo state. The gitlink must still be the same commit,
/// but the nested worktree must now be initialized and clean.
nonisolated static func submoduleDeinitUndoTargetAfterRestore(
    _ context: PersistedSubmoduleUndo,
    modules: [SubmoduleInfo],
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> Bool {
    guard context.operation == .deinitialize,
          let module = modules.first(where: { $0.path == context.path }) else {
        return false
    }
    return module.state == .clean
        && !module.dirty
        && module.headId == context.expectedHeadID
        && gitmodulesPresent == context.expectedGitmodulesPresent
        && gitmodulesContents == context.expectedGitmodulesContents
}

func branchDeleteRestoreRequest(
    targets: [PersistedBranchDeleteRecoveryTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .restoreDeletedBranches,
        projectPath: projectWorkspace.path,
        rootPath: targets.count == 1 ? targets[0].rootPath : nil,
        shelfName: "",
        branchDeleteRecoveryTargets: targets
    )
}

func branchDeleteRestoreAction(
    contexts: [BranchDeleteRecoveryContext],
    title: String = "Restore"
) -> FeedbackAction? {
    guard let targets = branchDeleteRecoveryTargets(from: contexts) else { return nil }
    return branchDeleteRestoreAction(
        targets: targets,
        title: title
    )
}

func branchDeleteRestoreAction(
    targets: [PersistedBranchDeleteRecoveryTarget],
    title: String = "Restore"
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = branchDeleteRestoreRequest(targets: targets)
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func restoreDeletedBranch(_ context: BranchDeleteRecoveryContext) {
    if let notificationID = branchDeleteNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
    beginFeedbackOperation("Restore branch")
    Task.detached(priority: .userInitiated) {
        do {
            try context.repo.branchCreate(
                name: context.preview.branchName,
                at: context.preview.tipId
            )
            var upstreamError: String?
            if let upstream = context.preview.upstream {
                do {
                    try context.repo.branchSetUpstream(
                        branch: context.preview.branchName,
                        upstream: upstream
                    )
                } catch {
                    upstreamError = errorMessage(error)
                }
            }
            let restoreUpstreamError = upstreamError
            await MainActor.run {
                self.branchWorkspace.deleteRecovery = nil
                if let rootPath = context.rootPath {
                    self.loadMultiRoots()
                    if let restoreUpstreamError {
                        self.feedbackCenter.warning(
                            "Branch restored",
                            detail: "\(context.preview.branchName) · \(rootPath). Upstream was not restored: \(restoreUpstreamError)"
                        )
                    } else {
                        self.feedbackCenter.success("Branch restored", detail: "\(context.preview.branchName) · \(rootPath)")
                    }
                } else {
                    self.branchWorkspace.branches = (try? context.repo.branchList()) ?? self.branchWorkspace.branches
                    self.loadRepoData()
                    if let restoreUpstreamError {
                        self.feedbackCenter.warning(
                            "Branch restored",
                            detail: "\(context.preview.branchName). Upstream was not restored: \(restoreUpstreamError)"
                        )
                    } else {
                        self.feedbackCenter.success("Branch restored", detail: context.preview.branchName)
                    }
                    if self.projectWorkspace.toolWindowMode == .log { self.loadLog() }
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Restore branch failed",
                    detail: "\(context.preview.branchName): \(errorMessage(error))",
                    additionalActions: self.branchDeleteRestoreAction(
                        contexts: [context],
                        title: "Retry Restore"
                    ).map { [$0] } ?? [],
                    notificationID: self.branchDeleteNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

func restoreDeletedTags(_ contexts: [TagDeleteRecoveryContext]) {
    guard !contexts.isEmpty else { return }
    tagWorkspace.multiRootDeleteRecovery = nil
    beginFeedbackOperation("Restore multi-root tags")
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [TagDeleteRecoveryContext] = []
        for context in contexts {
            do {
                try context.repo.tagCreate(name: context.tag.name, at: context.tag.id)
            } catch {
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")): \(errorMessage(error))"
                )
                remaining.append(context)
            }
        }
        let failuresToReport = failures
        let remainingContexts = remaining
        await MainActor.run {
            self.loadMultiRoots()
            if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root tag restore completed",
                    detail: contexts.first?.tag.name ?? ""
                )
            } else {
                self.tagWorkspace.multiRootDeleteRecovery = remainingContexts.isEmpty
                    ? nil
                    : MultiRootTagDeleteRecoveryContext(
                        tagName: contexts.first?.tag.name ?? "",
                        contexts: remainingContexts
                    )
                self.feedbackCenter.warning(
                    "Multi-root tag restore partially failed",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the affected roots and retry the remaining restore action."
                )
            }
        }
    }
}

/// Run a standalone SubmodulePanel operation from durable input, keeping the
/// same command, credential broker, cancellation, and notification lifecycle
/// for both the initial click and a retry restored from Operation Log.
func submoduleUpdateRestoreAction(
    repo: Repository,
    rootPath: String
) -> FeedbackAction? {
    guard let info = ((try? repo.applyLocalChangesRestoreInfo()) ?? nil),
          info.operation == "submodule-update",
          let savedChangesKind = ArborVCSActionRequest.SavedChangesKind(rawValue: info.kind) else {
        return nil
    }
    let request = ArborVCSActionRequest(
        kind: .restoreApplyLocalChanges,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        savedChangesKind: savedChangesKind,
        savedChangesID: info.identifier
    )
    return FeedbackAction(title: "Resolve local changes", semanticAction: request) {
        self.openApplyLocalChangesRestore(request)
    }
}

func restoreDeletedTag(_ context: TagDeleteRecoveryContext) {
    beginFeedbackOperation("Restore tag")
    Task.detached(priority: .userInitiated) {
        do {
            // IntelliJ restores the saved tag tip as a new lightweight tag;
            // using the full peeled id avoids dependence on reflog retention.
            try context.repo.tagCreate(name: context.tag.name, at: context.tag.id)
            await MainActor.run {
                self.tagWorkspace.deleteRecovery = nil
                if let rootPath = context.rootPath {
                    self.loadMultiRoots()
                    self.feedbackCenter.success("Tag restored", detail: "\(context.tag.name) · \(rootPath)")
                } else {
                    self.refreshAll(showFeedback: false)
                    self.feedbackCenter.success("Tag restored", detail: context.tag.name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Restore tag failed",
                    detail: "\(context.tag.name): \(errorMessage(error))"
                )
            }
        }
    }
}

}
