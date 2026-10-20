import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func doShelveUnshelveShelves(
    _ names: [String],
    targetName: String?,
    removeApplied: Bool = false,
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
    let explicitTargetName = targetName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if targetName != nil, explicitTargetName?.isEmpty != false { return }

    var seenNames = Set<String>()
    let uniqueNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seenNames.insert($0).inserted }
    guard !uniqueNames.isEmpty else { return }

    let isSilent = explicitTargetName == nil
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map { $0.name })
    let notificationID = shelfBatchNotificationID(
        operation: .apply,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        isSilent ? "Unshelve shelves silently" : "Unshelve selected shelves",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Unshelve Shelf"
    )
    Task.detached(priority: .userInitiated) {
        do {
            let lists = try shelfRepository.changelistList()
            if let explicitTargetName,
               !lists.contains(where: { $0.name == explicitTargetName }) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Move changes failed",
                        detail: explicitTargetName,
                        notificationID: self.shelfBatchNotificationID(
                            operation: .apply,
                            rootPath: resolvedRootPath
                        )
                    )
                }
                return
            }

            var appliedNames: [String] = []
            var appliedDetails: [String] = []
            var mutatedPaths: [String] = []
            var failureMessages: [String] = []
            var postApplyWarnings: [String] = []
            var itemStates: [String: FeedbackResultState] = [:]
            var itemDetails: [String: String] = [:]
            var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
            var conflict: (name: String, paths: [String], targetName: String?)?

            for (index, name) in uniqueNames.enumerated() {
                var currentTargetName: String?
                var didApply = false
                var shelfPaths: [String] = []
                do {
                    let activeShelf = try shelfRepository.shelveList().first(where: { $0.name == name })
                    let deletedShelf = activeShelf == nil
                        ? try shelfRepository.shelveDeletedList().first(where: { $0.name == name })
                        : nil
                    guard let shelf = activeShelf ?? deletedShelf else {
                        throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
                    }
                    shelfPaths = shelf.paths
                    if let explicitTargetName {
                        currentTargetName = explicitTargetName
                    } else {
                        currentTargetName = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
                    }
                    let applyResult: PatchApplyResult
                    if activeShelf != nil {
                        applyResult = try shelfRepository.shelveUnshelveWithOptionsDifferentiated(
                            name: name,
                            removeApplied: removeApplied
                        )
                    } else {
                        applyResult = try shelfRepository.shelveUnshelveDeletedWithOptionsDifferentiated(
                            name: name,
                            removeApplied: removeApplied
                        )
                    }
                    let appliedPaths = applyResult.appliedPaths
                    let failedPaths = applyResult.failedPaths
                    mutatedPaths.append(contentsOf: appliedPaths)
                    if !appliedPaths.isEmpty {
                        appliedNames.append(name)
                        appliedDetails.append(
                            currentTargetName.map { "\(name) → \($0)" } ?? name
                        )
                    }
                    itemStates[name] = patchApplyFeedbackState(applyResult)
                    itemDetails[name] = patchApplySummary(
                        applyResult,
                        successDetail: currentTargetName.map { "Applied → \($0)" } ?? "Applied",
                        failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                    )
                    itemChildren[name] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + name,
                        paths: shelfPaths,
                        result: applyResult,
                        successDetail: currentTargetName.map { "Applied → \($0)" } ?? "Applied",
                        failureDetail: "Not applied"
                    )
                    didApply = !appliedPaths.isEmpty
                    if patchApplyNeedsAttention(applyResult) {
                        failureMessages.append(
                            "\(name): \(appliedPaths.count) applied, \(failedPaths.count) not applied"
                        )
                    }
                    let status = try shelfRepository.status()
                    try assignUnshelvedPaths(
                        appliedPaths,
                        to: currentTargetName,
                        status: status,
                        repo: shelfRepository
                    )
                } catch {
                    if case let .ShelveApplyConflict(conflictName, paths) = error as? EngineError {
                        if let currentTargetName {
                            _ = try? shelfRepository.shelveSetRestoreTarget(
                                name: conflictName,
                                targetChangeList: currentTargetName
                            )
                        }
                        conflict = (conflictName, paths, currentTargetName)
                        itemStates[conflictName] = .failed
                        itemDetails[conflictName] = "Conflict paused: \(paths.joined(separator: ", "))"
                        itemChildren[conflictName] = shelfOperationSubitems(
                            scope: resolvedRootPath + "\u{1f}" + conflictName,
                            paths: shelfPaths,
                            appliedPaths: [],
                            failedPaths: Set(paths),
                            successDetail: "Applied",
                            failureDetail: "Conflict paused"
                        )
                        await MainActor.run {
                            self.feedbackCenter.updateBatchProgress(
                                completed: index + 1,
                                total: uniqueNames.count,
                                phase: "Unshelve Shelf",
                                detail: conflictName
                            )
                        }
                        break
                    }
                    if didApply {
                        itemStates[name] = .success
                        itemDetails[name] = "Applied, but Changelist assignment failed: \(errorMessage(error))"
                        itemChildren[name] = shelfOperationSubitems(
                            scope: resolvedRootPath + "\u{1f}" + name,
                            paths: shelfPaths,
                            state: .success,
                            detail: "Applied, but Changelist assignment failed"
                        )
                        postApplyWarnings.append(
                            "\(name): applied, but final Changelist assignment failed: \(errorMessage(error))"
                        )
                    } else {
                        itemStates[name] = .failed
                        itemDetails[name] = errorMessage(error)
                        itemChildren[name] = shelfOperationSubitems(
                            scope: resolvedRootPath + "\u{1f}" + name,
                            paths: shelfPaths,
                            state: .failed,
                            detail: errorMessage(error)
                        )
                        failureMessages.append("\(name): \(errorMessage(error))")
                    }
                }
                await MainActor.run {
                    self.feedbackCenter.updateBatchProgress(
                        completed: index + 1,
                        total: uniqueNames.count,
                        phase: "Unshelve Shelf",
                        detail: name
                    )
                }
            }

            let finalStatus = (try? shelfRepository.status()) ?? []
            let nextChangeLists = (try? shelfRepository.changelistList()) ?? []
            let nextShelves = (try? shelfRepository.shelveList()) ?? []
            let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
            let appliedNamesSnapshot = appliedNames
            let appliedDetailsSnapshot = appliedDetails
            let mutatedPathsSnapshot = mutatedPaths
            let failureMessagesSnapshot = failureMessages
            let postApplyWarningsSnapshot = postApplyWarnings
            let itemStatesSnapshot = itemStates
            let itemDetailsSnapshot = itemDetails
            let itemChildrenSnapshot = itemChildren
            let conflictSnapshot = conflict
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
                    self.repositoryStatus.entries = finalStatus
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
                    paths: mutatedPathsSnapshot,
                    metadataChanged: removeApplied
                )
                if !isPrimaryRoot {
                    self.refreshAll(showFeedback: false)
                }

                let retryNames = uniqueNames.filter {
                    itemStatesSnapshot[$0] != .success && $0 != conflictSnapshot?.name
                }
                let retryAction = self.shelfBatchRetryFeedbackAction(
                    names: retryNames,
                    operation: .apply,
                    targetName: explicitTargetName,
                    removeApplied: removeApplied,
                    rootPath: resolvedRootPath
                )
                let operationItems = shelfOperationItems(
                    rootPath: resolvedRootPath,
                    names: uniqueNames,
                    states: itemStatesSnapshot,
                    details: itemDetailsSnapshot,
                    children: itemChildrenSnapshot
                )
                let destination = isSilent
                    ? (appliedDetailsSnapshot.isEmpty
                        ? "0/\(uniqueNames.count)"
                        : appliedDetailsSnapshot.joined(separator: ", "))
                    : "\(appliedNamesSnapshot.count)/\(uniqueNames.count) → \(explicitTargetName ?? "")"
                let restoreActions = removeApplied
                        ? nextDeletedShelves
                            .filter { !deletedShelfNamesBefore.contains($0.name) }
                            .map {
                                self.shelfRestoreFeedbackAction(
                                    name: $0.name,
                                    rootPath: resolvedRootPath
                                )
                            }
                    : []
                if let conflictSnapshot {
                    let failures = failureMessagesSnapshot.isEmpty
                        ? postApplyWarningsSnapshot.isEmpty
                            ? nil
                            : postApplyWarningsSnapshot.joined(separator: "\n")
                        : (failureMessagesSnapshot + postApplyWarningsSnapshot)
                            .joined(separator: "\n")
                    self.feedbackCenter.warning(
                        isSilent ? "Unshelve shelves silently paused" : "Unshelve selected shelves paused",
                        detail: [destination, failures].compactMap { $0 }.joined(separator: "\n"),
                        additionalActions: [retryAction].compactMap { $0 } + restoreActions,
                        notificationID: notificationID
                    )
                    self.presentShelveConflict(
                        name: conflictSnapshot.name,
                        paths: conflictSnapshot.paths,
                        isPop: false,
                        changeListName: conflictSnapshot.targetName,
                        repository: shelfRepository
                    )
                } else if failureMessagesSnapshot.isEmpty && postApplyWarningsSnapshot.isEmpty {
                    self.feedbackCenter.success(
                        isSilent ? "Shelves unshelved silently" : "Shelves unshelved",
                        detail: destination,
                        additionalActions: restoreActions,
                        notificationID: notificationID
                    )
                } else if appliedNamesSnapshot.isEmpty {
                    self.feedbackCenter.error(
                        isSilent ? "Unshelve shelves silently failed" : "Unshelve selected shelves failed",
                        detail: (failureMessagesSnapshot + postApplyWarningsSnapshot)
                            .joined(separator: "\n"),
                        nextStep: "The remaining shelves were kept. Resolve the local issue, then retry.",
                        additionalActions: [retryAction].compactMap { $0 },
                        notificationID: notificationID,
                        localized: true
                    )
                } else if failureMessagesSnapshot.isEmpty {
                    self.feedbackCenter.warning(
                        "Shelves applied with warnings",
                        detail: [
                            destination,
                            postApplyWarningsSnapshot.joined(separator: "\n")
                        ].joined(separator: "\n"),
                        additionalActions: [retryAction].compactMap { $0 } + restoreActions,
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Some shelves were not unshelved",
                        detail: [
                            destination,
                            (failureMessagesSnapshot + postApplyWarningsSnapshot)
                                .joined(separator: "\n")
                        ]
                            .joined(separator: "\n"),
                        additionalActions: [retryAction].compactMap { $0 } + restoreActions,
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
                let retryAction = self.shelfBatchRetryFeedbackAction(
                    names: uniqueNames,
                    operation: .apply,
                    targetName: explicitTargetName,
                    removeApplied: removeApplied,
                    rootPath: resolvedRootPath
                )
                let notificationID = self.shelfBatchNotificationID(
                    operation: .apply,
                    rootPath: resolvedRootPath
                )
                self.feedbackCenter.error(
                    isSilent ? "Unshelve shelves silently failed" : "Unshelve selected shelves failed",
                    detail: errorMessage(error),
                    nextStep: "The shelves were kept. Resolve the local issue, then retry.",
                    additionalActions: [retryAction].compactMap { $0 },
                    notificationID: notificationID,
                    localized: true
                )
                self.feedbackCenter.attachOperationItems(
                    uniqueNames.map {
                        FeedbackOperationItem(
                            scope: resolvedRootPath,
                            name: $0,
                            state: .failed,
                            detail: errorMessage(error)
                        )
                    },
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        }
    }
}

func doShelveUnshelveShelvesIntoChangeList(
    _ names: [String],
    targetName: String,
    removeApplied: Bool = false,
    rootPath: String? = nil
) {
    let trimmedTargetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTargetName.isEmpty else { return }
    var seenNames = Set<String>()
    let uniqueNames = names.filter { seenNames.insert($0).inserted }
    guard uniqueNames.count > 1 else { return }
    doShelveUnshelveShelves(
        uniqueNames,
        targetName: trimmedTargetName,
        removeApplied: removeApplied,
        rootPath: rootPath
    )
}

func doShelveUnshelveSilently(
    _ names: [String],
    removeApplied: Bool = false,
    rootPath: String? = nil
) {
    doShelveUnshelveShelves(
        names,
        targetName: nil,
        removeApplied: removeApplied,
        rootPath: rootPath
    )
}

}
