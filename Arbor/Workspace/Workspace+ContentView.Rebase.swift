import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// IntelliJ's ref action group falls back to rebasing the current branch onto
/// the selected commit when no non-current branch ref is attached to it. The
/// reachability check belongs at invocation time because the visible log page
/// may not contain the whole current-branch history.
func rebaseOntoCommitFromLog(_ commit: CommitInfo) {
    guard let rootPath = logReferenceRootPath(for: commit) else {
        feedbackCenter.warning(
            "Rebase unavailable",
            detail: "The selected commit has no Git root.",
            nextStep: "Refresh Git Roots, then retry from the commit history."
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard let currentBranch = try rootRepo.branchList().first(where: \.isCurrent)?.name else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Rebase onto a commit requires the selected root to be on a branch."
                    ]
                )
            }
            let containingBranches = Set(
                try rootRepo.commitContainingBranches(commitId: commit.id)
            )
            guard !containingBranches.contains(currentBranch) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected commit is already contained in the current branch."
                    ]
                )
            }
            await MainActor.run {
                self.rebaseCurrentInRoot(rootPath: rootPath, onto: commit.id)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.warning(
                    "Rebase unavailable",
                    detail: errorMessage(error),
                    nextStep: "Select a commit outside the current branch and retry."
                )
            }
        }
    }
}

/// IntelliJ's auto-squash actions create a normal commit whose message is
/// understood by Git's autosquash rebase. They do not rewrite history
/// immediately; the generated message is presented in the Commit tool window
/// so the user can review, stage, and commit the current local changes. The
/// optional Commit and Rebase executor remains available for that same commit.
func beginAutoSquashCommitFromLog(_ commit: CommitInfo, kind: AutoSquashCommitKind) {
    if isLogAggregate {
        feedbackCenter.warning(
            "Auto-squash unavailable in aggregate Log",
            detail: "The selected commit belongs to a root whose Commit workspace is not active.",
            nextStep: "Navigate to one Git root before creating an autosquash commit."
        )
        return
    }
    if let activeRoot = logActiveRootPath,
       activeRoot != projectPath {
        feedbackCenter.warning(
            "Auto-squash is available in the primary Log root",
            detail: "The nested root Log is read and mutation capable, but its Commit workspace is not yet root-scoped.",
            nextStep: "Switch Log back to the primary repository before creating an autosquash commit."
        )
        return
    }
    guard hasLocalChanges else {
        feedbackCenter.warning(
            "No local changes",
            detail: "\(kind.title) commits need changes to commit.",
            nextStep: "Make or stage changes, then retry."
        )
        return
    }
    let isRootTarget = commit.parentIds.isEmpty
    let isMergeTarget = commit.parentIds.count > 1
    if isMergeTarget {
        feedbackCenter.warning(
            "Merge commit autosquash unavailable",
            detail: "Git autosquash cannot safely target a merge topology row.",
            nextStep: "Use Interactive Rebase with merge preservation to edit the merge history."
        )
        return
    }
    let onto = commit.parentIds.first ?? ""
    let subject = commit.summary
        .split(whereSeparator: { $0.isNewline })
        .first
        .map(String.init) ?? commit.summary
    commitMessage = "\(kind.prefix)! \(subject)"
    pendingAutoSquashRebase = PendingAutoSquashRebase(
        targetID: commit.id,
        onto: onto,
        kind: kind,
        root: isRootTarget
    )
    amendMode = false
    toolWindowMode = .commit
    toolWindowExpanded = true
    projectPanelExpanded = false
    commitFeedback = nil
}

/// Derive the oldest commit in the original rewritten range. IntelliJ uses
/// the first changed commit rather than blindly checking the old tip. The
/// merge-base fallback keeps older persisted Undo actions safe when Git cannot
/// resolve a common ancestor or the original range is no longer available.
nonisolated func rebaseUndoProtectionCommit(
    repo: Repository,
    initialHead: String,
    expectedHead: String,
    recordedCommitID: String?
) -> String {
    if let recordedCommitID,
       !recordedCommitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (try? repo.isCommitReachableFrom(
            commitId: recordedCommitID,
            descendantId: initialHead
        )) == true
            ? recordedCommitID
            : initialHead
    }
    guard initialHead != expectedHead,
          let base = try? repo.mergeBaseRevisionId(
              first: initialHead,
              second: expectedHead
          ),
          let commits = try? repo.logWithCommand(
              commandArgs: ["--reverse", "\(base)..\(initialHead)"],
              limit: 1
          ),
          let firstChangedCommit = commits.first?.id else {
        return initialHead
    }
    return firstChangedCommit
}

/// Match GitSquashedCommitsMessage.prettySquash closely enough for the
/// standalone Log Squash dialog: preserve full messages, remove duplicate
/// entries, and trim fixup!/squash! subjects when their target is selected.
nonisolated func prettySquashMessage(_ commits: [CommitInfo]) -> String {
    let messages = commits.map(completeCommitMessage)
    let subjects = Set(messages.map { message in
        String(message.split(whereSeparator: \.isNewline).first ?? "")
    }.filter { subject in
        !subject.hasPrefix("fixup! ") && !subject.hasPrefix("squash! ")
    })
    var seen = Set<String>()
    let rendered = messages.compactMap { message -> String? in
        let subject = String(message.split(whereSeparator: \.isNewline).first ?? "")
        var value = message
        if subject.hasPrefix("fixup! ") || subject.hasPrefix("squash! ") {
            let target = subject.hasPrefix("fixup! ")
                ? String(subject.dropFirst("fixup! ".count))
                : String(subject.dropFirst("squash! ".count))
            if subjects.contains(target) {
                value = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    .dropFirst()
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !value.isEmpty, seen.insert(value).inserted else { return nil }
        return value
    }
    return rendered.joined(separator: "\n\n\n")
}

/// Run IntelliJ's Commit and Rebase executor after a generated fixup!/squash!
/// commit. Let native interactive rebase apply Git's exact autosquash title
/// matching and ordering rules, then use the same conflict recovery path as
/// interactive rebase.
func startAutoSquashRebase(
    onto: String,
    targetID: String,
    root: Bool
) {
    guard let repo else { return }
    let repositoryPath = repo.workdir() ?? ""
    rebaseUndoSeed = nil
    rebaseUndoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Rebase", cancelHandle: cancel)
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        do {
            // IntelliJ's Commit and Rebase executor starts a native
            // interactive rebase after the fixup!/squash! commit is created.
            // Load the plain range only to validate the target; Git itself is
            // authoritative for autosquash ordering and control semantics.
            let todo: RebaseTodo = if root {
                try repo.rebaseRootTodo(autoSquash: false, preserveMerges: false)
            } else {
                try repo.rebaseTodoWithOptions(
                    onto: onto,
                    autoSquash: false,
                    preserveMerges: false
                )
            }
            guard todo.items.contains(where: { $0.commitId == targetID }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected target commit is not in the current rebase range."
                    ]
                )
            }
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
            let nativeActions = todo.items.map { _ in RebaseAction.pick }
            let outcome = try repo.rebaseWithAdvancedOptionsAndPolicyAndCancel(
                onto: onto,
                actions: nativeActions,
                preserveMerges: false,
                autoSquash: true,
                keepEmpty: false,
                updateRefs: false,
                root: root,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            let st = try repo.status()
            let finalHead = seed.flatMap { try? repo.revisionCommitId(revision: $0.branch) }
            let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                self.entries = st
                self.rebaseRange = []
                self.rebaseActions = []
                self.rebaseTodoItems = []
                self.rebaseTodoRoot = false
                self.showRebaseTodoEditor = false
                self.rebasePaused = outcome.paused
                self.rebasePauseReason = outcome.pauseReason
                self.rebaseConflicts = outcome.conflicts
                if outcome.paused, outcome.pauseReason == .conflict {
                    let names = outcome.conflicts.prefix(3).joined(separator: "、")
                    let suffix = names.isEmpty ? "" : "：\(names)"
                    self.rebaseFeedback = "Autosquash 冲突 \(outcome.conflicts.count) 个文件\(suffix)，请解决后「继续」"
                    self.showMergeRevisionsDialog = true
                } else if outcome.paused {
                    self.rebaseFeedback = "Autosquash 已暂停在 edit 提交，可修改文件后「继续」"
                } else {
                    self.rebaseFeedback = "Autosquash 变基完成"
                }
                self.rebaseUndoSeed = outcome.paused ? seed : nil
                self.rebaseUndoTarget = outcome.paused ? nil : undoTarget
                if outcome.paused {
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                } else {
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                if let undoTarget {
                    self.feedbackCenter.success(
                        "Rebase completed",
                        detail: String(outcome.headId.prefix(7)),
                        additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                        notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                        notificationGroup: .standard
                    )
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.rebaseFeedback = "Autosquash 变基已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Autosquash rebase cancelled",
                        detail: self.rebaseFeedback ?? "保存的本地现场未被丢弃",
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
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = nil
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                let detail = errorMessage(error)
                self.rebaseFeedback = "Autosquash 变基失败：\(detail)"
                self.feedbackCenter.error(
                    "Autosquash rebase failed",
                    detail: detail,
                    nextStep: "Review the rebase target and operation state, then retry or abort.",
                    additionalActions: self.pendingSavedChangesFeedbackAction(
                        repo: repo,
                        rootPath: repositoryPath
                    ).map { [$0] } ?? []
                )
            }
        }
    }
}

/// REBASE-001：从 Log 选中提交发起交互式 rebase。
/// 生成显式 todo（rebase_todo）并打开编辑器；autosquash 在生成时预览。
func interactiveRebaseFromLog(_ commit: CommitInfo) {
    guard let repo = logRepository(for: commit) else { return }
    let root = commit.parentIds.isEmpty
    guard root || interactiveRebaseBaseRevision(for: commit) != nil else {
        feedbackCenter.error(
            "Interactive Rebase unavailable",
            detail: "The selected commit has no usable rebase upstream.",
            nextStep: "Select a commit on the current branch and retry."
        )
        return
    }
    guard !root || (try? repo.isCommitReachableFrom(commitId: commit.id, descendantId: "HEAD")) == true else {
        feedbackCenter.error(
            "Interactive Rebase unavailable",
            detail: "The selected root is not an ancestor of the current branch.",
            nextStep: "Select the current branch root and retry."
        )
        return
    }
    let onto = interactiveRebaseBaseRevision(for: commit) ?? ""
    let preserveMerges = commit.parentIds.count > 1
    beginFeedbackOperation("Interactive Rebase")
    Task.detached(priority: .userInitiated) {
        do {
            let todo: RebaseTodo = if root {
                try repo.rebaseRootTodo(autoSquash: false, preserveMerges: preserveMerges)
            } else {
                try repo.rebaseTodoWithOptions(
                    onto: onto,
                    autoSquash: false,
                    preserveMerges: preserveMerges
                )
            }
            await MainActor.run {
                self.rebaseTodoOnto = onto
                self.rebaseTodoItems = todo.items
                self.rebaseTodoPreserveMerges = preserveMerges
                self.rebaseTodoRoot = root
                self.showRebaseTodoEditor = true
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Interactive Rebase failed", detail: errorMessage(error), nextStep: "无法从该提交生成 todo。")
            }
        }
    }
}

func rebaseUndoRequest(for target: RebaseUndoTarget) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .undoRebase,
        projectPath: projectPath,
        rootPath: target.repositoryPath,
        shelfName: "",
        rebaseUndoInitialHead: target.initialHead,
        rebaseUndoExpectedHead: target.expectedHead,
        rebaseUndoBranch: target.branch,
        rebaseUndoProtectionCommit: target.protectionCommitID
    )
}

func rebaseUndoFeedbackAction(for target: RebaseUndoTarget) -> FeedbackAction {
    let request = rebaseUndoRequest(for: target)
    return FeedbackAction(
        id: "undo-rebase:\(target.repositoryPath):\(target.expectedHead)",
        title: "Undo Rebase",
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

/// Convert the confirmed Squash message into one reword root followed by
/// fixups. The resulting tree is identical to pick+squash, while the root
/// keeps exactly the message edited in the IntelliJ-style dialog.
func submitLogSquash() {
    let message = logSquashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        feedbackCenter.warning(
            "Commit message required",
            detail: "A squashed commit must keep a non-empty message.",
            nextStep: "Enter a combined commit message and retry."
        )
        return
    }
    let indexes = logSquashIndexes.sorted()
    guard let first = indexes.first,
          indexes.count >= 2,
          indexes.allSatisfy({ $0 >= 0 && $0 < rebaseTodoItems.count }) else {
        feedbackCenter.error(
            "Squash unavailable",
            detail: "The selected commits are no longer available in the prepared history range.",
            nextStep: "Refresh the Log and select the commits again."
        )
        showLogSquashDialog = false
        return
    }
    rebaseTodoItems[first].action = .reword
    rebaseTodoItems[first].message = message
    for index in indexes.dropFirst() {
        rebaseTodoItems[index].action = .fixup
        rebaseTodoItems[index].message = nil
    }
    showLogSquashDialog = false
    logSquashIndexes = []
    logSquashSummaries = []
    startTodoRebase()
}

/// Capture Git's complete native todo for the current structured rebase
/// draft. This is the IntelliJ fallback for label/reset/merge, exec, break,
/// update-ref, and any future command that is not a structured row action.
func prepareRawRebaseTodoEditor() {
    guard !isLogAggregate, let repo = logRepository else { return }
    let onto = rebaseTodoOnto
    let preserve = rebaseTodoPreserveMerges
    let root = rebaseTodoRoot
    showRebaseTodoEditor = false
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
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
                self.rebaseRawTodoText = raw
                self.showRawRebaseTodoEditor = true
                self.feedbackCenter.success(
                    "Native rebase todo ready",
                    detail: "Git control rows remain editable as text."
                )
            }
        } catch {
            await MainActor.run {
                if case .Cancelled = error as? EngineError {
                    self.operationFeedback = "Native rebase todo preparation cancelled; local changes were restored"
                    self.feedbackCenter.warning(
                        "Native rebase todo preparation cancelled",
                        detail: self.operationFeedback ?? "Local changes were restored",
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
    let onto = rebaseTodoOnto
    let todo = RebaseTodo(onto: onto, items: rebaseTodoItems)
    let preserve = rebaseTodoPreserveMerges
    let root = rebaseTodoRoot
    let repositoryPath = repo.workdir() ?? ""
    let useInMemory = shouldUseInMemoryCommitEditing(
        settingEnabled: GitInMemoryCommitEditingSettings.isEnabled(),
        items: rebaseTodoItems,
        preserveMerges: preserve
    )
    let nativeActions = rebaseTodoItems.map { item -> RebaseAction in
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
    rebaseUndoSeed = nil
    rebaseUndoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
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
                self.showRebaseTodoEditor = false
                self.rebaseTodoRoot = false
                if outcome.paused {
                    self.rebaseUndoSeed = seed
                    self.rebaseUndoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.operationFeedback = outcome.pauseReason == .conflict
                        ? "Rebase 冲突暂停：\(outcome.conflicts.count) 个文件"
                        : "Rebase 在 edit 暂停"
                    self.showMergeRevisionsDialog = true
                } else {
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = undoTarget
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
                    self.operationFeedback = "Rebase 已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Rebase cancelled",
                        detail: self.operationFeedback ?? "保存的本地现场未被丢弃",
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
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = nil
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
    let onto = rebaseTodoOnto
    let rawTodo = rebaseRawTodoText
    let preserve = rebaseTodoPreserveMerges
    let root = rebaseTodoRoot
    let repositoryPath = repo.workdir() ?? ""
    rebaseUndoSeed = nil
    rebaseUndoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Start Native Interactive Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        let messageMonitor = Task.detached(priority: .userInitiated) {
            var sawActiveRebase = false
            while !Task.isCancelled {
                let active = (try? repo.operationState())?.kind == .rebase
                sawActiveRebase = sawActiveRebase || active
                if let pending = try? repo.rebasePendingMessage() {
                    await MainActor.run {
                        guard !self.showRawRebaseMessageEditor else { return }
                        self.rawRebaseMessageRepository = repo
                        self.rawRebaseMessageText = pending
                        self.showRawRebaseMessageEditor = true
                    }
                }
                if sawActiveRebase && !active {
                    await MainActor.run {
                        guard (self.rawRebaseMessageRepository?.workdir() ?? "") == repositoryPath else { return }
                        self.showRawRebaseMessageEditor = false
                        self.rawRebaseMessageRepository = nil
                        self.rawRebaseMessageText = ""
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
                self.showRawRebaseTodoEditor = false
                self.rebaseRawTodoText = ""
                self.rebaseTodoRoot = false
                if outcome.paused {
                    self.rebaseUndoSeed = seed
                    self.rebaseUndoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.operationFeedback = outcome.pauseReason == .conflict
                        ? "Native rebase conflict paused: \(outcome.conflicts.count) files"
                        : "Native rebase paused; resolve the operation before continuing"
                    self.showMergeRevisionsDialog = true
                } else {
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = undoTarget
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
                    self.operationFeedback = "Native rebase cancelled; saved local changes were not discarded"
                    self.feedbackCenter.warning(
                        "Native rebase cancelled",
                        detail: self.operationFeedback ?? "Saved local changes were not discarded",
                        nextStep: "Continue or abort the native rebase, then restore Saved Changes or Stash if it remains pending.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: repositoryPath
                        ).map { [$0] } ?? []
                    )
                    return
                }
                if (try? repo.operationState())?.kind != .rebase {
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = nil
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
    guard let repo = rawRebaseMessageRepository else { return }
    let message = rawRebaseMessageText
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
        showRawRebaseMessageEditor = false
        rawRebaseMessageRepository = nil
        rawRebaseMessageText = ""
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
    guard let repo = rawRebaseMessageRepository else { return }
    do {
        try repo.rebaseCancelPendingMessage()
        showRawRebaseMessageEditor = false
        rawRebaseMessageRepository = nil
        rawRebaseMessageText = ""
    } catch {
        feedbackCenter.error(
            "Cancel rebase message failed",
            detail: errorMessage(error),
            nextStep: "The rebase may already have completed; refresh the operation state."
        )
    }
}

/// IntelliJ 的 Checkout with Rebase：将选中的本地分支 rebase 到当前分支，
/// 而不是切换后 pull 它自己的 upstream。引擎使用 --autostash，冲突时留下
/// system rebase 状态，由统一 Continue/Skip/Abort 工作台接管。
func checkoutAndRebaseOntoCurrent(repo: Repository, name: String) {
    rebaseUndoTarget = nil
    rebaseUndoSeed = nil
    let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
    let seed = makeRebaseUndoSeed(repo: repo, branch: name, onto: currentBranch)
    if let seed {
        saveRebaseUndoSeed(seed)
        rebaseUndoSeed = seed
    }
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Checkout with Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.rebaseBranchOnCurrentWithPolicyAndCancel(
                branch: name,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.rebaseUndoSeed = nil
                if let seed {
                    clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                }
                self.feedbackCenter.success("Checked out and rebased", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Checkout with Rebase cancelled",
                        detail: "The saved local scene for \(name) was not discarded.",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: seed?.repositoryPath ?? repo.workdir()
                        ).map { [$0] } ?? []
                    )
                }
                return
            }
            let status = (try? repo.status()) ?? []
            let state = try? repo.operationState()
            let firstConflict = status.first {
                $0.staged == .conflicted || $0.unstaged == .conflicted
            }?.path
            await MainActor.run {
                if state?.kind == .rebase {
                    if let seed {
                        self.rebaseUndoSeed = seed
                        saveRebaseUndoSeed(seed)
                    }
                    self.entries = status
                    self.operationState = state
                    self.mergeInProgress = true
                    self.mergeInitialPath = firstConflict
                    self.showMergeRevisionsDialog = true
                    self.feedbackCenter.warning(
                        "Checkout with Rebase paused",
                        detail: errorMessage(error),
                        nextStep: "Resolve conflicts, then Continue or Abort the rebase.",
                        additionalActions: [
                            seed.map {
                                persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)
                            },
                            self.pendingSavedChangesFeedbackAction(
                                repo: repo,
                                rootPath: seed?.repositoryPath ?? repo.workdir()
                            )
                        ].compactMap { $0 },
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    self.rebaseUndoSeed = nil
                    if let seed {
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    self.feedbackCenter.error(
                        "Checkout with Rebase failed",
                        detail: errorMessage(error),
                        nextStep: "检查目标分支与当前仓库状态后重试。",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: repo,
                            rootPath: seed?.repositoryPath ?? repo.workdir()
                        ).map { [$0] } ?? []
                    )
                }
                self.refreshAll(showFeedback: false)
            }
        }
    }
}

/// Route a persisted rebase action back to the root-scoped recovery workbench.
/// The actual Continue/Abort command re-reads Git's operation state, so a
/// notification response cannot replay an obsolete command line.
func openPersistedRebaseRecovery(rootPath: String, branch: String? = nil) {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    guard let seed = loadRebaseUndoSeed(repositoryPath: normalizedRoot) else { return }
    rebaseUndoSeed = seed
    rebaseRootPath = normalizedRoot
    rebaseBranch = branch ?? seed.branch
    rebasePaused = true
    if let persistedRepo = try? openRepository(path: normalizedRoot) {
        let persistedState = try? persistedRepo.operationState()
        operationState = persistedState
        rebasePauseReason = persistedState?.conflictedFiles.isEmpty == false ? .conflict : .edit
        rebaseConflicts = persistedState?.conflictedFiles ?? []
    }
    openMultiRootConflictResolver(preferredRootPath: normalizedRoot)
    if repo?.workdir() == normalizedRoot {
        loadRepoData()
    }
}

func persistedRebaseRecoveryAction(rootPath: String, branch: String) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .resumeRebase,
        projectPath: projectPath ?? rootPath,
        rootPath: rootPath,
        shelfName: "",
        rebaseBranch: branch
    )
    return FeedbackAction(
        title: "Open Rebase Recovery",
        semanticAction: request
    ) {
        self.openPersistedRebaseRecovery(rootPath: rootPath, branch: branch)
    }
}

enum UpdateRebaseOverMergeDecision: Sendable, Equatable {
    case mergeInstead
    case rebaseAnyway
    case cancel
}

/// IntelliJ's Update Project guard: only roots whose local range contains a
/// non-empty merge commit are called out, and the user can substitute merge
/// for those roots without changing the selected rebase method elsewhere.
func presentUpdateRebaseOverMergeDialog(
    problematicRoots: [GitRootInfo]
) -> UpdateRebaseOverMergeDecision {
    let alert = NSAlert()
    alert.messageText = "Rebase would replay merge commits"
    let roots = problematicRoots
        .map { "• \($0.displayName) (\($0.relativePath))" }
        .joined(separator: "\n")
    alert.informativeText = "The following Git roots contain merge commits with file changes in the range that would be rebased:\n\n\(roots)\n\nMerging those roots preserves their merge history."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Merge Instead")
    alert.addButton(withTitle: "Rebase Anyway")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        return .mergeInstead
    case .alertSecondButtonReturn:
        return .rebaseAnyway
    default:
        return .cancel
    }
}

func makeMultiRootRebaseRecoveryRequest(
    _ action: ArborVCSActionRequest.MultiRootRebaseRecoveryAction,
    rootPath: String? = nil,
    sessionID: UUID? = nil,
    rollbackTargets: [MultiRootRebaseRollbackTarget]? = nil
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .multiRootRebaseRecovery,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        multiRootRebaseRecoveryAction: action,
        multiRootRebaseSessionID: sessionID?.uuidString,
        multiRootRebaseRollbackTargets: rollbackTargets?.map(PersistedMultiRootRebaseRollbackTarget.init)
    )
}

func multiRootRebaseRecoveryFeedbackAction(
    _ action: ArborVCSActionRequest.MultiRootRebaseRecoveryAction,
    rootPath: String? = nil,
    sessionID: UUID? = nil,
    rollbackTargets: [MultiRootRebaseRollbackTarget]? = nil
) -> FeedbackAction {
    let request = makeMultiRootRebaseRecoveryRequest(
        action,
        rootPath: rootPath,
        sessionID: sessionID,
        rollbackTargets: rollbackTargets
    )
    let title: String
    switch action {
    case .resume:
        title = "Resume Rebase"
    case .retry:
        title = "Retry Rebase"
    case .stageAndRetry:
        title = "Stage-and-Retry"
    case .openRecovery:
        title = "Open Recovery"
    case .rollback:
        title = "Rollback Rebase"
    case .keepPartial:
        title = "Keep Partial Rebase"
    case .undo:
        title = "Undo Rebase"
    }
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func multiRootRebaseNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-rebase.\(stableProject)"
}

/// IntelliJ 的多 root Branches Popup 语义：非当前本地分支 rebase 到当前分支，
/// 而不是 checkout 后 pull 该分支自己的 upstream。远程分支需先检出为本地分支。
func executeMultiRootCheckoutWithRebase(rootPath: String, branch: String) {
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.warning("Checkout with Rebase cancelled", detail: "A local branch is required.")
        return
    }
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Checkout with Rebase", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        let rootRepo: Repository
        do {
            rootRepo = try openRepository(path: rootPath)
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Checkout with Rebase failed",
                    detail: "\(branch): \(errorMessage(error))",
                    nextStep: "Resolve the selected root's status, then retry Checkout with Rebase."
                )
            }
            return
        }
        let currentBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name
        let seed = makeRebaseUndoSeed(repo: rootRepo, branch: branch, onto: currentBranch)
        if let seed {
            saveRebaseUndoSeed(seed)
        }
        do {
            try rootRepo.rebaseBranchOnCurrentWithPolicyAndCancel(
                branch: branch,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                if let seed {
                    clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    if self.repo?.workdir() == seed.repositoryPath {
                        self.rebaseUndoSeed = nil
                    }
                }
                self.feedbackCenter.success("Checked out and rebased", detail: branch)
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Checkout with Rebase cancelled",
                        detail: "The saved local scene for \(branch) was not discarded.",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: rootRepo,
                            rootPath: rootPath
                        ).map { [$0] } ?? []
                    )
                }
                return
            }
            let state = try? rootRepo.operationState()
            await MainActor.run {
                self.operationsViewMode = .roots
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                if state?.kind == .rebase {
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.feedbackCenter.warning(
                        "Checkout with Rebase paused",
                        detail: "\(branch): \(errorMessage(error))",
                        nextStep: "Resolve the selected root's rebase, then continue or abort it.",
                        additionalActions: [
                            seed.map {
                                persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)
                            },
                            self.pendingSavedChangesFeedbackAction(
                                repo: rootRepo,
                                rootPath: rootPath
                            )
                        ].compactMap { $0 },
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    if let seed {
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    self.feedbackCenter.error(
                        "Checkout with Rebase failed",
                        detail: "\(branch): \(errorMessage(error))",
                        nextStep: "Resolve the selected root's status, then retry Checkout with Rebase.",
                        additionalActions: self.pendingSavedChangesFeedbackAction(
                            repo: rootRepo,
                            rootPath: rootPath
                        ).map { [$0] } ?? []
                    )
                }
                self.loadMultiRoots()
            }
        }
    }
}

func stageAndRetryMultiRootRebaseContinue(rootPath: String, sessionID: UUID) {
    guard multiRootRebaseSession?.id == sessionID else { return }
    runMultiRootResolverRecovery(
        rootPath: rootPath,
        action: .continueOperation,
        stageTrackedBeforeContinue: true
    )
}

/// Finish the remote Checkout with Rebase workflow after the user confirms
/// the local branch name in the shared New Branch dialog. Reuse the existing
/// checkout-with-rebase recovery path so conflicts remain resumable instead
/// of becoming an untracked background failure.
func branchCreateAndRebase(
    at baseRevision: String? = nil,
    reset: Bool = false,
    repository repositoryOverride: Repository? = nil
) {
    guard let targetRepo = repositoryOverride ?? newBranchRepositoryOverride ?? repo else { return }
    let name = GitBranchNameCleanup.cleanUp(newBranchName)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let base = baseRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let existingBranches = try? targetRepo.branchList() else {
        feedbackCenter.error(
            "Checkout with Rebase failed",
            detail: "Unable to inspect the selected repository's local branches."
        )
        return
    }
    guard existingBranches.first(where: { $0.isCurrent })?.name != name else {
        feedbackCenter.error(
            "Checkout with Rebase failed",
            detail: "The branch '\(name)' is already checked out."
        )
        return
    }
    let branchAlreadyExists = existingBranches.contains { $0.name == name }
    guard !reset || confirmBranchResetIfNeeded(
        repo: targetRepo,
        name: name,
        startPoint: base
    ) else { return }
    beginFeedbackOperation("Create branch for Checkout with Rebase")
    Task.detached(priority: .userInitiated) {
        do {
            let startPoint = base?.isEmpty == true ? nil : base
            // Keep the original branch checked out while the rebase starts.
            // `rebaseBranchOnCurrentWithPolicy` deliberately rejects a target
            // that is already HEAD; the native operation then switches the
            // newly rebased branch into HEAD as IntelliJ does.
            // An existing local branch is intentionally reused when Reset is
            // off. IntelliJ's remote Checkout with Rebase workflow only
            // creates the branch for roots that do not already have it.
            if branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: branchAlreadyExists,
                resetExisting: reset
            ) {
                try targetRepo.branchCreateOrReset(
                    name: name,
                    at: startPoint,
                    checkout: false,
                    reset: reset
                )
            }
            let bs = try targetRepo.branchList()
            await MainActor.run {
                if self.repo?.workdir() == targetRepo.workdir() {
                    self.branches = bs
                    self.loadRepoData()
                } else {
                    self.loadMultiRoots()
                }
                self.newBranchName = ""
                self.newBranchBase = ""
                if self.toolWindowMode == .log { self.loadLog() }
                self.checkoutAndRebaseOntoCurrent(repo: targetRepo, name: name)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Checkout with Rebase failed",
                    detail: errorMessage(error),
                    nextStep: "Check the branch name and working tree, then retry."
                )
            }
        }
    }
}

/// 多 root Branches Popup 的 Rebase Current onto：先生成该 root 当前分支的
/// explicit todo，再交给引擎执行，保持与单 root Rebase 对话框相同的历史语义。
func rebaseCurrentInRoot(rootPath: String, onto: String) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Rebase branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let seed = try rootRepo.branchList()
                .first(where: { $0.isCurrent })
                .flatMap { makeRebaseUndoSeed(repo: rootRepo, branch: $0.name, onto: onto) }
            if let seed {
                saveRebaseUndoSeed(seed)
            }
            let todo = try rootRepo.rebaseTodo(onto: onto, autoSquash: false)
            let outcome = try rootRepo.rebaseWithTodoAndPolicyAndCancel(
                onto: onto,
                todo: todo,
                preserveMerges: false,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            let finalHead = seed.flatMap { try? rootRepo.revisionCommitId(revision: $0.branch) }
            let currentBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                self.loadMultiRoots()
                if outcome.paused {
                    if let seed {
                        self.rebaseUndoSeed = seed
                        saveRebaseUndoSeed(seed)
                    }
                    self.feedbackCenter.warning(
                        "Rebase paused",
                        detail: "\(onto) · \(rootPath): \(outcome.conflicts.count) conflict(s)",
                        nextStep: "Resolve conflicts in that root, then use Continue, Skip, or Abort in Git Roots.",
                        additionalActions: seed.map {
                            [persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)]
                        } ?? [],
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    if let seed {
                        self.rebaseUndoSeed = nil
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase completed",
                            detail: "\(onto) · \(rootPath)",
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(
                                repositoryPath: undoTarget.repositoryPath
                            ),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success("Rebase completed", detail: "\(onto) · \(rootPath)")
                    }
                }
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Rebase cancelled",
                        detail: "The saved local scene for \(rootPath) was not discarded.",
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry."
                    )
                }
                return
            }
            let rootRepo = try? openRepository(path: rootPath)
            let state = rootRepo.flatMap { try? $0.operationState() }
            let seed = rootRepo?.workdir().flatMap {
                loadRebaseUndoSeed(repositoryPath: $0)
            }
            await MainActor.run {
                self.loadMultiRoots()
                if state?.kind == .rebase {
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.feedbackCenter.warning(
                        "Rebase paused",
                        detail: "\(onto) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Resolve conflicts in that root, then use Continue, Skip, or Abort in Git Roots.",
                        additionalActions: seed.map {
                            [persistedRebaseRecoveryAction(rootPath: $0.repositoryPath, branch: $0.branch)]
                        } ?? [],
                        notificationID: seed.map { rebaseRecoveryNotificationID(repositoryPath: $0.repositoryPath) }
                    )
                } else {
                    if let seed {
                        self.rebaseUndoSeed = nil
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    self.feedbackCenter.error(
                        "Rebase failed",
                        detail: "\(onto) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Check the target root status, then retry Rebase."
                    )
                }
            }
        }
    }
}

func rebaseActionBinding(_ index: Int) -> Binding<RebaseAction> {
    Binding(
        get: { self.rebaseActions[index] },
        set: { self.rebaseActions[index] = $0 }
    )
}

func loadRebaseRange() {
    rebaseRangeGeneration += 1
    let generation = rebaseRangeGeneration
    guard let repo else {
        rebaseRange = []
        rebaseActions = []
        return
    }
    let onto = rebaseOnto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = rebaseRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = rebaseRoot
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root) else {
        rebaseRange = []
        rebaseActions = []
        return
    }
    let preserveMerges = rebasePreserveMerges
    let currentRepositoryPath = repo.workdir() ?? ""
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            let range = try selectedRepo.rebaseRangeForBranch(
                onto: onto,
                preserveMerges: preserveMerges,
                root: root,
                branch: branch
            )
            await MainActor.run {
                guard rebaseRangeRequestIsCurrent(
                    generation: generation,
                    currentGeneration: self.rebaseRangeGeneration,
                    requestedOnto: onto,
                    currentOnto: self.rebaseOnto,
                    requestedPreserveMerges: preserveMerges,
                    currentPreserveMerges: self.rebasePreserveMerges,
                    requestedRoot: root,
                    currentRoot: self.rebaseRoot,
                    requestedBranch: branch,
                    currentBranch: self.rebaseBranch,
                    requestedRepositoryPath: repositoryPath,
                    currentRepositoryPath: self.rebaseRootPath
                ) else { return }
                self.rebaseRange = range
                self.rebaseActions = Array(repeating: .pick, count: range.count)
                self.rebaseFeedback = "范围 \(range.count) 个提交"
            }
        } catch {
            await MainActor.run {
                guard rebaseRangeRequestIsCurrent(
                    generation: generation,
                    currentGeneration: self.rebaseRangeGeneration,
                    requestedOnto: onto,
                    currentOnto: self.rebaseOnto,
                    requestedPreserveMerges: preserveMerges,
                    currentPreserveMerges: self.rebasePreserveMerges,
                    requestedRoot: root,
                    currentRoot: self.rebaseRoot,
                    requestedBranch: branch,
                    currentBranch: self.rebaseBranch,
                    requestedRepositoryPath: repositoryPath,
                    currentRepositoryPath: self.rebaseRootPath
                ) else { return }
                self.rebaseRange = []
                self.rebaseActions = []
                self.rebaseFeedback = "\(error)"
            }
        }
    }
}

func invalidateLoadedRebaseRange() {
    rebaseRangeGeneration += 1
    rebaseRange = []
    rebaseActions = []
    rebaseFeedback = nil
}

func doRebase() {
    guard operationState?.kind == nil,
          isArborVCSActionEnabled(.rebase, in: vcsActionContext),
          let repo else { return }
    let interactive = rebaseInteractive
    guard !interactive || !rebaseActions.isEmpty else { return }
    let onto = rebaseOnto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = rebaseRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = rebaseRoot
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root) else { return }
    let currentRepositoryPath = repo.workdir() ?? ""
    let persistedRepositoryPath = repositoryPath.isEmpty ? currentRepositoryPath : repositoryPath
    rebaseRangeGeneration += 1
    rebaseUndoSeed = nil
    rebaseUndoTarget = nil
    clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Rebase", cancelHandle: cancel)
    let actions = rebaseActions
    let preserveMerges = rebasePreserveMerges
    let autoSquash = rebaseAutoSquash
    let keepEmpty = rebaseKeepEmpty
    let updateRefs = rebaseUpdateRefs
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    rebaseRetryContext = RebaseRetryContext(
        repositoryPath: repositoryPath,
        branch: branch,
        onto: onto,
        actions: actions,
        interactive: interactive,
        preserveMerges: preserveMerges,
        autoSquash: autoSquash,
        keepEmpty: keepEmpty,
        updateRefs: updateRefs,
        root: root
    )
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            let initialHead = try? selectedRepo.revisionCommitId(revision: branch)
            let undoSeed = initialHead.map {
                RebaseUndoSeed(
                    repositoryPath: persistedRepositoryPath,
                    branch: branch,
                    initialHead: $0,
                    updateRefs: updateRefs,
                    protectionCommitID: rebaseUndoProtectionCommitBeforeOperation(
                        repo: selectedRepo,
                        initialHead: $0,
                        onto: onto
                    )
                )
            }
            if let undoSeed {
                await MainActor.run {
                    self.rebaseUndoSeed = undoSeed
                    saveRebaseUndoSeed(undoSeed)
                }
            }
            let outcome: RebaseOutcome
            if interactive {
                outcome = try selectedRepo.rebaseBranchWithAdvancedOptionsAndPolicyAndCancel(
                    onto: onto,
                    branch: branch,
                    actions: actions,
                    preserveMerges: preserveMerges,
                    autoSquash: autoSquash,
                    keepEmpty: keepEmpty,
                    updateRefs: updateRefs,
                    root: root,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            } else {
                outcome = try selectedRepo.rebaseBranchWithOptionsAndPolicyAndCancel(
                    onto: onto,
                    branch: branch,
                    preserveMerges: preserveMerges,
                    autoSquash: autoSquash,
                    keepEmpty: keepEmpty,
                    updateRefs: updateRefs,
                    root: root,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            }
            let st = try selectedRepo.status()
            let finalHead = try? selectedRepo.revisionCommitId(revision: branch)
            let currentBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: undoSeed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    self.entries = st
                }
                if outcome.paused {
                    self.rebaseRetryContext = nil
                    let pausedSeed = undoSeed
                    self.rebaseUndoSeed = pausedSeed
                    if let pausedSeed {
                        saveRebaseUndoSeed(pausedSeed)
                    } else {
                        clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
                    }
                    self.rebaseUndoTarget = nil
                    self.rebasePaused = true
                    self.rebasePauseReason = outcome.pauseReason
                    self.rebaseConflicts = outcome.conflicts
                    if outcome.pauseReason == .conflict {
                        let names = outcome.conflicts.prefix(3).joined(separator: "、")
                        let suffix = names.isEmpty ? "" : "：\(names)"
                        self.rebaseFeedback = "冲突 \(outcome.conflicts.count) 个文件\(suffix)，请在状态页解决后「继续」"
                        self.showMergeRevisionsDialog = true
                    } else {
                        self.rebaseFeedback = "已暂停在 edit 提交，可修改文件后「继续」"
                    }
                    self.rebaseRange = []
                    self.rebaseActions = []
                } else {
                    self.rebaseRetryContext = nil
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = undoTarget
                    clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
                    self.rebasePaused = false
                    self.rebasePauseReason = nil
                    self.rebaseConflicts = []
                    self.rebaseFeedback = "变基完成"
                    self.rebaseRange = []
                    self.rebaseActions = []
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
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.rebaseFeedback = "变基已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Rebase cancelled",
                        detail: self.rebaseFeedback ?? detail,
                        nextStep: "Check Saved Changes or Stash, restore any pending local scene, then retry if needed."
                    )
                }
                return
            }
            // Re-running the original command is unsafe while Git has an
            // unfinished operation in the worktree. The recovery bar owns
            // Continue/Abort in that case; Retry is only offered for a clean
            // failed start.
            let operationStillActive: Bool
            do {
                let operationRepo: Repository
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    operationRepo = repo
                } else {
                    operationRepo = try openRepository(path: repositoryPath)
                }
                operationStillActive = try operationRepo.operationState() != nil
            } catch {
                // Do not offer a destructive retry when the recovery state
                // itself cannot be inspected.
                operationStillActive = true
            }
            await MainActor.run {
                self.rebaseFeedback = detail
                if operationStillActive {
                    self.feedbackCenter.error(
                        "Rebase failed",
                        detail: detail,
                        nextStep: "Resolve conflicts, then Continue or Abort the rebase."
                    )
                } else {
                    self.rebaseUndoSeed = nil
                    clearRebaseUndoSeed(repositoryPath: persistedRepositoryPath)
                    self.feedbackCenter.error(
                        "Rebase failed",
                        detail: detail,
                        nextStep: "Resolve the cause and retry, or Abort if Git left an operation in progress.",
                        actionTitle: "Retry",
                        action: { self.retryLastRebase() }
                    )
                }
            }
        }
    }
}

func retryLastRebase() {
    guard let context = rebaseRetryContext else { return }
    rebaseRootPath = context.repositoryPath
    rebaseBranch = context.branch
    rebaseOnto = context.onto
    rebaseActions = context.actions
    rebaseInteractive = context.interactive
    rebasePreserveMerges = context.preserveMerges
    rebaseAutoSquash = context.autoSquash
    rebaseKeepEmpty = context.keepEmpty
    rebaseUpdateRefs = context.updateRefs
    rebaseRoot = context.root
    doRebase()
}

/// Undo only a completed single-root rebase whose target branch still points
/// at the exact HEAD produced by that operation.  This is the same safety
/// boundary as IntelliJ's notification actions: a later fetch, commit, push,
/// branch switch, active Git operation, or protected-remote publication
/// invalidates the action.
func undoLastRebase(_ requestedTarget: RebaseUndoTarget? = nil) {
    guard let target = requestedTarget ?? rebaseUndoTarget else { return }
    let protectedPatterns = effectiveProtectedBranchPatterns
    let notificationID = rebaseUndoNotificationID(repositoryPath: target.repositoryPath)
    beginFeedbackOperation("Undo Rebase", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo = try openRepository(path: target.repositoryPath)
            guard try selectedRepo.operationState() == nil else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The rebase Undo action is unavailable while another Git operation is active."
                    ]
                )
            }
            let currentBranch = (try selectedRepo.branchList()).first(where: { $0.isCurrent })?.name
            guard currentBranch == target.branch,
                  try selectedRepo.revisionCommitId(revision: target.branch) == target.expectedHead else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The branch changed after the rebase; the Undo action is no longer safe."
                    ]
                )
            }
            let remoteBranches = try selectedRepo.remoteBranchList()
            let protectedCommitID = rebaseUndoProtectionCommit(
                repo: selectedRepo,
                initialHead: target.initialHead,
                expectedHead: target.expectedHead,
                recordedCommitID: target.protectionCommitID
            )
            if let protectedBranch = protectedRemoteBranchContainingCommit(
                repo: selectedRepo,
                commitID: protectedCommitID,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            ) {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The rebase Undo action is blocked: \(protectedBranch) contains published pre-rebase history."
                    ]
                )
            }
            try selectedRepo.reset(commitId: target.initialHead, mode: .keep)
            await MainActor.run {
                self.feedbackCenter.expire(notificationID: notificationID)
                if self.rebaseUndoTarget?.expectedHead == target.expectedHead {
                    self.rebaseUndoTarget = nil
                }
                clearRebaseUndoSeed(repositoryPath: target.repositoryPath)
                self.feedbackCenter.success(
                    "Rebase undone",
                    detail: target.branch + " restored to " + String(target.initialHead.prefix(7))
                )
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo Rebase failed",
                    detail: errorMessage(error),
                    nextStep: "The branch or published history may have changed; inspect the Log before trying another reset.",
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Prepare one independent todo list per root before starting a batch rebase.
/// The preparation step is intentionally separate from execution so a user
/// can inspect every root's range and fix an invalid branch/ref before any
/// repository is rewritten.
func prepareMultiRootRebaseEditor() {
    guard !multiRoots.isEmpty else { return }
    let onto = rebaseOnto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootMode = rebaseRoot
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: rootMode) else { return }

    let roots = multiRoots
    let preserveMerges = rebasePreserveMerges
    beginFeedbackOperation("Prepare multi-root rebase")
    Task.detached(priority: .userInitiated) {
        var drafts: [MultiRootRebaseTodoDraft] = []
        for root in roots {
            do {
                let rootRepo = try openRepository(path: root.path)
                let todo = try rootRepo.rebaseTodoForBranchWithOptions(
                    onto: onto,
                    // Keep the initial visible rows in native commit order;
                    // later edits carry their commit identities in the
                    // structured multi-root spec.
                    autoSquash: false,
                    preserveMerges: preserveMerges,
                    root: rootMode,
                    branch: branch
                )
                drafts.append(
                    MultiRootRebaseTodoDraft(
                        rootPath: root.path,
                        displayName: root.displayName,
                        items: todo.items,
                        rawTodo: nil,
                        loadError: nil
                    )
                )
            } catch {
                drafts.append(
                    MultiRootRebaseTodoDraft(
                        rootPath: root.path,
                        displayName: root.displayName,
                        items: [],
                        rawTodo: nil,
                        loadError: errorMessage(error)
                    )
                )
            }
        }
        let preparedDrafts = drafts
        await MainActor.run {
            self.multiRootRebaseDrafts = preparedDrafts
            self.showMultiRootRebaseEditor = true
            let failures = preparedDrafts.filter { $0.loadError != nil }
            if failures.isEmpty {
                let count = preparedDrafts.reduce(0) { $0 + $1.items.count }
                self.feedbackCenter.success(
                    "Multi-root rebase prepared",
                    detail: String(count) + " commits across " + String(preparedDrafts.count) + " repositories"
                )
            } else {
                self.feedbackCenter.error(
                    "Multi-root rebase range incomplete",
                    detail: failures.map { "\($0.displayName): \($0.loadError ?? "Unknown error")" }.joined(separator: "\n"),
                    nextStep: "Fix the branch or onto revision, then reload the ranges."
                )
            }
        }
    }
}

/// Execute the edited per-root todo lists as one dependency-ordered batch.
/// The Rust engine stops at the first paused/failed root and returns the
/// already completed and skipped roots for the same partial-result model as
/// IntelliJ's GitRebaseSpec/GitRebaseProcess.
func doMultiRootRebase(drafts: [MultiRootRebaseTodoDraft]?) {
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    guard let projectPath, !multiRoots.isEmpty else { return }
    let onto = rebaseOnto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootMode = rebaseRoot
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: rootMode) else { return }

    let draftsByPath = Dictionary(uniqueKeysWithValues: (drafts ?? []).map { ($0.rootPath, $0) })
    if rebaseInteractive {
        guard multiRoots.allSatisfy({
            guard let draft = draftsByPath[$0.path] else { return false }
            return draft.loadError == nil && !draft.items.isEmpty
        }) else {
            feedbackCenter.error(
                "Multi-root rebase is not ready",
                detail: "Every repository must have a loaded, non-empty todo list.",
                nextStep: "Reload the ranges and review each repository before starting."
            )
            return
        }
    }

    let savePolicyRaw = GitLocalChangesSavePolicySettings.choice(for: projectPath).rawValue
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)

    let specs = multiRoots.compactMap { root -> MultiRootRebaseSpec? in
        let actions: [RebaseAction]
        if rebaseInteractive {
            guard let draft = draftsByPath[root.path] else { return nil }
            actions = draft.items.map { item -> RebaseAction in
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
        } else {
            actions = []
        }
        return MultiRootRebaseSpec(
            rootPath: root.path,
            branch: branch,
            onto: onto,
            actions: actions,
            orderedCommitIds: rebaseInteractive
                && rebasePreserveMerges
                && draftsByPath[root.path]?.rawTodo == nil
                ? (draftsByPath[root.path]?.items.map(\.commitId) ?? [])
                : [],
            rawTodo: draftsByPath[root.path]?.rawTodo,
            preserveMerges: rebasePreserveMerges,
            autoSquash: rebaseAutoSquash,
            keepEmpty: rebaseKeepEmpty,
            updateRefs: rebaseUpdateRefs,
            root: rootMode,
            interactive: rebaseInteractive,
            savePolicy: savePolicy
        )
    }
    guard specs.count == multiRoots.count else { return }

    let session = MultiRootRebaseSession(
        projectPath: projectPath,
        roots: specs.map { spec in
            let displayName = multiRoots.first(where: { $0.path == spec.rootPath })?.displayName
                ?? URL(fileURLWithPath: spec.rootPath).lastPathComponent
            return MultiRootRebaseSessionRoot(
                rootPath: spec.rootPath,
                displayName: displayName,
                branch: spec.branch,
                onto: spec.onto,
                actions: spec.actions.map(PersistedRebaseAction.init),
                orderedCommitIds: spec.orderedCommitIds.isEmpty ? nil : spec.orderedCommitIds,
                rawTodo: spec.rawTodo,
                preserveMerges: spec.preserveMerges,
                autoSquash: spec.autoSquash,
                keepEmpty: spec.keepEmpty,
                updateRefs: spec.updateRefs,
                root: spec.root,
                savePolicyRaw: savePolicyRaw,
                state: .pending,
                initialHead: nil,
                expectedHead: nil,
                initialBranch: nil,
                message: ""
            )
        }
    )
    multiRootRebaseSession = session
    saveMultiRootRebaseSession(session)
    rebaseRangeGeneration += 1
    runPendingMultiRootRebase(session)
}

func multiRootRebaseSessionKey(projectPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.multiRootRebase.session.v1.\(encoded)"
}

func saveMultiRootRebaseSession(_ session: MultiRootRebaseSession) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    UserDefaults.standard.set(data, forKey: multiRootRebaseSessionKey(projectPath: session.projectPath))
}

func loadMultiRootRebaseSession(projectPath: String) -> MultiRootRebaseSession? {
    let key = multiRootRebaseSessionKey(projectPath: projectPath)
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(MultiRootRebaseSession.self, from: data)
}

func clearMultiRootRebaseSession(_ session: MultiRootRebaseSession) {
    UserDefaults.standard.removeObject(forKey: multiRootRebaseSessionKey(projectPath: session.projectPath))
}

func multiRootRebaseRows(for session: MultiRootRebaseSession) -> [RootOperationResult] {
    session.roots.map { root in
        switch root.state {
        case .pending:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: true,
                skipped: true,
                message: root.message.isEmpty ? "not attempted yet" : root.message
            )
        case .completed:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: true,
                skipped: false,
                message: root.message.isEmpty ? "rebase completed" : root.message
            )
        case .paused:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: true,
                skipped: false,
                message: root.message.isEmpty ? "rebase paused" : root.message
            )
        case .failed:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: false,
                skipped: false,
                message: root.message.isEmpty ? "rebase failed" : root.message
            )
        case .aborted:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: false,
                skipped: false,
                message: root.message.isEmpty ? "rebase aborted" : root.message
            )
        }
    }
}

func multiRootRebaseFeedbackResultRows(
    for session: MultiRootRebaseSession
) -> [FeedbackResultRow] {
    let pausedRootPaths = Set(
        session.roots
            .filter { $0.state == .paused }
            .map(\.rootPath)
    )
    return feedbackResultRows(
        from: multiRootRebaseRows(for: session),
        partialRootPaths: pausedRootPaths
    )
}

func updateMultiRootRebaseSession(
    _ session: MultiRootRebaseSession,
    with results: [MultiRootRebaseResult]
) -> MultiRootRebaseSession {
    var updated = session
    for result in results {
        guard let index = updated.roots.firstIndex(where: { $0.rootPath == result.rootPath }) else { continue }
        var root = updated.roots[index]
        root.initialHead = result.initialHead ?? root.initialHead
        root.expectedHead = result.finalHead ?? root.expectedHead
        root.initialBranch = result.initialBranch ?? root.initialBranch
        root.message = result.message
        if result.skipped {
            updated.roots[index] = root
            continue
        }
        if result.requiresFinish {
            root.state = .paused
        } else if result.success && result.completed {
            root.state = .completed
        } else {
            root.state = .failed
        }
        updated.roots[index] = root
    }
    return updated
}

func multiRootRebaseRollbackTargets(
    for session: MultiRootRebaseSession,
    completedOnly: Bool = true
) -> [MultiRootRebaseRollbackTarget] {
    session.roots.compactMap { root -> MultiRootRebaseRollbackTarget? in
        guard (!completedOnly || root.state == .completed),
              let initialHead = root.initialHead,
              let expectedHead = root.expectedHead,
              initialHead != expectedHead else { return nil }
        return MultiRootRebaseRollbackTarget(
            rootPath: root.rootPath,
            displayName: root.displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            branch: root.branch,
            protectionCommitID: root.protectionCommitID
        )
    }
}

func runPendingMultiRootRebase(_ session: MultiRootRebaseSession) {
    guard !multiRootRunning else { return }
    let pendingRoots = session.roots.filter { $0.state == .pending }
    guard !pendingRoots.isEmpty else { return }
    let specs = pendingRoots.map { $0.makeSpec() }
    let sessionID = session.id
    let cancel = GitCancelHandle()
    multiRootRunning = true
    beginFeedbackOperation(
        "Multi-root Rebase",
        cancelHandle: cancel,
        notificationID: multiRootRebaseNotificationID()
    )
    if session.roots.contains(where: { $0.state != .pending }) {
        feedbackCenter.attachResultRows(
            multiRootRebaseFeedbackResultRows(for: session),
            notificationID: multiRootRebaseNotificationID()
        )
    }
    Task.detached(priority: .userInitiated) {
        var activeRootPath: String?
        for root in pendingRoots {
            if let rootRepo = try? openRepository(path: root.rootPath),
               (try? rootRepo.operationState()) != nil {
                activeRootPath = root.rootPath
                break
            }
        }
        if let activeRootPath {
            if let activeRepo = try? openRepository(path: activeRootPath) {
                Task.detached(priority: .userInitiated) {
                    while !Task.isCancelled {
                        if let pending = try? activeRepo.rebasePendingMessage() {
                            await MainActor.run {
                                guard self.multiRootRebaseSession?.id == sessionID,
                                      !self.showRawRebaseMessageEditor else { return }
                                self.rawRebaseMessageRepository = activeRepo
                                self.rawRebaseMessageText = pending
                                self.showRawRebaseMessageEditor = true
                            }
                        }
                        if (try? activeRepo.operationState()) == nil {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            await MainActor.run {
                guard self.multiRootRebaseSession?.id == sessionID else { return }
                self.multiRootRunning = false
                self.feedbackCenter.warning(
                    "Multi-root rebase paused",
                    detail: "A Git rebase is already in progress in \(activeRootPath).",
                    additionalActions: [
                        self.multiRootRebaseRecoveryFeedbackAction(
                            .openRecovery,
                            rootPath: activeRootPath,
                            sessionID: sessionID
                        )
                    ],
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.feedbackCenter.attachResultRows(
                    multiRootRebaseFeedbackResultRows(for: session),
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.openMultiRootConflictResolver(preferredRootPath: activeRootPath)
            }
            return
        }
        var protectionCommitIDs: [String: String] = [:]
        for root in pendingRoots {
            guard let rootRepo = try? openRepository(path: root.rootPath),
                  let initialHead = try? rootRepo.revisionCommitId(revision: root.branch),
                  let protectionCommitID = rebaseUndoProtectionCommitBeforeOperation(
                      repo: rootRepo,
                      initialHead: initialHead,
                      onto: root.onto
                  ) else { continue }
            protectionCommitIDs[root.rootPath] = protectionCommitID
        }
        if !protectionCommitIDs.isEmpty {
            let recordedProtectionCommitIDs = protectionCommitIDs
            await MainActor.run {
                guard var current = self.multiRootRebaseSession,
                      current.id == sessionID else { return }
                for index in current.roots.indices {
                    if let protectionCommitID = recordedProtectionCommitIDs[current.roots[index].rootPath] {
                        current.roots[index].protectionCommitID = protectionCommitID
                    }
                }
                self.multiRootRebaseSession = current
                saveMultiRootRebaseSession(current)
            }
        }
        let messageMonitorRepositories = pendingRoots.compactMap {
            try? openRepository(path: $0.rootPath)
        }
        let messageMonitorPaths = Set(pendingRoots.map(\.rootPath))
        let messageMonitor = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                for rootRepo in messageMonitorRepositories {
                    if let pending = try? rootRepo.rebasePendingMessage() {
                        await MainActor.run {
                            guard !self.showRawRebaseMessageEditor else { return }
                            self.rawRebaseMessageRepository = rootRepo
                            self.rawRebaseMessageText = pending
                            self.showRawRebaseMessageEditor = true
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        do {
            let results = try runMultiRootRebaseWithCancel(specs: specs, cancel: cancel)
            messageMonitor.cancel()
            await MainActor.run {
                guard let current = self.multiRootRebaseSession,
                      current.id == sessionID else { return }
                if messageMonitorPaths.contains(self.rawRebaseMessageRepository?.workdir() ?? "") {
                    self.showRawRebaseMessageEditor = false
                    self.rawRebaseMessageRepository = nil
                    self.rawRebaseMessageText = ""
                }
                self.applyMultiRootRebaseResults(results, to: current)
            }
        } catch {
            messageMonitor.cancel()
            await MainActor.run {
                guard let current = self.multiRootRebaseSession,
                      current.id == sessionID else { return }
                self.multiRootRunning = false
                if messageMonitorPaths.contains(self.rawRebaseMessageRepository?.workdir() ?? "") {
                    self.showRawRebaseMessageEditor = false
                    self.rawRebaseMessageRepository = nil
                    self.rawRebaseMessageText = ""
                }
                self.feedbackCenter.error(
                    "Multi-root rebase failed",
                    detail: errorMessage(error),
                    nextStep: "Review the roots view before retrying.",
                    additionalActions: [
                        self.multiRootRebaseRecoveryFeedbackAction(.retry, sessionID: sessionID)
                    ],
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.feedbackCenter.attachResultRows(
                    multiRootRebaseFeedbackResultRows(for: current),
                    notificationID: self.multiRootRebaseNotificationID()
                )
            }
        }
    }
}

func applyMultiRootRebaseResults(
    _ results: [MultiRootRebaseResult],
    to session: MultiRootRebaseSession
) {
    let updated = updateMultiRootRebaseSession(session, with: results)
    multiRootRebaseSession = updated
    saveMultiRootRebaseSession(updated)
    multiRootRunning = false
    multiRootResults = multiRootRebaseRows(for: updated)
    rebaseFeedback = updated.roots
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    multiRootRebaseDrafts = []
    loadMultiRoots()

    if let paused = results.first(where: { $0.requiresFinish }) {
        let conflicts = paused.conflicts.isEmpty
            ? ""
            : "\n\(paused.conflicts.joined(separator: "、"))"
        feedbackCenter.warning(
            "Multi-root rebase paused",
            detail: "\(paused.displayName): \(paused.message)\(conflicts)",
            nextStep: "Resolve the root conflict, then use Continue or Abort from the roots view.",
            additionalActions: [
                multiRootRebaseRecoveryFeedbackAction(
                    .openRecovery,
                    rootPath: paused.rootPath,
                    sessionID: updated.id
                )
            ],
            notificationID: multiRootRebaseNotificationID()
        )
        openMultiRootConflictResolver(
            preferredRootPath: paused.rootPath,
            preferredPath: paused.conflicts.first
        )
    } else if let failure = results.first(where: { !$0.success && !$0.skipped }) {
        feedbackCenter.error(
            "Multi-root rebase partially completed",
            detail: "\(failure.displayName): \(failure.message)",
            nextStep: "Fix the failed root, then retry the remaining repositories.",
            additionalActions: [
                multiRootRebaseRecoveryFeedbackAction(.retry, sessionID: updated.id)
            ],
            notificationID: multiRootRebaseNotificationID()
        )
    } else if updated.roots.allSatisfy({ $0.state == .completed }) {
        let undoTargets = updated.roots.allSatisfy { !$0.updateRefs }
            ? multiRootRebaseRollbackTargets(for: updated)
            : []
        clearMultiRootRebaseSession(updated)
        multiRootRebaseSession = nil
        if undoTargets.count == updated.roots.count, !undoTargets.isEmpty {
            let undoAction = multiRootRebaseRecoveryFeedbackAction(
                .undo,
                rollbackTargets: undoTargets
            )
            feedbackCenter.success(
                "Multi-root rebase completed",
                detail: updated.projectPath,
                additionalActions: [undoAction],
                notificationID: multiRootRebaseNotificationID()
            )
        } else {
            feedbackCenter.success(
                "Multi-root rebase completed",
                detail: updated.projectPath,
                notificationID: multiRootRebaseNotificationID()
            )
        }
    }
    feedbackCenter.attachResultRows(
        multiRootRebaseFeedbackResultRows(for: updated),
        notificationID: multiRootRebaseNotificationID()
    )
}

func retryMultiRootRebase() {
    guard var session = multiRootRebaseSession else { return }
    for index in session.roots.indices where session.roots[index].state == .failed {
        session.roots[index].state = .pending
        session.roots[index].message = ""
    }
    multiRootRebaseSession = session
    saveMultiRootRebaseSession(session)
    runPendingMultiRootRebase(session)
}

func resumeMultiRootRebase() {
    guard let session = multiRootRebaseSession else { return }
    let sessionID = session.id
    Task.detached(priority: .utility) { [session] in
        let activeRoot = session.roots.compactMap { root -> String? in
            guard let rootRepo = try? openRepository(path: root.rootPath),
                  (try? rootRepo.operationState()) != nil else { return nil }
            return root.rootPath
        }.first
        await MainActor.run {
            guard self.multiRootRebaseSession?.id == sessionID else { return }
            if let activeRoot {
                self.openMultiRootConflictResolver(preferredRootPath: activeRoot)
                return
            }
            if session.roots.contains(where: { $0.state == .paused }) {
                self.feedbackCenter.error(
                    "Multi-root rebase recovery unavailable",
                    detail: "Git no longer reports the paused rebase state for this session.",
                    nextStep: "Inspect the affected roots and keep or restore the partial state manually."
                )
                return
            }
            var resumedSession = session
            for index in resumedSession.roots.indices where resumedSession.roots[index].state == .failed {
                resumedSession.roots[index].state = .pending
                resumedSession.roots[index].message = ""
            }
            self.multiRootRebaseSession = resumedSession
            saveMultiRootRebaseSession(resumedSession)
            self.runPendingMultiRootRebase(resumedSession)
        }
    }
}

func handleMultiRootRebaseRecovery(
    rootPath: String,
    action: MultiRootRecoveryAction,
    operationStillActive: Bool,
    sessionID: UUID
) {
    guard var session = multiRootRebaseSession, session.id == sessionID,
          let index = session.roots.firstIndex(where: { $0.rootPath == rootPath }) else { return }
    var root = session.roots[index]
    if operationStillActive {
        root.state = .paused
        root.message = "rebase remains paused"
        session.roots[index] = root
        multiRootRebaseSession = session
        saveMultiRootRebaseSession(session)
        return
    }

    switch action {
    case .continueOperation, .skip:
        root.state = .completed
        root.message = action == .skip ? "rebase step skipped and root completed" : "rebase completed"
        session.roots[index] = root
        multiRootRebaseSession = session
        saveMultiRootRebaseSession(session)
        if session.roots.contains(where: { $0.state == .pending }) {
            feedbackCenter.success("Rebase root completed", detail: "Starting the next repository.")
            runPendingMultiRootRebase(session)
        } else {
            clearMultiRootRebaseSession(session)
            multiRootRebaseSession = nil
            feedbackCenter.success("Multi-root rebase completed", detail: session.projectPath)
        }
    case .abort:
        root.state = .aborted
        root.message = "rebase aborted"
        session.roots[index] = root
        multiRootRebaseSession = session
        saveMultiRootRebaseSession(session)
        let targets = multiRootRebaseRollbackTargets(for: session)
        let failures = session.roots
            .filter { $0.state == .failed || $0.state == .aborted || $0.state == .pending }
            .map { "\($0.displayName): \($0.message)" }
        if targets.isEmpty {
            clearMultiRootRebaseSession(session)
            multiRootRebaseSession = nil
            feedbackCenter.warning("Multi-root rebase aborted", detail: failures.joined(separator: "\n"))
        } else {
            multiRootRebaseRollbackContext = MultiRootRebaseRollbackContext(
                sessionID: session.id,
                branch: root.branch,
                targets: targets,
                failures: failures
            )
            feedbackCenter.warning(
                "Multi-root rebase partially completed",
                detail: failures.joined(separator: "\n"),
                nextStep: "Choose whether to rollback the successful repositories or keep the partial state.",
                additionalActions: [
                    multiRootRebaseRecoveryFeedbackAction(
                        .rollback,
                        sessionID: session.id
                    ),
                    multiRootRebaseRecoveryFeedbackAction(
                        .keepPartial,
                        sessionID: session.id
                    )
                ],
                notificationID: multiRootRebaseNotificationID()
            )
        }
    }
}

func rollbackPersistedMultiRootRebase() {
    guard let session = multiRootRebaseSession else { return }
    let targets = multiRootRebaseRollbackTargets(for: session)
    guard !targets.isEmpty else {
        clearMultiRootRebaseSession(session)
        multiRootRebaseSession = nil
        feedbackCenter.warning(
            "Multi-root rebase rollback unavailable",
            detail: "No completed root has an expected HEAD to restore.",
            notificationID: multiRootRebaseNotificationID()
        )
        return
    }
    multiRootRebaseRollbackContext = MultiRootRebaseRollbackContext(
        sessionID: session.id,
        branch: session.roots.first?.branch ?? rebaseBranch,
        targets: targets,
        failures: session.roots
            .filter { $0.state == .failed || $0.state == .aborted || $0.state == .pending }
            .map { "\($0.displayName): \($0.message)" }
    )
    rollbackMultiRootRebase(targets)
}

func keepPersistedMultiRootRebasePartial() {
    guard let session = multiRootRebaseSession else { return }
    let context = MultiRootRebaseRollbackContext(
        sessionID: session.id,
        branch: session.roots.first?.branch ?? rebaseBranch,
        targets: multiRootRebaseRollbackTargets(for: session),
        failures: session.roots
            .filter { $0.state == .failed || $0.state == .aborted || $0.state == .pending }
            .map { "\($0.displayName): \($0.message)" }
    )
    keepMultiRootRebasePartial(context)
}

func keepMultiRootRebasePartial(_ context: MultiRootRebaseRollbackContext) {
    multiRootRebaseRollbackContext = nil
    if let session = multiRootRebaseSession, session.id == context.sessionID {
        clearMultiRootRebaseSession(session)
        multiRootRebaseSession = nil
    }
    feedbackCenter.warning(
        "Partial rebase kept",
        detail: context.branch,
        nextStep: "Review the affected repositories in Git Roots."
    )
}

func rollbackMultiRootRebase(
    _ targets: [MultiRootRebaseRollbackTarget],
    completionTitle: String = "Multi-root rebase rollback completed"
) {
    guard !targets.isEmpty else { return }
    let context = multiRootRebaseRollbackContext
    multiRootRebaseRollbackContext = nil
    let protectedPatterns = effectiveProtectedBranchPatterns
    let notificationID = multiRootRebaseNotificationID()
    beginFeedbackOperation(
        "Rollback multi-root rebase",
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [MultiRootRebaseRollbackTarget] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard try rootRepo.operationState() == nil else {
                    throw NSError(
                        domain: "Arbor.MultiRootRebaseRollback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "A Git operation is still in progress."]
                    )
                }
                let remoteBranches = try rootRepo.remoteBranchList()
                let protectedCommitID = rebaseUndoProtectionCommit(
                    repo: rootRepo,
                    initialHead: target.initialHead,
                    expectedHead: target.expectedHead,
                    recordedCommitID: target.protectionCommitID
                )
                if let protectedBranch = protectedRemoteBranchContainingCommit(
                    repo: rootRepo,
                    commitID: protectedCommitID,
                    remoteBranches: remoteBranches,
                    protectedPatterns: protectedPatterns
                ) {
                    throw NSError(
                        domain: "Arbor.MultiRootRebaseRollback",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Rollback is blocked: \(protectedBranch) contains published pre-rebase history."
                        ]
                    )
                }
                try rootRepo.restoreBranchIfExpected(
                    branch: target.branch,
                    initialCommitId: target.initialHead,
                    expectedCommitId: target.expectedHead
                )
            } catch {
                failures.append("\(target.displayName): \(errorMessage(error))")
                remaining.append(target)
            }
        }
        let rollbackFailures = failures
        let rollbackRemaining = remaining
        await MainActor.run {
            self.loadMultiRoots()
            if rollbackFailures.isEmpty {
                if let session = self.multiRootRebaseSession {
                    clearMultiRootRebaseSession(session)
                }
                self.multiRootRebaseSession = nil
                if let notificationID {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                self.feedbackCenter.success(completionTitle)
            } else {
                self.feedbackCenter.warning(
                    "Multi-root rebase rollback partially failed",
                    detail: rollbackFailures.joined(separator: "\n"),
                    nextStep: "Review the affected repositories and retry the remaining rollback targets.",
                    additionalActions: rollbackRemaining.isEmpty
                        ? []
                        : [
                            self.multiRootRebaseRecoveryFeedbackAction(
                                .undo,
                                rollbackTargets: rollbackRemaining
                            )
                        ],
                    notificationID: notificationID
                )
                if let context {
                    self.multiRootRebaseRollbackContext = MultiRootRebaseRollbackContext(
                        sessionID: context.sessionID,
                        branch: context.branch,
                        targets: rollbackRemaining,
                        failures: rollbackFailures
                    )
                }
            }
        }
    }
}

func doRebaseContinue() {
    guard let repo else { return }
    beginFeedbackOperation("Continue rebase")
    let seed = rebaseUndoSeed
    let selectedRootPath = rebaseRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = seed?.repositoryPath ?? selectedRootPath
    let currentRepositoryPath = repo.workdir() ?? ""
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            let outcome = try selectedRepo.rebaseContinue()
            let st = try selectedRepo.status()
            let currentBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let finalHead = seed.flatMap { try? selectedRepo.revisionCommitId(revision: $0.branch) }
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    self.entries = st
                }
                self.rebasePaused = outcome.paused
                self.rebasePauseReason = outcome.pauseReason
                self.rebaseConflicts = outcome.conflicts
                if outcome.paused, outcome.pauseReason == .conflict {
                    let names = outcome.conflicts.prefix(3).joined(separator: "、")
                    let suffix = names.isEmpty ? "" : "：\(names)"
                    self.rebaseFeedback = "再次冲突 \(outcome.conflicts.count) 个文件\(suffix)"
                    self.rebaseUndoSeed = seed
                    self.rebaseUndoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.showMergeRevisionsDialog = true
                } else {
                    self.rebaseFeedback = outcome.paused ? "再次暂停在 edit 提交" : "变基完成"
                    if !outcome.paused {
                        self.showMergeRevisionsDialog = false
                        self.rebaseUndoSeed = nil
                        self.rebaseUndoTarget = undoTarget
                        if let seed {
                            clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                        }
                        if let undoTarget {
                            self.feedbackCenter.success(
                                "Rebase completed",
                                detail: String(outcome.headId.prefix(7)),
                                additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                                notificationID: rebaseUndoNotificationID(repositoryPath: undoTarget.repositoryPath),
                                notificationGroup: .standard
                            )
                        } else {
                            self.feedbackCenter.success(
                                "Rebase completed",
                                detail: String(outcome.headId.prefix(7))
                            )
                        }
                    } else {
                        self.rebaseUndoSeed = seed
                        self.rebaseUndoTarget = nil
                        if let seed {
                            saveRebaseUndoSeed(seed)
                        }
                    }
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            let recoveryRepository: Repository?
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                recoveryRepository = repo
            } else {
                recoveryRepository = try? openRepository(path: repositoryPath)
            }
            let canStageAndRetry: Bool
            if let recoveryRepository {
                canStageAndRetry = (try? recoveryRepository.status().contains {
                    $0.unstaged != .unchanged
                        && $0.unstaged != .untracked
                        && $0.unstaged != .ignored
                        && $0.unstaged != .conflicted
                }) ?? false
            } else {
                canStageAndRetry = false
            }
            await MainActor.run {
                self.rebaseFeedback = detail
                self.feedbackCenter.error(
                    "Rebase continue failed",
                    detail: detail,
                    nextStep: "Resolve remaining conflicts or stage tracked changes before continuing.",
                    actionTitle: canStageAndRetry ? "Stage-and-Retry" : nil,
                    action: canStageAndRetry ? { self.stageAndRetryRebaseContinue() } : nil
                )
            }
        }
    }
}

func stageAndRetryRebaseContinue() {
    guard let repo else { return }
    beginFeedbackOperation("Stage-and-Retry Rebase")
    let seed = rebaseUndoSeed
    let selectedRootPath = rebaseRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryPath = seed?.repositoryPath ?? selectedRootPath
    let currentRepositoryPath = repo.workdir() ?? ""
    Task.detached(priority: .userInitiated) {
        do {
            let selectedRepo: Repository
            if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                selectedRepo = repo
            } else {
                selectedRepo = try openRepository(path: repositoryPath)
            }
            try selectedRepo.stageTracked()
            let outcome = try selectedRepo.rebaseContinue()
            let st = try selectedRepo.status()
            let currentBranch = (try? selectedRepo.branchList())?.first(where: { $0.isCurrent })?.name
            let finalHead = seed.flatMap { try? selectedRepo.revisionCommitId(revision: $0.branch) }
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )
            await MainActor.run {
                if repositoryPath.isEmpty || repositoryPath == currentRepositoryPath {
                    self.entries = st
                }
                self.rebasePaused = outcome.paused
                self.rebasePauseReason = outcome.pauseReason
                self.rebaseConflicts = outcome.conflicts
                self.rebaseFeedback = outcome.paused
                    ? "Rebase 继续后再次暂停"
                    : "Rebase 完成"
                if !outcome.paused {
                    self.showMergeRevisionsDialog = false
                    self.rebaseUndoSeed = nil
                    self.rebaseUndoTarget = undoTarget
                    if let seed {
                        clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
                    }
                    if let undoTarget {
                        self.feedbackCenter.success(
                            "Rebase continued",
                            detail: String(outcome.headId.prefix(7)),
                            additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                            notificationID: rebaseUndoNotificationID(repositoryPath: undoTarget.repositoryPath),
                            notificationGroup: .standard
                        )
                    } else {
                        self.feedbackCenter.success(
                            "Rebase continued",
                            detail: String(outcome.headId.prefix(7))
                        )
                    }
                } else if outcome.pauseReason == .conflict {
                    self.rebaseUndoSeed = seed
                    self.rebaseUndoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                    self.showMergeRevisionsDialog = true
                } else {
                    self.rebaseUndoSeed = seed
                    self.rebaseUndoTarget = nil
                    if let seed {
                        saveRebaseUndoSeed(seed)
                    }
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Stage-and-Retry failed",
                    detail: errorMessage(error),
                    nextStep: "Review tracked and conflicted files, then continue or abort the rebase."
                )
            }
        }
    }
}

func doRebaseAbort() {
    guard let repo else { return }
    let repositoryPath = rebaseUndoSeed?.repositoryPath ?? repo.workdir() ?? ""
    beginFeedbackOperation("Abort rebase")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.rebaseAbort()
            let st = try repo.status()
            await MainActor.run {
                self.entries = st
                self.rebasePaused = false
                self.rebasePauseReason = nil
                self.rebaseConflicts = []
                self.rebaseUndoSeed = nil
                self.rebaseUndoTarget = nil
                clearRebaseUndoSeed(repositoryPath: repositoryPath)
                self.rebaseFeedback = "已中止变基"
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch { await MainActor.run { self.rebaseFeedback = "\(error)" } }
    }
}

}
