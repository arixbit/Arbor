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
    if let activeRoot = logList.activeRootPath,
       activeRoot != projectWorkspace.path {
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
    commitWorkspace.message = "\(kind.prefix)! \(subject)"
    rebaseWorkspace.pendingAutoSquash = PendingAutoSquashRebase(
        targetID: commit.id,
        onto: onto,
        kind: kind,
        root: isRootTarget
    )
    commitWorkspace.amendMode = false
    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    projectPanelExpanded = false
    commitWorkspace.feedback = nil
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
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Rebase", cancelHandle: cancel)
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
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
                self.repositoryStatus.entries = st
                self.rebaseWorkspace.range = []
                self.rebaseWorkspace.actions = []
                self.rebaseWorkspace.todoItems = []
                self.rebaseWorkspace.todoRoot = false
                self.rebaseWorkspace.showTodoEditor = false
                self.rebaseWorkspace.paused = outcome.paused
                self.rebaseWorkspace.pauseReason = outcome.pauseReason
                self.rebaseWorkspace.conflicts = outcome.conflicts
                if outcome.paused, outcome.pauseReason == .conflict {
                    let names = outcome.conflicts.prefix(3).joined(separator: "、")
                    let suffix = names.isEmpty ? "" : "：\(names)"
                    self.rebaseWorkspace.feedback = "Autosquash 冲突 \(outcome.conflicts.count) 个文件\(suffix)，请解决后「继续」"
                    self.operationRecovery.showConflictResolver = true
                } else if outcome.paused {
                    self.rebaseWorkspace.feedback = "Autosquash 已暂停在 edit 提交，可修改文件后「继续」"
                } else {
                    self.rebaseWorkspace.feedback = "Autosquash 变基完成"
                }
                self.rebaseWorkspace.undoSeed = outcome.paused ? seed : nil
                self.rebaseWorkspace.undoTarget = outcome.paused ? nil : undoTarget
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
                    self.rebaseWorkspace.feedback = "Autosquash 变基已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Autosquash rebase cancelled",
                        detail: self.rebaseWorkspace.feedback ?? "保存的本地现场未被丢弃",
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
                let detail = errorMessage(error)
                self.rebaseWorkspace.feedback = "Autosquash 变基失败：\(detail)"
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
                self.rebaseWorkspace.todoOnto = onto
                self.rebaseWorkspace.todoItems = todo.items
                self.rebaseWorkspace.todoPreserveMerges = preserveMerges
                self.rebaseWorkspace.todoRoot = root
                self.rebaseWorkspace.showTodoEditor = true
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
        projectPath: projectWorkspace.path,
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
    let message = logRewrite.squashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        feedbackCenter.warning(
            "Commit message required",
            detail: "A squashed commit must keep a non-empty message.",
            nextStep: "Enter a combined commit message and retry."
        )
        return
    }
    let indexes = logRewrite.squashIndexes.sorted()
    guard let first = indexes.first,
          indexes.count >= 2,
          indexes.allSatisfy({ $0 >= 0 && $0 < rebaseWorkspace.todoItems.count }) else {
        feedbackCenter.error(
            "Squash unavailable",
            detail: "The selected commits are no longer available in the prepared history range.",
            nextStep: "Refresh the Log and select the commits again."
        )
        logRewrite.showSquashDialog = false
        return
    }
    rebaseWorkspace.todoItems[first].action = .reword
    rebaseWorkspace.todoItems[first].message = message
    for index in indexes.dropFirst() {
        rebaseWorkspace.todoItems[index].action = .fixup
        rebaseWorkspace.todoItems[index].message = nil
    }
    logRewrite.showSquashDialog = false
    logRewrite.squashIndexes = []
    logRewrite.squashSummaries = []
    startTodoRebase()
}

}
