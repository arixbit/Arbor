import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func beginCommitAndPush() {
    if multiRoots.count > 1 {
        openMultiRootCommitDialog()
        return
    }
    guard hasStaged,
          !commitMessage.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    // Match GitCommitAndPushExecutor: the commit workflow owns the first
    // stage. Push options are shown only after Git has created the commit.
    // This prevents a rejected/failed commit from ever entering transport.
    pendingCommitAndPush = true
    doCommit()
}

/// Complete the single-root Commit and Push executor after the commit phase.
/// The default keeps IntelliJ's Push preview, while the project preference can
/// opt into automatic transport for a root that has a usable remote/branch.
func beginSingleRootPushAfterCommit(rootPath: String) {
    let choice = GitPushAfterCommitSettings.choice(for: projectPath)
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

/// 顶部工具栏/Branches 弹出的普通 Push 入口；提交工具窗的
/// “Commit and Push…” 则仍由 beginCommitAndPush 进入同一对话框的另一模式。
func beginPushDialog(branch: String? = nil) {
    // GitPushBranchAction remains reachable for a local branch without a
    // configured remote; let the dialog explain that state and offer remote
    // configuration instead of silently discarding the click.
    guard self.repo != nil else { return }
    let sourceBranch = branch ?? currentBranchName
    let configuredTarget = syncStatuses
        .first(where: { $0.branch == sourceBranch && $0.trackingExists })
        .flatMap {
            remoteBranchTargetForConfiguredUpstream($0.upstream, remotes: remotes)
        }
    pushDialogRemote = configuredTarget?.remote
    pushDialogRefspec = nil
    pushDialogBranch = configuredTarget?.branch ?? sourceBranch
    pushDialogSourceRevision = sourceBranch
    pushDialogMode = .push
    showPushDialog = true
}

/// LOG-003：将 Log 中选中的提交作为 source 推送到目标分支。
/// IntelliJ 会打开 Push 对话框；有包含该提交的本地分支时预填它，
/// 否则使用 detached source，并让用户编辑远程目标分支。
func pushUpToCommitFromLog(_ commit: CommitInfo) {
    guard let repo = logRepository(for: commit) else {
        feedbackCenter.error("Push unavailable", detail: "No remote is configured.", nextStep: "Add a remote before pushing.")
        return
    }
    let commitRemotes = (try? repo.remoteList()) ?? activeLogRemotes
    guard !commitRemotes.isEmpty else {
        feedbackCenter.error("Push unavailable", detail: "No remote is configured.", nextStep: "Add a remote before pushing.")
        return
    }
    let commitID = commit.id
    let localBranches = activeLogBranches
    Task.detached(priority: .userInitiated) {
        // Match GitPushUpToCommitAction: prefer the current branch only when
        // it actually contains the selected commit; otherwise use the first
        // local branch that contains it. Query the repository's live permanent
        // graph once instead of walking every local branch independently. The
        // old implementation always pushed to the checked-out branch, which
        // could move an unrelated branch when the Log view was showing another
        // branch's history.
        let containingBranches = Set(
            (try? repo.commitContainingBranches(commitId: commitID)) ?? []
        )
        let current = localBranches.first(where: { $0.isCurrent })
        let candidate = [current].compactMap { $0 }
            .first { containingBranches.contains($0.name) }
            ?? localBranches.first {
                !$0.isCurrent
                    && containingBranches.contains($0.name)
            }
        await MainActor.run {
            self.pushDialogMode = .pushUpToCommit
            self.pushDialogRemote = nil
            self.pushDialogBranch = candidate?.name
            self.pushDialogSourceRevision = commitID
            self.pushDialogRefspec = nil
            self.showPushDialog = true
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
    let msg = commitMessage
    let hooks = GitCommitHooksSettings.effectiveSkipHooks(requested: self.skipHooks)
    let checks = beforeCommitCommands
    let authorNameOverride = identityAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorEmailOverride = identityAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerNameOverride = identityCommitterName.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerEmailOverride = identityCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let signOff = identitySignOff
    let coAuthors = parseCoAuthors(identityCoAuthors)
    let broker = credentialAuth.broker
    rememberCommitAuthor(
        name: authorNameOverride,
        email: authorEmailOverride,
        projectPath: projectPath
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
                self.entries = st
                self.changeLists = cls
                self.headId = hid
                self.stagingModel = staging
                self.lastIndexRevision = staging?.indexRevision
                self.branches = branchList
                self.syncStatuses = syncStatuses
                self.recentMessages = recent
                if self.toolWindowMode == .log {
                    self.loadLog()
                }
                self.commitMessage = ""
                self.pushFeedback = outcome.pushed
                    ? "已提交并推送 \(String(outcome.commitId.prefix(7)))"
                    : "已提交 \(String(outcome.commitId.prefix(7)))（未推送：没有可用远程或分支）"
                self.commitFeedback = self.pushFeedback
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
                    alert.messageText = "提交前检查失败"
                    alert.informativeText = "\(checkError.command)\n\n\(checkError.output)"
                    alert.addButton(withTitle: "强制提交并推送")
                    alert.addButton(withTitle: "取消")
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
                self.pushFeedback = friendlyRemoteError(error)
                self.commitFeedback = self.pushFeedback
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
                    self.showHostingAuthPrompt = true
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

func pushTag(_ tag: String, remote selectedRemote: String? = nil) {
    guard let repo,
          let remote = resolveSelectedRemoteName(
              selectedRemote: selectedRemote,
              availableRemoteNames: remotes.map(\.name)
          ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing the tag",
            detail: "Multiple remotes are configured for this Git root."
        )
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push tag", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.tagPushWithAuthAndCancel(
                remote: remote,
                tag: tag,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run { self.tagWorkspace.feedback = "已推送 \(tag)" }
        } catch {
            await MainActor.run {
                self.tagWorkspace.feedback = friendlyRemoteError(error)
                if self.isAuthenticationFailure(error) { self.showHostingAuthPrompt = true }
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

/// Project-level Push uses the same root result workbench as the other
/// aggregate operations, but needs the credential broker, cancellation and
/// submodule dependency guard supplied by the dedicated engine API.
func executeMultiRootPush(
    selectedRootPaths: [String]? = nil,
    fromCommit: Bool = false
) {
    multiRootPushOptionsRootPaths = selectedRootPaths
    multiRootPushOptionsFromCommit = fromCommit
    showMultiRootPushOptions = true
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
    let choice = GitPushAfterCommitSettings.choice(for: projectPath)
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

func runMultiRootPush(
    selectedRootPaths: [String]?,
    explicitTargets: [MultiRootPushTargetSelection]? = nil,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    force: Bool = false,
    forceWithLease: Bool = false,
    fromCommit: Bool = false,
    priorViewCommitRanges: [PersistedLogRevisionRange] = [],
    priorResultRows: [FeedbackResultRow] = []
) {
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    multiRootPushRetryContext = nil
    guard let projectPath else { return }
    let observedRootPaths: [String]
    if let selectedRootPaths {
        observedRootPaths = selectedRootPaths
    } else {
        // The Push All dialog is populated from this snapshot already. Do
        // not synchronously rescan a large project on the main actor just to
        // enrich the eventual notification; an empty snapshot only loses the
        // optional View Commits action, never the push itself.
        observedRootPaths = multiRoots.map(\.path)
    }
    let pendingPushRevisionRanges = Self.multiRootPushRevisionRanges(
        for: observedRootPaths
    )
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let protectedPatternsByRoot = observedRootPaths.map { rootPath in
        RootProtectedBranchPatterns(
            rootPath: canonicalExternalLogPath(rootPath),
            patterns: effectiveProtectedBranchPatterns(forRootPath: rootPath)
        )
    }
    let notificationID = multiRootRetryNotificationID(.push)
    multiRootRunning = true
    // A partial Commit and Push notification may still contain Retry Failed
    // Commits for roots that were not committed. Starting the Push stage must
    // not expire that recovery entry; the Push notification has a different
    // stable ID and can coexist with it in Operation Log.
    if !fromCommit,
       let notificationID = multiRootRetryNotificationID(.commit) {
        feedbackCenter.expire(notificationID: notificationID)
    }
    beginFeedbackOperation(
        "Push All",
        cancelHandle: cancel,
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) { () async -> Void in
        let result: Result<[RootOperationResult], Error> = Result { () throws -> [RootOperationResult] in
            let engineTagMode = tagMode.map { mode in
                switch mode {
                case .all: PushTagMode.all
                case .currentBranch: PushTagMode.follow
                }
            }
            if let explicitTargets, !explicitTargets.isEmpty {
                return try runMultiRootPushWithTargets(
                    scanRoot: projectPath,
                    targets: explicitTargets.map {
                        MultiRootPushTarget(
                            rootPath: $0.rootPath,
                            remote: $0.remote,
                            targetBranch: $0.targetBranch
                        )
                    },
                    tagMode: engineTagMode,
                    skipHooks: skipHooks,
                    force: force,
                    forceWithLease: forceWithLease,
                    protectedBranchPatterns: protectedPatternsByRoot,
                    broker: broker,
                    cancel: cancel
                )
            } else {
                return try runMultiRootPushWithForceOptions(
                    scanRoot: projectPath,
                    selectedRootPaths: selectedRootPaths,
                    tagMode: engineTagMode,
                    skipHooks: skipHooks,
                    force: force,
                    forceWithLease: forceWithLease,
                    protectedBranchPatterns: protectedPatternsByRoot,
                    broker: broker,
                    cancel: cancel
                )
            }
        }
        let lfsWarnings: [String]
        if case let .success(pushedResults) = result {
            lfsWarnings = lfsPushCoverageWarnings(results: pushedResults, skipHooks: skipHooks)
        } else {
            lfsWarnings = []
        }
        await MainActor.run {
            switch result {
            case let .success(results):
                self.finishMultiRootPush(
                    results,
                    lfsWarnings: lfsWarnings,
                    tagMode: tagMode,
                    skipHooks: skipHooks,
                    force: force,
                    forceWithLease: forceWithLease,
                    pendingPushRevisionRanges: pendingPushRevisionRanges,
                    priorViewCommitRanges: priorViewCommitRanges,
                    priorResultRows: priorResultRows,
                    explicitTargets: explicitTargets,
                    notificationID: notificationID
                )
            case let .failure(error):
                self.multiRootRunning = false
                let retryAction: FeedbackAction? = observedRootPaths.isEmpty
                    ? nil
                    : {
                        let retryRequest = self.makeMultiRootRetryRequest(
                            operation: .push,
                            rootPaths: observedRootPaths,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            force: force,
                            forceWithLease: forceWithLease,
                            logRevisionRanges: priorViewCommitRanges
                        )
                        return FeedbackAction(
                            title: "Retry Push",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    }()
                let actions = retryAction.map { [$0] } ?? []
                if let engineError = error as? EngineError, case .Cancelled = engineError {
                    self.feedbackCenter.warning(
                        "Multi-root Push canceled",
                        detail: "No additional Push roots were published.",
                        additionalActions: actions,
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        "Multi-root Push failed",
                        detail: errorMessage(error),
                        nextStep: "检查各 Git root 的 remote 和认证配置后重试。",
                        additionalActions: actions,
                        notificationID: notificationID
                    )
                }
                if self.isAuthenticationFailure(error) {
                    self.showHostingAuthPrompt = true
                }
            }
        }
    }
}

func finishMultiRootPush(
    _ results: [RootOperationResult],
    lfsWarnings: [String] = [],
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    force: Bool,
    forceWithLease: Bool,
    pendingPushRevisionRanges: [PersistedLogRevisionRange],
    priorViewCommitRanges: [PersistedLogRevisionRange],
    priorResultRows: [FeedbackResultRow],
    explicitTargets: [MultiRootPushTargetSelection]?,
    notificationID: String?
) {
    if !priorResultRows.isEmpty {
        let preservedEngineResults = self.multiRootResults.isEmpty
            ? rootOperationResults(from: priorResultRows)
            : self.multiRootResults
        self.multiRootResults = mergeRootOperationResults(
            preserved: preservedEngineResults,
            retry: results,
            rootOrder: priorResultRows.map(\.rootPath)
        )
    } else {
        self.multiRootResults = results
    }
    self.multiRootRunning = false
    self.showHostingAuthPromptIfNeeded(for: results)
    let resultRows = mergeFeedbackResultRows(
        preserved: priorResultRows,
        retry: feedbackResultRows(from: results)
    )
    let effectiveResults = priorResultRows.isEmpty
        ? results
        : rootOperationResults(from: resultRows)
    let retryPaths = effectiveResults.filter { result in
        if !result.success { return true }
        guard result.skipped else { return false }
        return result.message.localizedCaseInsensitiveContains("submodule push failed")
            || result.message.localizedCaseInsensitiveContains("cancelled")
    }.map(\.rootPath)
    let retryForceOptions = multiRootPushRetryForceOptions(
        requestedForce: force,
        requestedForceWithLease: forceWithLease,
        hasPriorResultRows: !priorResultRows.isEmpty,
        retryResults: effectiveResults.filter { retryPaths.contains($0.rootPath) }
    )
    let retryForce = retryForceOptions.force
    let retryForceWithLease = retryForceOptions.forceWithLease
    let viewCommitRanges = Self.joinedRevisionRanges(
        existing: priorViewCommitRanges,
        latest: Self.successfulPushRevisionRanges(
            pendingRanges: pendingPushRevisionRanges,
            results: results
        )
    )
    self.multiRootPushRetryContext = retryPaths.isEmpty
        ? nil
        : MultiRootPushRetryContext(
            rootPaths: retryPaths,
            tagMode: tagMode,
            skipHooks: skipHooks,
            force: retryForce,
            forceWithLease: retryForceWithLease,
            viewCommitRanges: viewCommitRanges,
            resultRows: resultRows,
            targetSelections: explicitTargets?.filter { retryPaths.contains($0.rootPath) } ?? []
        )
    let nonFastForwardPaths = effectiveResults.filter { result in
        !retryForce && !result.success && pushResultNeedsUpdate(result)
    }.map(\.rootPath)
    let staleLeasePaths = effectiveResults.filter { result in
        !result.success && pushResultIsStaleLeaseRejected(result)
    }.map(\.rootPath)
    let hasRejectedResults = effectiveResults.contains { result in
        !result.success && pushResultIsRejected(result)
    }
    let hasErrorResults = effectiveResults.contains { result in
        !result.success && !pushResultIsRejected(result)
    }
    let ok = effectiveResults.filter { $0.success && !$0.skipped }.count
    let failed = effectiveResults.filter { !$0.success }.count
    let skipped = effectiveResults.filter { $0.skipped }.count
    let detail = effectiveResults.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n")
    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
        ranges: viewCommitRanges
    )
    let shouldAutoUpdate = staleLeasePaths.isEmpty
        && !nonFastForwardPaths.isEmpty
        && !hasErrorResults
        && GitPushAutoUpdateSettings.value(for: self.projectPath)
    if shouldAutoUpdate {
        self.recoverMultiRootPushRoots(
            nonFastForwardPaths,
            rebase: GitUpdateMethodSettings.method(for: self.projectPath) == .rebase,
            updateRootPaths: self.multiRoots.map(\.path),
            tagMode: tagMode,
            skipHooks: skipHooks,
            priorViewCommitRanges: viewCommitRanges,
            priorResultRows: resultRows
        )
    } else if failed == 0 && retryPaths.isEmpty {
        self.feedbackCenter.success(
            "Multi-root complete",
            detail: "\(ok) ok · \(failed) failed · \(skipped) skipped",
            additionalActions: viewCommitsAction.map { [$0] } ?? [],
            notificationID: notificationID,
            notificationGroup: .standard
        )
        self.publishLfsPushWarnings(lfsWarnings)
    } else {
        self.operationsViewMode = .roots
        self.toolWindowMode = .operations
        self.toolWindowExpanded = true
        var additionalActions = [FeedbackAction]()
        if let viewCommitsAction {
            additionalActions.append(viewCommitsAction)
        }
        if !shouldAutoUpdate && !staleLeasePaths.isEmpty {
            let forceRequest = makeMultiRootRetryRequest(
                operation: .push,
                rootPaths: staleLeasePaths,
                tagMode: tagMode,
                skipHooks: skipHooks,
                force: true,
                forceWithLease: false,
                logRevisionRanges: viewCommitRanges,
                priorResultRows: resultRows
            )
            additionalActions.append(
                FeedbackAction(
                    title: "Force Push Anyway",
                    semanticAction: forceRequest
                ) {
                    self.handleVCSActionRequest(forceRequest)
                }
            )
        }
        if !shouldAutoUpdate && !nonFastForwardPaths.isEmpty {
            let updateRootPaths = self.multiRoots.map(\.path)
            let mergeRequest = makeMultiRootRetryRequest(
                operation: .pushRecovery,
                rootPaths: nonFastForwardPaths,
                updateRootPaths: updateRootPaths,
                rebase: false,
                tagMode: tagMode,
                skipHooks: skipHooks,
                logRevisionRanges: viewCommitRanges
            )
            additionalActions.append(
                FeedbackAction(
                    title: "Update with Merge",
                    semanticAction: mergeRequest
                ) {
                    self.handleVCSActionRequest(mergeRequest)
                }
            )
            let rebaseRequest = makeMultiRootRetryRequest(
                operation: .pushRecovery,
                rootPaths: nonFastForwardPaths,
                updateRootPaths: updateRootPaths,
                rebase: true,
                tagMode: tagMode,
                skipHooks: skipHooks,
                logRevisionRanges: viewCommitRanges
            )
            additionalActions.append(
                FeedbackAction(
                    title: "Update with Rebase",
                    semanticAction: rebaseRequest
                ) {
                    self.handleVCSActionRequest(rebaseRequest)
                }
            )
        }
        if !retryPaths.isEmpty {
            let retryRequest = makeMultiRootRetryRequest(
                operation: .push,
                rootPaths: retryPaths,
                tagMode: tagMode,
                skipHooks: skipHooks,
                force: retryForce,
                forceWithLease: retryForceWithLease,
                logRevisionRanges: viewCommitRanges,
                priorResultRows: resultRows
            )
            additionalActions.append(
                FeedbackAction(
                    title: "Retry Failed Push Roots",
                    semanticAction: retryRequest
                ) {
                    self.handleVCSActionRequest(retryRequest)
                }
            )
        }
        if let notificationID {
            additionalActions.append(
                self.showOperationDetailsAction(notificationID: notificationID)
            )
        }
        additionalActions.append(
            FeedbackAction(title: "Git Roots") {
                self.operationsViewMode = .roots
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
            }
        )
        let title: String
        if hasErrorResults {
            title = ok > 0 ? "Multi-root Push partially failed" : "Multi-root Push failed"
            self.feedbackCenter.error(
                title,
                detail: detail,
                nextStep: "Open the details, correct the affected Git roots, then retry.",
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: .important
            )
        } else if hasRejectedResults {
            title = ok > 0 ? "Multi-root Push partially rejected" : "Multi-root Push rejected"
            self.feedbackCenter.warning(
                title,
                detail: detail,
                nextStep: "Open the details, update or force-push only after verifying the remote history.",
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: .important
            )
        } else {
            self.feedbackCenter.warning(
                "Multi-root Push partially completed",
                detail: detail,
                nextStep: "Retry failed roots after correcting their Git configuration.",
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: .important
            )
        }
    }
    self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
    // Keep Push's grouped Operation Log entry root-qualified just like the
    // generic Fetch/Pull runner. The rows are presentation-only; retry safety
    // continues to use the dedicated root paths and semantic request context.
    self.feedbackCenter.attachResultRows(
        resultRows,
        notificationID: notificationID
    )
    if shouldAutoUpdate, let notificationID {
        self.feedbackCenter.expire(notificationID: notificationID)
    }
    self.refreshAll(showFeedback: false)
}

func recoverMultiRootPushRoots(
    _ rootPaths: [String],
    rebase: Bool,
    updateRootPaths: [String]? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool = false,
    priorViewCommitRanges: [PersistedLogRevisionRange] = [],
    priorResultRows: [FeedbackResultRow] = []
) {
    guard !rootPaths.isEmpty, !multiRootRunning, let projectPath else { return }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootRunning = true
    let notificationID = multiRootRetryNotificationID(.pushRecovery)
    beginFeedbackOperation(
        rebase ? "Update Push Roots (rebase)" : "Update Push Roots",
        cancelHandle: cancel,
        notificationID: notificationID
    )
    let fetchTagMode = fetchTagsMode
    let observedRootPaths = Array(Set((updateRootPaths ?? []) + rootPaths)).sorted()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        let previousHeads = Self.headCommitIDs(for: observedRootPaths)
        let result: Result<[RootOperationResult], Error> = Result { () throws -> [RootOperationResult] in
            try runMultiRootPushRecoveryWithOptionsAndFetchTags(
                scanRoot: projectPath,
                selectedRootPaths: rootPaths,
                updateRootPaths: updateRootPaths,
                rebase: rebase,
                fetchTagsMode: fetchTagMode,
                tagMode: tagMode.map { mode in
                    switch mode {
                    case .all: PushTagMode.all
                    case .currentBranch: PushTagMode.follow
                    }
                },
                skipHooks: skipHooks,
                broker: broker,
                cancel: cancel,
                savePolicy: projectSavePolicy
            )
        }
        let currentHeads = Self.headCommitIDs(for: observedRootPaths)
        await MainActor.run {
            self.finishMultiRootPushRecovery(
                result,
                rebase: rebase,
                pushRootPaths: rootPaths,
                updateRootPaths: updateRootPaths,
                tagMode: tagMode,
                skipHooks: skipHooks,
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                priorViewCommitRanges: priorViewCommitRanges,
                priorResultRows: priorResultRows
            )
        }
    }
}

func finishMultiRootPushRecovery(
    _ result: Result<[RootOperationResult], Error>,
    rebase: Bool,
    pushRootPaths: [String],
    updateRootPaths: [String]?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    previousHeads: [String: String],
    currentHeads: [String: String],
    priorViewCommitRanges: [PersistedLogRevisionRange],
    priorResultRows: [FeedbackResultRow]
) {
    switch result {
    case let .success(results):
        if !priorResultRows.isEmpty {
            let preservedEngineResults = self.multiRootResults.isEmpty
                ? rootOperationResults(from: priorResultRows)
                : self.multiRootResults
            self.multiRootResults = mergeRootOperationResults(
                preserved: preservedEngineResults,
                retry: results,
                rootOrder: priorResultRows.map(\.rootPath)
            )
        } else {
            self.multiRootResults = results
        }
        self.multiRootRunning = false
        self.showHostingAuthPromptIfNeeded(for: results)
        let resultRows = mergeFeedbackResultRows(
            preserved: priorResultRows,
            retry: feedbackResultRows(from: results)
        )
        let effectiveResults = priorResultRows.isEmpty
            ? results
            : rootOperationResults(from: resultRows)
        let retryPaths = effectiveResults
            .filter { pushRootPaths.contains($0.rootPath) && (!$0.success || $0.skipped) }
            .map(\.rootPath)
        let viewCommitRanges = Self.joinedRevisionRanges(
            existing: priorViewCommitRanges,
            latest: Self.updateSessionRevisionRanges(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: results
            )
        )
        self.multiRootPushRetryContext = retryPaths.isEmpty
            ? nil
            : MultiRootPushRetryContext(
                rootPaths: retryPaths,
                recoveryRebase: rebase,
                recoveryUpdateRootPaths: updateRootPaths,
                tagMode: tagMode,
                skipHooks: skipHooks,
                viewCommitRanges: viewCommitRanges,
                resultRows: resultRows
            )
        let failures = effectiveResults.filter { !$0.success }
        let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
            ranges: viewCommitRanges
        )
        if failures.isEmpty && retryPaths.isEmpty {
            self.feedbackCenter.success(
                rebase ? "Update Push Roots completed (rebase)" : "Update Push Roots completed",
                detail: "\(effectiveResults.filter { $0.success && !$0.skipped }.count) updated and pushed",
                additionalActions: viewCommitsAction.map { [$0] } ?? [],
                notificationID: multiRootRetryNotificationID(.pushRecovery),
                notificationGroup: .standard
            )
        } else {
            self.operationsViewMode = .roots
            self.toolWindowMode = .operations
            self.toolWindowExpanded = true
            var recoveryActions = [FeedbackAction]()
            if failures.contains(where: {
                $0.message.localizedCaseInsensitiveContains("conflict")
                    || $0.message.localizedCaseInsensitiveContains("local changes remain")
            }) {
                recoveryActions.append(
                    FeedbackAction(title: "Resolve Conflicts") {
                        self.openMultiRootConflictResolver()
                    }
                )
            }
            recoveryActions.append(
                FeedbackAction(title: "Git Roots") {
                    self.operationsViewMode = .roots
                    self.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                }
            )
            let retryRequest = retryPaths.isEmpty
                ? nil
                : makeMultiRootRetryRequest(
                    operation: .pushRecovery,
                    rootPaths: retryPaths,
                    updateRootPaths: updateRootPaths,
                    rebase: rebase,
                    tagMode: tagMode,
                    skipHooks: skipHooks,
                    logRevisionRanges: viewCommitRanges,
                    priorResultRows: resultRows
                )
            if let retryRequest {
                recoveryActions.insert(
                FeedbackAction(
                        title: "Retry Failed Push Roots",
                        semanticAction: retryRequest
                    ) {
                        self.handleVCSActionRequest(retryRequest)
                    },
                    at: 0
                )
            }
            if let viewCommitsAction {
                recoveryActions.insert(viewCommitsAction, at: 0)
            }
            self.feedbackCenter.warning(
                rebase ? "Update Push Roots partially completed (rebase)" : "Update Push Roots partially completed",
                detail: effectiveResults.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                nextStep: "Resolve the affected roots, then retry the remaining Push roots.",
                additionalActions: recoveryActions,
                notificationID: multiRootRetryNotificationID(.pushRecovery)
            )
        }
        self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
        self.feedbackCenter.attachResultRows(
            resultRows,
            notificationID: multiRootRetryNotificationID(.pushRecovery)
        )
        self.refreshAll(showFeedback: false)
    case let .failure(error):
        self.multiRootRunning = false
        let retryRequest = makeMultiRootRetryRequest(
            operation: .pushRecovery,
            rootPaths: pushRootPaths,
            updateRootPaths: updateRootPaths,
            rebase: rebase,
            tagMode: tagMode,
            skipHooks: skipHooks,
            logRevisionRanges: priorViewCommitRanges,
            priorResultRows: priorResultRows
        )
        let retryAction = FeedbackAction(
            title: "Retry Push Recovery",
            semanticAction: retryRequest
        ) {
            self.handleVCSActionRequest(retryRequest)
        }
        if let engineError = error as? EngineError, case .Cancelled = engineError {
            self.feedbackCenter.warning(
                rebase ? "Update Push Roots canceled (rebase)" : "Update Push Roots canceled",
                detail: "The affected roots were kept for an explicit retry.",
                additionalActions: [retryAction],
                notificationID: multiRootRetryNotificationID(.pushRecovery),
                notificationGroup: .important
            )
        } else {
            self.feedbackCenter.error(
                rebase ? "Update Push Roots failed (rebase)" : "Update Push Roots failed",
                detail: errorMessage(error),
                nextStep: "Resolve the affected roots, then retry the Push recovery.",
                additionalActions: [retryAction],
                notificationID: multiRootRetryNotificationID(.pushRecovery)
            )
            if self.isAuthenticationFailure(error) {
                self.showHostingAuthPrompt = true
            }
        }
    }
}

func retryMultiRootPushFailedRoots(
    rootPaths: [String]? = nil,
    recoveryRebase: Bool? = nil,
    recoveryUpdateRootPaths: [String]? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool? = nil,
    force: Bool? = nil,
    forceWithLease: Bool? = nil,
    priorViewCommitRanges: [PersistedLogRevisionRange]? = nil,
    priorResultRows: [FeedbackResultRow]? = nil
) {
    guard !multiRootRunning else { return }
    let context = multiRootPushRetryContext
    let retryPaths = rootPaths ?? context?.rootPaths ?? []
    guard !retryPaths.isEmpty else { return }
    let resolvedRebase = recoveryRebase ?? context?.recoveryRebase
    let resolvedUpdateRootPaths = recoveryUpdateRootPaths ?? context?.recoveryUpdateRootPaths
    let resolvedTagMode = tagMode ?? context?.tagMode
    let resolvedSkipHooks = skipHooks ?? context?.skipHooks ?? false
    let resolvedForce = force ?? context?.force ?? false
    let resolvedForceWithLease = forceWithLease ?? context?.forceWithLease ?? false
    let resolvedTargets = context?.targetSelections.filter { retryPaths.contains($0.rootPath) } ?? []
    let resolvedViewCommitRanges = priorViewCommitRanges ?? context?.viewCommitRanges ?? []
    let resolvedResultRows = priorResultRows ?? context?.resultRows ?? []
    if let recoveryRebase = resolvedRebase {
        recoverMultiRootPushRoots(
            retryPaths,
            rebase: recoveryRebase,
            updateRootPaths: resolvedUpdateRootPaths,
            tagMode: resolvedTagMode,
            skipHooks: resolvedSkipHooks,
            priorViewCommitRanges: resolvedViewCommitRanges,
            priorResultRows: resolvedResultRows
        )
    } else {
        runMultiRootPush(
            selectedRootPaths: retryPaths,
            explicitTargets: resolvedTargets.isEmpty ? nil : resolvedTargets,
            tagMode: resolvedTagMode,
            skipHooks: resolvedSkipHooks,
            force: resolvedForce,
            forceWithLease: resolvedForce && resolvedForceWithLease,
            priorViewCommitRanges: resolvedViewCommitRanges,
            priorResultRows: resolvedResultRows
        )
    }
}

/// Push leaves the local HEAD unchanged, so its View Commits range uses the
/// merge-base of the local tip and the tracked upstream tip, matching
/// IntelliJ's `GitUpdatedRanges` calculation. Roots without a resolvable
/// upstream or common ancestor are intentionally omitted: a first publish or
/// a tag-only push has no trustworthy old commit boundary.
nonisolated static func multiRootPushRevisionRanges(
    for rootPaths: [String],
    remote: String? = nil
) -> [PersistedLogRevisionRange] {
    let normalizedRootPaths = Set(rootPaths.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    })
    return normalizedRootPaths.compactMap { rootPath in
        guard let rootRepo = try? openRepository(path: rootPath),
              let branch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name,
              let head = rootRepo.headCommitId(),
              !head.isEmpty,
              let sync = (try? rootRepo.syncStatus())?.first(where: {
                  $0.branch == branch && $0.trackingExists
              }),
              remote.map({ sync.upstream.hasPrefix("\($0)/") }) ?? true,
              let upstreamHead = try? rootRepo.revisionCommitId(revision: sync.upstream),
              !upstreamHead.isEmpty,
              let rangeStart = try? rootRepo.mergeBaseRevisionId(
                  first: head,
                  second: upstreamHead
              ),
              !rangeStart.isEmpty,
              rangeStart != head else {
            return nil
        }
        return PersistedLogRevisionRange(
            rootPath: rootPath,
            oldRevision: rangeStart,
            newRevision: head
        )
    }
    .sorted { $0.rootPath < $1.rootPath }
}

/// Keep only ranges belonging to roots whose Push result actually completed.
/// This prevents a successful sibling from exposing a failed root's pending
/// commits in a compound notification.
nonisolated static func successfulPushRevisionRanges(
    pendingRanges: [PersistedLogRevisionRange],
    results: [RootOperationResult]
) -> [PersistedLogRevisionRange] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    let successfulRoots = Set(
        results
            .filter { $0.success && !$0.skipped }
            .map { normalizedPath($0.rootPath) }
    )
    return pendingRanges
        .filter { successfulRoots.contains(normalizedPath($0.rootPath)) }
        .sorted { $0.rootPath < $1.rootPath }
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

/// Rebuild the current branch when its upstream was force-pushed. IntelliJ
/// first offers the affected local changes, then routes Smart/Force/Cancel
/// through the same preserving decision used by checkout and merge.
func updateForcePushedBranch() {
    guard let repo else { return }
    do {
        let paths = try dirtyPathsForSmartDecision(repo)
        if paths.isEmpty {
            runForcePushedBranchUpdate(repo: repo, rootPath: nil, force: false)
        } else {
            feedbackCenter.warning(
                "Force-pushed branch update needs a decision",
                detail: paths.joined(separator: ", "),
                nextStep: "Choose Smart Update to preserve local changes, Force Update to discard them, or cancel."
            )
            presentSmartOperationDecision(
                operationTitle: "Force-pushed branch update",
                paths: paths,
                smartButtonTitle: "Smart Update",
                forceButtonTitle: "Force Update",
                onSmart: {
                    self.runForcePushedBranchUpdate(repo: repo, rootPath: nil, force: false)
                },
                onForce: {
                    self.runForcePushedBranchUpdate(repo: repo, rootPath: nil, force: true)
                }
            )
        }
    } catch {
        feedbackCenter.error(
            "Force-pushed branch update unavailable",
            detail: errorMessage(error),
            nextStep: "Refresh the repository, then retry the update."
        )
    }
}

/// The multi-root Branches Popup can target a current branch in a root that is
/// not the window's primary Repository. Preflight that root on a worker before
/// presenting the same affected-changes dialog.
func updateForcePushedBranchInRoot(rootPath: String, branch: String) {
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let paths = try dirtyPathsForSmartDecision(rootRepo)
            await MainActor.run {
                if paths.isEmpty {
                    self.runForcePushedBranchUpdate(
                        repo: rootRepo,
                        rootPath: rootPath,
                        force: false
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Force-pushed branch update needs a decision",
                        detail: "\(rootPath): \(paths.joined(separator: ", "))",
                        nextStep: "Choose Smart Update to preserve local changes, Force Update to discard them, or cancel."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Force-pushed branch update",
                        paths: paths.map { "\(rootPath): \($0)" },
                        smartButtonTitle: "Smart Update",
                        forceButtonTitle: "Force Update",
                        onSmart: {
                            self.runForcePushedBranchUpdate(
                                repo: rootRepo,
                                rootPath: rootPath,
                                force: false
                            )
                        },
                        onForce: {
                            self.runForcePushedBranchUpdate(
                                repo: rootRepo,
                                rootPath: rootPath,
                                force: true
                            )
                        }
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Force-pushed branch update unavailable",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Refresh Git Roots, then retry the update."
                )
            }
        }
    }
}

/// Present one Smart/Force decision for all eligible current roots that share
/// a branch name, then execute the engine's per-root aggregate operation.
func updateForcePushedBranchAcrossRoots(_ branch: String) {
    guard self.projectPath != nil else { return }
    let roots = multiRootBranchSnapshots.filter { snapshot in
        snapshot.branches.contains { $0.name == branch && $0.isCurrent }
            && snapshot.syncStatuses.contains {
                $0.branch == branch
                    && $0.trackingExists
                    && $0.ahead > 0
                    && $0.behind > 0
            }
    }
    guard !roots.isEmpty else {
        feedbackCenter.warning(
            "Force-pushed branch update unavailable",
            detail: branch,
            nextStep: "Refresh Git Roots and retry after the branch shows both local and remote divergence."
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        var dirtyByRoot: [(rootPath: String, displayName: String, paths: [String])] = []
        var preflightErrors: [String] = []
        for root in roots {
            do {
                let rootRepo = try openRepository(path: root.rootPath)
                let paths = try dirtyPathsForSmartDecision(rootRepo)
                if !paths.isEmpty {
                    dirtyByRoot.append((root.rootPath, root.displayName, paths))
                }
            } catch {
                preflightErrors.append("\(root.displayName): \(errorMessage(error))")
            }
        }

        let dirtyRoots = dirtyByRoot
        let errors = preflightErrors
        await MainActor.run {
            if !errors.isEmpty {
                self.feedbackCenter.error(
                    "Multi-root force-pushed update unavailable",
                    detail: errors.joined(separator: "\n"),
                    nextStep: "Refresh Git Roots, then retry the update."
                )
                return
            }
            let selectedRootPaths = roots.map(\.rootPath)
            if dirtyRoots.isEmpty {
                self.runMultiRootForcePushedBranchUpdate(
                    branch: branch,
                    selectedRootPaths: selectedRootPaths,
                    force: false
                )
            } else {
                let detail = dirtyRoots.map {
                    "\($0.displayName): \($0.paths.joined(separator: ", "))"
                }.joined(separator: "\n")
                self.feedbackCenter.warning(
                    "Multi-root force-pushed update needs a decision",
                    detail: detail,
                    nextStep: "Choose Smart Update to preserve local changes in each root, Force Update to discard them, or cancel."
                )
                self.presentSmartOperationDecision(
                    operationTitle: "Multi-root force-pushed branch update",
                    paths: dirtyRoots.flatMap { root in
                        root.paths.map { "\(root.displayName): \($0)" }
                    },
                    smartButtonTitle: "Smart Update",
                    forceButtonTitle: "Force Update",
                    onSmart: {
                        self.runMultiRootForcePushedBranchUpdate(
                            branch: branch,
                            selectedRootPaths: selectedRootPaths,
                            force: false
                        )
                    },
                    onForce: {
                        self.runMultiRootForcePushedBranchUpdate(
                            branch: branch,
                            selectedRootPaths: selectedRootPaths,
                            force: true
                        )
                    }
                )
            }
        }
    }
}

func runForcePushedBranchUpdate(
    repo: Repository,
    rootPath: String?,
    force: Bool
) {
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Update force-pushed branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let outcome: ForcePushedBranchUpdateOutcome
            if force {
                outcome = try repo.forcePushedBranchUpdateWithAuthAndCancelForce(
                    broker: broker,
                    cancel: cancel
                )
            } else {
                outcome = try repo.forcePushedBranchUpdateWithAuthAndCancel(
                    savePolicy: projectSavePolicy,
                    broker: broker,
                    cancel: cancel
                )
            }
            await MainActor.run {
                self.loadError = nil
                let updateDetail = outcome.usedMergeUpdate
                    ? "\(outcome.branch) ← \(outcome.upstream) · merge update"
                    : "\(outcome.branch) ← \(outcome.upstream) · replayed \(outcome.replayedCommits) local commit(s)"
                let counts = outcome.receivedCommitsCount > 0 || outcome.updatedFilesCount > 0
                    ? " · \(outcome.updatedFilesCount) updated file(s) in \(outcome.receivedCommitsCount) received commit(s)"
                    : ""
                let detail = rootPath.map { "\($0): \(updateDetail)\(counts)" } ?? "\(updateDetail)\(counts)"
                let viewCommitRanges = self.forcePushedRevisionRanges(
                    oldTip: outcome.updateRangeStart,
                    newTip: outcome.newUpstreamTip,
                    rootPath: rootPath
                )
                let viewAction = self.forcePushedViewCommitsAction(
                    ranges: viewCommitRanges,
                    rootPath: rootPath
                )
                self.feedbackCenter.success(
                    "Force-pushed branch updated",
                    detail: detail,
                    additionalActions: viewAction.map { [$0] } ?? [],
                    notificationID: rootPath.map { "git.force-pushed-update.\($0)" }
                        ?? "git.force-pushed-update"
                )
                self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
                if rootPath == nil {
                    self.refreshAll(showFeedback: false)
                    self.loadRepoData()
                } else {
                    self.loadMultiRoots()
                }
            }
        } catch {
            let operationState = (try? repo.operationState()) ?? nil
            let backupBranchNames = (try? repo.branchList())?
                .filter { isArborForcePushedBackupBranch($0.name) }
                .map(\.name)
                .sorted() ?? []
            await MainActor.run {
                self.loadError = errorMessage(error)
                let isPrimaryRoot = rootPath == nil || rootPath == repo.workdir()
                let backupActions = self.forcePushedBackupActions(
                    rootPath: rootPath,
                    branchNames: backupBranchNames
                )
                if !backupBranchNames.isEmpty {
                    self.feedbackCenter.warning(
                        "Force-pushed backup branch kept",
                        detail: backupBranchNames.joined(separator: ", "),
                        nextStep: "Saved backup branches remain available for inspection or deletion.",
                        additionalActions: backupActions
                    )
                }
                if isPrimaryRoot, case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Force-pushed branch update",
                        stashID: stashID
                    )
                } else if isPrimaryRoot,
                          case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    self.presentShelveConflict(name: name, paths: paths, isPop: true)
                } else if let rootPath {
                    self.feedbackCenter.warning(
                        "Force-pushed branch update paused",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Open the Git Roots conflict workbench to resolve the saved local changes.",
                        actionTitle: "Resolve Conflicts",
                        action: { self.openMultiRootConflictResolver(preferredRootPath: rootPath) },
                        additionalActions: backupActions
                    )
                    self.loadMultiRoots()
                } else if operationState != nil {
                    self.feedbackCenter.warning(
                        "Force-pushed branch update paused",
                        detail: errorMessage(error),
                        nextStep: "Resolve the pending operation, then Continue or Abort.",
                        actionTitle: "Resolve Conflicts",
                        action: self.openActiveOperationConflictResolver,
                        additionalActions: backupActions
                    )
                } else {
                    self.feedbackCenter.error(
                        "Force-pushed branch update failed",
                        detail: errorMessage(error),
                        nextStep: "Inspect the backup branch and current Git state before retrying.",
                        additionalActions: backupActions
                    )
                }
            }
        }
    }
}

func runMultiRootForcePushedBranchUpdate(
    branch: String,
    selectedRootPaths: [String],
    force: Bool
) {
    guard let projectPath else { return }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    multiRootRunning = true
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Multi-root force-pushed branch update", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let results = try runMultiRootForcePushedBranchUpdateWithAuthAndCancel(
                scanRoot: projectPath,
                selectedRootPaths: selectedRootPaths,
                broker: broker,
                cancel: cancel,
                savePolicy: projectSavePolicy,
                force: force
            )
            let operationResults = results.map { result in
                RootOperationResult(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    success: result.success,
                    skipped: result.skipped,
                    message: result.message
                )
            }
            let failures = results.filter { !$0.success }
            let skippedResults = results.filter { $0.skipped }
            let successCount = results.filter { $0.success && !$0.skipped }.count
            var backupBranchesByRoot: [String: [String]] = [:]
            for result in failures {
                guard let rootRepo = try? openRepository(path: result.rootPath) else { continue }
                let branchNames = (try? rootRepo.branchList())?
                    .filter { isArborForcePushedBackupBranch($0.name) }
                    .map(\.name)
                    .sorted() ?? []
                if !branchNames.isEmpty {
                    backupBranchesByRoot[result.rootPath] = branchNames
                }
            }
            let finalizedBackupBranchesByRoot = backupBranchesByRoot
            await MainActor.run {
                self.multiRootRunning = false
                self.multiRootResults = operationResults
                self.loadMultiRoots()
                let successfulResults = results.filter { $0.success && !$0.skipped }
                let receivedCommits = successfulResults.reduce(0) { $0 + Int($1.receivedCommitsCount) }
                let updatedFiles = successfulResults.reduce(0) { $0 + Int($1.updatedFilesCount) }
                let countDetail = receivedCommits > 0 || updatedFiles > 0
                    ? " · \(updatedFiles) updated file(s) in \(receivedCommits) received commit(s)"
                    : ""
                let skippedDetail = self.forcePushedSkippedDetail(skippedResults)
                let viewCommitRanges = successfulResults.compactMap { result in
                    self.forcePushedRevisionRanges(
                        oldTip: result.updateRangeStart,
                        newTip: result.newUpstreamTip,
                        rootPath: result.rootPath
                    ).first
                }
                let viewAction = self.forcePushedViewCommitsAction(
                    ranges: viewCommitRanges
                )
                if failures.isEmpty {
                    self.feedbackCenter.success(
                        "Multi-root force-pushed branch updated",
                        detail: "\(successCount) repositories · \(branch)\(countDetail)\(skippedDetail)",
                        additionalActions: viewAction.map { [$0] } ?? [],
                        notificationID: "git.force-pushed-update.multi-root"
                    )
                } else {
                    let detail = failures.map {
                        "\($0.displayName): \($0.message.isEmpty ? "failed" : $0.message)"
                    }.joined(separator: "\n")
                    let pendingRoot = failures.first(where: { !$0.localChangesOverwritePaths.isEmpty })?.rootPath
                    let backupActions = self.forcePushedBackupActionsByRoot(finalizedBackupBranchesByRoot)
                    let backupDetail = finalizedBackupBranchesByRoot
                        .sorted { $0.key < $1.key }
                        .flatMap { rootPath, names in
                            names.map { "\(rootPath): \($0)" }
                        }
                        .joined(separator: "\n")
                    let detailWithBackups = backupDetail.isEmpty
                        ? detail
                        : "\(detail)\n\n\(String(localized: "Backup branches kept")):\n\(backupDetail)"
                    var additionalActions = backupActions
                    if let viewAction {
                        additionalActions.insert(viewAction, at: 0)
                    }
                    self.feedbackCenter.warning(
                        "Multi-root force-pushed update partially completed",
                        detail: "\(detailWithBackups)\(countDetail)\(skippedDetail)",
                        nextStep: "Review each Git root; saved local changes remain available for recovery.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            self.openMultiRootConflictResolver(preferredRootPath: pendingRoot)
                        },
                        additionalActions: additionalActions,
                        notificationID: "git.force-pushed-update.multi-root"
                    )
                }
                self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
            }
        } catch {
            await MainActor.run {
                self.multiRootRunning = false
                self.feedbackCenter.error(
                    "Multi-root force-pushed update failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry the update."
                )
            }
        }
    }
}

func forcePushedSkippedDetail(
    _ results: [MultiRootForcePushedBranchUpdateResult]
) -> String {
    guard !results.isEmpty else { return "" }
    let grouped = Dictionary(grouping: results, by: \.message)
        .sorted { $0.key < $1.key }
        .map { reason, roots in
            "\(roots.map(\.displayName).sorted().joined(separator: ", ")) (\(reason))"
        }
        .joined(separator: "; ")
    return " · skipped roots: \(grouped)"
}

func forcePushedRevisionRanges(
    oldTip: String?,
    newTip: String,
    rootPath: String?
) -> [PersistedLogRevisionRange] {
    guard let oldTip,
          !oldTip.isEmpty,
          !newTip.isEmpty,
          oldTip != newTip,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return [] }
    return [PersistedLogRevisionRange(
        rootPath: resolvedRootPath,
        oldRevision: oldTip,
        newRevision: newTip
    )]
}

func forcePushedViewCommitsAction(
    oldTip: String?,
    newTip: String,
    rootPath: String?
) -> FeedbackAction? {
    let ranges = forcePushedRevisionRanges(
        oldTip: oldTip,
        newTip: newTip,
        rootPath: rootPath
    )
    return forcePushedViewCommitsAction(ranges: ranges, rootPath: rootPath)
}

func forcePushedViewCommitsAction(
    ranges: [PersistedLogRevisionRange],
    rootPath: String? = nil
) -> FeedbackAction? {
    guard !ranges.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showLogRanges,
        projectPath: projectPath,
        rootPath: ranges.count == 1 ? rootPath : nil,
        shelfName: "",
        logRevisionRanges: ranges
    )
    return FeedbackAction(title: "View Commits", semanticAction: request) {
        self.showLogRevisionRanges(ranges)
    }
}

func forcePushedBackupActions(
    rootPath: String?,
    branchNames: [String]
) -> [FeedbackAction] {
    guard !branchNames.isEmpty else { return [] }
    var actions = [
        FeedbackAction(title: "Open Branches") {
            if rootPath == nil {
                self.loadRepoData()
            } else {
                self.loadMultiRoots()
            }
            self.showBranchesPopover = true
        }
    ]
    actions.append(contentsOf: branchNames.map { branchName in
        FeedbackAction(title: "Delete backup branch") {
            self.deleteForcePushedBackupBranch(rootPath: rootPath, name: branchName)
        }
    })
    return actions
}

func forcePushedBackupActionsByRoot(
    _ branchesByRoot: [String: [String]]
) -> [FeedbackAction] {
    guard !branchesByRoot.isEmpty else { return [] }
    var actions = [
        FeedbackAction(title: "Open Branches") {
            self.loadMultiRoots()
            self.showBranchesPopover = true
        }
    ]
    for (rootPath, branchNames) in branchesByRoot.sorted(by: { $0.key < $1.key }) {
        actions.append(contentsOf: branchNames.map { branchName in
            FeedbackAction(title: "Delete backup branch") {
                self.deleteForcePushedBackupBranch(rootPath: rootPath, name: branchName)
            }
        })
    }
    return actions
}

func deleteForcePushedBackupBranch(rootPath: String?, name: String) {
    guard isArborForcePushedBackupBranch(name) else { return }
    if let rootPath {
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                await MainActor.run {
                    self.prepareForceDeleteBranch(repo: rootRepo, name: name, rootPath: rootPath)
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Delete backup branch failed",
                        detail: "\(rootPath): \(errorMessage(error))"
                    )
                }
            }
        }
    } else if let repo {
        prepareForceDeleteBranch(repo: repo, name: name, rootPath: nil)
    }
}

/// 多 root Branches Popup 的 Push 对话框必须先读取目标 root 的数据，不能
/// 复用当前窗口绑定的 remote、branch 或 log 列表。
func beginMultiRootPushDialog(rootPath: String, branch: String) {
    beginFeedbackOperation("Load Push dialog")
    let defaultPushTagMode = GitPushTagSettings.projectTagMode(for: projectPath)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let remotes = try rootRepo.remoteList()
            guard !remotes.isEmpty else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "该 Git root 没有配置 remote。"]
                )
            }
            let branches = try rootRepo.branchList()
            let commits = try rootRepo.log(path: nil, limit: 200, follow: false, afterId: nil)
            let syncStatuses = try rootRepo.syncStatus()
            let selectedBranch = branches.contains(where: { $0.name == branch })
                ? branch
                : branches.first(where: { $0.isCurrent })?.name
            let configuredTarget = syncStatuses
                .first(where: { $0.branch == selectedBranch && $0.trackingExists })
                .flatMap {
                    remoteBranchTargetForConfiguredUpstream($0.upstream, remotes: remotes)
                }
            await MainActor.run {
                self.multiRootPushContext = MultiRootPushContext(
                    rootPath: rootPath,
                    repo: rootRepo,
                    remotes: remotes,
                    branches: branches,
                    commits: commits,
                    defaultRemote: configuredTarget?.remote
                        ?? (remotes.count == 1 ? remotes[0].name : nil),
                    defaultBranch: configuredTarget?.branch ?? selectedBranch,
                    defaultSourceRevision: selectedBranch,
                    currentHasUpstream: syncStatuses.first(where: { $0.branch == selectedBranch })?.trackingExists ?? false,
                    protectedBranchPatterns: self.effectiveProtectedBranchPatterns(
                        forRootPath: rootPath
                    ),
                    defaultPushTagMode: defaultPushTagMode
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Push unavailable",
                    detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Configure a remote in that Git root, then retry."
                )
            }
        }
    }
}

func pushNotificationID(rootPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.push.v1.\(encoded)"
}

func singleRootPushRecoveryRequest(
    rootPath: String,
    recovery: PersistedPushRecovery,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .retryPushRecovery,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        pushRecovery: recovery,
        logRevisionRanges: viewCommitRanges.isEmpty ? nil : viewCommitRanges
    )
}

func singleRootPushRequest(
    rootPath: String,
    remote: String,
    branch: String,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .retryPush,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        pushRecovery: PersistedPushRecovery(
            remote: remote,
            branch: branch,
            force: force,
            forceWithLease: forceWithLease,
            setUpstream: setUpstream,
            refspec: refspec,
            tagModeRaw: tagMode?.rawValue,
            skipHooks: skipHooks,
            rebase: false
        ),
        logRevisionRanges: viewCommitRanges.isEmpty ? nil : viewCommitRanges
    )
}

func directPushRetryActions(
    rootPath: String,
    remote: String,
    branch: String,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = [],
    includeForce: Bool
) -> [FeedbackAction] {
    let retryRequest = singleRootPushRequest(
        rootPath: rootPath,
        remote: remote,
        branch: branch,
        force: force,
        forceWithLease: forceWithLease,
        setUpstream: setUpstream,
        refspec: refspec,
        tagMode: tagMode,
        skipHooks: skipHooks,
        viewCommitRanges: viewCommitRanges
    )
    var actions = [FeedbackAction]()
    if includeForce {
        let forceRequest = singleRootPushRequest(
            rootPath: rootPath,
            remote: remote,
            branch: branch,
            force: true,
            forceWithLease: false,
            setUpstream: setUpstream,
            refspec: refspec,
            tagMode: tagMode,
            skipHooks: skipHooks,
            viewCommitRanges: viewCommitRanges
        )
        actions.append(
            FeedbackAction(title: "Force Push Anyway", semanticAction: forceRequest) {
                self.handleVCSActionRequest(forceRequest)
            }
        )
    }
    actions.append(
        FeedbackAction(title: "Retry Push", semanticAction: retryRequest) {
            self.handleVCSActionRequest(retryRequest)
        }
    )
    return actions
}

/// Retry the original Push itself after a rejected or transport failure. The
/// root, remote, branch, refspec and force policy are persisted; only the
/// current Git state is revalidated before starting the command.
func retrySingleRootPush(
    rootPath: String,
    push: PersistedPushRecovery,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    let hasCustomRefspec = !(push.refspec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    guard !push.remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          hasCustomRefspec || !push.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.error(
            "Push retry unavailable",
            detail: "The saved Push request is incomplete; no Git operation was started.",
            nextStep: "Open Push again and retry after selecting a remote and branch.",
            notificationID: pushNotificationID(rootPath: rootPath)
        )
        return
    }
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.warning(
            "Push retry unavailable",
            detail: "Open the Git root that originally rejected the Push before retrying.",
            nextStep: rootPath,
            notificationID: pushNotificationID(rootPath: rootPath),
            notificationGroup: .important
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        let currentBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name
        let branchIsValid = hasCustomRefspec || currentBranch == push.branch
        await MainActor.run {
            guard branchIsValid else {
                self.feedbackCenter.warning(
                    "Push retry is stale",
                    detail: "The checked-out branch changed. No Push was started.",
                    nextStep: "Switch back to \(push.branch), then retry the Push action.",
                    notificationID: self.pushNotificationID(rootPath: rootPath),
                    notificationGroup: .important
                )
                return
            }
            self.pushInRoot(
                rootPath: rootPath,
                remote: push.remote,
                branch: push.branch,
                force: push.force,
                forceWithLease: push.forceWithLease,
                setUpstream: push.setUpstream,
                refspec: push.refspec,
                tagMode: push.tagModeRaw.flatMap(PushDialogTagMode.init(rawValue:)),
                skipHooks: push.skipHooks,
                viewCommitRanges: viewCommitRanges
            )
        }
    }
}

/// Resume the rejected-push follow-up only when the original Git root and
/// checked-out branch are still active. IntelliJ's notification action is
/// bound to the Push operation; silently applying it to a different branch
/// after relaunch would be materially unsafe.
func retrySingleRootPushRecovery(
    rootPath: String,
    recovery: PersistedPushRecovery,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    guard !recovery.remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !recovery.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.error(
            "Push recovery unavailable",
            detail: "The saved Push recovery request is incomplete; no Git operation was started.",
            nextStep: "Open Push again and retry after selecting a remote and branch.",
            notificationID: pushNotificationID(rootPath: rootPath)
        )
        return
    }
    guard let activeRepo = repo,
          let activePath = activeRepo.workdir(),
          URL(fileURLWithPath: activePath).standardizedFileURL.path
              == URL(fileURLWithPath: rootPath).standardizedFileURL.path else {
        feedbackCenter.warning(
            "Push recovery unavailable",
            detail: "Open the Git root that originally rejected the Push before retrying.",
            nextStep: rootPath,
            notificationID: pushNotificationID(rootPath: rootPath),
            notificationGroup: .important
        )
        return
    }

    let expectedBranch = recovery.branch
    Task.detached(priority: .userInitiated) {
        let currentBranch = (try? activeRepo.branchList())?.first(where: { $0.isCurrent })?.name
        let trackingExists = (try? activeRepo.syncStatus())?
            .first(where: { $0.branch == expectedBranch })?
            .trackingExists == true
        await MainActor.run {
            guard currentBranch == expectedBranch, trackingExists else {
                self.feedbackCenter.warning(
                    "Push recovery is stale",
                    detail: "The repository branch or its configured upstream changed. No update or push was started.",
                    nextStep: "Switch back to \(expectedBranch) and restore its upstream, then retry the Push recovery action.",
                    notificationID: self.pushNotificationID(rootPath: rootPath),
                    notificationGroup: .important
                )
                return
            }
            // Keep the recovery as one root-scoped compound operation. The
            // generic doPull/doPush path owns separate global operation
            // lifecycles and would lose the original Push notification and
            // root context when update pauses for conflicts.
            self.updateRootForPushRecovery(
                rootPath: rootPath,
                remote: recovery.remote,
                branch: recovery.branch,
                force: recovery.force,
                forceWithLease: recovery.forceWithLease,
                setUpstream: recovery.setUpstream,
                refspec: nil,
                tagMode: recovery.tagModeRaw.flatMap(PushDialogTagMode.init(rawValue:)),
                skipHooks: recovery.skipHooks,
                rebase: recovery.rebase,
                viewCommitRanges: viewCommitRanges
            )
        }
    }
}

/// 从 root-scoped Push 对话框执行完整 push 选择：remote、branch、force、
/// force-with-lease、publish/upstream 和 custom refspec 都固定在该 root。
func pushInRoot(
    rootPath: String,
    remote requestedRemote: String?,
    branch requestedBranch: String?,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let protectedPatterns = effectiveProtectedBranchPatterns(forRootPath: rootPath)
    let notificationID = pushNotificationID(rootPath: rootPath)
    beginFeedbackOperation("Push", cancelHandle: cancel, notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        var resolvedRemote = requestedRemote
        var resolvedBranch = requestedBranch
        do {
            let rootRepo = try openRepository(path: rootPath)
            let rootRemotes = try rootRepo.remoteList()
            guard let remote = resolveSelectedRemoteName(
                selectedRemote: requestedRemote,
                availableRemoteNames: rootRemotes.map(\.name)
            ) else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: rootRemotes.count > 1
                            ? "该 Git root 配置了多个 remote，请先选择目标 remote。"
                            : "该 Git root 没有可用的 remote。"
                    ]
                )
            }
            resolvedRemote = remote
            let rootBranches = try rootRepo.branchList()
            let branch = requestedBranch
                ?? rootBranches.first(where: { $0.isCurrent })?.name
                ?? ""
            let hasCustomRefspec = !(refspec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard hasCustomRefspec || !branch.isEmpty else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Push 需要一个本地分支。"]
                )
            }
            resolvedBranch = branch
            let effectiveForce = force || PushDialogRefspec.requestsForce(refspec)
            let protectedTarget = PushDialogRefspec.targetBranch(refspec) ?? branch
            guard !effectiveForce || !GitProtectedBranchRules.matches(
                protectedTarget,
                patterns: protectedPatterns
            ) else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "\(protectedTarget) is protected by Git settings."]
                )
            }
            let engineTagMode = tagMode.map { mode in
                switch mode {
                case .all: PushTagMode.all
                case .currentBranch: PushTagMode.follow
                }
            }
            if let refspec, !refspec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if engineTagMode != nil || skipHooks {
                    try rootRepo.pushRefspecWithOptionsAndAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: effectiveForce,
                        forceWithLease: effectiveForce && forceWithLease,
                        tagMode: engineTagMode,
                        skipHooks: skipHooks,
                        broker: broker,
                        cancel: cancel
                    )
                } else {
                    try rootRepo.pushRefspecWithAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: effectiveForce,
                        forceWithLease: effectiveForce && forceWithLease,
                        broker: broker,
                        cancel: cancel
                    )
                }
            } else {
                let trackingExists = (try rootRepo.syncStatus())
                    .first(where: { $0.branch == branch })?.trackingExists ?? false
                try rootRepo.pushWithOptionsAndAuthAndCancel(
                    remote: remote,
                    branch: branch,
                    force: effectiveForce,
                    forceWithLease: effectiveForce && forceWithLease,
                    setUpstream: setUpstream || !trackingExists,
                    tagMode: engineTagMode,
                    skipHooks: skipHooks,
                    broker: broker,
                    cancel: cancel
                )
            }
            await MainActor.run {
                self.loadMultiRoots()
                let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: viewCommitRanges
                )
                self.feedbackCenter.success(
                    "Push completed",
                    detail: "\(remote)/\(branch) · \(rootPath)",
                    additionalActions: viewCommitsAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
                self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
            }
        } catch {
            let retryRemote = resolvedRemote
            let retryBranch = resolvedBranch
            let recoveryRepo = try? openRepository(path: rootPath)
            let recoveryBranches = recoveryRepo.flatMap { try? $0.branchList() } ?? []
            let recoveryStatuses = recoveryRepo.flatMap { try? $0.syncStatus() } ?? []
            let currentBranchForPush = recoveryBranches.first(where: { $0.isCurrent })?.name
            let hasTrackingForPush = recoveryStatuses
                .first(where: { $0.branch == retryBranch })?.trackingExists ?? false
            await MainActor.run {
                self.loadMultiRoots()
                if let stale = stalePushRejectionDetails(error) {
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: viewCommitRanges
                    )
                    let actions = self.directPushRetryActions(
                        rootPath: rootPath,
                        remote: stale.remote,
                        branch: stale.branch,
                        force: force,
                        forceWithLease: forceWithLease,
                        setUpstream: setUpstream,
                        refspec: refspec,
                        tagMode: tagMode,
                        skipHooks: skipHooks,
                        viewCommitRanges: viewCommitRanges,
                        includeForce: true
                    ) + (viewCommitsAction.map { [$0] } ?? []) + [
                        self.showOperationDetailsAction(notificationID: notificationID)
                    ]
                    self.feedbackCenter.warning(
                        "Push rejected by force-with-lease",
                        detail: "\(rootPath): \(stale.remote)/\(stale.branch): \(stale.message)",
                        nextStep: "The remote branch changed after the lease was recorded. Verify the remote history before overwriting it.",
                        additionalActions: actions,
                        notificationID: notificationID,
                        notificationGroup: .important,
                        localized: false
                    )
                } else if case let .PushRejected(kind, rejectedRemote, rejectedBranch, message) = error as? EngineError,
                          kind == .nonFastForward,
                          !force,
                          refspec == nil {
                    let autoUpdate = gitPushAutoUpdateIsEligible(
                        enabled: GitPushAutoUpdateSettings.value(for: self.projectPath),
                        force: force,
                        refspec: refspec,
                        currentBranch: currentBranchForPush,
                        rejectedBranch: rejectedBranch,
                        hasTracking: hasTrackingForPush
                    )
                    if autoUpdate {
                        self.updateRootForPushRecovery(
                            rootPath: rootPath,
                            remote: rejectedRemote,
                            branch: rejectedBranch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: nil,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            rebase: GitUpdateMethodSettings.method(for: self.projectPath) == .rebase,
                            viewCommitRanges: viewCommitRanges
                        )
                    } else {
                        let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                            ranges: viewCommitRanges
                        )
                        let recovery = PersistedPushRecovery(
                            remote: rejectedRemote,
                            branch: rejectedBranch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagModeRaw: tagMode?.rawValue,
                            skipHooks: skipHooks,
                            rebase: false
                        )
                        let mergeRequest = self.singleRootPushRecoveryRequest(
                            rootPath: rootPath,
                            recovery: recovery,
                            viewCommitRanges: viewCommitRanges
                        )
                        let rebaseRequest = self.singleRootPushRecoveryRequest(
                            rootPath: rootPath,
                            recovery: PersistedPushRecovery(
                                remote: recovery.remote,
                                branch: recovery.branch,
                                force: recovery.force,
                                forceWithLease: recovery.forceWithLease,
                                setUpstream: recovery.setUpstream,
                                refspec: recovery.refspec,
                                tagModeRaw: recovery.tagModeRaw,
                                skipHooks: recovery.skipHooks,
                                rebase: true
                            ),
                            viewCommitRanges: viewCommitRanges
                        )
                        let recoveryActions = [
                            FeedbackAction(title: "Update with Merge", semanticAction: mergeRequest) {
                                self.handleVCSActionRequest(mergeRequest)
                            },
                            FeedbackAction(title: "Update with Rebase", semanticAction: rebaseRequest) {
                                self.handleVCSActionRequest(rebaseRequest)
                            }
                        ] + self.directPushRetryActions(
                            rootPath: rootPath,
                            remote: rejectedRemote,
                            branch: rejectedBranch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            viewCommitRanges: viewCommitRanges,
                            includeForce: false
                        ) + (viewCommitsAction.map { [$0] } ?? []) + [
                            self.showOperationDetailsAction(notificationID: notificationID)
                        ]
                        self.feedbackCenter.warning(
                            "Push rejected",
                            detail: "\(rootPath): \(rejectedRemote)/\(rejectedBranch): \(message)",
                            nextStep: "Update this Git root, resolve any conflicts, then retry Push.",
                            additionalActions: recoveryActions,
                            notificationID: notificationID,
                            notificationGroup: .important,
                            localized: false
                        )
                    }
                } else {
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: viewCommitRanges
                    )
                    let retryActions: [FeedbackAction]
                    let hasCustomRefspec = !(refspec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    if let remote = retryRemote,
                       let branch = retryBranch,
                       !remote.isEmpty,
                       hasCustomRefspec || !branch.isEmpty {
                        retryActions = self.directPushRetryActions(
                            rootPath: rootPath,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            viewCommitRanges: viewCommitRanges,
                            includeForce: false
                        )
                    } else {
                        retryActions = []
                    }
                    self.feedbackCenter.error(
                        "Push failed",
                        detail: "\(rootPath): \(friendlyRemoteError(error))",
                        nextStep: "Check the selected remote, refspec, credentials, and protected-branch settings.",
                        additionalActions: retryActions
                            + (viewCommitsAction.map { [$0] } ?? [])
                            + [self.showOperationDetailsAction(notificationID: notificationID)],
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

/// Root-scoped recovery for a rejected push. The selected nested repository is
/// updated directly; it never falls back to the superproject's current repo.
/// A clean update proceeds straight to the original push, while an update
/// conflict stays in the existing project-level resolver with a Resolve action.
func updateRootForPushRecovery(
    rootPath: String,
    remote: String,
    branch: String,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    rebase: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let notificationID = pushNotificationID(rootPath: rootPath)
    beginFeedbackOperation(
        rebase ? "Update root with rebase" : "Update root with merge",
        cancelHandle: cancel,
        notificationID: notificationID
    )
    let fetchTagMode = fetchTagsMode
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        let previousHeads = Self.headCommitIDs(for: [rootPath])
        do {
            let result = try runRootUpdateForPushRecoveryWithOptions(
                rootPath: rootPath,
                remote: remote,
                branch: branch,
                rebase: rebase,
                tagMode: fetchTagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: projectSavePolicy
            )
            let currentHeads = Self.headCommitIDs(for: [rootPath])
            let latestViewCommitRanges = result.success && !result.skipped
                ? Self.updateSessionRevisionRanges(
                    previousHeads: previousHeads,
                    currentHeads: currentHeads,
                    results: [result]
                )
                : []
            let combinedViewCommitRanges = Self.joinedRevisionRanges(
                existing: viewCommitRanges,
                latest: latestViewCommitRanges
            )
            await MainActor.run {
                self.loadMultiRoots()
                let existingViewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: viewCommitRanges
                )
                if result.success && !result.skipped {
                    self.feedbackCenter.success(
                        "Root updated; retrying Push",
                        detail: "\(rootPath): \(remote)/\(branch)",
                        notificationID: notificationID
                    )
                    self.pushInRoot(
                        rootPath: rootPath,
                        remote: remote,
                        branch: branch,
                        force: force,
                        forceWithLease: forceWithLease,
                        setUpstream: setUpstream,
                        refspec: refspec,
                        tagMode: tagMode,
                        skipHooks: skipHooks,
                        viewCommitRanges: combinedViewCommitRanges
                    )
                } else if result.skipped {
                    self.feedbackCenter.warning(
                        "Push update cancelled",
                        detail: "\(rootPath): \(result.message)",
                        nextStep: "Retry the root-scoped update when the worktree is ready.",
                        actionTitle: "Retry Update",
                        action: {
                            self.updateRootForPushRecovery(
                                rootPath: rootPath,
                                remote: remote,
                                branch: branch,
                                force: force,
                                forceWithLease: forceWithLease,
                                setUpstream: setUpstream,
                                refspec: refspec,
                                tagMode: tagMode,
                                skipHooks: skipHooks,
                                rebase: rebase,
                                viewCommitRanges: viewCommitRanges
                            )
                        },
                        additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                        notificationID: notificationID,
                        localized: false
                    )
                } else if result.message.localizedCaseInsensitiveContains("conflict")
                            || result.message.localizedCaseInsensitiveContains("operation is already in progress") {
                    self.feedbackCenter.warning(
                        "Push update paused for conflicts",
                        detail: "\(rootPath): \(result.message)",
                        nextStep: "Resolve the files in this Git root, then continue the operation.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                        },
                        additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                        notificationID: notificationID,
                        localized: false
                    )
                } else {
                    self.feedbackCenter.error(
                        "Push update failed",
                        detail: "\(rootPath): \(result.message)",
                        nextStep: "Resolve the update error, then retry the root-scoped update.",
                        actionTitle: "Retry Update",
                        action: {
                            self.updateRootForPushRecovery(
                                rootPath: rootPath,
                                remote: remote,
                                branch: branch,
                                force: force,
                                forceWithLease: forceWithLease,
                                setUpstream: setUpstream,
                                refspec: refspec,
                                tagMode: tagMode,
                                skipHooks: skipHooks,
                                rebase: rebase,
                                viewCommitRanges: viewCommitRanges
                            )
                        },
                        additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                        notificationID: notificationID,
                        localized: false
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                let existingViewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: viewCommitRanges
                )
                self.feedbackCenter.error(
                    "Push update failed",
                    detail: "\(rootPath): \(friendlyRemoteError(error))",
                    nextStep: "Resolve the update error, then retry the root-scoped update.",
                    actionTitle: "Retry Update",
                    action: {
                        self.updateRootForPushRecovery(
                            rootPath: rootPath,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            rebase: rebase,
                            viewCommitRanges: viewCommitRanges
                        )
                    },
                    additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            }
        }
    }
}

func pushTagInRoot(rootPath: String, name: String, remote selectedRemote: String? = nil) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push tag", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let remoteNames = try rootRepo.remoteList().map(\.name)
            guard let remote = resolveSelectedRemoteName(
                selectedRemote: selectedRemote,
                availableRemoteNames: remoteNames
            ) else {
                throw NSError(
                    domain: "Arbor.PushTags",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: selectedRemote == nil
                            ? "Multiple remotes are configured; choose a remote before pushing the tag."
                            : "The selected remote is no longer configured."
                    ]
                )
            }
            try rootRepo.tagPushWithAuthAndCancel(
                remote: remote,
                tag: name,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Tag pushed", detail: "\(name) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Push tag failed", detail: "\(name) · \(rootPath): \(friendlyRemoteError(error))")
                if self.isAuthenticationFailure(error) { self.showHostingAuthPrompt = true }
            }
        }
    }
}

/// Push every local tag to the selected root's explicitly selected or only
/// configured remote. This mirrors IntelliJ's Git.Push.Tags action while
/// keeping the operation non-forceful:
/// divergent remote tags are rejected by Git instead of being overwritten.
func pushAllTagsInRoot(rootPath: String, remote selectedRemote: String? = nil) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push all tags", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let remoteNames = try rootRepo.remoteList().map(\.name)
            guard let remote = resolveSelectedRemoteName(
                selectedRemote: selectedRemote,
                availableRemoteNames: remoteNames
            ) else {
                throw NSError(
                    domain: "Arbor.PushTags",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: selectedRemote == nil
                            ? "Multiple remotes are configured; choose a remote before pushing all tags."
                            : "The selected remote is no longer configured."
                    ]
                )
            }
            try rootRepo.pushRefspecWithAuthAndCancel(
                remote: remote,
                refspec: "refs/tags/*:refs/tags/*",
                force: false,
                forceWithLease: false,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("All tags pushed", detail: "\(remote) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error(
                    "Push all tags failed",
                    detail: "\(rootPath): \(friendlyRemoteError(error))",
                    nextStep: "Check the remote and tag names, then retry."
                )
            }
        }
    }
}

/// Phase 5：推送 tag 到远程。
func tagPushToRemote(_ name: String, remote selectedRemote: String? = nil) {
    guard let repo,
          let remote = resolveSelectedRemoteName(
              selectedRemote: selectedRemote,
              availableRemoteNames: remotes.map(\.name)
          ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing the tag",
            detail: "Multiple remotes are configured for this Git root."
        )
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push tag", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.tagPushWithAuthAndCancel(
                remote: remote,
                tag: name,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run { self.feedbackCenter.success("Tag pushed", detail: "\(remote)/\(name)") }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Push tag failed", detail: friendlyRemoteError(error), nextStep: "检查远程与 tag 后重试。")
                if self.isAuthenticationFailure(error) { self.showHostingAuthPrompt = true }
            }
        }
    }
}

/// Push all local tags to the current root's explicitly selected or only configured remote.
func pushAllTagsToRemote(remote selectedRemote: String? = nil) {
    guard let repo,
          let remote = resolveSelectedRemoteName(
              selectedRemote: selectedRemote,
              availableRemoteNames: remotes.map(\.name)
          ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing all tags",
            detail: "Multiple remotes are configured for this Git root."
        )
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push all tags", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.pushRefspecWithAuthAndCancel(
                remote: remote,
                refspec: "refs/tags/*:refs/tags/*",
                force: false,
                forceWithLease: false,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.feedbackCenter.success("All tags pushed", detail: remote)
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Push all tags failed",
                    detail: friendlyRemoteError(error),
                    nextStep: "Check the remote and tag names, then retry."
                )
            }
        }
    }
}

func doPush(
    _ name: String? = nil,
    branch requestedBranch: String? = nil,
    force requestedForce: Bool? = nil,
    forceWithLease requestedForceWithLease: Bool? = nil,
    setUpstream: Bool = false,
    refspec: String? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool = false,
    viewCommitRanges: [PersistedLogRevisionRange] = [],
    afterCommit: Bool = false
) {
    guard let repo else { return }
    guard let remote = resolveSelectedRemoteName(
        selectedRemote: name,
        availableRemoteNames: remotes.map(\.name)
    ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing",
            detail: remotes.count > 1
                ? "Multiple remotes are configured for this Git root."
                : "No usable remote is configured for this Git root."
        )
        return
    }
    let branch = requestedBranch ?? branches.first { $0.isCurrent }?.name ?? "main"
    let force = (requestedForce ?? pushForce) || PushDialogRefspec.requestsForce(refspec)
    let useForceWithLease = GitPushSettings.useForceWithLease(force: force, requested: requestedForceWithLease)
    let protectedTarget = PushDialogRefspec.targetBranch(refspec) ?? branch
    if force,
       GitProtectedBranchRules.matches(
           protectedTarget,
           patterns: effectiveProtectedBranchPatterns
       ) {
        feedbackCenter.error(
            "Force push blocked",
            detail: "\(protectedTarget) is protected by Git settings.",
            nextStep: "Edit Protected Branches in Settings or use a non-force push."
        )
        return
    }
    let cancel = GitCancelHandle()
    let notificationID = pushNotificationID(rootPath: repo.workdir() ?? "current")
    let rootPath = repo.workdir()
    beginFeedbackOperation("Push", cancelHandle: cancel, notificationID: notificationID)
    let currentBranchForPush = currentBranchName
    let publish = setUpstream
        || (branch == currentBranchForPush && currentSyncStatus?.trackingExists == false)
    let broker = credentialAuth.broker
    let engineTagMode = tagMode.map { mode in
        switch mode {
        case .all: PushTagMode.all
        case .currentBranch: PushTagMode.follow
        }
    }
    Task.detached(priority: .userInitiated) {
        let initialViewCommitRanges: [PersistedLogRevisionRange] = {
            guard viewCommitRanges.isEmpty,
                  refspec == nil,
                  branch == currentBranchForPush,
                  let rootPath = repo.workdir() else {
                return viewCommitRanges
            }
            return Self.multiRootPushRevisionRanges(for: [rootPath], remote: remote)
        }()
        do {
            if let refspec, !refspec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if engineTagMode != nil || skipHooks {
                    try repo.pushRefspecWithOptionsAndAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: force,
                        forceWithLease: useForceWithLease,
                        tagMode: engineTagMode,
                        skipHooks: skipHooks,
                        broker: broker,
                        cancel: cancel
                    )
                } else {
                    try repo.pushRefspecWithAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: force,
                        forceWithLease: useForceWithLease,
                        broker: broker,
                        cancel: cancel
                    )
                }
            } else {
                try repo.pushWithOptionsAndAuthAndCancel(
                    remote: remote,
                    branch: branch,
                    force: force,
                    forceWithLease: useForceWithLease,
                    setUpstream: publish,
                    tagMode: engineTagMode,
                    skipHooks: skipHooks,
                    broker: broker,
                    cancel: cancel
                )
            }
            let lfsCoverageWarning = lfsPushCoverageWarning(repo: repo, skipHooks: skipHooks)
            await MainActor.run {
                self.mergeFeedback = "push 完成"
                self.feedbackCenter.success(
                    "Push completed",
                    detail: "\(remote)/\(branch)",
                    additionalActions: self.multiRootUpdateViewCommitsAction(
                        ranges: initialViewCommitRanges
                    ).map { [$0] } ?? [],
                    notificationID: notificationID
                )
                if let lfsCoverageWarning {
                    self.feedbackCenter.warning(
                        "Git LFS objects were not uploaded",
                        detail: lfsCoverageWarning,
                        nextStep: "在 Git LFS 面板安装 hooks，或手动执行 Push LFS objects。"
                    )
                }
                self.autoOpenUpdateInfoIfEnabled(initialViewCommitRanges)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.mergeFeedback = detail
                if let stale = stalePushRejectionDetails(error) {
                    if let rootPath {
                        let actions = self.directPushRetryActions(
                            rootPath: rootPath,
                            remote: stale.remote,
                            branch: stale.branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: publish,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            viewCommitRanges: initialViewCommitRanges,
                            includeForce: true
                        ) + (self.multiRootUpdateViewCommitsAction(
                            ranges: initialViewCommitRanges
                        ).map { [$0] } ?? []) + [
                            self.showOperationDetailsAction(notificationID: notificationID)
                        ]
                        self.feedbackCenter.warning(
                            afterCommit
                                ? "Commit completed; Push rejected by force-with-lease"
                                : "Push rejected by force-with-lease",
                            detail: "\(stale.remote)/\(stale.branch): \(stale.message)",
                            nextStep: "The remote branch changed after the lease was recorded. Verify the remote history before overwriting it.",
                            additionalActions: actions,
                            notificationID: notificationID,
                            notificationGroup: .important,
                            localized: false
                        )
                    } else {
                        self.feedbackCenter.warning(
                            afterCommit
                                ? "Commit completed; Push rejected by force-with-lease"
                                : "Push rejected by force-with-lease",
                            detail: "\(stale.remote)/\(stale.branch): \(stale.message)",
                            nextStep: "The remote branch changed after the lease was recorded. Verify the remote history before overwriting it.",
                            actionTitle: "Force Push Anyway",
                            action: {
                                self.doPush(
                                    stale.remote,
                                    branch: stale.branch,
                                    force: true,
                                    forceWithLease: false,
                                    setUpstream: publish,
                                    refspec: refspec,
                                    tagMode: tagMode,
                                    skipHooks: skipHooks,
                                    viewCommitRanges: initialViewCommitRanges
                                )
                            },
                            notificationID: notificationID,
                            localized: false
                        )
                    }
                } else {
                    let autoUpdate = gitPushAutoUpdateIsEligible(
                        enabled: GitPushAutoUpdateSettings.value(for: self.projectPath),
                        force: force,
                        refspec: refspec,
                        currentBranch: currentBranchForPush,
                        rejectedBranch: branch,
                        hasTracking: self.currentSyncStatus?.trackingExists == true
                    )
                    if autoUpdate, let rootPath {
                        self.updateRootForPushRecovery(
                            rootPath: rootPath,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: publish,
                            refspec: nil,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            rebase: GitUpdateMethodSettings.method(for: self.projectPath) == .rebase,
                            viewCommitRanges: initialViewCommitRanges
                        )
                    } else {
                        let retryActions: [FeedbackAction] = rootPath.map { path in
                            self.directPushRetryActions(
                                rootPath: path,
                                remote: remote,
                                branch: branch,
                                force: force,
                                forceWithLease: useForceWithLease,
                                setUpstream: publish,
                                refspec: refspec,
                                tagMode: tagMode,
                                skipHooks: skipHooks,
                                viewCommitRanges: initialViewCommitRanges,
                                includeForce: false
                            )
                        } ?? []
                        let detailAction = self.showOperationDetailsAction(notificationID: notificationID)
                        self.feedbackCenter.error(
                            "Push failed",
                            detail: detail,
                            nextStep: "Check the remote, upstream, and credentials, then retry.",
                            additionalActions: retryActions + [detailAction],
                            notificationID: notificationID,
                            notificationGroup: .important
                        )
                        self.offerPushRecovery(
                            error,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: publish,
                            refspec: refspec,
                            tagMode: tagMode,
                            afterCommit: afterCommit,
                            viewCommitRanges: initialViewCommitRanges
                        )
                    }
                }
                if self.isAuthenticationFailure(error) { self.showHostingAuthPrompt = true }
            }
        }
    }
}

/// Rebased 的 rejected push 引导：只对 non-fast-forward 提供 Merge/Rebase，
/// 不把 force push 当成修复建议；Publish Branch 则由 Push 对话框的 upstream 开关完成。
func offerPushRecovery(
    _ error: Error,
    remote: String?,
    branch: String?,
    force: Bool,
    forceWithLease: Bool = false,
    setUpstream: Bool,
    refspec: String? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool = false,
    afterCommit: Bool = false,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    // A detached/custom source cannot be repaired by pulling the checked-out
    // branch and retrying it. The caller must rebuild that source against the
    // newly fetched remote tip instead of silently pushing the wrong ref.
    guard refspec == nil else { return }
    guard case let .PushRejected(kind, remote, branch, _) = error as? EngineError,
          kind == .nonFastForward else { return }
    // Match GitPushOperation.pushingToNotTrackedBranch and
    // pushingNotCurrentBranch: updating the checked-out branch is only a
    // valid repair when the rejected push came from that branch's tracked
    // upstream. A custom/non-current push must remain a plain rejection.
    guard currentBranchName == branch,
          currentSyncStatus?.trackingExists == true else { return }
    guard let rootPath = repo?.workdir() else { return }
    let recovery = PersistedPushRecovery(
        remote: remote,
        branch: branch,
        force: force,
        forceWithLease: forceWithLease,
        setUpstream: setUpstream,
        tagModeRaw: tagMode?.rawValue,
        skipHooks: skipHooks,
        rebase: false
    )
    let mergeRequest = singleRootPushRecoveryRequest(
        rootPath: rootPath,
        recovery: recovery,
        viewCommitRanges: viewCommitRanges
    )
    let rebaseRequest = singleRootPushRecoveryRequest(
        rootPath: rootPath,
        recovery: PersistedPushRecovery(
            remote: recovery.remote,
            branch: recovery.branch,
            force: recovery.force,
            forceWithLease: recovery.forceWithLease,
            setUpstream: recovery.setUpstream,
            tagModeRaw: recovery.tagModeRaw,
            skipHooks: recovery.skipHooks,
            rebase: true
        ),
        viewCommitRanges: viewCommitRanges
    )
    let notificationID = pushNotificationID(rootPath: rootPath)
    let recoveryActions = [
        FeedbackAction(title: "Update with Merge", semanticAction: mergeRequest) {
            self.handleVCSActionRequest(mergeRequest)
        },
        FeedbackAction(title: "Update with Rebase", semanticAction: rebaseRequest) {
            self.handleVCSActionRequest(rebaseRequest)
        }
    ] + self.directPushRetryActions(
        rootPath: rootPath,
        remote: remote,
        branch: branch,
        force: force,
        forceWithLease: forceWithLease,
        setUpstream: setUpstream,
        refspec: refspec,
        tagMode: tagMode,
        skipHooks: skipHooks,
        viewCommitRanges: viewCommitRanges,
        includeForce: false
    ) + (self.multiRootUpdateViewCommitsAction(ranges: viewCommitRanges).map { [$0] } ?? [])
        + [self.showOperationDetailsAction(notificationID: notificationID)]
    feedbackCenter.warning(
        afterCommit ? "Commit completed; Push rejected" : "Push rejected",
        detail: "Remote branch \(remote)/\(branch) has commits that are not local.",
        nextStep: "Update the checked-out branch, then retry Push.",
        additionalActions: recoveryActions,
        notificationID: notificationID,
        notificationGroup: .important
    )
}

}


/// push 完成后确认 LFS 对象这次是否真的会上传：
/// - 装了 pre-push hook 时 `git-lfs` 自己会上传，不必提示；
/// - 仓库有 LFS 跟踪规则但没有 hook（或本次显式跳过 hooks）时，代码推上去了、
///   对象却没上传，后续 clone 会拿到 pointer，必须明确告警。
func lfsPushCoverageWarning(repo: Repository, skipHooks: Bool) -> String? {
    guard repo.lfsCapability().installed else { return nil }
    let patterns = (try? repo.lfsTrackedPatterns()) ?? []
    guard !patterns.isEmpty else { return nil }
    if skipHooks {
        return "本次 Push 跳过了 Git hooks，Git LFS 对象不会随代码一起上传。"
    }
    guard !repo.lfsHookState().prePush else { return nil }
    return "该仓库没有安装 Git LFS 的 pre-push hook，本次 Push 只上传了代码引用，LFS 对象没有上传。"
}


/// 多 root Push 的 LFS 覆盖检查：逐个成功 root 判断 LFS 对象是否随代码上传。
/// 在后台线程调用（会打开每个 root 的 Repository）。
func lfsPushCoverageWarnings(results: [RootOperationResult], skipHooks: Bool) -> [String] {
    var warnings: [String] = []
    for result in results where result.success && !result.skipped {
        guard let rootRepo = try? openRepository(path: result.rootPath),
              let warning = lfsPushCoverageWarning(repo: rootRepo, skipHooks: skipHooks)
        else { continue }
        let displayName = result.displayName.isEmpty ? result.rootPath : result.displayName
        warnings.append("\(displayName)：\(warning)")
    }
    return warnings
}

extension ContentView {
    /// 把 LFS 覆盖告警合成为一条通知，避免每个 root 刷一遍。
    func publishLfsPushWarnings(_ warnings: [String]) {
        guard !warnings.isEmpty else { return }
        feedbackCenter.warning(
            "Git LFS objects were not uploaded",
            detail: warnings.joined(separator: "\n"),
            nextStep: "在 Git LFS 面板安装 hooks，或手动执行 Push LFS objects。"
        )
    }
}
