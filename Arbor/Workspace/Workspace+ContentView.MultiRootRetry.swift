import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func multiRootUpdateNotificationID(partial: Bool) -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return partial
        ? "git.project.partially.updated.\(stableProject)"
        : "git.project.updated.\(stableProject)"
}

func multiRootUpdateErrorNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "git.project.update.error.\(stableProject)"
}

func multiRootUpdateRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "git.project.update.rollback.\(stableProject)"
}

/// Retry only roots that failed in the last Update Project run. Successful
/// roots stay untouched; the engine adds the submodule dependency closure
/// (parent chain plus nested submodule descendants) when needed.
func retryMultiRootUpdateFailedRoots(
    rootPaths: [String]? = nil,
    rebase: Bool? = nil,
    rebaseRootPaths: [String]? = nil,
    priorRevisionRanges: [PersistedLogRevisionRange] = []
) {
    guard let projectPath = projectWorkspace.path else { return }
    let selectedRootPaths = rootPaths ?? multiRootWorkspace.results
        .filter { !$0.success }
        .map(\.rootPath)
    guard !selectedRootPaths.isEmpty else {
        feedbackCenter.warning("Retry unavailable", detail: "There are no failed Git roots to retry.")
        return
    }
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let cancel = GitCancelHandle()
    let rebase = rebase ?? multiRootWorkspace.updateRebase
    let rebaseRootPaths = rebaseRootPaths
        ?? multiRootWorkspace.updateRebaseRootPaths.map(Array.init)
    multiRootWorkspace.running = true
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation(
        rebase ? "Retry Update Project (rebase)" : "Retry Update Project",
        cancelHandle: cancel,
        notificationID: multiRootUpdateNotificationID(partial: false)
    )
    Task.detached(priority: .userInitiated) {
        do {
            let observedRoots = (try? discoverGitRoots(
                scanRoot: projectPath,
                maxDepth: nil
            )) ?? []
            let observedRootPaths = observedRoots.isEmpty ? selectedRootPaths : observedRoots.map(\.path)
            let submoduleRootPaths = Set(observedRoots.filter(\.isSubmodule).map(\.path))
            let previousHeads = Self.headCommitIDs(for: observedRootPaths)
            let previousHeadBranches = Self.headBranchNames(for: observedRootPaths)
            let retryResults = try runMultiRootUpdateSelectedWithMethodsAndOptions(
                scanRoot: projectPath,
                selectedRootPaths: selectedRootPaths,
                rebase: rebase,
                rebaseRootPaths: rebaseRootPaths,
                prefetchedRootPaths: nil,
                broker: broker,
                cancel: cancel,
                tagMode: tagMode,
                savePolicy: projectSavePolicy
            )
            let currentHeads = Self.headCommitIDs(for: observedRootPaths)
            let revisionRanges = Self.updateSessionRevisionRanges(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: retryResults
            )
            let combinedRevisionRanges = Self.joinedRevisionRanges(
                existing: priorRevisionRanges,
                latest: revisionRanges
            )
            let updatedFilesCount = Self.updateSessionUpdatedFilesCount(combinedRevisionRanges)
            let rollbackTargets = Self.updateSessionRollbackTargets(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: retryResults,
                submoduleRootPaths: Array(submoduleRootPaths),
                previousHeadBranches: previousHeadBranches
            )
            let recoveryTargets = Self.updateRootRecoveryTargets(
                results: retryResults,
                roots: observedRoots.map {
                    UpdateRootRecoveryRoot(
                        path: $0.path,
                        displayName: $0.displayName,
                        isSubmodule: $0.isSubmodule,
                        headBranch: $0.headBranch
                    )
                }
            )
            await MainActor.run {
                var mergedResults = self.multiRootWorkspace.results
                for retryResult in retryResults {
                    if let index = mergedResults.firstIndex(where: { $0.rootPath == retryResult.rootPath }) {
                        mergedResults[index] = retryResult
                    } else {
                        mergedResults.append(retryResult)
                    }
                }
                self.multiRootWorkspace.results = mergedResults
                self.multiRootWorkspace.running = false
                for result in retryResults {
                    if result.success || result.skipped {
                        self.stashRecovery.multiRootUpdateStashedRoots.remove(result.rootPath)
                    } else if result.message.localizedCaseInsensitiveContains("local changes remain in stash")
                                || result.message.localizedCaseInsensitiveContains("local changes remain in shelf")
                                || result.message.localizedCaseInsensitiveContains("local restore conflicted") {
                        self.stashRecovery.multiRootUpdateStashedRoots.insert(result.rootPath)
                    }
                }
                self.loadMultiRoots()
                let failures = retryResults.filter { !$0.success }
                let cancelled = retryResults.contains {
                    $0.message.localizedCaseInsensitiveContains("cancelled")
                }
                if failures.isEmpty && !cancelled {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: combinedRevisionRanges
                    )
                    let recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    self.feedbackCenter.success(
                        rebase ? "Retry Update Project completed (rebase)" : "Retry Update Project completed",
                        detail: Self.multiRootUpdateSuccessDetail(
                            retryResults,
                            updatedFilesCount: combinedRevisionRanges.isEmpty ? nil : updatedFilesCount
                        ),
                        additionalActions: (viewCommitsAction.map { [$0] } ?? []) + recoveryActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: false),
                        notificationGroup: .standard
                    )
                    self.autoOpenUpdateInfoIfEnabled(combinedRevisionRanges)
                } else {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    var details = Self.multiRootUpdateFailureDetails(
                        retryResults,
                        submoduleRootPaths: submoduleRootPaths
                    )
                    if !combinedRevisionRanges.isEmpty {
                        details.insert(
                            Self.multiRootUpdateSuccessDetail(
                                retryResults,
                                updatedFilesCount: updatedFilesCount
                            ),
                            at: 0
                        )
                    }
                    var additionalActions = [FeedbackAction]()
                    if !failures.isEmpty {
                        let retryPaths = failures.map(\.rootPath)
                        let retryRequest = makeMultiRootRetryRequest(
                            operation: .update,
                            rootPaths: retryPaths,
                            rebase: rebase,
                            rebaseRootPaths: self.multiRootWorkspace.updateRebaseRootPaths.map(Array.init)
                        )
                        additionalActions.append(
                            FeedbackAction(
                                title: "Retry Failed Update Roots",
                                semanticAction: retryRequest
                            ) {
                                self.handleVCSActionRequest(retryRequest)
                            }
                        )
                    }
                    if let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: combinedRevisionRanges
                    ) {
                        additionalActions.insert(viewCommitsAction, at: 0)
                    }
                    additionalActions.append(contentsOf: self.updateRootRecoveryActions(recoveryTargets))
                    if let rollbackAction = self.multiRootUpdateRollbackAction(
                        targets: rollbackTargets
                    ) {
                        additionalActions.append(rollbackAction)
                    }
                    self.feedbackCenter.warning(
                        rebase ? "Retry Update Project partially completed (rebase)" : "Retry Update Project partially completed",
                        detail: details.joined(separator: "\n"),
                        nextStep: "Resolve the affected roots, then retry only the remaining failures.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            NotificationCenter.default.post(
                                name: .arborOpenMultiRootConflictResolver,
                                object: nil
                            )
                        },
                        additionalActions: additionalActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: true),
                        notificationGroup: .standard
                    )
                    self.autoOpenUpdateInfoIfEnabled(combinedRevisionRanges)
                    self.presentMultiRootUpdateRestoreConflicts(retryResults)
                    self.recoverMultiRootUpdateStashesAfterFailure(retryResults)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                self.feedbackCenter.error(
                    "Retry Update Project failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry after resolving their current state.",
                    notificationID: self.multiRootUpdateErrorNotificationID()
                )
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
            }
        }
    }
}

func makeMultiRootRetryRequest(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    rootPaths: [String],
    changePath: String? = nil,
    changePaths: [PersistedMultiRootChangePath]? = nil,
    updateRootPaths: [String]? = nil,
    rebase: Bool? = nil,
    rebaseRootPaths: [String]? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool? = nil,
    force: Bool? = nil,
    forceWithLease: Bool? = nil,
    commitRetry: PersistedMultiRootCommitRetry? = nil,
    logRevisionRanges: [PersistedLogRevisionRange]? = nil,
    priorResultRows: [FeedbackResultRow]? = nil
) -> ArborVCSActionRequest {
    let persistedTagMode = tagMode.map { mode -> ArborVCSActionRequest.MultiRootPushTagMode in
        switch mode {
        case .all: .all
        case .currentBranch: .currentBranch
        }
    }
    return ArborVCSActionRequest(
        kind: .retryMultiRootOperation,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootRetryOperation: operation,
        multiRootRetryRootPaths: rootPaths,
        multiRootRetryPath: changePath,
        multiRootRetryChangePaths: changePaths,
        multiRootRetryUpdateRootPaths: updateRootPaths,
        multiRootRetryRebase: rebase,
        multiRootRetryRebaseRootPaths: rebaseRootPaths,
        multiRootRetryLogRevisionRanges: logRevisionRanges,
        multiRootRetryResultRows: priorResultRows,
        multiRootPushTagMode: persistedTagMode,
        multiRootPushSkipHooks: skipHooks,
        multiRootPushForce: force,
        multiRootPushForceWithLease: forceWithLease,
        multiRootCommitRetry: commitRetry
    )
}

func multiRootChangesRetryFeedbackAction(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    rootPath: String,
    path: String?
) -> FeedbackAction {
    let request = makeMultiRootRetryRequest(
        operation: operation,
        rootPaths: [rootPath],
        changePath: path
    )
    let title: String = switch operation {
    case .stage: "Retry Stage"
    case .unstage: "Retry Unstage"
    case .stageAll: "Retry Stage All"
    case .unstageAll: "Retry Unstage All"
    default: "Retry Changes"
    }
    let identity = [operation.rawValue, rootPath, path ?? "all"]
        .joined(separator: "|")
    return FeedbackAction(
        id: "retry-multi-root-changes:\(identity)",
        title: title,
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

func multiRootChangesBatchRetryFeedbackAction(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    changePaths: [PersistedMultiRootChangePath]
) -> FeedbackAction {
    let normalizedPaths = normalizedMultiRootChangePaths(changePaths)
    let rootPaths = Array(Set(normalizedPaths.map(\.rootPath))).sorted()
    let request = makeMultiRootRetryRequest(
        operation: operation,
        rootPaths: rootPaths,
        changePaths: normalizedPaths
    )
    let title: String = switch operation {
    case .stage: "Retry Selected Stage"
    case .unstage: "Retry Selected Unstage"
    default: "Retry Selected Changes"
    }
    let identity = normalizedPaths
        .map { "\($0.rootPath)\u{1f}\($0.path)" }
        .joined(separator: "|")
    return FeedbackAction(
        id: "retry-multi-root-changes-batch:\(operation.rawValue):\(identity)",
        title: title,
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

func multiRootChangesMutationNotificationID(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    rootPath: String,
    path: String?
) -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableComponent: (String) -> String = { value in
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
    }
    return [
        "arbor.multi-root-changes",
        operation.rawValue,
        stableComponent(URL(fileURLWithPath: projectPath).standardizedFileURL.path),
        stableComponent(rootPath),
        stableComponent(path ?? "all")
    ].joined(separator: ".")
}

func multiRootChangesBatchMutationNotificationID(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    changePaths: [PersistedMultiRootChangePath]
) -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableComponent: (String) -> String = { value in
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "\u{1f}", with: "_")
    }
    let identity = normalizedMultiRootChangePaths(changePaths)
        .map { "\(stableComponent($0.rootPath))_\(stableComponent($0.path))" }
        .joined(separator: "_")
    return [
        "arbor.multi-root-changes.batch",
        operation.rawValue,
        stableComponent(URL(fileURLWithPath: projectPath).standardizedFileURL.path),
        identity
    ].joined(separator: ".")
}

func multiRootRetryNotificationID(
    _ operation: ArborVCSActionRequest.MultiRootRetryOperation
) -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-retry.\(operation.rawValue).\(stableProject)"
}

}
