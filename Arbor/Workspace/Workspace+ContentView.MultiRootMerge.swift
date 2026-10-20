import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func presentMultiRootMergeDialog(name: String) {
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let eligible = multiRootWorkspace.branchSnapshots.filter { snapshot in
        snapshot.branches.contains { $0.name == branchName }
    }
    guard !branchName.isEmpty, !eligible.isEmpty else {
        feedbackCenter.warning(
            "Merge branch unavailable",
            detail: "No Git root contains " + branchName + "."
        )
        return
    }
    mergeWorkspace.multiRootBranchName = branchName
    mergeWorkspace.multiRootSelectedRootPaths = Set(eligible.map(\.rootPath))
    mergeWorkspace.multiRootMergedBranchesByRoot = [:]
    mergeWorkspace.multiRootDialogGeneration &+= 1
    let generation = mergeWorkspace.multiRootDialogGeneration
    mergeWorkspace.showMultiRootDialog = true
    let rootPaths = eligible.map(\.rootPath)
    Task.detached(priority: .userInitiated) {
        var mergedBranchesByRoot: [String: Set<String>] = [:]
        for rootPath in rootPaths {
            guard let rootRepo = try? openRepository(path: rootPath),
                  let mergedBranches = try? rootRepo.branchListMergedAll() else {
                continue
            }
            mergedBranchesByRoot[rootPath] = Set(mergedBranches.map(\.name))
        }
        let loadedMergedBranchesByRoot = mergedBranchesByRoot
        await MainActor.run {
            guard generation == self.mergeWorkspace.multiRootDialogGeneration else { return }
            let alreadyMergedRootPaths = Set(
                loadedMergedBranchesByRoot.compactMap { rootPath, mergedBranches in
                    mergeBranchIsAlreadyMerged(branchName, mergedBranches: mergedBranches)
                        ? rootPath
                        : nil
                }
            )
            self.mergeWorkspace.multiRootMergedBranchesByRoot = loadedMergedBranchesByRoot
            self.mergeWorkspace.multiRootSelectedRootPaths.subtract(alreadyMergedRootPaths)
        }
    }
}

func presentMultiRootMergeFromPopup(name: String) {
    presentMultiRootMergeDialog(name: name)
    branchWorkspace.showPopover = false
}

func dismissMultiRootMergeDialog() {
    mergeWorkspace.multiRootDialogGeneration &+= 1
    mergeWorkspace.showMultiRootDialog = false
    mergeWorkspace.multiRootBranchName = ""
    mergeWorkspace.multiRootSelectedRootPaths = []
    mergeWorkspace.multiRootMergedBranchesByRoot = [:]
}

func startMultiRootMergeFromDialog() {
    let actionableRootPaths = mergeWorkspace.multiRootSelectedRootPaths.filter { rootPath in
        guard let mergedBranches = mergeWorkspace.multiRootMergedBranchesByRoot[rootPath] else {
            return true
        }
        return !mergeBranchIsAlreadyMerged(
            mergeWorkspace.multiRootBranchName,
            mergedBranches: mergedBranches
        )
    }
    mergeWorkspace.multiRootSelectedRootPaths = actionableRootPaths
    guard !actionableRootPaths.isEmpty else {
        feedbackCenter.warning(
            "Merge is not needed",
            detail: "The selected branch is already merged in every selected repository."
        )
        return
    }
    saveMergeDialogSettings()
    mergeMultiRootBranch(
        name: mergeWorkspace.multiRootBranchName,
        selectedRootPaths: actionableRootPaths,
        options: currentMergeEngineOptions()
    )
}

func dismissMultiRootMergeRollback() {
    mergeWorkspace.multiRootRollbackContext = nil
    if let notificationID = multiRootMergeRollbackNotificationID() {
        feedbackCenter.expire(notificationID: notificationID)
    }
}

func keepMultiRootMergePartial(_ context: MultiRootMergeRollbackContext) {
    mergeWorkspace.multiRootRollbackContext = nil
    let pendingRootPath = context.targets.first(where: { $0.operationPending })?.rootPath
        ?? context.pendingRootPath
    feedbackCenter.warning(
        "Partial merge kept",
        detail: context.branchName,
        nextStep: pendingRootPath == nil
            ? "Review the successful repositories in Git Roots."
            : "Resolve the pending merge in the affected Git root.",
        notificationID: multiRootMergeRollbackNotificationID(),
        notificationGroup: .standard
    )
    if let pendingRootPath {
        openMultiRootConflictResolver(preferredRootPath: pendingRootPath)
    }
}

/// Merge one local branch in the selected Git roots using IntelliJ's
/// repository-operation sequencing: conflicts are retained and the next root
/// is attempted, while a fatal failure marks all later roots as skipped.
func mergeMultiRootBranch(
    name: String,
    selectedRootPaths: Set<String>,
    options: MergeOptions? = nil
) {
    runMultiRootMergeOperation(
        name: name,
        selectedRootPaths: selectedRootPaths,
        options: options ?? currentMergeEngineOptions(),
        preserveLocalChanges: false
    )
}

func runMultiRootMergeOperation(
    name: String,
    selectedRootPaths: Set<String>,
    options: MergeOptions,
    preserveLocalChanges: Bool,
    rootOrder: [String]? = nil,
    preservedResults: [MultiRootMergeResult] = []
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains { $0.name == branchName }
    }
    guard !branchName.isEmpty, !roots.isEmpty, let projectPath = projectWorkspace.path else { return }

    let canDeleteMergedBranch = roots.allSatisfy { snapshot in
        !snapshot.branches.contains { $0.name == branchName && $0.isCurrent }
    } && !GitProtectedBranchRules.matches(
        branchName,
        patterns: effectiveProtectedBranchPatterns
    )
    let deleteOnMerge = GitDeleteOnMergeOption.effectiveOption(
        mergeDeleteOnMergeOption,
        canDeleteBranch: canDeleteMergedBranch
    )
    let mergeRootPaths = roots.map(\.rootPath)
    let resultRootOrder = rootOrder ?? (
        mergeRootPaths + preservedResults
            .map(\.rootPath)
            .filter { !mergeRootPaths.contains($0) }
    )
    let allMergeRootPaths = rootOrder ?? mergeRootPaths
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    multiRootWorkspace.running = true
    beginFeedbackOperation(
        "Multi-root merge",
        notificationID: multiRootMergeNotificationID()
    )
    Task.detached(priority: .userInitiated) {
        do {
            let results: [MultiRootMergeResult]
            if preserveLocalChanges {
                results = try runMultiRootMergeWithPolicy(
                    scanRoot: projectPath,
                    selectedRootPaths: roots.map(\.rootPath),
                    branch: branchName,
                    options: options,
                    savePolicy: projectSavePolicy
                )
            } else {
                results = try runMultiRootMerge(
                    scanRoot: projectPath,
                    selectedRootPaths: roots.map(\.rootPath),
                    branch: branchName,
                    options: options
                )
            }
            let combinedResults = mergeMultiRootMergeResults(
                preserved: preservedResults,
                retry: results,
                rootOrder: resultRootOrder
            )
            let operationResults = combinedResults.map { result in
                RootOperationResult(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    success: result.success,
                    skipped: result.skipped,
                    message: result.message
                )
            }
            let rollbackTargets = combinedResults.compactMap { result -> MultiRootMergeRollbackTarget? in
                guard result.success, !result.skipped,
                      let initialHead = result.initialHead,
                      let expectedHead = result.finalHead,
                      result.requiresFinish || !result.conflicts.isEmpty || initialHead != expectedHead else {
                    return nil
                }
                return MultiRootMergeRollbackTarget(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    initialHead: initialHead,
                    expectedHead: expectedHead,
                    operationPending: result.requiresFinish || !result.conflicts.isEmpty
                )
            }
            let conflicts = combinedResults.filter { $0.success && !$0.skipped && !$0.conflicts.isEmpty }
            let failures = combinedResults.filter { !$0.success || $0.skipped }
            let overwriteFailures = combinedResults.filter {
                !$0.success && !$0.skipped && !$0.localChangesOverwritePaths.isEmpty
            }
            let pendingOperations = combinedResults.contains {
                !$0.skipped && $0.requiresFinish
            }
            let pendingFailureRootPath = combinedResults.first {
                !$0.success && !$0.skipped && $0.requiresFinish
            }?.rootPath
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.mergeWorkspace.showMultiRootDialog = false
                self.mergeWorkspace.multiRootBranchName = ""
                self.mergeWorkspace.multiRootSelectedRootPaths = []
                self.multiRootWorkspace.results = operationResults
                self.loadMultiRoots()
                if preserveLocalChanges {
                    self.presentMultiRootMergeRestoreConflicts(combinedResults)
                }

                let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: Self.completedMergeRevisionRanges(combinedResults)
                )

                if !overwriteFailures.isEmpty && !pendingOperations && !preserveLocalChanges {
                    let details = overwriteFailures.map {
                        "\($0.displayName): \($0.localChangesOverwritePaths.joined(separator: ", "))"
                    }.joined(separator: "\n")
                    self.feedbackCenter.warning(
                        "Multi-root Merge needs a decision",
                        detail: details,
                        nextStep: "Choose Smart Merge to preserve local changes in each affected root, or cancel.",
                        additionalActions: viewCommitsAction.map { [$0] } ?? [],
                        notificationID: self.multiRootMergeNotificationID()
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Multi-root Merge",
                        paths: overwriteFailures.flatMap { result in
                            result.localChangesOverwritePaths.map { "\(result.displayName): \($0)" }
                        },
                        detail: details,
                        smartButtonTitle: "Smart Merge",
                        onSmart: {
                            self.runMultiRootMergeOperation(
                                name: branchName,
                                selectedRootPaths: Set(overwriteFailures.map(\.rootPath)),
                                options: options,
                                preserveLocalChanges: true,
                                rootOrder: resultRootOrder,
                                preservedResults: combinedResults.filter { result in
                                    !overwriteFailures.contains(where: { $0.rootPath == result.rootPath })
                                }
                            )
                        }
                    )
                } else if !failures.isEmpty {
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let failureDetails = failures.map {
                        "\($0.displayName): \($0.message.isEmpty ? ($0.skipped ? "skipped" : "failed") : $0.message)"
                    }
                    var additionalActions = self.multiRootMergeRollbackAction(
                        branchName: branchName,
                        targets: rollbackTargets
                    ).map { [$0] } ?? []
                    if let viewCommitsAction {
                        additionalActions.append(viewCommitsAction)
                    }
                    self.feedbackCenter.warning(
                        "Multi-root merge partially completed",
                        detail: failureDetails.joined(separator: "\n"),
                        nextStep: rollbackTargets.isEmpty
                            ? "Review the affected Git roots and resolve or abort any pending merge."
                            : "Choose whether to rollback successful roots or keep the partial state.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootMergeNotificationID(),
                        notificationGroup: rollbackTargets.isEmpty ? .toolWindow : .standard
                    )
                    if !rollbackTargets.isEmpty {
                        self.mergeWorkspace.multiRootRollbackContext = MultiRootMergeRollbackContext(
                            branchName: branchName,
                            targets: rollbackTargets,
                            failures: failureDetails,
                            pendingRootPath: pendingFailureRootPath
                        )
                    }
                    if rollbackTargets.isEmpty, let pendingFailureRootPath {
                        self.openMultiRootConflictResolver(preferredRootPath: pendingFailureRootPath)
                    }
                } else if !conflicts.isEmpty {
                    let conflict = conflicts.first
                    self.feedbackCenter.warning(
                        "Multi-root merge paused",
                        detail: conflicts.map {
                            "\($0.displayName): \($0.conflicts.count) conflict(s)"
                        }.joined(separator: "\n"),
                        nextStep: "Resolve conflicts in each affected root, then use Continue or Abort in Git Roots.",
                        additionalActions: viewCommitsAction.map { [$0] } ?? [],
                        notificationID: self.multiRootMergeNotificationID(),
                        notificationGroup: viewCommitsAction == nil ? .toolWindow : .standard
                    )
                    self.openMultiRootConflictResolver(
                        preferredRootPath: conflict?.rootPath,
                        preferredPath: conflict?.conflicts.first
                    )
                } else {
                    let mergeResultRows = feedbackResultRows(from: operationResults)
                    if deleteOnMerge == .delete {
                        self.feedbackCenter.success(
                            "Multi-root merge completed",
                            detail: "\(combinedResults.filter { $0.success && !$0.skipped }.count) repositories · \(branchName)",
                            additionalActions: viewCommitsAction.map { [$0] } ?? [],
                            notificationID: self.multiRootMergeNotificationID(),
                            notificationGroup: .standard
                        )
                        self.feedbackCenter.attachResultRows(
                            mergeResultRows,
                            notificationID: self.multiRootMergeNotificationID()
                        )
                        self.deleteMultiRootBranch(
                            name: branchName,
                            selectedRootPaths: Set(allMergeRootPaths),
                            allowForceDelete: false
                        )
                    } else if deleteOnMerge == .propose {
                        if let deleteAction = self.multiRootMergeDeleteAction(
                            branch: branchName,
                            rootPaths: allMergeRootPaths
                        ) {
                            self.feedbackCenter.success(
                                "Multi-root merge completed",
                                detail: "\(combinedResults.filter { $0.success && !$0.skipped }.count) repositories · \(branchName)",
                                additionalActions: [deleteAction] + (viewCommitsAction.map { [$0] } ?? []),
                                notificationID: self.multiRootMergeDeleteNotificationID(),
                                notificationGroup: .standard
                            )
                            self.feedbackCenter.attachResultRows(
                                mergeResultRows,
                                notificationID: self.multiRootMergeDeleteNotificationID()
                            )
                        }
                    } else {
                        self.feedbackCenter.success(
                            "Multi-root merge completed",
                            detail: "\(combinedResults.filter { $0.success && !$0.skipped }.count) repositories · \(branchName)",
                            additionalActions: viewCommitsAction.map { [$0] } ?? [],
                            notificationID: self.multiRootMergeNotificationID(),
                            notificationGroup: .standard
                        )
                        self.feedbackCenter.attachResultRows(
                            mergeResultRows,
                            notificationID: self.multiRootMergeNotificationID()
                        )
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    "Multi-root merge failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry the merge."
                )
            }
        }
    }
}

}
