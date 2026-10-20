import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func resetCommit(_ commit: CommitInfo, mode: ResetMode) {
    guard let repo = logRepository(for: commit) else { return }
    GitResetModeSettings.save(GitResetModeChoice(mode), for: projectWorkspace.path)
    runResetCommit(repo: repo, id: commit.id, mode: mode, preserveLocalChanges: false)
}

func runResetCommit(
    repo: Repository,
    id: String,
    mode: ResetMode,
    preserveLocalChanges: Bool
) {
    beginFeedbackOperation("Reset branch")
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        do {
            let recovery = try repo.resetWithRecovery(
                commitId: id,
                mode: mode,
                savePolicy: projectSavePolicy,
                smart: preserveLocalChanges,
                force: false
            )
            await MainActor.run {
                self.commitWorkspace.feedback = "已 \(resetModeName(mode)) reset 到 \(String(id.prefix(7)))"
                let recoveryTarget = recovery.rollbackId.map {
                    PersistedResetRecoveryTarget(
                        rootPath: repo.workdir() ?? "",
                        displayName: URL(fileURLWithPath: repo.workdir() ?? "").lastPathComponent,
                        initialHead: recovery.initialHead,
                        expectedHead: recovery.finalHead,
                        expectedHeadBranch: recovery.finalBranch,
                        mode: mode,
                        rollbackID: $0
                    )
                }
                self.feedbackCenter.success(
                    "Reset completed",
                    detail: "\(resetModeName(mode)) · \(String(id.prefix(7)))",
                    additionalActions: recoveryTarget.map {
                        self.resetRecoveryActions(targets: [$0])
                    } ?? [],
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.commitWorkspace.feedback = errorMessage(error)
                if case let .LocalChangesWouldBeOverwritten(paths) = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Reset needs a decision",
                        detail: paths.joined(separator: ", "),
                        nextStep: "Choose Smart Reset to preserve local changes, or cancel and keep the current worktree."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Reset",
                        paths: paths,
                        detail: errorMessage(error),
                        smartButtonTitle: "Smart Reset",
                        forceButtonTitle: mode == .hard ? "Reset hard anyway" : nil,
                        onSmart: {
                            self.runResetCommit(
                                repo: repo,
                                id: id,
                                mode: mode,
                                preserveLocalChanges: true
                            )
                        },
                        onForce: mode == .hard ? {
                            self.forceResetCommit(repo: repo, id: id)
                        } : nil
                    )
                } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Reset",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? [],
                        stashID: stashID
                    )
                } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? []
                    )
                } else {
                    self.feedbackCenter.error(
                        "Reset failed",
                        detail: errorMessage(error),
                        nextStep: "Check the target revision and current Git state, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? []
                    )
                }
            }
        }
    }
}

func forceResetCommit(repo: Repository, id: String) {
    beginFeedbackOperation("Force reset branch")
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        do {
            let recovery = try repo.resetWithRecovery(
                commitId: id,
                mode: .hard,
                savePolicy: projectSavePolicy,
                smart: false,
                force: true
            )
            await MainActor.run {
                self.commitWorkspace.feedback = "已 hard reset 到 \(String(id.prefix(7)))"
                let recoveryTarget = recovery.rollbackId.map {
                    PersistedResetRecoveryTarget(
                        rootPath: repo.workdir() ?? "",
                        displayName: URL(fileURLWithPath: repo.workdir() ?? "").lastPathComponent,
                        initialHead: recovery.initialHead,
                        expectedHead: recovery.finalHead,
                        expectedHeadBranch: recovery.finalBranch,
                        mode: .hard,
                        rollbackID: $0
                    )
                }
                self.feedbackCenter.success(
                    "Hard reset completed",
                    detail: String(id.prefix(7)),
                    additionalActions: recoveryTarget.map {
                        self.resetRecoveryActions(targets: [$0])
                    } ?? [],
                    notificationID: self.resetRecoveryNotificationID(),
                    notificationGroup: .standard
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Hard reset failed",
                    detail: errorMessage(error),
                    nextStep: "No local changes were restored; inspect the current Git state before retrying."
                )
            }
        }
    }
}

/// Reset the same revision across all discovered Git roots. The first pass is
/// deliberately direct so the engine can return every affected path; only the
/// explicit Smart/Force choice retries the roots that were actually blocked.
func resetCommitsAcrossRoots(_ commit: CommitInfo, mode: ResetMode) {
    guard let projectPath = projectWorkspace.path, multiRootWorkspace.roots.count > 1 else { return }
    GitResetModeSettings.save(GitResetModeChoice(mode), for: projectPath)
    let selectedRootPaths = multiRootWorkspace.roots.map(\.path)
    runMultiRootResetOperation(
        projectPath: projectPath,
        selectedRootPaths: selectedRootPaths,
        commitID: commit.id,
        mode: mode,
        smart: false,
        force: false
    )
}

/// Reset the Log selection with one target revision per owning Git root.
func resetCommitsAcrossRoots(_ commits: [CommitInfo], mode: ResetMode) {
    guard let projectPath = projectWorkspace.path, isResetSelectionAvailable(for: commits) else { return }
    GitResetModeSettings.save(GitResetModeChoice(mode), for: projectPath)
    let targets = commits.compactMap { commit -> MultiRootResetTarget? in
        guard let repository = logRepository(for: commit),
              let rootPath = repository.workdir() else { return nil }
        return MultiRootResetTarget(rootPath: rootPath, commitId: commit.id)
    }
    guard targets.count == commits.count else {
        feedbackCenter.error(
            "Reset unavailable",
            detail: "One or more selected revisions no longer belongs to an available Git root.",
            nextStep: "Refresh the Log and select the revisions again."
        )
        return
    }
    runMultiRootResetOperation(
        projectPath: projectPath,
        selectedRootPaths: targets.map(\.rootPath),
        targetSpecs: targets,
        mode: mode,
        smart: false,
        force: false
    )
}

}
