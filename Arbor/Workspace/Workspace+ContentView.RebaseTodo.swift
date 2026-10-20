import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Capture Git's complete native todo for the current structured rebase
/// draft. This is the IntelliJ fallback for label/reset/merge, exec, break,
/// update-ref, and any future command that is not a structured row action.
func prepareRawRebaseTodoEditor() {
    guard !isLogAggregate, let repo = logRepository else { return }
    let onto = rebaseWorkspace.todoOnto
    let preserve = rebaseWorkspace.todoPreserveMerges
    let root = rebaseWorkspace.todoRoot
    rebaseWorkspace.showTodoEditor = false
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Prepare Native Rebase Todo", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let raw = try repo.rebaseRawTodoWithOptionsAndPolicyAndCancel(
                onto: onto,
                preserveMerges: preserve,
                autoSquash: false,
                keepEmpty: false,
                updateRefs: false,
                root: root,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.rebaseWorkspace.rawTodoText = raw
                self.rebaseWorkspace.showRawTodoEditor = true
                self.feedbackCenter.success(
                    "Native rebase todo ready",
                    detail: "Git control rows remain editable as text."
                )
            }
        } catch {
            await MainActor.run {
                if case .Cancelled = error as? EngineError {
                    self.operationRecovery.feedback = "Native rebase todo preparation cancelled; local changes were restored"
                    self.feedbackCenter.warning(
                        "Native rebase todo preparation cancelled",
                        detail: self.operationRecovery.feedback ?? "Local changes were restored",
                        nextStep: "Edit the native todo again when the repository is ready."
                    )
                    return
                }
                self.feedbackCenter.error(
                    "Prepare native rebase todo failed",
                    detail: errorMessage(error),
                    nextStep: "The repository must be free of another Git operation; retry after refreshing."
                )
            }
        }
    }
}

/// 按编辑后的 todo 启动 rebase（顺序与 action 为最终权威）。
func startTodoRebase() {
    guard !isLogAggregate else {
        feedbackCenter.warning(
            "Interactive Rebase unavailable in aggregate Log",
            detail: "Rebase edits must be scoped to one Git root.",
            nextStep: "Navigate to one repository before applying the edited todo list."
        )
        return
    }
    guard let repo = logRepository else { return }
    let onto = rebaseWorkspace.todoOnto
    let todo = RebaseTodo(onto: onto, items: rebaseWorkspace.todoItems)
    let preserve = rebaseWorkspace.todoPreserveMerges
    let root = rebaseWorkspace.todoRoot
    let repositoryPath = repo.workdir() ?? ""
    let useInMemory = shouldUseInMemoryCommitEditing(
        settingEnabled: GitInMemoryCommitEditingSettings.isEnabled(),
        items: rebaseWorkspace.todoItems,
        preserveMerges: preserve
    )
    let nativeActions = rebaseWorkspace.todoItems.map { item -> RebaseAction in
        switch item.action {
        case .pick:
            return .pick
        case .drop:
            return .drop
        case .reword:
            return .reword(message: item.message ?? item.summary)
        case .squash:
            if let message = item.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return .squashWithMessage(message: message)
            }
            return .squash
        case .fixup:
            return .fixup
        case .edit:
            return .edit
        }
    }
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Start Interactive Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let branch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let initialHead = branch.flatMap { try? repo.revisionCommitId(revision: $0) }
            let seed = initialHead.flatMap { initialHead in
                branch.map {
                    RebaseUndoSeed(
                        repositoryPath: repositoryPath,
                        branch: $0,
                        initialHead: initialHead,
                        updateRefs: false,
                        protectionCommitID: root
                            ? nil
                            : rebaseUndoProtectionCommitBeforeOperation(
                                repo: repo,
                                initialHead: initialHead,
                                onto: onto
                            )
                    )
                }
            }
            if let seed {
                saveRebaseUndoSeed(seed)
            }
            let runNativeRebase: () throws -> RebaseOutcome = {
                if let branch {
                    return try repo.rebaseBranchWithAdvancedOptionsAndPolicyAndCancel(
                        onto: onto,
                        branch: branch,
                        actions: nativeActions,
                        preserveMerges: preserve,
                        autoSquash: false,
                        keepEmpty: false,
                        updateRefs: false,
                        root: root,
                        savePolicy: projectSavePolicy,
                        cancel: cancel
                    )
                }
                return try repo.rebaseWithAdvancedOptionsAndPolicyAndCancel(
                    onto: onto,
                    actions: nativeActions,
                    preserveMerges: preserve,
                    autoSquash: false,
                    keepEmpty: false,
                    updateRefs: false,
                    root: root,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            }
            let outcome: RebaseOutcome
            if useInMemory {
                let inMemoryOutcome: RebaseOutcome = if root {
                    try repo.rebaseRootWithTodoAndPolicyAndCancel(
                        todo: todo,
                        preserveMerges: preserve,
                        savePolicy: projectSavePolicy,
                        cancel: cancel
                    )
                } else {
                    try repo.rebaseWithTodoAndPolicyAndCancel(
                        onto: onto,
                        todo: todo,
                        preserveMerges: preserve,
                        savePolicy: projectSavePolicy,
                        cancel: cancel
                    )
                }
                if inMemoryOutcome.paused, inMemoryOutcome.pauseReason == .conflict {
                    // The reference implementation discards partial object-level
                    // progress and retries the complete native todo. Abort first:
                    // it restores the original HEAD and the saved local scene,
                    // after which the native runner preserves that scene again.
                    try repo.rebaseAbort()
                    outcome = try runNativeRebase()
                } else {
                    outcome = inMemoryOutcome
                }
            } else {
                outcome = try runNativeRebase()
            }
            let finalHead = seed.flatMap { try? repo.revisionCommitId(revision: $0.branch) }
            let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                self.rebaseWorkspace.showTodoEditor = false
                self.rebaseWorkspace.todoRoot = false
                if outcome.paused {
                    self.rebaseWorkspace.undoSeed = seed
                    self.rebaseWorkspace.undoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.operationRecovery.feedback = outcome.pauseReason == .conflict
                        ? "Rebase 冲突暂停：\(outcome.conflicts.count) 个文件"
                        : "Rebase 在 edit 暂停"
                    self.operationRecovery.showConflictResolver = true
                } else {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = undoTarget
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: String(outcome.headId.prefix(7)),
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success("Rebase completed", detail: String(outcome.headId.prefix(7)))
                    }
                }
                self.refreshAll(showFeedback: false)
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.operationRecovery.feedback = "Rebase 已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Rebase cancelled",
                        detail: self.operationRecovery.feedback ?? "保存的本地现场未被丢弃",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repositoryPath
                        ).map { [$0] } ?? []
                    )
                }
                return
            }
            await MainActor.run {
                if (try? repo.operationState())?.kind != .rebase {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = nil
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                self.feedbackCenter.error(
                    "Rebase failed",
                    detail: errorMessage(error),
                    nextStep: "修正 todo 后重试，或 Abort。",
                    additionalActions: self.pendingSavedChangesFeedbackAction(
                        repo: repo,
                        rootPath: repositoryPath
                    ).map { [$0] } ?? []
                )
            }
        }
    }
}

/// Execute the text edited in Git's native todo format. The engine writes it
/// back through GIT_SEQUENCE_EDITOR and lets Git own every command's native
/// topology and pause semantics.
func startRawTodoRebase() {
    guard !isLogAggregate else {
        feedbackCenter.warning(
            "Interactive Rebase unavailable in aggregate Log",
            detail: "Native todo edits must be scoped to one Git root.",
            nextStep: "Navigate to one repository before applying the edited todo list."
        )
        return
    }
    guard let repo = logRepository else { return }
    let onto = rebaseWorkspace.todoOnto
    let rawTodo = rebaseWorkspace.rawTodoText
    let preserve = rebaseWorkspace.todoPreserveMerges
    let root = rebaseWorkspace.todoRoot
    let repositoryPath = repo.workdir() ?? ""
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Start Native Interactive Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        let messageMonitor = Task.detached(priority: .userInitiated) {
            var sawActiveRebase = false
            while !Task.isCancelled {
                let active = (try? repo.operationState())?.kind == .rebase
                sawActiveRebase = sawActiveRebase || active
                if let pending = try? repo.rebasePendingMessage() {
                    await MainActor.run {
                        guard !self.rebaseWorkspace.showRawMessageEditor else { return }
                        self.rebaseWorkspace.rawMessageRepository = repo
                        self.rebaseWorkspace.rawMessageText = pending
                        self.rebaseWorkspace.showRawMessageEditor = true
                    }
                }
                if sawActiveRebase && !active {
                    await MainActor.run {
                        guard (self.rebaseWorkspace.rawMessageRepository?.workdir() ?? "") == repositoryPath else { return }
                        self.rebaseWorkspace.showRawMessageEditor = false
                        self.rebaseWorkspace.rawMessageRepository = nil
                        self.rebaseWorkspace.rawMessageText = ""
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        do {
            let branch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let initialHead = branch.flatMap { try? repo.revisionCommitId(revision: $0) }
            let seed = initialHead.flatMap { initialHead in
                branch.map {
                    RebaseUndoSeed(
                        repositoryPath: repositoryPath,
                        branch: $0,
                        initialHead: initialHead,
                        updateRefs: false,
                        protectionCommitID: rebaseUndoProtectionCommitBeforeOperation(
                            repo: repo,
                            initialHead: initialHead,
                            onto: onto
                        )
                    )
                }
            }
            if let seed {
                saveRebaseUndoSeed(seed)
            }
            let outcome = try repo.rebaseWithRawTodoAndPolicyAndCancel(
                onto: onto,
                rawTodo: rawTodo,
                preserveMerges: preserve,
                autoSquash: false,
                keepEmpty: false,
                updateRefs: false,
                root: root,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            if !outcome.paused {
                messageMonitor.cancel()
            }
            let finalHead = seed.flatMap { try? repo.revisionCommitId(revision: $0.branch) }
            let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                self.rebaseWorkspace.showRawTodoEditor = false
                self.rebaseWorkspace.rawTodoText = ""
                self.rebaseWorkspace.todoRoot = false
                if outcome.paused {
                    self.rebaseWorkspace.undoSeed = seed
                    self.rebaseWorkspace.undoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.operationRecovery.feedback = outcome.pauseReason == .conflict
                        ? "Native rebase conflict paused: \(outcome.conflicts.count) files"
                        : "Native rebase paused; resolve the operation before continuing"
                    self.operationRecovery.showConflictResolver = true
                } else {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = undoTarget
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: String(outcome.headId.prefix(7)),
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: String(outcome.headId.prefix(7))
                        )
                    }
                }
                self.refreshAll(showFeedback: false)
            }
        } catch {
            messageMonitor.cancel()
            await MainActor.run {
                if case .Cancelled = error as? EngineError {
                    self.operationRecovery.feedback = "Native rebase cancelled; saved local changes were not discarded"
                    self.feedbackCenter.warning(
                        "Native rebase cancelled",
                        detail: self.operationRecovery.feedback ?? "Saved local changes were not discarded",
                        nextStep: "Continue or abort the native rebase, then restore Saved Changes or Stash if it remains pending.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repositoryPath
                        ).map { [$0] } ?? []
                    )
                    return
                }
                if (try? repo.operationState())?.kind != .rebase {
                    self.rebaseWorkspace.undoSeed = nil
                    self.rebaseWorkspace.undoTarget = nil
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                self.feedbackCenter.error(
                    "Native rebase failed",
                    detail: errorMessage(error),
                    nextStep: "Review the Git todo syntax and operation state, then retry or abort.",
                    additionalActions: self.pendingSavedChangesFeedbackAction(
                        repo: repo,
                        rootPath: repositoryPath
                    ).map { [$0] } ?? []
                )
            }
        }
    }
}

/// Complete the commit-message request made by Git's native GIT_EDITOR.
func submitRawRebaseMessage() {
    guard let repo = rebaseWorkspace.rawMessageRepository else { return }
    let message = rebaseWorkspace.rawMessageText
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.warning(
            "Commit message required",
            detail: "A reworded or squashed commit must keep a non-empty message.",
            nextStep: "Enter a commit title and save the message."
        )
        return
    }
    do {
        try repo.rebaseSetPendingMessage(message: message)
        rebaseWorkspace.showRawMessageEditor = false
        rebaseWorkspace.rawMessageRepository = nil
        rebaseWorkspace.rawMessageText = ""
    } catch {
        feedbackCenter.error(
            "Save rebase message failed",
            detail: errorMessage(error),
            nextStep: "Retry while the native rebase message editor is waiting."
        )
    }
}

/// Cancel the native message editor by returning the same non-zero result
/// Git would receive from an IntelliJ unstructured-editor cancellation.
func cancelRawRebaseMessage() {
    guard let repo = rebaseWorkspace.rawMessageRepository else { return }
    do {
        try repo.rebaseCancelPendingMessage()
        rebaseWorkspace.showRawMessageEditor = false
        rebaseWorkspace.rawMessageRepository = nil
        rebaseWorkspace.rawMessageText = ""
    } catch {
        feedbackCenter.error(
            "Cancel rebase message failed",
            detail: errorMessage(error),
            nextStep: "The rebase may already have completed; refresh the operation state."
        )
    }
}

}
