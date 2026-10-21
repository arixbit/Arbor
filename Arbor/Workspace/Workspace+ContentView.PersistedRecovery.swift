import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Restore the single-root rebase seed that was written when Arbor paused a
/// rebase entry point. Git keeps the operation itself in `.git/rebase-*`, but
/// that state does not contain Arbor's expected-HEAD undo boundary or the
/// original `--update-refs` policy. Do not synthesize a seed for an operation
/// created outside Arbor: without those facts, offering Undo would be unsafe.
func restorePersistedSingleRootRebaseState(for repositoryPath: String) {
    guard rebaseWorkspace.multiRootSession == nil,
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
                guard self.rebaseWorkspace.multiRootSession == nil else { return }
                let isCurrentRoot = self.repo?.workdir().map({
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }) == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
                if isCurrentRoot {
                    self.rebaseWorkspace.undoSeed = seed
                    self.rebaseWorkspace.rootPath = repositoryPath
                    self.rebaseWorkspace.branch = seed.branch
                    self.rebaseWorkspace.paused = true
                    self.rebaseWorkspace.pauseReason = pauseReason
                    self.rebaseWorkspace.conflicts = state.conflictedFiles
                    self.operationRecovery.operation = state
                    self.repositoryStatus.entries = status
                    if pauseReason == .conflict {
                        self.operationRecovery.showConflictResolver = true
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
                guard self.projectWorkspace.repository?.workdir().map({
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }) == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path else {
                    return
                }
                self.stashRecovery.pendingPullShelfName = preservation.shelfName
                self.stashRecovery.pendingPullStashPop = preservation.stashID != nil || preservation.stashMessage != nil
                self.stashRecovery.pendingPullStashID = preservation.stashID
                self.stashRecovery.pendingPullStashMessage = preservation.stashMessage
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
    rebaseWorkspace.paused = false
    rebaseWorkspace.pauseReason = nil
    rebaseWorkspace.conflicts = []
    rebaseWorkspace.undoSeed = nil
    rebaseWorkspace.undoTarget = target
    clearRebaseUndoSeed(repositoryPath: seed.repositoryPath)
}

/// Rehydrate preserving-process restore markers after launch. The marker is
/// written before Merge/Reset/Cherry-pick/Revert/Rebase changes the worktree,
/// so a process crash must leave an actionable path back to the same saved
/// stash or Shelf instead of silently looking like an ordinary dirty repository.
func scanPendingApplyRestores() {
    guard let projectPath = projectWorkspace.path else { return }
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
                guard self.projectWorkspace.path == projectPath else { return }
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

/// Restore the persisted batch spec after project reopen. An active Git
/// operation is never replayed; it is handed to the project-level resolver.
func restorePersistedMultiRootRebaseSession(for projectPath: String) {
    guard rebaseWorkspace.multiRootSession == nil,
          let session = loadMultiRootRebaseSession(projectPath: projectPath),
          session.projectPath == projectPath else { return }
    guard session.roots.contains(where: { $0.state != .completed && $0.state != .aborted }) else {
        clearMultiRootRebaseSession(session)
        return
    }
    rebaseWorkspace.multiRootSession = session
    let sessionID = session.id
    Task.detached(priority: .utility) {
        let activeRoot = session.roots.compactMap { root -> String? in
            guard let rootRepo = try? openRepository(path: root.rootPath),
                  (try? rootRepo.operationState()) != nil else { return nil }
            return root.rootPath
        }.first
        await MainActor.run {
            guard self.rebaseWorkspace.multiRootSession?.id == sessionID else { return }
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
