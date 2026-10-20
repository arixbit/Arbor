import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Build the same two-level ShelvedChangeList -> path tree that IntelliJ uses
/// for a shelf. The helper is kept pure so ordering and folder de-duplication
/// remain testable independently from SwiftUI state.
func intellijFilePathCompare(
    _ lhs: String,
    _ rhs: String,
    flattened: Bool
) -> ComparisonResult {
    if flattened {
        let lhsName = lhs.split(separator: "/").last.map(String.init) ?? lhs
        let rhsName = rhs.split(separator: "/").last.map(String.init) ?? rhs
        let nameOrder = lhsName.localizedStandardCompare(rhsName)
        if nameOrder != .orderedSame {
            return nameOrder
        }
    }
    return lhs.localizedStandardCompare(rhs)
}

enum StagingComparisonAction: String, CaseIterable, Equatable {
    case localWithStaged
    case stagedWithLocal
    case stagedWithHead
    case threeVersions
}

func stagingComparisonDiffMode(for action: StagingComparisonAction) -> DiffMode? {
    switch action {
    case .localWithStaged:
        // IntelliJ's Local-with-Staged and Staged-with-Local actions share
        // compareStagedWithLocal: staged is the base and local is the right
        // side, which is also the coordinate system used by stageLines.
        return .worktreeToIndex
    case .stagedWithLocal:
        return .worktreeToIndex
    case .stagedWithHead:
        return .indexToHead
    case .threeVersions:
        return nil
    }
}

/// Match IntelliJ's staging action visibility to the two-dimensional status
/// model. A comparison is only offered when both sides are represented by the
/// entry; single-sided untracked/deleted changes must not advertise a second
/// version that does not exist.
func stagingComparisonActions(
    for entry: FileEntry,
    presence: StagingVersionPresence? = nil
) -> [StagingComparisonAction] {
    guard entry.staged != .conflicted,
          entry.unstaged != .conflicted,
          entry.staged != .ignored,
          entry.unstaged != .ignored else { return [] }

    var actions: [StagingComparisonAction] = []
    let hasHead = presence?.head ?? (
        entry.staged != .unchanged
            && entry.staged != .added
            && entry.staged != .untracked
    )
    let hasStaged = presence?.staged ?? (entry.staged != .unchanged)
    let hasLocal = presence?.local ?? (entry.unstaged != .unchanged)
    if hasStaged && hasLocal {
        actions.append(contentsOf: [.localWithStaged, .stagedWithLocal])
        if hasHead {
            actions.append(.threeVersions)
        }
    }
    if hasStaged && hasHead {
        actions.append(.stagedWithHead)
    }
    return actions
}
