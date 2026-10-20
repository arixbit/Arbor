import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func completeMultiRootResolverStash(_ root: MultiRootConflictResolverRoot) {
    guard case let .stash(stashID, _, isPop) = root.kind,
          let rootRepo = multiRootResolverActiveRepo else { return }
    multiRootResolverWorking = true
    multiRootResolverError = nil
    Task.detached(priority: .userInitiated) {
        do {
            let conflicts = try rootRepo.status().filter {
                $0.staged == .conflicted || $0.unstaged == .conflicted
            }
            guard conflicts.isEmpty else {
                throw NSError(
                    domain: "Arbor.MultiRootStashRestore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "仍有冲突文件未解决：\(conflicts.map(\.path).joined(separator: ", "))"]
                )
            }
            if isPop {
                let finalizedPreserved = try rootRepo.finalizeApplyLocalChangesRestore()
                if !finalizedPreserved {
                    guard let stashID else {
                        throw NSError(
                            domain: "Arbor.MultiRootStashRestore",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The stash identity is unavailable; the stash was kept."]
                        )
                    }
                    try rootRepo.stashDrop(index: try currentStashIndex(repo: rootRepo, stashID: stashID))
                }
            }
            await MainActor.run {
                self.stashRecovery.multiRootConflicts[root.rootPath] = nil
                self.stashRecovery.multiRootConflictIndexes[root.rootPath] = nil
                self.stashRecovery.multiRootConflictIDs[root.rootPath] = nil
                self.stashRecovery.multiRootConflictPopModes[root.rootPath] = nil
                if isPop {
                    if let stashID {
                        self.clearStashDiffIfMatching(rootPath: root.rootPath, stashID: stashID)
                    }
                    self.stashRecovery.multiRootUpdateStashedRoots.remove(root.rootPath)
                }
                self.multiRootResolverWorking = false
                self.feedbackCenter.success(
                    isPop ? "Stash pop completed" : "Stash apply completed",
                    detail: root.rootPath
                )
                self.openMultiRootConflictResolver(preferredRootPath: root.rootPath)
            }
        } catch {
            await MainActor.run {
                self.multiRootResolverWorking = false
                self.multiRootResolverError = "\(root.rootPath): \(errorMessage(error))"
                self.refreshMultiRootResolverActiveRoot()
            }
        }
    }
}

func recoverMultiRootUpdateStashesAfterFailure(_ results: [RootOperationResult]) {
    let roots = results.filter {
        !$0.success
            && ($0.message.localizedCaseInsensitiveContains("local changes remain in stash")
                || $0.message.localizedCaseInsensitiveContains("local changes remain in shelf"))
    }
    for result in roots {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                guard try rootRepo.operationState() == nil else { return }
                let shelf = try rootRepo.shelveList().first(where: { isArborUpdateShelfName($0.name) })
                let stash = try rootRepo.stashList().enumerated().first(where: {
                    isArborUpdateStashMessage($0.element.message)
                })
                guard shelf != nil || stash != nil else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Update local changes unavailable",
                            detail: "\(rootPath): the temporary Update Project local-change save could not be located.",
                            nextStep: "Inspect that root's stash or Shelf list before retrying Update."
                        )
                    }
                    return
                }
                do {
                    if let shelf {
                        try rootRepo.shelvePopPreservation(name: shelf.name)
                    } else if let stash {
                        try rootRepo.stashPopWithIndex(
                            index: try currentStashIndex(
                                repo: rootRepo,
                                stashID: stash.element.id
                            ),
                            restoreIndex: true
                        )
                    }
                    await MainActor.run {
                        self.stashRecovery.multiRootUpdateStashedRoots.remove(rootPath)
                        self.loadMultiRoots()
                        self.feedbackCenter.success(
                            "Local changes restored",
                            detail: "\(rootPath): Update failed before completion, so the temporary local changes were restored."
                        )
                    }
                } catch let error as EngineError {
                    if case let .StashApplyConflict(paths, conflictStashID) = error {
                        await MainActor.run {
                            self.presentMultiRootStashConflict(
                                rootPath: rootPath,
                                index: stash?.offset ?? 0,
                                stashID: conflictStashID ?? stash?.element.id,
                                isPop: true,
                                paths: paths
                            )
                        }
                    } else if case .ShelveApplyConflict = error {
                        await MainActor.run {
                            self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                        }
                    } else {
                        await MainActor.run {
                            self.feedbackCenter.error(
                                "Local changes restore failed",
                                detail: "\(rootPath): \(errorMessage(error))",
                                nextStep: "Retry the root-specific local-change restore after checking its Git status."
                            )
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Local changes restore failed",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Inspect that Git root and restore its Update Project local changes manually."
                    )
                }
            }
        }
    }
}

func clearStashDiffIfMatching(rootPath: String, stashID: String) {
    guard stashUI.diffRootPath == rootPath, stashUI.diffStashID == stashID else { return }
    stashUI.showDiff = false
    stashUI.diffText = nil
    stashUI.diffStashID = nil
    stashUI.diffRootPath = nil
}

func applyStashInRoot(rootPath: String, stashID: String, restoreIndex: Bool) {
    beginFeedbackOperation("Apply stash")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let currentIndex = try currentStashIndex(repo: rootRepo, stashID: stashID)
            try rootRepo.stashApplyWithIndex(index: currentIndex, restoreIndex: restoreIndex)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Stash applied; stash kept", detail: "\(rootPath) · \(String(stashID.prefix(7)))")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case let .StashApplyConflict(paths, conflictStashID) = error as? EngineError {
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        stashID: conflictStashID ?? stashID,
                        isPop: false,
                        paths: paths
                    )
                } else {
                    self.feedbackCenter.error(
                        "Apply stash failed",
                        detail: "\(rootPath) · \(String(stashID.prefix(7))): \(errorMessage(error))",
                        nextStep: "Resolve the root-specific conflict before retrying."
                    )
                }
            }
        }
    }
}

func popStashInRoot(rootPath: String, stashID: String, restoreIndex: Bool) {
    beginFeedbackOperation("Pop stash")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let currentIndex = try currentStashIndex(repo: rootRepo, stashID: stashID)
            try rootRepo.stashPopWithIndex(index: currentIndex, restoreIndex: restoreIndex)
            await MainActor.run {
                self.loadMultiRoots()
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: stashID)
                self.feedbackCenter.success("Stash popped", detail: "\(rootPath) · \(String(stashID.prefix(7)))")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case let .StashApplyConflict(paths, conflictStashID) = error as? EngineError {
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        stashID: conflictStashID ?? stashID,
                        isPop: true,
                        paths: paths
                    )
                } else {
                    self.feedbackCenter.error(
                        "Pop stash failed",
                        detail: "\(rootPath) · \(String(stashID.prefix(7))): \(errorMessage(error))",
                        nextStep: "Resolve the root-specific conflict; the stash is retained when Git cannot pop it."
                    )
                }
            }
        }
    }
}

func dropStashInRoot(rootPath: String, stashID: String) {
    let alert = NSAlert()
    alert.messageText = "Drop selected stash?"
    alert.informativeText = "This permanently removes the selected stash from the root."
    alert.addButton(withTitle: "Drop")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    dropStashInRootConfirmed(rootPath: rootPath, stashID: stashID)
}

/// Execute a root-scoped stash drop after the caller has already confirmed
/// the destructive action in its own UI surface.
func dropStashInRootConfirmed(rootPath: String, stashID: String) {
    beginFeedbackOperation("Drop stash")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let currentIndex = try currentStashIndex(repo: rootRepo, stashID: stashID)
            try rootRepo.stashDrop(index: currentIndex)
            await MainActor.run {
                self.loadMultiRoots()
                self.refreshUnstashRootIfVisible(rootPath)
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: stashID)
                self.feedbackCenter.success("Stash dropped", detail: "\(rootPath) · \(String(stashID.prefix(7)))")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Drop stash failed", detail: "\(rootPath) · \(String(stashID.prefix(7))): \(errorMessage(error))")
            }
        }
    }
}

func stashBranchInRoot(rootPath: String, stashID: String) {
    let alert = NSAlert()
    alert.messageText = "Create branch from stash"
    alert.informativeText = "The new branch will be checked out in the selected root and the stash will be applied."
    let field = NSTextField(string: "stash-branch")
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let branch = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else { return }
    stashBranchInRoot(rootPath: rootPath, stashID: stashID, branch: branch)
}

func stashBranchNotificationComponent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
        .replacingOccurrences(of: "|", with: "_")
        .replacingOccurrences(of: " ", with: "_")
}

func stashBranchNotificationID(rootPath: String, branch: String) -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    return [
        "git.stash.branch",
        stashBranchNotificationComponent(URL(fileURLWithPath: projectPath).standardizedFileURL.path),
        stashBranchNotificationComponent(URL(fileURLWithPath: rootPath).standardizedFileURL.path),
        stashBranchNotificationComponent(branch)
    ].joined(separator: ".")
}

func stashBranchRetryRequest(
    _ retry: PersistedStashBranchRetry,
    rootPath: String
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .retryStashBranch,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        stashBranchRetry: retry
    )
}

nonisolated func stashBranchRetryIsCurrentlySafe(
    _ retry: PersistedStashBranchRetry,
    rootPath: String
) -> Bool {
    guard let rootRepo = try? openRepository(path: rootPath),
          let branches = try? rootRepo.branchList(),
          let stashes = try? rootRepo.stashList() else {
        return false
    }
    return stashBranchRetryStateIsSafe(
        retry,
        currentBranch: branches.first(where: { $0.isCurrent })?.name,
        currentHead: rootRepo.headCommitId(),
        stashIDs: stashes.map(\.id),
        localBranches: branches.map(\.name)
    )
}

func stashBranchRetryFeedbackAction(
    _ retry: PersistedStashBranchRetry,
    rootPath: String
) -> FeedbackAction {
    let request = stashBranchRetryRequest(retry, rootPath: rootPath)
    return FeedbackAction(
        id: "retry-stash-branch:\(rootPath):\(retry.stashID):\(retry.branch)",
        title: "Retry Create Branch from Stash",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func retryStashBranch(
    rootPath: String,
    retry: PersistedStashBranchRetry
) {
    let notificationID = stashBranchNotificationID(rootPath: rootPath, branch: retry.branch)
    beginFeedbackOperation("Create branch from stash", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let stashes = try rootRepo.stashList()
            let branchNames = try rootRepo.branchList().map(\.name)
            guard stashBranchRetryStateIsSafe(
                retry,
                currentBranch: try rootRepo.branchList().first(where: { $0.isCurrent })?.name,
                currentHead: rootRepo.headCommitId(),
                stashIDs: stashes.map(\.id),
                localBranches: branchNames
            ) else {
                throw NSError(
                    domain: "Arbor.StashBranch",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The repository changed after the failed stash branch operation; retry was refused."
                    ]
                )
            }
            try rootRepo.stashBranch(
                index: try currentStashIndex(repo: rootRepo, stashID: retry.stashID),
                branch: retry.branch
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.refreshUnstashRootIfVisible(rootPath)
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: retry.stashID)
                self.feedbackCenter.success(
                    "Branch created from stash",
                    detail: "\(retry.branch) · \(rootPath)",
                    notificationID: notificationID
                )
            }
        } catch {
            let canRetry = stashBranchRetryIsCurrentlySafe(retry, rootPath: rootPath)
            await MainActor.run {
                self.feedbackCenter.error(
                    "Create branch from stash retry failed",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "The retry was refused if the original repository state no longer matches; inspect the root before retrying again.",
                    additionalActions: canRetry
                        ? [self.stashBranchRetryFeedbackAction(retry, rootPath: rootPath)]
                        : [],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Execute Create Branch from Stash after the root-scoped Unstash dialog has
/// already validated and captured the branch name.
func stashBranchInRoot(rootPath: String, stashID: String, branch: String) {
    let notificationID = stashBranchNotificationID(rootPath: rootPath, branch: branch)
    beginFeedbackOperation("Create branch from stash", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        var retry: PersistedStashBranchRetry?
        do {
            let rootRepo = try openRepository(path: rootPath)
            let stashes = try rootRepo.stashList()
            guard stashes.contains(where: { $0.id == stashID }) else {
                throw NSError(
                    domain: "Arbor.StashBranch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The selected stash no longer exists."]
                )
            }
            retry = PersistedStashBranchRetry(
                stashID: stashID,
                branch: branch,
                expectedCurrentBranch: try rootRepo.branchList().first(where: { $0.isCurrent })?.name,
                expectedCurrentHead: rootRepo.headCommitId()
            )
            let currentIndex = try currentStashIndex(repo: rootRepo, stashID: stashID)
            try rootRepo.stashBranch(index: currentIndex, branch: branch)
            await MainActor.run {
                self.loadMultiRoots()
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: stashID)
                self.feedbackCenter.success(
                    "Branch created from stash",
                    detail: "\(branch) · \(rootPath)",
                    notificationID: notificationID
                )
            }
        } catch {
            let retryContext = retry
            let canRetry = retryContext.map {
                stashBranchRetryIsCurrentlySafe($0, rootPath: rootPath)
            } ?? false
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error(
                    "Create branch from stash failed",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "The stash is kept when Git cannot complete the branch operation. Retry only if the original repository state is unchanged.",
                    additionalActions: canRetry
                        ? (retryContext.map {
                            [self.stashBranchRetryFeedbackAction($0, rootPath: rootPath)]
                        } ?? [])
                        : [],
                    notificationID: notificationID
                )
            }
        }
    }
}

func showStashDiffInRoot(rootPath: String, stashID: String) {
    stashUI.diffStashID = stashID
    stashUI.diffRootPath = rootPath
    stashUI.diffText = nil
    stashUI.showDiff = false
    beginFeedbackOperation("Load stash diff")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let currentIndex = try currentStashIndex(repo: rootRepo, stashID: stashID)
            let diff = try rootRepo.stashDiff(index: currentIndex)
            await MainActor.run {
                guard self.stashUI.diffStashID == stashID,
                      self.stashUI.diffRootPath == rootPath else { return }
                self.stashUI.diffText = diff
                self.stashUI.showDiff = true
                self.feedbackCenter.success("Stash diff loaded", detail: "\(rootPath) · \(String(stashID.prefix(7)))")
            }
        } catch {
            await MainActor.run {
                guard self.stashUI.diffStashID == stashID,
                      self.stashUI.diffRootPath == rootPath else { return }
                self.feedbackCenter.error("Load stash diff failed", detail: "\(rootPath): \(errorMessage(error))")
            }
        }
    }
}

func clearStashesInRoot(rootPath: String) {
    let repositoryName = URL(fileURLWithPath: rootPath).lastPathComponent
    let confirmation = stashClearConfirmation(repositoryName: repositoryName)
    let alert = NSAlert()
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.addButton(withTitle: confirmation.confirmTitle)
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    clearStashesInRootConfirmed(rootPath: rootPath)
}

/// Execute a root-scoped stash clear after the caller has already confirmed
/// the destructive action in its own UI surface.
func clearStashesInRootConfirmed(rootPath: String) {
    beginFeedbackOperation("Clear stashes")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.stashClear()
            await MainActor.run {
                self.loadMultiRoots()
                self.refreshUnstashRootIfVisible(rootPath)
                self.stashUI.clearDiff(rootPath: rootPath)
                self.feedbackCenter.success("Stashes cleared", detail: rootPath)
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Clear stashes failed", detail: "\(rootPath): \(errorMessage(error))")
            }
        }
    }
}

/// 清空整个 stash 栈（等价 git stash clear）。
func stashClearAll() {
    guard let repo else { return }
    let repositoryName = repo.workdir().map {
        URL(fileURLWithPath: $0).lastPathComponent
    } ?? "the current Git root"
    let confirmation = stashClearConfirmation(repositoryName: repositoryName)
    let alert = NSAlert()
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.addButton(withTitle: confirmation.confirmTitle)
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Clear stashes")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stashClear()
            let ss = try repo.stashList()
            await MainActor.run {
                self.stashes = ss
                self.stashUI.showDiff = false
                self.stashUI.diffText = nil
                self.stashUI.diffStashID = nil
                self.stashUI.diffRootPath = nil
                self.stashUI.previewStashID = nil
                self.stashUI.previewText = nil
                self.stashUI.showPreview = false
                self.feedbackCenter.success("Stashes cleared")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Clear stashes failed", detail: errorMessage(error), nextStep: "stash 栈未变，可重试。")
            }
        }
    }
}

func presentStashDialog() {
    guard let rootPath = repo?.workdir() ?? multiRoots.first?.path else { return }
    // 对话框的初始状态收敛在 StashWorkspaceState，不再逐字段重置。
    stashUI.beginCreate(rootPath: rootPath, currentBranch: currentBranchName)
    selectStashRoot(rootPath)
    loadMultiRoots()
}

/// Load the branch label for the root selected in the IntelliJ-style Stash
/// dialog. The stash operation itself opens the same selected root again so a
/// secondary root can never fall back to the primary repository.
func selectStashRoot(_ rootPath: String) {
    stashUI.rootPath = rootPath
    stashUI.currentBranch = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath })?.headBranch ?? ""
    stashUI.rootLoading = true
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let branch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""
            await MainActor.run {
                guard self.stashUI.showCreateDialog, self.stashUI.rootPath == rootPath else { return }
                self.stashUI.currentBranch = branch
                self.stashUI.rootLoading = false
            }
        } catch {
            await MainActor.run {
                guard self.stashUI.showCreateDialog, self.stashUI.rootPath == rootPath else { return }
                self.stashUI.currentBranch = ""
                self.stashUI.rootLoading = false
                self.feedbackCenter.error(
                    "Load Git root failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git root and retry."
                )
            }
        }
    }
}

func stashSave(rootPath requestedRootPath: String? = nil) {
    let targetRootPath = requestedRootPath ?? repo?.workdir()
    guard let targetRootPath, !targetRootPath.isEmpty else { return }
    beginFeedbackOperation("Stash changes")
    let msg = stashUI.message.trimmingCharacters(in: .whitespaces)
    let keepIndex = stashUI.keepIndex
    let currentRootPath = repo?.workdir().map(canonicalExternalLogPath)
    let targetRootKey = canonicalExternalLogPath(targetRootPath)
    Task.detached(priority: .userInitiated) {
        do {
            let targetRepo = try openRepository(path: targetRootPath)
            if keepIndex {
                _ = try targetRepo.stashSaveWithKeepIndex(message: msg.isEmpty ? nil : msg)
            } else {
                _ = try targetRepo.stashSave(message: msg.isEmpty ? nil : msg)
            }
            let ss = try targetRepo.stashList()
            let st = try targetRepo.status()
            let staging = try? targetRepo.stagingModel()
            await MainActor.run {
                if currentRootPath == targetRootKey {
                    self.stashes = ss
                    self.entries = st
                    self.stashUI.previewStashID = nil
                    self.stashUI.previewText = nil
                    self.stashUI.showPreview = false
                    self.stagingModel = staging
                    self.lastIndexRevision = staging?.indexRevision
                }
                self.stashUI.message = ""
                self.stashUI.keepIndex = false
                self.feedbackCenter.success("Changes stashed")
                if currentRootPath == targetRootKey {
                    self.loadRepoData(includeComparisons: false)
                }
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Stash changes failed",
                    detail: errorMessage(error),
                    nextStep: "No stash was created if Git rejected the operation; check the selected root and retry."
                )
            }
        }
    }
}

/// 打开 IntelliJ Git 风格的 Stash Files 对话框。右键触发的路径默认选中，
/// 用户可以在提交前继续扩大或缩小选区。
func showStashFiles(paths: [String]) {
    stashUI.filesInitialPaths = Set(paths)
    stashUI.filesMessage = ""
    stashUI.showFilesDialog = true
}

/// Open the single-stash variant of IntelliJ's Git.Stash.UnstashAs action.
/// The stash ID is retained instead of its stack index because another refresh
/// can reorder the stash list while the dialog is open.
func presentUnstashAsDialog(stashID: String) {
    guard stashes.contains(where: { $0.id == stashID }) else { return }
    stashUI.unstashAsStashID = stashID
    stashUI.showUnstashAsDialog = true
}

/// Open the repository-level Unstash dialog with the currently active root.
/// Multi-root projects receive their root chooser as soon as discovery has
/// refreshed `multiRoots`; the initial list still comes from the visible root
/// so the dialog is immediately useful while discovery is in flight.
func presentUnstashDialog() {
    guard let rootPath = repo?.workdir() else { return }
    stashUI.beginUnstash(rootPath: rootPath, stashes: stashes, currentBranch: currentBranchName)
    loadMultiRoots()
}

/// Load stash data for the root selected in the IntelliJ-style Unstash root
/// chooser. The generation guard is the selected path itself: a slower root
/// cannot overwrite a newer selection after the user switches repositories.
func selectUnstashRoot(_ rootPath: String) {
    stashUI.unstashRootPath = rootPath
    stashUI.unstashStashes = []
    stashUI.unstashCurrentBranch = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath })?.headBranch ?? ""
    stashUI.unstashRootLoading = true
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let loadedStashes = try rootRepo.stashList()
            let loadedBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""
            await MainActor.run {
                guard self.stashUI.showUnstashDialog, self.stashUI.unstashRootPath == rootPath else { return }
                self.stashUI.unstashStashes = loadedStashes
                self.stashUI.unstashCurrentBranch = loadedBranch
                self.stashUI.unstashRootLoading = false
            }
        } catch {
            await MainActor.run {
                guard self.stashUI.showUnstashDialog, self.stashUI.unstashRootPath == rootPath else { return }
                self.stashUI.unstashStashes = []
                self.stashUI.unstashRootLoading = false
                self.feedbackCenter.error(
                    "Load stashes failed",
                    detail: "(rootPath): (errorMessage(error))",
                    nextStep: "Check the selected Git root and retry."
                )
            }
        }
    }
}

func refreshUnstashRootIfVisible(_ rootPath: String) {
    guard stashUI.showUnstashDialog, stashUI.unstashRootPath == rootPath else { return }
    selectUnstashRoot(rootPath)
}

func stashSelectedFiles(_ paths: [String]) {
    guard let repo, !paths.isEmpty else { return }
    beginFeedbackOperation("Stash selected files")
    let message = stashUI.filesMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    Task.detached(priority: .userInitiated) {
        do {
            _ = try repo.stashSavePaths(
                message: message.isEmpty ? nil : message,
                paths: paths,
                includeUntracked: true
            )
            let ss = try repo.stashList()
            let st = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.stashes = ss
                self.entries = st
                self.stagingModel = staging
                self.lastIndexRevision = staging?.indexRevision
                self.stashUI.filesMessage = ""
                self.stashUI.filesInitialPaths = []
                self.feedbackCenter.success("Selected files stashed")
                self.loadRepoData(includeComparisons: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Stash selected files failed",
                    detail: errorMessage(error),
                    nextStep: "Selected files were not removed; check the repository state and retry."
                )
            }
        }
    }
}

/// Git.Stage.Toolbar uses `Git.Stash.Silently`: it saves a default WIP stash
/// directly instead of opening the full option dialog. Keep the dialog-backed
/// stash action for the explicit Stash menu, but make the toolbar behavior
/// match rebased exactly.
func stashSilently() {
    guard let repo else { return }
    beginFeedbackOperation("Stash changes")
    Task.detached(priority: .userInitiated) {
        do {
            _ = try repo.stashSave(message: nil)
            let ss = try repo.stashList()
            let st = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.stashes = ss
                self.entries = st
                self.stagingModel = staging
                self.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Changes stashed")
                self.loadRepoData(includeComparisons: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Stash changes failed", detail: errorMessage(error), nextStep: "Check the repository state and retry.")
            }
        }
    }
}

func stashPop(stashID: String, restoreIndex: Bool = false) {
    guard let repo else { return }
    let rootPath = repo.workdir() ?? projectPath ?? ""
    beginFeedbackOperation("Pop stash")
    Task.detached(priority: .userInitiated) {
        do {
            let currentIndex = try currentStashIndex(repo: repo, stashID: stashID)
            try repo.stashPopWithIndex(index: currentIndex, restoreIndex: restoreIndex)
            let ss = try repo.stashList()
            let st = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.stashes = ss; self.entries = st
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: stashID)
                // Pop removes the selected stash. Close the split preview
                // rather than leaving it bound to the next row at the same
                // numeric index.
                self.stashUI.previewStashID = nil
                self.stashUI.previewText = nil
                self.stashUI.showPreview = false
                self.stagingModel = staging
                self.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Stash popped")
                self.loadRepoData(includeComparisons: false)
            }
        } catch {
            if case let .StashApplyConflict(paths, conflictStashID) = error as? EngineError {
                await MainActor.run {
                    self.stashRecovery.popConflictInProgress = true
                    self.stashRecovery.applyConflictInProgress = false
                    self.stashRecovery.pendingConflictNotificationID = nil
                    self.stashRecovery.pendingPopIndex = self.stashes.firstIndex(
                        where: { $0.id == (conflictStashID ?? stashID) }
                    ) ?? 0
                    self.stashRecovery.pendingPopID = conflictStashID ?? stashID
                    self.stashRecovery.pendingPullStashPop = false
                    self.mergeInProgress = true
                    self.mergeInitialPath = paths.first
                    if self.toolWindowMode != .log {
                        self.selection = paths.first
                    }
                    self.fileSelection = nil
                    self.selectionModePath = nil
                    self.commitPreviewPath = nil
                    self.commitPreviewVisible = false
                    self.showMergeRevisionsDialog = true
                    self.mergeFeedback = "Stash pop 冲突：\(paths.joined(separator: ", "))"
                    self.feedbackCenter.error(
                        "Stash pop paused",
                        detail: paths.joined(separator: ", "),
                        nextStep: "解决冲突后点击 Complete Merge/Restore。"
                    )
                    self.refreshAll(showFeedback: false)
                }
            } else {
                await MainActor.run { self.loadError = errorMessage(error) }
            }
        }
    }
}

func stashApply(stashID: String, restoreIndex: Bool = false) {
    guard let repo else { return }
    beginFeedbackOperation("Apply stash")
    Task.detached(priority: .userInitiated) {
        do {
            let currentIndex = try currentStashIndex(repo: repo, stashID: stashID)
            try repo.stashApplyWithIndex(index: currentIndex, restoreIndex: restoreIndex)
            let st = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.entries = st
                self.stagingModel = staging
                self.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Stash applied; stash kept")
                self.loadRepoData(includeComparisons: false)
            }
        } catch {
            if case let .StashApplyConflict(paths, conflictStashID) = error as? EngineError {
                await MainActor.run {
                    self.stashRecovery.popConflictInProgress = false
                    self.stashRecovery.applyConflictInProgress = true
                    self.stashRecovery.pendingConflictNotificationID = nil
                    self.stashRecovery.pendingPopIndex = nil
                    self.stashRecovery.pendingPopID = conflictStashID ?? stashID
                    self.stashRecovery.pendingPullStashPop = false
                    self.mergeInProgress = true
                    self.mergeInitialPath = paths.first
                    if self.toolWindowMode != .log {
                        self.selection = paths.first
                    }
                    self.fileSelection = nil
                    self.selectionModePath = nil
                    self.commitPreviewPath = nil
                    self.commitPreviewVisible = false
                    self.showMergeRevisionsDialog = true
                    self.mergeFeedback = "Stash apply 冲突：\(paths.joined(separator: ", "))"
                    self.feedbackCenter.error(
                        "Stash apply paused",
                        detail: paths.joined(separator: ", "),
                        nextStep: "解决冲突后点击 Complete Stash Apply。"
                    )
                    self.refreshAll(showFeedback: false)
                }
            } else {
                await MainActor.run { self.loadError = errorMessage(error) }
            }
        }
    }
}

func stashDrop(stashID: String) {
    guard let repo else { return }
    let rootPath = repo.workdir() ?? projectPath ?? ""
    beginFeedbackOperation("Drop stash")
    Task.detached(priority: .userInitiated) {
        do {
            let currentIndex = try currentStashIndex(repo: repo, stashID: stashID)
            try repo.stashDrop(index: currentIndex)
            let ss = try repo.stashList()
            await MainActor.run {
                self.stashes = ss
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: stashID)
                // Dropping any row can shift every following stash index;
                // close the preview instead of showing another stash's patch.
                self.stashUI.previewStashID = nil
                self.stashUI.previewText = nil
                self.stashUI.showPreview = false
                self.feedbackCenter.success("Stash dropped")
                self.loadRepoData(includeComparisons: false)
            }
        } catch { await MainActor.run { self.loadError = errorMessage(error) } }
    }
}

func stashBranch(stashID: String) {
    let alert = NSAlert()
    alert.messageText = "Create branch from stash"
    alert.informativeText = "The new branch will be checked out and the stash will be applied."
    let field = NSTextField(string: "stash-branch")
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let branch = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else { return }
    stashBranch(stashID: stashID, branch: branch)
}

func stashBranch(stashID: String, branch: String) {
    guard let repo else { return }
    let rootPath = repo.workdir() ?? projectPath ?? ""
    let notificationID = stashBranchNotificationID(rootPath: rootPath, branch: branch)
    beginFeedbackOperation("Create branch from stash", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        var retry: PersistedStashBranchRetry?
        do {
            let currentStashes = try repo.stashList()
            guard currentStashes.contains(where: { $0.id == stashID }) else {
                throw NSError(
                    domain: "Arbor.StashBranch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The selected stash no longer exists."]
                )
            }
            retry = PersistedStashBranchRetry(
                stashID: stashID,
                branch: branch,
                expectedCurrentBranch: try repo.branchList().first(where: { $0.isCurrent })?.name,
                expectedCurrentHead: repo.headCommitId()
            )
            let currentIndex = try currentStashIndex(repo: repo, stashID: stashID)
            try repo.stashBranch(index: currentIndex, branch: branch)
            let ss = try repo.stashList()
            await MainActor.run {
                self.stashes = ss
                self.clearStashDiffIfMatching(rootPath: rootPath, stashID: stashID)
                self.stashUI.previewStashID = nil
                self.stashUI.previewText = nil
                self.stashUI.showPreview = false
                self.feedbackCenter.success(
                    "Branch created from stash",
                    detail: branch,
                    notificationID: notificationID
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let retryContext = retry
            let canRetry = retryContext.map {
                stashBranchRetryIsCurrentlySafe($0, rootPath: rootPath)
            } ?? false
            await MainActor.run {
                self.feedbackCenter.error(
                    "Create branch from stash failed",
                    detail: errorMessage(error),
                    nextStep: "The stash is kept when Git cannot complete the branch operation. Retry only if the original repository state is unchanged.",
                    additionalActions: canRetry
                        ? (retryContext.map {
                            [self.stashBranchRetryFeedbackAction($0, rootPath: rootPath)]
                        } ?? [])
                        : [],
                    notificationID: notificationID
                )
            }
        }
    }
}

func showStashDiffFor(stashID: String) {
    guard let repo else { return }
    let rootPath = repo.workdir() ?? projectPath ?? ""
    stashUI.diffStashID = stashID
    stashUI.diffRootPath = rootPath
    stashUI.diffText = nil
    stashUI.showDiff = false
    Task.detached(priority: .userInitiated) {
        do {
            let currentIndex = try currentStashIndex(repo: repo, stashID: stashID)
            let diff = try repo.stashDiff(index: currentIndex)
            await MainActor.run {
                guard self.stashUI.diffStashID == stashID,
                      self.stashUI.diffRootPath == rootPath else { return }
                self.stashUI.diffText = diff
                self.stashUI.showDiff = true
            }
        } catch {
            await MainActor.run {
                guard self.stashUI.diffStashID == stashID,
                      self.stashUI.diffRootPath == rootPath else { return }
                self.feedbackCenter.error("Load stash diff failed", detail: errorMessage(error))
            }
        }
    }
}

/// Stash 工作区的内嵌预览入口。与分支弹出菜单使用的文本 sheet 分开，
/// 这样 Commit/Stash 左工作区不会因为查看 diff 而遮住右侧 Log。
func showStashPreviewFor(stashID: String) {
    guard let repo else { return }
    shelfPreviewName = nil
    shelfPreviewText = nil
    showShelfPreview = false
    stashUI.previewStashID = stashID
    stashUI.previewText = nil
    stashUI.showPreview = true
    Task.detached(priority: .userInitiated) {
        do {
            let diff = try repo.stashDiff(
                index: try currentStashIndex(repo: repo, stashID: stashID)
            )
            await MainActor.run {
                guard self.stashUI.showPreview, self.stashUI.previewStashID == stashID else { return }
                self.stashUI.previewText = diff
            }
        } catch {
            await MainActor.run {
                guard self.stashUI.showPreview, self.stashUI.previewStashID == stashID else { return }
                self.stashUI.previewText = "Load stash diff failed: \(errorMessage(error))"
            }
        }
    }
}

/// Resolve the exact stash created by the current preserving process. The
/// stash stack is user-visible and may change while Pull is running, so
/// `stash@{0}` is not a stable identity for an automatic restore.
nonisolated static func pullStashReference(
    repo: Repository,
    stashID: String? = nil,
    message: String?
) throws -> (index: UInt32, stash: StashInfo) {
    let stashes = try repo.stashList()
    if let stashID {
        guard let index = stashes.firstIndex(where: { $0.id == stashID }) else {
            throw NSError(
                domain: "Arbor.Git",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "找不到本次 Pull 保存的临时 stash；现有 stash 已保留。"]
            )
        }
        return (UInt32(index), stashes[index])
    }
    guard let message else {
        throw NSError(
            domain: "Arbor.Git",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "无法确认 Pull 保存的临时 stash；现有 stash 已保留。"]
        )
    }
    guard let index = pullStashIndex(message: message, in: stashes) else {
        throw NSError(
            domain: "Arbor.Git",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "找不到本次 Pull 保存的临时 stash：\(message)"]
        )
    }
    return (UInt32(index), stashes[index])
}

/// dirty-tree pull 的 UI 编排：按保存策略保存本地现场，pull 成功后恢复；
/// pull 进入冲突暂停时保留 stash 或 Shelf，避免把用户变更混进冲突索引。
func stashAndPull(
    remote: String?,
    remoteBranch: String?,
    rebase: Bool,
    pullOptions: PullOptions? = nil,
    autoOpenUpdateInfo: Bool = false,
    onComplete: (() -> Void)? = nil
) {
    guard let repo else { return }
    beginFeedbackOperation(rebase ? "Preserve and pull with rebase" : "Preserve and pull")
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        do {
            let preservation = try Self.saveLocalChangesBeforePull(
                repo: repo,
                policy: savePolicy
            )
            let savedStash = preservation.stashID != nil || preservation.stashMessage != nil
            if let repositoryPath = repo.workdir() {
                savePendingPullPreservation(
                    repositoryPath: repositoryPath,
                    preservation: preservation
                )
            }
            await MainActor.run {
                self.stashRecovery.pendingPullShelfName = preservation.shelfName
                self.stashRecovery.pendingPullStashPop = savedStash
                self.stashRecovery.pendingPullStashID = preservation.stashID
                self.stashRecovery.pendingPullStashMessage = preservation.stashMessage
                self.runPull(
                    remote: remote,
                    remoteBranch: remoteBranch,
                        rebase: rebase,
                        pullOptions: pullOptions,
                        restoreStash: savedStash,
                        restoreStashID: preservation.stashID,
                        restoreStashMessage: preservation.stashMessage,
                        restoreShelf: preservation.shelfName,
                        autoOpenUpdateInfo: autoOpenUpdateInfo,
                        onComplete: onComplete
                )
            }
        } catch {
            await MainActor.run {
                let detail = errorMessage(error)
                if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    self.stashRecovery.pendingPullShelfName = nil
                    self.presentShelveConflict(name: name, paths: paths, isPop: true)
                }
                self.mergeFeedback = detail
                self.feedbackCenter.error("Pull failed before preserving local changes", detail: detail, nextStep: "Check the local worktree and retry.")
            }
        }
    }
}

func popPendingPullStash() {
    guard let repo, stashRecovery.pendingPullStashPop || stashRecovery.pendingPullShelfName != nil else { return }
    let repositoryPath = repo.workdir()
    let shelfName = stashRecovery.pendingPullShelfName
    let stashID = stashRecovery.pendingPullStashID
    let stashMessage = stashRecovery.pendingPullStashMessage
    let pullRebaseSeed = rebaseUndoSeed
    let restoreCancel = GitCancelHandle()
    beginFeedbackOperation(
        shelfName == nil ? "Restore pull stash" : "Restore pull Shelf",
        cancelHandle: restoreCancel
    )
    Task.detached(priority: .userInitiated) {
        var stashRestoreID: String? = stashID
        do {
            if let shelfName {
                try repo.shelvePopWithCancel(name: shelfName, cancel: restoreCancel)
            } else if stashID != nil || stashUI.message != nil {
                let reference = try Self.pullStashReference(
                    repo: repo,
                    stashID: stashID,
                    message: stashUI.message
                )
                stashRestoreID = reference.stash.id
                try repo.stashPopWithIndexAndCancel(
                    index: try currentStashIndex(repo: repo, stashID: reference.stash.id),
                    restoreIndex: true,
                    cancel: restoreCancel
                )
            } else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "无法确认 Pull 保存的临时 stash；现有 stash 已保留。"]
                )
            }
            let pullRebaseRestoreCompleted = pullRebaseSeed != nil
                && (try? repo.operationState()) == nil
            let completedPullRebaseUndoTarget = pullRebaseRestoreCompleted
                ? pullRebaseSeed.flatMap { seed in
                    rebaseUndoTargetAfterCompletion(
                        seed: seed,
                        currentBranch: (try? repo.branchList())?.first(where: { $0.isCurrent })?.name,
                        finalHead: try? repo.revisionCommitId(revision: seed.branch)
                    )
                }
                : nil
            await MainActor.run {
                self.stashRecovery.pendingPullStashPop = false
                self.stashRecovery.pendingPullStashID = nil
                self.stashRecovery.pendingPullStashMessage = nil
                self.stashRecovery.pendingPullShelfName = nil
                if let repositoryPath {
                    clearPendingPullPreservation(repositoryPath: repositoryPath)
                }
                if pullRebaseRestoreCompleted {
                    self.finishPendingPullRebaseRestore(
                        seed: pullRebaseSeed,
                        target: completedPullRebaseUndoTarget
                    )
                }
                self.mergeFeedback = "已恢复 pull 前的本地变更"
                if let completedPullRebaseUndoTarget {
                    self.feedbackCenter.success(
                        "Pull changes restored",
                        additionalActions: [self.rebaseUndoFeedbackAction(for: completedPullRebaseUndoTarget)],
                        notificationID: rebaseUndoNotificationID(
                            repositoryPath: completedPullRebaseUndoTarget.repositoryPath
                        ),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.success("Pull changes restored")
                }
                self.refreshAll(showFeedback: false)
            }
        } catch let error as EngineError {
            let stashRestoreIDValue = stashRestoreID
            await MainActor.run {
                switch error {
                case .Cancelled:
                    let action: FeedbackAction? = {
                        if let shelfName {
                            return self.savedChangesFeedbackAction(kind: .shelf, identifier: shelfName)
                        }
                        if let stashRestoreIDValue {
                            return self.savedChangesFeedbackAction(kind: .stash, identifier: stashRestoreIDValue)
                        }
                        return nil
                    }()
                    let savedKind = shelfName == nil ? "Stash" : "Shelf"
                    self.mergeFeedback = "已取消恢复 pull 前的本地变更，保存的\(savedKind) 已保留"
                    self.feedbackCenter.warning(
                        "Restore pull changes cancelled",
                        detail: self.mergeFeedback ?? "保存的\(savedKind) 已保留",
                        nextStep: "Retry restoring the saved \(savedKind) when ready.",
                        additionalActions: action.map { [$0] } ?? []
                    )
                case let .StashApplyConflict(paths, conflictStashID):
                    self.showStashRestoreConflict(
                        paths,
                        operationName: "Pull",
                        stashID: conflictStashID ?? stashRestoreIDValue
                    )
                case let .ShelveApplyConflict(name, paths):
                    self.stashRecovery.pendingPullShelfName = nil
                    self.presentShelveConflict(name: name, paths: paths, isPop: true)
                default:
                    let detail = errorMessage(error)
                    self.mergeFeedback = detail
                    self.feedbackCenter.error(
                        "Restore pull changes failed",
                        detail: detail,
                        nextStep: "Resolve the local conflict before retrying."
                    )
                }
            }
        } catch {
            await MainActor.run {
                let detail = errorMessage(error)
                self.mergeFeedback = detail
                self.feedbackCenter.error("Restore pull changes failed", detail: detail, nextStep: "Resolve the local conflict before retrying.")
            }
        }
    }
}

}
