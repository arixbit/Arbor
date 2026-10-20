import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Open the Uncommit chooser against the repository that owns the selected
/// Log commit. This matters in aggregate/multi-root Log: the visible HEAD may
/// belong to a nested repository rather than the primary Commit workspace.
func uncommitFromLog(_ selectedCommit: CommitInfo) {
    guard isUncommitActionAvailable(for: selectedCommit) else {
        feedbackCenter.warning(
            "Undo commit unavailable",
            detail: "Only the current HEAD commit with a parent can be undone.",
            nextStep: "Select the latest commit in the owning Git root."
        )
        return
    }
    guard let selectedRepo = logRepository(for: selectedCommit) else {
        feedbackCenter.error(
            "Undo commit unavailable",
            detail: "The Git root for the selected commit is no longer available.",
            nextStep: "Refresh Git roots and retry."
        )
        return
    }
    let protectedPatterns = effectiveProtectedBranchPatterns
    Task.detached(priority: .userInitiated) {
        do {
            guard let repositoryPath = selectedRepo.workdir() else {
                throw EngineError.GitOperation(message: "Undo commit requires a worktree repository.")
            }
            guard selectedRepo.headCommitId() == selectedCommit.id else {
                throw EngineError.GitOperation(
                    message: "The selected commit is no longer HEAD in its Git root."
                )
            }
            guard let head = try selectedRepo.log(path: nil, limit: 1, follow: false, afterId: nil).first,
                  let parentID = head.parentIds.first else {
                throw EngineError.GitOperation(message: "Undo commit requires a HEAD commit with a parent.")
            }
            let remoteBranches = try selectedRepo.remoteBranchList()
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: selectedRepo,
                commitID: head.id,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Undo commit blocked",
                        detail: "The selected commit is published to protected branch \(protectedBranch).",
                        nextStep: "Fetch or select an unpublished commit before rewriting history."
                    )
                }
                return
            }
            let changes = try selectedRepo.treeChanges(rev1: parentID, rev2: head.id)
            let changedPaths = uncommitChangedPaths(changes)
            let rootChangeLists = try selectedRepo.changelistList()
            let headBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            await MainActor.run {
                self.commitWorkspace.uncommitRequest = RebasedUncommitRequest(
                    commit: head,
                    repositoryPath: repositoryPath,
                    changedPaths: changedPaths,
                    changeLists: rootChangeLists,
                    headBranch: headBranch
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo commit unavailable",
                    detail: errorMessage(error),
                    nextStep: "Select a non-root HEAD commit."
                )
            }
        }
    }
}

func performUncommit(_ request: RebasedUncommitRequest, targetName: String) {
    let restoredCommitMessage = request.commit.messageBody.isEmpty
        ? request.commit.summary
        : "\(request.commit.summary)\n\n\(request.commit.messageBody)"
    beginFeedbackOperation("Undo commit")
    Task.detached(priority: .userInitiated) {
        var didUncommit = false
        do {
            let targetRepo = try openRepository(path: request.repositoryPath)
            guard targetRepo.headCommitId() == request.commit.id else {
                throw EngineError.GitOperation(
                    message: "The selected commit is no longer HEAD in its Git root."
                )
            }
            let normalizedTargetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedTargetName.isEmpty {
                // Create/lookup the target before the destructive soft reset.
                try targetRepo.changelistEnsure(name: normalizedTargetName)
            }
            try targetRepo.uncommitExpectedHead(expectedHead: request.commit.id)
            didUncommit = true
            let statusPaths = Set(try targetRepo.status().map(\.path))
            let assignablePaths = request.changedPaths.filter(statusPaths.contains)
            if !normalizedTargetName.isEmpty, !assignablePaths.isEmpty {
                try targetRepo.changelistMovePaths(paths: assignablePaths, targetName: normalizedTargetName)
            }
            let lists = try targetRepo.changelistList()
            await MainActor.run {
                // IntelliJ restores the undone commit's full message into the
                // Changes workflow so the user can recommit without copying it.
                self.commitWorkspace.message = restoredCommitMessage
                self.commitWorkspace.feedback = "已撤销最近一次提交，变更仍保留在暂存区"
                if self.repo?.workdir() == request.repositoryPath {
                    self.repositoryStatus.changeLists = lists
                    self.refreshAll(showFeedback: false)
                } else {
                    self.loadMultiRoots {
                        if self.logList.viewMode == .command || self.isLogAggregate {
                            self.reloadLogView()
                        }
                    }
                }
                let undoAction = self.uncommitUndoFeedbackAction(for: request)
                self.feedbackCenter.success(
                    "Latest commit undone",
                    detail: normalizedTargetName.isEmpty
                        ? "Changes remain staged"
                        : "Changes moved to \(normalizedTargetName)",
                    additionalActions: undoAction.map { [$0] } ?? [],
                    notificationID: self.uncommitUndoNotificationID(
                        rootPath: request.repositoryPath
                    )
                )
            }
        } catch {
            let uncommitDidComplete = didUncommit
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo commit failed",
                    detail: errorMessage(error),
                    nextStep: uncommitDidComplete
                        ? "Uncommit 已完成，但后续 Changelist 同步失败；先恢复或重新检查当前状态。"
                        : "确认当前提交存在父提交且工作区状态允许 soft reset。",
                    additionalActions: uncommitDidComplete
                        ? (self.uncommitUndoFeedbackAction(for: request).map { [$0] } ?? [])
                        : [],
                    notificationID: uncommitDidComplete
                        ? self.uncommitUndoNotificationID(rootPath: request.repositoryPath)
                        : nil
                )
            }
        }
    }
}

func uncommitUndoNotificationID(rootPath: String) -> String {
    let normalized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.uncommit-undo.\(normalized)"
}

func uncommitUndoRequest(
    for request: RebasedUncommitRequest
) -> ArborVCSActionRequest? {
    guard let expectedHead = request.commit.parentIds.first else { return nil }
    return ArborVCSActionRequest(
        kind: .undoUncommit,
        projectPath: projectWorkspace.path,
        rootPath: request.repositoryPath,
        shelfName: "",
        uncommitCommitID: request.commit.id,
        uncommitExpectedHead: expectedHead,
        uncommitExpectedBranch: request.headBranch ?? ""
    )
}

func uncommitUndoFeedbackAction(
    for request: RebasedUncommitRequest
) -> FeedbackAction? {
    guard let semanticRequest = uncommitUndoRequest(for: request) else { return nil }
    return FeedbackAction(
        id: "undo-uncommit:\(semanticRequest.rootPath ?? ""):\(semanticRequest.uncommitCommitID ?? "")",
        title: "Undo Uncommit",
        semanticAction: semanticRequest
    ) {
        handleVCSActionRequest(semanticRequest)
    }
}

/// Restore the exact commit that was just soft-uncommitted. The engine only
/// moves the ref and checks both the expected parent and branch identity, so
/// local edits made after the Uncommit are never rewritten.
func undoUncommit(
    rootPath: String,
    originalCommitID: String,
    expectedHead: String,
    expectedBranch: String
) {
    beginFeedbackOperation("Undo Uncommit")
    Task.detached(priority: .userInitiated) {
        do {
            let targetRepo = try openRepository(path: rootPath)
            try targetRepo.undoUncommitExpectedHead(
                originalCommitId: originalCommitID,
                expectedHead: expectedHead,
                expectedBranch: expectedBranch
            )
            await MainActor.run {
                self.feedbackCenter.expire(
                    notificationID: self.uncommitUndoNotificationID(rootPath: rootPath)
                )
                let isCurrentRoot = self.repo?.workdir().map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                        == URL(fileURLWithPath: rootPath).standardizedFileURL.path
                } == true
                if isCurrentRoot {
                    self.refreshAll(showFeedback: false)
                } else {
                    self.loadMultiRoots {
                        if self.logList.viewMode == .command || self.isLogAggregate {
                            self.reloadLogView()
                        }
                    }
                }
                self.feedbackCenter.success(
                    "Uncommit undone",
                    detail: "HEAD restored to \(String(originalCommitID.prefix(8)))."
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Uncommit failed",
                    detail: errorMessage(error),
                    nextStep: "The repository changed after Uncommit; review the current branch and retry only if the original HEAD is still intended."
                )
            }
        }
    }
}

}
