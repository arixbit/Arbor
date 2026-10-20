import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Permanently remove selected members from several Recently Deleted Shelves
/// as one serialized operation with one retryable notification.
func doShelveDeleteDeletedPathGroups(
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
        operation: .deleteDeleted,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Delete deleted Shelf changes permanently",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: groups.count,
        phase: "Delete Shelf Changes"
    )
    Task.detached(priority: .userInitiated) {
        var completedKeys = Set<String>()
        var deletedDetails: [String] = []
        var failures: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        for (index, group) in groups.enumerated() {
            do {
                try shelfRepository.shelveDeleteDeletedPaths(name: group.shelfName, paths: group.paths)
                completedKeys.insert(shelfPathGroupKey(group))
                deletedDetails.append("\(group.shelfName): \(group.paths.joined(separator: ", "))")
                itemStates[group.shelfName] = .success
                itemDetails[group.shelfName] = "Deleted permanently"
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .success,
                    detail: "Deleted permanently"
                )
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
                    phase: "Delete Shelf Changes",
                    detail: group.shelfName
                )
            }
        }
        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let completedKeysSnapshot = completedKeys
        let deletedDetailsSnapshot = deletedDetails
        let failuresSnapshot = failures
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
            let retryAction = self.shelfMemberBatchRetryFeedbackAction(
                groups: retryGroups,
                operation: .deleteDeleted,
                rootPath: resolvedRootPath
            )
            let additionalActions = [retryAction].compactMap { $0 }
            let detail = deletedDetailsSnapshot.isEmpty
                ? "0/\(groups.count)"
                : "\(completedKeysSnapshot.count)/\(groups.count): \(deletedDetailsSnapshot.joined(separator: "; "))"
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: groups.map(\.shelfName),
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Deleted Shelf changes deleted permanently",
                    detail: detail,
                    notificationID: notificationID
                )
            } else if completedKeysSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Deleted Shelf changes deletion failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The deleted Shelf changes were kept. Resolve the reported issue and retry.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some deleted Shelf changes were deleted",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")].joined(separator: "\n"),
                    nextStep: "Retry the remaining deleted Shelf changes.",
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

/// Permanently remove recycled Shelf lists through the explicit IntelliJ
/// "clean already unshelved" action. This does not touch active or Recently
/// Deleted shelves; the engine owns the lifecycle cutoff and ref cleanup.
func cleanRecycledShelves(rootPath: String? = nil) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfWorkspace.rootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let cutoff = Int64(Date().timeIntervalSince1970)
    let notificationID = shelfMetadataNotificationID(
        operation: "clean",
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Clear Already Unshelved",
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            let cleaned = try shelfRepository.shelveCleanRecycled(beforeTimestamp: cutoff)
            let nextShelves = try shelfRepository.shelveList()
            let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
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
                if cleaned.isEmpty {
                    self.feedbackCenter.warning(
                        "No already unshelved shelves to clear",
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.success(
                        "Already unshelved shelves cleared",
                        detail: cleaned.joined(separator: ", "),
                        notificationID: notificationID
                    )
                }
            }
        } catch {
            let nextShelves = (try? shelfRepository.shelveList()) ?? []
            let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
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
                self.feedbackCenter.error(
                    "Clear already unshelved shelves failed",
                    detail: errorMessage(error),
                    nextStep: "The remaining shelves were kept. Retry the cleanup when the repository is ready.",
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Permanently remove selected members from a Recently Deleted Shelf. The
/// remaining members stay recoverable; deleting the last member removes the
/// deleted Shelf itself.
func doShelveDeleteDeletedPaths(
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
    beginFeedbackOperation("Delete deleted Shelf members permanently")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveDeleteDeletedPaths(name: name, paths: paths)
            let ss = (try? shelfRepository.shelveList()) ?? []
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
                    paths.count == 1
                        ? "Deleted Shelf member deleted permanently"
                        : "Deleted Shelf members deleted permanently",
                    detail: "\(name): \(paths.joined(separator: ", "))",
                    notificationID: self.shelfDeletedMemberDeletionNotificationID(
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Delete deleted Shelf members failed",
                    detail: errorMessage(error),
                    nextStep: "The selected deleted Shelf members were kept. Retry the permanent deletion.",
                    additionalActions: [
                        self.shelfDeleteDeletedMembersFeedbackAction(
                            name: name,
                            paths: paths,
                            rootPath: resolvedRootPath
                        )
                    ],
                    notificationID: self.shelfDeletedMemberDeletionNotificationID(
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// Permanently delete a shelf from Recently Deleted after an explicit prompt.
func deleteDeletedShelve(_ name: String, rootPath: String? = nil) {
    deleteDeletedShelves([name], rootPath: rootPath)
}

/// Permanently delete one or more selected Recently Deleted shelves.
func deleteDeletedShelves(
    _ names: [String],
    confirm: Bool = true,
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
    if confirm {
        let alert = NSAlert()
        alert.messageText = uniqueNames.count == 1
            ? "Delete Shelf Permanently?"
            : "Delete Shelves Permanently?"
        alert.informativeText = uniqueNames.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    let notificationID = shelfLifecycleNotificationID(
        operation: .deleteDeleted,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        uniqueNames.count == 1 ? "Delete shelf permanently" : "Delete shelves permanently",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Delete Shelf"
    )
    Task.detached(priority: .userInitiated) { [uniqueNames] in
        let shelfPathsByName = Dictionary(
            uniqueKeysWithValues: ((try? shelfRepository.shelveDeletedList()) ?? []).map {
                ($0.name, $0.paths)
            }
        )
        var deleted: [String] = []
        var failures: [String] = []
        var failedNames: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        for (index, name) in uniqueNames.enumerated() {
            do {
                try shelfRepository.shelveDeleteDeleted(name: name)
                deleted.append(name)
                itemStates[name] = .success
                itemDetails[name] = "Deleted permanently"
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPathsByName[name] ?? [],
                    state: .success,
                    detail: "Deleted permanently"
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
                    phase: "Delete Shelf",
                    detail: name
                )
            }
        }
        let deletedNames = deleted
        let failureMessages = failures
        let failedNamesSnapshot = failedNames
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        do {
            let dsh = try shelfRepository.shelveDeletedList()
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                let currentShelves = shelfRootSelectionIsPrimary(
                    selectedRootPath: resolvedRootPath,
                    primaryRootPath: self.primaryShelfRootPath
                ) ? self.shelfWorkspace.shelves : self.activeShelfList
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: currentShelves,
                    deletedShelves: dsh
                )
                let retryAction = self.shelfLifecycleRetryFeedbackAction(
                    names: failedNamesSnapshot,
                    operation: .deleteDeleted,
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
                        deletedNames.count == 1 ? "Shelf deleted permanently" : "Shelves deleted permanently",
                        detail: deletedNames.joined(separator: ", "),
                        notificationID: notificationID
                    )
                } else if deletedNames.isEmpty {
                    self.feedbackCenter.error(
                        "Permanent shelf deletion failed",
                        detail: failureMessages.joined(separator: "\n"),
                        nextStep: "The deleted shelves were kept. Retry after checking repository permissions.",
                        additionalActions: retryAction.map { [$0] } ?? [],
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Some shelves deleted permanently",
                        detail: "Deleted: \(deletedNames.joined(separator: ", "))\nFailed: \(failureMessages.joined(separator: ", "))",
                        nextStep: "The failed deleted shelves were kept. Retry after checking repository permissions.",
                        additionalActions: retryAction.map { [$0] } ?? [],
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
                    operation: .deleteDeleted,
                    rootPath: resolvedRootPath
                )
                self.feedbackCenter.error(
                    "Permanent shelf deletion failed",
                    detail: failureMessages.isEmpty ? errorMessage(error) : failureMessages.joined(separator: "\n"),
                    nextStep: "The deleted shelf was kept. Retry after checking repository permissions.",
                    additionalActions: self.shelfLifecycleRetryFeedbackAction(
                        names: failedNamesSnapshot,
                        operation: .deleteDeleted,
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
