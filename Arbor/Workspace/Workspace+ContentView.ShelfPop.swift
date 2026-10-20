import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func doShelvePop(
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
    let notificationID = shelfBatchNotificationID(
        operation: .pop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        shelfFeedbackTitle(.pop),
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    Task.detached(priority: .userInitiated) {
        do {
            guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
            }
            let targetChangeList = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
            let applyResult = try shelfRepository.shelvePopDifferentiated(name: name)
            let appliedPaths = applyResult.appliedPaths
            let failedPaths = applyResult.failedPaths
            let st = try shelfRepository.status()
            try assignUnshelvedPaths(
                appliedPaths,
                to: targetChangeList,
                status: st,
                repo: shelfRepository
            )
            let cls = (try? shelfRepository.changelistList()) ?? []
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                if shelfRootSelectionIsPrimary(
                    selectedRootPath: resolvedRootPath,
                    primaryRootPath: self.primaryShelfRootPath
                ) {
                    self.repositoryStatus.entries = st
                    self.repositoryStatus.changeLists = cls
                }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh
                )
                self.refreshAfterShelfMutation(repo: shelfRepository, paths: appliedPaths)
                if self.shelfWorkspace.previewName == name,
                   !ss.contains(where: { $0.name == name }),
                   shelfActionRootMatchesCurrentRoot(
                       requestedRootPath: resolvedRootPath,
                       currentRootPath: self.shelfWorkspace.previewRootPath ?? self.primaryShelfRootPath
                   ) {
                    self.shelfWorkspace.previewName = nil
                    self.shelfWorkspace.previewText = nil
                    self.shelfWorkspace.showPreview = false
                }
                let operationItem = FeedbackOperationItem(
                    scope: resolvedRootPath,
                    name: name,
                    state: patchApplyFeedbackState(applyResult),
                    detail: patchApplySummary(
                        applyResult,
                        successDetail: targetChangeList.map { "Applied → \($0)" } ?? "Applied",
                        failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                    ),
                    children: shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + name,
                        paths: shelf.paths,
                        result: applyResult,
                        successDetail: "Applied",
                        failureDetail: "Not applied"
                    )
                )
                if !patchApplyNeedsAttention(applyResult) {
                    self.feedbackCenter.success(
                        "Shelve pop completed",
                        detail: targetChangeList.map { "\(name) → \($0)" },
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Shelve pop partially completed",
                        detail: "\(name): \(appliedPaths.count) applied, \(failedPaths.count) not applied",
                        nextStep: "Review the remaining Shelf members and retry them separately.",
                        notificationID: notificationID
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    [operationItem],
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        } catch {
            if case let .ShelveApplyConflict(conflictName, paths) = error as? EngineError {
                if GitChangelistSettings.createAutomatically(from: .standard),
                   let shelf = try? shelfRepository.shelveList().first(where: { $0.name == conflictName }),
                   let target = try? automaticUnshelveTarget(for: shelf, repo: shelfRepository) {
                    _ = try? shelfRepository.shelveSetRestoreTarget(
                        name: conflictName,
                        targetChangeList: target
                    )
                }
                await MainActor.run {
                    self.presentShelveConflict(
                        name: conflictName,
                        paths: paths,
                        isPop: true,
                        changeListName: (try? shelfRepository.shelveRestoreInfo())?.targetChangeList,
                        repository: shelfRepository
                    )
                }
            } else {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Shelve pop failed",
                        detail: errorMessage(error),
                        nextStep: "The shelf was kept. Resolve the local conflict, then retry.",
                        notificationID: self.shelfBatchNotificationID(
                            operation: .pop,
                            rootPath: resolvedRootPath
                        )
                    )
                }
            }
        }
    }
}

/// Pop multiple active Shelves with the same non-dialog action semantics as
/// IntelliJ's PopShelfAction. Each list is applied and removed independently;
/// a conflict stops the queue so the persisted restore snapshot can be
/// resolved before another Shelf touches the same worktree.
func doShelvePopShelves(
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
    var seen = Set<String>()
    let uniqueNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !uniqueNames.isEmpty else { return }
    if uniqueNames.count == 1, let name = uniqueNames.first {
        doShelvePop(
            name,
            rootPath: resolvedRootPath,
            preservePreviousItems: preservePreviousItems
        )
        return
    }

    let notificationID = shelfBatchNotificationID(
        operation: .pop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Pop shelves",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Pop Shelf"
    )
    Task.detached(priority: .userInitiated) {
        var appliedDetails: [String] = []
        var appliedNames: [String] = []
        var consumedNames: [String] = []
        var mutatedPaths: [String] = []
        var failures: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        var conflict: (name: String, paths: [String], targetName: String?)?

        for (index, name) in uniqueNames.enumerated() {
            var shelfPaths: [String] = []
            do {
                guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                    throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
                }
                shelfPaths = shelf.paths
                let targetName = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
                let applyResult = try shelfRepository.shelvePopDifferentiated(name: name)
                let appliedPaths = applyResult.appliedPaths
                let failedPaths = applyResult.failedPaths
                if !(try shelfRepository.shelveList()).contains(where: { $0.name == name }) {
                    consumedNames.append(name)
                }
                mutatedPaths.append(contentsOf: appliedPaths)
                let status = try shelfRepository.status()
                try assignUnshelvedPaths(
                    appliedPaths,
                    to: targetName,
                    status: status,
                    repo: shelfRepository
                )
                if !patchApplyNeedsAttention(applyResult) {
                    appliedNames.append(name)
                    appliedDetails.append(
                        targetName.map { "\(name) → \($0)" } ?? name
                    )
                } else {
                    failures.append(
                        "\(name): \(appliedPaths.count) applied, \(failedPaths.count) not applied"
                    )
                }
                itemStates[name] = patchApplyFeedbackState(applyResult)
                itemDetails[name] = patchApplySummary(
                    applyResult,
                    successDetail: targetName.map { "Applied → \($0)" } ?? "Applied",
                    failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                )
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPaths,
                    result: applyResult,
                    successDetail: "Applied",
                    failureDetail: "Not applied"
                )
            } catch {
                if case let .ShelveApplyConflict(conflictName, paths) = error as? EngineError {
                    let targetName: String? = {
                        guard GitChangelistSettings.createAutomatically(from: .standard),
                              let shelf = try? shelfRepository.shelveList().first(where: { $0.name == conflictName })
                        else { return nil }
                        return try? automaticUnshelveTarget(for: shelf, repo: shelfRepository)
                    }()
                    if let targetName {
                        _ = try? shelfRepository.shelveSetRestoreTarget(
                            name: conflictName,
                            targetChangeList: targetName
                        )
                    }
                    let restoreInfo = (try? shelfRepository.shelveRestoreInfo()) ?? nil
                    let appliedPaths = restoreInfo?.appliedPaths ?? []
                    let conflictPaths = restoreInfo?.conflictPaths ?? paths
                    mutatedPaths.append(contentsOf: appliedPaths)
                    conflict = (conflictName, paths, targetName)
                    itemStates[conflictName] = .failed
                    itemDetails[conflictName] = "Conflict paused: \(paths.joined(separator: ", "))"
                    itemChildren[conflictName] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + conflictName,
                        paths: shelfPaths,
                        appliedPaths: Set(appliedPaths),
                        failedPaths: Set(conflictPaths),
                        successDetail: "Applied",
                        failureDetail: "Conflict paused"
                    )
                    await MainActor.run {
                        self.feedbackCenter.updateBatchProgress(
                            completed: index + 1,
                            total: uniqueNames.count,
                            phase: "Pop Shelf",
                            detail: conflictName
                        )
                    }
                    break
                }
                itemStates[name] = .failed
                itemDetails[name] = errorMessage(error)
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPaths,
                    state: .failed,
                    detail: errorMessage(error)
                )
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Pop Shelf",
                    detail: name
                )
            }
        }

        let finalStatus = (try? shelfRepository.status()) ?? []
        let nextChangeLists = (try? shelfRepository.changelistList()) ?? []
        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let appliedNamesSnapshot = appliedNames
        let consumedNamesSnapshot = consumedNames
        let mutatedPathsSnapshot = mutatedPaths
        let appliedDetailsSnapshot = appliedDetails
        let failuresSnapshot = failures
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
                paths: mutatedPathsSnapshot
            )
            if !isPrimaryRoot {
                self.refreshAll(showFeedback: false)
            }
            if let previewName = self.shelfWorkspace.previewName,
               uniqueNames.contains(previewName),
               !nextShelves.contains(where: { $0.name == previewName }) {
                self.shelfWorkspace.previewName = nil
                self.shelfWorkspace.previewText = nil
                self.shelfWorkspace.showPreview = false
            }

            let retryNames = uniqueNames.filter {
                !appliedNamesSnapshot.contains($0)
                    && !consumedNamesSnapshot.contains($0)
                    && $0 != conflictSnapshot?.name
            }
            let retryAction = self.shelfBatchRetryFeedbackAction(
                names: retryNames,
                operation: .pop,
                targetName: nil,
                removeApplied: true,
                rootPath: resolvedRootPath
            )
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: uniqueNames,
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            let detail = appliedDetailsSnapshot.isEmpty
                ? "0/\(uniqueNames.count)"
                : appliedDetailsSnapshot.joined(separator: ", ")
            if let conflictSnapshot {
                let remaining = failuresSnapshot.isEmpty
                    ? nil
                    : failuresSnapshot.joined(separator: "\n")
                self.feedbackCenter.warning(
                    "Shelve pop paused",
                    detail: [detail, remaining].compactMap { $0 }.joined(separator: "\n"),
                    nextStep: "Resolve the restored local changes, then complete the Shelf pop.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
                self.presentShelveConflict(
                    name: conflictSnapshot.name,
                    paths: conflictSnapshot.paths,
                    isPop: true,
                    changeListName: conflictSnapshot.targetName,
                    repository: shelfRepository
                )
            } else if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelve pop completed",
                    detail: detail,
                    notificationID: notificationID
                )
            } else if !appliedDetailsSnapshot.isEmpty {
                self.feedbackCenter.warning(
                    "Shelves applied with warnings",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")]
                        .joined(separator: "\n"),
                    nextStep: "Review the remaining Shelves and retry them individually.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            } else {
                self.feedbackCenter.error(
                    "Shelf pop failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The remaining Shelves were kept. Resolve the local issue, then retry.",
                    additionalActions: retryAction.map { [$0] } ?? [],
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
