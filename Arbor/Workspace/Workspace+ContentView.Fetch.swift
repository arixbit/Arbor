import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// 多 root Branches Popup 的远程分支 Fetch：只更新该 root 对应 remote 的
/// remote-tracking refs，不把当前窗口绑定的 repository 当成目标。
func fetchRemoteBranchInRoot(rootPath: String, branch: String) {
    guard let remote = branch.split(separator: "/", maxSplits: 1).first,
          !remote.isEmpty else {
        feedbackCenter.error("Fetch remote branch failed", detail: "Invalid remote branch: \(branch)")
        return
    }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    beginFeedbackOperation("Fetch remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let outcome = try rootRepo.fetchRemoteBranchWithOptionsAndAuthAndCancel(
                remote: String(remote),
                branch: branch,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            let detail = outcome.updated.isEmpty ? "No updates" : outcome.updated.joined(separator: ", ")
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success(
                    "Remote branch fetched",
                    detail: "\(branch) · \(detail) · \(rootPath)"
                )
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error(
                    "Fetch remote branch failed",
                    detail: "\(branch) · \(rootPath): \(friendlyRemoteError(error))",
                    nextStep: "Check the remote and credentials, then retry."
                )
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
            }
        }
    }
}

/// Remote branch without a local tracking branch: fetch it only; never merge it into HEAD.
func fetchRemoteBranch(_ branch: RemoteBranchInfo) {
    guard let repo else { return }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    beginFeedbackOperation("Fetch remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let outcome = try repo.fetchRemoteBranchWithOptionsAndAuthAndCancel(
                remote: branch.remote,
                branch: branch.name,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            let detail = outcome.updated.isEmpty ? "No updates" : outcome.updated.joined(separator: ", ")
            await MainActor.run {
                self.feedbackCenter.success("Remote branch fetched", detail: "\(branch.name) · \(detail)")
                self.loadRepoData()
                self.synchronizeRemoteProtectedBranchPatterns()
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.feedbackCenter.error(
                    "Fetch remote branch failed",
                    detail: "\(branch.name): \(detail)",
                    nextStep: "Check the remote and credentials, then retry."
                )
                if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
            }
        }
    }
}

func fetchRemoteInRoot(rootPath: String, remote: String) {
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Fetch", cancelHandle: cancel)
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let outcome = try rootRepo.fetchWithOptionsAndAuthAndCancel(
                remote: remote,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            let detail = outcome.updated.isEmpty ? "无更新" : outcome.updated.joined(separator: ", ")
            await MainActor.run {
                self.feedbackCenter.success("Fetch completed", detail: "\(remote) · \(detail)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Fetch failed",
                    detail: "\(remote) · \(rootPath): \(friendlyRemoteError(error))",
                    nextStep: "Check the remote and Git identity, then retry."
                )
            }
        }
    }
}

/// IntelliJ's `Git.Fetch` action fetches every configured remote in every Git
/// root.  A named remote is still supported for remote configuration flows
/// that intentionally fetch only the remote just edited.
func doFetch(_ name: String? = nil) {
    guard let name else {
        doFetchAll()
        return
    }
    doFetchRemote(name)
}

func doFetchRemote(_ remote: String) {
    guard !isArborFetchInProgress(
        isRunning: feedbackCenter.isRunning,
        operationName: feedbackCenter.operationName
    ) else { return }
    guard let repository = repo else { return }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Fetch", cancelHandle: cancel)
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    Task.detached(priority: .userInitiated) {
        do {
            let fo = try repository.fetchWithOptionsAndAuthAndCancel(
                remote: remote,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            let detail = fo.updated.isEmpty ? "无更新" : fo.updated.joined(separator: ", ")
            await MainActor.run {
                self.mergeWorkspace.feedback = "fetch 完成：\(detail)"
                self.publishFetchCompletion(detail: detail)
                self.loadRepoData()
                self.synchronizeRemoteProtectedBranchPatterns()
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.mergeWorkspace.feedback = detail
                self.feedbackCenter.error("Fetch failed", detail: detail, nextStep: "Check the remote and Git identity, then retry.")
                if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
            }
        }
    }
}

func autoFetchRecoveryRequest(
    _ action: ArborVCSActionRequest.AutoFetchRecoveryAction,
    rootPaths: [String]? = nil
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .autoFetchRecovery,
        projectPath: projectWorkspace.path,
        rootPath: repo?.workdir(),
        shelfName: "",
        autoFetchRecoveryAction: action,
        autoFetchRootPaths: rootPaths ?? autoFetchRootPaths
    )
}

func autoFetchRecoveryFeedbackAction(
    _ action: ArborVCSActionRequest.AutoFetchRecoveryAction,
    rootPaths: [String]? = nil
) -> FeedbackAction {
    let request = autoFetchRecoveryRequest(action, rootPaths: rootPaths)
    let title: String = switch action {
    case .fetchAll: "Fetch All"
    case .retryCheck: incomingCheckStrategy == .fetch ? "Retry Fetch All" : "Retry Check"
    case .enable: "Enable Auto-fetch"
    case .doNotAskAgain: "Do Not Ask Again"
    }
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

/// IntelliJ 的 Fetch All：每个 remote 独立执行，保留部分成功结果。
func doFetchAll(rootPaths: [String]? = nil) {
    guard !isArborFetchInProgress(
        isRunning: feedbackCenter.isRunning,
        operationName: feedbackCenter.operationName
    ) else { return }
    let paths = Array(Set(rootPaths ?? autoFetchRootPaths)).sorted()
    guard !paths.isEmpty else { return }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Fetch all remotes", cancelHandle: cancel)
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    Task.detached(priority: .userInitiated) {
        var updated: [String] = []
        var failures: [String] = []
        var successfulRemoteCount = 0
        var configuredRemoteCount = 0
        for rootPath in paths {
            guard !cancel.isCancelled() else { break }
            do {
                let rootRepo = try openRepository(path: rootPath)
                let rootRemotes = try rootRepo.remoteList()
                configuredRemoteCount += rootRemotes.count
                for remote in rootRemotes {
                    guard !cancel.isCancelled() else { break }
                    do {
                        let outcome = try rootRepo.fetchWithOptionsAndAuthAndCancel(
                            remote: remote.name,
                            tagMode: tagMode,
                            broker: broker,
                            cancel: cancel
                        )
                        successfulRemoteCount += 1
                        updated.append(contentsOf: outcome.updated.map {
                            "\(rootPath) · \(remote.name)/\($0)"
                        })
                    } catch {
                        failures.append("\(rootPath) · \(remote.name): \(friendlyRemoteError(error))")
                    }
                }
            } catch {
                failures.append("\(rootPath): \(friendlyRemoteError(error))")
            }
        }
        let result = (
            updated: updated,
            failures: failures,
            successfulRemoteCount: successfulRemoteCount,
            configuredRemoteCount: configuredRemoteCount
        )
        await MainActor.run {
            self.loadRepoData()
            self.loadMultiRoots()
            self.gitSettings.autoFetchIncomingFingerprint = nil
            self.gitSettings.autoFetchFailureFingerprint = nil
            if result.successfulRemoteCount > 0 {
                self.synchronizeRemoteProtectedBranchPatternsForAllRoots()
            }
            // A repository without remotes has nothing to fetch. Reporting
            // "Fetch all completed" there tells the user the operation
            // succeeded when it never ran, so say what is actually missing.
            if result.failures.isEmpty, result.configuredRemoteCount == 0 {
                self.feedbackCenter.success(
                    "Nothing to fetch",
                    detail: "No remotes are configured for this repository.",
                    actionTitle: "Configure Remotes…",
                    action: { self.beginConfigureRemotes() }
                )
            } else if result.failures.isEmpty {
                self.publishFetchCompletion(
                    detail: result.updated.isEmpty ? "No updates" : result.updated.joined(separator: ", "),
                    title: "Fetch all completed"
                )
            } else {
                self.feedbackCenter.warning(
                    "Fetch all partially completed",
                    detail: result.failures.joined(separator: "\n"),
                    nextStep: "修正失败的 remote 或认证配置后重试。",
                    additionalActions: [
                        self.autoFetchRecoveryFeedbackAction(.fetchAll, rootPaths: paths)
                    ],
                    notificationID: "\(self.autoFetchNotificationIDPrefix).error"
                )
            }
        }
    }
}

func publishFetchCompletion(detail: String, title: String = "Fetch completed") {
    let suggestionCount = GitIncomingCheckStrategySettings.suggestionCount(for: projectWorkspace.path)
    let suggestionDisabled = GitIncomingCheckStrategySettings.suggestionDisabled(for: projectWorkspace.path)
    guard shouldSuggestAutoFetch(
        autoFetchEnabled: incomingCheckStrategy == .fetch,
        suggestionDisabled: suggestionDisabled,
        shownCount: suggestionCount
    ) else {
        feedbackCenter.success(
            title,
            detail: detail,
            notificationID: "\(autoFetchNotificationIDPrefix).result"
        )
        return
    }

    GitIncomingCheckStrategySettings.setSuggestionCount(
        suggestionCount + 1,
        for: projectWorkspace.path
    )
    feedbackCenter.success(
        title,
        detail: detail,
        additionalActions: [
            autoFetchRecoveryFeedbackAction(.enable),
            autoFetchRecoveryFeedbackAction(.doNotAskAgain)
        ],
        notificationID: "\(autoFetchNotificationIDPrefix).result"
    )
}

/// 对所有已配置 remote 执行 prune，避免删除远程分支后 Branches Popup 保留旧引用。
func doFetchPrune() {
    guard !isArborFetchInProgress(
        isRunning: feedbackCenter.isRunning,
        operationName: feedbackCenter.operationName
    ) else { return }
    guard let repo, !remoteWorkspace.remotes.isEmpty else { return }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Prune remote branches", cancelHandle: cancel)
    let remoteNames = remoteWorkspace.remotes.map(\.name)
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        for remote in remoteNames {
            guard !cancel.isCancelled() else { break }
            do {
                try repo.fetchPruneWithOptionsAndAuthAndCancel(
                    remote: remote,
                    tagMode: tagMode,
                    broker: broker,
                    cancel: cancel
                )
            } catch {
                failures.append("\(remote): \(friendlyRemoteError(error))")
            }
        }
        let result = failures
        await MainActor.run {
            self.loadRepoData()
            if result.isEmpty {
                self.feedbackCenter.success("Remote branches pruned")
            } else {
                self.feedbackCenter.warning(
                    "Prune partially completed",
                    detail: result.joined(separator: "\n"),
                    nextStep: "检查失败的 remote 后重试。"
                )
            }
        }
    }
}

/// 将浅克隆补全为完整历史；执行前要求用户确认，因为该操作不可逆地扩大本地仓库。
func doFetchUnshallow() {
    guard !isArborFetchInProgress(
        isRunning: feedbackCenter.isRunning,
        operationName: feedbackCenter.operationName
    ) else { return }
    guard let repo, repositoryStatus.isShallowRepository else { return }
    let preferredRemote: String? = currentSyncStatus.flatMap { status -> String? in
        let candidate = status.upstream.split(separator: "/", maxSplits: 1).first.map(String.init)
        guard let candidate, remoteWorkspace.remotes.contains(where: { $0.name == candidate }) else { return nil }
        return candidate
    }
    let remote = defaultFetchRemoteName(
        preferredRemote: preferredRemote,
        availableRemoteNames: remoteWorkspace.remotes.map(\.name)
    )
    guard let remote else {
        feedbackCenter.warning(
            "Fetch full history unavailable",
            detail: remoteWorkspace.remotes.count > 1
                ? "No tracked remote or origin is available; choose a remote configuration before retrying."
                : "No usable remote is configured for this Git root."
        )
        return
    }
    let alert = NSAlert()
    alert.messageText = "Fetch complete history?"
    alert.informativeText = "这会把当前浅克隆补全为完整历史，并增加本地磁盘占用。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Fetch Full History")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Fetch full history", cancelHandle: cancel)
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    Task.detached(priority: .userInitiated) {
        do {
            try repo.fetchUnshallowWithOptionsAndAuthAndCancel(
                remote: remote,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadRepoData()
                self.feedbackCenter.success("Full history fetched", detail: remote)
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.feedbackCenter.error("Fetch full history failed", detail: detail, nextStep: "确认该 remote 支持 unshallow 后重试。")
            }
        }
    }
}

func fetchPullDialogRemote(rootPath: String, remote: String) {
    let normalizedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRootPath.isEmpty, !normalizedRemote.isEmpty else { return }
    guard !isArborFetchInProgress(
        isRunning: feedbackCenter.isRunning,
        operationName: feedbackCenter.operationName
    ) else { return }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    beginFeedbackOperation("Fetch for Pull", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: normalizedRootPath)
            let outcome = try rootRepo.fetchWithOptionsAndAuthAndCancel(
                remote: normalizedRemote,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.refreshPullDialogSnapshots()
                self.loadRepoData()
                self.feedbackCenter.success(
                    "Fetch for Pull completed",
                    detail: outcome.updated.isEmpty ? "No updates from \(normalizedRemote)." : outcome.updated.joined(separator: ", ")
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Fetch for Pull failed",
                    detail: friendlyRemoteError(error),
                    nextStep: "Check the selected remote and credentials, then retry."
                )
            }
        }
    }
}

}
