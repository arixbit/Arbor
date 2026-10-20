import Foundation

/// Durable context for Create Branch from Stash. The stash index is only a
/// presentation position and changes after another stash is created or
/// dropped, so retries use the stash object id plus the repository state that
/// the original operation observed.
struct PersistedStashBranchRetry: Codable, Equatable, Sendable {
    let stashID: String
    let branch: String
    let expectedCurrentBranch: String?
    let expectedCurrentHead: String?

    init(
        stashID: String,
        branch: String,
        expectedCurrentBranch: String?,
        expectedCurrentHead: String?
    ) {
        self.stashID = stashID
        self.branch = branch
        self.expectedCurrentBranch = expectedCurrentBranch
        self.expectedCurrentHead = expectedCurrentHead
    }
}

func stashBranchRetryStateIsSafe(
    _ retry: PersistedStashBranchRetry,
    currentBranch: String?,
    currentHead: String?,
    stashIDs: [String],
    localBranches: [String]
) -> Bool {
    retry.expectedCurrentBranch == currentBranch
        && retry.expectedCurrentHead == currentHead
        && stashIDs.contains(retry.stashID)
        && !localBranches.contains(retry.branch)
}

struct PersistedShelfPathGroup: Codable, Equatable, Sendable {
    let shelfName: String
    let paths: [String]
}

/// Durable retry scope for IntelliJ's mixed Shelf DeleteProvider action.
/// Active and Recently Deleted members must remain distinguishable when a
/// notification outlives the original tree selection.
struct PersistedShelfDeletePlan: Codable, Equatable, Sendable {
    let activeShelfNames: [String]
    let activePathGroups: [PersistedShelfPathGroup]
    let deletedShelfNames: [String]
    let deletedPathGroups: [PersistedShelfPathGroup]

    init(_ plan: ShelfDeletePlan) {
        activeShelfNames = plan.activeShelfNames
        activePathGroups = plan.activePathGroups.map {
            PersistedShelfPathGroup(shelfName: $0.shelfName, paths: $0.paths)
        }
        deletedShelfNames = plan.deletedShelfNames
        deletedPathGroups = plan.deletedPathGroups.map {
            PersistedShelfPathGroup(shelfName: $0.shelfName, paths: $0.paths)
        }
    }

    var shelfDeletePlan: ShelfDeletePlan {
        ShelfDeletePlan(
            activeShelfNames: activeShelfNames,
            activePathGroups: activePathGroups.map {
                ShelfPathDeleteGroup(shelfName: $0.shelfName, paths: $0.paths)
            },
            deletedShelfNames: deletedShelfNames,
            deletedPathGroups: deletedPathGroups.map {
                ShelfPathDeleteGroup(shelfName: $0.shelfName, paths: $0.paths)
            }
        )
    }
}
