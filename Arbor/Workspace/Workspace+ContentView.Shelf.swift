import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Reload the selected secondary root's complete Shelf state after an
/// external Git metadata change. The generation guard prevents an older VFS
/// event from replacing a newer root selection or a newer refresh result.
func reloadSecondaryShelfSnapshot(rootPath: String) {
    let normalizedRootPath = canonicalExternalLogPath(rootPath)
    guard activeShelfRootPath == normalizedRootPath,
          !shelfRootSelectionIsPrimary(
              selectedRootPath: normalizedRootPath,
              primaryRootPath: primaryShelfRootPath
          ) else { return }

    shelfRootLoadGeneration += 1
    let generation = shelfRootLoadGeneration
    shelfRootLoading = true
    Task.detached(priority: .utility) {
        do {
            let rootRepo = try openRepository(path: normalizedRootPath)
            let rootShelves = try rootRepo.shelveList()
            let rootDeletedShelves = (try? rootRepo.shelveDeletedList()) ?? []
            let rootChangeLists = (try? rootRepo.changelistList()) ?? []
            await MainActor.run {
                guard self.shelfRootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedRootPath else { return }
                self.shelfRootRepository = rootRepo
                self.shelfRootSnapshots[normalizedRootPath] = ShelfRootSnapshot(
                    rootPath: normalizedRootPath,
                    shelves: rootShelves,
                    deletedShelves: rootDeletedShelves,
                    changeLists: rootChangeLists
                )
                self.shelfRootError = nil
                self.shelfRootLoading = false
            }
        } catch {
            await MainActor.run {
                guard self.shelfRootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedRootPath else { return }
                self.shelfRootError = "Refresh Shelf for "
                    + normalizedRootPath
                    + " failed: "
                    + errorMessage(error)
                self.shelfRootLoading = false
            }
        }
    }
}

/// Restore selected historical file versions into both the index and worktree.
/// This is the Changes Browser's `Vcs.GetVersion` action. IntelliJ accepts the
/// complete selected-change set, so a single confirmation covers multi-file,
/// multi-commit, and multi-root selections.
func restoreSelectedFilesFromRevisions(_ records: [LogChangeRecord]) {
    guard !records.isEmpty else { return }
    let requests = records.compactMap { record -> (Repository, String, String, String)? in
        guard let repo = logRepository(for: record.commit) else { return nil }
        return (
            repo,
            record.change.path,
            record.commit.id,
            "\(record.commit.repositoryPath ?? "Git root") · \(record.commit.shortId) · \(record.change.path)"
        )
    }
    guard !requests.isEmpty else { return }

    let alert = NSAlert()
    alert.messageText = records.count == 1 ? "Get file version?" : "Get file versions?"
    let rootCount = max(
        1,
        Set(records.compactMap(\.commit.repositoryPath).filter { !$0.isEmpty }).count
    )
    alert.informativeText = "Replace the index and working tree copies of \(requests.count) file(s) from \(rootCount) Git root(s)?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: records.count == 1 ? "Get Version" : "Get Versions")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    beginFeedbackOperation(records.count == 1 ? "Get file version" : "Get file versions")
    Task.detached(priority: .userInitiated) {
        var restoredCount = 0
        var failures: [String] = []
        for (repo, path, revision, label) in requests {
            do {
                try repo.restoreFile(path: path, revision: revision)
                restoredCount += 1
            } catch {
                failures.append("\(label): \(errorMessage(error))")
            }
        }

        let restored = restoredCount
        let failed = failures
        await MainActor.run {
            self.refreshAll(showFeedback: false)
            if failed.isEmpty {
                self.feedbackCenter.success(
                    restored == 1 ? "File restored" : "Files restored",
                    detail: "\(restored) file(s)"
                )
            } else if restored > 0 {
                self.feedbackCenter.warning(
                    "Some files could not be restored",
                    detail: "Restored \(restored); failed \(failed.count). \(failed.joined(separator: " | "))",
                    nextStep: "Check the selected revisions and retry the failed files."
                )
            } else {
                self.feedbackCenter.error(
                    "Get file versions failed",
                    detail: failed.joined(separator: " | "),
                    nextStep: "Check the selected revisions and retry."
                )
            }
        }
    }
}

/// A Drop/Extract rewrite can finish its history edit and still fail while
/// replaying the user's saved local scene. The engine leaves a stable
/// history-rewrite marker and the exact stash; open the same root-scoped
/// resolver used by the other preserving operations instead of leaving only
/// a generic error and a stash hint.
func presentLogSelectedChangesRestoreConflict(rootPath: String) {
    guard !rootPath.isEmpty else { return }
    Task.detached(priority: .utility) {
        guard let rootRepo = try? openRepository(path: rootPath),
              let info = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil,
              info.operation == "history-rewrite" else { return }
        let paths = ((try? rootRepo.status()) ?? [])
            .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
            .map(\.path)
        await MainActor.run {
            self.openMultiRootConflictResolver(
                preferredRootPath: rootPath,
                preferredPath: paths.first
            )
        }
    }
}

func restoreSelectedFile() {
    // The Commit workspace keeps its selected row in `commitPreviewPath` so the
    // main Log selection can remain independent.  Fall back to the older
    // selection channels for Project/Conflict workspaces.
    guard let path = commitPreviewPath ?? selection ?? fileSelection else { return }
    restoreFileFromHead(path)
}

/// Restore is a tree action in GitStagePanel, not a global toolbar action.
/// Keep the selected-file wrapper for keyboard/legacy callers, but let the
/// tree context menu pass its path directly so a context-menu click cannot
/// race the asynchronous row-selection state update.
func restoreFileFromHead(
    _ path: String,
    prompt: String = "Restore file from HEAD?",
    confirmTitle: String = "Restore",
    feedbackTitle: String = "File restored"
) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = prompt
    alert.informativeText = "This restores \(path) in both the index and working tree."
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Restore file")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.restoreFile(path: path, revision: nil)
            await MainActor.run {
                self.feedbackCenter.success(feedbackTitle, detail: path)
                self.selection = nil
                self.commitPreviewPath = nil
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Restore file failed", detail: errorMessage(error), nextStep: "Check the selected path and retry.")
            }
        }
    }
}

/// Project-tree Revert is the same tracked-file operation as ChangesView's
/// Revert, but resolves nested Git roots before touching the index/worktree.
func restoreProjectTreePath(_ path: String) {
    guard let normalizedPath = normalizedRepositoryRelativePath(path),
          let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          !primaryRootPath.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Revert file?"
    alert.informativeText = "This restores \(normalizedPath) in both the index and working tree."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Revert")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let cachedRoots = multiRoots
    beginFeedbackOperation("Revert file")
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
            guard projectFileTreeCanRevert(
                path: target.relativePath,
                isDirectory: false,
                entries: currentStatus
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The file is no longer a tracked, non-conflicted change."]
                )
            }
            try targetRepo.restoreFile(path: target.relativePath, revision: nil)
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                self.loadMultiRootChanges()
                self.feedbackCenter.success("File reverted", detail: normalizedPath)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Revert failed",
                    detail: errorMessage(error),
                    nextStep: "Check that the file is a tracked, non-conflicted change, then retry."
                )
            }
        }
    }
}

func publishShelfSnapshot(
    rootPath: String,
    shelves: [ShelveInfo],
    deletedShelves: [ShelveInfo],
    changeLists: [ChangeListInfo]? = nil
) {
    let normalizedRootPath = canonicalExternalLogPath(rootPath)
    if shelfRootSelectionIsPrimary(
        selectedRootPath: normalizedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) {
        self.shelves = shelves
        self.deletedShelves = deletedShelves
        if let changeLists {
            self.changeLists = changeLists
        }
    } else if activeShelfRootPath == normalizedRootPath {
        let previousChangeLists = shelfRootSnapshots[normalizedRootPath]?.changeLists ?? []
        shelfRootSnapshots[normalizedRootPath] = ShelfRootSnapshot(
            rootPath: normalizedRootPath,
            shelves: shelves,
            deletedShelves: deletedShelves,
            changeLists: changeLists ?? previousChangeLists
        )
    }
}

/// Select the repository whose Shelves are shown in the Commit workspace.
/// Secondary roots keep their own snapshot and repository so metadata-only
/// Shelf mutations cannot accidentally target the primary repository.
func setShelfRoot(_ rootPath: String) {
    let normalizedPath = canonicalExternalLogPath(rootPath)
    let primaryPath = primaryShelfRootPath
    guard availableShelfRoots.contains(where: {
        canonicalExternalLogPath($0.path) == normalizedPath
    }) else {
        return
    }

    shelfRootLoadGeneration += 1
    let generation = shelfRootLoadGeneration
    shelfRootError = nil
    shelfPreviewName = nil
    shelfPreviewRootPath = nil
    shelfPreviewText = nil
    shelfPreviewIsDeleted = false
    showShelfPreview = false

    if normalizedPath == primaryPath {
        shelfRootPath = nil
        shelfRootRepository = nil
        shelfRootLoading = false
        return
    }

    shelfRootPath = normalizedPath
    shelfRootRepository = nil
    shelfRootLoading = true
    if shelfRootSnapshots[normalizedPath] == nil,
       let snapshot = multiRootBranchSnapshots.first(where: {
           canonicalExternalLogPath($0.rootPath) == normalizedPath
       }) {
        shelfRootSnapshots[normalizedPath] = ShelfRootSnapshot(
            rootPath: normalizedPath,
            shelves: snapshot.shelves,
            deletedShelves: [],
            changeLists: []
        )
    }

    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: normalizedPath)
            let rootShelves = try rootRepo.shelveList()
            let rootDeletedShelves = (try? rootRepo.shelveDeletedList()) ?? []
            let rootChangeLists = (try? rootRepo.changelistList()) ?? []
            await MainActor.run {
                guard self.shelfRootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedPath else { return }
                self.shelfRootRepository = rootRepo
                self.shelfRootSnapshots[normalizedPath] = ShelfRootSnapshot(
                    rootPath: normalizedPath,
                    shelves: rootShelves,
                    deletedShelves: rootDeletedShelves,
                    changeLists: rootChangeLists
                )
                self.shelfRootLoading = false
            }
        } catch {
            await MainActor.run {
                guard self.shelfRootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedPath else { return }
                self.shelfRootRepository = nil
                self.shelfRootLoading = false
                self.shelfRootError = "Load Shelf for "
                    + normalizedPath
                    + " failed: "
                    + errorMessage(error)
            }
        }
    }
}

/// Load the active repository's Shelf location before presenting the settings
/// sheet. The location is repository-scoped, so a secondary Git root must be
/// resolved through the same context used by every other Shelf mutation.
func presentShelfLocationSettings() {
    guard let rootPath = activeShelfRootPath,
          let shelfRepo = activeShelfRepository,
          canMutateShelfMetadata else { return }
    do {
        let location = try shelfRepo.shelveLocation()
        shelfLocationCurrent = location
        shelfLocationValue = location
        shelfLocationMigrateExisting = true
        showShelfLocationDialog = true
    } catch {
        feedbackCenter.error(
            "Load Shelf location failed",
            detail: errorMessage(error),
            notificationID: shelfMetadataNotificationID(operation: "location", rootPath: rootPath)
        )
    }
}

/// Switch the active repository to a custom Shelf directory. The Rust engine
/// performs copy-then-marker migration and leaves Git refs in place; this
/// method only refreshes the root snapshot after that transaction succeeds.
func setShelfLocation(
    _ location: String,
    migrateExisting: Bool,
    rootPath: String?
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepo = context.repository
    let resolvedRootPath = context.rootPath
    let requested = location.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requested.isEmpty else { return }
    beginFeedbackOperation("Change Shelf location")
    Task.detached(priority: .userInitiated) {
        do {
            let resolved = try shelfRepo.shelveSetLocation(
                location: requested,
                migrateExisting: migrateExisting
            )
            let nextShelves = try shelfRepo.shelveList()
            let nextDeletedShelves = (try? shelfRepo.shelveDeletedList()) ?? []
            let nextChangeLists = (try? shelfRepo.changelistList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.shelfLocationCurrent = resolved
                self.shelfLocationValue = resolved
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: nextShelves,
                    deletedShelves: nextDeletedShelves,
                    changeLists: nextChangeLists
                )
                self.feedbackCenter.success(
                    "Shelf location changed",
                    detail: resolved,
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "location",
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Change Shelf location failed",
                    detail: errorMessage(error),
                    nextStep: "Choose an empty directory or retry the migration after checking its permissions.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "location",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// Restore the single-root rebase seed that was written when Arbor paused a
/// rebase entry point. Git keeps the operation itself in `.git/rebase-*`, but
/// that state does not contain Arbor's expected-HEAD undo boundary or the
/// original `--update-refs` policy. Do not synthesize a seed for an operation
/// created outside Arbor: without those facts, offering Undo would be unsafe.
func restorePersistedSingleRootRebaseState(for repositoryPath: String) {
    guard multiRootRebaseSession == nil,
          let seed = loadRebaseUndoSeed(repositoryPath: repositoryPath) else { return }
    Task.detached(priority: .utility) {
        do {
            let rootRepo = try openRepository(path: repositoryPath)
            guard let state = try rootRepo.operationState(), state.kind == .rebase else {
                clearRebaseUndoSeed(repositoryPath: repositoryPath)
                return
            }
            let status = try rootRepo.status()
            let pauseReason: RebasePauseReason = state.conflictedFiles.isEmpty ? .edit : .conflict
            await MainActor.run {
                guard self.multiRootRebaseSession == nil else { return }
                let isCurrentRoot = self.repo?.workdir().map({
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }) == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
                if isCurrentRoot {
                    self.rebaseUndoSeed = seed
                    self.rebaseRootPath = repositoryPath
                    self.rebaseBranch = seed.branch
                    self.rebasePaused = true
                    self.rebasePauseReason = pauseReason
                    self.rebaseConflicts = state.conflictedFiles
                    self.operationState = state
                    self.entries = status
                    if pauseReason == .conflict {
                        self.showMergeRevisionsDialog = true
                    }
                }
                let request = ArborVCSActionRequest(
                    kind: .resumeRebase,
                    projectPath: repositoryPath,
                    rootPath: repositoryPath,
                    shelfName: "",
                    rebaseBranch: seed.branch
                )
                let detail = state.conflictedFiles.isEmpty
                    ? "\(seed.branch): rebase paused at edit"
                    : "\(seed.branch): \(state.conflictedFiles.count) unresolved file(s)"
                self.feedbackCenter.warning(
                    "Rebase recovery available",
                    detail: detail,
                    nextStep: "Continue or abort the paused rebase from the recovery workbench.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Open Rebase Recovery",
                            semanticAction: request
                        ) {
                            self.openPersistedRebaseRecovery(
                                rootPath: repositoryPath,
                                branch: seed.branch
                            )
                        }
                    ],
                    notificationID: rebaseRecoveryNotificationID(repositoryPath: repositoryPath)
                )
            }
        } catch {
            // A later project refresh will retry. Never keep a stale seed when
            // the repository cannot be opened or its operation state vanished.
            clearRebaseUndoSeed(repositoryPath: repositoryPath)
        }
    }
}

/// Rehydrate the local-change preservation paired with Pull. Unlike Git's
/// rebase/merge state, the temporary Shelf/Stash is an Arbor concern, so its
/// association must be persisted separately from the operation itself.
func restorePersistedPullPreservation(for repositoryPath: String) {
    guard let preservation = loadPendingPullPreservation(repositoryPath: repositoryPath) else {
        return
    }
    Task.detached(priority: .utility) {
        do {
            let rootRepo = try openRepository(path: repositoryPath)
            let preservationStillExists: Bool
            if let shelfName = preservation.shelfName {
                preservationStillExists = try rootRepo.shelveList().contains { $0.name == shelfName }
            } else if let stashID = preservation.stashID {
                preservationStillExists = try rootRepo.stashList().contains { $0.id == stashID }
            } else if let stashMessage = preservation.stashMessage {
                preservationStillExists = try rootRepo.stashList().contains { $0.message == stashMessage }
            } else {
                preservationStillExists = false
            }
            guard preservationStillExists else {
                clearPendingPullPreservation(repositoryPath: repositoryPath)
                return
            }
            let state = try? rootRepo.operationState()
            await MainActor.run {
                guard self.projectRepo?.workdir().map({
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }) == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path else {
                    return
                }
                self.pendingPullShelfName = preservation.shelfName
                self.pendingPullStashPop = preservation.stashID != nil || preservation.stashMessage != nil
                self.pendingPullStashID = preservation.stashID
                self.pendingPullStashMessage = preservation.stashMessage
                guard state == nil else { return }
                self.feedbackCenter.warning(
                    "Pull local changes pending",
                    detail: preservation.shelfName ?? preservation.stashMessage,
                    nextStep: "Restore the local changes saved before Pull.",
                    actionTitle: "Restore Pull Changes",
                    action: { self.popPendingPullStash() },
                    notificationID: pendingPullPreservationNotificationID(repositoryPath: repositoryPath)
                )
            }
        } catch {
            // A later refresh can retry. Do not delete the marker merely
            // because the repository was temporarily unavailable.
        }
    }
}

func finishPendingPullRebaseRestore(
    seed: RebaseUndoSeed?,
    target: RebaseUndoTarget?
) {
    guard let seed else { return }
    rebasePaused = false
    rebasePauseReason = nil
    rebaseConflicts = []
    rebaseUndoSeed = nil
    rebaseUndoTarget = target
    clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
}

/// Rehydrate preserving-process restore markers after launch. The marker is
/// written before Merge/Reset/Cherry-pick/Revert/Rebase changes the worktree,
/// so a process crash must leave an actionable path back to the same saved
/// stash or Shelf instead of silently looking like an ordinary dirty repository.
func scanPendingApplyRestores() {
    guard let projectPath else { return }
    Task.detached(priority: .utility) {
        do {
            let roots = try discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            var pending: [(
                rootPath: String,
                displayName: String,
                operation: String,
                kind: String,
                identifier: String,
                paths: [String]
            )] = []
            for root in roots {
                guard let rootRepo = try? openRepository(path: root.path),
                      let info = ((try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil)
                        ?? ((try? rootRepo.rebaseLocalChangesRestoreInfo()) ?? nil) else { continue }
                let paths = ((try? rootRepo.status()) ?? [])
                    .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                    .map(\.path)
                    .sorted()
                let savedArtifactExists: Bool? = {
                    switch info.kind {
                    case "stash":
                        guard let stashes = try? rootRepo.stashList() else { return nil }
                        return stashes.contains { $0.id == info.identifier }
                    case "shelf":
                        guard let shelves = try? rootRepo.shelveList() else { return nil }
                        return shelves.contains { $0.name == info.identifier }
                    default:
                        return nil
                    }
                }()
                if info.operation == "submodule-update",
                   paths.isEmpty,
                   savedArtifactExists == false {
                    // If restore already consumed the artifact and the app
                    // died just before clearing the marker, finalize the
                    // marker silently instead of surfacing a false recovery.
                    _ = try? rootRepo.finalizeApplyLocalChangesRestore()
                    continue
                }
                pending.append((root.path, root.displayName, info.operation, info.kind, info.identifier, paths))
            }
            let pendingItems = pending
            await MainActor.run {
                guard self.projectPath == projectPath else { return }
                for item in pendingItems {
                    guard let savedChangesKind = ArborVCSActionRequest.SavedChangesKind(rawValue: item.kind) else {
                        continue
                    }
                    let request = ArborVCSActionRequest(
                        kind: .restoreApplyLocalChanges,
                        projectPath: projectPath,
                        rootPath: item.rootPath,
                        shelfName: "",
                        savedChangesKind: savedChangesKind,
                        savedChangesID: item.identifier
                    )
                    let affected = item.paths.isEmpty
                        ? item.identifier
                        : item.paths.joined(separator: ", ")
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: savedChangesKind,
                        identifier: item.identifier,
                        rootPath: item.rootPath
                    )
                    let resolveAction: FeedbackAction? = item.operation == "rebase"
                        ? nil
                        : FeedbackAction(
                            title: "Resolve local changes",
                            semanticAction: request
                        ) {
                            self.openApplyLocalChangesRestore(request)
                        }
                    self.feedbackCenter.warning(
                        "Saved local changes need restoration",
                        detail: "\(item.displayName): \(item.operation) · \(affected)",
                        nextStep: "Resolve the saved local changes in the Git Roots conflict workbench.",
                        additionalActions: [viewAction, resolveAction].compactMap { $0 },
                        notificationID: "arbor.apply-restore.\(item.rootPath.replacingOccurrences(of: "/", with: "_"))"
                    )
                }
            }
        } catch {
            // A later root refresh will retry this scan. Do not replace a
            // usable project shell with a startup-only marker error.
        }
    }
}

/// Route a typed preserving-operation restore failure to the root-scoped
/// workbench. The apply marker identifies the exact saved artifact; the
/// conflict paths come from the failed restore when available. Pull uses the
/// same marker after a selected secondary root completes Merge/Rebase.
func presentMultiRootMergeRestoreConflict(
    rootPath: String,
    paths: [String],
    stashID: String? = nil
) {
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard let info = try rootRepo.applyLocalChangesRestoreInfo() else {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Saved local changes unavailable",
                        detail: "\(rootPath): the preservation marker is missing.",
                        nextStep: "Inspect that Git root's saved changes before continuing."
                    )
                }
                return
            }
            if info.kind == "shelf" {
                await MainActor.run {
                    self.openMultiRootConflictResolver(
                        preferredRootPath: rootPath,
                        preferredPath: paths.first
                    )
                }
            } else {
                let resolvedStashID = stashID ?? info.identifier
                guard let index = try rootRepo.stashList().firstIndex(where: {
                    $0.id == resolvedStashID
                }) else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Saved local changes unavailable",
                            detail: "\(rootPath): the temporary \(info.kind) for \(info.operation) could not be located.",
                            nextStep: "Inspect that Git root's saved changes before continuing."
                        )
                    }
                    return
                }
                await MainActor.run {
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: index,
                        stashID: resolvedStashID,
                        isPop: true,
                        paths: paths
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Saved local changes unavailable",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Open that Git root and resolve its saved local changes manually."
                )
            }
        }
    }
}

/// Rehydrate Smart Merge's per-root preservation marker after a merge result
/// reports a restore failure. The marker is authoritative; stash messages and
/// numeric positions are only used to connect the root to the existing
/// conflict workbench.
func presentMultiRootMergeRestoreConflicts(_ results: [MultiRootMergeResult]) {
    for result in results where !result.success {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                guard let info = try rootRepo.applyLocalChangesRestoreInfo(),
                      info.operation == "merge" else { return }
                let paths = try rootRepo.status()
                    .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                    .map(\.path)
                if info.kind == "shelf" {
                    await MainActor.run {
                        self.openMultiRootConflictResolver(
                            preferredRootPath: rootPath,
                            preferredPath: paths.first
                        )
                    }
                } else if let index = try rootRepo.stashList().firstIndex(where: {
                    $0.id == info.identifier
                }) {
                    await MainActor.run {
                        self.presentMultiRootStashConflict(
                            rootPath: rootPath,
                            index: index,
                            stashID: info.identifier,
                            isPop: true,
                            paths: paths
                        )
                    }
                } else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Merge local changes unavailable",
                            detail: "\(rootPath): the temporary \(info.kind) could not be located.",
                            nextStep: "Inspect that Git root's saved changes before changing its conflicted files."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Merge local changes unavailable",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Open that Git root and resolve its saved local changes manually."
                    )
                }
            }
        }
    }
}

/// Smart rollback can leave a reset preserving marker when the user's saved
/// changes conflict during restore. Reuse the project resolver immediately so
/// the failure is actionable before the next retry.
func presentMultiRootMergeRollbackRestoreConflict(
    _ targets: [MultiRootMergeRollbackTarget]
) {
    Task.detached(priority: .utility) {
        for target in targets {
            guard let rootRepo = try? openRepository(path: target.rootPath),
                  let info = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil,
                  info.operation == "reset" else {
                continue
            }
            let paths = ((try? rootRepo.status()) ?? [])
                .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                .map(\.path)
            await MainActor.run {
                self.openMultiRootConflictResolver(
                    preferredRootPath: target.rootPath,
                    preferredPath: paths.first
                )
            }
            return
        }
    }
}

func restoreDeletedBranchesFromSemanticTargets(
    _ targets: [PersistedBranchDeleteRecoveryTarget]
) {
    guard let normalizedTargets = normalizedBranchDeleteRecoveryTargets(targets) else { return }
    if let notificationID = branchDeleteNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
    branchDeleteRecovery = nil
    multiRootBranchDeleteRecovery = nil
    beginFeedbackOperation("Restore deleted branches")
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [PersistedBranchDeleteRecoveryTarget] = []
        var upstreamWarnings: [String] = []
        for target in normalizedTargets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                try rootRepo.branchCreate(
                    name: target.branchName,
                    at: target.tipID
                )
                if let upstream = target.upstream, !upstream.isEmpty {
                    do {
                        try rootRepo.branchSetUpstream(
                            branch: target.branchName,
                            upstream: upstream
                        )
                    } catch {
                        upstreamWarnings.append(
                            "\(target.rootPath): \(errorMessage(error))"
                        )
                    }
                }
            } catch {
                failures.append(
                    "\(target.rootPath): \(errorMessage(error))"
                )
                remaining.append(target)
            }
        }
        let failuresToReport = failures
        let remainingTargets = remaining
        let upstreamWarningsToReport = upstreamWarnings
        await MainActor.run {
            self.loadMultiRoots()
            if let currentRootPath = self.repo?.workdir().map({
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }), normalizedTargets.contains(where: { $0.rootPath == currentRootPath }) {
                self.loadRepoData()
            }
            if failuresToReport.isEmpty && upstreamWarningsToReport.isEmpty {
                self.feedbackCenter.success(
                    "Deleted branch restore completed",
                    detail: normalizedTargets.map { "\($0.branchName) · \($0.rootPath)" }.joined(separator: ", ")
                )
            } else {
                let details = failuresToReport + upstreamWarningsToReport
                self.feedbackCenter.warning(
                    "Deleted branch restore partially failed",
                    detail: details.joined(separator: "\n"),
                    nextStep: "Retry the remaining branch restore action.",
                    additionalActions: self.branchDeleteRestoreAction(
                        targets: remainingTargets,
                        title: "Retry Restore"
                    ).map { [$0] } ?? [],
                    notificationID: remainingTargets.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: remainingTargets.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

func restoreDeletedBranches(_ contexts: [BranchDeleteRecoveryContext]) {
    guard !contexts.isEmpty else { return }
    if let notificationID = branchDeleteNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
    multiRootBranchDeleteRecovery = nil
    beginFeedbackOperation("Restore multi-root branches")
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [BranchDeleteRecoveryContext] = []
        var upstreamWarnings: [String] = []
        for context in contexts {
            do {
                try context.repo.branchCreate(
                    name: context.preview.branchName,
                    at: context.preview.tipId
                )
                if let upstream = context.preview.upstream, !upstream.isEmpty {
                    do {
                        try context.repo.branchSetUpstream(
                            branch: context.preview.branchName,
                            upstream: upstream
                        )
                    } catch {
                        upstreamWarnings.append(
                            "\(context.rootPath ?? String(localized: "Repository")): \(errorMessage(error))"
                        )
                    }
                }
            } catch {
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")): \(errorMessage(error))"
                )
                remaining.append(context)
            }
        }
        let failuresToReport = failures
        let remainingContexts = remaining
        let upstreamWarningsToReport = upstreamWarnings
        await MainActor.run {
            self.loadMultiRoots()
            if failuresToReport.isEmpty && upstreamWarningsToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root branch restore completed",
                    detail: contexts.first?.preview.branchName ?? ""
                )
            } else {
                self.multiRootBranchDeleteRecovery = remainingContexts.isEmpty
                    ? nil
                    : MultiRootBranchDeleteRecoveryContext(
                        branchName: contexts.first?.preview.branchName ?? "",
                        contexts: remainingContexts
                    )
                let details = failuresToReport + upstreamWarningsToReport
                self.feedbackCenter.warning(
                    "Multi-root branch restore partially failed",
                    detail: details.joined(separator: "\n"),
                    nextStep: "Review the affected roots and retry the remaining restore action.",
                    additionalActions: self.branchDeleteRestoreAction(
                        contexts: remainingContexts,
                        title: "Retry Restore"
                    ).map { [$0] } ?? [],
                    notificationID: remainingContexts.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: remainingContexts.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

/// Validate the post-Undo state. The gitlink must still be the same commit,
/// but the nested worktree must now be initialized and clean.
nonisolated static func submoduleDeinitUndoTargetAfterRestore(
    _ context: PersistedSubmoduleUndo,
    modules: [SubmoduleInfo],
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> Bool {
    guard context.operation == .deinitialize,
          let module = modules.first(where: { $0.path == context.path }) else {
        return false
    }
    return module.state == .clean
        && !module.dirty
        && module.headId == context.expectedHeadID
        && gitmodulesPresent == context.expectedGitmodulesPresent
        && gitmodulesContents == context.expectedGitmodulesContents
}

func branchDeleteRestoreRequest(
    targets: [PersistedBranchDeleteRecoveryTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .restoreDeletedBranches,
        projectPath: projectPath,
        rootPath: targets.count == 1 ? targets[0].rootPath : nil,
        shelfName: "",
        branchDeleteRecoveryTargets: targets
    )
}

func branchDeleteRestoreAction(
    contexts: [BranchDeleteRecoveryContext],
    title: String = "Restore"
) -> FeedbackAction? {
    guard let targets = branchDeleteRecoveryTargets(from: contexts) else { return nil }
    return branchDeleteRestoreAction(
        targets: targets,
        title: title
    )
}

func branchDeleteRestoreAction(
    targets: [PersistedBranchDeleteRecoveryTarget],
    title: String = "Restore"
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = branchDeleteRestoreRequest(targets: targets)
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func completeMultiRootResolverShelf(
    _ root: MultiRootConflictResolverRoot,
    name: String
) {
    guard case let .shelve(_, isPop) = root.kind,
          let rootRepo = multiRootResolverActiveRepo else { return }
    let batchRebaseSessionID = isPop
        && multiRootRebaseSession?.roots.contains(where: { $0.rootPath == root.rootPath }) == true
        ? multiRootRebaseSession?.id
        : nil
    multiRootResolverWorking = true
    multiRootResolverError = nil
    Task.detached(priority: .userInitiated) {
        do {
            let conflicts = try rootRepo.status().filter {
                $0.staged == .conflicted || $0.unstaged == .conflicted
            }
            guard conflicts.isEmpty else {
                throw NSError(
                    domain: "Arbor.MultiRootShelfRestore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "仍有冲突文件未解决：\(conflicts.map(\.path).joined(separator: ", "))"]
                )
            }
            // A crash can happen after the preserving apply marker is written
            // but before the Shelf restore snapshot is created. In that
            // narrow window there is no shelveRestoreInfo yet; replay the
            // exact marked Shelf so a clean apply finalizes the marker and a
            // conflicting apply creates the normal restore snapshot.
            let pendingShelveRestore = (try? rootRepo.shelveRestoreInfo()) ?? nil
            let applyInfo = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil
            if pendingShelveRestore == nil,
               let applyInfo,
               applyInfo.kind == "shelf",
               applyInfo.identifier == name {
                try rootRepo.shelvePopPreservation(name: name)
                _ = try rootRepo.finalizeApplyLocalChangesRestore()
            } else {
                try rootRepo.shelveCompleteRestore(name: name)
            }
            await MainActor.run {
                self.multiRootResolverWorking = false
                self.multiRootResolverError = nil
                if let batchRebaseSessionID {
                    self.closeMultiRootResolver()
                    self.handleMultiRootRebaseRecovery(
                        rootPath: root.rootPath,
                        action: .continueOperation,
                        operationStillActive: false,
                        sessionID: batchRebaseSessionID
                    )
                } else {
                    self.feedbackCenter.success(
                        isPop ? "Shelf pop completed" : "Unshelve completed",
                        detail: "\(root.rootPath) · \(name)"
                    )
                    self.openMultiRootConflictResolver(preferredRootPath: root.rootPath)
                }
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

func abortMultiRootResolverShelf(
    _ root: MultiRootConflictResolverRoot,
    name: String
) {
    guard let rootRepo = multiRootResolverActiveRepo else { return }
    let batchRebaseSessionID = multiRootRebaseSession?.roots.contains(where: { $0.rootPath == root.rootPath }) == true
        ? multiRootRebaseSession?.id
        : nil
    multiRootResolverWorking = true
    multiRootResolverError = nil
    Task.detached(priority: .userInitiated) {
        do {
            try rootRepo.shelveAbortRestore(name: name)
            await MainActor.run {
                self.multiRootResolverWorking = false
                self.multiRootResolverError = nil
                if let batchRebaseSessionID {
                    self.closeMultiRootResolver()
                    self.handleMultiRootRebaseRecovery(
                        rootPath: root.rootPath,
                        action: .continueOperation,
                        operationStillActive: false,
                        sessionID: batchRebaseSessionID
                    )
                } else {
                    self.feedbackCenter.success(
                        "Shelf restore rolled back",
                        detail: "\(root.rootPath) · \(name)"
                    )
                    self.openMultiRootConflictResolver(preferredRootPath: root.rootPath)
                }
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

func presentMultiRootUpdateRestoreConflicts(_ results: [RootOperationResult]) {
    let roots = results.filter {
        !$0.success && $0.message.localizedCaseInsensitiveContains("local restore conflicted")
    }
    for result in roots {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            do {
                let rootRepo = try openRepository(path: rootPath)
                let paths = try rootRepo.status().filter {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                }.map(\.path)
                let shelveRestore = (try? rootRepo.shelveRestoreInfo()) ?? nil
                let stash = try rootRepo.stashList().enumerated().first {
                    isArborUpdateStashMessage($0.element.message)
                }
                await MainActor.run {
                    if shelveRestore != nil {
                        self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                        return
                    }
                    guard !paths.isEmpty, let stash else {
                        self.feedbackCenter.error(
                            "Update local changes unavailable",
                            detail: "\(rootPath): the temporary Update Project local-change save could not be located.",
                            nextStep: "Inspect that root's stash or Shelf list before changing its conflicted files."
                        )
                        return
                    }
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: stash.offset,
                        stashID: stash.element.id,
                        isPop: true,
                        paths: paths
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Local restore conflict unavailable",
                        detail: "\(rootPath): \(errorMessage(error))",
                        nextStep: "Open that Git root and resolve its conflicted files manually."
                    )
                }
            }
        }
    }
}

/// Smart Checkout and Checkout and Update can also leave a named Shelf in a
/// pending restore state. Reuse the project resolver so this remains
/// root-scoped instead of falling back to the currently selected Repository.
func presentMultiRootShelfRestoreConflicts(_ results: [RootOperationResult]) {
    for result in results where !result.success {
        let rootPath = result.rootPath
        Task.detached(priority: .userInitiated) {
            guard let rootRepo = try? openRepository(path: rootPath) else { return }
            let pending = (try? rootRepo.shelveRestoreInfo()) ?? nil
            let paths = ((try? rootRepo.status()) ?? [])
                .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                .map(\.path)
            let stash = try? rootRepo.stashList().enumerated().first(where: {
                $0.element.message.hasPrefix("Arbor: Smart Checkout to")
                    || $0.element.message.hasPrefix("Arbor: Checkout and Update to")
            })
            await MainActor.run {
                if pending != nil {
                    self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                } else if let stash {
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: stash.offset,
                        stashID: stash.element.id,
                        isPop: true,
                        paths: paths
                    )
                }
            }
        }
    }
}

/// Restore temporary Update Project local changes discovered after relaunch.
///
/// A Git operation in progress must be completed or aborted first; popping
/// the stash while merge/rebase metadata is active would mix two recovery
/// flows. If the root is clean from Git's operation-state perspective, this
/// follows the same root-scoped conflict workbench used by in-session Update.
func restoreMultiRootUpdateStash(rootPath: String) {
    guard !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    beginFeedbackOperation("Restore Update Project changes")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            guard try rootRepo.operationState() == nil else {
                throw NSError(
                    domain: "Arbor.MultiRootRecovery",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "该 Git root 仍有进行中的操作，请先 Continue 或 Abort。"]
                )
            }
            let shelf = try rootRepo.shelveList().first(where: { isArborUpdateShelfName($0.name) })
            let stash = try rootRepo.stashList().enumerated().first(where: {
                isArborUpdateStashMessage($0.element.message)
            })
            guard shelf != nil || stash != nil else {
                throw NSError(
                    domain: "Arbor.MultiRootRecovery",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "找不到临时 Update Project stash 或 Shelf。"]
                )
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
                    self.loadMultiRoots()
                    self.feedbackCenter.success(
                        "Local changes restored",
                        detail: "\(rootPath): the Update Project local changes were restored after relaunch."
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
                    throw error
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Local changes restore failed",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Inspect the root's status and Update Project stash before retrying."
                )
            }
        }
    }
}

func restoreDeletedBranch(_ context: BranchDeleteRecoveryContext) {
    if let notificationID = branchDeleteNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
    beginFeedbackOperation("Restore branch")
    Task.detached(priority: .userInitiated) {
        do {
            try context.repo.branchCreate(
                name: context.preview.branchName,
                at: context.preview.tipId
            )
            var upstreamError: String?
            if let upstream = context.preview.upstream {
                do {
                    try context.repo.branchSetUpstream(
                        branch: context.preview.branchName,
                        upstream: upstream
                    )
                } catch {
                    upstreamError = errorMessage(error)
                }
            }
            let restoreUpstreamError = upstreamError
            await MainActor.run {
                self.branchDeleteRecovery = nil
                if let rootPath = context.rootPath {
                    self.loadMultiRoots()
                    if let restoreUpstreamError {
                        self.feedbackCenter.warning(
                            "Branch restored",
                            detail: "\(context.preview.branchName) · \(rootPath). Upstream was not restored: \(restoreUpstreamError)"
                        )
                    } else {
                        self.feedbackCenter.success("Branch restored", detail: "\(context.preview.branchName) · \(rootPath)")
                    }
                } else {
                    self.branches = (try? context.repo.branchList()) ?? self.branches
                    self.loadRepoData()
                    if let restoreUpstreamError {
                        self.feedbackCenter.warning(
                            "Branch restored",
                            detail: "\(context.preview.branchName). Upstream was not restored: \(restoreUpstreamError)"
                        )
                    } else {
                        self.feedbackCenter.success("Branch restored", detail: context.preview.branchName)
                    }
                    if self.toolWindowMode == .log { self.loadLog() }
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Restore branch failed",
                    detail: "\(context.preview.branchName): \(errorMessage(error))",
                    additionalActions: self.branchDeleteRestoreAction(
                        contexts: [context],
                        title: "Retry Restore"
                    ).map { [$0] } ?? [],
                    notificationID: self.branchDeleteNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

func showStashRestoreConflict(
    _ paths: [String],
    operationName: String = "Smart Checkout",
    additionalActions: [FeedbackAction] = [],
    notificationID: String? = nil,
    stashID: String? = nil
) {
    pendingStashConflictNotificationID = notificationID
    stashPopConflictInProgress = true
    stashApplyConflictInProgress = false
    pendingStashPopIndex = 0
    pendingStashPopID = stashID
    pendingPullStashPop = false
    pendingPullStashID = nil
    pendingPullStashMessage = nil
    mergeInProgress = true
    mergeInitialPath = paths.first
    if toolWindowMode != .log {
        selection = paths.first
    }
    fileSelection = nil
    selectionModePath = nil
    commitPreviewPath = nil
    commitPreviewVisible = false
    showMergeRevisionsDialog = true
    mergeFeedback = "\(operationName) 冲突：\(paths.joined(separator: ", "))"
    feedbackCenter.error(
        "\(operationName) paused",
        detail: paths.joined(separator: ", "),
        nextStep: "Resolve every file, then complete the local-change restore.",
        additionalActions: additionalActions,
        notificationID: notificationID
    )
    refreshAll(showFeedback: false)
}

func restoreDeletedTags(_ contexts: [TagDeleteRecoveryContext]) {
    guard !contexts.isEmpty else { return }
    multiRootTagDeleteRecovery = nil
    beginFeedbackOperation("Restore multi-root tags")
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [TagDeleteRecoveryContext] = []
        for context in contexts {
            do {
                try context.repo.tagCreate(name: context.tag.name, at: context.tag.id)
            } catch {
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")): \(errorMessage(error))"
                )
                remaining.append(context)
            }
        }
        let failuresToReport = failures
        let remainingContexts = remaining
        await MainActor.run {
            self.loadMultiRoots()
            if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root tag restore completed",
                    detail: contexts.first?.tag.name ?? ""
                )
            } else {
                self.multiRootTagDeleteRecovery = remainingContexts.isEmpty
                    ? nil
                    : MultiRootTagDeleteRecoveryContext(
                        tagName: contexts.first?.tag.name ?? "",
                        contexts: remainingContexts
                    )
                self.feedbackCenter.warning(
                    "Multi-root tag restore partially failed",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the affected roots and retry the remaining restore action."
                )
            }
        }
    }
}

/// Reconcile a Shelf/Apply Patch mutation through the same root-scoped dirty
/// lifecycle as an external VFS event. Updating `entries` directly is not
/// enough: file previews, the staging model, and the index revision cache
/// must all observe the post-apply worktree/index boundary.
func refreshAfterShelfMutation(
    repo: Repository,
    paths: [String],
    metadataChanged: Bool = true
) {
    guard let workdir = repo.workdir() else {
        refreshAll(showFeedback: false)
        return
    }

    let dirtyPaths = repositoryShelfMutationDirtyPaths(
        workdir: workdir,
        paths: paths
    )
    let scope = dirtyPaths.isEmpty
        ? RepositoryDirtyScope(
            files: [],
            directories: [],
            nonRecursiveDirectories: [],
            everything: !metadataChanged
        )
        : repositoryDirtyScope(
            workdir: workdir,
            gitDir: repo.gitDir(),
            dirtyPaths: dirtyPaths
        )
    let changeScope: RepositoryChangeScope = metadataChanged
        ? [.worktree, .gitMetadata]
        : [.worktree]

    // Keep the exact path ledger in lockstep with the compacted scope. Shelf
    // operations are internal writes, so they do not enter the external VCS
    // action queue, but their file events still need the same acknowledge
    // boundary as watcher-delivered changes.
    repositoryDirtyFileManager.mark(
        repositoryPath: workdir,
        dirtyPaths: dirtyPaths
    )
    _ = repositoryDirtyScopeManager.mark(
        repositoryPath: workdir,
        scope: scope,
        changeScope: changeScope,
        dirtyPaths: dirtyPaths
    )
    startPendingRepositoryDirtyScopes()
}

/// Execute the DeleteProvider's mixed active/Recently Deleted Shelf scope as
/// one root-scoped lifecycle. IntelliJ's ShelvedChangesViewManager performs
/// this as one deletion notification; keeping the four storage mutations in
/// one serial runner prevents concurrent repository access and gives Undo and
/// Retry one coherent result.
func deleteShelfPlan(
    _ plan: ShelfDeletePlan,
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let operations = shelfDeleteOperations(plan)
    guard !operations.isEmpty else { return }

    let notificationID = shelfRootNotificationID(
        prefix: "shelf-delete-plan",
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Delete Shelf changes",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: operations.count,
        phase: "Delete Shelf Changes"
    )

    Task.detached(priority: .userInitiated) {
        var completedKeys = Set<String>()
        var successfulLabels: [String] = []
        var undoNames: [String] = []
        var undoTimestamps: [String: Int64] = [:]
        var knownDeletedNames = Set((try? shelfRepository.shelveDeletedList().map(\.name)) ?? [])
        var failures: [String] = []
        var failedActiveShelfNames: [String] = []
        var failedActivePathGroups: [ShelfPathDeleteGroup] = []
        var failedDeletedShelfNames: [String] = []
        var failedDeletedPathGroups: [ShelfPathDeleteGroup] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]

        for (index, operation) in operations.enumerated() {
            do {
                switch operation.kind {
                case .activeShelf:
                    guard let shelf = try shelfRepository.shelveList().first(where: {
                        $0.name == operation.shelfName
                    }) else {
                        throw EngineError.GitOperation(
                            message: "shelve: shelf not found '\(operation.shelfName)'"
                        )
                    }
                    try shelfRepository.shelveDrop(name: operation.shelfName)
                    undoNames.append(operation.shelfName)
                    undoTimestamps[operation.shelfName] = shelf.timestamp
                    itemChildren[operation.key] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + operation.key,
                        paths: shelf.paths,
                        state: .success,
                        detail: "Moved to Recently Deleted"
                    )
                    itemDetails[operation.key] = "Moved to Recently Deleted"

                case .activePaths:
                    guard let shelf = try shelfRepository.shelveList().first(where: {
                        $0.name == operation.shelfName
                    }) else {
                        throw EngineError.GitOperation(
                            message: "shelve: shelf not found '\(operation.shelfName)'"
                        )
                    }
                    try shelfRepository.shelveDropPaths(
                        name: operation.shelfName,
                        paths: operation.paths
                    )
                    let currentDeleted = try shelfRepository.shelveDeletedList()
                    for deleted in currentDeleted where !knownDeletedNames.contains(deleted.name) {
                        knownDeletedNames.insert(deleted.name)
                        undoNames.append(deleted.name)
                        undoTimestamps[deleted.name] = shelf.timestamp
                    }
                    itemChildren[operation.key] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + operation.key,
                        paths: operation.paths,
                        state: .success,
                        detail: "Moved to Recently Deleted"
                    )
                    itemDetails[operation.key] = "Moved to Recently Deleted"

                case .deletedShelf:
                    guard let shelf = try shelfRepository.shelveDeletedList().first(where: {
                        $0.name == operation.shelfName
                    }) else {
                        throw EngineError.GitOperation(
                            message: "shelve: deleted Shelf not found '\(operation.shelfName)'"
                        )
                    }
                    try shelfRepository.shelveDeleteDeleted(name: operation.shelfName)
                    itemChildren[operation.key] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + operation.key,
                        paths: shelf.paths,
                        state: .success,
                        detail: "Deleted permanently"
                    )
                    itemDetails[operation.key] = "Deleted permanently"

                case .deletedPaths:
                    guard let shelf = try shelfRepository.shelveDeletedList().first(where: {
                        $0.name == operation.shelfName
                    }) else {
                        throw EngineError.GitOperation(
                            message: "shelve: deleted Shelf not found '\(operation.shelfName)'"
                        )
                    }
                    try shelfRepository.shelveDeleteDeletedPaths(
                        name: operation.shelfName,
                        paths: operation.paths
                    )
                    itemChildren[operation.key] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + operation.key,
                        paths: operation.paths,
                        state: .success,
                        detail: "Deleted permanently"
                    )
                    itemDetails[operation.key] = "Deleted permanently"
                    _ = shelf
                }
                completedKeys.insert(operation.key)
                successfulLabels.append(operation.displayName)
                itemStates[operation.key] = .success
            } catch {
                let message = errorMessage(error)
                failures.append("\(operation.displayName): \(message)")
                itemStates[operation.key] = .failed
                itemDetails[operation.key] = message
                let currentPaths: [String] = {
                    switch operation.kind {
                    case .activeShelf, .activePaths:
                        return (try? shelfRepository.shelveList().first(where: {
                            $0.name == operation.shelfName
                        })?.paths) ?? []
                    case .deletedShelf, .deletedPaths:
                        return (try? shelfRepository.shelveDeletedList().first(where: {
                            $0.name == operation.shelfName
                        })?.paths) ?? []
                    }
                }()
                itemChildren[operation.key] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + operation.key,
                    paths: operation.paths.isEmpty ? currentPaths : operation.paths,
                    state: .failed,
                    detail: message
                )
                switch operation.kind {
                case .activeShelf:
                    failedActiveShelfNames.append(operation.shelfName)
                case .activePaths:
                    failedActivePathGroups.append(
                        ShelfPathDeleteGroup(
                            shelfName: operation.shelfName,
                            paths: operation.paths
                        )
                    )
                case .deletedShelf:
                    failedDeletedShelfNames.append(operation.shelfName)
                case .deletedPaths:
                    failedDeletedPathGroups.append(
                        ShelfPathDeleteGroup(
                            shelfName: operation.shelfName,
                            paths: operation.paths
                        )
                    )
                }
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: operations.count,
                    phase: "Delete Shelf Changes",
                    detail: operation.displayName
                )
            }
        }

        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let completedKeysSnapshot = completedKeys
        let successfulLabelsSnapshot = successfulLabels
        let undoNamesSnapshot = undoNames
        let undoTimestampsSnapshot = undoTimestamps
        let failuresSnapshot = failures
        let retryPlan = ShelfDeletePlan(
            activeShelfNames: failedActiveShelfNames,
            activePathGroups: failedActivePathGroups,
            deletedShelfNames: failedDeletedShelfNames,
            deletedPathGroups: failedDeletedPathGroups
        )
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        await MainActor.run {
            guard shelfActionRootMatchesCurrentRoot(
                requestedRootPath: resolvedRootPath,
                currentRootPath: self.activeShelfRootPath
            ) else { return }
            self.publishShelfSnapshot(
                rootPath: resolvedRootPath,
                shelves: nextShelves,
                deletedShelves: nextDeletedShelves
            )
            if let previewName = self.shelfPreviewName,
               let previewOperation = operations.first(where: {
                   $0.shelfName == previewName
                       && (($0.kind == .deletedShelf || $0.kind == .deletedPaths)
                           == self.shelfPreviewIsDeleted)
                       && completedKeysSnapshot.contains($0.key)
               }) {
                _ = previewOperation
                self.shelfPreviewName = nil
                self.shelfPreviewText = nil
                self.showShelfPreview = false
            }

            let undoAction = self.shelfUndoDeletionsFeedbackAction(
                names: undoNamesSnapshot,
                originalTimestamps: undoTimestampsSnapshot,
                rootPath: resolvedRootPath
            )
            let retryAction = self.shelfDeletePlanRetryFeedbackAction(
                plan: retryPlan,
                rootPath: resolvedRootPath
            )
            let additionalActions = [undoAction, retryAction].compactMap { $0 }
            let operationItems = operations.map { operation in
                FeedbackOperationItem(
                    scope: resolvedRootPath,
                    name: operation.displayName,
                    state: itemStatesSnapshot[operation.key] ?? .skipped,
                    detail: itemDetailsSnapshot[operation.key] ?? "Not attempted",
                    children: itemChildrenSnapshot[operation.key] ?? []
                )
            }
            let detail = successfulLabelsSnapshot.isEmpty
                ? "0/\(operations.count)"
                : "\(completedKeysSnapshot.count)/\(operations.count): "
                    + successfulLabelsSnapshot.joined(separator: ", ")
            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelf changes deleted",
                    detail: detail,
                    additionalActions: undoAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            } else if completedKeysSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Shelf deletion failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The selected Shelves were kept. Resolve the reported issue and retry.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some Shelf changes were not deleted",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")].joined(separator: "\n"),
                    nextStep: "Retry the remaining Shelf changes or use Undo to restore active deletions.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            }
            self.feedbackCenter.attachOperationItems(
                operationItems,
                notificationID: notificationID,
                mergeWithExisting: preservePreviousItems
            )
        }
    }
}

func normalizedShelfPathGroups(
    _ groups: [ShelfPathDeleteGroup]
) -> [ShelfPathDeleteGroup] {
    var result: [ShelfPathDeleteGroup] = []
    var indexes: [String: Int] = [:]
    for group in groups {
        let name = group.shelfName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        var paths: [String] = []
        var seenPaths = Set<String>()
        for path in group.paths {
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seenPaths.insert(normalized).inserted else { continue }
            paths.append(normalized)
        }
        guard !paths.isEmpty else { continue }
        if let index = indexes[name] {
            var merged = result[index].paths
            for path in paths where !merged.contains(path) {
                merged.append(path)
            }
            result[index] = ShelfPathDeleteGroup(shelfName: name, paths: merged)
        } else {
            indexes[name] = result.count
            result.append(ShelfPathDeleteGroup(shelfName: name, paths: paths))
        }
    }
    return result
}

nonisolated func shelfPathGroupKey(_ group: ShelfPathDeleteGroup) -> String {
    "\(group.shelfName)\u{1E}\(group.paths.joined(separator: "\u{1F}"))"
}

/// Apply multiple ShelvedChangeLists serially. An explicit target mirrors
/// UnshelveWithDialogAction; a nil target mirrors ChangesView.UnshelveSilently
/// and lets the automatic Changelist setting choose a destination per Shelf.
/// Serial execution is intentional because all lists modify one worktree and
/// the Rust engine persists one conflict restore snapshot per repository.
nonisolated func shelfOperationItems(
    rootPath: String,
    names: [String],
    states: [String: FeedbackResultState],
    details: [String: String],
    children: [String: [FeedbackOperationSubitem]] = [:]
) -> [FeedbackOperationItem] {
    names.map { name in
        FeedbackOperationItem(
            scope: rootPath,
            name: name,
            state: states[name] ?? .skipped,
            detail: details[name] ?? "Not attempted",
            children: children[name] ?? []
        )
    }
}

nonisolated func shelfOperationSubitems(
    scope: String,
    paths: [String],
    result: PatchApplyResult,
    successDetail: String,
    failureDetail: String,
    skippedDetail: String = "Not attempted"
) -> [FeedbackOperationSubitem] {
    var statuses: [String: PatchApplyStatus] = [:]
    for member in result.memberStatuses {
        statuses[member.path] = member.status
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map { path in
        let status = statuses[path] ?? .skip
        let state: FeedbackResultState
        let detail: String
        switch status {
        case .success:
            state = .success
            detail = successDetail
        case .alreadyApplied:
            state = .success
            detail = "Already applied"
        case .partial:
            state = .partial
            detail = "Partially applied"
        case .failure:
            state = .failed
            detail = failureDetail
        case .skip:
            state = .skipped
            detail = skippedDetail
        case .abort:
            state = .aborted
            detail = "Aborted"
        }
        return FeedbackOperationSubitem(
            scope: scope,
            path: path,
            state: state,
            detail: detail
        )
    }
}

nonisolated func shelfOperationSubitems(
    scope: String,
    paths: [String],
    state: FeedbackResultState,
    detail: String
) -> [FeedbackOperationSubitem] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map {
        FeedbackOperationSubitem(
            scope: scope,
            path: $0,
            state: state,
            detail: detail
        )
    }
}

nonisolated func shelfOperationSubitems(
    scope: String,
    paths: [String],
    appliedPaths: Set<String>,
    failedPaths: Set<String>,
    successDetail: String,
    failureDetail: String,
    skippedDetail: String = "Not attempted"
) -> [FeedbackOperationSubitem] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map { path in
        let state: FeedbackResultState
        let detail: String
        if failedPaths.contains(path) {
            state = .failed
            detail = failureDetail
        } else if appliedPaths.contains(path) {
            state = .success
            detail = successDetail
        } else {
            state = .skipped
            detail = skippedDetail
        }
        return FeedbackOperationSubitem(
            scope: scope,
            path: path,
            state: state,
            detail: detail
        )
    }
}

/// Move selected Shelf members to another ShelvedChangeList without applying
/// them to the worktree. The engine preserves patch metadata and moves the
/// source to Recently Deleted when its final member is transferred.
func moveShelfPaths(
    _ sourceName: String,
    _ targetName: String,
    _ paths: [String],
    rootPath: String? = nil
) {
    guard !paths.isEmpty,
          let context = shelfMutationContext(
              rootPath: rootPath,
              activeRootPath: activeShelfRootPath,
              primaryRootPath: primaryShelfRootPath,
              primaryRepository: repo,
              secondaryRepository: shelfRootRepository
          ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    beginFeedbackOperation("Move shelf changes")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveMovePaths(
                sourceName: sourceName,
                targetName: targetName,
                paths: paths
            )
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh
                )
                self.feedbackCenter.success(
                    "Shelf changes moved",
                    detail: targetName,
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "move",
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Move shelf changes failed",
                    detail: errorMessage(error),
                    nextStep: "Choose a destination shelf without overlapping paths, then retry.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "move",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

func openApplyLocalChangesRestore(_ request: ArborVCSActionRequest) {
    guard let rootPath = request.rootPath else { return }
    toolWindowMode = .commit
    toolWindowExpanded = true
    openMultiRootConflictResolver(preferredRootPath: rootPath)
}

func showSavedChanges(_ request: ArborVCSActionRequest) {
    guard let savedChangesKind = request.savedChangesKind,
          let savedChangesID = request.savedChangesID,
          !savedChangesID.isEmpty else { return }

    let rootPath = request.rootPath ?? repo?.workdir()
    guard let rootPath else { return }
    let savedChangesRepo: Repository
    do {
        savedChangesRepo = try openRepository(path: rootPath)
    } catch {
        feedbackCenter.error("Load saved changes failed", detail: errorMessage(error))
        return
    }

    toolWindowMode = .commit
    toolWindowExpanded = true
    Task.detached(priority: .userInitiated) {
        do {
            switch savedChangesKind {
            case .shelf:
                let shelves = try savedChangesRepo.shelveList()
                guard shelves.contains(where: { $0.name == savedChangesID }) else {
                    throw NSError(
                        domain: "Arbor.SavedChanges",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "找不到已保存的 Shelf：\(savedChangesID)"]
                    )
                }
                let diff = try savedChangesRepo.shelveDiff(name: savedChangesID)
                await MainActor.run {
                    self.shelves = shelves
                    self.stashPreviewStashID = nil
                    self.stashPreviewText = nil
                    self.showStashPreview = false
                    self.shelfPreviewName = savedChangesID
                    self.shelfPreviewIsDeleted = false
                    self.shelfPreviewText = diff
                    self.showShelfPreview = true
                }
            case .stash:
                let stashes = try savedChangesRepo.stashList()
                guard let index = stashes.firstIndex(where: { $0.id == savedChangesID }) else {
                    throw NSError(
                        domain: "Arbor.SavedChanges",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "找不到已保存的 stash：\(savedChangesID)"]
                    )
                }
                let diff = try savedChangesRepo.stashDiff(
                    index: try currentStashIndex(repo: savedChangesRepo, stashID: savedChangesID)
                )
                await MainActor.run {
                    self.stashes = stashes
                    self.shelfPreviewName = nil
                    self.shelfPreviewText = nil
                    self.showShelfPreview = false
                    self.stashPreviewStashID = stashes[index].id
                    self.stashPreviewText = diff
                    self.showStashPreview = true
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Load saved changes failed", detail: errorMessage(error))
            }
        }
    }
}

func shelfActionRequest(
    kind: ArborVCSActionRequest.Kind,
    name: String,
    paths: [String]? = nil,
    restoreTimestamp: Int64? = nil,
    rootPath: String? = nil
) -> ArborVCSActionRequest? {
    guard let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    return ArborVCSActionRequest(
        kind: kind,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: name,
        shelfPaths: paths,
        shelfRestoreTimestamp: restoreTimestamp
    )
}

func isShelfSemanticAction(_ kind: ArborVCSActionRequest.Kind) -> Bool {
    switch kind {
    case .restoreShelf,
         .restoreShelfPaths,
         .deleteDeletedShelfPaths,
         .undoShelfDeletion,
         .undoShelfDeletions,
         .dropShelf,
         .retryShelfBatch,
         .retryShelfMemberBatch,
         .retryShelfLifecycleBatch,
         .retryShelfDeletePlan:
        return true
    default:
        return false
    }
}

func shelfRootNotificationID(
    prefix: String,
    rootPath: String? = nil
) -> String? {
    guard let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    return shelfNotificationID(prefix: prefix, rootPath: resolvedRootPath)
}

func shelfMetadataNotificationID(
    operation: String,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(prefix: "shelf-metadata.\(operation)", rootPath: rootPath)
}

func shelfBatchNotificationID(
    operation: ArborVCSActionRequest.ShelfBatchOperation,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(
        prefix: "shelf-batch.\(operation.rawValue)",
        rootPath: rootPath
    )
}

func shelfMemberBatchNotificationID(
    operation: ArborVCSActionRequest.ShelfMemberBatchOperation,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(
        prefix: "shelf-member-batch.\(operation.rawValue)",
        rootPath: rootPath
    )
}

func shelfLifecycleNotificationID(
    operation: ArborVCSActionRequest.ShelfLifecycleOperation,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(
        prefix: "shelf-lifecycle.\(operation.rawValue)",
        rootPath: rootPath
    )
}

func shelfUndoDeletionNotificationID(rootPath: String? = nil) -> String? {
    shelfRootNotificationID(prefix: "shelf-undo-deletion", rootPath: rootPath)
}

func shelfDeletedMemberDeletionNotificationID(rootPath: String? = nil) -> String? {
    shelfRootNotificationID(prefix: "shelf-deleted-member-deletion", rootPath: rootPath)
}

func shelfBatchRetryFeedbackAction(
    names: [String],
    operation: ArborVCSActionRequest.ShelfBatchOperation,
    targetName: String?,
    removeApplied: Bool,
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !normalizedNames.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfBatch,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfNames: normalizedNames,
        shelfBatchOperation: operation,
        shelfBatchTargetName: targetName,
        shelfBatchRemoveApplied: removeApplied
    )
    return FeedbackAction(title: "Retry Remaining Shelves", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfMemberBatchRetryFeedbackAction(
    groups: [ShelfPathDeleteGroup],
    operation: ArborVCSActionRequest.ShelfMemberBatchOperation,
    targetName: String? = nil,
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedGroups = normalizedShelfPathGroups(groups)
    guard !normalizedGroups.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfMemberBatch,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfMemberGroups: normalizedGroups.map {
            PersistedShelfPathGroup(shelfName: $0.shelfName, paths: $0.paths)
        },
        shelfMemberBatchOperation: operation,
        shelfMemberBatchTargetName: targetName
    )
    return FeedbackAction(title: "Retry Remaining Shelf Changes", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfDeletePlanRetryFeedbackAction(
    plan: ShelfDeletePlan,
    rootPath: String? = nil
) -> FeedbackAction? {
    guard !plan.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfDeletePlan,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfDeletePlan: PersistedShelfDeletePlan(plan)
    )
    return FeedbackAction(title: "Retry Remaining Shelf Actions", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfLifecycleRetryFeedbackAction(
    names: [String],
    operation: ArborVCSActionRequest.ShelfLifecycleOperation,
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !normalizedNames.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfLifecycleBatch,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfNames: normalizedNames,
        shelfLifecycleOperation: operation
    )
    return FeedbackAction(title: "Retry Remaining Shelf Actions", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func savedChangesFeedbackAction(
    kind: ArborVCSActionRequest.SavedChangesKind,
    identifier: String,
    rootPath: String? = nil
) -> FeedbackAction? {
    guard let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showSavedChanges,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: "",
        savedChangesKind: kind,
        savedChangesID: identifier
    )
    return FeedbackAction(title: "View saved changes…", semanticAction: request) {
        self.showSavedChanges(request)
    }
}

/// Find the exact saved artifact left by any automatic preserving operation.
/// Apply-style operations and Rebase intentionally use different persisted
/// markers, but both must resolve to the same root-qualified preview action.
func pendingSavedChangesFeedbackAction(
    repo: Repository,
    rootPath: String? = nil
) -> FeedbackAction? {
    let info = ((try? repo.applyLocalChangesRestoreInfo()) ?? nil)
        ?? ((try? repo.rebaseLocalChangesRestoreInfo()) ?? nil)
    guard let info,
          let kind = ArborVCSActionRequest.SavedChangesKind(rawValue: info.kind) else {
        return nil
    }
    return savedChangesFeedbackAction(
        kind: kind,
        identifier: info.identifier,
        rootPath: rootPath ?? repo.workdir()
    )
}

func shelfRestoreFeedbackAction(
    name: String,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .restoreShelf,
        name: name,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Restore", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfUndoDeletionFeedbackAction(
    name: String,
    originalTimestamp: Int64,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .undoShelfDeletion,
        name: name,
        restoreTimestamp: originalTimestamp,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Undo", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfUndoDeletionsFeedbackAction(
    names: [String],
    originalTimestamps: [String: Int64],
    title: String = "Undo",
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && originalTimestamps[$0] != nil }
    guard !normalizedNames.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .undoShelfDeletions,
        projectPath: projectPath,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfRestoreTimestamps: Dictionary(
            uniqueKeysWithValues: normalizedNames.compactMap { name in
                originalTimestamps[name].map { (name, $0) }
            }
        ),
        shelfNames: normalizedNames
    )
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfUndoDeletedMembersFeedbackAction(
    name: String,
    paths: [String],
    originalTimestamp: Int64,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .restoreShelfPaths,
        name: name,
        paths: paths,
        restoreTimestamp: originalTimestamp,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Undo", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfDropFeedbackAction(
    name: String,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .dropShelf,
        name: name,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Drop", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfDeleteDeletedMembersFeedbackAction(
    name: String,
    paths: [String],
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .deleteDeletedShelfPaths,
        name: name,
        paths: paths,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Retry Delete Permanently", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

/// Restore a shelf from IntelliJ's Recently Deleted collection.
func restoreDeletedShelve(_ name: String, rootPath: String? = nil) {
    restoreDeletedShelves([name], rootPath: rootPath)
}

/// Undo a recent Shelf deletion while preserving the original list timestamp.
/// This is distinct from the Recently Deleted Restore action: IntelliJ's
/// deletion notification restores the list to its pre-delete position rather
/// than making it a newly modified Shelf.
func undoShelfDeletion(
    _ name: String,
    originalTimestamp: Int64,
    rootPath: String? = nil
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    beginFeedbackOperation("Undo shelf deletion")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveRestoreDeletedWithTimestamp(
                name: name,
                timestamp: originalTimestamp
            )
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh
                )
                self.feedbackCenter.success(
                    "Shelf deletion undone",
                    detail: name,
                    additionalActions: [self.shelfDropFeedbackAction(
                        name: name,
                        rootPath: resolvedRootPath
                    )],
                    notificationID: self.shelfUndoDeletionNotificationID(
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Undo shelf deletion failed",
                    detail: errorMessage(error),
                    nextStep: "The deleted Shelf was kept. Resolve any active name conflict, then retry Undo.",
                    notificationID: self.shelfUndoDeletionNotificationID(
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// Undo one notification's multi-Shelf deletion as one semantic action. The
/// timestamp map preserves IntelliJ's restore-to-original-position behavior
/// while allowing a partial result when one deleted list is no longer present.
func undoShelfDeletions(
    _ names: [String],
    originalTimestamps: [String: Int64],
    rootPath: String? = nil
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    var seen = Set<String>()
    let uniqueNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !uniqueNames.isEmpty else { return }

    beginFeedbackOperation("Undo shelf deletions")
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Undo Shelf Deletion"
    )
    Task.detached(priority: .userInitiated) {
        var restored: [String] = []
        var failures: [String] = []
        var failedNames: [String] = []
        for (index, name) in uniqueNames.enumerated() {
            do {
                guard let timestamp = originalTimestamps[name] else {
                    throw EngineError.GitOperation(message: "shelve: missing original timestamp for '\(name)'")
                }
                try shelfRepository.shelveRestoreDeletedWithTimestamp(name: name, timestamp: timestamp)
                restored.append(name)
            } catch {
                failedNames.append(name)
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Undo Shelf Deletion",
                    detail: name
                )
            }
        }

        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let restoredSnapshot = restored
        let failuresSnapshot = failures
        let failedNamesSnapshot = failedNames
        let retryTimestamps = originalTimestamps
        await MainActor.run {
            guard shelfActionRootMatchesCurrentRoot(
                requestedRootPath: resolvedRootPath,
                currentRootPath: self.activeShelfRootPath
            ) else { return }
            self.publishShelfSnapshot(
                rootPath: resolvedRootPath,
                shelves: nextShelves,
                deletedShelves: nextDeletedShelves
            )
            let dropActions = restoredSnapshot.map {
                self.shelfDropFeedbackAction(name: $0, rootPath: resolvedRootPath)
            }
            let retryAction = self.shelfUndoDeletionsFeedbackAction(
                names: failedNamesSnapshot,
                originalTimestamps: retryTimestamps,
                title: "Retry Undo",
                rootPath: resolvedRootPath
            )
            let notificationID = self.shelfUndoDeletionNotificationID(rootPath: resolvedRootPath)
            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    restoredSnapshot.count == 1 ? "Shelf deletion undone" : "Shelf deletions undone",
                    detail: restoredSnapshot.joined(separator: ", "),
                    additionalActions: dropActions,
                    notificationID: notificationID
                )
            } else if restoredSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Undo shelf deletion failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The deleted Shelves were kept. Resolve any active name conflict, then retry Undo.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            } else {
                var actions = dropActions
                if let retryAction { actions.append(retryAction) }
                self.feedbackCenter.warning(
                    "Some shelf deletions undone",
                    detail: "Restored: \(restoredSnapshot.joined(separator: ", "))\nFailed: \(failuresSnapshot.joined(separator: ", "))",
                    nextStep: "Retry Undo for the deleted Shelves that remain in Recently Deleted.",
                    additionalActions: actions,
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Restore one or more deleted shelves as a single Recently Deleted action.
/// IntelliJ's RestoreShelvedChange action operates on the selected deleted
/// changelists and reports a partial result when one list cannot be restored.
func restoreDeletedShelves(
    _ names: [String],
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    var uniqueNames: [String] = []
    var seen = Set<String>()
    for name in names {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
        uniqueNames.append(trimmed)
    }
    guard !uniqueNames.isEmpty else { return }
    let notificationID = shelfLifecycleNotificationID(
        operation: .restoreDeleted,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        uniqueNames.count == 1 ? "Restore deleted shelf" : "Restore deleted shelves",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Restore Shelf"
    )
    Task.detached(priority: .userInitiated) { [uniqueNames] in
        let shelfPathsByName = Dictionary(
            uniqueKeysWithValues: ((try? shelfRepository.shelveDeletedList()) ?? []).map {
                ($0.name, $0.paths)
            }
        )
        var restored: [String] = []
        var failures: [String] = []
        var failedNames: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        for (index, name) in uniqueNames.enumerated() {
            do {
                try shelfRepository.shelveRestoreDeleted(name: name)
                restored.append(name)
                itemStates[name] = .success
                itemDetails[name] = "Restored from Recently Deleted"
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPathsByName[name] ?? [],
                    state: .success,
                    detail: "Restored from Recently Deleted"
                )
            } catch {
                failedNames.append(name)
                itemStates[name] = .failed
                itemDetails[name] = errorMessage(error)
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPathsByName[name] ?? [],
                    state: .failed,
                    detail: errorMessage(error)
                )
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Restore Shelf",
                    detail: name
                )
            }
        }
        let restoredNames = restored
        let failureMessages = failures
        let failedNamesSnapshot = failedNames
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        do {
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh
                )
                let actions = restoredNames.map {
                    self.shelfDropFeedbackAction(
                        name: $0,
                        rootPath: resolvedRootPath
                    )
                }
                let retryAction = self.shelfLifecycleRetryFeedbackAction(
                    names: failedNamesSnapshot,
                    operation: .restoreDeleted,
                    rootPath: resolvedRootPath
                )
                let operationItems = shelfOperationItems(
                    rootPath: resolvedRootPath,
                    names: uniqueNames,
                    states: itemStatesSnapshot,
                    details: itemDetailsSnapshot,
                    children: itemChildrenSnapshot
                )
                if failureMessages.isEmpty {
                    self.feedbackCenter.success(
                        restoredNames.count == 1 ? "Shelf restored" : "Shelves restored",
                        detail: restoredNames.joined(separator: ", "),
                        additionalActions: actions,
                        notificationID: notificationID
                    )
                } else if restoredNames.isEmpty {
                    self.feedbackCenter.error(
                        "Shelf restore failed",
                        detail: failureMessages.joined(separator: "\n"),
                        nextStep: "The deleted shelves were kept. Resolve any active shelf name conflict and retry.",
                        additionalActions: retryAction.map { [$0] } ?? [],
                        notificationID: notificationID
                    )
                } else {
                    var additionalActions = actions
                    if let retryAction { additionalActions.append(retryAction) }
                    self.feedbackCenter.warning(
                        "Some shelves restored",
                        detail: "Restored: \(restoredNames.joined(separator: ", "))\nFailed: \(failureMessages.joined(separator: ", "))",
                        nextStep: "The failed deleted shelves were kept. Resolve the reported conflict and retry.",
                        additionalActions: additionalActions,
                        notificationID: notificationID
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    operationItems,
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        } catch {
            await MainActor.run {
                let notificationID = self.shelfLifecycleNotificationID(
                    operation: .restoreDeleted,
                    rootPath: resolvedRootPath
                )
                self.feedbackCenter.error(
                    "Shelf restore failed",
                    detail: failureMessages.isEmpty ? errorMessage(error) : failureMessages.joined(separator: "\n"),
                    nextStep: "The deleted shelf was kept. Resolve any active shelf name conflict and retry.",
                    additionalActions: self.shelfLifecycleRetryFeedbackAction(
                        names: failedNamesSnapshot,
                        operation: .restoreDeleted,
                        rootPath: resolvedRootPath
                    ).map { [$0] } ?? [],
                    notificationID: notificationID
                )
                self.feedbackCenter.attachOperationItems(
                    uniqueNames.map {
                        FeedbackOperationItem(
                            scope: resolvedRootPath,
                            name: $0,
                            state: itemStatesSnapshot[$0] ?? .failed,
                            detail: itemDetailsSnapshot[$0] ?? errorMessage(error)
                        )
                    },
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        }
    }
}

/// Run a standalone SubmodulePanel operation from durable input, keeping the
/// same command, credential broker, cancellation, and notification lifecycle
/// for both the initial click and a retry restored from Operation Log.
func submoduleUpdateRestoreAction(
    repo: Repository,
    rootPath: String
) -> FeedbackAction? {
    guard let info = ((try? repo.applyLocalChangesRestoreInfo()) ?? nil),
          info.operation == "submodule-update",
          let savedChangesKind = ArborVCSActionRequest.SavedChangesKind(rawValue: info.kind) else {
        return nil
    }
    let request = ArborVCSActionRequest(
        kind: .restoreApplyLocalChanges,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        savedChangesKind: savedChangesKind,
        savedChangesID: info.identifier
    )
    return FeedbackAction(title: "Resolve local changes", semanticAction: request) {
        self.openApplyLocalChangesRestore(request)
    }
}

func restoreDeletedTag(_ context: TagDeleteRecoveryContext) {
    beginFeedbackOperation("Restore tag")
    Task.detached(priority: .userInitiated) {
        do {
            // IntelliJ restores the saved tag tip as a new lightweight tag;
            // using the full peeled id avoids dependence on reflog retention.
            try context.repo.tagCreate(name: context.tag.name, at: context.tag.id)
            await MainActor.run {
                self.tagDeleteRecovery = nil
                if let rootPath = context.rootPath {
                    self.loadMultiRoots()
                    self.feedbackCenter.success("Tag restored", detail: "\(context.tag.name) · \(rootPath)")
                } else {
                    self.refreshAll(showFeedback: false)
                    self.feedbackCenter.success("Tag restored", detail: context.tag.name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Restore tag failed",
                    detail: "\(context.tag.name): \(errorMessage(error))"
                )
            }
        }
    }
}

nonisolated static func restoreLocalChangesAfterPull(
    repo: Repository,
    preservation: PullLocalChangesPreservation
) throws {
    if let shelfName = preservation.shelfName {
        try repo.shelvePopPreservation(name: shelfName)
    } else if preservation.stashID != nil || preservation.stashMessage != nil {
        let reference = try pullStashReference(
            repo: repo,
            stashID: preservation.stashID,
            message: preservation.stashMessage
        )
        try repo.stashPopWithIndex(
            index: try currentStashIndex(repo: repo, stashID: reference.stash.id),
            restoreIndex: true
        )
    }
}

/// Restore the persisted batch spec after project reopen. An active Git
/// operation is never replayed; it is handed to the project-level resolver.
func restorePersistedMultiRootRebaseSession(for projectPath: String) {
    guard multiRootRebaseSession == nil,
          let session = loadMultiRootRebaseSession(projectPath: projectPath),
          session.projectPath == projectPath else { return }
    guard session.roots.contains(where: { $0.state != .completed && $0.state != .aborted }) else {
        clearMultiRootRebaseSession(session)
        return
    }
    multiRootRebaseSession = session
    let sessionID = session.id
    Task.detached(priority: .utility) {
        let activeRoot = session.roots.compactMap { root -> String? in
            guard let rootRepo = try? openRepository(path: root.rootPath),
                  (try? rootRepo.operationState()) != nil else { return nil }
            return root.rootPath
        }.first
        await MainActor.run {
            guard self.multiRootRebaseSession?.id == sessionID else { return }
            if let activeRoot {
                self.feedbackCenter.warning(
                    "Multi-root rebase paused",
                    detail: "A persisted rebase is waiting in \(activeRoot).",
                    additionalActions: [
                        self.multiRootRebaseRecoveryFeedbackAction(
                            .openRecovery,
                            rootPath: activeRoot,
                            sessionID: sessionID
                        )
                    ],
                    notificationID: self.multiRootRebaseNotificationID()
                )
            } else {
                self.feedbackCenter.warning(
                    "Multi-root rebase recovery available",
                    detail: "The previous multi-root rebase did not finish.",
                    additionalActions: [
                        self.multiRootRebaseRecoveryFeedbackAction(.resume, sessionID: sessionID)
                    ],
                    notificationID: self.multiRootRebaseNotificationID()
                )
            }
        }
    }
}

}
