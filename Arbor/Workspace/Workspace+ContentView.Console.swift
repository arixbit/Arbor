import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func rewordUndoNotificationID(
    rootPath: String,
    expectedHeadID: String
) -> String {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.reword-undo.\(normalizedRoot).\(expectedHeadID)"
}

func rewordUndoFeedbackAction(
    rootPath: String,
    context: PersistedRewordUndo
) -> FeedbackAction {
    let request = rewordUndoRequest(rootPath: rootPath, context: context)
    return FeedbackAction(
        id: "undo-reword:\(rootPath):\(context.expectedHeadID)",
        title: "Undo Reword Commit",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

/// Keep signing recovery on the same durable VCS notification as the failed
/// commit. The action is safe to replay after relaunch because it only opens
/// the settings surface; it never mutates Git state by itself.
func gpgAgentSettingsFeedbackAction() -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .openGpgAgentSettings,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: ""
    )
    return FeedbackAction(
        id: "open-gpg-agent-settings",
        title: "Configure GPG Agent…",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func beginFeedbackOperation(
    _ name: String,
    cancelHandle: GitCancelHandle? = nil,
    notificationID: String? = nil,
    preserveResultItems: Bool = false
) {
    feedbackCenter.begin(
        name,
        notificationID: notificationID,
        preserveResultItems: preserveResultItems,
        onCancel: cancelHandle.map { handle in
            { handle.cancel() }
        }
    )
}

/// Present the full IntelliJ-style Smart/Force/Cancel decision instead of
/// reducing an overwrite detector to a one-line retry toast.
func presentSmartOperationDecision(
    operationTitle: String,
    paths: [String],
    detail: String? = nil,
    smartButtonTitle: String,
    forceButtonTitle: String? = nil,
    onSmart: @escaping () -> Void,
    onForce: (() -> Void)? = nil
) {
    smartOperationRequest = SmartOperationRequest(
        operationTitle: operationTitle,
        smartButtonTitle: smartButtonTitle,
        forceButtonTitle: forceButtonTitle,
        paths: paths,
        detail: detail,
        localChangesSavePolicy: GitLocalChangesSavePolicySettings.choice(for: projectPath),
        onSmart: onSmart,
        onForce: onForce
    )
}

func runGitConsole(command: String, args: [String]) {
    guard let repo else { return }
    beginFeedbackOperation("Git Console")
    Task.detached(priority: .userInitiated) {
        do {
            let result = try repo.runGitCommand(command: command, args: args)
            await MainActor.run {
                self.consoleResult = result
                self.feedbackCenter.recordGitCommand(result)
                if result.exitCode == 0 {
                    self.feedbackCenter.success("Git command completed", detail: result.command)
                } else {
                    self.feedbackCenter.error(
                        "Git command failed",
                        detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                        nextStep: "Review stderr in Git Console and retry after fixing the command."
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Git Console failed", detail: errorMessage(error))
            }
        }
    }
}

/// 在当前窗口加载单个项目，并丢弃上一项目的所有选择和缓存。
func expireOperationRecoveryNotifications() {
    for rootPath in operationRecoveryNotificationFingerprints.keys {
        feedbackCenter.expire(
            notificationID: operationRecoveryNotificationID(rootPath: rootPath)
        )
    }
    operationRecoveryNotificationFingerprints.removeAll()
}

func runMultiRootResetOperation(
    projectPath: String,
    selectedRootPaths: [String],
    commitID: String? = nil,
    targetSpecs: [MultiRootResetTarget]? = nil,
    mode: ResetMode,
    smart: Bool,
    force: Bool,
    rootOrder: [String]? = nil,
    preservedResults: [RootOperationResult] = []
) {
    let operationRootPaths = selectedRootPaths
    let resultRootOrder = rootOrder ?? (
        operationRootPaths + preservedResults
            .map(\.rootPath)
            .filter { !operationRootPaths.contains($0) }
    )
    multiRootRunning = true
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Multi-root reset")
    Task.detached(priority: .userInitiated) {
        do {
            let results: [MultiRootResetResult]
            if let targetSpecs {
                results = try runMultiRootResetWithTargets(
                    scanRoot: projectPath,
                    targets: targetSpecs,
                    mode: mode,
                    savePolicy: projectSavePolicy,
                    smart: smart,
                    force: force
                )
            } else if let commitID {
                results = try runMultiRootResetWithPolicy(
                    scanRoot: projectPath,
                    selectedRootPaths: operationRootPaths,
                    commitId: commitID,
                    mode: mode,
                    savePolicy: projectSavePolicy,
                    smart: smart,
                    force: force
                )
            } else {
                throw NSError(
                    domain: "Arbor.Reset",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reset target is missing"]
                )
            }
            let operationResults = results.map { result in
                RootOperationResult(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    success: result.success,
                    skipped: result.skipped,
                    message: result.message
                )
            }
            let combinedOperationResults = mergeRootOperationResults(
                preserved: preservedResults,
                retry: operationResults,
                rootOrder: resultRootOrder
            )
            let overwriteFailures = results.filter {
                !$0.success && !$0.skipped && !$0.localChangesOverwritePaths.isEmpty
            }
            let failures = combinedOperationResults.filter { !$0.success || $0.skipped }
            let resetRecoveryTargets: [PersistedResetRecoveryTarget] = results.compactMap { result in
                guard result.success,
                      !result.skipped,
                      let initialHead = result.initialHead,
                      let expectedHead = result.finalHead,
                      let rollbackID = result.rollbackId else { return nil }
                return PersistedResetRecoveryTarget(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    initialHead: initialHead,
                    expectedHead: expectedHead,
                    expectedHeadBranch: result.finalBranch,
                    mode: mode,
                    rollbackID: rollbackID
                )
            }
            await MainActor.run {
                self.multiRootRunning = false
                self.multiRootResults = combinedOperationResults
                self.loadMultiRoots()
                if !overwriteFailures.isEmpty && !smart && !force {
                    let detail = overwriteFailures.map {
                        "\($0.displayName): \($0.localChangesOverwritePaths.joined(separator: ", "))"
                    }.joined(separator: "\n")
                    self.feedbackCenter.warning(
                        "Multi-root Reset needs a decision",
                        detail: detail,
                        nextStep: "Choose Smart Reset to preserve local changes in blocked roots, or cancel."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Multi-root Reset",
                        paths: overwriteFailures.flatMap { result in
                            result.localChangesOverwritePaths.map { "\(result.displayName): \($0)" }
                        },
                        detail: detail,
                        smartButtonTitle: "Smart Reset",
                        forceButtonTitle: mode == .hard ? "Force Reset" : nil,
                        onSmart: {
                            self.runMultiRootResetOperation(
                                projectPath: projectPath,
                                selectedRootPaths: overwriteFailures.map(\.rootPath),
                                commitID: commitID,
                                targetSpecs: targetSpecs?.filter { target in
                                    overwriteFailures.contains(where: { $0.rootPath == target.rootPath })
                                },
                                mode: mode,
                                smart: true,
                                force: false,
                                rootOrder: resultRootOrder,
                                preservedResults: combinedOperationResults.filter { result in
                                    !overwriteFailures.contains(where: { $0.rootPath == result.rootPath })
                                }
                            )
                        },
                        onForce: mode == .hard ? {
                            self.runMultiRootResetOperation(
                                projectPath: projectPath,
                                selectedRootPaths: overwriteFailures.map(\.rootPath),
                                commitID: commitID,
                                targetSpecs: targetSpecs?.filter { target in
                                    overwriteFailures.contains(where: { $0.rootPath == target.rootPath })
                                },
                                mode: mode,
                                smart: false,
                                force: true,
                                rootOrder: resultRootOrder,
                                preservedResults: combinedOperationResults.filter { result in
                                    !overwriteFailures.contains(where: { $0.rootPath == result.rootPath })
                                }
                            )
                        } : nil
                    )
                } else if failures.isEmpty {
                    let targetDetail = targetSpecs == nil
                        ? "target \(String((commitID ?? "").prefix(7)))"
                        : "one target per repository"
                    self.feedbackCenter.success(
                        "Multi-root Reset completed",
                        detail: "\(results.count) repositories · \(self.resetModeName(mode)) · \(targetDetail)",
                        additionalActions: self.resetRecoveryActions(
                            targets: resetRecoveryTargets
                        ),
                        notificationID: self.multiRootResetNotificationID(),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Multi-root Reset partially completed",
                        detail: failures.map {
                            "\($0.displayName): \($0.message.isEmpty ? ($0.skipped ? "skipped" : "failed") : $0.message)"
                        }.joined(separator: "\n"),
                        nextStep: "Review the affected Git roots and resolve any saved local-change restore marker.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            self.openMultiRootConflictResolver(preferredRootPath: failures.first?.rootPath)
                        },
                        additionalActions: self.resetRecoveryActions(
                            targets: resetRecoveryTargets
                        ),
                        notificationID: self.multiRootResetNotificationID(),
                        notificationGroup: .standard
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootRunning = false
                self.feedbackCenter.error(
                    "Multi-root Reset failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and target revision, then retry."
                )
            }
        }
    }
}

func multiRootResetNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-reset.\(stableProject)"
}

func resetRecoveryNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.reset-recovery.\(stableProject)"
}

nonisolated func logSelectedChangesUndoNotificationID(
    repositoryPath: String,
    expectedHead: String
) -> String {
    let stablePath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.log-selected-changes-undo.\(stablePath).\(expectedHead)"
}

func logSelectedChangesUndoFeedbackAction(
    for target: LogSelectedChangesUndoTarget
) -> FeedbackAction {
    let request = logSelectedChangesUndoRequest(for: target)
    return FeedbackAction(
        id: "undo-log-selected-changes:\(target.repositoryPath):\(target.expectedHead)",
        title: "Undo Selected Changes",
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

/// REPO-001:对全部 root 执行聚合操作,展示逐 root 结果(部分成功/失败/跳过)。
/// When `rootPaths` is supplied, the operation is a root-scoped retry and must
/// not repeat roots that already completed successfully in the original run.
func executeMultiRootOperation(
    _ operation: MultiRootOperation,
    message: String? = nil,
    rootPaths: [String]? = nil,
    priorRevisionRanges: [PersistedLogRevisionRange] = []
) {
    if let rebase = multiRootPullRebaseMode(operation) {
        multiRootPushRetryContext = nil
        if let rootPaths {
            retryMultiRootUpdateFailedRoots(
                rootPaths: rootPaths,
                rebase: rebase,
                priorRevisionRanges: priorRevisionRanges
            )
        } else {
            executeMultiRootUpdate(rebase: rebase)
        }
        return
    }
    switch operation {
    case .push:
        executeMultiRootPush()
        return
    default:
        multiRootPushRetryContext = nil
    }
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    guard let projectPath else { return }
    multiRootRunning = true
    beginFeedbackOperation(
        multiRootOperationTitle(operation),
        notificationID: multiRootRetryOperation(for: operation)
            .flatMap { multiRootRetryNotificationID($0) }
    )
    Task.detached(priority: .userInitiated) {
        do {
            let results: [RootOperationResult]
            if let rootPaths {
                results = try runMultiRootOperationOnRoots(
                    scanRoot: projectPath,
                    selectedRootPaths: rootPaths,
                    operation: operation,
                    commitMessage: message
                )
            } else {
                results = try runMultiRootOperation(
                    scanRoot: projectPath,
                    operation: operation,
                    commitMessage: message
                )
            }
            await MainActor.run {
                self.finishGenericMultiRootOperation(
                    results,
                    operation: operation,
                    priorRevisionRanges: [],
                    revisionRanges: []
                )
            }
        } catch {
            await MainActor.run {
                self.multiRootRunning = false
                let retryPaths = rootPaths ?? self.multiRoots.map(\.path)
                let retryAction: FeedbackAction? = self.multiRootRetryOperation(for: operation).flatMap { retryOperation in
                    guard !retryPaths.isEmpty else { return nil }
                    let request = self.makeMultiRootRetryRequest(
                        operation: retryOperation,
                        rootPaths: retryPaths,
                        logRevisionRanges: []
                    )
                    let title: String = switch retryOperation {
                    case .fetch: "Retry Fetch Roots"
                    case .pullMerge: "Retry Pull Roots (Merge)"
                    case .pullRebase: "Retry Pull Roots (Rebase)"
                    default: "Retry Failed Roots"
                    }
                    return FeedbackAction(title: title, semanticAction: request) {
                        self.handleVCSActionRequest(request)
                    }
                }
                self.feedbackCenter.error(
                    "Multi-root operation failed",
                    detail: errorMessage(error),
                    nextStep: "检查仓库配置后重试。",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: self.multiRootRetryOperation(for: operation)
                        .flatMap { self.multiRootRetryNotificationID($0) }
                )
                // Fetch/Pull can fail before the engine has a chance to emit
                // per-root results. Preserve the same hosting-token recovery
                // path used by single-root and partial aggregate failures.
                if self.isAuthenticationFailure(error) {
                    self.showHostingAuthPrompt = true
                }
            }
        }
    }
}

func multiRootOperationTitle(_ operation: MultiRootOperation) -> String {
    switch operation {
    case .fetch: "Fetch All"
    case .pullMerge: "Pull All (Merge)"
    case .pullRebase: "Pull All (Rebase)"
    case .push: "Push All"
    case .commit: "Commit All"
    }
}

func multiRootRetryOperation(
    for operation: MultiRootOperation
) -> ArborVCSActionRequest.MultiRootRetryOperation? {
    switch operation {
    case .fetch: .fetch
    case .pullMerge: .pullMerge
    case .pullRebase: .pullRebase
    case .push, .commit: nil
    }
}

func multiRootRetryableRootPaths(
    from results: [RootOperationResult]
) -> [String] {
    results.compactMap { result in
        if !result.success {
            return result.rootPath
        }
        guard result.skipped,
              result.message.localizedCaseInsensitiveContains("cancel") else {
            return nil
        }
        return result.rootPath
    }
}

func finishGenericMultiRootOperation(
    _ results: [RootOperationResult],
    operation: MultiRootOperation,
    priorRevisionRanges: [PersistedLogRevisionRange] = [],
    revisionRanges: [PersistedLogRevisionRange] = []
) {
    multiRootResults = results
    multiRootRunning = false
    showHostingAuthPromptIfNeeded(for: results)

    let completed = results.filter { $0.success && !$0.skipped }.count
    let failed = results.filter { !$0.success }.count
    let skipped = results.filter { $0.skipped }.count
    let retryPaths = multiRootRetryableRootPaths(from: results)
    let retryOperation = multiRootRetryOperation(for: operation)
    let combinedRevisionRanges = operation == .pullMerge || operation == .pullRebase
        ? ContentView.joinedRevisionRanges(existing: priorRevisionRanges, latest: revisionRanges)
        : []
    var actions: [FeedbackAction] = []

    if let viewCommitsAction = multiRootUpdateViewCommitsAction(ranges: combinedRevisionRanges) {
        actions.append(viewCommitsAction)
    }

    if let retryOperation, !retryPaths.isEmpty {
        let request = makeMultiRootRetryRequest(
            operation: retryOperation,
            rootPaths: retryPaths,
            logRevisionRanges: combinedRevisionRanges
        )
        let title: String = switch retryOperation {
        case .fetch: "Retry Failed Fetch Roots"
        case .pullMerge: "Retry Failed Pull Roots (Merge)"
        case .pullRebase: "Retry Failed Pull Roots (Rebase)"
        default: "Retry Failed Roots"
        }
        actions.append(
            FeedbackAction(
                id: "retry-multi-root-\(retryOperation.rawValue):\(retryPaths.sorted().joined(separator: "|"))",
                title: title,
                semanticAction: request
            ) {
                handleVCSActionRequest(request)
            }
        )
    }

    let detail = results.map { result in
        let state = result.success
            ? (result.skipped ? "skipped" : "ok")
            : "failed"
        let message = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "\(result.displayName): \(state)"
            : "\(result.displayName): \(state) — \(message)"
    }.joined(separator: "\n")
    let notificationID = multiRootRetryOperation(for: operation)
        .flatMap { multiRootRetryNotificationID($0) }

    if failed == 0 && skipped == 0 {
        feedbackCenter.success(
            multiRootOperationTitle(operation) + " completed",
            detail: "\(completed) ok",
            additionalActions: actions,
            notificationID: notificationID,
            notificationGroup: .standard
        )
    } else {
        feedbackCenter.warning(
            multiRootOperationTitle(operation) + " partially completed",
            detail: "\(completed) ok · \(failed) failed · \(skipped) skipped\n\(detail)",
            nextStep: actions.isEmpty
                ? "Review the affected Git roots and resolve their configuration or operation state."
                : "Resolve the affected roots, then retry only the remaining roots.",
            additionalActions: actions,
            notificationID: notificationID,
            notificationGroup: failed == 0 ? .toolWindow : .important
        )
    }
    feedbackCenter.attachResultRows(
        feedbackResultRows(from: results),
        notificationID: notificationID
    )
    refreshAll(showFeedback: false)
}

func multiRootUpdateNotificationID(partial: Bool) -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return partial
        ? "git.project.partially.updated.\(stableProject)"
        : "git.project.updated.\(stableProject)"
}

func multiRootUpdateErrorNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "git.project.update.error.\(stableProject)"
}

func multiRootUpdateRollbackNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
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
    guard let projectPath else { return }
    let selectedRootPaths = rootPaths ?? multiRootResults
        .filter { !$0.success }
        .map(\.rootPath)
    guard !selectedRootPaths.isEmpty else {
        feedbackCenter.warning("Retry unavailable", detail: "There are no failed Git roots to retry.")
        return
    }
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let cancel = GitCancelHandle()
    let rebase = rebase ?? multiRootUpdateRebase
    let rebaseRootPaths = rebaseRootPaths
        ?? multiRootUpdateRebaseRootPaths.map(Array.init)
    multiRootRunning = true
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
                var mergedResults = self.multiRootResults
                for retryResult in retryResults {
                    if let index = mergedResults.firstIndex(where: { $0.rootPath == retryResult.rootPath }) {
                        mergedResults[index] = retryResult
                    } else {
                        mergedResults.append(retryResult)
                    }
                }
                self.multiRootResults = mergedResults
                self.multiRootRunning = false
                for result in retryResults {
                    if result.success || result.skipped {
                        self.multiRootUpdateStashedRoots.remove(result.rootPath)
                    } else if result.message.localizedCaseInsensitiveContains("local changes remain in stash")
                                || result.message.localizedCaseInsensitiveContains("local changes remain in shelf")
                                || result.message.localizedCaseInsensitiveContains("local restore conflicted") {
                        self.multiRootUpdateStashedRoots.insert(result.rootPath)
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
                    self.operationsViewMode = .roots
                    self.toolWindowMode = .operations
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
                            rebaseRootPaths: self.multiRootUpdateRebaseRootPaths.map(Array.init)
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
                self.multiRootRunning = false
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
                    self.showHostingAuthPrompt = true
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
        projectPath: projectPath,
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
    guard let projectPath, !projectPath.isEmpty else { return nil }
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
    guard let projectPath, !projectPath.isEmpty else { return nil }
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
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-retry.\(operation.rawValue).\(stableProject)"
}

func operationRecoveryKindTitle(_ kind: OperationKind) -> String {
    switch kind {
    case .merge: return "Merge"
    case .rebase: return "Rebase"
    case .cherryPick: return "Cherry-pick"
    case .revert: return "Revert"
    }
}

func operationRecoveryActionTitle(
    _ action: ArborVCSActionRequest.OperationRecoveryAction
) -> String {
    switch action {
    case .continueOperation: return "Continue"
    case .skip: return "Skip"
    case .abort: return "Abort"
    case .openRecovery: return "Open Recovery"
    }
}

func operationRecoveryRequest(
    action: ArborVCSActionRequest.OperationRecoveryAction,
    projectPath: String?,
    rootPath: String
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .operationRecovery,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        operationRecoveryAction: action
    )
}

func operationRecoveryFeedbackAction(
    _ action: ArborVCSActionRequest.OperationRecoveryAction,
    projectPath: String?,
    rootPath: String
) -> FeedbackAction {
    let request = operationRecoveryRequest(
        action: action,
        projectPath: projectPath,
        rootPath: rootPath
    )
    return FeedbackAction(
        title: operationRecoveryActionTitle(action),
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func operationRecoveryFeedbackActions(
    state: OperationState,
    rootPath: String
) -> [FeedbackAction] {
    var actions = [
        operationRecoveryFeedbackAction(
            .continueOperation,
            projectPath: projectPath,
            rootPath: rootPath
        )
    ]
    if state.kind == .rebase {
        actions.append(
            operationRecoveryFeedbackAction(
                .skip,
                projectPath: projectPath,
                rootPath: rootPath
            )
        )
    }
    actions.append(
        operationRecoveryFeedbackAction(
            .abort,
            projectPath: projectPath,
            rootPath: rootPath
        )
    )
    actions.append(
        operationRecoveryFeedbackAction(
            .openRecovery,
            projectPath: projectPath,
            rootPath: rootPath
        )
    )
    return actions
}

func publishOperationRecoveryNotice(
    state: OperationState,
    rootPath: String
) -> Bool {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let hasDedicatedRebaseRecovery = state.kind == .rebase
        && (
            loadRebaseUndoSeed(repositoryPath: normalizedRoot) != nil
                || multiRootRebaseSession?.roots.contains(where: {
                    URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path == normalizedRoot
                }) == true
        )
    guard !hasDedicatedRebaseRecovery else { return false }
    let kindTitle = operationRecoveryKindTitle(state.kind)
    let detail: String
    if state.conflictedFiles.isEmpty {
        detail = "A \(kindTitle) operation is paused in this repository."
    } else {
        detail = "\(state.conflictedFiles.count) conflicted file(s) must be resolved before continuing."
    }
    feedbackCenter.warning(
        "\(kindTitle) recovery available",
        detail: detail,
        nextStep: "Continue, Skip, or Abort the operation from the recovery actions.",
        additionalActions: operationRecoveryFeedbackActions(
            state: state,
            rootPath: rootPath
        ),
        notificationID: operationRecoveryNotificationID(rootPath: rootPath),
        notificationGroup: .important,
        localized: false
    )
    return true
}

func publishOperationRecoveryNoticeIfNeeded(
    state: OperationState,
    rootPath: String
) {
    let key = operationRecoveryNotificationRootKey(rootPath)
    let fingerprint = operationRecoveryNotificationFingerprint(state)
    guard operationRecoveryNotificationFingerprints[key] != fingerprint else { return }
    if publishOperationRecoveryNotice(state: state, rootPath: rootPath) {
        operationRecoveryNotificationFingerprints[key] = fingerprint
    }
}

func openOperationRecovery(rootPath: String, preferredPath: String? = nil) {
    toolWindowMode = .commit
    toolWindowExpanded = true
    let currentRootMatches = repo?.workdir().map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
            == URL(fileURLWithPath: rootPath).standardizedFileURL.path
    } == true
    guard currentRootMatches else {
        openMultiRootConflictResolver(
            preferredRootPath: rootPath,
            preferredPath: preferredPath
        )
        return
    }
    if let preferredPath {
        mergeInitialPath = preferredPath
        selection = preferredPath
    } else if let conflictPath = operationState?.conflictedFiles.first {
        mergeInitialPath = conflictPath
        selection = conflictPath
    }
    if let state = operationState, !state.conflictedFiles.isEmpty {
        openMultiRootConflictResolver(
            preferredRootPath: rootPath,
            preferredPath: preferredPath ?? state.conflictedFiles.first
        )
    }
}

/// OPS-001 恢复动作：根据 operation_state() 的类别分派
/// continue/skip/abort（引擎层已按 origin 分派到引擎实现或系统 git）。
func doOperationContinue() {
    if stashPopConflictInProgress || stashApplyConflictInProgress {
        finishStashConflict()
        return
    }
    guard let repo, let state = operationState else { return }
    let rebaseRootPath = repo.workdir()
    let rebaseSessionID = state.kind == .rebase
        ? multiRootRebaseSession?.roots.contains(where: { $0.rootPath == rebaseRootPath }) == true
            ? multiRootRebaseSession?.id
            : nil
        : nil
    let sourceBranch = state.kind == .merge && state.origin == .engine
        ? (pendingMergeDeleteBranch ?? repo.mergeSourceReference())
        : nil
    let protectedPatterns = effectiveProtectedBranchPatterns
    let pendingPullStash = pendingPullStashPop
    let pendingPullStashIDValue = pendingPullStashID
    let pendingPullStashMessageValue = pendingPullStashMessage
    let pendingPullShelfNameValue = pendingPullShelfName
    let singleRootRebaseSeed = state.kind == .rebase && rebaseSessionID == nil
        ? rebaseUndoSeed
        : nil
    let completedLogApplyRecovery = rebaseRootPath.flatMap { rootPath -> PersistedLogApplyRecovery? in
        guard let recovery = loadLogApplyRecovery(repositoryPath: rootPath) else { return nil }
        switch state.kind {
        case .cherryPick:
            return recovery.operation == .cherryPick ? recovery : nil
        case .revert:
            return recovery.operation == .revert ? recovery : nil
        case .merge, .rebase:
            return nil
        }
    }
    let operationNotificationID = rebaseRootPath.map {
        operationRecoveryNotificationID(rootPath: $0)
    }
    beginFeedbackOperation(
        "Continue operation",
        notificationID: operationNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            switch state.kind {
            case .merge:
                _ = try state.origin == .engine
                    ? repo.finishMerge(message: nil)
                    : repo.mergeContinue(message: nil)
            case .rebase:
                _ = try repo.rebaseContinue()
            case .cherryPick:
                try repo.cherryPickContinueWithOptions(
                    emptyPolicy: configuredCherryPickEmptyPolicy()
                )
            case .revert:
                try repo.revertContinue()
            }
            let continuationState = try repo.operationState()
            let operationStillActive = continuationState != nil
            if !operationStillActive, let rootPath = rebaseRootPath {
                clearLogApplyRecovery(repositoryPath: rootPath)
            }
            let completedRebaseUndoTarget: RebaseUndoTarget?
            if !operationStillActive, let singleRootRebaseSeed {
                let finalHead = try? repo.revisionCommitId(revision: singleRootRebaseSeed.branch)
                let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
                completedRebaseUndoTarget = rebaseUndoTargetAfterCompletion(
                    seed: singleRootRebaseSeed,
                    currentBranch: currentBranch,
                    finalHead: finalHead
                )
            } else {
                completedRebaseUndoTarget = nil
            }
            var pullStashRestoreConflictPaths: [String]?
            var pullStashRestoreIndex: Int?
            var pullStashRestoreConflictID: String?
            var pullShelfRestoreConflictName: String?
            var pullShelfRestoreConflictPaths: [String]?
            var pullRestoreError: String?
            var pullRestoreStashID: String?
            var pullRestoreShelfName: String?
            var pullChangesRestored = false
            if !operationStillActive {
                if let pendingPullShelfNameValue {
                    pullRestoreShelfName = pendingPullShelfNameValue
                    do {
                        try repo.shelvePopPreservation(name: pendingPullShelfNameValue)
                        pullChangesRestored = true
                    } catch let error as EngineError {
                        if case let .ShelveApplyConflict(name, paths) = error {
                            pullShelfRestoreConflictName = name
                            pullShelfRestoreConflictPaths = paths
                        } else {
                            pullRestoreError = errorMessage(error)
                        }
                    } catch {
                        pullRestoreError = errorMessage(error)
                    }
                } else if pendingPullStash {
                    do {
                        let reference = try Self.pullStashReference(
                            repo: repo,
                            stashID: pendingPullStashIDValue,
                            message: pendingPullStashMessageValue
                        )
                        pullRestoreStashID = reference.stash.id
                        pullStashRestoreIndex = Int(reference.index)
                        try repo.stashPopWithIndex(
                            index: try currentStashIndex(repo: repo, stashID: reference.stash.id),
                            restoreIndex: true
                        )
                        pullChangesRestored = true
                    } catch let error as EngineError {
                        if case let .StashApplyConflict(paths, conflictID) = error {
                            pullStashRestoreConflictPaths = paths
                            pullStashRestoreConflictID = conflictID ?? pullRestoreStashID
                        } else {
                            pullRestoreError = errorMessage(error)
                        }
                    } catch {
                        pullRestoreError = errorMessage(error)
                    }
                }
            }
            let pullRestoreBlocked = pullStashRestoreConflictPaths != nil
                || pullShelfRestoreConflictPaths != nil
                || pullRestoreError != nil
            let canProposeDelete = (
                !operationStillActive && (sourceBranch.map {
                    canProposeDeleteMergedBranch(
                        repo: repo,
                        branch: $0,
                        protectedPatterns: protectedPatterns
                    )
                } ?? false)
            ) && !pullRestoreBlocked
            let pullStashRestoreConflictPathsValue = pullStashRestoreConflictPaths
            let pullStashRestoreIndexValue = pullStashRestoreIndex
            let pullStashRestoreConflictIDValue = pullStashRestoreConflictID
            let pullShelfRestoreConflictNameValue = pullShelfRestoreConflictName
            let pullShelfRestoreConflictPathsValue = pullShelfRestoreConflictPaths
            let pullRestoreErrorValue = pullRestoreError
            let pullRestoreStashIDValue = pullRestoreStashID
            let pullRestoreShelfNameValue = pullRestoreShelfName
            let pullChangesRestoredValue = pullChangesRestored
            await MainActor.run {
                self.operationFeedback = "已继续"
                if let pullStashRestoreConflictPathsValue {
                    self.showStashRestoreConflict(
                        pullStashRestoreConflictPathsValue,
                        operationName: "Pull",
                        notificationID: operationNotificationID,
                        stashID: pullStashRestoreConflictIDValue ?? pullRestoreStashIDValue
                    )
                    self.pendingStashPopIndex = pullStashRestoreIndexValue
                    self.pendingPullStashPop = false
                    self.pendingPullStashID = nil
                    self.pendingPullStashMessage = nil
                } else if let pullShelfRestoreConflictNameValue,
                          let pullShelfRestoreConflictPathsValue
                {
                    self.pendingPullShelfName = nil
                    self.presentShelveConflict(
                        name: pullShelfRestoreConflictNameValue,
                        paths: pullShelfRestoreConflictPathsValue,
                        isPop: true,
                        notificationID: operationNotificationID
                    )
                } else if pullChangesRestoredValue {
                    self.pendingPullStashPop = false
                    self.pendingPullStashID = nil
                    self.pendingPullStashMessage = nil
                    self.pendingPullShelfName = nil
                    if let rebaseRootPath {
                        clearPendingPullPreservation(repositoryPath: rebaseRootPath)
                    }
                }
                if let pullRestoreErrorValue {
                    let savedChangesAction: FeedbackAction? = {
                        if let pullRestoreShelfNameValue {
                            return self.savedChangesFeedbackAction(
                                kind: .shelf,
                                identifier: pullRestoreShelfNameValue
                            )
                        }
                        if let pullRestoreStashIDValue {
                            return self.savedChangesFeedbackAction(
                                kind: .stash,
                                identifier: pullRestoreStashIDValue
                            )
                        }
                        return nil
                    }()
                    self.feedbackCenter.error(
                        "Pull local changes restore failed",
                        detail: pullRestoreErrorValue,
                        nextStep: "View the saved changes, resolve the local issue, then retry the restore.",
                        additionalActions: savedChangesAction.map { [$0] } ?? [],
                        notificationID: operationNotificationID
                    )
                } else if pullRestoreBlocked {
                    self.feedbackCenter.warning(
                        "Pull local changes restore paused",
                        detail: "Resolve the restored local changes, then complete the restore.",
                        notificationID: operationNotificationID
                    )
                }
                if state.kind == .merge {
                    self.pendingMergeDeleteBranch = nil
                }
                if state.kind == .rebase, rebaseSessionID == nil {
                    if operationStillActive {
                        self.rebasePaused = true
                        self.rebasePauseReason = continuationState?.conflictedFiles.isEmpty == false
                            ? .conflict
                            : .edit
                        self.rebaseConflicts = continuationState?.conflictedFiles ?? []
                        self.rebaseUndoSeed = singleRootRebaseSeed
                        self.rebaseUndoTarget = nil
                        if let singleRootRebaseSeed {
                            saveRebaseUndoSeed(singleRootRebaseSeed)
                        }
                    } else if !pullRestoreBlocked {
                        self.rebasePaused = false
                        self.rebasePauseReason = nil
                        self.rebaseConflicts = []
                        self.rebaseUndoSeed = nil
                        self.rebaseUndoTarget = completedRebaseUndoTarget
                        if let singleRootRebaseSeed {
                            clearRebaseUndoSeed(repositoryPath: singleRootRebaseSeed.repositoryPath)
                        }
                    } else {
                        // The Git rebase has completed; only the saved local
                        // scene remains unresolved. Keep its seed for a
                        // later expected-HEAD Undo, but do not leave the
                        // operation bar pretending that Git is still paused.
                        self.rebasePaused = false
                        self.rebasePauseReason = nil
                        self.rebaseConflicts = []
                        self.rebaseUndoSeed = singleRootRebaseSeed
                        self.rebaseUndoTarget = nil
                        if let singleRootRebaseSeed {
                            saveRebaseUndoSeed(singleRootRebaseSeed)
                        }
                    }
                }
                self.refreshAll(showFeedback: false)
                if state.kind == .rebase,
                   let rebaseRootPath,
                   let rebaseSessionID,
                   !pullRestoreBlocked {
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rebaseRootPath,
                        action: .continueOperation,
                        operationStillActive: operationStillActive,
                        sessionID: rebaseSessionID
                    )
                    return
                }
                if canProposeDelete, let sourceBranch {
                    self.feedbackCenter.success(
                        "Merge completed",
                        detail: sourceBranch,
                        actionTitle: "Delete branch",
                        action: postMergeDeleteAction(repo: repo, branch: sourceBranch),
                        notificationID: operationNotificationID
                    )
                } else if state.kind == .rebase,
                          rebaseSessionID == nil,
                          operationStillActive,
                          !pullRestoreBlocked
                {
                    self.feedbackCenter.warning(
                        "Rebase paused",
                        detail: continuationState?.conflictedFiles.isEmpty == false
                            ? "Resolve the remaining conflicts before continuing."
                            : "The rebase is paused at an edit step.",
                        nextStep: "Continue or abort the rebase from the recovery bar.",
                        notificationID: operationNotificationID
                    )
                } else if state.kind == .rebase,
                          rebaseSessionID == nil,
                          let completedRebaseUndoTarget,
                          !pullRestoreBlocked
                {
                    self.feedbackCenter.success(
                        "Rebase completed",
                        detail: String(completedRebaseUndoTarget.expectedHead.prefix(7)),
                        additionalActions: [self.rebaseUndoFeedbackAction(for: completedRebaseUndoTarget)],
                        notificationID: rebaseUndoNotificationID(
                            repositoryPath: completedRebaseUndoTarget.repositoryPath
                        ),
                        notificationGroup: .standard
                    )
                } else if !pullRestoreBlocked {
                    let detail = pullChangesRestoredValue
                        ? "The Git operation is no longer paused; local changes were restored."
                        : "The Git operation is no longer paused."
                    self.feedbackCenter.success(
                        "Operation continued",
                        detail: detail,
                        notificationID: operationNotificationID
                    )
                    if !operationStillActive,
                       let completedLogApplyRecovery {
                        self.retryNextLogApplyRoot(after: completedLogApplyRecovery)
                    }
                }
            }
        } catch {
            let latestState = try? repo.operationState()
            let latestRootPath = repo.workdir()
            await MainActor.run {
                self.operationFeedback = friendlyRemoteError(error)
                // A failed recovery command can leave Git at a different
                // paused step (or with a different conflict set). Read the
                // state synchronously before publishing actions; refresh the
                // visible UI as well, so neither surface keeps a stale
                // pre-command snapshot.
                self.refreshAll(showFeedback: false)
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: state.kind == .cherryPick ? "Cherry-pick" : "Revert",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? [],
                        notificationID: operationNotificationID,
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
                        ).map { [$0] } ?? [],
                        notificationID: operationNotificationID
                    )
                } else {
                    let recoveryRootPath = latestRootPath ?? rebaseRootPath
                    let recoveryActions: [FeedbackAction]
                    if let latestState, let recoveryRootPath {
                        recoveryActions = self.operationRecoveryFeedbackActions(
                            state: latestState,
                            rootPath: recoveryRootPath
                        )
                    } else {
                        recoveryActions = []
                    }
                    self.feedbackCenter.error(
                        "Continue failed",
                        detail: errorMessage(error),
                        nextStep: "解决剩余冲突后重试，或选择 Abort。",
                        additionalActions: recoveryActions + (self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: latestRootPath ?? rebaseRootPath
                        ).map { [$0] } ?? []),
                        notificationID: recoveryRootPath.map {
                            operationRecoveryNotificationID(rootPath: $0)
                        }
                    )
                }
            }
        }
    }
}

func doOperationSkip() {
    guard let repo, let state = operationState, state.kind == .rebase else { return }
    let rebaseRootPath = repo.workdir()
    let rebaseSessionID = rebaseRootPath.flatMap { rootPath in
        multiRootRebaseSession?.roots.contains(where: { $0.rootPath == rootPath }) == true
            ? multiRootRebaseSession?.id
            : nil
    }
    let singleRootRebaseSeed = rebaseSessionID == nil ? rebaseUndoSeed : nil
    let operationNotificationID = rebaseRootPath.map {
        operationRecoveryNotificationID(rootPath: $0)
    }
    beginFeedbackOperation(
        "Skip rebase step",
        notificationID: operationNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            let outcome = try repo.rebaseSkip()
            let continuationState = try repo.operationState()
            let operationStillActive = continuationState != nil
            let completedRebaseUndoTarget: RebaseUndoTarget?
            if !operationStillActive, let singleRootRebaseSeed {
                let finalHead = try? repo.revisionCommitId(revision: singleRootRebaseSeed.branch)
                let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
                completedRebaseUndoTarget = rebaseUndoTargetAfterCompletion(
                    seed: singleRootRebaseSeed,
                    currentBranch: currentBranch,
                    finalHead: finalHead
                )
            } else {
                completedRebaseUndoTarget = nil
            }
            await MainActor.run {
                self.operationFeedback = outcome.paused ? "已跳过当前步，rebase 继续暂停" : "已跳过，rebase 完成"
                if operationStillActive {
                    self.rebaseUndoSeed = singleRootRebaseSeed
                    self.rebaseUndoTarget = nil
                    if let singleRootRebaseSeed {
                        saveRebaseUndoSeed(singleRootRebaseSeed)
                    }
                } else {
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = completedRebaseUndoTarget
                    if let singleRootRebaseSeed {
                        clearRebaseUndoSeed(repositoryPath: singleRootRebaseSeed.repositoryPath)
                    }
                }
                self.refreshAll(showFeedback: false)
                if let rebaseRootPath,
                   let rebaseSessionID {
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rebaseRootPath,
                        action: .skip,
                        operationStillActive: operationStillActive,
                        sessionID: rebaseSessionID
                    )
                    return
                }
                    if let completedRebaseUndoTarget, !operationStillActive {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: self.operationFeedback,
                            additionalActions: [self.rebaseUndoFeedbackAction(for: completedRebaseUndoTarget)],
                            notificationID: rebaseUndoNotificationID(
                                repositoryPath: completedRebaseUndoTarget.repositoryPath
                            ),
                            notificationGroup: .standard
                        )
                } else {
                    self.feedbackCenter.success(
                        outcome.paused ? "Rebase step skipped" : "Rebase completed",
                        detail: self.operationFeedback,
                        notificationID: operationNotificationID
                    )
                }
            }
        } catch {
            let latestState = try? repo.operationState()
            let latestRootPath = repo.workdir()
            await MainActor.run {
                self.operationFeedback = friendlyRemoteError(error)
                // Re-read the native rebase state before exposing another
                // Skip/Continue/Abort action after a failed command.
                self.refreshAll(showFeedback: false)
                let recoveryRootPath = latestRootPath ?? rebaseRootPath
                let recoveryActions: [FeedbackAction]
                if let latestState, let recoveryRootPath {
                    recoveryActions = self.operationRecoveryFeedbackActions(
                        state: latestState,
                        rootPath: recoveryRootPath
                    )
                } else {
                    recoveryActions = []
                }
                self.feedbackCenter.error(
                    "Skip failed",
                    detail: errorMessage(error),
                    nextStep: "可改为 Continue 或 Abort。",
                    additionalActions: recoveryActions + (self.pendingSavedChangesFeedbackAction(
                        repo: repo,
                        rootPath: latestRootPath ?? rebaseRootPath
                    ).map { [$0] } ?? []),
                    notificationID: recoveryRootPath.map {
                        operationRecoveryNotificationID(rootPath: $0)
                    }
                )
            }
        }
    }
}

func doOperationAbort() {
    guard let repo, let state = operationState else { return }
    let repositoryName = repo.workdir()
        .map { URL(fileURLWithPath: $0).lastPathComponent }
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? "repository"
    let confirmation = operationAbortConfirmation(
        for: state.kind,
        repositoryName: repositoryName
    )
    let alert = NSAlert()
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmation.confirmTitle)
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let rebaseRootPath = repo.workdir()
    let rebaseSessionID = state.kind == .rebase
        ? rebaseRootPath.flatMap { rootPath in
            multiRootRebaseSession?.roots.contains(where: { $0.rootPath == rootPath }) == true
                ? multiRootRebaseSession?.id
                : nil
        }
        : nil
    let singleRootRebaseSeed = state.kind == .rebase && rebaseSessionID == nil
        ? rebaseUndoSeed
        : nil
    let operationNotificationID = rebaseRootPath.map {
        operationRecoveryNotificationID(rootPath: $0)
    }
    let activeLogApplyRecovery = rebaseRootPath.flatMap { rootPath -> PersistedLogApplyRecovery? in
        guard let recovery = loadLogApplyRecovery(repositoryPath: rootPath) else {
            return nil
        }
        switch state.kind {
        case .cherryPick:
            return recovery.operation == .cherryPick ? recovery : nil
        case .revert:
            return recovery.operation == .revert ? recovery : nil
        case .merge, .rebase:
            return nil
        }
    }
    let logApplyRecoveriesToCancel = activeLogApplyRecovery.map {
        logApplyRecoveryCancellationTargets(
            current: $0,
            pending: pendingLogApplyRecoveries(sessionID: $0.sessionID)
        )
    } ?? []
    beginFeedbackOperation(
        "Abort operation",
        notificationID: operationNotificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            switch state.kind {
            case .merge:
                try repo.mergeAbort()
            case .rebase:
                try repo.rebaseAbort()
            case .cherryPick:
                try repo.cherryPickAbort()
            case .revert:
                try repo.revertAbort()
            }
            let operationStillActive = try repo.operationState() != nil
            await MainActor.run {
                self.operationFeedback = "已中止"
                if !operationStillActive {
                    for recovery in logApplyRecoveriesToCancel {
                        clearLogApplyRecovery(repositoryPath: recovery.rootPath)
                        self.logApplyRecoveryNotificationFingerprints.removeValue(
                            forKey: operationRecoveryNotificationRootKey(recovery.rootPath)
                        )
                        self.feedbackCenter.expire(
                            notificationID: self.logApplyRecoveryNotificationID(
                                rootPath: recovery.rootPath
                            )
                        )
                    }
                }
                if state.kind == .merge {
                    self.pendingMergeDeleteBranch = nil
                    self.mergeInitialHead = nil
                }
                if state.kind == .rebase, rebaseSessionID == nil {
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = nil
                    if let singleRootRebaseSeed {
                        clearRebaseUndoSeed(repositoryPath: singleRootRebaseSeed.repositoryPath)
                    } else if let rebaseRootPath {
                        clearRebaseUndoSeed(repositoryPath: rebaseRootPath)
                    }
                }
                if state.kind == .rebase,
                   let rebaseRootPath,
                   let rebaseSessionID {
                    self.handleMultiRootRebaseRecovery(
                        rootPath: rebaseRootPath,
                        action: .abort,
                        operationStillActive: operationStillActive,
                        sessionID: rebaseSessionID
                    )
                    self.refreshAll(showFeedback: false)
                    return
                }
                self.refreshAll(showFeedback: false)
                self.feedbackCenter.success(
                    "Operation aborted",
                    detail: "The repository was restored to its pre-operation state.",
                    notificationID: operationNotificationID
                )
            }
        } catch {
            let latestState = try? repo.operationState()
            let latestRootPath = repo.workdir()
            await MainActor.run {
                self.operationFeedback = friendlyRemoteError(error)
                // Abort failures must retain the current Git operation and
                // its latest conflicts, not the snapshot captured at click
                // time. This keeps Retry/Continue/Abort root-qualified.
                self.refreshAll(showFeedback: false)
                if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    self.showStashRestoreConflict(
                        paths,
                        operationName: state.kind == .cherryPick ? "Cherry-pick" : "Revert",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repo.workdir()
                        ).map { [$0] } ?? [],
                        notificationID: operationNotificationID,
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
                        ).map { [$0] } ?? [],
                        notificationID: operationNotificationID
                    )
                } else {
                    let recoveryRootPath = latestRootPath ?? rebaseRootPath
                    let recoveryActions: [FeedbackAction]
                    if let latestState, let recoveryRootPath {
                        recoveryActions = self.operationRecoveryFeedbackActions(
                            state: latestState,
                            rootPath: recoveryRootPath
                        )
                    } else {
                        recoveryActions = []
                    }
                    self.feedbackCenter.error(
                        "Abort failed",
                        detail: errorMessage(error),
                        nextStep: "状态已保留，可重试或选择其他动作。",
                        additionalActions: recoveryActions + (self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: latestRootPath ?? rebaseRootPath
                        ).map { [$0] } ?? []),
                        notificationID: recoveryRootPath.map {
                            operationRecoveryNotificationID(rootPath: $0)
                        }
                    )
                }
            }
        }
    }
}

func showOperationDetailsAction(notificationID: String) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .showOperationDetails,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: "",
        operationNotificationID: notificationID
    )
    return FeedbackAction(title: "Show Details", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

}
