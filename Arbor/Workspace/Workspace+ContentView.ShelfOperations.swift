import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func normalizedShelfPathGroups(
    _ groups: [ShelfPathDeleteGroup]
) -> [ShelfPathDeleteGroup] {
    var result: [ShelfPathDeleteGroup] = []
    var indexes: [String: Int] = [:]
    for group in groups {
        let name = group.shelfName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        var paths: [String] = []
        var seenPaths = Set<String>()
        for path in group.paths {
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seenPaths.insert(normalized).inserted else { continue }
            paths.append(normalized)
        }
        guard !paths.isEmpty else { continue }
        if let index = indexes[name] {
            var merged = result[index].paths
            for path in paths where !merged.contains(path) {
                merged.append(path)
            }
            result[index] = ShelfPathDeleteGroup(shelfName: name, paths: merged)
        } else {
            indexes[name] = result.count
            result.append(ShelfPathDeleteGroup(shelfName: name, paths: paths))
        }
    }
    return result
}

nonisolated func shelfPathGroupKey(_ group: ShelfPathDeleteGroup) -> String {
    "\(group.shelfName)\u{1E}\(group.paths.joined(separator: "\u{1F}"))"
}

/// Apply multiple ShelvedChangeLists serially. An explicit target mirrors
/// UnshelveWithDialogAction; a nil target mirrors ChangesView.UnshelveSilently
/// and lets the automatic Changelist setting choose a destination per Shelf.
/// Serial execution is intentional because all lists modify one worktree and
/// the Rust engine persists one conflict restore snapshot per repository.
nonisolated func shelfOperationItems(
    rootPath: String,
    names: [String],
    states: [String: FeedbackResultState],
    details: [String: String],
    children: [String: [FeedbackOperationSubitem]] = [:]
) -> [FeedbackOperationItem] {
    names.map { name in
        FeedbackOperationItem(
            scope: rootPath,
            name: name,
            state: states[name] ?? .skipped,
            detail: details[name] ?? "Not attempted",
            children: children[name] ?? []
        )
    }
}

nonisolated func shelfOperationSubitems(
    scope: String,
    paths: [String],
    result: PatchApplyResult,
    successDetail: String,
    failureDetail: String,
    skippedDetail: String = "Not attempted"
) -> [FeedbackOperationSubitem] {
    var statuses: [String: PatchApplyStatus] = [:]
    for member in result.memberStatuses {
        statuses[member.path] = member.status
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map { path in
        let status = statuses[path] ?? .skip
        let state: FeedbackResultState
        let detail: String
        switch status {
        case .success:
            state = .success
            detail = successDetail
        case .alreadyApplied:
            state = .success
            detail = "Already applied"
        case .partial:
            state = .partial
            detail = "Partially applied"
        case .failure:
            state = .failed
            detail = failureDetail
        case .skip:
            state = .skipped
            detail = skippedDetail
        case .abort:
            state = .aborted
            detail = "Aborted"
        }
        return FeedbackOperationSubitem(
            scope: scope,
            path: path,
            state: state,
            detail: detail
        )
    }
}

nonisolated func shelfOperationSubitems(
    scope: String,
    paths: [String],
    state: FeedbackResultState,
    detail: String
) -> [FeedbackOperationSubitem] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map {
        FeedbackOperationSubitem(
            scope: scope,
            path: $0,
            state: state,
            detail: detail
        )
    }
}

nonisolated func shelfOperationSubitems(
    scope: String,
    paths: [String],
    appliedPaths: Set<String>,
    failedPaths: Set<String>,
    successDetail: String,
    failureDetail: String,
    skippedDetail: String = "Not attempted"
) -> [FeedbackOperationSubitem] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map { path in
        let state: FeedbackResultState
        let detail: String
        if failedPaths.contains(path) {
            state = .failed
            detail = failureDetail
        } else if appliedPaths.contains(path) {
            state = .success
            detail = successDetail
        } else {
            state = .skipped
            detail = skippedDetail
        }
        return FeedbackOperationSubitem(
            scope: scope,
            path: path,
            state: state,
            detail: detail
        )
    }
}

/// Move selected Shelf members to another ShelvedChangeList without applying
/// them to the worktree. The engine preserves patch metadata and moves the
/// source to Recently Deleted when its final member is transferred.
func moveShelfPaths(
    _ sourceName: String,
    _ targetName: String,
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
    beginFeedbackOperation("Move shelf changes")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveMovePaths(
                sourceName: sourceName,
                targetName: targetName,
                paths: paths
            )
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
                self.feedbackCenter.success(
                    "Shelf changes moved",
                    detail: targetName,
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "move",
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Move shelf changes failed",
                    detail: errorMessage(error),
                    nextStep: "Choose a destination shelf without overlapping paths, then retry.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "move",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

}
