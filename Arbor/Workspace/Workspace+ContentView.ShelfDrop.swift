import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Drop multiple active Shelves as one serial operation. IntelliJ treats a
/// multi-selection delete as one notification with per-list recovery actions;
/// serial execution keeps the repository lock and Recently Deleted ordering
/// deterministic while still allowing the remaining lists to be retried.
func doShelveDropShelves(
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
    var seenNames = Set<String>()
    let uniqueNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seenNames.insert($0).inserted }
    guard !uniqueNames.isEmpty else { return }
    if uniqueNames.count == 1, let name = uniqueNames.first {
        doShelveDrop(
            name,
            rootPath: resolvedRootPath,
            preservePreviousItems: preservePreviousItems
        )
        return
    }

    let notificationID = shelfBatchNotificationID(
        operation: .drop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Drop shelves",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Drop Shelf"
    )
    Task.detached(priority: .userInitiated) {
        var droppedNames: [String] = []
        var originalTimestamps: [String: Int64] = [:]
        var failures: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]

        for (index, name) in uniqueNames.enumerated() {
            do {
                guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                    throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
                }
                originalTimestamps[name] = shelf.timestamp
                try shelfRepository.shelveDrop(name: name)
                droppedNames.append(name)
                itemStates[name] = .success
                itemDetails[name] = "Moved to Recently Deleted"
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelf.paths,
                    state: .success,
                    detail: "Moved to Recently Deleted"
                )
            } catch {
                itemStates[name] = .failed
                itemDetails[name] = errorMessage(error)
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: (try? shelfRepository.shelveList().first(where: { $0.name == name })?.paths) ?? [],
                    state: .failed,
                    detail: errorMessage(error)
                )
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Drop Shelf",
                    detail: name
                )
            }
        }

        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let droppedNamesSnapshot = droppedNames
        let originalTimestampsSnapshot = originalTimestamps
        let failuresSnapshot = failures
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
               droppedNamesSnapshot.contains(previewName) {
                self.shelfWorkspace.previewName = nil
                self.shelfWorkspace.previewText = nil
                self.shelfWorkspace.showPreview = false
            }

            let batchUndoAction = self.shelfUndoDeletionsFeedbackAction(
                names: droppedNamesSnapshot,
                originalTimestamps: originalTimestampsSnapshot,
                rootPath: resolvedRootPath
            )
            let retryNames = uniqueNames.filter { !droppedNamesSnapshot.contains($0) }
            let retryAction = self.shelfBatchRetryFeedbackAction(
                names: retryNames,
                operation: .drop,
                targetName: nil,
                removeApplied: false,
                rootPath: resolvedRootPath
            )
            let additionalActions = (batchUndoAction.map { [$0] } ?? []) + (retryAction.map { [$0] } ?? [])
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: uniqueNames,
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            let droppedDetail = droppedNamesSnapshot.isEmpty
                ? "0/\(uniqueNames.count)"
                : "\(droppedNamesSnapshot.count)/\(uniqueNames.count): "
                    + droppedNamesSnapshot.joined(separator: ", ")

            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelves dropped",
                    detail: droppedDetail,
                    additionalActions: batchUndoAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            } else if droppedNamesSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Shelf drop failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The selected Shelves were kept. Resolve the reported issue and retry.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some Shelves dropped",
                    detail: [droppedDetail, failuresSnapshot.joined(separator: "\n")]
                        .joined(separator: "\n"),
                    nextStep: "The failed Shelves were kept. Retry them after resolving the reported issue.",
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

/// Drop selected members from several active Shelves as one serialized
/// lifecycle operation. Every successful group remains undoable through one
/// timestamp-preserving batch action.
func doShelveDropPathGroups(
    _ groups: [ShelfPathDeleteGroup],
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
    let groups = normalizedShelfPathGroups(groups)
    guard !groups.isEmpty else { return }
    let notificationID = shelfMemberBatchNotificationID(
        operation: .drop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Drop Shelf changes",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: groups.count,
        phase: "Drop Shelf Changes"
    )
    Task.detached(priority: .userInitiated) {
        var completedKeys = Set<String>()
        var droppedNames: [String] = []
        var failures: [String] = []
        var restoreNames: [String] = []
        var restoreTimestamps: [String: Int64] = [:]
        var knownDeletedNames = Set((try? shelfRepository.shelveDeletedList().map(\.name)) ?? [])
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]

        for (index, group) in groups.enumerated() {
            do {
                guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == group.shelfName }) else {
                    throw EngineError.GitOperation(message: "shelve: shelf not found '\(group.shelfName)'")
                }
                try shelfRepository.shelveDropPaths(name: group.shelfName, paths: group.paths)
                completedKeys.insert(shelfPathGroupKey(group))
                droppedNames.append(group.shelfName)
                itemStates[group.shelfName] = .success
                itemDetails[group.shelfName] = "Moved to Recently Deleted"
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .success,
                    detail: "Moved to Recently Deleted"
                )
                let currentDeleted = try shelfRepository.shelveDeletedList()
                for deleted in currentDeleted where !knownDeletedNames.contains(deleted.name) {
                    knownDeletedNames.insert(deleted.name)
                    restoreNames.append(deleted.name)
                    restoreTimestamps[deleted.name] = shelf.timestamp
                }
            } catch {
                failures.append("\(group.shelfName): \(errorMessage(error))")
                itemStates[group.shelfName] = .failed
                itemDetails[group.shelfName] = errorMessage(error)
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .failed,
                    detail: errorMessage(error)
                )
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: groups.count,
                    phase: "Drop Shelf Changes",
                    detail: group.shelfName
                )
            }
        }

        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let completedKeysSnapshot = completedKeys
        let droppedNamesSnapshot = droppedNames
        let failuresSnapshot = failures
        let restoreNamesSnapshot = restoreNames
        let restoreTimestampsSnapshot = restoreTimestamps
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        let retryGroups = groups.filter { !completedKeysSnapshot.contains(shelfPathGroupKey($0)) }
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
               droppedNamesSnapshot.contains(previewName) {
                self.shelfWorkspace.previewName = nil
                self.shelfWorkspace.previewText = nil
                self.shelfWorkspace.showPreview = false
            }
            let retryAction = self.shelfMemberBatchRetryFeedbackAction(
                groups: retryGroups,
                operation: .drop,
                rootPath: resolvedRootPath
            )
            let undoAction = self.shelfUndoDeletionsFeedbackAction(
                names: restoreNamesSnapshot,
                originalTimestamps: restoreTimestampsSnapshot,
                rootPath: resolvedRootPath
            )
            let additionalActions = [undoAction, retryAction].compactMap { $0 }
            let detail = droppedNamesSnapshot.isEmpty
                ? "0/\(groups.count)"
                : "\(droppedNamesSnapshot.count)/\(groups.count): \(droppedNamesSnapshot.joined(separator: ", "))"
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: groups.map(\.shelfName),
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelf changes dropped",
                    detail: detail,
                    additionalActions: [undoAction].compactMap { $0 },
                    notificationID: notificationID
                )
            } else if droppedNamesSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Shelf changes drop failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The selected Shelf changes were kept. Resolve the reported issue and retry.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some Shelf changes were dropped",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")].joined(separator: "\n"),
                    nextStep: "Retry the remaining Shelf changes or use Undo to restore the dropped groups.",
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

/// 仅删除 Shelf 中选中的成员；未选中的成员仍留在原 Shelf 中。
func doShelveDropPaths(
    _ name: String,
    _ paths: [String],
    rootPath: String? = nil
) {
    guard !paths.isEmpty,
          let context = shelfMutationContext(
              rootPath: rootPath,
              activeRootPath: activeShelfRootPath,
              primaryRootPath: primaryShelfRootPath,
              primaryRepository: repo,
              secondaryRepository: shelfWorkspace.rootRepository
          ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let scopedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.shelves : activeShelfList
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map { $0.name })
    let originalShelfTimestamp = scopedShelves.first(where: { $0.name == name })?.timestamp
    beginFeedbackOperation("Drop shelve changes")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveDropPaths(name: name, paths: paths)
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
                if self.shelfWorkspace.previewName == name,
                   shelfActionRootMatchesCurrentRoot(
                       requestedRootPath: resolvedRootPath,
                       currentRootPath: self.shelfWorkspace.previewRootPath ?? self.primaryShelfRootPath
                   ) {
                    self.shelfWorkspace.previewText = nil
                    self.shelfWorkspace.showPreview = false
                }
                let restoredName = dsh.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                if let restoredName {
                    let restoreAction = originalShelfTimestamp.map {
                        self.shelfUndoDeletedMembersFeedbackAction(
                            name: restoredName,
                            paths: paths,
                            originalTimestamp: $0,
                            rootPath: resolvedRootPath
                        )
                    } ?? self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        detail: paths.joined(separator: ", "),
                        additionalActions: [restoreAction],
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                } else {
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        detail: paths.joined(separator: ", "),
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Shelve drop failed",
                    detail: errorMessage(error),
                    nextStep: "The shelf was kept. Select a valid member and try again.",
                    notificationID: self.shelfBatchNotificationID(
                        operation: .drop,
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

func doShelveDrop(
    _ name: String,
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
    let scopedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.shelves : activeShelfList
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map(\.name))
    let originalShelfTimestamp = scopedShelves.first(where: { $0.name == name })?.timestamp
    let originalShelfPaths = scopedShelves.first(where: { $0.name == name })?.paths ?? []
    let notificationID = shelfBatchNotificationID(
        operation: .drop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        shelfFeedbackTitle(.drop),
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveDrop(name: name)
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
                if self.shelfWorkspace.previewName == name,
                   shelfActionRootMatchesCurrentRoot(
                       requestedRootPath: resolvedRootPath,
                       currentRootPath: self.shelfWorkspace.previewRootPath ?? self.primaryShelfRootPath
                   ) {
                    self.shelfWorkspace.previewName = nil
                    self.shelfWorkspace.previewText = nil
                    self.shelfWorkspace.showPreview = false
                }
                let restoredName = dsh.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                if let restoredName {
                    let restoreAction = originalShelfTimestamp.map {
                        self.shelfUndoDeletionFeedbackAction(
                            name: restoredName,
                            originalTimestamp: $0,
                            rootPath: resolvedRootPath
                        )
                    } ?? self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        additionalActions: [restoreAction],
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                } else {
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    [FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: .success,
                        detail: "Moved to Recently Deleted",
                        children: originalShelfPaths.map {
                            FeedbackOperationSubitem(
                                scope: resolvedRootPath + "\u{1f}" + name,
                                path: $0,
                                state: .success,
                                detail: "Moved to Recently Deleted"
                            )
                        }
                    )],
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Shelve drop failed",
                    detail: errorMessage(error),
                    nextStep: "The shelf was kept. Retry the deletion when the repository is ready.",
                    notificationID: self.shelfBatchNotificationID(
                        operation: .drop,
                        rootPath: resolvedRootPath
                    )
                )
                self.feedbackCenter.attachOperationItems(
                    [FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: .failed,
                        detail: errorMessage(error),
                        children: originalShelfPaths.map {
                            FeedbackOperationSubitem(
                                scope: resolvedRootPath + "\u{1f}" + name,
                                path: $0,
                                state: .failed,
                                detail: errorMessage(error)
                            )
                        }
                    )],
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        }
    }
}

}
