import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func recoverMultiRootPushRoots(
    _ rootPaths: [String],
    rebase: Bool,
    updateRootPaths: [String]? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool = false,
    priorViewCommitRanges: [PersistedLogRevisionRange] = [],
    priorResultRows: [FeedbackResultRow] = []
) {
    guard !rootPaths.isEmpty, !multiRootWorkspace.running, let projectPath = projectWorkspace.path else { return }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootWorkspace.running = true
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
        self.pushWorkspace.multiRootPushRetryContext = retryPaths.isEmpty
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
            self.operationRecovery.viewMode = .roots
            self.projectWorkspace.toolWindowMode = .operations
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
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
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
        self.multiRootWorkspace.running = false
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
                self.hostingWorkspace.showHostingAuthPrompt = true
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
    guard !multiRootWorkspace.running else { return }
    let context = pushWorkspace.multiRootPushRetryContext
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

}
