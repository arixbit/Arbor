import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func loadProjectProtectedBranchSettings(for projectPath: String?) {
    projectProtectedBranchPatterns = GitProtectedBranchRules.projectRawValue(for: projectPath)
    projectProtectedBranchSynchronize = GitProtectedBranchRules.projectSynchronizeValue(for: projectPath)
}

var logBranchFilterTitle: String {
    activeLogStartRevisions.isEmpty
        ? "Branch"
        : activeLogStartRevisions.joined(separator: ", ")
}

/// Branch dashboard navigation is root-aware. Selecting a branch in a nested
/// Git root changes only the Log repository context; the primary Commit/Status
/// repository remains unchanged.
func navigateLogToBranch(rootPath: String?, branch: String) {
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    var navigationHeadID: String?
    if let rootPath {
        guard let rootRepo = try? openRepository(path: rootPath) else {
            feedbackCenter.error(
                "Log navigation failed",
                detail: "Unable to open Git root: \(rootPath)",
                nextStep: "Refresh Git roots and retry."
            )
            return
        }
        logList.activeRootPath = rootPath
        logList.activeRepo = rootRepo
        logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
        logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
        logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
        navigationHeadID = try? rootRepo.revisionCommitId(revision: branch)
    } else {
        logList.activeRootPath = nil
        logList.activeRepo = nil
        logRuntime.activeBranches = []
        logRuntime.activeRemoteBranches = []
        logRuntime.activeRemotes = []
        navigationHeadID = repo.flatMap { try? $0.revisionCommitId(revision: branch) }
    }
    setLogStartRevision(branch)
    logSelectionState.selection = navigationHeadID
    logSelectionState.selectedIDs = navigationHeadID.map { [$0] } ?? []
    logList.viewMode = .graph
    loadLog()
}

func presentNewBranchDialog(
    baseRevision: String? = nil,
    suggestedName: String? = nil,
    title: String? = nil,
    afterCreateRebase: Bool = false,
    repositoryOverride: Repository? = nil
) {
    branchWorkspace.newName = suggestedName ?? ""
    branchWorkspace.newBase = baseRevision ?? ""
    branchWorkspace.newDialogTitle = title ?? String(localized: "New Branch")
    branchWorkspace.newCheckout = true
    branchWorkspace.newResetExisting = false
    branchWorkspace.newAfterCreateRebase = afterCreateRebase
    branchWorkspace.newRepositoryOverride = repositoryOverride
    if let targetRepo = repositoryOverride ?? repo {
        branchWorkspace.newDialogBranches = (try? targetRepo.branchList()) ?? branchWorkspace.branches
    } else {
        branchWorkspace.newDialogBranches = branchWorkspace.branches
    }
    branchWorkspace.showNewDialog = true
}

func dismissNewBranchDialog() {
    branchWorkspace.showNewDialog = false
    branchWorkspace.newDialogTitle = String(localized: "New Branch")
    branchWorkspace.newName = ""
    branchWorkspace.newBase = ""
    branchWorkspace.newCheckout = true
    branchWorkspace.newResetExisting = false
    branchWorkspace.newAfterCreateRebase = false
    branchWorkspace.newRepositoryOverride = nil
    branchWorkspace.newDialogBranches = []
}

/// Shared Branch Dashboard semantics for a single Git root. IntelliJ's
/// Checkout as New Branch keeps the selected ref as the start point; the
/// remote Checkout with Rebase variant creates the local branch first and
/// then rebases it onto the current branch.
func presentNewBranchFromReference(
    _ reference: String,
    isRemote: Bool,
    afterCreateRebase: Bool = false,
    rootPath: String? = nil
) {
    let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReference.isEmpty else { return }
    let suggestedName: String
    if isRemote,
       let separator = trimmedReference.firstIndex(of: "/") {
        let suffixStart = trimmedReference.index(after: separator)
        suggestedName = suffixStart < trimmedReference.endIndex
            ? String(trimmedReference[suffixStart...])
            : trimmedReference
    } else {
        suggestedName = trimmedReference
    }
    let repositoryOverride: Repository?
    if let rootPath {
        guard let selectedRepository = try? openRepository(path: rootPath) else {
            feedbackCenter.warning(
                "Checkout with Rebase unavailable",
                detail: "The selected Git root could not be opened.",
                nextStep: "Refresh Git Roots, then retry from the branch or tag."
            )
            return
        }
        repositoryOverride = selectedRepository
    } else {
        repositoryOverride = nil
    }
    presentNewBranchDialog(
        baseRevision: trimmedReference,
        suggestedName: afterCreateRebase ? suggestedName : suggestedName + "-copy",
        title: afterCreateRebase ? "Checkout with Rebase" : "Checkout as New Branch",
        afterCreateRebase: afterCreateRebase,
        repositoryOverride: repositoryOverride
    )
}

nonisolated static func branchNameForProtection(_ remoteBranch: RemoteBranchInfo) -> String {
    let prefix = "\(remoteBranch.remote)/"
    if remoteBranch.name.hasPrefix(prefix) {
        return String(remoteBranch.name.dropFirst(prefix.count))
    }
    return remoteBranch.name.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/")
}

/// BRANCH-001：Recent 分组检出（recent_branches 数据源）。
func checkoutRecentBranch(_ name: String) {
    // Keep Recent and Local Branches on the same checkout state machine so a
    // dirty-worktree checkout cannot bypass Smart/Force/Cancel recovery.
    switchBranch(name)
}

/// IntelliJ's "Show My Branches" is based on branch ownership, not merely on
/// the author of the branch tip. The engine computes each reference's commits
/// that are not reachable from another branch and matches those commits to
/// Git's configured identity. Keep the expensive reachability work off the UI
/// actor and discard results after a project/root refresh.
func setLogBranchesShowOnlyMy(_ enabled: Bool) {
    logBranchesPanel.showOnlyMy = enabled
    logBranchesPanel.showMyTask?.cancel()
    logBranchesPanel.showMyTask = nil

    guard enabled else {
        logBranchesPanel.myBranchIDs = []
        logBranchesPanel.isLoadingMy = false
        return
    }

    var rootPaths: [String]
    if multiRootBranchSnapshots.count > 1 {
        rootPaths = multiRootBranchSnapshots.map(\.rootPath)
    } else if let projectPath {
        rootPaths = [projectPath]
    } else {
        rootPaths = []
    }
    rootPaths = Array(Set(rootPaths)).sorted()
    guard !rootPaths.isEmpty else {
        logBranchesPanel.myBranchIDs = []
        logBranchesPanel.isLoadingMy = false
        return
    }

    let projectToken = projectPath
    logBranchesPanel.isLoadingMy = true
    logBranchesPanel.showMyTask = Task.detached(priority: .utility) { [rootPaths] in
        var branchIDs = Set<String>()
        for rootPath in rootPaths {
            guard !Task.isCancelled,
                  let rootRepo = try? openRepository(path: rootPath),
                  let names = try? rootRepo.myBranchNames() else { continue }
            branchIDs.formUnion(names.local.map {
                BranchDashboardReference.referenceID(
                    rootPath: rootPath,
                    name: $0,
                    kind: .local
                )
            })
            branchIDs.formUnion(names.remote.map {
                BranchDashboardReference.referenceID(
                    rootPath: rootPath,
                    name: $0,
                    kind: .remote
                )
            })
        }
        guard !Task.isCancelled else { return }
        let resolvedBranchIDs = branchIDs
        await MainActor.run {
            guard self.projectPath == projectToken,
                  self.logBranchesPanel.showOnlyMy else { return }
            self.logBranchesPanel.myBranchIDs = resolvedBranchIDs
            self.logBranchesPanel.isLoadingMy = false
            self.logBranchesPanel.showMyTask = nil
        }
    }
}

func refreshLogMyBranches() {
    guard logBranchesPanel.showOnlyMy else { return }
    setLogBranchesShowOnlyMy(true)
}

func presentMultiRootNewBranchDialog() {
    guard !multiRootBranchSnapshots.isEmpty else {
        loadMultiRoots()
        feedbackCenter.warning("New branch unavailable", detail: "No Git roots were discovered.")
        return
    }
    branchWorkspace.multiRootNewName = ""
    branchWorkspace.multiRootNewBase = ""
    branchWorkspace.multiRootNewCheckout = true
    branchWorkspace.multiRootNewResetExisting = false
    branchWorkspace.multiRootExistingNames = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { snapshot in
            (snapshot.rootPath, Set(snapshot.branches.map(\.name)))
        }
    )
    branchWorkspace.multiRootNewSelectedRootPaths = Set(multiRootBranchSnapshots.map(\.rootPath))
    branchWorkspace.showMultiRootNewDialog = true
}

/// IntelliJ's Checkout as New Branch action keeps the selected reference as
/// the base revision and restricts the dialog to the owning Git root.  Do not
/// reuse the project-wide New Branch defaults here: a same-named ref in a
/// nested root must never become the base of the new branch.
func presentMultiRootNewBranchFromReference(
    rootPath: String,
    reference: String,
    isRemote: Bool
) {
    guard multiRootBranchSnapshots.contains(where: { $0.rootPath == rootPath }) else {
        feedbackCenter.warning(
            "Checkout as New Branch unavailable",
            detail: "The selected Git root is no longer available: \(rootPath)"
        )
        loadMultiRoots()
        return
    }

    let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReference.isEmpty else {
        feedbackCenter.warning(
            "Checkout as New Branch unavailable",
            detail: "The selected reference is empty."
        )
        return
    }

    let suggestedName: String
    if isRemote,
       let separator = trimmedReference.firstIndex(of: "/") {
        let suffixStart = trimmedReference.index(after: separator)
        suggestedName = suffixStart < trimmedReference.endIndex
            ? String(trimmedReference[suffixStart...])
            : trimmedReference
    } else {
        suggestedName = trimmedReference
    }

    branchWorkspace.multiRootNewName = suggestedName + "-copy"
    branchWorkspace.multiRootNewBase = trimmedReference
    branchWorkspace.multiRootNewCheckout = true
    branchWorkspace.multiRootNewResetExisting = false
    branchWorkspace.multiRootExistingNames = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { snapshot in
            (snapshot.rootPath, Set(snapshot.branches.map(\.name)))
        }
    )
    branchWorkspace.multiRootNewSelectedRootPaths = [rootPath]
    branchWorkspace.showMultiRootNewDialog = true
}

func dismissMultiRootNewBranchDialog() {
    branchWorkspace.showMultiRootNewDialog = false
    branchWorkspace.multiRootNewName = ""
    branchWorkspace.multiRootNewBase = ""
    branchWorkspace.multiRootNewCheckout = true
    branchWorkspace.multiRootNewResetExisting = false
    branchWorkspace.multiRootExistingNames = [:]
    branchWorkspace.multiRootNewSelectedRootPaths = []
}

func presentMultiRootRenameBranchDialog(name: String) {
    let eligible = multiRootBranchSnapshots.filter { snapshot in
        snapshot.branches.contains(where: { $0.name == name })
    }
    guard !eligible.isEmpty else {
        feedbackCenter.warning("Rename branch unavailable", detail: "No Git root contains " + name + ".")
        return
    }
    branchWorkspace.multiRootRenameOldName = name
    branchWorkspace.multiRootRenameNewName = name
    branchWorkspace.multiRootRenameUnsetUpstream = false
    branchWorkspace.multiRootRenameSelectedRootPaths = Set(eligible.map(\.rootPath))
    branchWorkspace.showMultiRootRenameDialog = true
}

func dismissMultiRootRenameBranchDialog() {
    branchWorkspace.showMultiRootRenameDialog = false
    branchWorkspace.multiRootRenameOldName = ""
    branchWorkspace.multiRootRenameNewName = ""
    branchWorkspace.multiRootRenameUnsetUpstream = false
    branchWorkspace.multiRootRenameSelectedRootPaths = []
}

/// Rename the same local branch in selected Git roots. A failure in one root
/// does not hide successful roots; the user gets an explicit rollback choice,
/// matching IntelliJ's repository-scoped branch operation model.
func renameMultiRootBranch(
    oldName: String,
    newName: String,
    unsetUpstream: Bool,
    selectedRootPaths: Set<String>
) {
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return }
    let roots = multiRootBranchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains(where: { $0.name == oldName })
    }
    guard !roots.isEmpty else { return }
    multiRootRunning = true
    beginFeedbackOperation("Multi-root branch rename")
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var successfulTargets: [PersistedMultiRootBranchRenameRollbackTarget] = []
        var failures: [String] = []
        for snapshot in roots {
            let originalUpstream = snapshot.syncStatuses.first {
                $0.branch == oldName && $0.trackingExists
            }?.upstream
            do {
                let rootRepo = try openRepository(path: snapshot.rootPath)
                try rootRepo.branchRename(old: oldName, new: newName)
                if unsetUpstream {
                    do {
                        try rootRepo.branchUnsetUpstream(branch: newName)
                    } catch {
                        do {
                            try rootRepo.branchRename(old: newName, new: oldName)
                        } catch let rollbackError {
                            throw NSError(
                                domain: "Arbor.MultiRootBranchRename",
                                code: 2,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Upstream removal failed: \(errorMessage(error)); automatic rename rollback failed: \(errorMessage(rollbackError))"
                                ]
                            )
                        }
                        throw NSError(
                            domain: "Arbor.MultiRootBranchRename",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Upstream removal failed; the branch rename was rolled back: \(errorMessage(error))"
                            ]
                        )
                    }
                }
                if let expectedNewTip = try? rootRepo.revisionCommitId(revision: newName),
                   !expectedNewTip.isEmpty,
                   let branchSnapshot = try? rootRepo.branchList() {
                    let expectedCurrentBranch = branchSnapshot.first { $0.isCurrent }?.name ?? ""
                    let expectedUpstream = unsetUpstream ? nil : originalUpstream
                    successfulTargets.append(
                        PersistedMultiRootBranchRenameRollbackTarget(
                            rootPath: snapshot.rootPath,
                            displayName: snapshot.displayName,
                            oldName: oldName,
                            newName: newName,
                            expectedNewTip: expectedNewTip,
                            expectedCurrentBranch: expectedCurrentBranch,
                            expectedUpstream: expectedUpstream,
                            upstream: originalUpstream
                        )
                    )
                }
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: true,
                        skipped: false,
                        message: "Renamed \(oldName) to \(newName)"
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
        let successfulTargetsToOffer = successfulTargets
        let failuresToReport = failures
        await MainActor.run {
            self.multiRootRunning = false
            self.branchWorkspace.showMultiRootRenameDialog = false
            self.multiRootResults = resultsToApply
            self.loadMultiRoots()
            if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root branch rename completed",
                    detail: "\(successfulTargetsToOffer.count) repositories · \(oldName) → \(newName)"
                )
            } else {
                self.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.presentMultiRootBranchRenameRollback(
                    oldName: oldName,
                    newName: newName,
                    targets: successfulTargetsToOffer,
                    failureDetail: failuresToReport.joined(separator: "\n")
                )
            }
        }
    }
}

func presentMultiRootBranchRenameRollback(
    oldName: String,
    newName: String,
    targets: [PersistedMultiRootBranchRenameRollbackTarget],
    failureDetail: String
) {
    guard !targets.isEmpty else {
        feedbackCenter.warning(
            "Multi-root branch rename failed",
            detail: failureDetail,
            nextStep: "Check the selected Git roots and retry.",
            notificationID: multiRootBranchRenameRollbackNotificationID(),
            notificationGroup: .standard
        )
        return
    }
    let rollbackRequest = multiRootBranchRenameRollbackRequest(
        oldName: oldName,
        newName: newName,
        targets: targets
    )
    let keepRequest = ArborVCSActionRequest(
        kind: .keepMultiRootBranchRenamePartial,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: "",
        multiRootBranchRenameOldName: oldName,
        multiRootBranchRenameNewName: newName
    )
    feedbackCenter.warning(
        "Multi-root branch rename partially completed",
        detail: failureDetail,
        nextStep: "Rollback the successful roots or keep the partial branch state.",
        additionalActions: [
            FeedbackAction(
                title: "Rollback Successful Roots",
                semanticAction: rollbackRequest
            ) {
                self.handleVCSActionRequest(rollbackRequest)
            },
            FeedbackAction(
                title: "Keep Partial Renames",
                semanticAction: keepRequest
            ) {
                self.handleVCSActionRequest(keepRequest)
            }
        ],
        notificationID: multiRootBranchRenameRollbackNotificationID(),
        notificationGroup: .standard
    )
}

func multiRootBranchRenameRollbackRequest(
    oldName: String,
    newName: String,
    targets: [PersistedMultiRootBranchRenameRollbackTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootBranchRename,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: "",
        multiRootBranchRenameOldName: oldName,
        multiRootBranchRenameNewName: newName,
        multiRootBranchRenameRollbackTargets: targets
    )
}

func multiRootBranchRenameRollbackNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-branch-rename.rollback.\(stableProject)"
}

func rollbackMultiRootBranchRename(
    _ targets: [PersistedMultiRootBranchRenameRollbackTarget]
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Rollback multi-root branch rename")
    Task.detached(priority: .userInitiated) {
        var results: [(target: PersistedMultiRootBranchRenameRollbackTarget, success: Bool, message: String)] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                let branches = try rootRepo.branchList()
                let oldBranch = branches.first { $0.name == target.oldName }
                let newBranch = branches.first { $0.name == target.newName }
                let currentBranch = branches.first { $0.isCurrent }?.name ?? ""

                if newBranch != nil {
                    guard oldBranch == nil else {
                        throw NSError(
                            domain: "Arbor.MultiRootBranchRenameRollback",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "both old and new branch names exist"]
                        )
                    }
                    let actualTip = try rootRepo.revisionCommitId(revision: target.newName)
                    let actualUpstream = (try rootRepo.syncStatus()).first {
                        $0.branch == target.newName && $0.trackingExists
                    }?.upstream
                    guard actualTip == target.expectedNewTip,
                          currentBranch == target.expectedCurrentBranch,
                          actualUpstream == target.expectedUpstream else {
                        throw NSError(
                            domain: "Arbor.MultiRootBranchRenameRollback",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "branch state changed after the rename"]
                        )
                    }
                    try rootRepo.branchRename(old: target.newName, new: target.oldName)
                } else {
                    guard oldBranch != nil else {
                        throw NSError(
                            domain: "Arbor.MultiRootBranchRenameRollback",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "neither renamed branch exists"]
                        )
                    }
                    let actualTip = try rootRepo.revisionCommitId(revision: target.oldName)
                    let expectedRollbackBranch = target.expectedCurrentBranch == target.newName
                        ? target.oldName
                        : target.expectedCurrentBranch
                    let actualUpstream = (try rootRepo.syncStatus()).first {
                        $0.branch == target.oldName && $0.trackingExists
                    }?.upstream
                    let upstreamIsSafe = target.upstream == nil
                        ? actualUpstream == nil
                        : actualUpstream == nil || actualUpstream == target.upstream
                    guard actualTip == target.expectedNewTip,
                          currentBranch == expectedRollbackBranch,
                          upstreamIsSafe else {
                        throw NSError(
                            domain: "Arbor.MultiRootBranchRenameRollback",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "branch state changed after rollback began"]
                        )
                    }
                }
                if let upstream = target.upstream, !upstream.isEmpty {
                    try rootRepo.branchSetUpstream(branch: target.oldName, upstream: upstream)
                }
                results.append((target, true, ""))
            } catch {
                results.append((target, false, errorMessage(error)))
            }
        }
        let resultsSnapshot = results
        await MainActor.run {
            self.loadMultiRoots()
            let failures = resultsSnapshot.filter { !$0.success }
            guard !failures.isEmpty else {
                self.feedbackCenter.success(
                    "Branch rename rollback completed",
                    detail: "\(resultsSnapshot.count) repositories · \(targets.first?.oldName ?? "")",
                    notificationID: self.multiRootBranchRenameRollbackNotificationID(),
                    notificationGroup: .standard
                )
                return
            }
            let remainingTargets = failures.map { $0.target }
            let retryRequest = self.multiRootBranchRenameRollbackRequest(
                oldName: targets.first?.oldName ?? "",
                newName: targets.first?.newName ?? "",
                targets: remainingTargets
            )
            self.feedbackCenter.warning(
                "Branch rename rollback partially failed",
                detail: failures.map { "\($0.target.displayName): \($0.message)" }.joined(separator: "\n"),
                nextStep: "Review changed roots and retry only the remaining rollback targets.",
                additionalActions: [
                    FeedbackAction(
                        title: "Retry Remaining Rollback",
                        semanticAction: retryRequest
                    ) {
                        self.handleVCSActionRequest(retryRequest)
                    }
                ],
                notificationID: self.multiRootBranchRenameRollbackNotificationID(),
                notificationGroup: .standard
            )
        }
    }
}

func presentMultiRootDeleteBranchDialog(name: String) {
    let eligible = multiRootBranchSnapshots.filter { snapshot in
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
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    for notificationID in [
        multiRootMergeNotificationID(),
        multiRootMergeDeleteNotificationID()
    ].compactMap({ $0 }) {
        feedbackCenter.expire(notificationID: notificationID)
    }
    let roots = multiRootBranchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains { $0.name == branchName && !$0.isCurrent }
    }
    guard !roots.isEmpty else { return }
    multiRootRunning = true
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
            self.multiRootRunning = false
            self.branchWorkspace.showMultiRootDeleteDialog = false
            self.multiRootResults = resultsToApply
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
                self.toolWindowMode = .operations
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
    alert.messageText = "Multi-root branch deletion partially completed"
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

/// BRANCH-001：对选中的 Git roots 创建同名分支。Rust 返回旧 HEAD 与逐 root
/// 状态，Swift 只负责呈现 IntelliJ 风格的部分成功和显式 rollback 决策。
func createMultiRootBranch(
    name: String,
    baseRevision: String,
    checkout: Bool,
    reset: Bool,
    selectedRootPaths: Set<String>
) {
    multiRootUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryAvailable = false
    multiRootCheckoutUpdateRetryContext = nil
    guard let projectPath else { return }
    let branchName = GitBranchNameCleanup.cleanUp(name)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    let startPoint = baseRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = selectedRootPaths.isEmpty ? nil : Array(selectedRootPaths)
    multiRootRunning = true
    beginFeedbackOperation("Multi-root branch creation")
    Task.detached(priority: .userInitiated) {
        do {
            let results = try Arbor.runMultiRootBranchCreateWithOptions(
                scanRoot: projectPath,
                selectedRootPaths: selected,
                name: branchName,
                startPoint: startPoint.isEmpty ? nil : startPoint,
                checkout: checkout,
                reset: reset
            )
            await MainActor.run {
                self.multiRootResults = results.map {
                    RootOperationResult(
                        rootPath: $0.rootPath,
                        displayName: $0.displayName,
                        success: $0.success,
                        skipped: $0.skipped,
                        message: $0.message
                    )
                }
                self.multiRootRunning = false
                self.loadMultiRoots()
                let created = results.filter { $0.success && !$0.skipped && $0.branchCreated }.count
                let overwritten = results.filter {
                    $0.success && !$0.skipped && $0.previousBranchTip != nil
                }.count
                let failures = results.filter { !$0.success }
                if failures.isEmpty {
                    self.feedbackCenter.success(
                        "Multi-root branch creation completed",
                        detail: "\(created) created · \(overwritten) overwritten · \(branchName)"
                    )
                } else {
                    self.operationsViewMode = .roots
                    self.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    self.presentMultiRootBranchRollback(name: branchName, results: results)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootRunning = false
                self.feedbackCenter.error(
                    "Multi-root branch creation failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func presentMultiRootBranchRollback(
    name: String,
    results: [MultiRootBranchResult]
) {
    let targets = results
        .filter {
            $0.success && !$0.skipped
                && ($0.branchCreated || $0.previousBranchTip != nil)
        }
        .map {
            MultiRootBranchCreateTarget(
                rootPath: $0.rootPath,
                checkedOut: $0.checkedOut,
                previousBranch: $0.previousBranch,
                previousHead: $0.previousHead,
                expectedHead: $0.checkedOut ? $0.expectedBranchTip : nil,
                expectedBranch: $0.checkedOut ? name : nil,
                previousBranchTip: $0.previousBranchTip,
                expectedBranchTip: $0.expectedBranchTip
            )
        }
    let failureDetail = results
        .filter { !$0.success || $0.skipped }
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    guard !targets.isEmpty else {
        feedbackCenter.warning(
            "Multi-root branch creation failed",
            detail: failureDetail,
            nextStep: "Check the selected Git roots and retry.",
            notificationID: multiRootBranchCreateRollbackNotificationID(),
            notificationGroup: .standard
        )
        return
    }

    let rollbackRequest = multiRootBranchCreateRollbackRequest(
        branchName: name,
        targets: targets
    )
    let keepRequest = ArborVCSActionRequest(
        kind: .keepMultiRootBranchCreatePartial,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: "",
        multiRootBranchName: name
    )
    feedbackCenter.warning(
        "Multi-root branch creation partially completed",
        detail: failureDetail,
        nextStep: "Rollback the successful roots or keep the partial branch state.",
        additionalActions: [
            FeedbackAction(
                title: "Rollback Successful Roots",
                semanticAction: rollbackRequest
            ) {
                self.handleVCSActionRequest(rollbackRequest)
            },
            FeedbackAction(
                title: "Keep Partial Branches",
                semanticAction: keepRequest
            ) {
                self.handleVCSActionRequest(keepRequest)
            }
        ],
        notificationID: multiRootBranchCreateRollbackNotificationID(),
        notificationGroup: .standard
    )
}

func multiRootBranchCreateRollbackRequest(
    branchName: String,
    targets: [MultiRootBranchCreateTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootBranchCreate,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: "",
        multiRootBranchName: branchName,
        multiRootBranchCreateRollbackTargets: targets.map(PersistedMultiRootBranchCreateTarget.init)
    )
}

func multiRootBranchCreateRollbackNotificationID() -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-branch-create.rollback.\(stableProject)"
}

func rollbackMultiRootBranchCreate(
    _ targets: [MultiRootBranchCreateTarget],
    branchName: String
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Rollback multi-root branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rollback = try Arbor.rollbackMultiRootBranchCreateWithState(
                name: branchName,
                targets: targets
            )
            await MainActor.run {
                self.finishMultiRootBranchCreateRollback(
                    branchName: branchName,
                    targets: targets,
                    results: rollback
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.warning(
                    "Branch rollback failed",
                    detail: errorMessage(error),
                    nextStep: "Retry after confirming the selected roots still contain the expected branch state.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Branch Rollback",
                            semanticAction: self.multiRootBranchCreateRollbackRequest(
                                branchName: branchName,
                                targets: targets
                            )
                        ) {
                            self.rollbackMultiRootBranchCreate(targets, branchName: branchName)
                        }
                    ],
                    notificationID: self.multiRootBranchCreateRollbackNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

func finishMultiRootBranchCreateRollback(
    branchName: String,
    targets: [MultiRootBranchCreateTarget],
    results: [RootOperationResult]
) {
    multiRootResults = results
    loadMultiRoots()
    let failedRootPaths = Set(results.filter { !$0.success }.map(\.rootPath))
    let remainingTargets = targets.filter { failedRootPaths.contains($0.rootPath) }
    guard !remainingTargets.isEmpty else {
        feedbackCenter.success(
            "Branch rollback completed",
            detail: branchName,
            notificationID: multiRootBranchCreateRollbackNotificationID(),
            notificationGroup: .standard
        )
        return
    }

    let retryRequest = multiRootBranchCreateRollbackRequest(
        branchName: branchName,
        targets: remainingTargets
    )
    let failures = results
        .filter { !$0.success }
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    feedbackCenter.warning(
        "Branch rollback partially failed",
        detail: failures,
        nextStep: "Review the remaining roots and retry only when their expected branch state is still present.",
        additionalActions: [
            FeedbackAction(
                title: "Retry Remaining Rollback",
                semanticAction: retryRequest
            ) {
                self.rollbackMultiRootBranchCreate(
                    remainingTargets,
                    branchName: branchName
                )
            }
        ],
        notificationID: multiRootBranchCreateRollbackNotificationID(),
        notificationGroup: .standard
    )
}

/// Capture the symbolic HEAD identity alongside commit IDs so an Update
/// rollback cannot mutate a different branch that happens to share the same
/// commit tip. An empty value represents detached HEAD.
nonisolated static func headBranchNames(for rootPaths: [String]) -> [String: String] {
    var branches: [String: String] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
        let branch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name ?? ""
        branches[rootPath] = branch
    }
    return branches
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
    guard let projectPath, !projectPath.isEmpty else { return nil }
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
    guard let projectPath, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.branch-deleted.\(stableProject)"
}

func createdCheckoutBranch(
    reference: String,
    detach: Bool,
    snapshot: GitRootBranchSnapshot?
) -> String? {
    guard !detach,
          let snapshot,
          snapshot.branches.allSatisfy({ $0.name != reference }),
          snapshot.remoteBranches.contains(where: { $0.name == reference }),
          let separator = reference.firstIndex(of: "/") else {
        return nil
    }
    return String(reference[reference.index(after: separator)...])
}

/// IntelliJ asks for a second confirmation only when resetting an existing
/// branch would actually drop commits that are not reachable from the chosen
/// start point. The checkbox itself is still the explicit opt-in for reset;
/// this guard protects the more destructive local-commit case.
func confirmBranchResetIfNeeded(
    repo: Repository,
    name: String,
    startPoint: String?
) -> Bool {
    guard let branches = try? repo.branchList(),
          branches.contains(where: { $0.name == name }) else {
        return true
    }
    let base: String
    if let trimmed = startPoint?.trimmingCharacters(in: .whitespacesAndNewlines),
       !trimmed.isEmpty {
        base = trimmed
    } else {
        base = "HEAD"
    }
    guard let comparison = try? repo.branchCompare(a: name, b: base),
          comparison.ahead > 0 else {
        return true
    }

    let alert = NSAlert()
    alert.messageText = "Reset existing branch?"
    alert.informativeText = "(name) has (comparison.ahead) local commit(s) not contained in (base). Resetting it will discard those commits from the branch ref."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Drop Local Commits")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}

func branchCreate(
    at baseRevision: String? = nil,
    checkout: Bool = false,
    reset: Bool = false,
    repository repositoryOverride: Repository? = nil
) {
    guard let targetRepo = repositoryOverride ?? branchWorkspace.newRepositoryOverride ?? repo else { return }
    let name = GitBranchNameCleanup.cleanUp(branchWorkspace.newName)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let base = baseRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reset || confirmBranchResetIfNeeded(
        repo: targetRepo,
        name: name,
        startPoint: base
    ) else { return }
    beginFeedbackOperation("Create branch")
    let targetRootPath = targetRepo.workdir() ?? "selected repository"
    Task.detached(priority: .userInitiated) {
        do {
            let startPoint = base?.isEmpty == true ? nil : base
            try targetRepo.branchCreateOrReset(
                name: name,
                at: startPoint,
                checkout: checkout,
                reset: reset
            )
            let bs = try targetRepo.branchList()
            await MainActor.run {
                if self.repo?.workdir() == targetRootPath {
                    self.branchWorkspace.branches = bs
                    self.loadRepoData()
                } else {
                    self.loadMultiRoots()
                }
                self.branchWorkspace.newName = ""
                self.branchWorkspace.newBase = ""
                self.feedbackCenter.success(
                    "Branch created",
                    detail: checkout
                        ? "\(name) (checked out) · \(targetRootPath)"
                        : "\(name) · \(targetRootPath)"
                )
                if self.toolWindowMode == .log { self.loadLog() }
            }
        } catch { await MainActor.run { self.loadError = errorMessage(error) } }
    }
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
                if self.toolWindowMode == .log { self.loadLog() }
            }
        } catch {
            await MainActor.run {
                if isUnmergedBranchDeletionError(error) {
                    self.prepareForceDeleteBranch(repo: repo, name: name, rootPath: nil)
                } else {
                    self.loadError = errorMessage(error)
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
    alert.informativeText = "\(details)\(location)"
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
                    if self.toolWindowMode == .log { self.loadLog() }
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

func nextBranchCleanupGeneration() -> Int {
    branchCleanup.windowGeneration += 1
    return branchCleanup.windowGeneration
}

nonisolated func loadBranchCleanupRoots(scanRoot: String) throws -> [BranchCleanupRoot] {
    let roots = try discoverGitRoots(scanRoot: scanRoot, maxDepth: nil)
    return try roots.map { root in
        let rootRepo = try openRepository(path: root.path)
        let branches = try rootRepo.branchList()
        let syncStatuses = (try? rootRepo.syncStatus()) ?? []
        let trackingByBranch = Dictionary(
            uniqueKeysWithValues: syncStatuses
                .filter { $0.trackingExists }
                .map { ($0.branch, $0.upstream) }
        )
        return BranchCleanupRoot(
            rootPath: root.path,
            displayName: root.displayName,
            relativePath: root.relativePath,
            branches: branches,
            trackingByBranch: trackingByBranch,
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: nil
        )
    }
}

func beginBranchCleanup() {
    guard let projectPath else { return }
    let generation = nextBranchCleanupGeneration()
    beginFeedbackOperation("Load branch cleanup")
    let scanRoot = projectPath
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            await MainActor.run {
                guard self.branchCleanup.windowGeneration == generation else { return }
                self.branchCleanupWindow.present(roots: roots)
                self.feedbackCenter.success("Branch cleanup loaded", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load branch cleanup failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func refreshBranchCleanup() {
    guard let projectPath else { return }
    let generation = nextBranchCleanupGeneration()
    beginFeedbackOperation("Refresh branch cleanup")
    let scanRoot = projectPath
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            await MainActor.run {
                guard self.branchCleanup.windowGeneration == generation else { return }
                self.branchCleanupWindow.updateRoots(roots)
                self.feedbackCenter.success("Branch cleanup refreshed", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Refresh branch cleanup failed", detail: errorMessage(error))
            }
        }
    }
}

func reloadBranchCleanupContext(for generation: Int) {
    guard let projectPath else { return }
    let scanRoot = projectPath
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            await MainActor.run {
                guard self.branchCleanup.windowGeneration == generation else { return }
                self.branchCleanupWindow.updateRoots(roots)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Refresh branch cleanup failed", detail: errorMessage(error))
            }
        }
    }
}

func calculateBranchCleanup(target: String, prefix: String) {
    let roots = branchCleanupWindow.roots
    let generation = nextBranchCleanupGeneration()
    let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return }
    beginFeedbackOperation("Calculate branch merge status")
    Task.detached(priority: .userInitiated) {
        let scanResults = await scanBranchMergeRoots(roots, target: target, prefix: prefix)
        let rootsToApply = scanResults.map(\.root)
        let failuresToReport = scanResults.compactMap { result in
            result.error.map { "\(result.root.displayName): \($0)" }
        }
        await MainActor.run {
            guard self.branchCleanup.windowGeneration == generation else { return }
            self.branchCleanupWindow.updateRoots(rootsToApply)
            if failuresToReport.isEmpty {
                self.feedbackCenter.success("Branch merge status calculated", detail: target)
            } else {
                self.feedbackCenter.warning(
                    "Branch merge status incomplete",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Choose a target branch that exists in each affected root."
                )
            }
        }
    }
}

func deleteBranchCleanup(_ selections: [BranchCleanupSelection]) {
    guard !selections.isEmpty else { return }
    let generation = nextBranchCleanupGeneration()
    beginFeedbackOperation("Delete selected branches")
    Task.detached(priority: .userInitiated) {
        var deleted: [String] = []
        var failures: [String] = []
        for selection in selections {
            do {
                let rootRepo = try openRepository(path: selection.rootPath)
                try rootRepo.branchDelete(name: selection.branchName, force: false)
                deleted.append("\(selection.branchName) · \(selection.rootPath)")
            } catch {
                failures.append("\(selection.branchName) · \(selection.rootPath): \(errorMessage(error))")
            }
        }
        let deletedToReport = deleted
        let failuresToReport = failures
        await MainActor.run {
            guard self.branchCleanup.windowGeneration == generation else { return }
            self.loadRepoData()
            if failuresToReport.isEmpty {
                self.feedbackCenter.success("Selected branches deleted", detail: deletedToReport.joined(separator: ", "))
            } else {
                self.feedbackCenter.warning(
                    "Some branches could not be deleted",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the affected roots and delete the remaining branches individually."
                )
            }
            self.reloadBranchCleanupContext(for: generation)
        }
    }
}

func branchRename() {
    guard let repo, !branchWorkspace.renameOld.isEmpty, !branchWorkspace.renameNew.isEmpty else { return }
    let old = branchWorkspace.renameOld, new = branchWorkspace.renameNew
    beginFeedbackOperation("Rename branch")
    Task.detached(priority: .userInitiated) {
        do {
            let localBranchNames = try repo.branchList().map(\.name)
            let remoteBranchNames = try repo.remoteBranchList().map(\.name)
            if let conflict = branchRenameConflictMessage(
                oldName: old,
                newName: new,
                localBranchNames: localBranchNames,
                remoteBranchNames: remoteBranchNames
            ) {
                throw NSError(
                    domain: "Arbor.BranchRename",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: conflict]
                )
            }
            try repo.validateBranchName(name: new)
            try repo.branchRename(old: old, new: new)
            let bs = try repo.branchList()
            await MainActor.run {
                self.branchWorkspace.branches = bs; self.branchWorkspace.renameOld = ""; self.branchWorkspace.renameNew = ""
                self.feedbackCenter.success("Branch renamed", detail: "\(old) → \(new)")
                self.loadRepoData()
                if self.toolWindowMode == .log { self.loadLog() }
            }
        } catch { await MainActor.run { self.loadError = errorMessage(error) } }
    }
}

func switchBranch(_ name: String) {
    guard let repo else { return }
    beginFeedbackOperation("Checkout branch")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.switchBranch(name: name)
            await MainActor.run {
                self.loadError = nil
                self.feedbackCenter.success("Branch checked out", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: name,
                    detail: detail,
                    onSmart: { self.smartCheckoutBranch(repo: repo, name: name) },
                    onForce: { self.forceCheckoutBranch(repo: repo, name: name) }
                )
            }
        }
    }
}

/// Branches Popup 多 root 行为：在选中 root 内检出，不把同名分支误操作到
/// 当前窗口绑定的另一个 repository。
func checkoutBranchInRoot(rootPath: String, reference: String, isRemote: Bool) {
    beginFeedbackOperation(isRemote ? "Checkout remote branch" : "Checkout branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if isRemote {
                try rootRepo.checkoutRemoteBranch(remoteBranch: reference, localName: nil)
            } else {
                try rootRepo.switchBranch(name: reference)
            }
            await MainActor.run {
                self.feedbackCenter.success(
                    isRemote ? "Remote branch checked out" : "Branch checked out",
                    detail: reference
                )
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
            }
        } catch {
            let detail = errorMessage(error)
            do {
                let rootRepo = try openRepository(path: rootPath)
                await MainActor.run {
                    self.presentCheckoutRecovery(
                        repo: rootRepo,
                        name: reference,
                        detail: detail,
                        onSmart: {
                            if isRemote {
                                self.smartCheckoutRemoteBranch(repo: rootRepo, remoteBranch: reference) {
                                    self.loadMultiRoots()
                                }
                            } else {
                                self.smartCheckoutBranch(repo: rootRepo, name: reference) {
                                    self.loadMultiRoots()
                                }
                            }
                        },
                        onForce: {
                            if isRemote {
                                self.forceCheckoutRemoteBranch(repo: rootRepo, remoteBranch: reference) {
                                    self.loadMultiRoots()
                                }
                            } else {
                                self.forceCheckoutBranch(repo: rootRepo, name: reference) {
                                    self.loadMultiRoots()
                                }
                            }
                        }
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error("Root checkout failed", detail: detail)
                }
            }
        }
    }
}

/// Recent branch checkout is the same local-branch operation, but the root is
/// explicit so a matching branch name in another repository cannot win.
func checkoutRecentBranchInRoot(rootPath: String, name: String) {
    checkoutBranchInRoot(rootPath: rootPath, reference: name, isRemote: false)
}

func smartCheckoutBranch(
    repo: Repository,
    name: String,
    onSuccess: @escaping () -> Void = {}
) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Smart Checkout", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.smartSwitchBranchWithPolicyAndCancel(
                name: name,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.loadError = nil
                self.feedbackCenter.success("Smart Checkout completed", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Smart Checkout cancelled",
                        detail: name,
                        nextStep: "The preservation Shelf was kept when restore had started; retry after reviewing the root."
                    )
                }
            } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                await MainActor.run {
                    let viewAction = stashID.flatMap {
                        self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: $0,
                            rootPath: repo.workdir()
                        )
                    }
                    self.showStashRestoreConflict(
                        paths,
                        additionalActions: viewAction.map { [$0] } ?? [],
                        stashID: stashID
                    )
                }
            } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                await MainActor.run {
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: .shelf,
                        identifier: name,
                        rootPath: repo.workdir()
                    )
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                }
            } else {
                await MainActor.run {
                    self.loadError = errorMessage(error)
                    self.feedbackCenter.error(
                        "Smart Checkout failed",
                        detail: errorMessage(error),
                        nextStep: "The original local changes were restored when possible."
                    )
                }
            }
        }
    }
}

func forceCheckoutBranch(
    repo: Repository,
    name: String,
    onSuccess: @escaping () -> Void = {}
) {
    beginFeedbackOperation("Force Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.forceSwitchBranch(name: name)
            await MainActor.run {
                self.loadError = nil
                self.feedbackCenter.success("Force Checkout completed", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            await MainActor.run {
                self.loadError = errorMessage(error)
                self.feedbackCenter.error("Force Checkout failed", detail: errorMessage(error))
            }
        }
    }
}

func updateSelectedBranch(_ name: String) {
    guard let repo, let rootPath = repo.workdir() else { return }
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let rebase = GitUpdateMethodSettings.method(for: projectPath) == .rebase
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Update branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let result = try executeBranchUpdateInRoot(
                repo: repo,
                rootPath: rootPath,
                branch: name,
                displayName: name,
                rebase: rebase,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: savePolicy
            )
            await MainActor.run {
                self.loadError = nil
                if result.success && !result.skipped {
                    self.feedbackCenter.success("Branch updated", detail: name)
                    self.refreshAll(showFeedback: false)
                    self.loadRepoData()
                } else if result.skipped {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: result.message,
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Branch update paused",
                        detail: result.message,
                        nextStep: "Resolve the update state, then retry the branch."
                    )
                }
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.loadError = detail
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: detail,
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Update branch failed",
                        detail: detail,
                        nextStep: "Check the upstream, credentials, and Git operation state, then retry."
                    )
                }
            }
        }
    }
}

/// 多 root Branches Popup 的 Update：操作必须固定到行所属的 root。
func updateBranchInRoot(rootPath: String, branch: String) {
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let rebase = GitUpdateMethodSettings.method(for: projectPath) == .rebase
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Update branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let result = try executeBranchUpdateInRoot(
                repo: rootRepo,
                rootPath: rootPath,
                branch: branch,
                displayName: rootPath,
                rebase: rebase,
                tagMode: tagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: savePolicy
            )
            await MainActor.run {
                if result.success && !result.skipped {
                    self.feedbackCenter.success("Branch updated", detail: "\(branch) · \(rootPath)")
                } else if result.skipped {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: "\(branch) · \(rootPath): \(result.message)",
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Branch update paused",
                        detail: "\(branch) · \(rootPath): \(result.message)",
                        nextStep: "Resolve the update state, then retry the branch."
                    )
                }
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Branch update cancelled",
                        detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Retry the branch update when the worktree is ready."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Update branch failed",
                        detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Check the upstream, credentials, and Git operation state, then retry."
                    )
                }
            }
        }
    }
}

/// IntelliJ's MultipleLocalBranchActions.UpdateSelectedBranchAction for the
/// Log dashboard. Each selected reference keeps its root and branch name; a
/// failure in one target does not silently skip the remaining independent
/// targets, and the aggregated result is exposed in the Operations workbench.
func updateSelectedBranchesInRoots(_ targets: [BranchDashboardReference]) {
    let selected = targets
        .filter { $0.kind == .local && $0.hasTracking }
        .sorted {
            if $0.rootPath == $1.rootPath {
                if $0.isCurrent != $1.isCurrent { return !$0.isCurrent }
                return $0.name < $1.name
            }
            return $0.rootPath < $1.rootPath
        }
    guard !selected.isEmpty, !multiRootRunning else { return }

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    multiRootRunning = true
    let cancel = GitCancelHandle()
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let rebase = GitUpdateMethodSettings.method(for: projectPath) == .rebase
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Update selected branches", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        for target in selected {
            if cancel.isCancelled() {
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: false,
                        skipped: true,
                        message: "Cancelled before updating \(target.name)"
                    )
                )
                continue
            }
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                results.append(
                    try executeBranchUpdateInRoot(
                        repo: rootRepo,
                        rootPath: target.rootPath,
                        branch: target.name,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        rebase: rebase,
                        tagMode: tagMode,
                        broker: broker,
                        cancel: cancel,
                        savePolicy: savePolicy
                    )
                )
            } catch {
                let wasCancelled: Bool
                if case .Cancelled = error as? EngineError {
                    wasCancelled = true
                } else {
                    wasCancelled = false
                }
                results.append(
                    RootOperationResult(
                        rootPath: target.rootPath,
                        displayName: displayNames[target.rootPath] ?? target.rootPath,
                        success: false,
                        skipped: wasCancelled,
                        message: wasCancelled
                            ? "Cancelled while updating \(target.name)"
                            : "\(target.name): \(errorMessage(error))"
                    )
                )
            }
        }
        let completedResults = results
        let completedFailures = completedResults.filter { !$0.success && !$0.skipped }
        let completedSkipped = completedResults.filter(\.skipped)
        await MainActor.run {
            self.multiRootRunning = false
            self.multiRootResults = completedResults
            self.loadMultiRoots()
            if completedFailures.isEmpty && completedSkipped.isEmpty {
                self.feedbackCenter.success(
                    "Selected branches updated",
                    detail: "\(selected.count) branches"
                )
            } else {
                let failureDetail = completedFailures.map {
                    "\($0.displayName): \($0.message)"
                }
                let skippedDetail = completedSkipped.map {
                    "\($0.displayName): \($0.message)"
                }
                self.feedbackCenter.warning(
                    "Selected branch update partially completed",
                    detail: (failureDetail + skippedDetail).joined(separator: "\n"),
                    nextStep: completedFailures.isEmpty
                        ? "Retry the skipped branch updates when ready."
                        : "Resolve the failed branch upstreams, then retry those branches."
                )
            }
        }
    }
}

func multiRootCommonTrackingBranches(
    remoteBranch: String,
    snapshots: [GitRootBranchSnapshot],
    selectedRootPaths: Set<String>
) -> [String] {
    let selected = snapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.remoteBranches.contains { $0.name == remoteBranch }
    }
    guard let first = selected.first else { return [] }
    let initial = Set(
        first.syncStatuses
            .filter { $0.upstream == remoteBranch && $0.trackingExists }
            .map(\.branch)
    )
    let common = selected.dropFirst().reduce(initial) { current, snapshot in
        current.intersection(
            snapshot.syncStatuses
                .filter { $0.upstream == remoteBranch && $0.trackingExists }
                .map(\.branch)
        )
    }
    let currentBranches = Set(selected.compactMap(\.headBranch))
    return common.subtracting(currentBranches).sorted()
}

func presentSingleRootRenameBranchDialog(rootPath: String, oldName: String) {
    guard let rootRepo = try? openRepository(path: rootPath),
          (try? rootRepo.branchList().contains(where: { $0.name == oldName })) == true else {
        feedbackCenter.warning(
            "Rename branch unavailable",
            detail: "The selected branch no longer exists in this Git root.",
            nextStep: "Refresh Git Roots and try again."
        )
        return
    }
    branchWorkspace.renameRootPath = rootPath
    branchWorkspace.renameOldName = oldName
    branchWorkspace.renameNewName = oldName
    branchWorkspace.renameUnsetUpstream = false
    branchWorkspace.renameHasUpstream = ((try? rootRepo.syncStatus()) ?? []).contains {
        $0.branch == oldName && $0.trackingExists
    }
    branchWorkspace.showRenameDialog = true
}

func dismissSingleRootRenameBranchDialog() {
    branchWorkspace.showRenameDialog = false
    branchWorkspace.renameRootPath = ""
    branchWorkspace.renameOldName = ""
    branchWorkspace.renameNewName = ""
    branchWorkspace.renameUnsetUpstream = false
    branchWorkspace.renameHasUpstream = false
}

func renameBranchInRoot(rootPath: String, oldName: String) {
    presentSingleRootRenameBranchDialog(rootPath: rootPath, oldName: oldName)
}

func renameBranchInRoot(
    rootPath: String,
    oldName: String,
    newName: String,
    unsetUpstream: Bool
) {
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return }
    dismissSingleRootRenameBranchDialog()
    beginFeedbackOperation("Rename branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let localBranchNames = try rootRepo.branchList().map(\.name)
            let remoteBranchNames = try rootRepo.remoteBranchList().map(\.name)
            if let conflict = branchRenameConflictMessage(
                oldName: oldName,
                newName: newName,
                localBranchNames: localBranchNames,
                remoteBranchNames: remoteBranchNames
            ) {
                throw NSError(
                    domain: "Arbor.BranchRename",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: conflict]
                )
            }
            try rootRepo.validateBranchName(name: newName)
            try rootRepo.branchRename(old: oldName, new: newName)
            if unsetUpstream {
                do {
                    try rootRepo.branchUnsetUpstream(branch: newName)
                } catch {
                    do {
                        try rootRepo.branchRename(old: newName, new: oldName)
                    } catch let rollbackError {
                        throw NSError(
                            domain: "Arbor.BranchRename",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Upstream removal failed: \(errorMessage(error)); automatic rename rollback failed: \(errorMessage(rollbackError))"
                            ]
                        )
                    }
                    throw NSError(
                        domain: "Arbor.BranchRename",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Upstream removal failed; the branch rename was rolled back: \(errorMessage(error))"
                        ]
                    )
                }
            }
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Branch renamed", detail: "\(oldName) → \(newName) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Rename branch failed", detail: "\(oldName) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

func deleteBranchInRoot(rootPath: String, name: String, confirm: Bool = true) {
    if confirm {
        let alert = NSAlert()
        alert.messageText = "Delete branch \(name)?"
        alert.informativeText = "This removes the local branch reference in the selected root."
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
    guard !selected.isEmpty, !multiRootRunning else { return }

    let alert = NSAlert()
    alert.messageText = "Delete selected branches?"
    alert.informativeText = selected
        .map { "\($0.name) · \($0.rootPath)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootBranchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootRunning = true
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
            self.multiRootRunning = false
            self.multiRootResults = completedResults
            self.loadMultiRoots()
            guard !completedRecoveryContexts.isEmpty else {
                if completedFailures.isEmpty {
                    self.feedbackCenter.success(
                        "Selected branch deletion completed",
                        detail: "\(completedResults.filter(\.success).count) branches"
                    )
                } else {
                    self.toolWindowMode = .operations
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
                self.toolWindowMode = .operations
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
