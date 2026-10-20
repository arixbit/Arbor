import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func stageAll() {
    guard let repo else { return }
    // GitStagePanel's toolbar action is Git.Stage.Add.Tracked, not
    // Git.Stage.Add.All. The latter belongs to the overflow action group and
    // also stages untracked files. Keep the toolbar's default behavior aligned
    // with rebased: stage tracked worktree changes only.
    guard repositoryStatus.entries.contains(where: {
        $0.unstaged != .unchanged
            && $0.unstaged != .untracked
            && $0.unstaged != .ignored
    }) else { return }
    beginFeedbackOperation("Stage changes")
    Task.detached(priority: .userInitiated) {
        do {
            // Keep Git.Stage.Add.Tracked in the engine so deleted tracked
            // files and the untracked exclusion have one authoritative path.
            try repo.stageTracked()
            let status = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.repositoryStatus.entries = status
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.fileWorkspace.refreshToken &+= 1
                self.feedbackCenter.success("Changes staged")
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Stage changes failed", detail: errorMessage(error), nextStep: "Check the file permissions and retry.")
            }
        }
    }
}

/// Explicit Git.Stage.Add.All action: include tracked and untracked changes.
/// The adjacent toolbar action remains tracked-only to match IntelliJ's
/// Git.Stage.Add.Tracked affordance.
func stageEverything() {
    guard let repo else { return }
    guard repositoryStatus.entries.contains(where: {
        $0.unstaged != .unchanged && $0.unstaged != .ignored
    }) else { return }
    beginFeedbackOperation("Stage all changes")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stageAll()
            let status = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.repositoryStatus.entries = status
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.fileWorkspace.refreshToken &+= 1
                self.feedbackCenter.success("All changes staged")
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Stage all changes failed", detail: errorMessage(error), nextStep: "Check the file permissions and retry.")
            }
        }
    }
}

func beginNewTagDialog() {
    tagWorkspace.repositoryOverride = nil
    tagWorkspace.force = false
    tagWorkspace.showCreateDialog = true
}

/// Open the shared Tag dialog for a Log commit, retaining the commit's own
/// repository so a multi-root Log cannot create the tag in the primary root.
func beginCreateTagFromLog(_ commit: CommitInfo) {
    guard let targetRepo = logRepository(for: commit) else {
        feedbackCenter.warning(
            "Create Tag unavailable",
            detail: "The selected commit's Git root could not be opened.",
            nextStep: "Refresh Git Roots, then retry from the commit history."
        )
        return
    }
    tagWorkspace.repositoryOverride = targetRepo
    tagWorkspace.at = commit.id
    tagWorkspace.force = false
    tagWorkspace.showCreateDialog = true
}

func createTag() {
    guard let targetRepo = tagWorkspace.repositoryOverride ?? repo else { return }
    let name = tagWorkspace.name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    let at = tagWorkspace.at.trimmingCharacters(in: .whitespaces)
    let annotated = tagWorkspace.annotated
    let force = tagWorkspace.force
    let message = tagWorkspace.message
    let signKey = tagWorkspace.signKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetRootPath = targetRepo.workdir()
    beginFeedbackOperation("Create tag")
    Task.detached(priority: .userInitiated) {
        do {
            if annotated {
                if signKey.isEmpty {
                    try targetRepo.tagCreateWithOptionsAndForce(
                        name: name,
                        at: at.isEmpty ? nil : at,
                        message: message,
                        signKey: nil,
                        force: force
                    )
                } else {
                    try withArborPinentrySession {
                        try targetRepo.tagCreateWithOptionsAndForce(
                            name: name,
                            at: at.isEmpty ? nil : at,
                            message: message,
                            signKey: signKey,
                            force: force
                        )
                    }
                }
            } else {
                try targetRepo.tagCreateWithForce(
                    name: name,
                    at: at.isEmpty ? nil : at,
                    force: force
                )
            }
            let tags = try targetRepo.tagList()
            await MainActor.run {
                if targetRootPath == self.repo?.workdir() {
                    self.tagWorkspace.tags = tags
                }
                self.tagWorkspace.name = ""
                self.tagWorkspace.at = ""
                self.tagWorkspace.message = ""
                self.tagWorkspace.signKey = ""
                self.tagWorkspace.annotated = false
                self.tagWorkspace.force = false
                self.tagWorkspace.repositoryOverride = nil
                self.tagWorkspace.feedback = "已创建 \(name)"
                self.feedbackCenter.success(
                    "Tag created",
                    detail: targetRootPath.map { "\(name) @ \($0)" } ?? name
                )
                if self.projectWorkspace.toolWindowMode == .log { self.loadLog() }
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.tagWorkspace.feedback = detail
                let signingAction = !signKey.isEmpty
                    || gitCommitSigningFailureNeedsGPGConfiguration(detail)
                    ? [self.gpgAgentSettingsFeedbackAction()]
                    : []
                self.feedbackCenter.error(
                    "Create tag failed",
                    detail: detail,
                    nextStep: !signKey.isEmpty
                        ? "Install GnuPG if needed, configure pinentry, then retry the signed tag."
                        : "Check the tag name and selected Git root, then retry.",
                    additionalActions: signingAction
                )
            }
        }
    }
}

func deleteTag(_ name: String) {
    guard let repo else { return }
    beginFeedbackOperation("Delete tag")
    Task.detached(priority: .userInitiated) {
        do {
            guard let tag = try repo.tagList().first(where: { $0.name == name }) else {
                throw NSError(
                    domain: "Arbor.TagDelete",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Tag not found: \(name)"]
                )
            }
            try repo.tagDelete(name: name)
            let tags = try repo.tagList()
            await MainActor.run {
                self.tagWorkspace.tags = tags
                self.tagWorkspace.feedback = "已删除 \(name)"
                self.tagWorkspace.deleteRecovery = TagDeleteRecoveryContext(repo: repo, tag: tag, rootPath: nil)
                if self.projectWorkspace.toolWindowMode == .log { self.loadLog() }
            }
        } catch {
            await MainActor.run { self.tagWorkspace.feedback = errorMessage(error) }
        }
    }
}

func stagePath(_ p: String) {
    guard let repo else { return }
    beginFeedbackOperation("Stage file")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stage(path: p)
            let st = try repo.statusPaths(paths: [p]); let hid = repo.headCommitId()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.applyIncrementalStatus(st, paths: [p]); self.repositoryStatus.headId = hid
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Changes staged")
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
}

/// Project-tree Git.Add must resolve the owning root at invocation time. The
/// tree is rendered from the primary worktree, but nested repositories may
/// appear in it and must never be staged through the parent repository.
func stageProjectTreePath(_ path: String) {
    guard let normalizedPath = normalizedRepositoryRelativePath(path),
          let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          !primaryRootPath.isEmpty else { return }
    let cachedRoots = multiRootWorkspace.roots
    beginFeedbackOperation("Add file")
    Task.detached(priority: .userInitiated) {
        do {
            let roots = cachedRoots.isEmpty
                ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
                : cachedRoots
            guard let target = fileReferenceComparisonTarget(
                path: normalizedPath,
                primaryRootPath: primaryRootPath,
                roots: roots
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The selected path is outside the discovered Git roots."]
                )
            }
            let targetRepo = canonicalExternalLogPath(primaryRootPath) == target.rootPath
                ? primaryRepo
                : try openRepository(path: target.rootPath)
            let currentStatus = try targetRepo.statusPaths(paths: [target.relativePath])
            guard projectFileTreeCanAdd(
                path: target.relativePath,
                isDirectory: false,
                entries: currentStatus
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The file is no longer an untracked, non-conflicted path."]
                )
            }
            try targetRepo.stage(path: target.relativePath)
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                self.loadMultiRootChanges()
                self.feedbackCenter.success("Added to Git", detail: normalizedPath)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Add failed",
                    detail: errorMessage(error),
                    nextStep: "Refresh the project tree and retry."
                )
            }
        }
    }
}

/// Git.Add from the main menu and the project-tree context menu share the same
/// invocation-time root and status validation. This keeps a stale menu state
/// from staging a newly modified tracked file.
func stageSelectedFileFromFileAction(_ file: ArborSelectedGitFileContext) {
    guard !file.isDirectory else { return }
    stageProjectTreePath(file.path)
}

func stageWithoutContent(_ p: String) {
    guard let repo else { return }
    beginFeedbackOperation("Stage without content")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stageWithoutContent(path: p)
            let st = try repo.statusPaths(paths: [p])
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.applyIncrementalStatus(st, paths: [p])
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Intent-to-add staged", detail: p)
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error(
                    "Intent-to-add failed",
                    detail: errorMessage(error),
                    nextStep: "选择一个未跟踪文件后重试。"
                )
            }
        }
    }
}

/// Batch Git.Stage.Add.No.Content action for the untracked section. The
/// engine sends one `git add -N -- <paths>` command so the index update has
/// the same all-or-nothing command boundary as IntelliJ's batch action.
func stageWithoutContentAll() {
    guard let repo else { return }
    let paths = untrackedEntries.map(\.path)
    guard !paths.isEmpty else { return }
    beginFeedbackOperation("Stage untracked without content")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stageWithoutContentPaths(paths: paths)
            let status = try repo.status()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.repositoryStatus.entries = status
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.fileWorkspace.refreshToken &+= 1
                self.feedbackCenter.success("Intent-to-add staged", detail: "\(paths.count) untracked files")
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error(
                    "Intent-to-add failed",
                    detail: errorMessage(error),
                    nextStep: "选择未跟踪文件后重试。"
                )
            }
        }
    }
}

func unstagePath(_ p: String) {
    guard let repo else { return }
    beginFeedbackOperation("Unstage file")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.unstage(path: p)
            let st = try repo.statusPaths(paths: [p]); let hid = repo.headCommitId()
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.applyIncrementalStatus(st, paths: [p]); self.repositoryStatus.headId = hid
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Changes unstaged")
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
}

/// Revert only the unstaged side of a file. This deliberately restores from
/// the index instead of HEAD so a partially staged file keeps its staged
/// content intact.
func revertUnstagedPath(_ p: String) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = "Revert unstaged changes?"
    alert.informativeText = "This restores \(p) to the staged version and keeps the index unchanged."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Revert")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Revert unstaged changes")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.restoreUnstagedPath(path: p)
            let status = try repo.statusPaths(paths: [p])
            let staging = try? repo.stagingModel()
            await MainActor.run {
                self.applyIncrementalStatus(status, paths: [p])
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.feedbackCenter.success("Unstaged changes reverted", detail: p)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Revert unstaged changes failed",
                    detail: errorMessage(error),
                    nextStep: "检查文件是否仍有未暂存内容后重试。"
                )
            }
        }
    }
}

/// BRANCH-001：Tag 检出（detached HEAD）。
func checkoutTag(_ name: String) {
    guard let repo else { return }
    beginFeedbackOperation("Checkout tag")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.checkoutDetached(commitId: name)
            await MainActor.run { self.feedbackCenter.success("Checked out tag", detail: name) }
            await MainActor.run { self.refreshAll(showFeedback: false) }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: name,
                    detail: detail,
                    onSmart: { self.smartCheckoutDetached(repo: repo, revision: name) },
                    onForce: { self.forceCheckoutDetached(repo: repo, revision: name) }
                )
            }
        }
    }
}

/// Stage one path in the Git root that owns the aggregate Changes row.
/// This deliberately opens the supplied root instead of using `repo`, which
/// is only the primary repository of the current window.
func stageMultiRootPath(rootPath: String, path: String) {
    let retryAction = multiRootChangesRetryFeedbackAction(
        operation: .stage,
        rootPath: rootPath,
        path: path
    )
    let notificationID = multiRootChangesMutationNotificationID(
        operation: .stage,
        rootPath: rootPath,
        path: path
    )
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.error(
            "Stage failed",
            detail: "\(rootPath): \(path)\nUnable to open the owning Git root.",
            nextStep: "Check the root, then retry staging.",
            additionalActions: [retryAction],
            notificationID: notificationID
        )
        return
    }
    beginFeedbackOperation("Stage file · \(rootPath)")
    Task.detached(priority: .userInitiated) {
        do {
            try rootRepo.stage(path: path)
            await MainActor.run {
                self.feedbackCenter.success(
                    "Changes staged",
                    detail: "\(rootPath): \(path)",
                    notificationID: notificationID
                )
                self.loadMultiRootChanges()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Stage failed",
                    detail: "\(rootPath): \(path)\n\(errorMessage(error))",
                    nextStep: "Check the file, then retry staging.",
                    additionalActions: [retryAction],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Unstage one path in its owning Git root without touching any other root.
func unstageMultiRootPath(rootPath: String, path: String) {
    let retryAction = multiRootChangesRetryFeedbackAction(
        operation: .unstage,
        rootPath: rootPath,
        path: path
    )
    let notificationID = multiRootChangesMutationNotificationID(
        operation: .unstage,
        rootPath: rootPath,
        path: path
    )
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.error(
            "Unstage failed",
            detail: "\(rootPath): \(path)\nUnable to open the owning Git root.",
            nextStep: "Check the root, then retry unstaging.",
            additionalActions: [retryAction],
            notificationID: notificationID
        )
        return
    }
    beginFeedbackOperation("Unstage file · \(rootPath)")
    Task.detached(priority: .userInitiated) {
        do {
            try rootRepo.unstage(path: path)
            await MainActor.run {
                self.feedbackCenter.success(
                    "Changes unstaged",
                    detail: "\(rootPath): \(path)",
                    notificationID: notificationID
                )
                self.loadMultiRootChanges()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unstage failed",
                    detail: "\(rootPath): \(path)\n\(errorMessage(error))",
                    nextStep: "Check the file, then retry unstaging.",
                    additionalActions: [retryAction],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Apply a project-level Changes Browser selection without collapsing rows
/// from nested repositories into one relative-path list. Roots are processed
/// in stable order and each root's index is mutated serially; a failure does
/// not prevent unrelated roots or later selected files from being attempted.
func stageMultiRootPaths(_ selections: [MultiRootChangeSelection]) {
    runMultiRootChangeMutation(
        operation: .stage,
        paths: selections.map(PersistedMultiRootChangePath.init)
    )
}

func unstageMultiRootPaths(_ selections: [MultiRootChangeSelection]) {
    runMultiRootChangeMutation(
        operation: .unstage,
        paths: selections.map(PersistedMultiRootChangePath.init)
    )
}

/// Stage all visible worktree changes belonging to one selected Git root.
func stageAllMultiRootPath(rootPath: String) {
    let retryAction = multiRootChangesRetryFeedbackAction(
        operation: .stageAll,
        rootPath: rootPath,
        path: nil
    )
    let notificationID = multiRootChangesMutationNotificationID(
        operation: .stageAll,
        rootPath: rootPath,
        path: nil
    )
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.error(
            "Stage all failed",
            detail: "\(rootPath)\nUnable to open the owning Git root.",
            nextStep: "Check the root, then retry staging.",
            additionalActions: [retryAction],
            notificationID: notificationID
        )
        return
    }
    beginFeedbackOperation("Stage all · \(rootPath)")
    Task.detached(priority: .userInitiated) {
        do {
            try rootRepo.stageAll()
            await MainActor.run {
                self.feedbackCenter.success(
                    "Root changes staged",
                    detail: rootPath,
                    notificationID: notificationID
                )
                self.loadMultiRootChanges()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Stage all failed",
                    detail: "\(rootPath)\n\(errorMessage(error))",
                    nextStep: "Check the root, then retry staging.",
                    additionalActions: [retryAction],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Unstage all indexed changes belonging to one selected Git root.
func unstageAllMultiRootPath(rootPath: String) {
    let retryAction = multiRootChangesRetryFeedbackAction(
        operation: .unstageAll,
        rootPath: rootPath,
        path: nil
    )
    let notificationID = multiRootChangesMutationNotificationID(
        operation: .unstageAll,
        rootPath: rootPath,
        path: nil
    )
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.error(
            "Unstage all failed",
            detail: "\(rootPath)\nUnable to open the owning Git root.",
            nextStep: "Check the root, then retry unstaging.",
            additionalActions: [retryAction],
            notificationID: notificationID
        )
        return
    }
    beginFeedbackOperation("Unstage all · \(rootPath)")
    Task.detached(priority: .userInitiated) {
        do {
            try rootRepo.unstageAll()
            await MainActor.run {
                self.feedbackCenter.success(
                    "Root changes unstaged",
                    detail: rootPath,
                    notificationID: notificationID
                )
                self.loadMultiRootChanges()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unstage all failed",
                    detail: "\(rootPath)\n\(errorMessage(error))",
                    nextStep: "Check the root, then retry unstaging.",
                    additionalActions: [retryAction],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Tag checkout is detached and uses the selected root's own Smart/Force
/// recovery path.
func checkoutTagInRoot(rootPath: String, name: String) {
    beginFeedbackOperation("Checkout tag")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.checkoutDetached(commitId: name)
            await MainActor.run {
                self.feedbackCenter.success("Checked out tag", detail: "\(name) · \(rootPath)")
                self.loadMultiRoots()
            }
        } catch {
            let detail = errorMessage(error)
            do {
                let rootRepo = try openRepository(path: rootPath)
                await MainActor.run {
                    self.presentCheckoutRecovery(
                        repo: rootRepo,
                        name: name,
                        detail: detail,
                        onSmart: { self.smartCheckoutRevisionInRoot(rootPath: rootPath, revision: name) },
                        onForce: { self.forceCheckoutRevisionInRoot(rootPath: rootPath, revision: name) }
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error("Tag checkout failed", detail: "\(name) · \(rootPath): \(detail)")
                }
            }
        }
    }
}

/// IntelliJ's multi-ref delete action includes tags alongside branches. Keep
/// the tag batch root-qualified and reuse the existing restore/remote-delete
/// recovery surface instead of treating tag deletion as an irreversible
/// branch-only operation.
func deleteSelectedTagsInRoots(_ targets: [BranchDashboardReference]) {
    let selected = targets
        .filter { $0.kind == .tag && !$0.isCurrent }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.name < $1.name }
            return $0.rootPath < $1.rootPath
        }
    guard !selected.isEmpty, !multiRootWorkspace.running else { return }

    let alert = NSAlert()
    alert.messageText = "Delete selected tags?"
    alert.informativeText = selected
        .map { "\($0.name) · \($0.rootPath)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    multiRootWorkspace.running = true
    beginFeedbackOperation("Delete selected tags")
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var contexts: [TagDeleteRecoveryContext] = []
        var failures: [String] = []

        for target in selected {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard let tag = try rootRepo.tagList().first(where: { $0.name == target.name }) else {
                    throw NSError(
                        domain: "Arbor.TagDelete",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Tag not found: \(target.name)"]
                    )
                }
                try rootRepo.tagDelete(name: target.name)
                contexts.append(
                    TagDeleteRecoveryContext(
                        repo: rootRepo,
                        tag: tag,
                        rootPath: target.rootPath
                    )
                )
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: true,
                        skipped: false,
                        message: "Deleted tag \(target.name)"
                    )
                )
            } catch {
                let detail = "\(target.name) · \(target.rootPath): \(errorMessage(error))"
                failures.append(detail)
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: false,
                        skipped: false,
                        message: detail
                    )
                )
            }
        }

        let completedResults = results
        let completedContexts = contexts
        let completedFailures = failures
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.multiRootWorkspace.results = completedResults
            self.loadMultiRoots()
            if !completedContexts.isEmpty {
                self.tagWorkspace.multiRootDeleteRecovery = MultiRootTagDeleteRecoveryContext(
                    tagName: "selected tags",
                    contexts: completedContexts
                )
            }
            if completedFailures.isEmpty {
                self.feedbackCenter.success(
                    "Selected tag deletion completed",
                    detail: "\(completedContexts.count) tags"
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Selected tag deletion partially completed",
                    detail: completedFailures.joined(separator: "\n"),
                    nextStep: completedContexts.isEmpty
                        ? "Review the failed tags and retry them individually."
                        : "Use Restore All if you need to recover the deleted tags."
                )
            }
        }
    }
}

func deleteTagInRoot(rootPath: String, name: String) {
    let alert = NSAlert()
    alert.messageText = "Delete tag \(name)?"
    alert.informativeText = "This removes the local tag in the selected root."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Delete tag")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard let tag = try rootRepo.tagList().first(where: { $0.name == name }) else {
                throw NSError(
                    domain: "Arbor.TagDelete",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Tag not found: \(name)"]
                )
            }
            try rootRepo.tagDelete(name: name)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Tag deleted", detail: "\(name) · \(rootPath)")
                self.tagWorkspace.deleteRecovery = TagDeleteRecoveryContext(
                    repo: rootRepo,
                    tag: tag,
                    rootPath: rootPath
                )
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Delete tag failed", detail: "\(name) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

func presentMultiRootDeleteTagDialog(name: String) {
    let eligible = multiRootWorkspace.branchSnapshots.filter { snapshot in
        snapshot.tags.contains { $0.name == name }
    }
    guard !eligible.isEmpty else {
        feedbackCenter.warning(
            "Delete tag unavailable",
            detail: "No Git root contains \(name)."
        )
        return
    }
    tagWorkspace.multiRootDeleteName = name
    tagWorkspace.multiRootDeleteSelectedRootPaths = Set(eligible.map(\.rootPath))
    tagWorkspace.showMultiRootDeleteDialog = true
}

func dismissMultiRootDeleteTagDialog() {
    tagWorkspace.showMultiRootDeleteDialog = false
    tagWorkspace.multiRootDeleteName = ""
    tagWorkspace.multiRootDeleteSelectedRootPaths = []
}

/// Delete one local tag from selected Git roots while retaining the exact
/// peeled target for Restore All and the follow-up remote-delete action.
func deleteMultiRootTag(name: String, selectedRootPaths: Set<String>) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    let tagName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tagName.isEmpty else { return }
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.tags.contains { $0.name == tagName }
    }
    guard !roots.isEmpty else { return }
    multiRootWorkspace.running = true
    beginFeedbackOperation("Multi-root tag deletion")
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var contexts: [TagDeleteRecoveryContext] = []
        var failures: [String] = []
        for snapshot in roots {
            do {
                let rootRepo = try openRepository(path: snapshot.rootPath)
                guard let tag = try rootRepo.tagList().first(where: { $0.name == tagName }) else {
                    throw NSError(
                        domain: "Arbor.TagDelete",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Tag not found: \(tagName)"]
                    )
                }
                try rootRepo.tagDelete(name: tagName)
                contexts.append(
                    TagDeleteRecoveryContext(
                        repo: rootRepo,
                        tag: tag,
                        rootPath: snapshot.rootPath
                    )
                )
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: true,
                        skipped: false,
                        message: "Deleted \(tagName)"
                    )
                )
            } catch {
                let detail = "\(snapshot.displayName): \(errorMessage(error))"
                failures.append(detail)
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: false,
                        skipped: false,
                        message: errorMessage(error)
                    )
                )
            }
        }
        let resultsToApply = results
        let contextsToOffer = contexts
        let failuresToReport = failures
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.tagWorkspace.showMultiRootDeleteDialog = false
            self.multiRootWorkspace.results = resultsToApply
            self.loadMultiRoots()
            if !contextsToOffer.isEmpty {
                self.tagWorkspace.multiRootDeleteRecovery = MultiRootTagDeleteRecoveryContext(
                    tagName: tagName,
                    contexts: contextsToOffer
                )
            }
            if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root tag deletion completed",
                    detail: "\(contextsToOffer.count) repositories · \(tagName)"
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Multi-root tag deletion partially completed",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: contextsToOffer.isEmpty
                        ? "Review the affected roots and retry the operation."
                        : "Use Restore All if you need to recover the deleted local tags."
                )
            }
        }
    }
}

func renameTagInRoot(rootPath: String, name: String) {
    let alert = NSAlert()
    alert.messageText = "Rename Tag"
    let field = NSTextField(string: name)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != name else { return }
    beginFeedbackOperation("Rename tag")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.tagRename(old: name, new: newName)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Tag renamed", detail: "\(name) → \(newName) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Rename tag failed", detail: "\(name) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

/// Phase 5：重命名 tag。
func tagRename(_ old: String, _ new: String) {
    guard let repo, !new.isEmpty else { return }
    beginFeedbackOperation("Rename tag")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.tagRename(old: old, new: new)
            await MainActor.run {
                self.feedbackCenter.success("Tag renamed", detail: "\(old) → \(new)")
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Rename tag failed", detail: errorMessage(error), nextStep: "检查 tag 名后重试。")
            }
        }
    }
}

/// Phase 5：删除 tag。
func tagDelete(_ name: String) {
    guard let repo else { return }
    beginFeedbackOperation("Delete tag")
    Task.detached(priority: .userInitiated) {
        do {
            guard let tag = try repo.tagList().first(where: { $0.name == name }) else {
                throw NSError(
                    domain: "Arbor.TagDelete",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Tag not found: \(name)"]
                )
            }
            try repo.tagDelete(name: name)
            await MainActor.run {
                self.feedbackCenter.success("Tag deleted", detail: name)
                self.tagWorkspace.deleteRecovery = TagDeleteRecoveryContext(repo: repo, tag: tag, rootPath: nil)
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Delete tag failed", detail: errorMessage(error), nextStep: "tag 可能已被删除。")
            }
        }
    }
}

}
