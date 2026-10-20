import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PersistedLogGraphRestore: Equatable, Sendable {
    let commits: [CommitInfo]
    let cursor: String?
    let hasMore: Bool
}
/// Multi-root preserving processes use a unique Shelf name so parallel roots
/// never overwrite one another. The stable prefix keeps relaunch recovery
/// discoverable without depending on in-memory operation state.
func isArborUpdateShelfName(_ name: String) -> Bool {
    name.hasPrefix("Arbor: Update Project")
        || name.hasPrefix("Arbor: Checkout and Update")
}
func isArborPushRecoveryShelfName(_ name: String) -> Bool {
    name.hasPrefix("Arbor: Push update")
}
func isArborTemporaryShelfName(_ name: String) -> Bool {
    isArborUpdateShelfName(name) || isArborPushRecoveryShelfName(name)
}
/// Shelf semantic actions carry a root-qualified identity. Reject an inactive
/// root before any action can accidentally use `projectRepo`; metadata-only
/// actions may proceed through the selected secondary Shelf repository.
func shelfActionRootMatchesCurrentRoot(
    requestedRootPath: String?,
    currentRootPath: String?
) -> Bool {
    guard let requestedRootPath else { return true }
    guard let currentRootPath else { return false }
    return canonicalExternalLogPath(requestedRootPath)
        == canonicalExternalLogPath(currentRootPath)
}
/// A nil selection means the workspace's primary root. This helper keeps the
/// read-only boundary explicit and testable instead of relying on view state
/// comparisons that can briefly observe an old root during reload.
func shelfRootSelectionIsPrimary(
    selectedRootPath: String?,
    primaryRootPath: String?
) -> Bool {
    guard let primaryRootPath else { return selectedRootPath == nil }
    guard let selectedRootPath else { return true }
    return canonicalExternalLogPath(selectedRootPath)
        == canonicalExternalLogPath(primaryRootPath)
}
/// A secondary Shelf root owns its shelf files under `.git`. A metadata event
/// for that root must reload the selected Shelf snapshot; refreshing the
/// aggregate Branches snapshot alone cannot update Recently Deleted or the
/// selected root's existing change-list snapshot.
func shouldRefreshSecondaryShelfSnapshot(
    eventRootPath: String,
    activeRootPath: String?,
    primaryRootPath: String?,
    scopes: RepositoryChangeScope
) -> Bool {
    guard scopes.contains(.gitMetadata),
          let activeRootPath,
          !shelfRootSelectionIsPrimary(
              selectedRootPath: activeRootPath,
              primaryRootPath: primaryRootPath
          ) else {
        return false
    }
    return canonicalExternalLogPath(eventRootPath)
        == canonicalExternalLogPath(activeRootPath)
}
func shelfNotificationID(prefix: String, rootPath: String) -> String {
    let stableRoot = rootPath
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.\(prefix).\(stableRoot)"
}
func shelfFeedbackTitle(
    _ operation: ArborVCSActionRequest.ShelfBatchOperation,
    removeApplied: Bool = false
) -> String {
    switch operation {
    case .apply:
        return removeApplied ? "Unshelve and Remove Shelf" : "Apply Shelf"
    case .pop:
        return "Pop Shelf"
    case .drop:
        return "Drop Shelf"
    }
}
func shelfMutationContext(
    rootPath: String?,
    activeRootPath: String?,
    primaryRootPath: String?,
    primaryRepository: Repository?,
    secondaryRepository: Repository?
) -> (repository: Repository, rootPath: String)? {
    guard let requestedRootPath = rootPath ?? primaryRootPath,
          !requestedRootPath.isEmpty else { return nil }
    let resolvedRootPath = canonicalExternalLogPath(requestedRootPath)

    // A direct call without an explicit root is a primary-root operation. An
    // explicit root must still be the root currently selected in the Shelf
    // workspace; this prevents a late notification action from crossing roots.
    if rootPath == nil {
        guard shelfRootSelectionIsPrimary(
            selectedRootPath: activeRootPath,
            primaryRootPath: primaryRootPath
        ) else { return nil }
    } else {
        guard shelfActionRootMatchesCurrentRoot(
            requestedRootPath: resolvedRootPath,
            currentRootPath: activeRootPath
        ) else { return nil }
    }

    if shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryRootPath
    ) {
        guard let primaryRepository else { return nil }
        return (primaryRepository, resolvedRootPath)
    }
    guard let secondaryRepository else { return nil }
    return (secondaryRepository, resolvedRootPath)
}
func shelfPreviewRequestMatches(
    requestedRootPath: String,
    currentRootPath: String?,
    requestedName: String,
    currentName: String?,
    requestedIsDeleted: Bool,
    currentIsDeleted: Bool
) -> Bool {
    shelfActionRootMatchesCurrentRoot(
        requestedRootPath: requestedRootPath,
        currentRootPath: currentRootPath
    )
        && requestedName == currentName
        && requestedIsDeleted == currentIsDeleted
}
func isSecondaryShelfRootScopedAction(
    _ kind: ArborVCSActionRequest.Kind
) -> Bool {
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
         .retryShelfDeletePlan,
         // Root-scoped Push notifications may target a nested Git root even
         // when the Shelf panel is currently pointed at another repository.
         .retryPush,
         .retryPushRecovery,
         .retryStashBranch,
         // Log apply recovery is also root-scoped. Its notification can be
         // acted on while the Shelf panel remains focused on another root.
         .retryLogApply,
         .showLogApplyAffectedFiles:
        return true
    default:
        return false
    }
}
