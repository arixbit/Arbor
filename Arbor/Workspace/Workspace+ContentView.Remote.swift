import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// IntelliJ's Add Commits to Remote Branch action fetches only the selected
/// remote branch, replays the selected commits without touching the checked
/// out worktree, and then hands the detached result to the normal Push dialog.
func addCommitsToRemoteBranchNotificationID(repositoryPath: String) -> String {
    let stablePath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.add-commits-to-remote-branch.\(stablePath)"
}

func addCommitsToRemoteBranchFromLog(_ commits: [CommitInfo]) {
    guard let firstCommit = commits.first,
          let commitRepo = logRepository(for: firstCommit) else {
        feedbackCenter.error(
            "Add commits unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }
    var seen = Set<String>()
    let selected = commits.filter { seen.insert($0.id).inserted }
    guard !selected.isEmpty else { return }
    guard isAddCommitsToRemoteBranchAvailable(for: selected) else {
        feedbackCenter.warning(
            "Add commits unavailable",
            detail: "Select linear commits from one Git root.",
            nextStep: "Do not include merge commits or commits from another repository."
        )
        return
    }
    let notificationID = addCommitsToRemoteBranchNotificationID(
        repositoryPath: commitRepo.workdir() ?? ""
    )
    // In an aggregate multi-root Log, the active dashboard root is not
    // necessarily the root that owns the selected commits. Resolve the
    // remote-tracking branches from the commit's repository, just as the
    // subsequent fetch/replay step resolves its Repository instance.
    let remoteBranches = (try? commitRepo.remoteBranchList()) ?? []
    guard !remoteBranches.isEmpty else {
        feedbackCenter.error(
            "Add commits unavailable",
            detail: "No fetched remote branches are available.",
            nextStep: "Fetch a remote branch, then retry.",
            notificationID: notificationID
        )
        return
    }
    addCommitsToRemoteBranchContext = AddCommitsToRemoteBranchContext(
        commits: selected,
        remoteBranches: remoteBranches
    )
}

func prepareAddCommitsToRemoteBranch(
    _ remoteBranch: RemoteBranchInfo,
    commits: [CommitInfo]
) {
    guard isAddCommitsToRemoteBranchAvailable(for: commits) else {
        feedbackCenter.warning(
            "Add commits unavailable",
            detail: "Select linear commits from one Git root.",
            nextStep: "Do not include merge commits or commits from another repository."
        )
        return
    }
    guard let firstCommit = commits.first,
          let repo = logRepository(for: firstCommit) else {
        feedbackCenter.warning(
            "Add commits unavailable",
            detail: "Selected commits must belong to one Git root.",
            nextStep: "Select commits from one repository and retry."
        )
        return
    }
    let branch = ContentView.branchNameForProtection(remoteBranch)
    let ordered = commits.count > 1 ? Array(commits.reversed()) : commits
    let commitIDs = ordered.map(\.id)
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let cancel = GitCancelHandle()
    let notificationID = addCommitsToRemoteBranchNotificationID(
        repositoryPath: repo.workdir() ?? ""
    )
    beginFeedbackOperation(
        "Add commits to remote branch",
        cancelHandle: cancel,
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            _ = try repo.fetchRemoteBranchWithOptionsAndAuthAndCancel(
                remote: remoteBranch.remote,
                branch: branch,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            guard !Task.isCancelled, !cancel.isCancelled() else {
                throw EngineError.Cancelled
            }
            let tip = try repo.prepareAddCommitsToRemoteBranch(
                remote: remoteBranch.remote,
                branch: branch,
                commitIds: commitIDs
            )
            guard !Task.isCancelled, !cancel.isCancelled() else {
                throw EngineError.Cancelled
            }
            await MainActor.run {
                guard !cancel.isCancelled() else {
                    self.feedbackCenter.warning(
                        "Add commits to remote branch canceled",
                        detail: "The remote branch was fetched, but no detached replay was published.",
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                    return
                }
                if let tip {
                    self.feedbackCenter.success(
                        "Commits prepared for remote branch",
                        detail: "Prepared detached tip \(tip) for \(remoteBranch.name).",
                        notificationID: notificationID,
                        notificationGroup: .standard
                    )
                    self.pushDialogMode = .addCommitsToRemoteBranch
                    self.pushDialogRemote = remoteBranch.remote
                    self.pushDialogBranch = branch
                    self.pushDialogSourceRevision = tip
                    self.pushDialogRefspec = nil
                    self.showPushDialog = true
                } else {
                    self.feedbackCenter.success(
                        "No commits to add",
                        detail: "All selected changes are already present on \(remoteBranch.name).",
                        notificationID: notificationID,
                        notificationGroup: .standard
                    )
                }
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                if let engineError = error as? EngineError, case .Cancelled = engineError {
                    self.feedbackCenter.warning(
                        "Add commits to remote branch canceled",
                        detail: "The remote branch was fetched, but no detached replay was published.",
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        "Add commits to remote branch failed",
                        detail: detail,
                        nextStep: "Resolve the conflict or authentication problem, then retry.",
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                }
                if self.isAuthenticationFailure(error) {
                    self.showHostingAuthPrompt = true
                }
            }
        }
    }
}

/// Returns the first protected remote branch that contains a commit. This is
/// the same reachability rule IntelliJ uses before Log history editing: a
/// published commit on a protected branch must not be rewritten locally.
nonisolated static func protectedRemoteBranchNameContainingCommit(
    commitID: String,
    remoteBranches: [RemoteBranchInfo],
    protectedPatterns: [String],
    isReachable: (String, String) -> Bool
) -> String? {
    remoteBranches.first { remoteBranch in
        GitProtectedBranchRules.matches(
            ContentView.branchNameForProtection(remoteBranch),
            patterns: protectedPatterns
        ) && isReachable(commitID, remoteBranch.name)
    }?.name
}

nonisolated func protectedRemoteBranchContainingCommit(
    repo: Repository,
    commitID: String,
    remoteBranches: [RemoteBranchInfo],
    protectedPatterns: [String]
) -> String? {
    let containingBranches = Set(
        (try? repo.commitContainingBranches(commitId: commitID)) ?? []
    )
    return remoteBranches.first { remoteBranch in
        GitProtectedBranchRules.matches(
            ContentView.branchNameForProtection(remoteBranch),
            patterns: protectedPatterns
        ) && containingBranches.contains(remoteBranch.name)
    }?.name
}

func trackedRemoteProtectionName(_ remoteBranch: String) -> String {
    String(remoteBranch.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/"))
}

func deleteTrackedRemoteBranch(_ context: BranchDeleteRecoveryContext) {
    guard let remoteBranch = context.trackedRemoteBranch else { return }
    deleteTrackedRemoteBranch(remoteBranch, contexts: [context])
}

func deleteTrackedRemoteBranch(
    _ remoteBranch: String,
    contexts: [BranchDeleteRecoveryContext]
) {
    let normalizedRemoteBranch = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRemoteBranch.isEmpty,
          !contexts.isEmpty,
          contexts.contains(where: { $0.trackedRemoteBranch == normalizedRemoteBranch }) else {
        return
    }
    guard !GitProtectedBranchRules.matches(
        trackedRemoteProtectionName(normalizedRemoteBranch),
        patterns: effectiveProtectedBranchPatterns
    ) else {
        feedbackCenter.warning(
            "Tracked remote branch is protected",
            detail: normalizedRemoteBranch,
            nextStep: "Edit Protected Branches in Settings before deleting it."
        )
        return
    }

    let roots = contexts.filter { $0.trackedRemoteBranch == normalizedRemoteBranch }
    let location = roots.compactMap(\.rootPath).joined(separator: "\n")
    let alert = NSAlert()
    alert.messageText = "Delete tracked remote branch?"
    alert.informativeText = "This will delete \(normalizedRemoteBranch) from the remote repository.\(location.isEmpty ? "" : "\n\n\(location)")"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete tracked remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var succeeded: [BranchDeleteRecoveryContext] = []
        var failures: [String] = []
        var cancelled = false
        for context in roots {
            guard !cancel.isCancelled() else {
                cancelled = true
                break
            }
            do {
                try context.repo.deleteRemoteBranchWithAuthAndCancel(
                    remoteBranch: normalizedRemoteBranch,
                    broker: broker,
                    cancel: cancel
                )
                succeeded.append(context)
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")): \(friendlyRemoteError(error))"
                )
            }
        }
        let succeededIDs = Set(succeeded.map(\.id))
        let failuresToReport = failures
        let cancelledToReport = cancelled
        await MainActor.run {
            if let context = self.branchDeleteRecovery,
               context.trackedRemoteBranch == normalizedRemoteBranch,
               succeededIDs.contains(context.id) {
                self.branchDeleteRecovery = BranchDeleteRecoveryContext(
                    repo: context.repo,
                    preview: context.preview,
                    rootPath: context.rootPath,
                    trackedRemoteBranch: nil
                )
            }
            if let context = self.multiRootBranchDeleteRecovery {
                let updatedContexts = context.contexts.map { item in
                    guard item.trackedRemoteBranch == normalizedRemoteBranch,
                          succeededIDs.contains(item.id) else { return item }
                    return BranchDeleteRecoveryContext(
                        repo: item.repo,
                        preview: item.preview,
                        rootPath: item.rootPath,
                        trackedRemoteBranch: nil
                    )
                }
                self.multiRootBranchDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: context.branchName,
                    contexts: updatedContexts
                )
            }
            if roots.contains(where: { $0.rootPath != nil }) {
                self.loadMultiRoots()
            }
            if roots.contains(where: { $0.rootPath == nil }) {
                self.loadRepoData()
            }
            if failuresToReport.isEmpty && !cancelledToReport {
                self.feedbackCenter.success(
                    "Tracked remote branch deleted",
                    detail: normalizedRemoteBranch
                )
            } else {
                var details = failuresToReport
                if cancelledToReport {
                    details.insert("Operation cancelled.", at: 0)
                }
                self.feedbackCenter.warning(
                    "Tracked remote branch deletion partially failed",
                    detail: details.joined(separator: "\n"),
                    nextStep: "Retry the remaining remote deletion from the recovery sheet."
                )
            }
        }
    }
}

func chooseUpstreamFeedbackAction(for error: Error) -> FeedbackAction? {
    let branch: String
    switch error as? EngineError {
    case let .NoUpstream(name):
        branch = name
    case let .TrackingMissing(name, _):
        branch = name
    default:
        return nil
    }
    guard !branch.isEmpty else { return nil }
    return FeedbackAction(title: "Choose Upstream Branch") {
        self.upstreamLocalBranch = branch
        self.loadRepoData(includeComparisons: false)
        self.showUpstreamDialog = true
    }
}

func resetCurrentBranchToRemote() {
    guard let repository = repo else { return }
    guard multiRoots.count == 1,
          branches.contains(where: { $0.isCurrent }),
          currentSyncStatus?.trackingExists == true,
          !(currentSyncStatus?.upstream.isEmpty ?? true) else {
        feedbackCenter.warning(
            "Reset to Remote Branch unavailable",
            detail: "This action requires one Git root, a checked-out branch, and a tracked remote branch.",
            nextStep: "Fetch the remote or configure an upstream, then retry."
        )
        return
    }
    guard let currentBranch = branches.first(where: { $0.isCurrent })?.name,
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

    let saveChoice = GitLocalChangesSavePolicySettings.choice(for: projectPath)
    let alert = NSAlert()
    alert.messageText = "Reset to Remote Branch?"
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
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
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
                    self.showHostingAuthPrompt = true
                }
            }
        }
    }
}

/// 建立或修改本地分支的 configured upstream。
func setBranchUpstream(_ branch: String, upstream: String) {
    guard let repo else { return }
    let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let upstream = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty, !upstream.isEmpty else { return }
    beginFeedbackOperation("Set branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.branchSetUpstream(branch: branch, upstream: upstream)
            await MainActor.run {
                self.feedbackCenter.success("Upstream configured", detail: "\(branch) → \(upstream)")
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Set upstream failed", detail: errorMessage(error), nextStep: "选择一个有效的 remote-tracking branch 后重试。")
            }
        }
    }
}

/// 清除本地分支的 configured upstream，不删除本地或远程分支。
func unsetBranchUpstream(_ branch: String) {
    guard let repo else { return }
    beginFeedbackOperation("Unset branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.branchUnsetUpstream(branch: branch)
            await MainActor.run {
                self.feedbackCenter.success("Upstream removed", detail: branch)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Unset upstream failed", detail: errorMessage(error))
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
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
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
                self.loadError = nil
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
                    self.loadError = errorMessage(error)
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
                self.loadError = nil
                self.feedbackCenter.success("Force Checkout completed", detail: remoteBranch)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            await MainActor.run {
                self.loadError = errorMessage(error)
                self.feedbackCenter.error("Force Checkout failed", detail: errorMessage(error))
            }
        }
    }
}

/// 多 root Branches Popup 的远程分支删除；保留二次确认，避免把远程
/// tracking ref 的删除误认为仅本地清理。
func deleteRemoteBranchInRoot(rootPath: String, branch: String) {
    let branchName = branch.split(separator: "/", maxSplits: 1)
        .dropFirst()
        .joined(separator: "/")
    let protectedName = branchName.isEmpty ? branch : branchName
    guard !GitProtectedBranchRules.matches(
        protectedName,
        patterns: effectiveProtectedBranchPatterns
    ) else {
        feedbackCenter.warning(
            "Delete remote branch unavailable",
            detail: "Protected branch: \(branch)",
            nextStep: "Remove the protection rule only if deleting this remote branch is intentional."
        )
        return
    }
    let alert = NSAlert()
    alert.messageText = "Delete remote branch?"
    alert.informativeText = "This will delete \(branch) from its remote repository."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                remoteBranch: branch,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Remote branch deleted", detail: "\(branch) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if cancel.isCancelled() {
                    self.feedbackCenter.warning(
                        "Remote branch deletion cancelled",
                        detail: "\(branch) · \(rootPath)",
                        nextStep: "The remote branch was not confirmed as deleted; refresh before retrying."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Delete remote branch failed",
                        detail: "\(branch) · \(rootPath): \(friendlyRemoteError(error))",
                        nextStep: "Check permissions and the remote name, then retry."
                    )
                }
            }
        }
    }
}

func presentMultiRootRemoteDeleteDialog(branch: String) {
    let eligible = multiRootBranchSnapshots.filter { snapshot in
        snapshot.remoteBranches.contains { $0.name == branch }
    }
    guard !eligible.isEmpty else {
        feedbackCenter.warning(
            "Delete remote branch unavailable",
            detail: "No Git root contains " + branch + "."
        )
        return
    }
    multiRootRemoteDeleteBranchName = branch
    multiRootRemoteDeleteSelectedRootPaths = Set(eligible.map(\.rootPath))
    multiRootRemoteDeleteTracking = false
    showMultiRootRemoteDeleteDialog = true
}

func dismissMultiRootRemoteDeleteDialog() {
    showMultiRootRemoteDeleteDialog = false
    multiRootRemoteDeleteBranchName = ""
    multiRootRemoteDeleteSelectedRootPaths = []
    multiRootRemoteDeleteTracking = false
}

/// Delete one remote branch across selected roots. IntelliJ first asks once
/// for the remote deletion and whether common local tracking branches should
/// follow; remote failures are reported per root, but tracking cleanup starts
/// only after every selected remote deletion succeeds. Local force deletions
/// retain exact previews for Restore All.
func deleteMultiRootRemoteBranch(
    remoteBranch: String,
    deleteTracking: Bool,
    selectedRootPaths: Set<String>
) {
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    let branchName = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    let roots = multiRootBranchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.remoteBranches.contains { $0.name == branchName }
    }
    guard !roots.isEmpty else { return }
    let commonTrackingBranches = multiRootCommonTrackingBranches(
        remoteBranch: branchName,
        snapshots: multiRootBranchSnapshots,
        selectedRootPaths: selectedRootPaths
    )
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootRunning = true
    beginFeedbackOperation("Multi-root remote branch deletion", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var recoveryContexts: [BranchDeleteRecoveryContext] = []
        var remoteFailures: [String] = []
        var trackingWarnings: [String] = []
        var cancelled = false
        var repositoriesByRoot: [String: Repository] = [:]
        for snapshot in roots {
            guard !cancel.isCancelled() else {
                cancelled = true
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: false,
                        skipped: true,
                        message: "Cancelled"
                    )
                )
                continue
            }
            do {
                let rootRepo = try openRepository(path: snapshot.rootPath)
                try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                    remoteBranch: branchName,
                    broker: broker,
                    cancel: cancel
                )
                repositoriesByRoot[snapshot.rootPath] = rootRepo
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: true,
                        skipped: false,
                        message: "Deleted \(branchName)"
                    )
                )
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    results.append(
                        RootOperationResult(
                            rootPath: snapshot.rootPath,
                            displayName: snapshot.displayName,
                            success: false,
                            skipped: true,
                            message: "Cancelled"
                        )
                    )
                    continue
                }
                let detail = "\(snapshot.displayName): \(errorMessage(error))"
                remoteFailures.append(detail)
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: false,
                        skipped: false,
                        message: errorMessage(error)
                    )
                )
            }
        }

        // IntelliJ only removes the common local tracking branches after the
        // remote deletion succeeds for every selected repository. A failed
        // remote operation therefore never causes an extra local deletion.
        var trackingDeletedByRoot: [String: Int] = [:]
        if remoteFailures.isEmpty && !cancelled && deleteTracking {
            for localBranch in commonTrackingBranches {
                for snapshot in roots {
                    guard snapshot.branches.contains(where: { $0.name == localBranch && !$0.isCurrent }),
                          let rootRepo = repositoriesByRoot[snapshot.rootPath] else {
                        continue
                    }
                    do {
                        let preview = try rootRepo.branchDeletePreview(name: localBranch)
                        do {
                            try rootRepo.branchDelete(name: localBranch, force: false)
                        } catch {
                            guard isUnmergedBranchDeletionError(error) else { throw error }
                            try rootRepo.branchDelete(name: localBranch, force: true)
                        }
                        recoveryContexts.append(
                            BranchDeleteRecoveryContext(
                                repo: rootRepo,
                                preview: preview,
                                rootPath: snapshot.rootPath
                            )
                        )
                        trackingDeletedByRoot[snapshot.rootPath, default: 0] += 1
                    } catch {
                        let warning = "\(snapshot.displayName): \(localBranch): \(errorMessage(error))"
                        trackingWarnings.append(warning)
                    }
                }
            }
        }
        if remoteFailures.isEmpty, !cancelled, deleteTracking, !commonTrackingBranches.isEmpty {
            for index in results.indices where results[index].success {
                let deletedCount = trackingDeletedByRoot[results[index].rootPath, default: 0]
                results[index].message = deletedCount == commonTrackingBranches.count
                    ? "Deleted \(branchName) and common local tracking branches"
                    : "Deleted \(branchName); local branches kept"
            }
        }
        let resultsToApply = results
        let recoveryContextsToOffer = recoveryContexts
        let remoteFailuresToReport = remoteFailures
        let trackingWarningsToReport = trackingWarnings
        let cancelledToReport = cancelled
        let restoredBranchNames = Array(
            Set(recoveryContextsToOffer.map(\.preview.branchName))
        ).sorted()
        await MainActor.run {
            self.multiRootRunning = false
            self.showMultiRootRemoteDeleteDialog = false
            self.multiRootResults = resultsToApply
            self.loadMultiRoots()
            if !recoveryContextsToOffer.isEmpty {
                self.multiRootBranchDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: restoredBranchNames.joined(separator: ", "),
                    contexts: recoveryContextsToOffer
                )
            }
            var details = remoteFailuresToReport + trackingWarningsToReport
            if cancelledToReport {
                details.insert("Operation cancelled.", at: 0)
            }
            if details.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root remote branch deletion completed",
                    detail: "\(resultsToApply.filter(\.success).count) repositories · \(branchName)",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: recoveryContextsToOffer
                    ),
                    notificationID: recoveryContextsToOffer.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: recoveryContextsToOffer.isEmpty ? .toolWindow : .standard
                )
            } else {
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    cancelledToReport
                        ? "Multi-root remote branch deletion cancelled"
                        : remoteFailuresToReport.isEmpty
                        ? "Remote branch deleted; some local branches kept"
                        : "Multi-root remote branch deletion partially completed",
                    detail: details.joined(separator: "\n"),
                    nextStep: recoveryContextsToOffer.isEmpty
                        ? "Review the affected roots and retry the failed operation."
                        : "Use Restore All if you need to recover the deleted local tracking branches.",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: recoveryContextsToOffer
                    ),
                    notificationID: recoveryContextsToOffer.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: recoveryContextsToOffer.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

/// 多 root tracking 配置使用显式输入，避免把当前 root 的 remote branch 列表
/// 错误地复用到另一个 root。
func setBranchUpstreamInRoot(rootPath: String, branch: String) {
    let alert = NSAlert()
    alert.messageText = "Set Upstream"
    alert.informativeText = "输入 remote-tracking branch，例如 origin/\(branch)。"
    let field = NSTextField(string: "origin/\(branch)")
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Set Upstream")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let upstream = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !upstream.isEmpty else { return }
    setBranchUpstreamInRoot(
        rootPath: rootPath,
        branch: branch,
        upstream: upstream,
        requireCurrentBranch: false
    )
}

/// 保存已从目标 root 的 remote-tracking branch 选择器中选出的 upstream。
/// The write remains explicitly root-scoped; it never falls back to `repo`.
func setBranchUpstreamInRoot(
    rootPath: String,
    branch: String,
    upstream: String,
    requireCurrentBranch: Bool
) {
    beginFeedbackOperation("Set branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if requireCurrentBranch {
                let currentBranch = try rootRepo.branchList().first(where: { $0.isCurrent })?.name
                guard currentBranch == branch else {
                    throw NSError(
                        domain: "Arbor.UpstreamRecovery",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The target root is no longer on branch '\(branch)'."
                        ]
                    )
                }
            }
            try rootRepo.branchSetUpstream(branch: branch, upstream: upstream)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Upstream configured", detail: "\(branch) → \(upstream) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Set upstream failed", detail: "\(branch) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

/// Load the upstream choices from the skipped root itself before showing the
/// shared picker. This matches IntelliJ's repository-qualified recovery action
/// and avoids asking users to hand-type a refspec in a multi-root project.
func presentUpstreamDialogInRoot(rootPath: String, displayName: String, branch: String) {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRoot.isEmpty, !normalizedBranch.isEmpty else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: normalizedRoot)
            let currentBranch = try rootRepo.branchList().first(where: { $0.isCurrent })?.name
            guard currentBranch == normalizedBranch else {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Upstream recovery is stale",
                        detail: "\(displayName) is no longer on branch \(normalizedBranch)."
                    )
                }
                return
            }
            let remoteBranches = try rootRepo.remoteBranchList()
            let currentUpstream = (try? rootRepo.syncStatus())?.first {
                $0.branch == normalizedBranch && $0.trackingExists
            }?.upstream
            await MainActor.run {
                self.multiRootUpstreamContext = MultiRootUpstreamContext(
                    rootPath: normalizedRoot,
                    displayName: displayName,
                    localBranch: normalizedBranch,
                    remoteBranches: remoteBranches,
                    currentUpstream: currentUpstream
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load upstream branches failed",
                    detail: "\(displayName) · \(errorMessage(error))"
                )
            }
        }
    }
}

func unsetBranchUpstreamInRoot(rootPath: String, branch: String) {
    beginFeedbackOperation("Unset branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.branchUnsetUpstream(branch: branch)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Upstream removed", detail: "\(branch) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Unset upstream failed", detail: "\(branch) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

struct MultiRootRemoteBranchDeleteGroup: Equatable, Sendable {
    let remoteBranch: String
    let rootPaths: [String]
}

nonisolated static func multiRootRemoteBranchDeleteGroups(
    _ targets: [BranchDashboardReference]
) -> [MultiRootRemoteBranchDeleteGroup] {
    let groupedTargets = Dictionary(grouping: targets, by: \.name)
    return groupedTargets
        .keys
        .sorted()
        .compactMap { remoteBranch in
            guard let branchTargets = groupedTargets[remoteBranch] else {
                return nil
            }
            return MultiRootRemoteBranchDeleteGroup(
                remoteBranch: remoteBranch,
                rootPaths: Array(Set(branchTargets.map(\.rootPath))).sorted()
            )
        }
}

/// IntelliJ's multi-ref DeleteBranchAction also accepts remote branch refs.
/// Keep each remote ref tied to its owning root, ask once whether common local
/// tracking branches should follow, and only perform that local cleanup after
/// every selected root for the same remote branch succeeded.
func deleteSelectedRemoteBranchesInRoots(_ targets: [BranchDashboardReference]) {
    let selected = targets
        .filter { $0.kind == .remote }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.name < $1.name }
            return $0.rootPath < $1.rootPath
        }
    guard !selected.isEmpty, !multiRootRunning else { return }
    guard selected.allSatisfy({ !$0.isProtected }) else {
        feedbackCenter.warning(
            "Delete remote branches unavailable",
            detail: "One or more selected remote branches are protected.",
            nextStep: "Remove the protection rule only if deleting these branches is intentional."
        )
        return
    }

    let groups = Self.multiRootRemoteBranchDeleteGroups(selected)
    let commonTrackingBranchesByRemoteBranch = Dictionary(
        uniqueKeysWithValues: groups.map { group in
            (
                group.remoteBranch,
                multiRootCommonTrackingBranches(
                    remoteBranch: group.remoteBranch,
                    snapshots: multiRootBranchSnapshots,
                    selectedRootPaths: Set(group.rootPaths)
                )
            )
        }
    )
    let trackingSummary = groups.flatMap { group in
        (commonTrackingBranchesByRemoteBranch[group.remoteBranch] ?? []).map {
            "\(group.remoteBranch) → \($0)"
        }
    }

    let alert = NSAlert()
    alert.messageText = "Delete selected remote branches?"
    alert.informativeText = selected
        .map { "\($0.name) · \($0.rootPath)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    var deleteTrackingCheckbox: NSButton?
    if !trackingSummary.isEmpty {
        let checkbox = NSButton(
            checkboxWithTitle: "Also delete common local tracking branches: \(trackingSummary.joined(separator: ", "))",
            target: nil,
            action: nil
        )
        checkbox.state = .off
        alert.accessoryView = checkbox
        deleteTrackingCheckbox = checkbox
    }
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let deleteTracking = deleteTrackingCheckbox?.state == .on

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    let localBranchesByRoot = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { snapshot in
            (
                snapshot.rootPath,
                Set(snapshot.branches.filter { !$0.isCurrent }.map(\.name))
            )
        }
    )
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootRunning = true
    beginFeedbackOperation("Delete selected remote branches", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var failures: [String] = []
        var trackingWarnings: [String] = []
        var recoveryContexts: [BranchDeleteRecoveryContext] = []
        var repositoriesByRoot: [String: Repository] = [:]
        var cancelled = false

        for group in groups {
            let groupTargets = selected.filter {
                $0.name == group.remoteBranch && group.rootPaths.contains($0.rootPath)
            }
            var groupSucceeded = true

            for target in groupTargets {
                guard !cancel.isCancelled() else {
                    cancelled = true
                    groupSucceeded = false
                    results.append(
                        RootOperationResult(
                            rootPath: target.rootPath,
                            displayName: displayNames[target.rootPath] ?? target.rootPath,
                            success: false,
                            skipped: true,
                            message: "Cancelled"
                        )
                    )
                    continue
                }
                do {
                    let rootRepo = try openRepository(path: target.rootPath)
                    try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                        remoteBranch: target.name,
                        broker: broker,
                        cancel: cancel
                    )
                    repositoriesByRoot[target.rootPath] = rootRepo
                    results.append(
                        RootOperationResult(
                            rootPath: target.rootPath,
                            displayName: displayNames[target.rootPath] ?? target.rootPath,
                            success: true,
                            skipped: false,
                            message: "Deleted \(target.name)"
                        )
                    )
                } catch {
                    groupSucceeded = false
                    if cancel.isCancelled() {
                        cancelled = true
                        results.append(
                            RootOperationResult(
                                rootPath: target.rootPath,
                                displayName: displayNames[target.rootPath] ?? target.rootPath,
                                success: false,
                                skipped: true,
                                message: "Cancelled"
                            )
                        )
                    } else {
                        let detail = "\(target.name) · \(target.rootPath): \(friendlyRemoteError(error))"
                        failures.append(detail)
                        results.append(
                            RootOperationResult(
                                rootPath: target.rootPath,
                                displayName: displayNames[target.rootPath] ?? target.rootPath,
                                success: false,
                                skipped: false,
                                message: "\(target.name): \(friendlyRemoteError(error))"
                            )
                        )
                    }
                }
            }

            let commonTrackingBranches = commonTrackingBranchesByRemoteBranch[group.remoteBranch] ?? []
            guard deleteTracking,
                  groupSucceeded,
                  !cancelled,
                  !cancel.isCancelled(),
                  !commonTrackingBranches.isEmpty else {
                continue
            }

            var trackingDeletedByRoot: [String: Int] = [:]
            for localBranch in commonTrackingBranches {
                for rootPath in group.rootPaths {
                    guard !cancel.isCancelled() else {
                        cancelled = true
                        break
                    }
                    guard localBranchesByRoot[rootPath]?.contains(localBranch) == true,
                          let rootRepo = repositoriesByRoot[rootPath] else {
                        continue
                    }
                    do {
                        let preview = try rootRepo.branchDeletePreview(name: localBranch)
                        do {
                            try rootRepo.branchDelete(name: localBranch, force: false)
                        } catch {
                            guard isUnmergedBranchDeletionError(error) else { throw error }
                            try rootRepo.branchDelete(name: localBranch, force: true)
                        }
                        recoveryContexts.append(
                            BranchDeleteRecoveryContext(
                                repo: rootRepo,
                                preview: preview,
                                rootPath: rootPath
                            )
                        )
                        trackingDeletedByRoot[rootPath, default: 0] += 1
                    } catch {
                        let warning = "\(displayNames[rootPath] ?? rootPath): \(localBranch): \(errorMessage(error))"
                        trackingWarnings.append(warning)
                    }
                }
            }

            for index in results.indices where group.rootPaths.contains(results[index].rootPath)
                && results[index].success
                && !results[index].skipped
                && results[index].message == "Deleted \(group.remoteBranch)" {
                let deletedCount = trackingDeletedByRoot[results[index].rootPath, default: 0]
                results[index].message = deletedCount == commonTrackingBranches.count
                    ? "Deleted \(group.remoteBranch) and common local tracking branches"
                    : "Deleted \(group.remoteBranch); local branches kept"
            }
        }

        let completedResults = results
        let completedFailures = failures + trackingWarnings + (cancelled ? ["Operation cancelled."] : [])
        let completedRecoveryContexts = recoveryContexts
        let cancelledToReport = cancelled
        await MainActor.run {
            self.multiRootRunning = false
            self.multiRootResults = completedResults
            self.loadMultiRoots()
            if !completedRecoveryContexts.isEmpty {
                self.multiRootBranchDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: groups.map(\.remoteBranch).joined(separator: ", "),
                    contexts: completedRecoveryContexts
                )
            }
            if completedFailures.isEmpty && !cancelledToReport {
                self.feedbackCenter.success(
                    "Selected remote branch deletion completed",
                    detail: "\(completedResults.filter(\.success).count) branches",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: completedRecoveryContexts
                    ),
                    notificationID: completedRecoveryContexts.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: completedRecoveryContexts.isEmpty ? .toolWindow : .standard
                )
            } else {
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    cancelledToReport
                        ? "Selected remote branch deletion cancelled"
                        : "Selected remote branch deletion partially completed",
                    detail: completedFailures.joined(separator: "\n"),
                    nextStep: completedRecoveryContexts.isEmpty
                        ? "Review the failed remote deletions and retry them individually."
                        : "Use Restore All if you need to recover the deleted local tracking branches.",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: completedRecoveryContexts
                    ),
                    notificationID: completedRecoveryContexts.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: completedRecoveryContexts.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

func deleteRemoteTagsFromRecovery(_ contexts: [TagDeleteRecoveryContext]) {
    guard !contexts.isEmpty else { return }
    let remotes: [(TagDeleteRecoveryContext, RemoteInfo)] = contexts.flatMap { context in
        let repositoryRemotes = (try? context.repo.remoteList()) ?? []
        return repositoryRemotes.map { remote in (context, remote) }
    }
    guard !remotes.isEmpty else {
        feedbackCenter.warning("No remotes configured", detail: contexts.first?.tag.name ?? "")
        return
    }
    multiRootTagDeleteRecovery = nil
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete multi-root remote tags", cancelHandle: cancel)
    let broker = credentialAuth.broker
    Task.detached(priority: .userInitiated) {
        var deleted: [String] = []
        var missing: [String] = []
        var failures: [String] = []
        var cancelled = false
        for (context, remote) in remotes {
            if cancel.isCancelled() {
                cancelled = true
                break
            }
            do {
                let didDelete = try context.repo.deleteRemoteTagWithAuthLeaseAndCancel(
                    remote: remote.name,
                    tag: context.tag.name,
                    expectedObjectId: context.tag.objectId,
                    broker: broker,
                    cancel: cancel
                )
                let location = "\(context.rootPath ?? String(localized: "Repository")) · \(remote.name)"
                if didDelete {
                    deleted.append(location)
                } else {
                    missing.append(location)
                }
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")) · \(remote.name): \(friendlyRemoteError(error))"
                )
            }
        }
        let deletedRemotes = deleted
        let missingRemotes = missing
        let failuresToReport = failures
        let wasCancelled = cancelled
        await MainActor.run {
            if failuresToReport.isEmpty && !wasCancelled {
                self.loadMultiRoots()
                let detail = deletedRemotes.isEmpty
                    ? "Tag was not present on configured remotes"
                    : deletedRemotes.joined(separator: "\n")
                if !missingRemotes.isEmpty && !deletedRemotes.isEmpty {
                    self.feedbackCenter.success(
                        "Multi-root remote tag deletion completed",
                        detail: "\(detail)\nAlready absent: \(missingRemotes.joined(separator: ", "))"
                    )
                } else {
                    self.feedbackCenter.success("Multi-root remote tag deletion completed", detail: detail)
                }
            } else if wasCancelled {
                self.multiRootTagDeleteRecovery = MultiRootTagDeleteRecoveryContext(
                    tagName: contexts.first?.tag.name ?? "",
                    contexts: contexts
                )
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Multi-root remote tag deletion canceled",
                    detail: "Deleted \(deletedRemotes.count); already absent \(missingRemotes.count).",
                    nextStep: "Retry the recovery action to process the remaining remotes."
                )
            } else {
                self.multiRootTagDeleteRecovery = MultiRootTagDeleteRecoveryContext(
                    tagName: contexts.first?.tag.name ?? "",
                    contexts: contexts
                )
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Multi-root remote tag deletion partially completed",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the failed remotes and retry the action."
                )
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

func deleteRemoteBranch(_ branch: RemoteBranchInfo) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = "Delete remote branch?"
    alert.informativeText = "This will delete \(branch.name) from the remote repository."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    let currentLocalBranches = Set(branches.filter(\.isCurrent).map(\.name))
    let trackingLocalBranches = syncStatuses
        .filter {
            $0.upstream == branch.name
                && $0.trackingExists
                && !currentLocalBranches.contains($0.branch)
        }
        .map(\.branch)
        .sorted()
    var deleteTrackingCheckbox: NSButton?
    if !trackingLocalBranches.isEmpty {
        let localBranchesTitle = trackingLocalBranches.count == 1
            ? "Also delete local branch \(trackingLocalBranches[0])"
            : "Also delete local branches: \(trackingLocalBranches.joined(separator: ", "))"
        let checkbox = NSButton(
            checkboxWithTitle: localBranchesTitle,
            target: nil,
            action: nil
        )
        checkbox.state = .off
        alert.accessoryView = checkbox
        deleteTrackingCheckbox = checkbox
    }
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let deleteTracking = deleteTrackingCheckbox?.state == .on
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.deleteRemoteBranchWithAuthAndCancel(
                remoteBranch: branch.name,
                broker: broker,
                cancel: cancel
            )
            if cancel.isCancelled() {
                await MainActor.run {
                    self.refreshAll(showFeedback: false)
                    self.loadRepoData()
                    self.feedbackCenter.warning(
                        "Remote branch deletion cancelled",
                        detail: branch.name
                    )
                }
                return
            }
            let localDeletionMessages: [String]
            if deleteTracking {
                localDeletionMessages = trackingLocalBranches.compactMap { localBranchName in
                    do {
                        try repo.branchDelete(name: localBranchName, force: false)
                        return nil
                    } catch {
                        return "\(localBranchName): \(errorMessage(error))"
                    }
                }
            } else {
                localDeletionMessages = []
            }
            await MainActor.run {
                if !localDeletionMessages.isEmpty {
                    self.feedbackCenter.warning(
                        "Remote branch deleted; local branches kept",
                        detail: localDeletionMessages.joined(separator: "\n"),
                        nextStep: "Resolve local changes or delete the local branch separately."
                    )
                } else {
                    self.feedbackCenter.success("Remote branch deleted", detail: branch.name)
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.loadError = errorMessage(error)
                if cancel.isCancelled() {
                    self.feedbackCenter.warning(
                        "Remote branch deletion cancelled",
                        detail: branch.name
                    )
                } else {
                    self.feedbackCenter.error("Delete remote branch failed", detail: friendlyRemoteError(error), nextStep: "Check permissions and the remote name, then retry.")
                }
            }
        }
    }
}

/// IntelliJ's local tag deletion notification exposes a follow-up action that
/// removes the same tag from every configured remote. Each remote is checked
/// independently; an already absent tag is successful, while a real push
/// failure keeps the recovery surface open for another attempt.
func deleteRemoteTagFromRecovery(_ context: TagDeleteRecoveryContext) {
    let remotes = context.remotes
    guard !remotes.isEmpty else {
        feedbackCenter.warning("No remotes configured", detail: context.tag.name)
        return
    }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete remote tag", cancelHandle: cancel)
    let broker = credentialAuth.broker
    Task.detached(priority: .userInitiated) {
        var deleted: [String] = []
        var missing: [String] = []
        var failures: [String] = []
        var cancelled = false
        for remote in remotes {
            if cancel.isCancelled() {
                cancelled = true
                break
            }
            do {
                let didDelete = try context.repo.deleteRemoteTagWithAuthLeaseAndCancel(
                    remote: remote.name,
                    tag: context.tag.name,
                    expectedObjectId: context.tag.objectId,
                    broker: broker,
                    cancel: cancel
                )
                if didDelete {
                    deleted.append(remote.name)
                } else {
                    missing.append(remote.name)
                }
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                failures.append("\(remote.name): \(friendlyRemoteError(error))")
            }
        }
        let deletedRemotes = deleted
        let missingRemotes = missing
        let failuresToReport = failures
        let wasCancelled = cancelled
        await MainActor.run {
            if failuresToReport.isEmpty && !wasCancelled {
                self.tagDeleteRecovery = nil
                self.refreshAll(showFeedback: false)
                let detail = deletedRemotes.isEmpty
                    ? "\(context.tag.name) was not present on configured remotes"
                    : "\(context.tag.name) · \(deletedRemotes.joined(separator: ", "))"
                self.feedbackCenter.success("Remote tag deletion completed", detail: detail)
            } else if wasCancelled {
                self.feedbackCenter.warning(
                    "Remote tag deletion canceled",
                    detail: "Deleted \(deletedRemotes.count); already absent \(missingRemotes.count).",
                    nextStep: "Retry the recovery action to process the remaining remotes."
                )
            } else {
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                let missingDetail = missingRemotes.isEmpty
                    ? ""
                    : "\nAlready absent: \(missingRemotes.joined(separator: ", "))"
                self.feedbackCenter.warning(
                    "Remote tag deletion partially completed",
                    detail: failuresToReport.joined(separator: "\n") + missingDetail,
                    nextStep: "Review the failed remotes and retry the action."
                )
            }
        }
    }
}

/// 重新加载远程列表到状态（Configure Remotes Dialog 与推送选择共用）。
func loadRemotes() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let rs = try repo.remoteList()
            await MainActor.run {
                self.remotes = rs
                self.restoreRemoteProtectedBranchPatterns(for: rs, projectPath: self.projectPath)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Load remotes failed", detail: errorMessage(error), nextStep: "检查仓库配置后重试。")
            }
        }
    }
}

/// 打开指定 Git root 的 Configure Remotes，而不是复用当前窗口 repository
/// 的 remote 状态。Push 对话框和 Branches Popup 都通过这个入口进入。
func beginConfigureRemotes() {
    guard let projectPath else { return }
    beginFeedbackOperation("Load remotes")
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadRemoteConfigRoots(scanRoot: projectPath)
            await MainActor.run {
                self.multiRootRemoteConfigAggregateContext = MultiRootRemoteConfigAggregateContext(roots: roots)
                self.feedbackCenter.success("Remotes loaded", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load remotes failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func loadMultiRootRemoteConfigAggregate() {
    guard let projectPath else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadRemoteConfigRoots(scanRoot: projectPath)
            await MainActor.run {
                guard self.multiRootRemoteConfigAggregateContext != nil else { return }
                self.multiRootRemoteConfigAggregateContext = MultiRootRemoteConfigAggregateContext(roots: roots)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Refresh remotes failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func beginMultiRootRemoteConfig(rootPath: String, selectedRemote: String? = nil) {
    beginFeedbackOperation("Load root remotes")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let rootRemotes = try rootRepo.remoteList()
            let selected = selectedRemote.flatMap { name in
                rootRemotes.first(where: { $0.name == name })
            }
            await MainActor.run {
                self.multiRootRemoteName = selected?.name ?? ""
                self.multiRootRemoteURL = selected?.url ?? ""
                self.multiRootRemotePushURL = selected?.pushUrl ?? ""
                self.multiRootRemoteFetchRefspec = selected?.fetchRefspec ?? ""
                self.multiRootRemotePushRefspec = selected?.pushRefspec ?? ""
                self.multiRootRemoteConfigContext = MultiRootRemoteConfigContext(
                    rootPath: rootPath,
                    remotes: rootRemotes
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load root remotes failed",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Check the selected Git root and retry."
                )
            }
        }
    }
}

func loadMultiRootRemoteConfig(rootPath: String) {
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let rootRemotes = try rootRepo.remoteList()
            await MainActor.run {
                guard self.multiRootRemoteConfigContext?.rootPath == rootPath else { return }
                self.multiRootRemoteConfigContext = MultiRootRemoteConfigContext(
                    rootPath: rootPath,
                    remotes: rootRemotes
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Refresh root remotes failed",
                    detail: "\(rootPath): \(errorMessage(error))"
                )
            }
        }
    }
}

func saveRemoteConfigInRoot(rootPath: String) {
    let name = multiRootRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = multiRootRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else { return }
    let pushURL = multiRootRemotePushURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let fetchRefspec = multiRootRemoteFetchRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    let pushRefspec = multiRootRemotePushRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    let broker = credentialAuth.broker
    beginFeedbackOperation("Save root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if let checkFailure = try remoteURLCheckFailure(repo: rootRepo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                }
                return
            }
            try rootRepo.remoteSetUrl(name: name, url: url)
            try rootRepo.remoteSetPushUrl(name: name, pushUrl: pushURL)
            try rootRepo.remoteSetRefspecs(
                name: name,
                fetchRefspec: fetchRefspec.isEmpty ? nil : fetchRefspec,
                pushRefspec: pushRefspec.isEmpty ? nil : pushRefspec
            )
            await MainActor.run {
                self.feedbackCenter.success("Root remote updated", detail: "\(name) · \(rootPath)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Save root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the URL and refspec, then retry."
                )
            }
        }
    }
}

func addRemoteInRoot(rootPath: String, fetchAfterAdd: Bool = true) {
    let name = multiRootRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = multiRootRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else { return }
    addRemoteInRoot(rootPath: rootPath, name: name, url: url, fetchAfterAdd: fetchAfterAdd)
}

func addRemoteInRoot(
    rootPath: String,
    name: String,
    url: String,
    fetchAfterAdd: Bool = true,
    completion: @escaping (Bool) -> Void = { _ in }
) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else {
        completion(false)
        return
    }
    let broker = credentialAuth.broker
    beginFeedbackOperation("Add root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if let checkFailure = try remoteURLCheckFailure(repo: rootRepo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                    completion(false)
                }
                return
            }
            try rootRepo.remoteAdd(name: name, url: url)
            await MainActor.run {
                if self.multiRootRemoteConfigContext?.rootPath == rootPath {
                    self.multiRootRemoteName = ""
                    self.multiRootRemoteURL = ""
                    self.multiRootRemotePushURL = ""
                    self.multiRootRemoteFetchRefspec = ""
                    self.multiRootRemotePushRefspec = ""
                }
                self.feedbackCenter.success("Root remote added", detail: "\(name) · \(rootPath)")
                completion(true)
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
                if fetchAfterAdd {
                    self.fetchRemoteInRoot(rootPath: rootPath, remote: name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Add root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the remote name and URL, then retry."
                )
                completion(false)
            }
        }
    }
}

func updateRemoteInRoot(
    rootPath: String,
    oldName: String,
    name: String,
    url: String,
    pushURL: String,
    fetchRefspec: String,
    pushRefspec: String,
    fetchAfterUpdate: Bool,
    completion: @escaping (Bool) -> Void = { _ in }
) {
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let pushURL = pushURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let fetchRefspec = fetchRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    let pushRefspec = pushRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldName.isEmpty, !name.isEmpty, !url.isEmpty else {
        completion(false)
        return
    }
    let broker = credentialAuth.broker
    beginFeedbackOperation("Update root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if let checkFailure = try remoteURLCheckFailure(repo: rootRepo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                    completion(false)
                }
                return
            }
            if oldName != name {
                try rootRepo.remoteRename(old: oldName, new: name)
            }
            try rootRepo.remoteSetUrl(name: name, url: url)
            try rootRepo.remoteSetPushUrl(name: name, pushUrl: pushURL)
            try rootRepo.remoteSetRefspecs(
                name: name,
                fetchRefspec: fetchRefspec.isEmpty ? nil : fetchRefspec,
                pushRefspec: pushRefspec.isEmpty ? nil : pushRefspec
            )
            await MainActor.run {
                self.feedbackCenter.success("Root remote updated", detail: "\(name) · \(rootPath)")
                completion(true)
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
                if fetchAfterUpdate {
                    self.fetchRemoteInRoot(rootPath: rootPath, remote: name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Update root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the remote name, URL, and refspec, then retry."
                )
                completion(false)
            }
        }
    }
}

func removeRemoteInRoot(rootPath: String, name: String) {
    guard confirmRemoteRemoval(name) else { return }
    beginFeedbackOperation("Remove root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.remoteRemove(name: name)
            await MainActor.run {
                self.feedbackCenter.success("Root remote removed", detail: "\(name) · \(rootPath)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Remove root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))"
                )
            }
        }
    }
}

/// IntelliJ's MultipleGroupActions removes each selected remote group while
/// retaining the owning Git root. A failure in one root must not prevent the
/// other selected remotes from being attempted.
func removeSelectedRemotesInRoots(_ groups: [BranchDashboardRemoteGroup]) {
    let selected = Array(Set(groups)).sorted {
        if $0.rootPath == $1.rootPath { return $0.name < $1.name }
        return $0.rootPath < $1.rootPath
    }
    guard !selected.isEmpty, !multiRootRunning else { return }

    let alert = NSAlert()
    alert.messageText = "Remove selected remotes?"
    alert.informativeText = selected
        .map { "\($0.name) · \($0.rootPath)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    multiRootRunning = true
    beginFeedbackOperation("Remove selected remotes")
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        for group in selected {
            do {
                let rootRepo = try openRepository(path: group.rootPath)
                try rootRepo.remoteRemove(name: group.name)
                results.append(
                    RootOperationResult(
                        rootPath: group.rootPath,
                        displayName: displayNames[group.rootPath] ?? group.rootPath,
                        success: true,
                        skipped: false,
                        message: "Removed \(group.name)"
                    )
                )
            } catch {
                results.append(
                    RootOperationResult(
                        rootPath: group.rootPath,
                        displayName: displayNames[group.rootPath] ?? group.rootPath,
                        success: false,
                        skipped: false,
                        message: "\(group.name): \(errorMessage(error))"
                    )
                )
            }
        }

        let completedResults = results
        let completedFailures = completedResults.filter { !$0.success }
        await MainActor.run {
            self.multiRootRunning = false
            self.multiRootResults = completedResults
            self.loadMultiRootRemoteConfigAggregate()
            self.loadMultiRoots()
            if completedFailures.isEmpty {
                self.feedbackCenter.success(
                    "Selected remotes removed",
                    detail: "\(selected.count) remotes"
                )
            } else {
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Selected remote removal partially completed",
                    detail: completedFailures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                    nextStep: "Review the failed remote removals and retry them individually."
                )
            }
        }
    }
}

func renameRemoteInRoot(rootPath: String, old: String, new: String) {
    let newName = new.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != old else { return }
    beginFeedbackOperation("Rename root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.remoteRename(old: old, new: newName)
            await MainActor.run {
                self.multiRootRemoteName = newName
                self.feedbackCenter.success("Root remote renamed", detail: "\(old) → \(newName) · \(rootPath)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Rename root remote failed",
                    detail: "\(old) → \(newName) · \(rootPath): \(errorMessage(error))"
                )
            }
        }
    }
}

/// REMOTE-001：保存当前编辑的远程配置（URL/push URL/refspec）。
func saveRemoteConfig() {
    guard let repo, !remoteName.isEmpty, !remoteUrl.isEmpty else { return }
    let name = remoteName.trimmingCharacters(in: .whitespaces)
    let url = remoteUrl.trimmingCharacters(in: .whitespaces)
    let pushUrl = remotePushUrl.trimmingCharacters(in: .whitespaces)
    let fetchRefspec = remoteFetchRefspec.trimmingCharacters(in: .whitespaces)
    let pushRefspec = remotePushRefspec.trimmingCharacters(in: .whitespaces)
    let broker = credentialAuth.broker
    beginFeedbackOperation("Save remote")
    Task.detached(priority: .userInitiated) {
        do {
            if let checkFailure = try remoteURLCheckFailure(repo: repo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                }
                return
            }
            try repo.remoteSetUrl(name: name, url: url)
            try repo.remoteSetPushUrl(name: name, pushUrl: pushUrl)
            try repo.remoteSetRefspecs(
                name: name,
                fetchRefspec: fetchRefspec.isEmpty ? nil : fetchRefspec,
                pushRefspec: pushRefspec.isEmpty ? nil : pushRefspec
            )
            await MainActor.run {
                self.feedbackCenter.success("Remote updated", detail: name)
            }
            await MainActor.run { self.loadRemotes() }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Save remote failed", detail: errorMessage(error), nextStep: "检查名称与 URL 后重试。")
            }
        }
    }
}

/// REMOTE-001：重命名远程（config + refs/remotes 一并处理）。
func remoteRename(_ old: String, _ new: String) {
    guard let repo, !new.isEmpty else { return }
    let newName = new.trimmingCharacters(in: .whitespaces)
    beginFeedbackOperation("Rename remote")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.remoteRename(old: old, new: newName)
            await MainActor.run { self.feedbackCenter.success("Remote renamed", detail: "\(old) → \(newName)") }
            await MainActor.run { self.loadRemotes() }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Rename remote failed", detail: errorMessage(error), nextStep: "检查名称后重试。")
            }
        }
    }
}

func remoteAdd(_ fetchAfterAdd: Bool = true) {
    guard let repo, !remoteName.isEmpty, !remoteUrl.isEmpty else { return }
    let name = remoteName, url = remoteUrl
    let broker = credentialAuth.broker
    beginFeedbackOperation("Add remote")
    Task.detached(priority: .userInitiated) {
        do {
            if let checkFailure = try remoteURLCheckFailure(repo: repo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                }
                return
            }
            try repo.remoteAdd(name: name, url: url)
            let rs = try repo.remoteList()
            await MainActor.run {
                self.remotes = rs; self.remoteName = ""; self.remoteUrl = ""
                self.feedbackCenter.success("Remote added", detail: name)
                if fetchAfterAdd {
                    self.doFetch(name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Add remote failed",
                    detail: errorMessage(error),
                    nextStep: "Check the remote name and URL, then retry."
                )
            }
        }
    }
}

func remoteRemove(_ name: String) {
    guard let repo else { return }
    guard confirmRemoteRemoval(name) else { return }
    beginFeedbackOperation("Remove remote")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.remoteRemove(name: name)
            let rs = try repo.remoteList()
            await MainActor.run {
                self.remotes = rs
                self.feedbackCenter.success("Remote removed", detail: name)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Remove remote failed",
                    detail: errorMessage(error),
                    nextStep: "Check the remote configuration, then retry."
                )
            }
        }
    }
}

func confirmRemoteRemoval(_ name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Remove remote?"
    alert.informativeText = "This removes the remote configuration and its remote-tracking branches."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

nonisolated func friendlyRemoteError(_ error: Error) -> String {
    let full = errorMessage(error)
    let raw = full.count > 4000 ? String(full.prefix(4000)) + "\n…" : full
    let lower = raw.lowercased()
    if lower.contains("ssh host key changed")
        || lower.contains("remote host identification has changed")
    {
        return raw + "\nSSH 安全阻断：远端 host key 已变化。请先确认服务器身份，在 Git SSH Settings 检查 Known Hosts 后再重试。"
    }
    if lower.contains("authentication failed")
        || lower.contains("invalid username or token")
        || lower.contains("invalid credentials")
        || lower.contains("could not read username")
        || lower.contains("permission denied (publickey)")
        || lower.contains("publickey") {
        return raw + "\n认证失败：请检查 SSH key，或配置 git credential.helper。"
    }
    return raw
}

}
