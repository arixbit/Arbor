import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

func presentMultiRootRenameBranchDialog(name: String) {
    let eligible = multiRootWorkspace.branchSnapshots.filter { snapshot in
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
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return }
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains(where: { $0.name == oldName })
    }
    guard !roots.isEmpty else { return }
    multiRootWorkspace.running = true
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
            self.multiRootWorkspace.running = false
            self.branchWorkspace.showMultiRootRenameDialog = false
            self.multiRootWorkspace.results = resultsToApply
            self.loadMultiRoots()
            if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root branch rename completed",
                    detail: "\(successfulTargetsToOffer.count) repositories · \(oldName) → \(newName)"
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
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
        projectPath: projectWorkspace.path,
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
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootBranchRenameOldName: oldName,
        multiRootBranchRenameNewName: newName,
        multiRootBranchRenameRollbackTargets: targets
    )
}

func multiRootBranchRenameRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
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
                if self.projectWorkspace.toolWindowMode == .log { self.loadLog() }
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
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
}
