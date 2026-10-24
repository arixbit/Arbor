import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func resetCurrentBranchToRemote() {
    guard let repository = repo else { return }
    guard multiRootWorkspace.roots.count == 1,
          branchWorkspace.branches.contains(where: { $0.isCurrent }),
          currentSyncStatus?.trackingExists == true,
          !(currentSyncStatus?.upstream.isEmpty ?? true) else {
        feedbackCenter.warning(
            "Reset to Remote Branch unavailable",
            detail: "This action requires one Git root, a checked-out branch, and a tracked remote branch.",
            nextStep: "Fetch the remote or configure an upstream, then retry."
        )
        return
    }
    guard let currentBranch = branchWorkspace.branches.first(where: { $0.isCurrent })?.name,
          let sync = currentSyncStatus,
          let separator = sync.upstream.firstIndex(of: "/") else {
        feedbackCenter.warning(
            "Reset to Remote Branch unavailable",
            detail: "The current branch has no usable tracked remote branch.",
            nextStep: "Configure an upstream branch, then retry."
        )
        return
    }

    let upstream = sync.upstream
    let remote = String(upstream[..<separator])
    guard !remote.isEmpty, !upstream[upstream.index(after: separator)...].isEmpty else {
        feedbackCenter.warning(
            "Reset to Remote Branch unavailable",
            detail: "The configured upstream is invalid: \(upstream)",
            nextStep: "Choose a valid upstream branch, then retry."
        )
        return
    }

    let saveChoice = GitLocalChangesSavePolicySettings.choice(for: projectWorkspace.path)
    let alert = NSAlert()
    alert.messageText = String(localized: "Reset to Remote Branch?")
    alert.informativeText = [
        "Reset \(currentBranch) to \(upstream) after fetching the remote tip.",
        "Local commits on \(currentBranch) will no longer be reachable from that branch.",
        "Uncommitted changes will be preserved with \(saveChoice.title) when needed, and the completed reset can be undone."
    ].joined(separator: "\n\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Reset to Remote Branch")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    let cancel = GitCancelHandle()
    beginFeedbackOperation(
        "Reset to Remote Branch",
        cancelHandle: cancel,
        notificationID: resetRecoveryNotificationID()
    )
    Task.detached(priority: .userInitiated) {
        do {
            _ = try repository.fetchRemoteBranchWithOptionsAndAuthAndCancel(
                remote: remote,
                branch: upstream,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            guard !Task.isCancelled, !cancel.isCancelled() else {
                throw EngineError.Cancelled
            }
            let remoteID = try repository.revisionCommitId(revision: upstream)
            let recovery = try repository.resetWithRecovery(
                commitId: remoteID,
                mode: .hard,
                savePolicy: savePolicy,
                smart: true,
                force: false
            )
            await MainActor.run {
                let recoveryTarget = recovery.rollbackId.map {
                    PersistedResetRecoveryTarget(
                        rootPath: repository.workdir() ?? "",
                        displayName: URL(fileURLWithPath: repository.workdir() ?? "").lastPathComponent,
                        initialHead: recovery.initialHead,
                        expectedHead: recovery.finalHead,
                        expectedHeadBranch: recovery.finalBranch,
                        mode: .hard,
                        rollbackID: $0
                    )
                }
                self.feedbackCenter.success(
                    "Reset to Remote Branch completed",
                    detail: "\(currentBranch) → \(upstream) · \(String(remoteID.prefix(7)))",
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
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Reset to Remote Branch",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repository,
                            rootPath: repository.workdir()
                        ).map { [$0] } ?? [],
                        stashID: stashID
                    )
                } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        repository: repository,
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repository,
                            rootPath: repository.workdir()
                        ).map { [$0] } ?? []
                    )
                } else if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Reset to Remote Branch cancelled",
                        detail: "The remote branch was fetched, but the local branch was not reset.",
                        notificationID: self.resetRecoveryNotificationID(),
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        "Reset to Remote Branch failed",
                        detail: friendlyRemoteError(error),
                        nextStep: "Check the upstream branch and working tree, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repository,
                            rootPath: repository.workdir()
                        ).map { [$0] } ?? [],
                        notificationID: self.resetRecoveryNotificationID(),
                        notificationGroup: .important
                    )
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
            }
        }
    }
}

func smartCheckoutRemoteBranch(
    repo: Repository,
    remoteBranch: String,
    onSuccess: @escaping () -> Void = {}
) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Smart Checkout", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.smartCheckoutRemoteBranchWithPolicyAndCancel(
                remoteBranch: remoteBranch,
                localName: nil,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Smart Checkout completed", detail: remoteBranch)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Smart Checkout cancelled",
                        detail: remoteBranch,
                        nextStep: "The preservation Shelf was kept when restore had started; retry after reviewing the root."
                    )
                }
            } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                await MainActor.run {
                    let viewAction = stashID.flatMap {
                        self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: $0,
                            rootPath: repo.workdir()
                        )
                    }
                    self.showStashRestoreConflict(
                        paths,
                        additionalActions: viewAction.map { [$0] } ?? [],
                        stashID: stashID
                    )
                }
            } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                await MainActor.run {
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: .shelf,
                        identifier: name,
                        rootPath: repo.workdir()
                    )
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                }
            } else {
                await MainActor.run {
                    self.repositoryStatus.loadError = errorMessage(error)
                    self.feedbackCenter.error(
                        "Smart Checkout failed",
                        detail: errorMessage(error),
                        nextStep: "The original local changes were restored when possible."
                    )
                }
            }
        }
    }
}

func forceCheckoutRemoteBranch(
    repo: Repository,
    remoteBranch: String,
    onSuccess: @escaping () -> Void = {}
) {
    beginFeedbackOperation("Force Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.forceCheckoutRemoteBranch(remoteBranch: remoteBranch, localName: nil)
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Force Checkout completed", detail: remoteBranch)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Force Checkout failed", detail: errorMessage(error))
            }
        }
    }
}

func checkoutRemoteBranch(_ branch: RemoteBranchInfo) {
    guard let repo else { return }
    beginFeedbackOperation("Checkout remote branch")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.checkoutRemoteBranch(remoteBranch: branch.name, localName: nil)
            await MainActor.run {
                self.feedbackCenter.success("Remote branch checked out", detail: branch.name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: branch.name,
                    detail: detail,
                    onSmart: { self.smartCheckoutRemoteBranch(repo: repo, remoteBranch: branch.name) },
                    onForce: { self.forceCheckoutRemoteBranch(repo: repo, remoteBranch: branch.name) }
                )
            }
        }
    }
}

}
