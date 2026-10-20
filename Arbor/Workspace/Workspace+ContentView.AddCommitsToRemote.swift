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
    pushWorkspace.addCommitsToRemoteBranchContext = AddCommitsToRemoteBranchContext(
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
                    self.pushWorkspace.dialogMode = .addCommitsToRemoteBranch
                    self.pushWorkspace.dialogRemote = remoteBranch.remote
                    self.pushWorkspace.dialogBranch = branch
                    self.pushWorkspace.dialogSourceRevision = tip
                    self.pushWorkspace.dialogRefspec = nil
                    self.pushWorkspace.showDialog = true
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
                    self.hostingWorkspace.showHostingAuthPrompt = true
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

}
