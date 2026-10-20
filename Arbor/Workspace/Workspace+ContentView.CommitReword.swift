import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
/// Commit success notifications in IntelliJ expose a Reword action while the
/// newly created commit is still the repository HEAD. Keep the request tied
/// to the owning root and commit id so a notification from a nested root
/// cannot accidentally rewrite the primary repository after a reload.
func commitRewordFeedbackAction(
    rootPath: String,
    commitID: String
) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .rewordCommit,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        rewordCommitID: commitID
    )
    return FeedbackAction(
        id: "reword-commit:\(rootPath):\(commitID)",
        title: "Reword Commit",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func commitNotificationID(rootPath: String) -> String {
    let stableRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.commit.\(stableRoot)"
}

/// Reopen the exact Git root and commit referenced by a commit notification,
/// then enter the same HEAD-only reword flow used by the Log action group.
/// The HEAD check is repeated after loading the commit so a stale notification
/// can never rewrite a newer commit created after the original commit.
func openRewordCommit(rootPath: String, commitID: String) {
    let normalizedRootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let normalizedCommitID = commitID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedCommitID.isEmpty,
          let rootRepo = try? openRepository(path: normalizedRootPath) else {
        feedbackCenter.error(
            "Reword Commit unavailable",
            detail: "The Git root or commit from the notification is no longer available.",
            nextStep: "Refresh Git Roots and retry from Log."
        )
        return
    }

    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    logSelectionState.selection = nil
    logSelectionState.selectedIDs = []
    logList.viewMode = .graph
    projectWorkspace.toolWindowMode = .log
    toolWindowExpanded = true
    projectPanelExpanded = false

    let primaryRoot = repo?.workdir().map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    if normalizedRootPath == primaryRoot {
        logList.activeRootPath = nil
        logList.activeRepo = nil
        logRuntime.activeBranches = []
        logRuntime.activeRemoteBranches = []
        logRuntime.activeRemotes = []
    } else {
        logList.activeRootPath = normalizedRootPath
        logList.activeRepo = rootRepo
        logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
        logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
        logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
    }
    loadLog()

    Task.detached(priority: .userInitiated) {
        do {
            guard rootRepo.headCommitId() == normalizedCommitID else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The committed HEAD has changed."]
                )
            }
            let commit = try rootRepo.logFiltered(
                path: nil,
                limit: 1,
                follow: false,
                startRev: normalizedCommitID,
                author: nil,
                since: nil
            ).first { candidate in
                candidate.id == normalizedCommitID
                    || candidate.id.hasPrefix(normalizedCommitID)
                    || normalizedCommitID.hasPrefix(candidate.id)
            }
            guard let commit, rootRepo.headCommitId() == commit.id else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The committed HEAD has changed."]
                )
            }
            await MainActor.run {
                guard self.isActiveLogRepository(rootRepo) else { return }
                self.logSelectionState.selection = commit.id
                self.logSelectionState.selectedIDs = [commit.id]
                self.logSelectionState.detailCommit = commit
                self.logRewrite.rewordCommit = commit
                self.logRewrite.rewordMessage = commit.messageBody.isEmpty
                    ? commit.summary
                    : "\(commit.summary)\n\n\(commit.messageBody)"
                self.logRewrite.rewordUsesRootRebase = false
                if commit.parentIds.isEmpty {
                    self.logRewrite.pendingInitialCommitReword = commit
                    self.logRewrite.showInitialCommitRewordAlert = true
                } else {
                    self.logRewrite.showRewordDialog = true
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.warning(
                    "Reword Commit unavailable",
                    detail: errorMessage(error),
                    nextStep: "The action applies only while the referenced commit remains the current HEAD."
                )
            }
        }
    }
}

/// Undo a successful reword by restoring only the original HEAD ref. The
/// expected HEAD and branch make the operation compare-and-swap safe, while
/// the protected-remote check mirrors IntelliJ's refusal to rewrite published
/// history. No index or worktree materialization is performed.
func undoRewordCommit(
    rootPath: String,
    context: PersistedRewordUndo
) {
    let notificationID = rewordUndoNotificationID(
        rootPath: rootPath,
        expectedHeadID: context.expectedHeadID
    )
    let protectedPatterns = effectiveProtectedBranchPatterns
    beginFeedbackOperation("Undo Reword Commit", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let targetRepo = try openRepository(path: rootPath)
            guard try targetRepo.operationState() == nil else {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit is unavailable while another Git operation is active."
                )
            }
            guard targetRepo.headCommitId() == context.expectedHeadID else {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit refused: HEAD changed after reword."
                )
            }
            let currentBranch = try targetRepo.branchList()
                .first(where: { $0.isCurrent })?.name ?? ""
            guard currentBranch == context.expectedBranch else {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit refused: the current branch changed after reword."
                )
            }
            let remoteBranches = try targetRepo.remoteBranchList()
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: targetRepo,
                commitID: context.initialHeadID,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                throw EngineError.GitOperation(
                    message: "Undo Reword Commit blocked: \(protectedBranch) contains the published commit."
                )
            }
            try targetRepo.restoreHeadRefIfExpected(
                initialCommitId: context.initialHeadID,
                expectedCommitId: context.expectedHeadID,
                expectedHeadBranch: context.expectedBranch
            )
            await MainActor.run {
                self.feedbackCenter.expire(notificationID: notificationID)
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
                    "Reword undone",
                    detail: "HEAD restored to \(String(context.initialHeadID.prefix(8)))."
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Reword Commit failed",
                    detail: errorMessage(error),
                    nextStep: "The repository may have changed after reword; review the current HEAD and branch before retrying.",
                    notificationID: notificationID
                )
            }
        }
    }
}

}
