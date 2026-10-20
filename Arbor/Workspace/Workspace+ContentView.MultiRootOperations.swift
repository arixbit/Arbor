import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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
        pushWorkspace.multiRootPushRetryContext = nil
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
        pushWorkspace.multiRootPushRetryContext = nil
    }
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    guard let projectPath = projectWorkspace.path else { return }
    multiRootWorkspace.running = true
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
                self.multiRootWorkspace.running = false
                let retryPaths = rootPaths ?? self.multiRootWorkspace.roots.map(\.path)
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
                    self.hostingWorkspace.showHostingAuthPrompt = true
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
    multiRootWorkspace.results = results
    multiRootWorkspace.running = false
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

}
