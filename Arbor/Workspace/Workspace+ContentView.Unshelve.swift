import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
nonisolated func automaticUnshelveTarget(
    for shelf: ShelveInfo,
    repo: Repository
) throws -> String? {
    guard GitChangelistSettings.createAutomatically(from: .standard) else { return nil }
    let name = shelf.description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    try repo.changelistEnsure(name: name)
    return name
}

/// Keep the comment entered in the Unshelve dialog with the destination
/// Changelist. Changelist metadata has no separate comment column, so append
/// the note to its description while preserving existing context/task flags.
func recordUnshelveComment(
    targetName: String,
    comment: String,
    rootPath: String?
) {
    let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedComment.isEmpty,
          let context = shelfMutationContext(
              rootPath: rootPath,
              activeRootPath: activeShelfRootPath,
              primaryRootPath: primaryShelfRootPath,
              primaryRepository: repo,
              secondaryRepository: shelfWorkspace.rootRepository
          ) else { return }
    let shelfRepo = context.repository
    let resolvedTarget = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedTarget.isEmpty else { return }
    Task.detached(priority: .utility) {
        do {
            let metadata = try shelfRepo.changelistMetadata()
                .first(where: { $0.name == resolvedTarget })
            let existing = metadata?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = existing.isEmpty
                ? normalizedComment
                : (existing == normalizedComment ? existing : "\(existing)\n\n\(normalizedComment)")
            try shelfRepo.changelistSetMetadata(
                name: resolvedTarget,
                description: description,
                trackContext: metadata?.trackContext ?? false,
                taskIdentity: metadata?.taskIdentity
            )
        } catch {
            await MainActor.run {
                self.feedbackCenter.warning(
                    "Save Unshelve comment failed",
                    detail: errorMessage(error),
                    nextStep: "The Shelf apply itself is preserved; retry after refreshing the Changelist."
                )
            }
        }
    }
}

nonisolated func assignUnshelvedPaths(
    _ paths: [String],
    to target: String?,
    status: [FileEntry],
    repo: Repository
) throws {
    guard let target, !paths.isEmpty else { return }
    let currentPaths = Set(status.map(\.path))
    let assignablePaths = paths.filter(currentPaths.contains)
    guard !assignablePaths.isEmpty else { return }
    try repo.changelistMovePaths(paths: assignablePaths, targetName: target)
}

func doShelveUnshelve(
    _ name: String,
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
        shelfFeedbackTitle(.apply, removeApplied: removeApplied),
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    Task.detached(priority: .userInitiated) {
        do {
            guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
            }
            let targetChangeList = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
            let applyResult = try shelfRepository.shelveUnshelveWithOptionsDifferentiated(
                name: name,
                removeApplied: removeApplied
            )
            let appliedPaths = applyResult.appliedPaths
            let failedPaths = applyResult.failedPaths
            let operationPaths = Array(
                Set(shelf.paths + appliedPaths + failedPaths)
            ).sorted()
            let operationItem = FeedbackOperationItem(
                scope: resolvedRootPath,
                name: name,
                state: patchApplyFeedbackState(applyResult),
                detail: patchApplySummary(
                    applyResult,
                    successDetail: "Shelf changes unshelved",
                    failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                ),
                children: shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: operationPaths,
                    result: applyResult,
                    successDetail: "Applied",
                    failureDetail: "Not applied"
                )
            )
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
                    deletedShelves: dsh,
                    changeLists: cls
                )
                self.refreshAfterShelfMutation(
                    repo: shelfRepository,
                    paths: appliedPaths,
                    metadataChanged: removeApplied
                )
                let restoredName = removeApplied
                    ? dsh.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                    : nil
                let detail = targetChangeList.map { "\(name) → \($0)" } ?? name
                if let restoredName {
                    let actions = [self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )]
                    if !patchApplyNeedsAttention(applyResult) {
                        self.feedbackCenter.success(
                            "Shelf unshelved and removed",
                            detail: detail,
                            additionalActions: actions,
                            notificationID: self.shelfBatchNotificationID(
                                operation: .apply,
                                rootPath: resolvedRootPath
                            )
                        )
                    } else {
                        self.feedbackCenter.warning(
                            "Shelf partially unshelved and removed",
                            detail: "\(detail): \(appliedPaths.count) applied, \(failedPaths.count) not applied",
                            nextStep: "Review the failed Shelf members and retry them separately.",
                            additionalActions: actions,
                            notificationID: self.shelfBatchNotificationID(
                                operation: .apply,
                                rootPath: resolvedRootPath
                            )
                        )
                    }
                } else if !patchApplyNeedsAttention(applyResult) {
                    self.feedbackCenter.success(
                        "Shelf unshelved",
                        detail: detail,
                        notificationID: self.shelfBatchNotificationID(
                            operation: .apply,
                            rootPath: resolvedRootPath
                        )
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Shelf partially unshelved",
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
                        isPop: false,
                        changeListName: (try? shelfRepository.shelveRestoreInfo())?.targetChangeList,
                        repository: shelfRepository
                    )
                }
            } else {
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

}
