import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Apply a whole Shelf or selected Shelf members directly into a local
/// Changelist. This is the Changes Browser target-list drop path; unlike a
/// generic group drop it keeps the Shelf apply and Changelist assignment as
/// one user-visible operation.
func doShelveUnshelveIntoChangeList(
    _ name: String,
    paths: [String]?,
    selections: [ShelvePatchSelection]? = nil,
    targetName: String,
    removeApplied: Bool? = nil,
    basePath: String? = nil,
    pathStrip: UInt32 = 1,
    rootPath: String? = nil
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfWorkspace.rootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let targetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetName.isEmpty else { return }
    let selectedPaths = paths?.filter { !$0.isEmpty }
    let selectedSelections = selections?.filter { !$0.path.isEmpty }
    let shouldRemoveApplied = removeApplied
        ?? ShelfViewSettings.removeAppliedFilesFromShelf(for: projectWorkspace.path)
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map { $0.name })
    beginFeedbackOperation("Unshelve changes")
    Task.detached(priority: .userInitiated) {
        do {
            let lists = try shelfRepository.changelistList()
            guard lists.contains(where: { $0.name == targetName }) else {
                await MainActor.run {
                    self.feedbackCenter.error("Move changes failed", detail: targetName)
                }
                return
            }

            guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                await MainActor.run {
                    self.feedbackCenter.error("Unshelve failed", detail: name)
                }
                return
            }
            let requestedPaths = selectedSelections?.map(\.path) ?? selectedPaths ?? shelf.paths
            guard !requestedPaths.isEmpty else {
                await MainActor.run {
                    self.feedbackCenter.error("Unshelve failed", detail: name)
                }
                return
            }

            let appliedPaths: [String]
            var engineFailedPaths = Set<String>()
            var applyResult: PatchApplyResult?
            do {
                let mappedBasePath = basePath?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasPathMapping = (mappedBasePath?.isEmpty == false) || pathStrip != 1
                if hasPathMapping {
                    if let selectedSelections, !selectedSelections.isEmpty {
                        appliedPaths = try shelfRepository.shelveUnshelveSelectionsWithOptionsAndBase(
                            name: name,
                            selections: selectedSelections,
                            removeApplied: shouldRemoveApplied,
                            basePath: mappedBasePath ?? "",
                            pathStrip: pathStrip
                        )
                    } else {
                        appliedPaths = try shelfRepository.shelveUnshelvePathsWithOptionsAndBase(
                            name: name,
                            paths: selectedPaths ?? shelf.paths,
                            removeApplied: shouldRemoveApplied,
                            basePath: mappedBasePath ?? "",
                            pathStrip: pathStrip
                        )
                    }
                } else if let selectedSelections, !selectedSelections.isEmpty {
                    let result = try shelfRepository.shelveUnshelveSelectionsWithOptionsDifferentiated(
                        name: name,
                        selections: selectedSelections,
                        removeApplied: shouldRemoveApplied
                    )
                    applyResult = result
                    appliedPaths = result.appliedPaths
                    engineFailedPaths = Set(result.failedPaths)
                } else if let selectedPaths {
                    let result = try shelfRepository.shelveUnshelvePathsWithOptionsDifferentiated(
                        name: name,
                        paths: selectedPaths,
                        removeApplied: shouldRemoveApplied
                    )
                    applyResult = result
                    appliedPaths = result.appliedPaths
                    engineFailedPaths = Set(result.failedPaths)
                } else {
                    let result = try shelfRepository.shelveUnshelveWithOptionsDifferentiated(
                        name: name,
                        removeApplied: shouldRemoveApplied
                    )
                    applyResult = result
                    appliedPaths = result.appliedPaths
                    engineFailedPaths = Set(result.failedPaths)
                }
            } catch {
                if case let .ShelveApplyConflict(conflictName, conflictPaths) = error as? EngineError {
                    // The target is also persisted in the Rust snapshot so a
                    // resolver restored after relaunch can finish the same
                    // drag operation.
                    _ = try? shelfRepository.shelveSetRestoreTarget(
                        name: conflictName,
                        targetChangeList: targetName
                    )
                    await MainActor.run {
                        self.presentShelveConflict(
                            name: conflictName,
                            paths: conflictPaths,
                            isPop: false,
                            changeListName: targetName,
                            repository: shelfRepository
                        )
                    }
                } else {
                    await MainActor.run {
                        self.feedbackCenter.error(
                            "Unshelve failed",
                            detail: errorMessage(error),
                            nextStep: "The shelf was kept. Resolve the local conflict, then retry."
                        )
                    }
                }
                return
            }

            let status = try shelfRepository.status()
            let currentPaths = Set(status.map(\.path))
            let assignablePaths = appliedPaths.filter(currentPaths.contains)
            do {
                if !assignablePaths.isEmpty {
                    try shelfRepository.changelistMovePaths(paths: assignablePaths, targetName: targetName)
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error("Move changes failed", detail: targetName)
                }
                return
            }

            let nextChangeLists = try shelfRepository.changelistList()
            let nextShelves = try shelfRepository.shelveList()
            let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
            let failedPaths = Set(requestedPaths)
                .subtracting(Set(appliedPaths))
                .union(engineFailedPaths)
            let feedbackApplyResult = applyResult
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                let isPrimaryRoot = shelfRootSelectionIsPrimary(
                    selectedRootPath: resolvedRootPath,
                    primaryRootPath: self.primaryShelfRootPath
                )
                if isPrimaryRoot {
                    self.repositoryStatus.entries = status
                    self.repositoryStatus.changeLists = nextChangeLists
                }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: nextShelves,
                    deletedShelves: nextDeletedShelves,
                    changeLists: nextChangeLists
                )
                self.refreshAfterShelfMutation(
                    repo: shelfRepository,
                    paths: appliedPaths,
                    metadataChanged: shouldRemoveApplied
                )
                if !isPrimaryRoot {
                    self.refreshAll(showFeedback: false)
                }
                let restoredName = shouldRemoveApplied
                    ? nextDeletedShelves.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                    : nil
                let detail = "\(name) → \(targetName)"
                let operationItem: FeedbackOperationItem
                if let applyResult = feedbackApplyResult {
                    operationItem = FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: patchApplyFeedbackState(applyResult),
                        detail: patchApplySummary(
                            applyResult,
                            successDetail: "Applied → \(targetName)",
                            failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                        ),
                        children: shelfOperationSubitems(
                            scope: resolvedRootPath + "\u{1f}" + name,
                            paths: requestedPaths,
                            result: applyResult,
                            successDetail: "Applied",
                            failureDetail: "Not applied"
                        )
                    )
                } else {
                    operationItem = FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: failedPaths.isEmpty ? .success : .failed,
                        detail: failedPaths.isEmpty
                            ? "Applied → \(targetName)"
                            : "\(appliedPaths.count) applied, \(failedPaths.count) not applied",
                        children: shelfOperationSubitems(
                            scope: resolvedRootPath + "\u{1f}" + name,
                            paths: requestedPaths,
                            appliedPaths: Set(appliedPaths),
                            failedPaths: failedPaths,
                            successDetail: "Applied",
                            failureDetail: "Not applied"
                        )
                    )
                }
                let needsAttention = feedbackApplyResult.map(patchApplyNeedsAttention) ?? !failedPaths.isEmpty
                if let restoredName {
                    let actions = [self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )]
                    if !needsAttention {
                        self.feedbackCenter.success(
                            "Unshelve completed",
                            detail: detail,
                            additionalActions: actions,
                            notificationID: self.shelfBatchNotificationID(
                                operation: .apply,
                                rootPath: resolvedRootPath
                            )
                        )
                    } else {
                        self.feedbackCenter.warning(
                            "Unshelve partially completed",
                            detail: "\(detail): \(appliedPaths.count) applied, \(failedPaths.count) not applied",
                            nextStep: "Review the failed Shelf members and retry them separately.",
                            additionalActions: actions,
                            notificationID: self.shelfBatchNotificationID(
                                operation: .apply,
                                rootPath: resolvedRootPath
                            )
                        )
                    }
                } else if !needsAttention {
                    self.feedbackCenter.success(
                        "Unshelve completed",
                        detail: detail,
                        notificationID: self.shelfBatchNotificationID(
                            operation: .apply,
                            rootPath: resolvedRootPath
                        )
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Unshelve partially completed",
                        detail: "\(detail): \(appliedPaths.count) applied, \(failedPaths.count) not applied",
                        nextStep: "Review the failed Shelf members and retry them separately.",
                        notificationID: self.shelfBatchNotificationID(
                            operation: .apply,
                            rootPath: resolvedRootPath
                        )
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    [operationItem],
                    notificationID: self.shelfBatchNotificationID(
                        operation: .apply,
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unshelve failed",
                    detail: errorMessage(error),
                    nextStep: "The shelf was kept. Resolve the local conflict, then retry.",
                    notificationID: self.shelfBatchNotificationID(
                        operation: .apply,
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

}
