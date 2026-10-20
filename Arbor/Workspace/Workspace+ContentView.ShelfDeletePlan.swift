import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

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
        secondaryRepository: shelfWorkspace.rootRepository
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
            if let previewName = self.shelfWorkspace.previewName,
               let previewOperation = operations.first(where: {
                   $0.shelfName == previewName
                       && (($0.kind == .deletedShelf || $0.kind == .deletedPaths)
                           == self.shelfWorkspace.previewIsDeleted)
                       && completedKeysSnapshot.contains($0.key)
               }) {
                _ = previewOperation
                self.shelfWorkspace.previewName = nil
                self.shelfWorkspace.previewText = nil
                self.shelfWorkspace.showPreview = false
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

}
