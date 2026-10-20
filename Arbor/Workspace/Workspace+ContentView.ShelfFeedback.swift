import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func openApplyLocalChangesRestore(_ request: ArborVCSActionRequest) {
    guard let rootPath = request.rootPath else { return }
    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    openMultiRootConflictResolver(preferredRootPath: rootPath)
}

func showSavedChanges(_ request: ArborVCSActionRequest) {
    guard let savedChangesKind = request.savedChangesKind,
          let savedChangesID = request.savedChangesID,
          !savedChangesID.isEmpty else { return }

    let rootPath = request.rootPath ?? repo?.workdir()
    guard let rootPath else { return }
    let savedChangesRepo: Repository
    do {
        savedChangesRepo = try openRepository(path: rootPath)
    } catch {
        feedbackCenter.error("Load saved changes failed", detail: errorMessage(error))
        return
    }

    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    Task.detached(priority: .userInitiated) {
        do {
            switch savedChangesKind {
            case .shelf:
                let shelves = try savedChangesRepo.shelveList()
                guard shelves.contains(where: { $0.name == savedChangesID }) else {
                    throw NSError(
                        domain: "Arbor.SavedChanges",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "找不到已保存的 Shelf：\(savedChangesID)"]
                    )
                }
                let diff = try savedChangesRepo.shelveDiff(name: savedChangesID)
                await MainActor.run {
                    self.shelfWorkspace.shelves = shelves
                    self.stashUI.clearPreview()
                    self.shelfWorkspace.previewName = savedChangesID
                    self.shelfWorkspace.previewIsDeleted = false
                    self.shelfWorkspace.previewText = diff
                    self.shelfWorkspace.showPreview = true
                }
            case .stash:
                let stashes = try savedChangesRepo.stashList()
                guard let index = stashes.firstIndex(where: { $0.id == savedChangesID }) else {
                    throw NSError(
                        domain: "Arbor.SavedChanges",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "找不到已保存的 stash：\(savedChangesID)"]
                    )
                }
                let diff = try savedChangesRepo.stashDiff(
                    index: try currentStashIndex(repo: savedChangesRepo, stashID: savedChangesID)
                )
                await MainActor.run {
                    self.stashUI.stashes = stashes
                    self.shelfWorkspace.previewName = nil
                    self.shelfWorkspace.previewText = nil
                    self.shelfWorkspace.showPreview = false
                    self.stashUI.previewStashID = stashes[index].id
                    self.stashUI.previewText = diff
                    self.stashUI.showPreview = true
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Load saved changes failed", detail: errorMessage(error))
            }
        }
    }
}

func shelfActionRequest(
    kind: ArborVCSActionRequest.Kind,
    name: String,
    paths: [String]? = nil,
    restoreTimestamp: Int64? = nil,
    rootPath: String? = nil
) -> ArborVCSActionRequest? {
    guard let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    return ArborVCSActionRequest(
        kind: kind,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: name,
        shelfPaths: paths,
        shelfRestoreTimestamp: restoreTimestamp
    )
}

func isShelfSemanticAction(_ kind: ArborVCSActionRequest.Kind) -> Bool {
    switch kind {
    case .restoreShelf,
         .restoreShelfPaths,
         .deleteDeletedShelfPaths,
         .undoShelfDeletion,
         .undoShelfDeletions,
         .dropShelf,
         .retryShelfBatch,
         .retryShelfMemberBatch,
         .retryShelfLifecycleBatch,
         .retryShelfDeletePlan:
        return true
    default:
        return false
    }
}

func shelfRootNotificationID(
    prefix: String,
    rootPath: String? = nil
) -> String? {
    guard let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    return shelfNotificationID(prefix: prefix, rootPath: resolvedRootPath)
}

func shelfMetadataNotificationID(
    operation: String,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(prefix: "shelf-metadata.\(operation)", rootPath: rootPath)
}

func shelfBatchNotificationID(
    operation: ArborVCSActionRequest.ShelfBatchOperation,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(
        prefix: "shelf-batch.\(operation.rawValue)",
        rootPath: rootPath
    )
}

func shelfMemberBatchNotificationID(
    operation: ArborVCSActionRequest.ShelfMemberBatchOperation,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(
        prefix: "shelf-member-batch.\(operation.rawValue)",
        rootPath: rootPath
    )
}

func shelfLifecycleNotificationID(
    operation: ArborVCSActionRequest.ShelfLifecycleOperation,
    rootPath: String? = nil
) -> String? {
    shelfRootNotificationID(
        prefix: "shelf-lifecycle.\(operation.rawValue)",
        rootPath: rootPath
    )
}

func shelfUndoDeletionNotificationID(rootPath: String? = nil) -> String? {
    shelfRootNotificationID(prefix: "shelf-undo-deletion", rootPath: rootPath)
}

func shelfDeletedMemberDeletionNotificationID(rootPath: String? = nil) -> String? {
    shelfRootNotificationID(prefix: "shelf-deleted-member-deletion", rootPath: rootPath)
}

func shelfBatchRetryFeedbackAction(
    names: [String],
    operation: ArborVCSActionRequest.ShelfBatchOperation,
    targetName: String?,
    removeApplied: Bool,
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !normalizedNames.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfBatch,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfNames: normalizedNames,
        shelfBatchOperation: operation,
        shelfBatchTargetName: targetName,
        shelfBatchRemoveApplied: removeApplied
    )
    return FeedbackAction(title: "Retry Remaining Shelves", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfMemberBatchRetryFeedbackAction(
    groups: [ShelfPathDeleteGroup],
    operation: ArborVCSActionRequest.ShelfMemberBatchOperation,
    targetName: String? = nil,
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedGroups = normalizedShelfPathGroups(groups)
    guard !normalizedGroups.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfMemberBatch,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfMemberGroups: normalizedGroups.map {
            PersistedShelfPathGroup(shelfName: $0.shelfName, paths: $0.paths)
        },
        shelfMemberBatchOperation: operation,
        shelfMemberBatchTargetName: targetName
    )
    return FeedbackAction(title: "Retry Remaining Shelf Changes", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfDeletePlanRetryFeedbackAction(
    plan: ShelfDeletePlan,
    rootPath: String? = nil
) -> FeedbackAction? {
    guard !plan.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfDeletePlan,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfDeletePlan: PersistedShelfDeletePlan(plan)
    )
    return FeedbackAction(title: "Retry Remaining Shelf Actions", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfLifecycleRetryFeedbackAction(
    names: [String],
    operation: ArborVCSActionRequest.ShelfLifecycleOperation,
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !normalizedNames.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .retryShelfLifecycleBatch,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfNames: normalizedNames,
        shelfLifecycleOperation: operation
    )
    return FeedbackAction(title: "Retry Remaining Shelf Actions", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func savedChangesFeedbackAction(
    kind: ArborVCSActionRequest.SavedChangesKind,
    identifier: String,
    rootPath: String? = nil
) -> FeedbackAction? {
    guard let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showSavedChanges,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: "",
        savedChangesKind: kind,
        savedChangesID: identifier
    )
    return FeedbackAction(title: "View saved changes…", semanticAction: request) {
        self.showSavedChanges(request)
    }
}

/// Find the exact saved artifact left by any automatic preserving operation.
/// Apply-style operations and Rebase intentionally use different persisted
/// markers, but both must resolve to the same root-qualified preview action.
func pendingSavedChangesFeedbackAction(
    repo: Repository,
    rootPath: String? = nil
) -> FeedbackAction? {
    let info = ((try? repo.applyLocalChangesRestoreInfo()) ?? nil)
        ?? ((try? repo.rebaseLocalChangesRestoreInfo()) ?? nil)
    guard let info,
          let kind = ArborVCSActionRequest.SavedChangesKind(rawValue: info.kind) else {
        return nil
    }
    return savedChangesFeedbackAction(
        kind: kind,
        identifier: info.identifier,
        rootPath: rootPath ?? repo.workdir()
    )
}

func shelfRestoreFeedbackAction(
    name: String,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .restoreShelf,
        name: name,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Restore", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfUndoDeletionFeedbackAction(
    name: String,
    originalTimestamp: Int64,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .undoShelfDeletion,
        name: name,
        restoreTimestamp: originalTimestamp,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Undo", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfUndoDeletionsFeedbackAction(
    names: [String],
    originalTimestamps: [String: Int64],
    title: String = "Undo",
    rootPath: String? = nil
) -> FeedbackAction? {
    let normalizedNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && originalTimestamps[$0] != nil }
    guard !normalizedNames.isEmpty,
          let resolvedRootPath = rootPath ?? repo?.workdir() else { return nil }
    let request = ArborVCSActionRequest(
        kind: .undoShelfDeletions,
        projectPath: projectWorkspace.path,
        rootPath: resolvedRootPath,
        shelfName: "",
        shelfRestoreTimestamps: Dictionary(
            uniqueKeysWithValues: normalizedNames.compactMap { name in
                originalTimestamps[name].map { (name, $0) }
            }
        ),
        shelfNames: normalizedNames
    )
    return FeedbackAction(title: title, semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func shelfUndoDeletedMembersFeedbackAction(
    name: String,
    paths: [String],
    originalTimestamp: Int64,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .restoreShelfPaths,
        name: name,
        paths: paths,
        restoreTimestamp: originalTimestamp,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Undo", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfDropFeedbackAction(
    name: String,
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .dropShelf,
        name: name,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Drop", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

func shelfDeleteDeletedMembersFeedbackAction(
    name: String,
    paths: [String],
    rootPath: String? = nil
) -> FeedbackAction {
    let request = shelfActionRequest(
        kind: .deleteDeletedShelfPaths,
        name: name,
        paths: paths,
        rootPath: rootPath
    )
    return FeedbackAction(title: "Retry Delete Permanently", semanticAction: request) {
        guard let request else { return }
        self.handleVCSActionRequest(request)
    }
}

}
