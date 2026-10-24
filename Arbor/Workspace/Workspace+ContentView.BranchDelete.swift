import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

func presentMultiRootDeleteBranchDialog(name: String) {
    let eligible = multiRootWorkspace.branchSnapshots.filter { snapshot in
        snapshot.branches.contains { $0.name == name && !$0.isCurrent }
    }
    guard !eligible.isEmpty else {
        feedbackCenter.warning(
            "Delete branch unavailable",
            detail: "No non-current Git root contains " + name + "."
        )
        return
    }
    branchWorkspace.multiRootDeleteName = name
    branchWorkspace.multiRootDeleteSelectedRootPaths = Set(eligible.map(\.rootPath))
    branchWorkspace.showMultiRootDeleteDialog = true
}

func dismissMultiRootDeleteBranchDialog() {
    branchWorkspace.showMultiRootDeleteDialog = false
    branchWorkspace.multiRootDeleteName = ""
    branchWorkspace.multiRootDeleteSelectedRootPaths = []
}

/// Delete a shared local branch using IntelliJ's multi-repository semantics:
/// safe deletion is attempted first, and an unmerged branch is force-deleted
/// while retaining the exact tip for a restore action.
func deleteMultiRootBranch(
    name: String,
    selectedRootPaths: Set<String>,
    allowForceDelete: Bool = true
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    for notificationID in [
        multiRootMergeNotificationID(),
        multiRootMergeDeleteNotificationID()
    ].compactMap({ $0 }) {
        feedbackCenter.expire(notificationID: notificationID)
    }
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains { $0.name == branchName && !$0.isCurrent }
    }
    guard !roots.isEmpty else { return }
    multiRootWorkspace.running = true
    beginFeedbackOperation("Multi-root branch deletion")
    let protectedPatterns = effectiveProtectedBranchPatterns
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var recoveryContexts: [BranchDeleteRecoveryContext] = []
        var syncStatusesByRoot: [[SyncStatus]] = []
        var failures: [String] = []
        var forceDeletedRoots: [String] = []
        for snapshot in roots {
            do {
                let rootRepo = try openRepository(path: snapshot.rootPath)
                let preview = try rootRepo.branchDeletePreview(name: branchName)
                let syncStatusesBeforeDelete = (try? rootRepo.syncStatus()) ?? []
                syncStatusesByRoot.append(syncStatusesBeforeDelete)
                var forceDeleted = false
                do {
                    try rootRepo.branchDelete(name: branchName, force: false)
                } catch {
                    guard allowForceDelete, isUnmergedBranchDeletionError(error) else { throw error }
                    try rootRepo.branchDelete(name: branchName, force: true)
                    forceDeleted = true
                }
                recoveryContexts.append(
                    BranchDeleteRecoveryContext(
                        repo: rootRepo,
                        preview: preview,
                        rootPath: snapshot.rootPath
                    )
                )
                if forceDeleted {
                    forceDeletedRoots.append(snapshot.displayName)
                }
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: true,
                        skipped: false,
                        message: forceDeleted ? "Deleted \(branchName) (force)" : "Deleted \(branchName)"
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
        let deletableRemoteBranches = deletableTrackedRemoteBranches(
            branchName: branchName,
            syncStatusesByRoot: syncStatusesByRoot,
            protectedPatterns: protectedPatterns
        )
        let contextsToOffer = recoveryContexts.map { context in
            guard let upstream = context.preview.upstream,
                  deletableRemoteBranches.contains(upstream) else { return context }
            return BranchDeleteRecoveryContext(
                repo: context.repo,
                preview: context.preview,
                rootPath: context.rootPath,
                trackedRemoteBranch: upstream
            )
        }
        let failuresToReport = failures
        let forceDeletedRootsToReport = forceDeletedRoots
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.branchWorkspace.showMultiRootDeleteDialog = false
            self.multiRootWorkspace.results = resultsToApply
            self.loadMultiRoots()
            if failuresToReport.isEmpty {
                self.branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: branchName,
                    contexts: contextsToOffer
                )
                let detail = forceDeletedRootsToReport.isEmpty
                    ? "\(contextsToOffer.count) repositories"
                    : "\(contextsToOffer.count) repositories · force deleted: \(forceDeletedRootsToReport.joined(separator: ", "))"
                self.feedbackCenter.success(
                    "Multi-root branch deletion completed",
                    detail: detail,
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: contextsToOffer
                    ),
                    notificationID: self.branchDeleteNotificationID(),
                    notificationGroup: .standard
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Multi-root branch deletion partially completed",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the affected roots and keep or rollback the successful deletions.",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: contextsToOffer
                    ),
                    notificationID: self.branchDeleteNotificationID(),
                    notificationGroup: contextsToOffer.isEmpty ? .toolWindow : .standard
                )
                self.presentMultiRootBranchDeleteRollback(
                    branchName: branchName,
                    contexts: contextsToOffer,
                    failures: failuresToReport
                )
            }
        }
    }
}

func presentMultiRootBranchDeleteRollback(
    branchName: String,
    contexts: [BranchDeleteRecoveryContext],
    failures: [String]
) {
    guard !contexts.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Multi-root branch deletion partially completed")
    let successful = contexts.map { $0.rootPath ?? String(localized: "Repository") }
    alert.informativeText = "Deleted \(branchName) in:\n\(successful.joined(separator: "\n"))\n\nFailures:\n\(failures.joined(separator: "\n"))"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Rollback Successful Roots")
    alert.addButton(withTitle: "Keep Partial Deletions")
    guard alert.runModal() == .alertFirstButtonReturn else {
        branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
            branchName: branchName,
            contexts: contexts
        )
        feedbackCenter.warning(
            "Partial branch deletions kept",
            detail: "\(branchName) in \(contexts.count) repositories"
        )
        return
    }
    restoreDeletedBranches(contexts)
}

func branchDeleteRecoveryTargets(
    from contexts: [BranchDeleteRecoveryContext]
) -> [PersistedBranchDeleteRecoveryTarget]? {
    let targets = contexts.compactMap { context -> PersistedBranchDeleteRecoveryTarget? in
        guard let rootPath = context.rootPath ?? context.repo.workdir() else { return nil }
        return PersistedBranchDeleteRecoveryTarget(
            rootPath: URL(fileURLWithPath: rootPath).standardizedFileURL.path,
            branchName: context.preview.branchName,
            tipID: context.preview.tipId,
            upstream: context.preview.upstream,
            baseBranches: context.preview.baseBranches,
            unmergedCommits: context.preview.unmergedCommits.map {
                PersistedBranchDeleteCommit(
                    id: $0.id,
                    shortID: $0.shortId,
                    summary: $0.summary,
                    time: $0.time
                )
            }
        )
    }
    guard targets.count == contexts.count, !targets.isEmpty else { return nil }
    return targets.sorted {
        if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
        if $0.branchName != $1.branchName { return $0.branchName < $1.branchName }
        return $0.tipID < $1.tipID
    }
}

func normalizedBranchDeleteRecoveryTargets(
    _ targets: [PersistedBranchDeleteRecoveryTarget]
) -> [PersistedBranchDeleteRecoveryTarget]? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let projectRoot = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let normalizedTargets = targets.map { target in
        PersistedBranchDeleteRecoveryTarget(
            rootPath: URL(fileURLWithPath: target.rootPath).standardizedFileURL.path,
            branchName: target.branchName,
            tipID: target.tipID,
            upstream: target.upstream,
            baseBranches: target.baseBranches,
            unmergedCommits: target.unmergedCommits
        )
    }.sorted {
        if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
        if $0.branchName != $1.branchName { return $0.branchName < $1.branchName }
        return $0.tipID < $1.tipID
    }
    guard !normalizedTargets.isEmpty,
          normalizedTargets.allSatisfy({ target in
              !target.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !target.tipID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && (target.rootPath == projectRoot || target.rootPath.hasPrefix(projectRoot + "/"))
          }) else {
        return nil
    }
    return normalizedTargets
}

func branchDeleteRecoveryActions(
    contexts: [BranchDeleteRecoveryContext]
) -> [FeedbackAction] {
    [
        branchDeleteRestoreAction(contexts: contexts),
        branchDeleteViewCommitsAction(contexts: contexts)
    ].compactMap { $0 }
}

func branchDeleteNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.branch-deleted.\(stableProject)"
}

func branchDelete(_ name: String) {
    guard let repo else { return }
    let protectedPatterns = effectiveProtectedBranchPatterns
    beginFeedbackOperation("Delete branch")
    Task.detached(priority: .userInitiated) {
        do {
            let preview = try? repo.branchDeletePreview(name: name)
            let syncStatusesBeforeDelete = (try? repo.syncStatus()) ?? []
            try repo.branchDelete(name: name, force: false)
            let bs = try repo.branchList()
            await MainActor.run {
                self.branchWorkspace.branches = bs
                if let preview {
                    let context = BranchDeleteRecoveryContext(
                        repo: repo,
                        preview: preview,
                        rootPath: nil,
                        trackedRemoteBranch: deletableTrackedRemoteBranch(
                            branchName: name,
                            upstream: preview.upstream,
                            syncStatuses: syncStatusesBeforeDelete,
                            protectedPatterns: protectedPatterns
                        )
                    )
                    self.branchWorkspace.deleteRecovery = context
                    self.feedbackCenter.success(
                        "Branch deleted",
                        detail: name,
                        additionalActions: self.branchDeleteRecoveryActions(
                            contexts: [context]
                        ),
                        notificationID: self.branchDeleteNotificationID(),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.success("Branch deleted", detail: name)
                }
                self.loadRepoData()
                if self.showsLogWorkspace { self.loadLog() }
            }
        } catch {
            await MainActor.run {
                if isUnmergedBranchDeletionError(error) {
                    self.prepareForceDeleteBranch(repo: repo, name: name, rootPath: nil)
                } else {
                    self.repositoryStatus.loadError = errorMessage(error)
                }
            }
        }
    }
}

func prepareForceDeleteBranch(repo: Repository, name: String, rootPath: String?) {
    let protectedPatterns = effectiveProtectedBranchPatterns
    Task.detached(priority: .userInitiated) {
        do {
            let preview = try repo.branchDeletePreview(name: name)
            let syncStatusesBeforeDelete = (try? repo.syncStatus()) ?? []
            await MainActor.run {
                guard self.confirmForceDeleteBranch(preview: preview, rootPath: rootPath) else {
                    self.feedbackCenter.warning("Branch deletion cancelled", detail: name)
                    return
                }
                self.forceDeleteBranch(
                    repo: repo,
                    preview: preview,
                    rootPath: rootPath,
                    trackedRemoteBranch: deletableTrackedRemoteBranch(
                        branchName: name,
                        upstream: preview.upstream,
                        syncStatuses: syncStatusesBeforeDelete,
                        protectedPatterns: protectedPatterns
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Delete branch failed", detail: errorMessage(error))
            }
        }
    }
}

func confirmForceDeleteBranch(preview: BranchDeletePreview, rootPath: String?) -> Bool {
    let alert = NSAlert()
    alert.messageText = "\(String(localized: "Branch is not fully merged")): \(preview.branchName)"
    let location = rootPath.map { "\n\(String(localized: "Repository")): \($0)" } ?? ""
    var details = String(localized: "Delete anyway? This permanently removes the local branch reference and can discard commits.")
    if !preview.baseBranches.isEmpty {
        details += "\n\n\(String(localized: "Already merged into")): \(preview.baseBranches.joined(separator: ", "))"
    }
    if !preview.unmergedCommits.isEmpty {
        let commits = preview.unmergedCommits
            .prefix(12)
            .map { "\($0.shortId) \($0.summary)" }
            .joined(separator: "\n")
        details += "\n\n\(String(localized: "Unmerged commits")):\n\(commits)"
        if preview.unmergedCommits.count > 12 {
            details += "\n…"
        }
    }
    alert.informativeText = String(localized: "\(details)\(location)")
    alert.addButton(withTitle: String(localized: "Delete Anyway"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}

func forceDeleteBranch(
    repo: Repository,
    preview: BranchDeletePreview,
    rootPath: String?,
    trackedRemoteBranch: String?
) {
    beginFeedbackOperation("Force delete branch")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.branchDelete(name: preview.branchName, force: true)
            let bs = try repo.branchList()
            await MainActor.run {
                let context = BranchDeleteRecoveryContext(
                    repo: repo,
                    preview: preview,
                    rootPath: rootPath,
                    trackedRemoteBranch: trackedRemoteBranch
                )
                if let rootPath {
                    self.loadMultiRoots()
                    self.feedbackCenter.success(
                        "Branch deleted",
                        detail: "\(preview.branchName) · \(rootPath)",
                        additionalActions: self.branchDeleteRecoveryActions(
                            contexts: [context]
                        ),
                        notificationID: self.branchDeleteNotificationID(),
                        notificationGroup: .standard
                    )
                } else {
                    self.branchWorkspace.branches = bs
                    self.feedbackCenter.success(
                        "Branch deleted",
                        detail: "\(preview.branchName) (force)",
                        additionalActions: self.branchDeleteRecoveryActions(
                            contexts: [context]
                        ),
                        notificationID: self.branchDeleteNotificationID(),
                        notificationGroup: .standard
                    )
                    self.loadRepoData()
                    if self.showsLogWorkspace { self.loadLog() }
                }
                self.branchWorkspace.deleteRecovery = context
            }
        } catch {
            await MainActor.run {
                let detail = rootPath.map { "\(preview.branchName) · \($0): \(errorMessage(error))" } ?? errorMessage(error)
                self.feedbackCenter.error("Force delete branch failed", detail: detail)
            }
        }
    }
}

func deleteBranchInRoot(rootPath: String, name: String, confirm: Bool = true) {
    if confirm {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete branch \(name)?")
        alert.informativeText = String(localized: "This removes the local branch reference in the selected root.")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    let protectedPatterns = effectiveProtectedBranchPatterns
    beginFeedbackOperation("Delete branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let preview = try? rootRepo.branchDeletePreview(name: name)
            let syncStatusesBeforeDelete = (try? rootRepo.syncStatus()) ?? []
            try rootRepo.branchDelete(name: name, force: false)
            await MainActor.run {
                self.loadMultiRoots()
                if let preview {
                    let context = BranchDeleteRecoveryContext(
                        repo: rootRepo,
                        preview: preview,
                        rootPath: rootPath,
                        trackedRemoteBranch: deletableTrackedRemoteBranch(
                            branchName: name,
                            upstream: preview.upstream,
                            syncStatuses: syncStatusesBeforeDelete,
                            protectedPatterns: protectedPatterns
                        )
                    )
                    self.branchWorkspace.deleteRecovery = context
                    self.feedbackCenter.success(
                        "Branch deleted",
                        detail: "\(name) · \(rootPath)",
                        additionalActions: self.branchDeleteRecoveryActions(
                            contexts: [context]
                        ),
                        notificationID: self.branchDeleteNotificationID(),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.success("Branch deleted", detail: "\(name) · \(rootPath)")
                }
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if isUnmergedBranchDeletionError(error),
                   let forceRepo = try? openRepository(path: rootPath) {
                    self.prepareForceDeleteBranch(repo: forceRepo, name: name, rootPath: rootPath)
                } else {
                    self.feedbackCenter.error("Delete branch failed", detail: "\(name) · \(rootPath): \(errorMessage(error))")
                }
            }
        }
    }
}

/// Batch counterpart of IntelliJ's DeleteBranchAction for selected local
/// references. Targets may belong to different roots and may have different
/// names; each deletion is still executed against its own repository. Safe
/// deletion is attempted first, then an unmerged target is force-deleted only
/// because the user explicitly confirmed the batch action. Every successful
/// deletion retains its exact preview for Restore/Rollback.
func deleteSelectedBranchesInRoots(_ targets: [BranchDashboardReference]) {
    if targets.allSatisfy({ $0.kind == .tag }) {
        deleteSelectedTagsInRoots(targets)
        return
    }
    if targets.allSatisfy({ $0.kind == .remote }) {
        deleteSelectedRemoteBranchesInRoots(targets)
        return
    }

    let selected = targets
        .filter { !$0.isCurrent }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.name < $1.name }
            return $0.rootPath < $1.rootPath
        }
    guard !selected.isEmpty, !multiRootWorkspace.running else { return }

    let alert = NSAlert()
    alert.messageText = String(localized: "Delete selected branches?")
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
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootWorkspace.running = true
    beginFeedbackOperation("Delete selected branches", cancelHandle: cancel)
    let protectedPatterns = effectiveProtectedBranchPatterns
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var recoveryContexts: [BranchDeleteRecoveryContext] = []
        var syncStatusesByBranch: [String: [[SyncStatus]]] = [:]
        var failures: [String] = []
        var forceDeleted: [String] = []
        var cancelled = false

        for target in selected {
            guard !cancel.isCancelled() else {
                cancelled = true
                break
            }
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                if target.kind == .remote {
                    try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                        remoteBranch: target.name,
                        broker: broker,
                        cancel: cancel
                    )
                    results.append(
                        RootOperationResult(
                            rootPath: target.rootPath,
                            displayName: displayNames[target.rootPath] ?? target.rootPath,
                            success: true,
                            skipped: false,
                            message: "Deleted \(target.name)"
                        )
                    )
                    continue
                }

                let preview = try rootRepo.branchDeletePreview(name: target.name)
                let syncStatusesBeforeDelete = (try? rootRepo.syncStatus()) ?? []
                syncStatusesByBranch[target.name, default: []].append(syncStatusesBeforeDelete)
                var wasForceDeleted = false
                do {
                    try rootRepo.branchDelete(name: target.name, force: false)
                } catch {
                    guard isUnmergedBranchDeletionError(error) else { throw error }
                    try rootRepo.branchDelete(name: target.name, force: true)
                    wasForceDeleted = true
                }
                recoveryContexts.append(
                    BranchDeleteRecoveryContext(
                        repo: rootRepo,
                        preview: preview,
                        rootPath: target.rootPath
                    )
                )
                if wasForceDeleted {
                    forceDeleted.append("\(target.name) · \(target.rootPath)")
                }
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: true,
                        skipped: false,
                        message: wasForceDeleted
                            ? "Deleted \(target.name) (force)"
                            : "Deleted \(target.name)"
                    )
                )
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                let detailMessage = target.kind == .remote
                    ? friendlyRemoteError(error)
                    : errorMessage(error)
                let detail = "\(target.name) · \(target.rootPath): \(detailMessage)"
                failures.append(detail)
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: false,
                        skipped: false,
                        message: "\(target.name): \(detailMessage)"
                    )
                )
            }
        }

        let completedResults = results
        let completedRecoveryContexts = recoveryContexts.map { context in
            let deletableRemoteBranches = deletableTrackedRemoteBranches(
                branchName: context.preview.branchName,
                syncStatusesByRoot: syncStatusesByBranch[context.preview.branchName] ?? [],
                protectedPatterns: protectedPatterns
            )
            guard let upstream = context.preview.upstream,
                  deletableRemoteBranches.contains(upstream) else { return context }
            return BranchDeleteRecoveryContext(
                repo: context.repo,
                preview: context.preview,
                rootPath: context.rootPath,
                trackedRemoteBranch: upstream
            )
        }
        let completedFailures = failures + (cancelled ? ["Operation cancelled."] : [])
        let completedForceDeleted = forceDeleted
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.multiRootWorkspace.results = completedResults
            self.loadMultiRoots()
            guard !completedRecoveryContexts.isEmpty else {
                if completedFailures.isEmpty {
                    self.feedbackCenter.success(
                        "Selected branch deletion completed",
                        detail: "\(completedResults.filter(\.success).count) branches"
                    )
                } else {
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    self.feedbackCenter.warning(
                        "Selected branch deletion partially completed",
                        detail: completedFailures.joined(separator: "\n"),
                        nextStep: "Review the failed branch or remote deletions and retry them individually."
                    )
                }
                return
            }

            let label = "selected branches"
            self.branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                branchName: label,
                contexts: completedRecoveryContexts
            )
            if completedFailures.isEmpty {
                let forceDetail = completedForceDeleted.isEmpty
                    ? "\(completedResults.filter(\.success).count) branches"
                    : "\(completedResults.filter(\.success).count) branches · force deleted: \(completedForceDeleted.joined(separator: ", "))"
                self.feedbackCenter.success(
                    "Selected branch deletion completed",
                    detail: forceDetail,
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: completedRecoveryContexts
                    ),
                    notificationID: self.branchDeleteNotificationID(),
                    notificationGroup: .standard
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Selected branch deletion partially completed",
                    detail: completedFailures.joined(separator: "\n"),
                    nextStep: "Rollback the successful deletions or keep the partial result.",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: completedRecoveryContexts
                    ),
                    notificationID: self.branchDeleteNotificationID(),
                    notificationGroup: .standard
                )
                self.presentMultiRootBranchDeleteRollback(
                    branchName: label,
                    contexts: completedRecoveryContexts,
                    failures: completedFailures
                )
            }
        }
    }
}
}
