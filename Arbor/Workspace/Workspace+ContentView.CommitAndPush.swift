import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
func beginCommitAndPush() {
    if multiRootWorkspace.roots.count > 1 {
        openMultiRootCommitDialog()
        return
    }
    guard hasStaged,
          !commitWorkspace.message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    // Match GitCommitAndPushExecutor: the commit workflow owns the first
    // stage. Push options are shown only after Git has created the commit.
    // This prevents a rejected/failed commit from ever entering transport.
    commitWorkspace.pendingCommitAndPush = true
    doCommit()
}

/// Complete the single-root Commit and Push executor after the commit phase.
/// The default keeps IntelliJ's Push preview, while the project preference can
/// opt into automatic transport for a root that has a usable remote/branch.
func beginSingleRootPushAfterCommit(rootPath: String) {
    let choice = GitPushAfterCommitSettings.choice(for: projectWorkspace.path)
    let protectedBranchPatterns = effectiveProtectedBranchPatterns
    Task.detached(priority: .userInitiated) {
        let requiresPreview = pushAfterCommitRequiresPreview(
            rootPath: rootPath,
            choice: choice,
            protectedBranchPatterns: protectedBranchPatterns
        )
        await MainActor.run {
            guard self.repo?.workdir().map({
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }) == URL(fileURLWithPath: rootPath).standardizedFileURL.path else {
                self.feedbackCenter.warning(
                    "Push after commit unavailable",
                    detail: "The original Git root is no longer active.",
                    nextStep: "Open the original project and use Push from that Git root."
                )
                return
            }
            if requiresPreview {
                self.beginPushDialog()
            } else {
                self.doPush(
                    nil,
                    branch: nil,
                    force: false,
                    forceWithLease: false,
                    setUpstream: false,
                    refspec: nil,
                    tagMode: nil,
                    skipHooks: false,
                    afterCommit: true
                )
            }
        }
    }
}

func commitAndPush(
    remote: String?,
    branch: String?,
    force: Bool,
    forceWithLease: Bool? = nil,
    setUpstream: Bool = false,
    skipChecks: Bool = false
) {
    guard let repo else { return }
    let targetBranch = branch ?? currentBranchName
    let useForceWithLease = GitPushSettings.useForceWithLease(force: force, requested: forceWithLease)
    if force,
       GitProtectedBranchRules.matches(
           targetBranch,
           patterns: effectiveProtectedBranchPatterns
       ) {
        feedbackCenter.error(
            "Force push blocked",
            detail: "\(targetBranch) is protected by Git settings.",
            nextStep: "Edit Protected Branches in Settings or use a non-force push."
        )
        return
    }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Commit and push", cancelHandle: cancel)
    let msg = commitWorkspace.message
    let hooks = GitCommitHooksSettings.effectiveSkipHooks(requested: self.commitWorkspace.skipHooks)
    let checks = commitWorkspace.beforeCommitCommands
    let authorNameOverride = gitSettings.identityAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorEmailOverride = gitSettings.identityAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerNameOverride = gitSettings.identityCommitterName.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerEmailOverride = gitSettings.identityCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let signOff = gitSettings.identitySignOff
    let coAuthors = parseCoAuthors(gitSettings.identityCoAuthors)
    let broker = credentialAuth.broker
    rememberCommitAuthor(
        name: authorNameOverride,
        email: authorEmailOverride,
        projectPath: projectWorkspace.path
    )
    Task.detached(priority: .userInitiated) {
        do {
            if !skipChecks {
                try runBeforeCommitChecks(repo: repo, commands: checks)
            }
            let identity = try? repo.gitIdentity()
            let hasOverrides = !authorNameOverride.isEmpty || !authorEmailOverride.isEmpty
                || !committerNameOverride.isEmpty || !committerEmailOverride.isEmpty || signOff || !coAuthors.isEmpty
            let outcome: CommitPushOutcome
            if identity?.signCommits == true || hasOverrides {
                outcome = try withArborPinentrySession {
                    try repo.commitAndPushWithIdentityWithAuthAndCancel(
                        message: msg,
                        remote: remote,
                        branch: branch,
                        force: force,
                        forceWithLease: useForceWithLease,
                        skipHooks: hooks,
                        setUpstream: setUpstream,
                        authorName: authorNameOverride.isEmpty ? nil : authorNameOverride,
                        authorEmail: authorEmailOverride.isEmpty ? nil : authorEmailOverride,
                        committerName: committerNameOverride.isEmpty ? nil : committerNameOverride,
                        committerEmail: committerEmailOverride.isEmpty ? nil : committerEmailOverride,
                        signKey: identity?.signingKey,
                        signOff: signOff,
                        coAuthors: coAuthors,
                        broker: broker,
                        cancel: cancel
                    )
                }
            } else {
                outcome = try repo.commitAndPushWithOptionsWithAuthAndCancel(
                    message: msg,
                    remote: remote,
                    branch: branch,
                    force: force,
                    forceWithLease: useForceWithLease,
                    skipHooks: hooks,
                    setUpstream: setUpstream,
                    broker: broker,
                    cancel: cancel
                )
            }
            let st = try repo.status()
            let cls = (try? repo.changelistList()) ?? []
            let hid = repo.headCommitId()
            let recent = (try? repo.recentCommitMessages(limit: 10)) ?? []
            let staging = try? repo.stagingModel()
            let branchList = (try? repo.branchList()) ?? []
            let syncStatuses = (try? repo.syncStatus()) ?? []
            await MainActor.run {
                self.repositoryStatus.entries = st
                self.repositoryStatus.changeLists = cls
                self.repositoryStatus.headId = hid
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.branchWorkspace.branches = branchList
                self.branchWorkspace.syncStatuses = syncStatuses
                self.commitWorkspace.recentMessages = recent
                if self.showsLogWorkspace {
                    self.loadLog()
                }
                self.commitWorkspace.message = ""
                self.pushWorkspace.feedback = outcome.pushed
                    ? "已提交并推送 \(String(outcome.commitId.prefix(7)))"
                    : "已提交 \(String(outcome.commitId.prefix(7)))（未推送：没有可用远程或分支）"
                self.commitWorkspace.feedback = self.pushWorkspace.feedback
            }
        } catch {
            await MainActor.run {
                if let checkError = error as? BeforeCommitCheckError {
                    self.feedbackCenter.warning(
                        "Commit checks failed",
                        detail: "\(checkError.command)\n\n\(checkError.output)",
                        nextStep: "Review the check output, then retry or choose the force action."
                    )
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Before Commit checks failed")
                    alert.informativeText = String(localized: "\(checkError.command)\n\n\(checkError.output)")
                    alert.addButton(withTitle: String(localized: "Commit and Push Anyway"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        self.commitAndPush(
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: setUpstream,
                            skipChecks: true
                        )
                    }
                    return
                }
                self.pushWorkspace.feedback = friendlyRemoteError(error)
                self.commitWorkspace.feedback = self.pushWorkspace.feedback
                let detail = errorMessage(error)
                if gitCommitSigningFailureNeedsGPGConfiguration(detail) {
                    self.feedbackCenter.error(
                        "Commit signing failed",
                        detail: detail,
                        nextStep: "Install GnuPG if needed, or configure a working pinentry program, then retry the commit.",
                        additionalActions: [self.gpgAgentSettingsFeedbackAction()],
                        notificationID: self.repo?.workdir().map(self.pushNotificationID)
                    )
                }
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
                self.offerPushRecovery(
                    error,
                    remote: remote,
                    branch: branch,
                    force: force,
                    forceWithLease: useForceWithLease,
                    setUpstream: setUpstream,
                    afterCommit: true
                )
            }
        }
    }
}

/// Project-level Commit and Push follows IntelliJ's two-stage executor: the
/// selected roots are committed first, then only roots that actually created
/// a commit are offered to the shared Push options flow.
func commitAndPushMultiRootSelectedRoots(_ rootPaths: [String], _ message: String) {
    let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootPaths.isEmpty, !commitMessage.isEmpty else { return }

    let options = currentMultiRootCommitOptions()

    performMultiRootCommit(
        rootPaths: rootPaths,
        message: commitMessage,
        options: options,
        allowForceRetry: true,
        pushAfterCommit: true
    )
}

/// Selected-file Commit and Push commits the root-qualified file set first,
/// then exposes Push options only for roots that actually produced a commit.
func commitAndPushMultiRootSelectedChanges(
    _ selectedChanges: [MultiRootChangeSelection],
    _ message: String
) {
    let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedChanges = normalizedMultiRootCommitSelections(selectedChanges)
    guard !normalizedChanges.isEmpty, !commitMessage.isEmpty else { return }

    performMultiRootCommit(
        rootPaths: Array(Set(normalizedChanges.map(\.rootPath))).sorted(),
        message: commitMessage,
        options: currentMultiRootCommitOptions(),
        allowForceRetry: true,
        pushAfterCommit: true,
        selectedChanges: normalizedChanges
    )
}

func beginMultiRootCommitPushOptions(rootPaths: [String]) {
    guard !rootPaths.isEmpty else { return }
    executeMultiRootPush(selectedRootPaths: rootPaths, fromCommit: true)
}

/// Run the post-commit Push executor according to the effective project
/// preference. The explicit action remains available in Operation Log, while
/// automatic mode preflights every committed root before starting transport.
func beginMultiRootCommitPush(rootPaths: [String]) {
    let normalizedPaths = Array(Set(rootPaths)).sorted()
    guard !normalizedPaths.isEmpty else { return }
    let choice = GitPushAfterCommitSettings.choice(for: projectWorkspace.path)
    let protectedBranchPatternsByRoot = Dictionary(
        uniqueKeysWithValues: normalizedPaths.map { rootPath in
            (
                canonicalExternalLogPath(rootPath),
                effectiveProtectedBranchPatterns(forRootPath: rootPath)
            )
        }
    )
    Task.detached(priority: .userInitiated) {
        let requiresPreview = choice == .always || normalizedPaths.contains { rootPath in
            pushAfterCommitRequiresPreview(
                rootPath: rootPath,
                choice: choice,
                protectedBranchPatterns: protectedBranchPatternsByRoot[
                    canonicalExternalLogPath(rootPath)
                ] ?? []
            )
        }
        await MainActor.run {
            if requiresPreview {
                self.executeMultiRootPush(
                    selectedRootPaths: normalizedPaths,
                    fromCommit: true
                )
            } else {
                self.runMultiRootPush(
                    selectedRootPaths: normalizedPaths,
                    tagMode: nil,
                    skipHooks: false,
                    force: false,
                    forceWithLease: false,
                    fromCommit: true
                )
            }
        }
    }
}

func multiRootCommitPushFeedbackAction(rootPaths: [String]) -> FeedbackAction {
    let normalizedPaths = Array(Set(rootPaths)).sorted()
    let request = makeMultiRootRetryRequest(
        operation: .pushAfterCommit,
        rootPaths: normalizedPaths
    )
    return FeedbackAction(
        id: "push-multi-root-committed:\(normalizedPaths.joined(separator: "|"))",
        title: "Push Committed Roots",
        semanticAction: request
    ) {
        self.beginMultiRootCommitPushOptions(rootPaths: normalizedPaths)
    }
}

}
