import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Apply selected members from several Shelves as one serialized operation.
/// IntelliJ passes a grouped-changes map to ShelfService; never starting one
/// detached repository mutation per group preserves that same lock and
/// notification boundary in SwiftUI.
func doShelveUnshelvePathGroups(
    _ groups: [ShelfPathDeleteGroup],
    removeApplied: Bool,
    sourceIsDeleted: Bool,
    targetName: String? = nil,
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
    let explicitTargetName = targetName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if targetName != nil, explicitTargetName?.isEmpty != false { return }
    let operation: ArborVCSActionRequest.ShelfMemberBatchOperation = sourceIsDeleted
        ? (removeApplied ? .unshelveDeletedAndRemove : .unshelveDeleted)
        : (removeApplied ? .unshelveAndRemove : .unshelve)
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map { $0.name })
    let notificationID = shelfMemberBatchNotificationID(
        operation: operation,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        sourceIsDeleted ? "Unshelve deleted Shelf changes" : "Unshelve Shelf changes",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: groups.count,
        phase: "Unshelve Shelf Changes"
    )
    Task.detached(priority: .userInitiated) {
        var completedKeys = Set<String>()
        var appliedDetails: [String] = []
        var mutatedPaths: [String] = []
        var failures: [String] = []
        var postApplyWarnings: [String] = []
        var conflict: (name: String, paths: [String], targetName: String?)?
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]

        for (index, group) in groups.enumerated() {
            let key = shelfPathGroupKey(group)
            var didApply = false
            var targetName: String?
            do {
                if let explicitTargetName,
                   !(try shelfRepository.changelistList()).contains(where: { $0.name == explicitTargetName }) {
                    throw EngineError.GitOperation(message: "Target Changelist not found: \(explicitTargetName)")
                }
                let sourceShelves = sourceIsDeleted
                    ? try shelfRepository.shelveDeletedList()
                    : try shelfRepository.shelveList()
                guard let shelf = sourceShelves.first(where: { $0.name == group.shelfName }) else {
                    throw EngineError.GitOperation(
                        message: "shelve: shelf not found '\(group.shelfName)'"
                    )
                }
                if let explicitTargetName {
                    targetName = explicitTargetName
                } else {
                    targetName = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
                }
                let applyResult = sourceIsDeleted
                    ? try shelfRepository.shelveUnshelveDeletedPathsWithOptionsDifferentiated(
                        name: group.shelfName,
                        paths: group.paths,
                        removeApplied: removeApplied
                    )
                    : try shelfRepository.shelveUnshelvePathsWithOptionsDifferentiated(
                        name: group.shelfName,
                        paths: group.paths,
                        removeApplied: removeApplied
                    )
                let appliedPaths = applyResult.appliedPaths
                let failedPaths = applyResult.failedPaths
                didApply = !appliedPaths.isEmpty
                itemStates[group.shelfName] = patchApplyFeedbackState(applyResult)
                itemDetails[group.shelfName] = patchApplySummary(
                    applyResult,
                    successDetail: targetName.map { "Applied → \($0)" } ?? "Shelf changes unshelved",
                    failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                )
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    result: applyResult,
                    successDetail: "Applied",
                    failureDetail: "Not applied"
                )
                if !patchApplyNeedsAttention(applyResult) {
                    completedKeys.insert(key)
                } else {
                    failures.append(
                        "\(group.shelfName): \(appliedPaths.count) applied, \(failedPaths.count) not applied"
                    )
                }
                mutatedPaths.append(contentsOf: appliedPaths)
                let status = try shelfRepository.status()
                do {
                    try assignUnshelvedPaths(
                        appliedPaths,
                        to: targetName,
                        status: status,
                        repo: shelfRepository
                    )
                } catch {
                    postApplyWarnings.append(
                        "\(group.shelfName): applied, but final Changelist assignment failed: \(errorMessage(error))"
                    )
                }
                appliedDetails.append(
                    targetName.map { "\(group.shelfName) → \($0): \(group.paths.joined(separator: ", "))" }
                        ?? "\(group.shelfName): \(group.paths.joined(separator: ", "))"
                )
            } catch {
                if case let .ShelveApplyConflict(conflictName, paths) = error as? EngineError {
                    if let targetName {
                        _ = try? shelfRepository.shelveSetRestoreTarget(
                            name: conflictName,
                            targetChangeList: targetName
                        )
                    }
                    conflict = (conflictName, paths, targetName)
                    itemStates[group.shelfName] = .failed
                    itemDetails[group.shelfName] = "Conflict paused: \(paths.joined(separator: ", "))"
                    itemChildren[group.shelfName] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                        paths: group.paths,
                        appliedPaths: [],
                        failedPaths: Set(paths),
                        successDetail: "Applied",
                        failureDetail: "Conflict paused"
                    )
                    await MainActor.run {
                        self.feedbackCenter.updateBatchProgress(
                            completed: index + 1,
                            total: groups.count,
                            phase: "Unshelve Shelf Changes",
                            detail: conflictName
                        )
                    }
                    break
                }
                if !didApply {
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
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: groups.count,
                    phase: "Unshelve Shelf Changes",
                    detail: group.shelfName
                )
            }
        }

        let finalStatus = (try? shelfRepository.status()) ?? []
        let nextChangeLists = (try? shelfRepository.changelistList()) ?? []
        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let completedKeysSnapshot = completedKeys
        let appliedDetailsSnapshot = appliedDetails
        let mutatedPathsSnapshot = mutatedPaths
        let failuresSnapshot = failures
        let postApplyWarningsSnapshot = postApplyWarnings
        let conflictSnapshot = conflict
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        let retryGroups = groups.filter {
            !completedKeysSnapshot.contains(shelfPathGroupKey($0))
                && $0.shelfName != conflictSnapshot?.name
        }
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
                deletedShelves: nextDeletedShelves
            )
            self.refreshAfterShelfMutation(
                repo: shelfRepository,
                paths: mutatedPathsSnapshot,
                metadataChanged: removeApplied || sourceIsDeleted
            )
            if !isPrimaryRoot {
                self.refreshAll(showFeedback: false)
            }

            let retryAction = self.shelfMemberBatchRetryFeedbackAction(
                groups: retryGroups,
                operation: operation,
                targetName: explicitTargetName,
                rootPath: resolvedRootPath
            )
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
            let additionalActions = [retryAction].compactMap { $0 } + restoreActions
            let detail = appliedDetailsSnapshot.isEmpty
                ? "0/\(groups.count)"
                : "\(completedKeysSnapshot.count)/\(groups.count): \(appliedDetailsSnapshot.joined(separator: "; "))"
            let warningDetail = [detail, failuresSnapshot.joined(separator: "\n"), postApplyWarningsSnapshot.joined(separator: "\n")]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: groups.map(\.shelfName),
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )

            if let conflictSnapshot {
                self.feedbackCenter.warning(
                    sourceIsDeleted ? "Unshelve deleted Shelf changes paused" : "Unshelve Shelf changes paused",
                    detail: warningDetail,
                    nextStep: "Resolve the conflict, then retry the remaining Shelf changes.",
                    additionalActions: additionalActions,
                    notificationID: notificationID
                )
                self.presentShelveConflict(
                    name: conflictSnapshot.name,
                    paths: conflictSnapshot.paths,
                    isPop: false,
                    changeListName: conflictSnapshot.targetName,
                    repository: shelfRepository
                )
            } else if failuresSnapshot.isEmpty && postApplyWarningsSnapshot.isEmpty {
                self.feedbackCenter.success(
                    sourceIsDeleted ? "Deleted Shelf changes unshelved" : "Shelf changes unshelved",
                    detail: detail,
                    additionalActions: restoreActions,
                    notificationID: notificationID
                )
            } else if completedKeysSnapshot.isEmpty {
                self.feedbackCenter.error(
                    sourceIsDeleted ? "Deleted Shelf changes unshelve failed" : "Shelf changes unshelve failed",
                    detail: warningDetail,
                    nextStep: "The selected Shelf changes were kept. Resolve the reported issue and retry.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some Shelf changes were not unshelved",
                    detail: warningDetail,
                    nextStep: "The failed Shelf changes were kept. Retry the remaining groups.",
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

func doShelveUnshelvePathGroupsIntoChangeList(
    _ groups: [ShelfPathDeleteGroup],
    targetName: String,
    removeApplied: Bool = false,
    rootPath: String? = nil
) {
    let trimmedTargetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTargetName.isEmpty else { return }
    let uniqueGroups = normalizedShelfPathGroups(groups)
    guard uniqueGroups.count > 1 else { return }
    doShelveUnshelvePathGroups(
        uniqueGroups,
        removeApplied: removeApplied,
        sourceIsDeleted: false,
        targetName: trimmedTargetName,
        rootPath: rootPath
    )
}

/// 仅应用 Shelf 中选中的成员，保留其余成员和整个 Shelf。
func doShelveUnshelvePaths(
    _ name: String,
    _ paths: [String],
    removeApplied: Bool = false,
    selections: [ShelvePatchSelection]? = nil,
    sourceIsDeleted: Bool = false,
    basePath: String? = nil,
    pathStrip: UInt32 = 1,
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
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelfWorkspace.deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map { $0.name })
    beginFeedbackOperation("Unshelve changes")
    Task.detached(priority: .userInitiated) {
        var operationItem: FeedbackOperationItem?
        do {
            let sourceShelves = sourceIsDeleted
                ? (try shelfRepository.shelveDeletedList())
                : (try shelfRepository.shelveList())
            guard let shelf = sourceShelves.first(where: { $0.name == name }) else {
                throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
            }
            let targetChangeList = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
            let appliedPaths: [String]
            var engineFailedPaths = Set<String>()
            var applyResult: PatchApplyResult?
            let mappedBasePath = basePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasPathMapping = (mappedBasePath?.isEmpty == false) || pathStrip != 1
            if let selections, !selections.isEmpty {
                guard !sourceIsDeleted else {
                    throw EngineError.GitOperation(
                        message: "shelve: hunk selection is not available for Recently Deleted members"
                    )
                }
                if hasPathMapping {
                    appliedPaths = try shelfRepository.shelveUnshelveSelectionsWithOptionsAndBase(
                        name: name,
                        selections: selections,
                        removeApplied: removeApplied,
                        basePath: mappedBasePath ?? "",
                        pathStrip: pathStrip
                    )
                } else {
                    let result = try shelfRepository.shelveUnshelveSelectionsWithOptionsDifferentiated(
                        name: name,
                        selections: selections,
                        removeApplied: removeApplied
                    )
                    applyResult = result
                    appliedPaths = result.appliedPaths
                    engineFailedPaths = Set(result.failedPaths)
                }
            } else {
                if sourceIsDeleted {
                    if hasPathMapping {
                        appliedPaths = try shelfRepository.shelveUnshelveDeletedPathsWithOptionsAndBase(
                            name: name,
                            paths: paths,
                            removeApplied: removeApplied,
                            basePath: mappedBasePath ?? "",
                            pathStrip: pathStrip
                        )
                    } else {
                        let result = try shelfRepository.shelveUnshelveDeletedPathsWithOptionsDifferentiated(
                            name: name,
                            paths: paths,
                            removeApplied: removeApplied
                        )
                        applyResult = result
                        appliedPaths = result.appliedPaths
                        engineFailedPaths = Set(result.failedPaths)
                    }
                } else {
                    if hasPathMapping {
                        appliedPaths = try shelfRepository.shelveUnshelvePathsWithOptionsAndBase(
                            name: name,
                            paths: paths,
                            removeApplied: removeApplied,
                            basePath: mappedBasePath ?? "",
                            pathStrip: pathStrip
                        )
                    } else {
                        let result = try shelfRepository.shelveUnshelvePathsWithOptionsDifferentiated(
                            name: name,
                            paths: paths,
                            removeApplied: removeApplied
                        )
                        applyResult = result
                        appliedPaths = result.appliedPaths
                        engineFailedPaths = Set(result.failedPaths)
                    }
                }
            }
            let requestedPaths = selections?.map(\.path) ?? paths
            let requestedPathSet = Set(requestedPaths)
            let appliedPathSet = Set(appliedPaths).intersection(requestedPathSet)
            let failedPathSet = requestedPathSet
                .subtracting(appliedPathSet)
                .union(engineFailedPaths)
            if let applyResult {
                operationItem = FeedbackOperationItem(
                    scope: resolvedRootPath,
                    name: name,
                    state: patchApplyFeedbackState(applyResult),
                    detail: patchApplySummary(
                        applyResult,
                        successDetail: "Shelf changes unshelved",
                        failureDetail: "\(appliedPathSet.count) applied, \(failedPathSet.count) not applied"
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
                    state: failedPathSet.isEmpty ? .success : .failed,
                    detail: failedPathSet.isEmpty
                        ? "Shelf changes unshelved"
                        : "\(appliedPathSet.count) applied, \(failedPathSet.count) not applied",
                    children: shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + name,
                        paths: requestedPaths,
                        appliedPaths: appliedPathSet,
                        failedPaths: failedPathSet,
                        successDetail: "Applied",
                        failureDetail: "Not applied"
                    )
                )
            }
            let needsAttention = applyResult.map(patchApplyNeedsAttention) ?? !failedPathSet.isEmpty
            let st = try shelfRepository.status()
            try assignUnshelvedPaths(appliedPaths, to: targetChangeList, status: st, repo: shelfRepository)
            let cls = (try? shelfRepository.changelistList()) ?? []
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            let operationItemSnapshot = operationItem
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
                    self.repositoryStatus.entries = st
                    self.repositoryStatus.changeLists = cls
                }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh,
                    changeLists: cls
                )
                self.refreshAfterShelfMutation(
                    repo: shelfRepository,
                    paths: appliedPaths,
                    metadataChanged: removeApplied || sourceIsDeleted
                )
                if !isPrimaryRoot {
                    self.refreshAll(showFeedback: false)
                }
                let restoredName = removeApplied
                    ? dsh.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                    : nil
                let detail = targetChangeList.map { "\(name) → \($0)" } ?? paths.joined(separator: ", ")
                let notificationID = self.shelfBatchNotificationID(
                    operation: .apply,
                    rootPath: resolvedRootPath
                )
                if let restoredName {
                    let restoreAction = self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )
                    if !needsAttention {
                        self.feedbackCenter.success(
                            "Shelf changes unshelved and removed",
                            detail: detail,
                            additionalActions: [restoreAction],
                            notificationID: notificationID
                        )
                    } else {
                        self.feedbackCenter.warning(
                            "Shelf changes partially unshelved",
                            detail: "\(detail): \(appliedPathSet.count) applied, \(failedPathSet.count) not applied",
                            nextStep: "Review the failed Shelf members and retry them separately.",
                            additionalActions: [restoreAction],
                            notificationID: notificationID
                        )
                    }
                } else if !needsAttention {
                    self.feedbackCenter.success(
                        "Shelf changes unshelved",
                        detail: detail,
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Shelf changes partially unshelved",
                        detail: "\(detail): \(appliedPathSet.count) applied, \(failedPathSet.count) not applied",
                        nextStep: "Review the failed Shelf members and retry them separately.",
                        notificationID: notificationID
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    [operationItemSnapshot].compactMap { $0 },
                    notificationID: notificationID
                )
            }
        } catch {
            let requestedPaths = selections?.map(\.path) ?? paths
            let operationItemSnapshot = operationItem
            if case let .ShelveApplyConflict(conflictName, conflictPaths) = error as? EngineError {
                if GitChangelistSettings.createAutomatically(from: .standard),
                   let shelf = try? (sourceIsDeleted
                       ? shelfRepository.shelveDeletedList()
                       : shelfRepository.shelveList()).first(where: { $0.name == conflictName }),
                       let target = try? automaticUnshelveTarget(for: shelf, repo: shelfRepository) {
                    _ = try? shelfRepository.shelveSetRestoreTarget(name: conflictName, targetChangeList: target)
                }
                await MainActor.run {
                    let notificationID = self.shelfBatchNotificationID(
                        operation: .apply,
                        rootPath: resolvedRootPath
                    )
                    self.presentShelveConflict(
                        name: conflictName,
                        paths: conflictPaths,
                        isPop: false,
                        repository: shelfRepository,
                        notificationID: notificationID
                    )
                    self.feedbackCenter.attachOperationItems(
                        [FeedbackOperationItem(
                            scope: resolvedRootPath,
                            name: name,
                            state: .failed,
                            detail: "Conflict paused: \(conflictPaths.joined(separator: ", "))",
                            children: shelfOperationSubitems(
                                scope: resolvedRootPath + "\u{1f}" + name,
                                paths: requestedPaths,
                                appliedPaths: [],
                                failedPaths: Set(conflictPaths),
                                successDetail: "Applied",
                                failureDetail: "Conflict paused"
                            )
                        )],
                        notificationID: notificationID
                    )
                }
            } else {
                await MainActor.run {
                    let notificationID = self.shelfBatchNotificationID(
                        operation: .apply,
                        rootPath: resolvedRootPath
                    )
                    self.feedbackCenter.error(
                        "Unshelve selected changes failed",
                        detail: errorMessage(error),
                        nextStep: "The shelf was kept. Resolve any local conflict, then try the member again.",
                        notificationID: notificationID
                    )
                    let item = operationItemSnapshot.map {
                        FeedbackOperationItem(
                            scope: $0.scope,
                            name: $0.name,
                            state: .failed,
                            detail: "Shelf apply completed, but post-apply bookkeeping failed: \(errorMessage(error))",
                            children: $0.children
                        )
                    } ?? FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: .failed,
                        detail: errorMessage(error),
                        children: shelfOperationSubitems(
                            scope: resolvedRootPath + "\u{1f}" + name,
                            paths: requestedPaths,
                            state: .failed,
                            detail: errorMessage(error)
                        )
                    )
                    self.feedbackCenter.attachOperationItems(
                        [item],
                        notificationID: notificationID
                    )
                }
            }
        }
    }
}

/// Apply selected text hunks from a Shelf while preserving the same
/// automatic Changelist and conflict-recovery behavior as file selection.
func doShelveUnshelveSelections(
    _ name: String,
    selections: [ShelvePatchSelection],
    removeApplied: Bool = false,
    basePath: String? = nil,
    pathStrip: UInt32 = 1,
    rootPath: String? = nil
) {
    guard !selections.isEmpty else { return }
    var paths: [String] = []
    var seen = Set<String>()
    for selection in selections where seen.insert(selection.path).inserted {
        paths.append(selection.path)
    }
    doShelveUnshelvePaths(
        name,
        paths,
        removeApplied: removeApplied,
        selections: selections,
        basePath: basePath,
        pathStrip: pathStrip,
        rootPath: rootPath
    )
}

}
