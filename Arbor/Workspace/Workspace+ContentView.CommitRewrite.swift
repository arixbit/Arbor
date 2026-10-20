import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// REBASE-002：从 Log 的提交上下文菜单预配置单提交改写动作。
/// 仍然交给 todo 编辑器确认，避免上下文菜单直接执行不可逆的历史重写。
func rewriteCommitFromLog(
    _ commit: CommitInfo,
    action: RebaseTodoAction,
    initialCommitConfirmed: Bool = false
) {
    guard let repo = logRepository(for: commit) else { return }
    guard (try? repo.isCommitReachableFrom(commitId: commit.id, descendantId: "HEAD")) == true else {
        feedbackCenter.error(
            "Rewrite commit unavailable",
            detail: "The selected commit is not on the current branch's linear history.",
            nextStep: "Select a commit from the current branch and retry."
        )
        return
    }
    if let protectedBranch = protectedRemoteBranchContainingCommit(
        repo: repo,
        commitID: commit.id,
        remoteBranches: activeLogRemoteBranches,
        protectedPatterns: effectiveProtectedBranchPatterns
    ) {
        feedbackCenter.error(
            "History rewrite blocked",
            detail: "The selected commit is published to protected branch \(protectedBranch).",
            nextStep: "Fetch or select an unpublished commit before rewriting history."
        )
        return
    }

    // IntelliJ uses `git commit --amend --only` for the latest commit. Keep
    // this fast path separate from the todo editor: a Log reword must never
    // absorb unrelated staged changes from the Commit workspace.
    if action == .reword, commit.isHead {
        logRewrite.rewordUsesRootRebase = false
        logRewrite.rewordCommit = commit
        logRewrite.rewordMessage = commit.messageBody.isEmpty
            ? commit.summary
            : "\(commit.summary)\n\n\(commit.messageBody)"
        if commit.parentIds.isEmpty {
            logRewrite.pendingInitialCommitReword = commit
            logRewrite.showInitialCommitRewordAlert = true
        } else {
            logRewrite.showRewordDialog = true
        }
        return
    }
    if action == .reword, commit.parentIds.isEmpty {
        // IntelliJ uses `git rebase --root` when the selected root is not
        // HEAD. Keep the same full-message editor, but route confirmation to
        // the engine's clean linear root-history rewrite path.
        logRewrite.rewordUsesRootRebase = true
        logRewrite.rewordCommit = commit
        logRewrite.rewordMessage = commit.messageBody.isEmpty
            ? commit.summary
            : "\(commit.summary)\n\n\(commit.messageBody)"
        logRewrite.showRewordDialog = true
        return
    }
    if action == .drop, commit.parentIds.isEmpty {
        if !initialCommitConfirmed {
            logRewrite.pendingInitialCommitRewrite = PendingInitialCommitRewrite(
                commits: [commit],
                action: action
            )
            logRewrite.showInitialCommitRewriteAlert = true
            return
        }
        dropSelectedCommitsFromLog([commit], repository: repo)
        return
    }
    guard let firstParent = commit.parentIds.first else {
        feedbackCenter.error(
            "Rewrite commit unavailable",
            detail: "The initial commit can only be reworded when it is HEAD.",
            nextStep: "Check out the branch containing the initial commit, then retry."
        )
        return
    }
    if commit.parentIds.count > 1 {
        feedbackCenter.error(
            "Rewrite commit unavailable",
            detail: "Merge commits are not supported by the linear todo editor.",
            nextStep: "Use a regular interactive rebase with merge preservation."
        )
        return
    }
    if action == .drop {
        dropSelectedCommitsFromLog([commit], repository: repo)
        return
    }

    beginFeedbackOperation("Prepare Commit Rewrite")
    Task.detached(priority: .userInitiated) {
        do {
            let onto: String
            switch action {
            case .squash, .fixup:
                let previous = try repo.logFiltered(
                    path: nil,
                    limit: 1,
                    follow: false,
                    startRev: firstParent,
                    author: nil,
                    since: nil
                ).first
                guard let previous,
                      let previousParent = previous.parentIds.first else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected commit has no previous commit to combine with."]
                    )
                }
                onto = previousParent
            default:
                onto = firstParent
            }

            var todo = try repo.rebaseTodo(onto: onto, autoSquash: false)
            guard let targetIndex = todo.items.firstIndex(where: { item in
                item.commitId == commit.id
                    || item.commitId.hasPrefix(commit.id)
                    || commit.id.hasPrefix(item.commitId)
            }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commit is not on the current branch's linear history."]
                )
            }
            todo.items[targetIndex].action = action
            let preparedItems = todo.items

            await MainActor.run {
                self.rebaseWorkspace.todoOnto = onto
                self.rebaseWorkspace.todoItems = preparedItems
                self.rebaseWorkspace.todoPreserveMerges = false
                self.rebaseWorkspace.todoRoot = false
                self.rebaseWorkspace.showTodoEditor = true
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Prepare commit rewrite failed",
                    detail: errorMessage(error),
                    nextStep: "The action applies only to a linear commit on the current branch."
                )
            }
        }
    }
}

/// Continue the IntelliJ-style initial-commit warning into the normal full
/// message editor. The engine still uses `--amend --only`, which also works
/// for a root HEAD commit without importing staged changes.
func confirmInitialCommitReword() {
    guard let commit = logRewrite.pendingInitialCommitReword else { return }
    logRewrite.pendingInitialCommitReword = nil
    logRewrite.rewordUsesRootRebase = false
    logRewrite.rewordCommit = commit
    logRewrite.rewordMessage = commit.messageBody.isEmpty
        ? commit.summary
        : "\(commit.summary)\n\n\(commit.messageBody)"
    logRewrite.showRewordDialog = true
}

/// Execute IntelliJ's direct multi-commit Drop path. The engine still builds
/// and validates the explicit todo, but the user gets the native action
/// confirmation instead of an intermediate todo editor.
func dropSelectedCommitsFromLog(_ commits: [CommitInfo], repository repo: Repository) {
    // IntelliJ permits Log Drop while HEAD is detached. Keep an empty branch
    // identity so the same expected-HEAD Undo/CAS path can validate detached
    // state without inventing a ref to update.
    let branch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""

    if GitDropCommitSettings.showConfirmation() {
        let alert = NSAlert()
        alert.messageText = commits.count == 1 ? "Drop this commit?" : "Drop selected commits?"
        let summaries = commits.prefix(3).map { $0.summary }.joined(separator: ", ")
        let suffix = commits.count > 3 ? " …" : ""
        let noun = commits.count == 1 ? "commit" : "commits"
        let destination = branch.isEmpty ? "detached HEAD" : branch
        alert.informativeText = String(commits.count) + " " + noun + " will be removed from " + destination + " and the history will be rewritten. " + summaries + suffix
        alert.addButton(withTitle: commits.count == 1 ? "Drop Commit" : "Drop Commits")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    let repositoryPath = repo.workdir() ?? ""
    let commitIDs = commits.map { $0.id }
    let commitSummaries = commits.map { $0.summary }
    let protectedPatterns = effectiveProtectedBranchPatterns
    let remoteBranchesForRewrite = activeLogRemoteBranches
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = nil
    clearRebaseUndoSeed(repositoryPath: repositoryPath)
    let cancel = GitCancelHandle()
    let useInMemory = shouldUseInMemoryCommitEditing(
        settingEnabled: GitInMemoryCommitEditingSettings.isEnabled(),
        items: [],
        preserveMerges: false
    )
    beginFeedbackOperation("Drop Commits", cancelHandle: cancel)

    Task.detached(priority: .userInitiated) {
        do {
            guard commitIDs.allSatisfy({
                (try? repo.isCommitReachableFrom(
                    commitId: $0,
                    descendantId: "HEAD"
                )) == true
            }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected commit is not on the current branch's linear history."
                    ]
                )
            }
            if let protectedBranch = commitIDs.compactMap({ commitID in
                protectedRemoteBranchContainingCommit(
                    repo: repo,
                    commitID: commitID,
                    remoteBranches: remoteBranchesForRewrite,
                    protectedPatterns: protectedPatterns
                )
            }).first {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected commit is published to protected branch \(protectedBranch)."
                    ]
                )
            }

            guard let initialHead = repo.headCommitId() else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Drop Commits requires a checked-out commit."]
                )
            }
            let seed = RebaseUndoSeed(
                repositoryPath: repositoryPath,
                branch: branch,
                initialHead: initialHead,
                updateRefs: false
            )
            saveRebaseUndoSeed(seed)
            let runNativeDrop: () throws -> RebaseOutcome = {
                try repo.dropSelectedCommitsNativeWithPolicyAndCancel(
                    commitIds: commitIDs,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
            }
            let outcome: RebaseOutcome
            if useInMemory {
                let inMemoryOutcome = try repo.dropSelectedCommitsWithPolicyAndCancel(
                    commitIds: commitIDs,
                    savePolicy: projectSavePolicy,
                    cancel: cancel
                )
                if inMemoryOutcome.paused, inMemoryOutcome.pauseReason == .conflict {
                    // IntelliJ drops the partial object-level rewrite before
                    // retrying native Git, so the native path sees the same
                    // original HEAD and local scene as the first attempt.
                    try repo.rebaseAbort()
                    outcome = try runNativeDrop()
                } else {
                    outcome = inMemoryOutcome
                }
            } else {
                outcome = try runNativeDrop()
            }
            let status = try repo.status()
            let finalHead = repo.headCommitId()
            let currentBranch = (try? repo.branchList())?.first(where: { $0.isCurrent })?.name
            let undoTarget = rebaseUndoTargetAfterCompletion(
                seed: seed,
                currentBranch: currentBranch,
                finalHead: finalHead
            )

            await MainActor.run {
                self.repositoryStatus.entries = status
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
                    self.rebaseWorkspace.feedback = "Drop Commits 冲突 \(outcome.conflicts.count) 个文件\(suffix)，请解决后「继续」"
                    self.operationRecovery.showConflictResolver = true
                } else if outcome.paused {
                    self.rebaseWorkspace.feedback = "Drop Commits 已暂停，可修改文件后「继续」"
                } else {
                    self.rebaseWorkspace.feedback = "已删除 \(commitIDs.count) 个提交"
                }
                self.rebaseWorkspace.undoSeed = outcome.paused ? seed : nil
                self.rebaseWorkspace.undoTarget = outcome.paused ? nil : undoTarget
                if outcome.paused {
                    saveRebaseUndoSeed(seed)
                } else {
                    clearRebaseUndoSeed(repositoryPath: repositoryPath)
                }
                if let undoTarget {
                    self.feedbackCenter.success(
                        "Drop Commits completed",
                        detail: commitSummaries.prefix(3).joined(separator: ", "),
                        additionalActions: [self.rebaseUndoFeedbackAction(for: undoTarget)],
                        notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                        notificationGroup: .standard
                    )
                } else if !outcome.paused {
                    self.feedbackCenter.success(
                        "Drop Commits completed",
                        detail: commitSummaries.prefix(3).joined(separator: ", "),
                        notificationID: rebaseUndoNotificationID(repositoryPath: repositoryPath),
                        notificationGroup: .standard
                    )
                }
                self.logSelectionState.selection = nil
                self.refreshAll(showFeedback: false)
                self.loadLog()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.rebaseWorkspace.feedback = "Drop Commits 已取消；保存的本地现场未被丢弃"
                    self.feedbackCenter.warning(
                        "Drop Commits cancelled",
                        detail: self.rebaseWorkspace.feedback ?? "保存的本地现场未被丢弃",
                        nextStep: "Check Saved Changes or Stash, then retry when the repository is ready.",
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
                    "Drop Commits failed",
                    detail: errorMessage(error),
                    nextStep: "The operation only accepts linear commits on the checked-out history; resolve any preserved local-change conflict or Abort the paused rebase."
                )
            }
        }
    }
}

/// REBASE-003：从 Log 多选提交预配置批量 reword/squash/drop。
/// 多选动作只接受当前分支上的线性提交；root 可用于 Reword/Squash/Drop，
/// 其中 Drop 仍保持 merge-preserving 边界。Squash 使用独立完整消息
/// 对话框，Reword 仍交给 todo 编辑器确认，Drop 使用 IntelliJ 的直接确认执行路径。
func rewriteSelectedCommitsFromLog(
    _ commits: [CommitInfo],
    action: RebaseTodoAction,
    initialCommitConfirmed: Bool = false
) {
    guard let repo = logRepository(for: commits) else {
        feedbackCenter.warning("Batch rewrite unavailable", detail: "Selected commits must belong to one Git root.", nextStep: "Select commits from one repository and retry.")
        return
    }
    var seenCommitIDs = Set<String>()
    let selected = commits.filter { commit in
        seenCommitIDs.insert(commit.id).inserted
    }
    guard selected.count >= 2 else {
        feedbackCenter.warning(
            "Select at least two commits",
            detail: "Batch rewrite needs multiple selected commits.",
            nextStep: "Use Cmd-click or Shift-click in the Log graph."
        )
        return
    }
    guard action == .reword || action == .squash || action == .drop else {
        feedbackCenter.error(
            "Batch rewrite unavailable",
            detail: "Only reword, squash, and drop support multi-selection from Log.",
            nextStep: "Use the interactive rebase editor for other actions."
        )
        return
    }
    if action == .drop {
        guard selected.allSatisfy({ $0.parentIds.count <= 1 }) else {
            feedbackCenter.error(
                "Batch drop unavailable",
                detail: "Merge commits cannot be dropped by the linear multi-selection action.",
                nextStep: "Use Interactive Rebase with the appropriate history-preserving mode."
            )
            return
        }
        dropSelectedCommitsFromLog(selected, repository: repo)
        return
    }

    guard selected.allSatisfy({ $0.parentIds.count <= 1 }) else {
        feedbackCenter.error(
            "Batch rewrite unavailable",
            detail: "Merge commits cannot be rewritten by the linear multi-selection action.",
            nextStep: "Use Interactive Rebase with merge preservation instead."
        )
        return
    }

    if selected.contains(where: { $0.parentIds.isEmpty }), !initialCommitConfirmed {
        logRewrite.pendingInitialCommitRewrite = PendingInitialCommitRewrite(
            commits: selected,
            action: action
        )
        logRewrite.showInitialCommitRewriteAlert = true
        return
    }

    beginFeedbackOperation("Prepare Batch Commit Rewrite")
    let protectedPatterns = effectiveProtectedBranchPatterns
    let remoteBranchesForRewrite = activeLogRemoteBranches
    Task.detached(priority: .userInitiated) {
        do {
            guard selected.allSatisfy({
                (try? repo.isCommitReachableFrom(
                    commitId: $0.id,
                    descendantId: "HEAD"
                )) == true
            }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commit is not on the current branch's linear history."]
                )
            }
            guard let oldest = oldestSelectedLinearCommit(
                selected,
                isAncestor: { ancestor, descendant in
                    (try? repo.isCommitReachableFrom(
                        commitId: ancestor,
                        descendantId: descendant
                    )) == true
                }
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commits do not form one linear history range."]
                )
            }
            let rootRebase = oldest.parentIds.isEmpty
            let onto = oldest.parentIds.first ?? ""
            if let protectedBranch = selected.compactMap({ commit in
                protectedRemoteBranchContainingCommit(
                    repo: repo,
                    commitID: commit.id,
                    remoteBranches: remoteBranchesForRewrite,
                    protectedPatterns: protectedPatterns
                )
            }).first {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commit is published to protected branch \(protectedBranch)."]
                )
            }
            var todo: RebaseTodo = if rootRebase {
                try repo.rebaseRootTodo(autoSquash: false, preserveMerges: false)
            } else {
                try repo.rebaseTodo(onto: onto, autoSquash: false)
            }
            let indexes = selected.map { commit in
                todo.items.firstIndex { item in
                    item.commitId == commit.id
                        || item.commitId.hasPrefix(commit.id)
                        || commit.id.hasPrefix(item.commitId)
                }
            }
            guard indexes.allSatisfy({ $0 != nil }) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "One or more selected commits are not on the current branch's linear history."]
                )
            }
            let sortedIndexes = indexes.compactMap { $0 }.sorted()
            guard sortedIndexes.count == selected.count else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "The selected commits could not be mapped to one rebase range."]
                )
            }
            let squashCommits: [CommitInfo]
            let preparedSquashIndexes: [Int]
            if action == .squash {
                // IntelliJ's in-memory `unite` moves selected entries next to
                // the first selected entry, preserving their history order,
                // then turns that group into one squash. Do the same before
                // presenting the standalone message editor so non-contiguous
                // selection does not silently lose its intended semantics.
                let selectedTodoIDs = Set(sortedIndexes.map { todo.items[$0].commitId })
                let selectedItems = sortedIndexes.map { todo.items[$0] }
                let insertionIndex = sortedIndexes[0]
                let remainingItems = todo.items.filter { !selectedTodoIDs.contains($0.commitId) }
                var reorderedItems = remainingItems
                reorderedItems.insert(contentsOf: selectedItems, at: insertionIndex)
                todo.items = reorderedItems
                preparedSquashIndexes = Array(insertionIndex..<(insertionIndex + selectedItems.count))
                squashCommits = selectedItems.compactMap { item in
                    let todoID = item.commitId
                    return selected.first { commit in
                        commit.id == todoID
                            || todoID.hasPrefix(commit.id)
                            || commit.id.hasPrefix(todoID)
                    }
                }
                guard squashCommits.count == selectedItems.count else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "The selected commits could not be loaded for the Squash message."]
                    )
                }
            } else if action == .reword {
                preparedSquashIndexes = sortedIndexes
                squashCommits = []
                for index in sortedIndexes {
                    todo.items[index].action = .reword
                    // The todo editor exposes each message field so every
                    // selected commit can be changed independently before
                    // the destructive operation starts.
                    todo.items[index].message = todo.items[index].summary
                }
            } else {
                preparedSquashIndexes = sortedIndexes
                squashCommits = []
                for index in sortedIndexes {
                    todo.items[index].action = .drop
                }
            }
            let preparedItems = todo.items
            let squashSummaries = squashCommits.map(\.summary)
            let squashMessage = prettySquashMessage(squashCommits)
            await MainActor.run {
                self.rebaseWorkspace.todoOnto = onto
                self.rebaseWorkspace.todoItems = preparedItems
                self.rebaseWorkspace.todoPreserveMerges = false
                self.rebaseWorkspace.todoRoot = rootRebase
                if action == .squash {
                    self.logRewrite.squashIndexes = preparedSquashIndexes
                    self.logRewrite.squashSummaries = squashSummaries
                    self.logRewrite.squashMessage = squashMessage
                    self.feedbackCenter.success(
                        "Squash message ready",
                        detail: "Edit the combined message before rewriting \(squashSummaries.count) commits."
                    )
                    self.logRewrite.showSquashDialog = true
                } else {
                    self.rebaseWorkspace.showTodoEditor = true
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Prepare batch rewrite failed",
                    detail: errorMessage(error),
                    nextStep: action == .squash
                        ? "Select linear commits on the current branch, then retry."
                        : "Select linear commits from the current branch, then retry."
                )
            }
        }
    }
}

/// Continue the IntelliJ-style warning shown before a multi-selection that
/// includes the initial commit enters the root todo editor.
func confirmInitialCommitRewrite() {
    guard let pending = logRewrite.pendingInitialCommitRewrite else { return }
    logRewrite.pendingInitialCommitRewrite = nil
    if pending.commits.count == 1,
       let commit = pending.commits.first,
       pending.action == .drop {
        rewriteCommitFromLog(commit, action: pending.action, initialCommitConfirmed: true)
    } else {
        rewriteSelectedCommitsFromLog(
            pending.commits,
            action: pending.action,
            initialCommitConfirmed: true
        )
    }
}

}
