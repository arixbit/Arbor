import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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
        secondaryRepository: shelfWorkspace.rootRepository
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
        secondaryRepository: shelfWorkspace.rootRepository
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
        secondaryRepository: shelfWorkspace.rootRepository
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

}
