import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Project-level Push uses the same root result workbench as the other
/// aggregate operations, but needs the credential broker, cancellation and
/// submodule dependency guard supplied by the dedicated engine API.
func executeMultiRootPush(
    selectedRootPaths: [String]? = nil,
    fromCommit: Bool = false
) {
    pushWorkspace.multiRootPushOptionsRootPaths = selectedRootPaths
    pushWorkspace.multiRootPushOptionsFromCommit = fromCommit
    pushWorkspace.showMultiRootPushOptions = true
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
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    pushWorkspace.multiRootPushRetryContext = nil
    guard let projectPath = projectWorkspace.path else { return }
    let observedRootPaths: [String]
    if let selectedRootPaths {
        observedRootPaths = selectedRootPaths
    } else {
        // The Push All dialog is populated from this snapshot already. Do
        // not synchronously rescan a large project on the main actor just to
        // enrich the eventual notification; an empty snapshot only loses the
        // optional View Commits action, never the push itself.
        observedRootPaths = multiRootWorkspace.roots.map(\.path)
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
    multiRootWorkspace.running = true
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
                self.multiRootWorkspace.running = false
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
                    self.hostingWorkspace.showHostingAuthPrompt = true
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
        let preservedEngineResults = self.multiRootWorkspace.results.isEmpty
            ? rootOperationResults(from: priorResultRows)
            : self.multiRootWorkspace.results
        self.multiRootWorkspace.results = mergeRootOperationResults(
            preserved: preservedEngineResults,
            retry: results,
            rootOrder: priorResultRows.map(\.rootPath)
        )
    } else {
        self.multiRootWorkspace.results = results
    }
    self.multiRootWorkspace.running = false
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
    self.pushWorkspace.multiRootPushRetryContext = retryPaths.isEmpty
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
        && GitPushAutoUpdateSettings.value(for: self.projectWorkspace.path)
    if shouldAutoUpdate {
        self.recoverMultiRootPushRoots(
            nonFastForwardPaths,
            rebase: GitUpdateMethodSettings.method(for: self.projectWorkspace.path) == .rebase,
            updateRootPaths: self.multiRootWorkspace.roots.map(\.path),
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
        self.operationRecovery.viewMode = .roots
        self.projectWorkspace.toolWindowMode = .operations
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
            let updateRootPaths = self.multiRootWorkspace.roots.map(\.path)
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
                self.operationRecovery.viewMode = .roots
                self.projectWorkspace.toolWindowMode = .operations
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

/// 多 root Branches Popup 的 Push 对话框必须先读取目标 root 的数据，不能
/// 复用当前窗口绑定的 remote、branch 或 log 列表。
func beginMultiRootPushDialog(rootPath: String, branch: String) {
    beginFeedbackOperation("Load Push dialog")
    let defaultPushTagMode = GitPushTagSettings.projectTagMode(for: projectWorkspace.path)
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
            let configuredTarget = branchWorkspace.syncStatuses
                .first(where: { $0.branch == selectedBranch && $0.trackingExists })
                .flatMap {
                    remoteBranchTargetForConfiguredUpstream($0.upstream, remotes: remotes)
                }
            await MainActor.run {
                self.pushWorkspace.multiRootPushContext = MultiRootPushContext(
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

}
